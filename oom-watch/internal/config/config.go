// Package config loads the oom-watch JSON configuration file.
//
// JSON was chosen over YAML/TOML to keep the binary fully self-contained
// (zero external dependencies). System administrators are accustomed to
// hand-editing JSON, and the file is small.
package config

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"os"
)

// Config is the on-disk shape. Defaults are populated by ApplyDefaults so a
// missing field never produces a silently-zero threshold (which would either
// fire constantly or never fire — both are anti-bluff hazards).
type Config struct {
	IntervalSeconds int    `json:"interval_seconds"`
	ReportDir       string `json:"report_dir"`
	StateDir        string `json:"state_dir"`
	LogLevel        string `json:"log_level"`
	LogFormat       string `json:"log_format"`
	AtopBinary      string `json:"atop_binary"`

	Thresholds Thresholds `json:"thresholds"`
	Report     Report     `json:"report"`
}

// Thresholds is the severity ladder. Each metric has separate notice / warn /
// critical levels so the daemon can distinguish "watch this" from "act now".
type Thresholds struct {
	MemoryUsedRatioNotice   float64 `json:"memory_used_ratio_notice"`
	MemoryUsedRatioWarn     float64 `json:"memory_used_ratio_warn"`
	MemoryUsedRatioCritical float64 `json:"memory_used_ratio_critical"`

	SwapUsedRatioWarn     float64 `json:"swap_used_ratio_warn"`
	SwapUsedRatioCritical float64 `json:"swap_used_ratio_critical"`

	PSIMemFullAvg10Warn     float64 `json:"psi_mem_full_avg10_warn"`
	PSIMemFullAvg10Critical float64 `json:"psi_mem_full_avg10_critical"`
	PSIMemSomeAvg10Warn     float64 `json:"psi_mem_some_avg10_warn"`

	LoadPerCPUWarn     float64 `json:"load_per_cpu_warn"`
	LoadPerCPUCritical float64 `json:"load_per_cpu_critical"`
}

// Report controls report-writing behavior.
type Report struct {
	MinIntervalSeconds int `json:"min_interval_seconds"` // cooldown between reports of the same severity
	TopNProcesses      int `json:"top_n_processes"`
}

// Load reads and validates a config file. If path == "", returns Defaults().
func Load(path string) (*Config, error) {
	if path == "" {
		c := Defaults()
		return &c, nil
	}
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("config: read %s: %w", path, err)
	}
	var c Config
	dec := json.NewDecoder(bytes.NewReader(b))
	dec.DisallowUnknownFields() // catch typos loudly
	if err := dec.Decode(&c); err != nil {
		return nil, fmt.Errorf("config: parse %s: %w", path, err)
	}
	c.ApplyDefaults()
	if err := c.Validate(); err != nil {
		return nil, fmt.Errorf("config: invalid %s: %w", path, err)
	}
	return &c, nil
}

// Defaults returns a Config with safe production defaults. These are the
// values you get if no config file is provided.
func Defaults() Config {
	return Config{
		IntervalSeconds: 10,
		ReportDir:       "/var/log/oom-watch/reports",
		StateDir:        "/var/lib/oom-watch",
		LogLevel:        "info",
		LogFormat:       "text",
		AtopBinary:      "atop",
		Thresholds: Thresholds{
			MemoryUsedRatioNotice:   0.80,
			MemoryUsedRatioWarn:     0.90,
			MemoryUsedRatioCritical: 0.95,
			SwapUsedRatioWarn:       0.50,
			SwapUsedRatioCritical:   0.80,
			PSIMemFullAvg10Warn:     10.0,
			PSIMemFullAvg10Critical: 30.0,
			PSIMemSomeAvg10Warn:     40.0,
			LoadPerCPUWarn:          2.0,
			LoadPerCPUCritical:      4.0,
		},
		Report: Report{
			MinIntervalSeconds: 60,
			TopNProcesses:      20,
		},
	}
}

