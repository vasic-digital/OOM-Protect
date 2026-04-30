# oom-watch

A small Go daemon that uses [atop](https://github.com/Atoptool/atop) to detect imminent system overload and write a detailed forensic Markdown report **before** the system actually breaks.

It is the third leg of OOM-Protect, alongside `oom-hardening.sh` (the umbrella) and `oom-runner.sh` (the per-leaf cgroup bound).

## Why

After the 2026-04-28 user-manager OOM kill (see `../reports/Crash_Report.md`), we wanted *evidence* of what was running in the seconds before the crash — not after, when the kernel had already killed everything. atop logs are post-hoc; oom-watch writes Markdown reports while the system is still alive but heading off the cliff.

## Status

- **Tests:** real, anti-bluff (see `Constitution.md` Article I). `go test ./...` and `bash ../challenges/run-all.sh` are part of the definition of done.
- **Dependencies:** Go 1.22+ stdlib only. atop must be installed on the host at runtime.
- **Constitution:** the project root `Constitution.md` applies; this submodule has its own `Constitution.md`, `CLAUDE.md`, and `AGENTS.md` reiterating it.

## Build and test

```bash
make oomwatch-build
make oomwatch-test
make oomwatch-challenges
```

Or directly:

```bash
cd oom-watch
go build -o oomwatch ./cmd/oomwatch
go test -count=1 ./...
```

## Quick start

```bash
# 1. Install atop on the host (ALT: apt-get install atop, RHEL: dnf install atop, Debian/Ubuntu: apt install atop).
# 2. Validate the config:
./oomwatch -config config/oom-watch.example.json -dry-run
# 3. Take a one-shot diagnostic report:
sudo ./oomwatch -config config/oom-watch.example.json -one-shot
# 4. Install the systemd unit and start as a service (see Manual).
```

See `../manuals/oom-watch-manual.md` (rendered to HTML/PDF via `make docs`) for installation, troubleshooting, threshold tuning, and integration with `oom-hardening.sh`.

## Layout

```
oom-watch/
├── cmd/oomwatch/main.go     entry point + flag parsing
├── internal/atop/           atop -PALL parser + runner
├── internal/config/         JSON config loader (zero external deps)
├── internal/monitor/        threshold engine + main loop
├── internal/snapshot/       /proc + cgroup + journal capture
├── internal/report/         Markdown report writer
├── internal/logx/           tiny slog wrapper
├── systemd/                 oom-watch.service unit
├── config/                  example config
├── Constitution.md          submodule charter (anti-bluff)
├── CLAUDE.md                context for Claude Code
└── AGENTS.md                context for AI agents
```

## Resources used

This daemon was built consulting:

- [atop official repository](https://github.com/Atoptool/atop) — parseable output format reference.
- [atop interactive cheatsheet (PDF)](https://www.atoptool.nl/download/ATOP-cheatsheet-keys.pdf) — for cross-checking key sequences when running atop interactively for triage.
- [atoptool.nl](https://www.atoptool.nl/) — official site.
- [bytedance/netatop-bpf](https://github.com/bytedance/netatop-bpf) — eBPF-based per-process network stats (PRN label) — future integration target.
- [pizhenwei/atophttpd](https://github.com/pizhenwei/atophttpd) — atop served over HTTP — useful pattern if we ever want to expose oom-watch reports remotely.
- [atopsar-plot](https://codeberg.org/mgellner/atopsar-plot) — retrospective plotting from atop logs; complements oom-watch's incident-time reports.
