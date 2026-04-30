package report

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/milos85vasic/oom-protect/oom-watch/internal/atop"
	"github.com/milos85vasic/oom-protect/oom-watch/internal/monitor"
	"github.com/milos85vasic/oom-protect/oom-watch/internal/snapshot"
)

// TestWriteMarkdown_FullReport: the report must contain the severity, the
// host, the trigger, the top process, and the proc/meminfo we passed in.
// Anti-bluff: each substring is something that could only appear if the
// corresponding section was actually rendered.
func TestWriteMarkdown_FullReport(t *testing.T) {
	t.Parallel()
	dir := t.TempDir()
	snap := &snapshot.Snapshot{
		Time:     time.Date(2026, 4, 30, 14, 36, 35, 0, time.UTC),
		Hostname: "nezha",
		Verdict: monitor.Verdict{
			Severity: monitor.SevCritical,
			Triggers: []monitor.Trigger{
				{Metric: "memory_used_ratio", Value: 0.97, Limit: 0.95,
					Severity: monitor.SevCritical, Note: "available memory critically low"},
			},
		},
		Sample: &atop.Sample{
			MEM: &atop.MEM{PageSize: 4096, PhysPages: 16_000_000, AvailPages: 250_000},
			SWP: &atop.SWP{SwapPages: 4_194_304, SwapFree: 800_000},
			PSI: &atop.PSI{Present: true, MemFullAvg10: 45.2},
			PRM: []atop.PRM{{PID: 5678, Cmd: "chromium", RSize: 7_000_000, PageSize: 4096}},
		},
		TopByMemory: []snapshot.ProcessLine{
			{PID: 5678, Cmd: "chromium", RSize: 7_000_000, Source: "atop-PRM"},
		},
		MemInfo:        "MemTotal:       65625040 kB\nMemAvailable:    1024000 kB\n",
		PressureMemory: "some avg10=45.20\nfull avg10=45.20\n",
	}

	path, err := WriteMarkdown(snap, dir)
	if err != nil {
		t.Fatalf("WriteMarkdown: %v", err)
	}
	if _, err := os.Stat(path); err != nil {
		t.Fatalf("report file does not exist: %v", err)
	}
	if filepath.Dir(path) != dir {
		// allow Abs() conversion to /tmp/.../, the basename should be in dir
		if !strings.HasSuffix(filepath.Dir(path), strings.TrimPrefix(dir, "/")) {
			t.Errorf("report not in dir; got %s, want under %s", path, dir)
		}
	}
	body, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	str := string(body)
	for _, want := range []string{
		"CRITICAL",
		"nezha",
		"memory_used_ratio",
		"chromium",
		"MemAvailable:    1024000 kB",
		"avg10=45.20",
		"PSI memory.full",
		"## Top processes by resident memory",
	} {
		if !strings.Contains(str, want) {
			t.Errorf("report missing expected substring %q\n--- report follows ---\n%s", want, str)
		}
	}
	// Filename encodes severity (critical) and timestamp.
	base := filepath.Base(path)
	if !strings.Contains(base, "critical") {
		t.Errorf("filename %q should include severity", base)
	}
	if !strings.Contains(base, "2026-04-30") {
		t.Errorf("filename %q should include date", base)
	}
}

// TestWriteMarkdown_AtomicRename: a partial file should never appear in dir
// during the write. We can't easily inject a failure mid-write here, but we
// CAN assert no leftover .tmp file exists after a successful write.
func TestWriteMarkdown_NoLeftoverTemp(t *testing.T) {
	t.Parallel()
	dir := t.TempDir()
	snap := &snapshot.Snapshot{
		Time:     time.Now().UTC(),
		Hostname: "h",
		Verdict:  monitor.Verdict{Severity: monitor.SevNotice},
	}
	if _, err := WriteMarkdown(snap, dir); err != nil {
		t.Fatal(err)
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	for _, e := range entries {
		if strings.HasPrefix(e.Name(), ".oom-watch-") {
			t.Errorf("leftover temp file: %s", e.Name())
		}
	}
}

// TestWriteMarkdown_NilSnapshotFailsLoudly: anti-bluff — a function that
// silently returns "" path and nil err on bad input is forbidden.
func TestWriteMarkdown_NilSnapshotFailsLoudly(t *testing.T) {
	t.Parallel()
	_, err := WriteMarkdown(nil, t.TempDir())
	if err == nil {
		t.Fatal("expected error on nil snapshot, got nil")
	}
}
