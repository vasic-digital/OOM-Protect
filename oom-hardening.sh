#!/usr/bin/env bash
# oom-hardening.sh
#
# Safely apply the OOM-hardening + workstation tuning recommended in
# ~/Downloads/Crash_Report.md.
#
# What it does (in order):
#   1. Pre-flight: verifies root, systemd, kernel, RAM, distro.
#   2. Backs up any /etc file we are about to overwrite into a timestamped
#      directory under /root.
#   3. Writes drop-ins for systemd-oomd, the user-.slice cgroup limits,
#      logind power-key behaviour, coredump retention, and VM sysctls.
#   4. Reloads systemd, enables systemd-oomd, applies live cgroup limits to
#      the running user-1000.slice without ending the session, applies
#      sysctls, restarts systemd-journald.
#   5. Prints a verification report.
#
# What it deliberately does NOT do:
#   - Does NOT restart systemd-logind (that ends the GUI session).
#   - Does NOT touch /etc/fstab, swap, GRUB, or anything that could prevent
#     the next boot.
#   - Does NOT install packages. If systemd-oomd is missing, it tells you
#     the package name candidates and stops at that step.
#
# Modes:
#   sudo bash oom-hardening.sh                   # apply
#   sudo bash oom-hardening.sh --dry-run         # preview, change nothing
#   sudo bash oom-hardening.sh --rollback DIR    # restore from backup dir
#   sudo bash oom-hardening.sh --uninstall       # remove all drop-ins we placed
#
# Re-running is safe — every step is idempotent.

set -Eeuo pipefail
IFS=$'\n\t'

# Many distros (ALT Linux, RHEL, others) keep sysctl, busctl, lsof, etc. in
# /sbin or /usr/sbin. sudo's secure_path may strip those. Prepend them so
# every tool resolves regardless of how sudo was configured.
export PATH="/usr/sbin:/sbin:/usr/bin:/bin:${PATH:-}"

# ---------- constants ----------------------------------------------------------

readonly SCRIPT_NAME="oom-hardening"
readonly SCRIPT_VERSION="1.0.0"
LOG_FILE="/var/log/${SCRIPT_NAME}.log"   # mutable: fallback path may rewrite to /tmp
readonly TS="$(date +%Y%m%d-%H%M%S)"
readonly BACKUP_ROOT="/root/${SCRIPT_NAME}-backup-${TS}"
readonly MIN_KERNEL_MAJOR=5
readonly MIN_KERNEL_MINOR=15

# Files we manage. Format: <relative-path-under-/etc>|<mode>
# Content is held in a heredoc indexed by the same key in CONTENT_<sanitized>.
readonly -a MANAGED_FILES=(
    "systemd/oomd.conf.d/50-defaults.conf|0644"
    "systemd/system/user-.slice.d/50-oomd.conf|0644"
    "systemd/system/user-.slice.d/50-memory.conf|0644"
    "systemd/logind.conf.d/10-no-poweroff.conf|0644"
    "systemd/coredump.conf.d/50-keep.conf|0644"
    "sysctl.d/99-mem.conf|0644"
    "security/limits.d/99-nproc-elastic.conf|0644"
)

# ---------- output helpers -----------------------------------------------------

if [[ -t 1 ]]; then
    C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'
    C_BLU=$'\033[34m'; C_DIM=$'\033[2m';  C_RST=$'\033[0m'
else
    C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_DIM=""; C_RST=""
fi

log()  { printf '%s [%s] %s\n' "$(date '+%F %T')" "INFO " "$*" | tee -a "$LOG_FILE" >&2; }
ok()   { printf '%s%s [%s]%s %s\n' "$C_GRN" "$(date '+%F %T')" "OK   " "$C_RST" "$*" | tee -a "$LOG_FILE" >&2; }
warn() { printf '%s%s [%s]%s %s\n' "$C_YEL" "$(date '+%F %T')" "WARN " "$C_RST" "$*" | tee -a "$LOG_FILE" >&2; }
err()  { printf '%s%s [%s]%s %s\n' "$C_RED" "$(date '+%F %T')" "ERROR" "$C_RST" "$*" | tee -a "$LOG_FILE" >&2; }
hdr()  { printf '\n%s== %s ==%s\n' "$C_BLU" "$*" "$C_RST" | tee -a "$LOG_FILE" >&2; }

