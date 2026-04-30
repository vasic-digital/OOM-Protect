#!/usr/bin/env bash
# install-and-verify.sh
#
# One-shot installer + verifier for oom-watch as a systemd service.
#
# Run as root (or via sudo). Idempotent. Safe to re-run. Anti-bluff: every
# step asserts an observable outcome and exits non-zero on failure.
#
# What it does:
#   1. Pre-flight: atop installed, systemd reachable, Go available if we
#      need to build, oomwatch binary present (build if missing).
#   2. Run `make oomwatch-install` (idempotent; honours $(SUDO)).
#   3. Reload systemd, enable + start oom-watch.service.
#   4. Wait up to 30 s for the unit to reach `active` state.
#   5. Tail recent journal lines for context.
#   6. Wait up to 60 s for the first report to land in the report dir.
#   7. Print a summary; rc=0 iff every check passed.
#
# Diagnostics: if any step fails, dumps `systemctl status`, the journal
# tail, and the daemon's last-known sample so the failure is visible.
#
# Usage:
#   sudo bash oom-watch/scripts/install-and-verify.sh [--no-install] [--quiet]
#
# Flags:
#   --no-install   Skip step 2 (use when already installed; just verify).
#   --quiet        Suppress success-step prints; still prints diagnostics.

set -Eeuo pipefail

# Colours (suppressed when not on a TTY).
if [[ -t 1 ]]; then
    G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; B=$'\033[1m'; D=$'\033[2m'; C=$'\033[0m'
else
    G=""; Y=""; R=""; B=""; D=""; C=""
fi
QUIET=0
NO_INSTALL=0
for a in "$@"; do
    case "$a" in
        --no-install) NO_INSTALL=1 ;;
        --quiet) QUIET=1 ;;
        --help|-h)
            sed -n '2,30p' "$0"
            exit 0
            ;;
        *) printf '%sunknown flag:%s %s\n' "$R" "$C" "$a" >&2; exit 64 ;;
    esac
done

log()  { (( QUIET )) || printf '%s[install-and-verify]%s %s\n' "$D" "$C" "$*" >&2; }
ok()   { (( QUIET )) || printf '%s[install-and-verify] OK%s %s\n' "$G" "$C" "$*" >&2; }
warn() { printf '%s[install-and-verify] WARN%s %s\n' "$Y" "$C" "$*" >&2; }
err()  { printf '%s[install-and-verify] ERROR%s %s\n' "$R" "$C" "$*" >&2; }
hdr()  { (( QUIET )) || printf '\n%s== %s ==%s\n' "$B" "$*" "$C" >&2; }

dump_diagnostics() {
    err "Diagnostics follow:"
    {
        echo "--- systemctl is-active ---"
        systemctl is-active oom-watch.service 2>&1 || true
        echo "--- systemctl status (last 30 lines) ---"
        systemctl status oom-watch.service --no-pager -n 30 2>&1 || true
        echo "--- journalctl -u oom-watch -n 50 ---"
        journalctl -u oom-watch.service -n 50 --no-pager 2>&1 || true
        echo "--- /etc/oom-watch/config.json ---"
        cat /etc/oom-watch/config.json 2>&1 || true
        echo "--- /etc/systemd/system/oom-watch.service ---"
        cat /etc/systemd/system/oom-watch.service 2>&1 || true
        echo "--- /var/log/oom-watch/reports/ ---"
        ls -la /var/log/oom-watch/reports/ 2>&1 || true
    } >&2
}

trap 'rc=$?; if (( rc != 0 )); then dump_diagnostics; fi' EXIT

# ---- privilege --------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
    log "not running as root; trying sudo"
    if ! command -v sudo >/dev/null 2>&1; then
        err "sudo not found; please re-run as root: su - -c 'bash $0'"
        exit 1
    fi
    exec sudo bash "$0" "$@"
fi

# Resolve repo root (this script lives at oom-watch/scripts/).
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
log "repo root: $REPO_ROOT"

# ---- pre-flight -------------------------------------------------------
hdr "1. Pre-flight"

if ! command -v atop >/dev/null 2>&1; then
    err "atop is not installed. Install atop first (apt install atop / dnf install atop / etc) and re-run."
    exit 1
fi
ok "atop present: $(command -v atop) ($(atop -V 2>&1 | head -1 | awk '{print $2}'))"

if ! command -v systemctl >/dev/null 2>&1; then
    err "systemctl not found. This script requires a systemd host."
    exit 1
fi
ok "systemd present: $(systemctl --version | head -1)"

