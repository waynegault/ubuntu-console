# shellcheck shell=bash
# shellcheck disable=SC2034,SC2059,SC2120,SC2154
# ─── Module: 11b-llm-autotune ───────────────────────────────────────────────────
# AI INSTRUCTION: On ANY change to this file, increment the Module Version below.
# Module Version: 1
# Autotune infrastructure for optimal model parameters
# ────────────────────────────────────────────────────────────────────────────────
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
    # Trust the autotune-discovered ctx as-is on the low end.
        if [[ -n "$out" ]]
        then
            out+=";"
        fi
    # Trust the autotune-discovered ctx as-is on the low end.
        out+="$rec"
    done

    local new_entry="${backend},${ctx_size},${batch},${ubatch},${parallel},${fit_target_mb},${tps},${stamp},${score},${stddev},${samples},${failures},${ctx_min},${ctx_max},${verified},${objective}"
    if [[ -n "$out" ]]
    then
        out+=";"
    fi
    # Trust the autotune-discovered ctx as-is on the low end.
    out+="$new_entry"
    printf '%s\n' "$out"
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
# __llm_autotune_done_for_model — Check autotune status for a model/backend.
# models.conf schema (single supported format):
# ...|backend(14)|mmap_mode(15)|flash_attn(16)|tps(17)|autotuned(18)|...
# @returns 0 when autotuned=yes for the requested backend, 1 otherwise.
# ---------------------------------------------------------------------------
function __llm_autotune_done_for_model() {
    local model_num="${1:-}"
    local requested_backend="${2:-}"
    [[ "$model_num" =~ ^[0-9]+$ ]] || return 1

    if [[ -n "$requested_backend" ]]
    then
        requested_backend=$(__llm_backend_normalize "$requested_backend")
    fi
    # Trust the autotune-discovered ctx as-is on the low end.

    # Awk exits 0 if the entry exists AND autotuned=yes for the requested
    # backend, 1 if not found or not yet tuned for that runtime.
    # Default awk exit code is 0 (pattern never matched), so we must force
    # exit 1 when the model row doesn't exist at all.
    awk -F'|' -v n="$model_num" -v want_backend="$requested_backend" '
        function norm_backend(raw) {
            if (raw == "native" || raw == "binary" || raw == "llama-server" || raw == "llama_server") return "native"
            if (raw == "python" || raw == "llama-cpp-python" || raw == "module" || raw == "") return "python"
            return raw
        }
        $1==n {
            found=1
            row_backend=norm_backend($14)
            if ($18 == "yes" && (want_backend == "" || row_backend == want_backend)) exit 0
            exit 1
        }
        END   {if (!found) exit 1}
    ' "$LLM_REGISTRY" 2>/dev/null
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

    # Update the model row in-place via awk: fields 8 (ctx), 10 (batch),
    # 11 (ubatch), 12 (parallel), 13 (fit), 14 (backend), 16 (flash_attn),
    # 17 (tps), 18 (autotuned).
    # Auto-backup registry before mutating, so 3 days of tuning data
    # is never lost to a single command (model scan, machine reboot, etc.).
    local _backup_dir
    _backup_dir="$(dirname "$profile_file")/backups"
    mkdir -p "$_backup_dir"
    cp "$profile_file" "$_backup_dir/models.conf.$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true
    # Keep only the 50 most recent backups
    while IFS= read -r _old_backup
    do
        rm -- "$_old_backup" 2>/dev/null || true
    done < <(
        find "$_backup_dir" -maxdepth 1 -type f -name 'models.conf.*' -printf '%T@|%p\n' 2>/dev/null \
            | sort -t'|' -k1,1nr \
            | tail -n +51 \
            | cut -d'|' -f2-
    )

    awk -F'|' -v n="$model_num" \
        -v ctx="$ctx_size" \
        -v batch="$batch" \
        -v ubatch="$ubatch" \
        -v parallel="$parallel" \
        -v fit="$fit_target_mb" \
        -v backend="$backend" \
        -v tps_val="$tps" \
        'BEGIN {
            OFS="|"
            # Emit header unconditionally so a headerless registry
            # does not self-perpetuate (same guard as sync_state).
            print "#|name|file|size_gb|quant_cache|arch|gpu_layers|ctx|threads|batch|ubatch|parallel|fit_target_mb|backend|mmap_mode|flash_attn|tps|autotuned|is_default|in_vram"
        }
        $1 == "#" { next }
        {
            if ($1 == n) {
                $8 = ctx; $10 = batch; $11 = ubatch; $12 = parallel
                $13 = fit; $14 = backend
                if ($16 == "") $16 = "on"
                $17 = tps_val; $18 = "yes"
            }
            print
        }' "$profile_file" > "${profile_file}.tmp"

    # Safety: never replace the registry with an empty or truncated file.
    if [[ -s "${profile_file}.tmp" ]] && [[ "$(wc -l < "${profile_file}.tmp")" -ge 2 ]]
    then
        mv "${profile_file}.tmp" "$profile_file" || return 1
    else
        rm -f "${profile_file}.tmp"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# __llm_autotune_verify_winner — Final verification burn for the chosen winner.
