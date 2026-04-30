// Command oomwatch is the OOM-Protect monitoring daemon.
//
// It periodically samples atop, evaluates thresholds, and writes detailed
// Markdown forensic reports just before the system would have been pushed
// off the cliff. See ~/Downloads/manuals/oom-watch-manual.md for full docs.
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"runtime/debug"
	"syscall"
	"time"

	"github.com/milos85vasic/oom-protect/oom-watch/internal/atop"
	"github.com/milos85vasic/oom-protect/oom-watch/internal/config"
	"github.com/milos85vasic/oom-protect/oom-watch/internal/logx"
	"github.com/milos85vasic/oom-protect/oom-watch/internal/monitor"
	"github.com/milos85vasic/oom-protect/oom-watch/internal/report"
	"github.com/milos85vasic/oom-protect/oom-watch/internal/snapshot"
)

// Version is overridden at build time via -ldflags '-X main.Version=...'.
var Version = "dev"

func main() {
	var (
		cfgPath     = flag.String("config", "", "path to JSON config; omit for defaults")
		dryRun      = flag.Bool("dry-run", false, "validate config and exit")
		oneShot     = flag.Bool("one-shot", false, "take one sample, write a report unconditionally, exit")
		printConfig = flag.Bool("print-config", false, "print effective config (after defaults) and exit")
		showVersion = flag.Bool("version", false, "print version and exit")
	)
	flag.Parse()

	if *showVersion {
		bi, _ := debug.ReadBuildInfo()
		fmt.Printf("oomwatch %s (go %s)\n", Version, bi.GoVersion)
		return
	}

	cfg, err := config.Load(*cfgPath)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
	if *printConfig {
		fmt.Println(formatConfig(cfg))
		return
	}
	if *dryRun {
		fmt.Println("config OK")
		return
	}

	log := logx.New(cfg.LogLevel, cfg.LogFormat, os.Stderr)
	log.Info("oom-watch starting", "version", Version,
		"interval_s", cfg.IntervalSeconds, "report_dir", cfg.ReportDir)

	// Verify atop FIRST so an environment without atop installed produces a
	// clear, actionable error rather than a confusing report-dir failure.
	runner := &atop.Runner{
		Binary:   cfg.AtopBinary,
		Interval: time.Duration(cfg.IntervalSeconds) * time.Second,
		Labels:   "MEM,SWP,CPU,CPL,PSI,PRC,PRM,DSK,GPU",
	}
	if err := runner.Locate(); err != nil {
		log.Error("atop binary not found — install atop and retry", "err", err)
		fmt.Fprintln(os.Stderr, "fatal: atop binary not found in PATH; install atop and retry")
		os.Exit(1)
	}
	log.Info("atop located", "path", runner.Binary)

	if err := os.MkdirAll(cfg.ReportDir, 0o755); err != nil {
		log.Error("cannot create report dir", "err", err)
		os.Exit(1)
	}

	snapOpts := snapshot.Defaults()
	snapOpts.TopN = cfg.Report.TopNProcesses

	incident := func(ctx context.Context, v monitor.Verdict, s *atop.Sample) (string, error) {
		snap := snapshot.Capture(ctx, v, s, snapOpts)
		return report.WriteMarkdown(snap, cfg.ReportDir)
	}

	if *oneShot {
		// Take one sample no matter what and force a report. Useful for
		// Challenges and for "did this even install correctly?" checks.
		ctx, cancel := context.WithTimeout(context.Background(),
			time.Duration(cfg.IntervalSeconds*3)*time.Second+5*time.Second)
		defer cancel()
		s, err := runner.Sample(ctx)
		if err != nil {
			log.Error("one-shot sample failed", "err", err)
			os.Exit(1)
		}
		v := monitor.Evaluate(s, cfg.Thresholds)
		if v.Severity == monitor.SevNone {
			// Force a notice-level report so operators can verify the path.
			v.Severity = monitor.SevNotice
			v.Triggers = append(v.Triggers, monitor.Trigger{
				Metric: "_one_shot_diagnostic", Severity: monitor.SevNotice,
				Note: "produced via --one-shot; thresholds not breached",
			})
		}
		path, err := incident(ctx, v, s)
		if err != nil {
			log.Error("one-shot report failed", "err", err)
			os.Exit(1)
		}
		log.Info("one-shot report written", "path", path, "severity", v.Severity.String())
		return
	}

	loop := &monitor.Loop{
		Cfg:      cfg,
		Sampler:  runner,
		Incident: incident,
		Log:      log,
	}

	ctx, cancel := signal.NotifyContext(context.Background(),
		syscall.SIGINT, syscall.SIGTERM)
	defer cancel()
	if err := loop.Run(ctx); err != nil && !errors.Is(err, context.Canceled) {
		log.Error("loop exited", "err", err)
		os.Exit(1)
	}
	log.Info("oom-watch exited cleanly")
}

func formatConfig(c *config.Config) string {
	return fmt.Sprintf(`interval_seconds      = %d
report_dir            = %s
state_dir             = %s
log_level             = %s
log_format            = %s
atop_binary           = %s
thresholds.memory_used_ratio = notice=%.2f warn=%.2f critical=%.2f
thresholds.swap_used_ratio   = warn=%.2f critical=%.2f
thresholds.psi_mem_full_avg10 = warn=%.2f critical=%.2f
thresholds.psi_mem_some_avg10 = warn=%.2f
thresholds.load_per_cpu       = warn=%.2f critical=%.2f
report.min_interval_seconds   = %d
report.top_n_processes        = %d`,
		c.IntervalSeconds, c.ReportDir, c.StateDir, c.LogLevel, c.LogFormat, c.AtopBinary,
		c.Thresholds.MemoryUsedRatioNotice, c.Thresholds.MemoryUsedRatioWarn, c.Thresholds.MemoryUsedRatioCritical,
		c.Thresholds.SwapUsedRatioWarn, c.Thresholds.SwapUsedRatioCritical,
		c.Thresholds.PSIMemFullAvg10Warn, c.Thresholds.PSIMemFullAvg10Critical,
		c.Thresholds.PSIMemSomeAvg10Warn,
		c.Thresholds.LoadPerCPUWarn, c.Thresholds.LoadPerCPUCritical,
		c.Report.MinIntervalSeconds, c.Report.TopNProcesses,
	)
}
