# shellcheck shell=bash
# --- Module: 11c-llm-server ---
# AI INSTRUCTION: On ANY change to this file, increment the Module Version below.
# Module Version: 18
# ==============================================================================
# 11c-llm-server — LLM server lifecycle, health, Python resolution
# ==============================================================================
# @modular-section: llm-manager
# @depends: constants, design-tokens, ui-engine, hooks, telemetry, llm-registry
# @exports: __llm_active_entry, __llm_active_state_recorded, __llm_is_healthy,
#   __llm_server_running, __llm_server_gone,
#   __llm_server_stop, __llm_python_bin_resolve, __llm_health_timeout,
#   __llm_burn_request_timeout, __llm_wait_for_health, __llm_quant_rating,
#   __llm_proc_is_server, __llm_server_pids, __llm_lane_pids, __llm_pid_is_lane,
#   __llm_owned_server_pids

# Globals assigned by sibling modules at source time, named here instead of
# relying on a file-wide `disable=SC2154` (removed 2026-09-15): shellcheck lints
# each module in isolation and cannot see an assignment made elsewhere, so the
# module declares what it consumes.
#   colours — 03-design-tokens.sh (as `readonly`)
# `:=` assigns ONLY when the variable is unset, so this is a runtime no-op and is
# safe against the `readonly` in 03 (a plain C_Dim="$C_Dim" would abort).
: "${C_Dim:=}"
: "${C_Reset:=}"
: "${C_Warning:=}"

# ---- Named constants for model size thresholds (in tenths of GB) ----
# Idempotent include guard: sub-modules are sourced both by their thin
# loader and directly by the profile/env loaders, so run the body once.
[[ -n "${__TAC_MOD_11C_LLM_SERVER_LOADED:-}" ]] && return 0
__TAC_MOD_11C_LLM_SERVER_LOADED=1

readonly _MODEL_SIZE_LARGE=30       # 3.0GB+ — large model, longer startup
readonly _MODEL_SIZE_MEDIUM=20      # 2.0GB+ — medium model, moderate startup
readonly _MODEL_SIZE_SMALL=15       # 1.5GB+ — small model, fast startup
readonly _GPU_OFFLOAD_DISABLED=0    # gpu_layers = 0 means CPU-only mode

# ---- Special-case model names (for custom settings/behavior) ----
readonly _MODEL_QWEN35_4B="Qwen3.5-4B"

function __llm_active_entry() {
    [[ -f "$ACTIVE_LLM_FILE" ]] || return 1
    local active_file
    active_file=$(< "$ACTIVE_LLM_FILE")
    [[ -n "$active_file" ]] || return 1
    # The pointer names the model FILE: resolving it by number would re-target this
    # lookup whenever a scan renumbers the registry.
    __llm_registry_entry_by_file "$active_file"
}

# ---------------------------------------------------------------------------
# __llm_active_state_recorded <model_file> — read-back witness for the
# "writes active model state" side effect of `model use`.
#
# @returns 0 when ACTIVE_LLM_FILE exists AND holds exactly <model_file>.
#
# WHY IT EXISTS (card CLAIMED-SUCCESS-WITNESS-001): `model use` printed
# "ONLINE [Port N]" whether or not the pointer write had landed — a failed write
# only produced a "[Could not save state]" warning and the launch continued — so
# the success line claimed a side effect nothing had checked.  Every consumer of
# state resolves the active model THROUGH this pointer (status, burn timeouts,
# the dashboard, the gateway, the watchdog-side state contract), and each one
# silently falls back when it is missing or wrong, which is why the failure has
# to be caught here rather than downstream.
#
# The comparison is against the FILE NAME the launch started, not "is it
# non-empty": a pointer left over from a previous model is exactly the stale
# state this rejects.
# ---------------------------------------------------------------------------
function __llm_active_state_recorded() {
    local _expect="${1:-}" _actual
    [[ -n "$_expect" ]] || return 1
    [[ -f "$ACTIVE_LLM_FILE" ]] || return 1
    _actual=$(< "$ACTIVE_LLM_FILE")
    [[ "$_actual" == "$_expect" ]]
}