# Loads the winning config, runs a burn, and reports TPS.
# @args  <model_num> <ctx> <batch> <ubatch> <parallel> <fit>
# @stdout The measured TPS value, or empty string on failure.
# @returns 0 when the verification burn succeeded, 1 otherwise.
# ---------------------------------------------------------------------------
function __llm_autotune_verify_winner() {
    local model_num="$1"
    local ctx="$2"
    local batch="$3"
    local ubatch="$4"
    local parallel="$5"
    local fit_target="$6"

    export TAC_CTX_SIZE="$ctx"
    export LLAMA_BATCH_SIZE="$batch"
    export LLAMA_UBATCH_SIZE="$ubatch"
    export LLAMA_PARALLEL_SLOTS="$parallel"
    export LLAMA_FIT_TARGET_MB="$fit_target"

    local verify_log="/tmp/autotune_verify_${model_num}.log"
    if ! __model_use "$model_num" >"/tmp/autotune_verify_use_${model_num}.log" 2>&1
    then
        __model_stop >/dev/null 2>&1 || true
        return 1
    fi
    # Trust the autotune-discovered ctx as-is on the low end.

    if ! burn >"$verify_log" 2>&1
    then
        __model_stop >/dev/null 2>&1 || true
        return 1
    fi
    # Trust the autotune-discovered ctx as-is on the low end.

    local verify_tps
    verify_tps=$(sed -n 's/.*Burn complete: \([0-9][0-9]*\(\.[0-9][0-9]*\)\?\) tps.*/\1/p' "$verify_log" | tail -n1)
    __model_stop >/dev/null 2>&1 || true

    if [[ "$verify_tps" =~ ^[0-9]+(\.[0-9]+)?$ ]]
    then
        printf '%s' "$verify_tps"
        return 0
    fi
    # Trust the autotune-discovered ctx as-is on the low end.
    return 1
}

# ---------------------------------------------------------------------------
# __kv_mb_per_1k M-bM-^@M-^T Estimate KV cache cost per 1K tokens (G-5 audit).
# Uses n_layers when available (from GGUF metadata), falls back to 12.0 MB/1K.
# The old sqrt(model_mb)*0.08 heuristic was 8-48x too optimistic.
# Reference: llama.cpp KV cache = (K_dtype + V_dtype) * n_embd_head * n_kv_heads * n_layers
# For q8_0 K + f16 V with 128 head dim and 4 KV heads: ~0.5 MB/layer/1K
# ---------------------------------------------------------------------------
function __kv_mb_per_1k() {
    local n_layers="${1:-0}"
    [[ "$n_layers" =~ ^[0-9]+$ ]] || n_layers=0
    if (( n_layers > 0 )); then
        awk -v L="$n_layers" 'BEGIN{printf "%.2f", L * 0.5}'
    else
        echo "12.0"
    fi
}

