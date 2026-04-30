# CLAUDE.md — oom-watch submodule

The project-root `../Constitution.md` and `../CLAUDE.md` apply. This file adds submodule-specific context only. Read this **before** the first edit so you understand which design decisions are deliberate and which are open to change.

## Anti-bluff testing (re-stated, non-negotiable)

> **A passing test or Challenge MUST prove that the product really works.**

For oom-watch:

- Tests use real fixtures (`internal/atop/testdata/sample.txt`) and temp /proc trees. No method stubs.
- Challenges (`../challenges/challenge-*.sh`) invoke the built `oomwatch` binary and assert on real on-disk reports.
- Before declaring done: `go test -count=1 ./...` AND `bash ../challenges/run-all.sh` must both pass. **Both, not either.**
- One Challenge is dedicated to proving the test suite isn't a bluff: `challenge-tests-are-not-bluffs.sh` mutates `AvailPages: pi(24)` → `AvailPages: 0` in `internal/atop/parser.go`, runs `go test`, asserts non-zero exit, and restores. If the mutation passes silently, the suite is a bluff.

## Verified deployment target

Field-tested on **ALT Linux 11 "Salvia"** (Sisyphus branch), kernel 6.12.61-6.12-alt1, systemd 258, atop 2.12.1, x86_64. The deployer accommodates ALT-specific quirks automatically (root not in sudoers, systemd 258 directive forms). Do NOT regress these accommodations without testing on ALT.

## Module layout

```
cmd/oomwatch/main.go              flag parsing, signal handling, wires monitor.Loop
cmd/oommemhog/main.go             in-tree memory hog for challenge-real-pressure.sh
                                  (bounded 16 GiB / 5 min; touches every page)
internal/atop/                    atop -PALL parser + runner. Handles atop 2.x
                                  per-thread PRM emission via PRM.IsLeader.
internal/config/                  JSON config + Defaults() + Validate(). Rejects
                                  unknown fields (DisallowUnknownFields).
internal/monitor/                 pure Evaluate(); threshold-driven Loop with
                                  cooldown + escalation discipline.
internal/snapshot/                captures /proc, cgroup, journal at incident
                                  time PLUS forensic enrichment of top-N PIDs
                                  (cmdline, status, cgroup, oom_score, parent
                                  cmdline) PLUS kernel OOM dmesg tail. All
                                  best-effort: errors record into Snapshot.Errors.
internal/report/                  atomic Markdown writer (temp + rename).
internal/logx/                    slog wrapper (text or json).
scripts/install-and-verify.sh     one-shot deployer (make oomwatch-deploy).
                                  Auto-remediates a broken installed config.
scripts/diagnose.sh               full state bundler (make oomwatch-diagnose).
                                  16 sections, written to /tmp/.
systemd/oom-watch.service         hardened unit, atop-compatible sandbox.
config/oom-watch.example.json     shipped example. Validated by Challenge.
```

The dependency graph is acyclic: `monitor` does NOT import `snapshot`. main.go provides an `OnIncident` callback that bridges them — keeps both packages testable in isolation.

## Key design decisions (for future agents)

### Code & runtime

- **Stdlib only.** No yaml.v3, no testify. Keeps the binary self-contained, reproducible offline, and statically buildable. JSON for config, `encoding/json` with `DisallowUnknownFields` for typo safety.
- **atop is mandatory.** The daemon refuses to start without it (`runner.Locate()` returns `ErrAtopMissing`). Do NOT add silent /proc fallbacks — they would mask the dependency and produce inconsistent reports across hosts.
- **Reports must be atomic.** Write to `.oom-watch-*.tmp` in the same directory and `os.Rename`. `TestWriteMarkdown_NoLeftoverTemp` enforces no `.tmp` files remain after success.
- **Cooldown discipline.** Same severity within `min_interval_seconds` is suppressed; an escalation always emits, even within cooldown. Tested in `loop_test.go` (`TestLoop_CooldownSuppressesSameSeverity`, `TestLoop_EscalationBypassesCooldown`).
- **Error tolerance in snapshot.** Missing /proc files or absent journalctl record into `Snapshot.Errors`; we never abort the snapshot. Reports document what they could not collect. `TestCapture_PartialFailure` enforces this.
- **Forensic enrichment at snapshot time, not report-read time.** `/proc/<pid>/cmdline` only exists while the process is running. By the time an operator reads a report 30 minutes later, the runaway may already have been OOM-killed. Capturing during `Capture()` preserves evidence the moment it matters; doing it later would be too late.

### atop integration

- atop 2.x emits one PRM row per kernel thread; non-leader rows duplicate the parent's RSize. The parser exposes `PRM.IsLeader` (read from the `y`/`n` flag at PRM tail index 13); `snapshot.topProcesses` filters by it. Without this filter a 100-thread JVM drowns out every other process in top-N.
- atop 1.x lacks the leader flag. The parser defaults `IsLeader=true` so old atop hosts still produce useful top-N — lossless fallback.

### systemd unit

