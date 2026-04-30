package monitor

import (
	"testing"

	"github.com/milos85vasic/oom-protect/oom-watch/internal/atop"
	"github.com/milos85vasic/oom-protect/oom-watch/internal/config"
)

// TestEvaluate_Spectrum walks the severity ladder for memory and confirms
// every level fires for the right input and stays quiet for inputs below it.
// Anti-bluff: a parser regression that always returns 0 would fail here.
func TestEvaluate_Spectrum(t *testing.T) {
	t.Parallel()
	th := config.Defaults().Thresholds

	mkSample := func(usedRatio float64) *atop.Sample {
		// Avail = (1 - usedRatio) * Phys
		const phys = int64(1_000_000)
		avail := int64(float64(phys) * (1 - usedRatio))
		return &atop.Sample{MEM: &atop.MEM{PhysPages: phys, AvailPages: avail}}
	}

	cases := []struct {
		name      string
		ratio     float64
		want      Severity
		wantFires bool
	}{
		{"clean", 0.50, SevNone, false},
		{"notice", 0.85, SevNotice, true},
		{"warn", 0.92, SevWarn, true},
		{"critical", 0.97, SevCritical, true},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			v := Evaluate(mkSample(c.ratio), th)
			if v.Severity != c.want {
				t.Errorf("severity = %v, want %v", v.Severity, c.want)
			}
			if c.wantFires && len(v.Triggers) == 0 {
				t.Error("expected at least one trigger, got none")
			}
			if !c.wantFires && len(v.Triggers) != 0 {
				t.Errorf("expected no triggers, got %d: %+v", len(v.Triggers), v.Triggers)
			}
		})
	}
}

// TestEvaluate_PSIMemFullCritical proves PSI alone can drive critical even
// when MemAvailable still looks OK — kernel may report avail high while
// thrashing if reclaim is "succeeding" but everything is stalled.
func TestEvaluate_PSIMemFullCritical(t *testing.T) {
	t.Parallel()
	th := config.Defaults().Thresholds
	s := &atop.Sample{
		MEM: &atop.MEM{PhysPages: 1000, AvailPages: 500}, // 50% used — clean
		PSI: &atop.PSI{Present: true, MemFullAvg10: 35.0},
	}
	v := Evaluate(s, th)
	if v.Severity != SevCritical {
		t.Fatalf("severity = %v, want CRITICAL", v.Severity)
	}
	found := false
	for _, tr := range v.Triggers {
		if tr.Metric == "psi_mem_full_avg10" && tr.Severity == SevCritical {
			found = true
		}
	}
	if !found {
		t.Errorf("expected psi_mem_full_avg10 critical trigger, got %+v", v.Triggers)
	}
}

// TestEvaluate_NilSampleSafe — defensive. The daemon should never panic on a
// missing or partial sample.
func TestEvaluate_NilSampleSafe(t *testing.T) {
	t.Parallel()
	v := Evaluate(nil, config.Defaults().Thresholds)
	if v.Severity != SevNone || len(v.Triggers) != 0 {
		t.Errorf("nil sample produced verdict %+v", v)
	}
}

// TestSeverityString — used by report writers; lock the strings down so
// reports stay grep-friendly.
func TestSeverityString(t *testing.T) {
	t.Parallel()
	cases := map[Severity]string{
		SevNone: "OK", SevNotice: "NOTICE", SevWarn: "WARN", SevCritical: "CRITICAL",
	}
	for s, want := range cases {
		if got := s.String(); got != want {
			t.Errorf("(%d).String() = %q, want %q", int(s), got, want)
		}
	}
}
