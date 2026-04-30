#!/usr/bin/env bash
# Challenge: --one-shot must produce a real Markdown report on disk that
# contains the host name, severity heading, and the atop sample data.
#
# We use a fake atop on $PATH (since real atop may not be installed in CI)
# to feed deterministic input, but the binary under test is the unmodified
# production binary. Reading the produced report is the assertion.

CHAL_NAME="one-shot-report"
. "$(dirname "$0")/lib.sh"

chal_require go

bin="$(chal_build_oomwatch)"
root="$(chal_repo_root)"
fixture="$root/oom-watch/internal/atop/testdata/sample.txt"
[[ -f "$fixture" ]] || chal_fail "fixture missing: $fixture"

sandbox="$(mktemp -d)"
trap 'rm -rf "$sandbox"' EXIT
chal_install_fake_atop "$sandbox" "$fixture"

reports="$sandbox/reports"
mkdir -p "$reports"

cat > "$sandbox/cfg.json" <<EOF
{
  "interval_seconds": 1,
  "report_dir": "$reports",
  "state_dir": "$sandbox/state",
  "atop_binary": "atop",
  "thresholds": {
    "memory_used_ratio_critical": 0.99,
    "memory_used_ratio_warn": 0.97,
    "memory_used_ratio_notice": 0.50
  }
}
EOF

PATH="$sandbox:$PATH" "$bin" -config "$sandbox/cfg.json" -one-shot

# Exactly one report should exist.
shopt -s nullglob
files=( "$reports"/*.md )
chal_assert "[[ ${#files[@]} -eq 1 ]]" "exactly 1 report file present (got ${#files[@]})"

report="${files[0]}"
chal_log "report = $report"
chal_assert_file_contains "$report" "OOM-Watch incident"
chal_assert_file_contains "$report" "severity:"
chal_assert_file_contains "$report" "## Atop sample summary"
chal_assert_file_contains "$report" "PSI memory.full"

# Atomic write left no .tmp leftovers.
leftovers=( "$reports"/.oom-watch-*.tmp )
chal_assert "[[ ${#leftovers[@]} -eq 0 ]]" "no leftover .tmp files in report dir"

bytes=$(wc -c < "$report")
chal_assert "[[ $bytes -gt 500 ]]" "report has substantial content (${bytes} bytes)"

chal_summary "verified: --one-shot produced $report (${bytes} bytes) with required sections (incident header, atop summary, PSI block) and no temp leftovers"
