// Package snapshot captures a coherent picture of system state at the moment
// a threshold breach is detected. The point is forensic: when the user opens
// a report two days later, every datum needed to reason about the incident
// must already be on disk.
//
// We intentionally accept partial failures: if the journal is unreadable, we
// note that and continue rather than aborting the whole snapshot. A report
// with eight of ten sections is far more useful than no report at all.
package snapshot

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/milos85vasic/oom-protect/oom-watch/internal/atop"
	"github.com/milos85vasic/oom-protect/oom-watch/internal/monitor"
)

// Snapshot is a self-contained record of one incident.
type Snapshot struct {
	Time     time.Time
	Hostname string
	Verdict  monitor.Verdict
	Sample   *atop.Sample

	// Raw text from various /proc and cgroup files. Keep them as strings so
	// the report can quote them verbatim — operators trust raw output.
	MemInfo         string // /proc/meminfo
	LoadAvg         string // /proc/loadavg
	PressureMemory  string // /proc/pressure/memory
	PressureCPU     string // /proc/pressure/cpu
	PressureIO      string // /proc/pressure/io
	UserSliceCgroup string // /sys/fs/cgroup/user.slice/memory.* highlights

	// Top processes, derived from atop's PRM/PRC and from a ps fallback.
	TopByMemory []ProcessLine
	TopByCPU    []ProcessLine

	// Forensic detail for each PID in TopByMemory: full /proc/<pid>/cmdline,
	// PPID + UID from /proc/<pid>/status, cgroup membership, peak RSS, and
	// the parent's command line (so a script that forked the runaway can be
	// identified). Captured best-effort — a process may exit between top-N
	// selection and detail capture, in which case its entry is partial and
	// the missing fields are documented in Snapshot.Errors.
	TopByMemoryDetail []ProcessDetail

	// Recent dmesg lines mentioning oom-killer / killed process / cgroup
	// memory exhaustion. Empty if dmesg is unavailable or nothing recent.
	KernelOOMTail string

	// Journal tail — best-effort. May be empty if journalctl is unavailable.
	JournalTail string

	// Errors encountered during capture. Each entry names the source. We do
	// not abort on these; we record them so reports document what is missing.
	Errors []string
}

// ProcessDetail is the per-process forensic enrichment, read directly from
// /proc/<pid>/* at snapshot time. atop's PRM line gives only a truncated cmd
// name (~15 characters) and no context; ProcessDetail closes that gap so an
// operator opening the report two days later can answer "which process,
// started by what, owned by whom, in which cgroup, with what arguments?".
type ProcessDetail struct {
	PID         int      // 0 if the /proc/<pid> tree was already gone
	PPID        int      // parent PID
	UID         int      // real UID
	Cmdline     []string // /proc/<pid>/cmdline split on NUL — the actual argv
	State       string   // /proc/<pid>/status State: line
	VmRSSKB     int64    // current resident set
	VmHWMKB     int64    // peak resident set (high-water mark) — may exceed
	//                    // VmRSSKB after the kernel has reclaimed pages
	VmPeakKB    int64    // peak virtual address space
	OomScore    int      // /proc/<pid>/oom_score (kernel's badness score)
	OomScoreAdj int      // /proc/<pid>/oom_score_adj (operator override)
	Cgroup      string   // /proc/<pid>/cgroup (top entry — usually unified)
	ParentCmd   string   // /proc/<ppid>/cmdline (joined) — "this was forked by …"
	Source      string   // "/proc/<pid>" or "<missing>" if process exited
}

// ProcessLine is a flattened view of a process for the report.
type ProcessLine struct {
	PID    int
	Cmd    string
	State  string
	RSize  int64 // pages — bytes when multiplied by sample.MEM.PageSize
	VSize  int64 // pages
	Source string // "atop-PRM", "atop-PRC", "ps"
}

// Options controls Capture's behavior. Production callers leave defaults
// (ProcRoot="/proc", CgroupRoot="/sys/fs/cgroup", JournalCommand=...). Tests
// override these to point at fake fixtures.
type Options struct {
	ProcRoot       string
	CgroupRoot     string
	UID            int      // for /sys/fs/cgroup/user.slice/user-<UID>.slice
	JournalCommand []string // e.g. ["journalctl", "-n", "200", "--no-pager"]
	DmesgCommand   []string // e.g. ["dmesg", "--time-format=iso"]; empty disables
	TopN           int      // how many processes to report
	// EnrichTopN bounds how many top-mem PIDs get the per-process /proc/<pid>
	// forensic enrichment. 10 strikes a balance between forensic depth and
	// snapshot wall-clock cost on a 2000-PID system.
	EnrichTopN int

	// SkipJournal lets tests opt out of running journalctl (which may not
	// exist or may require permissions on the test host).
	SkipJournal bool
	// SkipDmesg lets tests opt out of running dmesg (output volume + perms).
	SkipDmesg bool
	// SkipEnrich lets tests opt out of /proc/<pid> reads when the test root
	// has no realistic per-PID structure.
	SkipEnrich bool
}

