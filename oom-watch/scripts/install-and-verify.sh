#!/usr/bin/env bash
#==============================================================================
# install-and-verify.sh
#
#   One-shot end-to-end deployer for the oom-watch monitoring daemon.
#
#   Run this script as root (or via sudo) on the target host. It is idempotent
#   and safe to re-run; every step asserts an observable outcome and exits
#   non-zero on failure with a full diagnostic dump (so you never get a
#   cryptic error like 'systemctl status: code=exited, status=2' without the
#   actual cause).
#
#   The shorthand wrapper is:  make oomwatch-deploy
#
#------------------------------------------------------------------------------
# What it does, in order
#------------------------------------------------------------------------------
#
#   0. (optional, with --pull) git pull the repo so the binary, example
#      config, and unit file you install reflect the current main branch.
#
#   1. Pre-flight checks:
#        - running as root (otherwise re-execs under sudo)
#        - atop is on PATH (refuses to proceed without it; the daemon needs
#          atop at runtime, not just once)
#        - systemctl is reachable
#        - Go toolchain present IF we need to build oomwatch from source
#
#   2. Build oomwatch (skipped when binary already exists and --rebuild not
#      passed) and run `make oomwatch-install`. The install target is
#      idempotent: it will not clobber an existing /etc/oom-watch/config.json,
#      so a prior customised config is preserved.
#
#   3. Validate the INSTALLED config with `oomwatch -dry-run`. This is the
#      anti-bluff guard against the class of bug where the daemon would
#      otherwise enter the systemd start path with bad config and die at
#      exit code 2 with no human-readable diagnostic.
#
#      If validation fails, the script auto-remediates:
#        - The broken file is moved aside to:
#            /etc/oom-watch/config.json.broken.<timestamp>
#        - The shipped example is copied in as the new config.
#        - The new config is re-validated.
#        - If THAT fails, the repo itself is broken and we abort with
#          a fatal error.
#      The backup path is printed prominently so you can re-apply any
#      custom thresholds you previously had.
#
#   4. systemctl daemon-reload, enable, and restart the unit (a clean restart
#      gives the verifier a known starting state).
#
#   5. Poll `systemctl is-active` for up to 30 s. Bails immediately if the
#      unit goes to 'failed'; times out otherwise. On either bad outcome
#      the EXIT trap dumps full diagnostics.
#
#   6. Assert the journal contains 'atop located' from the last 2 minutes.
#      A daemon that bounced because the systemd sandbox blocked /proc or
#      atop would otherwise show 'active' but not have run — this assertion
#      proves the sample loop was reached.
#
#   7. Wait up to 60 s for the first report to appear in
#      /var/log/oom-watch/reports/. A calm host may not produce ANY auto-
#      report — quiet IS the goal — so if the wait expires, the script
#      forces a `-one-shot` diagnostic to put proof on disk.
#
#   8. Print a Summary block: unit state, binary mode, paths, last report.
#
#------------------------------------------------------------------------------
# Flags
#------------------------------------------------------------------------------
#
#   --pull           Run `git pull --ff-only` in the repo before building.
#                    Useful for fully-automated update-and-redeploy. Default
#                    OFF because pull on a dirty tree may conflict.
#
#   --no-install     Skip the build + install step (step 2). Use when the
#                    binary, config, and unit file are already in place and
#                    you only want to verify the running unit.
#
#   --rebuild        Force a fresh `go build` of oomwatch even if the binary
#                    already exists in oom-watch/.
#
#   --quiet          Suppress per-step "OK" and informational prints. Failure
#                    diagnostics are always printed.
#
#   --help, -h       Print this header and exit.
#
#------------------------------------------------------------------------------
# Exit codes
#------------------------------------------------------------------------------
#
#   0   Success. The daemon is installed, active, and producing reports.
#   1   Any pre-flight, install, validation, or runtime check failed. The
#       EXIT trap will have dumped systemctl status + journal + config +
#       unit file + report directory listing.
#   64  Usage error (unknown flag).
#
#------------------------------------------------------------------------------
# Examples
#------------------------------------------------------------------------------
#
#   # First-time deploy on a fresh host (typical):
#   sudo bash oom-watch/scripts/install-and-verify.sh
#
#   # Re-deploy after `git pull` upstream:
#   sudo bash oom-watch/scripts/install-and-verify.sh --pull --rebuild
#
#   # Just verify a running unit after a manual restart:
#   sudo bash oom-watch/scripts/install-and-verify.sh --no-install
#
#   # As root under su (note: no sudo needed):
#   bash oom-watch/scripts/install-and-verify.sh
#
#==============================================================================

set -Eeuo pipefail

# ---- colours (suppressed when stdout is not a TTY) -------------------------

