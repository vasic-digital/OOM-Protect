// Package report writes a Snapshot to disk as a Markdown forensic report.
//
// One Snapshot becomes one .md file. The filename encodes timestamp +
// severity so a directory listing is already useful at triage time. Writes
// are atomic (temp + rename) so a partial file is never observed.
package report

import (
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/milos85vasic/oom-protect/oom-watch/internal/atop"
	"github.com/milos85vasic/oom-protect/oom-watch/internal/snapshot"
)

// WriteMarkdown writes snap as a Markdown report under dir. dir is created if
// it does not exist. Returns the absolute path of the file written.
func WriteMarkdown(snap *snapshot.Snapshot, dir string) (string, error) {
	if snap == nil {
		return "", errors.New("report: nil snapshot")
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return "", fmt.Errorf("report: mkdir %s: %w", dir, err)
	}
	name := fmt.Sprintf("%s-%s.md",
		snap.Time.Format("2006-01-02T15-04-05Z"),
		strings.ToLower(snap.Verdict.Severity.String()))
	path := filepath.Join(dir, name)

	tmp, err := os.CreateTemp(dir, ".oom-watch-*.tmp")
	if err != nil {
		return "", fmt.Errorf("report: temp: %w", err)
	}
	tmpName := tmp.Name()
	defer os.Remove(tmpName) // harmless if rename succeeded
	if err := writeReport(tmp, snap); err != nil {
		tmp.Close()
		return "", err
	}
	if err := tmp.Close(); err != nil {
		return "", err
	}
	if err := os.Rename(tmpName, path); err != nil {
		return "", fmt.Errorf("report: rename: %w", err)
	}
	abs, err := filepath.Abs(path)
	if err != nil {
		return path, nil
	}
	return abs, nil
}

func writeReport(w io.Writer, snap *snapshot.Snapshot) error {
	bw := &errWriter{w: w}

	// Frontmatter (YAML) — pandoc-friendly.
	bw.printf("---\n")
	bw.printf("title: \"OOM-Watch incident: %s\"\n", snap.Verdict.Severity)
	bw.printf("host: %q\n", snap.Hostname)
	bw.printf("timestamp: %q\n", snap.Time.Format(time.RFC3339))
	bw.printf("severity: %q\n", snap.Verdict.Severity)
	bw.printf("---\n\n")

	bw.printf("# OOM-Watch incident — %s\n\n", snap.Verdict.Severity)
	bw.printf("- **Host:** `%s`\n", snap.Hostname)
	bw.printf("- **Time (UTC):** `%s`\n", snap.Time.Format(time.RFC3339))
	bw.printf("- **Severity:** **%s**\n\n", snap.Verdict.Severity)

	// Triggers
	bw.printf("## Triggers\n\n")
	if len(snap.Verdict.Triggers) == 0 {
		bw.printf("_No triggers recorded._\n\n")
	} else {
		bw.printf("| Severity | Metric | Value | Limit | Note |\n")
		bw.printf("|---|---|---:|---:|---|\n")
		for _, t := range snap.Verdict.Triggers {
			bw.printf("| %s | `%s` | %.4f | %.4f | %s |\n",
				t.Severity, t.Metric, t.Value, t.Limit, t.Note)
		}
		bw.printf("\n")
	}

	// Atop sample summary
	bw.printf("## Atop sample summary\n\n")
	if snap.Sample == nil {
		bw.printf("_No sample available._\n\n")
	} else {
		writeSampleSummary(bw, snap.Sample)
	}

	// Top processes
	bw.printf("## Top processes by resident memory\n\n")
	writeProcessTable(bw, snap.TopByMemory, snap.Sample)

	bw.printf("## Top processes by CPU (per atop)\n\n")
	writeProcessTable(bw, snap.TopByCPU, snap.Sample)

	// /proc snapshots
	bw.printf("## /proc/meminfo\n\n```\n%s\n```\n\n", trimRight(snap.MemInfo))
	bw.printf("## /proc/loadavg\n\n```\n%s\n```\n\n", trimRight(snap.LoadAvg))
	bw.printf("## /proc/pressure/memory\n\n```\n%s\n```\n\n", trimRight(snap.PressureMemory))
	bw.printf("## /proc/pressure/cpu\n\n```\n%s\n```\n\n", trimRight(snap.PressureCPU))
	bw.printf("## /proc/pressure/io\n\n```\n%s\n```\n\n", trimRight(snap.PressureIO))

	// Cgroup
	bw.printf("## User-slice cgroup\n\n")
	if snap.UserSliceCgroup == "" {
		bw.printf("_No data._\n\n")
	} else {
		bw.printf("```\n%s\n```\n\n", trimRight(snap.UserSliceCgroup))
	}

	// Journal
	bw.printf("## Journal tail\n\n")
	if snap.JournalTail == "" {
		bw.printf("_No data._\n\n")
	} else {
		bw.printf("```\n%s\n```\n\n", trimRight(snap.JournalTail))
	}

	// Capture errors — these MUST appear so reviewers know what is missing.
	if len(snap.Errors) > 0 {
		bw.printf("## Capture errors\n\n")
		for _, e := range snap.Errors {
			bw.printf("- `%s`\n", e)
		}
		bw.printf("\n")
	}

	return bw.err
}