die()  { err "$*"; exit 1; }

on_err() {
    local rc=$?
    err "Failed at line $1 (exit $rc). See $LOG_FILE."
    if [[ -d "$BACKUP_ROOT" ]] && [[ "${MODE:-apply}" == "apply" ]]; then
        warn "Partial state may exist. Backups (if any) are at: $BACKUP_ROOT"
        warn "Rollback with: sudo $0 --rollback $BACKUP_ROOT"
    fi
    exit "$rc"
}
trap 'on_err $LINENO' ERR

# ---------- embedded config content -------------------------------------------

content_for() {
    case "$1" in
    "systemd/oomd.conf.d/50-defaults.conf")
        cat <<'EOF'
[OOM]
# Elastic: oomd acts only at TRUE exhaustion (swap ~full + sustained-severe PSI),
# never on transient load with RAM free. Was 80% / 50% / 20s.
SwapUsedLimit=90%
DefaultMemoryPressureLimit=90%
DefaultMemoryPressureDurationSec=60s
EOF
        ;;
    "systemd/system/user-.slice.d/50-oomd.conf")
        cat <<'EOF'
[Slice]
ManagedOOMSwap=kill
ManagedOOMMemoryPressure=kill
# Kill only on SUSTAINED (60s) SEVERE (90% PSI) stall — not 50%/20s, which killed
# >3 concurrent agents under normal reclaim. Still enabled as a real-runaway backstop.
ManagedOOMMemoryPressureLimit=90%
ManagedOOMMemoryPressureDurationSec=60s
EOF
        ;;
    "systemd/system/user-.slice.d/50-memory.conf")
        cat <<'EOF'
[Slice]
MemoryAccounting=yes
# Elastic/liquid: use all RAM, throttle/kill only near true exhaustion. Percentages
# adapt to any host (were host-specific 48G/56G/8G for a 62 GiB box).
#   MemoryHigh=90%  soft reclaim only at 90% (48G caused the multi-GB-pgscan "stuck").
#   MemoryMax=95%   hard backstop below full so a runaway can't freeze the box.
#   MemorySwapMax=infinity  swap/zram used elastically instead of OOM-killing (was 8G).
MemoryHigh=90%
MemoryMax=95%
MemorySwapMax=infinity
TasksMax=infinity
EOF
        ;;
    "systemd/logind.conf.d/10-no-poweroff.conf")
        cat <<'EOF'
[Login]
HandlePowerKey=ignore
HandlePowerKeyLongPress=poweroff
EOF
        ;;
    "systemd/coredump.conf.d/50-keep.conf")
        cat <<'EOF'
[Coredump]
Storage=external
Compress=yes
ProcessSizeMax=8G
ExternalSizeMax=8G
MaxUse=10G
KeepFree=20G
EOF
        ;;
    "sysctl.d/99-mem.conf")
        cat <<'EOF'
vm.swappiness = 10
vm.min_free_kbytes = 262144
vm.overcommit_memory = 0
vm.overcommit_ratio = 80
vm.vfs_cache_pressure = 50
vm.dirty_background_ratio = 5
vm.dirty_ratio = 15
EOF
        ;;
    "security/limits.d/99-nproc-elastic.conf")
        cat <<'EOF'
# Raise the per-user process/thread ceiling so many concurrent thread-heavy
# agents (node / Claude Code) never hit "fork: retry: Resource temporarily
# unavailable". Overrides the low distro default (nproc 512/1024). 99- prefix
# makes pam_limits read this LAST so it wins. cgroup TasksMax stays the real
# ceiling (infinity on the user slice); this removes the artificial pam ceiling.
*		soft	nproc	65536
*		hard	nproc	65536
root		soft	nproc	65536
EOF
        ;;
    *)
        die "No embedded content for: $1"
        ;;
    esac
}

# ---------- pre-flight ---------------------------------------------------------

require_root() {
    [[ $EUID -eq 0 ]] || die "Must run as root. Try: sudo bash $0 ${*:-}"
}