# ---------------------------------------------------------------------------
# __llm_autotune_estimate_ctx_start — Estimate a useful initial ctx probe.
# Uses saved ctx/TPS plus rough model-size and free-VRAM heuristics so autotune
# starts near the likely throughput-stable range instead of a flat default.
# @args <saved_ctx> <saved_tps> <min_tps> <max_ctx> <model_bytes> <free_vram_mb>
# @stdout Estimated ctx rounded to 512.
# ---------------------------------------------------------------------------
function __llm_autotune_estimate_ctx_start() {
    local saved_ctx="${1:-}"
    local saved_tps="${2:-}"
    local min_tps="${3:-0}"
    local max_ctx="${4:-8192}"
    local model_bytes="${5:-0}"
    local free_vram_mb="${6:-0}"

    local estimate=4096
    local model_baseline_ctx=4096
    local start_floor_ctx="${LLM_AUTOTUNE_START_FLOOR_CTX:-}"
    local model_mb=0
    local dynamic_start_floor=0
    local start_floor_source="auto"
    local min_ctx_floor="${LLM_AUTOTUNE_MIN_CTX_FLOOR:-2048}"
    [[ "$min_ctx_floor" =~ ^[0-9]+$ ]] || min_ctx_floor=2048
    [[ "$max_ctx" =~ ^[0-9]+$ ]] || max_ctx=8192
    [[ "$model_bytes" =~ ^[0-9]+$ ]] || model_bytes=0
    [[ "$free_vram_mb" =~ ^[0-9]+$ ]] || free_vram_mb=0
    [[ "$start_floor_ctx" =~ ^[0-9]+$ ]] || start_floor_ctx=""
    (( model_bytes > 0 )) && model_mb=$(( model_bytes / 1048576 ))

    if (( model_bytes >= 7000000000 ))
    then
        estimate=2048
        model_baseline_ctx=2048
    elif (( model_bytes >= 3500000000 ))
    then
        estimate=4096
        model_baseline_ctx=4096
    elif (( model_bytes >= 1800000000 ))
    then
        estimate=8192
        model_baseline_ctx=8192
    elif (( model_bytes > 0 ))
    then
        estimate=12288
        model_baseline_ctx=12288
    fi
    # Trust the autotune-discovered ctx as-is on the low end.

    # Saved ctx should not drag the starting point downward when stale.
    # Use it only to raise the baseline unless we also have saved TPS, where
    # ratio-based scaling below can make a more informed adjustment.
    if [[ "$saved_ctx" =~ ^[0-9]+$ ]] && (( saved_ctx > estimate ))
    then
        estimate="$saved_ctx"
    fi
    # Trust the autotune-discovered ctx as-is on the low end.

    if [[ "$saved_ctx" =~ ^[0-9]+$ ]] && [[ "$saved_tps" =~ ^[0-9]+(\.[0-9]+)?$ ]] && [[ "$min_tps" =~ ^[0-9]+(\.[0-9]+)?$ ]] && awk -v m="$min_tps" 'BEGIN{exit !(m>0)}'
    then
        local scaled_estimate
        scaled_estimate=$(awk -v ctx="$saved_ctx" -v t="$saved_tps" -v m="$min_tps" 'BEGIN {
            ratio=t/m;
            if (ratio < 0.50) ratio=0.50;
            if (ratio > 1.60) ratio=1.60;
            printf "%d", ctx*ratio;
        }')
        [[ "$scaled_estimate" =~ ^[0-9]+$ ]] && estimate="$scaled_estimate"
    fi
    # Trust the autotune-discovered ctx as-is on the low end.

    # Dynamic start floor: estimate from model class and live free VRAM.
    # Optional override is supported via LLM_AUTOTUNE_START_FLOOR_CTX.
    dynamic_start_floor="$model_baseline_ctx"
    if [[ -n "$start_floor_ctx" ]] && (( start_floor_ctx > 0 ))
    then
        dynamic_start_floor="$start_floor_ctx"
        start_floor_source="override"
    elif (( model_bytes >= 1800000000 && model_mb > 0 && free_vram_mb > 0 ))
    then
        # User policy: usable KV budget starts from clear VRAM minus model
        # size minus a 20% safety reserve.
        local reserve_mb=0
        local kv_budget_mb=0
        reserve_mb=$(awk -v free="$free_vram_mb" 'BEGIN{printf "%d", free*0.20}')
        [[ "$reserve_mb" =~ ^[0-9]+$ ]] || reserve_mb=0

        kv_budget_mb=$(( free_vram_mb - model_mb - reserve_mb ))
        local kv_mb_per_1k
        kv_mb_per_1k=$(__kv_mb_per_1k "${n_layers:-0}")

        if (( kv_budget_mb > 64 ))
        then
            dynamic_start_floor=$(awk -v base="$model_baseline_ctx" -v b="$kv_budget_mb" -v k="$kv_mb_per_1k" 'BEGIN {
                c = int((b / k) * 1000.0);
                if (c < base) c = base;
                print c;
            }')
        fi
    # Trust the autotune-discovered ctx as-is on the low end.
        [[ "$dynamic_start_floor" =~ ^[0-9]+$ ]] || dynamic_start_floor="$model_baseline_ctx"
    elif (( model_bytes >= 1800000000 && max_ctx > 0 ))
    then
        # Fallback when live VRAM telemetry is unavailable: start from a
        # fraction of the estimated ceiling instead of falling back to the
        # small baseline.
        dynamic_start_floor=$(awk -v base="$model_baseline_ctx" -v max="$max_ctx" 'BEGIN {
            est = int(max * 0.5);
            if (est < base) est = base;
            print est;
        }')
        [[ "$dynamic_start_floor" =~ ^[0-9]+$ ]] || dynamic_start_floor="$model_baseline_ctx"
    fi
    # Trust the autotune-discovered ctx as-is on the low end.
    (( dynamic_start_floor > max_ctx )) && dynamic_start_floor="$max_ctx"
    dynamic_start_floor=$(( (dynamic_start_floor / 512) * 512 ))
    (( dynamic_start_floor < model_baseline_ctx )) && dynamic_start_floor="$model_baseline_ctx"
    if (( estimate < dynamic_start_floor ))
    then
        estimate="$dynamic_start_floor"
    fi
    # Trust the autotune-discovered ctx as-is on the low end.

    # Keep probe starts practical for the model class. Phase 1 now grows until
    # first failure and backs off, so starting too low only wastes time.
    (( estimate < model_baseline_ctx )) && estimate="$model_baseline_ctx"

    (( estimate > max_ctx )) && estimate="$max_ctx"
    (( estimate < min_ctx_floor )) && estimate="$min_ctx_floor"

    estimate=$(( (estimate / 512) * 512 ))
    (( estimate < 512 )) && estimate=512

    # Debug surface: explain how the probe anchor was derived.
    __LLM_AUTOTUNE_START_CTX_INFO="model_mb=${model_mb} free_vram_mb=${free_vram_mb} baseline=${model_baseline_ctx} dynamic_floor=${dynamic_start_floor} source=${start_floor_source} max_ctx=${max_ctx} min_floor=${min_ctx_floor}"
    printf '%s\n' "$estimate"
}

