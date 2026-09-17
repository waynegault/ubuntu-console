# shellcheck shell=bash
# ─── Module: 11b-llm-autotune ───────────────────────────────────────────────────
# AI INSTRUCTION: On ANY change to this file, increment the Module Version below.
# Module Version: 18
# Autotune infrastructure for optimal model parameters
# ────────────────────────────────────────────────────────────────────────────────
# @modular-section: llm-manager
# @depends: constants, llm-model, llm-runtime
# @exports: __llm_autotune_done_for_model,
#   __llm_autotune_profile_save, __llm_autotune_verify_winner,
#   __llm_autotune_estimate_ctx_start, __llm_autotune_profiles_remap_by_registry,
#   __autotune_ctx_bounds
# Idempotent include guard: sub-modules are sourced both by their thin
# loader and directly by the profile/env loaders, so run the body once.
[[ -n "${__TAC_MOD_11B_LLM_AUTOTUNE_LOADED:-}" ]] && return 0
__TAC_MOD_11B_LLM_AUTOTUNE_LOADED=1

# (Removed 2026-09-16, both unreferenced repo-wide: __llm_autotune_blob_upsert — a
# backend-keyed encoded blob — and __llm_autotune_profiles_file, which only ever returned
# $LLM_REGISTRY.  The "profile store" is the registry row itself; the blob predated that.)

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
# __llm_round2 — Render a numeric value to at most 2 decimals, dropping
# trailing zeros/dot (e.g. 143.0963 → 143.1, 88.00 → 88).
# ---------------------------------------------------------------------------
function __llm_round2() {
    awk -v v="$1" 'BEGIN { printf "%.2f", v }' 2>/dev/null | sed -E 's/0+$//; s/\.$//'
}

# ---------------------------------------------------------------------------
# __autotune_ctx_bounds — the ctx-probe floor/ceiling arithmetic, as a pure function.
#   args: start_raw native_ctx vram_mult [min_ctx]
#   stdout: "start_ctx max_ctx min_ctx"
# Every input is an argument and nothing here touches the card, the registry or the
# ledger, so the bounds are testable without a GPU (tests/unit/13-gguf-ctx-bounds.bats).
# That matters because this failure mode is arithmetic, not hardware: on 2026-09-16 a
# ceiling that landed BELOW the floor — MAX_CTX = the model's native window (2048 for
# legalparam) against MIN_CTX = 4096 — made autotune-model.sh's phase-1 loop
# `while [[ $c -ge $MIN_CTX ]]` run ZERO iterations, so the row aborted as an
# "unsupported model" having attempted nothing (three runs, 30 s each, no spawn).
# The invariant callers rely on: 1 <= min_ctx <= start_ctx <= max_ctx.
# native_ctx may be empty/"0" when the GGUF did not yield one.  Then max_ctx stays at
# start_ctx (the climb cannot exceed the KV-math start — pre-existing behaviour, kept
# deliberately: without a native window the only thing above start is the VRAM cap,
# which cannot raise a ceiling).  vram_mult is validated here so a typo cannot reach
# the arithmetic — a bad value warns and becomes 2.
# ---------------------------------------------------------------------------
function __autotune_ctx_bounds() {
    local start="${1:-0}" native="${2:-}" mult="${3:-2}" min_ctx="${4:-4096}"
    local max cap

    if ! [[ "$mult" =~ ^[0-9]+$ ]] || (( mult < 1 )); then
        echo "WARN: vram cap multiplier '$mult' is not a positive integer — using 2" >&2
        mult=2
    fi

    (( start < 1 )) && start=$min_ctx
    start=$(( (start / 1024) * 1024 ))
    (( start < min_ctx )) && start=$min_ctx
    (( start > 4194304 )) && start=4194304

    max=$start
    if [[ "$native" =~ ^[0-9]+$ ]] && (( native > 0 )); then
        max=$native
        (( start > max )) && start=$max
    fi
    (( max > 4194304 )) && max=4194304

    cap=$(( start * mult ))
    (( max > cap )) && max=$cap

    # The floor follows the ceiling down: MIN_CTX is a floor for a USABLE context,
    # not a licence to ask a model for more than it has.
    (( min_ctx > max )) && min_ctx=$max

    printf '%s %s %s\n' "$start" "$max" "$min_ctx"
}