preflight() {
    hdr "1. Pre-flight checks"

    # systemd
    command -v systemctl >/dev/null 2>&1 || die "systemctl not found — this script requires systemd."
    local sd_ver
    sd_ver="$(systemctl --version | awk 'NR==1 {print $2}')"
    log "systemd version: $sd_ver"
    if [[ "$sd_ver" -lt 248 ]]; then
        warn "systemd $sd_ver is older than 248. systemd-oomd / ManagedOOM* may not be available."
    fi

    # kernel
    local kver kmaj kmin
    kver="$(uname -r)"
    kmaj="$(echo "$kver" | awk -F. '{print $1}')"
    kmin="$(echo "$kver" | awk -F. '{print $2}')"
    log "Kernel: $kver"
    if (( kmaj < MIN_KERNEL_MAJOR )) || (( kmaj == MIN_KERNEL_MAJOR && kmin < MIN_KERNEL_MINOR )); then
        warn "Kernel < ${MIN_KERNEL_MAJOR}.${MIN_KERNEL_MINOR}; PSI / cgroup v2 may be incomplete."
    fi

    # cgroup v2
    if ! mount | grep -q 'cgroup2 on /sys/fs/cgroup'; then
        warn "cgroup v2 unified hierarchy not detected at /sys/fs/cgroup. systemd-oomd needs cgroup v2."
    else
        ok "cgroup v2 unified hierarchy: present."
    fi

    # PSI
    if [[ ! -r /proc/pressure/memory ]]; then
        warn "/proc/pressure/memory not readable — PSI may be disabled. systemd-oomd needs PSI."
    else
        ok "PSI: present."
    fi

    # RAM amount sanity check
    local mem_kb
    mem_kb="$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)"
    local mem_gib=$(( mem_kb / 1024 / 1024 ))
    log "MemTotal: ${mem_kb} kB (~${mem_gib} GiB)"
    if (( mem_gib < 16 )); then
        warn "Total RAM is only ${mem_gib} GiB. Caps are percentage-based (MemoryHigh=90%,"
        warn "MemoryMax=95%) so they self-adapt — but on a small host, enable zram (compressed"
        warn "swap) so memory stays elastic under load instead of hitting the cap."
    fi

    # systemd-oomd availability
    if systemctl list-unit-files systemd-oomd.service >/dev/null 2>&1; then
        ok "systemd-oomd.service: present."
        OOMD_AVAILABLE=1
    else
        warn "systemd-oomd.service NOT found. Install package (try one of):"
        warn "  apt-get install systemd-oomd-defaults     (Debian/Ubuntu/ALT)"
        warn "  apt install systemd-oomd                  (some ALT branches)"
        warn "  dnf install systemd-oomd-defaults         (Fedora-likes)"
        warn "Continuing — drop-ins still install, but the daemon won't run."
        OOMD_AVAILABLE=0
    fi

    # Check user-1000.slice exists (the running user)
    if systemctl is-active user-1000.slice >/dev/null 2>&1; then
        ok "user-1000.slice: active (limits will be applied live)."
    else
        warn "user-1000.slice not active — limits take effect at next user login."
    fi

    # Disk space for backups
    local free_root_kb
    free_root_kb="$(df -Pk / | awk 'NR==2 {print $4}')"
    if (( free_root_kb < 102400 )); then
        die "Less than 100 MiB free on / — refusing to proceed."
    fi

    log "Backup directory will be: $BACKUP_ROOT"
    log "Log file: $LOG_FILE"
}

# ---------- file install -------------------------------------------------------

install_managed_file() {
    local rel="$1" mode="$2"
    local dst="/etc/$rel"
    local newcontent
    newcontent="$(content_for "$rel")"

    if [[ -f "$dst" ]]; then
        if [[ "$(< "$dst")" == "$newcontent" ]]; then
            ok "  unchanged: $dst"
            return 0
        fi
        if [[ "$MODE" == "dry-run" ]]; then
            warn "  WOULD overwrite (and back up): $dst"
            diff -u "$dst" <(printf '%s' "$newcontent") | sed 's/^/    | /' >> "$LOG_FILE" || true
            return 0
        fi
        local bdst="$BACKUP_ROOT/$rel"
        install -d -m 0700 "$(dirname "$bdst")"
        cp -a -- "$dst" "$bdst"
        log "  backed up: $dst -> $bdst"
    else
        if [[ "$MODE" == "dry-run" ]]; then
            warn "  WOULD create: $dst"
            return 0
        fi
    fi

    install -d -m 0755 "$(dirname "$dst")"
    printf '%s' "$newcontent" > "$dst.tmp.$$"
    chmod "$mode" "$dst.tmp.$$"
    mv -f -- "$dst.tmp.$$" "$dst"
    ok "  installed: $dst"
}

