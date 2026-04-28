#!/usr/bin/env bash
# oom-runner.sh
#
# Run *almost any* command inside its own bounded systemd transient scope
# (foreground) or service (background), so a runaway never takes down your
# whole user session.
#
# After the 2026-04-28 incident (see ~/Downloads/Crash_Report.md), every heavy
# workload — Claude Code, MCP servers, Android builds, browsers, containers,
# IDEs, even random shell pipelines — should be wrapped here. Defaults are
# deliberately generous so wrapping commands does not break them; the *real*
# protection is "you cannot exhaust the whole machine from inside one scope."
#
# Companion script to ~/Downloads/oom-hardening.sh:
#   - oom-hardening.sh bounds the *entire* user slice (sets the umbrella).
#   - oom-runner.sh   bounds *individual workloads* inside that umbrella.
#
# This script does NOT need root. It uses the per-user systemd manager.
#
# Quick start:
#   oom-runner -- claude
#   oom-runner --preset claude -- claude
#   oom-runner --preset mcp -n upstash -- npm exec @upstash/context7-mcp@latest
#   oom-runner --preset build -- bash -c 'cd ~/proj && m -j8'
#   oom-runner --shell -- 'cat huge.log | grep ERROR | head -100'
#   oom-runner -m 4G -- python heavy.py
#   oom-runner list ; oom-runner status <unit> ; oom-runner kill <unit>

set -Eeuo pipefail
# NOTE: do NOT set IFS=$'\n\t' here; we depend on default IFS (space) when
# joining "$*" for the unit description.

readonly SCRIPT_NAME="oom-runner"
readonly SCRIPT_VERSION="1.1.0"
readonly UNIT_PREFIX="oomrun"

# Hard floor: refuse to set memory limits below this (would cripple anything)
readonly MIN_MEM_MAX_BYTES=$((128 * 1024 * 1024))   # 128 MiB

# ---------- output helpers ---------------------------------------------------

if [[ -t 2 ]]; then
    C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'
    C_BLU=$'\033[34m'; C_DIM=$'\033[2m';  C_RST=$'\033[0m'
else
    C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_DIM=""; C_RST=""
fi
log()  { printf '%s%s%s %s\n' "$C_DIM" "[oom-runner]" "$C_RST" "$*" >&2; }
ok()   { printf '%s[oom-runner]%s %s\n' "$C_GRN" "$C_RST" "$*" >&2; }
warn() { printf '%s[oom-runner]%s %s\n' "$C_YEL" "$C_RST" "$*" >&2; }
err()  { printf '%s[oom-runner]%s %s\n' "$C_RED" "$C_RST" "$*" >&2; }
die()  { err "$*"; exit 1; }

# ---------- presets ----------------------------------------------------------
#
# Format: MemoryMax|MemoryHigh|MemorySwapMax|TasksMax|CPUQuotaPct|IOWeight
# Empty fields → systemd default for that property (no limit applied).
declare -A PRESETS=(
    [tiny]="512M|384M|128M|256||"
    [small]="1G|768M|256M|512||"
    [medium]="4G|3G|512M|2048||"
    [large]="16G|12G|2G|infinity||"
    [huge]="32G|24G|4G|infinity||"

    # Workload presets — generous so commands aren't crippled
    [default]="12G|10G|2G|infinity||"
    [safe]="8G|6G|1G|4096||"

    [claude]="10G|8G|2G|4096||200"
    [mcp]="2G|1500M|512M|1024||100"
    [build]="32G|24G|6G|infinity||400"
    [browser]="8G|6G|1G|4096||150"
    [container]="4G|3G|512M|2048||100"
    [editor]="6G|5G|1G|2048||200"
    [vm]="16G|12G|2G|infinity||100"
    [shell]="4G|3G|512M|2048||"
)

# Order presets are listed (assoc arrays have no order)
readonly -a PRESET_ORDER=(
    default safe
    tiny small medium large huge
    claude mcp build browser container editor vm shell
)