- `User=root` is required (atop reads `/proc/<pid>/io` for I/O accounting and `/proc/kallsyms`).
- `MemoryMax=128M`, `MemoryHigh=64M`, `TasksMax=64` — daemon plus atop subprocess fits comfortably; observed peak 46 MiB.
- `OOMScoreAdjust=-500` — the daemon's job is to write a report **before** the kernel OOM-killer fires; it must not be a victim.
- `StartLimitIntervalSec` / `StartLimitBurst` live in `[Unit]` (systemd ≥ 230). Older systemds tolerated `[Service]`; systemd 258 emits "Unknown key" warnings.
- `ProtectControlGroups=yes` — only `yes`/`no` are universally accepted. `read-only` is rejected by systemd 258.
- **NOT enabled** (atop compatibility — see comments in the unit file): `RestrictNamespaces`, `SystemCallArchitectures`, `SystemCallFilter`, `CapabilityBoundingSet`. Each of these can SIGKILL atop with empty stderr (`atop exit -1: ` in the journal). The cgroup limits + `OOMScoreAdjust` + `ProtectSystem=strict` + `ReadWritePaths` are the load-bearing protections.

### Deployer (`scripts/install-and-verify.sh`)

- **Auto-remediates** a broken installed config: backs up to `/etc/oom-watch/config.json.broken.<ts>`, copies the shipped example, re-validates. If THAT fails, the repo is broken and we abort fatal.
- **`systemctl reset-failed` BEFORE every restart.** A unit that bounced 150+ times under a previous bad config will be in `Start request repeated too quickly` state until reset; without this, fresh restarts silently fail.
- **`oomwatch -dry-run` BEFORE `systemctl restart`.** Turns a cryptic `code=exited, status=2` into the precise validator error.

### Cross-UID build

- `-buildvcs=false` is passed to every `go build` (Makefile, scripts/install-and-verify.sh, challenges/lib.sh `GOFLAGS`). Without it, a repo on a mount owned by UID X built by UID Y triggers git's "dubious ownership" safety and `go build` fails. We never read the VCS stamp from the binary, so disabling is zero-cost.

### Challenge harness

- **`chal_assert "..."` is dangerous for content-bearing tests.** Bash's outer double-quote expansion in the caller re-evaluates backticks INSIDE captured markdown content (e.g. `` `bash /…/script.sh` `` in a "Parent cmdline" field) as command substitution. This caused a real fork-bomb-class bug on 2026-04-30 — `challenge-real-pressure.sh` recursively self-spawned 9+ times. **Use direct inline `if grep -qF "$needle" "$file"; then chal_ok ...; else chal_fail ...; fi` for any test against captured content.** `lib.sh` ships `chal_assert_var` (using `${!varname}`) for the common nonempty/empty case; safe alternative.

## Common commands

```bash
# from this dir (oom-watch/):
go test -count=1 ./...                          # all unit tests
go vet ./...
go build -buildvcs=false -o oomwatch ./cmd/oomwatch
./oomwatch -dry-run                             # validate default config
./oomwatch -print-config                        # show effective config (defaults + file overlay)
./oomwatch -one-shot -config /tmp/c.json        # one forensic report on demand
./oomwatch -version

# from repo root:
make oomwatch-test                              # vet + tests
make oomwatch-build                             # binary
make oommemhog-build                            # the in-tree memory hog
make challenges                                 # full E2E suite (7 / 7)
make oomwatch-deploy                            # install + verify (sudo)
make oomwatch-diagnose                          # full diagnostic bundle (sudo)
```

## Editing the parser

`internal/atop/parser.go` is keyed off the field positions documented in atop(1)'s "parsable output" section. When atop adds new MEM/SWP/PSI fields, append to the typed struct **at the end** to preserve old fixture compatibility, and add a `len(f) > N` guard before reading. Tests in `parser_test.go` target specific field values; update them with the new expectations and run the mutation audit.

The `extractCmd` function handles both `(cmd with spaces)` and `-Z`-escaped barewords for process labels (PRM, PRC, PRG). PRM-specific: index 13 of the trailing-fields array is the `y`/`n` thread-group-leader flag (atop 2.x); older atops omit it and parser defaults `IsLeader=true`.

## Editing the systemd unit

Test changes in isolation BEFORE redeploying:

```bash
cp oom-watch/systemd/oom-watch.service /tmp/test.service
systemd-analyze verify /tmp/test.service
```

Verify there are no `Unknown key` or `Failed to parse` warnings on the target systemd version. After install, watch `journalctl -u oom-watch.service` for `atop sample failed: atop exit -1` — that's the signal a sandbox directive blocked atop. Section `Sandbox blocking atop` in `../manuals/oom-watch-runbook.md` documents the recovery.

## When you finish

Run the full suite **in this order**:

```bash
go vet ./...                                # quick correctness
go test -count=1 ./...                      # unit tests
bash ../challenges/run-all.sh               # E2E (7 / 7 expected)
sudo make oomwatch-deploy                   # production sanity (if changing
                                            # the deployer or unit)
```

If you changed something in the report format, the `oomwatch-deploy` will produce a fresh `*-notice.md` you can inspect at `/var/log/oom-watch/reports/`.