write_all_files() {
    hdr "2. Installing drop-in files"
    if [[ "$MODE" != "dry-run" ]]; then
        install -d -m 0700 "$BACKUP_ROOT"
        # Write a manifest into the backup dir so rollback is self-describing
        {
            echo "# ${SCRIPT_NAME} backup manifest"
            echo "# created: $(date -Is)"
            echo "# host: $(hostname)"
            echo "# script-version: $SCRIPT_VERSION"
            echo "# managed files (relative to /etc):"
            for entry in "${MANAGED_FILES[@]}"; do
                echo "  - ${entry%%|*}"
            done
        } > "$BACKUP_ROOT/MANIFEST.txt"
    fi

    local entry rel mode
    for entry in "${MANAGED_FILES[@]}"; do
        rel="${entry%%|*}"
        mode="${entry##*|}"
        install_managed_file "$rel" "$mode"
    done
}

# ---------- runtime apply ------------------------------------------------------

reload_systemd() {
    hdr "3. systemd daemon-reload"
    if [[ "$MODE" == "dry-run" ]]; then
        warn "  WOULD: systemctl daemon-reload"
        return 0
    fi
    systemctl daemon-reload
    ok "  reloaded."
}

enable_oomd() {
    hdr "4. Enable systemd-oomd"
    if (( OOMD_AVAILABLE == 0 )); then
        warn "  systemd-oomd unit missing. Skipping enable. Install the package and re-run."
        return 0
    fi
    if [[ "$MODE" == "dry-run" ]]; then
        warn "  WOULD: systemctl enable --now systemd-oomd.socket systemd-oomd.service"
        return 0
    fi
    systemctl enable --now systemd-oomd.socket || warn "  socket enable failed (non-fatal)"
    systemctl enable --now systemd-oomd.service
    if systemctl is-active --quiet systemd-oomd.service; then
        ok "  systemd-oomd is active."
    else
        err "  systemd-oomd failed to start. Check: journalctl -u systemd-oomd -b"
    fi
}

apply_live_cgroup_limits() {
    hdr "5. Live cgroup limits on user-1000.slice"
    if ! systemctl is-active --quiet user-1000.slice; then
        warn "  user-1000.slice not active. Skipping live apply (drop-in handles next login)."
        return 0
    fi
    if [[ "$MODE" == "dry-run" ]]; then
        warn "  WOULD: systemctl set-property user-1000.slice MemoryAccounting=yes MemoryHigh=90% MemoryMax=95% MemorySwapMax=infinity"
        return 0
    fi
    systemctl set-property user-1000.slice \
        MemoryAccounting=yes \
        MemoryHigh=90% \
        MemoryMax=95% \
        MemorySwapMax=infinity
    ok "  applied."
    systemctl show user-1000.slice -p MemoryMax,MemoryHigh,MemorySwapMax,MemoryAccounting \
        | sed 's/^/    /'
}

restart_journald() {
    hdr "6. Restart systemd-journald (picks up coredump.conf changes)"
    if [[ "$MODE" == "dry-run" ]]; then
        warn "  WOULD: systemctl restart systemd-journald"
        return 0
    fi
    systemctl restart systemd-journald
    ok "  restarted."
}

apply_sysctls() {
    hdr "7. Apply VM sysctls"
    if [[ "$MODE" == "dry-run" ]]; then
        warn "  WOULD: sysctl --system"
        return 0
    fi
    sysctl --system >/dev/null
    sysctl vm.swappiness vm.min_free_kbytes vm.overcommit_memory \
           vm.overcommit_ratio vm.vfs_cache_pressure \
           vm.dirty_background_ratio vm.dirty_ratio | sed 's/^/    /'
    ok "  applied."
}