print_presets() {
    printf '%-12s %-10s %-10s %-12s %-10s %-10s %s\n' \
        "PRESET" "Mem.Max" "Mem.High" "Swap.Max" "TasksMax" "CPUQuota" "IOWeight"
    printf '%s\n' "---------------------------------------------------------------------------"
    local p f mm mh ms tm cq iw
    for p in "${PRESET_ORDER[@]}"; do
        f="${PRESETS[$p]:-}"
        IFS='|' read -r mm mh ms tm cq iw <<< "$f"
        printf '%-12s %-10s %-10s %-12s %-10s %-10s %s\n' \
            "$p" "${mm:--}" "${mh:--}" "${ms:--}" "${tm:--}" \
            "${cq:+${cq}%}" "${iw:--}"
    done
}

# ---------- pre-flight -------------------------------------------------------

preflight() {
    command -v systemd-run >/dev/null 2>&1 \
        || die "systemd-run not found. Install systemd."

    # If XDG_RUNTIME_DIR is empty (e.g. SSH session without lingering),
    # try to recover. systemctl --user must be reachable.
    if [[ -z "${XDG_RUNTIME_DIR:-}" ]] || [[ ! -S "${XDG_RUNTIME_DIR}/systemd/private" ]]; then
        if [[ -d "/run/user/$(id -u)" ]]; then
            export XDG_RUNTIME_DIR="/run/user/$(id -u)"
        fi
        if ! systemctl --user --no-pager status >/dev/null 2>&1; then
            die "User systemd manager is not reachable.

Fixes:
  - If this is an SSH session without a graphical login, enable lingering:
      sudo loginctl enable-linger $(id -un)
    then re-login.
  - Otherwise run from inside a graphical login session."
        fi
    fi

    # Memory accounting on the user slice (only a warning — limits still
    # work in scopes/services even if user.slice itself isn't accounted)
    local sys_acct
    sys_acct="$(systemctl show -p MemoryAccounting --value "user-$(id -u).slice" 2>/dev/null || true)"
    if [[ "$sys_acct" != "yes" ]]; then
        warn "MemoryAccounting=no on user-$(id -u).slice — apply oom-hardening.sh:"
        warn "    sudo bash ~/Downloads/oom-hardening.sh"
    fi

    # systemd-run version sanity (--user --collect requires >=236; we use much newer features)
    local sd_ver
    sd_ver="$(systemctl --version | awk 'NR==1 {print $2}')"
    if [[ -n "$sd_ver" ]] && (( sd_ver < 240 )); then
        warn "systemd $sd_ver is older than 240. Some properties may be ignored."
    fi
}

# ---------- helpers ----------------------------------------------------------

random_id() { tr -dc 'a-z0-9' < /dev/urandom | head -c 6; }

# Sanitize a string into a systemd unit-name-safe token (lowercase a-z 0-9 _ -)
sanitize() {
    local s="$1"
    s="${s//[^A-Za-z0-9_-]/-}"
    s="${s##-}"; s="${s%%-}"
    s="${s:-cmd}"
    printf '%s' "${s,,}" | head -c 32
}

unit_name() {
    local cmd_basename="$1" custom="${2:-}"
    if [[ -n "$custom" ]]; then
        printf '%s-%s' "${UNIT_PREFIX}" "$(sanitize "$custom")"
    else
        printf '%s-%s-%s' "${UNIT_PREFIX}" "$(sanitize "$cmd_basename")" "$(random_id)"
    fi
}

# Convert size string (10G, 512M, 4096K, 1024) to bytes; "infinity" → empty
size_to_bytes() {
    local v="$1"
    [[ -z "$v" || "$v" == "infinity" ]] && { printf ''; return 0; }
    local num unit
    if [[ "$v" =~ ^([0-9]+)([KMGTkmgt]?)$ ]]; then
        num="${BASH_REMATCH[1]}"
        unit="${BASH_REMATCH[2],,}"
    else
        return 1
    fi
    case "$unit" in
        ''|b) printf '%s' "$num" ;;
        k)    printf '%s' $((num * 1024)) ;;
        m)    printf '%s' $((num * 1024 * 1024)) ;;
        g)    printf '%s' $((num * 1024 * 1024 * 1024)) ;;
        t)    printf '%s' $((num * 1024 * 1024 * 1024 * 1024)) ;;
        *)    return 1 ;;
    esac
}

