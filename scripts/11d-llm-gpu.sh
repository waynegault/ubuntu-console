# shellcheck shell=bash
# shellcheck disable=SC2034,SC2120,SC2154
# --- Module: 11d-llm-gpu ---
# AI INSTRUCTION: On ANY change to this file, increment the Module Version below.
# Module Version: 7
# ==============================================================================
# 11d-llm-gpu — GPU status, GGUF metadata, calculations
# ==============================================================================
# @modular-section: llm-manager
# @depends: constants, design-tokens, ui-engine, hooks, telemetry, llm-server
# @exports: wake, gpu-status, gpu-check, __gguf_metadata, __calc_gpu_layers,
#   __calc_ctx_size, __calc_threads, __quant_label, __tac_cleanup_stale_locks,
#   __gpu_clear_stale_processes, __llm_kill_cuda_llama_servers

# Idempotent include guard: sub-modules are sourced both by their thin
# loader and directly by the profile/env loaders, so run the body once.
[[ -n "${__TAC_MOD_11D_LLM_GPU_LOADED:-}" ]] && return 0
__TAC_MOD_11D_LLM_GPU_LOADED=1

function __tac_cleanup_stale_locks() {
    # shellcheck disable=SC2034
    local _c_lock _c_pid _c_kf _c_sp _c_my_pid _c_ppid _c_cmd
    local -a _c_live_model_shells=()

    # Track currently live model-shell wrappers so we do not kill keepers that
    # still belong to an active model session.
    local _c_ms_kf _c_ms_pid
    for _c_ms_kf in /tmp/llm-modelshell.*.pid /tmp/llm-modelshell.pid
    do
        [[ -f "$_c_ms_kf" ]] || continue
        _c_ms_pid=$(cat "$_c_ms_kf" 2>/dev/null || true)
        if [[ "$_c_ms_pid" =~ ^[0-9]+$ ]] && kill -0 "$_c_ms_pid" 2>/dev/null
        then
            _c_live_model_shells+=("$_c_ms_pid")
        fi
    done

    # bench lock + pid — also check custom paths used by non-default configs
    local _c_lock_candidates
    _c_lock_candidates=(
        "${LLM_BENCH_LOCK_FILE:-/tmp/llm-bench.lock}"
        "${LLM_AUTOTUNE_LOCK_FILE:-/tmp/llm-autotune.lock}"
    )
    for _c_lock in "${_c_lock_candidates[@]}"
    do
        [[ -f "$_c_lock" ]] || continue
        if command -v lsof >/dev/null 2>&1
        then
            if ! lsof "$_c_lock" >/dev/null 2>&1
            then
                rm -f "$_c_lock"
            fi
        else
            # shellcheck disable=SC2188
            _c_pid=$(<"$_c_lock" 2>/dev/null || true)
            if [[ -z "$_c_pid" ]] || ! kill -0 "$_c_pid" 2>/dev/null
            then
                rm -f "$_c_lock"
            fi
        fi
    done

    # bench PID file — check custom path too
    local _c_pid_file="${LLM_BENCH_PID_FILE:-/tmp/llm-bench.pid}"
    local _c_bench_active=0
    if [[ -f "$_c_pid_file" ]]
    then
        # shellcheck disable=SC2188
        _c_pid=$(<"$_c_pid_file" 2>/dev/null || true)
        if [[ -z "$_c_pid" ]] || ! kill -0 "$_c_pid" 2>/dev/null
        then
            rm -f "$_c_pid_file"
        else
            _c_bench_active=1
        fi
    fi

    # Bench lock ownership is cooperative: the lock file stores owner PID.
    # Treat bench as active only when that owner PID is alive. An orphaned
    # child can keep the lock file open without owning a valid bench session.
    local _c_bench_lock="${LLM_BENCH_LOCK_FILE:-/tmp/llm-bench.lock}"
    if [[ -f "$_c_bench_lock" ]]
    then
        # shellcheck disable=SC2188
        local _c_lock_owner
        _c_lock_owner=$(cat "$_c_bench_lock" 2>/dev/null || true)
        if [[ "$_c_lock_owner" =~ ^[0-9]+$ ]] && kill -0 "$_c_lock_owner" 2>/dev/null
        then
            _c_bench_active=1
        fi
    fi

    # orphaned stdin keepers
    _c_my_pid=$$
    for _c_sp in $(pgrep -a bash 2>/dev/null | awk '/llm-stdin/{print $1}' || true)
    do
        if [[ "$_c_sp" =~ ^[0-9]+$ ]] && [[ "$_c_sp" != "$_c_my_pid" ]]
        then
            # Only kill true orphans. Live keepers can belong to an active
            # model run in another shell.
            _c_ppid=$(ps -o ppid= -p "$_c_sp" 2>/dev/null | tr -d '[:space:]')
            _c_cmd=$(ps -o args= -p "$_c_sp" 2>/dev/null || true)
            if [[ "$_c_cmd" == *"llm-stdin"* ]] && {
                [[ "$_c_ppid" == "1" ]] || ! [[ " ${_c_live_model_shells[*]} " == *" $_c_ppid "* ]];
            }
            then
                kill -TERM "$_c_sp" 2>/dev/null || true
            fi
        fi
    done

    # orphaned bench timeout wrappers (left behind after interrupted runs)
    # Only reap when no active bench owner exists.
    local _c_bp _c_bppid _c_bcmd
    if (( _c_bench_active == 0 ))
    then
        for _c_bp in $(pgrep -af '__BENCH_MODE=1' 2>/dev/null | awk '{print $1}' || true)
        do
            [[ "$_c_bp" =~ ^[0-9]+$ ]] || continue
            _c_bppid=$(ps -o ppid= -p "$_c_bp" 2>/dev/null | tr -d '[:space:]')
            _c_bcmd=$(ps -o args= -p "$_c_bp" 2>/dev/null || true)
            if [[ "$_c_bcmd" == *"__BENCH_MODE=1"* ]] && [[ "$_c_bppid" != "$$" ]]
            then
                kill -TERM "$_c_bp" 2>/dev/null || true
                sleep 1
                kill -KILL "$_c_bp" 2>/dev/null || true
            fi
        done
    fi

    # orphaned keeper PID files
    for _c_kf in /tmp/llm-keeper.*.pid
    do
        [[ -f "$_c_kf" ]] || continue
        local _c_remove_kf=1
        # shellcheck disable=SC2188
        _c_pid=$(<"$_c_kf" 2>/dev/null || true)
        if [[ "$_c_pid" =~ ^[0-9]+$ ]]
        then
            if kill -0 "$_c_pid" 2>/dev/null
            then
                _c_ppid=$(ps -o ppid= -p "$_c_pid" 2>/dev/null | tr -d '[:space:]')
                _c_cmd=$(ps -o args= -p "$_c_pid" 2>/dev/null || true)
                if [[ "$_c_cmd" == *"sleep 3600"* ]] && {
                    [[ "$_c_ppid" == "1" ]] || ! [[ " ${_c_live_model_shells[*]} " == *" $_c_ppid "* ]];
                }
                then
                    kill -TERM "$_c_pid" 2>/dev/null || true
                else
                    # Live non-orphan keeper: keep its PID file so active
                    # model-stop flows still have the right target.
                    _c_remove_kf=0
                fi
            fi
        fi
        (( _c_remove_kf == 1 )) && rm -f "$_c_kf"
    done

    # Fallback: if a keeper lost its PID file, reap any remaining sleep-loop
    # helpers that are no longer attached to a live model shell.
    while IFS= read -r _c_line
    do
        [[ -n "$_c_line" ]] || continue
        _c_sp=${_c_line%% *}
        _c_cmd=${_c_line#* }
        [[ "$_c_sp" =~ ^[0-9]+$ ]] || continue
        [[ "$_c_cmd" == *"sleep 3600"* ]] || continue
        _c_ppid=$(ps -o ppid= -p "$_c_sp" 2>/dev/null | tr -d '[:space:]')
        if [[ -z "$_c_ppid" ]] || [[ "$_c_ppid" == "1" ]] || ! [[ " ${_c_live_model_shells[*]} " == *" $_c_ppid "* ]]
        then
            kill -TERM "$_c_sp" 2>/dev/null || true
        fi
    done < <(pgrep -af 'sleep 3600' 2>/dev/null || true)

    return 0
}

# ---------------------------------------------------------------------------
# __llm_json_escape — Escape a string for safe inline JSON output.
# @returns 0 always.

# ---------------------------------------------------------------------------
# __gpu_clear_stale_processes — Kill stale Python/CUDA processes holding VRAM.
# Bench/autotune call __model_stop which only kills llama-server. Python
# processes holding CUDA contexts are not cleared, silently consuming VRAM.
# This function finds python3.12 processes that hold GPU file descriptors
# and kills any that are not the current bench/autotune session.
# REF: G-5 audit — VRAM clearing gap
# ---------------------------------------------------------------------------
function __gpu_clear_stale_processes() {
    local _gpu_pid _keep_pid _keep_pids _stale_wait count=0
    _keep_pid="$$"
    _keep_pids=" $PPID $_keep_pid "
    while IFS= read -r _gpu_pid; do
        [[ "$_gpu_pid" =~ ^[0-9]+$ ]] || continue
        [[ "$_keep_pids" == *" $_gpu_pid "* ]] && continue
        local _gpu_etime _gpu_cmd
        _gpu_etime=$(ps -o etime= -p "$_gpu_pid" 2>/dev/null | tr -d '[:space:]')
        _gpu_cmd=$(ps -o comm= -p "$_gpu_pid" 2>/dev/null | tr -d '[:space:]')
        [[ -z "$_gpu_cmd" ]] && continue
        [[ "$_gpu_cmd" == *llama* ]] && continue
        if [[ "$_gpu_cmd" == python* ]]; then
            kill -TERM "$_gpu_pid" 2>/dev/null || true
            # Graceful wait (WSL2 dxgkrnl): SIGKILL orphans the process's CUDA
            # handles; poll up to 15s for a clean exit before escalating.
            _stale_wait=0
            while kill -0 "$_gpu_pid" 2>/dev/null && (( _stale_wait < 15 )); do
                sleep 1; _stale_wait=$((_stale_wait + 1))
            done
            if kill -0 "$_gpu_pid" 2>/dev/null; then
                kill -KILL "$_gpu_pid" 2>/dev/null || true
            fi
            count=$((count + 1))
        fi
    done < <(nvidia-smi --query-compute-apps=pid --format=csv,noheader 2>/dev/null || true)
    if (( count > 0 )); then
        __tac_info "VRAM" "killed ${count} stale GPU process(es)" "$C_Warning"
    fi
}

# ---------------------------------------------------------------------------
# __llm_kill_cuda_llama_servers — Kill ONLY CUDA-held llama.cpp processes.
#
# Two-card machine: the Xe fleet server (llama-server.service, :18081) and
# the embed server (llama-embed-server.service, :18080) run the SAME
# llama-server binary on the Intel Xe via OpenCL as every CUDA server.  A
# name-based pkill (pkill -x/-f llama-server) therefore collateral-kills the
# Xe fleet even though it holds NO CUDA VRAM.  This helper kills only
# llama.cpp processes that hold a CUDA compute context
# (nvidia-smi --query-compute-apps) and, as a second guard, excludes the
# MainPIDs of the persistent llama systemd units (a live NVIDIA unit must
# never be evicted by an autotune/bench cleanup either).
#
# Prints nothing on stdout (bench harnesses parse it); warnings go to stderr.
# ---------------------------------------------------------------------------
function __llm_kill_cuda_llama_servers() {
    local _unit _svc_pid _pid _comm _smi _skip _p _llm_wait _alive
    local -a _protected=() _cuda_pids=() _kill_pids=()

    # Protected: MainPIDs of the persistent llama systemd units.
    for _unit in llama-server.service llama-embed-server.service \
                 llama-server-nvidia.service llama-server-phi4.service
    do
        _svc_pid=$(systemctl --user show -p MainPID --value "$_unit" 2>/dev/null | tr -d ' \n' || true)
        if [[ "$_svc_pid" =~ ^[0-9]+$ ]] && (( _svc_pid > 0 ))
        then
            _protected+=("$_svc_pid")
        fi
    done

    # CUDA attribution: only llama.cpp processes holding a CUDA compute
    # context are candidates.  When nvidia-smi cannot attribute (absent or
    # probe failure) we kill NOTHING rather than fall back to a name sweep —
    # a name sweep would reintroduce the Xe collateral this helper exists to
    # prevent.
    _smi=$(command -v nvidia-smi 2>/dev/null || true)
    if [[ -z "$_smi" ]]
    then
        echo "[llm-kill] nvidia-smi unavailable — skipping llama cleanup (no CUDA attribution)" >&2
        return 0
    fi
    while read -r _pid
    do
        [[ "$_pid" =~ ^[0-9]+$ ]] || continue
        _comm=$(cat "/proc/$_pid/comm" 2>/dev/null || echo "")
        [[ "$_comm" == llama* ]] || continue
        _cuda_pids+=("$_pid")
    done < <("$_smi" --query-compute-apps=pid --format=csv,noheader,nounits 2>/dev/null || true)

    if [[ ${#_cuda_pids[@]} -eq 0 ]]
    then
        return 0
    fi

    for _pid in "${_cuda_pids[@]}"
    do
        _skip=0
        for _p in "${_protected[@]:-}"
        do
            [[ "$_pid" == "$_p" ]] && { _skip=1; break; }
        done
        (( _skip == 0 )) && _kill_pids+=("$_pid")
    done

    if [[ ${#_kill_pids[@]} -gt 0 ]]
    then
        echo "[llm-kill] killing CUDA llama-server PIDs: ${_kill_pids[*]}" >&2
        kill -TERM "${_kill_pids[@]}" 2>/dev/null || true
        # Graceful wait (WSL2 dxgkrnl): SIGKILL orphans the servers' CUDA
        # handles; poll up to 15s for a clean exit before escalating.
        _llm_wait=0
        while (( _llm_wait < 15 )); do
            _alive=0
            for _pid in "${_kill_pids[@]}"; do
                if kill -0 "$_pid" 2>/dev/null; then _alive=1; break; fi
            done
            (( _alive == 0 )) && break
            sleep 1; _llm_wait=$((_llm_wait + 1))
        done
        for _pid in "${_kill_pids[@]}"
        do
            if kill -0 "$_pid" 2>/dev/null
            then
                kill -KILL "$_pid" 2>/dev/null || true
            fi
        done
    fi
}

# ---------------------------------------------------------------------------
function wake() {
    local smi_cmd
    smi_cmd=$(__resolve_smi) || {
        __tac_info "GPU" "[nvidia-smi not found]" "$C_Error"
        return 1
    }

    # Try to enable persistence mode; capture output for NVML error detection
    local _pm_output
    _pm_output=$(sudo -n "$smi_cmd" -pm 1 2>&1)
    local _pm_status=$?

    # Check for any NVML initialization failure (common in WSL2 with various driver states)
    if [[ "$_pm_output" == *"Failed to initialize NVML"* ]]
    then
        # NVML unavailable (WSL2/driver limitation) — GPU still works for inference
        return 0
    fi

    # Check for actual failure (sudo denied or other error)
    if (( _pm_status != 0 ))
    then
        if [[ "$_pm_output" == *"password"* || "$_pm_output" == *"sudo"* || "$_pm_output" == *"authentication"* ]]
        then
            __tac_info "GPU Persistence" "[FAILED - passwordless sudo required for nvidia-smi]" "$C_Warning"
        else
            __tac_info "GPU Persistence" "[FAILED - nvidia-smi error: $_pm_output]" "$C_Warning"
        fi
        return 1
    fi

    __tac_info "GPU Persistence" "[ENABLED]" "$C_Success"

    local gpu_stat
    gpu_stat=$("$smi_cmd" \
        --query-gpu=utilization.gpu,memory.used,memory.total,temperature.gpu \
        --format=csv,noheader,nounits 2>/dev/null)
    if [[ -n "$gpu_stat" ]]
    then
        local g_util g_used g_total g_temp
        IFS=',' read -r g_util g_used g_total g_temp <<< "$gpu_stat"
        g_util="${g_util// /}"; g_used="${g_used// /}"; g_total="${g_total// /}"; g_temp="${g_temp// /}"
        __tac_info "GPU Util" "${g_util}%" "$C_Text"
        __tac_info "GPU VRAM" "${g_used} MiB / ${g_total} MiB" "$C_Text"
        __tac_info "Temp" "${g_temp}${DEGREE}C" "$C_Text"
    fi
}

# ---------------------------------------------------------------------------
# gpu-status — Detailed NVIDIA GPU status (replaces standalone oc-gpu-status).
# Shows utilisation, VRAM, temperature, power draw, persistence mode.
# ---------------------------------------------------------------------------
function gpu-status() {
    local smi
    smi=$(__resolve_smi) || {
        __tac_info "GPU" "[nvidia-smi not found]" "$C_Error"
        return 1
    }

    __tac_header "GPU STATUS" "open"

    while IFS=, read -r gname gutil gmused gmtotal gmfree gtemp gpwr gplim
    do
        gutil="${gutil// /}"; gmused="${gmused// /}"; gmtotal="${gmtotal// /}"
        gmfree="${gmfree// /}"; gtemp="${gtemp// /}"; gpwr="${gpwr// /}"; gplim="${gplim// /}"

        local util_n="${gutil%\%}"
        if ! [[ "$util_n" =~ ^[0-9]+$ ]]
        then
            util_n=0
        fi
        local color
        color=$(__threshold_color "$util_n")

        __tac_info "GPU" "${gname}" "$C_Highlight"
        __tac_info "Util" "${color}${gutil}${C_Reset}" "$color"
        __tac_info "VRAM" "${gmused} / ${gmtotal} (${gmfree} free)" "$C_Text"
        __tac_info "Temp" "${gtemp} C" "$C_Text"
        __tac_info "Power" "${gpwr} / ${gplim}" "$C_Text"
    done < <("$smi" \
        --query-gpu=name,utilization.gpu,memory.used,memory.total,memory.free,temperature.gpu,power.draw,power.limit \
        --format=csv,noheader 2>/dev/null)

    local pm
    pm=$("$smi" --query-gpu=persistence_mode --format=csv,noheader 2>/dev/null | head -1 | tr -d ' ')
    if [[ "$pm" == "Enabled" ]]
    then
        __tac_info "Persist" "ON" "$C_Success"
    else
        __tac_info "Persist" "OFF (run 'wake' to enable)" "$C_Warning"
    fi
    __tac_footer
}

# ---------------------------------------------------------------------------
# gpu-check — Quick 5-second CUDA verification.
# Confirms nvidia-smi is reachable, the GPU is visible, and (if a model is
# running) that llama-server is actually offloading layers to the GPU.
# ---------------------------------------------------------------------------
function gpu-check() {
    local smi
    smi=$(__resolve_smi 2>/dev/null) || true

    __tac_header "CUDA / GPU CHECK" "open"

    # 1. nvidia-smi reachable?
    if [[ -z "$smi" ]]
    then
        __tac_info "nvidia-smi" "NOT FOUND - GPU passthrough broken" "$C_Error"
        __tac_info "Tip" "In WSL run: nvidia-smi  (if this fails, CUDA is unavailable)" "$C_Dim"
        __tac_footer; return 1
    fi
    __tac_info "nvidia-smi" "OK" "$C_Success"

    # 2. CUDA device visible?
    local gpu_name
    gpu_name=$("$smi" --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)
    if [[ -z "$gpu_name" ]]
    then
        __tac_info "CUDA Device" "NONE DETECTED" "$C_Error"
        __tac_footer; return 1
    fi
    __tac_info "CUDA Device" "$gpu_name" "$C_Success"

    # 3. VRAM status
    local vram
    vram=$("$smi" --query-gpu=memory.used,memory.total --format=csv,noheader,nounits 2>/dev/null | head -1)
    if [[ -n "$vram" ]]
    then
        local used total
        IFS=',' read -r used total <<< "$vram"
        used="${used// /}"; total="${total// /}"
        __tac_info "VRAM" "${used} MiB / ${total} MiB" "$C_Text"
    fi

    # 4. llama-server CUDA offload (check the runtime log)
    if __llm_server_running && [[ -f "$LLM_LOG_FILE" ]]
    then
        local offload_line
        offload_line=$(grep -i \
            'offload.*layers to GPU\|offloading.*layers to GPU' \
            "$LLM_LOG_FILE" 2>/dev/null | tail -1)
        local cuda_line
        cuda_line=$(grep -i 'ggml_cuda.*found.*CUDA' "$LLM_LOG_FILE" 2>/dev/null | tail -1)

        if [[ -n "$cuda_line" ]]
        then
            __tac_info "CUDA Init" "${cuda_line##*: }" "$C_Success"
        fi
        if [[ -n "$offload_line" ]]
        then
            __tac_info "Offload" "${offload_line##*: }" "$C_Success"
        elif [[ -n "$cuda_line" ]]
        then
            __tac_info "Offload" "No offload line found (check -ngl setting)" "$C_Warning"
        else
            __tac_info "Offload" "No CUDA references in log - may be CPU-only build" "$C_Error"
        fi
    else
        __tac_info "Server" "Not running - start a model to verify offloading" "$C_Dim"
    fi

    __tac_footer
}

# ---------------------------------------------------------------------------
# model — Unified LLM model manager (v3 — auto-scan, numbered selection).
# Subcommands: scan, list, default, use, stop, status, doctor, recommend,
#   info, bench, bench-diff, bench-compare, bench-latest, bench-history,
#   delete, archive, download
# Registry: models.conf — auto-generated by 'model scan', do not hand-edit.
# Format: #|name|file|size_gb|quant_cache|arch|gpu_layers|ctx|threads|batch|ubatch|parallel|fit_target_mb|backend|mmap_mode|flash_attn|tps|autotuned|is_default|in_vram|prefill_tps|p2_ctx|p2_batch|p2_ubatch|p2_tps|p2_prefill
# Active model tracked in: $ACTIVE_LLM_FILE (just the model number)
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# __gguf_metadata — Extract key metadata from a GGUF file header.
# Outputs: name|architecture|block_count|context_length|file_type
# Uses dd+awk to parse GGUF binary format (pure bash, no python dependency).
# Reads first 256KB — sufficient for all KV metadata in any GGUF file.
# ---------------------------------------------------------------------------
function __gguf_metadata() {
    local fpath="$1" fname
    fname=$(basename "$fpath" .gguf)
    dd if="$fpath" bs=262144 count=1 2>/dev/null | od -A n -t u1 -v | \
    awk -v fname="$fname" '
    #-------------------------------------------------------------------
    # GGUF binary parser (pure awk).
    # Input: unsigned byte stream from od -t u1.
    # GGUF layout: 4-byte magic "GGUF" (71,71,85,70), version (u32),
    #   tensor_count (u64), metadata_kv_count (u64), then KV pairs.
    # Each KV: key_len (u64), key (utf8), value_type (u32), value.
    # We extract 5 fields: name, architecture, block_count, ctx, ftype.
    #-------------------------------------------------------------------

    # Helper: read a little-endian u32 from byte array at offset p.
    function u32(p) {
        return b[p] + b[p+1]*256 + b[p+2]*65536 + b[p+3]*16777216
    }

    # Phase 1: Load all bytes into array b[0..n-1].
    { for (i = 1; i <= NF; i++) b[n++] = $i + 0 }

    END {
        # --- Validate GGUF magic bytes ---
        if (n < 24 || b[0] != 71 || b[1] != 71 || b[2] != 85 || b[3] != 70) {
            print fname "|unknown|0|4096|0"
            exit
        }

        # --- Read metadata KV count (u64, but only lower 32 bits matter) ---
        nkv = u32(16)

        # Sanity check: no valid GGUF has more than 10000 metadata keys.
        # Corrupted/truncated files could have garbage nkv causing out-of-bounds reads.
        if (nkv > 10000 || nkv < 0) {
            print fname "|unknown|0|4096|0"
            exit
        }

        # --- Defaults (overwritten if keys are found) ---
        name   = fname
        arch   = "unknown"
        blocks = 0
        ctx    = 4096
        ftype  = 0
        found  = 0

        # --- Walk KV pairs ---
        # Offset starts after the 24-byte header (magic + version + counts).
        off = 24
        for (kv = 0; kv < nkv && off < n - 8; kv++) {

            # -- Read key: length (u64, lower 32) then UTF-8 bytes --
            klen = u32(off); off += 8
            if (klen < 0 || klen > 1000 || off + klen > n) break
            key = ""
            for (i = 0; i < klen; i++)
                key = key sprintf("%c", b[off + i])
            off += klen

            # -- Read value type (u32) --
            if (off + 4 > n) break
            vt = u32(off); off += 4

            # -- Type 8: STRING (u64 length + UTF-8 bytes) --
            if (vt == 8) {
                if (off + 8 > n) break
                vlen = u32(off); off += 8
                if (off + vlen > n) break
                val = ""
                for (i = 0; i < vlen; i++)
                    val = val sprintf("%c", b[off + i])
                off += vlen
                if (key == "general.architecture") { arch = val; found++ }
                if (key == "general.name")         { name = val; found++ }
            }
            # -- Types 4,5: UINT32, INT32 (4 bytes) --
            else if (vt == 4 || vt == 5) {
                if (off + 4 > n) break
                val = u32(off); off += 4
                if (key == "general.file_type")  { ftype  = val; found++ }
                if (key ~ /block_count/)         { blocks = val; found++ }
                if (key ~ /context_length/)      { ctx    = val; found++ }
            }
            # -- Types 10,11,12: UINT64, INT64, FLOAT64 (8 bytes) --
            else if (vt == 10 || vt == 11 || vt == 12) {
                if (off + 8 > n) break
                val = u32(off); off += 8
                if (key == "general.file_type")  { ftype  = val; found++ }
                if (key ~ /block_count/)         { blocks = val; found++ }
                if (key ~ /context_length/)      { ctx    = val; found++ }
            }
            # -- Type 6: FLOAT32 (4 bytes) --
            else if (vt == 6) { off += 4 }
            # -- Types 0,1,7: UINT8, INT8, BOOL (1 byte) --
            else if (vt == 0 || vt == 1 || vt == 7) { off += 1 }
            # -- Types 2,3: UINT16, INT16 (2 bytes) --
            else if (vt == 2 || vt == 3) { off += 2 }
            # -- Type 9: ARRAY (element_type u32, count u64, then elements) --
            else if (vt == 9) {
                if (off + 12 > n) break
                at = u32(off); off += 4              # element type
                al = u32(off); off += 8              # array length (lower 32)
                # Skip array contents based on element type
                if      (at == 0 || at == 1 || at == 7)          off += al
                else if (at == 2 || at == 3)                     off += al * 2
                else if (at == 4 || at == 5 || at == 6)          off += al * 4
                else if (at == 10 || at == 11 || at == 12)       off += al * 8
                else if (at == 8) {
                    # Array of strings: each has u64 len + bytes
                    for (a = 0; a < al && off < n; a++) {
                        sl = u32(off)
                        off += 8 + sl
                    }
                }
                else break  # unknown element type - bail
            }
            else break  # unknown value type - bail

            # Early exit once all 5 target keys are found.
            if (found >= 5) break
        }

        print name "|" arch "|" blocks "|" ctx "|" ftype
    }'
}

# __calc_gpu_layers — Calculate optimal GPU layer count for available VRAM.
# Strategy: use -ngl 999 at launch to let llama.cpp offload the maximum
# layers that fit in VRAM. This scan-time function determines the launch
# MODE (gpu vs cpu-only) and stores a hint for display/logging. The actual
# offload count is decided by the runtime, not by this calculation.
#
# Decision logic (binary, not partial offload):
#   - If model fits entirely in VRAM: return 999 (offload all layers)
#   - If model exceeds VRAM: return 0 (CPU-only mode is faster than partial)
#   - For MoE models: return total_layers (expert weights stay on CPU anyway)
#
# Rationale: Partial offload (some layers on GPU, rest in system RAM) causes
# PCIe bandwidth bottlenecks. Pure CPU inference with --mlock is faster than
# the hybrid path when the model doesn't fit in VRAM.
# Args: file_size_bytes total_layers [arch]
# Returns: 999 (max offload), total_layers (MoE), or 0 (CPU-only)
function __calc_gpu_layers() {
    local _file_bytes=$1 _total_layers=$2 _arch="${3:-}"
    local usable_vram=$(( VRAM_TOTAL_BYTES * VRAM_USABLE_PCT / 100 ))

    # MoE models keep experts on CPU; full offload heuristics are not useful.
    if [[ "${_arch,,}" == *moe* ]]
    then
        echo "${_total_layers:-0}"
        return
    fi

    # Full offload when the model fits in usable VRAM, otherwise CPU-only.
    if (( _file_bytes <= usable_vram ))
    then
        echo 999
    else
        echo 0
    fi
}

# __calc_ctx_size — Pick a practical context size.
# Must account for KV cache VRAM: larger ctx = more VRAM consumed beyond model weights.
# CPU-only models (>4GB) have no VRAM constraint so can use larger ctx.
# For GPU-capable models, estimates ctx from VRAM budget so first registration
# is realistic instead of storing the GGUF metadata value (which can be 1M+).
function __calc_ctx_size() {
    local _file_bytes=$1 _native_ctx=$2 _arch="${3:-}"
    # MoE models use a stable conservative context regardless of size.
    if [[ "${_arch,,}" == *moe* ]]
    then
        echo "$MOE_DEFAULT_CTX"
        return
    fi

    # CPU-only mode (model exceeds VRAM threshold): cap to MOE_DEFAULT_CTX.
    if (( _file_bytes > VRAM_TOTAL_BYTES * VRAM_THRESHOLD_PCT / 100 ))
    then
        echo "$MOE_DEFAULT_CTX"
        return
    fi

    # GPU-capable: estimate realistic ctx from VRAM budget.
    # KV cache overhead: ~0.5 MB per layer per 1K tokens (q8_0 K + f16 V).
    # We budget remaining VRAM after model weights for ~20K context as a
    # practical starting point, capped by the model's native max.
    local _model_mb=$(( _file_bytes / 1048576 ))
    local _vram_free_mb
    if command -v nvidia-smi &>/dev/null; then
        _vram_free_mb=$(nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ')
    fi
    [[ "$_vram_free_mb" =~ ^[0-9]+$ ]] || _vram_free_mb=""
    local _vram_total_mb=$(( VRAM_TOTAL_BYTES / 1048576 ))  # 4096 for 4GB
    [[ -n "$_vram_free_mb" && "$_vram_free_mb" -gt "$_vram_total_mb" ]] && _vram_free_mb=$_vram_total_mb
    local _vram_avail_mb=$(( _vram_total_mb - _model_mb - 200 ))  # minus weights + 200MB OS
    [[ -n "$_vram_free_mb" && "$_vram_free_mb" -lt "$_vram_avail_mb" ]] && _vram_avail_mb=$_vram_free_mb

    # Estimate KV cache MB per 1K tokens from model size (proxy for layer count).
    # Typical: <1GB ~16 layers (0.5 MB/layer => 8 MB/1K), 1-2GB ~24 layers (12 MB/1K),
    # 2-3GB ~28 layers (14 MB/1K), 3-4GB ~32 layers (16 MB/1K)
    local _kv_mb_per_1k=12.0
    if (( _model_mb >= 3500 )); then
        _kv_mb_per_1k=16.0
    elif (( _model_mb >= 2000 )); then
        _kv_mb_per_1k=14.0
    elif (( _model_mb >= 1000 )); then
        _kv_mb_per_1k=12.0
    elif (( _model_mb >= 500 )); then
        _kv_mb_per_1k=10.0
    else
        _kv_mb_per_1k=8.0
    fi

    if (( _vram_avail_mb > 0 )); then
        # Estimate ctx from available VRAM: ctx = trunc(vram_avail / kv_mb_per_1k * 1000 / 1024) * 1024
        local _est_ctx
        _est_ctx=$(awk -v v="$_vram_avail_mb" -v k="$_kv_mb_per_1k" 'BEGIN{c=int(v/k*1000/1024)*1024; print c<4096?4096:c}')
        # Cap at native model context limit
        if (( _native_ctx > 0 && _native_ctx < _est_ctx )); then
            _est_ctx=$_native_ctx
        fi
        # Absolute ceiling: 64K for initial registration on a 4GB GPU.
        # Autotune will find the real optimum; this is just a realistic first guess.
        (( _est_ctx > 65536 )) && _est_ctx=65536
        echo "$_est_ctx"
    else
        # No VRAM available before freeing model weights, use a conservative fallback
        if (( _native_ctx > 0 )); then
            # Cap native ctx to a value proportional to model size vs VRAM
            local _ratio=$(( _model_mb * 100 / _vram_total_mb ))
            if (( _ratio >= 100 )); then
                echo "$MOE_DEFAULT_CTX"
            elif (( _ratio >= 75 )); then
                local _cap=$(( _native_ctx < 16384 ? _native_ctx : 16384 ))
                echo "$_cap"
            else
                local _cap=$(( _native_ctx < 32768 ? _native_ctx : 32768 ))
                echo "$_cap"
            fi
        else
            echo "$MOE_DEFAULT_CTX"
        fi
    fi
}

# ---------------------------------------------------------------------------
# __bench_resolve_files — Resolve old/new benchmark TSV paths.
# Usage:
#   __bench_resolve_files                   -> latest two bench TSVs
#   __bench_resolve_files old.tsv new.tsv   -> explicit files
# Outputs: old_path|new_path
# ---------------------------------------------------------------------------
function __bench_resolve_files() {
    if (( $# == 2 ))
    then
        printf '%s|%s\n' "$1" "$2"
        return 0
    fi
    if (( $# != 0 ))
    then
        return 1
    fi

    local latest_files=()
    while IFS= read -r bench_file
    do
        latest_files+=("$bench_file")
    done < <(find "$HOME/.llm" -maxdepth 1 -name 'bench_*.tsv' -type f \
        -printf '%T@ %p\n' 2>/dev/null | sort -n -r | head -2 | cut -d' ' -f2-)

    if (( ${#latest_files[@]} < 2 ))
    then
        return 1
    fi

    # newest first from ls -t; diff should read old -> new
    printf '%s|%s\n' "${latest_files[1]}" "${latest_files[0]}"
}

# ---------------------------------------------------------------------------
# __bench_latest_file — Return newest benchmark TSV path.
# Returns 1 if no bench TSV exists.
# ---------------------------------------------------------------------------
function __bench_latest_file() {
    find "$HOME/.llm" -maxdepth 1 -name 'bench_*.tsv' -type f \
        -printf '%T@ %p\n' 2>/dev/null | sort -n -r | head -1 | cut -d' ' -f2-
}

# ---------------------------------------------------------------------------
# __llm_thread_cap — Clamp a compute-thread count to the i9-12900HK P-cores.
# Usage: __llm_thread_cap <threads>  ->  prints min(threads, 6)
#
# On the i9-12900HK (6 P-cores / 8 E-cores) any thread count above 6 spills
# onto the efficiency cores and SLOWS generation via sync latency — the
# DFlash article's hybrid-architecture pitfall.  WSL2 exposes 12 CPUs
# (`processors=12` in .wslconfig → `nproc` = 12), so every nproc-derived
# count must be capped here or it silently exceeds the P-core ceiling.
#
# REF: "Speculative Decoding on CPUs — Nearly 4x Faster Token Generation
# with DFlash" (Intel, TDS 2026)
# https://towardsdatascience.com/speculative-decoding-on-cpus-nearly-4x-faster-token-generation-with-dflash/
function __llm_thread_cap() {
    local _raw="${1:-6}"
    [[ "$_raw" =~ ^[0-9]+$ ]] || _raw=6
    if (( _raw > 6 )); then
        echo "6"
    else
        echo "$_raw"
    fi
}

# ---------------------------------------------------------------------------
# __spec_decode_stats — Parse llama-server speculative-decode stats from a log.
# Usage: __spec_decode_stats <logfile>
# Output: rate|accepted|generated|mean_len|present
#   rate      acceptance ratio (accepted/generated draft tokens)
#   accepted  draft tokens accepted by the target model
#   generated draft tokens proposed
#   mean_len  mean acceptance LENGTH = accepted-per-round + 1 (the article's
#             tuning metric — do NOT compare runs on rate alone)
#   present   "yes" when a stats line was found, "no" otherwise
# The server emits one "draft acceptance = ..." line per completed request
# (tools/server/server-context.cpp @1692f9e50); the LAST line is the most
# recent request.  SPEC-DEC-003: counter inflation — usage.completion_tokens
# can count accepted final-block tokens discarded at max_tokens, so TPS must
# be recomputed from delivered tokens when spec-decode is on.
#
# REF: "Speculative Decoding on CPUs — Nearly 4x Faster Token Generation
# with DFlash" (Intel, TDS 2026)
# https://towardsdatascience.com/speculative-decoding-on-cpus-nearly-4x-faster-token-generation-with-dflash/
function __spec_decode_stats() {
    local _log="${1:-}"
    [[ -f "$_log" ]] || { echo "0|0|0|0|no"; return 1; }
    local _line
    _line=$(grep -oE 'draft acceptance = [0-9.]+ \( *[0-9]+ accepted / *[0-9]+ generated\), mean len = *[0-9.]+' \
        "$_log" 2>/dev/null | tail -1)
    [[ -n "$_line" ]] || { echo "0|0|0|0|no"; return 1; }

    # shellcheck disable=SC2001
    local _clean
    _clean=$(echo "$_line" | sed -E \
        -e 's/draft acceptance = //' \
        -e 's/ *\( *([0-9]+) accepted \/ *([0-9]+) generated\), mean len = */|\1|\2|/')
    local _rate _accepted _generated _mean_len
    IFS='|' read -r _rate _accepted _generated _mean_len <<< "$_clean"
    [[ "$_rate" =~ ^[0-9.]+$ ]] || _rate=0
    [[ "$_accepted" =~ ^[0-9]+$ ]] || _accepted=0
    [[ "$_generated" =~ ^[0-9]+$ ]] || _generated=0
    [[ "$_mean_len" =~ ^[0-9.]+$ ]] || _mean_len=0
    echo "${_rate}|${_accepted}|${_generated}|${_mean_len}|yes"
}

# ---------------------------------------------------------------------------
# __spec_block_size — Resolve the active speculative-decode block size.
# Priority: LLM_SPEC_DRAFT_N_MAX env > LLM_SPECULATIVE_NGRAM env > the active
# model's registry spec_draft_n_max (field 29, written by SPEC-DEC-004
# autotune) > 16 (the llama.cpp --spec-draft-n-max default).  Prints int.
function __spec_block_size() {
    local _n_max="${LLM_SPEC_DRAFT_N_MAX:-}"
    [[ "$_n_max" =~ ^[0-9]+$ ]] && [[ $_n_max -gt 0 ]] && { echo "$_n_max"; return 0; }
    local _ngram="${LLM_SPECULATIVE_NGRAM:-}"
    [[ "$_ngram" =~ ^[0-9]+$ ]] && [[ $_ngram -gt 0 ]] && { echo "$_ngram"; return 0; }
    if [[ -f "${ACTIVE_LLM_FILE:-}" && -f "$LLM_REGISTRY" ]]; then
        local _act_num _act_row _reg_n_max
        _act_num=$(cat "$ACTIVE_LLM_FILE" 2>/dev/null || true)
        if [[ "$_act_num" =~ ^[0-9]+$ ]]; then
            _act_row=$(awk -F'|' -v n="$_act_num" '$1 == n {print; exit}' "$LLM_REGISTRY" 2>/dev/null || true)
            _reg_n_max=$(echo "$_act_row" | cut -d'|' -f29)
            [[ "$_reg_n_max" =~ ^[0-9]+$ ]] && [[ $_reg_n_max -gt 0 ]] && { echo "$_reg_n_max"; return 0; }
        fi
    fi
    echo "16"
}

# ---------------------------------------------------------------------------
# __spec_launch_flags — Emit speculative-decoding launch flags (VERIFIED
# llama.cpp @1692f9e50 names — the removed --draft-model / --speculative-ngram
# crash llama-server at launch, common/arg.cpp:825).
#
# Resolution priority: LLM_SPEC_* env overrides > registry row_spec_* fields
# (dynamic scope) > defaults.  Reads: LLM_SPEC_DRAFT_ENABLED, LLM_SPEC_TYPE,
# LLM_SPEC_DRAFT_MODEL, LLM_SPEC_DRAFT_N_MAX, LLM_SPEC_DRAFT_NGL,
# LLM_SPEC_DRAFT_DEVICE, LLM_SPECULATIVE_NGRAM and the row_spec_* variables.
#
# 4 GB VRAM rule: a draft model must NEVER steal VRAM from the target, so the
# default draft placement is CPU-only (--spec-draft-device none) unless the
# user explicitly sets LLM_SPEC_DRAFT_NGL>0 or LLM_SPEC_DRAFT_DEVICE.
#
# Speculative decoding is LOSSLESS (rejection sampling recovers the target
# distribution exactly) — preferred over lossy quantization for
# quality-critical paths (legal evidence); ngram spec-decode needs no extra
# model and is the natural first step on a 4 GB card.
#
# Output: one flag per line on stdout (paths may contain spaces); empty when
# spec-decode is disabled or nothing is configured.
#
# REF: "Speculative Decoding on CPUs — Nearly 4x Faster Token Generation
# with DFlash" (Intel, TDS 2026)
# https://towardsdatascience.com/speculative-decoding-on-cpus-nearly-4x-faster-token-generation-with-dflash/
function __spec_launch_flags() {
    # SPEC-DEC-005 knob: disable draft decoding under load (per-server).
    case "${LLM_SPEC_DRAFT_ENABLED:-1}" in
        0|false|FALSE|no|NO|off|OFF) return 0 ;;
    esac

    local _type="${LLM_SPEC_TYPE:-${row_spec_type:-}}"
    local _draft="${LLM_SPEC_DRAFT_MODEL:-${row_spec_draft_model:-}}"
    local _n_max="${LLM_SPEC_DRAFT_N_MAX:-${row_spec_n_max:-0}}"
    [[ "$_n_max" =~ ^[0-9]+$ ]] || _n_max=0
    local _ngl="${LLM_SPEC_DRAFT_NGL:-${row_spec_ngl:-0}}"
    [[ "$_ngl" =~ ^[0-9]+$ ]] || _ngl=0
    local _device="${LLM_SPEC_DRAFT_DEVICE:-${row_spec_device:-}}"
    local _ngram="${LLM_SPECULATIVE_NGRAM:-0}"
    [[ "$_ngram" =~ ^[0-9]+$ ]] || _ngram=0

    [[ -n "$_draft" || "$_type" == "ngram" || $_ngram -gt 0 ]] || return 0

    if [[ -n "$_draft" ]]
    then
        printf '%s\n' "--spec-draft-model" "$_draft"
        if [[ -n "$_device" ]]
        then
            printf '%s\n' "--spec-draft-device" "$_device"
        elif (( _ngl > 0 ))
        then
            printf '%s\n' "--spec-draft-ngl" "$_ngl"
        else
            # CPU-only draft: never steal VRAM from the target on 4 GB.
            printf '%s\n' "--spec-draft-device" "none"
        fi
    fi

    if [[ "$_type" == "ngram" || $_ngram -gt 0 ]]
    then
        local _block="$_n_max"
        (( _block > 0 )) || _block="$_ngram"
        (( _block > 0 )) || _block=16
        # n_min pinned to the block so a small block is actually drafted
        # (the ngram-mod default n_min=48 would swallow smaller blocks).
        printf '%s\n' "--spec-type" "ngram-mod" \
            "--spec-ngram-mod-n-max" "$_block" \
            "--spec-ngram-mod-n-min" "$_block"
    elif (( _n_max > 0 ))
    then
        printf '%s\n' "--spec-draft-n-max" "$_n_max"
    fi
}

# __calc_threads — CPU threads based on how much spills to CPU.
# Uses nproc to detect available threads, then scales:
#   CPU-only  → 80% (all layers on CPU, maximise parallelism)
#   Partial   → 70% (CPU handles remaining layers + KV-cache)
#   Full GPU  → 50% (CPU only does prompt processing + sampling)
# Result is hard-capped at 6 (__llm_thread_cap): on the i9-12900HK hybrid
# architecture, more than 6 compute threads (the P-core count) spill onto
# E-cores and slow generation (SPEC-DEC-002).
function __calc_threads() {
    local _gpu_layers=$1 _total_layers=$2
    local ncpu pct
    ncpu=$(nproc 2>/dev/null || echo 16)

    if (( _gpu_layers <= 0 ))
    then
        pct=80
    elif (( _total_layers > 0 && _gpu_layers >= _total_layers ))
    then
        pct=50
    else
        pct=70
    fi

    local threads=$(( ncpu * pct / 100 ))
    (( threads < 1 )) && threads=1
    __llm_thread_cap "$threads"
}

# __quant_label — Map GGUF file_type int to human-readable quant label.
# Values sourced from llama.cpp's ggml.h GGML_FTYPE enum.
# Falls back to extracting quant from filename if file_type is 0/unknown.
function __quant_label() {
    local ftype=$1 fname=$2
    local label=""
    case "$ftype" in
        1) label="F16";;   2) label="Q4_0";;  3) label="Q4_1";;
        7) label="Q8_0";;  8) label="Q5_0";;  9) label="Q5_1";;  10) label="Q2_K";;
        11) label="Q3_K_S";; 12) label="Q3_K_M";; 13) label="Q3_K_L";;
        14) label="Q4_K_S";; 15) label="Q4_K_M";; 16) label="Q5_K_S";;
        17) label="Q5_K_M";; 18) label="Q6_K";;  19) label="IQ2_XXS";;
        20) label="IQ2_XS";; 21) label="IQ3_XXS";; 26) label="IQ3_M";;
        28) label="Q4_0_4_4";; 29) label="Q4_0_4_8";; 30) label="Q4_0_8_8";;
        *) ;;
    esac
    # Regex matches GGUF quantization naming patterns:
    #   IQ variants (IQ2_XXS, IQ3_M, etc.), standard K-quants (Q4_K_S, Q5_K_M),
    #   base quants (Q4_0, Q8_0), split formats (Q4_0_4_4), and float types (F16, BF16).
    if [[ -z "$label" || "$ftype" == "0" ]] && [[ -n "$fname" ]]
    then
        local quant_pat='(IQ[0-9]_[A-Z]+|Q[0-9]+_K_[SML]'
        quant_pat+='|Q[0-9]+_K|Q[0-9]+_[0-9]+|Q[0-9]+|F16|F32|BF16)'
        local extracted
        extracted=$(echo "$fname" \
            | grep -oiE "$quant_pat" | head -1 \
            | tr '[:lower:]' '[:upper:]')
        [[ -n "$extracted" ]] && label="$extracted"
    fi
    echo "${label:-unknown}"
}

