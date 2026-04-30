#!/usr/bin/env bash
# Challenge: oomwatch must FAIL LOUDLY if atop is missing.
#
# We were burned by silent zero-output features. Validate that the daemon
# treats a missing atop as a fatal startup error and exits non-zero. A
# product that "starts fine" but does nothing is exactly the bluff the
# Constitution forbids.

CHAL_NAME="no-atop"
. "$(dirname "$0")/lib.sh"

chal_require go

bin="$(chal_build_oomwatch)"
sandbox="$(mktemp -d)"
trap 'rm -rf "$sandbox"' EXIT

# Empty PATH directory → atop unfindable.
PATH="$sandbox" "$bin" -dry-run >/dev/null
chal_ok "-dry-run still succeeds when atop is missing (config validation only)"

# Now run the real daemon mode under empty PATH; expect non-zero.
set +e
PATH="$sandbox" "$bin" 2>"$sandbox/stderr"
rc=$?
set -e

chal_assert "[[ $rc -ne 0 ]]"     "daemon exits non-zero when atop is missing (got rc=$rc)"
chal_assert_file_contains "$sandbox/stderr" "atop"
chal_assert_file_contains "$sandbox/stderr" "not found"

chal_summary "verified: oom-watch refuses to start (rc=$rc) and prints a clear 'atop not found' error when atop is absent"
