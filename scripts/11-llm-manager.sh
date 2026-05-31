# shellcheck shell=bash
# shellcheck disable=SC2034,SC2059,SC2120,SC2154
# ─── Module: 11-llm-manager ───────────────────────────────────────────────────────
# AI INSTRUCTION: On ANY change to this file, increment the Module Version below.
# TACTICAL_PROFILE_VERSION auto-computes from the sum of all module versions.
# Module Version: 41
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

# Fallback for __LLAMA_DRIVE_MOUNTED if module load order changes or §1 is skipped.
# Default to "not mounted" so callers fail safe instead of silently assuming success.
: "${__LLAMA_DRIVE_MOUNTED:=0}"

# Ensure LLM_DEFAULT_FILE is defined even if Section 1 wasn't updated
export LLM_DEFAULT_FILE="${LLM_DEFAULT_FILE:-$LLAMA_DRIVE_ROOT/.llm/default_model.conf}"

# ---- Named constants for model size thresholds (in tenths of GB) ----
readonly _MODEL_SIZE_LARGE=30       # 3.0GB+ — large model, longer startup
readonly _MODEL_SIZE_MEDIUM=20      # 2.0GB+ — medium model, moderate startup
readonly _MODEL_SIZE_SMALL=15       # 1.5GB+ — small model, fast startup
readonly _GPU_OFFLOAD_DISABLED=0    # gpu_layers = 0 means CPU-only mode

# ---- Special-case model names (for custom settings/behavior) ----
readonly _MODEL_QWEN35_4B="Qwen3.5-4B"
readonly _MODEL_QWEN25_CODER_3B="Qwen2.5 Coder 3B Instruct"
readonly _MODEL_GEMMA3_4B="Gemma 3 4b It"
readonly _MODEL_PHI4_MINI="Phi-4-mini"

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
    __llm_registry_sync_state >/dev/null 2>&1 || true
    local active_num
    active_num=$(< "$ACTIVE_LLM_FILE")
    [[ -z "$active_num" ]] && return
    awk -F'|' -v n="$active_num" -v t="$tps_val" 'BEGIN{OFS="|"} $1 == n {$16 = t} {print}' \
        "$LLM_REGISTRY" > "${LLM_REGISTRY}.tmp" \
        && mv "${LLM_REGISTRY}.tmp" "$LLM_REGISTRY"
}

# ---------------------------------------------------------------------------
# __save_model_ctx — Persist autotune winner ctx to registry.
# Enforces a minimum context floor (24000) so autotune doesn't save
# suspiciously small values. Caps are not applied on the high end —
# autotune's binary search already finds the VRAM-stable maximum.
# ---------------------------------------------------------------------------
function __save_model_ctx() {
    local model_num="$1"
    local ctx_val="$2"
    [[ "$model_num" =~ ^[0-9]+$ && "$ctx_val" =~ ^[0-9]+$ && -f "$LLM_REGISTRY" ]] || return
    __llm_registry_sync_state >/dev/null 2>&1 || true

    # Enforce a minimum context floor of 24000. Autotune may pick a very
    # small ctx on OOM for the best-performing config, but that's rarely
    # what the user wants. The binary search already finds the max stable
    # ctx — trust its discovered_ctx, not the combo-sweep runner-up.
    local min_ctx="${LLM_AUTOTUNE_MIN_CTX:-24000}"
    [[ "$min_ctx" =~ ^[0-9]+$ ]] || min_ctx=24000
    local saved="$ctx_val"
    (( saved < min_ctx )) && saved=$min_ctx

    awk -F'|' -v n="$model_num" -v c="$saved" 'BEGIN{OFS="|"} $1 == n {$8 = c} {print}' \
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
# __llm_json_escape — Escape a string for safe inline JSON output.
# @returns 0 always.
# ---------------------------------------------------------------------------
function __llm_json_escape() {
    local raw="${1:-}"
    raw="${raw//\\/\\\\}"
    raw="${raw//\"/\\\"}"
    raw="${raw//$'\n'/\\n}"
    raw="${raw//$'\r'/\\r}"
    raw="${raw//$'\t'/\\t}"
    printf '%s' "$raw"
}

# ---------------------------------------------------------------------------
# __llm_registry_entry_by_num — Resolve a registry entry by model number.
# Validates that target is numeric before querying.
# @returns 0 on success, 1 if the registry or requested entry is unavailable.
# ---------------------------------------------------------------------------
function __llm_registry_entry_by_num() {
    local target="${1:-}"
    # Validate target is numeric
    [[ ! "$target" =~ ^[0-9]+$ ]] && return 1
    [[ -n "$target" && -f "$LLM_REGISTRY" ]] || return 1
    awk -F'|' -v n="$target" '$1 == n {print; exit}' "$LLM_REGISTRY" 2>/dev/null
}

# ---------------------------------------------------------------------------
# __llm_registry_entry_by_file — Resolve a registry entry by GGUF filename.
# @returns 0 on success, 1 if the registry or requested entry is unavailable.
# ---------------------------------------------------------------------------
function __llm_registry_entry_by_file() {
    local target_file="${1:-}"
    [[ -n "$target_file" && -f "$LLM_REGISTRY" ]] || return 1
    awk -F'|' -v f="$target_file" '$3 == f {print; exit}' "$LLM_REGISTRY" 2>/dev/null
}

# ---------------------------------------------------------------------------
# __llm_default_file — Read the configured default GGUF filename.
# @returns 0 on success, 1 if no default model is configured.
# ---------------------------------------------------------------------------
function __llm_default_file() {
    [[ -f "$LLM_DEFAULT_FILE" ]] || return 1
    local default_file
    default_file=$(< "$LLM_DEFAULT_FILE")
    [[ -n "$default_file" ]] || return 1
    printf '%s\n' "$default_file"
}

# ---------------------------------------------------------------------------
# __llm_default_entry — Resolve the configured default model to a registry row.
# @returns 0 on success, 1 if no default is configured or it is missing from the registry.
# ---------------------------------------------------------------------------
function __llm_default_entry() {
    local default_file
    default_file=$(__llm_default_file) || return 1
    __llm_registry_entry_by_file "$default_file"
}

# ---------------------------------------------------------------------------
# __llm_default_number — Resolve the configured default model number.
# @returns 0 on success, 1 if no default is configured or it is missing from the registry.
# ---------------------------------------------------------------------------
function __llm_default_number() {
    local entry
    entry=$(__llm_default_entry) || return 1
    printf '%s\n' "${entry%%|*}"
}

# ---------------------------------------------------------------------------
# __llm_registry_sync_state — Persist default and active flags into registry.
# Keeps models.conf as canonical state for default selection and in-VRAM model.
# @returns 0 on success or when registry is unavailable.
# ---------------------------------------------------------------------------
function __llm_registry_sync_state() {
    [[ -f "$LLM_REGISTRY" ]] || return 0

    local default_file=""
    local active_num=""
    local active_file=""
    local running=0

    default_file=$(__llm_default_file 2>/dev/null || true)
    if __llm_server_running && __test_port "$LLM_PORT"
    then
        running=1
    fi

    if [[ -f "$ACTIVE_LLM_FILE" ]]
    then
        active_num=$(< "$ACTIVE_LLM_FILE")
        active_file=$(awk -F'|' -v n="$active_num" '$1==n {print $3; exit}' "$LLM_REGISTRY" 2>/dev/null || true)
    fi

    awk -F'|' -v def="$default_file" -v af="$active_file" -v run="$running" 'BEGIN{OFS="|"}
        $1 == "#" {
            print "#|name|file|size_gb|quant_cache|arch|gpu_layers|ctx|threads|batch|ubatch|parallel|fit_target_mb|backend|mmap_mode|tps|autotuned|is_default|in_vram"
            next
        }
        NF < 16 {
            next
        }
        {
            # Legacy 16-col: no file state fields and no mmap_mode.
            if (NF == 16) {
                $19="no"; $18="no"; $17=$16; $16=$15; $15="auto"
            }
            # Legacy 18-col: has state flags but no mmap_mode.
            if (NF == 18) {
                $19=$18; $18=$17; $17=$16; $16=$15; $15="auto"
            }
            d = ($3 == def ? "yes" : "no")
            a = (run == 1 && af != "" && $3 == af ? "yes" : "no")
            $18=d; $19=a
            if ($15 == "") $15="auto"
            print $1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17,$18,$19
        }
    ' "$LLM_REGISTRY" > "${LLM_REGISTRY}.tmp" || return 1

    mv "${LLM_REGISTRY}.tmp" "$LLM_REGISTRY" || return 1
    return 0
}

# ---------------------------------------------------------------------------
# __llm_autotune_profiles_file — Return registry path for autotune persistence.
# Autotune winners are persisted directly into flat tuning columns in models.conf.
# @returns 0 always.
# ---------------------------------------------------------------------------
function __llm_autotune_profiles_file() {
    printf '%s\n' "$LLM_REGISTRY"
}

# ---------------------------------------------------------------------------
# __llm_autotune_sanitize_token — Remove registry delimiters from profile values.
# @returns 0 always.
# ---------------------------------------------------------------------------
function __llm_autotune_sanitize_token() {
    local token="${1:-}"
    token="${token//|/_}"
    token="${token//;/_}"
    token="${token//,/_}"
    printf '%s\n' "$token"
}

# ---------------------------------------------------------------------------
# __llm_autotune_blob_upsert — Upsert backend winner into encoded blob.
# Blob format (per entry, comma-separated; entries separated by ';'):
# backend,ctx,batch,ubatch,parallel,fit,tps,stamp,score,stddev,samples,
# failures,ctx_min,ctx_max,verified,objective
# Keeps at most one profile entry per backend (latest winner wins).
# @returns 0 always.
# ---------------------------------------------------------------------------
function __llm_autotune_blob_upsert() {
    local blob="${1:-}"
    local backend="${2:-}"
    local ctx_size="${3:-}"
    local batch="${4:-}"
    local ubatch="${5:-}"
    local parallel="${6:-}"
    local fit_target_mb="${7:-}"
    local tps="${8:-}"
    local stamp="${9:-}"
    local score="${10:-0}"
    local stddev="${11:-0}"
    local samples="${12:-0}"
    local failures="${13:-0}"
    local ctx_min="${14:-$ctx_size}"
    local ctx_max="${15:-$ctx_size}"
    local verified="${16:-0}"
    local objective="${17:-no-oom>max-ctx>max-tps}"

    objective=$(__llm_autotune_sanitize_token "$objective")

    local out=""
    local rec
    local -a entries=()
    IFS=';' read -r -a entries <<< "$blob"
    for rec in "${entries[@]}"
    do
        [[ -z "$rec" ]] && continue
        local rb rc _rest
        IFS=',' read -r rb rc _rest <<< "$rec"
        if [[ "$rb" == "$backend" ]]
        then
            continue
        fi
        if [[ -n "$out" ]]
        then
            out+=";"
        fi
        out+="$rec"
    done

    local new_entry="${backend},${ctx_size},${batch},${ubatch},${parallel},${fit_target_mb},${tps},${stamp},${score},${stddev},${samples},${failures},${ctx_min},${ctx_max},${verified},${objective}"
    if [[ -n "$out" ]]
    then
        out+=";"
    fi
    out+="$new_entry"
    printf '%s\n' "$out"
}

# ---------------------------------------------------------------------------
# __llm_autotune_profile_get — Legacy helper retained for compatibility.
# Flat schema uses direct columns rather than encoded profile blobs.
# Returned format:
#   model_num\tbackend\tctx\tbatch\tubatch\tparallel\tfit_target_mb\ttps\tstamp...
# @returns 0 on success, 1 when no profile exists.
# ---------------------------------------------------------------------------
function __llm_autotune_profile_get() {
    local model_num="${1:-}"
    local backend="${2:-}"
    local ctx_size="${3:-}"
    local entry=""
    entry=$(__llm_registry_entry_by_num "$model_num") || return 1

    local _num _name _file _size _arch _quant _layers _gpu _ctx _threads _tps blob _done
    IFS='|' read -r _num _name _file _size _arch _quant _layers _gpu _ctx _threads _tps blob _done <<< "$entry"
    [[ -n "$backend" && -n "$blob" ]] || return 1

    local exact=""
    local fallback=""
    local rec
    local -a entries=()
    IFS=';' read -r -a entries <<< "$blob"
    for rec in "${entries[@]}"
    do
        [[ -z "$rec" ]] && continue
        local rb rc rbatch rubatch rparallel rfit rtps rstamp rscore rstddev rsamples rfail rctxmin rctxmax rverified robj
        IFS=',' read -r rb rc rbatch rubatch rparallel rfit rtps rstamp rscore rstddev rsamples rfail rctxmin rctxmax rverified robj <<< "$rec"
        [[ "$rb" == "$backend" ]] || continue

        [[ -z "$rc" ]] && rc="*"
        [[ -z "$rscore" ]] && rscore="$rtps"
        [[ -z "$rstddev" ]] && rstddev="0"
        [[ -z "$rsamples" ]] && rsamples="0"
        [[ -z "$rfail" ]] && rfail="0"
        [[ -z "$rctxmin" ]] && rctxmin="$rc"
        [[ -z "$rctxmax" ]] && rctxmax="$rc"
        [[ -z "$rverified" ]] && rverified="0"
        [[ -z "$robj" ]] && robj="no-oom>max-ctx>max-tps"

        local row
        row=$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' \
            "$model_num" "$rb" "$rc" "$rbatch" "$rubatch" "$rparallel" "$rfit" "$rtps" "$rstamp" \
            "$rscore" "$rstddev" "$rsamples" "$rfail" "$rctxmin" "$rctxmax" "$rverified" "$robj")

        if [[ -n "$ctx_size" && "$rc" == "$ctx_size" ]]
        then
            exact="$row"
        elif [[ ("$rc" == "*" || -z "$rc") && -z "$fallback" ]]
        then
            fallback="$row"
        fi
    done

    if [[ -n "$exact" ]]
    then
        printf '%s\n' "$exact"
        return 0
    fi
    if [[ -n "$fallback" ]]
    then
        printf '%s\n' "$fallback"
        return 0
    fi

    # Latest backend winner fallback (ctx-agnostic).
    local rec_any
    for rec_any in "${entries[@]}"
    do
        [[ -z "$rec_any" ]] && continue
        local rb rc rbatch rubatch rparallel rfit rtps rstamp rscore rstddev rsamples rfail rctxmin rctxmax rverified robj
        IFS=',' read -r rb rc rbatch rubatch rparallel rfit rtps rstamp rscore rstddev rsamples rfail rctxmin rctxmax rverified robj <<< "$rec_any"
        [[ "$rb" == "$backend" ]] || continue

        [[ -z "$rscore" ]] && rscore="$rtps"
        [[ -z "$rstddev" ]] && rstddev="0"
        [[ -z "$rsamples" ]] && rsamples="0"
        [[ -z "$rfail" ]] && rfail="0"
        [[ -z "$rctxmin" ]] && rctxmin="$rc"
        [[ -z "$rctxmax" ]] && rctxmax="$rc"
        [[ -z "$rverified" ]] && rverified="0"
        [[ -z "$robj" ]] && robj="no-oom>max-ctx>max-tps"

        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$model_num" "$rb" "${rc:-*}" "$rbatch" "$rubatch" "$rparallel" "$rfit" "$rtps" "$rstamp" \
            "$rscore" "$rstddev" "$rsamples" "$rfail" "$rctxmin" "$rctxmax" "$rverified" "$robj"
        return 0
    done

    return 1
}

# ---------------------------------------------------------------------------
# __llm_backend_normalize — Normalize backend labels to native/python.
# @returns 0 and prints normalized backend label.
# ---------------------------------------------------------------------------
function __llm_backend_normalize() {
    local backend_raw="${1:-native}"
    case "$backend_raw" in
        native|binary|llama-server) printf '%s\n' "native" ;;
        python|llama-cpp-python|module|"") printf '%s\n' "python" ;;
        *) printf '%s\n' "$backend_raw" ;;
    esac
}

# ---------------------------------------------------------------------------
# __llm_autotune_profile_best_for_model — Pick best saved profile for model.
# Selection priority: backend match, then max ctx, then max score/tps.
# @returns 0 on success, 1 when no matching profile exists.
# ---------------------------------------------------------------------------
function __llm_autotune_profile_best_for_model() {
    local model_num="${1:-}"
    local backend="${2:-}"
    [[ "$model_num" =~ ^[0-9]+$ ]] || return 1

    local entry=""
    entry=$(__llm_registry_entry_by_num "$model_num") || return 1
    local _num _name _file _size _arch _quant _layers _gpu _ctx _threads _tps blob _done
    IFS='|' read -r _num _name _file _size _arch _quant _layers _gpu _ctx _threads _tps blob _done <<< "$entry"
    [[ -n "$blob" ]] || return 1

    local seen=0
    local best=""
    local best_ctx=0
    local best_score=0
    local rec
    local -a entries=()
    IFS=';' read -r -a entries <<< "$blob"
    for rec in "${entries[@]}"
    do
        [[ -z "$rec" ]] && continue
        local rb rc rbatch rubatch rparallel rfit rtps rstamp rscore rstddev rsamples rfail rctxmin rctxmax rverified robj
        IFS=',' read -r rb rc rbatch rubatch rparallel rfit rtps rstamp rscore rstddev rsamples rfail rctxmin rctxmax rverified robj <<< "$rec"
        [[ -n "$backend" && "$rb" != "$backend" ]] && continue

        local cval=0
        local sval=0
        [[ "$rc" =~ ^[0-9]+$ ]] && cval="$rc"
        if [[ "$rscore" =~ ^[0-9]+(\.[0-9]+)?$ ]]
        then
            sval="$rscore"
        elif [[ "$rtps" =~ ^[0-9]+(\.[0-9]+)?$ ]]
        then
            sval="$rtps"
        fi
        [[ -z "$rscore" ]] && rscore="$rtps"
        [[ -z "$rstddev" ]] && rstddev="0"
        [[ -z "$rsamples" ]] && rsamples="0"
        [[ -z "$rfail" ]] && rfail="0"
        [[ -z "$rctxmin" ]] && rctxmin="$rc"
        [[ -z "$rctxmax" ]] && rctxmax="$rc"
        [[ -z "$rverified" ]] && rverified="0"
        [[ -z "$robj" ]] && robj="no-oom>max-ctx>max-tps"

        if (( seen == 0 )) \
            || (( cval > best_ctx )) \
            || { (( cval == best_ctx )) && awk -v s="$sval" -v b="$best_score" 'BEGIN{exit !(s>b)}'; }
        then
            best=$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' \
                "$model_num" "$rb" "${rc:-*}" "$rbatch" "$rubatch" "$rparallel" "$rfit" "$rtps" "$rstamp" \
                "$rscore" "$rstddev" "$rsamples" "$rfail" "$rctxmin" "$rctxmax" "$rverified" "$robj")
            best_ctx="$cval"
            best_score="$sval"
            seen=1
        fi
    done

    [[ "$seen" == "1" ]] || return 1
    printf '%s\n' "$best"
}

# ---------------------------------------------------------------------------
# __llm_autotune_done_for_model — Check flat autotune flag column.
# models.conf schema (v37): column 17 stores yes/no.
# @returns 0 when autotuned=yes, 1 otherwise.
# ---------------------------------------------------------------------------
function __llm_autotune_done_for_model() {
    local model_num="${1:-}"
    [[ "$model_num" =~ ^[0-9]+$ ]] || return 1

    awk -F'|' -v n="$model_num" '$1==n {exit !($17=="yes")}' "$LLM_REGISTRY" 2>/dev/null
}

