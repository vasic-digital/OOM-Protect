# AGENTS.md — oom-watch submodule

The project-root `../Constitution.md` and `../AGENTS.md` apply in full. This file adds submodule-specific context for agents working on the oom-watch daemon.

## Anti-bluff testing (binding)

> **A passing test or Challenge MUST prove that the product really works.**

Before any agent declares a change done in this submodule:

1. `go vet ./...` clean.
2. `go test -count=1 ./...` green (six packages: atop, config, monitor, snapshot, report — logx has no tests because it's a thin slog wrapper).
3. `bash ../challenges/run-all.sh` green — all **7 / 7 PASS**.
4. The mutation audit performed at least once on the changed code (temporarily break a representative production line, confirm the corresponding test goes red, restore). The dedicated Challenge `challenge-tests-are-not-bluffs.sh` does this for the parser as a permanent regression check.
5. New features come with a new Challenge in `../challenges/` covering the feature end-to-end with **specific** assertions on observable outcomes (file paths, byte ranges, content substrings — never just "exit 0").

## Quick orientation

- **Entry point:** `cmd/oomwatch/main.go`. Flags: `-config`, `-dry-run`, `-one-shot`, `-print-config`, `-version`.
- **In-tree memory hog:** `cmd/oommemhog/main.go`. Used only by `challenge-real-pressure.sh`. Bounded 16 GiB / 5 min by source. Touches every page so MemAvailable actually drops.
- **atop parser:** `internal/atop/parser.go`. Fixture: `internal/atop/testdata/sample.txt`. Handles atop 2.x per-thread PRM emission via `PRM.IsLeader` (read from the `y`/`n` flag at PRM tail index 13).
- **Threshold engine:** `internal/monitor/threshold.go` (pure; trivial to test exhaustively).
- **Loop:** `internal/monitor/loop.go`. Calls an `OnIncident` callback so `monitor` does not import `snapshot` (acyclic).
- **Snapshot:** `internal/snapshot/snapshot.go`. `Capture` is best-effort; partial failures land in `Snapshot.Errors`. Includes:
  - `/proc/meminfo`, `/proc/loadavg`, `/proc/pressure/{memory,cpu,io}`
  - User-slice cgroup memory state
  - Top-N PIDs by RSize (post-IsLeader filter)
  - **Per-PID forensic enrichment** of top-N: `/proc/<pid>/cmdline` (full argv), `/proc/<pid>/status` (PPID, UID, VmRSS/HWM/Peak), `/proc/<pid>/cgroup`, `/proc/<pid>/oom_score{,_adj}`, `/proc/<ppid>/cmdline`
  - Kernel OOM dmesg tail (filtered)
  - `journalctl -u … -n 200` tail
- **Report:** `internal/report/markdown.go`. Atomic write (temp + rename). Filename encodes timestamp + severity for fast triage.
- **Logging:** `internal/logx/logx.go` — slog text or json.
- **Deployer:** `scripts/install-and-verify.sh`. Auto-remediates broken installed config; clears restart-throttle; pre-validates with `-dry-run` before asking systemd to start.
- **Diagnose bundler:** `scripts/diagnose.sh`. 16 sections, single log file at `/tmp/oomwatch-diagnose-<ts>.log`. Run via `make oomwatch-diagnose`.

## Constraints you MUST observe

- **stdlib only.** No `go get` of third-party deps. JSON config (not YAML/TOML).
- **`-buildvcs=false`** on every `go build` (Makefile + script + `GOFLAGS` in challenges/lib.sh). Cross-UID-mount safety; zero functional cost.
- **atop is mandatory** at runtime. Do not add silent /proc fallbacks.
- **Atomic writes** for any artifact in `report_dir`.
- **No `t.Skip`, no `|| true`** swallowing exit codes in tests or Challenges.
- **`chal_assert "...$content..."` is dangerous** for content captured from external sources (markdown reports, journal, command output). The caller's outer double-quotes re-evaluate backticks inside the content as command substitution; this caused a real fork-bomb in `challenge-real-pressure.sh` on 2026-04-30. Use direct inline tests (`if grep -qF "$needle" "$file"; then chal_ok …; else chal_fail …; fi`) or the safer `chal_assert_var <name> nonempty <msg>` helper that uses indirect expansion `${!name}`.
- **systemd unit hardening trade-offs.** Do NOT re-enable `RestrictNamespaces=yes`, `SystemCallFilter`, `CapabilityBoundingSet`, or `SystemCallArchitectures=native` without testing on the target host. They SIGKILL atop with empty stderr (`atop exit -1: `). Comment in the unit file names the symptom.
- **Submodule Constitution** (`Constitution.md` here) governs additions; do not weaken it.

## Workflows

### Adding a new metric / threshold

1. Add the typed struct field (or new struct) in `internal/atop/parser.go` and update the parser. Append at the end for fixture compatibility.
2. Update `parser_test.go` to assert the field on the existing fixture, or add a new fixture under `internal/atop/testdata/`.
3. Add the threshold(s) in `internal/config/config.go` (`Defaults`, `ApplyDefaults`, `Validate`).
4. Add the evaluation in `internal/monitor/threshold.go`; add cases in `threshold_test.go`.
5. Add a row in `internal/report/markdown.go` so reports surface the new value.
6. Add a Challenge (`../challenges/challenge-<metric>.sh`) and add it to `run-all.sh`.
7. Run the full suite. Run the mutation audit on the new code.
8. Update the manual (`../manuals/oom-watch-manual.md`) "Configuration" table and "Anatomy of a report" section.
9. Update the runbook (`../manuals/oom-watch-runbook.md`) if the new metric introduces a new failure mode worth documenting.
10. Re-render docs (`bash ../build-docs.sh`).

### Adding a new forensic field to per-PID detail

1. Read the relevant `/proc/<pid>/*` file in `internal/snapshot/snapshot.go` `enrichProcess()`.
2. Add the field to `ProcessDetail` struct.
3. Render the field in `internal/report/markdown.go` `writeProcessDetails()`.
4. Update `TestEnrichProcess` in `snapshot_test.go` with realistic fake-/proc content and assert the field round-trips.
5. Update `challenge-real-pressure.sh` to assert the new field appears in the report (use `grep -qF` against a sandbox-written file, NOT `chal_assert "...$content..."`).
6. Update manual ("Anatomy of a report") and architecture doc (rationale) and re-render.

### Changing the systemd unit

1. Edit `oom-watch/systemd/oom-watch.service`.
2. Verify in isolation:
   ```bash
   cp oom-watch/systemd/oom-watch.service /tmp/test.service
   systemd-analyze verify /tmp/test.service
   ```
   No `Unknown key` or `Failed to parse` for `oom-watch-test.service`.
3. Test on the target systemd version. systemd 258 (ALT 11) is the verified baseline.
4. After install, watch `journalctl -u oom-watch.service` for `atop sample failed: atop exit -1` — that's the signal a sandbox directive blocked atop. Refer to `../manuals/oom-watch-runbook.md` §5.

### Changing the deployer or diagnose script

1. Edit `oom-watch/scripts/{install-and-verify,diagnose}.sh`.
2. `bash -n` syntax-check.
3. Test under both EUID 0 (root via `su -`) and EUID 1000 (sudo path). The `$(SUDO)` variable in the Makefile and the `exec sudo bash …` re-exec pattern in install-and-verify.sh must continue to work in both.
4. Update deployment-guide and runbook if the script's behaviour or flag set changed.

## Verified production target

ALT Linux 11 "Salvia" (Sisyphus branch), kernel 6.12.61-6.12-alt1, systemd 258, atop 2.12.1, x86_64. Field-validated end-to-end including:

- Cross-UID mount build (repo owned by UID 1000, deployer run as root)
- systemd 258 directive forms (StartLimit* in `[Unit]`, ProtectControlGroups=yes)
- Auto-remediation of `_comment`-bearing example config
- Sandbox compatibility with atop 2.12.1
- 6 GiB real memory pressure → WARN report on disk with full forensic detail

Do NOT regress these — the runbook documents each scenario and the Challenge that locks it in.
