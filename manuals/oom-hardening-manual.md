---
title: oom-hardening — User Manual
subtitle: Workstation OOM hardening for systemd Linux
author: System post-mortem 2026-04-28
date: 2026-04-28
---

# Overview

`oom-hardening.sh` is a one-shot, idempotent installer that applies
**workstation-grade memory-pressure protection** to a systemd Linux host.
It exists because of the 2026-04-28 incident on host `nezha`, where a
60.6 GiB user-slice on a 62 GiB machine caused the kernel OOM killer to
SIGKILL the systemd user-manager itself, taking down ~60 active processes
(Claude Code, Android build, MCP servers, IDE, browsers, terminals) and
ultimately rebooting the laptop. See `Crash_Report.md` for the full
post-mortem.

The script:

1. Enables `systemd-oomd` (proactive userspace OOM daemon).
2. Sets hard cgroup memory limits on `user-.slice` so the user-manager
   can never again be the OOM victim.
3. Applies VM tuning (`vm.swappiness`, `min_free_kbytes`, dirty ratios).
4. Neutralises accidental short-press power-off via `systemd-logind`.
5. Keeps coredumps so the next incident leaves real evidence.

It does **not** touch fstab, swap, GRUB, or anything that could prevent
the next boot. Every change is reversible.

---

# Quick Start

```bash
# 1. Read what would change without changing anything
bash ~/Downloads/oom-hardening.sh --dry-run

# 2. Apply (interactive — prompts y/N before making changes)
sudo bash ~/Downloads/oom-hardening.sh

# 3. (Optional) Stress-test the protection
journalctl -fu systemd-oomd &
stress-ng --vm 4 --vm-bytes 16G --vm-keep --timeout 60s
# Expected: stress-ng dies, your shell/IDE/tmux/browsers SURVIVE.
```

---

# What the script installs

| File | Effect |
|---|---|
| `/etc/systemd/oomd.conf.d/50-defaults.conf` | Global `systemd-oomd` thresholds (kill on swap > 80% or sustained memory pressure > 50% for 20 s) |
| `/etc/systemd/system/user-.slice.d/50-oomd.conf` | Tells `systemd-oomd` to manage all user slices |
| `/etc/systemd/system/user-.slice.d/50-memory.conf` | Cgroup ceiling on every user slice: `MemoryHigh=48G`, `MemoryMax=56G`, `MemorySwapMax=8G` |
| `/etc/systemd/logind.conf.d/10-no-poweroff.conf` | Short power-button tap ignored; long-press still powers off |
| `/etc/systemd/coredump.conf.d/50-keep.conf` | Coredump retention policy (10 GiB cap, keep 20 GiB free) |
| `/etc/sysctl.d/99-mem.conf` | VM tuning (lower swappiness, larger `min_free_kbytes`, smaller dirty queues) |

The script also performs runtime side-effects:

- `systemctl daemon-reload`
- `systemctl enable --now systemd-oomd.{socket,service}`
- `systemctl set-property user-1000.slice MemoryMax=… MemoryHigh=… MemorySwapMax=…` (live, no relogin needed)
- `sysctl --system`
- `systemctl restart systemd-journald` (for coredump.conf reload)

It does **not** restart `systemd-logind` (that ends your GUI session).
After applying, run that yourself when convenient:

```bash
sudo systemctl restart systemd-logind
```

---

# Command Reference

## Modes

| Form | Purpose |
|---|---|
| `sudo bash oom-hardening.sh` | Apply (interactive) |
| `sudo bash oom-hardening.sh --yes` | Apply (non-interactive) |
| `bash oom-hardening.sh --dry-run` | Preview only — no root needed, changes nothing |
| `sudo bash oom-hardening.sh --rollback DIR` | Restore from a previous backup |
| `sudo bash oom-hardening.sh --uninstall` | Remove drop-ins this script wrote |
| `bash oom-hardening.sh --help` | Show usage |

## Options

| Option | Effect |
|---|---|
| `--dry-run` | Print exactly what would change. Diff-mode for any pre-existing files. Logs to `/tmp/oom-hardening-dryrun.log`. |
| `--yes`, `-y` | Skip confirmation prompt. Required if stdin is not a TTY (e.g. piping the script). |
| `--rollback DIR` | Restore `/etc` files from `/root/oom-hardening-backup-<TS>/`. Reads the backup’s `MANIFEST.txt`. |
| `--uninstall` | Remove only files whose contents are bit-identical to ours. Manually edited copies are skipped. |

## Pre-flight checks

The script verifies all of these before touching anything:

| Check | Pass criterion |
|---|---|
| Privileges | Running as root (except `--dry-run`) |
| systemd version | ≥ 248 (warn otherwise — `ManagedOOM*` may be missing) |
| Kernel version | ≥ 5.15 (warn otherwise — PSI / cgroup v2 may be incomplete) |
| cgroup hierarchy | cgroup v2 unified at `/sys/fs/cgroup` |
| PSI | `/proc/pressure/memory` readable |
| RAM | warn if < 16 GiB (the default 48G/56G limits make no sense for tiny machines) |
| `systemd-oomd.service` | unit file present (warn + skip enable step if missing) |
| `user-1000.slice` | active (otherwise live limits are deferred to next login) |
| Free space on `/` | ≥ 100 MiB (for backups) |

