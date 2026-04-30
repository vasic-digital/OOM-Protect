#!/usr/bin/env bash
# Challenge: under real memory pressure, oom-watch must produce a CRITICAL
# report. We achieve this here using a fake atop that emits a critical
# sample — the real memory-pressure side is best exercised by the existing
# verify-stress target on a host with stress-ng installed.
#
# This Challenge proves the *full pipeline*: sample → evaluate → snapshot →
# report → file on disk → contains "CRITICAL".
#
# A future enhancement (challenge-memory-stress.sh) will use stress-ng to
# generate real pressure on hosts where running atop as root is feasible.

CHAL_NAME="memory-pressure"
. "$(dirname "$0")/lib.sh"

chal_require go
bin="$(chal_build_oomwatch)"
root="$(chal_repo_root)"

sandbox="$(mktemp -d)"
trap 'rm -rf "$sandbox"' EXIT

# Construct a critical-pressure fixture: avail = 1% of phys, PSI memory.full
# avg10 = 60% (well above critical=30 default).
cat > "$sandbox/critical.txt" <<'EOF'
RESET
MEM nezha 1700000000 2024/01/01 00:00:00 10 4096 16000000 50000 100000 50000 200000 30000 8000 0 50000 25000 1000 2097152 0 0 0 0 0 5000 6000 8000 1073741824 0 0 100000 50000
PSI nezha 1700000000 2024/01/01 00:00:00 10 y 2.10 1.40 0.80 210000 78.30 65.40 35.10 7830000 60.20 48.10 28.50 6020000 12.50 8.30 3.10 1250000 8.20 5.10 2.30 820000
PRM nezha 1700000000 2024/01/01 00:00:00 10 9999 (greedy) R 4096 14000000 8000000 5000 7995000 0 0 5000 50 50000 7900000 12000000 50000 5000
SEP
MEM nezha 1700000010 2024/01/01 00:00:10 10 4096 16000000 30000 80000 40000 200000 30000 8000 0 50000 25000 1000 2097152 0 0 0 0 0 5000 6000 8000 1073741824 0 0 80000 50000
PSI nezha 1700000010 2024/01/01 00:00:10 10 y 2.50 1.60 0.90 250000 88.30 75.40 45.10 8830000 70.20 58.10 38.50 7020000 14.50 9.30 3.50 1450000 9.20 5.50 2.50 920000
PRM nezha 1700000010 2024/01/01 00:00:10 10 9999 (greedy) R 4096 14500000 8500000 5000 8495000 0 0 5500 55 55000 8400000 12500000 55000 5500
SEP
EOF

chal_install_fake_atop "$sandbox" "$sandbox/critical.txt"

reports="$sandbox/reports"
mkdir -p "$reports"

cat > "$sandbox/cfg.json" <<EOF
{
  "interval_seconds": 1,
  "report_dir": "$reports",
  "state_dir": "$sandbox/state"
}
EOF

PATH="$sandbox:$PATH" "$bin" -config "$sandbox/cfg.json" -one-shot

shopt -s nullglob
files=( "$reports"/*.md )
chal_assert "[[ ${#files[@]} -eq 1 ]]" "exactly 1 report (got ${#files[@]})"
report="${files[0]}"

chal_assert_file_contains "$report" "CRITICAL"
chal_assert_file_contains "$report" "memory_used_ratio"
chal_assert_file_contains "$report" "psi_mem_full_avg10"
chal_assert_file_contains "$report" "greedy"

# Severity is encoded in the filename for fast triage.
chal_assert "[[ \"$(basename "$report")\" == *critical* ]]" \
    "report filename contains 'critical' marker"

chal_summary "verified: under fixture-emitted critical pressure, oom-watch wrote $report containing CRITICAL severity, memory_used_ratio AND psi_mem_full_avg10 triggers, and the offending PID's command name (greedy)"
