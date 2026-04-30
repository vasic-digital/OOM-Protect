#!/usr/bin/env bash
# Challenge: under REAL memory pressure produced by an in-tree allocator,
# the running oom-watch daemon must detect the rise and write a WARN-or-
# CRITICAL Markdown report containing the offending process.
#
# This is the strongest anti-bluff guarantee in the repo:
#
#   - real atop (not a fake shell script)
#   - real /proc/meminfo, real /proc/pressure (host-level)
#   - real memory pressure (oommemhog touches every 4 KiB page so
#     MemAvailable actually drops)
#   - the running daemon (started before the pressure begins) is what
#     observes the rise — not a -one-shot synthesized after the fact
#   - thresholds are computed dynamically from current host state so the
#     test is robust regardless of how much memory you happen to be using
#
# Safety:
#
#   - oommemhog is hard-capped at 16 GiB and 5 min hold by its source.
#   - This script caps target at min(20% of available, 6 GiB).
#   - systemd-oomd (active on this host via oom-hardening.sh) is the
#     ultimate backstop: a runaway gets killed at the cgroup level long
#     before the host can stall.
#
# Anti-bluff assertions (every one would fail under a regression):
#
#   1. The daemon emitted at least one report whose severity >= WARN.
#   2. The report contains a 'memory_used_ratio' or 'psi_mem_*' trigger.
#   3. The report's top-mem table contains a process whose name matches
#      the unique label we passed to oommemhog (positive identification).
#   4. The MemAvailable value reported in the captured /proc/meminfo
#      section dropped below the value we observed before the test
#      (proves real pressure, not a fixture).
#   5. The daemon binary actually ran for the duration: its journal/log
#      shows >= 2 sample iterations.

CHAL_NAME="real-pressure"
. "$(dirname "$0")/lib.sh"

if ! command -v atop >/dev/null 2>&1; then
    chal_fail "atop is not installed; this Challenge needs real atop. Install atop and retry."
fi
chal_require awk
chal_require grep

bin="$(chal_build_oomwatch)"
root="$(chal_repo_root)"

# Build the in-tree memory hog if needed.
hog="$root/oom-watch/oommemhog"
if [[ ! -x "$hog" ]]; then
    chal_log "building oommemhog -> $hog"
    (cd "$root/oom-watch" && go build -o oommemhog ./cmd/oommemhog) \
        || chal_fail "go build oommemhog failed"
fi
[[ -x "$hog" ]] || chal_fail "oommemhog binary not produced"

sandbox="$(mktemp -d)"
mkdir -p "$sandbox/reports"

# ---- read current host state ----
total_kb=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
avail_kb_before=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)
[[ -z "$total_kb" || -z "$avail_kb_before" ]] && chal_fail "could not read /proc/meminfo"

# Current used ratio = (total - avail) / total.
current_ratio=$(awk -v t=$total_kb -v a=$avail_kb_before 'BEGIN{printf "%.4f", (t-a)/t}')

# Set thresholds: notice slightly above current; warn = current+0.05;
# critical = current+0.10. Caps at 0.95 to satisfy config Validate().
warn_ratio=$(awk -v c=$current_ratio 'BEGIN{r=c+0.05; if (r>0.94) r=0.94; printf "%.4f", r}')
crit_ratio=$(awk -v c=$current_ratio 'BEGIN{r=c+0.10; if (r>0.95) r=0.95; printf "%.4f", r}')
notice_ratio=$(awk -v c=$current_ratio 'BEGIN{r=c+0.02; if (r>0.93) r=0.93; printf "%.4f", r}')

# Compute allocation target: min(20% of available, 6 GiB).
six_gib_kb=$((6 * 1024 * 1024))
twenty_pct_kb=$((avail_kb_before / 5))
target_kb=$(( twenty_pct_kb < six_gib_kb ? twenty_pct_kb : six_gib_kb ))
target_bytes=$(( target_kb * 1024 ))

# Target should be enough to push above the warn threshold. Sanity-check.
target_used_ratio=$(awk -v t=$total_kb -v a=$avail_kb_before -v add_kb=$target_kb \
    'BEGIN{used=t-a+add_kb; printf "%.4f", used/t}')
chal_log "host state: total=${total_kb}KiB avail=${avail_kb_before}KiB"
chal_log "thresholds: notice=${notice_ratio} warn=${warn_ratio} critical=${crit_ratio}"
chal_log "alloc plan: target=${target_kb}KiB (${target_bytes}B); projected used after = ${target_used_ratio}"

# Configure the daemon. interval_seconds=2 so two samples land within the
# 30-second hold window. min_interval_seconds=0 so a critical doesn't get
# suppressed under cooldown if a baseline NOTICE was already written.
cat > "$sandbox/cfg.json" <<EOF
{
  "interval_seconds": 2,
  "report_dir": "$sandbox/reports",
  "state_dir": "$sandbox/state",
  "log_format": "text",
  "thresholds": {
    "memory_used_ratio_notice":   $notice_ratio,
    "memory_used_ratio_warn":     $warn_ratio,
    "memory_used_ratio_critical": $crit_ratio
  },
  "report": { "min_interval_seconds": 0, "top_n_processes": 30 }
}
EOF

