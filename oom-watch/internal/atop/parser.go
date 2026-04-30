// Package atop parses the parseable output emitted by atop -PALL (or -P<labels>).
//
// Format reference: atop(1) man page, "parsable output" section.
// Source of truth: https://github.com/Atoptool/atop (master/man/atop.1).
//
// Each line begins with six common fields:
//
//	<label> <host> <epoch> <YYYY/MM/DD> <HH:MM:SS> <interval-seconds>
//
// followed by label-specific fields. Process labels (PRC, PRM, PRG, PRD, PRN,
// PRE) embed a command name in parentheses (or, with -Z, an underscore-escaped
// bareword) which we must extract carefully because commands can contain
// spaces.
//
// Each sample is terminated by a line "SEP". Between samples-since-boot and
// the regular interval samples atop emits a "RESET" line. We treat RESET as
// the end of one sample (the boot summary) and the start of the next.
package atop

import (
	"bufio"
	"errors"
	"fmt"
	"io"
	"strconv"
	"strings"
)

// Sample is one full atop interval, decoded into typed fields. Only labels we
// actively care about for OOM/pressure detection are exposed as typed fields;
// all other labels are kept as raw lines under Other so callers can inspect
// them without re-parsing.
type Sample struct {
	Host     string
	Epoch    int64  // seconds since 1970-01-01
	Date     string // YYYY/MM/DD
	Time     string // HH:MM:SS
	Interval int    // seconds for this sample

	MEM *MEM
	SWP *SWP
	CPU *CPU
	CPL *CPL
	PSI *PSI

	PRC []PRC // per-process CPU
	PRM []PRM // per-process memory
	GPU []GPU
	DSK []DSK

	Other map[string][]string // label -> raw payload lines (without the 6-field header)

	// Reset is true if this sample was preceded by atop's RESET marker
	// (i.e. it represents values since boot, not a regular interval).
	Reset bool
}

// MEM matches the MEM label. All page-counted fields are kept as page counts;
// callers that need bytes multiply by PageSize.
//
// Field order (from atop man page, master branch as of 2024-07):
//
//	pagesize physmem freemem cachemem buffermem slabmem dirtypages slabreclaim
//	vmwareballoon shmem shmemres shmemswp shugesize shugetotal shugefree
//	zfsarc ksmsharing ksmshared tcpsockmem udpsockmem pagetables
//	lhugesize lhugetotal lhugefree availmem anonthp
type MEM struct {
	PageSize     int64
	PhysPages    int64
	FreePages    int64
	CachePages   int64
	BufferPages  int64
	SlabPages    int64
	DirtyPages   int64
	SlabReclaim  int64
	VmwBalloon   int64
	ShmemPages   int64
	ShmemRes     int64
	ShmemSwap    int64
	HugeSizeS    int64
	HugeTotalS   int64
	HugeFreeS    int64
	ZfsArcPages  int64
	KsmSharing   int64
	KsmShared    int64
	TcpSockPages int64
	UdpSockPages int64
	PageTables   int64
	HugeSizeL    int64
	HugeTotalL   int64
	HugeFreeL    int64
	AvailPages   int64 // kernel "MemAvailable" — the canonical "memory left for new work"
	AnonThp      int64
}

// SWP matches the SWP label.
type SWP struct {
	PageSize     int64
	SwapPages    int64
	SwapFree     int64
	SwapCache    int64
	CommittedAS  int64
	CommitLimit  int64
	SwapCache2   int64
	ZswapDecomp  int64
	ZswapStored  int64
}

// CPU matches the CPU (uppercase total) label.
type CPU struct {
	HertzPerSec int64 // clock-ticks per second
	NumCPU      int64
	SysTicks    int64
	UsrTicks    int64
	NiceTicks   int64
	IdleTicks   int64
	WaitTicks   int64
	IrqTicks    int64
	SoftIrq     int64
	StealTicks  int64
	GuestTicks  int64
	FreqMHz     int64
	FreqPct     int64
	Instr       int64
	Cycles      int64
}

// CPL matches the CPL label (load averages + ctxsw/intr).
type CPL struct {
	NumCPU       int64
	Load1        float64
	Load5        float64
	Load15       float64
	ContextSwits int64
	DeviceIntr   int64
}