logind_note() {
    hdr "8. systemd-logind"
    warn "  NOT restarted automatically — that would end your active GUI session."
    warn "  When you are ready, run:    sudo systemctl restart systemd-logind"
    warn "  After that, busctl get-property org.freedesktop.login1 /org/freedesktop/login1 \\"
    warn "                                  org.freedesktop.login1.Manager HandlePowerKey"
    warn "  should report 'ignore'."
}

# ---------- verification -------------------------------------------------------

verify() {
    hdr "9. Verification"

    if [[ "$MODE" == "dry-run" ]]; then
        warn "  skipped in --dry-run (nothing was applied to verify)"
        return 0
    fi

    # Each block tolerates non-zero exits; `systemctl is-active` returns 3
    # when inactive, which is information, not failure.
    set +e

    echo "[systemd-oomd]"
    systemctl is-active systemd-oomd.service 2>/dev/null | sed 's/^/  /'
    if command -v oomctl >/dev/null 2>&1; then
        oomctl 2>/dev/null | head -20 | sed 's/^/  /'
    fi

    echo
    echo "[user-1000.slice limits]"
    systemctl show user-1000.slice \
        -p MemoryMax,MemoryHigh,MemorySwapMax,MemoryAccounting,TasksMax 2>/dev/null \
        | sed 's/^/  /'

    echo
    echo "[active VM sysctls]"
    sysctl vm.swappiness vm.min_free_kbytes vm.overcommit_memory \
           vm.overcommit_ratio vm.vfs_cache_pressure \
           vm.dirty_background_ratio vm.dirty_ratio 2>/dev/null \
           | sed 's/^/  /'

    echo
    echo "[current pressure]"
    {
        echo "memory:"; cat /proc/pressure/memory 2>/dev/null
        echo "cpu:";    cat /proc/pressure/cpu 2>/dev/null
        echo "io:";     cat /proc/pressure/io 2>/dev/null
    } | sed 's/^/  /'

    echo
    echo "[memory now]"
    free -h | sed 's/^/  /'

    set -e
}

# ---------- rollback / uninstall ----------------------------------------------

rollback_from() {
    local dir="$1"
    [[ -d "$dir" ]] || die "Rollback dir not found: $dir"
    [[ -f "$dir/MANIFEST.txt" ]] || die "Not a valid backup (missing MANIFEST.txt): $dir"

    hdr "Rollback from $dir"
    local entry rel src dst
    for entry in "${MANAGED_FILES[@]}"; do
        rel="${entry%%|*}"
        src="$dir/$rel"
        dst="/etc/$rel"
        if [[ -f "$src" ]]; then
            install -d -m 0755 "$(dirname "$dst")"
            cp -a -- "$src" "$dst"
            ok "  restored: $dst"
        else
            # If a file was created (no backup existed), remove it
            if [[ -f "$dst" ]] && [[ "$(< "$dst")" == "$(content_for "$rel" 2>/dev/null)" ]]; then
                rm -f -- "$dst"
                ok "  removed (was created by us): $dst"
            fi
        fi
    done
    systemctl daemon-reload
    ok "Rollback complete. systemd reloaded."
    warn "You may want to review:"
    warn "  - systemctl is-active systemd-oomd"
    warn "  - systemctl show user-1000.slice -p MemoryMax,MemoryHigh,MemorySwapMax"
    warn "  - sysctl --system  (to reload sysctls)"
}

uninstall() {
    hdr "Uninstall — removing drop-ins"
    local entry rel dst
    for entry in "${MANAGED_FILES[@]}"; do
        rel="${entry%%|*}"
        dst="/etc/$rel"
        if [[ -f "$dst" ]] && [[ "$(< "$dst")" == "$(content_for "$rel")" ]]; then
            rm -f -- "$dst"
            ok "  removed: $dst"
        else
            warn "  skipped (not ours or modified): $dst"
        fi
        # try to clean empty dirs
        rmdir --ignore-fail-on-non-empty -- "$(dirname "$dst")" 2>/dev/null || true
    done
    systemctl daemon-reload
    if systemctl is-active --quiet systemd-oomd; then
        warn "  systemd-oomd is still enabled. To disable:"
        warn "    sudo systemctl disable --now systemd-oomd.service systemd-oomd.socket"
    fi
    if systemctl is-active --quiet user-1000.slice; then
        warn "  Resetting live cgroup limits on user-1000.slice."
        systemctl set-property user-1000.slice \
            MemoryMax= MemoryHigh= MemorySwapMax= 2>/dev/null || true
    fi
    ok "Done."
}