---

# Tuning the limits

Edit the script before running, or edit `/etc/systemd/system/user-.slice.d/50-memory.conf` after, and re-run:

```ini
[Slice]
MemoryAccounting=yes
MemoryHigh=48G    # soft throttle — kernel reclaims aggressively above
MemoryMax=56G     # hard ceiling — anything over gets OOM-killed inside the slice
MemorySwapMax=8G  # cap swap to prevent thrashing
TasksMax=infinity
```

**Sizing rule of thumb:** leave at least **6–8 GiB** headroom for the kernel,
system slice, and buffer/cache.

| Total RAM | Suggested `MemoryHigh` | Suggested `MemoryMax` |
|---|---|---|
| 16 GiB | 10G | 12G |
| 32 GiB | 22G | 26G |
| 64 GiB | **48G** | **56G** *(default)* |
| 128 GiB | 104G | 116G |

Apply changes without rebooting:

```bash
sudo systemctl daemon-reload
sudo systemctl set-property user-1000.slice MemoryHigh=48G MemoryMax=56G MemorySwapMax=8G
```

---

# Verification

```bash
# OOM daemon is up and watching
systemctl is-active systemd-oomd.service     # → active
oomctl                                        # shows monitored cgroups + thresholds

# Live cgroup limits applied
systemctl show user-1000.slice -p MemoryMax,MemoryHigh,MemorySwapMax,MemoryAccounting

# Active sysctls
sysctl vm.swappiness vm.min_free_kbytes vm.overcommit_memory \
       vm.overcommit_ratio vm.vfs_cache_pressure \
       vm.dirty_background_ratio vm.dirty_ratio

# Pressure (run during heavy work)
cat /proc/pressure/memory
cat /proc/pressure/cpu
cat /proc/pressure/io

# Logind power-key handling
busctl get-property org.freedesktop.login1 /org/freedesktop/login1 \
       org.freedesktop.login1.Manager HandlePowerKey   # → "ignore"
```

## Stress test

This **must** kill `stress-ng` and leave your shell/IDE/tmux alive. If your whole session dies again, re-investigate before trusting the config:

```bash
# Watch in one terminal
journalctl -fu systemd-oomd

# Run in another
stress-ng --vm 4 --vm-bytes 16G --vm-keep --timeout 60s
```

Expected log line:

```
systemd-oomd[…]: Killed /user.slice/user-1000.slice/…/oomrun-stress-….scope due to memory pressure …
```

---

# Rollback & Uninstall

## Rollback (best for "I want everything back exactly")

The installer writes every overwritten file to `/root/oom-hardening-backup-<TS>/` and includes a `MANIFEST.txt`. To restore:

```bash
sudo bash ~/Downloads/oom-hardening.sh --rollback /root/oom-hardening-backup-20260428-194355
```

This will:

- Restore each managed file from its backup (or remove it if it didn't exist before)
- `systemctl daemon-reload`
- Print follow-up commands for `systemd-oomd` / sysctls

## Uninstall (best for "I just want this script's stuff gone")

```bash
sudo bash ~/Downloads/oom-hardening.sh --uninstall
```

Removes only files whose contents match exactly what the script wrote. Hand-edited or unrelated files are left alone.

## Manual reversion

```bash
# Disable systemd-oomd
sudo systemctl disable --now systemd-oomd.service systemd-oomd.socket

# Drop a single drop-in
sudo rm /etc/systemd/system/user-.slice.d/50-memory.conf
sudo systemctl daemon-reload

# Reset live limits on the running slice
sudo systemctl set-property user-1000.slice MemoryMax=infinity MemoryHigh=infinity MemorySwapMax=infinity
```

---

# Troubleshooting

## "systemd-oomd.service NOT found"

`systemd-oomd` is packaged separately on some distros. The drop-ins still install; you just need to install the daemon and re-run:

```bash
# ALT Linux / Debian / Ubuntu
sudo apt-get install systemd-oomd-defaults

# Or
sudo apt install systemd-oomd

# Fedora-like
sudo dnf install systemd-oomd-defaults

# Then
sudo bash ~/Downloads/oom-hardening.sh --yes
```

## "MemoryAccounting=no on user-X.slice" warning from oom-runner

You ran `oom-runner.sh` before applying this script, or skipped the slice drop-in. Re-run `oom-hardening.sh`. Verify:

```bash
systemctl show -p MemoryAccounting --value "user-$(id -u).slice"   # → yes
```

## "stress-ng survived the 16G alloc"

Causes in order of likelihood:

1. The script wasn't applied (or was rolled back). Verify `oomctl`.
2. `MemoryAccounting=no` somewhere in the parent slice chain. Apply this script.
3. Cgroup v2 not unified (rare on modern kernels). Run `mount | grep cgroup`.
4. `systemd-oomd` is installed but socket/service is masked: `systemctl unmask systemd-oomd.{socket,service}`.

## "I lost a tmux session after applying"

The drop-ins themselves don't kill any session. But if you applied the script while running a workload that was already over `MemoryMax=56G`, the kernel may immediately enforce the ceiling. Trim the workload or relax the limit, then re-apply.

## "Sysctls keep being overridden by something else"

Check load order:

```bash
sudo systemd-sysctl --cat-config | grep -E "vm\.(swappiness|dirty|overcommit)"
```

Files in `/usr/lib/sysctl.d/`, `/run/sysctl.d/`, and `/etc/sysctl.d/` are processed in lexicographic order. The script writes `99-mem.conf` so it runs late and wins.

---

# FAQ

**Q. Why 48G/56G specifically?**
The host has 62 GiB. Leaving ~6 GiB headroom for kernel + system slice + page cache is the smallest safe margin. 48 GiB soft / 56 GiB hard gives you 8 GiB of "kernel reclaims aggressively but you're not killed yet" zone before the wall.

**Q. Why not just buy more RAM?**
The CPU on this host (i7-1165G7, Tiger Lake) is hard-capped at 64 GiB by the integrated memory controller. Even 64 GiB DDR4 SODIMMs (which exist) will not be addressed beyond 64 GiB total. See `Crash_Report.md` §6.

**Q. Will this slow down builds?**
No. `MemoryHigh` only kicks in when you exceed 48 GiB; below that the kernel does its normal thing. `vm.swappiness=10` actually *speeds up* memory-pressure scenarios because the kernel won't push hot pages to swap prematurely.

**Q. Can I run this on a server?**
Yes, but tune `MemoryMax` first — the defaults are workstation-sized. Servers should typically reserve 10–15% of RAM for kernel/buffers, not the fixed 8 GiB this script uses.

**Q. Does this conflict with `earlyoom` / `nohang` / other OOM daemons?**
Yes — they all watch PSI. Pick one. Disable the others before enabling `systemd-oomd`:

```bash
sudo systemctl disable --now earlyoom.service nohang.service 2>/dev/null
```

**Q. The script wrote backups to `/root/`. Can I move them?**
Yes — the rollback mode reads the directory you point it at. Move the directory anywhere. Just keep `MANIFEST.txt` next to the backed-up files.

**Q. Why does the script not restart `systemd-logind` automatically?**
Restarting it ends your active GUI session, including any unsaved work in graphical apps. The script tells you to do it manually when ready. Logind restart is only needed for the `HandlePowerKey=ignore` change to take effect; the cgroup and oomd changes are applied immediately without it.

---

# Companion Tools

- **`oom-runner.sh`** — wraps individual workloads (Claude, MCP servers, builds, browsers) in their own bounded scopes/services *inside* the umbrella set by this hardening script. See `oom-runner-manual.md`.
- **`Crash_Report.md`** — full post-mortem of the 2026-04-28 incident.

---

# Appendix A — Full file contents

## `/etc/systemd/oomd.conf.d/50-defaults.conf`

```ini
[OOM]
SwapUsedLimit=80%
DefaultMemoryPressureLimit=50%
DefaultMemoryPressureDurationSec=20s
```

## `/etc/systemd/system/user-.slice.d/50-oomd.conf`

```ini
[Slice]
ManagedOOMSwap=kill
ManagedOOMMemoryPressure=kill
ManagedOOMMemoryPressureLimit=50%
ManagedOOMMemoryPressureDurationSec=20s
```

## `/etc/systemd/system/user-.slice.d/50-memory.conf`

```ini
[Slice]
MemoryAccounting=yes
MemoryHigh=48G
MemoryMax=56G
MemorySwapMax=8G
TasksMax=infinity
```

## `/etc/systemd/logind.conf.d/10-no-poweroff.conf`

```ini
[Login]
HandlePowerKey=ignore
HandlePowerKeyLongPress=poweroff
```

## `/etc/systemd/coredump.conf.d/50-keep.conf`

```ini
[Coredump]
Storage=external
Compress=yes
ProcessSizeMax=8G
ExternalSizeMax=8G
MaxUse=10G
KeepFree=20G
```

## `/etc/sysctl.d/99-mem.conf`

```ini
vm.swappiness = 10
vm.min_free_kbytes = 262144
vm.overcommit_memory = 0
vm.overcommit_ratio = 80
vm.vfs_cache_pressure = 50
vm.dirty_background_ratio = 5
vm.dirty_ratio = 15
```

---

# Appendix B — Exit codes

| Code | Meaning |
|---|---|
| 0 | Success |
| 1 | User error (bad arg, missing dir, refused confirmation) |
| Other | Step-specific failure — see `/var/log/oom-hardening.log` and check the rollback hint printed by the script |