# ---------------------------------------------------------------------------
# __llm_autotune_profile_save — Persist latest winning autotune as defaults.
# New signature:
#   __llm_autotune_profile_save <model> <backend> <ctx> <batch> <ubatch> <parallel> <fit> <tps> [stamp]
# @returns 0 on success, 1 on validation/write failure.
# ---------------------------------------------------------------------------
function __llm_autotune_profile_save() {
    local model_num="${1:-}"
    local backend="${2:-llama_server}"
    local ctx_size="${3:-}"
    local batch="${4:-}"
    local ubatch="${5:-}"
    local parallel="${6:-}"
    local fit_target_mb="${7:-}"
    local tps="${8:-}"
    local profile_file="$LLM_REGISTRY"

    [[ "$model_num" =~ ^[0-9]+$ ]] || return 1
    [[ "$ctx_size" =~ ^[0-9]+$ ]] || return 1
    [[ "$batch" =~ ^[0-9]+$ ]] || return 1
    [[ "$ubatch" =~ ^[0-9]+$ ]] || return 1
    [[ "$parallel" =~ ^[0-9]+$ ]] || return 1
    [[ "$fit_target_mb" =~ ^[0-9]+$ ]] || return 1
    [[ "$tps" =~ ^[0-9]+(\.[0-9]+)?$ ]] || tps="0"

    [[ -f "$profile_file" ]] || return 1

    local updated=0
    : > "${profile_file}.tmp" || return 1
    local line
    while IFS= read -r line
    do
        if [[ "$line" == "#|"* ]]
        then
            printf '%s\n' "#|name|file|size_gb|quant_cache|arch|gpu_layers|ctx|threads|batch|ubatch|parallel|fit_target_mb|backend|mmap_mode|tps|autotuned|is_default|in_vram" >> "${profile_file}.tmp" || return 1
            continue
        fi

        if [[ -z "$line" ]]
        then
            continue
        fi

        local rnum rname rfile rsize rquant_cache rarch rgpu rctx rthreads rbatch rubatch rparallel rfit rbackend rmmap rtps rautotuned ris_default rin_vram
        IFS='|' read -r rnum rname rfile rsize rquant_cache rarch rgpu rctx rthreads rbatch rubatch rparallel rfit rbackend rmmap rtps rautotuned ris_default rin_vram <<< "$line"

        if [[ "$rnum" == "$model_num" ]]
        then
            rctx="$ctx_size"
            rbatch="$batch"
            rubatch="$ubatch"
            rparallel="$parallel"
            rfit="$fit_target_mb"
            rbackend="$backend"
            [[ -n "$rmmap" ]] || rmmap="auto"
            rtps="$tps"
            rautotuned="yes"
            updated=1
        fi

        printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
            "$rnum" "$rname" "$rfile" "$rsize" "$rquant_cache" "$rarch" "$rgpu" "$rctx" "$rthreads" "$rbatch" "$rubatch" "$rparallel" "$rfit" "$rbackend" "${rmmap:-auto}" "$rtps" "${rautotuned:-no}" "${ris_default:-no}" "${rin_vram:-no}" >> "${profile_file}.tmp" || return 1
    done < "$profile_file"

    [[ "$updated" == "1" ]] || {
        rm -f "${profile_file}.tmp"
        return 1
    }

    mv "${profile_file}.tmp" "$profile_file" || return 1
}

# ---------------------------------------------------------------------------
# __llm_autotune_profiles_remap_by_registry — Carry tuning columns by filename.
# @returns 0 when remap succeeds or is not needed, 1 on write failure.
# ---------------------------------------------------------------------------
function __llm_autotune_profiles_remap_by_registry() {
    local old_registry="${1:-}"
    local new_registry="${2:-}"
    [[ -f "$old_registry" && -f "$new_registry" ]] || return 0

    awk -F'|' 'BEGIN{OFS="|"}
        FNR == NR {
            if ($1 != "#" && NF >= 16) {
                key=$3
                old_ctx[key]=$8; old_thr[key]=$9; old_batch[key]=$10; old_ub[key]=$11
                old_par[key]=$12; old_fit[key]=$13; old_be[key]=$14
                if (NF >= 19) {
                    old_mm[key]=$15; old_tps[key]=$16; old_done[key]=$17
                } else {
                    old_mm[key]="auto"; old_tps[key]=$15; old_done[key]=$16
                }
            }
            next
        }
        {
            if ($1 == "#") {
                print "#|name|file|size_gb|quant_cache|arch|gpu_layers|ctx|threads|batch|ubatch|parallel|fit_target_mb|backend|mmap_mode|tps|autotuned|is_default|in_vram"
                next
            }

            if (NF < 16) {
                next
            }
            if (NF == 16) {
                $19="no"; $18="no"; $17=$16; $16=$15; $15="auto"
            }
            if (NF == 18) {
                $19=$18; $18=$17; $17=$16; $16=$15; $15="auto"
            }
            key=$3
            if (key in old_ctx) {
                $8=old_ctx[key]; $9=old_thr[key]; $10=old_batch[key]; $11=old_ub[key]
                $12=old_par[key]; $13=old_fit[key]; $14=old_be[key]; $15=old_mm[key]; $16=old_tps[key]; $17=old_done[key]
            }
            print $1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17,$18,$19
        }
    ' "$old_registry" "$new_registry" > "${new_registry}.tmp" || return 1

    mv "${new_registry}.tmp" "$new_registry" || return 1
    return 0
}

# ---------------------------------------------------------------------------
# __llm_stddev_from_list — Print population standard deviation from numeric stdin.
# @returns 0 when a deviation is emitted, 1 when input has no numeric rows.
# ---------------------------------------------------------------------------
function __llm_stddev_from_list() {
    awk '/^[0-9]+(\.[0-9]+)?$/ { x[NR]=$1; sum+=$1 }
        END {
            if (NR == 0) {
                exit 1
            }
            mean = sum / NR
            for (i=1; i<=NR; i++) {
                d = x[i] - mean
                sq += d * d
            }
            printf "%.4f\n", sqrt(sq / NR)
        }'
}

# ---------------------------------------------------------------------------
# __llm_median_from_list — Print median value from numeric stdin lines.
# Even count returns arithmetic mean of the two middle values.
# @returns 0 when a median is emitted, 1 when input has no numeric rows.
# ---------------------------------------------------------------------------
function __llm_median_from_list() {
    awk '/^[0-9]+(\.[0-9]+)?$/ { print $0 }' \
        | sort -n \
        | awk '
            { a[NR] = $1 }
            END {
                if (NR == 0) {
                    exit 1
                }
                if (NR % 2 == 1) {
                    print a[(NR + 1) / 2]
                } else {
                    printf "%.2f\n", (a[NR / 2] + a[(NR / 2) + 1]) / 2
                }
            }
        '
}

# ---------------------------------------------------------------------------
# __llm_active_entry — Resolve the currently active model to a registry row.
# @returns 0 on success, 1 if no active model state is recorded or it is stale.
# ---------------------------------------------------------------------------
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
        if [[ "$_kp" =~ ^[0-9]+$ ]]; then kill -TERM "$_kp" 2>/dev/null; fi
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

    __tac_header "GPU PERFORMANCE PREP" "open"

    # 1. AC / battery check via /sys/class/power_supply
    local _on_ac=1 _bat_path
    for _bat_path in /sys/class/power_supply/BAT0 /sys/class/power_supply/BAT1 \
                     /sys/class/power_supply/battery
    do
        [[ -f "$_bat_path/status" ]] || continue
        local _bat_status
        _bat_status=$(< "$_bat_path/status")
        [[ "$_bat_status" == "Discharging" ]] && _on_ac=0
        break
    done

    if (( _on_ac == 0 ))
    then
        __tac_info "Power" "[ON BATTERY — plug in AC for sustained bench performance]" "$C_Warning"
    else
        __tac_info "Power" "AC connected" "$C_Success"
    fi

    if [[ -z "$smi_cmd" ]]
    then
        __tac_info "GPU" "[nvidia-smi unavailable — clock data skipped]" "$C_Warning"
        __tac_footer
        return 0
    fi

    # 2. Clock + pstate + thermal snapshot
    local _gstat
    _gstat=$(
        "$smi_cmd" --query-gpu=pstate,clocks.gr,clocks.sm,clocks.mem,temperature.gpu,power.draw \
            --format=csv,noheader,nounits 2>/dev/null | head -1
    )
    if [[ -n "$_gstat" ]]
    then
        local _pstate _gr _sm _mem _temp _pwr
        IFS=',' read -r _pstate _gr _sm _mem _temp _pwr <<< "$_gstat"
        _pstate=$(printf '%s' "$_pstate" | xargs)
        _gr=$(printf '%s' "$_gr" | xargs)
        _sm=$(printf '%s' "$_sm" | xargs)
        _mem=$(printf '%s' "$_mem" | xargs)
        _temp=$(printf '%s' "$_temp" | xargs)
        _pwr=$(printf '%s' "$_pwr" | xargs)

        # P0–P3 = active performance, P4+ = idle/power-save
        local _pstate_num="${_pstate#P}"
        local _pstate_note=""
        local _pstate_color="$C_Success"
        if [[ "$_pstate_num" =~ ^[0-9]+$ ]] && (( _pstate_num >= 4 ))
        then
            _pstate_color="$C_Warning"
            _pstate_note=" — idle/power-save (clocks boost once load begins)"
        fi

        __tac_info "pstate" "${_pstate_color}${_pstate}${C_Reset}${_pstate_note}" "$C_Text"
        __tac_info "Clocks" "${_gr} MHz gr / ${_sm} MHz sm / ${_mem} MHz mem" "$C_Text"
        __tac_info "Temp" "${_temp}${DEGREE}C" "$C_Text"
        __tac_info "Power" "${_pwr} W" "$C_Text"

        if [[ "$_temp" =~ ^[0-9]+$ ]] && (( _temp >= 80 ))
        then
            __tac_info "THERMAL" "[${_temp}${DEGREE}C — throttling likely; cool down before bench]" "$C_Error"
        fi
    fi

    # 3. Active SW throttle check (live state only).
    # Read from "Clocks Throttle Reasons" to avoid mixing in cumulative
    # "Clocks Event Reasons" counters (e.g., 0 us / historical us values).
    local _throttle_active
    _throttle_active=$(
        "$smi_cmd" -q -d PERFORMANCE 2>/dev/null \
            | awk '
                /Clocks Throttle Reasons/ { in_reasons=1; next }
                /Clocks Event Reasons/    { in_reasons=0 }
                in_reasons && /SW Thermal Slowdown|SW Power Cap Slowdown/ {
                    if ($0 !~ /Not Active/) {
                        gsub(/^[[:space:]]+/, "")
                        print
                        count++
                        if (count >= 4) exit
                    }
                }
            '
    )
    if [[ -n "$_throttle_active" ]]
    then
        local _thr_msg
        _thr_msg=$(printf '%s' "$_throttle_active" | tr '\n' ';' | sed 's/;$//')
        __tac_info "Throttle" "[ACTIVE: ${_thr_msg} — reduce heat/load for best bench results]" "$C_Warning"
    else
        __tac_info "Throttle" "None detected" "$C_Success"
    fi

    # 4. Actionable tips line
    printf '%s\n' "${C_Dim}  Tips: Windows power mode → Best Performance · NVIDIA Control Panel → Prefer Max Performance · use AC power${C_Reset}"
    __tac_footer

    # Brief settle — lets persistence mode take effect and driver clock state update
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
# Format: #|name|file|size_gb|quant_cache|arch|gpu_layers|ctx|threads|batch|ubatch|parallel|fit_target_mb|backend|mmap_mode|tps|autotuned|is_default|in_vram
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
    else
        if (( _native_ctx > 0 ))
        then
            echo "$_native_ctx"
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
    done < <(find "$LLAMA_DRIVE_ROOT/.llm" -maxdepth 1 -name 'bench_*.tsv' -type f \
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
    find "$LLAMA_DRIVE_ROOT/.llm" -maxdepth 1 -name 'bench_*.tsv' -type f \
        -printf '%T@ %p\n' 2>/dev/null | sort -n -r | head -1 | cut -d' ' -f2-
}