// Defaults returns production-ready Options for the current host.
func Defaults() Options {
	return Options{
		ProcRoot:       "/proc",
		CgroupRoot:     "/sys/fs/cgroup",
		UID:            os.Getuid(),
		JournalCommand: []string{"journalctl", "-n", "200", "--no-pager"},
		// dmesg --since-boot is fine; we filter to oom-related lines only.
		// On hosts where dmesg requires CAP_SYSLOG and the daemon doesn't
		// have it, the call returns EPERM, snap.Errors records it, and
		// the report's "Kernel OOM events" section shows "no data" — the
		// rest of the report is unaffected.
		DmesgCommand: []string{"dmesg", "--ctime"},
		TopN:         20,
		EnrichTopN:   10,
	}
}

// Capture takes a Verdict + Sample and assembles a Snapshot. It MUST NOT
// return nil: any failures are recorded in Snapshot.Errors so the report
// captures the partial state.
func Capture(ctx context.Context, v monitor.Verdict, s *atop.Sample, opts Options) *Snapshot {
	if opts.ProcRoot == "" {
		opts.ProcRoot = "/proc"
	}
	if opts.CgroupRoot == "" {
		opts.CgroupRoot = "/sys/fs/cgroup"
	}
	if opts.TopN <= 0 {
		opts.TopN = 20
	}
	if opts.EnrichTopN <= 0 {
		opts.EnrichTopN = 10
	}
	host, _ := os.Hostname()
	snap := &Snapshot{
		Time:     time.Now().UTC(),
		Hostname: host,
		Verdict:  v,
		Sample:   s,
	}

	// Each readSafe records (not raises) errors so partial captures still ship.
	snap.MemInfo = snap.readSafe(filepath.Join(opts.ProcRoot, "meminfo"))
	snap.LoadAvg = snap.readSafe(filepath.Join(opts.ProcRoot, "loadavg"))
	snap.PressureMemory = snap.readSafe(filepath.Join(opts.ProcRoot, "pressure", "memory"))
	snap.PressureCPU = snap.readSafe(filepath.Join(opts.ProcRoot, "pressure", "cpu"))
	snap.PressureIO = snap.readSafe(filepath.Join(opts.ProcRoot, "pressure", "io"))

	snap.UserSliceCgroup = snap.readUserSlice(opts)

	snap.TopByMemory, snap.TopByCPU = topProcesses(s, opts.TopN)

	// Forensic enrichment: full /proc/<pid> detail for the top-N memory
	// suspects. atop gives only a truncated cmd name; this section closes
	// the gap so a future operator can identify exactly WHICH instance,
	// running with WHICH arguments, started by WHICH parent script.
	if !opts.SkipEnrich {
		n := opts.EnrichTopN
		if n > len(snap.TopByMemory) {
			n = len(snap.TopByMemory)
		}
		snap.TopByMemoryDetail = make([]ProcessDetail, 0, n)
		for i := 0; i < n; i++ {
			snap.TopByMemoryDetail = append(snap.TopByMemoryDetail,
				snap.enrichProcess(snap.TopByMemory[i].PID, opts.ProcRoot))
		}
	}

	// Kernel OOM events (separate from systemd-oomd events, which appear
	// in the journal tail). The kernel's own OOM-killer messages — "Out of
	// memory: Killed process …", "Memory cgroup out of memory" — are the
	// authoritative record of who the kernel terminated and why.
	if !opts.SkipDmesg && len(opts.DmesgCommand) > 0 {
		snap.KernelOOMTail = snap.runDmesgOOM(ctx, opts.DmesgCommand)
	}

	if !opts.SkipJournal && len(opts.JournalCommand) > 0 {
		snap.JournalTail = snap.runJournalctl(ctx, opts.JournalCommand)
	}

	return snap
}

func (s *Snapshot) readSafe(path string) string {
	b, err := os.ReadFile(path)
	if err != nil {
		s.Errors = append(s.Errors, fmt.Sprintf("read %s: %v", path, err))
		return ""
	}
	return string(b)
}