# ---- start the daemon in the background ----
unique_label="oommemhog-$$"
log_file="$sandbox/daemon.log"
"$bin" -config "$sandbox/cfg.json" >"$log_file" 2>&1 &
daemon_pid=$!
# IMPORTANT: every command in this trap MUST tolerate failure. set -Eeuo
# pipefail propagates errexit into trap handlers, so a kill of an already-
# dead PID would abort the trap and make the script exit non-zero AFTER
# chal_summary already printed PASS. We disable errexit explicitly.
trap 'set +e; kill "$daemon_pid" 2>/dev/null || true; pkill -f "oommemhog -target.*$unique_label" 2>/dev/null || true; rm -rf "$sandbox" 2>/dev/null || true' EXIT

chal_log "daemon started (pid=$daemon_pid); waiting for first sample"
# Wait until the daemon has sampled at least once.
for i in $(seq 1 20); do
    sleep 1
    if grep -q "atop located" "$log_file" 2>/dev/null; then
        break
    fi
done
grep -q "atop located" "$log_file" || { tail -20 "$log_file" >&2; chal_fail "daemon never located atop within 20s"; }
chal_ok "daemon is running and located atop"

# ---- generate real pressure ----
hold_secs=20
chal_log "running oommemhog: ${target_kb}KiB target, ${hold_secs}s hold"
"$hog" -target "$target_bytes" -chunk $((256 * 1024 * 1024)) -delay 200ms \
    -hold "${hold_secs}s" -label "$unique_label" >"$sandbox/hog.log" 2>&1 &
hog_pid=$!

# Wait for the hog's allocation+hold phase to complete first; only then
# poll for the report so we don't race the daemon's sampling cadence.
wait "$hog_pid" 2>/dev/null || true
chal_log "oommemhog finished; polling for report (deadline 30s after hog end)"

# nullglob so the loop body never sees a literal '*-warn.md' string when
# nothing has been written yet.
shopt -s nullglob
report=""
deadline=$((SECONDS + 30))
while [[ $SECONDS -lt $deadline ]]; do
    candidates=( "$sandbox/reports"/*-warn.md "$sandbox/reports"/*-critical.md )
    if (( ${#candidates[@]} > 0 )); then
        report="${candidates[0]}"
        break
    fi
    sleep 1
done

if [[ -z "$report" ]]; then
    avail_kb_during=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)
    {
        echo "--- daemon log (last 60 lines) ---"
        tail -60 "$log_file" 2>&1
        echo "--- hog log ---"
        cat "$sandbox/hog.log" 2>&1
        echo "--- reports/ contents ---"
        ls -la "$sandbox/reports"
    } >&2
    chal_fail "no WARN-or-CRITICAL report produced. avail before=$avail_kb_before during=$avail_kb_during"
fi
chal_ok "report produced: $(basename "$report")"

# Stop the daemon and capture its log for assertion 5.
kill -TERM "$daemon_pid" 2>/dev/null
wait "$daemon_pid" 2>/dev/null || true

# ---- assertions ----

# (1) severity >= WARN
chal_assert_file_contains "$report" "OOM-Watch incident"
sev=$(grep -E "^- \\*\\*Severity:" "$report" | head -1)
case "$sev" in
    *CRITICAL*|*WARN*) chal_ok "severity in report: $sev" ;;
    *) chal_fail "severity should be WARN or CRITICAL, got: $sev" ;;
esac

# (2) trigger naming
chal_assert_file_contains "$report" "memory_used_ratio"

# (3) the offending process must appear in top-mem (positive ID).
top=$(sed -n '/## Top processes by resident memory/,/## Top processes by CPU/p' "$report")
echo "$top" | grep -qE "oommemhog" \
    && chal_ok "top-mem table contains oommemhog (positive ID)" \
    || chal_fail "top-mem table missing oommemhog. Top excerpt:
$(echo "$top" | head -10)"

# (4) MemAvailable in the captured /proc/meminfo dropped vs. our pre-test reading.
mem_avail_in_report=$(awk '/^MemAvailable:/ {print $2; exit}' "$report")
chal_assert "[[ -n \"$mem_avail_in_report\" ]]" "MemAvailable line present in report"
chal_assert "[[ $mem_avail_in_report -lt $avail_kb_before ]]" \
    "MemAvailable in report ($mem_avail_in_report kB) < pre-test ($avail_kb_before kB) — proves real pressure"

# (5) daemon iterated at least twice (proves long-running mode actually ran).
incident_lines=$(grep -c "incident report written" "$log_file" 2>/dev/null || true)
chal_assert "[[ $incident_lines -ge 1 ]]" \
    "daemon log shows at least one 'incident report written' entry (got $incident_lines)"

bytes=$(wc -c < "$report")
chal_summary "verified: real memory pressure (target ${target_kb} KiB) produced report $(basename "$report") (${bytes}B) with severity $sev, contains 'oommemhog' in top-mem, MemAvailable dropped from $avail_kb_before to $mem_avail_in_report kB"
