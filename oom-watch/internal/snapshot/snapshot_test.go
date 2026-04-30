package snapshot

import (
	"context"
	"fmt"
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
			{PID: 1, Cmd: "small", RSize: 100, IsLeader: true},
			{PID: 2, Cmd: "biggest", RSize: 50_000, IsLeader: true},
			{PID: 3, Cmd: "medium", RSize: 10_000, IsLeader: true},
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

// TestTopProcesses_FiltersNonLeaders: atop 2.x emits one PRM row per kernel
// thread; non-leader threads inherit the parent's RSize and would otherwise
// drown out every real process in the top-N. Anti-bluff: this test was added
// after running real atop 2.12 produced a top-mem table where the same
// 8-GiB Java process appeared 11 times; the production code change (filter
// by PRM.IsLeader) was made first, then this test locks the contract in.
func TestTopProcesses_FiltersNonLeaders(t *testing.T) {
	t.Parallel()
	sample := &atop.Sample{
		PRM: []atop.PRM{
			{PID: 9100, Cmd: "jvm-leader", RSize: 7_000_000, IsLeader: true},
			{PID: 9101, Cmd: "jvm-thread-A", RSize: 7_000_000, IsLeader: false},
			{PID: 9102, Cmd: "jvm-thread-B", RSize: 7_000_000, IsLeader: false},
			{PID: 9103, Cmd: "jvm-thread-C", RSize: 7_000_000, IsLeader: false},
			{PID: 4242, Cmd: "browser", RSize: 1_500_000, IsLeader: true},
			{PID: 100, Cmd: "old-atop-no-flag", RSize: 500_000, IsLeader: true},
		},
	}
	mem, _ := topProcesses(sample, 20)
	if len(mem) != 3 {
		t.Fatalf("expected exactly 3 leaders in top-mem (9100, 4242, 100); got %d: %+v", len(mem), mem)
	}
	if mem[0].PID != 9100 || mem[0].Cmd != "jvm-leader" {
		t.Errorf("rank-1 should be jvm-leader (9100), got %+v", mem[0])
	}
	if mem[1].PID != 4242 || mem[1].Cmd != "browser" {
		t.Errorf("rank-2 should be browser (4242), got %+v", mem[1])
	}
	for _, m := range mem {
		if m.PID == 9101 || m.PID == 9102 || m.PID == 9103 {
			t.Errorf("non-leader PID %d leaked into top list: %+v", m.PID, m)
		}
	}
}

// TestEnrichProcess: builds a fake /proc/<pid>/ tree containing realistic
// cmdline (NUL-separated), status (PPid, Uid, VmRSS, VmHWM, VmPeak), cgroup,
// oom_score, oom_score_adj. Anti-bluff: every assertion targets a specific
// field that would silently zero out under a parser regression.
func TestEnrichProcess(t *testing.T) {
	t.Parallel()
	root := t.TempDir()

	// Child process — the suspect.
	mkProc(t, root, 5678, map[string]string{
		"cmdline":       "/usr/local/bin/node\x00--max-old-space-size=8192\x00/srv/app/server.js\x00--port=3000\x00",
		"status":        "Name:\tnode\nState:\tR (running)\nPPid:\t1234\nUid:\t1000\t1000\t1000\t1000\nVmPeak:\t12345 kB\nVmHWM:\t10000 kB\nVmRSS:\t9876 kB\n",
		"cgroup":        "0::/user.slice/user-1000.slice/user@1000.service/app.slice/node.scope\n",
		"oom_score":     "234\n",
		"oom_score_adj": "0\n",
	})
	// Parent — the script that started it.
	mkProc(t, root, 1234, map[string]string{
		"cmdline": "/bin/bash\x00/home/me/scripts/start-server.sh\x00--env=prod\x00",
	})

	snap := &Snapshot{}
	d := snap.enrichProcess(5678, root)

	if d.PID != 5678 {
		t.Errorf("PID = %d, want 5678", d.PID)
	}
	if len(d.Cmdline) != 4 {
		t.Fatalf("Cmdline len = %d, want 4 (full argv); got %v", len(d.Cmdline), d.Cmdline)
	}
	if d.Cmdline[0] != "/usr/local/bin/node" || d.Cmdline[2] != "/srv/app/server.js" {
		t.Errorf("Cmdline = %q, want full /usr/local/bin/node argv", d.Cmdline)
	}
	if d.PPID != 1234 {
		t.Errorf("PPID = %d, want 1234", d.PPID)
	}
	if d.UID != 1000 {
		t.Errorf("UID = %d, want 1000", d.UID)
	}
	if d.State != "R" {
		t.Errorf("State = %q, want R", d.State)
	}
	if d.VmRSSKB != 9876 {
		t.Errorf("VmRSSKB = %d, want 9876", d.VmRSSKB)
	}
	if d.VmHWMKB != 10000 {
		t.Errorf("VmHWMKB = %d, want 10000", d.VmHWMKB)
	}
	if d.VmPeakKB != 12345 {
		t.Errorf("VmPeakKB = %d, want 12345", d.VmPeakKB)
	}
	if d.OomScore != 234 {
		t.Errorf("OomScore = %d, want 234", d.OomScore)
	}
	if d.OomScoreAdj != 0 {
		t.Errorf("OomScoreAdj = %d, want 0", d.OomScoreAdj)
	}
	if d.Cgroup != "0::/user.slice/user-1000.slice/user@1000.service/app.slice/node.scope" {
		t.Errorf("Cgroup = %q (unexpected)", d.Cgroup)
	}
	if d.ParentCmd == "" || !strings.Contains(d.ParentCmd, "start-server.sh") {
		t.Errorf("ParentCmd = %q, want substring 'start-server.sh'", d.ParentCmd)
	}
}

// TestEnrichProcess_MissingPid: a process that exits between top-N
// selection and detail capture must produce a benign placeholder, not
// crash the snapshot.
func TestEnrichProcess_MissingPid(t *testing.T) {
	t.Parallel()
	root := t.TempDir() // no /proc/<pid>/ entries
	snap := &Snapshot{}
	d := snap.enrichProcess(99999, root)
	if d.PID != 0 {
		t.Errorf("missing pid: expected PID=0, got %d", d.PID)
	}
	if d.Source != "<missing>" {
		t.Errorf("missing pid: expected Source=<missing>, got %q", d.Source)
	}
	if len(snap.Errors) == 0 {
		t.Error("expected snap.Errors to record the missing pid")
	}
}

// TestCapture_EnrichesTopByMemory: end-to-end through Capture, asserting
// the new TopByMemoryDetail is populated with the right number of entries
// and contains the cmdline of a known fake PID. Anti-bluff: a regression
// that disabled enrichment would leave TopByMemoryDetail empty.
func TestCapture_EnrichesTopByMemory(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, "loadavg"), []byte("0 0 0 0/0 0\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	mkProc(t, root, 7777, map[string]string{
		"cmdline": "/opt/big-app\x00--config=/etc/big-app.yaml\x00",
		"status":  "Name:\tbig-app\nState:\tS (sleeping)\nPPid:\t1\nUid:\t0\t0\t0\t0\nVmRSS:\t12000 kB\n",
	})

	sample := &atop.Sample{
		PRM: []atop.PRM{
			{PID: 7777, Cmd: "big-app", RSize: 3000, IsLeader: true},
		},
	}
	snap := Capture(context.Background(), monitor.Verdict{}, sample, Options{
		ProcRoot:    root,
		SkipJournal: true,
		SkipDmesg:   true,
		TopN:        5,
		EnrichTopN:  5,
	})
	if len(snap.TopByMemoryDetail) != 1 {
		t.Fatalf("expected 1 enriched detail (PID 7777), got %d", len(snap.TopByMemoryDetail))
	}
	d := snap.TopByMemoryDetail[0]
	if d.PID != 7777 || len(d.Cmdline) != 2 || d.Cmdline[1] != "--config=/etc/big-app.yaml" {
		t.Errorf("enriched detail unexpected: %+v", d)
	}
	if d.VmRSSKB != 12000 {
		t.Errorf("VmRSSKB = %d, want 12000 (from fake status)", d.VmRSSKB)
	}
}

// mkProc writes a fake /proc/<pid>/ tree with the given file contents.
// Used by TestEnrichProcess and TestCapture_EnrichesTopByMemory.
func mkProc(t *testing.T, root string, pid int, files map[string]string) {
	t.Helper()
	dir := filepath.Join(root, fmt.Sprintf("%d", pid))
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	for name, content := range files {
		if err := os.WriteFile(filepath.Join(dir, name), []byte(content), 0o644); err != nil {
			t.Fatalf("write %s: %v", name, err)
		}
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