# __calc_threads — CPU threads based on how much spills to CPU.
# Uses nproc to detect available threads, then scales:
#   CPU-only  → 80% (all layers on CPU, maximise parallelism)
#   Partial   → 70% (CPU handles remaining layers + KV-cache)
#   Full GPU  → 50% (CPU only does prompt processing + sampling)
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
    local old_registry_snapshot
    old_registry_snapshot=$(mktemp "${LLM_REGISTRY}.old.XXXXXX") || return 1
    cp "$LLM_REGISTRY" "$old_registry_snapshot" 2>/dev/null || {
        rm -f "$old_registry_snapshot"
        return 1
    }

    awk -F'|' -v n="$target" '$1 != n && $1 != "#"' "$LLM_REGISTRY" > "${LLM_REGISTRY}.tmp"
    local newnum=0
    {
        echo "#|name|file|size_gb|quant_cache|arch|gpu_layers|ctx|threads|batch|ubatch|parallel|fit_target_mb|backend|mmap_mode|tps|autotuned|is_default|in_vram"
        while IFS='|' read -r _num rest
        do
            ((newnum++))
            echo "${newnum}|${rest}"
        done < "${LLM_REGISTRY}.tmp"
    } > "$LLM_REGISTRY"
    rm -f "${LLM_REGISTRY}.tmp"
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
# ---------------------------------------------------------------------------
function __model_scan() {
    if (( ! __LLAMA_DRIVE_MOUNTED ))
    then
        __tac_info "Error" \
            "[Model drive $LLAMA_DRIVE_ROOT is not mounted - run: sudo mount -t drvfs M: $LLAMA_DRIVE_ROOT]" \
            "$C_Error"
        return 1
    fi

    __tac_info "Scanning" "$LLAMA_MODEL_DIR" "$C_Highlight"
    local tmpconf="${LLM_REGISTRY}.tmp"
    local old_registry_snapshot=""
    if [[ -f "$LLM_REGISTRY" ]]
    then
        old_registry_snapshot=$(mktemp "${LLM_REGISTRY}.oldscan.XXXXXX") || return 1
        cp "$LLM_REGISTRY" "$old_registry_snapshot" 2>/dev/null || {
            rm -f "$old_registry_snapshot"
            return 1
        }
    fi
    echo "#|name|file|size_gb|quant_cache|arch|gpu_layers|ctx|threads|batch|ubatch|parallel|fit_target_mb|backend|mmap_mode|tps|autotuned|is_default|in_vram" > "$tmpconf"

    local num=0
    local gguf
    for gguf in "$LLAMA_MODEL_DIR"/*.gguf
    do
        [[ ! -f "$gguf" ]] && continue
        local fname
        fname=$(basename "$gguf")
        local fbytes
        fbytes=$(stat --format=%s "$gguf" 2>/dev/null || stat -f%z "$gguf" 2>/dev/null)
        (( fbytes < 500000000 )) && continue

        __tac_info "Reading" "${fname%.gguf}" "$C_Dim"
        local meta
        meta=$(__gguf_metadata "$gguf")
        local _mname march mblocks mctx mftype
        IFS='|' read -r _mname march mblocks mctx mftype <<< "$meta"

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
        local prev_batch="${LLAMA_BATCH_SIZE:-1024}"
        local prev_ubatch="${LLAMA_UBATCH_SIZE:-256}"
        local prev_parallel="${LLAMA_PARALLEL_SLOTS:-1}"
        local prev_fit="${LLAMA_FIT_TARGET_MB:-256}"
        local prev_backend="llama_server"
        local prev_mmap="auto"
        local prev_tps="0"
        local prev_autotuned="no"
        local prev_default="no"
        local prev_active="no"
        if [[ -f "$LLM_REGISTRY" ]]
        then
            local prev_row
            prev_row=$(awk -F'|' -v f="$fname" '$3 == f {print; exit}' "$LLM_REGISTRY" 2>/dev/null || true)
            if [[ -n "$prev_row" ]]
            then
                IFS='|' read -r _pn _pname _pfile _psize _pqc _parch _pgpu _pctx _pthr prev_batch prev_ubatch prev_parallel prev_fit prev_backend prev_mmap prev_tps prev_autotuned prev_default prev_active <<< "$prev_row"
            fi
        fi

        local quant_cache="${quant}/${LLAMA_CACHE_TYPE_K:-q8_0}"

        local _reg_line="${num}|${_mname:-$fname}|${fname}|${size_gb}G|${quant_cache}|${march}|${gpu_layers}|${ctx}|${threads}"
        _reg_line+="|${prev_batch}|${prev_ubatch}|${prev_parallel}|${prev_fit}|${prev_backend}|${prev_mmap}|${prev_tps}|${prev_autotuned}|${prev_default}|${prev_active}"
        echo "$_reg_line" >> "$tmpconf"

        local __tac_msg="${_mname:-Model} (${size_gb}G, ${quant_cache}, ${mblocks}L ${ARROW_R} ${gpu_layers} GPU)"
        __tac_info "  #${num}" "$__tac_msg" "$C_Success"
    done

    if (( num == 0 ))
    then
        __tac_info "Result" "[No models found in $LLAMA_MODEL_DIR]" "$C_Warning"
        rm -f "$tmpconf"
        return 1
    fi

    mv "$tmpconf" "$LLM_REGISTRY"
    if [[ -n "$old_registry_snapshot" ]]
    then
        __llm_autotune_profiles_remap_by_registry "$old_registry_snapshot" "$LLM_REGISTRY" >/dev/null 2>&1 || true
        rm -f "$old_registry_snapshot"
    fi
    __tac_info "Registry" "[${num} models written to $LLM_REGISTRY]" "$C_Success"
    __llm_registry_sync_state >/dev/null 2>&1 || true

    if [[ -f "$QUANT_GUIDE" ]]
    then
        local active_num
        active_num=$(cat "$ACTIVE_LLM_FILE" 2>/dev/null)
        local archived=0
        local to_archive=()
        local _qnum _qname _qfile _qsize _qqcache _qarch _qgpu _qctx _qthr _qb _qub _qp _qfit _qbe _qmm _qtps _qautotuned _qdefault _qactive
        while IFS='|' read -r _qnum _qname _qfile _qsize _qqcache _qarch _qgpu _qctx _qthr _qb _qub _qp _qfit _qbe _qmm _qtps _qautotuned _qdefault _qactive
        do
            [[ "$_qnum" == "#"* || -z "$_qname" ]] && continue
            [[ "$_qnum" == "$active_num" ]] && continue
            local _qrating=""
            local _r _pat _d
            while IFS='|' read -r _r _pat _d
            do
                [[ -z "$_pat" || "$_r" == "#"* ]] && continue
                if [[ "${_qfile^^}" == *"${_pat^^}"* ]]
                then
                    _qrating="$_r"
                    break
                fi
            done < "$QUANT_GUIDE"
            if [[ "$_qrating" == "discouraged" ]]
            then
                to_archive+=("${_qnum}|${_qfile}|${_qqcache}")
            fi
        done < "$LLM_REGISTRY"

        local _ae
        for _ae in "${to_archive[@]}"
        do
            local _anum _aname _aqunt
            IFS='|' read -r _anum _aname _aqunt <<< "$_ae"
            local src="$LLAMA_MODEL_DIR/$_aname"
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
            local clean_tmp="${LLM_REGISTRY}.tmp"
            local new_num=0
            echo "#|name|file|size_gb|quant_cache|arch|gpu_layers|ctx|threads|batch|ubatch|parallel|fit_target_mb|backend|mmap_mode|tps|autotuned|is_default|in_vram" > "$clean_tmp"
            local _cline
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

    __model_list
}

# ---------------------------------------------------------------------------
# __model_list
# @description Display the numbered registry with active/default markers and drive usage.
# @returns 0 on success, 1 if the registry does not exist.
# ---------------------------------------------------------------------------
function __model_list() {
    local output_mode="human"
    case "${1:-}" in
        --json) output_mode="json" ;;
        --plain) output_mode="plain" ;;
    esac

    if [[ ! -f "$LLM_REGISTRY" ]]
    then
        if [[ "$output_mode" == "json" ]]
        then
            printf '{"error":"Registry not found","registry":"%s"}\n' "$LLM_REGISTRY"
        else
            __tac_info "Registry" "[Not found - run 'model scan' first]" "$C_Warning"
        fi
        return 1
    fi

    __llm_registry_sync_state >/dev/null 2>&1 || true

    local active_num=""
    [[ -f "$ACTIVE_LLM_FILE" ]] && active_num=$(< "$ACTIVE_LLM_FILE")
    local default_file=""
    default_file=$(__llm_default_file 2>/dev/null || true)

    if [[ "$output_mode" == "json" ]]
    then
        printf '{\n  "models": [\n'
        local first=1
        while IFS='|' read -r num name file size quant_cache arch gpu_layers ctx threads batch ubatch parallel fit_target_mb backend mmap_mode tps autotuned is_default in_vram
        do
            [[ "$num" == "#" || -z "$num" ]] && continue
            local is_active="false"
            local is_default_json="false"
            [[ "${in_vram:-no}" == "yes" ]] && is_active="true"
            [[ "${is_default:-no}" == "yes" ]] && is_default_json="true"
            (( first )) || printf ',\n'
            printf '    {"num":%s,"name":"%s","file":"%s","size":"%s","quant_cache":"%s","arch":"%s",\
"gpu_layers":%s,"ctx":%s,"threads":%s,"batch":%s,"ubatch":%s,"parallel":%s,"fit":%s,"backend":"%s","mmap_mode":"%s","tps":"%s","autotuned":"%s","active":%s,"default":%s}' \
                "$num" "$(__llm_json_escape "$name")" "$(__llm_json_escape "$file")" "$size" "$(__llm_json_escape "$quant_cache")" \
                "$(__llm_json_escape "$arch")" "$gpu_layers" "$ctx" "$threads" "$batch" "$ubatch" "$parallel" "$fit_target_mb" \
                "$(__llm_json_escape "$backend")" "$(__llm_json_escape "${mmap_mode:-auto}")" "$(__llm_json_escape "${tps:--}")" "$(__llm_json_escape "${autotuned:-no}")" "$is_active" "$is_default_json"
            first=0
        done < "$LLM_REGISTRY"
        printf '\n  ],\n'
        local d_used_bytes d_total_bytes d_avail_bytes d_pct_n
        d_used_bytes=$(df -B1 --output=used "$LLAMA_DRIVE_ROOT" 2>/dev/null | awk 'NR==2{print $1+0}')
        d_used_bytes=${d_used_bytes:-0}
        d_total_bytes=$LLAMA_DRIVE_SIZE
        d_avail_bytes=$(( d_total_bytes - d_used_bytes ))
        (( d_avail_bytes < 0 )) && d_avail_bytes=0
        d_pct_n=$(( d_total_bytes > 0 ? d_used_bytes * 100 / d_total_bytes : 0 ))
        printf '  "drive": {"used_gb":%d,"total_gb":%d,"avail_gb":%d,"pct":%d}\n}' \
            "$((d_used_bytes / 1024 / 1024 / 1024))" "$((d_total_bytes / 1024 / 1024 / 1024))" \
            "$((d_avail_bytes / 1024 / 1024 / 1024))" "$d_pct_n"
        return 0
    fi

    if [[ "$output_mode" == "plain" ]]
    then
        while IFS='|' read -r num name file size quant_cache arch gpu_layers ctx threads batch ubatch parallel fit_target_mb backend mmap_mode tps autotuned is_default in_vram
        do
            [[ "$num" == "#" || -z "$num" ]] && continue
            local status="idle"
            [[ "${in_vram:-no}" == "yes" ]] && status="active"
            [[ "${is_default:-no}" == "yes" ]] && status="default"
            printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
                "$num" "$name" "$file" "$size" "$quant_cache" "$arch" "$gpu_layers" "$ctx" "$threads" "$batch" "$ubatch" "$parallel" "$fit_target_mb" "$backend" "${mmap_mode:-auto}" "${tps:--}" "${autotuned:-no}" "$status"
        done < "$LLM_REGISTRY"
        return 0
    fi

    # Human-readable output
    printf "\n${C_Dim}  %-4s %-20s %-5s %-8s %-6s %-4s %-5s %-4s %-4s %-4s %-4s %-4s %-6s %-4s %-6s %-5s %-4s %-4s${C_Reset}\n" \
        "#" "MODEL" "SIZE" "Q/CACHE" "ARCH" "GPU" "CTX" "THR" "B" "UB" "PAR" "FIT" "BACK" "MMAP" "TPS" "ATUNE" "DEF" "VRAM"
    local _list_rule
    printf -v _list_rule '%*s' $((UIWidth - 4)) ''
    _list_rule="${_list_rule// /${BOX_SL}}"
    printf "${C_Dim}  %s${C_Reset}\n" "$_list_rule"

    local num name file size quant_cache arch gpu_layers ctx threads batch ubatch parallel fit_target_mb backend mmap_mode tps autotuned is_default in_vram
    while IFS='|' read -r num name file size quant_cache arch gpu_layers ctx threads batch ubatch parallel fit_target_mb backend mmap_mode tps autotuned is_default in_vram
    do
        [[ "$num" == "#" || -z "$num" ]] && continue
        local marker="  "
        local color=""
        if [[ "${in_vram:-no}" == "yes" ]]
        then
            marker="> "
            color="$C_Success"
        elif [[ "${is_default:-no}" == "yes" ]]
        then
            marker="* "
            color="$C_Highlight"
        fi
        printf "${color}${marker}%-4s %-20s %-5s %-8s %-6s %-4s %-5s %-4s %-4s %-4s %-4s %-4s %-6s %-4s %-6s %-5s %-4s %-4s${C_Reset}\n" \
            "$num" "${name:0:20}" "$size" "${quant_cache:0:8}" "${arch:0:6}" "$gpu_layers" "$ctx" "$threads" "$batch" "$ubatch" "$parallel" "$fit_target_mb" "${backend:0:6}" "${mmap_mode:-auto}" "${tps:--}" "${autotuned:-no}" "${is_default:-no}" "${in_vram:-no}"
    done < "$LLM_REGISTRY"

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
    printf "|  model scan  |  model bench  |  model autotune N${C_Reset}\n"
}

# ---------------------------------------------------------------------------
# __model_default
# @description Show the current default model or set it to a registry entry.
# @returns 0 on success, 1 if the target is invalid or missing.
# ---------------------------------------------------------------------------
function __model_default() {
    local target="${1:-}"

    if [[ -z "$target" ]]
    then
        if [[ -f "$LLM_DEFAULT_FILE" ]]
        then
            local def_file
            def_file=$(__llm_default_file 2>/dev/null || true)
            local entry=""
            [[ -n "$def_file" ]] && entry=$(__llm_registry_entry_by_file "$def_file")
            if [[ -n "$entry" ]]
            then
                local num name _rest
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
        __tac_info "Error" "[Not a number: '$target']" "$C_Error"
        return 1
    fi

    local entry
    entry=$(__llm_registry_entry_by_num "$target")
    if [[ -z "$entry" ]]
    then
        __tac_info "Error" "[Model #$target not found in registry]" "$C_Error"
        return 1
    fi

    local _n name file _rest
    IFS='|' read -r _n name file _rest <<< "$entry"
    mkdir -p "$(dirname "$LLM_DEFAULT_FILE")" 2>/dev/null
    echo "$file" > "$LLM_DEFAULT_FILE"
    __llm_registry_sync_state >/dev/null 2>&1 || true
    __tac_info "Default Model" "[SET TO: $name]" "$C_Success"
}

# ---------------------------------------------------------------------------
# __model_use
# @description Start a registry model with adaptive llama-server settings and health checks.
# @returns 0 on success, 1 if validation or startup fails.
# ---------------------------------------------------------------------------
function __model_use() {
    local target="${1:-}"

    if [[ -z "$target" ]]
    then
        local _use_default_file=""
        _use_default_file=$(__llm_default_file 2>/dev/null || true)
        if [[ -z "$_use_default_file" ]]
        then
            __tac_info "Error" \
                "[No model specified and no default set. Run 'model default <N>' to configure.]" \
                "$C_Error"
            return 1
        fi
        target=$(__llm_default_number 2>/dev/null || true)
        if [[ -z "$target" ]]
        then
            __tac_info "Error" \
                "[Default file not found in registry: $_use_default_file - run 'model scan']" \
                "$C_Error"
            return 1
        fi
        __tac_info "Default" "[Using default model #${target}]" "$C_Dim"
    fi

    if [[ ! "$target" =~ ^[0-9]+$ ]]
    then
        __tac_info "Error" "[Not a number: '$target']" "$C_Error"
        return 1
    fi
    local entry
    entry=$(__llm_registry_entry_by_num "$target")
    if [[ -z "$entry" ]]
    then
        __tac_info "Error" "[Model #$target not in registry - run 'model scan']" "$C_Error"
        return 1
    fi

    local num name file size quant_cache arch gpu_layers ctx threads batch_size ubatch_size parallel_slots fit_target_mb row_backend row_mmap_mode tps autotuned is_default in_vram
    IFS='|' read -r num name file size quant_cache arch gpu_layers ctx threads batch_size ubatch_size parallel_slots fit_target_mb row_backend row_mmap_mode tps autotuned is_default in_vram <<< "$entry"

    # Allow context size override via TAC_CTX_SIZE environment variable
    # (set by `serve --ctx-size N` or `model use N --ctx-size N`)
    if [[ -n "${TAC_CTX_SIZE:-}" ]]
    then
        if [[ "${TAC_CTX_SIZE:-}" =~ ^[0-9]+$ ]]
        then
            ctx="$TAC_CTX_SIZE"
            __tac_info "Context" "[OVERRIDDEN to $ctx via --ctx-size]" "$C_Dim"
        else
            __tac_info "Context" "[Invalid override '$TAC_CTX_SIZE' — using registry value $ctx]" "$C_Warning"
        fi
    fi

    local model_path="$LLAMA_MODEL_DIR/$file"
    local model_bytes=0

    # Auto-download model if not found (with user confirmation for large files)
    if [[ ! -f "$model_path" ]]
    then
        __tac_info "Model File" "[NOT FOUND - $file]" "$C_Warning"

        # Skip prompts in non-interactive mode - auto-confirm downloads
        if [[ "${TAC_NONINTERACTIVE:-}" == "1" ]]
        then
            __tac_info "Non-interactive" "[Auto-confirming download]" "$C_Dim"
            confirm="y"
            confirm_large="y"
        else
            # Check if model download is possible (HuggingFace repo info in registry)
            local download_prompt="Would you like to download model #$target ($name)? [y/N]: "
            read -r -e -p "$download_prompt" confirm
        fi

        if [[ "${confirm,,}" == "y" || "${confirm,,}" == "yes" ]]
        then
            # Check file size before downloading
            local size_num="${size%G}"
            if (( $(echo "$size_num > 2" | bc -l 2>/dev/null || echo 0) ))
            then
                __tac_info "Download Size" "[${size} - This may take several minutes]" "$C_Warning"
                if [[ "${TAC_NONINTERACTIVE:-}" != "1" ]]
                then
                    read -r -e -p "Continue? [y/N]: " confirm_large
                fi
                if [[ "${confirm_large,,}" != "y" && "${confirm_large,,}" != "yes" ]]
                then
                    __tac_info "Download" "[CANCELLED]" "$C_Dim"
                    return 1
                fi
            fi

            # Attempt download
            __tac_info "Download" "[STARTING - $name ($size)]" "$C_Dim"
            if __model_download "$file"
            then
                __tac_info "Download" "[COMPLETE]" "$C_Success"
                # Re-check file exists after download
                if [[ ! -f "$model_path" ]]
                then
                    __tac_info "Error" "[Download completed but file not found]" "$C_Error"
                    return 1
                fi
            else
                __tac_info "Download" "[FAILED]" "$C_Error"
                __tac_info "Hint" "Run 'model download $file' manually" "$C_Dim"
                return 1
            fi
        else
            __tac_info "Download" "[CANCELLED]" "$C_Dim"
            __tac_info "Hint" "Run 'model download $file' to download manually" "$C_Dim"
            return 1
        fi
    fi

    model_bytes=$(stat --format=%s "$model_path" 2>/dev/null || echo 0)
    local quant_rating
    quant_rating=$(__llm_quant_rating "$file")
    local llm_backend
    llm_backend="${LLM_SERVER_BACKEND:-${row_backend:-llama_server}}"
    case "$llm_backend" in
        native|binary|llama-server|llama_server)
            llm_backend="native"
            ;;
        python|llama-cpp-python|module|"")
            llm_backend="python"
            ;;
        *)
            __tac_info "Backend" "[Unknown '$llm_backend' - falling back to python]" "$C_Warning"
            llm_backend="python"
            ;;
    esac

    local python_bin=""
    if [[ "$llm_backend" == "python" ]]
    then
        python_bin=$(__llm_python_bin_resolve 2>/dev/null || true)
        if [[ -z "$python_bin" ]]
        then
            __tac_info "Error" "[No compatible Python found with llama-cpp-python==${LLAMA_CPP_PYTHON_VERSION}]" "$C_Error"
            __tac_info "Install" "[CMAKE_ARGS='-DGGML_CUDA=on' FORCE_CMAKE=1 pip install 'llama-cpp-python[server]==${LLAMA_CPP_PYTHON_VERSION}']" "$C_Dim"
            return 1
        fi
        LLM_SERVER_PYTHON_BIN="$python_bin"
    else
        if [[ ! -x "$LLAMA_SERVER_BIN" ]]
        then
            __tac_info "Error" "[Native llama-server binary not found: $LLAMA_SERVER_BIN]" "$C_Error"
            return 1
        fi
    fi

    # Prefer per-model registry values from model scan; fall back to global defaults.
    [[ "$threads" =~ ^[0-9]+$ ]] || threads="${LLAMA_CPU_THREADS:-6}"
    if [[ -z "${TAC_CTX_SIZE:-}" ]]
    then
        [[ "$ctx" =~ ^[0-9]+$ ]] || ctx="${LLAMA_CTX_SIZE:-4096}"
    fi
    local smi_cmd
    smi_cmd=$(__resolve_smi 2>/dev/null || true)
    if [[ -n "$smi_cmd" ]]
    then
        [[ "$gpu_layers" =~ ^[0-9]+$ ]] || gpu_layers="${LLAMA_GPU_LAYERS:-24}"
        if [[ "${LLAMA_GPU_LAYERS:-}" =~ ^[0-9]+$ ]]
        then
            gpu_layers="${LLAMA_GPU_LAYERS}"
        fi
    else
        gpu_layers=0
    fi

    # Quant-guide-aware launch tuning for 4GB VRAM systems.
    # Recommended quants can use the scanned/default layer target; larger
    # discouraged quants get conservative offload limits to reduce stalls.
    if (( gpu_layers > 0 ))
    then
        case "$quant_rating" in
            discouraged)
                if (( model_bytes >= 3500000000 ))
                then
                    gpu_layers=0
                elif (( model_bytes >= 2500000000 ))
                then
                    (( gpu_layers > 12 )) && gpu_layers=12
                fi
                ;;
            acceptable)
                if (( model_bytes >= 2600000000 ))
                then
                    (( gpu_layers > 20 )) && gpu_layers=20
                fi
                ;;
        esac
    fi

    __llm_server_stop
    sleep 1
    sudo -n prlimit --memlock=unlimited:unlimited --pid $$ 2>/dev/null

    [[ "$batch_size" =~ ^[0-9]+$ ]] || batch_size=1024
    [[ "$ubatch_size" =~ ^[0-9]+$ ]] || ubatch_size=256
    [[ "$parallel_slots" =~ ^[0-9]+$ ]] || parallel_slots=1
    local free_vram_mb=0
    if (( gpu_layers > 0 ))
    then
        if [[ -n "$smi_cmd" ]]
        then
            free_vram_mb=$(
                "$smi_cmd" --query-gpu=memory.free --format=csv,noheader,nounits 2>/dev/null \
                | head -1 | tr -d ' '
            )
        fi
        [[ "$free_vram_mb" =~ ^[0-9]+$ ]] || free_vram_mb=0

        :
    fi

    if [[ "${LLAMA_BATCH_SIZE:-}" =~ ^[0-9]+$ ]] && (( LLAMA_BATCH_SIZE > 0 ))
    then
        batch_size="$LLAMA_BATCH_SIZE"
    fi
    if [[ "${LLAMA_UBATCH_SIZE:-}" =~ ^[0-9]+$ ]] && (( LLAMA_UBATCH_SIZE > 0 ))
    then
        ubatch_size="$LLAMA_UBATCH_SIZE"
    fi
    if (( ubatch_size > batch_size ))
    then
        ubatch_size="$batch_size"
    fi
    if [[ "${LLAMA_PARALLEL_SLOTS:-}" =~ ^[0-9]+$ ]] && (( LLAMA_PARALLEL_SLOTS > 0 ))
    then
        parallel_slots="$LLAMA_PARALLEL_SLOTS"
    fi

    if (( ubatch_size > batch_size ))
    then
        ubatch_size="$batch_size"
    fi

    local type_k_val
    type_k_val=$(__llm_type_k_value)

    local cmd=()
    if [[ "$llm_backend" == "native" ]]
    then
        fit_target_mb="${fit_target_mb:-${LLAMA_FIT_TARGET_MB:-1024}}"
        if [[ ! "$fit_target_mb" =~ ^[0-9]+$ ]] || (( fit_target_mb < 0 ))
        then
            fit_target_mb=1024
        fi

        local flash_attn_mode="auto"
        case "${LLAMA_FLASH_ATTN:-true}" in
            true|TRUE|1|yes|YES|on|ON) flash_attn_mode="on" ;;
            false|FALSE|0|no|NO|off|OFF) flash_attn_mode="off" ;;
        esac

        local kv_offload_flag="--kv-offload"
        case "${LLAMA_OFFLOAD_KQV:-true}" in
            false|FALSE|0|no|NO|off|OFF) kv_offload_flag="--no-kv-offload" ;;
        esac

        cmd=("$LLAMA_SERVER_BIN")
        cmd+=("--model" "$model_path" "--port" "$LLM_PORT" "--host" "127.0.0.1")
        cmd+=("--ctx-size" "$ctx")
        cmd+=("--batch-size" "$batch_size" "--ubatch-size" "$ubatch_size")
        cmd+=("--threads" "$threads")
        cmd+=("--n-gpu-layers" "$gpu_layers")
        cmd+=("--fit" "on" "--fit-target" "$fit_target_mb")
        cmd+=("--flash-attn" "$flash_attn_mode")
        cmd+=("$kv_offload_flag")
        cmd+=("--cache-type-k" "${LLAMA_CACHE_TYPE_K:-q8_0}")
        cmd+=("--parallel" "$parallel_slots")
    else
        cmd=("$python_bin" "-m" "$LLM_SERVER_MODULE")
        cmd+=("--model" "$model_path" "--port" "$LLM_PORT" "--host" "127.0.0.1")
        cmd+=("--n_ctx" "$ctx")
        cmd+=("--n_batch" "$batch_size" "--n_ubatch" "$ubatch_size")
        cmd+=("--n_threads" "$threads")
        cmd+=("--n_gpu_layers" "$gpu_layers")
        cmd+=("--flash_attn" "${LLAMA_FLASH_ATTN:-true}")
        cmd+=("--offload_kqv" "${LLAMA_OFFLOAD_KQV:-true}")
        cmd+=("--type_k" "$type_k_val")
    fi

    # Adaptive memory-mapping behavior (video-inspired stability tuning).
    # --no-mmap can reduce page-fault stalls and mmap-related thrashing,
    # especially for MoE models, low free VRAM situations, and WSL hosts.
    local use_no_mmap=0
    local no_mmap_mode="${row_mmap_mode:-${LLAMA_NO_MMAP_MODE:-auto}}"
    case "$no_mmap_mode" in
        auto|on|off) ;;
        *) no_mmap_mode="${LLAMA_NO_MMAP_MODE:-auto}" ;;
    esac
    case "$no_mmap_mode" in
        on)
            use_no_mmap=1
            ;;
        off)
            use_no_mmap=0
            ;;
        auto|*)
            if [[ "$arch" == *"moe"* ]] || (( free_vram_mb > 0 && free_vram_mb < 1500 ))
            then
                use_no_mmap=1
            elif grep -qi microsoft /proc/version 2>/dev/null
            then
                use_no_mmap=1
            elif (( model_bytes >= 3000000000 ))
            then
                use_no_mmap=1
            fi
            ;;
    esac

    if (( use_no_mmap ))
    then
        if [[ "$llm_backend" == "native" ]]
        then
            cmd+=("--no-mmap")
        else
            cmd+=("--use_mmap" "false")
        fi
    fi

    local ngl_label="CPU-only"
    (( gpu_layers > 0 )) && ngl_label="ngl=${gpu_layers}"
    local mmap_label="mmap:on"
    (( use_no_mmap )) && mmap_label="mmap:off"
    local start_msg="#${num} ${name} (${size}, ${ngl_label}, ctx ${ctx}, "
    start_msg+="b ${batch_size}/${ubatch_size}, p ${parallel_slots}, ${mmap_label}, t=${threads}, k=${LLAMA_CACHE_TYPE_K:-q8_0})"
    __tac_info "Starting" "$start_msg" "$C_Highlight"
    __tac_info "Backend" "[$llm_backend]" "$C_Dim"

    if [[ -n "${__BENCH_MODE:-}" ]]
    then
        local _bench_vram_label _bench_clock_info
        if [[ "$free_vram_mb" =~ ^[0-9]+$ && "$free_vram_mb" -gt 0 ]]
        then
            _bench_vram_label="${free_vram_mb} MiB"
        else
            _bench_vram_label="unknown"
        fi
        _bench_clock_info=$(__llm_gpu_clock_snapshot)
        __tac_info "Bench Perf" "[free_vram_mb=${_bench_vram_label}; batch/ubatch=${batch_size}/${ubatch_size}; parallel=${parallel_slots}; ${_bench_clock_info}]" "$C_Dim"
    fi

    # llama.cpp monitors stdin and will force-shutdown on EOF.
    # We keep stdin open via a FIFO and a dedicated keeper process, then
    # explicitly tear down the keeper when llama-server exits.
    (
        trap '' HUP INT TERM

        # Close all inherited lock file descriptors (from autotune/bench locks)
        # so child processes (stdin keeper, llama-server) don't inherit them.
        # This prevents orphaned locks when the parent is killed.
        for _lfd in "/proc/$$/fd/"*; do
            _lfdnum="${_lfd##*/}"
            if [[ "$_lfdnum" -ge 10 ]]; then exec {_lfdnum}>&- 2>/dev/null; fi
        done 2>/dev/null

        # Clean up orphan FIFOs and keepers from any previous llama-server
        # instance that was killed without running __model_stop.
        local _okf
        for _okf in /tmp/llm-keeper.*.pid; do
            [[ -f "$_okf" ]] || continue
            _okp=$(< "$_okf")
            if [[ "$_okp" =~ ^[0-9]+$ ]]; then kill -TERM "$_okp" 2>/dev/null; fi
            rm -f "$_okf"
        done
        rm -f /tmp/llm-stdin.*

        local stdin_fifo
        stdin_fifo=$(mktemp -u /tmp/llm-stdin.XXXXXX)
        if ! mkfifo "$stdin_fifo" 2>/dev/null
        then
            __tac_info "Status" "FAILED OR TIMEOUT - could not create stdin fifo" "$C_Error"
            exit 1
        fi

        # Open FIFO writer and keep it alive without producing data.
        # The keeper writes its PID to a file so __model_stop can kill it
        # directly, preventing orphan sleep processes from accumulating when
        # llama-server is killed abruptly.
        #
        # The keeper self-destructs after 1 hour if orphaned (reparented to
        # init by a SIGKILL on its parent tree). This is a safety net: in
        # normal operation __model_stop kills the keeper directly.
        local stdin_keeper_pid_file="/tmp/llm-keeper.$$.pid"
        {
            exec 3>"$stdin_fifo"
            # The PID file is written by the parent after $! is captured.
            # We just need to keep the FIFO open.
            # sleep 3600 (1 h) — if the parent is killed and we get
            # reparented, we'll eventually die on our own, preventing
            # infinite accumulation.
            sleep 3600
            # If we reach here, we were orphaned — clean up
            rm -f "$stdin_fifo" "$stdin_keeper_pid_file" 2>/dev/null || true
        } &
        local stdin_keeper_pid=$!
        # Write the ACTUAL keeper PID (from $!) to the PID file.
        # Previously we wrote $$ inside the block, which was the parent's PID.
        # This caused __model_stop to kill the wrong process.
        echo "$stdin_keeper_pid" > "$stdin_keeper_pid_file"
        # Also register the PID in the parent's cleanup list if available
        if declare -p bench_cleanup_spawned_pids &>/dev/null
        then
            bench_cleanup_spawned_pids+=("$stdin_keeper_pid")
        fi

        nohup "${cmd[@]}" <"$stdin_fifo" >"$LLM_LOG_FILE" 2>&1
        local server_rc=$?

        kill "$stdin_keeper_pid" >/dev/null 2>&1 || true
        wait "$stdin_keeper_pid" 2>/dev/null || true
        rm -f "$stdin_fifo"
        exit "$server_rc"
    ) &
    local model_shell_pid=$!
    disown
    # Save the model subshell PID so __model_stop can kill it.
    # Include our own PID to prevent stale PIDs from overlapping runs.
    echo "$model_shell_pid" > "/tmp/llm-modelshell.$$.pid"

    if ! { echo "$num" > "${ACTIVE_LLM_FILE}.tmp" 2>/dev/null && mv "${ACTIVE_LLM_FILE}.tmp" "$ACTIVE_LLM_FILE"; }
    then
        __tac_info "Warning" "[Could not save state]" "$C_Warning"
    fi

    local health_timeout
    health_timeout=$(__llm_health_timeout "$size" "$gpu_layers" "$name")
    local _health_elapsed=0
    if __llm_wait_for_health "$health_timeout" _health_elapsed "dots" "Loading LLM (health check)"
    then
        __llm_registry_sync_state >/dev/null 2>&1 || true
        __tac_info "Status" "ONLINE [Port $LLM_PORT]" "$C_Success"
        local offload_info
        offload_info=$(grep -oiE 'offload(ing|ed) [0-9]+ .* layers' "$LLM_LOG_FILE" 2>/dev/null | tail -1)
        if [[ -n "$offload_info" ]]
        then
            __tac_info "GPU Offload" "[$offload_info]" "$C_Dim"
        fi
        return 0
    fi

    # Failed startup must not leave a lingering server process.
    __llm_server_stop
    rm -f "$ACTIVE_LLM_FILE"
    __llm_registry_sync_state >/dev/null 2>&1 || true
    __tac_info "Status" "FAILED OR TIMEOUT - check: tail $LLM_LOG_FILE" "$C_Error"
    return 1
}