# ---------------------------------------------------------------------------
# __llm_is_healthy — Check whether llama-server is listening and reports OK.
# @returns 0 if the local LLM health endpoint reports ok, 1 otherwise.
# ---------------------------------------------------------------------------
function __llm_is_healthy() {
    # Optional port argument: callers that are not talking about the SCRATCH port
    # (LLM_PORT, where `so` loads a duplicate) can ask about the PRODUCTION lane
    # (LLM_SERVICE_PORT).  Default keeps every existing caller unchanged.
    local _port="${1:-$LLM_PORT}"
    __test_port "$_port" || return 1
    local health_body models_body
    local health_timeout="${LLM_HEALTH_HTTP_TIMEOUT:-20}"
    # Both probes are POLLED while a server is starting, so curl's own "connection
    # refused" would be a line per attempt that a reader learns to skip.  An endpoint
    # that did not answer is this function's "not healthy" ANSWER - but the status is
    # handled here rather than discarded, so nothing is silent about it.
    # swallow-ok: curl's stderr is the same not-healthy answer, repeated once per poll of a starting server; the status is acted on below.
    if ! health_body=$(curl -s --max-time "$health_timeout" "http://127.0.0.1:$_port/health" 2>/dev/null)
    then
        health_body=""
    fi
    if [[ "$health_body" == *'"ok"'* ]]
    then
        return 0
    fi
    # swallow-ok: the second acceptance probe, polled the same way as the first for the same reason.
    if ! models_body=$(curl -s --max-time "$health_timeout" "http://127.0.0.1:$_port/v1/models" 2>/dev/null)
    then
        models_body=""
    fi
    if [[ "$models_body" == *'"data"'* ]]
    then
        return 0
    fi

    # Some OpenAI-compatible variants return object=list first; accept that
    # as a readiness signal when the process is bound and responding.
    [[ "$models_body" == *'"object"'* && "$models_body" == *'"list"'* ]]
}

# ---------------------------------------------------------------------------
# __llm_server_running / __llm_server_stop — Backend process helpers.
#
# A llama backend is identified by the ARTEFACT it runs (/proc/PID/exe), not by
# its command line.  Command-line matching was the old way, and it is unfaithful
# in both directions:
#
#   * it matches processes that are not the backend — ANY process whose argv
#     merely mentions the pattern.  On 2026-09-15 a human's
#     `grep -iE 'llama|autotune'` was read as a bench workload and the watchdog
#     stopped a healthy CUDA lane; the same shape in this module would have made
#     `__llm_server_running` report a server that does not exist;
#   * it misses the backend itself once a card launcher is involved — the
#     launchers `exec` the build binary, so the command line and comm are
#     `llama-server` with nothing card- or launcher-specific left in them.
#
# exe is the artefact that is actually running and an argument cannot forge it.
# The one shape it cannot show is the python backend
# (`python3 -m llama_cpp.server`), whose exe is the interpreter — so the module
# name is read from the command line for an interpreter exe ONLY.
# ---------------------------------------------------------------------------
function __llm_proc_exe() { readlink -f "/proc/${1}/exe" 2>/dev/null; }

# __llm_proc_is_server <pid> — 0 when the pid runs a llama backend.
function __llm_proc_is_server() {
    local _pid="$1" _exe _base _cmd
    [[ "$_pid" =~ ^[0-9]+$ ]] || return 1
    _exe=$(__llm_proc_exe "$_pid") || return 1
    _base="${_exe##*/}"
    case "$_base" in
        llama-server|llama-bench|llama-embedding|llama-cli|llama-quantize|llama-perplexity)
            return 0 ;;
        python|python3|python3.*|pypy3) ;;
        *) return 1 ;;
    esac
    # A pid that exited between the exe read above and this one is not a backend any
    # more - the same answer as a cmdline that does not match - so the race is
    # decided and returned rather than swallowed.
    [[ -r "/proc/${_pid}/cmdline" ]] || return 1
    _cmd=$(tr '\0' ' ' < "/proc/${_pid}/cmdline") || return 1
    [[ "$_cmd" == *"${LLM_SERVER_MODULE:-llama_cpp.server}"* ]]
}

