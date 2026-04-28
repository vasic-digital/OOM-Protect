#!/usr/bin/env bash
# One-shot installer for the OOM hardening drop-ins.
# Reads files from $(dirname "$0")/etc and copies them under /etc, then
# reloads systemd, enables systemd-oomd, applies sysctls, and prints a
# verification summary.
#
# Safe to re-run. Each step is idempotent. Nothing is deleted.

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root. Try: sudo $0" >&2
    exit 1
fi

SRC="$(cd "$(dirname "$0")" && pwd)/etc"
if [[ ! -d "$SRC" ]]; then
    echo "Cannot find staging tree at $SRC" >&2
    exit 1
fi

ts="$(date +%Y%m%d-%H%M%S)"
backup_root="/root/oom-hardening-backup-$ts"
mkdir -p "$backup_root"

echo "==> Staging source: $SRC"
echo "==> Backups (only of overwritten files) will go to: $backup_root"
echo

install_file() {
    local rel="$1"          # relative path under etc/, e.g. systemd/oomd.conf.d/50-defaults.conf
    local src="$SRC/$rel"
    local dst="/etc/$rel"

    if [[ ! -f "$src" ]]; then
        echo "  SKIP (no source): $rel"
        return
    fi

    install -d -m 755 "$(dirname "$dst")"

    if [[ -f "$dst" ]]; then
        if cmp -s "$src" "$dst"; then
            echo "  OK   (already identical): $dst"
            return
        fi
        local bdst="$backup_root/$rel"
        install -d -m 700 "$(dirname "$bdst")"
        cp -a "$dst" "$bdst"
        echo "  BAK  $dst -> $bdst"
    fi

    install -m 644 "$src" "$dst"
    echo "  COPY $src -> $dst"
}

echo "== 1. Copying drop-ins =="
install_file systemd/oomd.conf.d/50-defaults.conf
install_file systemd/system/user-.slice.d/50-oomd.conf
install_file systemd/system/user-.slice.d/50-memory.conf
install_file systemd/logind.conf.d/10-no-poweroff.conf
install_file systemd/coredump.conf.d/50-keep.conf
install_file sysctl.d/99-mem.conf
echo

echo "== 2. Reloading systemd =="
systemctl daemon-reload
echo "  systemd reloaded."
echo

echo "== 3. Enabling systemd-oomd =="
if systemctl list-unit-files systemd-oomd.service >/dev/null 2>&1; then
    systemctl enable --now systemd-oomd.socket || true
    systemctl enable --now systemd-oomd.service
    echo "  systemd-oomd enabled and started."
else
    echo "  WARN: systemd-oomd.service not found in unit files."
    echo "        On ALT, install with: apt-get install systemd-oomd-defaults  (package name may differ)"
fi
echo

echo "== 4. Applying live cgroup limits to running user-1000.slice =="
# Apply now so you don't need to relog. Persistent values come from the drop-in.
if systemctl is-active user-1000.slice >/dev/null 2>&1; then
    systemctl set-property user-1000.slice \
        MemoryAccounting=yes \
        MemoryHigh=48G \
        MemoryMax=56G \
        MemorySwapMax=8G || true
    echo "  Live limits applied."
else
    echo "  user-1000.slice not active; limits will take effect at next login."
fi
echo

echo "== 5. Restarting systemd-logind (will end your GDM session if applicable) =="
echo "  Skipping automatic restart of systemd-logind to avoid kicking you out."
echo "  Run manually when ready:  sudo systemctl restart systemd-logind"
echo

echo "== 6. Restarting systemd-journald (for coredump.conf changes) =="
systemctl restart systemd-journald || true
echo

echo "== 7. Applying sysctls =="
sysctl --system | grep -E "swappiness|min_free|overcommit_(memory|ratio)|vfs_cache|dirty_(background_)?ratio" || true
echo

echo "==================== VERIFICATION ===================="
echo
echo "[systemd-oomd state]"
systemctl is-active systemd-oomd.service || true
echo
echo "[oomctl monitored cgroups]"
oomctl 2>/dev/null | sed -n '1,40p' || echo "(oomctl not available)"
echo
echo "[user-1000.slice limits]"
systemctl show user-1000.slice -p MemoryMax,MemoryHigh,MemorySwapMax,MemoryAccounting 2>/dev/null
echo
echo "[active sysctls]"
sysctl vm.swappiness vm.min_free_kbytes vm.overcommit_memory \
       vm.overcommit_ratio vm.vfs_cache_pressure \
       vm.dirty_background_ratio vm.dirty_ratio 2>/dev/null
echo
echo "[logind power-key handling]"
busctl get-property org.freedesktop.login1 /org/freedesktop/login1 \
       org.freedesktop.login1.Manager HandlePowerKey 2>/dev/null \
       || echo "(needs systemd-logind restart to read updated value)"
echo
echo "Done. If anything looks off, configs were backed up to: $backup_root"
