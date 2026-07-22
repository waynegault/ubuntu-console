# shellcheck shell=bash
# shellcheck disable=SC2034,SC2059,SC2120,SC2154
# --- Module: 11e-llm-model ---
# AI INSTRUCTION: On ANY change to this file, increment the Module Version below.
# Module Version: 2
# ==============================================================================
# 11e-llm-model
# ==============================================================================

# Idempotent include guard: sub-modules are sourced both by their thin
# loader and directly by the profile/env loaders, so run the body once.
[[ -n "${__TAC_MOD_11E_LLM_MODEL_LOADED:-}" ]] && return 0
__TAC_MOD_11E_LLM_MODEL_LOADED=1

function __model_scan() {
    if (( ! __LLAMA_DRIVE_MOUNTED ))
    then
        __tac_info "Error" \
            "[Model drive $LLAMA_DRIVE_ROOT is not mounted - run: sudo mount -t drvfs M: $LLAMA_DRIVE_ROOT]" \
            "$C_Error"
        return 1
    fi

    # Before scanning, count how many autotuned rows exist. If any will be
    # lost by a fresh scan, warn the user so 3 days of tuning data is not
    # silently destroyed (as happened in the 2026-06-05 incident).
    local _autotuned_count=0
    if [[ -f "$LLM_REGISTRY" ]]
    then
        _autotuned_count=$(awk -F'|' '$18 == "yes" {count++} END {print count+0}' "$LLM_REGISTRY")
        if (( _autotuned_count > 0 ))
        then
            __tac_info "Note" "[$_autotuned_count models with autotuned data — remapped from previous scan]" "$C_Dim"
        fi
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
        # Persistent backup in ~/.llm/backups/ so pre-scan state can be
        # recovered if autotune data is accidentally lost (issue 2026-07-07).
        local _scan_backup_dir
        _scan_backup_dir="$(dirname "$LLM_REGISTRY")/backups"
        mkdir -p "$_scan_backup_dir"
        cp "$LLM_REGISTRY" "$_scan_backup_dir/models.conf.$(date +%Y%m%d-%H%M%S).pre-scan"
    fi
    echo "#|name|file|size_gb|quant_cache|arch|gpu_layers|ctx|threads|batch|ubatch|parallel|fit_target_mb|backend|mmap_mode|flash_attn|tps|autotuned|is_default|in_vram" > "$tmpconf"

    local num=0
    __tac_info "Reading" "files from $LLAMA_MODEL_DIR..." "$C_Dim"
    local gguf
    for gguf in "$LLAMA_MODEL_DIR"/*.gguf
    do
        [[ ! -f "$gguf" ]] && continue
        local fname
        fname=$(basename "$gguf")
        local fbytes
        fbytes=$(stat --format=%s "$gguf" 2>/dev/null || stat -f%z "$gguf" 2>/dev/null)
        (( fbytes < 300000000 )) && continue

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

        ((++num))
        local prev_batch="${LLAMA_BATCH_SIZE:-1024}"
        local prev_ubatch="${LLAMA_UBATCH_SIZE:-256}"
        local prev_parallel="${LLAMA_PARALLEL_SLOTS:-1}"
        local prev_fit="${LLAMA_FIT_TARGET_MB:-256}"
        local prev_backend="llama_server"
        local prev_mmap="auto"
        local prev_flash_attn="on"
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
                IFS='|' read -r _pn _pname _pfile _psize _pqc _parch _pgpu _pctx _pthr prev_batch prev_ubatch prev_parallel prev_fit prev_backend prev_mmap prev_flash_attn prev_tps prev_autotuned prev_default prev_active <<< "$prev_row"
                [[ -z "${prev_flash_attn:-}" ]] && prev_flash_attn="on"
            fi
        fi

        local quant_cache="${quant}/${LLAMA_CACHE_TYPE_K:-q8_0}"

        # Preserve autotuned ctx: use prev_ctx instead of fresh calc when autotuned
        local _final_ctx="$ctx"
        if [[ "$prev_autotuned" == "yes" ]] && [[ -n "${_pctx:-}" ]] && (( _pctx > 0 ))
        then
            _final_ctx="$_pctx"
        fi
        local _reg_line="${num}|${_mname:-$fname}|${fname}|${size_gb}G|${quant_cache}|${march}|${gpu_layers}|${_final_ctx}|${threads}"
        _reg_line+="|${prev_batch}|${prev_ubatch}|${prev_parallel}|${prev_fit}|${prev_backend}|${prev_mmap}|${prev_flash_attn}|${prev_tps}|${prev_autotuned}|${prev_default}|${prev_active}"
        echo "$_reg_line" >> "$tmpconf"

        # Progress: not printing each model individually
    done

    if (( num == 0 ))
    then
        __tac_info "Result" "[No models found in $LLAMA_MODEL_DIR]" "$C_Warning"
        rm -f "$tmpconf"
        return 1
    fi

    __tac_info "Found" "${num} models" "$C_Success"
    # Safety: never replace the registry with an empty or header-only file.
    # A failed scan (disk full, I/O error, drive unmounted mid-scan) can
    # produce a tmpconf with only the header line.  Require ≥ 2 lines
    # (header + at least 1 data row) before overwriting the registry.
    if [[ -s "$tmpconf" ]] && [[ "$(wc -l < "$tmpconf")" -ge 2 ]]
    then
        mv "$tmpconf" "$LLM_REGISTRY"
    else
        __tac_info "Registry" "[Refusing to overwrite with $(wc -l < "$tmpconf") lines — keeping existing registry]" "$C_Error"
        rm -f "$tmpconf"
        if [[ -n "$old_registry_snapshot" ]]
        then
            rm -f "$old_registry_snapshot"
        fi
        return 1
    fi
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
        local _qnum _qname _qfile _qsize _qqcache _qarch _qgpu _qctx _qthr _qb _qub _qp _qfit _qbe _qmm _qfa _qtps _qautotuned _qdefault _qactive
        while IFS='|' read -r _qnum _qname _qfile _qsize _qqcache _qarch _qgpu _qctx _qthr _qb _qub _qp _qfit _qbe _qmm _qfa _qtps _qautotuned _qdefault _qactive
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
                    ((++archived))
                fi
            fi
        done

        if (( archived > 0 ))
        then
            __tac_info "Enforcement" "[$archived discouraged model(s) moved to archive]" "$C_Warning"
            # Use a per-run temp file (not .tmp which is shared with the
            # initial scan write and with __llm_registry_sync_state).
            # An interrupted renumber pass must never leave a half-built
            # registry behind; the original models.conf stays intact
            # until the final mv.
            local clean_tmp="${LLM_REGISTRY}.renum.$$"
            local new_num=0
            echo "#|name|file|size_gb|quant_cache|arch|gpu_layers|ctx|threads|batch|ubatch|parallel|fit_target_mb|backend|mmap_mode|flash_attn|tps|autotuned|is_default|in_vram" > "$clean_tmp"
            local _cline
            while IFS= read -r _cline
            do
                [[ "$_cline" == "#"* || -z "$_cline" ]] && continue
                local _cfile
                _cfile=$(cut -d'|' -f3 <<< "$_cline")
                [[ -f "$LLAMA_MODEL_DIR/$_cfile" ]] || continue
                ((++new_num))
                echo "${new_num}|$(cut -d'|' -f2- <<< "$_cline")" >> "$clean_tmp"
            done < "$LLM_REGISTRY"
            if [[ -s "$clean_tmp" ]] && [[ "$(wc -l < "$clean_tmp")" -ge 2 ]]
            then
                mv "$clean_tmp" "$LLM_REGISTRY"
            else
                __tac_info "Registry" "[Refusing to renumber — output has $(wc -l < "$clean_tmp") lines, keeping existing registry]" "$C_Error"
                rm -f "$clean_tmp"
            fi
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
        *) ;;
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
        while IFS='|' read -r num name file size quant_cache arch gpu_layers ctx threads batch ubatch parallel fit_target_mb backend mmap_mode flash_attn tps autotuned is_default in_vram
        do
            [[ "$num" == "#" || -z "$num" ]] && continue
            local quant_rating="unknown"
            quant_rating=$(__llm_quant_rating "$file")
            local is_active="false"
            local is_default_json="false"
            [[ "${in_vram:-no}" == "yes" ]] && is_active="true"
            [[ "${is_default:-no}" == "yes" ]] && is_default_json="true"
            (( first )) || printf ',\n'
            printf '    {"num":%s,"name":"%s","file":"%s","size":"%s","quant_cache":"%s","arch":"%s",\
"gpu_layers":%s,"ctx":%s,"threads":%s,"batch":%s,"ubatch":%s,"parallel":%s,"fit":%s,"backend":"%s","mmap_mode":"%s","flash_attn":"%s","tps":"%s","autotuned":"%s","quant_rating":"%s","active":%s,"default":%s}' \
                "$num" "$(__llm_json_escape "$name")" "$(__llm_json_escape "$file")" "$size" "$(__llm_json_escape "$quant_cache")" \
                "$(__llm_json_escape "$arch")" "$gpu_layers" "$ctx" "$threads" "$batch" "$ubatch" "$parallel" "$fit_target_mb" \
                "$(__llm_json_escape "$backend")" "$(__llm_json_escape "${mmap_mode:-auto}")" "$(__llm_json_escape "${flash_attn:-on}")" "$(__llm_json_escape "${tps:--}")" "$(__llm_json_escape "${autotuned:-no}")" "$(__llm_json_escape "$quant_rating")" "$is_active" "$is_default_json"
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
        while IFS='|' read -r num name file size quant_cache arch gpu_layers ctx threads batch ubatch parallel fit_target_mb backend mmap_mode flash_attn tps autotuned is_default in_vram
        do
            [[ "$num" == "#" || -z "$num" ]] && continue
            local status="idle"
            [[ "${in_vram:-no}" == "yes" ]] && status="active"
            [[ "${is_default:-no}" == "yes" ]] && status="default"
            printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
                "$num" "$name" "$file" "$size" "$quant_cache" "$arch" "$gpu_layers" "$ctx" "$threads" "$batch" "$ubatch" "$parallel" "$fit_target_mb" "$backend" "${mmap_mode:-auto}" "${flash_attn:-on}" "${tps:--}" "${autotuned:-no}" "$status"
        done < "$LLM_REGISTRY"
        return 0
    fi

    # Human-readable output — compute column widths dynamically
    local _col_spec="%4s %28s %5s %9s %7s %4s %7s %4s %4s %4s %4s %4s %7s %4s %5s %5s %5s %4s %4s %11s"
    printf "\n${C_Dim}  ${_col_spec}${C_Reset}\n" \
        "#" "MODEL" "SIZE" "Q/CACHE" "ARCH" "GPU" "CTX" "THR" "B" "UB" "PAR" "FIT" "BACK" "FA" "MMAP" "TPS" "ATUNE" "DEF" "VRAM" "RATING"
    local _list_rule
    printf -v _list_rule '%*s' 149 ''
    _list_rule="${_list_rule// /${BOX_SL}}"
    printf "${C_Dim}  %s${C_Reset}\n" "$_list_rule"

    local num name file size quant_cache arch gpu_layers ctx threads batch ubatch parallel fit_target_mb backend mmap_mode flash_attn tps autotuned is_default in_vram
    while IFS='|' read -r num name file size quant_cache arch gpu_layers ctx threads batch ubatch parallel fit_target_mb backend mmap_mode flash_attn tps autotuned is_default in_vram
    do
        [[ "$num" == "#" || -z "$num" ]] && continue
        local quant_rating="unknown"
        quant_rating=$(__llm_quant_rating "$file")
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
        printf "${color}${marker}${_col_spec}${C_Reset}\n" \
            "$num" "${name:0:28}" "$size" "${quant_cache:0:9}" "${arch:0:7}" "$gpu_layers" "$ctx" "$threads" "$batch" "$ubatch" "$parallel" "$fit_target_mb" "${backend:0:7}" "${flash_attn:-on}" "${mmap_mode:-auto}" "${tps:--}" "${autotuned:-no}" "${is_default:-no}" "${in_vram:-no}" "${quant_rating:0:11}"
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
# ====== __model_use helper functions ======

# ---------------------------------------------------------------------------
# __model_use_resolve_model
# @description Resolve model target, look up registry entry, parse fields.
# @arg $1 target model number (may be empty to use default)
# @sets target, num, name, file, size, quant_cache, arch, gpu_layers, ctx,
#        threads, batch_size, ubatch_size, parallel_slots, fit_target_mb,
#        row_backend, row_mmap_mode, row_flash_attn, tps, autotuned,
#        is_default, in_vram; may also override ctx via TAC_CTX_SIZE
# @returns 0 on success, 1 if validation or registry lookup fails.
# ---------------------------------------------------------------------------
function __model_use_resolve_model() {
    target="${1:-}"

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

    # These variables are shared with caller via dynamic scope —
    # declared as `local` in __model_use, assigned here.
    IFS='|' read -r num name file size quant_cache arch gpu_layers ctx threads batch_size ubatch_size parallel_slots fit_target_mb row_backend row_mmap_mode row_flash_attn tps autotuned is_default in_vram <<< "$entry"

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
}

# ---------------------------------------------------------------------------
# __model_use_ensure_downloaded
# @description Check if model file exists locally; prompt and download if not.
# @uses file, name, size, target (from resolve_model scope)
# @sets model_path, model_bytes
# @returns 0 on success (file present), 1 if download fails or cancelled.
# ---------------------------------------------------------------------------
function __model_use_ensure_downloaded() {
    model_path="$LLAMA_MODEL_DIR/$file"
    model_bytes=0

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
}

# ---------------------------------------------------------------------------
# __model_use_select_backend
# @description Determine server backend (native vs python) and resolve binary.
# @uses file, row_backend (from resolve_model scope)
# @sets quant_rating, llm_backend, python_bin, LLM_SERVER_PYTHON_BIN
# @returns 0 on success, 1 if required binary not found.
# ---------------------------------------------------------------------------
function __model_use_select_backend() {
    quant_rating=$(__llm_quant_rating "$file")
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

    python_bin=""
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
}

# ---------------------------------------------------------------------------
# __model_use_configure_params
# @description Configure runtime parameters: threads, ctx, GPU layers, batch,
#   ubatch, parallel slots, free VRAM, and cache type.
# @uses TAC_CTX_SIZE, ctx, threads (initial from registry), quant_rating,
#   model_bytes, gpu_layers (initial from registry)
# @sets threads, smi_cmd, gpu_layers, batch_size, ubatch_size, parallel_slots,
#   free_vram_mb, type_k_val (all finalised)
# @returns 0 always.
# ---------------------------------------------------------------------------
function __model_use_configure_params() {
    # Prefer per-model registry values from model scan; fall back to global defaults.
    [[ "$threads" =~ ^[0-9]+$ ]] || threads="${LLAMA_CPU_THREADS:-6}"
    if [[ -z "${TAC_CTX_SIZE:-}" ]]
    then
        [[ "$ctx" =~ ^[0-9]+$ ]] || ctx="${LLAMA_CTX_SIZE:-4096}"
    fi
    smi_cmd=$(__resolve_smi 2>/dev/null || true)
    if [[ -n "$smi_cmd" ]]
    then
        [[ "$gpu_layers" =~ ^[0-9]+$ ]] || gpu_layers="${LLAMA_GPU_LAYERS:-${LLM_GPU_LAYERS:-24}}"
        if [[ -n "${LLAMA_GPU_LAYERS:-}" && "${LLAMA_GPU_LAYERS}" =~ ^[0-9]+$ ]]
        then
            gpu_layers="${LLAMA_GPU_LAYERS}"
        elif [[ -n "${LLM_GPU_LAYERS:-}" && "${LLM_GPU_LAYERS}" =~ ^[0-9]+$ ]]
        then
            gpu_layers="${LLM_GPU_LAYERS}"
        fi
    else
        gpu_layers=0
    fi

    # Quant-guide-aware launch tuning for 4GB VRAM systems
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
            *) ;;
        esac
    fi

    __llm_server_stop
    sleep 1
    sudo -n prlimit --memlock=unlimited:unlimited --pid $$ 2>/dev/null

    [[ "$batch_size" =~ ^[0-9]+$ ]] || batch_size=1024
    [[ "$ubatch_size" =~ ^[0-9]+$ ]] || ubatch_size=256
    [[ "$parallel_slots" =~ ^[0-9]+$ ]] || parallel_slots=1
    free_vram_mb=0
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

    type_k_val=$(__llm_type_k_value)
}

# ---------------------------------------------------------------------------
# __model_use_build_command
# @description Build the server command array and configure mmap behavior.
# @uses llm_backend, model_path, ctx, batch_size, ubatch_size, threads,
#   gpu_layers, row_flash_attn, fit_target_mb, row_mmap_mode, arch,
#   free_vram_mb, model_bytes, parallel_slots
# @sets cmd, fit_target_mb (finalised), use_no_mmap
# @returns 0 always.
# ---------------------------------------------------------------------------
function __model_use_build_command() {
    cmd=()
    if [[ "$llm_backend" == "native" ]]
    then
        fit_target_mb="${fit_target_mb:-${LLAMA_FIT_TARGET_MB:-1024}}"
        if [[ ! "$fit_target_mb" =~ ^[0-9]+$ ]] || (( fit_target_mb < 0 ))
        then
            fit_target_mb=1024
        fi

        local flash_attn_mode="auto"
        local _flash_attn_setting="${LLAMA_FLASH_ATTN:-${row_flash_attn:-true}}"
        case "${_flash_attn_setting}" in
            true|TRUE|1|yes|YES|on|ON) flash_attn_mode="on" ;;
            false|FALSE|0|no|NO|off|OFF) flash_attn_mode="off" ;;
            *) ;;
        esac

        local kv_offload_flag="--kv-offload"
        case "${LLAMA_OFFLOAD_KQV:-true}" in
            false|FALSE|0|no|NO|off|OFF) kv_offload_flag="--no-kv-offload" ;;
            *) ;;
        esac

        cmd=("$LLAMA_SERVER_BIN")
        cmd+=("--model" "$model_path" "--port" "$LLM_PORT" "--host" "127.0.0.1")
        cmd+=("--ctx-size" "$ctx")
        cmd+=("--batch-size" "$batch_size" "--ubatch-size" "$ubatch_size")
        cmd+=("--threads" "$threads")
        cmd+=("--n-gpu-layers" "$gpu_layers")
        if [[ -n "${__BENCH_MODE:-}" ]]; then
            cmd+=("--fit" "on" "--fit-target" "256")
        else
            cmd+=("--fit" "on" "--fit-target" "$fit_target_mb")
        fi
        cmd+=("--flash-attn" "$flash_attn_mode")
        cmd+=("--jinja")
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
    use_no_mmap=0
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
}

# ---------------------------------------------------------------------------
# __model_use_launch_server
# @description Print startup info, launch server with stdin FIFO keeper, save PID.
# @uses cmd, num, name, size, gpu_layers, ctx, batch_size, ubatch_size,
#   parallel_slots, threads, use_no_mmap, llm_backend, free_vram_mb,
#   autotuned, fit_target_mb, __BENCH_MODE
# @sets model_shell_pid; writes active model state to disk.
# @returns 0 always.
# ---------------------------------------------------------------------------
function __model_use_launch_server() {
    local ngl_label="CPU-only"
    (( gpu_layers > 0 )) && ngl_label="ngl=${gpu_layers}"
    local mmap_label="mmap:on"
    (( use_no_mmap )) && mmap_label="mmap:off"
    local start_msg="#${num} ${name} (${size}, ${ngl_label}, ctx ${ctx}, "
    start_msg+="b ${batch_size}/${ubatch_size}, p ${parallel_slots}, ${mmap_label}, t=${threads}, k=${LLAMA_CACHE_TYPE_K:-q8_0})"
    if [[ -z "${__BENCH_MODE:-}" ]]
    then
        __tac_info "Starting" "$start_msg" "$C_Highlight"
        __tac_info "Backend" "[$llm_backend]" "$C_Dim"
    fi

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
        local _fit_label="fit:${fit_target_mb}"
        local _autotuned_label=""
        if [[ "${autotuned:-no}" == "yes" ]]
        then
            _autotuned_label="autotuned"
        else
            _autotuned_label="defaults"
        fi
        printf "Using %s params: ctx %s  b %s/%s  p %s  ngl %s  %s\n" \
            "$_autotuned_label" "$ctx" "$batch_size" "$ubatch_size" "$parallel_slots" "$gpu_layers" "$_fit_label"
    fi

    # llama.cpp monitors stdin and will force-shutdown on EOF.
    # We keep stdin open via a FIFO and a dedicated keeper process, then
    # explicitly tear down the keeper when llama-server exits.
    (
        trap '' HUP INT TERM

        # Close all inherited lock file descriptors (from autotune/bench locks)
        # so child processes (stdin keeper, llama-server) don't inherit them.
        local _lock_fd_dir="/proc/${BASHPID:-$$}/fd"
        for _lfd in "${_lock_fd_dir}/"*; do
            _lfdnum="${_lfd##*/}"
            if [[ "$_lfdnum" =~ ^[0-9]+$ ]] && [[ "$_lfdnum" -ge 10 ]]; then
                eval "exec ${_lfdnum}>&-" 2>/dev/null || true
            fi
        done 2>/dev/null

        # Clean up orphan FIFOs and keepers from any previous llama-server
        # instance that was killed without running __model_stop.
        local _okf
        for _okf in /tmp/llm-keeper.*.pid; do
            [[ -f "$_okf" ]] || continue
            _okp=$(< "$_okf")
            if [[ "$_okp" =~ ^[0-9]+$ ]]; then
                kill -TERM "$_okp" 2>/dev/null
            fi
            rm -f "$_okf"
        done
        rm -rf /tmp/llm-stdin.* 2>/dev/null || true

        local stdin_fifo_dir
        stdin_fifo_dir=$(mktemp -d /tmp/llm-stdin.XXXXXX)
        if [[ -z "$stdin_fifo_dir" || ! -d "$stdin_fifo_dir" ]]
        then
            __tac_info "Status" "FAILED OR TIMEOUT - could not allocate stdin fifo directory" "$C_Error"
            exit 1
        fi
        local stdin_fifo="$stdin_fifo_dir/stdin"
        if ! mkfifo "$stdin_fifo" 2>/dev/null
        then
            rm -rf "$stdin_fifo_dir" 2>/dev/null || true
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
            rm -rf "$stdin_fifo_dir" 2>/dev/null || true
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
        rm -rf "$stdin_fifo_dir" 2>/dev/null || true
        exit "$server_rc"
    ) 2>/dev/null &
    model_shell_pid=$!
    disown
    # Save the model subshell PID so __model_stop can kill it.
    # Include our own PID to prevent stale PIDs from overlapping runs.
    echo "$model_shell_pid" > "/tmp/llm-modelshell.$$.pid"

    if ! { echo "$num" > "${ACTIVE_LLM_FILE}.tmp" 2>/dev/null && mv "${ACTIVE_LLM_FILE}.tmp" "$ACTIVE_LLM_FILE"; }
    then
        __tac_info "Warning" "[Could not save state]" "$C_Warning"
    fi
}

