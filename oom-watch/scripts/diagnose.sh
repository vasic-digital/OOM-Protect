#!/usr/bin/env bash
#==============================================================================
# diagnose.sh
#
#   Collects EVERY piece of context needed to debug an oom-watch install
#   failure into a single log file you can paste back to support.
#
#   Run as root (or via sudo). The script intentionally does NOT exit early
#   when a section fails — every section runs, and each section's failure is
#   itself useful evidence.
#
#   Output: /tmp/oomwatch-diagnose-<timestamp>.log (also tee'd to stdout so
#   you can watch progress).
#
#   Shorthand: make oomwatch-diagnose
#
#------------------------------------------------------------------------------
# What it captures (in order)
#------------------------------------------------------------------------------
#
#    1. Timestamp + host identity
#    2. Tool versions (atop, systemctl, go, make, git)
#    3. Repo state: HEAD commit, dirty files, configured remotes
#    4. Top of the SHIPPED example config (so we can see if the file in the
#       repo is the fixed version)
#    5. Installed paths: binary, /etc/oom-watch/*, /var/log/oom-watch/*,
#       /var/lib/oom-watch/*, the unit file
#    6. INSTALLED config in full (cat) — proves whether _comment is still
#       there
#    7. Result of `oomwatch -dry-run` against the installed config — the
#       canonical "is this config valid?" verdict, with rc captured
#    8. systemctl is-enabled / is-active / status -n 50 for the unit
#    9. The unit file in full
#   10. Last 200 journal lines for oom-watch.service
#   11. /var/log/oom-watch/reports/ directory listing
#   12. A live atop sample (sanity check that atop itself works)
#   13. A full `make oomwatch-deploy` run with all step headers and any
#       diagnostic-trap dump
#   14. Post-deploy unit state and journal
#
#------------------------------------------------------------------------------
# Safety
#------------------------------------------------------------------------------
#
#   - The script does NOT modify state on its own. It runs `make
#     oomwatch-deploy` as the final section, which IS the deploy/repair flow,
#     but that's the same thing you'd run manually. Skip the deploy by
#     passing `--no-deploy` if you only want a snapshot of current state.
#
#   - `set -u` (nounset) is on; `set -e` is OFF (we want every section to
#     run regardless of failures earlier in the script).
#
#==============================================================================

set -u

# ---- args ------------------------------------------------------------------

NO_DEPLOY=0
for a in "$@"; do
    case "$a" in
        --no-deploy)  NO_DEPLOY=1 ;;
        --help|-h)    sed -n '2,/^#==/p' "$0" | sed 's/^# \?//' | head -60; exit 0 ;;
        *)            printf 'unknown flag: %s\n' "$a" >&2; exit 64 ;;
    esac
done

# ---- privilege -------------------------------------------------------------

if [[ $EUID -ne 0 ]]; then
    if command -v sudo >/dev/null 2>&1; then
        echo "Re-executing under sudo..." >&2
        exec sudo -E bash "$0" "$@"
    fi
    echo "WARNING: not running as root and sudo not found; some sections will fail." >&2
fi

# ---- locate repo + log file ------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TS=$(date +%Y%m%d-%H%M%S)
LOG=/tmp/oomwatch-diagnose-${TS}.log

echo "Writing diagnostic log to: $LOG"
echo "Repo root: $REPO_ROOT"
echo

# ---- helper for section headers -------------------------------------------

section() {
    printf '\n========================================================\n'
    printf '== %s\n' "$*"
    printf '========================================================\n'
}

# ---- main capture (everything below this line goes to $LOG and stdout) ----