// PSI matches the PSI label (pressure stall info).
//
// Each "avg" is the percentage of time stalled, averaged over 10/60/300
// seconds. "Total" is accumulated microseconds during the interval. The
// MemFull family is the strongest leading indicator of imminent OOM.
type PSI struct {
	Present      bool
	CpuSomeAvg10 float64
	CpuSomeAvg60 float64
	CpuSomeAvg300 float64
	CpuSomeTotalUs int64
	MemSomeAvg10 float64
	MemSomeAvg60 float64
	MemSomeAvg300 float64
	MemSomeTotalUs int64
	MemFullAvg10 float64
	MemFullAvg60 float64
	MemFullAvg300 float64
	MemFullTotalUs int64
	IoSomeAvg10 float64
	IoSomeAvg60 float64
	IoSomeAvg300 float64
	IoSomeTotalUs int64
	IoFullAvg10 float64
	IoFullAvg60 float64
	IoFullAvg300 float64
	IoFullTotalUs int64
}

// PRC is one process line under the PRC (CPU) label.
type PRC struct {
	PID      int
	Cmd      string
	State    string
	Raw      []string // remaining fields, for callers that need them
}

// PRM is one process line under the PRM (memory) label.
//
// Field positions after the common header and after (cmd) state (atop 2.x):
//
//	[0] pagesize    [1] vsize       [2] rsize         [3] pgshared
//	[4] pgnonshared [5] pgswapped   [6] pgswapped_tot [7] minorflt
//	[8] majorflt    [9] vexec       [10] vlibs        [11] vdata
//	[12] vstack/tgid (atop 2.10+ uses this slot for tgid in newer fields)
//	[13] is-thread-group-leader ('y' or 'n')
//	[14..] additional accounting fields (varies by atop version)
//
// IsLeader is true when atop reports this row as the thread-group leader. On
// hosts running atop 2.x, multi-threaded processes (JVMs, browsers, etc.)
// emit ONE PRM row per thread; only the leader row's RSize/VSize represent
// the process's true address-space footprint. Non-leader rows duplicate the
// parent's RSize because threads share memory. Filter by IsLeader at display
// time to avoid hundreds of false-duplicate rows. Older atop versions that
// do not emit the flag leave IsLeader == true (lossless fallback).
type PRM struct {
	PID       int
	Cmd       string
	State     string
	PageSize  int64 // bytes
	VSize     int64 // pages of virtual memory
	RSize     int64 // pages of resident memory
	PgShared  int64
	IsLeader  bool
	Raw       []string
}

// GPU is one line under the GPU label.
type GPU struct {
	Index   int
	BusID   string
	Type    string
	BusyPct int64
	MemPct  int64
	MemTotKB int64
	MemUsedKB int64
	Raw     []string
}

// DSK is one line under the DSK / LVM / MDD label.
type DSK struct {
	Name           string
	IOMillis       int64
	Reads          int64
	ReadSectors    int64
	Writes         int64
	WriteSectors   int64
	Discards       int64
	DiscardSectors int64
	InFlight       int64
	AvgQueueDepth  float64
}

// Parse reads atop -PALL output from r and returns one Sample per "SEP"
// marker. The input may contain any number of samples. Parse returns
// io.EOF (wrapped or not) when r is exhausted; callers should treat
// "no error" with an empty result as a parse error.
func Parse(r io.Reader) ([]*Sample, error) {
	sc := bufio.NewScanner(r)
	// atop lines are short — but a process command line can be long.
	// Cap at 1 MiB to be safe against pathological cases.
	sc.Buffer(make([]byte, 0, 64*1024), 1024*1024)

	var samples []*Sample
	cur := newSample()
	resetPending := false

	for sc.Scan() {
		line := strings.TrimRight(sc.Text(), "\r\n")
		if line == "" {
			continue
		}
		if line == "RESET" {
			resetPending = true
			continue
		}
		if line == "SEP" {
			if cur.hasAny() {
				cur.Reset = resetPending
				resetPending = false
				samples = append(samples, cur)
			}
			cur = newSample()
			continue
		}
		if err := cur.absorb(line); err != nil {
			return samples, fmt.Errorf("atop: %w (line: %q)", err, line)
		}
	}
	if err := sc.Err(); err != nil {
		return samples, err
	}
	// Flush a trailing sample without final SEP (atop -P emits SEP after each
	// sample including the last, but we are forgiving for fixtures and for
	// truncated streams).
	if cur.hasAny() {
		cur.Reset = resetPending
		samples = append(samples, cur)
	}
	if len(samples) == 0 {
		return nil, errors.New("atop: no samples found")
	}
	return samples, nil
}

func newSample() *Sample {
	return &Sample{Other: map[string][]string{}}
}

func (s *Sample) hasAny() bool {
	return s.MEM != nil || s.SWP != nil || s.CPU != nil || s.CPL != nil ||
		s.PSI != nil || len(s.PRC) > 0 || len(s.PRM) > 0 ||
		len(s.GPU) > 0 || len(s.DSK) > 0 || len(s.Other) > 0
}