# ---------------------------------------------------------------------------
# __model_use_wait_healthy
# @description Wait for server health check, run bench preflight if needed.
# @uses size, gpu_layers, name, num, __BENCH_MODE, ACTIVE_LLM_FILE
# @returns 0 when healthy, 1 on timeout/failure (after cleanup).
# ---------------------------------------------------------------------------
function __model_use_wait_healthy() {
    local health_timeout
    health_timeout=$(__llm_health_timeout "$size" "$gpu_layers" "$name")
    local _health_elapsed=0
    local _health_progress="silent"
    [[ -n "${__BENCH_MODE:-}" ]] || _health_progress="dots"
    if __llm_wait_for_health "$health_timeout" _health_elapsed "$_health_progress" "Loading LLM (health check)"
    then
        __llm_registry_sync_state >/dev/null 2>&1 || true
        # Bench mode: pre-flight a tiny completion to make sure the model slot is
        # actually ready to serve (WSL2: /health returns OK before slot is ready,
        # causing curl 52 on the first real request).
        if [[ -n "${__BENCH_MODE:-}" ]]
        then
            local _preflight='{"messages":[{"role":"user","content":"hi"}],"max_tokens":1,"temperature":0}'
            local _pf_rc
            _pf_rc=$(curl -s -o /dev/null -w '%{http_code}' --max-time 30 \
                -H 'Content-Type: application/json' \
                -d "$_preflight" "http://127.0.0.1:$LLM_PORT/v1/chat/completions" 2>/dev/null || echo 0)
            # If preflight didn't get a 200, the slot wasn't ready yet — wait for
            # it to stabilise by polling /health until it sticks.
            if [[ "$_pf_rc" != "200" ]]
            then
                local _pf
                for (( _pf=0; _pf < 60; _pf++ ))
                do
                    sleep 1
                    _pf_rc=$(curl -s -o /dev/null -w '%{http_code}' --max-time 30 \
                        -H 'Content-Type: application/json' \
                        -d "$_preflight" "http://127.0.0.1:$LLM_PORT/v1/chat/completions" 2>/dev/null || echo 0)
                    [[ "$_pf_rc" == "200" ]] && break
                done
            fi
        fi
        [[ -n "${__BENCH_MODE:-}" ]] || __tac_info "Status" "ONLINE [Port $LLM_PORT]" "$C_Success"
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
    [[ -z "${__BENCH_MODE:-}" ]] && __tac_info "Status" "FAILED OR TIMEOUT - check: tail $LLM_LOG_FILE" "$C_Error"
    return 1
}

