# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Constitution (read first)

The repository's authoritative charter is `Constitution.md` at the root. **Read it before doing anything.** All contributors — humans and agents — are bound by it. The most load-bearing rule is reproduced inline below so it cannot be missed:

### Article I — Anti-Bluff Testing (Non-Negotiable)

> **A passing test or Challenge MUST prove that the product really works. A test that passes while the product is broken is a defect more serious than the original bug.**

When you write tests or Challenges:

1. **Exercise the real artifact.** Run the actual built binary against real inputs. Stub only true external boundaries (kernel, network), never the code under test.
2. **Assert observable outcomes.** Verify files exist on disk with required content, exit codes, subprocess output, systemd unit states. "I called the function" is not an assertion.
3. **Fail loudly when the feature is missing.** Every test must be one whose green status genuinely depends on the production code being correct. Do mutation spot-checks: temporarily break the code and confirm the test goes red. If it doesn't, that test is a bluff and must be rewritten.
4. **No `t.Skip`, no `pending`, no `|| true`, no `--no-fail`, no swallowed exit codes.** A test that cannot run is not a test.
5. **Challenges must reproduce the real failure mode.** A memory-protection Challenge must actually allocate enough memory to trip the threshold. Synthetic shortcuts that bypass the hazard are forbidden.
6. **Every public feature has at least one Challenge.** No feature ships without an end-to-end Challenge a user can reproduce by reading the script.
7. **The suite is part of the definition of done.** A change is not complete until `make test` and `make challenges` pass on a clean checkout.

Before declaring any task done, run the relevant tests and Challenges and report the actual outcome. The full Constitution covers other articles (idempotency, doc parity, multi-upstream discipline, submodule rules) — consult `Constitution.md` directly.

## What this project is

A pure-Bash systems-tooling toolkit for ALT Linux / systemd workstations. Born from a 2026-04-28 incident on host `nezha` where the kernel OOM-killer SIGKILL'd the systemd user-manager and destroyed the entire user session. There is **no application code, no runtime, no package** — the deliverables are four shell scripts, a Makefile, and Markdown docs that render to HTML/PDF.

The toolkit ships two complementary layers, and they are intended to be used together:

1. **`oom-hardening.sh`** — the umbrella. Writes drop-ins under `/etc/systemd/...d/` and `/etc/sysctl.d/` to bound `user-.slice`, enable `systemd-oomd`, harden logind, and tune VM sysctls. Runs as root.
2. **`oom-runner.sh`** — the per-leaf bound. Wraps any command in a transient `systemd-run --user` scope or service so a runaway dies in isolation inside the umbrella. Runs as the user (no sudo).

Reading either script in isolation will be misleading — they are designed as a pair and the architecture only makes sense together.

## Common commands

The Makefile is the canonical entry point. Run `make help` (the default target) for the live list. Most-used:

```bash
make dry-run                    # preview hardening changes (no sudo, no writes)
make install                    # apply hardening (calls sudo internally)
make verify                     # health check; exit 0=green, 1=warn, 2=fail
make verify-stress              # verify + 16G stress-ng test
make uninstall                  # remove only drop-ins this toolkit wrote
make rollback BACKUP=/root/oom-hardening-backup-YYYYMMDD-HHMMSS

make docs                       # rebuild all .html + .pdf from .md
make docs-clean                 # remove generated HTML/PDF
make package                    # bundle into oom-toolkit-<ts>.tar.gz

make presets                    # list oom-runner presets
make list                       # list active oom-runner units
make status UNIT=<name>         # one unit's live mem usage
make logs UNIT=<name>           # journalctl -fu for the unit
make kill UNIT=<name>           # stop one unit
make clean-units                # stop ALL oom-runner units

make test                       # quick functional smoke (256M scope echoes "OK")
make check                      # bash -n + shellcheck (if installed)
make all                        # docs + verify (typical CI)
```

`verify.sh --json` produces machine-readable output for CI.

## Architecture: how the two layers interact

### `oom-hardening.sh` (sets the umbrella)

Idempotent root-only installer. Six managed files declared in the `MANAGED_FILES` array near the top of the script — that array is the single source of truth for what gets written. Each file's content is in a `content_for()` heredoc keyed by the same path.

Modes (`MODE` variable, set from argv): `apply` (default), `dry-run`, `rollback`, `uninstall`. Backups go to `/root/oom-hardening-backup-<TS>/` before any overwrite. The `on_err` ERR trap prints the rollback command on partial failure.

The script deliberately does **not** restart `systemd-logind` (would end the GUI session), does not touch `/etc/fstab`/swap/GRUB, and does not install packages — if `systemd-oomd` is missing it tells you the package candidates and stops.

### `oom-runner.sh` (sets per-leaf bounds)

