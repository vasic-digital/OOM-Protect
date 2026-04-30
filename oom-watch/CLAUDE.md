# CLAUDE.md — oom-watch submodule

The project-root `../Constitution.md` and `../CLAUDE.md` apply. This file adds submodule-specific context only.

## Anti-bluff testing (re-stated, non-negotiable)

> **A passing test or Challenge MUST prove that the product really works.**

For oom-watch:

- Tests use real fixtures (`internal/atop/testdata/sample.txt`) and temp /proc trees. No method stubs.
- Challenges (`../challenges/challenge-*.sh`) invoke the built `oomwatch` binary and assert on real on-disk reports.
- Before declaring done: `go test -count=1 ./...` and `bash ../challenges/run-all.sh` must both pass.
- Run the mutation audit at least once per change.

## Module layout

```
cmd/oomwatch/main.go      flag parsing, signal handling, wires monitor.Loop together
internal/atop/            parses atop -PALL output; spawns atop subprocess
internal/config/          JSON config + Defaults() + Validate()
internal/monitor/         pure Evaluate(); threshold-driven Loop with cooldown/escalation
internal/snapshot/        captures /proc, cgroup, journal at incident time (best-effort)
internal/report/          atomic Markdown writer
internal/logx/            slog wrapper (text or json)
```

The dependency graph is acyclic: `monitor` does NOT import `snapshot`. main.go provides an `OnIncident` callback that bridges them.

## Key design decisions (for future agents)

- **Stdlib only.** No yaml.v3, no testify. Keeps the binary self-contained and reproducible.
- **atop is mandatory.** The daemon refuses to start without it. Don't add silent /proc fallbacks.
- **Reports must be atomic.** Write to `.oom-watch-*.tmp` and rename. Tests verify no leftover temps.
- **Cooldown discipline.** Same severity within `min_interval_seconds` is suppressed; an escalation always emits, even within cooldown. This is tested in `loop_test.go`.
- **Error tolerance in snapshot.** Missing /proc files or absent journalctl record into `Snapshot.Errors`; we never abort the snapshot. Reports document what they could not collect.

## Common commands

```bash
# from this dir:
go test -count=1 ./...                      # all unit tests
go vet ./...
go build -o oomwatch ./cmd/oomwatch         # produce binary
./oomwatch -dry-run                         # validate default config
./oomwatch -print-config                    # show effective config
./oomwatch -one-shot -config /tmp/c.json    # produce one diagnostic report

# from repo root:
bash challenges/run-all.sh                  # full E2E suite
```

## Editing the parser

`internal/atop/parser.go` is keyed off the field positions documented in atop(1)'s "parsable output" section (master branch as of 2024-07). When atop adds new MEM/SWP/PSI fields, append to the typed struct **at the end** to preserve old fixture compatibility, and add a `len(f) > N` guard before reading. Tests in `parser_test.go` target specific field values; update them with the new expectations and run the mutation audit.
