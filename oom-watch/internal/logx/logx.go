// Package logx is a tiny structured logger built on log/slog.
//
// The daemon must run for weeks without operator attention, so every line we
// emit must be greppable, machine-parseable when needed, and never panic. We
// deliberately avoid third-party logging libraries.
package logx

import (
	"io"
	"log/slog"
	"os"
	"strings"
)

// New returns a slog.Logger configured for the given level and format.
// format is "text" (default, human readable) or "json".
// out is typically os.Stderr; tests pass a buffer.
func New(level, format string, out io.Writer) *slog.Logger {
	if out == nil {
		out = os.Stderr
	}
	var lvl slog.Level
	switch strings.ToLower(level) {
	case "debug":
		lvl = slog.LevelDebug
	case "info", "":
		lvl = slog.LevelInfo
	case "warn", "warning":
		lvl = slog.LevelWarn
	case "error":
		lvl = slog.LevelError
	default:
		lvl = slog.LevelInfo
	}
	opts := &slog.HandlerOptions{Level: lvl}
	var h slog.Handler
	if strings.ToLower(format) == "json" {
		h = slog.NewJSONHandler(out, opts)
	} else {
		h = slog.NewTextHandler(out, opts)
	}
	return slog.New(h)
}
