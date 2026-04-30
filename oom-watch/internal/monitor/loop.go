package monitor

import (
	"context"
	"log/slog"
	"time"

	"github.com/milos85vasic/oom-protect/oom-watch/internal/atop"
	"github.com/milos85vasic/oom-protect/oom-watch/internal/config"
)

// Sampler is the abstraction we depend on for live data. The atop.Runner
// satisfies it; tests pass a stub that returns canned samples.
type Sampler interface {
	Sample(ctx context.Context) (*atop.Sample, error)
}

// OnIncident is called when a threshold breach should be reported. The
// implementation captures the system snapshot, writes the report, and
// returns the on-disk path. Returning an error logs the failure but does
// not abort the daemon.
//
// monitor intentionally does not import snapshot/report — main.go wires
// them together. Keeps the dependency graph acyclic.
type OnIncident func(ctx context.Context, v Verdict, s *atop.Sample) (path string, err error)

// Loop runs the daemon's main cycle. It returns when ctx is cancelled, with
// the cancellation reason as error (or nil for clean shutdown).
//
// The cooldown discipline:
//   - SevNone => no report; reset cooldown clock so that a transient dip
//     doesn't suppress a real escalation later.
//   - lower-or-equal severity within cooldown => no report (avoid spam).
//   - higher severity than the last report => always emit a report.
type Loop struct {
	Cfg      *config.Config
	Sampler  Sampler
	Incident OnIncident
	Log      *slog.Logger
}

// Run blocks until ctx is cancelled.
func (l *Loop) Run(ctx context.Context) error {
	if l.Log == nil {
		l.Log = slog.Default()
	}
	interval := time.Duration(l.Cfg.IntervalSeconds) * time.Second
	cooldown := time.Duration(l.Cfg.Report.MinIntervalSeconds) * time.Second

	var lastReport time.Time
	var lastSeverity Severity

	t := time.NewTicker(interval)
	defer t.Stop()

	// Run a sample immediately so the first report doesn't wait one interval
	// when a critical condition is already present at startup.
	l.tick(ctx, &lastReport, &lastSeverity, cooldown)

	for {
		select {
		case <-ctx.Done():
			l.Log.Info("oom-watch: shutting down", "reason", ctx.Err())
			return ctx.Err()
		case <-t.C:
			l.tick(ctx, &lastReport, &lastSeverity, cooldown)
		}
	}
}

func (l *Loop) tick(ctx context.Context, lastReport *time.Time, lastSeverity *Severity, cooldown time.Duration) {
	s, err := l.Sampler.Sample(ctx)
	if err != nil {
		l.Log.Error("atop sample failed", "err", err)
		return
	}
	v := Evaluate(s, l.Cfg.Thresholds)
	l.Log.Debug("verdict", "severity", v.Severity.String(), "triggers", len(v.Triggers))

	if v.Severity == SevNone {
		*lastSeverity = SevNone
		return
	}

	now := time.Now()
	escalated := v.Severity > *lastSeverity
	cooled := now.Sub(*lastReport) >= cooldown
	if !escalated && !cooled {
		l.Log.Info("threshold breach suppressed by cooldown",
			"severity", v.Severity.String(),
			"since_last_report", now.Sub(*lastReport).Round(time.Second).String())
		return
	}

	path, werr := l.Incident(ctx, v, s)
	if werr != nil {
		l.Log.Error("incident write failed", "err", werr, "severity", v.Severity.String())
		return
	}
	*lastReport = now
	*lastSeverity = v.Severity
	l.Log.Warn("incident report written",
		"path", path, "severity", v.Severity.String(),
		"triggers", len(v.Triggers))
}
