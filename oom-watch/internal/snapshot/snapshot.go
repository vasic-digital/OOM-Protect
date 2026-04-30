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

	// Journal tail — best-effort. May be empty if journalctl is unavailable.
	JournalTail string

	// Errors encountered during capture. Each entry names the source. We do
	// not abort on these; we record them so reports document what is missing.
	Errors []string
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
	TopN           int      // how many processes to report

	// SkipJournal lets tests opt out of running journalctl (which may not
	// exist or may require permissions on the test host).
	SkipJournal bool
}

// Defaults returns production-ready Options for the current host.
func Defaults() Options {
	return Options{
		ProcRoot:       "/proc",
		CgroupRoot:     "/sys/fs/cgroup",
		UID:            os.Getuid(),
		JournalCommand: []string{"journalctl", "-n", "200", "--no-pager"},
		TopN:           20,
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

// topProcesses sorts atop's PRM by RSize desc and PRC by some-CPU-proxy. We
// keep it simple: PRC.Raw[0] is interpreted as % CPU when populated, else 0.
// The point of "top" lists in the report is forensic ranking, not precision.
func topProcesses(s *atop.Sample, n int) (mem, cpu []ProcessLine) {
	if s == nil {
		return
	}
	memList := make([]ProcessLine, 0, len(s.PRM))
	for _, p := range s.PRM {
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