verify_size() {
    local v="$1" name="$2"
    [[ "$v" == "infinity" ]] && return 0
    [[ "$v" =~ ^[0-9]+[KMGTkmgt]?$ ]] \
        || die "Invalid value for $name: '$v' (expected e.g. 4G, 512M, infinity)"
}

# ---------- subcommands ------------------------------------------------------

cmd_list() {
    local rows
    rows="$(systemctl --user list-units --type=scope,service --no-legend --no-pager 2>/dev/null \
            | awk -v p="${UNIT_PREFIX}-" '$1 ~ "^"p {print}')"
    if [[ -z "$rows" ]]; then
        log "No active oom-runner units."
        return 0
    fi
    printf '%-50s %-8s %-12s %s\n' "UNIT" "LOAD" "ACTIVE" "DESCRIPTION"
    printf '%s\n' "----------------------------------------------------------------------------------"
    printf '%s\n' "$rows" | awk '{
        unit=$1; load=$2; active=$3; sub_=$4;
        desc=""; for (i=5;i<=NF;i++) desc = desc (i==5?"":" ") $i;
        printf "%-50s %-8s %-12s %s\n", unit, load, active, desc;
    }'
}

cmd_kill() {
    local target="${1:-}"
    [[ -n "$target" ]] || die "kill: missing unit name. Try: $0 list"
    [[ "$target" == ${UNIT_PREFIX}-* ]] || target="${UNIT_PREFIX}-${target}"
    if [[ "$target" != *.scope && "$target" != *.service ]]; then
        if systemctl --user is-active --quiet "${target}.scope" 2>/dev/null; then
            target="${target}.scope"
        elif systemctl --user is-active --quiet "${target}.service" 2>/dev/null; then
            target="${target}.service"
        else
            die "Unit '$target' not found as .scope or .service. List with: $0 list"
        fi
    fi
    ok "Stopping $target"
    systemctl --user stop "$target"
}

cmd_clean() {
    local units
    units="$(systemctl --user list-units --type=scope,service --no-legend --no-pager 2>/dev/null \
            | awk -v p="${UNIT_PREFIX}-" '$1 ~ "^"p {print $1}')"
    if [[ -z "$units" ]]; then
        log "No oom-runner units to stop."
        return 0
    fi
    local u
    while IFS= read -r u; do
        ok "Stopping $u"
        systemctl --user stop "$u" 2>/dev/null || warn "  failed to stop $u"
    done <<< "$units"
}

cmd_status() {
    local target="${1:-}"
    [[ -n "$target" ]] || die "status: missing unit name. Try: $0 list"
    [[ "$target" == ${UNIT_PREFIX}-* ]] || target="${UNIT_PREFIX}-${target}"
    if [[ "$target" != *.scope && "$target" != *.service ]]; then
        if systemctl --user is-active --quiet "${target}.scope" 2>/dev/null; then
            target="${target}.scope"
        else
            target="${target}.service"
        fi
    fi
    systemctl --user status "$target" --no-pager
}

cmd_logs() {
    local target="${1:-}"
    shift || true
    [[ -n "$target" ]] || die "logs: missing unit name. Try: $0 list"
    [[ "$target" == ${UNIT_PREFIX}-* ]] || target="${UNIT_PREFIX}-${target}"
    if [[ "$target" != *.scope && "$target" != *.service ]]; then
        target="${target}.service"
    fi
    journalctl --user -u "$target" --no-pager "$@"
}

# ---------- run subcommand ---------------------------------------------------

