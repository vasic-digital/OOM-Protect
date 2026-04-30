package atop

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// writeFakeAtop creates a `atop` shell script in dir that emits the given
// payload to stdout and exits 0. Callers prepend dir to $PATH.
func writeFakeAtop(t *testing.T, dir, payload string) {
	t.Helper()
	script := "#!/bin/sh\ncat <<'__EOF__'\n" + payload + "\n__EOF__\n"
	path := filepath.Join(dir, "atop")
	if err := os.WriteFile(path, []byte(script), 0o755); err != nil {
		t.Fatalf("write fake atop: %v", err)
	}
}

// TestRunner_SampleHappyPath proves the runner spawns the atop binary it
// finds on PATH, captures stdout, and decodes the latest sample. Anti-bluff:
// the test asserts a specific field from the fixture (not just "no error").
func TestRunner_SampleHappyPath(t *testing.T) {
	dir := t.TempDir()
	payload, err := os.ReadFile(filepath.Join("testdata", "sample.txt"))
	if err != nil {
		t.Fatalf("read fixture: %v", err)
	}
	writeFakeAtop(t, dir, string(payload))
	t.Setenv("PATH", dir+":"+os.Getenv("PATH"))

	r := &Runner{Interval: time.Second}
	s, err := r.Sample(context.Background())
	if err != nil {
		t.Fatalf("Sample: %v", err)
	}
	// The runner returns the LATEST (post-boot) sample.
	if s.MEM == nil || s.MEM.AvailPages != 250000 {
		t.Fatalf("expected latest sample MEM.AvailPages=250000, got %+v", s.MEM)
	}
	if s.PSI == nil || s.PSI.MemFullAvg10 != 45.20 {
		t.Fatalf("expected PSI.MemFullAvg10=45.20, got %+v", s.PSI)
	}
}

// TestRunner_AtopMissing fails when the binary is absent. Anti-bluff: the
// daemon must surface this loudly, not silently emit zero samples.
func TestRunner_AtopMissing(t *testing.T) {
	t.Setenv("PATH", t.TempDir()) // empty PATH dir
	r := &Runner{}
	_, err := r.Sample(context.Background())
	if err == nil {
		t.Fatal("expected error when atop is missing, got nil")
	}
	if !errors.Is(err, ErrAtopMissing) {
		t.Errorf("error = %v, want ErrAtopMissing", err)
	}
}

// TestRunner_AtopExitsNonZero verifies we surface exit codes rather than
// returning a degenerate sample.
func TestRunner_AtopExitsNonZero(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "atop")
	if err := os.WriteFile(path, []byte("#!/bin/sh\necho 'broken' >&2\nexit 7\n"), 0o755); err != nil {
		t.Fatalf("write: %v", err)
	}
	t.Setenv("PATH", dir+":"+os.Getenv("PATH"))
	r := &Runner{Interval: time.Second}
	_, err := r.Sample(context.Background())
	if err == nil {
		t.Fatal("expected error on nonzero exit")
	}
}
