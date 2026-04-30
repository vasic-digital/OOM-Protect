package atop

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestParse_RealFixture exercises Parse against a real-shape atop -PALL
// fixture. Per Constitution Article I, this test asserts specific values
// derived from the fixture; if the parser silently corrupts a field the
// test fails with a clear diagnostic. No "len > 0" trivialities.
func TestParse_RealFixture(t *testing.T) {
	t.Parallel()
	data, err := os.ReadFile(filepath.Join("testdata", "sample.txt"))
	if err != nil {
		t.Fatalf("read fixture: %v", err)
	}
	samples, err := Parse(strings.NewReader(string(data)))
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	if len(samples) != 2 {
		t.Fatalf("expected exactly 2 samples (boot + interval), got %d", len(samples))
	}

	// Sample 1: should be the boot/RESET sample.
	s1 := samples[0]
	if !s1.Reset {
		t.Errorf("sample[0].Reset = false, want true (RESET marker should propagate)")
	}
	if s1.Host != "nezha" {
		t.Errorf("host = %q, want %q", s1.Host, "nezha")
	}
	if s1.MEM == nil {
		t.Fatal("sample[0].MEM is nil")
	}
	// MemAvailable in fixture sample 1 = 4500000 pages of 4096 bytes ≈ 17 GiB
	// out of 16M pages physical (≈ 64 GiB).
	if s1.MEM.PhysPages != 16000000 {
		t.Errorf("MEM.PhysPages = %d, want 16000000", s1.MEM.PhysPages)
	}
	if s1.MEM.AvailPages != 4500000 {
		t.Errorf("MEM.AvailPages = %d, want 4500000", s1.MEM.AvailPages)
	}
	if got := s1.MEM.MemUsedRatio(); got < 0.71 || got > 0.72 {
		t.Errorf("MEM.MemUsedRatio() = %.4f, want ~0.7188", got)
	}

	// Sample 2: critical-pressure case. Avail collapses to 250000 pages (~1G).
	s2 := samples[1]
	if s2.Reset {
		t.Errorf("sample[1].Reset = true, want false")
	}
	if s2.MEM == nil {
		t.Fatal("sample[1].MEM is nil")
	}
	if s2.MEM.AvailPages != 250000 {
		t.Errorf("MEM.AvailPages = %d, want 250000", s2.MEM.AvailPages)
	}
	if got := s2.MEM.MemUsedRatio(); got < 0.984 || got > 0.985 {
		t.Errorf("MEM.MemUsedRatio() = %.4f, want ~0.9844", got)
	}

	// PSI: in the second sample memory full avg10 jumps from 0.30 to 45.20.
	if s2.PSI == nil || !s2.PSI.Present {
		t.Fatal("sample[1].PSI missing or absent")
	}
	if s2.PSI.MemFullAvg10 != 45.20 {
		t.Errorf("PSI.MemFullAvg10 = %.2f, want 45.20", s2.PSI.MemFullAvg10)
	}
	if s2.PSI.MemSomeAvg10 != 65.30 {
		t.Errorf("PSI.MemSomeAvg10 = %.2f, want 65.30", s2.PSI.MemSomeAvg10)
	}

	// Process command names with spaces must round-trip via the parens form.
	foundChromium := false
	for _, p := range s2.PRM {
		if p.PID == 5678 {
			if p.Cmd != "chromium with spaces" {
				t.Errorf("PRM PID 5678 cmd = %q, want %q", p.Cmd, "chromium with spaces")
			}
			if p.RSize != 7000000 {
				t.Errorf("PRM PID 5678 RSize = %d, want 7000000", p.RSize)
			}
			foundChromium = true
		}
	}
	if !foundChromium {
		t.Error("did not find PRM entry for PID 5678 (chromium with spaces)")
	}

	// Swap pressure also visible: free swap drops from 3.5M pages to 800K.
	if s2.SWP == nil {
		t.Fatal("sample[1].SWP is nil")
	}
	if s2.SWP.SwapFree != 800000 {
		t.Errorf("SWP.SwapFree = %d, want 800000", s2.SWP.SwapFree)
	}
	if got := s2.SWP.SwapUsedRatio(); got < 0.80 || got > 0.81 {
		t.Errorf("SWP.SwapUsedRatio() = %.4f, want ~0.8092", got)
	}

	// Common header fields populated correctly.
	if s1.Epoch != 1714492595 {
		t.Errorf("sample[0].Epoch = %d, want 1714492595", s1.Epoch)
	}
	if s1.Interval != 10 {
		t.Errorf("sample[0].Interval = %d, want 10", s1.Interval)
	}
}

// TestParse_EmptyInput ensures we fail loudly rather than silently returning
// an empty slice. A bluff test would assert len == 0 with err == nil.
func TestParse_EmptyInput(t *testing.T) {
	t.Parallel()
	_, err := Parse(strings.NewReader(""))
	if err == nil {
		t.Fatal("expected error on empty input, got nil")
	}
}

// TestParse_MalformedHeader catches a regression where short lines used to
// silently produce a zero-valued sample.
func TestParse_MalformedHeader(t *testing.T) {
	t.Parallel()
	_, err := Parse(strings.NewReader("MEM bad\nSEP\n"))
	if err == nil {
		t.Fatal("expected error on malformed header, got nil")
	}
	if !strings.Contains(err.Error(), "header") {
		t.Errorf("error %q should mention 'header'", err)
	}
}

// TestParse_ProcessNameWithoutParens covers the -Z form where atop replaces
// spaces with underscores and drops the parens.
func TestParse_ProcessNameWithoutParens(t *testing.T) {
	t.Parallel()
	in := "PRM nezha 1700000000 2024/01/01 00:00:00 10 9999 chromium_helper R 4096 1000 500 100 400 0 0 1 0 0 400 800 0 0\nSEP\n"
	samples, err := Parse(strings.NewReader(in))
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	if len(samples) != 1 || len(samples[0].PRM) != 1 {
		t.Fatalf("got samples=%d prm=%v", len(samples), samples)
	}
	p := samples[0].PRM[0]
	if p.PID != 9999 {
		t.Errorf("pid = %d, want 9999", p.PID)
	}
	if p.Cmd != "chromium_helper" {
		t.Errorf("cmd = %q, want chromium_helper", p.Cmd)
	}
	if p.State != "R" {
		t.Errorf("state = %q, want R", p.State)
	}
}

// TestMemUsedRatio_AntiBluff is a directed mutation check. If MemUsedRatio is
// rewritten to always return 0 (a tempting bug), this test fails.
func TestMemUsedRatio_AntiBluff(t *testing.T) {
	t.Parallel()
	cases := []struct {
		name string
		m    *MEM
		want float64
	}{
		{"nil", nil, 0},
		{"zero phys", &MEM{PhysPages: 0}, 0},
		{"half used", &MEM{PhysPages: 1000, AvailPages: 500}, 0.5},
		{"all used", &MEM{PhysPages: 1000, AvailPages: 0}, 1.0},
		{"none used", &MEM{PhysPages: 1000, AvailPages: 1000}, 0.0},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := c.m.MemUsedRatio()
			if got != c.want {
				t.Errorf("got %f, want %f", got, c.want)
			}
		})
	}
}
