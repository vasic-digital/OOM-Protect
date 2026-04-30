#!/usr/bin/env bash
# Challenge: an invalid config (warn > critical) must be REJECTED at -dry-run.
# Anti-bluff: a daemon that accepts nonsense thresholds and runs forever
# without ever firing is the worst kind of broken.

CHAL_NAME="config-validation"
. "$(dirname "$0")/lib.sh"

chal_require go
bin="$(chal_build_oomwatch)"
sandbox="$(mktemp -d)"
trap 'rm -rf "$sandbox"' EXIT

# Bad config: warn > critical (impossible ordering).
cat > "$sandbox/bad.json" <<EOF
{
  "thresholds": {
    "memory_used_ratio_warn": 0.99,
    "memory_used_ratio_critical": 0.50
  }
}
EOF

set +e
"$bin" -config "$sandbox/bad.json" -dry-run 2>"$sandbox/err"
rc=$?
set -e
chal_assert "[[ $rc -ne 0 ]]" "exits non-zero on bad config (rc=$rc)"
chal_assert_file_contains "$sandbox/err" "memory_used_ratio"

# Unknown field must also be rejected (typo guard).
cat > "$sandbox/typo.json" <<EOF
{ "intervall_seconds": 5 }
EOF
set +e
"$bin" -config "$sandbox/typo.json" -dry-run 2>"$sandbox/err2"
rc2=$?
set -e
chal_assert "[[ $rc2 -ne 0 ]]" "exits non-zero on typo'd field (rc=$rc2)"

# Good config passes.
cat > "$sandbox/good.json" <<EOF
{ "interval_seconds": 5 }
EOF
"$bin" -config "$sandbox/good.json" -dry-run >/dev/null
chal_ok "good config passes -dry-run"

chal_summary "verified: invalid threshold ordering is rejected (rc=$rc), unknown fields are rejected (rc=$rc2), and a minimal valid config succeeds"