# ---------- main ---------------------------------------------------------------

usage() {
    cat <<EOF
${SCRIPT_NAME} ${SCRIPT_VERSION}

Usage:
  sudo bash $0 [--dry-run] [--yes]
  sudo bash $0 --rollback /root/${SCRIPT_NAME}-backup-YYYYMMDD-HHMMSS
  sudo bash $0 --uninstall
  bash $0 --help

Options:
  --dry-run       Print exactly what would change. Touch nothing. Safe to run as non-root.
  --yes           Skip the confirmation prompt.
  --rollback DIR  Restore /etc files from a previous backup.
  --uninstall     Remove only the drop-ins this script wrote.
  --help          This message.
EOF
}

confirm() {
    local prompt="$1"
    if [[ "${ASSUME_YES:-0}" == 1 ]]; then return 0; fi
    if [[ ! -t 0 ]]; then
        die "Refusing to proceed without --yes when stdin is not a TTY."
    fi
    read -r -p "$prompt [y/N] " ans
    [[ "$ans" =~ ^[Yy]([Ee][Ss])?$ ]]
}

main() {
    MODE="apply"
    ASSUME_YES=0
    OOMD_AVAILABLE=0
    local rollback_dir=""

    while (( $# )); do
        case "$1" in
            --dry-run)   MODE="dry-run"; shift ;;
            --yes|-y)    ASSUME_YES=1; shift ;;
            --rollback)  MODE="rollback"; rollback_dir="${2:-}"; shift 2 ;;
            --uninstall) MODE="uninstall"; shift ;;
            --help|-h)   usage; exit 0 ;;
            *)           usage; die "Unknown argument: $1" ;;
        esac
    done

    # Allow dry-run as non-root for review purposes — but writes need root.
    if [[ "$MODE" != "dry-run" ]]; then
        require_root
        # log file
        : > "$LOG_FILE" 2>/dev/null || { LOG_FILE="/tmp/${SCRIPT_NAME}.log"; warn "Falling back log file: $LOG_FILE"; : > "$LOG_FILE"; }
        chmod 0640 "$LOG_FILE" 2>/dev/null || true
    else
        LOG_FILE="/tmp/${SCRIPT_NAME}-dryrun.log"
        : > "$LOG_FILE"
    fi

    log "${SCRIPT_NAME} ${SCRIPT_VERSION} starting in mode: ${MODE}"

    case "$MODE" in
        rollback)
            require_root
            rollback_from "$rollback_dir"
            exit 0
            ;;
        uninstall)
            require_root
            confirm "This will remove the drop-ins this script installed. Proceed?" \
                || die "Aborted."
            uninstall
            exit 0
            ;;
    esac

    preflight

    if [[ "$MODE" == "apply" ]]; then
        echo
        echo "About to install/update these files:"
        for entry in "${MANAGED_FILES[@]}"; do
            echo "  /etc/${entry%%|*}"
        done
        echo
        echo "Backups (only of overwritten files) will go to:"
        echo "  $BACKUP_ROOT"
        echo
        confirm "Proceed with apply?" || die "Aborted by user."
    fi

    write_all_files
    reload_systemd
    enable_oomd
    apply_live_cgroup_limits
    restart_journald
    apply_sysctls
    logind_note
    verify

    hdr "Done"
    if [[ "$MODE" == "apply" ]]; then
        ok "Hardening applied. Backups: $BACKUP_ROOT"
        ok "Rollback if needed: sudo bash $0 --rollback $BACKUP_ROOT"
        ok "Log: $LOG_FILE"
        echo
        warn "Recommended stress test (run as your normal user, not root):"
        warn "  In one terminal:  journalctl -fu systemd-oomd"
        warn "  In another:       stress-ng --vm 4 --vm-bytes 16G --vm-keep --timeout 60s"
        warn "  Result must be: stress-ng dies, your shell/IDE/tmux survive."
    else
        ok "Dry-run complete. No changes were made. Diff details in: $LOG_FILE"
    fi
}

main "$@"
