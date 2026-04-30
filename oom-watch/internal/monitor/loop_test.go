package monitor

import (
	"context"
	"errors"
	"io"
	"log/slog"
	"sync"
	"testing"
	"time"

	"github.com/milos85vasic/oom-protect/oom-watch/internal/atop"
	"github.com/milos85vasic/oom-protect/oom-watch/internal/config"
)

// fakeSampler returns the i-th element from the queue and stops returning new
// values once exhausted (returns the last). Goroutine-safe.
type fakeSampler struct {
	mu      sync.Mutex
	queue   []*atop.Sample
	calls   int
	failOn  int // index where Sample returns an error (use -1 to disable)
	failErr error
}

func (f *fakeSampler) Sample(_ context.Context) (*atop.Sample, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	i := f.calls
	f.calls++
	if i == f.failOn {
		return nil, f.failErr
	}
	if len(f.queue) == 0 {
		return &atop.Sample{}, nil
	}
	if i >= len(f.queue) {
		i = len(f.queue) - 1
	}
	return f.queue[i], nil
}

// recordingIncident is a test OnIncident that captures every invocation.
type recordingIncident struct {
	mu    sync.Mutex
	seen  []Verdict
	fail  error
	path  string
}

func (r *recordingIncident) handle(_ context.Context, v Verdict, _ *atop.Sample) (string, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.seen = append(r.seen, v)
	if r.fail != nil {
		return "", r.fail
	}
	return r.path, nil
}

func quietLog() *slog.Logger {
	return slog.New(slog.NewTextHandler(io.Discard, nil))
}

// TestLoop_EscalatesAndWritesReport: feed a critical sample, run one tick,
// confirm the incident handler was actually called with the right severity.
// Anti-bluff: a loop that swallowed the verdict would fail the call counter.
func TestLoop_EscalatesAndWritesReport(t *testing.T) {
	t.Parallel()
	cfg := config.Defaults()
	cfg.IntervalSeconds = 1
	cfg.Report.MinIntervalSeconds = 0

	critical := &atop.Sample{MEM: &atop.MEM{PhysPages: 100, AvailPages: 1}} // 99% used
	sampler := &fakeSampler{queue: []*atop.Sample{critical}, failOn: -1}
	rec := &recordingIncident{path: "/tmp/fake.md"}

	loop := &Loop{Cfg: &cfg, Sampler: sampler, Incident: rec.handle, Log: quietLog()}
	ctx, cancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
	defer cancel()
	_ = loop.Run(ctx)

	rec.mu.Lock()
	defer rec.mu.Unlock()
	if len(rec.seen) == 0 {
		t.Fatal("expected at least one incident, got zero")
	}
	if rec.seen[0].Severity != SevCritical {
		t.Errorf("first severity = %v, want CRITICAL", rec.seen[0].Severity)
	}
}

// TestLoop_CooldownSuppressesSameSeverity: equal-severity ticks within
// cooldown should produce only one incident.
func TestLoop_CooldownSuppressesSameSeverity(t *testing.T) {
	t.Parallel()
	cfg := config.Defaults()
	cfg.IntervalSeconds = 1
	cfg.Report.MinIntervalSeconds = 60

	warn := &atop.Sample{MEM: &atop.MEM{PhysPages: 100, AvailPages: 7}} // 93% used — warn
	sampler := &fakeSampler{queue: []*atop.Sample{warn, warn, warn}, failOn: -1}
	rec := &recordingIncident{path: "/tmp/fake.md"}

	loop := &Loop{Cfg: &cfg, Sampler: sampler, Incident: rec.handle, Log: quietLog()}
	ctx, cancel := context.WithTimeout(context.Background(), 2500*time.Millisecond)
	defer cancel()
	_ = loop.Run(ctx)

	rec.mu.Lock()
	defer rec.mu.Unlock()
	if len(rec.seen) != 1 {
		t.Errorf("expected exactly 1 incident under cooldown, got %d", len(rec.seen))
	}
}

// TestLoop_EscalationBypassesCooldown: warn -> critical fires a new incident
// even within the cooldown window.
func TestLoop_EscalationBypassesCooldown(t *testing.T) {
	t.Parallel()
	cfg := config.Defaults()
	cfg.IntervalSeconds = 1
	cfg.Report.MinIntervalSeconds = 60

	warn := &atop.Sample{MEM: &atop.MEM{PhysPages: 100, AvailPages: 7}}
	crit := &atop.Sample{MEM: &atop.MEM{PhysPages: 100, AvailPages: 1}}
	sampler := &fakeSampler{queue: []*atop.Sample{warn, crit, crit}, failOn: -1}
	rec := &recordingIncident{path: "/tmp/fake.md"}

	loop := &Loop{Cfg: &cfg, Sampler: sampler, Incident: rec.handle, Log: quietLog()}
	ctx, cancel := context.WithTimeout(context.Background(), 2500*time.Millisecond)
	defer cancel()
	_ = loop.Run(ctx)

	rec.mu.Lock()
	defer rec.mu.Unlock()
	if len(rec.seen) < 2 {
		t.Fatalf("expected at least 2 incidents (warn then escalated critical), got %d", len(rec.seen))
	}
	if rec.seen[0].Severity != SevWarn || rec.seen[1].Severity != SevCritical {
		t.Errorf("severity sequence = [%v, %v], want [WARN, CRITICAL]",
			rec.seen[0].Severity, rec.seen[1].Severity)
	}
}

// TestLoop_SamplerErrorDoesNotCrash: a flaky atop should log and continue,
// not abort the daemon.
func TestLoop_SamplerErrorDoesNotCrash(t *testing.T) {
	t.Parallel()
	cfg := config.Defaults()
	cfg.IntervalSeconds = 1
	cfg.Report.MinIntervalSeconds = 0
	sampler := &fakeSampler{
		queue:   []*atop.Sample{{MEM: &atop.MEM{PhysPages: 100, AvailPages: 1}}},
		failOn:  0,
		failErr: errors.New("boom"),
	}
	rec := &recordingIncident{path: "/tmp/fake.md"}

	loop := &Loop{Cfg: &cfg, Sampler: sampler, Incident: rec.handle, Log: quietLog()}
	ctx, cancel := context.WithTimeout(context.Background(), 1500*time.Millisecond)
	defer cancel()
	if err := loop.Run(ctx); err != nil && !errors.Is(err, context.DeadlineExceeded) {
		t.Errorf("Run returned unexpected err = %v", err)
	}
}