func (s *Snapshot) readUserSlice(opts Options) string {
	dir := filepath.Join(opts.CgroupRoot, "user.slice", fmt.Sprintf("user-%d.slice", opts.UID))
	files := []string{"memory.current", "memory.max", "memory.high", "memory.swap.current",
		"memory.pressure", "cpu.pressure", "cgroup.procs"}
	var b strings.Builder
	missingAll := true
	for _, f := range files {
		path := filepath.Join(dir, f)
		raw, err := os.ReadFile(path)
		if err != nil {
			continue
		}
		missingAll = false
		fmt.Fprintf(&b, "%s:\n%s\n", f, strings.TrimRight(string(raw), "\n"))
	}
	if missingAll {
		s.Errors = append(s.Errors, fmt.Sprintf("cgroup dir empty or missing: %s", dir))
	}
	return b.String()
}

// enrichProcess reads /proc/<pid>/{cmdline,status,cgroup} and the parent's
// /proc/<ppid>/cmdline. Best-effort: missing fields are left zero/empty and
// each failure is recorded in Snapshot.Errors so the report documents what
// could not be captured.
func (s *Snapshot) enrichProcess(pid int, procRoot string) ProcessDetail {
	d := ProcessDetail{PID: pid, Source: fmt.Sprintf("%s/%d", procRoot, pid)}
	procDir := filepath.Join(procRoot, fmt.Sprintf("%d", pid))
	if _, err := os.Stat(procDir); err != nil {
		// Process exited between top-N selection and detail capture.
		d.PID = 0
		d.Source = "<missing>"
		s.Errors = append(s.Errors, fmt.Sprintf("enrich pid=%d: %v (process exited)", pid, err))
		return d
	}

	if raw, err := os.ReadFile(filepath.Join(procDir, "cmdline")); err == nil {
		// /proc/<pid>/cmdline is NUL-separated argv. Split on NUL, drop the
		// trailing empty element kernel adds.
		parts := strings.Split(string(raw), "\x00")
		out := parts[:0]
		for _, p := range parts {
			if p != "" {
				out = append(out, p)
			}
		}
		d.Cmdline = out
	} else {
		s.Errors = append(s.Errors, fmt.Sprintf("enrich pid=%d cmdline: %v", pid, err))
	}

	if raw, err := os.ReadFile(filepath.Join(procDir, "status")); err == nil {
		// Parse the small subset of /proc/<pid>/status we care about. Format
		// is "Key:\tValue\n" with whitespace variation between kernels.
		for _, line := range strings.Split(string(raw), "\n") {
			key, value, found := strings.Cut(line, ":")
			if !found {
				continue
			}
			value = strings.TrimSpace(value)
			switch key {
			case "PPid":
				d.PPID = parseIntFirst(value)
			case "Uid":
				// "Uid:\t<real>\t<effective>\t<saved>\t<filesystem>"
				d.UID = parseIntFirst(value)
			case "State":
				// "State:\tR (running)" — keep just the letter.
				if len(value) >= 1 {
					d.State = string(value[0])
				}
			case "VmRSS":
				d.VmRSSKB = parseKB(value)
			case "VmHWM":
				d.VmHWMKB = parseKB(value)
			case "VmPeak":
				d.VmPeakKB = parseKB(value)
			}
		}
	} else {
		s.Errors = append(s.Errors, fmt.Sprintf("enrich pid=%d status: %v", pid, err))
	}

	if raw, err := os.ReadFile(filepath.Join(procDir, "oom_score")); err == nil {
		d.OomScore = parseIntFirst(strings.TrimSpace(string(raw)))
	}
	if raw, err := os.ReadFile(filepath.Join(procDir, "oom_score_adj")); err == nil {
		d.OomScoreAdj = parseIntFirst(strings.TrimSpace(string(raw)))
	}

	if raw, err := os.ReadFile(filepath.Join(procDir, "cgroup")); err == nil {
		// /proc/<pid>/cgroup typically has one line on cgroup-v2 unified
		// hierarchies: "0::/user.slice/user-1000.slice/...". We keep the
		// first non-empty line.
		for _, line := range strings.Split(string(raw), "\n") {
			line = strings.TrimSpace(line)
			if line != "" {
				d.Cgroup = line
				break
			}
		}
	}

	// Parent command line — the most useful single piece of forensic context
	// for "this Java was forked by IntelliJ" / "this python was started by
	// build.sh". Best-effort: parent may have already exited.
	if d.PPID > 0 && d.PPID != pid {
		ppDir := filepath.Join(procRoot, fmt.Sprintf("%d", d.PPID))
		if raw, err := os.ReadFile(filepath.Join(ppDir, "cmdline")); err == nil {
			parent := strings.ReplaceAll(strings.TrimRight(string(raw), "\x00"), "\x00", " ")
			d.ParentCmd = parent
		}
	}

	return d
}

