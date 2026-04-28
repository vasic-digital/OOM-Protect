#!/usr/bin/env bash
# verify.sh — comprehensive health check for the oom-toolkit on this host.
#
# Verifies that every recommendation from Crash_Report.md and oom-hardening.sh
# is in effect, and that oom-runner.sh works end-to-end.
#
# Exit code:
#   0 = all green
#   1 = at least one yellow (warning) and no red
#   2 = at least one red (failure)
#
# Usage:
#   bash verify.sh                   # default checks
#   bash verify.sh --stress          # also run a 16G stress test
#   bash verify.sh --json            # machine-readable JSON output

# Health checks intentionally tolerate non-zero exits (a yellow or red is
# valid information, not a script failure). We use `set -E` for the ERR trap
# discipline but NOT `set -e`/`-o pipefail`, so individual `grep` or `oomctl`
# commands returning non-zero don't abort the whole script.
set -Eu

# sysctl, busctl, oomctl etc. live in /sbin or /usr/sbin on many distros
# (ALT, RHEL). Ensure they resolve regardless of how the user's PATH is set.
export PATH="/usr/sbin:/sbin:/usr/bin:/bin:${PATH:-}"

readonly ROOT="$(cd "$(dirname "$0")" && pwd)"

# ---- output --------------------------------------------------------------
if [[ -t 1 ]]; then
    G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; B=$'\033[1m'; D=$'\033[2m'; C=$'\033[0m'
else
    G=""; Y=""; R=""; B=""; D=""; C=""
fi

# Counters and structured results
GREEN=0; YELLOW=0; RED=0
declare -a ROWS=()    # "color|name|detail"

JSON=0; STRESS=0
for arg in "$@"; do
    case "$arg" in
        --json)   JSON=1 ;;
        --stress) STRESS=1 ;;
        --help|-h) sed -n '2,12p' "$0"; exit 0 ;;
    esac
done

record() {
    local color="$1" name="$2" detail="$3"
    ROWS+=("$color|$name|$detail")
    case "$color" in
        green)  GREEN=$((GREEN+1)) ;;
        yellow) YELLOW=$((YELLOW+1)) ;;
        red)    RED=$((RED+1)) ;;
    esac
}

# ---- individual checks ---------------------------------------------------

check_kernel_version() {
    local v; v="$(uname -r)"
    local maj min; maj="${v%%.*}"; min="${v#*.}"; min="${min%%.*}"
    if (( maj > 5 )) || (( maj == 5 && min >= 15 )); then
        record green "kernel" "$v"
    else
        record yellow "kernel" "$v (recommend ≥ 5.15 for full PSI/cgroup-v2)"
    fi
}

check_systemd_version() {
    local v; v="$(systemctl --version 2>/dev/null | awk 'NR==1{print $2}')"
    if [[ -z "$v" ]]; then
        record red "systemd" "not found"
    elif (( v >= 248 )); then
        record green "systemd" "version $v"
    else
        record yellow "systemd" "version $v (recommend ≥ 248 for ManagedOOM*)"
    fi
}

check_cgroup_v2() {
    if mount 2>/dev/null | grep -q 'cgroup2 on /sys/fs/cgroup'; then
        record green "cgroup v2 unified" "/sys/fs/cgroup"
    else
        record red "cgroup v2 unified" "not detected"
    fi
}

check_psi() {
    if [[ -r /proc/pressure/memory ]]; then
        record green "PSI" "/proc/pressure/* readable"
    else
        record red "PSI" "/proc/pressure/memory not readable"
    fi
}

check_oomd() {
    if ! systemctl list-unit-files systemd-oomd.service >/dev/null 2>&1; then
        record red "systemd-oomd" "not installed"
        return
    fi
    if systemctl is-active --quiet systemd-oomd.service; then
        record green "systemd-oomd" "active"
    else
        record red "systemd-oomd" "installed but not active (oom-hardening.sh not applied?)"
    fi
}

check_oomd_managing_user_slice() {
    if ! command -v oomctl >/dev/null 2>&1; then
        record yellow "oomd managing user slice" "oomctl not available, cannot verify"
        return
    fi
    if oomctl 2>/dev/null | grep -qE "user(-[0-9]+)?\.slice"; then
        record green "oomd managing user slice" "user.slice tracked"
    else
        record yellow "oomd managing user slice" "no user slice in oomctl output"
    fi
}