func writeSampleSummary(bw *errWriter, s *atop.Sample) {
	if s.MEM != nil {
		bw.printf("- Memory used ratio: **%.4f** (avail=%d / phys=%d pages, page=%d B)\n",
			s.MEM.MemUsedRatio(), s.MEM.AvailPages, s.MEM.PhysPages, s.MEM.PageSize)
	}
	if s.SWP != nil {
		bw.printf("- Swap used ratio: **%.4f** (free=%d / total=%d pages)\n",
			s.SWP.SwapUsedRatio(), s.SWP.SwapFree, s.SWP.SwapPages)
	}
	if s.PSI != nil && s.PSI.Present {
		bw.printf("- PSI memory.full: avg10=%.2f avg60=%.2f avg300=%.2f\n",
			s.PSI.MemFullAvg10, s.PSI.MemFullAvg60, s.PSI.MemFullAvg300)
		bw.printf("- PSI memory.some: avg10=%.2f avg60=%.2f avg300=%.2f\n",
			s.PSI.MemSomeAvg10, s.PSI.MemSomeAvg60, s.PSI.MemSomeAvg300)
	}
	if s.CPL != nil {
		bw.printf("- Load: %.2f / %.2f / %.2f over %d CPUs (per-CPU = %.2f)\n",
			s.CPL.Load1, s.CPL.Load5, s.CPL.Load15, s.CPL.NumCPU,
			s.CPL.Load1/float64(maxInt64(s.CPL.NumCPU, 1)))
	}
	bw.printf("\n")
}

func writeProcessTable(bw *errWriter, ps []snapshot.ProcessLine, s *atop.Sample) {
	if len(ps) == 0 {
		bw.printf("_None._\n\n")
		return
	}
	pageBytes := int64(0)
	if s != nil && s.MEM != nil {
		pageBytes = s.MEM.PageSize
	}
	bw.printf("| PID | Cmd | State | RSize | VSize | Source |\n")
	bw.printf("|---:|---|:---:|---:|---:|---|\n")
	for _, p := range ps {
		rss := formatBytes(p.RSize, pageBytes)
		vsz := formatBytes(p.VSize, pageBytes)
		bw.printf("| %d | `%s` | %s | %s | %s | %s |\n",
			p.PID, escapePipe(p.Cmd), p.State, rss, vsz, p.Source)
	}
	bw.printf("\n")
}

func formatBytes(pages, pageSize int64) string {
	if pages <= 0 || pageSize <= 0 {
		return fmt.Sprintf("%d", pages)
	}
	b := pages * pageSize
	const (
		kib = 1024
		mib = kib * 1024
		gib = mib * 1024
	)
	switch {
	case b >= gib:
		return fmt.Sprintf("%.2f GiB", float64(b)/float64(gib))
	case b >= mib:
		return fmt.Sprintf("%.2f MiB", float64(b)/float64(mib))
	case b >= kib:
		return fmt.Sprintf("%.2f KiB", float64(b)/float64(kib))
	default:
		return fmt.Sprintf("%d B", b)
	}
}

func escapePipe(s string) string { return strings.ReplaceAll(s, "|", "\\|") }
func trimRight(s string) string  { return strings.TrimRight(s, "\n ") }
func maxInt64(a, b int64) int64 {
	if a > b {
		return a
	}
	return b
}

// errWriter accumulates the first write error and short-circuits subsequent
// printf calls — keeps writeReport free of error noise.
type errWriter struct {
	w   io.Writer
	err error
}

func (e *errWriter) printf(f string, a ...any) {
	if e.err != nil {
		return
	}
	_, e.err = fmt.Fprintf(e.w, f, a...)
}
