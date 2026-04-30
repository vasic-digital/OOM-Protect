// Package monitor contains the daemon's main loop, threshold engine, and the
// debouncer that decides when to write a report.
//
// The threshold engine is intentionally pure: given a Sample and a Thresholds
// struct, it returns a Severity and the list of triggers. No time, no I/O, no
// state — easy to test exhaustively.
package monitor

import (
	"fmt"

	"github.com/milos85vasic/oom-protect/oom-watch/internal/atop"
	"github.com/milos85vasic/oom-protect/oom-watch/internal/config"
)

// Severity is the level of concern raised by a sample. Higher = worse.
type Severity int

const (
	SevNone Severity = iota
	SevNotice
	SevWarn
	SevCritical
)

func (s Severity) String() string {
	switch s {
	case SevNone:
		return "OK"
	case SevNotice:
		return "NOTICE"
	case SevWarn:
		return "WARN"
	case SevCritical:
		return "CRITICAL"
	default:
		return fmt.Sprintf("Severity(%d)", int(s))
	}
}

// Trigger is one threshold breach.
type Trigger struct {
	Metric   string   // e.g. "memory_used_ratio"
	Value    float64  // observed value
	Limit    float64  // configured threshold
	Severity Severity // severity this breach implies
	Note     string   // human-readable detail
}

// Verdict is the result of evaluating one sample.
type Verdict struct {
	Severity Severity
	Triggers []Trigger
}

// Evaluate returns a Verdict for the given sample under the given thresholds.
// It is pure and goroutine-safe.
func Evaluate(s *atop.Sample, t config.Thresholds) Verdict {
	v := Verdict{Severity: SevNone}
	if s == nil {
		return v
	}

	// Memory used ratio (the single most important signal).
	if s.MEM != nil {
		r := s.MEM.MemUsedRatio()
		switch {
		case r >= t.MemoryUsedRatioCritical:
			v.add(Trigger{"memory_used_ratio", r, t.MemoryUsedRatioCritical,
				SevCritical, "available memory critically low"})
		case r >= t.MemoryUsedRatioWarn:
			v.add(Trigger{"memory_used_ratio", r, t.MemoryUsedRatioWarn,
				SevWarn, "available memory low"})
		case r >= t.MemoryUsedRatioNotice:
			v.add(Trigger{"memory_used_ratio", r, t.MemoryUsedRatioNotice,
				SevNotice, "memory consumption rising"})
		}
	}

	// Swap used ratio.
	if s.SWP != nil {
		r := s.SWP.SwapUsedRatio()
		switch {
		case r >= t.SwapUsedRatioCritical:
			v.add(Trigger{"swap_used_ratio", r, t.SwapUsedRatioCritical,
				SevCritical, "swap nearly exhausted"})
		case r >= t.SwapUsedRatioWarn:
			v.add(Trigger{"swap_used_ratio", r, t.SwapUsedRatioWarn,
				SevWarn, "swap utilisation high"})
		}
	}

	// PSI: memory.full avg10 is the strongest leading indicator. It measures
	// the percentage of time ALL non-idle tasks were stalled on memory in
	// the last 10s. High values mean the system is thrashing.
	if s.PSI != nil && s.PSI.Present {
		switch {
		case s.PSI.MemFullAvg10 >= t.PSIMemFullAvg10Critical:
			v.add(Trigger{"psi_mem_full_avg10", s.PSI.MemFullAvg10,
				t.PSIMemFullAvg10Critical, SevCritical,
				"memory pressure: all tasks stalled significant fraction of last 10s"})
		case s.PSI.MemFullAvg10 >= t.PSIMemFullAvg10Warn:
			v.add(Trigger{"psi_mem_full_avg10", s.PSI.MemFullAvg10,
				t.PSIMemFullAvg10Warn, SevWarn,
				"memory pressure: tasks fully stalling on memory"})
		case s.PSI.MemSomeAvg10 >= t.PSIMemSomeAvg10Warn:
			v.add(Trigger{"psi_mem_some_avg10", s.PSI.MemSomeAvg10,
				t.PSIMemSomeAvg10Warn, SevWarn,
				"memory pressure: some tasks stalling on memory"})
		}
	}

	// Load average per CPU.
	if s.CPL != nil && s.CPL.NumCPU > 0 {
		perCPU := s.CPL.Load1 / float64(s.CPL.NumCPU)
		switch {
		case perCPU >= t.LoadPerCPUCritical:
			v.add(Trigger{"load_per_cpu", perCPU, t.LoadPerCPUCritical,
				SevCritical, "CPU load far exceeds physical capacity"})
		case perCPU >= t.LoadPerCPUWarn:
			v.add(Trigger{"load_per_cpu", perCPU, t.LoadPerCPUWarn,
				SevWarn, "CPU load above sustainable level"})
		}
	}

	return v
}

func (v *Verdict) add(t Trigger) {
	v.Triggers = append(v.Triggers, t)
	if t.Severity > v.Severity {
		v.Severity = t.Severity
	}
}