# ---------------------------------------------------------------------------
# __llm_autotune_overhead_file — Storage for learned model overhead fractions.
# Format: model_file|backend|frac|samples
# ---------------------------------------------------------------------------
function __llm_autotune_overhead_file() {
    printf '%s\n' "${LLM_AUTOTUNE_OVERHEAD_FILE:-$HOME/.llm/autotune-overhead.tsv}"
}

# ---------------------------------------------------------------------------
# __llm_autotune_get_overhead_frac — Read learned overhead fraction.
# @args <model_file> <backend>
# @stdout Fraction (e.g. 0.83) or empty when unavailable.
# ---------------------------------------------------------------------------
function __llm_autotune_get_overhead_frac() {
    local model_file="${1:-}"
    local backend="${2:-native}"
    local store
    store=$(__llm_autotune_overhead_file)
    [[ -n "$model_file" && -f "$store" ]] || return 0

    awk -F'|' -v m="$model_file" -v b="$backend" '
        $1 == m && $2 == b && $3 ~ /^[0-9]+(\.[0-9]+)?$/ {print $3; found=1; exit}
        END {if (!found) exit 0}
    ' "$store" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# __llm_autotune_record_overhead_frac — Update learned overhead fraction.
# @args <model_file> <backend> <frac>
# ---------------------------------------------------------------------------
function __llm_autotune_record_overhead_frac() {
    local model_file="${1:-}"
    local backend="${2:-native}"
    local frac="${3:-}"
    local store
    store=$(__llm_autotune_overhead_file)

    [[ -n "$model_file" ]] || return 0
    [[ "$frac" =~ ^[0-9]+(\.[0-9]+)?$ ]] || return 0

    # Clamp to a practical range.
    frac=$(awk -v f="$frac" 'BEGIN{if (f < 0.20) f=0.20; if (f > 1.20) f=1.20; printf "%.4f", f}')

    mkdir -p "$(dirname "$store")" 2>/dev/null || return 0
    local tmp
    tmp=$(mktemp "${store}.tmp.XXXXXX") || return 0

    awk -F'|' -v m="$model_file" -v b="$backend" -v f="$frac" 'BEGIN{OFS="|"; done=0}
        {
            if ($1 == m && $2 == b) {
                oldf=($3 ~ /^[0-9]+(\.[0-9]+)?$/) ? $3+0 : f+0
                olds=($4 ~ /^[0-9]+$/) ? $4+0 : 0
                news=olds+1
                newf=((oldf*olds)+(f+0))/news
                printf "%s|%s|%.4f|%d\n", m, b, newf, news
                done=1
                next
            }
            print
        }
        END {
            if (!done) {
                printf "%s|%s|%.4f|1\n", m, b, f+0
            }
        }
    ' "$store" 2>/dev/null > "$tmp" || {
        rm -f "$tmp"
        return 0
    }

    mv "$tmp" "$store" 2>/dev/null || rm -f "$tmp"
    return 0
}