{
    section "0. TIMESTAMP"
    date -Is
    echo "host: $(hostname)"
    echo "user: $(id)"

    section "1. SYSTEM"
    uname -a
    echo "---"
    cat /etc/os-release 2>/dev/null | head -10

    section "2. TOOL VERSIONS"
    if command -v atop >/dev/null 2>&1; then
        echo "atop: $(command -v atop)"
        atop -V 2>&1 | head -3
    else
        echo "atop: NOT FOUND"
    fi
    echo "---"
    if command -v systemctl >/dev/null 2>&1; then
        systemctl --version | head -1
    else
        echo "systemctl: NOT FOUND"
    fi
    echo "---"
    command -v go >/dev/null 2>&1 && go version || echo "go: NOT FOUND"
    command -v make >/dev/null 2>&1 && make --version | head -1 || echo "make: NOT FOUND"
    command -v git >/dev/null 2>&1 && git --version || echo "git: NOT FOUND"

    section "3. REPO STATE ($REPO_ROOT)"
    cd "$REPO_ROOT"
    echo "HEAD:"
    git log -1 --oneline 2>&1
    echo "---"
    echo "dirty files (git status --short):"
    git status --short 2>&1
    echo "---"
    echo "remotes:"
    git remote -v 2>&1
    echo "---"
    echo "branch tracking:"
    git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>&1

    section "4. SHIPPED EXAMPLE CONFIG (first 5 lines of repo's example)"
    head -5 "$REPO_ROOT/oom-watch/config/oom-watch.example.json" 2>&1
    echo "..."
    echo "(SHA256: $(sha256sum "$REPO_ROOT/oom-watch/config/oom-watch.example.json" 2>&1 | awk '{print $1}'))"

    section "5. INSTALLED PATHS"
    for p in \
        /usr/local/sbin/oomwatch \
        /etc/oom-watch \
        /etc/oom-watch/config.json \
        /etc/systemd/system/oom-watch.service \
        /var/log/oom-watch \
        /var/log/oom-watch/reports \
        /var/lib/oom-watch
    do
        if [[ -e "$p" ]]; then
            ls -la "$p" 2>&1
        else
            echo "MISSING: $p"
        fi
    done

    section "6. INSTALLED CONFIG (full cat)"
    if [[ -f /etc/oom-watch/config.json ]]; then
        cat /etc/oom-watch/config.json
        echo "---"
        echo "(SHA256: $(sha256sum /etc/oom-watch/config.json 2>&1 | awk '{print $1}'))"
    else
        echo "MISSING: /etc/oom-watch/config.json"
    fi

    section "7. DRY-RUN AGAINST INSTALLED CONFIG"
    if [[ -x /usr/local/sbin/oomwatch ]]; then
        /usr/local/sbin/oomwatch -config /etc/oom-watch/config.json -dry-run 2>&1
        echo "rc=$?"
    else
        echo "MISSING: /usr/local/sbin/oomwatch"
    fi

    section "8. UNIT STATE"
    if systemctl cat oom-watch.service >/dev/null 2>&1; then
        echo "is-enabled: $(systemctl is-enabled oom-watch.service 2>&1)"
        echo "is-active:  $(systemctl is-active oom-watch.service 2>&1)"
        echo "is-failed:  $(systemctl is-failed oom-watch.service 2>&1)"
        echo "---"
        systemctl status oom-watch.service --no-pager -n 50 2>&1
    else
        echo "unit oom-watch.service not registered with systemd"
    fi

    section "9. UNIT FILE (full cat)"
    if [[ -f /etc/systemd/system/oom-watch.service ]]; then
        cat /etc/systemd/system/oom-watch.service
    else
        echo "MISSING: /etc/systemd/system/oom-watch.service"
    fi

    section "10. JOURNAL (last 200 lines for oom-watch.service)"
    journalctl -u oom-watch.service -n 200 --no-pager 2>&1

    section "11. REPORTS DIRECTORY"
    if [[ -d /var/log/oom-watch/reports ]]; then
        ls -la /var/log/oom-watch/reports/ 2>&1
        echo "---"
        echo "report count: $(find /var/log/oom-watch/reports -name '*.md' 2>/dev/null | wc -l)"
        echo "newest report: $(ls -t /var/log/oom-watch/reports/*.md 2>/dev/null | head -1)"
    else
        echo "MISSING: /var/log/oom-watch/reports/"
    fi

    section "12. ATOP LIVE SAMPLE (sanity check that atop itself works)"
    if command -v atop >/dev/null 2>&1; then
        echo "Running 'atop -PMEM,PSI,CPL 1 2'..."
        timeout 10 atop -PMEM,PSI,CPL 1 2 2>&1 | head -20
    else
        echo "atop missing — skipped"
    fi

    if (( NO_DEPLOY == 0 )); then
        section "13. FULL DEPLOY ATTEMPT (make oomwatch-deploy, all step headers visible)"
        echo "Running: make oomwatch-deploy"
        echo "..."
        ( cd "$REPO_ROOT" && make oomwatch-deploy 2>&1 )
        echo "make rc=$?"

        section "14. POST-DEPLOY UNIT STATE"
        echo "is-active:  $(systemctl is-active oom-watch.service 2>&1)"
        echo "---"
        systemctl status oom-watch.service --no-pager -n 30 2>&1

        section "15. POST-DEPLOY JOURNAL (last 50 lines)"
        journalctl -u oom-watch.service -n 50 --no-pager 2>&1

        section "16. POST-DEPLOY REPORTS"
        if [[ -d /var/log/oom-watch/reports ]]; then
            ls -la /var/log/oom-watch/reports/ 2>&1
        else
            echo "MISSING: /var/log/oom-watch/reports/"
        fi
    else
        section "13. DEPLOY ATTEMPT (skipped per --no-deploy)"
    fi

    section "END"
    date -Is

} 2>&1 | tee "$LOG"

echo
echo "===================================================================="
echo "Diagnostic log written to: $LOG"
echo "Size: $(wc -c < "$LOG") bytes, $(wc -l < "$LOG") lines"
echo "Paste the file's contents back so the issue can be diagnosed."
echo "===================================================================="