# ---------------------------------------------------------------------------
# __autotune_descent_candidates <from_ctx> <min_ctx> <prev_ctx>
#   stdout: the ctx candidates for a TPS-floor descent, descending, one per line.
#
# The phase-4 descent walks DOWN from the capacity ctx by x3/4 until the filled-cache decode
# holds MIN_TPS.  That ladder can step clean over a value that matters.  Measured 2026-09-17
# on row 12 (Phi-3.5-mini-instruct-Q4_K_M, native 131072): 131072 -> 98304 -> 73728 -> 55296
# -> 41472 -> 30720 -> 23040 -> 16896 -> 12288 -> 9216 -> 6656.  It stepped over 8,192 and
# certified 6,656 without ever testing 8,192.  The filled-cache decode is 5.05 tps at 131072
# and only 6.05 at 9216, then 25.65 at 6,656 — so the 8,192 question sits exactly where the
# answer changes, and the run answered it by arithmetic instead of by measurement.
#
# 8,192 was the value the registry then held for that row, and it was itself an artifact of
# the old GGUF-parser bug (MAX_CTX = 4096 x 2), never a measurement.  That is the failure this
# guards against: a registry value nothing ever verified.  So the previous value is added as a
# candidate, and a run can no longer certify a DIFFERENT window from the one the registry
# holds without having measured the held one — whether that value was a real certification or
# a stale artifact, the new number is now backed by evidence rather than by the ladder's step.
#
# <from_ctx> is EXCLUDED: every caller has just measured it and it failed (the floor, or the
# load), so re-testing would burn a CUDA cycle to re-learn that.  Pure arithmetic — no card,
# no registry — so the ladder is unit-testable (tests/unit/13-gguf-ctx-bounds.bats).
# ---------------------------------------------------------------------------
function __autotune_descent_candidates() {
    local from="${1:-0}" min_ctx="${2:-4096}" prev="${3:-0}"
    [[ "$from" =~ ^[0-9]+$ ]] && (( from > 0 )) || return 0
    [[ "$min_ctx" =~ ^[0-9]+$ ]] && (( min_ctx > 0 )) || min_ctx=4096

    local -a cands=()
    local c="$from" x dup
    while (( c > min_ctx )); do
        c=$(( c * 3 / 4 )); c=$(( c / 512 * 512 ))
        (( c < min_ctx )) && c=$min_ctx
        dup=0
        for x in ${cands[@]+"${cands[@]}"}; do [[ "$x" == "$c" ]] && dup=1; done
        (( dup )) || cands+=("$c")
    done
    # The previously certified window, when it is a real candidate (inside the range and not
    # already on the ladder).
    if [[ "$prev" =~ ^[0-9]+$ ]] && (( prev >= min_ctx && prev < from )); then
        dup=0
        for x in ${cands[@]+"${cands[@]}"}; do [[ "$x" == "$prev" ]] && dup=1; done
        (( dup )) || cands+=("$prev")
    fi
    (( ${#cands[@]} )) || return 0
    printf '%s\n' "${cands[@]}" | LC_ALL=C sort -nr | awk '!seen[$0]++'
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
    local model_ref="${1:-}"
    local requested_backend="${2:-}"
    [[ -n "$model_ref" ]] || return 1

    # A model FILE name is the row's identity; a row NUMBER is accepted and resolved, but
    # the row is matched on the FILE, so a rescan cannot make this report another model's
    # autotune status (it gates the auto-autotune path).
    local model_file=""
    if [[ "$model_ref" =~ ^[0-9]+$ ]]; then
        model_file="$(__llm_registry_file_for_row "$model_ref")"
    else
        model_file="$model_ref"
    fi
    [[ -n "$model_file" ]] || return 1

    if [[ -n "$requested_backend" ]]
    then
        requested_backend=$(__llm_backend_normalize "$requested_backend")
    fi

    # Awk exits 0 if the entry exists AND autotuned=yes for the requested
    # backend, 1 if not found or not yet tuned for that runtime.
    # Default awk exit code is 0 (pattern never matched), so we must force
    # exit 1 when the model row doesn't exist at all.
    awk -F'|' -v f="$model_file" -v want_backend="$requested_backend" '
        function norm_backend(raw) {
            if (raw == "native" || raw == "binary" || raw == "llama-server" || raw == "llama_server") return "native"
            if (raw == "python" || raw == "llama-cpp-python" || raw == "module" || raw == "") return "python"
            return raw
        }
        $3==f {
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
# Registry schema v6 (37 columns): the v5 32 columns plus the AUTOTUNE-001/003
# measurement columns workload(33), ttft_ms(34) and the AUTOTUNE-005
# investigator-observed input profile bench_ctx(35), bench_max_chunks(36),
# bench_avg_prompt_tokens(37).
#   v4 (26 cols)   — pre-spec-decode schema
#   v5 (32 cols)   — SPEC-DEC-004 speculative-decoding fields spec_type(27),
#                    spec_draft_model(28), spec_draft_n_max(29),
#                    spec_draft_ngl(30), spec_draft_device(31),
#                    spec_accept_len(32)
#   v6 (37 cols)   — AUTOTUNE workload(33) + ttft_ms(34) + bench_*(35-37)
# Signature:
#   __llm_autotune_profile_save <model> <backend> <ctx> <batch> <ubatch>
#       <parallel> <fit> <tps> [stamp] [prefill_tps] [p2_ctx] [p2_batch]
#       [p2_ubatch] [p2_tps] [p2_prefill] [kv_quant] [ngl]
#       [spec_type] [spec_draft_model] [spec_n_max] [spec_ngl] [spec_device]
#       [spec_accept_len] [workload] [ttft_ms]
#   Profile 1 (existing columns) = max-ctx config; prefill_tps (col 21) is its
#   prompt-eval throughput. Profile 2 (cols 22-26) = max-decode-TPS config for
#   interactive flows. kv_quant (col 5, "QUANT/type-k/type-v"), ngl (col 7)
#   and the spec fields (cols 27-32) are only written when explicitly
#   provided — legacy callers that omit them leave those fields untouched.
#   workload (col 33) records which scoring prompt set certified the winner
#   (chat|legal|agentic|mix, AUTOTUNE-001); ttft_ms (col 34) is the measured
#   time-to-first-token at the winning ctx (AUTOTUNE-003).  The bench_*
#   columns (35-37) are written by the investigator's bench companion
#   (AUTOTUNE-005), never by this function.
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
    local stamp="${9:-}"
    local prefill_tps="${10:-}"
    local p2_ctx="${11:-}"
    local p2_batch="${12:-}"
    local p2_ubatch="${13:-}"
    local p2_tps="${14:-}"
    local p2_prefill="${15:-}"
    local kv_quant="${16:-}"
    local ngl="${17:-}"
    local spec_type="${18:-}"
    local spec_draft_model="${19:-}"
    local spec_n_max="${20:-}"
    local spec_ngl="${21:-}"
    local spec_device="${22:-}"
    local spec_accept_len="${23:-}"
    local workload="${24:-}"
    local ttft_ms="${25:-}"
    local profile_file="$LLM_REGISTRY"

    # $1 is a row NUMBER or a model FILE name; both are accepted so existing callers
    # keep working, but the row is MATCHED by file name.  A rescan between a run and
    # its save cannot then write one model's measurements onto another (2026-09-16:
    # adding a model moved every row after it, so a number captured before the scan
    # pointed at a different model afterwards).
    local model_file="" _model_row=""
    if [[ "$model_num" =~ ^[0-9]+$ ]]; then
        _model_row="$model_num"
        model_file="$(__llm_registry_file_for_row "$model_num")"
    else
        model_file="$model_num"
        _model_row="$(__llm_registry_row_for_file "$model_num")"
    fi
    # Both must resolve.  A name that is not in the registry used to fall through to an
    # awk that matched nothing: it changed no row and returned 0, so a typo read as a
    # successful save.  Fail loudly instead.
    [[ -n "$model_file" && -n "$_model_row" ]] || return 1

    [[ "$ctx_size" =~ ^[0-9]+$ ]] || return 1
    [[ "$batch" =~ ^[0-9]+$ ]] || return 1
    [[ "$ubatch" =~ ^[0-9]+$ ]] || return 1
    [[ "$parallel" =~ ^[0-9]+$ ]] || return 1
    [[ "$fit_target_mb" =~ ^[0-9]+$ ]] || return 1
    [[ "$tps" =~ ^[0-9]+(\.[0-9]+)?$ ]] || tps="0"

    # Optional profile-2 / measurement fields — empty means "not provided":
    # keep whatever the row already holds (or pad empty for legacy rows).
    [[ "$stamp" =~ ^[0-9]+$ ]] || stamp=""
    [[ "$prefill_tps" =~ ^[0-9]+(\.[0-9]+)?$ ]] || prefill_tps=""
    [[ "$p2_ctx" =~ ^[0-9]+$ ]] || p2_ctx=""
    [[ "$p2_batch" =~ ^[0-9]+$ ]] || p2_batch=""
    [[ "$p2_ubatch" =~ ^[0-9]+$ ]] || p2_ubatch=""
    [[ "$p2_tps" =~ ^[0-9]+(\.[0-9]+)?$ ]] || p2_tps=""
    [[ "$p2_prefill" =~ ^[0-9]+(\.[0-9]+)?$ ]] || p2_prefill=""
    kv_quant=$(__llm_autotune_sanitize_token "$kv_quant")
    [[ "$ngl" =~ ^[0-9]+$ ]] || ngl=""
    spec_type=$(__llm_autotune_sanitize_token "$spec_type")
    spec_draft_model=$(__llm_autotune_sanitize_token "$spec_draft_model")
    [[ "$spec_n_max" =~ ^[0-9]+$ ]] || spec_n_max=""
    [[ "$spec_ngl" =~ ^[0-9]+$ ]] || spec_ngl=""
    spec_device=$(__llm_autotune_sanitize_token "$spec_device")
    [[ "$spec_accept_len" =~ ^[0-9]+(\.[0-9]+)?$ ]] || spec_accept_len=""
    workload=$(__llm_autotune_sanitize_token "$workload")
    [[ "$ttft_ms" =~ ^[0-9]+(\.[0-9]+)?$ ]] || ttft_ms=""

    # Registry hygiene: persist measured floats at a maximum of 2 decimal
    # places. The server timings carry full float64 precision (e.g. prefill
    # 143.09630118625265), which is noise in a config file consumers parse.
    tps=$(__llm_round2 "$tps")
    [[ -n "$prefill_tps" ]] && prefill_tps=$(__llm_round2 "$prefill_tps")
    [[ -n "$p2_tps" ]] && p2_tps=$(__llm_round2 "$p2_tps")
    [[ -n "$p2_prefill" ]] && p2_prefill=$(__llm_round2 "$p2_prefill")

    [[ -f "$profile_file" ]] || return 1

    # Update the model row in-place via awk: fields 8 (ctx), 10 (batch),
    # 11 (ubatch), 12 (parallel), 13 (fit), 14 (backend), 16 (flash_attn),
    # 17 (tps), 18 (autotuned); optional 5 (kv quant), 7 (ngl), 21-26
    # (prefill + profile 2). Legacy 20-column rows are padded to 26 so the
    # registry converges to the v4 schema on first save.
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

    awk -F'|' -v f="$model_file" \
        -v ctx="$ctx_size" \
        -v batch="$batch" \
        -v ubatch="$ubatch" \
        -v parallel="$parallel" \
        -v fit="$fit_target_mb" \
        -v backend="$backend" \
        -v tps_val="$tps" \
        -v prefill_val="$prefill_tps" \
        -v p2_ctx_val="$p2_ctx" \
        -v p2_batch_val="$p2_batch" \
        -v p2_ubatch_val="$p2_ubatch" \
        -v p2_tps_val="$p2_tps" \
        -v p2_prefill_val="$p2_prefill" \
        -v kv_quant_val="$kv_quant" \
        -v ngl_val="$ngl" \
        -v spec_type_val="$spec_type" \
        -v spec_draft_model_val="$spec_draft_model" \
        -v spec_n_max_val="$spec_n_max" \
        -v spec_ngl_val="$spec_ngl" \
        -v spec_device_val="$spec_device" \
        -v spec_accept_len_val="$spec_accept_len" \
        -v workload_val="$workload" \
        -v ttft_ms_val="$ttft_ms" \
        'BEGIN {
            OFS="|"
            # Emit header unconditionally so a headerless registry
            # does not self-perpetuate (same guard as sync_state).
            print "#|name|file|size_gb|quant_cache|arch|gpu_layers|ctx|threads|batch|ubatch|parallel|fit_target_mb|backend|mmap_mode|flash_attn|tps|autotuned|is_default|in_vram|prefill_tps|p2_ctx|p2_batch|p2_ubatch|p2_tps|p2_prefill|spec_type|spec_draft_model|spec_draft_n_max|spec_draft_ngl|spec_draft_device|spec_accept_len|workload|ttft_ms|bench_ctx|bench_max_chunks|bench_avg_prompt_tokens"
        }
        $1 == "#" { next }
        {
            # Pad legacy 20/26/32-column rows to the v6 37-column schema
            # BEFORE any field writes — awk extends NF only as far as the
            # highest assigned column, so a later $33 write would otherwise
            # cap the padded row at 33 columns.
            if (NF >= 20 && NF < 37) { for (i = NF + 1; i <= 37; i++) $i = "" }
            if ($3 == f) {
                $8 = ctx; $10 = batch; $11 = ubatch; $12 = parallel
                $13 = fit; $14 = backend
                if ($16 == "") $16 = "on"
                $17 = tps_val; $18 = "yes"
                if (kv_quant_val != "") $5 = kv_quant_val
                if (ngl_val != "") $7 = ngl_val
                if (prefill_val != "") $21 = prefill_val
                if (p2_ctx_val != "") {
                    $22 = p2_ctx_val; $23 = p2_batch_val; $24 = p2_ubatch_val
                    $25 = p2_tps_val; $26 = p2_prefill_val
                }
                if (spec_type_val != "") $27 = spec_type_val
                if (spec_draft_model_val != "") $28 = spec_draft_model_val
                if (spec_n_max_val != "") $29 = spec_n_max_val
                if (spec_ngl_val != "") $30 = spec_ngl_val
                if (spec_device_val != "") $31 = spec_device_val
                if (spec_accept_len_val != "") $32 = spec_accept_len_val
                if (workload_val != "") $33 = workload_val
                if (ttft_ms_val != "") $34 = ttft_ms_val
            }
            # SPEC-DEC-002: clamp the stored thread count to the i9-12900HK
            # P-core ceiling (6) on every registry write — a pre-cap row must
            # not survive the save with an E-core-spilling value.
            if ($9 != "" && $9 + 0 > 6) $9 = 6
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

    if ! burn >"$verify_log" 2>&1
    then
        __model_stop >/dev/null 2>&1 || true
        return 1
    fi

    local verify_tps
    verify_tps=$(sed -n 's/.*Burn complete: \([0-9][0-9]*\(\.[0-9][0-9]*\)\?\) tps.*/\1/p' "$verify_log" | tail -n1)
    __model_stop >/dev/null 2>&1 || true

    if [[ "$verify_tps" =~ ^[0-9]+(\.[0-9]+)?$ ]]
    then
        printf '%s' "$verify_tps"
        return 0
    fi
    return 1
}

# ---------------------------------------------------------------------------
# __kv_mb_per_1k M-bM-^@M-^T Estimate KV cache cost per 1K tokens (G-5 audit).
# Uses n_layers when available (from GGUF metadata), falls back to 48.0 MB/1K.
# The old sqrt(model_mb)*0.08 heuristic was 8-48x too optimistic.
# Reference: llama.cpp KV cache = (K_dtype + V_dtype) * n_embd_head * n_kv_heads * n_layers
# The autotune runs --cache-type-k/v q8_0 (both K and V quantized), so the cost
# per layer per 1K tokens is 2 * n_kv_heads * head_dim bytes. For a 3B-class
# model (8 KV heads, 128 head dim) that is ~2.1 MB/layer/1K. The prior 0.5
# assumed only 2 KV heads and under-estimated ~4x, so START_CTX overshot into
# the KV-spill regime (a 2.5GB model got 109K when its filled-cache ceiling is
# ~27K) — which wasted Phase-4 descent levels AND leaked GPU VA on every
# huge-ctx CUDA context (WSL2 dxgkrnl degradation, 2026-09-05).
# ---------------------------------------------------------------------------
function __kv_mb_per_1k() {
    local n_layers="${1:-0}"
    [[ "$n_layers" =~ ^[0-9]+$ ]] || n_layers=0
    if (( n_layers > 0 )); then
        awk -v L="$n_layers" 'BEGIN{printf "%.2f", L * 2.0}'
    else
        echo "48.0"
    fi
}

# ---------------------------------------------------------------------------
# __llm_autotune_estimate_ctx_start — Estimate a useful initial ctx probe.
# Uses saved ctx/TPS plus rough model-size and free-VRAM heuristics so autotune
# starts near the likely throughput-stable range instead of a flat default.
# @args <saved_ctx> <saved_tps> <min_tps> <max_ctx> <model_bytes> <free_vram_mb> <n_layers>
# @stdout Estimated ctx rounded to 512.
# ---------------------------------------------------------------------------
function __llm_autotune_estimate_ctx_start() {
    local saved_ctx="${1:-}"
    local saved_tps="${2:-}"
    local min_tps="${3:-0}"
    local max_ctx="${4:-8192}"
    local model_bytes="${5:-0}"
    local free_vram_mb="${6:-0}"
    local n_layers="${7:-0}"

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

    # Saved ctx should not drag the starting point downward when stale.
    # Use it only to raise the baseline unless we also have saved TPS, where
    # ratio-based scaling below can make a more informed adjustment.
    if [[ "$saved_ctx" =~ ^[0-9]+$ ]] && (( saved_ctx > estimate ))
    then
        estimate="$saved_ctx"
    fi

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
    (( dynamic_start_floor > max_ctx )) && dynamic_start_floor="$max_ctx"
    dynamic_start_floor=$(( (dynamic_start_floor / 512) * 512 ))
    (( dynamic_start_floor < model_baseline_ctx )) && dynamic_start_floor="$model_baseline_ctx"
    if (( estimate < dynamic_start_floor ))
    then
        estimate="$dynamic_start_floor"
    fi

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
            print "#|name|file|size_gb|quant_cache|arch|gpu_layers|ctx|threads|batch|ubatch|parallel|fit_target_mb|backend|mmap_mode|flash_attn|tps|autotuned|is_default|in_vram|prefill_tps|p2_ctx|p2_batch|p2_ubatch|p2_tps|p2_prefill|spec_type|spec_draft_model|spec_draft_n_max|spec_draft_ngl|spec_draft_device|spec_accept_len"
        }
        FNR == NR {
            if ($1 != "#" && (NF == 20 || NF == 26 || NF == 32)) {
                key=$3
                old_ctx[key]=$8; old_thr[key]=$9; old_batch[key]=$10; old_ub[key]=$11
                old_par[key]=$12; old_fit[key]=$13; old_be[key]=$14
                old_mm[key]=$15; old_fa[key]=$16; old_tps[key]=$17; old_done[key]=$18
                old_pf[key]=$21; old_p2c[key]=$22; old_p2b[key]=$23; old_p2u[key]=$24
                old_p2t[key]=$25; old_p2pf[key]=$26
                old_st[key]=$27; old_sdm[key]=$28; old_snm[key]=$29
                old_snl[key]=$30; old_sdv[key]=$31; old_sal[key]=$32
            }
            next
        }
        {
            if ($1 == "#" || (NF != 20 && NF != 26 && NF != 32)) { next }
            key=$3
            if (key in old_ctx) {
                $8=old_ctx[key]; $9=old_thr[key]; $10=old_batch[key]; $11=old_ub[key]
                $12=old_par[key]; $13=old_fit[key]; $14=old_be[key]; $15=old_mm[key];
                $16=old_fa[key]; $17=old_tps[key]; $18=old_done[key]
                $21=old_pf[key]; $22=old_p2c[key]; $23=old_p2b[key]; $24=old_p2u[key]
                $25=old_p2t[key]; $26=old_p2pf[key]
                if (old_st[key] != "") $27=old_st[key]
                if (old_sdm[key] != "") $28=old_sdm[key]
                if (old_snm[key] != "") $29=old_snm[key]
                if (old_snl[key] != "") $30=old_snl[key]
                if (old_sdv[key] != "") $31=old_sdv[key]
                if (old_sal[key] != "") $32=old_sal[key]
            }
            if ($16 == "") $16="on"
            # SPEC-DEC-002: clamp the carried thread count to the i9-12900HK
            # P-core ceiling (6) — a pre-cap registry must not reintroduce
            # E-core-spilling threads through a remap.
            if ($9 != "" && $9 + 0 > 6) $9 = 6
            if (NF == 20) { for (i=21; i<=32; i++) $i="" }
            if (NF == 26) { for (i=27; i<=32; i++) $i="" }
            print $1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17,$18,$19,$20,$21,$22,$23,$24,$25,$26,$27,$28,$29,$30,$31,$32
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

# end of file