// absorb decodes one parseable line into s.
func (s *Sample) absorb(line string) error {
	label, host, epoch, date, tm, interval, rest, err := splitHeader(line)
	if err != nil {
		return err
	}
	if s.Host == "" {
		s.Host, s.Epoch, s.Date, s.Time, s.Interval = host, epoch, date, tm, interval
	}

	switch label {
	case "MEM":
		m, err := parseMEM(rest)
		if err != nil {
			return err
		}
		s.MEM = m
	case "SWP":
		w, err := parseSWP(rest)
		if err != nil {
			return err
		}
		s.SWP = w
	case "CPU":
		c, err := parseCPU(rest)
		if err != nil {
			return err
		}
		s.CPU = c
	case "CPL":
		c, err := parseCPL(rest)
		if err != nil {
			return err
		}
		s.CPL = c
	case "PSI":
		p, err := parsePSI(rest)
		if err != nil {
			return err
		}
		s.PSI = p
	case "PRC":
		p, err := parsePRC(rest)
		if err != nil {
			return err
		}
		s.PRC = append(s.PRC, *p)
	case "PRM":
		p, err := parsePRM(rest)
		if err != nil {
			return err
		}
		s.PRM = append(s.PRM, *p)
	case "GPU":
		g, err := parseGPU(rest)
		if err != nil {
			return err
		}
		s.GPU = append(s.GPU, *g)
	case "DSK", "LVM", "MDD":
		d, err := parseDSK(rest)
		if err != nil {
			return err
		}
		s.DSK = append(s.DSK, *d)
	default:
		s.Other[label] = append(s.Other[label], rest)
	}
	return nil
}

// splitHeader pulls the six common fields off the front of a line, leaving the
// label-specific tail in rest. It is fast (no regex) and tolerant of multiple
// spaces between fields.
func splitHeader(line string) (label, host string, epoch int64, date, tm string, interval int, rest string, err error) {
	parts := strings.SplitN(line, " ", 7)
	// Re-parse without empty fields (atop uses single-space separators but
	// pad fields to width sometimes).
	parts = nonEmpty(parts)
	if len(parts) < 7 {
		// Compact form: maybe label + 5 + payload but atop spec is 6
		// header fields + payload, so anything shorter is malformed.
		err = fmt.Errorf("short header: only %d fields", len(parts))
		return
	}
	label = parts[0]
	host = parts[1]
	if epoch, err = strconv.ParseInt(parts[2], 10, 64); err != nil {
		err = fmt.Errorf("epoch: %w", err)
		return
	}
	date = parts[3]
	tm = parts[4]
	if interval, err = strconv.Atoi(parts[5]); err != nil {
		err = fmt.Errorf("interval: %w", err)
		return
	}
	rest = parts[6]
	return
}

func nonEmpty(in []string) []string {
	out := in[:0]
	for _, s := range in {
		if s != "" {
			out = append(out, s)
		}
	}
	return out
}

func splitFields(s string) []string {
	return strings.Fields(s)
}

// extractCmd takes the payload of a process line whose first token is the PID
// and returns (pid, cmd, state, remaining-fields). It handles both the default
// "(cmd with spaces)" form and the -Z form where atop replaces spaces with
// underscores and drops the parens.
func extractCmd(payload string) (pid int, cmd, state string, rest []string, err error) {
	// PID is first token.
	first := strings.IndexByte(payload, ' ')
	if first < 0 {
		err = errors.New("process line: missing PID")
		return
	}
	pid, err = strconv.Atoi(payload[:first])
	if err != nil {
		err = fmt.Errorf("process line: bad PID: %w", err)
		return
	}
	tail := strings.TrimLeft(payload[first+1:], " ")
	if tail == "" {
		err = errors.New("process line: empty after PID")
		return
	}
	if tail[0] == '(' {
		end := strings.LastIndexByte(tail, ')')
		if end < 0 {
			err = errors.New("process line: unterminated cmd parens")
			return
		}
		cmd = tail[1:end]
		tail = strings.TrimLeft(tail[end+1:], " ")
	} else {
		// -Z form: bareword then space.
		sp := strings.IndexByte(tail, ' ')
		if sp < 0 {
			cmd = tail
			tail = ""
		} else {
			cmd = tail[:sp]
			tail = strings.TrimLeft(tail[sp:], " ")
		}
	}
	fields := splitFields(tail)
	if len(fields) == 0 {
		err = errors.New("process line: missing state field")
		return
	}
	state = fields[0]
	rest = fields[1:]
	return
}