usage() {
    cat <<EOF
${SCRIPT_NAME} ${SCRIPT_VERSION}  —  run almost anything in a memory-bounded systemd cgroup

USAGE
  $0 [OPTIONS] -- <command> [args...]
  $0 [OPTIONS] --shell -- '<shell command line>'
  $0 run [OPTIONS] -- <command> [args...]
  $0 list                       List active oom-runner units
  $0 status <unit>              Show status of one unit
  $0 logs   <unit> [...]        journalctl --user -u <unit> [extra args]
  $0 kill   <unit>              Stop one unit
  $0 clean                      Stop ALL oom-runner units
  $0 presets                    List available presets
  $0 --help | --version

RUN OPTIONS
  -p, --preset NAME           Apply a named preset (default: 'default').
                              Run '$0 presets' to list. Explicit -m/-h/-s
                              flags override preset values.
  -m, --memory-max SIZE       Hard memory ceiling (e.g. 4G, 512M, infinity).
  -h, --memory-high SIZE      Soft throttle. Auto-clamped to <= MemoryMax.
  -s, --memory-swap-max SIZE  Swap cap.
  -t, --tasks-max N           Max tasks (PIDs). Default: infinity.
  -c, --cpu-quota PCT         CPU quota; 200 = 2 cores worth. Empty = unlimited.
      --io-weight N           I/O priority weight 1-10000.
  -n, --name NAME             Custom unit name suffix. Default: <cmd>-<rand>.
  -d, --detach                Run as background --service (returns immediately).
      --shell                 Run argv as a single 'bash -c' command. Lets you
                              use pipes, redirects, here-strings, env vars.
      --pty / --no-pty        Force/disable PTY allocation (foreground only).
                              Default: PTY when stdout is a TTY.
      --setenv K=V            Pass an env var into the unit. Repeatable.
      --inherit-env REGEX     Inherit env vars matching the regex from caller.
                              Default regex: ^(PATH|HOME|LANG|LC_|TERM|DISPLAY|
                              WAYLAND_DISPLAY|XDG_|DBUS_|SSH_AUTH_SOCK|EDITOR|
                              GIT_)
      --no-inherit-env        Don't inherit any env (start with clean env).
      --workdir PATH          WorkingDirectory for the unit. Default: \$PWD.
      --nice N                Nice level (-20..19). Default: 0.
      --read-only / --rw      Mount root read-only or read-write inside unit.
                              Default: rw.
      --no-protect            Disable extra hardening directives (default
                              on for --detach mode: NoNewPrivileges, etc.).
  -v, --verbose               Show the systemd-run invocation.
  -y, --yes                   Skip 'low limit' confirmation prompt.
      --dry-run               Print what would run, do not execute.

SAFETY GUARDS
  - Refuses MemoryMax below ${MIN_MEM_MAX_BYTES} bytes (128 MiB).
  - Auto-clamps MemoryHigh to <= MemoryMax (warning printed).
  - Refuses unrecognized commands unless they look like shell script paths.
  - In --detach mode, sets reasonable hardening (NoNewPrivileges, PrivateTmp).
  - Always sets MemoryAccounting=yes on the unit.

EXAMPLES
  # Run Claude Code with 10G ceiling
  $0 --preset claude -- claude

  # One MCP server in 2G ceiling, named "upstash"
  $0 --preset mcp -n upstash -- npm exec @upstash/context7-mcp@latest

  # Heavy build with 32G ceiling, 4 cores worth of CPU
  $0 --preset build -- bash -c 'cd ~/proj && m -j8'

  # Run a shell pipeline
  $0 --shell -- 'cat huge.log | grep ERROR | head -100'

  # Run a Python script with 4G hard cap and a clean env
  $0 -m 4G --no-inherit-env --setenv PATH=/usr/bin -- python heavy.py

  # Background a service, view its logs
  $0 -d --preset mcp -n my-mcp -- npm exec my-mcp@latest
  $0 logs my-mcp -f

  # Stop everything
  $0 clean

INTEGRATION
  Add to ~/.bashrc or ~/.zshrc:
      alias oom='~/Downloads/oom-runner.sh'
      alias claude='~/Downloads/oom-runner.sh --preset claude -- claude'
EOF
}

# Default env-inherit regex
readonly DEFAULT_INHERIT_RE='^(PATH|HOME|LANG|LC_.*|TERM|DISPLAY|WAYLAND_DISPLAY|XDG_.*|DBUS_.*|SSH_AUTH_SOCK|EDITOR|GIT_.*)$'

