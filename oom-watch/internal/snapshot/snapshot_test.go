package snapshot

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/milos85vasic/oom-protect/oom-watch/internal/atop"
	"github.com/milos85vasic/oom-protect/oom-watch/internal/monitor"
)

// TestCapture_FakeProc: build a fake /proc tree, point Options at it, and
// confirm the snapshot contains the EXACT bytes we wrote. Anti-bluff: a
// snapshot that returned empty strings would fail this test loudly.
func TestCapture_FakeProc(t *testing.T) {
	t.Parallel()
	root := t.TempDir()

	must := func(rel, content string) {
		path := filepath.Join(root, rel)
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
	}

	must("meminfo", "MemTotal: 16000 kB\nMemAvailable: 1500 kB\n")
	must("loadavg", "12.34 8.90 4.56 2/1234 99999\n")
	must("pressure/memory", "some avg10=45.20 avg60=38.10 avg300=18.50 total=4520000\n")
	must("pressure/cpu", "some avg10=12.50 avg60=8.30 avg300=3.10 total=1250000\n")
	must("pressure/io", "some avg10=5.20 avg60=3.10 avg300=1.50 total=520000\n")

	// Cgroup dir
	cgRoot := t.TempDir()
	uid := 1000
	cgDir := filepath.Join(cgRoot, "user.slice", "user-1000.slice")
	must2 := func(rel, content string) {
		path := filepath.Join(cgDir, rel)
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	must2("memory.current", "42949672960\n")
	must2("memory.max", "60129542144\n")

	sample := &atop.Sample{
		MEM: &atop.MEM{PhysPages: 4_000_000, AvailPages: 100_000},
		PRM: []atop.PRM{
			{PID: 1, Cmd: "small", RSize: 100},
			{PID: 2, Cmd: "biggest", RSize: 50_000},
			{PID: 3, Cmd: "medium", RSize: 10_000},
		},
		PRC: []atop.PRC{{PID: 2, Cmd: "biggest", State: "R"}},
	}
	v := monitor.Verdict{Severity: monitor.SevCritical}

	snap := Capture(context.Background(), v, sample, Options{
		ProcRoot:    root,
		CgroupRoot:  cgRoot,
		UID:         uid,
		SkipJournal: true,
		TopN:        3,
	})

	if !strings.Contains(snap.MemInfo, "MemAvailable: 1500 kB") {
		t.Errorf("MemInfo missing expected content: %q", snap.MemInfo)
	}
	if !strings.Contains(snap.PressureMemory, "avg10=45.20") {
		t.Errorf("PressureMemory missing expected content: %q", snap.PressureMemory)
	}
	if !strings.Contains(snap.UserSliceCgroup, "memory.current") ||
		!strings.Contains(snap.UserSliceCgroup, "42949672960") {
		t.Errorf("UserSliceCgroup missing expected content: %q", snap.UserSliceCgroup)
	}

	// Top by memory must be sorted desc by RSize.
	if len(snap.TopByMemory) != 3 {
		t.Fatalf("expected 3 top mem procs, got %d", len(snap.TopByMemory))
	}
	if snap.TopByMemory[0].PID != 2 || snap.TopByMemory[0].Cmd != "biggest" {
		t.Errorf("expected biggest first, got %+v", snap.TopByMemory[0])
	}
	if snap.TopByMemory[1].PID != 3 {
		t.Errorf("expected medium second, got %+v", snap.TopByMemory[1])
	}
}

// TestCapture_PartialFailure: missing /proc/pressure should not abort the
// snapshot — the daemon must still produce a report covering whatever it
// could collect, and document the missing piece in Errors.
func TestCapture_PartialFailure(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, "loadavg"), []byte("0 0 0 0/0 0\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	// /proc/meminfo and /proc/pressure intentionally absent.
	snap := Capture(context.Background(), monitor.Verdict{}, &atop.Sample{},
		Options{ProcRoot: root, SkipJournal: true})
	if snap == nil {
		t.Fatal("snapshot is nil — must not abort on partial failure")
	}
	if snap.LoadAvg == "" {
		t.Error("LoadAvg should be populated even if siblings are missing")
	}
	if len(snap.Errors) == 0 {
		t.Error("expected Errors to record the missing /proc files")
	}
}
