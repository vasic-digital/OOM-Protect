# AGENTS.md — oom-watch submodule

The project-root `../Constitution.md` and `../AGENTS.md` apply in full. This file adds submodule-specific context.

## Anti-bluff testing (binding)

> **A passing test or Challenge MUST prove that the product really works.**

Before any agent declares a change done in this submodule:

1. `go vet ./...` must be clean.
2. `go test -count=1 ./...` must be green.
3. `bash ../challenges/run-all.sh` must be green.
4. The mutation audit must have been performed at least once on the changed code: temporarily break a representative production line, confirm the corresponding test goes red, restore.
5. New features must come with a new Challenge in `../challenges/`.

## Quick orientation

- Entry point: `cmd/oomwatch/main.go`. Flags: `-config`, `-dry-run`, `-one-shot`, `-print-config`, `-version`.
- atop parser: `internal/atop/parser.go`. Fixture: `internal/atop/testdata/sample.txt`.
- Threshold engine: `internal/monitor/threshold.go` (pure; trivial to test exhaustively).
- Loop: `internal/monitor/loop.go`. Calls an `OnIncident` callback so `monitor` does not import `snapshot` (acyclic).
- Snapshot: `internal/snapshot/snapshot.go`. `Capture` is best-effort; partial failures land in `Snapshot.Errors`.
- Report: `internal/report/markdown.go`. Atomic write (temp + rename).
- Logging: `internal/logx/logx.go` — slog text or json.

## Constraints you MUST observe

- **stdlib only.** No `go get` of third-party deps.
- **atop is mandatory** at runtime. Do not add silent fallbacks.
- **Atomic writes** for any artifact in `report_dir`.
- **No t.Skip, no `|| true`.**
- **Submodule Constitution** (`Constitution.md` here) governs additions; do not weaken it.

## When the user asks you to add a new metric

1. Add the typed struct field (or new struct) in `internal/atop/parser.go` and update the parser.
2. Update `parser_test.go` to assert the field on the existing fixture (or add a new fixture if the metric isn't covered).
3. Add the threshold(s) in `internal/config/config.go` (Defaults, ApplyDefaults, Validate).
4. Add the evaluation in `internal/monitor/threshold.go`; add cases in `threshold_test.go`.
5. Add a row in `internal/report/markdown.go` so reports surface the new value.
6. Add a Challenge (`../challenges/challenge-<metric>.sh`) and add it to `run-all.sh`.
7. Run the full suite. Run the mutation audit on the new code.
