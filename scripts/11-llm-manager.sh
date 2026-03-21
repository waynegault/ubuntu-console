# shellcheck shell=bash
# shellcheck disable=SC2034,SC2059,SC2120,SC2154
# ─── Module: 11-llm-manager ───────────────────────────────────────────────────────
# AI INSTRUCTION: On ANY change to this file, increment the Module Version below.
# TACTICAL_PROFILE_VERSION auto-computes from the sum of all module versions.
# Module Version: 2
# ==============================================================================
# 11. LLM MODEL MANAGER & OPENCLAW INTEROP
# ==============================================================================
# @modular-section: llm-manager
# @depends: constants, design-tokens, ui-engine, hooks
# @exports: wake, model, serve, halt, mlogs, burn, explain, wtf_repl,
#   __llm_sse_core, __llm_stream, __llm_chat_send, local_chat, chat-context,
#   __gguf_metadata, __calc_gpu_layers, __calc_ctx_size, __calc_threads,
#   __quant_label, __require_llm
# @state-out: LAST_TPS, __LAST_LLM_RESPONSE, ACTIVE_LLM_FILE
#   (These globals are written by this module and read by other modules.)
# @state-in: __LLAMA_DRIVE_MOUNTED (§1), C_* design tokens (§4)
#   (These globals are read by this module but defined in other modules.)

# Ensure LLM_DEFAULT_FILE is defined even if Section 1 wasn't updated
export LLM_DEFAULT_FILE="${LLM_DEFAULT_FILE:-$LLAMA_DRIVE_ROOT/.llm/default_model.conf}"

# ---------------------------------------------------------------------------
# __save_tps — Persist TPS measurement to the registry's tps column.
# Called after burn / llm_stream benchmarks so the dashboard and model list
# can display the most recent inference speed for each model.
# Must run AFTER the model is loaded (ACTIVE_LLM_FILE exists) and the
# registry is initialised (LLM_REGISTRY exists).
# ---------------------------------------------------------------------------
function __save_tps() {
    local tps_val="$1"
    [[ -z "$tps_val" || ! -f "$ACTIVE_LLM_FILE" || ! -f "$LLM_REGISTRY" ]] && return
    local active_num
    active_num=$(< "$ACTIVE_LLM_FILE")
    [[ -z "$active_num" ]] && return
    awk -F'|' -v n="$active_num" -v t="$tps_val" 'BEGIN{OFS="|"} $1 == n {$11 = t} {print}' \
        "$LLM_REGISTRY" > "${LLM_REGISTRY}.tmp" \
        && mv "${LLM_REGISTRY}.tmp" "$LLM_REGISTRY"
}