if [[ -t 1 ]]; then
    G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; B=$'\033[1m'; D=$'\033[2m'; C=$'\033[0m'
else
    G=""; Y=""; R=""; B=""; D=""; C=""
fi

QUIET=0
NO_INSTALL=0
DO_PULL=0
REBUILD=0

for a in "$@"; do
    case "$a" in
        --pull)        DO_PULL=1 ;;
        --no-install)  NO_INSTALL=1 ;;
        --rebuild)     REBUILD=1 ;;
        --quiet)       QUIET=1 ;;
        --help|-h)     sed -n '2,/^#==/p' "$0" | sed 's/^# \?//' | head -100; exit 0 ;;
        *)             printf '%sunknown flag:%s %s (use --help)\n' "$R" "$C" "$a" >&2; exit 64 ;;
    esac
done

log()  { (( QUIET )) || printf '%s[deploy]%s %s\n' "$D" "$C" "$*" >&2; }
ok()   { (( QUIET )) || printf '%s[deploy] OK%s %s\n' "$G" "$C" "$*" >&2; }
warn() { printf '%s[deploy] WARN%s %s\n' "$Y" "$C" "$*" >&2; }
err()  { printf '%s[deploy] ERROR%s %s\n' "$R" "$C" "$*" >&2; }
hdr()  { (( QUIET )) || printf '\n%s== %s ==%s\n' "$B" "$*" "$C" >&2; }

# ---- diagnostics dump on any non-zero exit ---------------------------------

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

# ---- privilege escalation --------------------------------------------------

if [[ $EUID -ne 0 ]]; then
    log "not running as root; trying sudo"
    if ! command -v sudo >/dev/null 2>&1; then
        err "sudo not found and not running as root."
        err "Re-run with: su - -c 'bash $(realpath "$0") $*'"
        exit 1
    fi
    exec sudo bash "$0" "$@"
fi

# ---- locate repo -----------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
log "repo root: $REPO_ROOT"

# ---- step 0: optional git pull ---------------------------------------------

if (( DO_PULL )); then
    hdr "0. git pull (--pull)"
    if [[ ! -d "$REPO_ROOT/.git" ]]; then
        err "$REPO_ROOT is not a git repository; --pull cannot run"
        exit 1
    fi
    (cd "$REPO_ROOT" && git pull --ff-only)
    ok "git pull --ff-only succeeded"
fi

# ---- step 1: pre-flight ----------------------------------------------------

hdr "1. Pre-flight"

if ! command -v atop >/dev/null 2>&1; then
    err "atop is not installed."
    err "Install atop on this host first (e.g. 'apt install atop' / 'dnf install atop' / 'apt-get install atop' on ALT) and re-run."
    exit 1
fi
ok "atop present: $(command -v atop) ($(atop -V 2>&1 | head -1 | awk '{print $2}'))"

if ! command -v systemctl >/dev/null 2>&1; then
    err "systemctl not found. This script requires a systemd host."
    exit 1
fi
ok "systemd present: $(systemctl --version | head -1)"

# ---- step 2: build + install ----------------------------------------------

bin="$REPO_ROOT/oom-watch/oomwatch"
if (( NO_INSTALL == 0 )); then
    hdr "2. Build + install"
    if [[ ! -x "$bin" ]] || (( REBUILD )); then
        if (( REBUILD )); then
            log "rebuilding oomwatch (--rebuild)"
            rm -f "$bin"
        else
            log "binary missing at $bin; building"
        fi
        if ! command -v go >/dev/null 2>&1; then
            err "Go toolchain required to build oomwatch. Install Go (>=1.22) and re-run."
            exit 1
        fi
        # -buildvcs=false avoids 'error obtaining VCS status' when the repo
        # lives on a mount owned by a different UID than the builder (e.g. an
        # external drive owned by the user, but root is running the script).
        (cd "$REPO_ROOT/oom-watch" && go build -buildvcs=false -o oomwatch ./cmd/oomwatch)
    fi
    [[ -x "$bin" ]] || { err "build failed; binary not produced"; exit 1; }
    ok "binary built: $bin"

    log "running 'make oomwatch-install' (idempotent)"
    (cd "$REPO_ROOT" && make oomwatch-install) >&2
    ok "make oomwatch-install completed"
else
    hdr "2. Build + install (skipped per --no-install)"
fi

# ---- step 2a: post-install path checks ------------------------------------

[[ -x /usr/local/sbin/oomwatch ]] \
    || { err "/usr/local/sbin/oomwatch missing or not executable"; exit 1; }
[[ -f /etc/oom-watch/config.json ]] \
    || { err "/etc/oom-watch/config.json missing"; exit 1; }
