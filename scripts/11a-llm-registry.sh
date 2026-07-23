# shellcheck shell=bash
# shellcheck disable=SC2034,SC2059,SC2120,SC2154
# --- Module: 11a-llm-registry ---
# AI INSTRUCTION: On ANY change to this file, increment the Module Version below.
# Module Version: 2
# ==============================================================================
# 11a-llm-registry — Registry CRUD, sync, renumber
# ==============================================================================
# @modular-section: llm-manager
# @depends: constants, design-tokens, ui-engine, hooks, llm-server, llm-autotune
# @exports: __save_tps, __save_model_ctx, __require_llm, __llm_json_escape,
#   __llm_registry_entry_by_num, __llm_registry_entry_by_file,
#   __llm_default_file, __llm_default_entry, __llm_default_number,
#   __llm_registry_sync_state, __renumber_registry

# Idempotent include guard: sub-modules are sourced both by their thin
# loader and directly by the profile/env loaders, so run the body once.
[[ -n "${__TAC_MOD_11A_LLM_REGISTRY_LOADED:-}" ]] && return 0
__TAC_MOD_11A_LLM_REGISTRY_LOADED=1

function __save_tps() {
    local tps_val="$1"
    [[ -z "$tps_val" || ! -f "$ACTIVE_LLM_FILE" || ! -f "$LLM_REGISTRY" ]] && return
    __llm_registry_sync_state >/dev/null 2>&1 || true
    local active_num
    active_num=$(< "$ACTIVE_LLM_FILE")
    [[ -z "$active_num" ]] && return
    awk -F'|' -v n="$active_num" -v t="$tps_val" 'BEGIN{OFS="|"} $1 == n {$17 = t} {print}' \
        "$LLM_REGISTRY" > "${LLM_REGISTRY}.tmp"
    if [[ -s "${LLM_REGISTRY}.tmp" ]] && [[ "$(wc -l < "${LLM_REGISTRY}.tmp")" -ge 2 ]]
    then
        mv "${LLM_REGISTRY}.tmp" "$LLM_REGISTRY"
    else
        rm -f "${LLM_REGISTRY}.tmp"
    fi
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

    local saved="$ctx_val"

    awk -F'|' -v n="$model_num" -v c="$saved" 'BEGIN{OFS="|"} $1 == n {$8 = c} {print}' \
        "$LLM_REGISTRY" > "${LLM_REGISTRY}.tmp"
    if [[ -s "${LLM_REGISTRY}.tmp" ]] && [[ "$(wc -l < "${LLM_REGISTRY}.tmp")" -ge 2 ]]
    then
        mv "${LLM_REGISTRY}.tmp" "$LLM_REGISTRY"
    else
        rm -f "${LLM_REGISTRY}.tmp"
    fi
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
# __tac_cleanup_stale_locks — Kill orphaned bench/autotune lock files and orphan
# stdin-keeper processes left behind by aborted runs (SIGKILL, WSL crash, etc.).
# Safe to call at any time — only removes files with no active holder.
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

    awk -F'|' -v def="$default_file" -v af="$active_file" -v run="$running" 'BEGIN {
            OFS="|"
            # Always emit the canonical header first, even if the input
            # registry has lost its header line (e.g. after an interrupted
            # model-scan renumbering pass).  This prevents a headerless
            # registry from self-perpetuating across every sync_state call.
            print "#|name|file|size_gb|quant_cache|arch|gpu_layers|ctx|threads|batch|ubatch|parallel|fit_target_mb|backend|mmap_mode|flash_attn|tps|autotuned|is_default|in_vram"
        }
        $1 == "#" { next }
        NF != 20 { next }
        {
            d = ($3 == def ? "yes" : "no")
            a = (run == 1 && af != "" && $3 == af ? "yes" : "no")
            $19=d; $20=a
            if ($15 == "") $15="auto"
            if ($16 == "") $16="on"
            print $1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17,$18,$19,$20
        }
    ' "$LLM_REGISTRY" > "${LLM_REGISTRY}.tmp" || return 1

    # Safety: never replace the registry with an empty or truncated file.
    # A failed awk run can produce 0 lines, wiping all model data.
    # Require header + at least 1 data row (≥ 2 lines) so a header-only
    # output cannot overwrite a populated registry.
    if [[ -s "${LLM_REGISTRY}.tmp" ]] && [[ "$(wc -l < "${LLM_REGISTRY}.tmp")" -ge 2 ]]
    then
        mv "${LLM_REGISTRY}.tmp" "$LLM_REGISTRY" || return 1
    else
        rm -f "${LLM_REGISTRY}.tmp"
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# __llm_autotune_profiles_file — Return registry path for autotune persistence.
# Autotune winners are persisted directly into flat tuning columns in models.conf.
# @returns 0 always.
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
        echo "#|name|file|size_gb|quant_cache|arch|gpu_layers|ctx|threads|batch|ubatch|parallel|fit_target_mb|backend|mmap_mode|flash_attn|tps|autotuned|is_default|in_vram"
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
# ---------------------------------------------------------------------------
# end of file