// ApplyDefaults fills any zero-valued field with the Defaults() value. This
// way a config file may set just the few thresholds it cares about and still
// boot a working daemon.
func (c *Config) ApplyDefaults() {
	d := Defaults()
	if c.IntervalSeconds == 0 {
		c.IntervalSeconds = d.IntervalSeconds
	}
	if c.ReportDir == "" {
		c.ReportDir = d.ReportDir
	}
	if c.StateDir == "" {
		c.StateDir = d.StateDir
	}
	if c.LogLevel == "" {
		c.LogLevel = d.LogLevel
	}
	if c.LogFormat == "" {
		c.LogFormat = d.LogFormat
	}
	if c.AtopBinary == "" {
		c.AtopBinary = d.AtopBinary
	}
	t := &c.Thresholds
	dt := d.Thresholds
	if t.MemoryUsedRatioNotice == 0 {
		t.MemoryUsedRatioNotice = dt.MemoryUsedRatioNotice
	}
	if t.MemoryUsedRatioWarn == 0 {
		t.MemoryUsedRatioWarn = dt.MemoryUsedRatioWarn
	}
	if t.MemoryUsedRatioCritical == 0 {
		t.MemoryUsedRatioCritical = dt.MemoryUsedRatioCritical
	}
	if t.SwapUsedRatioWarn == 0 {
		t.SwapUsedRatioWarn = dt.SwapUsedRatioWarn
	}
	if t.SwapUsedRatioCritical == 0 {
		t.SwapUsedRatioCritical = dt.SwapUsedRatioCritical
	}
	if t.PSIMemFullAvg10Warn == 0 {
		t.PSIMemFullAvg10Warn = dt.PSIMemFullAvg10Warn
	}
	if t.PSIMemFullAvg10Critical == 0 {
		t.PSIMemFullAvg10Critical = dt.PSIMemFullAvg10Critical
	}
	if t.PSIMemSomeAvg10Warn == 0 {
		t.PSIMemSomeAvg10Warn = dt.PSIMemSomeAvg10Warn
	}
	if t.LoadPerCPUWarn == 0 {
		t.LoadPerCPUWarn = dt.LoadPerCPUWarn
	}
	if t.LoadPerCPUCritical == 0 {
		t.LoadPerCPUCritical = dt.LoadPerCPUCritical
	}
	if c.Report.MinIntervalSeconds == 0 {
		c.Report.MinIntervalSeconds = d.Report.MinIntervalSeconds
	}
	if c.Report.TopNProcesses == 0 {
		c.Report.TopNProcesses = d.Report.TopNProcesses
	}
}

// Validate enforces invariants that ApplyDefaults can't (e.g. notice <= warn
// <= critical). Catching these at startup prevents a daemon that runs but
// never alerts.
func (c *Config) Validate() error {
	if c.IntervalSeconds <= 0 {
		return errors.New("interval_seconds must be > 0")
	}
	if c.IntervalSeconds > 600 {
		return errors.New("interval_seconds must be <= 600 (10 min)")
	}
	t := c.Thresholds
	if !(t.MemoryUsedRatioNotice <= t.MemoryUsedRatioWarn &&
		t.MemoryUsedRatioWarn <= t.MemoryUsedRatioCritical) {
		return fmt.Errorf("memory_used_ratio thresholds must satisfy notice (%.2f) <= warn (%.2f) <= critical (%.2f)",
			t.MemoryUsedRatioNotice, t.MemoryUsedRatioWarn, t.MemoryUsedRatioCritical)
	}
	if t.MemoryUsedRatioCritical >= 1.0 {
		return errors.New("memory_used_ratio_critical must be < 1.0 (cannot detect 100% used)")
	}
	if !(t.SwapUsedRatioWarn <= t.SwapUsedRatioCritical) {
		return errors.New("swap_used_ratio: warn must be <= critical")
	}
	if !(t.PSIMemFullAvg10Warn <= t.PSIMemFullAvg10Critical) {
		return errors.New("psi_mem_full_avg10: warn must be <= critical")
	}
	if !(t.LoadPerCPUWarn <= t.LoadPerCPUCritical) {
		return errors.New("load_per_cpu: warn must be <= critical")
	}
	if c.Report.MinIntervalSeconds < 0 {
		return errors.New("report.min_interval_seconds must be >= 0")
	}
	if c.Report.TopNProcesses <= 0 {
		return errors.New("report.top_n_processes must be > 0")
	}
	return nil
}