[[ -f /etc/systemd/system/oom-watch.service ]] \
    || { err "/etc/systemd/system/oom-watch.service missing"; exit 1; }
ok "post-install paths verified: binary, config, unit"

# ---- step 2b: validate installed config (auto-remediate if broken) ---------

hdr "2b. Validate /etc/oom-watch/config.json"

dryrun_log="/tmp/.oomwatch-dryrun.$$"

validate_installed_config() {
    /usr/local/sbin/oomwatch -config /etc/oom-watch/config.json -dry-run \
        >"$dryrun_log" 2>&1
}

if validate_installed_config; then
    ok "/etc/oom-watch/config.json passes -dry-run"
    rm -f "$dryrun_log"
else
    err "INSTALLED CONFIG IS INVALID — systemd start would fail with exit code 2."
    err "Validator output:"
    sed 's/^/    /' "$dryrun_log" >&2

    backup="/etc/oom-watch/config.json.broken.$(date +%Y%m%d-%H%M%S)"
    log "auto-remediation: backing up the broken file to $backup"
    cp /etc/oom-watch/config.json "$backup"

    src="$REPO_ROOT/oom-watch/config/oom-watch.example.json"
    [[ -f "$src" ]] || { err "shipped example missing at $src"; rm -f "$dryrun_log"; exit 1; }
    log "auto-remediation: installing shipped example over the broken config"
    install -m 0644 "$src" /etc/oom-watch/config.json

    if ! validate_installed_config; then
        err "FATAL: even the shipped example fails validation."
        err "Validator output (post-replace):"
        sed 's/^/    /' "$dryrun_log" >&2
        rm -f "$dryrun_log"
        exit 1
    fi
    rm -f "$dryrun_log"
    ok "fresh example installed and passes -dry-run"
    warn "if you had custom thresholds, re-apply them from the backup:"
    warn "    diff $backup /etc/oom-watch/config.json"
fi

# ---- step 3: enable + restart ---------------------------------------------

hdr "3. systemd: daemon-reload + reset-failed + enable + restart"
systemctl daemon-reload
# A previous bad config can leave the unit in restart-throttled state
# ('Start request repeated too quickly'). reset-failed clears the rate
# limit so the next restart actually runs ExecStart.
systemctl reset-failed oom-watch.service 2>/dev/null || true
ok "reset-failed cleared (unit can start fresh)"
if ! systemctl is-enabled --quiet oom-watch.service 2>/dev/null; then
    systemctl enable oom-watch.service
    ok "service enabled"
else
    log "service already enabled"
fi
systemctl restart oom-watch.service
ok "service restarted (clean slate for verification)"

# ---- step 4: wait for active state ----------------------------------------

hdr "4. Waiting for unit to reach 'active' (timeout 30 s)"
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

# ---- step 5: journal sanity ------------------------------------------------

hdr "5. Recent journal"
journalctl -u oom-watch.service -n 20 --no-pager
if ! journalctl -u oom-watch.service --since "2 minutes ago" --no-pager 2>/dev/null \
        | grep -q "atop located"; then
    err "journal does not contain 'atop located' from the last 2 min — daemon may not have run successfully."
    exit 1
fi
ok "journal contains 'atop located' (daemon reached the sample loop)"

# ---- step 6: first report on disk -----------------------------------------

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
if [[ -z "$report" ]]; then
    log "no automatic report yet (host appears calm); requesting -one-shot diagnostic"
    /usr/local/sbin/oomwatch -config /etc/oom-watch/config.json -one-shot
    files=( "$report_dir"/*.md )
    (( ${#files[@]} > 0 )) || { err "even -one-shot did not produce a report"; exit 1; }
    report="${files[0]}"
fi
ok "first report on disk: $report ($(wc -c < "$report") bytes)"

# ---- step 7: summary -------------------------------------------------------

hdr "Summary"
printf '%sUnit:%s        %s\n' "$B" "$C" "$(systemctl is-active oom-watch.service)"
printf '%sBinary:%s      %s\n' "$B" "$C" "$(ls -la /usr/local/sbin/oomwatch | awk '{print $1, $3, $5, $9}')"
printf '%sConfig:%s      /etc/oom-watch/config.json\n' "$B" "$C"
printf '%sUnit file:%s   /etc/systemd/system/oom-watch.service\n' "$B" "$C"
printf '%sReports dir:%s %s/\n' "$B" "$C" "$report_dir"
printf '%sLast report:%s %s (%s bytes)\n' "$B" "$C" "$report" "$(wc -c < "$report")"
printf '%sFollow logs:%s journalctl -fu oom-watch.service\n' "$B" "$C"

ok "oom-watch is installed, active, and producing reports."