Uses `systemd-run --user` to create transient `.scope` (foreground) or `.service` (with `--detach`) units, all named with prefix `oomrun-`. The `PRESETS` associative array (`tiny`, `small`, `claude`, `mcp`, `build`, `browser`, etc.) is the central knob — format is `MemoryMax|MemoryHigh|MemorySwapMax|TasksMax|CPUQuotaPct|IOWeight`. Empty fields mean "no limit".

Subcommand dispatch lives in `main()` at the bottom (case on `${1:-}`): `presets`, `list`, `kill`, `status`, `logs`, `clean`, `run`. A bare `--` or any leading flag falls through to `cmd_run`. A non-flag first word that resolves as an executable also falls through to `cmd_run -- "$@"` so `oom-runner echo hi` works.

Hard floor `MIN_MEM_MAX_BYTES=128 MiB` — refuses anything smaller because it would cripple any real workload. `MemoryHigh` is auto-clamped to ≤ `MemoryMax` with a warning.

The `preflight()` function recovers `XDG_RUNTIME_DIR` for SSH-without-lingering and warns (not errors) if `MemoryAccounting=no` on `user-<uid>.slice`, since the limits still work in scopes/services even without slice-level accounting.

### `verify.sh` (the truth oracle)

Independent of the install path. Each `check_*` function records into `ROWS` via `record green|yellow|red`. Exit code is derived from counters at the end (0/1/2). Tolerates non-zero exits (`set -Eu` only — no `-e`/`-o pipefail`) so a failing `oomctl` or `grep` becomes a yellow/red status, not a script abort. The `--stress` flag adds a live `stress-ng --vm 4 --vm-bytes 16G` test.

The full check list is documented in `README.md` under "What `make verify` actually checks" — re-read that table when adding or modifying checks.

### `build-docs.sh`

Pandoc-based renderer. Inputs are discovered dynamically (top-level + `manuals/` + `reports/` `.md` files). Outputs `.html` (CSS embedded from `assets/style.css`) and `.pdf` via WeasyPrint preferred, falling back to `chromium --headless --print-to-pdf`. Idempotent.

### Cross-cutting conventions

- All four scripts prepend `/usr/sbin:/sbin:/usr/bin:/bin` to `PATH` because ALT Linux / RHEL keep `sysctl`, `busctl`, `oomctl`, `lsof` in `/sbin` or `/usr/sbin` and `sudo`'s `secure_path` may strip those.
- Color helpers (`C_RED`, `C_GRN`, ...) are gated on `[[ -t 1 ]]` / `[[ -t 2 ]]` so output stays clean in pipes and CI.
- `set -Eeuo pipefail` everywhere except `verify.sh`, which uses only `set -Eu` for the reason above.
- Log helpers (`log` / `ok` / `warn` / `err` / `die` / `hdr`) are duplicated per-script with slightly different prefixes — do not try to factor them into a shared lib without good reason; each script must remain standalone-runnable.

### `system-config/` (informational staging tree)

Mirrors `/etc/` so a reviewer can see the drop-ins before installing. `system-config/install.sh` is an older standalone installer kept for review purposes — the canonical installer is `oom-hardening.sh` at the repo root. Keep `system-config/etc/` and the `content_for()` heredocs in `oom-hardening.sh` in sync when changing drop-ins.

### `Upstreams/`

One-line shell scripts that just `export UPSTREAMABLE_REPOSITORY=...` for each remote (GitHub, GitLab, GitFlic, GitVerse). Used by external tooling for multi-remote pushes — not consumed by anything in this repo. Don't edit unless the user is moving repos.

## Conventions for editing

- **Idempotency is non-negotiable.** Every install/apply path must be safe to re-run with no side effects. New checks/files must follow this.
- **No-restart guarantees.** Never add code paths that restart `systemd-logind`, touch `/etc/fstab`, swap, or GRUB — those can prevent the next boot or kill the GUI session, which is exactly what this toolkit exists to prevent.
- **Backup before overwrite.** Any new file written under `/etc` must be added to `MANAGED_FILES` so the existing backup-then-write logic covers it.
- **Pair the two layers.** When changing a drop-in in `oom-hardening.sh`, check whether the corresponding `verify.sh` check needs updating. When changing a preset in `oom-runner.sh`, regenerate docs (`make docs`) so the manuals stay current.
- **Hardware ceiling.** This is a Tiger Lake laptop capped at 64 GB RAM by the IMC — see `reports/Crash_Report.md` §6. Defaults assume that ceiling; a fork to a different host should re-tune `user-.slice` `MemoryHigh` / `MemoryMax`.

## Documentation

The post-mortem at `reports/Crash_Report.md` is the load-bearing context for every design decision. The two component manuals (`manuals/oom-hardening-manual.md`, `manuals/oom-runner-manual.md`) document every option exhaustively — consult them before adding new flags.