# ---- install ----------------------------------------------------------
if (( NO_INSTALL == 0 )); then
    hdr "2. Build + install"
    bin="$REPO_ROOT/oom-watch/oomwatch"
    if [[ ! -x "$bin" ]]; then
        log "binary missing at $bin; building"
        if ! command -v go >/dev/null 2>&1; then
            err "Go toolchain required to build oomwatch. Install Go (>=1.22) and re-run."
            exit 1
        fi
        (cd "$REPO_ROOT/oom-watch" && go build -o oomwatch ./cmd/oomwatch)
    fi
    [[ -x "$bin" ]] || { err "build failed; binary not produced"; exit 1; }
    ok "binary built: $bin"

    log "running 'make oomwatch-install' (idempotent)"
    (cd "$REPO_ROOT" && make oomwatch-install) >&2
    ok "make oomwatch-install completed"
else
    hdr "2. Build + install (skipped per --no-install)"
fi

# Anti-bluff post-install asserts: every artefact must exist with the
# expected mode. A regression that copied to the wrong path would fail
# here, before we even try to start the unit.
[[ -x /usr/local/sbin/oomwatch ]] \
    || { err "/usr/local/sbin/oomwatch missing or not executable"; exit 1; }
[[ -f /etc/oom-watch/config.json ]] \
    || { err "/etc/oom-watch/config.json missing"; exit 1; }
[[ -f /etc/systemd/system/oom-watch.service ]] \
    || { err "/etc/systemd/system/oom-watch.service missing"; exit 1; }
ok "post-install paths verified: binary, config, unit"

# ---- enable + start ---------------------------------------------------
hdr "3. Enable + start oom-watch.service"
systemctl daemon-reload
if ! systemctl is-enabled --quiet oom-watch.service 2>/dev/null; then
    systemctl enable oom-watch.service
    ok "service enabled"
else
    log "service already enabled"
fi
systemctl restart oom-watch.service
ok "service restarted (clean slate for verification)"

# ---- wait for active --------------------------------------------------
hdr "4. Waiting for unit to reach 'active' state (timeout 30 s)"
deadline=$((SECONDS + 30))
state="unknown"
while (( SECONDS < deadline )); do
    state=$(systemctl is-active oom-watch.service 2>/dev/null || true)
    case "$state" in
        active)
            ok "unit is active"
            break
            ;;
        failed)
            err "unit went to 'failed' state"
            exit 1
            ;;
        *)
            sleep 1
            ;;
    esac
done
if [[ "$state" != "active" ]]; then
    err "unit did not reach 'active' within 30 s (last state: $state)"
    exit 1
fi

# Anti-bluff: confirm the daemon actually located atop. A startup failure
# masked by Restart= would leave the unit cycling; the journal will show
# repeated 'atop located' or, on failure, an error line.
hdr "5. Recent journal"
journalctl -u oom-watch.service -n 20 --no-pager
if ! journalctl -u oom-watch.service --since "2 minutes ago" --no-pager 2>/dev/null \
        | grep -q "atop located"; then
    err "journal does not contain 'atop located' from the last 2 min — daemon may not have run successfully."
    exit 1
fi
ok "journal contains 'atop located' (daemon reached the sample loop)"

# ---- wait for first report -------------------------------------------
hdr "6. Waiting for first report (timeout 60 s)"
report_dir="/var/log/oom-watch/reports"
mkdir -p "$report_dir"
deadline=$((SECONDS + 60))
report=""
while (( SECONDS < deadline )); do
    shopt -s nullglob
    files=( "$report_dir"/*.md )
    if (( ${#files[@]} > 0 )); then
        report="${files[0]}"
        break
    fi
    sleep 2
done

# A clean idle host may not produce ANY report in 60 s (no thresholds
# breached). That is *correct* behaviour — quiet is the goal. Force one
# diagnostic report via -one-shot so we have proof the binary writes a
# real .md to the configured directory.
if [[ -z "$report" ]]; then
    log "no automatic report yet (host appears calm); requesting a -one-shot diagnostic"
    /usr/local/sbin/oomwatch -config /etc/oom-watch/config.json -one-shot
    files=( "$report_dir"/*.md )
    (( ${#files[@]} > 0 )) || { err "even -one-shot did not produce a report"; exit 1; }
    report="${files[0]}"
fi
ok "first report on disk: $report ($(wc -c < "$report") bytes)"

# ---- summary ----------------------------------------------------------
hdr "Summary"
printf '%sUnit:%s     %s\n' "$B" "$C" "$(systemctl is-active oom-watch.service)"
printf '%sBinary:%s   %s\n' "$B" "$C" "$(ls -la /usr/local/sbin/oomwatch | awk '{print $1, $3, $5, $9}')"
printf '%sConfig:%s   /etc/oom-watch/config.json\n' "$B" "$C"
printf '%sUnit file:%s /etc/systemd/system/oom-watch.service\n' "$B" "$C"
printf '%sReports:%s  %s\n' "$B" "$C" "$report_dir/"
printf '%sLast file:%s %s (%s bytes)\n' "$B" "$C" "$report" "$(wc -c < "$report")"

ok "oom-watch is installed, active, and producing reports."