// ----- per-label decoders -----

func parseMEM(rest string) (*MEM, error) {
	f := splitFields(rest)
	// Older atop versions emit fewer fields; require at least the canonical
	// "available memory" position (#25 / index 24).
	if len(f) < 25 {
		return nil, fmt.Errorf("MEM: expected >=25 fields, got %d", len(f))
	}
	pi := func(i int) int64 {
		v, _ := strconv.ParseInt(f[i], 10, 64)
		return v
	}
	m := &MEM{
		PageSize: pi(0), PhysPages: pi(1), FreePages: pi(2), CachePages: pi(3),
		BufferPages: pi(4), SlabPages: pi(5), DirtyPages: pi(6), SlabReclaim: pi(7),
		VmwBalloon: pi(8), ShmemPages: pi(9), ShmemRes: pi(10), ShmemSwap: pi(11),
		HugeSizeS: pi(12), HugeTotalS: pi(13), HugeFreeS: pi(14),
		ZfsArcPages: pi(15), KsmSharing: pi(16), KsmShared: pi(17),
		TcpSockPages: pi(18), UdpSockPages: pi(19), PageTables: pi(20),
		HugeSizeL: pi(21), HugeTotalL: pi(22), HugeFreeL: pi(23),
		AvailPages: pi(24),
	}
	if len(f) > 25 {
		m.AnonThp = pi(25)
	}
	return m, nil
}

func parseSWP(rest string) (*SWP, error) {
	f := splitFields(rest)
	if len(f) < 6 {
		return nil, fmt.Errorf("SWP: expected >=6 fields, got %d", len(f))
	}
	pi := func(i int) int64 {
		if i >= len(f) {
			return 0
		}
		v, _ := strconv.ParseInt(f[i], 10, 64)
		return v
	}
	return &SWP{
		PageSize: pi(0), SwapPages: pi(1), SwapFree: pi(2),
		SwapCache: pi(3), CommittedAS: pi(4), CommitLimit: pi(5),
		SwapCache2: pi(6), ZswapDecomp: pi(7), ZswapStored: pi(8),
	}, nil
}

func parseCPU(rest string) (*CPU, error) {
	f := splitFields(rest)
	if len(f) < 11 {
		return nil, fmt.Errorf("CPU: expected >=11 fields, got %d", len(f))
	}
	pi := func(i int) int64 {
		if i >= len(f) {
			return 0
		}
		v, _ := strconv.ParseInt(f[i], 10, 64)
		return v
	}
	return &CPU{
		HertzPerSec: pi(0), NumCPU: pi(1), SysTicks: pi(2), UsrTicks: pi(3),
		NiceTicks: pi(4), IdleTicks: pi(5), WaitTicks: pi(6), IrqTicks: pi(7),
		SoftIrq: pi(8), StealTicks: pi(9), GuestTicks: pi(10),
		FreqMHz: pi(11), FreqPct: pi(12), Instr: pi(13), Cycles: pi(14),
	}, nil
}

func parseCPL(rest string) (*CPL, error) {
	f := splitFields(rest)
	if len(f) < 6 {
		return nil, fmt.Errorf("CPL: expected >=6 fields, got %d", len(f))
	}
	pf := func(i int) float64 {
		v, _ := strconv.ParseFloat(f[i], 64)
		return v
	}
	pi := func(i int) int64 {
		v, _ := strconv.ParseInt(f[i], 10, 64)
		return v
	}
	return &CPL{
		NumCPU: pi(0), Load1: pf(1), Load5: pf(2), Load15: pf(3),
		ContextSwits: pi(4), DeviceIntr: pi(5),
	}, nil
}

func parsePSI(rest string) (*PSI, error) {
	f := splitFields(rest)
	// Field 0 is "n" or "y"; if "n", PSI is not present and the rest may be
	// zeros or absent.
	if len(f) < 1 {
		return nil, errors.New("PSI: empty")
	}
	p := &PSI{Present: f[0] == "y"}
	if !p.Present || len(f) < 21 {
		return p, nil
	}
	pf := func(i int) float64 {
		v, _ := strconv.ParseFloat(f[i], 64)
		return v
	}
	pi := func(i int) int64 {
		v, _ := strconv.ParseInt(f[i], 10, 64)
		return v
	}
	p.CpuSomeAvg10, p.CpuSomeAvg60, p.CpuSomeAvg300 = pf(1), pf(2), pf(3)
	p.CpuSomeTotalUs = pi(4)
	p.MemSomeAvg10, p.MemSomeAvg60, p.MemSomeAvg300 = pf(5), pf(6), pf(7)
	p.MemSomeTotalUs = pi(8)
	p.MemFullAvg10, p.MemFullAvg60, p.MemFullAvg300 = pf(9), pf(10), pf(11)
	p.MemFullTotalUs = pi(12)
	p.IoSomeAvg10, p.IoSomeAvg60, p.IoSomeAvg300 = pf(13), pf(14), pf(15)
	p.IoSomeTotalUs = pi(16)
	p.IoFullAvg10, p.IoFullAvg60, p.IoFullAvg300 = pf(17), pf(18), pf(19)
	p.IoFullTotalUs = pi(20)
	return p, nil
}