# ---------------------------------------------------------------------------
# __renumber_registry — Remove a model entry by number and renumber the rest.
# Usage: __renumber_registry <model_number>
# Shared by model delete and model archive to avoid duplicated renumber logic.
# ---------------------------------------------------------------------------
function __renumber_registry() {
    local target="$1"
    local old_registry_snapshot
    old_registry_snapshot=$(mktemp "${LLM_REGISTRY}.old.XXXXXX") || return 1
    cp "$LLM_REGISTRY" "$old_registry_snapshot" 2>/dev/null || {
        rm -f "$old_registry_snapshot"
        return 1
    }

    awk -F'|' -v n="$target" '$1 != n && $1 != "#"' "$LLM_REGISTRY" > "${LLM_REGISTRY}.tmp"
    local newnum=0
    {
        echo "#|name|file|size_gb|quant_cache|arch|gpu_layers|ctx|threads|batch|ubatch|parallel|fit_target_mb|backend|mmap_mode|flash_attn|tps|autotuned|is_default|in_vram|prefill_tps|p2_ctx|p2_batch|p2_ubatch|p2_tps|p2_prefill|spec_type|spec_draft_model|spec_draft_n_max|spec_draft_ngl|spec_draft_device|spec_accept_len|workload|ttft_ms|bench_ctx|bench_max_chunks|bench_avg_prompt_tokens"
        while IFS='|' read -r _num rest
        do
            ((++newnum))
            echo "${newnum}|${rest}"
        done < "${LLM_REGISTRY}.tmp"
    } > "${LLM_REGISTRY}.tmp2"
    rm -f "${LLM_REGISTRY}.tmp"
    # Safety: refuse to replace registry with header-only output.
    if [[ -s "${LLM_REGISTRY}.tmp2" ]] && [[ "$(wc -l < "${LLM_REGISTRY}.tmp2")" -ge 2 ]]
    then
        mv "${LLM_REGISTRY}.tmp2" "$LLM_REGISTRY"
    else
        __tac_info "Registry" "[Refusing to overwrite — would leave $(wc -l < "${LLM_REGISTRY}.tmp2") lines]" "$C_Error"
        rm -f "${LLM_REGISTRY}.tmp2"
        rm -f "$old_registry_snapshot"
        return 1
    fi
    __llm_autotune_profiles_remap_by_registry "$old_registry_snapshot" "$LLM_REGISTRY" >/dev/null 2>&1 || true
    rm -f "$old_registry_snapshot"
    rm -f "$ACTIVE_LLM_FILE"
    __llm_registry_sync_state >/dev/null 2>&1 || true
    echo "$newnum"
}

# ---------------------------------------------------------------------------
# __model_scan
# @description Scan GGUF files, regenerate the registry, and archive discouraged quants.
# @returns 0 on success, 1 if the model drive is unavailable or no models are found.
# ---------------------------------------------------------------------------# end of file

# end of file