# ---------------------------------------------------------------------------
# __model_use (thin orchestrator)
# @description Start a registry model with adaptive llama-server settings
#   and health checks.
# @returns 0 on success, 1 if validation or startup fails.
# ---------------------------------------------------------------------------
function __model_use() {
    # Shared variables — declared local here, populated by helpers via
    # dynamic scope (caller locals are visible to called functions).
    local target num name file size quant_cache arch gpu_layers
    local ctx threads batch_size ubatch_size parallel_slots fit_target_mb
    local row_backend row_mmap_mode row_flash_attn tps autotuned is_default in_vram
    local model_path model_bytes quant_rating llm_backend python_bin
    local smi_cmd free_vram_mb type_k_val use_no_mmap
    local cmd model_shell_pid

    __model_use_resolve_model "$@" || return 1
    __model_use_ensure_downloaded || return 1
    __model_use_select_backend || return 1
    __model_use_configure_params
    __model_use_build_command
    __model_use_launch_server
    __model_use_wait_healthy
    return $?
}

# ---------------------------------------------------------------------------
# __model_autotune_help
# @description Print detailed help for model autotune.
# @returns 0 always.
# ---------------------------------------------------------------------------
function __model_autotune_help() {
    echo "Usage: model autotune <N>"
    echo "       model autotune all"
    echo ""
    echo "Tests a range of context sizes and batch/ubatch combos to find the"
    echo "optimal configuration for model #N. Saves the best combo (ctx \u00d7 tps)"
    echo "to models.conf as the model's default runtime profile."
    echo ""
    echo "Strategy:"
    echo "  - Context ladder: 4096 \u2192 32768, stops at first level that OOMs"
    echo "  - Batch combos: 1-3 depending on model size"
    echo "  - Parallel always 1 (4GB VRAM limit)"
    echo "  - No --fit flag (projection bug in this llama-server build)"
    echo "  - Full VRAM drain between each test"
    echo ""
    echo "Batch:"
    echo "  model autotune all          Run autotune on all untuned models"
    echo ""
    echo "Examples:"
    echo "  model autotune 3"
    echo "  model autotune all"
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
    # Fallback for keepers that lost their PID file or were reparented to an
    # unexpected shell by the VS Code terminal relay.
    local _keeper_line _keeper_ppid _keeper_cmd
    while IFS= read -r _keeper_line
    do
        [[ -n "$_keeper_line" ]] || continue
        _keeper_pid=${_keeper_line%% *}
        _keeper_cmd=${_keeper_line#* }
        [[ "$_keeper_pid" =~ ^[0-9]+$ ]] || continue
        [[ "$_keeper_cmd" == *"sleep 3600"* ]] || continue
        _keeper_ppid=$(ps -o ppid= -p "$_keeper_pid" 2>/dev/null | tr -d '[:space:]')
        if [[ -z "$_keeper_ppid" ]] || [[ "$_keeper_ppid" == "1" ]]
        then
            kill -KILL "$_keeper_pid" 2>/dev/null || true
        fi
    done < <(pgrep -af 'sleep 3600' 2>/dev/null || true)
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
    [[ -z "${__BENCH_MODE:-}" ]] && __tac_info "Llama Server" "[STOPPED]" "$C_Success"
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
        *) ;;
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
    local num name file size quant_cache arch gpu_layers ctx threads batch ubatch parallel fit_target_mb backend mmap_mode flash_attn tps autotuned is_default in_vram
    IFS='|' read -r num name file size quant_cache arch gpu_layers ctx threads batch ubatch parallel fit_target_mb backend mmap_mode flash_attn tps autotuned is_default in_vram <<< "$entry"
    local quant_rating="unknown"
    quant_rating=$(__llm_quant_rating "$file")

    # Explicitly print every models.conf field so schema visibility is complete.
    __tac_info "#" "$num" "$C_Highlight"
    __tac_info "name" "$name" "$C_Success"
    __tac_info "file" "$file" "$C_Text"
    __tac_info "size_gb" "$size" "$C_Text"
    __tac_info "quant_cache" "$quant_cache" "$C_Text"
    __tac_info "quant_rating" "$quant_rating" "$C_Text"
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
    __tac_info "flash_attn" "${flash_attn:-on}" "$C_Text"
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
#
# SAFETY: Uses SIGTERM-first with a grace period to let EXIT traps fire.
# SIGKILL is only used as a last resort, and ONLY on the child's own
# process group — never on the parent. This prevents parent process
# EXIT traps (lock file cleanup, model stop) from being bypassed.
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
    local _monitor_was_on=0
    [[ "$-" == *m* ]] && _monitor_was_on=1
    local _self_pgid=""
    _self_pgid=$(ps -o pgid= -p "$$" 2>/dev/null | tr -d ' ')

    local _is_shell_func=0
    if declare -F "$1" >/dev/null 2>&1
    then
        _is_shell_func=1
    fi

    local _bench_runner_script="${TACTICAL_REPO_ROOT:-}/bin/bench-timeout-runner.sh"

    if (( _is_shell_func == 1 ))
    then
        local _bench_profile_path="${TACTICAL_PROFILE_PATH:-}"
        if [[ -z "$_bench_profile_path" || ! -f "$_bench_profile_path" ]]
        then
            _bench_profile_path="${TACTICAL_REPO_ROOT:-}/env.sh"
        fi
        # Shell functions cannot be exec'd by setsid directly.
        # Run them in a dedicated shell process-group when available.
        declare -fx "$1" 2>/dev/null || true
        (( _monitor_was_on == 1 )) && set +m
        if command -v setsid >/dev/null 2>&1; then
            setsid bash -lc "__BENCH_MODE=${__BENCH_MODE:-1} \"\$1\" \"\$2\" \"\${@:3}\"" _ "$_bench_runner_script" "$_bench_profile_path" "$@" &
        else
            bash -lc "__BENCH_MODE=${__BENCH_MODE:-1} \"\$1\" \"\$2\" \"\${@:3}\"" _ "$_bench_runner_script" "$_bench_profile_path" "$@" &
        fi
    elif command -v setsid >/dev/null 2>&1; then
        (( _monitor_was_on == 1 )) && set +m
        setsid "$@" &
    else
        (( _monitor_was_on == 1 )) && set +m
        "$@" &
    fi
    local cmd_pid=$!
    disown "$cmd_pid" 2>/dev/null || true
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
            if (( _monitor_was_on == 1 ))
            then
                set -m 2>/dev/null || true
            fi
            return $?
        fi
        sleep "$interval"
        waited=$(( waited + interval ))
    done

    # Phase 1 — SIGTERM with grace period (lets EXIT traps fire).
    if [[ -n "$cmd_pgid" ]] && [[ "$cmd_pgid" =~ ^[0-9]+$ ]] && [[ -n "$_self_pgid" ]] && [[ "$cmd_pgid" != "$_self_pgid" ]]
    then
        kill -TERM -- "-$cmd_pgid" 2>/dev/null || true
    else
        kill -TERM -- "$cmd_pid" 2>/dev/null || true
    fi

    # Grace wait: poll for clean exit, giving the child time to run EXIT traps.
    local _grace=10 _g_i
    for (( _g_i=0; _g_i < _grace; _g_i++ ))
    do
        if ! kill -0 "$cmd_pid" 2>/dev/null
        then
            wait "$cmd_pid" 2>/dev/null
            if (( _monitor_was_on == 1 ))
            then
                set -m 2>/dev/null || true
            fi
            return 124
        fi
        sleep 1
    done

    # Phase 2 — SIGKILL only if the child process group is distinct from ours.
    # NEVER send SIGKILL to our own process group — it would kill the parent
    # without triggering EXIT traps, leaving stale lock files.
    if [[ -n "$cmd_pgid" ]] && [[ "$cmd_pgid" =~ ^[0-9]+$ ]] && [[ -n "$_self_pgid" ]] && [[ "$cmd_pgid" != "$_self_pgid" ]]
    then
        kill -KILL -- "-$cmd_pgid" 2>/dev/null || true
    elif [[ "$cmd_pgid" =~ ^[0-9]+$ ]] && [[ "$cmd_pgid" == "$_self_pgid" ]]
    then
        # Child shares our PGID — can't safely SIGKILL it without killing
        # ourselves. Just orphan it; our EXIT trap will clean locks anyway.
        :
    else
        # No PGID info — last resort, try killing just the child PID.
        kill -KILL -- "$cmd_pid" 2>/dev/null || true
    fi
    wait "$cmd_pid" 2>/dev/null || true
    if (( _monitor_was_on == 1 ))
    then
        set -m 2>/dev/null || true
    fi
    return 124
}