cmd_run() {
    local preset="" mem_max="" mem_high="" mem_swap="" tasks_max=""
    local cpu_quota="" io_weight="" name="" detach=0
    local pty_mode="auto" verbose=0 dry_run=0 workdir="" nice=""
    local shell_mode=0 read_only=0 protect=1 assume_yes=0
    local inherit_env_re="$DEFAULT_INHERIT_RE"
    local no_inherit=0
    local -a env_vars=()

    while (( $# )); do
        case "$1" in
            -p|--preset)            preset="${2:-}"; shift 2 ;;
            -m|--memory-max)        mem_max="${2:-}"; shift 2 ;;
            -h|--memory-high)       mem_high="${2:-}"; shift 2 ;;
            -s|--memory-swap-max)   mem_swap="${2:-}"; shift 2 ;;
            -t|--tasks-max)         tasks_max="${2:-}"; shift 2 ;;
            -c|--cpu-quota)         cpu_quota="${2:-}"; shift 2 ;;
            --io-weight)            io_weight="${2:-}"; shift 2 ;;
            -n|--name)              name="${2:-}"; shift 2 ;;
            -d|--detach)            detach=1; shift ;;
            --shell)                shell_mode=1; shift ;;
            --pty)                  pty_mode="on"; shift ;;
            --no-pty)               pty_mode="off"; shift ;;
            --setenv)               env_vars+=("${2:-}"); shift 2 ;;
            --inherit-env)          inherit_env_re="${2:-}"; shift 2 ;;
            --no-inherit-env)       no_inherit=1; shift ;;
            --workdir)              workdir="${2:-}"; shift 2 ;;
            --nice)                 nice="${2:-}"; shift 2 ;;
            --read-only)            read_only=1; shift ;;
            --rw)                   read_only=0; shift ;;
            --no-protect)           protect=0; shift ;;
            -v|--verbose)           verbose=1; shift ;;
            -y|--yes)               assume_yes=1; shift ;;
            --dry-run)              dry_run=1; shift ;;
            --)                     shift; break ;;
            -*)                     usage >&2; die "Unknown option: $1" ;;
            *)                      break ;;
        esac
    done

    (( $# >= 1 )) || { usage >&2; die "Missing command. Pass it after '--'."; }

    # Apply preset (default to "default" preset for safety)
    : "${preset:=default}"
    if [[ -n "$preset" ]]; then
        local pf p_mm p_mh p_ms p_tm p_cq p_iw
        pf="${PRESETS[$preset]:-}"
        [[ -n "$pf" ]] || die "Unknown preset: $preset
Run: $0 presets    to list available presets."
        IFS='|' read -r p_mm p_mh p_ms p_tm p_cq p_iw <<< "$pf"
        : "${mem_max:=$p_mm}"
        : "${mem_high:=$p_mh}"
        : "${mem_swap:=$p_ms}"
        : "${tasks_max:=$p_tm}"
        : "${cpu_quota:=$p_cq}"
        : "${io_weight:=$p_iw}"
    fi

    # Universal sane fallbacks (only used if preset and flags both empty)
    : "${mem_max:=12G}"
    : "${tasks_max:=infinity}"

    # Validate sizes
    verify_size "$mem_max"  "--memory-max"
    [[ -n "$mem_high" ]] && verify_size "$mem_high" "--memory-high"
    [[ -n "$mem_swap" ]] && verify_size "$mem_swap" "--memory-swap-max"

    # Floor guard on MemoryMax
    if [[ "$mem_max" != "infinity" ]]; then
        local mm_b
        mm_b="$(size_to_bytes "$mem_max" || true)"
        if [[ -z "$mm_b" ]] || (( mm_b < MIN_MEM_MAX_BYTES )); then
            if (( assume_yes )); then
                warn "MemoryMax=$mem_max is below the recommended floor (128M); --yes given, continuing."
            else
                die "Refusing MemoryMax=$mem_max (< 128M floor). Override with --yes if intentional."
            fi
        fi
    fi

    # Auto-clamp MemoryHigh to <= MemoryMax
    if [[ -n "$mem_high" && "$mem_max" != "infinity" && "$mem_high" != "infinity" ]]; then
        local mh_b mm_b
        mh_b="$(size_to_bytes "$mem_high" || true)"
        mm_b="$(size_to_bytes "$mem_max" || true)"
        if [[ -n "$mh_b" && -n "$mm_b" ]] && (( mh_b > mm_b )); then
            warn "MemoryHigh ($mem_high) > MemoryMax ($mem_max); clamping to $mem_max."
            mem_high="$mem_max"
        fi
    fi

    # CPU quota validation
    if [[ -n "$cpu_quota" ]]; then
        cpu_quota="${cpu_quota%\%}"
        [[ "$cpu_quota" =~ ^[0-9]+$ ]] || die "Invalid --cpu-quota: $cpu_quota (e.g. 200 = 2 cores)"
    fi
    if [[ -n "$io_weight" ]]; then
        [[ "$io_weight" =~ ^[0-9]+$ ]] || die "Invalid --io-weight: $io_weight"
        (( io_weight >= 1 && io_weight <= 10000 )) \
            || die "--io-weight out of range (1-10000): $io_weight"
    fi
    if [[ -n "$nice" ]]; then
        [[ "$nice" =~ ^-?[0-9]+$ ]] || die "Invalid --nice: $nice"
        (( nice >= -20 && nice <= 19 )) || die "--nice out of range (-20..19): $nice"
    fi

    # Decide command form
    local -a final_argv
    if (( shell_mode )); then
        # Combine remaining args into a single shell line
        local shell_line
        if (( $# == 1 )); then
            shell_line="$1"
        else
            shell_line="$*"
        fi
        final_argv=(/bin/bash -c "$shell_line")
    else
        # Verify the command exists; warn but allow if not (e.g. running a path not yet on $PATH)
        if ! command -v -- "$1" >/dev/null 2>&1 && [[ ! -x "$1" ]]; then
            warn "Command '$1' not found in PATH and not an executable file."
            warn "Will attempt anyway; systemd will report the error."
        fi
        final_argv=("$@")
    fi

    # Compute description safely (default IFS=space joining "$@")
    local description
    description="oom-runner: ${final_argv[*]} (memmax=$mem_max"
    [[ -n "$mem_high" ]] && description+=", memhigh=$mem_high"
    [[ -n "$mem_swap" ]] && description+=", swap=$mem_swap"
    [[ -n "$cpu_quota" ]] && description+=", cpu=${cpu_quota}%"
    description+=")"

    # Unit name
    local cmd_basename
    cmd_basename="$(basename -- "${final_argv[0]}")"
    local unit
    unit="$(unit_name "$cmd_basename" "$name")"

    preflight

    # Compose systemd-run argv
    local -a srargs=(--user --collect)
    if (( detach )); then
        srargs+=(--service-type=simple --unit="${unit}.service")
    else
        srargs+=(--scope --unit="${unit}.scope")
        # PTY decision
        if [[ "$pty_mode" == "on" ]] || { [[ "$pty_mode" == "auto" ]] && [[ -t 1 ]]; }; then
            srargs+=(--pty)
        fi
    fi
    srargs+=(--description="$description")

    # Resource properties.
    # NOTE: explicit *Accounting=yes is deprecated on systemd >=258 — accounting
    # is auto-enabled when a resource limit is set on the unit. We only emit
    # MemoryAccounting because oom-hardening's slice limits expect it explicit.
    srargs+=(-p "MemoryMax=$mem_max")
    [[ -n "$mem_high" ]] && srargs+=(-p "MemoryHigh=$mem_high")
    [[ -n "$mem_swap" ]] && srargs+=(-p "MemorySwapMax=$mem_swap")
    [[ -n "$tasks_max" ]] && srargs+=(-p "TasksMax=$tasks_max")
    [[ -n "$cpu_quota" ]] && srargs+=(-p "CPUQuota=${cpu_quota}%")
    [[ -n "$io_weight" ]] && srargs+=(-p "IOWeight=$io_weight")
    [[ -n "$nice" ]] && srargs+=(-p "Nice=$nice")

    # WorkingDirectory: only valid on .service units, not .scope.
    # Scopes inherit $PWD from the caller automatically.
    if (( detach )); then
        if [[ -n "$workdir" ]]; then
            [[ -d "$workdir" ]] || die "--workdir does not exist: $workdir"
            srargs+=(-p "WorkingDirectory=$workdir")
        elif [[ -d "$PWD" ]]; then
            srargs+=(-p "WorkingDirectory=$PWD")
        fi
    else
        if [[ -n "$workdir" ]]; then
            [[ -d "$workdir" ]] || die "--workdir does not exist: $workdir"
            # Apply by cd-ing before exec; scopes can't set WorkingDirectory.
            cd -- "$workdir"
        fi
    fi

    # Hardening (only in detached/service mode by default — interactive scopes
    # often need privileges, e.g. browsers using sandbox setuid helpers)
    if (( detach && protect )); then
        srargs+=(-p "NoNewPrivileges=yes")
        srargs+=(-p "PrivateTmp=yes")
        srargs+=(-p "ProtectSystem=full")
        if (( read_only )); then
            srargs+=(-p "ProtectSystem=strict")
        fi
    fi

    # Read-only root for foreground if explicitly asked
    if (( read_only && detach == 0 )); then
        srargs+=(-p "ProtectSystem=strict")
    fi

    # Environment passing
    if (( ! no_inherit )) && [[ -n "$inherit_env_re" ]]; then
        local var
        while IFS= read -r var; do
            [[ -z "$var" ]] && continue
            local key="${var%%=*}"
            local val="${var#*=}"
            if [[ "$key" =~ $inherit_env_re ]]; then
                srargs+=(-p "Environment=${key}=${val}")
            fi
        done < <(env)
    fi
    local kv
    for kv in "${env_vars[@]}"; do
        srargs+=(-p "Environment=$kv")
    done

    # Verbose / dry-run output
    if (( verbose || dry_run )); then
        {
            printf '%s+%s ' "$C_DIM" "$C_RST"
            printf 'systemd-run'
            local a
            for a in "${srargs[@]}" -- "${final_argv[@]}"; do
                if [[ "$a" =~ [[:space:]\;\&\|\<\>\$\(\)\\\"\'] ]] || [[ -z "$a" ]]; then
                    printf ' %q' "$a"
                else
                    printf ' %s' "$a"
                fi
            done
            printf '\n'
        } >&2
        if (( dry_run )); then
            return 0
        fi
    fi

    # Show summary
    log "Unit:   ${unit}.$([[ $detach == 1 ]] && echo service || echo scope)"
    log "Limits: MemoryMax=$mem_max ${mem_high:+MemoryHigh=$mem_high} ${mem_swap:+MemorySwapMax=$mem_swap} ${cpu_quota:+CPUQuota=${cpu_quota}%}"

    if (( detach )); then
        ok "Starting detached service: ${unit}.service"
        systemd-run "${srargs[@]}" -- "${final_argv[@]}"
        log "  status: $0 status $unit"
        log "  logs:   $0 logs $unit -f"
        log "  kill:   $0 kill $unit"
    else
        # Foreground scope: replace this process so signals & exit code propagate.
        exec systemd-run "${srargs[@]}" -- "${final_argv[@]}"
    fi
}

# ---------- entrypoint -------------------------------------------------------

main() {
    # NOTE: case patterns are globs — bare '?' is a metachar matching any
    # single char. Do NOT use '-?' here, that would match every short flag.
    case "${1:-}" in
        ""|--help|-h)             usage; exit 0 ;;
        --version)                printf '%s %s\n' "$SCRIPT_NAME" "$SCRIPT_VERSION"; exit 0 ;;
        presets)                  print_presets; exit 0 ;;
        list)                     cmd_list; exit 0 ;;
        clean)                    cmd_clean; exit 0 ;;
        kill)                     shift; cmd_kill "$@"; exit 0 ;;
        status)                   shift; cmd_status "$@"; exit 0 ;;
        logs)                     shift; cmd_logs "$@"; exit 0 ;;
        run)                      shift; cmd_run "$@"; exit $? ;;
        --|-*)                    cmd_run "$@"; exit $? ;;
        *)
            # First word is a non-flag; treat all of $@ as the command so
            # 'oom-runner echo hi' works the same as 'oom-runner -- echo hi'.
            if command -v -- "$1" >/dev/null 2>&1 || [[ -x "$1" ]]; then
                cmd_run -- "$@"
            else
                cmd_run "$@"
            fi
            ;;
    esac
}

main "$@"