# ---------------------------------------------------------------------------
# __require_llm — Verify jq is installed and the local LLM is listening.
# Deduplicates the repeated jq + port checks across LLM functions.
# ---------------------------------------------------------------------------
function __require_llm() {
    if ! command -v jq >/dev/null 2>&1
    then
        printf '%s\n' "${C_Error}[jq missing]${C_Reset} Install: sudo apt install -y jq"
        return 1
    fi
    if ! __test_port "$LLM_PORT" >/dev/null 2>&1
    then
        __tac_info "Llama Server" "[OFFLINE]" "$C_Error"
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# wake — Lock the GPU into persistent mode to prevent WDDM sleep in WSL2.
# NOTE: Persistence mode (-pm 1) is a runtime setting and does NOT survive
# WSL restarts. You must re-run 'wake' after each 'wsl --shutdown'.
# ---------------------------------------------------------------------------
function wake() {
    local smi_cmd
    smi_cmd=$(__resolve_smi) || {
        __tac_info "GPU" "[nvidia-smi not found]" "$C_Error"
        return 1
    }

    # Requires passwordless sudo; harmless failure if denied
    if ! sudo -n "$smi_cmd" -pm 1 >/dev/null 2>&1
    then
        __tac_info "GPU Persistence" "[FAILED - sudo denied or nvidia-smi error]" "$C_Warning"
        return 1
    fi
    __tac_info "GPU Persistence" "[ENABLED]" "$C_Success"

    local stat
    stat=$("$smi_cmd" \
        --query-gpu=utilization.gpu,memory.used,memory.total,temperature.gpu \
        --format=csv,noheader,nounits 2>/dev/null || echo "")
    if [[ -n "$stat" ]]
    then
        local g_util g_used g_total g_temp
        IFS=',' read -r g_util g_used g_total g_temp <<< "$stat"
        g_util="${g_util// /}"; g_used="${g_used// /}"; g_total="${g_total// /}"; g_temp="${g_temp// /}"
        __tac_info "GPU Util" "${g_util}%" "$C_Text"
        __tac_info "VRAM" "${g_used} MiB / ${g_total} MiB" "$C_Text"
        __tac_info "Temp" "${g_temp}${DEGREE}C" "$C_Text"
    fi
    printf '%s\n' "${C_Dim}Note: -pm 1 does not survive WSL restarts. Re-run 'wake' after reboot.${C_Reset}"
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

    "$smi" \
        --query-gpu=name,utilization.gpu,memory.used,memory.total,memory.free,temperature.gpu,power.draw,power.limit \
        --format=csv,noheader 2>/dev/null | while IFS=, read -r gname gutil gmused gmtotal gmfree gtemp gpwr gplim
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
    done

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
    smi=$(__resolve_smi) || true

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
    if pgrep -x llama-server >/dev/null 2>&1 && [[ -f "$LLM_LOG_FILE" ]]
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
# Subcommands: scan, list, use, stop, status, info, bench, default
# Registry: models.conf — auto-generated by 'model scan', do not hand-edit.
# Format: #|name|file|size_gb|arch|quant|layers|gpu_layers|ctx|threads
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
            if (off + klen > n) break
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
# Args: file_size_bytes total_layers [arch]
# Returns: 999 (max offload), total_layers (MoE), or 0 (CPU-only)
function __calc_gpu_layers() {
    local file_bytes=$1 total_layers=$2 arch="${3:-}"
    local vram_bytes=$VRAM_TOTAL_BYTES
    local usable_bytes=$((vram_bytes * VRAM_USABLE_PCT / 100))

    # MoE models: with --cpu-moe, expert weights stay on CPU.
    # Only attention/dense layers load to GPU, so we can offload all layers.
    if [[ "$arch" == *"moe"* ]]
    then
        echo "$total_layers"
        return
    fi

    if (( file_bytes <= usable_bytes ))
    then
        # Model fits in VRAM — use 999 to offload everything the runtime can.
        echo 999
    else
        # Model exceeds VRAM — run CPU-only. Partial offload spills into
        # shared GPU memory which is ~10-15x slower than dedicated VRAM;
        # pure CPU inference with --mlock is faster than the hybrid path.
        echo 0
    fi
}

# __calc_ctx_size — Pick a practical context size.
# Must account for KV cache VRAM: larger ctx = more VRAM consumed beyond model weights.
# CPU-only models (>4GB) have no VRAM constraint so can use larger ctx.
function __calc_ctx_size() {
    local file_bytes=$1 native_ctx=$2 arch="${3:-}"
    local file_gb=$(( file_bytes / 1024 / 1024 / 1024 ))
    local vram_limit_gb=$(( VRAM_TOTAL_BYTES * VRAM_THRESHOLD_PCT / 100 / 1024 / 1024 / 1024 ))

    # MoE models: expert weights on CPU, only attention on GPU.
    # Active params ~3B, so treat like a small model for ctx sizing.
    if [[ "$arch" == *"moe"* ]]
    then
        echo "$MOE_DEFAULT_CTX"
        return
    fi

    if (( file_gb > vram_limit_gb ))
    then
        # CPU-only: no VRAM pressure, limited by RAM instead.
        # Use generous ctx but cap at MOE_DEFAULT_CTX to keep RAM usage reasonable.
        local cap=$MOE_DEFAULT_CTX
        if (( native_ctx < cap ))
        then
            echo "$native_ctx"
        else
            echo "$cap"
        fi
    elif (( file_gb >= 3 ))
    then
        echo "$MOE_DEFAULT_CTX"
    else
        local cap=16384
        if (( native_ctx < cap ))
        then
            echo "$native_ctx"
        else
            echo "$cap"
        fi
    fi
}

# __calc_threads — CPU threads based on how much spills to CPU.
# Uses nproc to detect available threads, then scales:
#   CPU-only  → 80% (all layers on CPU, maximise parallelism)
#   Partial   → 70% (CPU handles remaining layers + KV-cache)
#   Full GPU  → 50% (CPU only does prompt processing + sampling)
function __calc_threads() {
    local gpu_layers=$1 total_layers=$2
    local ncpu
    ncpu=$(nproc 2>/dev/null || echo 16)
    local threads
    if (( gpu_layers == 0 ))
    then
        threads=$(( ncpu * 80 / 100 ))
    elif (( gpu_layers >= total_layers ))
    then
        threads=$(( ncpu * 50 / 100 ))
    else
        threads=$(( ncpu * 70 / 100 ))
    fi
    (( threads < 1 )) && threads=1
    echo "$threads"
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
    awk -F'|' -v n="$target" '$1 != n && $1 != "#"' "$LLM_REGISTRY" > "${LLM_REGISTRY}.tmp"
    local newnum=0
    { echo "#|name|file|size_gb|arch|quant|layers|gpu_layers|ctx|threads|tps"
      while IFS='|' read -r _num rest
      do
          ((newnum++))
          echo "${newnum}|${rest}"
      done < "${LLM_REGISTRY}.tmp"
    } > "$LLM_REGISTRY"
    rm -f "${LLM_REGISTRY}.tmp"
    rm -f "$ACTIVE_LLM_FILE"
    echo "$newnum"
}

# @extractable: model() is the largest function (~500 lines). When splitting
# into modules, extract it into its own file (e.g. ~/.bashrc.d/11-llm-model.sh)
# along with __renumber_registry, __quant_label, and __save_tps.
function model() {
    local action="${1:-}"
    (( $# > 0 )) && shift
    local target="${1:-}"

    case "$action" in
        scan)
            # Scan LLAMA_MODEL_DIR for .gguf files, read metadata, calculate params,
            # and regenerate models.conf. Skips vocab/test files (<500MB).
            if (( ! __LLAMA_DRIVE_MOUNTED ))
            then
                __tac_info "Error" \
                    "[Model drive $LLAMA_DRIVE_ROOT is not mounted - run: sudo mount -t drvfs M: $LLAMA_DRIVE_ROOT]" \
                    "$C_Error"
                return 1
            fi
            __tac_info "Scanning" "$LLAMA_MODEL_DIR" "$C_Highlight"
            local tmpconf="${LLM_REGISTRY}.tmp"
            echo "#|name|file|size_gb|arch|quant|layers|gpu_layers|ctx|threads|tps" > "$tmpconf"

            # ── Phase 1: Iterate .gguf files, read metadata, calculate params ──
            local num=0
            for gguf in "$LLAMA_MODEL_DIR"/*.gguf
            do
                [[ ! -f "$gguf" ]] && continue
                local fname
                fname=$(basename "$gguf")
                local fbytes
                fbytes=$(stat --format=%s "$gguf" 2>/dev/null || stat -f%z "$gguf" 2>/dev/null)
                # Skip small files (vocab, test, corrupt)
                (( fbytes < 500000000 )) && continue

                __tac_info "Reading" "$fname" "$C_Dim"
                local meta
                meta=$(__gguf_metadata "$gguf")
                IFS='|' read -r mname march mblocks mctx mftype <<< "$meta"

                local size_gb
                size_gb=$(awk "BEGIN{printf \"%.1f\", $fbytes/1024/1024/1024}")
                local quant
                quant=$(__quant_label "$mftype" "$fname")
                local gpu_layers
                gpu_layers=$(__calc_gpu_layers "$fbytes" "$mblocks" "$march")
                local ctx
                ctx=$(__calc_ctx_size "$fbytes" "$mctx" "$march")
                local threads
                threads=$(__calc_threads "$gpu_layers" "$mblocks")

                ((num++))
                # Preserve existing TPS from previous registry if same file
                local prev_tps="-"
                if [[ -f "$LLM_REGISTRY" ]]
                then
                    prev_tps=$(awk -F'|' -v f="$fname" '$3 == f {print $11}' "$LLM_REGISTRY" 2>/dev/null)
                    [[ -z "$prev_tps" ]] && prev_tps="-"
                fi
                local _reg_line="${num}|${mname}|${fname}|${size_gb}G"
                _reg_line+="|${march}|${quant}|${mblocks}"
                _reg_line+="|${gpu_layers}|${ctx}|${threads}|${prev_tps}"
                echo "$_reg_line" >> "$tmpconf"
                local __tac_msg="${mname} (${size_gb}G, ${quant}, ${mblocks}L ${ARROW_R} ${gpu_layers} GPU)"
                __tac_info "  #${num}" "$__tac_msg" "$C_Success"
            done

            if (( num == 0 ))
            then
                __tac_info "Result" "[No models found in $LLAMA_MODEL_DIR]" "$C_Warning"
                rm -f "$tmpconf"
                return 1
            fi

            mv "$tmpconf" "$LLM_REGISTRY"
            __tac_info "Registry" "[${num} models written to $LLM_REGISTRY]" "$C_Success"

            # ── Phase 2: Quant enforcement — archive discouraged models ──────
            # Quant enforcement: archive discouraged models (skip active model)
            if [[ -f "$QUANT_GUIDE" ]]
            then
                local active_num
                active_num=$(cat "$ACTIVE_LLM_FILE" 2>/dev/null)
                local archived=0
                local to_archive=()
                while IFS='|' read -r _qnum _qname _qfile _qsize _qarch _qqnt _rest
                do
                    [[ "$_qnum" == "#"* || -z "$_qfile" ]] && continue
                    [[ "$_qnum" == "$active_num" ]] && continue
                    local _qrating=""
                    while IFS='|' read -r _r _pat _d
                    do
                        [[ -z "$_pat" || "$_r" == "#"* ]] && continue
                        if [[ "${_qfile^^}" == *"${_pat^^}"* ]]
                        then
                            _qrating="$_r"; break
                        fi
                    done < "$QUANT_GUIDE"
                    if [[ "$_qrating" == "discouraged" ]]
                    then
                        to_archive+=("${_qnum}|${_qname}|${_qfile}|${_qqnt}")
                    fi
                done < "$LLM_REGISTRY"

                for _ae in "${to_archive[@]}"
                do
                    IFS='|' read -r _anum _aname _afile _aqunt <<< "$_ae"
                    local src="$LLAMA_MODEL_DIR/$_afile"
                    if [[ -f "$src" ]]
                    then
                        mkdir -p "$LLAMA_ARCHIVE_DIR"
                        if mv "$src" "$LLAMA_ARCHIVE_DIR/"
                        then
                            __tac_info "Archived" "#${_anum} ${_aname} (${_aqunt} - discouraged)" "$C_Warning"
                            ((archived++))
                        fi
                    fi
                done

                if (( archived > 0 ))
                then
                    __tac_info "Enforcement" "[$archived discouraged model(s) moved to archive]" "$C_Warning"
                    # Rebuild registry without archived files
                    local clean_tmp="${LLM_REGISTRY}.tmp"
                    local new_num=0
                    echo "#|name|file|size_gb|arch|quant|layers|gpu_layers|ctx|threads|tps" > "$clean_tmp"
                    while IFS= read -r _cline
                    do
                        [[ "$_cline" == "#"* || -z "$_cline" ]] && continue
                        local _cfile
                        _cfile=$(cut -d'|' -f3 <<< "$_cline")
                        [[ -f "$LLAMA_MODEL_DIR/$_cfile" ]] || continue
                        ((new_num++))
                        echo "${new_num}|$(cut -d'|' -f2- <<< "$_cline")" >> "$clean_tmp"
                    done < "$LLM_REGISTRY"
                    mv "$clean_tmp" "$LLM_REGISTRY"
                    __tac_info "Registry" "[Renumbered - ${new_num} models remain]" "$C_Success"
                fi
            fi

            model list
            ;;

        list)
            # Display the numbered model registry with an arrow marking the active model.
            if [[ ! -f "$LLM_REGISTRY" ]]
            then
                __tac_info "Registry" "[Not found - run 'model scan' first]" "$C_Warning"
                return 1
            fi

            # Read active and default model info
            local active_num=""
            [[ -f "$ACTIVE_LLM_FILE" ]] && active_num=$(cat "$ACTIVE_LLM_FILE" 2>/dev/null)
            local def_conf="${LLAMA_DRIVE_ROOT:-/mnt/m}/.llm/default_model.conf"
            local default_file=""
            [[ -f "$def_conf" ]] && default_file=$(cat "$def_conf" 2>/dev/null)

            printf "\n${C_Dim}  %-4s %-30s %-7s %-8s %-9s %-4s %-5s %-4s %s${C_Reset}\n" \
                "#" "MODEL" "SIZE" "QUANT" "ARCH" "GPU" "CTX" "THR" "TPS"
            local _list_rule; printf -v _list_rule '%*s' $((UIWidth - 4)) ''; _list_rule="${_list_rule// /${BOX_SL}}"
            printf "${C_Dim}  %s${C_Reset}\n" "$_list_rule"

            while IFS='|' read -r num name file size arch quant layers gpu_layers ctx threads tps
            do
                [[ "$num" == "#" || -z "$num" ]] && continue
                local marker="  "
                local color=""
                if [[ "$num" == "$active_num" ]] && pgrep -x llama-server >/dev/null 2>&1
                then
                    marker="> "
                    color="$C_Success"
                elif [[ "$file" == "$default_file" ]]
                then
                    marker="* "
                    color="$C_Highlight"
                fi
                printf "${color}${marker}%-4s %-30s %-7s %-8s %-9s %-4s %-5s %-4s %s${C_Reset}\n" \
                    "$num" "${name:0:30}" "$size" "$quant" "${arch:0:9}" "$gpu_layers" "$ctx" "$threads" "${tps:--}"
            done < "$LLM_REGISTRY"

            # Drive space summary (df-based, instant — no tree walk)
            # Uses df to get volume-level usage instead of du -sb which walks
            # the entire directory tree and blocks on drvfs/NTFS mounts.
            local d_used_bytes d_total_bytes d_avail_bytes d_pct_n
            d_used_bytes=$(df -B1 --output=used "$LLAMA_DRIVE_ROOT" 2>/dev/null | awk 'NR==2{print $1+0}')
            d_used_bytes=${d_used_bytes:-0}
            d_total_bytes=$LLAMA_DRIVE_SIZE
            d_avail_bytes=$(( d_total_bytes - d_used_bytes ))
            (( d_avail_bytes < 0 )) && d_avail_bytes=0
            d_pct_n=$(( d_total_bytes > 0 ? d_used_bytes * 100 / d_total_bytes : 0 ))
            local d_avail_h=$(( d_avail_bytes / 1024 / 1024 / 1024 ))
            local d_total_h=$(( d_total_bytes / 1024 / 1024 / 1024 ))
            local d_color="$C_Success"
            (( d_pct_n >= 90 )) && d_color="$C_Error"
            (( d_pct_n >= 75 && d_pct_n < 90 )) && d_color="$C_Warning"
            local d_label
            d_label=$(basename "$LLAMA_DRIVE_ROOT")
            printf "\n${C_Dim}  Drive ${d_label^^}: "
            printf "${d_color}${d_avail_h}G free${C_Reset}"
            printf "${C_Dim} of ${d_total_h}G (${d_pct_n}%% used)${C_Reset}\n"

            printf "\n${C_Dim}  model use N  |  model stop  "
            printf "|  model info N  |  model default N  "
            printf "|  model scan  |  model bench${C_Reset}\n"
            ;;

        default)
            local def_conf="${LLAMA_DRIVE_ROOT:-/mnt/m}/.llm/default_model.conf"
            # View or set the default LLM
            if [[ -z "$target" ]]
            then
                # Show current default
                if [[ -f "$def_conf" ]]
                then
                    local def_file
                    def_file=$(< "$def_conf")
                    local entry
                    entry=$(awk -F'|' -v f="$def_file" '$3 == f {print $0}' "$LLM_REGISTRY" 2>/dev/null)
                    if [[ -n "$entry" ]]
                    then
                        IFS='|' read -r num name _rest <<< "$entry"
                        __tac_info "Default Model" "#${num} ${name}" "$C_Success"
                    else
                        __tac_info "Default Model" "[$def_file (Not found in registry)]" "$C_Warning"
                    fi
                else
                    __tac_info "Default Model" "[NONE SET]" "$C_Dim"
                    printf '%s\n' "  ${C_Dim}Run 'model default <N>' to set one.${C_Reset}"
                fi
                return 0
            fi

            if [[ ! "$target" =~ ^[0-9]+$ ]]
            then
                __tac_info "Error" "[Not a number: '$target']" "$C_Error"; return 1
            fi

            local entry
            entry=$(awk -F'|' -v n="$target" '$1 == n' "$LLM_REGISTRY" 2>/dev/null)
            if [[ -z "$entry" ]]
            then
                __tac_info "Error" "[Model #$target not found in registry]" "$C_Error"; return 1
            fi

            IFS='|' read -r _n name file _rest <<< "$entry"
            mkdir -p "$(dirname "$def_conf")" 2>/dev/null
            echo "$file" > "$def_conf"
            __tac_info "Default Model" "[SET TO: $name]" "$C_Success"
            ;;

        use)
            # Load and start model #N with VRAM-optimised layer split and context size.
            # ── Validation ──────────────────────────────────────────────────
            if [[ -z "$target" ]]
            then
                # No model number given — fall through to default
                local _use_def_conf="${LLAMA_DRIVE_ROOT:-/mnt/m}/.llm/default_model.conf"
                local _use_def_file=""
                [[ -f "$_use_def_conf" ]] && _use_def_file=$(< "$_use_def_conf")
                if [[ -z "$_use_def_file" ]]
                then
                    __tac_info "Error" \
                        "[No model specified and no default set. Run 'model default <N>' to configure.]" \
                        "$C_Error"
                    return 1
                fi
                target=$(awk -F'|' -v f="$_use_def_file" '$3 == f {print $1; exit}' "$LLM_REGISTRY" 2>/dev/null)
                if [[ -z "$target" ]]
                then
                    __tac_info "Error" \
                        "[Default file not found in registry: $_use_def_file - run 'model scan']" \
                        "$C_Error"
                    return 1
                fi
                __tac_info "Default" "[Using default model #${target}]" "$C_Dim"
            fi
            if [[ ! "$target" =~ ^[0-9]+$ ]]
            then
                __tac_info "Error" "[Not a number: '$target']" "$C_Error"; return 1
            fi
            local entry
            entry=$(awk -F'|' -v n="$target" '$1 == n' "$LLM_REGISTRY" 2>/dev/null)
            if [[ -z "$entry" ]]
            then
                __tac_info "Error" "[Model #$target not in registry - run 'model scan']" "$C_Error"; return 1
            fi

            IFS='|' read -r num name file size arch quant layers gpu_layers ctx threads tps <<< "$entry"
            local model_path="$LLAMA_MODEL_DIR/$file"

            if [[ ! -f "$model_path" ]]
            then
                __tac_info "Error" "[File $file missing from $LLAMA_MODEL_DIR]" "$C_Error"; return 1
            fi
            if [[ ! -x "$LLAMA_SERVER_BIN" ]]
            then
                __tac_info "Error" "[Server binary not found: $LLAMA_SERVER_BIN]" "$C_Error"; return 1
            fi

            # ── Stop existing & raise limits ──────────────────────────────
            pkill -u "$USER" -x llama-server 2>/dev/null
            sleep 1

            # Raise memlock ulimit so --mlock can actually pin the model in RAM.
            # Without this, the default limit (~64KB) causes --mlock to silently fail.
            # Requires passwordless sudo for prlimit; harmless no-op if denied.
            sudo -n prlimit --memlock=unlimited:unlimited --pid $$ 2>/dev/null

            # ── Build server command ────────────────────────────────────
            # Choose batch sizes based on offload level:
            # Larger batches dramatically improve prompt eval speed (~30-50%) when
            # the GPU is doing the work. CPU-only uses moderate batches.
            local batch_size=512
            local ubatch_size=512
            if (( gpu_layers > 0 ))
            then
                # GPU active: larger batches fill the GPU pipeline more efficiently.
                # -b 4096 / -ub 1024 is safe with 64GB system RAM + 4GB VRAM.
                batch_size=4096
                ubatch_size=1024
            fi

            # Build command
            # Recovery: if model loading hangs (known llama.cpp mmap issue with
            # some GGUFs over drvfs), manually add --no-mmap to the command and
            # restart. This forces read() instead of mmap(), slower but reliable.
            local cmd=("$LLAMA_SERVER_BIN" "-m" "$model_path" "--port" "$LLM_PORT" "--host" "127.0.0.1")
            cmd+=("--ctx-size" "$ctx" "--mlock" "--prio" "2")
            cmd+=("--batch-size" "$batch_size")
            cmd+=("--ubatch-size" "$ubatch_size")
            cmd+=("--cont-batching" "--parallel" "1")
            # --jinja: enable Jinja2 chat template processing from GGUF metadata.
            # Newer models (Qwen3, Phi-4, Gemma3) embed their chat templates;
            # without this flag the server may apply a wrong or hardcoded format.
            cmd+=("--jinja")

            if (( gpu_layers == 0 ))
            then
                # CPU-only mode: model too large for VRAM. Use q8_0 KV cache
                # (saves RAM), skip GPU flags entirely.
                cmd+=("--cache-type-k" "q8_0" "--cache-type-v" "q8_0")
                cmd+=("--n-gpu-layers" "0" "--threads" "$threads")
                __tac_info "Note" "CPU-only mode (model exceeds 4GB VRAM)" "$C_Dim"
            else
                # -ngl 999: tell llama.cpp to offload the maximum layers that fit
                # in VRAM. The runtime calculates the actual count based on available
                # memory. This is more accurate than pre-calculating a fixed number,
                # especially since available VRAM varies at launch time.
                #
                # q8_0 KV cache: huge win for partially-offloaded models (frees VRAM
                # for layers). For architectures that benefit from it, always enable.
                if [[ "$arch" == "gemma"* ]] || [[ "$arch" == *"moe"* ]]
                then
                    cmd+=("--cache-type-k" "q8_0" "--cache-type-v" "q8_0")
                fi
                # --flash-attn on: reduces VRAM bandwidth pressure, critical for
                # small GPUs (4GB). Improves throughput without quality loss.
                cmd+=("--n-gpu-layers" "999" "--flash-attn" "on" "--threads" "$threads")
            fi

            # ── Per-architecture overrides ──────────────────────────────
            # Per-architecture sampling and launch overrides
            if [[ "$arch" == "gemma"* ]]
            then
                # Google recommends: temp 1.0, top_k 64, top_p 0.95, min_p 0
                cmd+=("--temp" "1.0" "--top-k" "64" "--top-p" "0.95" "--min-p" "0")
                __tac_info "Note" "Gemma sampling: temp=1.0 top_k=64 top_p=0.95" "$C_Dim"
            else
                cmd+=("--temp" "0.7")
            fi

            # Disable Qwen3's default chain-of-thought thinking — it burns tokens
            # on internal reasoning before producing a visible response, which
            # causes timeouts on constrained hardware. Use --reasoning-budget 0.
            # Note: Only Qwen3 has thinking mode. Qwen2 does not.
            if [[ "$arch" == "qwen3" || "$arch" == "qwen3moe" ]]
            then
                cmd+=("--reasoning-budget" "0")
                # --no-context-shift: prevent the context manager from shifting out
                # the thinking portion when the window fills, which corrupts the
                # response structure on thinking-capable models.
                cmd+=("--no-context-shift")
                __tac_info "Note" "Reasoning disabled + no-context-shift (Qwen3)" "$C_Dim"
            fi

            # MoE models: offload expert weights to CPU, keep attention on GPU
            # This lets the ~3B active params use GPU while 30B total sits in RAM
            if [[ "$arch" == *"moe"* ]]
            then
                cmd+=("--cpu-moe")
                __tac_info "Note" "MoE: expert layers on CPU (--cpu-moe)" "$C_Dim"
            fi

            # ── Launch & health wait ────────────────────────────────────
            local ngl_label
            if (( gpu_layers > 0 ))
            then
                ngl_label="ngl=999"
            else
                ngl_label="CPU-only"
            fi
            __tac_info "Starting" \
                "#${num} ${name} (${size}, ${ngl_label}, ctx ${ctx}, batch ${batch_size})" \
                "$C_Highlight"

            (nohup "${cmd[@]}" > "$LLM_LOG_FILE" 2>&1 &)

            # Save active model number
            if echo "$num" > "${ACTIVE_LLM_FILE}.tmp" 2>/dev/null \
                && mv "${ACTIVE_LLM_FILE}.tmp" "$ACTIVE_LLM_FILE"
            then
                : # success
            else
                __tac_info "Warning" "[Could not save state]" "$C_Warning"
            fi

            # Wait for ready — CPU-only models over drvfs (9p) can take much
            # longer to mmap and warm up, and some larger GPU models need more
            # startup time than small models.
            local health_timeout=45
            local _size_tenths=0
            if [[ "$size" =~ ^([0-9]+)(\.([0-9]))?G$ ]]
            then
                _size_tenths=$(( BASH_REMATCH[1] * 10 + ${BASH_REMATCH[3]:-0} ))
            fi
            if (( gpu_layers == 0 ))
            then
                health_timeout=180
            elif (( _size_tenths >= 20 ))
            then
                health_timeout=60
            fi
            local ready=0
            printf '%s' "${C_Dim}Waiting for health endpoint"
            for (( _hw=0; _hw < health_timeout; _hw++ ))
            do
                if __test_port "$LLM_PORT"
                then
                    local _hbody
                    _hbody=$(curl -s --max-time 3 "http://127.0.0.1:$LLM_PORT/health" 2>/dev/null)
                    # llama-server returns {"status":"ok"} when ready, but may
                    # return 200 with {"status":"loading model"} while warming up.
                    if [[ "$_hbody" == *'"ok"'* ]]
                    then
                        ready=1
                        break
                    fi
                fi
                printf '.'
                sleep 1
            done
            printf '%s\n' "$C_Reset"
            if (( ready ))
            then
                __tac_info "Status" "ONLINE [Port $LLM_PORT]" "$C_Success"
                # Report actual GPU layer offload from the server log.
                # llama.cpp prints "offloading N layers to GPU" during startup.
                local offload_info
                offload_info=$(grep -oiE 'offload(ing|ed) [0-9]+ .* layers' "$LLM_LOG_FILE" 2>/dev/null | tail -1)
                if [[ -n "$offload_info" ]]
                then
                    __tac_info "GPU Offload" "[$offload_info]" "$C_Dim"
                fi
            else
                __tac_info "Status" "FAILED OR TIMEOUT - check: tail $LLM_LOG_FILE" "$C_Error"
            fi
            ;;

        stop)
            # Kill the running llama-server process and clear the active model marker.
            pkill -u "$USER" -x llama-server 2>/dev/null
            rm -f "$ACTIVE_LLM_FILE"
            __tac_info "Llama Server" "[STOPPED]" "$C_Success"
            ;;

        status)
            # Show what model is running (or not) and its TPS if available.
            if pgrep -x llama-server >/dev/null 2>&1 && __test_port "$LLM_PORT"
            then
                local active_num
                active_num=$(cat "$ACTIVE_LLM_FILE" 2>/dev/null)
                if [[ -n "$active_num" && -f "$LLM_REGISTRY" ]]
                then
                    local entry
                    entry=$(awk -F'|' -v n="$active_num" '$1 == n' "$LLM_REGISTRY" 2>/dev/null)
                    IFS='|' read -r _n name file size _rest <<< "$entry"
                    __tac_info "Active" "#${active_num} ${name} (${size})" "$C_Success"
                else
                    __tac_info "Active" "[Running but unknown model]" "$C_Warning"
                fi
                local health health_label health_color
                health=$(curl -s --max-time 2 "http://127.0.0.1:$LLM_PORT/health" 2>/dev/null)
                if [[ "$health" == *'"ok"'* ]]; then
                    health_label="OK"; health_color="$C_Success"
                else
                    health_label="${health:-UNKNOWN}"; health_color="$C_Warning"
                fi
                __tac_info "Health" "$health_label" "$health_color"
                local tps
                tps=$(cat "$LLM_TPS_CACHE" 2>/dev/null)
                [[ -n "$tps" ]] && __tac_info "Last TPS" "$tps" "$C_Dim"
                __tac_info "Build" "$LLAMA_BUILD_VERSION" "$C_Dim"
            else
                __tac_info "Status" "[OFFLINE]" "$C_Dim"
            fi
            ;;

        info)
            # Print detailed metadata for model #N from the registry.
            if [[ -z "$target" ]]
            then
                __tac_info "Usage" "[model info <number>]" "$C_Error"; return 1
            fi
            if [[ ! "$target" =~ ^[0-9]+$ ]]
            then
                __tac_info "Error" "[Not a number: '$target']" "$C_Error"; return 1
            fi
            local entry
            entry=$(awk -F'|' -v n="$target" '$1 == n' "$LLM_REGISTRY" 2>/dev/null)
            if [[ -z "$entry" ]]
            then
                __tac_info "Error" "[Model #$target not found]" "$C_Error"; return 1
            fi
            IFS='|' read -r num name file size arch quant layers gpu_layers ctx threads tps <<< "$entry"
            __tac_info "#" "$num" "$C_Highlight"
            __tac_info "Model" "$name" "$C_Success"
            __tac_info "File" "$file" "$C_Dim"
            __tac_info "Size" "$size" "$C_Text"
            __tac_info "Architecture" "$arch" "$C_Text"
            __tac_info "Quantisation" "$quant" "$C_Text"
            __tac_info "Total Layers" "$layers" "$C_Text"
            __tac_info "GPU Layers" "$gpu_layers / $layers" "$C_Highlight"
            __tac_info "Context Size" "$ctx" "$C_Text"
            __tac_info "CPU Threads" "$threads" "$C_Text"
            if [[ -f "$LLAMA_MODEL_DIR/$file" ]]
            then
                __tac_info "On Disk" "[FOUND]" "$C_Success"
            else
                __tac_info "On Disk" "[MISSING]" "$C_Error"
            fi
            ;;

        bench)
            if [[ ! -f "$LLM_REGISTRY" ]]
            then
                __tac_info "Registry" "[Not found - run 'model scan']" "$C_Error"; return 1
            fi
            __tac_header "MODEL BENCHMARK" "open"

            # Save the currently active model to restore after benchmarking
            local _bench_prev_model=""
            [[ -f "$ACTIVE_LLM_FILE" ]] && _bench_prev_model=$(< "$ACTIVE_LLM_FILE")

            local -a b_num=() b_name=() b_size=() b_gpu=() b_tps=()
            while IFS='|' read -r num name file size _arch _quant _layers gpu_layers _ctx _threads _tps
            do
                [[ "$num" == "#" || -z "$num" ]] && continue
                [[ ! -f "$LLAMA_MODEL_DIR/$file" ]] && continue
                b_num+=("$num"); b_name+=("$name"); b_size+=("$size")
                b_gpu+=("${gpu_layers:-0}")
            done < "$LLM_REGISTRY"

            (( ${#b_num[@]} == 0 )) && { __tac_info "Bench" "[No on-disk models]" "$C_Warning"; return 1; }
            printf '%s\n\n' "${C_Dim}Benchmarking ${#b_num[@]} model(s)...${C_Reset}"

            local __BENCH_MODE=1
            for i in "${!b_num[@]}"
            do
                printf '%s\n' "${C_Highlight}[$(( i+1 ))/${#b_num[@]}] ${b_name[$i]} (${b_size[$i]})${C_Reset}"
                rm -f "$LLM_TPS_CACHE"  # Clear stale TPS before each model
                model use "${b_num[$i]}"
                # Fairness gate: wait for explicit {"status":"ok"} before burn.
                local bench_ready=0
                local bench_ready_timeout=60
                (( ${b_gpu[$i]:-0} == 0 )) && bench_ready_timeout=180
                for (( _br=0; _br < bench_ready_timeout; _br++ ))
                do
                    if __test_port "$LLM_PORT"
                    then
                        local _bhealth
                        _bhealth=$(curl -s --max-time 3 "http://127.0.0.1:$LLM_PORT/health" 2>/dev/null)
                        if [[ "$_bhealth" == *'"ok"'* ]]
                        then
                            bench_ready=1
                            break
                        fi
                    fi
                    sleep 1
                done
                if (( bench_ready ))
                then
                    burn
                else
                    __tac_info "Bench" "[Model did not reach healthy state in ${bench_ready_timeout}s]" "$C_Error"
                fi
                local tps="FAIL"; [[ -f "$LLM_TPS_CACHE" ]] && tps=$(< "$LLM_TPS_CACHE")
                b_tps+=("$tps")
                model stop 2>/dev/null
                sleep 1
            done
            unset __BENCH_MODE

            echo ""
            printf "${C_Dim}  %-4s %-30s %-7s %s${C_Reset}\n" "#" "MODEL" "SIZE" "TPS"
            local _bench_rule
            printf -v _bench_rule '%*s' $((UIWidth - 4)) ''
            _bench_rule="${_bench_rule// /${BOX_SL}}"
            printf "%s  %s${C_Reset}\n" "${C_Dim}" "$_bench_rule"
            for i in "${!b_num[@]}"
            do
                printf "  %-4s %-30s %-7s %s\n" "${b_num[$i]}" "${b_name[$i]}" "${b_size[$i]}" "${b_tps[$i]}"
            done

            local bench_file
            bench_file="$LLAMA_DRIVE_ROOT/.llm/bench_$(date +%Y%m%d_%H%M%S).tsv"
            { printf "#\tmodel\tsize\ttps\n"
              for i in "${!b_num[@]}"
              do
                  printf "%s\t%s\t%s\t%s\n" \
                      "${b_num[$i]}" "${b_name[$i]}" "${b_size[$i]}" "${b_tps[$i]}"
              done
            } > "$bench_file"
            __tac_info "Saved" "$bench_file" "$C_Dim"

            # Restore previously active model if one was running
            if [[ -n "$_bench_prev_model" ]]
            then
                __tac_info "Restoring" "Model #${_bench_prev_model}" "$C_Dim"
                model use "$_bench_prev_model" 2>/dev/null
            fi
            __tac_footer
            ;;

        delete)
            # Delete model #N from disk (with confirmation) and renumber the registry.
            if [[ -z "$target" ]]
            then
                __tac_info "Usage" "[model delete <number>]" "$C_Error"; return 1
            fi
            if [[ ! "$target" =~ ^[0-9]+$ ]]
            then
                __tac_info "Error" "[Not a number: '$target']" "$C_Error"; return 1
            fi
            local entry
            entry=$(awk -F'|' -v n="$target" '$1 == n' "$LLM_REGISTRY" 2>/dev/null)
            if [[ -z "$entry" ]]
            then
                __tac_info "Error" "[Model #$target not found]" "$C_Error"; return 1
            fi
            IFS='|' read -r _n name file _rest <<< "$entry"
            local fpath="$LLAMA_MODEL_DIR/$file"

            # Guard: prevent deleting the default model
            local _del_def_conf="${LLAMA_DRIVE_ROOT:-/mnt/m}/.llm/default_model.conf"
            local _del_def_file=""
            [[ -f "$_del_def_conf" ]] && _del_def_file=$(< "$_del_def_conf")
            if [[ -n "$_del_def_file" && "$file" == "$_del_def_file" ]]
            then
                __tac_info "Error" \
                    "[#${target} ${name} is the default LLM - change the default first ('model default <N>')]" \
                    "$C_Error"
                return 1
            fi

            __tac_info "Delete" "#${target} ${name}" "$C_Warning"
            __tac_info "File" "$fpath" "$C_Dim"
            if [[ -f "$fpath" ]]
            then
                local fsize_bytes
                fsize_bytes=$(stat --format=%s "$fpath" 2>/dev/null || echo 0)
                local fsize
                fsize=$(awk "BEGIN{printf \"%.1fG\", $fsize_bytes/1024/1024/1024}")
                __tac_info "Size" "$fsize" "$C_Dim"
            fi
            read -r -p "${C_Warning}Permanently delete this model? [y/N]: ${C_Reset}" confirm
            if [[ "${confirm,,}" != "y" ]]
            then
                __tac_info "Delete" "[CANCELLED]" "$C_Dim"; return 0
            fi

            # Stop if it's the active model
            local active_num
            active_num=$(cat "$ACTIVE_LLM_FILE" 2>/dev/null)
            if [[ "$target" == "$active_num" ]]
            then
                model stop
            fi

            # Delete file
            if [[ -f "$fpath" ]]
            then
                if rm -f "$fpath" 2>/dev/null
                then
                    __tac_info "File" "[DELETED]" "$C_Success"
                else
                    __tac_info "File" "[DELETE FAILED - permission denied]" "$C_Error"
                    return 1
                fi
            fi

            # Remove from registry and renumber
            local remaining
            remaining=$(__renumber_registry "$target")
            __tac_info "Registry" "[Removed and renumbered - ${remaining} models remain]" "$C_Success"
            ;;

        download)
            # Download one or more GGUF models from Hugging Face and auto-scan into registry.
            if (( ! __LLAMA_DRIVE_MOUNTED ))
            then
                __tac_info "Error" \
                    "[Model drive $LLAMA_DRIVE_ROOT is not mounted - run: sudo mount -t drvfs M: $LLAMA_DRIVE_ROOT]" \
                    "$C_Error"
                return 1
            fi
            if [[ $# -eq 0 ]]
            then
                printf '%s\n' "${C_Error}Error:${C_Reset} No models specified."
                echo ""
                echo "Usage: model download <repo:file> [repo:file ...]"
                echo ""
                echo "Each argument must be a Hugging Face repo and filename separated by a colon:"
                echo "  <owner/repo>:<filename.gguf>"
                echo ""
                echo "Downloads are saved to ${LLAMA_MODEL_DIR}."
                echo ""
                echo "Examples:"
                echo "  model download TheBloke/Ferret_7B-GGUF:ferret_7b.Q4_K_M.gguf"
                echo "  model download Qwen/Qwen3-8B-GGUF:Qwen3-8B-Q4_K_M.gguf \\"
                echo "      bartowski/microsoft_Phi-4-mini-instruct-GGUF:"
                echo "      microsoft_Phi-4-mini-instruct-Q4_K_M.gguf"
                return 1
            fi

            # ── Preflight checks ────────────────────────────────────────
            if ! command -v hf >/dev/null 2>&1
            then
                printf '%s\n' "${C_Error}Error:${C_Reset} 'hf' CLI not found." \
                    "Install with: pip install huggingface_hub[cli]"
                return 1
            fi

            # Warn if no token set (gated repos will fail)
            if [[ -z "${HF_TOKEN:-}" ]]
            then
                printf '%s\n' "${C_Warning}Note:${C_Reset} HF_TOKEN is not set. Gated or private repos will fail."
                printf '%s\n' "      Set it with: export HF_TOKEN=hf_..."
                echo ""
            fi

            # Safe WSL cache directory
            export HF_HOME="${HF_HOME:-$HOME/hf_cache}"
            mkdir -p "$HF_HOME" "$LLAMA_MODEL_DIR"

            # ── Download loop ───────────────────────────────────────────
            local ok=0 fail=0
            local spec
            for spec in "$@"
            do
                if [[ "$spec" != *":"* ]]
                then
                    printf '%s\n' \
                        "${C_Error}Error:${C_Reset} '$spec' is not in the right format."
                    printf '%s\n' \
                        "       Expected ${C_Warning}<owner/repo>:<filename.gguf>${C_Reset}" \
                        " e.g. TheBloke/Ferret_7B-GGUF:ferret_7b.Q4_K_M.gguf"
                    ((fail++))
                    continue
                fi

                local dl_repo dl_file
                IFS=":" read -r dl_repo dl_file <<< "$spec"

                if [[ -z "$dl_repo" || "$dl_repo" != *"/"* ]]
                then
                    printf '%s\n' \
                        "${C_Error}Error:${C_Reset} '$spec' - repo must be in" \
                        "${C_Warning}<owner>/<repo>${C_Reset} format (e.g. TheBloke/Ferret_7B-GGUF)"
                    ((fail++))
                    continue
                fi

                if [[ -z "$dl_file" ]]
                then
                    printf '%s\n' \
                        "${C_Error}Error:${C_Reset} '$spec' -" \
                        "missing filename after colon (e.g. :ferret_7b.Q4_K_M.gguf)"
                    ((fail++))
                    continue
                fi

                local dest="$LLAMA_MODEL_DIR/$dl_file"
                local archive_dest="$LLAMA_ARCHIVE_DIR/$dl_file"

                # Check quantization against the guide config (warn, don't block)
                if [[ -f "$QUANT_GUIDE" ]]
                then
                    local _qrating=""
                    local _qdesc=""
                    while IFS='|' read -r _r _pat _d
                    do
                        [[ -z "$_pat" || "$_r" == "#"* ]] && continue
                        if [[ "${dl_file^^}" == *"${_pat^^}"* ]]
                        then
                            _qrating="$_r"; _qdesc="$_d"; break
                        fi
                    done < "$QUANT_GUIDE"
                    if [[ "$_qrating" == "discouraged" ]]
                    then
                        printf '%s\n' "${C_Warning}Warning:${C_Reset} ${_pat} is discouraged for 4GB VRAM - ${_qdesc}"
                        read -r -p "${C_Warning}Download anyway? [y/N]: ${C_Reset}" _qconfirm
                        if [[ "${_qconfirm,,}" != "y" ]]
                        then
                            __tac_info "Skip" "$dl_file (discouraged quant)" "$C_Dim"
                            ((fail++))
                            continue
                        fi
                    elif [[ "$_qrating" == "recommended" ]]
                    then
                        printf '%s\n' "${C_Success}${CHECK_MARK}${C_Reset} ${_pat} - ${_qdesc}"
                    elif [[ "$_qrating" == "acceptable" ]]
                    then
                        printf '%s\n' "${C_Dim}${BULLET} ${_pat} - ${_qdesc}${C_Reset}"
                    fi
                fi

                if [[ -f "$dest" ]]
                then
                    __tac_info "Skip" "$dl_file already exists (active)" "$C_Warning"
                    ((ok++))
                    continue
                fi
                if [[ -f "$archive_dest" ]]
                then
                    __tac_info "Skip" "$dl_file already exists (archived)" "$C_Warning"
                    ((ok++))
                    continue
                fi

                # Check available space before downloading.
                # Re-read drive usage at download time (may have changed since startup).
                # Use df instead of du -sb — du walks the entire directory tree which
                # is extremely slow on drvfs (Windows 9p) mounts with large GGUF files.
                local d_used_bytes
                d_used_bytes=$(df -B1 --output=used "$LLAMA_DRIVE_ROOT" 2>/dev/null | awk 'NR==2{print $1+0}')
                d_used_bytes=${d_used_bytes:-0}
                local d_total_now
                d_total_now=$(df -B1 --output=size "$LLAMA_DRIVE_ROOT" 2>/dev/null | awk 'NR==2{print $1+0}')
                d_total_now=${d_total_now:-$LLAMA_DRIVE_SIZE}
                local d_avail_bytes=$(( d_total_now - d_used_bytes ))
                (( d_avail_bytes < 0 )) && d_avail_bytes=0

                if [[ "$d_avail_bytes" =~ ^[0-9]+$ ]]
                then
                    # Query HF API for file size
                    local remote_size
                    local _hf_url="https://huggingface.co"
                    _hf_url+="/${dl_repo}/resolve/main/${dl_file}"
                    remote_size=$(curl -sfI --max-time 10 \
                        "$_hf_url" 2>/dev/null \
                        | awk 'BEGIN{IGNORECASE=1} /^content-length:/ {sub(/\r$/,"",$2); print $2; exit}')
                    if [[ "$remote_size" =~ ^[0-9]+$ ]] && (( remote_size > 0 ))
                    then
                        if (( remote_size > d_avail_bytes ))
                        then
                            local need_gb=$(( remote_size / 1024 / 1024 / 1024 ))
                            local have_gb=$(( d_avail_bytes / 1024 / 1024 / 1024 ))
                            printf '%s\n' \
                                "${C_Error}Error:${C_Reset} Not enough space" \
                                "for $dl_file (need ~${need_gb}G, only ${have_gb}G free on M:)"
                            ((fail++))
                            continue
                        fi
                    fi
                fi

                __tac_info "Downloading" "$dl_repo ${ARROW_R} $dl_file" "$C_Highlight"
                if hf download "$dl_repo" "$dl_file" --local-dir "$LLAMA_MODEL_DIR"
                then
                    __tac_info "OK" "$dl_file" "$C_Success"
                    ((ok++))
                else
                    __tac_info "FAIL" "$dl_repo $dl_file" "$C_Error"
                    ((fail++))
                fi
            done

            echo ""
            __tac_info "Done" "$ok succeeded, $fail failed. Models in $LLAMA_MODEL_DIR" "$C_Dim"
            (( fail > 0 )) && return 1
            # Auto-scan new models into the registry
            model scan
            ;;

        archive)
            # Move model #N to the archive directory and renumber the registry.
            if [[ -z "$target" ]]
            then
                __tac_info "Usage" "[model archive <number>]" "$C_Error"; return 1
            fi
            if [[ ! "$target" =~ ^[0-9]+$ ]]
            then
                __tac_info "Error" "[Not a number: '$target']" "$C_Error"; return 1
            fi
            local entry
            entry=$(awk -F'|' -v n="$target" '$1 == n' "$LLM_REGISTRY" 2>/dev/null)
            if [[ -z "$entry" ]]
            then
                __tac_info "Error" "[Model #$target not found]" "$C_Error"; return 1
            fi
            IFS='|' read -r _n name file _rest <<< "$entry"
            local fpath="$LLAMA_MODEL_DIR/$file"
            local archive_dir="$LLAMA_ARCHIVE_DIR"

            # Guard: prevent archiving the default model
            local _arc_def_conf="${LLAMA_DRIVE_ROOT:-/mnt/m}/.llm/default_model.conf"
            local _arc_def_file=""
            [[ -f "$_arc_def_conf" ]] && _arc_def_file=$(< "$_arc_def_conf")
            if [[ -n "$_arc_def_file" && "$file" == "$_arc_def_file" ]]
            then
                __tac_info "Error" \
                    "[#${target} ${name} is the default LLM - change the default first ('model default <N>')]" \
                    "$C_Error"
                return 1
            fi

            __tac_info "Archive" "#${target} ${name}" "$C_Warning"
            __tac_info "From" "$fpath" "$C_Dim"
            __tac_info "To" "$archive_dir/$file" "$C_Dim"
            read -r -p "${C_Warning}Archive this model? [y/N]: ${C_Reset}" confirm
            if [[ "${confirm,,}" != "y" ]]
            then
                __tac_info "Archive" "[CANCELLED]" "$C_Dim"; return 0
            fi

            # Stop if active
            local active_num
            active_num=$(cat "$ACTIVE_LLM_FILE" 2>/dev/null)
            if [[ "$target" == "$active_num" ]]
            then
                model stop
            fi

            # Move file
            mkdir -p "$archive_dir"
            if [[ -f "$fpath" ]]
            then
                if mv "$fpath" "$archive_dir/" 2>/dev/null
                then
                    __tac_info "File" "[MOVED]" "$C_Success"
                else
                    __tac_info "File" "[MOVE FAILED - try: sudo chmod 755 $archive_dir]" "$C_Error"
                    return 1
                fi
            else
                __tac_info "File" "[NOT ON DISK - removing from registry only]" "$C_Warning"
            fi

            # Remove from registry and renumber
            local remaining
            remaining=$(__renumber_registry "$target")
            __tac_info "Registry" "[Archived and renumbered - ${remaining} models remain]" "$C_Success"
            ;;

        *)
            echo "Usage: model {scan|list|default|use|stop|status|info|bench|delete|archive|download}"
            echo "  scan       - Scan $LLAMA_MODEL_DIR, read GGUF metadata, auto-calculate params"
            echo "  list       - Show numbered model registry (${PLAY_MARK} = active, * = default)"
            echo "  default [N] - Show current default LLM, or set it to model #N"
            echo "  use N      - Start model #N with optimal settings"
            echo "  stop       - Stop llama-server"
            echo "  status     - Show what's running"
            echo "  info N     - Detailed info for model #N"
            echo "  bench      - Benchmark all on-disk models"
            echo "  delete N   - Permanently delete model #N from disk and registry"
            echo "  archive N  - Move model #N to archive/ and remove from registry"
            echo "  download   - Download GGUF models from Hugging Face (repo:file)"
            ;;
    esac
}

# serve/halt/mlogs — convenience wrappers for the model manager.
# shellcheck disable=SC2034,SC2059,SC2120,SC2154
function serve() {
    local def_conf="${LLAMA_DRIVE_ROOT:-/mnt/m}/.llm/default_model.conf"
    if [[ -n "${1:-}" ]]
    then
        model use "$1"
    else
        # Start the default LLM
        if [[ -f "$def_conf" ]]
        then
            local def_file
            def_file=$(< "$def_conf")
            local def_num
            def_num=$(awk -F'|' -v f="$def_file" '$3 == f {print $1; exit}' "$LLM_REGISTRY" 2>/dev/null)
            if [[ -n "$def_num" ]]
            then
                model use "$def_num"
            else
                __tac_info "Local LLM" "[Default file not found in registry: $def_file]" "$C_Error"
                return 1
            fi
        else
            __tac_info "Local LLM" "[NO DEFAULT SET]" "$C_Error"
            printf '%s\n' "  ${C_Dim}Run 'model default <N>' to configure one.${C_Reset}"
            return 1
        fi
    fi
}
# halt — Stop the currently running LLM model.
function halt() {
    model stop
}

# mlogs — Open the llama-server log file in VS Code.
function mlogs() {
    __resolve_vscode_bin
    "$VSCODE_BIN" "$LLM_LOG_FILE"
    echo "VS Code opened..."
}

# ---------------------------------------------------------------------------
# burn — Stress test the local LLM with a ~1300 token physics prompt.
# Uses non-streaming request with accurate server-reported completion_tokens.
# Pure bash + curl + jq with nanosecond timing.
# ---------------------------------------------------------------------------
function burn() {
    __require_llm || return 1
    if [[ -z "${__BENCH_MODE:-}" ]]
    then
        [[ -t 1 ]] && command clear
        __tac_header "HARDWARE BURN-IN STRESS TEST"
    fi

    # Wait for the model to finish loading before sending the completion request.
    # The port may be open (passes __require_llm) but the server returns 503
    # "Loading model" while mmap-ing large files over drvfs (up to 90s for CPU).
    local _health
    _health=$(curl -sf --max-time 3 "http://127.0.0.1:$LLM_PORT/health" 2>/dev/null)
    if [[ "$_health" != *'"ok"'* ]]
    then
        printf '%s' "${C_Dim}Waiting for model to finish loading"
        for (( _bw=0; _bw < 90; _bw++ ))
        do
            _health=$(curl -sf --max-time 3 "http://127.0.0.1:$LLM_PORT/health" 2>/dev/null)
            [[ "$_health" == *'"ok"'* ]] && break
            printf '.'
            sleep 1
        done
        printf '%s\n' "$C_Reset"
        if [[ "$_health" != *'"ok"'* ]]
        then
            __tac_info "Status" "Model failed to become healthy - check: tail $LLM_LOG_FILE" "$C_Error"
            return 1
        fi
    fi

    printf '%s\n' "${C_Dim}Testing: ~1500 token synthetic physics response...${C_Reset}"
    printf '%s\n' "${C_Highlight}Processing ....${C_Reset}"

    local prompt="Explain the complete theory of special relativity"
    prompt+=" in extreme detail, including the mathematical"
    prompt+=" derivations for time dilation."

    # Non-streaming request — curl + jq, with bash nanosecond timing.
    local payload
    payload=$(jq -n --arg p "$prompt" '{messages: [{role: "user", content: $p}], max_tokens: 1500, temperature: 0.7}')

    local request_timeout=240
    if [[ -f "$ACTIVE_LLM_FILE" && -f "$LLM_REGISTRY" ]]
    then
        local _burn_num _burn_entry _burn_gpu _burn_size
        _burn_num=$(< "$ACTIVE_LLM_FILE")
        _burn_entry=$(awk -F'|' -v n="$_burn_num" '$1 == n {print; exit}' "$LLM_REGISTRY" 2>/dev/null)
        if [[ -n "$_burn_entry" ]]
        then
            IFS='|' read -r _n _name _file _burn_size _arch _quant _layers _burn_gpu _ctx _threads _tps <<< "$_burn_entry"
            if (( ${_burn_gpu:-0} == 0 ))
            then
                request_timeout=900
            else
                local _burn_size_tenths=0
                if [[ "$_burn_size" =~ ^([0-9]+)(\.([0-9]))?G$ ]]
                then
                    _burn_size_tenths=$(( BASH_REMATCH[1] * 10 + ${BASH_REMATCH[3]:-0} ))
                fi
                (( _burn_size_tenths >= 30 )) && request_timeout=360
            fi
        fi
    fi

    local start_ns end_ns response curl_rc
    start_ns=$(date +%s%N)
    response=$(curl -sS --max-time "$request_timeout" "$LOCAL_LLM_URL" \
        -H "Content-Type: application/json" \
        -d "$payload" 2>/dev/null)
    curl_rc=$?
    end_ns=$(date +%s%N)

    if (( curl_rc == 28 ))
    then
        printf '%s\n' "${C_Warning}[API Timeout]${C_Reset} No response within ${request_timeout}s (model likely still computing, not necessarily crashed)."
        return 1
    fi
    if (( curl_rc != 0 ))
    then
        printf '%s\n' "${C_Error}[API Transport Error]${C_Reset} curl exit ${curl_rc} while calling local server."
        return 1
    fi

    if [[ -z "$response" ]]
    then
        printf '%s\n' "${C_Error}[API Error]${C_Reset} Empty response from local server."
        return 1
    fi

    # Check for HTTP-level error in response body
    local err_msg
    err_msg=$(printf '%s' "$response" | jq -r '.error.message // empty' 2>/dev/null)
    if [[ -n "$err_msg" ]]
    then
        printf '%s\n' "${C_Warning}[API Status]${C_Reset} $err_msg"
        return 1
    fi

    local elapsed_ms=$(( (end_ns - start_ns) / 1000000 ))
    local elapsed_s=$(( elapsed_ms / 1000 ))
    local elapsed_dec=$(( (elapsed_ms % 1000) / 100 ))

    # Prefer server-reported completion_tokens; fall back to word count
    local tokens
    tokens=$(printf '%s' "$response" | jq -r '.usage.completion_tokens // 0' 2>/dev/null)
    if (( tokens == 0 ))
    then
        tokens=$(printf '%s' "$response" | jq -r '.choices[0].message.content // ""' 2>/dev/null | wc -w)
    fi

    local tps_int=0 tps_dec=0
    if (( elapsed_ms > 0 && tokens > 0 ))
    then
        local tps_x10=$(( tokens * 10000 / elapsed_ms ))
        tps_int=$(( tps_x10 / 10 ))
        tps_dec=$(( tps_x10 % 10 ))
    fi

    if [[ -z "${__BENCH_MODE:-}" ]]
    then
        printf '%s\n' "${C_Dim}Hint: If inference was slow, first run \"wake\" to lock WDDM state.${C_Reset}"
    fi
    printf '%s\n' \
        "${C_Success}Burn complete: ${tps_int}.${tps_dec} tps" \
        "(${tokens} tokens in ${elapsed_s}.${elapsed_dec}s)${C_Reset}"
    echo "${tps_int}.${tps_dec} tps" > "${LLM_TPS_CACHE}.tmp" && mv "${LLM_TPS_CACHE}.tmp" "$LLM_TPS_CACHE"
    __save_tps "${tps_int}.${tps_dec}"

    [[ -f "$LLM_TPS_CACHE" ]] && LAST_TPS=$(< "$LLM_TPS_CACHE")
}

# ---------------------------------------------------------------------------
# explain — Ask the local LLM to explain the last command run in the terminal.
# Uses `fc -ln -2 -2` instead of history parsing for reliability with HISTCONTROL.
# ---------------------------------------------------------------------------
function explain() {
    local last_cmd
    last_cmd=$(fc -ln -2 -2 2>/dev/null | sed 's/^\s*//')
    if [[ -z "$last_cmd" ]]
    then
        __tac_line "Explain" "[NO PREVIOUS COMMAND FOUND]" "$C_Warning"
        return 1
    fi
    __llm_stream "Explain this bash command and diagnose any potential errors:\n$last_cmd"
}

# ---------------------------------------------------------------------------
# wtf_repl — Ask the local LLM to explain a tool or concept (toggle mode).
# Type a topic, get an explanation, then type another. 'end-chat' or Ctrl-C to exit.
# Aliased as 'wtf:' in section 3.
# ---------------------------------------------------------------------------
function wtf_repl() {
    local initial="$*"
    __require_llm || return 1

    # Trap Ctrl-C so it breaks the loop cleanly (exit 0, no error badge)
    trap 'echo; trap - INT; return 0' INT

    # If called with args, handle the first query then enter the loop
    if [[ -n "$initial" ]]
    then
        __llm_stream "Explain how to use the following tool or concept:\n$initial"
    fi
    printf '%s\n' "${C_Dim}wtf: mode - type a topic (or 'end-chat' / Ctrl-C to exit)${C_Reset}"
    while true
    do
        local topic
        read -r -e -p "${C_Highlight}wtf: ${C_Reset}" topic || break
        [[ -z "$topic" ]] && continue
        [[ "$topic" == "end-chat" ]] && break
        __llm_stream "Explain how to use the following tool or concept:\n$topic"
    done

    trap - INT
}

# ---------------------------------------------------------------------------
# __llm_sse_core — Shared SSE streaming engine for all LLM functions.
# Called by __llm_stream (one-shot prompts) and __llm_chat_send (multi-turn).
# Pure bash + curl + jq. Posts payload to llama.cpp OpenAI-compatible API,
# streams SSE delta chunks, computes TPS, caches metrics.
# Sets __LAST_LLM_RESPONSE with the full response text.
# Usage: __llm_sse_core "$json_payload"
# ---------------------------------------------------------------------------
function __llm_sse_core() {
    local payload="$1"
    __LAST_LLM_RESPONSE=""

    local start_ns
    start_ns=$(date +%s%N)
    local chunk_count=0
    local server_tokens=0
    local response_text=""

    while IFS= read -r line
    do
        [[ "$line" != data:* ]] && continue
        local payload_data="${line#data: }"
        [[ "$payload_data" == "[DONE]" ]] && break

        local content
        content=$(printf '%s' "$payload_data" | jq -r '.choices[0].delta.content // empty' 2>/dev/null)
        if [[ -n "$content" ]]
        then
            printf '%s' "$content"
            response_text+="$content"
            ((chunk_count++))
        fi

        local srv_tok
        srv_tok=$(printf '%s' "$payload_data" | jq -r '.usage.completion_tokens // empty' 2>/dev/null)
        [[ -n "$srv_tok" && "$srv_tok" != "null" ]] && server_tokens=$srv_tok
    done < <(curl -s --no-buffer --max-time 300 -X POST "$LOCAL_LLM_URL" \
        -H "Content-Type: application/json" \
        -d "$payload" 2>/dev/null | tr -d '\r')

    local end_ns
    end_ns=$(date +%s%N)
    local elapsed_ms=$(( (end_ns - start_ns) / 1000000 ))
    local tokens=$server_tokens
    if (( tokens == 0 ))
    then
        tokens=$chunk_count
    fi

    if (( tokens > 0 && elapsed_ms > 0 ))
    then
        local tps_x10=$(( tokens * 10000 / elapsed_ms ))
        local tps_int=$(( tps_x10 / 10 ))
        local tps_dec=$(( tps_x10 % 10 ))
        local elapsed_s=$(( elapsed_ms / 1000 ))
        printf '\n%s(%s.%s tps)%s\n' "$C_Dim" "$tps_int" "$tps_dec" "$C_Reset"
        echo "${tps_int}.${tps_dec} tps" > "${LLM_TPS_CACHE}.tmp" && mv "${LLM_TPS_CACHE}.tmp" "$LLM_TPS_CACHE"
        __save_tps "${tps_int}.${tps_dec}"
    else
        echo
    fi

    [[ -f "$LLM_TPS_CACHE" ]] && LAST_TPS=$(< "$LLM_TPS_CACHE")
    __LAST_LLM_RESPONSE="$response_text"
}

# ---------------------------------------------------------------------------
# __llm_stream — SSE streaming helper for explain / wtf / chat.
# Usage: __llm_stream "prompt text" [show_header: 1|0] [messages_json]
#   If messages_json is provided (a valid JSON array), it is sent directly
#   instead of wrapping prompt in a single user message. This enables
#   multi-turn conversation history for local_chat.
# MODULARISATION NOTE: writes LLM_TPS_CACHE, read by tactical_dashboard.
# ---------------------------------------------------------------------------
function __llm_stream() {
    local prompt="$1"
    local show_header="${2:-1}"
    local messages_json="${3:-}"
    __require_llm || return 1

    local payload
    if [[ -n "$messages_json" ]]
    then
        payload=$(jq -n --argjson msgs "$messages_json" '{messages: $msgs, stream: true}')
    else
        payload=$(jq -n --arg p "$prompt" '{messages: [{role: "user", content: $p}], stream: true}')
    fi

    (( show_header == 1 )) && printf '\n%s\n\n' "${C_Highlight}AI Analysis:${C_Reset}"

    __llm_sse_core "$payload"
}

# ---------------------------------------------------------------------------
# __llm_chat_send — Send a message with conversation history to the local LLM.
# Usage: __llm_chat_send "user message" "messages_json_array"
#   Returns: the assistant's response text is captured via __LAST_LLM_RESPONSE.
# ---------------------------------------------------------------------------
function __llm_chat_send() {
    local user_msg="$1"
    local messages_json="$2"
    __require_llm || return 1

    local payload
    payload=$(jq -n --argjson msgs "$messages_json" '{messages: $msgs, stream: true}')

    __llm_sse_core "$payload"
}

# ---------------------------------------------------------------------------
# local_chat — Interactive chat REPL with multi-turn conversation history.
# Accumulates user and assistant messages so the LLM has context of the full
# conversation. First argument (if any) becomes the opening message.
# Type 'end-chat' or press Ctrl-C to return to the shell.
# Aliased as 'chatl' in section 3.
# ---------------------------------------------------------------------------
function local_chat() {
    __require_llm || return 1

    # Trap Ctrl-C: clean up nested function, restore trap, exit cleanly
    trap 'echo; unset -f __send_chat_msg 2>/dev/null; trap - INT; return 0' INT

    # Conversation history as a JSON array string
    local history='[]'

    # __send_chat_msg is a nested (dynamic-scoped) function that captures
    # the 'history' local variable from local_chat's scope. This works because
    # bash uses dynamic scoping — nested functions inherit the caller's locals.
    # It will break if extracted to file scope without passing history by reference.
    function __send_chat_msg() {
        local user_msg="$1"
        # Append user message to history
        history=$(printf '%s' "$history" \
            | jq --arg m "$user_msg" '. + [{role: "user", content: $m}]')
        echo
        __llm_chat_send "$user_msg" "$history"
        # Append assistant response to history
        if [[ -n "$__LAST_LLM_RESPONSE" ]]
        then
            history=$(printf '%s' "$history" \
                | jq --arg m "$__LAST_LLM_RESPONSE" \
                '. + [{role: "assistant", content: $m}]')
        fi
    }

    local initial="$*"
    # If called with an initial prompt, send it first
    if [[ -n "$initial" ]]
    then
        __send_chat_msg "$initial"
    fi
    printf '%s\n' "${C_Dim}chat: mode - type a message (or 'end-chat' / 'save' / Ctrl-C to exit)${C_Reset}"
    while true
    do
        local msg
        echo
        read -r -e -p "${C_Highlight}chat: ${C_Reset}" msg || break
        [[ -z "$msg" ]] && continue
        [[ "$msg" == "end-chat" ]] && break
        if [[ "$msg" == "save" ]]
        then
            local save_file
            save_file="$HOME/chat_$(date +%Y%m%d_%H%M%S).json"
            printf '%s' "$history" | jq '.' > "$save_file" 2>/dev/null \
                && printf '%s\n' "${C_Success}Saved to $save_file${C_Reset}" \
                || printf '%s\n' "${C_Error}Failed to save${C_Reset}"
            continue
        fi
        __send_chat_msg "$msg"
    done

    unset -f __send_chat_msg
    trap - INT
}

# ---------------------------------------------------------------------------
# chat-context — Feed a file as context then ask the local LLM about it.
# Usage: chat-context <file> "question about this file"
# The file content is prepended as context to the user's question.
# ---------------------------------------------------------------------------
function chat-context() {
    if [[ -z "$1" ]]
    then
        printf '%s\n' "${C_Dim}Usage:${C_Reset} chat-context <file> \"question about this file\""
        return 1
    fi
    local file="$1"; shift
    local question="$*"
    if [[ ! -f "$file" ]]
    then
        __tac_info "File" "[NOT FOUND: $file]" "$C_Error"
        return 1
    fi
    __require_llm || return 1
    # Cap file content to stay within context window (configurable via env)
    local max_chars="${CHAT_CONTEXT_MAX:-16000}"
    local content
    content=$(head -c "$max_chars" "$file")
    local prompt="Here is the content of '$file':\n\n\`\`\`\n${content}\n\`\`\`\n\n${question:-Explain this file.}"
    __llm_stream "$prompt"
}

# ---------------------------------------------------------------------------
# chat-pipe — Pipe stdin as context and ask the local LLM about it.
# Usage: cat error.log | chat-pipe "What's wrong here?"
# ---------------------------------------------------------------------------
function chat-pipe() {
    __require_llm || return 1
    local ctx
    ctx=$(cat)
    if [[ -z "$ctx" ]]
    then
        __tac_info "stdin" "[EMPTY - pipe some content]" "$C_Error"
        return 1
    fi
    local question="${*:-Explain this.}"
    __llm_stream "${ctx}\n\n${question}"
}
# end of file






# end of file