// parseIntFirst takes a whitespace-separated string and returns the first
// integer (or 0 on failure). Used for /proc/<pid>/status fields like "Uid:
// 1000\t1000\t1000\t1000" where only the first value matters.
func parseIntFirst(s string) int {
	for _, f := range strings.Fields(s) {
		var n int
		_, err := fmt.Sscanf(f, "%d", &n)
		if err == nil {
			return n
		}
	}
	return 0
}

// parseKB takes a string like "12345 kB" and returns the integer KB value.
func parseKB(s string) int64 {
	var n int64
	_, _ = fmt.Sscanf(s, "%d", &n)
	return n
}

// runDmesgOOM runs dmesg and filters to lines mentioning the kernel
// OOM-killer. The signal value of these lines is high — they are the
// authoritative record of who the kernel killed and why — but the volume
// is low (only present when something actually got killed), so most reports
// will show an empty section. That's fine and expected.
func (s *Snapshot) runDmesgOOM(ctx context.Context, argv []string) string {
	if _, err := exec.LookPath(argv[0]); err != nil {
		s.Errors = append(s.Errors, fmt.Sprintf("dmesg missing: %v", err))
		return ""
	}
	cctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	cmd := exec.CommandContext(cctx, argv[0], argv[1:]...)
	out, err := cmd.Output()
	if err != nil {
		s.Errors = append(s.Errors, fmt.Sprintf("dmesg: %v", err))
		// Continue; we may still have some captured output.
	}
	// Filter to OOM-relevant lines. Using a small set of substrings rather
	// than a regex keeps the implementation easy to audit and zero-deps.
	wanted := []string{
		"Out of memory",
		"oom-killer",
		"Killed process",
		"Memory cgroup out of memory",
		"oom_reaper",
	}
	var b strings.Builder
	for _, line := range strings.Split(string(out), "\n") {
		for _, w := range wanted {
			if strings.Contains(line, w) {
				b.WriteString(line)
				b.WriteByte('\n')
				break
			}
		}
	}
	return b.String()
}

func (s *Snapshot) runJournalctl(ctx context.Context, argv []string) string {
	if _, err := exec.LookPath(argv[0]); err != nil {
		s.Errors = append(s.Errors, fmt.Sprintf("journalctl missing: %v", err))
		return ""
	}
	cctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	cmd := exec.CommandContext(cctx, argv[0], argv[1:]...)
	out, err := cmd.Output()
	if err != nil {
		s.Errors = append(s.Errors, fmt.Sprintf("journalctl: %v", err))
		// Even on error we keep whatever stdout produced.
	}
	return string(out)
}

// topProcesses sorts atop's PRM by RSize desc and PRC by some-CPU-proxy.
//
// PRM filtering: atop 2.x emits ONE PRM row per kernel thread; non-leader
// threads duplicate the parent's RSize because they share its address space.
// A 100-thread JVM would otherwise drown out every other process in the
// top-N list. We keep only thread-group leader rows here. atop versions that
// do not emit the leader flag set IsLeader=true on every row, so this filter
// is a no-op there (lossless fallback). The parser keeps every row in the
// Sample for callers that genuinely want per-thread breakdowns.
func topProcesses(s *atop.Sample, n int) (mem, cpu []ProcessLine) {
	if s == nil {
		return
	}
	memList := make([]ProcessLine, 0, len(s.PRM))
	for _, p := range s.PRM {
		if !p.IsLeader {
			continue
		}
		memList = append(memList, ProcessLine{
			PID: p.PID, Cmd: p.Cmd, State: p.State,
			RSize: p.RSize, VSize: p.VSize, Source: "atop-PRM",
		})
	}
	sort.SliceStable(memList, func(i, j int) bool {
		return memList[i].RSize > memList[j].RSize
	})
	if len(memList) > n {
		memList = memList[:n]
	}

	cpuList := make([]ProcessLine, 0, len(s.PRC))
	for _, p := range s.PRC {
		cpuList = append(cpuList, ProcessLine{
			PID: p.PID, Cmd: p.Cmd, State: p.State, Source: "atop-PRC",
		})
	}
	if len(cpuList) > n {
		cpuList = cpuList[:n]
	}
	return memList, cpuList
}