# __model_bench
# @description Benchmark on-disk models, save TPS results, and restore prior state.
# @returns 0 on success, 1 if the registry or benchmark candidates are unavailable.
# ---------------------------------------------------------------------------
function __model_bench() {
    local -a bench_selectors=("$@")
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

    # Clean up any orphaned locks, keepers, and processes from prior runs
    # before attempting to acquire the bench lock.
    __tac_cleanup_stale_locks

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
    # The EXIT trap fires even under set -e or normal return, so lock files
    # are always cleaned unless the process receives SIGKILL.
    # ---------------------------------------------------------------------------
    local bench_cleanup_spawned_pids=()
    local __bench_signal_rc=0
    local __bench_cleaned=0
    local __bench_prev_int_trap=""
    local __bench_prev_term_trap=""
    local __bench_prev_exit_trap=""
    __bench_prev_int_trap=$(trap -p INT || true)
    __bench_prev_term_trap=$(trap -p TERM || true)
    __bench_prev_exit_trap=$(trap -p EXIT 2>/dev/null || true)
    __bench_restore_traps() {
        if [[ -n "$__bench_prev_int_trap" ]]
        then
            eval "$__bench_prev_int_trap"
        else
            trap - INT
        fi
        if [[ -n "$__bench_prev_term_trap" ]]
        then
            eval "$__bench_prev_term_trap"
        else
            trap - TERM
        fi
        if [[ -n "$__bench_prev_exit_trap" ]]
        then
            eval "$__bench_prev_exit_trap"
        else
            trap - EXIT
        fi
    }
    # shellcheck disable=SC2317  # called indirectly via trap
    __bench_cleanup() {
        local _exit_code=$?
        if (( __bench_cleaned == 1 ))
        then
            # Preserve original exit code from first call.
            return "$_exit_code"
        fi
        __bench_cleaned=1
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
        # Remove guard files (unconditionally — these are /tmp files, safe to rm)
        rm -f "$bench_pid_file"
        if [[ -n "$bench_lock_fd" ]]
        then
            flock -u "$bench_lock_fd" 2>/dev/null || true
            exec {bench_lock_fd}>&- 2>/dev/null || true
        fi
        rm -f "$bench_lock_file"
        __bench_restore_traps
        # shellcheck disable=SC2086
        return $_exit_code
    }
    trap '__bench_cleanup' EXIT
    trap '__bench_signal_rc=130; __bench_cleanup; return 130' INT
    trap '__bench_signal_rc=143; __bench_cleanup; return 143' TERM

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
    local bench_autotune_mode="unified"
    if [[ -n "${LLM_BENCH_AUTOTUNE_ENGINE:-}" && "${LLM_BENCH_AUTOTUNE_ENGINE}" != "shell" ]]
    then
        __tac_info "Bench" "[Ignoring LLM_BENCH_AUTOTUNE_ENGINE=${LLM_BENCH_AUTOTUNE_ENGINE}; single autotuner mode uses shell]" "$C_Dim"
    fi

    local -a b_num=() b_name=() b_file=() b_size=() b_gpu=() b_tps=()

    # shellcheck disable=SC2317  # invoked indirectly via timeout wrapper in child shell
    __bench_run_single_model() {
        export __BENCH_MODE=1
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
    local num name file size _quant_cache _arch gpu_layers _ctx _threads _batch _ubatch _parallel _fit _backend _mmap _flash_attn _tps _autotuned _is_default _in_vram
    while IFS='|' read -r num name file size _quant_cache _arch gpu_layers _ctx _threads _batch _ubatch _parallel _fit _backend _mmap _flash_attn _tps _autotuned _is_default _in_vram
    do
        [[ "$num" == "#" || -z "$num" ]] && continue
        [[ ! -f "$LLAMA_MODEL_DIR/$file" ]] && continue
        if (( ${#bench_selectors[@]} > 0 ))
        then
            local _bench_match=0
            local _selector _selector_lc
            for _selector in "${bench_selectors[@]}"
            do
                [[ -z "$_selector" ]] && continue
                _selector_lc="${_selector,,}"
                if [[ "$_selector" =~ ^[0-9]+$ ]]; then
                    [[ "$num" == "$_selector" ]] || continue
                elif [[ "${name,,}" != *"$_selector_lc"* && "${file,,}" != *"$_selector_lc"* ]]; then
                    continue
                fi
                if [[ "${num,,}" == "$_selector_lc" || "${name,,}" == *"$_selector_lc"* || "${file,,}" == *"$_selector_lc"* ]]
                then
                    _bench_match=1
                    break
                fi
            done
            (( _bench_match == 1 )) || continue
        fi
        b_num+=("$num")
        b_name+=("$name")
        b_file+=("$file")
        b_size+=("$size")
        b_gpu+=("${gpu_layers:-0}")
    done < "$LLM_REGISTRY"

    if (( ${#b_num[@]} == 0 ))
    then
        if (( ${#bench_selectors[@]} > 0 ))
        then
            __tac_info "Bench" "[No models matched selectors: ${bench_selectors[*]}]" "$C_Error"
        fi
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
            rm -f "$bench_lock_file"
        fi
        __bench_restore_traps
        return 1
    fi

    wake 2>/dev/null || true
    __llm_bench_perf_prep
    if (( ${#bench_selectors[@]} > 0 ))
    then
        printf '%s\n\n' "${C_Dim}Benchmarking ${#b_num[@]} selected models (${bench_selectors[*]})...${C_Reset}"
    else
        printf '%s\n\n' "${C_Dim}Benchmarking ${#b_num[@]} models...${C_Reset}"
    fi

    local __BENCH_MODE=1
    local i
    for i in "${!b_num[@]}"
    do
        local _prog_total="${#b_num[@]}"
        local _prog_num="$(( i+1 ))"
        printf "\n\n%s── [%s/%s] %s (%s) ──%s\n" "$C_Highlight" "$_prog_num" "$_prog_total" "${b_name[$i]}" "${b_size[$i]}" "$C_Reset"

        # Full VRAM cleanup BEFORE checking VRAM state
        sudo -n /usr/local/bin/clear_vram.sh >/dev/null 2>&1 || true

        local _bench_safe_overrides=0
        local _bench_min_free_vram_mb="${LLM_BENCH_MIN_FREE_VRAM_MB:-1200}"
        local _bench_free_vram_mb=0
        local _bench_smi
        _bench_smi=$(__resolve_smi 2>/dev/null || true)
        if [[ -n "$_bench_smi" ]]
        then
            _bench_free_vram_mb=$("$_bench_smi" --query-gpu=memory.free --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ')
        fi
        [[ "$_bench_min_free_vram_mb" =~ ^[0-9]+$ ]] || _bench_min_free_vram_mb=256
        [[ "$_bench_free_vram_mb" =~ ^[0-9]+$ ]] || _bench_free_vram_mb=0

        # Compact VRAM line
        if [[ "$_bench_free_vram_mb" =~ ^[0-9]+$ ]] && (( _bench_free_vram_mb > 0 )); then
            printf "VRAM %s MiB VRAM free\n" "$_bench_free_vram_mb"
        fi

        if (( _bench_free_vram_mb > 0 && _bench_free_vram_mb < _bench_min_free_vram_mb ))
        then
            export LLAMA_GPU_LAYERS=0
            export LLAMA_BATCH_SIZE=512
            export LLAMA_UBATCH_SIZE=128
            export LLAMA_PARALLEL_SLOTS=1
            _bench_safe_overrides=1
            __tac_info "  VRAM" "low (${_bench_free_vram_mb} MiB) — safe overrides: ngl=0" "$C_Warning"
        fi

        local _bench_quant_rating="unknown"
        _bench_quant_rating=$(__llm_quant_rating "${b_file[$i]}")

        # Auto-autotune only if this model/backend has never been autotuned.
        if ! __llm_autotune_done_for_model "${b_num[$i]}" "$bench_backend"
        then
            if [[ "$_bench_quant_rating" == "discouraged" && "${LLM_ALLOW_AUTOTUNE_DISCOURAGED:-0}" != "1" ]]
            then
                __tac_info "Bench" "[Skipping autotune for discouraged quant on model #${b_num[$i]} (set LLM_ALLOW_AUTOTUNE_DISCOURAGED=1 to override)]" "$C_Warning"
            else
                # If safe overrides are active (low VRAM), temporarily lift them for
                # autotune so the binary search finds the GPU-stable values, not
                # CPU-gated ones. Restore safe overrides after autotune for the
                # benchmark run itself.
                if (( _bench_safe_overrides == 1 ))
                then
                    unset LLAMA_GPU_LAYERS TAC_CTX_SIZE LLAMA_BATCH_SIZE LLAMA_UBATCH_SIZE LLAMA_PARALLEL_SLOTS
                fi
                __tac_info "  Autotune" "model #${b_num[$i]} (${bench_autotune_mode})..." "$C_Dim"
                export LLM_AUTOTUNE_RESTORE_PREV=0
                export LLM_AUTOTUNE_SKIP_LOCK=1


                local _autotune_rc=0
                # Single autotuner policy: bench and interactive flows both
                # use the standalone autotune script (no --fit bug, verified).
                bash "$HOME/ubuntu-console/scripts/autotune-model.sh" "${b_num[$i]}" 2>&1 || _autotune_rc=$?
                if (( _autotune_rc != 0 ))
                then
                    # Clear any lifted/safe overrides before skipping this model so
                    # later iterations do not inherit a failed model's bench state.
                    unset LLAMA_GPU_LAYERS TAC_CTX_SIZE LLAMA_BATCH_SIZE LLAMA_UBATCH_SIZE LLAMA_PARALLEL_SLOTS
                    unset LLM_AUTOTUNE_RESTORE_PREV
                    unset LLM_AUTOTUNE_SKIP_LOCK
                    __tac_info "Bench" "[Autotune failed for model #${b_num[$i]} (no working config) - skipping benchmark]" "$C_Error"
                    b_tps+=("FAIL_AUTOTUNE")
                    sudo -n /usr/local/bin/clear_vram.sh >/dev/null 2>&1 || true
                    __model_stop 2>/dev/null || true
                    __gpu_clear_stale_processes
                    sleep 2
                    continue
                fi
                unset LLM_AUTOTUNE_RESTORE_PREV
                unset LLM_AUTOTUNE_SKIP_LOCK
                # Restore safe overrides that were lifted before autotune.
                if (( _bench_safe_overrides == 1 ))
                then
                    export LLAMA_GPU_LAYERS=0
                    export LLAMA_BATCH_SIZE=512
                    export LLAMA_UBATCH_SIZE=128
                    export LLAMA_PARALLEL_SLOTS=1
                fi
                # FIX-C2: Autotune success path must also clear VRAM before bench.
                # Autotune's 6 OOM tests can leave VRAM fragmented or CUDA in a
                # corrupted state. The failure path already calls clear_vram.sh;
                # the success path was missing it, jumping straight to the bench.
                # REF: ubuntu-console card b9ba4596 — Card 2
                sudo -n /usr/local/bin/clear_vram.sh >/dev/null 2>&1 || true
            fi
        fi

        rm -f "$LLM_TPS_CACHE"
        # Timeout guard: force-bound full model run (__model_use + burn).
        local bench_model_timeout="${LLM_BENCH_MODEL_TIMEOUT:-600}"
        local bench_model_rc=0
        # Use || to capture non-zero exit codes safely under set -e.
        __bench_run_with_timeout "$bench_model_timeout" __bench_run_single_model "${b_num[$i]}" || bench_model_rc=$?
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
        printf "\nClearing VRAM\n"
        sudo -n /usr/local/bin/clear_vram.sh >/dev/null 2>&1 || true
        # Always clean up any leaked overrides between model iterations.
        # LLAMA_GPU_LAYERS etc. may have been set by a previous model's safe
        # override block and persist into the next model if that model doesn't
        # enter the override block._bench_safe_overrides only tracks whether
        # //WE// set them, but another iteration may have set them earlier.
        unset LLAMA_GPU_LAYERS TAC_CTX_SIZE LLAMA_BATCH_SIZE LLAMA_UBATCH_SIZE LLAMA_PARALLEL_SLOTS
        # Cooldown: let WSL2 9p drvfs flush cached file handles and release
        # any lingering locks on the previous model's GGUF before the next
        # model starts. Without this, rapid model cycling causes curl 52
        # (empty reply) as llama-server stalls on congested I/O.
        local _cooldown_s="${LLM_BENCH_COOLDOWN_SEC:-4}"
        [[ "$_cooldown_s" =~ ^[0-9]+$ ]] || _cooldown_s=4
        if (( _cooldown_s > 0 )); then
            sync 2>/dev/null || true
            sleep "$_cooldown_s"
        fi
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
    bench_file="$HOME/.llm/bench_$(date +%Y%m%d_%H%M%S).tsv"
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

    # Rotate old bench log directories — keep only the last 5 runs.
    local _bench_log_base="${TAC_CACHE_DIR:-/dev/shm}/llm-bench-logs"
    if [[ -d "$_bench_log_base" ]]
    then
        local _stale_count
        _stale_count=$(find "$_bench_log_base" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l)
        if (( _stale_count > 5 ))
        then
            find "$_bench_log_base" -maxdepth 1 -mindepth 1 -type d -printf '%T@ %p\n' 2>/dev/null \
                | sort -n | head -n $(( _stale_count - 5 )) | cut -d' ' -f2- \
                | while IFS= read -r _old_dir; do rm -rf "$_old_dir" 2>/dev/null || true; done
        fi
    fi

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
        rm -f "$bench_lock_file"
    fi
    __bench_restore_traps
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
        __tac_info "Hint" "Need two bench TSVs in $HOME/.llm" "$C_Dim"
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
    done < <(find "$HOME/.llm" -maxdepth 1 -name 'bench_*.tsv' -type f \
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
# __model_bench_trend
# @description Compare latest two bench TSV files and flag per-model TPS drops >15%.
# Stores a basic benchmark history so regressions are visible without manual
# comparison.  Flags models whose TPS dropped >15% from the previous run.
#
# Reference: G-6 — node-level slowdown detection
# (source: Kaarat, TDS 2026-06-11)
# ---------------------------------------------------------------------------
function __model_bench_trend() {
    local -a bench_files=()
    while IFS= read -r bench_file
    do
        bench_files+=("$bench_file")
    done < <(find "$HOME/.llm" -maxdepth 1 -name 'bench_*.tsv' -type f \
        -printf '%T@ %p\n' 2>/dev/null | sort -n -r | head -2 | cut -d' ' -f2-)

    if (( ${#bench_files[@]} < 2 ))
    then
        __tac_info "Bench Trend" "[Need at least 2 benchmark runs — only ${#bench_files[@]} found]" "$C_Error"
        return 1
    fi

    local old_file="${bench_files[1]}"  # older
    local new_file="${bench_files[0]}"  # newer (latest)

    # Read per-model TPS from both files (TSV format: #  model  file  tps  ...)
    # Using awk to build lookup from old file, then compare with new file
    local trend_output
    trend_output=$(
        awk -F'\t' '
            function tps_num(raw, val) {
                val = raw
                gsub(/ tps/, "", val)
                return (val ~ /^[0-9.]+$/ ? val + 0 : -1)
            }

            # First file (old): build lookup
            NR == FNR {
                if (FNR == 1 || \$1 == "#") next
                old_tps[\$2] = tps_num(\$4)
                old_ctx[\$2] = \$5  # ctx
                next
            }

            # Second file (new): compare
            {
                if (FNR == 1 || \$1 == "#") next
                if (\$1 == "") next
                new_t = tps_num(\$4)
                old_t = old_tps[\$2]
                if (old_t > 0 && new_t > 0) {
                    pct = (new_t - old_t) / old_t * 100
                    if (pct < -15) {
                        printf "FLAG|%s|%.1f|%.1f|%.0f%%|%s\n", \$2, old_t, new_t, pct, \$5
                    } else if (pct < -5) {
                        printf "WARN|%s|%.1f|%.1f|%.0f%%|%s\n", \$2, old_t, new_t, pct, \$5
                    }
                }
            }
        ' "$old_file" "$new_file"
    )

    if [[ -z "$trend_output" ]]
    then
        __tac_info "Bench Trend" "[No significant TPS changes detected between last two runs]" "$C_Success"
        return 0
    fi

    __tac_header "TPS TREND (last 2 runs)" "open"
    printf "${C_Dim}  %-6s %-50s %10s %10s %8s %s${C_Reset}\n" "STATUS" "MODEL" "OLD TPS" "NEW TPS" "CHANGE" "CTX"
    printf -v _trend_rule '%*s' $((UIWidth - 4)) ''
    _trend_rule="${_trend_rule// /${BOX_SL}}"
    printf "${C_Dim}  %s${C_Reset}\n" "$_trend_rule"

    local old_ifs="$IFS"
    while IFS='|' read -r status model old_tps new_tps pct ctx
    do
        local color="$C_Dim"
        local label="ok"
        case "$status" in
            FLAG) color="$C_Error";  label="DROP" ;;
            WARN) color="$C_Warning"; label="warn" ;;
            *) ;;
        esac
        printf "  ${color}%-6s %-50s %8.1f %8.1f %7.0f%% %s${C_Reset}\n" "$label" "${model:0:50}" "$old_tps" "$new_tps" "$pct" "$ctx"
    done <<< "$trend_output"
    IFS="$old_ifs"
    __tac_footer
    __tac_info "Tip" "Run model bench-diff for detailed per-model comparison" "$C_Dim"
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
        *) ;;
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
        [[ "$header_line" == "#|name|file|size_gb|quant_cache|arch|gpu_layers|ctx|threads|batch|ubatch|parallel|fit_target_mb|backend|mmap_mode|flash_attn|tps|autotuned|is_default|in_vram" ]] && header_ok=1

        local expected_num=1
        local num _name file _rest
        while IFS='|' read -r num _name file _rest
        do
            [[ "$num" == "#" || -z "$num" ]] && continue
            ((++entries_total))
            [[ "$num" == "$expected_num" ]] || numbering_ok=0
            [[ -f "$LLAMA_MODEL_DIR/$file" ]] || ((++missing_files))
            ((++expected_num))
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

    (( registry_exists )) || ((++issues))
    (( header_ok )) || ((++issues))
    (( numbering_ok )) || ((++issues))
    (( missing_files == 0 )) || ((++issues))
    (( default_set )) || ((++issues))
    (( default_in_registry )) || ((++issues))
    (( gpu_visible )) || ((++issues))

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
    local num name file size quant_cache arch gpu_layers ctx threads batch ubatch parallel fit_target_mb backend mmap_mode flash_attn tps autotuned is_default in_vram
    while IFS='|' read -r num name file size quant_cache arch gpu_layers ctx threads batch ubatch parallel fit_target_mb backend mmap_mode flash_attn tps autotuned is_default in_vram
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
            ((++fail))
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
            ((++fail))
            continue
        fi

        if [[ -z "$dl_file" ]]
        then
            printf '%s\n' \
                "${C_Error}Error:${C_Reset} '$spec' -" \
                "missing filename after colon (e.g. :ferret_7b.Q4_K_M.gguf)"
            ((++fail))
            continue
        fi

        # Path traversal and format validation
        if [[ "$dl_file" == *"/"* || "$dl_file" == *".."* ]]
        then
            printf '%s\n' \
                "${C_Error}Error:${C_Reset} '$spec' - invalid filename (path traversal detected)"
            ((++fail))
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
                    ((++fail))
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
            ((++ok))
            continue
        fi
        if [[ -f "$archive_dest" ]]
        then
            __tac_info "Skip" "$dl_file already exists (archived)" "$C_Warning"
            ((++ok))
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
                    ((++fail))
                    continue
                fi
            fi
        fi

        __tac_info "Downloading" "$dl_repo ${ARROW_R} $dl_file" "$C_Highlight"
        if hf download "$dl_repo" "$dl_file" --local-dir "$LLAMA_MODEL_DIR"
        then
            __tac_info "OK" "$dl_file" "$C_Success"
            ((++ok))
        else
            __tac_info "FAIL" "$dl_repo $dl_file" "$C_Error"
            ((++fail))
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
    echo "  bench [MODEL...] - Benchmark all on-disk models or a selected subset"
    echo "  bench check - Check if a bench run is active (lock status)"
    echo "  bench --help - Show bench-specific usage and selector examples"
    echo "  autotune N [--backend native|python] [--ctx-size N] [--trials N]"
    echo "             - Sweep safe runtime configs and save best profile for model #N"
    echo "  bench-diff - Compare the latest two bench TSVs (or pass old/new files)"
    echo "  bench-compare - Alias for bench-diff"
    echo "  bench-latest - Show the newest saved benchmark TSV"
    echo "  bench-history - Summarise recent saved benchmark TSV runs
  bench-trend   - Compare latest bench TPS vs baseline, flag >15% drops"
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
            # Check subcommand: --check / check queries lock status without running.
            case "${1:-}" in
                --help|-h|help)
                    echo "Usage: model bench [MODEL ...]"
                    echo ""
                    echo "Selectors (OR semantics):"
                    echo "  - Number: exact model row match (e.g. 6 15)"
                    echo "  - Text: case-insensitive substring of model name or file"
                    echo ""
                    echo "Examples:"
                    echo "  model bench"
                    echo "  model bench 6 15"
                    echo "  model bench qwen phi"
                    echo ""
                    echo "Environment knobs:"
                    echo "  LLM_BENCH_MODEL_TIMEOUT      Per-model timeout seconds"
                    echo "  LLM_BENCH_REQUEST_TIMEOUT    Burn request timeout seconds"
                    echo "  LLM_BENCH_BURN_TOKENS        Burn max_tokens (default 768)"
                    echo "  LLM_BENCH_COOLDOWN_SEC       Cooldown between models"
                    return 0
                    ;;
                --check|check)
                    local _bench_lock="${LLM_BENCH_LOCK_FILE:-/tmp/llm-bench.lock}"
                    local _bench_pid="${LLM_BENCH_PID_FILE:-/tmp/llm-bench.pid}"
                    if [[ -f "$_bench_lock" ]]
                    then
                        if command -v lsof >/dev/null 2>&1 && lsof "$_bench_lock" >/dev/null 2>&1
                        then
                            # shellcheck disable=SC2188
                            __tac_info "Bench" "[RUNNING — lock held by PID $(<"$_bench_lock" 2>/dev/null || echo unknown)]" "$C_Warning"
                            return 0
                        else
                            __tac_info "Bench" "[STALE — lock file exists but no active holder]" "$C_Warning"
                            __tac_info "Bench" "[Run 'model bench' to auto-clean and start]" "$C_Dim"
                            return 0
                        fi
                    fi
                    __tac_info "Bench" "[IDLE — no bench running]" "$C_Success"
                    return 0
                    ;;
                *) ;;
            esac
            __model_bench "$@"
            ;;

        autotune)
            # Clear stale traps from previous killed autotune runs
            trap - INT TERM EXIT
            if [[ "${1:-}" == "all" ]]
            then
                shift
                bash "$HOME/ubuntu-console/scripts/run-autotune-batch.sh" 2>&1
                __tac_info "Autotune All" "[Complete — all untuned models processed]" "$C_Success"
                return 0
            fi
            if [[ "${1:-}" == "--help" || "${1:-}" == "-h" || "${1:-}" == "help" ]]
            then
                __model_autotune_help
                return 0
            fi
            # Route to the standalone autotune script (proven, no --fit bug)
            bash "$HOME/ubuntu-console/scripts/autotune-model.sh" "$1" 2>&1
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

        bench-trend)
            __model_bench_trend
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
# end of file
