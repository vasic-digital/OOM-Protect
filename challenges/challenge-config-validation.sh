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

# The shipped example config MUST itself pass -dry-run. We were burned once
# when oom-watch.example.json contained a _comment key that was rejected
# by DisallowUnknownFields, so 'make oomwatch-install' copied a broken
# config to /etc/oom-watch/config.json and the daemon refused to start.
# Anti-bluff: this assertion would have failed on that commit.
example_cfg="$(chal_repo_root)/oom-watch/config/oom-watch.example.json"
[[ -f "$example_cfg" ]] || chal_fail "shipped example config not found at $example_cfg"
"$bin" -config "$example_cfg" -dry-run >/dev/null \
    || chal_fail "shipped example config $example_cfg fails -dry-run; would brick a fresh install"
chal_ok "shipped example config passes -dry-run (no install-time bricking)"

chal_summary "verified: invalid threshold ordering is rejected (rc=$rc), unknown fields are rejected (rc=$rc2), a minimal valid config succeeds, AND the shipped oom-watch.example.json itself passes -dry-run"