# __llm_server_pids [user] — every llama backend owned by <user> (default: the
# current user), one pid per line.  Replaces `pgrep -u <user> -f <pattern>`.
function __llm_server_pids() {
    local _user="${1-${USER:-}}" _dir _pid _owner
    for _dir in /proc/[0-9]*
    do
        _pid="${_dir#/proc/}"
        if [[ -n "$_user" ]]
        then
            _owner=$(stat -c %U "$_dir" 2>/dev/null) || continue
            [[ "$_owner" == "$_user" ]] || continue
        fi
        __llm_proc_is_server "$_pid" && printf '%s\n' "$_pid"
    done
}

# ---------------------------------------------------------------------------
# LANE PROTECTION — which llama backends TAC-side stop logic may NOT kill.
#
# WHY THIS IS DERIVED AND NOT A LIST (measured 2026-09-28, mid bench pass).  The
# protection was a hand-written list of three unit names.  The fleet grew two
# lanes on 2026-09-19 (d5d18e4c, 5c45f623) and the list did not, so every
# `model stop` swept those two up.  The CPU lane's journal, during one bench pass:
#
#     03:13:46  Main process exited, code=killed, status=9/KILL
#     03:13:51  Scheduled restart job, restart counter is at 18
#     03:14:16  cleaning up before exit          <- killed again
#     03:14:22  Failed with result 'start-limit-hit'
#
# i.e. the pass killed a live lane row after row until systemd gave up and left
# it failed.  A name list cannot stay correct against a growing fleet, so the set
# is derived from the process table and from systemd instead.
#
# Three criteria, ORed.  Each has a blind spot, and the failure direction here
# must always be "protect too much" — never "kill a lane":
#   * the pid is the MainPID of an ACTIVE llama-*.service user unit: the lanes as
#     systemd sees them.  Blind to a lane started outside systemd.
#   * the pid's PARENT is a systemd binary: true for every systemd-spawned
#     backend, false for anything TAC or a bench spawned.  This is the criterion
#     that needs no systemd query, so it still holds where `systemctl --user` has
#     no session bus (measured: this box's CI runners).
#   * the pid owns LLM_SERVICE_PORT (:18081): the fleet server by port, the
#     identity the rest of this module already uses.
# ---------------------------------------------------------------------------

# __llm_lane_pids — the MainPID of every ACTIVE llama-*.service user unit, one per
# line.  Empty (not an error) when systemd has nothing to report.
function __llm_lane_pids() {
    local _units _unit _pid
    _units=$(systemctl --user list-units --type=service --state=active \
                 --no-legend --plain 'llama-*.service' 2>/dev/null | awk '{print $1}')
    while IFS= read -r _unit
    do
        [[ -n "$_unit" ]] || continue
        _pid=$(systemctl --user show -p MainPID --value "$_unit" 2>/dev/null | tr -d ' \n')
        [[ "$_pid" =~ ^[0-9]+$ ]] || continue
        (( _pid > 0 )) || continue
        printf '%s\n' "$_pid"
    done <<< "$_units"
}

# __llm_pid_is_lane <pid> [lanes] — 0 when this pid is a fleet lane TAC must not
# touch.  <lanes> is an optional pre-computed __llm_lane_pids result: the caller
# normally has one already, and computing it is a systemctl round trip.
function __llm_pid_is_lane() {
    local _pid="${1:-}" _lanes="${2:-}" _ppid _pexe _pbase _sport_pid _lane
    [[ "$_pid" =~ ^[0-9]+$ ]] || return 1
    [[ -n "$_lanes" ]] || _lanes=$(__llm_lane_pids)

    while IFS= read -r _lane
    do
        [[ "$_lane" == "$_pid" ]] && return 0
    done <<< "$_lanes"

    # /proc/PID/status, not /proc/PID/stat: comm can carry spaces and parens.
    _ppid=$(awk '/^PPid:/ {print $2}' "/proc/${_pid}/status" 2>/dev/null)
    if [[ "$_ppid" =~ ^[0-9]+$ ]]
    then
        _pexe=$(__llm_proc_exe "$_ppid") || _pexe=""
        _pbase="${_pexe##*/}"
        # comm is the FALLBACK, and it is load-bearing rather than tidiness: the USER
        # systemd manager's /proc/PID/exe is EACCES for an ordinary reader (measured
        # 2026-09-28 - pid 568, errno 13), and that manager is the parent every lane has.
        # Without this, the criterion that "needs no systemd query" answers "not a lane"
        # for exactly the case it exists for.  Read with $(< ) so no redirection is added.
        if [[ -z "$_pbase" && -r "/proc/${_ppid}/comm" ]]
        then
            _pbase=$(< "/proc/${_ppid}/comm")
        fi
        [[ "$_pbase" == "systemd" ]] && return 0
    fi

    _sport_pid=$(ss -tlnp "sport = :${LLM_SERVICE_PORT:-18081}" 2>/dev/null \
        | awk 'match($0, /pid=([0-9]+)/, m) { print m[1]; exit }')
    [[ "$_sport_pid" == "$_pid" ]] && return 0

    return 1
}