check_user_slice_limits() {
    local uid; uid="$(id -u)"
    local slice="user-${uid}.slice"
    local mm mh ms acct
    mm="$(systemctl show -p MemoryMax --value "$slice" 2>/dev/null)"
    mh="$(systemctl show -p MemoryHigh --value "$slice" 2>/dev/null)"
    ms="$(systemctl show -p MemorySwapMax --value "$slice" 2>/dev/null)"
    acct="$(systemctl show -p MemoryAccounting --value "$slice" 2>/dev/null)"

    local issues=()
    [[ "$acct" == "yes" ]] || issues+=("MemoryAccounting=$acct")
    [[ "$mm" == "infinity" ]] && issues+=("MemoryMax=infinity (no ceiling!)")
    [[ "$mh" == "infinity" ]] && issues+=("MemoryHigh=infinity")
    [[ "$ms" == "infinity" ]] && issues+=("MemorySwapMax=infinity")

    local fmt; fmt="MemoryMax=$mm MemoryHigh=$mh MemorySwapMax=$ms acct=$acct"
    if (( ${#issues[@]} == 0 )); then
        record green "user slice limits" "$fmt"
    else
        record red "user slice limits" "$fmt — ${issues[*]}"
    fi
}

check_logind_powerkey() {
    local v
    v="$(busctl get-property org.freedesktop.login1 /org/freedesktop/login1 \
        org.freedesktop.login1.Manager HandlePowerKey 2>/dev/null \
        | awk -F'"' '{print $2}')"
    if [[ "$v" == "ignore" ]]; then
        record green "logind HandlePowerKey" "ignore"
    elif [[ -n "$v" ]]; then
        record yellow "logind HandlePowerKey" "$v (recommend 'ignore'; restart systemd-logind to apply)"
    else
        record yellow "logind HandlePowerKey" "could not query (busctl not available?)"
    fi
}

check_sysctl() {
    local key="$1" expect="$2"
    local v
    v="$(sysctl -n "$key" 2>/dev/null)"
    if [[ "$v" == "$expect" ]]; then
        record green "sysctl $key" "$v"
    else
        record yellow "sysctl $key" "$v (recommended: $expect)"
    fi
}

check_coredump() {
    local f="/etc/systemd/coredump.conf.d/50-keep.conf"
    if [[ -f "$f" ]]; then
        record green "coredump retention" "$f present"
    else
        record yellow "coredump retention" "$f missing"
    fi
}

check_swap() {
    local total used
    read -r total used < <(awk '/^Swap/ {print $2, $3}' /proc/meminfo)
    if (( total > 0 )); then
        record green "swap" "${total} kB total, ${used} kB used"
    else
        record yellow "swap" "no swap configured (recommend small swap for emergency)"
    fi
}

check_oom_runner() {
    local r="$ROOT/oom-runner.sh"
    [[ -x "$r" ]] || { record red "oom-runner" "$r not found"; return; }

    # oom-runner targets the per-user systemd manager. Running this check as
    # root (e.g. via su -c) usually fails because /run/user/0 doesn't exist.
    # Skip cleanly and tell the user what to do instead.
    if (( EUID == 0 )); then
        record yellow "oom-runner exec" \
            "skipped: run verify.sh as your normal user (not root) for user-context tests"
        return
    fi

    local out
    if out="$(bash "$r" --no-inherit-env -m 256M --no-pty -- /bin/echo "OK" 2>&1)"; then
        if grep -q '^OK$' <<< "$out"; then
            record green "oom-runner exec" "256M scope ran echo successfully"
        else
            record yellow "oom-runner exec" "ran but unexpected output"
        fi
    else
        record red "oom-runner exec" "failed: ${out:0:160}"
    fi
}

check_oom_runner_kill() {
    local r="$ROOT/oom-runner.sh"
    [[ -x "$r" ]] || return

    if (( EUID == 0 )); then
        record yellow "cgroup OOM enforcement" \
            "skipped: run verify.sh as your normal user (not root) for user-context tests"
        return
    fi

    # Need python3 for the allocation test. Skip cleanly if missing.
    if ! command -v python3 >/dev/null 2>&1; then
        record yellow "cgroup OOM enforcement" "python3 not installed; cannot test"
        return
    fi

    # Spawn a tiny scope and try to OOM it. We:
    #   - DO inherit env (so PATH is set; python3 needs to resolve)
    #   - Disable swap (-s 0) so the process can't survive by paging out
    #   - Try to alloc 2 GiB; with MemoryMax=128M and no swap, kernel WILL kill it
    local unit_name="verify-$(tr -dc 'a-z0-9' </dev/urandom | head -c 6)"
    local out rc
    out="$(timeout 30 bash "$r" --shell --yes -m 128M -s 0 -n "$unit_name" -- '
        python3 -c "x=bytearray(); _=[x.extend(b\"a\"*1024*1024) for _ in range(2048)]"
    ' 2>&1)"
    rc=$?

    if (( rc != 0 )); then
        record green "cgroup OOM enforcement" "scope killed when over 128M (rc=$rc)"
    else
        record red "cgroup OOM enforcement" \
            "scope NOT killed despite exceeding limit (rc=$rc, output: ${out:0:160})"
    fi

    bash "$r" kill "oomrun-$unit_name" >/dev/null 2>&1 || true
}

check_stress() {
    if ! command -v stress-ng >/dev/null 2>&1; then
        record yellow "stress-ng test" "stress-ng not installed; skip with --no-stress or install: sudo apt install stress-ng"
        return
    fi
    # Run 16G alloc; expect oomd to kill it, NOT us.
    local out
    out="$(timeout 90 stress-ng --vm 4 --vm-bytes 16G --vm-keep --timeout 30s 2>&1 || true)"
    if grep -qE 'oom|killed' <<< "$out"; then
        record green "stress test" "stress-ng was killed under memory pressure"
    else
        record yellow "stress test" "stress-ng completed without being killed (system has plenty of headroom or cgroup not enforced)"
    fi
}

check_files_exist() {
    # Files have a canonical name but may live in either the toolkit root or
    # a subdirectory like reports/. Search candidate paths and accept the
    # first hit. This survives the user reorganising the directory tree.
    local entry name candidates found
    local -a SEARCH=(
        "oom-hardening.sh"
        "oom-runner.sh"
        "build-docs.sh"
        "Crash_Report.md"
        "manuals/oom-hardening-manual.md"
        "manuals/oom-runner-manual.md"
        "style.css"
    )
    for entry in "${SEARCH[@]}"; do
        name="$(basename "$entry")"
        # Search candidate paths in priority order
        candidates=(
            "$ROOT/$entry"
            "$ROOT/reports/$entry"
            "$ROOT/reports/$name"
            "$ROOT/assets/$name"
            "$ROOT/reports/assets/$name"
        )
        found=""
        for c in "${candidates[@]}"; do
            if [[ -f "$c" ]]; then found="$c"; break; fi
        done
        if [[ -n "$found" ]]; then
            record green "file" "$name (${found#$ROOT/})"
        else
            record red "file" "$name MISSING"
        fi
    done
}

# ---- run -----------------------------------------------------------------

(( JSON )) || printf '%s\n%sOOM-Toolkit Health Check%s\n%s\n' \
    "==========================================" \
    "$B" "$C" \
    "=========================================="

check_files_exist
check_kernel_version
check_systemd_version
check_cgroup_v2
check_psi
check_oomd
check_oomd_managing_user_slice
check_user_slice_limits
check_logind_powerkey
check_sysctl vm.swappiness 10
check_sysctl vm.min_free_kbytes 262144
check_sysctl vm.overcommit_memory 0
check_sysctl vm.dirty_ratio 15
check_sysctl vm.dirty_background_ratio 5
check_sysctl vm.vfs_cache_pressure 50
check_coredump
check_swap
check_oom_runner
check_oom_runner_kill
(( STRESS )) && check_stress

# ---- output --------------------------------------------------------------

if (( JSON )); then
    printf '{\n'
    printf '  "summary": {"green": %d, "yellow": %d, "red": %d},\n' "$GREEN" "$YELLOW" "$RED"
    printf '  "checks": [\n'
    local first=1
    for row in "${ROWS[@]}"; do
        IFS='|' read -r color name detail <<< "$row"
        if (( first )); then first=0; else printf ',\n'; fi
        printf '    {"status": "%s", "name": "%s", "detail": "%s"}' \
            "$color" "${name//\"/\\\"}" "${detail//\"/\\\"}"
    done
    printf '\n  ]\n}\n'
else
    printf '\n'
    printf '%-32s %s\n' "CHECK" "DETAIL"
    printf '%s\n' "----------------------------------------------------------------"
    for row in "${ROWS[@]}"; do
        IFS='|' read -r color name detail <<< "$row"
        case "$color" in
            green)  printf '%s[ OK  ]%s %-24s %s\n' "$G" "$C" "$name" "$detail" ;;
            yellow) printf '%s[WARN ]%s %-24s %s\n' "$Y" "$C" "$name" "$detail" ;;
            red)    printf '%s[FAIL ]%s %-24s %s\n' "$R" "$C" "$name" "$detail" ;;
        esac
    done
    printf '\n'
    printf 'Summary: %s%d ok%s, %s%d warn%s, %s%d fail%s\n' \
        "$G" "$GREEN" "$C" "$Y" "$YELLOW" "$C" "$R" "$RED" "$C"
fi

if (( RED > 0 )); then
    exit 2
elif (( YELLOW > 0 )); then
    exit 1
else
    exit 0
fi