# ---------------------------------------------------------------------------
# __llm_autotune_profiles_remap_by_registry — Carry tuning columns by filename.
# @returns 0 when remap succeeds or is not needed, 1 on write failure.
# ---------------------------------------------------------------------------
function __llm_autotune_profiles_remap_by_registry() {
    local old_registry="${1:-}"
    local new_registry="${2:-}"
    [[ -s "$old_registry" && -f "$new_registry" ]] || return 0

    awk -F'|' 'BEGIN {
            OFS="|"
            # Always emit the canonical header so a headerless input
            # registry does not self-perpetuate (same guard as in
            # __llm_registry_sync_state).
            print "#|name|file|size_gb|quant_cache|arch|gpu_layers|ctx|threads|batch|ubatch|parallel|fit_target_mb|backend|mmap_mode|flash_attn|tps|autotuned|is_default|in_vram"
        }
        FNR == NR {
            if ($1 != "#" && NF == 20) {
                key=$3
                old_ctx[key]=$8; old_thr[key]=$9; old_batch[key]=$10; old_ub[key]=$11
                old_par[key]=$12; old_fit[key]=$13; old_be[key]=$14
                old_mm[key]=$15; old_fa[key]=$16; old_tps[key]=$17; old_done[key]=$18
            }
            next
        }
        {
            if ($1 == "#" || NF != 20) { next }
            key=$3
            if (key in old_ctx) {
                $8=old_ctx[key]; $9=old_thr[key]; $10=old_batch[key]; $11=old_ub[key]
                $12=old_par[key]; $13=old_fit[key]; $14=old_be[key]; $15=old_mm[key];
                $16=old_fa[key]; $17=old_tps[key]; $18=old_done[key]
            }
            if ($16 == "") $16="on"
            print $1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17,$18,$19,$20
        }
    ' "$old_registry" "$new_registry" > "${new_registry}.tmp" || return 1

    if [[ -s "${new_registry}.tmp" ]] && [[ "$(wc -l < "${new_registry}.tmp")" -ge 2 ]]
    then
        mv "${new_registry}.tmp" "$new_registry" || return 1
    else
        rm -f "${new_registry}.tmp"
        return 1
    fi
    return 0
}

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