# __llm_owned_server_pids [user] [lanes] — the llama backends `model stop` OWNS:
# every backend for <user> that is not a fleet lane.  THIS is the single definition
# both the killer and its read-back use, so the two cannot disagree about what the
# stop was supposed to remove.
function __llm_owned_server_pids() {
    local _user="${1-${USER:-}}" _lanes="${2:-}" _pg_out="" _pid
    [[ -n "$_lanes" ]] || _lanes=$(__llm_lane_pids)
    _pg_out=$(__llm_server_pids "$_user")
    while IFS= read -r _pid
    do
        [[ -n "$_pid" ]] || continue
        __llm_pid_is_lane "$_pid" "$_lanes" && continue
        printf '%s\n' "$_pid"
    done <<< "$_pg_out"
}

# ---------------------------------------------------------------------------
# __llm_server_gone — read-back witness for the "stops model server process"
# side effect of `model stop`.
#
# @returns 0 only when no backend `model stop` OWNS is still running AND the
# serving port is no longer bound; 1 otherwise.
#
# WHY IT EXISTS (card CLAIMED-SUCCESS-WITNESS-001): `__model_stop` printed
# "[STOPPED]" unconditionally.  `__llm_server_stop` waits for the processes it
# SIGTERMed and then SIGKILLs what is left, but it never re-queries afterwards,
# so a server that survived (a systemd-managed lane, a second server on the same
# port, a process the sweep could not see) still produced the success line — and
# the reader then believes the card and the port are free.  Both halves are
# checked because each one alone is insufficient: a backend can be alive without
# the port (between crashees) and the port can be held by something that is not a
# llama backend at all.
#
# SCOPED TO THE OWNED SET (2026-09-28): this witness used to ask whether ANY
# llama backend ran for this user, which on a multi-lane box is always true, so it
# reported "[FAILED ... NOT stopped]" on 22 of 22 rows of a bench pass whatever
# the stop had actually done.  An alarm that can never go green is worse than
# noise: it teaches the reader to skip the one line this card exists to make
# meaningful.  It now asks the same question the killer acts on.
# ---------------------------------------------------------------------------
function __llm_server_gone() {
    [[ -n "$(__llm_owned_server_pids)" ]] && return 1
    __test_port "$LLM_PORT" && return 1
    return 0
}

# __llm_current_user — the user whose llama backends this module manages.  $USER is
# the normal case; id(1) covers a cron/systemd context where it is unset.  An EMPTY
# answer is warned about rather than passed on quietly, because every caller scans
# with it and an empty value makes that scan UNSCOPED — every user's backends — which
# is a widening this module must never do by accident.
function __llm_current_user() {
    local _u="${USER:-}"
    if [[ -z "$_u" ]]
    then
        # swallow-ok: id(1)'s own message would only duplicate the warning below, which names the consequence instead of the errno.
        _u=$(id -un 2>/dev/null) || _u=""
    fi
    if [[ -z "$_u" ]]
    then
        # Built in a variable so the line stays inside the 120-column house limit
        # (tools/count-ratchet.sh item 8.1.8).
        local _msg
        _msg="[\$USER is unset and id(1) failed - the llama backend scan is"
        _msg+=" UNSCOPED across every user]"
        __tac_info "Warning" "$_msg" "$C_Warning"
    fi
    printf '%s\n' "$_u"
}

function __llm_server_running() {
    local _llm_user _pids
    _llm_user=$(__llm_current_user)
    _pids=$(__llm_server_pids "$_llm_user")
    [[ -n "$_pids" ]]
}

