package atop

import (
	"context"
	"errors"
	"fmt"
	"os/exec"
	"strings"
	"time"
)

// Runner spawns the atop binary and returns parsed Samples.
//
// We deliberately do NOT keep a long-running atop subprocess. The daemon's
// risk model is "atop misbehaves and we want to recover cleanly" — so each
// Sample call is a one-shot: `atop -PALL <interval> 2`. We ask atop for two
// samples because the first sample under -P is the boot summary (preceded by
// RESET) and the second is the actual interval sample we want. Asking for
// only "1" returns just the boot summary.
//
// If the binary is missing, Sample returns ErrAtopMissing — the caller is
// expected to surface this as a fatal startup error rather than retry.
type Runner struct {
	Binary   string        // path to atop, default "atop"
	Interval time.Duration // sampling window
	Labels   string        // e.g. "ALL" or "MEM,SWP,CPU,CPL,PSI,PRC,PRM"
	// Z, when true, asks atop to escape spaces in command lines with
	// underscores instead of using parentheses. Cleaner for parsing but
	// loses the original command text.
	Z bool
}

// ErrAtopMissing is returned when the atop binary is not found or not
// executable. The daemon should treat this as fatal at startup.
var ErrAtopMissing = errors.New("atop binary not found in PATH")

// Locate verifies that the runner's atop binary is available and executable.
// It is intended to be called once at daemon startup so we fail loudly rather
// than silently producing zero samples.
func (r *Runner) Locate() error {
	bin := r.Binary
	if bin == "" {
		bin = "atop"
	}
	path, err := exec.LookPath(bin)
	if err != nil {
		return fmt.Errorf("%w: %v", ErrAtopMissing, err)
	}
	r.Binary = path
	return nil
}

// Sample executes one atop sampling and returns the latest Sample (the second
// of the two atop emits). Returns ErrAtopMissing if the binary is gone.
func (r *Runner) Sample(ctx context.Context) (*Sample, error) {
	if err := r.Locate(); err != nil {
		return nil, err
	}
	interval := r.Interval
	if interval <= 0 {
		interval = 1 * time.Second
	}
	labels := r.Labels
	if labels == "" {
		labels = "ALL"
	}
	args := []string{"-P" + labels}
	if r.Z {
		args = append(args, "-Z")
	}
	args = append(args, fmt.Sprintf("%d", int(interval.Seconds())), "2")

	// Bound the subprocess to ~3x the requested interval so a hung atop can't
	// hold us forever. We propagate ctx cancellation too.
	deadline := time.Now().Add(interval*3 + 5*time.Second)
	cctx, cancel := context.WithDeadline(ctx, deadline)
	defer cancel()

	cmd := exec.CommandContext(cctx, r.Binary, args...)
	out, err := cmd.Output()
	if err != nil {
		var ee *exec.ExitError
		if errors.As(err, &ee) {
			return nil, fmt.Errorf("atop exit %d: %s",
				ee.ExitCode(), strings.TrimSpace(string(ee.Stderr)))
		}
		return nil, fmt.Errorf("atop: %w", err)
	}
	samples, err := Parse(strings.NewReader(string(out)))
	if err != nil {
		return nil, err
	}
	// Return the latest sample (the post-boot interval sample).
	return samples[len(samples)-1], nil
}
