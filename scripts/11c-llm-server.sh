# shellcheck shell=bash
# shellcheck disable=SC2034,SC2059,SC2120,SC2154
# --- Module: 11c-llm-server ---
# AI INSTRUCTION: On ANY change to this file, increment the Module Version below.
# Module Version: 3
# ==============================================================================
# 11c-llm-server — LLM server lifecycle, health, Python resolution
# ==============================================================================
# @modular-section: llm-manager
# @depends: constants, design-tokens, ui-engine, hooks, telemetry, llm-registry
# @exports: __llm_active_entry, __llm_is_healthy, __llm_server_running,
#   __llm_server_stop, __llm_python_bin_resolve, __llm_health_timeout,
#   __llm_burn_request_timeout, __llm_wait_for_health, __llm_quant_rating

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
    local active_num
    active_num=$(< "$ACTIVE_LLM_FILE")
    [[ -n "$active_num" ]] || return 1
    __llm_registry_entry_by_num "$active_num"
}

# ---------------------------------------------------------------------------
# __llm_is_healthy — Check whether llama-server is listening and reports OK.
# @returns 0 if the local LLM health endpoint reports ok, 1 otherwise.
# ---------------------------------------------------------------------------
function __llm_is_healthy() {
    __test_port "$LLM_PORT" || return 1
    local health_body models_body
    local health_timeout="${LLM_HEALTH_HTTP_TIMEOUT:-20}"
    health_body=$(curl -s --max-time "$health_timeout" "http://127.0.0.1:$LLM_PORT/health" 2>/dev/null || true)
    if [[ "$health_body" == *'"ok"'* ]]
    then
        return 0
    fi
    models_body=$(curl -s --max-time "$health_timeout" "http://127.0.0.1:$LLM_PORT/v1/models" 2>/dev/null || true)
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
# Supports both legacy llama-server and llama-cpp-python server module names.
# ---------------------------------------------------------------------------
function __llm_server_running() {
    local _llm_user
    _llm_user="${USER:-$(id -un 2>/dev/null || true)}"
    if [[ -n "$_llm_user" ]]
    then
        pgrep -u "$_llm_user" -f "${LLM_SERVER_PROC_PATTERN:-llama_cpp.server|llama-server}" >/dev/null 2>&1
    else
        pgrep -f "${LLM_SERVER_PROC_PATTERN:-llama_cpp.server|llama-server}" >/dev/null 2>&1
    fi
}

function __llm_server_stop() {
    local _llm_user _proc_re _grace _tries _i
    local _llm_pid _pid
    local -a _pids=()

    _llm_user="${USER:-$(id -un 2>/dev/null || true)}"
    _proc_re="${LLM_SERVER_PROC_PATTERN:-llama_cpp.server|llama-server}"
    _grace="${LLM_SERVER_STOP_GRACE_SECONDS:-8}"
    [[ "$_grace" =~ ^[0-9]+$ ]] || _grace=8
    _tries=$((_grace * 5))
    ((_tries < 5)) && _tries=5

    # Collect PIDs — avoid mapfile + process substitution (crashes nested context)
    local _pg_out=""
    if [[ -n "$_llm_user" ]]
    then
        _pg_out=$(pgrep -u "$_llm_user" -f "$_proc_re" 2>/dev/null || true)
    else
        _pg_out=$(pgrep -f "$_proc_re" 2>/dev/null || true)
    fi
    while IFS= read -r _pid
    do
        [[ -z "$_pid" ]] && continue
        _pids+=("$_pid")
    done <<< "$_pg_out"

    _llm_pid=$(ss -tlnp "sport = :${LLM_PORT}" 2>/dev/null | awk 'match($0, /pid=([0-9]+)/, m) { print m[1]; exit }')
    if [[ "$_llm_pid" =~ ^[0-9]+$ ]]
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
        kill -TERM "$_pid" 2>/dev/null || true
    done

    for ((_i=0; _i<_tries; _i++))
    do
        _pids=()
        if [[ -n "$_llm_user" ]]
        then
            _pg_out=$(pgrep -u "$_llm_user" -f "$_proc_re" 2>/dev/null || true)
        else
            _pg_out=$(pgrep -f "$_proc_re" 2>/dev/null || true)
        fi
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
        kill -KILL "$_pid" 2>/dev/null || true
    done

    # Kill any lingering stdin keeper processes (orphaned sleep loops).
    local _kp
    for _kf in /tmp/llm-keeper.*.pid
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
    _smi=$(__resolve_smi 2>/dev/null || true)
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
    local expected="${LLAMA_CPP_PYTHON_VERSION:-0.3.23}"
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
            resolved=$(command -v "$cand" 2>/dev/null || true)
        fi
        [[ -z "$resolved" ]] && continue

        if "$resolved" - <<'PY' >/dev/null 2>&1
import os
import sys

expected = os.environ.get("LLAMA_CPP_PYTHON_VERSION", "0.3.23")
import llama_cpp  # type: ignore
import uvicorn  # type: ignore
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
    smi_cmd=$(__resolve_smi 2>/dev/null || true)
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
    smi_cmd=$(__resolve_smi 2>/dev/null || true)

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

# ---------------------------------------------------------------------------
# wake — Lock the GPU into persistent mode to prevent WDDM sleep in WSL2.
# NOTE: Persistence mode (-pm 1) is a runtime setting and does NOT survive
# WSL restarts. You must re-run 'wake' after each 'wsl --shutdown'.
# ---------------------------------------------------------------------------# end of file