function __llm_server_stop() {
    local _llm_user _grace _tries _i
    local _llm_pid _pid _lanes
    local -a _pids=()

    _llm_user=$(__llm_current_user)
    _grace="${LLM_SERVER_STOP_GRACE_SECONDS:-8}"
    [[ "$_grace" =~ ^[0-9]+$ ]] || _grace=8
    _tries=$((_grace * 5))
    ((_tries < 5)) && _tries=5

    # The protected set, computed ONCE: it is the same for every candidate and for
    # every pass of the wait loop below, and __llm_lane_pids shells out to
    # systemctl.  See the LANE PROTECTION note above the helpers for the three
    # criteria and for why this is derived rather than a list of unit names.
    _lanes=$(__llm_lane_pids)

    # Collect PIDs — the servers this stop OWNS, i.e. every llama backend that is
    # not a fleet lane.  Deliberately not mapfile + process substitution (crashes
    # in nested contexts).
    local _pg_out=""
    _pg_out=$(__llm_owned_server_pids "$_llm_user" "$_lanes")
    while IFS= read -r _pid
    do
        [[ -z "$_pid" ]] && continue
        _pids+=("$_pid")
    done <<< "$_pg_out"

    # A backend can hold the serving port without the scan above recognising it
    # (a launcher, or a build the exe check does not cover); add it unless it is a
    # lane.
    _llm_pid=$(ss -tlnp "sport = :${LLM_PORT}" 2>/dev/null | awk 'match($0, /pid=([0-9]+)/, m) { print m[1]; exit }')
    if [[ "$_llm_pid" =~ ^[0-9]+$ ]] && ! __llm_pid_is_lane "$_llm_pid" "$_lanes"
    then
        _pids+=("$_llm_pid")
    fi

    if (( ${#_pids[@]} == 0 ))
    then
        return 0
    fi

    for _pid in "${_pids[@]}"
    do
        [[ "$_pid" =~ ^[0-9]+$ ]] || continue
        # swallow-ok: every pid here was chosen for termination a moment ago and may already have exited; the wait loop below re-reads the live set, so a signal with nothing left to signal is not an error.
        kill -TERM "$_pid" 2>/dev/null
    done

    for ((_i=0; _i<_tries; _i++))
    do
        _pids=()
        _pg_out=$(__llm_owned_server_pids "$_llm_user" "$_lanes")
        while IFS= read -r _pid
        do
            [[ -z "$_pid" ]] && continue
            _pids+=("$_pid")
        done <<< "$_pg_out"
        (( ${#_pids[@]} == 0 )) && return 0
        sleep 0.2
    done

    for _pid in "${_pids[@]}"
    do
        [[ "$_pid" =~ ^[0-9]+$ ]] || continue
        # swallow-ok: the SIGKILL pass over whatever the wait loop still found alive; a pid that exited between that scan and this signal is the outcome we wanted.
        kill -KILL "$_pid" 2>/dev/null
    done

    # Kill any lingering stdin keeper processes (orphaned sleep loops).
    local _kp
    for _kf in "${LLM_KEEPER_DIR:-/tmp}"/llm-keeper.*.pid
    do
        [[ -f "$_kf" ]] || continue
        _kp=$(< "$_kf")
        if [[ "$_kp" =~ ^[0-9]+$ ]]; then
            kill -TERM "$_kp" 2>/dev/null
        fi
        rm -f "$_kf"
    done

    # Reclaim GPU memory: wait for VRAM to stabilise after server kill.
    local _smi _free_before _free_after _mem_waited _mem_max_wait
    # swallow-ok: "no SMI tool on PATH" is the ordinary cannot-read-VRAM case, and the empty test right below is what handles it.
    _smi=$(__resolve_smi 2>/dev/null) || _smi=""
    if [[ -n "$_smi" ]]
    then
        _free_before=$(timeout 3 "$_smi" --query-gpu=memory.free --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ')
        if [[ "$_free_before" =~ ^[0-9]+$ ]]
        then
            _mem_waited=0
            _mem_max_wait=3
            while (( _mem_waited < _mem_max_wait ))
            do
                sleep 0.5
                _free_after=$(timeout 3 "$_smi" --query-gpu=memory.free --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ')
                [[ "$_free_after" =~ ^[0-9]+$ ]] || break
                (( _free_after <= _free_before )) && break
                _free_before="$_free_after"
                _mem_waited=$(( _mem_waited + 1 ))
            done
        fi
    fi
    sleep 0.5

    return 0
}

# ---------------------------------------------------------------------------
# __llm_python_bin_resolve — Pick a Python with llama_cpp==expected version.
# @returns 0 and prints the python path on success; 1 on failure.
# ---------------------------------------------------------------------------
function __llm_python_bin_resolve() {
    # The version is read from LLAMA_CPP_PYTHON_VERSION by the probe below, so
    # there is deliberately no shell copy of it to drift.
    local cand resolved
    local -a candidates=()

    [[ -n "${LLM_SERVER_PYTHON_BIN:-}" ]] && candidates+=("$LLM_SERVER_PYTHON_BIN")
    candidates+=("python3" "python" "/home/linuxbrew/.linuxbrew/bin/python3")

    for cand in "${candidates[@]}"
    do
        resolved=""
        if [[ -x "$cand" ]]
        then
            resolved="$cand"
        else
            # swallow-ok: a candidate that is not on PATH is this search failing for that one candidate, which the loop continues past.
            resolved=$(command -v "$cand" 2>/dev/null) || resolved=""
        fi
        [[ -z "$resolved" ]] && continue

        if "$resolved" - <<'PY' >/dev/null 2>&1
import os
import sys

expected = os.environ.get("LLAMA_CPP_PYTHON_VERSION", "0.3.23")
# No type checker analyses this heredoc, so no suppression comments are needed.
import llama_cpp
import uvicorn
if getattr(llama_cpp, "__version__", "unknown") != expected:
    raise SystemExit(1)
PY
        then
            printf '%s\n' "$resolved"
            return 0
        fi
    done

    return 1
}

# ---------------------------------------------------------------------------
# __llm_type_k_value — Map cache type label to llama_cpp --type_k int value.
# Falls back to a plain integer if LLAMA_CACHE_TYPE_K is already numeric.
# ---------------------------------------------------------------------------
function __llm_type_k_value() {
    local raw="${LLAMA_CACHE_TYPE_K:-q8_0}"
    case "${raw,,}" in
        q8_0) echo 8 ;;
        f16) echo 1 ;;
        f32) echo 0 ;;
        *)
            if [[ "$raw" =~ ^[0-9]+$ ]]
            then
                echo "$raw"
            else
                echo 8
            fi
            ;;
    esac
}

# ---------------------------------------------------------------------------
# __llm_health_timeout — Pick a startup timeout for llama-server readiness.
# @returns 0 always.
# ---------------------------------------------------------------------------
function __llm_health_timeout() {
    local size="${1:-0G}"
    local gpu_layers="${2:-0}"
    local name="${3:-}"
    local timeout=90
    local size_tenths=0

    if [[ "$size" =~ ^([0-9]+)(\.([0-9]))?G$ ]]
    then
        size_tenths=$(( BASH_REMATCH[1] * 10 + ${BASH_REMATCH[3]:-0} ))
    fi

    if (( gpu_layers == _GPU_OFFLOAD_DISABLED ))
    then
        timeout=180
    elif [[ "$name" == "$_MODEL_QWEN35_4B" ]]
    then
        timeout=180
    elif (( size_tenths >= _MODEL_SIZE_LARGE ))
    then
        timeout=180
    elif (( size_tenths >= _MODEL_SIZE_MEDIUM ))
    then
        timeout=180
    elif (( size_tenths >= _MODEL_SIZE_SMALL ))
    then
        timeout=120
    fi

    if [[ -n "${__BENCH_MODE:-}" && $timeout -lt 80 ]]
    then
        timeout=80
    fi

    printf '%s\n' "$timeout"
}

# ---------------------------------------------------------------------------
# __llm_burn_request_timeout — Pick a completion timeout for burn/bench runs.
# Non-streaming 1500-token requests can legitimately take several minutes on
# slower models, so benchmark mode uses a higher default floor.
# @returns 0 always.
# ---------------------------------------------------------------------------
function __llm_burn_request_timeout() {
    local size="${1:-0G}"
    local gpu_layers="${2:-0}"
    local arch="${3:-}"
    local bench_mode="${4:-${__BENCH_MODE:-}}"
    local timeout
    local size_tenths=0

    if [[ -n "$bench_mode" ]]
    then
        timeout="${LLM_BENCH_REQUEST_TIMEOUT:-600}"
    else
        timeout="${LLM_BURN_REQUEST_TIMEOUT:-360}"
    fi

    # If the caller explicitly set LLM_BURN_REQUEST_TIMEOUT (not defaulted),
    # respect it unconditionally — no model-size floor. This allows autotune
    # to enforce short per-trial timeouts (e.g. 90s) without model-size
    # scaling bumping them to 480-900s.
    if [[ -z "${LLM_BURN_REQUEST_TIMEOUT:-}" ]]
    then
        if [[ "$size" =~ ^([0-9]+)(\.([0-9]))?G$ ]]
        then
            size_tenths=$(( BASH_REMATCH[1] * 10 + ${BASH_REMATCH[3]:-0} ))
        fi

        if (( gpu_layers == _GPU_OFFLOAD_DISABLED ))
        then
            timeout="${LLM_BURN_REQUEST_TIMEOUT_CPU:-1200}"
        elif [[ "$arch" == "qwen35" ]]
        then
            (( timeout < 900 )) && timeout=900
        elif (( size_tenths >= _MODEL_SIZE_LARGE ))
        then
            (( timeout < 900 )) && timeout=900
        elif (( size_tenths >= _MODEL_SIZE_MEDIUM ))
        then
            (( timeout < 720 )) && timeout=720
        elif (( size_tenths >= _MODEL_SIZE_SMALL ))
        then
            (( timeout < 480 )) && timeout=480
        fi
    fi

    printf '%s\n' "$timeout"
}

# ---------------------------------------------------------------------------
# __llm_gpu_clock_snapshot — Return concise GPU clock/pstate snapshot.
# @returns 0 and prints "pstate=..., gr=...MHz, sm=...MHz, mem=...MHz, util=...%"
# or "unavailable" when nvidia-smi cannot be queried.
# ---------------------------------------------------------------------------
function __llm_gpu_clock_snapshot() {
    local smi_cmd
    # swallow-ok: a missing SMI tool is the documented skip path both callers test for explicitly below, not an error to raise here.
    smi_cmd=$(__resolve_smi 2>/dev/null) || smi_cmd=""
    if [[ -z "$smi_cmd" ]]
    then
        printf '%s\n' "unavailable"
        return 0
    fi

    local sample
    sample=$(
        "$smi_cmd" --query-gpu=pstate,clocks.gr,clocks.sm,clocks.mem,utilization.gpu \
            --format=csv,noheader,nounits 2>/dev/null | head -1
    )
    if [[ -z "$sample" ]]
    then
        printf '%s\n' "unavailable"
        return 0
    fi

    local pstate gr sm mem util
    IFS=',' read -r pstate gr sm mem util <<< "$sample"
    pstate=$(printf '%s' "$pstate" | xargs)
    gr=$(printf '%s' "$gr" | xargs)
    sm=$(printf '%s' "$sm" | xargs)
    mem=$(printf '%s' "$mem" | xargs)
    util=$(printf '%s' "$util" | xargs)
    printf 'pstate=%s, gr=%sMHz, sm=%sMHz, mem=%sMHz, util=%s%%\n' \
        "${pstate:-?}" "${gr:-?}" "${sm:-?}" "${mem:-?}" "${util:-?}"
}

# ---------------------------------------------------------------------------
# __llm_bench_perf_prep — Print GPU performance state before a bench run.
# Reports: AC/battery, pstate, clocks, temp, power, active throttles.
# Warns when conditions will limit throughput and gives actionable tips.
# Called by __model_bench; gives the driver 1 s to settle after wake.
# @returns 0 always.
# ---------------------------------------------------------------------------
function __llm_bench_perf_prep() {
    local smi_cmd
    # swallow-ok: a missing SMI tool is the documented skip path both callers test for explicitly below, not an error to raise here.
    smi_cmd=$(__resolve_smi 2>/dev/null) || smi_cmd=""

    # Compact GPU status within the bench header
    local _gpu_line=""
    if [[ -n "$smi_cmd" ]]
    then
        local _gstat _temp _pwr _pstate _gr _sm _mem
        _gstat=$(
            "$smi_cmd" --query-gpu=pstate,clocks.gr,clocks.sm,clocks.mem,temperature.gpu,power.draw \
                --format=csv,noheader,nounits 2>/dev/null | head -1
        )
        if [[ -n "$_gstat" ]]; then
            IFS=',' read -r _pstate _gr _sm _mem _temp _pwr <<< "$_gstat"
            _pstate=$(printf '%s' "$_pstate" | xargs)
            _gr=$(printf '%s' "$_gr" | xargs)
            _sm=$(printf '%s' "$_sm" | xargs)
            _mem=$(printf '%s' "$_mem" | xargs)
            _temp=$(printf '%s' "$_temp" | xargs)
            _pwr=$(printf '%s' "$_pwr" | xargs)
            _gpu_line="$_pstate  ${_gr}/${_sm}/${_mem} MHz  ${_temp}°C  ${_pwr}W ✓"
        fi
    fi
    [[ -z "$_gpu_line" ]] && _gpu_line="GPU info unavailable"
    printf "${C_Dim}  %s${C_Reset}\n" "$_gpu_line"
    __tac_footer
    sleep 1
}

# ---------------------------------------------------------------------------
# __llm_wait_for_health — Poll llama-server until it becomes healthy.
# Usage: __llm_wait_for_health <timeout> <elapsed_var> [dots|silent] [label]
# @returns 0 on success, 1 on timeout.
# ---------------------------------------------------------------------------
function __llm_wait_for_health() {
    local timeout="${1:-45}"
    local -n _elapsed_ref="${2:-_llm_wait_elapsed_sink}"
    local progress_mode="${3:-silent}"
    local label="${4:-Loading LLM (health check)}"

    _elapsed_ref=0
    if [[ "$progress_mode" == "dots" ]]
    then
        printf '%s' "${C_Dim}${label}${C_Reset}"
    fi

    for (( _elapsed_ref=0; _elapsed_ref < timeout; _elapsed_ref++ ))
    do
        if __llm_is_healthy
        then
            [[ "$progress_mode" == "dots" ]] && printf '%s\n' "$C_Reset"
            return 0
        fi
        [[ "$progress_mode" == "dots" ]] && printf '.'
        sleep 1
    done

    # Grace phase: if process/port are alive, keep waiting a bit longer for
    # /v1/models to become responsive under heavy WSL IO/load conditions.
    local grace_timeout="${LLM_HEALTH_GRACE_TIMEOUT:-180}"
    if __llm_server_running && __test_port "$LLM_PORT"
    then
        for (( _g=0; _g < grace_timeout; _g++ ))
        do
            if __llm_is_healthy
            then
                [[ "$progress_mode" == "dots" ]] && printf '%s\n' "$C_Reset"
                return 0
            fi
            [[ "$progress_mode" == "dots" ]] && printf '+'
            sleep 1
        done
    fi

    [[ "$progress_mode" == "dots" ]] && printf '%s\n' "$C_Reset"
    return 1
}

# ---------------------------------------------------------------------------
# __llm_quant_rating — Read the quant-guide rating for a model filename.
# @returns 0 always. Prints recommended, acceptable, discouraged, or unknown.
# ---------------------------------------------------------------------------
function __llm_quant_rating() {
    local model_file="${1:-}"
    if [[ -z "$model_file" || ! -f "$QUANT_GUIDE" ]]
    then
        printf '%s\n' "unknown"
        return 0
    fi

    local rating="unknown"
    local _r _pat _desc
    while IFS='|' read -r _r _pat _desc
    do
        [[ -z "$_pat" || "$_r" == "#"* ]] && continue
        if [[ "${model_file^^}" == *"${_pat^^}"* ]]
        then
            rating="$_r"
            break
        fi
    done < "$QUANT_GUIDE"
    printf '%s\n' "$rating"
}

# ---------------------------------------------------------------------------
# __llm_tps_number — Convert a registry or bench TPS string to a number.
# @returns 0 always.
# ---------------------------------------------------------------------------
function __llm_tps_number() {
    local raw="${1:-0}"
    raw="${raw// tps/}"
    raw="${raw//TPS/}"
    if [[ "$raw" =~ ^[0-9]+([.][0-9]+)?$ ]]
    then
        printf '%s\n' "$raw"
    else
        printf '%s\n' "0"
    fi
}

# end of file
