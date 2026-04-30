#!/usr/bin/env bash
# Challenge: oomwatch must drive REAL atop end-to-end and produce a report
# whose contents reflect the actual host state.
#
# Anti-bluff: the existing one-shot Challenge uses a *fake* atop shell script
# emitting a fixture. That proves the plumbing but cannot catch real-atop
# format quirks (per-thread PRM rows, optional fields, atop version drift).
# This Challenge runs real atop and asserts:
#
#   1. The report is written.
#   2. The reported "Memory used ratio" is non-zero — proves the parser
#      actually decoded a real MEM line (a parser regression that always
#      returned PhysPages=0 would show ratio=0).
#   3. The top-mem table contains a process whose name appears in `ps -e`
#      RIGHT NOW — proves PRM was decoded AND the snapshot's command-name
#      extraction round-tripped.
#   4. /proc/meminfo section in the report matches the live /proc/meminfo
#      MemTotal value within 1% — proves the live capture worked.
#   5. After filtering, no PID appears more than once in the top-mem table
#      (locks in the IsLeader fix from atop 2.x).
#
# Skipped (with clear reason, no t.Skip equivalent — exit non-zero) if atop
# is not installed: the Constitution forbids silent passes.

CHAL_NAME="real-atop"
. "$(dirname "$0")/lib.sh"

if ! command -v atop >/dev/null 2>&1; then
    chal_fail "atop is not installed on this host. Install atop and re-run. (Per Constitution Article I, a Challenge that cannot run is not a Challenge — it must fail loudly.)"
fi
chal_ok "real atop available: $(command -v atop) ($(atop -V 2>&1 | head -1 | awk '{print $2}'))"

bin="$(chal_build_oomwatch)"
sandbox="$(mktemp -d)"
trap 'rm -rf "$sandbox"' EXIT
reports="$sandbox/reports"
mkdir -p "$reports"

cat > "$sandbox/cfg.json" <<EOF
{
  "interval_seconds": 1,
  "report_dir": "$reports",
  "state_dir": "$sandbox/state"
}
EOF

# Run with the system PATH (real atop), not a fake.
"$bin" -config "$sandbox/cfg.json" -one-shot

# (1) report written
shopt -s nullglob
files=( "$reports"/*.md )
chal_assert "[[ ${#files[@]} -eq 1 ]]" "exactly 1 report written (got ${#files[@]})"
report="${files[0]}"

# (2) Memory used ratio is non-zero — anti-bluff against a parser that returns 0.
ratio_line=$(grep "Memory used ratio:" "$report" | head -1)
ratio=$(echo "$ratio_line" | grep -oE '[0-9]+\.[0-9]+' | head -1)
chal_assert "[[ -n \"$ratio\" ]]" "Memory used ratio line present: '$ratio_line'"
chal_assert "[[ \"$ratio\" != \"0.0000\" && \"$ratio\" != \"0.0\" ]]" \
    "Memory used ratio is non-zero ($ratio) — proves MEM was actually decoded"

# (3) at least one ps-visible process name appears in the report's top-mem table.
top_table=$(sed -n '/## Top processes by resident memory/,/## Top processes by CPU/p' "$report")
matched_proc=""
# Sample 20 long-lived processes from the live host; many will be in atop's PRM.
for proc in $(ps -eo comm= 2>/dev/null | sort -u | head -50); do
    [[ -z "$proc" ]] && continue
    # Skip extremely common short names that could match noise (e.g. "ps").
    [[ ${#proc} -lt 4 ]] && continue
    if echo "$top_table" | grep -qF "\`$proc\`"; then
        matched_proc="$proc"
        break
    fi
done
chal_assert "[[ -n \"$matched_proc\" ]]" \
    "top-mem table contains at least one process name ($matched_proc) currently visible in ps -e"

# (4) /proc/meminfo MemTotal in the report matches /proc/meminfo on disk.
report_memtotal=$(grep "^MemTotal:" "$report" | head -1 | awk '{print $2}')
live_memtotal=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
chal_assert "[[ -n \"$report_memtotal\" && -n \"$live_memtotal\" ]]" \
    "MemTotal values present (report=$report_memtotal live=$live_memtotal)"
# Allow 1% drift just in case atop sampled different page counts.
diff=$(( report_memtotal > live_memtotal ? report_memtotal - live_memtotal : live_memtotal - report_memtotal ))
allow=$(( live_memtotal / 100 ))
chal_assert "[[ $diff -le $allow ]]" \
    "report MemTotal ($report_memtotal kB) within 1% ($allow kB) of live /proc/meminfo ($live_memtotal kB); diff=$diff"

# (5) Each PID appears at most once in the top-mem table (IsLeader filter).
dup_count=$(echo "$top_table" | awk -F'|' '/^\|/ && $2 ~ /[0-9]/ {gsub(" ","",$2); print $2}' \
    | sort | uniq -d | wc -l)
chal_assert "[[ $dup_count -eq 0 ]]" \
    "no duplicate PIDs in top-mem table (atop 2.x per-thread rows are filtered; got $dup_count duplicates)"

bytes=$(wc -c < "$report")
chal_summary "verified: real atop $(atop -V 2>&1 | head -1 | awk '{print $2}') drove oomwatch end-to-end. Report at $report (${bytes} bytes), MemTotal matched within 1%, ratio=$ratio (non-zero), top-mem listed real running process '$matched_proc', no per-thread duplicates"
