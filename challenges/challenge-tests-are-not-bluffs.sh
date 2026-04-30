#!/usr/bin/env bash
# Challenge: prove the test suite itself is not a bluff.
#
# Per Constitution Article I, "passing tests must prove the product works."
# This Challenge implements the mandatory mutation audit: it temporarily
# breaks one well-known production line, runs the tests, confirms they
# turn red, then restores the file. If the tests stay green under mutation,
# they are bluffs and the suite fails this Challenge.

CHAL_NAME="tests-are-not-bluffs"
. "$(dirname "$0")/lib.sh"

chal_require go
chal_require sed

root="$(chal_repo_root)"
target="$root/oom-watch/internal/atop/parser.go"
[[ -f "$target" ]] || chal_fail "target file missing: $target"

backup="$(mktemp)"
trap 'cp "$backup" "$target"; rm -f "$backup"' EXIT
cp "$target" "$backup"

# Mutation 1: break MemAvailable parsing (zero it out).
sed -i 's/AvailPages: pi(24)/AvailPages: 0/' "$target"
chal_log "mutation applied: AvailPages forced to 0"

set +e
(cd "$root/oom-watch" && go test -count=1 ./internal/atop/... >/dev/null 2>&1)
mutated_rc=$?
set -e
chal_assert "[[ $mutated_rc -ne 0 ]]" \
    "atop tests FAIL under AvailPages mutation (rc=$mutated_rc; if 0 the tests are bluffs)"

# Restore.
cp "$backup" "$target"
(cd "$root/oom-watch" && go test -count=1 ./internal/atop/... >/dev/null 2>&1) \
    || chal_fail "tests should pass after restore but did not"
chal_ok "tests pass again after restoring the mutation"

chal_summary "verified: the atop parser tests are NOT bluffs — mutating AvailPages parsing turns them red (rc=$mutated_rc); restore returns them to green"