# ---------------------------------------------------------------------------
# __model_autotune
# @description Sweep safe runtime combos for one model/backend and persist best profile.
# Usage: model autotune [N] [--backend native|python] [--quick] [--ctx-size N] [--trials N]
# @returns 0 on success, 1 on validation/benchmark failure.
# ---------------------------------------------------------------------------
function __model_autotune() {
    if [[ "${1:-}" == "-h" || "${1:-}" == "--help" || "${1:-}" == "help" ]]
    then
        __model_autotune_help
        return 0
    fi

    local target="${1:-}"
    shift 1 2>/dev/null || true

    local backend_raw="${LLM_SERVER_BACKEND:-native}"
    local quick_mode=0
    local tune_ctx=""
    local trials="${LLM_AUTOTUNE_TRIALS:-3}"
    local __autotune_interrupted=0

    local __autotune_prev_int_trap=""
    local __autotune_prev_term_trap=""
    __autotune_prev_int_trap=$(trap -p INT || true)
    __autotune_prev_term_trap=$(trap -p TERM || true)
    __autotune_restore_traps() {
        if [[ -n "$__autotune_prev_int_trap" ]]; then
            eval "$__autotune_prev_int_trap"
        else
            trap - INT
        fi
        if [[ -n "$__autotune_prev_term_trap" ]]; then
            eval "$__autotune_prev_term_trap"
        else
            trap - TERM
        fi
    }
    __autotune_fail() {
        __autotune_restore_traps
        unset -f __autotune_restore_traps __autotune_fail 2>/dev/null || true
    }

    # Ensure Ctrl-C/termination cannot leave trial servers running.
    trap '__model_stop >/dev/null 2>&1 || true; __autotune_interrupted=130' INT
    trap '__model_stop >/dev/null 2>&1 || true; __autotune_interrupted=143' TERM

    while [[ $# -gt 0 ]]
    do
        (( __autotune_interrupted != 0 )) && break
        case "$1" in
            -h|--help)
                __model_autotune_help
                __autotune_fail
                return 0
                ;;
            --backend)
                backend_raw="$2"
                shift 2
                ;;
            --quick)
                quick_mode=1
                shift
                ;;
            --ctx-size|--ctx)
                tune_ctx="$2"
                shift 2
                ;;
            --trials)
                trials="$2"
                shift 2
                ;;
            *)
                shift
                ;;
        esac
    done

    if [[ -z "$target" ]]
    then
        target=$(__llm_default_number 2>/dev/null || true)
    fi
    if [[ -z "$target" || ! "$target" =~ ^[0-9]+$ ]]
    then
        __tac_info "Autotune" "[Specify model number: model autotune <N>]" "$C_Error"
        __autotune_fail
        return 1
    fi

    local entry
    entry=$(__llm_registry_entry_by_num "$target")
    if [[ -z "$entry" ]]
    then
        __tac_info "Autotune" "[Model #$target not in registry - run 'model scan']" "$C_Error"
        __autotune_fail
        return 1
    fi

    local num name file size quant_cache arch gpu_layers ctx threads batch ubatch parallel fit_target_mb backend mmap_mode tps autotuned is_default in_vram
    IFS='|' read -r num name file size quant_cache arch gpu_layers ctx threads batch ubatch parallel fit_target_mb backend mmap_mode tps autotuned is_default in_vram <<< "$entry"
    __tac_info "File" "$file" "$C_Dim"

    local backend
    case "$backend_raw" in
        native|binary|llama-server) backend="native" ;;
        python|llama-cpp-python|module|"") backend="python" ;;
        *)
            __tac_info "Autotune" "[Unknown backend '$backend_raw']" "$C_Error"
            __autotune_fail
            return 1
            ;;
    esac

    if [[ -n "$tune_ctx" ]] && [[ ! "$tune_ctx" =~ ^[0-9]+$ ]]
    then
        __tac_info "Autotune" "[Invalid --ctx-size '$tune_ctx']" "$C_Error"
        __autotune_fail
        return 1
    fi
    if [[ ! "$trials" =~ ^[0-9]+$ ]] || (( trials < 1 ))
    then
        __tac_info "Autotune" "[Invalid --trials '$trials']" "$C_Error"
        __autotune_fail
        return 1
    fi

    # Serialize autotune runs to avoid overlapping server/curl trials.
    local lock_fd=""
    local lock_file="${LLM_AUTOTUNE_LOCK_FILE:-/tmp/llm-autotune.lock}"
    local lock_wait_seconds="${LLM_AUTOTUNE_LOCK_WAIT_SECONDS:-5}"

    # Stale lock detection: if file exists but no process holds it open, remove it.
    if [[ -f "$lock_file" ]]
    then
        if ! lsof "$lock_file" >/dev/null 2>&1
        then
            __tac_info "Autotune" "[Cleaning stale lock: $lock_file]" "$C_Warning"
            rm -f "$lock_file"
        fi
    fi

    if [[ "${LLM_AUTOTUNE_SKIP_LOCK:-0}" != "1" ]] && command -v flock >/dev/null 2>&1
    then
        # shellcheck disable=SC2091  # intentional: capture the fd number
        local lock_fd
        exec {lock_fd}>"$lock_file" || {
            __tac_info "Autotune" "[Unable to open lock file: $lock_file]" "$C_Error"
            __autotune_fail
            return 1
        }
        if ! flock -w "$lock_wait_seconds" "$lock_fd"
        then
            __tac_info "Autotune" "[Another autotune is running (lock: $lock_file)]" "$C_Error"
            exec {lock_fd}>&-
            __autotune_fail
            return 1
        fi
    elif [[ "${LLM_AUTOTUNE_SKIP_LOCK:-0}" == "1" ]]
    then
        __tac_info "Autotune" "[Lock skipped by caller]" "$C_Dim"
    fi

    local prev_backend="${LLM_SERVER_BACKEND:-}"
    local prev_batch="${LLAMA_BATCH_SIZE:-}"
    local prev_ubatch="${LLAMA_UBATCH_SIZE:-}"
    local prev_parallel="${LLAMA_PARALLEL_SLOTS:-}"
    local prev_fit_target="${LLAMA_FIT_TARGET_MB:-}"
    local prev_ctx_override="${TAC_CTX_SIZE:-}"
    local prev_burn_timeout="${LLM_BURN_REQUEST_TIMEOUT:-}"
    local prev_burn_timeout_cpu="${LLM_BURN_REQUEST_TIMEOUT_CPU:-}"
    local prev_burn_ready_timeout="${LLM_BURN_READY_TIMEOUT:-}"
    local prev_model=""
    [[ -f "$ACTIVE_LLM_FILE" ]] && prev_model=$(< "$ACTIVE_LLM_FILE")

    local __AUTOTUNE_MODE=1
    local __BENCH_MODE=1
    export LLM_SERVER_BACKEND="$backend"
    [[ -n "$tune_ctx" ]] && export TAC_CTX_SIZE="$tune_ctx"

    # Keep autotune responsive: cap request/readiness waits per trial so one
    # bad config does not stall the whole sweep.
    if (( quick_mode ))
    then
        export LLM_BURN_REQUEST_TIMEOUT="${LLM_AUTOTUNE_BURN_TIMEOUT:-150}"
        export LLM_BURN_REQUEST_TIMEOUT_CPU="${LLM_AUTOTUNE_BURN_TIMEOUT_CPU:-300}"
    else
        export LLM_BURN_REQUEST_TIMEOUT="${LLM_AUTOTUNE_BURN_TIMEOUT:-240}"
        export LLM_BURN_REQUEST_TIMEOUT_CPU="${LLM_AUTOTUNE_BURN_TIMEOUT_CPU:-420}"
    fi
    export LLM_BURN_READY_TIMEOUT="${LLM_AUTOTUNE_READY_TIMEOUT:-120}"
    local oom_regex='(out of memory|oom|cuda.*(failed|error)|failed to allocate|std::bad_alloc|cannot allocate)'

    local -a combos=()
    local -a ctx_candidates=()
    if (( quick_mode ))
    then
        combos=(
            "1024:256:1:256"
            "2048:512:1:256"
            "1024:256:2:256"
            "2048:512:2:256"
        )
        # Quick mode still tests a higher-context candidate first.
        ctx_candidates=(8192 4096)
    else
        combos=(
            "512:128:1:256"
            "1024:256:1:256"
            "2048:512:1:256"
            "4096:1024:1:512"
            "512:128:2:256"
            "1024:256:2:256"
            "2048:512:2:256"
            "4096:1024:2:512"
        )
        ctx_candidates=(12288 8192 6144 4096)
    fi

    # Per-model candidate pruning based on available VRAM and model size.
    local free_vram_mb=0
    local smi_cmd
    smi_cmd=$(__resolve_smi 2>/dev/null || true)
    if [[ -n "$smi_cmd" ]]
    then
        free_vram_mb=$("$smi_cmd" --query-gpu=memory.free --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ')
    fi
    [[ "$free_vram_mb" =~ ^[0-9]+$ ]] || free_vram_mb=0

    local model_bytes=0
    model_bytes=$(stat --format=%s "$LLAMA_MODEL_DIR/$name" 2>/dev/null || echo 0)

    local -a pruned_combos=()
    local _pc
    for _pc in "${combos[@]}"
    do
        IFS=':' read -r _pb _pu _pp _pf <<< "$_pc"
        # Avoid aggressive parallelism when VRAM is tight.
        if (( free_vram_mb > 0 && free_vram_mb < 1800 && _pp > 1 ))
        then
            continue
        fi
        # Keep ubatch conservative for larger model footprints on 4GB VRAM.
        if (( model_bytes >= 1800000000 && _pu > 512 ))
        then
            continue
        fi
        pruned_combos+=("$_pc")
    done
    if (( ${#pruned_combos[@]} > 0 ))
    then
        combos=("${pruned_combos[@]}")
    fi

    # Always include registry/default ctx so each model has at least one
    # realistic baseline candidate.
    if [[ "$ctx" =~ ^[0-9]+$ ]]
    then
        ctx_candidates+=("$ctx")
    fi

    # If caller forced ctx, only test that value.
    if [[ -n "$tune_ctx" ]]
    then
        ctx_candidates=("$tune_ctx")
    elif [[ "${LLM_AUTOTUNE_CTX_STRATEGY:-binary}" == "binary" ]]
    then
        # Binary-search the highest startup-stable context first, then test
        # nearby contexts for throughput ranking.
        local sane_max_ctx="${LLM_AUTOTUNE_CTX_SANE_LIMIT:-8192}"
        [[ "$sane_max_ctx" =~ ^[0-9]+$ ]] || sane_max_ctx=8192

        local base_ctx="${ctx:-4096}"
        [[ "$base_ctx" =~ ^[0-9]+$ ]] || base_ctx=4096
        local max_ctx="${LLM_AUTOTUNE_MAX_CTX:-32768}"
        [[ "$max_ctx" =~ ^[0-9]+$ ]] || max_ctx=32768

        # If registry ctx is unrealistically large (> sane limit), treat it as
        # a placeholder (common for default template rows) and clamp base_ctx.
        # This prevents binary-search failure when low > high.
        if (( base_ctx > sane_max_ctx )); then
            base_ctx=$sane_max_ctx
        fi

        (( max_ctx < base_ctx )) && max_ctx=$base_ctx

        local discovered_ctx="$base_ctx"
        local low="$base_ctx"
        local high="$max_ctx"
        local probe_batch=1024
        local probe_ubatch=256
        local probe_parallel=1
        local probe_fit=256

        while (( low <= high ))
        do
            local mid=$(( (low + high) / 2 ))
            mid=$(( (mid / 512) * 512 ))
            (( mid < 512 )) && mid=512
            (( mid < low )) && mid=$low

            export TAC_CTX_SIZE="$mid"
            export LLAMA_BATCH_SIZE="$probe_batch"
            export LLAMA_UBATCH_SIZE="$probe_ubatch"
            export LLAMA_PARALLEL_SLOTS="$probe_parallel"
            export LLAMA_FIT_TARGET_MB="$probe_fit"

            local probe_log="/tmp/autotune_ctx_probe_${num}_${mid}.log"
            if __model_use "$num" >"$probe_log" 2>&1
            then
                if grep -Eiq "$oom_regex" "$probe_log" 2>/dev/null
                then
                    high=$((mid - 512))
                else
                    discovered_ctx="$mid"
                    low=$((mid + 512))
                fi
            else
                high=$((mid - 512))
            fi
            __model_stop >/dev/null 2>&1 || true

            # Prevent binary loop stalling on boundary rounding.
            if (( low > max_ctx ))
            then
                break
            fi
        done

        local ctx_step="${LLM_AUTOTUNE_CTX_STEP:-2048}"
        [[ "$ctx_step" =~ ^[0-9]+$ ]] || ctx_step=2048
        ctx_candidates=("$discovered_ctx" "$((discovered_ctx - ctx_step))" "$((discovered_ctx - 2 * ctx_step))" "$base_ctx")
    fi

    # Unique + sort descending so we prioritize higher context first.
    local _ctx_sorted=""
    _ctx_sorted=$(printf '%s\n' "${ctx_candidates[@]}" | awk '/^[0-9]+$/ {a[$1]=1} END {for (k in a) print k}' | sort -nr)
    ctx_candidates=()
    while IFS= read -r _ctx_line
    do
        [[ -n "$_ctx_line" ]] && ctx_candidates+=("$_ctx_line")
    done <<< "$_ctx_sorted"
    if (( ${#ctx_candidates[@]} == 0 ))
    then
        ctx_candidates=(4096)
    fi

    __tac_header "MODEL AUTOTUNE" "open"
    __tac_info "Target" "#${num} ${name} (${size})" "$C_Highlight"
    __tac_info "Backend" "[$backend]" "$C_Dim"
    __tac_info "Trials" "[${trials} per config, median score]" "$C_Dim"
    __tac_info "Objective" "[1) no OOM  2) max ctx  3) max TPS]" "$C_Dim"
    __tac_info "Ctx Sweep" "[${ctx_candidates[*]}]" "$C_Dim"
    [[ -n "$tune_ctx" ]] && __tac_info "Context" "[Forced ctx=${tune_ctx}]" "$C_Dim"
    echo ""
    printf "${C_Dim}  %-4s %-5s %-18s %-8s %-8s${C_Reset}\n" "#" "CTX" "CONFIG" "TPS" "STATUS"

    local _auto_rule
    printf -v _auto_rule '%*s' $((UIWidth - 4)) ''
    _auto_rule="${_auto_rule// /${BOX_SL}}"
    printf "${C_Dim}  %s${C_Reset}\n" "$_auto_rule"

    local idx=0
    local best_tps=""
    local best_score=""
    local best_stddev=""
    local best_failures=0
    local best_samples=0
    local best_combo=""
    local best_ctx=""
    local total_configs=$(( ${#ctx_candidates[@]} * ${#combos[@]} ))
    local jitter_penalty="${LLM_AUTOTUNE_JITTER_PENALTY:-0.30}"
    local early_stop_margin="${LLM_AUTOTUNE_EARLY_STOP_MARGIN:-2.0}"
    local do_warmup="${LLM_AUTOTUNE_WARMUP:-1}"

    local fail_oom=0
    local fail_timeout=0
    local fail_start=0
    local fail_burn=0
    local fail_notps=0
    local fail_dominated=0

    declare -A best_score_by_ctx

    local c_ctx=""
    for c_ctx in "${ctx_candidates[@]}"
    do
        (( __autotune_interrupted != 0 )) && break
        export TAC_CTX_SIZE="$c_ctx"
        for combo in "${combos[@]}"
        do
            (( __autotune_interrupted != 0 )) && break
            idx=$((idx + 1))
            IFS=':' read -r c_batch c_ubatch c_parallel c_fit <<< "$combo"
            export LLAMA_BATCH_SIZE="$c_batch"
            export LLAMA_UBATCH_SIZE="$c_ubatch"
            export LLAMA_PARALLEL_SLOTS="$c_parallel"
            export LLAMA_FIT_TARGET_MB="$c_fit"

            local use_log="/tmp/autotune_use_${num}_${idx}.log"
            local burn_log=""
            local -a tps_samples=()
            local trial run_tps trial_ok=1
            local oom_detected=0
            local dominated_detected=0

            if __model_use "$num" >"$use_log" 2>&1
            then
                if (( do_warmup == 1 ))
                then
                    curl -sS --max-time 30 "http://127.0.0.1:${LLM_PORT}/v1/chat/completions" \
                        -H "Content-Type: application/json" \
                        -d '{"messages":[{"role":"user","content":"Warmup"}],"max_tokens":64,"temperature":0,"top_p":1.0}' \
                        >"/tmp/autotune_warmup_${num}_${idx}.log" 2>&1 || true
                fi

                for (( trial=1; trial<=trials; trial++ ))
                do
                    if (( __autotune_interrupted != 0 ))
                    then
                        trial_ok=0
                        break
                    fi
                    burn_log="/tmp/autotune_burn_${num}_${idx}_${trial}.log"
                    __tac_info "Trial" "[Config ${idx}/${total_configs} | ctx ${c_ctx} | run ${trial}/${trials}: b ${c_batch}/${c_ubatch}, p ${c_parallel}]" "$C_Dim"
                    rm -f "$LLM_TPS_CACHE"
                    if burn >"$burn_log" 2>&1
                    then
                        run_tps=""
                        [[ -f "$LLM_TPS_CACHE" ]] && run_tps=$(< "$LLM_TPS_CACHE")

                        # Fallback: parse TPS directly from burn output when cache
                        # write is unavailable in non-interactive mode.
                        if [[ ! "$run_tps" =~ ^[0-9]+(\.[0-9]+)?$ ]] && [[ -f "$burn_log" ]]
                        then
                            run_tps=$(sed -n 's/.*Burn complete: \([0-9][0-9]*\(\.[0-9][0-9]*\)\?\) tps.*/\1/p' "$burn_log" | tail -n1)
                        fi

                        if grep -Eiq "$oom_regex" "$burn_log" 2>/dev/null
                        then
                            oom_detected=1
                            trial_ok=0
                            break
                        fi

                        if [[ "$run_tps" =~ ^[0-9]+(\.[0-9]+)?$ ]]
                        then
                            tps_samples+=("$run_tps")

                            # Early-stop dominated configs after first sample.
                            if (( trial == 1 && trials > 1 )) && [[ -n "${best_score_by_ctx[$c_ctx]:-}" ]]
                            then
                                local _ctx_best="${best_score_by_ctx[$c_ctx]}"
                                local _dominated
                                _dominated=$(awk -v run="$run_tps" -v best="$_ctx_best" -v margin="$early_stop_margin" 'BEGIN{ if (run + margin < best) print 1; else print 0 }')
                                if [[ "$_dominated" == "1" ]]
                                then
                                    dominated_detected=1
                                    trial_ok=0
                                    break
                                fi
                            fi
                        else
                            trial_ok=0
                            break
                        fi
                    else
                        if grep -Eiq "$oom_regex" "$burn_log" 2>/dev/null
                        then
                            oom_detected=1
                        fi
                        trial_ok=0
                        break
                    fi
                done
            else
                if grep -Eiq "$oom_regex" "$use_log" 2>/dev/null
                then
                    oom_detected=1
                    fail_oom=$((fail_oom + 1))
                fi
                (( oom_detected == 0 )) && fail_start=$((fail_start + 1))
                printf "  %-4s %-5s %-18s %-8s %-8s\n" "$idx" "$c_ctx" "b ${c_batch}/${c_ubatch} p ${c_parallel}" "FAIL" "$([[ $oom_detected -eq 1 ]] && echo OOM || echo START)"
                __model_stop >/dev/null 2>&1 || true
                sleep 1
                continue
            fi

            if (( ${#tps_samples[@]} > 0 ))
            then
                local median_tps=""
                local stddev_tps=""
                local score_tps=""
                median_tps=$(printf '%s\n' "${tps_samples[@]}" | __llm_median_from_list 2>/dev/null || true)
                stddev_tps=$(printf '%s\n' "${tps_samples[@]}" | __llm_stddev_from_list 2>/dev/null || true)
                [[ "$stddev_tps" =~ ^[0-9]+(\.[0-9]+)?$ ]] || stddev_tps="0"

                if [[ "$median_tps" =~ ^[0-9]+(\.[0-9]+)?$ ]]
                then
                    score_tps=$(awk -v m="$median_tps" -v s="$stddev_tps" -v p="$jitter_penalty" 'BEGIN{printf "%.3f", (m - (s*p))}')
                    local status_label="OK"
                    if (( oom_detected == 1 ))
                    then
                        status_label="OOM"
                        fail_oom=$((fail_oom + 1))
                    elif (( dominated_detected == 1 ))
                    then
                        status_label="DOM"
                        fail_dominated=$((fail_dominated + 1))
                    elif (( trial_ok == 0 ))
                    then
                        status_label="PARTIAL"
                    fi

                    printf "  %-4s %-5s %-18s %-8s %-8s\n" "$idx" "$c_ctx" "b ${c_batch}/${c_ubatch} p ${c_parallel}" "$median_tps" "$status_label"

                    # Objective priority:
                    # 1) no OOM, 2) maximum context, 3) maximum TPS.
                    if (( oom_detected == 0 ))
                    then
                        if [[ -z "$best_combo" ]] \
                            || (( c_ctx > best_ctx )) \
                            || { (( c_ctx == best_ctx )) && awk -v s="$score_tps" -v b="$best_score" 'BEGIN{exit !(s>b)}'; }
                        then
                            best_tps="$median_tps"
                            best_score="$score_tps"
                            best_stddev="$stddev_tps"
                            best_failures=$(( trials - ${#tps_samples[@]} ))
                            best_samples=${#tps_samples[@]}
                            best_combo="$combo"
                            best_ctx="$c_ctx"
                        fi

                        if [[ -z "${best_score_by_ctx[$c_ctx]:-}" ]] || awk -v s="$score_tps" -v b="${best_score_by_ctx[$c_ctx]:-0}" 'BEGIN{exit !(s>b)}'
                        then
                            best_score_by_ctx[$c_ctx]="$score_tps"
                        fi
                    fi
                else
                    fail_notps=$((fail_notps + 1))
                    printf "  %-4s %-5s %-18s %-8s %-8s\n" "$idx" "$c_ctx" "b ${c_batch}/${c_ubatch} p ${c_parallel}" "FAIL" "NO TPS"
                fi
            else
                local fail_status="BURN"
                if (( oom_detected == 1 ))
                then
                    fail_status="OOM"
                    fail_oom=$((fail_oom + 1))
                elif (( dominated_detected == 1 ))
                then
                    fail_status="DOM"
                    fail_dominated=$((fail_dominated + 1))
                fi
                if [[ -n "$burn_log" && -f "$burn_log" ]]
                then
                    local _burn_err
                    _burn_err=$(tail -n 6 "$burn_log" | tr '\n' ' ')
                    if [[ "$_burn_err" == *"timed out"* ]]
                    then
                        fail_status="TIMEOUT"
                        fail_timeout=$((fail_timeout + 1))
                    fi
                fi
                if [[ "$fail_status" == "BURN" ]]
                then
                    fail_burn=$((fail_burn + 1))
                fi
                printf "  %-4s %-5s %-18s %-8s %-8s\n" "$idx" "$c_ctx" "b ${c_batch}/${c_ubatch} p ${c_parallel}" "FAIL" "$fail_status"
            fi

            __model_stop >/dev/null 2>&1 || true
            sleep 1
        done
    done

    if [[ -n "$best_combo" ]]
    then
        IFS=':' read -r best_batch best_ubatch best_parallel best_fit <<< "$best_combo"
        local save_ctx="${best_ctx:-${tune_ctx:-$ctx}}"
        local verified=0
        [[ "$save_ctx" =~ ^[0-9]+$ ]] || save_ctx="*"

        # Optional final verification pass on the chosen winner.
        if [[ "${LLM_AUTOTUNE_CONFIRM_FINAL:-1}" == "1" ]]
        then
            export TAC_CTX_SIZE="$save_ctx"
            export LLAMA_BATCH_SIZE="$best_batch"
            export LLAMA_UBATCH_SIZE="$best_ubatch"
            export LLAMA_PARALLEL_SLOTS="$best_parallel"
            export LLAMA_FIT_TARGET_MB="$best_fit"
            local _verify_log="/tmp/autotune_verify_${num}.log"
            if __model_use "$num" >"/tmp/autotune_verify_use_${num}.log" 2>&1
            then
                if burn >"$_verify_log" 2>&1
                then
                    local _verify_tps
                    _verify_tps=$(sed -n 's/.*Burn complete: \([0-9][0-9]*\(\.[0-9][0-9]*\)\?\) tps.*/\1/p' "$_verify_log" | tail -n1)
                    if [[ "$_verify_tps" =~ ^[0-9]+(\.[0-9]+)?$ ]]
                    then
                        best_tps="$_verify_tps"
                        verified=1
                    fi
                fi
            fi
            __model_stop >/dev/null 2>&1 || true
        fi

        export LLM_AUTOTUNE_LAST_SCORE="${best_score:-$best_tps}"
        export LLM_AUTOTUNE_LAST_STDDEV="${best_stddev:-0}"
        export LLM_AUTOTUNE_LAST_SAMPLES="${best_samples:-0}"
        export LLM_AUTOTUNE_LAST_FAILURES="${best_failures:-0}"
        export LLM_AUTOTUNE_LAST_CTX_MIN="${ctx_candidates[${#ctx_candidates[@]}-1]:-$save_ctx}"
        export LLM_AUTOTUNE_LAST_CTX_MAX="${ctx_candidates[0]:-$save_ctx}"
        export LLM_AUTOTUNE_LAST_VERIFIED="$verified"
        export LLM_AUTOTUNE_OBJECTIVE="no-oom>max-ctx>max-tps"

        __llm_autotune_profile_save "$num" "$backend" "$save_ctx" "$best_batch" "$best_ubatch" "$best_parallel" "$best_fit" "$best_tps"
        # Keep future model use/bench aligned to the selected context when this
        # autotune run chose the context automatically.
        if [[ -z "$tune_ctx" && "$save_ctx" =~ ^[0-9]+$ ]]
        then
            __save_model_ctx "$num" "$save_ctx"
        fi
        __tac_info "Winner" "[b ${best_batch}/${best_ubatch}, p ${best_parallel}, fit=${best_fit} MB, tps=${best_tps}]" "$C_Success"
        __tac_info "Winner Score" "[${best_score:-$best_tps} (stddev=${best_stddev:-0})]" "$C_Success"
        __tac_info "Winner Ctx" "[${save_ctx}]" "$C_Success"
        __tac_info "Verified" "[$([[ "$verified" == "1" ]] && echo yes || echo no)]" "$C_Dim"
        __tac_info "Saved" "[models.conf row updated]" "$C_Dim"
    else
        __tac_info "Autotune" "[No stable configuration found]" "$C_Error"
    fi

    __tac_info "Failure Summary" "[oom=${fail_oom}, timeout=${fail_timeout}, start=${fail_start}, burn=${fail_burn}, no_tps=${fail_notps}, dominated=${fail_dominated}]" "$C_Dim"

    # Restore caller environment and prior model state.
    if [[ -n "$prev_backend" ]]; then export LLM_SERVER_BACKEND="$prev_backend"; else unset LLM_SERVER_BACKEND; fi
    if [[ -n "$prev_batch" ]]; then export LLAMA_BATCH_SIZE="$prev_batch"; else unset LLAMA_BATCH_SIZE; fi
    if [[ -n "$prev_ubatch" ]]; then export LLAMA_UBATCH_SIZE="$prev_ubatch"; else unset LLAMA_UBATCH_SIZE; fi
    if [[ -n "$prev_parallel" ]]; then export LLAMA_PARALLEL_SLOTS="$prev_parallel"; else unset LLAMA_PARALLEL_SLOTS; fi
    if [[ -n "$prev_fit_target" ]]; then export LLAMA_FIT_TARGET_MB="$prev_fit_target"; else unset LLAMA_FIT_TARGET_MB; fi
    if [[ -n "$prev_ctx_override" ]]; then export TAC_CTX_SIZE="$prev_ctx_override"; else unset TAC_CTX_SIZE; fi
    if [[ -n "$prev_burn_timeout" ]]; then export LLM_BURN_REQUEST_TIMEOUT="$prev_burn_timeout"; else unset LLM_BURN_REQUEST_TIMEOUT; fi
    if [[ -n "$prev_burn_timeout_cpu" ]]; then export LLM_BURN_REQUEST_TIMEOUT_CPU="$prev_burn_timeout_cpu"; else unset LLM_BURN_REQUEST_TIMEOUT_CPU; fi
    if [[ -n "$prev_burn_ready_timeout" ]]; then export LLM_BURN_READY_TIMEOUT="$prev_burn_ready_timeout"; else unset LLM_BURN_READY_TIMEOUT; fi
    unset LLM_AUTOTUNE_LAST_SCORE LLM_AUTOTUNE_LAST_STDDEV LLM_AUTOTUNE_LAST_SAMPLES
    unset LLM_AUTOTUNE_LAST_FAILURES LLM_AUTOTUNE_LAST_CTX_MIN LLM_AUTOTUNE_LAST_CTX_MAX
    unset LLM_AUTOTUNE_LAST_VERIFIED LLM_AUTOTUNE_OBJECTIVE
    if [[ -n "$lock_fd" ]]
    then
        flock -u "$lock_fd" 2>/dev/null || true
        exec {lock_fd}>&-
    fi

    if [[ "${LLM_AUTOTUNE_RESTORE_PREV:-1}" == "1" ]] && [[ -n "$prev_model" ]] && [[ "$prev_model" =~ ^[0-9]+$ ]]
    then
        __tac_info "Restoring" "Model #${prev_model}" "$C_Dim"
        __model_use "$prev_model" >/dev/null 2>&1 || true
    fi

    __tac_footer
    __autotune_restore_traps
    unset -f __autotune_restore_traps __autotune_fail 2>/dev/null || true
    if (( __autotune_interrupted != 0 ))
    then
        return "$__autotune_interrupted"
    fi
    [[ -n "$best_combo" ]]
}

# ---------------------------------------------------------------------------
# __model_autotune_help
# @description Print detailed help for model autotune.
# @returns 0 always.
# ---------------------------------------------------------------------------
function __model_autotune_help() {
    echo "Usage: model autotune <N> [--backend native|python] [--quick] [--ctx-size N] [--trials N]"
    echo ""
    echo "Objective priority:"
    echo "  1) no OOM"
    echo "  2) maximum context"
    echo "  3) maximum TPS"
    echo ""
    echo "What it does:"
    echo "  - Sweeps safe runtime configs (batch/ubatch/parallel/fit)"
    echo "  - Uses median TPS with jitter-aware scoring"
    echo "  - Saves winner directly into models.conf tuning columns"
    echo "  - model scan/model list will show 'pending' until a profile exists"
    echo ""
    echo "Common options:"
    echo "  --backend native|python   Select llama backend (default from env)"
    echo "  --quick                   Reduced sweep for faster tuning"
    echo "  --ctx-size N              Force one context value"
    echo "  --trials N                Number of burn trials per config"
    echo "  -h, --help                Show this help"
    echo ""
    echo "Key environment knobs:"
    echo "  LLM_AUTOTUNE_CTX_STRATEGY, LLM_AUTOTUNE_MAX_CTX, LLM_AUTOTUNE_CTX_STEP"
    echo "  LLM_AUTOTUNE_JITTER_PENALTY, LLM_AUTOTUNE_EARLY_STOP_MARGIN"
    echo "  LLM_AUTOTUNE_WARMUP, LLM_AUTOTUNE_CONFIRM_FINAL"
    echo "  LLM_AUTOTUNE_LOCK_FILE, LLM_AUTOTUNE_LOCK_WAIT_SECONDS"
    echo ""
    echo "Examples:"
    echo "  model autotune 3 --backend native --quick --trials 1"
    echo "  model autotune 7 --ctx-size 8192 --trials 3"
    return 0
}

# ---------------------------------------------------------------------------
# __model_stop
# @description Stop the running llama-server process and clear active model state.
# @returns 0 always.
# ---------------------------------------------------------------------------
function __model_stop() {
    __llm_server_stop
    # Kill any lingering stdin keeper processes (sleep-loop bash children)
    # that were orphaned when llama-server was killed.
    local _keeper_pid
    for _keeper_file in /tmp/llm-keeper.*.pid
    do
        [[ -f "$_keeper_file" ]] || continue
        _keeper_pid=$(< "$_keeper_file")
        if [[ "$_keeper_pid" =~ ^[0-9]+$ ]]
        then
            kill -TERM "$_keeper_pid" 2>/dev/null || true
        fi
        rm -f "$_keeper_file"
    done
    # Kill the model subshell (the `( ... ) & disown` wrapper from __model_use)
    # and its entire process tree (inner bash, stdin keeper, any children).
    # We kill children before the parent to prevent reparenting to init.
    local _ms_pid _ms_child _ms_depth
    # Kill ALL model subshells from any PID file.
    # We read all /tmp/llm-modelshell.*.pid files (including caller-specific
    # and legacy) and kill every subshell tree found. This handles stale PID
    # files from overlapping/previous runs.
    for _ms_kf in /tmp/llm-modelshell.*.pid /tmp/llm-modelshell.pid
    do
        [[ -f "$_ms_kf" ]] || continue
        _ms_pid=$(< "$_ms_kf")
        rm -f "$_ms_kf"
        [[ "$_ms_pid" =~ ^[0-9]+$ ]] || continue
        # Kill child tree recursively (up to 4 levels)
        for ((_ms_depth=0; _ms_depth<4; _ms_depth++))
        do
            for _ms_child in $(pgrep -P "$_ms_pid" 2>/dev/null || true)
            do
                kill -KILL "$_ms_child" 2>/dev/null || true
            done
        done
        # Kill the parent subshell
        kill -KILL "$_ms_pid" 2>/dev/null || true
    done
    # Kill any sleep 3600 keepers reparented to init
    for _ms_child in $(pgrep -P 1 -f 'sleep 3600' 2>/dev/null || true)
    do
        kill -KILL "$_ms_child" 2>/dev/null || true
    done

    rm -f "$ACTIVE_LLM_FILE"
    __llm_registry_sync_state >/dev/null 2>&1 || true

    # ---- GPU memory reclamation ----
    # After killing llama-server, the CUDA driver may hold VRAM for a grace
    # period. We must wait for it to be released before the next model loads,
    # otherwise fragmented memory from the previous run causes OOM.
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
                _free_after=$(timeout 3 "$_smi" --query-gpu=memory.free --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ')
                [[ "$_free_after" =~ ^[0-9]+$ ]] || break
                (( _free_after <= _free_before )) && break
                _free_before="$_free_after"
                _mem_waited=$(( _mem_waited + 1 ))
            done
        fi
    fi
    __tac_info "Llama Server" "[STOPPED]" "$C_Success"
    return 0
}

# ---------------------------------------------------------------------------
# __model_status
# @description Show the currently running model, health, TPS, and build information.
# @returns 0 always.
# ---------------------------------------------------------------------------
function __model_status() {
    local output_mode="human"
    case "${1:-}" in
        --json) output_mode="json" ;;
        --plain) output_mode="plain" ;;
    esac

    __llm_registry_sync_state >/dev/null 2>&1 || true

    if __llm_server_running && __test_port "$LLM_PORT"
    then
        local active_num=""
        [[ -f "$ACTIVE_LLM_FILE" ]] && active_num=$(< "$ACTIVE_LLM_FILE")
        local entry=""
        local name="" file="" size=""
        if [[ -n "$active_num" ]]
        then
            entry=$(__llm_active_entry 2>/dev/null || true)
        fi
        if [[ -n "$entry" ]]
        then
            local _n _rest
            IFS='|' read -r _n name file size _rest <<< "$entry"
        fi
        local health health_label health_color
        health=$(curl -s --max-time 2 "http://127.0.0.1:$LLM_PORT/health" 2>/dev/null || true)
        if __llm_is_healthy
        then
            health_label="OK"
            health_color="$C_Success"
        else
            health_label="${health:-UNHEALTHY}"
            health_color="$C_Warning"
        fi
        local tps
        tps=$(cat "$LLM_TPS_CACHE" 2>/dev/null) || true
        if [[ "$output_mode" == "json" ]]
        then
            printf '{'
            printf '"online":true,'
            printf '"port":%s,' "$LLM_PORT"
            printf '"active_num":"%s",' "$(__llm_json_escape "$active_num")"
            printf '"active_name":"%s",' "$(__llm_json_escape "$name")"
            printf '"active_file":"%s",' "$(__llm_json_escape "$file")"
            printf '"size":"%s",' "$(__llm_json_escape "$size")"
            printf '"health":"%s",' "$(__llm_json_escape "$health_label")"
            printf '"last_tps":"%s",' "$(__llm_json_escape "$tps")"
            printf '"build":"%s"' "$(__llm_json_escape "$LLAMA_BUILD_VERSION")"
            printf '}\n'
            return 0
        fi
        if [[ "$output_mode" == "plain" ]]
        then
            printf '%s\n' "online=1"
            printf '%s\n' "port=$LLM_PORT"
            printf '%s\n' "active_num=${active_num:-}"
            printf '%s\n' "active_name=${name:-}"
            printf '%s\n' "active_file=${file:-}"
            printf '%s\n' "size=${size:-}"
            printf '%s\n' "health=$health_label"
            printf '%s\n' "last_tps=${tps:-}"
            printf '%s\n' "build=$LLAMA_BUILD_VERSION"
            return 0
        fi
        if [[ -n "$entry" ]]
        then
            __tac_info "Active" "#${active_num} ${name} (${size})" "$C_Success"
        else
            __tac_info "Active" "[Running but unknown model]" "$C_Warning"
        fi
        __tac_info "Health" "$health_label" "$health_color"
        [[ -n "$tps" ]] && __tac_info "Last TPS" "$tps" "$C_Dim"
        __tac_info "Build" "$LLAMA_BUILD_VERSION" "$C_Dim"
        return 0
    fi

    if [[ "$output_mode" == "json" ]]
    then
        printf '{"online":false,"port":%s,"health":"OFFLINE","build":"%s"}\n' \
            "$LLM_PORT" "$(__llm_json_escape "$LLAMA_BUILD_VERSION")"
        return 0
    fi
    if [[ "$output_mode" == "plain" ]]
    then
        printf '%s\n' "online=0"
        printf '%s\n' "port=$LLM_PORT"
        printf '%s\n' "health=OFFLINE"
        printf '%s\n' "build=$LLAMA_BUILD_VERSION"
        return 0
    fi
    __tac_info "Status" "[OFFLINE]" "$C_Dim"
    return 0
}

# ---------------------------------------------------------------------------
# __model_info
# @description Print detailed registry metadata for one model.
# @returns 0 on success, 1 if the target is invalid or missing.
# ---------------------------------------------------------------------------
function __model_info() {
    local target="${1:-}"
    if [[ -z "$target" ]]
    then
        __tac_info "Usage" "[model info <number>]" "$C_Error"
        return 1
    fi
    if [[ ! "$target" =~ ^[0-9]+$ ]]
    then
        __tac_info "Error" "[Not a number: '$target']" "$C_Error"
        return 1
    fi
    local entry
    entry=$(__llm_registry_entry_by_num "$target")
    if [[ -z "$entry" ]]
    then
        __tac_info "Error" "[Model #$target not found]" "$C_Error"
        return 1
    fi
    local num name file size quant_cache arch gpu_layers ctx threads batch ubatch parallel fit_target_mb backend mmap_mode tps autotuned is_default in_vram
    IFS='|' read -r num name file size quant_cache arch gpu_layers ctx threads batch ubatch parallel fit_target_mb backend mmap_mode tps autotuned is_default in_vram <<< "$entry"

    # Explicitly print every models.conf field so schema visibility is complete.
    __tac_info "#" "$num" "$C_Highlight"
    __tac_info "name" "$name" "$C_Success"
    __tac_info "file" "$file" "$C_Text"
    __tac_info "size_gb" "$size" "$C_Text"
    __tac_info "quant_cache" "$quant_cache" "$C_Text"
    __tac_info "arch" "$arch" "$C_Text"
    __tac_info "gpu_layers" "$gpu_layers" "$C_Highlight"
    __tac_info "ctx" "$ctx" "$C_Text"
    __tac_info "threads" "$threads" "$C_Text"
    __tac_info "batch" "$batch" "$C_Text"
    __tac_info "ubatch" "$ubatch" "$C_Text"
    __tac_info "parallel" "$parallel" "$C_Text"
    __tac_info "fit_target_mb" "$fit_target_mb" "$C_Text"
    __tac_info "backend" "$backend" "$C_Text"
    __tac_info "mmap_mode" "${mmap_mode:-auto}" "$C_Text"
    __tac_info "tps" "${tps:--}" "$C_Text"
    __tac_info "autotuned" "${autotuned:-no}" "$C_Text"
    __tac_info "is_default" "${is_default:-no}" "$C_Text"
    __tac_info "in_vram" "${in_vram:-no}" "$C_Text"
    if [[ -f "$LLAMA_MODEL_DIR/$file" ]]
    then
        __tac_info "On Disk" "[FOUND]" "$C_Success"
    else
        __tac_info "On Disk" "[MISSING]" "$C_Error"
    fi
}

# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# __bench_run_with_timeout — Wrap a command with an overall timeout.
# Kills the entire process group if the timeout is exceeded, preventing runaway
# llama-server or sleep processes from accumulating.
# @usage  __bench_run_with_timeout <seconds> <command...>
# @returns 0 if command completes, 124 on timeout.
# ---------------------------------------------------------------------------
function __bench_run_with_timeout() {
    local timeout_s="$1"
    shift
    if (( $# == 0 ))
    then
        __tac_info "Bench" "[Timeout wrapper called without a command]" "$C_Error"
        return 2
    fi
    if [[ ! "$timeout_s" =~ ^[0-9]+$ ]] || (( timeout_s < 1 ))
    then
        timeout_s=120
    fi
    local _self_pgid=""
    _self_pgid=$(ps -o pgid= -p "$$" 2>/dev/null | tr -d ' ')

    local _is_shell_func=0
    if declare -F "$1" >/dev/null 2>&1
    then
        _is_shell_func=1
    fi

    if (( _is_shell_func == 1 ))
    then
        # Shell functions cannot be exec'd by setsid directly.
        # Run them in a dedicated shell process-group when available.
        if command -v setsid >/dev/null 2>&1
        then
            declare -fx "$1" 2>/dev/null || true
            setsid bash -lc "source \"\$1\" >/dev/null 2>&1 || true; shift; \"\$@\"" _ "$TACTICAL_PROFILE_PATH" "$@" &
        else
            "$@" &
        fi
    elif command -v setsid >/dev/null 2>&1
    then
        # Start command in a dedicated session/process-group when possible.
        setsid "$@" &
    else
        "$@" &
    fi

    local cmd_pid=$!
    __BENCH_TIMEOUT_LAST_PID="$cmd_pid"
    local cmd_pgid=""
    cmd_pgid=$(ps -o pgid= -p "$cmd_pid" 2>/dev/null | tr -d ' ')
    local waited=0
    local interval=1
    while (( waited < timeout_s ))
    do
        if ! kill -0 "$cmd_pid" 2>/dev/null
        then
            wait "$cmd_pid" 2>/dev/null
            return $?
        fi
        sleep "$interval"
        waited=$(( waited + interval ))
    done

    # Timeout — terminate whole spawned process-group when it is isolated.
    if [[ -n "$cmd_pgid" ]] && [[ "$cmd_pgid" =~ ^[0-9]+$ ]] && [[ -n "$_self_pgid" ]] && [[ "$cmd_pgid" != "$_self_pgid" ]]
    then
        kill -TERM -- "-$cmd_pgid" 2>/dev/null || true
    else
        kill -TERM -- "$cmd_pid" 2>/dev/null || true
    fi
    sleep 1

    if [[ -n "$cmd_pgid" ]] && [[ "$cmd_pgid" =~ ^[0-9]+$ ]] && [[ -n "$_self_pgid" ]] && [[ "$cmd_pgid" != "$_self_pgid" ]]
    then
        kill -KILL -- "-$cmd_pgid" 2>/dev/null || true
    else
        kill -KILL -- "$cmd_pid" 2>/dev/null || true
    fi
    wait "$cmd_pid" 2>/dev/null || true
    return 124
}

# __model_bench
# @description Benchmark on-disk models, save TPS results, and restore prior state.
# @returns 0 on success, 1 if the registry or benchmark candidates are unavailable.
# ---------------------------------------------------------------------------
function __model_bench() {
    if [[ ! -f "$LLM_REGISTRY" ]]
    then
        __tac_info "Registry" "[Not found - run 'model scan']" "$C_Error"
        return 1
    fi

    # ---------------------------------------------------------------------------
    # Singleton guard: PID file + flock with stale-process detection.
    # Prevents duplicate bench runs and cleans up after killed processes.
    # ---------------------------------------------------------------------------
    local bench_pid_file="${LLM_BENCH_PID_FILE:-/tmp/llm-bench.pid}"
    local bench_lock_file="${LLM_BENCH_LOCK_FILE:-/tmp/llm-bench.lock}"
    local bench_lock_wait_seconds="${LLM_BENCH_LOCK_WAIT_SECONDS:-5}"

    # Check for stale PID file (process that no longer exists)
    if [[ -f "$bench_pid_file" ]]
    then
        local old_pid
        old_pid=$(< "$bench_pid_file")
        if [[ -n "$old_pid" ]] && [[ "$old_pid" =~ ^[0-9]+$ ]]
        then
            if ! kill -0 "$old_pid" 2>/dev/null
            then
                __tac_info "Bench" "[Cleaning stale PID $old_pid from $bench_pid_file]" "$C_Warning"
                rm -f "$bench_pid_file" "$bench_lock_file"
            fi
        fi
    fi

    # Stale bench lock detection: if lock file exists but no one holds it, remove it.
    if [[ -f "$bench_lock_file" ]] && ! lsof "$bench_lock_file" >/dev/null 2>&1
    then
        __tac_info "Bench" "[Cleaning stale lock: $bench_lock_file]" "$C_Warning"
        rm -f "$bench_lock_file"
    fi

    local bench_lock_fd=""
    if command -v flock >/dev/null 2>&1
    then
        exec {bench_lock_fd}>"$bench_lock_file" || {
            __tac_info "Bench" "[Unable to open lock file: $bench_lock_file]" "$C_Error"
            return 1
        }
        if ! flock -w "$bench_lock_wait_seconds" "$bench_lock_fd"
        then
            __tac_info "Bench" "[Another bench run is already active (lock: $bench_lock_file)]" "$C_Error"
            exec {bench_lock_fd}>&-
            return 1
        fi
        # Write our PID to the lock (cooperative PID tracking)
        echo "$$" > "$bench_lock_file"
    fi

    # Write PID file for stale detection
    echo "$$" > "$bench_pid_file"

    # ---------------------------------------------------------------------------
    # Cleanup trap: kill orphan processes and remove guard files on exit.
    # Handles normal completion, SIGINT (Ctrl+C), and abrupt termination.
    # ---------------------------------------------------------------------------
    local bench_cleanup_spawned_pids=()
    local __bench_signal_rc=0
    local __bench_cleaned=0
    # shellcheck disable=SC2317  # called indirectly via trap
    __bench_cleanup() {
        if (( __bench_cleaned == 1 ))
        then
            return $?
        fi
        __bench_cleaned=1
        local exit_code=$?
        # Kill any subprocesses we spawned
        if (( ${#bench_cleanup_spawned_pids[@]} > 0 ))
        then
            kill "${bench_cleanup_spawned_pids[@]}" 2>/dev/null || true
        fi
        # On interrupt/termination, explicitly stop any active model server.
        if (( __bench_signal_rc != 0 ))
        then
            __model_stop >/dev/null 2>&1 || true
        fi
        # Remove guard files
        rm -f "$bench_pid_file"
        if [[ -n "$bench_lock_fd" ]]
        then
            flock -u "$bench_lock_fd" 2>/dev/null || true
            exec {bench_lock_fd}>&-
        fi
        rm -f "$bench_lock_file"
        return "$exit_code"
    }
    trap '__bench_cleanup' EXIT
    trap '__bench_signal_rc=130; __bench_cleanup; return 130' INT
    trap '__bench_signal_rc=143; __bench_cleanup; return 143' TERM

    # Kill any orphaned stdin keepers from prior runs before starting.
    # These accumulate if llama-server was killed without going through
    # __model_stop (e.g., OOM kill, system crash, SIGKILL).
    local _kp
    for _kf in /tmp/llm-keeper.*.pid
    do
        [[ -f "$_kf" ]] || continue
        _kp=$(< "$_kf")
        if [[ "$_kp" =~ ^[0-9]+$ ]]; then kill -TERM "$_kp" 2>/dev/null; fi
        rm -f "$_kf"
    done
    # Catch any orphan sleep loops that lost their PID file (e.g., from a
    # previous bench run that was SIGKILL'd). These show up as bash processes
    # holding open FIFOs — grep for the mkfifo pattern, not our own PID.
    local _my_pid=$$
    for _sp in $(pgrep -a bash 2>/dev/null | awk '/llm-stdin/{print $1}' || true)
    do
        if [[ "$_sp" =~ ^[0-9]+$ ]] && [[ "$_sp" != "$_my_pid" ]]; then kill -TERM "$_sp" 2>/dev/null; fi
    done

    __tac_header "MODEL BENCHMARK" "open"
    local bench_run_id
    bench_run_id=$(date +%Y%m%d_%H%M%S)
    local bench_log_dir="${TAC_CACHE_DIR:-/dev/shm}/llm-bench-logs/${bench_run_id}"
    mkdir -p "$bench_log_dir" 2>/dev/null

    local _bench_watchdog_was_active=0
    if systemctl --user is-active --quiet llama-watchdog.timer 2>/dev/null
    then
        _bench_watchdog_was_active=1
        systemctl --user stop llama-watchdog.timer 2>/dev/null
        __tac_info "Watchdog" "Suspended for bench (will restore)" "$C_Dim"
    fi

    local _bench_prev_model=""
    [[ -f "$ACTIVE_LLM_FILE" ]] && _bench_prev_model=$(< "$ACTIVE_LLM_FILE")
    local bench_backend=""
    bench_backend=$(__llm_backend_normalize "${LLM_SERVER_BACKEND:-native}")
    local bench_autotune_mode="${LLM_BENCH_AUTOTUNE_MODE:-quick}"
    local bench_autotune_trials="${LLM_BENCH_AUTOTUNE_TRIALS:-1}"
    [[ "$bench_autotune_trials" =~ ^[0-9]+$ ]] || bench_autotune_trials=1
    (( bench_autotune_trials < 1 )) && bench_autotune_trials=1

    local -a b_num=() b_name=() b_size=() b_gpu=() b_tps=()

    # shellcheck disable=SC2317  # invoked indirectly via timeout wrapper in child shell
    __bench_run_single_model() {
        local bench_num="$1"
        if ! __model_use "$bench_num"
        then
            return 2
        fi
        if ! burn
        then
            return 3
        fi
        return 0
    }
    local num name file size _quant_cache _arch gpu_layers _ctx _threads _batch _ubatch _parallel _fit _backend _mmap _tps _autotuned _is_default _in_vram
    while IFS='|' read -r num name file size _quant_cache _arch gpu_layers _ctx _threads _batch _ubatch _parallel _fit _backend _mmap _tps _autotuned _is_default _in_vram
    do
        [[ "$num" == "#" || -z "$num" ]] && continue
        [[ ! -f "$LLAMA_MODEL_DIR/$file" ]] && continue
        b_num+=("$num")
        b_name+=("$name")
        b_size+=("$size")
        b_gpu+=("${gpu_layers:-0}")
    done < "$LLM_REGISTRY"

    if (( ${#b_num[@]} == 0 ))
    then
        __tac_info "Bench" "[No on-disk models]" "$C_Warning"
        if (( _bench_watchdog_was_active ))
        then
            systemctl --user start llama-watchdog.timer 2>/dev/null
            __tac_info "Watchdog" "Restored" "$C_Dim"
        fi
        if [[ -n "$bench_lock_fd" ]]
        then
            flock -u "$bench_lock_fd" 2>/dev/null || true
            exec {bench_lock_fd}>&-
        fi
        return 1
    fi

    wake 2>/dev/null || true
    __llm_bench_perf_prep
    printf '%s\n\n' "${C_Dim}Benchmarking ${#b_num[@]} model(s)...${C_Reset}"

    local __BENCH_MODE=1
    local i
    for i in "${!b_num[@]}"
    do
        printf '%s\n' "${C_Highlight}[$(( i+1 ))/${#b_num[@]}] ${b_name[$i]} (${b_size[$i]})${C_Reset}"

        local _bench_safe_overrides=0
        local _bench_min_free_vram_mb="${LLM_BENCH_MIN_FREE_VRAM_MB:-1200}"
        local _bench_safe_ctx="${LLM_BENCH_SAFE_CTX:-8192}"
        local _bench_free_vram_mb=0
        local _bench_smi
        _bench_smi=$(__resolve_smi 2>/dev/null || true)
        if [[ -n "$_bench_smi" ]]
        then
            _bench_free_vram_mb=$("$_bench_smi" --query-gpu=memory.free --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ')
        fi
        [[ "$_bench_min_free_vram_mb" =~ ^[0-9]+$ ]] || _bench_min_free_vram_mb=256
        [[ "$_bench_safe_ctx" =~ ^[0-9]+$ ]] || _bench_safe_ctx=8192
        [[ "$_bench_free_vram_mb" =~ ^[0-9]+$ ]] || _bench_free_vram_mb=0

        if (( _bench_free_vram_mb > 0 && _bench_free_vram_mb < _bench_min_free_vram_mb ))
        then
            export LLAMA_GPU_LAYERS=0
            export LLM_IGNORE_AUTOTUNE_PROFILE=1
            export TAC_CTX_SIZE="$_bench_safe_ctx"
            export LLAMA_BATCH_SIZE=512
            export LLAMA_UBATCH_SIZE=128
            export LLAMA_PARALLEL_SLOTS=1
            _bench_safe_overrides=1
            __tac_info "Bench" "[Low free VRAM (${_bench_free_vram_mb} MiB) - applying safe overrides: ngl=0, ctx=${_bench_safe_ctx}, b=512/128, p=1]" "$C_Warning"
        fi

        # Auto-autotune only if this model/backend has never been autotuned.
        if ! __llm_autotune_done_for_model "${b_num[$i]}"
        then
            __tac_info "Bench" "[No prior autotune flag for model #${b_num[$i]} - running autotune first]" "$C_Warning"
            __tac_info "Bench" "[Autotune mode=${bench_autotune_mode}, trials=${bench_autotune_trials}]" "$C_Dim"
            export LLM_AUTOTUNE_RESTORE_PREV=0
            export LLM_AUTOTUNE_SKIP_LOCK=1
            local -a _bench_autotune_args=("--backend" "$bench_backend" "--trials" "$bench_autotune_trials")
            if [[ "$bench_autotune_mode" == "quick" ]]
            then
                _bench_autotune_args+=("--quick")
            fi
            if ! __model_autotune "${b_num[$i]}" "${_bench_autotune_args[@]}"
            then
                unset LLM_AUTOTUNE_RESTORE_PREV
                unset LLM_AUTOTUNE_SKIP_LOCK
                __tac_info "Bench" "[Autotune failed for model #${b_num[$i]} - skipping benchmark]" "$C_Error"
                b_tps+=("FAIL_AUTOTUNE")
                __model_stop 2>/dev/null || true
                sleep 1
                continue
            fi
            unset LLM_AUTOTUNE_RESTORE_PREV
            unset LLM_AUTOTUNE_SKIP_LOCK
        fi

        rm -f "$LLM_TPS_CACHE"
        # Timeout guard: force-bound full model run (__model_use + burn).
        local bench_model_timeout="${LLM_BENCH_MODEL_TIMEOUT:-300}"
        local bench_model_rc=0
        __bench_run_with_timeout "$bench_model_timeout" __bench_run_single_model "${b_num[$i]}"
        bench_model_rc=$?
        if [[ "${__BENCH_TIMEOUT_LAST_PID:-}" =~ ^[0-9]+$ ]]
        then
            bench_cleanup_spawned_pids+=("$__BENCH_TIMEOUT_LAST_PID")
        fi
        if (( bench_model_rc == 124 ))
        then
            __tac_info "Bench" "[Timed out after ${bench_model_timeout}s for model #${b_num[$i]} (__model_use + burn)]" "$C_Error"
        elif (( bench_model_rc == 2 ))
        then
            local bench_ready_timeout
            bench_ready_timeout=$(__llm_health_timeout "${b_size[$i]}" "${b_gpu[$i]}" "${b_name[$i]}")
            __tac_info "Bench" "[Model did not reach healthy state in ${bench_ready_timeout}s]" "$C_Error"
        elif (( bench_model_rc == 3 ))
        then
            __tac_info "Bench" "[Burn failed for model #${b_num[$i]}]" "$C_Error"
        elif (( bench_model_rc != 0 ))
        then
            __tac_info "Bench" "[Model run failed for model #${b_num[$i]} (rc=${bench_model_rc})]" "$C_Error"
        fi
        if [[ -f "$LLM_LOG_FILE" ]]
        then
            cp "$LLM_LOG_FILE" "$bench_log_dir/${b_num[$i]}_${b_name[$i]//[^A-Za-z0-9._-]/_}.log" 2>/dev/null
        fi
        local tps="FAIL"
        [[ -f "$LLM_TPS_CACHE" ]] && tps=$(< "$LLM_TPS_CACHE")
        b_tps+=("$tps")
        __model_stop 2>/dev/null
        if (( _bench_safe_overrides == 1 ))
        then
            unset LLAMA_GPU_LAYERS LLM_IGNORE_AUTOTUNE_PROFILE TAC_CTX_SIZE LLAMA_BATCH_SIZE LLAMA_UBATCH_SIZE LLAMA_PARALLEL_SLOTS
        fi
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
    {
        printf "#\tmodel\tsize\ttps\n"
        for i in "${!b_num[@]}"
        do
            printf "%s\t%s\t%s\t%s\n" \
                "${b_num[$i]}" "${b_name[$i]}" "${b_size[$i]}" "${b_tps[$i]}"
        done
    } > "$bench_file"
    __tac_info "Saved" "$bench_file" "$C_Dim"
    __tac_info "Bench Logs" "$bench_log_dir" "$C_Dim"

    if [[ -n "$_bench_prev_model" ]]
    then
        __tac_info "Restoring" "Model #${_bench_prev_model}" "$C_Dim"
        __model_use "$_bench_prev_model" 2>/dev/null
    fi

    if (( _bench_watchdog_was_active ))
    then
        systemctl --user start llama-watchdog.timer 2>/dev/null
        __tac_info "Watchdog" "Restored" "$C_Dim"
    fi
    if [[ -n "$bench_lock_fd" ]]
    then
        flock -u "$bench_lock_fd" 2>/dev/null || true
        exec {bench_lock_fd}>&-
    fi
    __tac_footer
}

# ---------------------------------------------------------------------------
# __model_bench_diff
# @description Compare two benchmark TSV files and print throughput deltas.
# @returns 0 on success, 1 if the bench files cannot be resolved.
# ---------------------------------------------------------------------------
function __model_bench_diff() {
    local diff_files old_bench new_bench
    diff_files=$(__bench_resolve_files "$@") || {
        __tac_info "Usage" "[model bench-diff [old.tsv new.tsv]]" "$C_Error"
        __tac_info "Hint" "Need two bench TSVs in $LLAMA_DRIVE_ROOT/.llm" "$C_Dim"
        return 1
    }
    IFS='|' read -r old_bench new_bench <<< "$diff_files"

    if [[ ! -f "$old_bench" || ! -f "$new_bench" ]]
    then
        __tac_info "Error" "[Bench file missing]" "$C_Error"
        return 1
    fi

    __tac_header "MODEL BENCH DIFF" "open"
    __tac_info "Old" "$old_bench" "$C_Dim"
    __tac_info "New" "$new_bench" "$C_Dim"
    echo ""
    printf "${C_Dim}  %-30s %-8s %-8s %-8s %s${C_Reset}\n" "MODEL" "OLD" "NEW" "DELTA" "TREND"
    local _diff_rule
    printf -v _diff_rule '%*s' $((UIWidth - 4)) ''
    _diff_rule="${_diff_rule// /${BOX_SL}}"
    printf "${C_Dim}  %s${C_Reset}\n" "$_diff_rule"

    awk -F'\t' '
        function tps_num(raw, val) {
            val = raw
            gsub(/ tps/, "", val)
            return val + 0
        }
        FNR == NR {
            if ($1 == "#" || $2 == "model") next
            old[$2] = tps_num($4)
            next
        }
        {
            if ($1 == "#" || $2 == "model") next
            model = $2
            newv = tps_num($4)
            oldv = ((model in old) ? old[model] : 0)
            delta = newv - oldv
            pct = (oldv > 0 ? (delta * 100.0 / oldv) : 0)
            trend = (delta > 0.05 ? "UP" : (delta < -0.05 ? "DOWN" : "FLAT"))
            printf "  %-30s %-8.1f %-8.1f %+7.1f %s (%+.1f%%)\n", model, oldv, newv, delta, trend, pct
        }
    ' "$old_bench" "$new_bench"
    __tac_footer
}

# ---------------------------------------------------------------------------
# __model_bench_latest
# @description Show the most recent benchmark TSV summary.
# @returns 0 on success, 1 if no benchmark TSV exists.
# ---------------------------------------------------------------------------
function __model_bench_latest() {
    local latest_bench
    latest_bench=$(__bench_latest_file)
    if [[ -z "$latest_bench" || ! -f "$latest_bench" ]]
    then
        __tac_info "Bench" "[No benchmark TSV found]" "$C_Error"
        return 1
    fi
    __tac_header "LATEST BENCH" "open"
    __tac_info "File" "$latest_bench" "$C_Dim"
    echo ""
    awk -F'\t' '
        $1 == "#" || $2 == "model" { next }
        { printf "  %-4s %-30s %-7s %s\n", $1, $2, $3, $4 }
    ' "$latest_bench"
    __tac_footer
}

# ---------------------------------------------------------------------------
# __model_bench_history
# @description Summarise recent benchmark TSV files so throughput trends are visible at a glance.
# @returns 0 on success, 1 if no benchmark TSV exists.
# ---------------------------------------------------------------------------
function __model_bench_history() {
    local limit="${1:-5}"
    [[ "$limit" =~ ^[0-9]+$ ]] || limit=5

    local -a bench_files=()
    while IFS= read -r bench_file
    do
        bench_files+=("$bench_file")
    done < <(find "$LLAMA_DRIVE_ROOT/.llm" -maxdepth 1 -name 'bench_*.tsv' -type f \
        -printf '%T@ %p\n' 2>/dev/null | sort -n -r | head -n "$limit" | cut -d' ' -f2-)

    if (( ${#bench_files[@]} == 0 ))
    then
        __tac_info "Bench" "[No benchmark TSV found]" "$C_Error"
        return 1
    fi

    __tac_header "BENCH HISTORY" "open"
    printf "${C_Dim}  %-20s %-6s %-28s %s${C_Reset}\n" "RUN" "MODELS" "BEST MODEL" "AVG TPS"
    local _hist_rule
    printf -v _hist_rule '%*s' $((UIWidth - 4)) ''
    _hist_rule="${_hist_rule// /${BOX_SL}}"
    printf "${C_Dim}  %s${C_Reset}\n" "$_hist_rule"

    local bench_file
    for bench_file in "${bench_files[@]}"
    do
        local bench_label
        bench_label=$(basename "$bench_file")
        bench_label="${bench_label#bench_}"
        bench_label="${bench_label%.tsv}"
        local summary
        summary=$(
            awk -F'\t' '
                function tps_num(raw, val) {
                    val = raw
                    gsub(/ tps/, "", val)
                    return (val ~ /^[0-9.]+$/ ? val + 0 : -1)
                }
                $1 == "#" || $2 == "model" { next }
                {
                    t = tps_num($4)
                    total++
                    if (t >= 0) {
                        good++
                        sum += t
                        if (t > best_tps) {
                            best_tps = t
                            best_model = $2
                        }
                    }
                }
                END {
                    avg = (good > 0 ? sum / good : 0)
                    printf "%d|%s|%.1f", total, best_model, avg
                }
            ' "$bench_file"
        )
        local models_count best_model avg_tps
        IFS='|' read -r models_count best_model avg_tps <<< "$summary"
        [[ -z "$best_model" ]] && best_model="No valid TPS data"
        printf "  %-20s %-6s %-28s %s\n" \
            "$bench_label" "$models_count" "${best_model:0:28}" "${avg_tps} tps"
    done
    __tac_footer
}

# ---------------------------------------------------------------------------
# __model_doctor
# @description Validate registry integrity, default model wiring, GPU visibility, watchdog state, and ports.
# @returns 0 on success, 1 if one or more checks fail.
# ---------------------------------------------------------------------------
function __model_doctor() {
    local output_mode="human"
    case "${1:-}" in
        --json) output_mode="json" ;;
        --plain) output_mode="plain" ;;
    esac

    local registry_exists=0
    local header_ok=0
    local numbering_ok=1
    local entries_total=0
    local missing_files=0
    local default_set=0
    local default_in_registry=0
    local gpu_visible=0
    local watchdog_active=0
    local port_listening=0
    local health_ok=0
    local active_known=0
    local issues=0
    local active_num="" active_name="" default_file=""

    if [[ -f "$LLM_REGISTRY" ]]
    then
        registry_exists=1
        local header_line
        header_line=$(head -1 "$LLM_REGISTRY" 2>/dev/null)
        [[ "$header_line" == "#|name|file|size_gb|quant_cache|arch|gpu_layers|ctx|threads|batch|ubatch|parallel|fit_target_mb|backend|mmap_mode|tps|autotuned|is_default|in_vram" ]] && header_ok=1

        local expected_num=1
        local num _name file _rest
        while IFS='|' read -r num _name file _rest
        do
            [[ "$num" == "#" || -z "$num" ]] && continue
            ((entries_total++))
            [[ "$num" == "$expected_num" ]] || numbering_ok=0
            [[ -f "$LLAMA_MODEL_DIR/$file" ]] || ((missing_files++))
            ((expected_num++))
        done < "$LLM_REGISTRY"
    fi

    default_file=$(__llm_default_file 2>/dev/null || true)
    if [[ -n "$default_file" ]]
    then
        default_set=1
        __llm_registry_entry_by_file "$default_file" >/dev/null && default_in_registry=1
    fi

    if command -v systemctl >/dev/null 2>&1 \
        && systemctl --user is-active --quiet llama-watchdog.timer 2>/dev/null
    then
        watchdog_active=1
    fi

    if __resolve_smi >/dev/null 2>&1
    then
        gpu_visible=1
    fi

    if __test_port "$LLM_PORT"
    then
        port_listening=1
        if __llm_is_healthy
        then
            health_ok=1
        fi
    fi

    local active_entry=""
    if [[ -f "$ACTIVE_LLM_FILE" ]]
    then
        active_num=$(< "$ACTIVE_LLM_FILE")
        active_entry=$(__llm_active_entry 2>/dev/null || true)
        if [[ -n "$active_entry" ]]
        then
            active_known=1
            IFS='|' read -r _ active_name _ <<< "$active_entry"
        fi
    fi

    (( registry_exists )) || ((issues++))
    (( header_ok )) || ((issues++))
    (( numbering_ok )) || ((issues++))
    (( missing_files == 0 )) || ((issues++))
    (( default_set )) || ((issues++))
    (( default_in_registry )) || ((issues++))
    (( gpu_visible )) || ((issues++))

    if [[ "$output_mode" == "json" ]]
    then
        printf '{'
        printf '"registry_exists":%s,' "$([[ $registry_exists -eq 1 ]] && echo true || echo false)"
        printf '"header_ok":%s,' "$([[ $header_ok -eq 1 ]] && echo true || echo false)"
        printf '"numbering_ok":%s,' "$([[ $numbering_ok -eq 1 ]] && echo true || echo false)"
        printf '"entries_total":%s,' "$entries_total"
        printf '"missing_files":%s,' "$missing_files"
        printf '"default_set":%s,' "$([[ $default_set -eq 1 ]] && echo true || echo false)"
        printf '"default_in_registry":%s,' "$([[ $default_in_registry -eq 1 ]] && echo true || echo false)"
        printf '"default_file":"%s",' "$(__llm_json_escape "$default_file")"
        printf '"gpu_visible":%s,' "$([[ $gpu_visible -eq 1 ]] && echo true || echo false)"
        printf '"watchdog_active":%s,' "$([[ $watchdog_active -eq 1 ]] && echo true || echo false)"
        printf '"port_listening":%s,' "$([[ $port_listening -eq 1 ]] && echo true || echo false)"
        printf '"health_ok":%s,' "$([[ $health_ok -eq 1 ]] && echo true || echo false)"
        printf '"active_num":"%s",' "$(__llm_json_escape "$active_num")"
        printf '"active_name":"%s",' "$(__llm_json_escape "$active_name")"
        printf '"issues":%s' "$issues"
        printf '}\n'
        (( issues == 0 ))
        return
    fi

    if [[ "$output_mode" == "plain" ]]
    then
        printf '%s\n' "registry_exists=$registry_exists"
        printf '%s\n' "header_ok=$header_ok"
        printf '%s\n' "numbering_ok=$numbering_ok"
        printf '%s\n' "entries_total=$entries_total"
        printf '%s\n' "missing_files=$missing_files"
        printf '%s\n' "default_set=$default_set"
        printf '%s\n' "default_in_registry=$default_in_registry"
        printf '%s\n' "default_file=$default_file"
        printf '%s\n' "gpu_visible=$gpu_visible"
        printf '%s\n' "watchdog_active=$watchdog_active"
        printf '%s\n' "port_listening=$port_listening"
        printf '%s\n' "health_ok=$health_ok"
        printf '%s\n' "active_num=$active_num"
        printf '%s\n' "active_name=$active_name"
        printf '%s\n' "issues=$issues"
        (( issues == 0 ))
        return
    fi

    __tac_header "MODEL DOCTOR" "open"
    __tac_info "Registry" "[$([[ $registry_exists -eq 1 ]] && echo FOUND || echo MISSING)]" \
        "$([[ $registry_exists -eq 1 ]] && printf '%s' "$C_Success" || printf '%s' "$C_Error")"
    __tac_info "Registry Header" "[$([[ $header_ok -eq 1 ]] && echo OK || echo BAD)]" \
        "$([[ $header_ok -eq 1 ]] && printf '%s' "$C_Success" || printf '%s' "$C_Error")"
    __tac_info "Registry Numbering" "[$([[ $numbering_ok -eq 1 ]] && echo OK || echo GAP_OR_DUPLICATE)]" \
        "$([[ $numbering_ok -eq 1 ]] && printf '%s' "$C_Success" || printf '%s' "$C_Error")"
    __tac_info "Missing Files" "[$missing_files]" \
        "$([[ $missing_files -eq 0 ]] && printf '%s' "$C_Success" || printf '%s' "$C_Error")"
    __tac_info "Default Model" "[$([[ $default_set -eq 1 ]] && echo "$default_file" || echo NONE_SET)]" \
        "$([[ $default_set -eq 1 ]] && printf '%s' "$C_Success" || printf '%s' "$C_Error")"
    __tac_info "Default In Registry" "[$([[ $default_in_registry -eq 1 ]] && echo YES || echo NO)]" \
        "$([[ $default_in_registry -eq 1 ]] && printf '%s' "$C_Success" || printf '%s' "$C_Error")"
    __tac_info "CUDA Visibility" "[$([[ $gpu_visible -eq 1 ]] && echo READY || echo OFFLINE)]" \
        "$([[ $gpu_visible -eq 1 ]] && printf '%s' "$C_Success" || printf '%s' "$C_Error")"
    __tac_info "Watchdog" "[$([[ $watchdog_active -eq 1 ]] && echo ACTIVE || echo INACTIVE)]" \
        "$([[ $watchdog_active -eq 1 ]] && printf '%s' "$C_Success" || printf '%s' "$C_Dim")"
    __tac_info "LLM Port" "[$([[ $port_listening -eq 1 ]] && echo LISTENING || echo CLOSED)]" \
        "$([[ $port_listening -eq 1 ]] && printf '%s' "$C_Success" || printf '%s' "$C_Dim")"
    __tac_info "Health" "[$([[ $health_ok -eq 1 ]] && echo OK || echo OFFLINE_OR_LOADING)]" \
        "$([[ $health_ok -eq 1 ]] && printf '%s' "$C_Success" || printf '%s' "$C_Warning")"
    if [[ -n "$active_num" ]]
    then
        __tac_info "Active Model" "[#${active_num} ${active_name:-unknown}]" \
            "$([[ $active_known -eq 1 ]] && printf '%s' "$C_Success" || printf '%s' "$C_Warning")"
    fi
    __tac_info "Summary" "[$issues issue(s)]" \
        "$([[ $issues -eq 0 ]] && printf '%s' "$C_Success" || printf '%s' "$C_Warning")"
    __tac_footer
    (( issues == 0 ))
}

# ---------------------------------------------------------------------------
# __model_recommend
# @description Rank on-disk models for a 4 GB VRAM system using quant, size, architecture, and TPS.
# @returns 0 on success, 1 if the registry is unavailable or empty.
# ---------------------------------------------------------------------------
function __model_recommend() {
    if [[ ! -f "$LLM_REGISTRY" ]]
    then
        __tac_info "Registry" "[Not found - run 'model scan' first]" "$C_Error"
        return 1
    fi

    local -a ranked=()
    local num name file size quant_cache arch gpu_layers ctx threads batch ubatch parallel fit_target_mb backend mmap_mode tps autotuned is_default in_vram
    while IFS='|' read -r num name file size quant_cache arch gpu_layers ctx threads batch ubatch parallel fit_target_mb backend mmap_mode tps autotuned is_default in_vram
    do
        [[ "$num" == "#" || -z "$num" ]] && continue
        [[ -f "$LLAMA_MODEL_DIR/$file" ]] || continue

        local score=0
        local rating tps_num size_tenths=0
        rating=$(__llm_quant_rating "$file")
        tps_num=$(__llm_tps_number "$tps")

        case "$rating" in
            recommended) score=$(( score + 35 )) ;;
            acceptable)  score=$(( score + 20 )) ;;
            discouraged) score=$(( score - 20 )) ;;
            *)           score=$(( score + 10 )) ;;
        esac

        if [[ "$size" =~ ^([0-9]+)(\.([0-9]))?G$ ]]
        then
            size_tenths=$(( BASH_REMATCH[1] * 10 + ${BASH_REMATCH[3]:-0} ))
        fi
        if (( size_tenths <= 15 ))
        then
            score=$(( score + 25 ))
        elif (( size_tenths <= 25 ))
        then
            score=$(( score + 18 ))
        elif (( size_tenths <= 35 ))
        then
            score=$(( score + 8 ))
        else
            score=$(( score - 8 ))
        fi

        if (( gpu_layers > 0 ))
        then
            score=$(( score + 15 ))
        else
            score=$(( score - 12 ))
        fi

        if [[ "$arch" == *"moe"* ]]
        then
            score=$(( score + 6 ))
        elif [[ "$arch" == "qwen3" || "$arch" == "qwen2" || "$arch" == "llama" ]]
        then
            score=$(( score + 4 ))
        elif [[ "$arch" == gemma* ]]
        then
            score=$(( score + 2 ))
        fi

        local tps_floor=${tps_num%.*}
        [[ "$tps_floor" =~ ^[0-9]+$ ]] || tps_floor=0
        (( tps_floor > 20 )) && tps_floor=20
        score=$(( score + tps_floor ))

        ranked+=("$(printf '%04d|%s|%s|%s|%s|%s|%s|%s\n' \
            "$score" "$num" "$name" "$size" "$quant_cache" "$arch" "$tps_num" "$rating")")
    done < "$LLM_REGISTRY"

    if (( ${#ranked[@]} == 0 ))
    then
        __tac_info "Recommend" "[No on-disk models in registry]" "$C_Error"
        return 1
    fi

    __tac_header "MODEL RECOMMENDATIONS" "open"
    printf "${C_Dim}  %-4s %-28s %-7s %-8s %-9s %-7s %s${C_Reset}\n" \
        "#" "MODEL" "SIZE" "QUANT" "ARCH" "TPS" "SCORE"
    local _rec_rule
    printf -v _rec_rule '%*s' $((UIWidth - 4)) ''
    _rec_rule="${_rec_rule// /${BOX_SL}}"
    printf "${C_Dim}  %s${C_Reset}\n" "$_rec_rule"

    mapfile -t ranked < <(printf '%s\n' "${ranked[@]}" | sort -r)
    local entry
    for entry in "${ranked[@]}"
    do
        [[ -z "$entry" ]] && continue
        local score_padded rec_num rec_name rec_size rec_quant rec_arch rec_tps rec_rating
        IFS='|' read -r score_padded rec_num rec_name rec_size rec_quant rec_arch rec_tps rec_rating <<< "$entry"
        local score_display="$score_padded"
        if [[ "$score_padded" =~ ^-[0-9]+$ ]]
        then
            score_display=$(( -10#${score_padded#-} ))
        elif [[ "$score_padded" =~ ^[0-9]+$ ]]
        then
            score_display=$((10#$score_padded))
        fi
        printf "  %-4s %-28s %-7s %-8s %-9s %-7s %s (%s)\n" \
            "$rec_num" "${rec_name:0:28}" "$rec_size" "$rec_quant" "${rec_arch:0:9}" \
            "${rec_tps}t/s" "$score_display" "$rec_rating"
    done
    __tac_footer
}

# ---------------------------------------------------------------------------
# __model_delete
# @description Delete a model from disk and renumber the registry after confirmation.
# @returns 0 on success or cancellation, 1 if validation or deletion fails.
# ---------------------------------------------------------------------------
function __model_delete() {
    local dry_run=0
    local target=""
    while (( $# > 0 ))
    do
        case "$1" in
            --dry-run|-n) dry_run=1 ;;
            *) target="${1:-}" ;;
        esac
        shift
    done
    if [[ -z "$target" ]]
    then
        __tac_info "Usage" "[model delete [--dry-run] <number>]" "$C_Error"
        return 1
    fi
    if [[ ! "$target" =~ ^[0-9]+$ ]]
    then
        __tac_info "Error" "[Not a number: '$target']" "$C_Error"
        return 1
    fi
    local entry
    entry=$(__llm_registry_entry_by_num "$target")
    if [[ -z "$entry" ]]
    then
        __tac_info "Error" "[Model #$target not found]" "$C_Error"
        return 1
    fi
    local _n name file _rest
    IFS='|' read -r _n name file _rest <<< "$entry"
    local fpath="$LLAMA_MODEL_DIR/$file"

    local _del_def_file=""
    _del_def_file=$(__llm_default_file 2>/dev/null || true)
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
    if (( dry_run ))
    then
        __tac_info "Dry Run" "[Would delete file and renumber registry only]" "$C_Warning"
        return 0
    fi
    local confirm
    read -r -p "${C_Warning}Permanently delete this model? [y/N]: ${C_Reset}" confirm
    if [[ "${confirm,,}" != "y" ]]
    then
        __tac_info "Delete" "[CANCELLED]" "$C_Dim"
        return 0
    fi

    local active_num
    active_num=$(cat "$ACTIVE_LLM_FILE" 2>/dev/null)
    if [[ "$target" == "$active_num" ]]
    then
        __model_stop
    fi

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

    local remaining
    remaining=$(__renumber_registry "$target")
    __tac_info "Registry" "[Removed and renumbered - ${remaining} models remain]" "$C_Success"
}

# ---------------------------------------------------------------------------
# __model_download
# @description Download one or more GGUF files from Hugging Face and rescan the registry.
# @returns 0 on success, 1 if validation or downloads fail.
# ---------------------------------------------------------------------------
function __model_download() {
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

    if ! command -v hf >/dev/null 2>&1
    then
        printf '%s\n' "${C_Error}Error:${C_Reset} 'hf' CLI not found." \
            "Install with: pip install huggingface_hub[cli]"
        return 1
    fi

    if [[ -z "${HF_TOKEN:-}" ]]
    then
        printf '%s\n' "${C_Warning}Note:${C_Reset} HF_TOKEN is not set. Gated or private repos will fail."
        printf '%s\n' "      Set it with: export HF_TOKEN=hf_..."
        echo ""
    fi

    export HF_HOME="${HF_HOME:-$HOME/hf_cache}"
    mkdir -p "$HF_HOME" "$LLAMA_MODEL_DIR"

    local ok=0
    local fail=0
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

        # Validate filename — prevent path traversal and non-GGUF files
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

        # Path traversal and format validation
        if [[ "$dl_file" == *"/"* || "$dl_file" == *".."* ]]
        then
            printf '%s\n' \
                "${C_Error}Error:${C_Reset} '$spec' - invalid filename (path traversal detected)"
            ((fail++))
            continue
        fi

        local dest="$LLAMA_MODEL_DIR/$dl_file"
        local archive_dest="$LLAMA_ARCHIVE_DIR/$dl_file"

        if [[ -f "$QUANT_GUIDE" ]]
        then
            local _qrating=""
            local _qdesc=""
            local _r _pat _d
            while IFS='|' read -r _r _pat _d
            do
                [[ -z "$_pat" || "$_r" == "#"* ]] && continue
                if [[ "${dl_file^^}" == *"${_pat^^}"* ]]
                then
                    _qrating="$_r"
                    _qdesc="$_d"
                    break
                fi
            done < "$QUANT_GUIDE"
            if [[ "$_qrating" == "discouraged" ]]
            then
                printf '%s\n' "${C_Warning}Warning:${C_Reset} ${_pat} is discouraged for 4GB VRAM - ${_qdesc}"
                local _qconfirm
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
    __model_scan
}

# ---------------------------------------------------------------------------
# __model_archive
# @description Move a model into the archive directory and renumber the registry.
# @returns 0 on success or cancellation, 1 if validation or move fails.
# ---------------------------------------------------------------------------
function __model_archive() {
    local dry_run=0
    local target=""
    while (( $# > 0 ))
    do
        case "$1" in
            --dry-run|-n) dry_run=1 ;;
            *) target="${1:-}" ;;
        esac
        shift
    done
    if [[ -z "$target" ]]
    then
        __tac_info "Usage" "[model archive [--dry-run] <number>]" "$C_Error"
        return 1
    fi
    if [[ ! "$target" =~ ^[0-9]+$ ]]
    then
        __tac_info "Error" "[Not a number: '$target']" "$C_Error"
        return 1
    fi
    local entry
    entry=$(__llm_registry_entry_by_num "$target")
    if [[ -z "$entry" ]]
    then
        __tac_info "Error" "[Model #$target not found]" "$C_Error"
        return 1
    fi
    local _n name file _rest
    IFS='|' read -r _n name file _rest <<< "$entry"
    local fpath="$LLAMA_MODEL_DIR/$file"
    local archive_dir="$LLAMA_ARCHIVE_DIR"

    local _arc_def_file=""
    _arc_def_file=$(__llm_default_file 2>/dev/null || true)
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
    if (( dry_run ))
    then
        __tac_info "Dry Run" "[Would move file and renumber registry only]" "$C_Warning"
        return 0
    fi
    local confirm
    read -r -p "${C_Warning}Archive this model? [y/N]: ${C_Reset}" confirm
    if [[ "${confirm,,}" != "y" ]]
    then
        __tac_info "Archive" "[CANCELLED]" "$C_Dim"
        return 0
    fi

    local active_num
    active_num=$(cat "$ACTIVE_LLM_FILE" 2>/dev/null)
    if [[ "$target" == "$active_num" ]]
    then
        __model_stop
    fi

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

    local remaining
    remaining=$(__renumber_registry "$target")
    __tac_info "Registry" "[Archived and renumbered - ${remaining} models remain]" "$C_Success"
}

# ---------------------------------------------------------------------------
# __model_usage
# @description Print the model command usage summary.
# @returns 0 always.
# ---------------------------------------------------------------------------
function __model_usage() {
    echo "Usage: model {scan|list|default|use|stop|status|doctor|recommend|info|bench|autotune|bench-diff|\
bench-compare|bench-latest|bench-history|delete|archive|download}"
    echo "  scan       - Scan $LLAMA_MODEL_DIR, read GGUF metadata, auto-calculate params"
    echo "  list       - Show numbered model registry (${PLAY_MARK} = active, * = default)"
    echo "  default [N] - Show current default LLM, or set it to model #N"
    echo "  use N [--ctx-size N] - Start model #N with optimal settings"
    echo "  stop       - Stop llama-server"
    echo "  status     - Show what's running (--json|--plain supported)"
    echo "  doctor     - Validate registry/default/GPU/watchdog/ports"
    echo "  recommend  - Rank scanned models for a 4GB VRAM system"
    echo "  info N     - Detailed info for model #N"
    echo "  bench      - Benchmark all on-disk models"
    echo "  autotune N [--backend native|python] [--quick] [--ctx-size N] [--trials N]"
    echo "             - Sweep safe runtime configs and save best profile for model #N"
    echo "  bench-diff - Compare the latest two bench TSVs (or pass old/new files)"
    echo "  bench-compare - Alias for bench-diff"
    echo "  bench-latest - Show the newest saved benchmark TSV"
    echo "  bench-history - Summarise recent saved benchmark TSV runs"
    echo "  delete N   - Permanently delete model #N from disk and registry (--dry-run)"
    echo "  archive N  - Move model #N to archive/ and remove from registry (--dry-run)"
    echo "  download   - Download GGUF models from Hugging Face (repo:file)"
    echo ""
    echo "Options:"
    echo "  --ctx-size N  Override context window (default from models.conf)"
    echo ""
    echo "Also: serve [--ctx-size N]  Start default LLM with optional context override"
    echo "      halt                  Stop the LLM server"
    return 0
}

# @extractable: model() is the largest function (~500 lines). When splitting
# into modules, extract it into its own file (e.g. ~/.bashrc.d/11-llm-model.sh)
# along with __renumber_registry, __quant_label, and __save_tps.
function model() {
    local action="${1:-}"
    (( $# > 0 )) && shift

    case "$action" in
        scan)
            __model_scan
            ;;

        list)
            __model_list "$@"
            ;;

        default)
            __model_default "${1:-}"
            ;;

        use)
            # Parse --ctx-size override from remaining args
            local _use_ctx=""
            local _use_num="${1:-}"
            shift 2>/dev/null || true
            while [[ $# -gt 0 ]]
            do
                case "$1" in
                    --ctx-size|--ctx)
                        _use_ctx="$2"
                        shift 2
                        ;;
                    *)
                        shift
                        ;;
                esac
            done
            if [[ -n "$_use_ctx" ]]
            then
                export TAC_CTX_SIZE="$_use_ctx"
            fi
            __model_use "$_use_num"
            ;;

        stop)
            __model_stop
            ;;

        status)
            __model_status "${1:-}"
            ;;

        doctor)
            __model_doctor "${1:-}"
            ;;

        recommend)
            __model_recommend
            ;;

        info)
            __model_info "${1:-}"
            ;;

        bench)
            __model_bench
            ;;

        autotune)
            __model_autotune "$@"
            ;;

        bench-diff)
            __model_bench_diff "$@"
            ;;

        bench-compare)
            __model_bench_diff "$@"
            ;;

        bench-latest)
            __model_bench_latest
            ;;

        bench-history)
            __model_bench_history "${1:-}"
            ;;

        delete)
            __model_delete "$@"
            ;;

        download)
            __model_download "$@"
            ;;

        archive)
            __model_archive "$@"
            ;;

        *)
            __model_usage
            ;;
    esac
}

# serve/halt/mlogs — convenience wrappers for the model manager.
# shellcheck disable=SC2034,SC2059,SC2120,SC2154
function serve() {
    # Parse optional --ctx-size override before passing to model use
    local ctx_override=""
    local model_arg=""
    while [[ $# -gt 0 ]]
    do
        case "$1" in
            --ctx-size|--ctx)
                ctx_override="$2"
                shift 2
                ;;
            -*)
                printf '%s\n' "${C_Error}[Unknown option: '$1']${C_Reset}"
                printf '%s\n' "  ${C_Dim}Usage: serve [MODEL_NUM] [--ctx-size N]${C_Reset}"
                return 1
                ;;
            *)
                model_arg="$1"
                shift
                ;;
        esac
    done

    # Export context size override so __model_use can pick it up
    if [[ -n "$ctx_override" ]]
    then
        if [[ ! "$ctx_override" =~ ^[0-9]+$ ]]
        then
            printf '%s\n' "${C_Error}[Not a number: '--ctx-size' = '$ctx_override']${C_Reset}"
            return 1
        fi
        export TAC_CTX_SIZE="$ctx_override"
    fi

    if [[ -n "$model_arg" ]]
    then
        model use "$model_arg"
    else
        # Start the default LLM
        local def_num
        def_num=$(__llm_default_number 2>/dev/null || true)
        if [[ -n "$def_num" ]]
        then
            model use "$def_num"
        else
            local def_file=""
            def_file=$(__llm_default_file 2>/dev/null || true)
            if [[ -n "$def_file" ]]
            then
                __tac_info "Local LLM" "[Default file not found in registry: $def_file]" "$C_Error"
            else
                __tac_info "Local LLM" "[NO DEFAULT SET]" "$C_Error"
                printf '%s\n' "  ${C_Dim}Run 'model default <N>' to configure one.${C_Reset}"
            fi
            return 1
        fi
    fi
}
# halt — Stop the currently running LLM model.
function halt() {
    model stop
}

# mlogs — Open the llama-server log file in VS Code.
# In read mode (TAC_READ_MODE=1): outputs log content instead.
function mlogs() {
    if [[ "${TAC_READ_MODE:-}" == "1" ]]
    then
        if [[ -f "$LLM_LOG_FILE" ]]
        then
            printf '%s\n' "=== $LLM_LOG_FILE ==="
            tail -100 "$LLM_LOG_FILE"
        else
            __tac_info "LLM Log" "[NOT FOUND: $LLM_LOG_FILE]" "$C_Warning"
            printf '%s\n' "  ${C_Dim}LLM may not have started yet.${C_Reset}"
        fi
        return 0
    fi
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
    if ! __llm_is_healthy
    then
        local burn_ready_timeout="${LLM_BURN_READY_TIMEOUT:-180}"
        printf '%s' "${C_Dim}Waiting for model to finish loading"
        for (( _bw=0; _bw < burn_ready_timeout; _bw++ ))
        do
            __llm_is_healthy && break
            printf '.'
            sleep 1
        done
        printf '%s\n' "$C_Reset"
        if ! __llm_is_healthy
        then
            __tac_info "Status" "Model failed to become healthy - check: tail $LLM_LOG_FILE" "$C_Error"
            return 1
        fi
    fi

    local bench_tokens="${LLM_BENCH_BURN_TOKENS:-768}"
    [[ "$bench_tokens" =~ ^[0-9]+$ ]] || bench_tokens=768
    (( bench_tokens < 128 )) && bench_tokens=128
    printf '%s\n' "${C_Dim}Testing: ~${bench_tokens} token synthetic physics response...${C_Reset}"
    printf '%s\n' "${C_Highlight}Processing ....${C_Reset}"

    local prompt="Explain the complete theory of special relativity"
    prompt+=" in extreme detail, including the mathematical"
    prompt+=" derivations for time dilation."

    # Non-streaming request — curl + jq, with bash nanosecond timing.
    # Bench mode uses deterministic sampling to make cross-run TPS comparisons
    # less sensitive to random token path variation.
    local payload
    if [[ -n "${__BENCH_MODE:-}" ]]
    then
        payload=$(jq -n \
            --arg p "$prompt" \
            --argjson bench_tokens "$bench_tokens" \
            --argjson bench_temp "${LLM_BENCH_TEMPERATURE:-0}" \
            '{messages: [{role: "user", content: $p}], max_tokens: $bench_tokens, min_tokens: $bench_tokens, temperature: $bench_temp, top_p: 1.0}')
    else
        payload=$(jq -n --arg p "$prompt" \
            '{messages: [{role: "user", content: $p}], max_tokens: 1500, temperature: 0.7}')
    fi

    local request_timeout=360
    if [[ -f "$ACTIVE_LLM_FILE" && -f "$LLM_REGISTRY" ]]
    then
        local _burn_num _burn_entry _burn_gpu _burn_size
        _burn_num=$(< "$ACTIVE_LLM_FILE")
        _burn_entry=$(awk -F'|' -v n="$_burn_num" '$1 == n {print; exit}' \
            "$LLM_REGISTRY" 2>/dev/null)
        if [[ -n "$_burn_entry" ]]
        then
            IFS='|' read -r _n _name _file _burn_size _arch _quant _layers \
                _burn_gpu _ctx _threads _tps <<< "$_burn_entry"
            request_timeout=$(__llm_burn_request_timeout "${_burn_size:-0G}" "${_burn_gpu:-0}" "${_arch:-}" "${__BENCH_MODE:-}")
        fi
    fi

    local start_ns end_ns response curl_rc
    local attempt=1 max_attempts=2
    while true
    do
        start_ns=$(date +%s%N)
        response=$(curl -sS --max-time "$request_timeout" "$LOCAL_LLM_URL" \
            -H "Content-Type: application/json" \
            -d "$payload" 2>/dev/null)
        curl_rc=$?
        end_ns=$(date +%s%N)

        # Retry once for transient transport issues (e.g. brief server restart
        # or socket reset) to improve benchmark fairness.
        if (( curl_rc != 0 && curl_rc != 28 && attempt < max_attempts ))
        then
            local _retry_msg
            _retry_msg="${C_Dim}[API Retry]${C_Reset} Transport error (curl ${curl_rc}); "
            _retry_msg+="waiting for health and retrying once..."
            printf '%s\n' \
                "$_retry_msg"
            local _rh
            for (( _rh=0; _rh < 20; _rh++ ))
            do
                __llm_is_healthy && break
                sleep 1
            done
            attempt=$(( attempt + 1 ))
            continue
        fi

        # Retry once if server returned 503 "Loading model" (readiness race:
        # /health reports ok before the model slot is fully ready to serve).
        if (( curl_rc == 0 && attempt < max_attempts ))
        then
            local _loading_msg
            _loading_msg=$(printf '%s' "$response" | jq -r '.error.message // empty' 2>/dev/null)
            if [[ "$_loading_msg" == *[Ll]oading* ]]
            then
                local _loading_retry_msg
                _loading_retry_msg="${C_Dim}[API Retry]${C_Reset} Server still loading "
                _loading_retry_msg+="(\"${_loading_msg}\"); waiting up to 30s..."
                printf '%s\n' \
                    "$_loading_retry_msg"
                local _lw
                for (( _lw=0; _lw < 30; _lw++ ))
                do
                    if __llm_is_healthy; then sleep 3; break; fi
                    sleep 1
                done
                attempt=$(( attempt + 1 ))
                continue
            fi
        fi

        break
    done

    if (( curl_rc == 28 ))
    then
        printf '%s\n' \
            "${C_Warning}[API Timeout]${C_Reset} No response within ${request_timeout}s "\
    "(model likely still computing, not necessarily crashed)."
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
    return 0
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
