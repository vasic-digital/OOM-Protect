#!/usr/bin/env bash
# challenges/lib.sh — shared helpers for OOM-Protect Challenges.
#
# Per Constitution Article I, every Challenge here MUST exercise the real
# product end-to-end. The helpers below enforce that discipline:
#
#   - chal_require <cmd>             fail loudly if a precondition is missing
#   - chal_assert <cond> <message>   stop on first false assertion
#   - chal_summary "section" "..."   print a verifiable success line
#
# Bare 'OK' is forbidden. Every passing Challenge prints exactly what it
# verified, so a reader of the script's output can audit the claim.

set -Eeuo pipefail

# Disable Go's VCS stamping for every 'go build' / 'go test' invocation
# launched by any Challenge. The repo may live on a filesystem owned by
# a UID different from the one running the Challenge (typical: external
# drive owned by user 1000, Challenge run as root). On such layouts git
# refuses to operate ('dubious ownership'), and 'go build' fails with
# 'error obtaining VCS status: exit status 128'. We do not read the
# stamp anywhere in the produced binaries, so disabling it is a
# zero-risk, zero-cost belt-and-suspenders against this whole class of
# failure. Append rather than overwrite so a caller's own GOFLAGS wins.
export GOFLAGS="${GOFLAGS:-} -buildvcs=false"

if [[ -t 1 ]]; then
    G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; B=$'\033[1m'; C=$'\033[0m'
else
    G=""; Y=""; R=""; B=""; C=""
fi

CHAL_NAME="${CHAL_NAME:-$(basename "${BASH_SOURCE[1]:-challenge}" .sh)}"

chal_log()  { printf '%s[%s]%s %s\n' "$B" "$CHAL_NAME" "$C" "$*" >&2; }
chal_ok()   { printf '%s[%s] OK%s %s\n' "$G" "$CHAL_NAME" "$C" "$*" >&2; }
chal_fail() { printf '%s[%s] FAIL%s %s\n' "$R" "$CHAL_NAME" "$C" "$*" >&2; exit 2; }
chal_warn() { printf '%s[%s] WARN%s %s\n' "$Y" "$CHAL_NAME" "$C" "$*" >&2; }

chal_require() {
    local cmd="$1"
    command -v "$cmd" >/dev/null 2>&1 \
        || chal_fail "missing prerequisite: $cmd not found in PATH"
}

# chal_assert <bool-expression-as-string> <human-message>
# Example: chal_assert "[[ -f $path ]]" "report file exists"
#
# DANGER: chal_assert's first argument is shell-expanded by the CALLER
# before chal_assert sees it, then re-evaluated via eval here. Both layers
# expand backticks ` ` and $(...). This is fine for tests against simple
# variables (paths, integers, exit codes), but NEVER pass content captured
# from external sources — markdown reports, journal lines, command output —
# through chal_assert. A markdown report containing "`bash script.sh`" will
# execute that script when the outer double-quotes expand the backticks.
#
# For content-bearing tests, use direct inline forms:
#   if [[ -n "$captured_content" ]]; then chal_ok "..."; else chal_fail "..."; fi
#   if grep -qF "$needle" "$file"; then chal_ok "..."; else chal_fail "..."; fi
#
# This caused a real fork-bomb-class bug in challenge-real-pressure.sh on
# 2026-04-30 — see that script's "(6) Forensic detail" section for the
# postmortem comment.
chal_assert() {
    local expr="$1" msg="$2"
    if eval "$expr"; then
        chal_ok "asserted: $msg"
    else
        chal_fail "assertion failed: $msg ($expr)"
    fi
}

# chal_assert_var <variable-name> <bool-test> <human-message>
# Indirect-expansion form for content-bearing assertions. The variable name
# is expanded via ${!name} INSIDE this function, so backticks in the value
# are never re-evaluated by the caller's outer quoting.
#
# Supported tests: nonempty, empty.
#
# Example:
#   forensic=$(sed -n '/## …/,/## …/p' "$report")
#   chal_assert_var forensic nonempty "report has forensic section"
chal_assert_var() {
    local varname="$1" test="$2" msg="$3"
    local value="${!varname}"
    case "$test" in
        nonempty)
            if [[ -n "$value" ]]; then chal_ok "$msg"; else chal_fail "$msg"; fi
            ;;
        empty)
            if [[ -z "$value" ]]; then chal_ok "$msg"; else chal_fail "$msg (value: ${value:0:200})"; fi
            ;;
        *)
            chal_fail "chal_assert_var: unknown test '$test' (use 'nonempty' or 'empty')"
            ;;
    esac
}

chal_assert_file_contains() {
    local path="$1" needle="$2"
    if [[ ! -f "$path" ]]; then
        chal_fail "file does not exist: $path"
    fi
    if grep -qF -- "$needle" "$path"; then
        chal_ok "file $path contains $(printf '%q' "$needle")"
    else
        chal_fail "file $path does NOT contain $(printf '%q' "$needle"); first 40 lines follow:
$(head -40 "$path")"
    fi
}

# chal_summary "passed: feature X verified end-to-end"
# Required final line; must be specific.
chal_summary() {
    printf '%s[%s] PASS%s %s\n' "$G" "$CHAL_NAME" "$C" "$*"
}

# Resolve repo root (challenges/ is at top level).
chal_repo_root() {
    cd "$(dirname "${BASH_SOURCE[1]}")/.."
    pwd
}

# Build the oomwatch binary into a temp location and echo the path. Subsequent
# Challenges can reuse the same build by setting OOMWATCH_BIN before sourcing
# this lib.
chal_build_oomwatch() {
    if [[ -n "${OOMWATCH_BIN:-}" && -x "${OOMWATCH_BIN}" ]]; then
        printf '%s' "$OOMWATCH_BIN"
        return
    fi
    local root
    root="$(chal_repo_root)"
    local out="${root}/oom-watch/oomwatch"
    chal_log "building oomwatch -> $out"
    (cd "${root}/oom-watch" && go build -o oomwatch ./cmd/oomwatch) \
        || chal_fail "go build failed"
    [[ -x "$out" ]] || chal_fail "binary not produced at $out"
    printf '%s' "$out"
}

# Place a fake atop binary in $1 (a directory) that emits a canned payload
# when invoked. Used by Challenges that don't have real atop installed.
# Args: target_dir, fixture_path
chal_install_fake_atop() {
    local dir="$1" fixture="$2"
    [[ -d "$dir" ]] || chal_fail "fake atop dir does not exist: $dir"
    [[ -f "$fixture" ]] || chal_fail "fake atop fixture not found: $fixture"
    cat > "$dir/atop" <<EOF
#!/bin/sh
cat $(printf '%q' "$fixture")
EOF
    chmod +x "$dir/atop"
    chal_ok "fake atop installed at $dir/atop (emits $fixture)"
}
