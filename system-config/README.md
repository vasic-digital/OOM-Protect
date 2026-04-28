# OOM Hardening Drop-Ins — Stage & Apply

Staging tree mirrors `/etc/` so you can review everything before installing.

## What each file does

| File | Purpose |
|---|---|
| `etc/systemd/oomd.conf.d/50-defaults.conf` | Global `systemd-oomd` thresholds: kill cgroups when swap is >80% used, or when memory PSI exceeds 50% sustained for 20 s. |
| `etc/systemd/system/user-.slice.d/50-oomd.conf` | Tells `systemd-oomd` to *manage* the user slice — kill leaf cgroups (one MCP server, one IDE, one tab process) instead of taking the whole session. |
| `etc/systemd/system/user-.slice.d/50-memory.conf` | Hard cgroup memory ceiling on the user slice: `MemoryHigh=48G`, `MemoryMax=56G`, `MemorySwapMax=8G`. The user manager itself can no longer be the OOM victim. |
| `etc/systemd/logind.conf.d/10-no-poweroff.conf` | A short power-button tap is ignored. Long-press still powers off. Prevents accidental shutdown when GDM is in a broken state. |
| `etc/systemd/coredump.conf.d/50-keep.conf` | Keep coredumps so the next incident leaves real evidence. |
| `etc/sysctl.d/99-mem.conf` | Kernel VM tuning: lower swappiness, larger min_free, smaller dirty queues. |

## Apply

```bash
sudo /home/milosvasic/Downloads/system-config/install.sh
```

The installer is idempotent: re-running is safe. Pre-existing files are backed up to `/root/oom-hardening-backup-<timestamp>/` before being overwritten.

## Roll back

The installer prints the backup path. To roll back any single file:

```bash
sudo cp -a /root/oom-hardening-backup-<timestamp>/<rel-path> /etc/<rel-path>
sudo systemctl daemon-reload
```

To remove a drop-in entirely:

```bash
sudo rm /etc/systemd/system/user-.slice.d/50-memory.conf   # for example
sudo systemctl daemon-reload
sudo systemctl set-property user-1000.slice MemoryMax=infinity MemoryHigh=infinity
```

## Verify after install

```bash
# OOM daemon
systemctl is-active systemd-oomd.service
oomctl

# Live cgroup limits on your slice
systemctl show user-1000.slice -p MemoryMax,MemoryHigh,MemorySwapMax

# sysctls
sysctl vm.swappiness vm.min_free_kbytes vm.overcommit_memory vm.dirty_ratio

# Pressure (run before/after a heavy task)
cat /proc/pressure/memory
cat /proc/pressure/cpu
cat /proc/pressure/io
```

## Stress test (recommended)

This MUST kill `stress-ng` and leave your shell, IDE, and other services alive. If
your whole session dies again, the config is wrong — investigate.

```bash
# In one terminal
journalctl -fu systemd-oomd
# In another
stress-ng --vm 4 --vm-bytes 16G --vm-keep --timeout 60s
```

## What this DOESN'T do

- It does not throttle individual containers — see `Crash_Report.md` §8.3.
- It does not fix thermals (zones at 81-82 °C idle) — see §8.6.
- It does not move the Android build off the laptop, which is the most impactful workload change.
- It does not raise RAM beyond 64 GB. The CPU caps at 64 GB; see Crash_Report.md §6.

## Tunables

If 48 G `MemoryHigh` / 56 G `MemoryMax` is too tight, edit
`etc/systemd/system/user-.slice.d/50-memory.conf` and re-run the installer.
Recommended floors: `MemoryHigh=40G`, `MemoryMax=52G`. Always leave at least 6 GiB
headroom for the kernel + system slice + buffer/cache.