func parsePRC(rest string) (*PRC, error) {
	pid, cmd, state, tail, err := extractCmd(rest)
	if err != nil {
		return nil, err
	}
	return &PRC{PID: pid, Cmd: cmd, State: state, Raw: tail}, nil
}

func parsePRM(rest string) (*PRM, error) {
	pid, cmd, state, tail, err := extractCmd(rest)
	if err != nil {
		return nil, err
	}
	// Default IsLeader=true for older atop versions that don't emit the flag —
	// we don't want to silently drop every PRM row on those hosts.
	p := &PRM{PID: pid, Cmd: cmd, State: state, IsLeader: true, Raw: tail}
	if len(tail) >= 1 {
		p.PageSize, _ = strconv.ParseInt(tail[0], 10, 64)
	}
	if len(tail) >= 2 {
		p.VSize, _ = strconv.ParseInt(tail[1], 10, 64)
	}
	if len(tail) >= 3 {
		p.RSize, _ = strconv.ParseInt(tail[2], 10, 64)
	}
	if len(tail) >= 4 {
		p.PgShared, _ = strconv.ParseInt(tail[3], 10, 64)
	}
	// atop 2.x emits a 'y' / 'n' thread-group-leader flag at tail[13].
	if len(tail) >= 14 {
		switch tail[13] {
		case "y":
			p.IsLeader = true
		case "n":
			p.IsLeader = false
		}
	}
	return p, nil
}

func parseGPU(rest string) (*GPU, error) {
	f := splitFields(rest)
	if len(f) < 7 {
		return nil, fmt.Errorf("GPU: expected >=7 fields, got %d", len(f))
	}
	g := &GPU{}
	g.Index, _ = strconv.Atoi(f[0])
	g.BusID = f[1]
	g.Type = f[2]
	g.BusyPct, _ = strconv.ParseInt(f[3], 10, 64)
	g.MemPct, _ = strconv.ParseInt(f[4], 10, 64)
	g.MemTotKB, _ = strconv.ParseInt(f[5], 10, 64)
	g.MemUsedKB, _ = strconv.ParseInt(f[6], 10, 64)
	g.Raw = f[7:]
	return g, nil
}

func parseDSK(rest string) (*DSK, error) {
	f := splitFields(rest)
	if len(f) < 9 {
		return nil, fmt.Errorf("DSK: expected >=9 fields, got %d", len(f))
	}
	d := &DSK{Name: f[0]}
	pi := func(i int) int64 {
		v, _ := strconv.ParseInt(f[i], 10, 64)
		return v
	}
	d.IOMillis = pi(1)
	d.Reads = pi(2)
	d.ReadSectors = pi(3)
	d.Writes = pi(4)
	d.WriteSectors = pi(5)
	d.Discards = pi(6)
	d.DiscardSectors = pi(7)
	d.InFlight = pi(8)
	if len(f) > 9 {
		d.AvgQueueDepth, _ = strconv.ParseFloat(f[9], 64)
	}
	return d, nil
}

// MemUsedRatio returns the fraction of physical memory that is unavailable for
// new work, based on the kernel's MemAvailable counter (which atop reports as
// AvailPages). A value of 1.0 means no memory is available; 0.0 means all of
// it is. This is the canonical signal the daemon uses for OOM imminence.
func (m *MEM) MemUsedRatio() float64 {
	if m == nil || m.PhysPages <= 0 {
		return 0
	}
	if m.AvailPages < 0 {
		return 0
	}
	used := m.PhysPages - m.AvailPages
	if used < 0 {
		used = 0
	}
	return float64(used) / float64(m.PhysPages)
}

// SwapUsedRatio returns the fraction of swap that is in use. 0 if no swap.
func (s *SWP) SwapUsedRatio() float64 {
	if s == nil || s.SwapPages <= 0 {
		return 0
	}
	used := s.SwapPages - s.SwapFree
	if used < 0 {
		used = 0
	}
	return float64(used) / float64(s.SwapPages)
}
