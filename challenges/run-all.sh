#!/usr/bin/env bash
# Run every Challenge. Exits non-zero on the first failure.
#
# Per Constitution Article I, this script's green output is part of the
# definition of done for any change.

set -Eeuo pipefail
here="$(cd "$(dirname "$0")" && pwd)"

if [[ -t 1 ]]; then
    G=$'\033[32m'; R=$'\033[31m'; B=$'\033[1m'; C=$'\033[0m'
else
    G=""; R=""; B=""; C=""
fi

challenges=(
    "$here/challenge-no-atop.sh"
    "$here/challenge-config-validation.sh"
    "$here/challenge-one-shot-report.sh"
    "$here/challenge-memory-pressure.sh"
    "$here/challenge-real-atop.sh"
    "$here/challenge-tests-are-not-bluffs.sh"
)

passed=0
failed=0
failed_names=()
for c in "${challenges[@]}"; do
    printf '%s== %s ==%s\n' "$B" "$(basename "$c")" "$C"
    if bash "$c"; then
        passed=$((passed+1))
    else
        failed=$((failed+1))
        failed_names+=( "$(basename "$c")" )
    fi
    echo
done

printf '%schallenges passed: %d / %d%s\n' "$G" "$passed" "${#challenges[@]}" "$C"
if (( failed > 0 )); then
    printf '%sfailed:%s %s\n' "$R" "$C" "${failed_names[*]}"
    exit 1
fi
