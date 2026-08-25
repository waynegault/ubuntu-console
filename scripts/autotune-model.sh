#!/home/linuxbrew/.linuxbrew/bin/bash
# shellcheck disable=SC1091
# AI INSTRUCTION: On ANY change to this file, increment the Module Version below.
# Module Version: 11
#===============================================================================
# autotune-model.sh — Find optimal ctx/batch/ubatch for one GGUF model.
#
# Phase 1: step down from start until a ctx works.
# Phase 2: step up 50% from working ctx until OOM, then binary probe
#          between the last working ctx and OOM point.
# Search : beam search over batch/ubatch at the winning ctx; in the "almost
#          fits" band, sweep n_gpu_layers and KV-cache quantization (both can
#          free VRAM for a higher ctx than the registry's 999-or-0 binary).
# Phase 4: TPS floor recovery at a *filled* KV cache — the scoring bench
#          pre-fills the context (LLM_AUTOTUNE_FILL_RATIO x ctx, capped) so
#          the floor certifies sustained throughput at the ctx being recorded,
#          not a burst on an empty cache. Prefill tok/s is captured from the
#          server timings and persisted alongside decode.
# Profiles: profile 1 = max ctx sustaining the floor (existing registry
#          columns); profile 2 = max decode TPS config for interactive flows
#          (registry fields 22-26). Winner recorded even when below floor
#          (best-effort honest capability).
# Score  : highest ctx that meets the TPS floor (best-effort max TPS otherwise).
#
# Sources tactical-console functions for VRAM budget, stale process cleanup,
# GGUF metadata, and profile saving — no duplicates.
#===============================================================================

set -uo pipefail

MODEL="${1:?Usage: autotune-model.sh MODEL_NUM}"
[[ "$MODEL" =~ ^[0-9]+$ ]] || { echo "Error: MODEL_NUM must be a number"; exit 1; }

_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$_SELF_DIR/.." || exit 1
source env.sh 2>/dev/null || { echo "Failed to source env.sh"; exit 1; }
source scripts/01-constants.sh 2>/dev/null || true
source scripts/11-llm-manager.sh 2>/dev/null || true

# Source the tactical console for shared functions (__gguf_metadata, __kv_mb_per_1k,
# __gpu_clear_stale_processes, __llm_autotune_profile_save)
# Falls back to standalone mode if sourcing fails.

ENTRY=$(grep "^${MODEL}|" "$LLM_REGISTRY" 2>/dev/null) || {
    echo "Error: Model #${MODEL} not found in registry"; exit 1; }

IFS='|' read -r _num name file size _qc _arch gpu_layers _ctx _thr _ba _ub _pa _fi _be _mm _fa _tps _autotuned _isdef _vram _prefill _p2ctx _p2b _p2u _p2tps _p2pf <<< "$ENTRY"

MODEL_PATH="$LLAMA_MODEL_DIR/$file"
[[ -f "$MODEL_PATH" ]] || { echo "Error: File not found: $MODEL_PATH"; exit 1; }

SIZE_INT=${size%G}; SIZE_INT=${SIZE_INT%.*}; SIZE_INT=${SIZE_INT:-1}
[[ "$SIZE_INT" =~ ^[0-9]+$ ]] || SIZE_INT=1

CPU_COUNT=$(nproc 2>/dev/null || echo 6)
# SPEC-DEC-002: the thread count is hard-capped at the i9-12900HK P-core
# count (6).  nproc inside WSL2 returns 12 (processors=12 in .wslconfig);
# using it uncapped spills decode onto the E-cores and slows generation
# (DFlash article hardware pitfall).  The cap is applied to registry reads
# AND fallbacks so the registry can never hold a >6 value from here.
# REF: "Speculative Decoding on CPUs — Nearly 4x Faster Token Generation
# with DFlash" (Intel, TDS 2026)
# https://towardsdatascience.com/speculative-decoding-on-cpus-nearly-4x-faster-token-generation-with-dflash/
if ! declare -f __llm_thread_cap &>/dev/null; then
    # Standalone fallback (11d-llm-gpu.sh not sourced): same P-core clamp.
    __llm_thread_cap() {
        local _raw="${1:-6}"
        [[ "$_raw" =~ ^[0-9]+$ ]] || _raw=6
        (( _raw > 6 )) && _raw=6
        echo "$_raw"
    }
fi
if [[ "$_thr" =~ ^[0-9]+$ ]] && [[ $_thr -gt 0 ]] && [[ $_thr -le $CPU_COUNT ]]; then
    TUNE_THREADS=$(__llm_thread_cap "$_thr")
else
    TUNE_THREADS=$(__llm_thread_cap "$CPU_COUNT")
fi
BENCH_NGL="${gpu_layers:-999}"
[[ ${gpu_layers:-999} -eq 0 ]] && TUNE_THREADS=$(__llm_thread_cap "$CPU_COUNT")

echo "[${MODEL}] ${name} (${size}, ${gpu_layers:-0} gpu layers)"
echo "  Bench NGL: ${BENCH_NGL}  — max envelope: 999"
echo ""

MIN_CTX=4096
# Uniform minimum acceptable generation speed. Sourced from env.sh (default 10).
MIN_TPS=${LLM_MIN_TPS:-10}

# ── Autotune v4 knobs (documented in env.sh) ────────────────────────────────
FILL_RATIO=${LLM_AUTOTUNE_FILL_RATIO:-0.75}
FILL_MAX_TOKENS=${LLM_AUTOTUNE_FILL_MAX_TOKENS:-16384}
FILL_MIN_TOKENS=${LLM_AUTOTUNE_FILL_MIN_TOKENS:-2048}
MIN_PREFILL_TPS=${LLM_MIN_PREFILL_TPS:-0}
BEAM_WIDTH=${LLM_AUTOTUNE_BEAM_WIDTH:-2}
BEAM_ROUNDS=${LLM_AUTOTUNE_BEAM_ROUNDS:-2}
NGL_BAND_FRAC=${LLM_AUTOTUNE_NGL_BAND_FRAC:-0.55}
BENCH_TIMEOUT=${LLM_AUTOTUNE_BENCH_TIMEOUT:-300}
KV_QUANTS=${LLM_AUTOTUNE_KV_QUANTS:-"q8_0/q8_0 q4_0/q4_0"}

# Sanitize the numeric knobs so a bad env value can't produce garbage math.
[[ "$FILL_RATIO" =~ ^0(\.[0-9]+)?$|^1(\.0+)?$ ]] || FILL_RATIO=0.75
[[ "$FILL_MAX_TOKENS" =~ ^[0-9]+$ ]] && [[ $FILL_MAX_TOKENS -gt 0 ]] || FILL_MAX_TOKENS=16384
[[ "$FILL_MIN_TOKENS" =~ ^[0-9]+$ ]] && [[ $FILL_MIN_TOKENS -gt 0 ]] || FILL_MIN_TOKENS=2048
[[ "$MIN_PREFILL_TPS" =~ ^[0-9]+(\.[0-9]+)?$ ]] || MIN_PREFILL_TPS=0
[[ "$BEAM_WIDTH" =~ ^[0-9]+$ ]] && [[ $BEAM_WIDTH -ge 1 ]] || BEAM_WIDTH=2
[[ "$BEAM_ROUNDS" =~ ^[0-9]+$ ]] && [[ $BEAM_ROUNDS -ge 0 ]] || BEAM_ROUNDS=2
[[ "$NGL_BAND_FRAC" =~ ^0(\.[0-9]+)?$|^1(\.0+)?$ ]] || NGL_BAND_FRAC=0.55
[[ "$BENCH_TIMEOUT" =~ ^[0-9]+$ ]] && [[ $BENCH_TIMEOUT -gt 0 ]] || BENCH_TIMEOUT=300
[[ $FILL_MAX_TOKENS -lt $FILL_MIN_TOKENS ]] && FILL_MAX_TOKENS=$FILL_MIN_TOKENS

# ---------------------------------------------------------------------------
# VRAM-based start ctx using shared __kv_mb_per_1k when available
# Falls back to simple size-class factor if functions unavailable.
# ---------------------------------------------------------------------------
MODEL_BYTES=$(stat --format=%s "$MODEL_PATH" 2>/dev/null || echo 0)
FREE_VRAM=$(nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ')
FREE_VRAM=${FREE_VRAM:-3965}
MODEL_MB=$(( MODEL_BYTES / 1048576 ))

# Combos — selected by GGUF file size to avoid guaranteed-OOM combos on large models
if [[ $MODEL_MB -lt 1000 ]]; then
    COMBOS=("1024:256" "2048:512" "4096:1024")
elif [[ $MODEL_MB -lt 2000 ]]; then
    COMBOS=("1024:256" "2048:512")
else
    COMBOS=("1024:256")
fi

BUDGET=$(( FREE_VRAM - MODEL_MB - 200 ))

if declare -f __kv_mb_per_1k &>/dev/null && declare -f __gguf_metadata &>/dev/null; then
    # Shared function path — architecture-aware estimate
    _meta=$(__gguf_metadata "$MODEL_PATH" 2>/dev/null || true)
    if [[ -n "$_meta" ]]; then
        _n_layers=$(echo "$_meta" | cut -d'|' -f3)
        _native_ctx=$(echo "$_meta" | cut -d'|' -f4)
        _kv_mb=$(__kv_mb_per_1k "${_n_layers:-0}")
    else
        _native_ctx=""
        _kv_mb=$(__kv_mb_per_1k "0")
    fi
    if (( BUDGET > 0 )); then
        START_CTX=$(awk -v b="$BUDGET" -v k="$_kv_mb" 'BEGIN{c=int((b/k)*1000); print c<4096?4096:c}')
    else
        START_CTX=$MIN_CTX
    fi
else
    # Standalone fallback: size-class factor heuristic
    _native_ctx=""
    if [[ $MODEL_MB -gt 3000 ]]; then FACTOR=50
    elif [[ $MODEL_MB -gt 2000 ]]; then FACTOR=100
    elif [[ $MODEL_MB -gt 1000 ]]; then FACTOR=500
    else FACTOR=1000; fi
    if [[ $BUDGET -gt 0 ]]; then START_CTX=$(( BUDGET * FACTOR ))
    else START_CTX=$MIN_CTX; fi
fi

START_CTX=$(( (START_CTX / 1024) * 1024 ))
[[ $START_CTX -lt $MIN_CTX ]] && START_CTX=$MIN_CTX
[[ $START_CTX -gt 4194304 ]] && START_CTX=4194304

# Cap every ctx probe by native training context to avoid probing into
# RoPE-extended territory where KV-cache load times explode and generation
# quality is unknown. Multiplier: 4× for <2 GB models (VRAM headroom), 2× for
# ≥2 GB (tight VRAM). MAX_CTX is a hard ceiling that every climb below must
# respect — previously only START_CTX was capped, so Phase-2 climbs could
# balloon to millions of tokens and record unusable profiles.
MAX_CTX=$START_CTX
if [[ -n "${_native_ctx:-}" ]] && [[ "$_native_ctx" =~ ^[0-9]+$ ]] && [[ $_native_ctx -gt 0 ]]; then
    _mult=4
    [[ $MODEL_MB -ge 2000 ]] && _mult=2
    MAX_CTX=$(( _native_ctx * _mult ))
    [[ $START_CTX -gt $MAX_CTX ]] && START_CTX=$MAX_CTX
fi
[[ $MAX_CTX -gt 4194304 ]] && MAX_CTX=4194304

# Comma-format numbers (standalone helpers — no outer-scope capture)
fmt() { printf "%'d" "$1"; }
# fmts — comma-format each "batch:ubatch" combo passed as args.
fmts() { local _c _out=""; for _c in "$@"; do _out+="$(printf "%'d:%'d " "${_c%%:*}" "${_c##*:}")"; done; printf '%s' "${_out% }"; }

echo "============================================="
echo ""
echo "  threads=$(fmt "$TUNE_THREADS")  cpu=$(fmt "$CPU_COUNT")"
echo "  combos: $(fmts "${COMBOS[@]}")"
echo "  probe:  start=$(fmt "$START_CTX") min_tps=${MIN_TPS}"
START_TS=$(date '+%H:%M:%S')
echo "  start:  ${START_TS}"
echo ""
START_EPOCH=$(date +%s)

LLAMA_BIN="${LLAMA_SERVER_BIN:-$HOME/llama.cpp/build/bin/llama-server}"
PAYLOAD_FILE="/tmp/autotune-payload-${MODEL}.json"
cat > "$PAYLOAD_FILE" << 'PAYLOAD'
{"messages":[{"role":"user","content":"Explain special relativity: time dilation, length contraction, mass-energy equivalence."}],"max_tokens":256,"temperature":0}
PAYLOAD

# Filled-cache payload generator — pre-fills the KV cache with a long prompt
# (FILL_RATIO x ctx, capped by LLM_AUTOTUNE_FILL_MAX_TOKENS) so the scoring
# bench measures sustained decode at the ctx being certified instead of a burst
# on an empty cache, and yields a real prefill tok/s measurement. On CPU-only
# models prefill is slow, so the cap is tightened to keep a bench bounded.
# args: ctx payload_file
gen_fill_payload() {
    local _ctx="$1" _out="$2"
    local _fill_tokens
    _fill_tokens=$(awk -v c="$_ctx" -v r="$FILL_RATIO" 'BEGIN{printf "%d", c*r}')
    [[ $_fill_tokens -gt $FILL_MAX_TOKENS ]] && _fill_tokens=$FILL_MAX_TOKENS
    [[ $_fill_tokens -lt $FILL_MIN_TOKENS ]] && _fill_tokens=$FILL_MIN_TOKENS
    if [[ "${BENCH_NGL:-999}" == "0" ]]; then
        local _cpu_cap=8192
        [[ $_fill_tokens -gt $_cpu_cap ]] && _fill_tokens=$_cpu_cap
    fi
    "$TAC_PYTHON" - "$_fill_tokens" "$_out" << 'PYEOF'
import json, sys
tokens = int(sys.argv[1])
out = sys.argv[2]
sentence = ("Explain special relativity: time dilation, length contraction, "
            "mass-energy equivalence. ")
count = tokens * 4 // len(sentence) + 1
content = (sentence * count)[: tokens * 5]
payload = {
    "messages": [{"role": "user", "content": content}],
    "max_tokens": 256,
    "temperature": 0,
}
with open(out, "w") as f:
    json.dump(payload, f)
PYEOF
}

#==============================================================================
# Helpers
#==============================================================================

# Shared cleanup — kills llama-server, stale processes, and forces WSL2
# ghost-VRAM release via nvidia-smi query-context reset (double-kill trick).
# This is the fast path (~2 s). The full nvidia-uvm reload (clear_vram.sh)
# runs between models in the bench loop, not between every ctx probe.
# Nested function — captures $MODEL from parent scope for temp-file naming
cleanup_gpu() {
    local max_retries="${1:-1}"
    local attempt=0
    while [[ $attempt -lt $max_retries ]]; do
        if declare -f __gpu_clear_stale_processes &>/dev/null; then
            pkill -9 -u "$(id -un)" -x llama-server 2>/dev/null || true
            sleep 1
            __gpu_clear_stale_processes
        else
            pkill -9 -u "$(id -un)" -x llama-server 2>/dev/null || true
        fi

        # WSL2 ghost-VRAM workaround: kill nvidia-smi to recycle the CUDA
        # query context, then double-kill to trigger dxgkrnl release.
        # Does NOT reload nvidia-uvm (too slow for per-probe use).
        pkill -9 -u "$(id -un)" -x nvidia-smi 2>/dev/null || true
        sleep 1
        sync 2>/dev/null || true
        if [[ -w /proc/sys/vm/drop_caches ]]; then
            echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
        fi
        nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits >/dev/null 2>&1 || true
        pkill -9 -u "$(id -un)" -x nvidia-smi 2>/dev/null || true
        sleep 1

        local waited=0
    local cleanup_port="${AUTOTUNE_PORT:-18082}"
        while [[ $waited -lt 20 ]]; do
            if ! ss -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:)$cleanup_port\$"; then return 0; fi
            sleep 1; waited=$((waited + 1))
        done

        attempt=$((attempt + 1))
        [[ $attempt -lt $max_retries ]] && sleep 2
    done
    echo "ERROR: Port $cleanup_port still occupied after ${max_retries} cleanup attempts" >&2
    return 1
}

# ---------------------------------------------------------------------------
# bench_once — start server, run benchmark, return decode TPS on stdout.
#   args: ctx batch ubatch [mmap_mode] [ngl] [mode] [kv_k] [kv_v]
#   mmap_mode: "auto" (--mmap, default) or "off" (--no-mmap)
#   mode: "quick" (short prompt, discovery) or "filled" (scoring: pre-fills
#         the KV cache with a FILL_RATIO x ctx prompt and measures sustained
#         decode + prefill from the server timings)
#   kv_k/kv_v: cache-type-k / cache-type-v (default q8_0)
#   Writes "decode|prefill" (tok/s) to /tmp/at-metrics-$$ for callers that
#   need the prefill half; stdout stays the decode TPS so existing callers
#   are unchanged. Defaults to --mmap to avoid CUDA malloc ghost-VRAM OOM on
#   WSL2.
# ---------------------------------------------------------------------------
# Nested function — captures $MODEL from parent scope for temp-tag naming
bench_once() {
    local c="$1" b="$2" u="$3" mmap_mode="${4:-auto}" override_ngl="${5:-}"
    local mode="${6:-quick}" kv_k="${7:-q8_0}" kv_v="${8:-q8_0}"
    local tag="/tmp/at-vram-${MODEL}-${c}"
    local effective_ngl="${override_ngl:-${BENCH_NGL:-999}}"

    _BENCH_FAIL_TYPE=""  # global: "load_fail" or "oom"; reset before each bench
    cleanup_gpu 2>/dev/null || { echo "0|0|oom" > "/tmp/at-metrics-$$"; echo ""; return 1; }

    if [[ ! -f $tag ]]; then
        local g; g=$(nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ')
        echo "  VRAM cleared: $(fmt "${g:-?}") MiB free" >&2
        touch "$tag"
    fi

    local mmap_flag=""
    [[ $mmap_mode == off ]] && mmap_flag="--no-mmap"

    # REF: ubuntu-console card ca23ec0a — Use AUTOTUNE_PORT (default 18082)
    # to avoid conflicting with llama-server.service (production, 18081).
    # The bench uses LLM_PORT which preserves the watchdog's port.
    local autotune_port="${AUTOTUNE_PORT:-18082}"
    # Update all curl/http references to use the same port
    local health_url="http://127.0.0.1:$autotune_port"
    # Flash-attn can hang or crash model load for some architectures (e.g.
    # qwen35 / certain Q8/F16 quants) — retry once with it off before
    # declaring the model unloadable.
    local flash_attn="on"
    local pid="" hw=0
    _launch_server() {
        local -a fa_args=()
        [[ $flash_attn == "on" ]] && fa_args=(--flash-attn on) || fa_args=(--flash-attn off)
        "$LLAMA_BIN" --model "$MODEL_PATH" --port "$autotune_port" --host 127.0.0.1 \
            --ctx-size "$c" --batch-size "$b" --ubatch-size "$u" \
            --threads "$TUNE_THREADS" --n-gpu-layers "$effective_ngl" \
            --parallel 1 --fit off "${fa_args[@]}" --kv-offload \
            --cache-type-k "$kv_k" --cache-type-v "$kv_v" $mmap_flag \
            > "/tmp/at-${MODEL}-c${c}-b${b}.log" 2>&1 &
        pid=$!
        hw=0
        while [[ $hw -lt 90 ]]; do
            sleep 1; hw=$((hw + 1))
            kill -0 "$pid" 2>/dev/null || return 1
            curl -sS --max-time 2 "$health_url/health" 2>/dev/null | grep -q 'ok' && return 0
        done
        return 1
    }
    _launch_server || {
        if [[ $flash_attn == "on" ]]; then
            echo "  flash-attn load failure — retrying with --flash-attn off" >&2
            kill "$pid" 2>/dev/null; sleep 1; kill -9 "$pid" 2>/dev/null
            flash_attn="off"
            _launch_server || true
        fi
    }
    if [[ $hw -ge 90 ]]; then
        kill "$pid" 2>/dev/null; sleep 1; kill -9 "$pid" 2>/dev/null
        echo "0|0|load_fail" > "/tmp/at-metrics-$$"; echo ""; _BENCH_FAIL_TYPE="load_fail"; return 1
    fi

    # Pre-flight: confirm model slot is actually ready to serve.
    # /health can return OK before the GGUF memory-map completes, so the
    # first real completion may stall or return 0 tokens (worst on slow
    # mounts); probe one real completion before benchmarking.
    local pf_ok=0 pf_w=0
    while [[ $pf_w -lt 60 ]]; do
        if curl -sS --max-time 5 "$health_url/v1/chat/completions" \
            -H "Content-Type: application/json" \
            -d '{"messages":[{"role":"user","content":"hi"}],"max_tokens":1,"temperature":0}' \
            2>/dev/null | "$TAC_PYTHON" -c "import sys,json; d=json.load(sys.stdin); print(d.get('usage',{}).get('completion_tokens',0))" 2>/dev/null | grep -q '[1-9]'; then
            pf_ok=1; break
        fi
        kill -0 "$pid" 2>/dev/null || { echo "0|0|oom" > "/tmp/at-metrics-$$"; echo ""; return 1; }
        sleep 1; pf_w=$((pf_w + 1))
    done
    if [[ $pf_ok -ne 1 ]]; then
        kill "$pid" 2>/dev/null; sleep 1; kill -9 "$pid" 2>/dev/null
        echo "0|0|oom" > "/tmp/at-metrics-$$"; echo ""; _BENCH_FAIL_TYPE="oom"; return 1
    fi

    # GPU warmup: wake clocks from power-save (P5/P8 → P0).
    # Laptop GPUs idle at 1035 MHz (~19 TPS) but can reach 1600+ MHz (60+ TPS).
    # 8 tokens isn't enough compute — use 64 when cold, 8 when already warm.
    local warmup_tokens=8
    local _pstate; _pstate=$(nvidia-smi --query-gpu=pstate --format=csv,noheader 2>/dev/null | head -1 | tr -d ' ')
    if [[ -n "$_pstate" ]] && [[ "$_pstate" != "P0" ]]; then
        warmup_tokens=64
    fi
    curl -sS --max-time 30 "$health_url/v1/chat/completions" \
        -H "Content-Type: application/json" \
        -d "{\"messages\":[{\"role\":\"user\",\"content\":\"Warmup\"}],\"max_tokens\":${warmup_tokens},\"temperature\":0}" \
        > /dev/null 2>&1 || true

    local payload_file="$PAYLOAD_FILE"
    local bench_timeout="$BENCH_TIMEOUT"
    if [[ $mode == filled ]]; then
        payload_file="/tmp/at-fill-${MODEL}-${c}.json"
        [[ -f $payload_file ]] || gen_fill_payload "$c" "$payload_file"
        # Filled prefill can be slow: with the KV cache spilling into host RAM
        # at huge ctx, prefill can drop below 55 tok/s, and lower still under
        # concurrent load. Give generous headroom so slow-but-real prefills
        # complete and are measured instead of timing out and being
        # misclassified as OOM (which forces unnecessary Phase-4 descents).
        [[ $bench_timeout -lt 1200 ]] && bench_timeout=1200
    fi

    local start_ns; start_ns=$(date +%s%N)
    local resp; resp=$(curl -sS --max-time "$bench_timeout" "$health_url/v1/chat/completions" \
        -H "Content-Type: application/json" -d @"$payload_file" 2>/dev/null) || true
    local end_ns; end_ns=$(date +%s%N)
    kill "$pid" 2>/dev/null; sleep 1; kill -9 "$pid" 2>/dev/null

    local elapsed_ms=$(( (end_ns - start_ns) / 1000000 ))

    # Parse usage + server timings in one pass. llama-server includes a
    # timings block (prompt_per_second / predicted_per_second) in every
    # /v1/chat/completions response; fall back to wall-clock if absent.
    local parsed; parsed=$(echo "$resp" | "$TAC_PYTHON" -c "
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    print('0|0|0|0|0'); sys.exit(0)
u = d.get('usage', {}) or {}
ct = u.get('completion_tokens', 0) or 0
pt = u.get('prompt_tokens', 0) or 0
t = d.get('timings', {}) or {}
decode = t.get('predicted_per_second', 0) or 0
prefill = t.get('prompt_per_second', 0) or 0
pred_ms = t.get('predicted_ms', 0) or 0
print('%s|%s|%s|%s|%s' % (ct, pt, decode, prefill, pred_ms))
" 2>/dev/null) || parsed="0|0|0|0|0"
    local tokens prompt_tokens decode_tps prefill_tps pred_ms
    IFS='|' read -r tokens prompt_tokens decode_tps prefill_tps pred_ms <<< "$parsed"
    [[ "$tokens" =~ ^[0-9]+$ ]] || tokens=0
    [[ "$prompt_tokens" =~ ^[0-9]+$ ]] || prompt_tokens=0

    if [[ $tokens -gt 0 ]]; then
        # Prefer the server's own decode timing; fall back to wall-clock.
        if [[ $(echo "${decode_tps:-0} > 0" | bc 2>/dev/null || echo "0") != 1 ]]; then
            if [[ $(echo "${pred_ms:-0} > 0" | bc 2>/dev/null || echo "0") == 1 ]]; then
                decode_tps=$(echo "scale=2; $tokens * 1000 / $pred_ms" | bc 2>/dev/null || echo "0")
            elif [[ $elapsed_ms -gt 0 ]]; then
                decode_tps=$(echo "scale=2; $tokens * 1000 / $elapsed_ms" | bc 2>/dev/null || echo "0")
            fi
        fi
        if [[ $(echo "${prefill_tps:-0} > 0" | bc 2>/dev/null || echo "0") != 1 ]] && [[ $prompt_tokens -gt 0 ]]; then
            if [[ $(echo "${pred_ms:-0} > 0" | bc 2>/dev/null || echo "0") == 1 ]] \
                && [[ $(echo "$elapsed_ms > $pred_ms" | bc 2>/dev/null || echo "0") == 1 ]]; then
                prefill_tps=$(echo "scale=2; $prompt_tokens * 1000 / ($elapsed_ms - $pred_ms)" | bc -l 2>/dev/null || echo "0")
            fi
        fi
    fi

    # Persist decode|prefill|failtype for callers (survives the subshell that
    # bench_ctx runs in — globals do not).
    echo "${decode_tps:-0}|${prefill_tps:-0}|" > "/tmp/at-metrics-$$"

    if [[ $elapsed_ms -gt 0 && $tokens -gt 0 ]] && [[ $(echo "${decode_tps:-0} > 0" | bc 2>/dev/null || echo "0") == 1 ]]; then
        echo "scale=2; $decode_tps / 1" | bc 2>/dev/null || echo "0"
        return 0
    fi
    echo "0|0|oom" > "/tmp/at-metrics-$$"; echo ""; _BENCH_FAIL_TYPE="oom"
    return 1
}

# ---------------------------------------------------------------------------
# bench_ctx — returns decode TPS on stdout, empty on failure. RC 0/1.
#   args: ctx batch ubatch [samples] [mmap_mode] [ngl] [mode] [kv_k] [kv_v]
#   Also refreshes /tmp/at-metrics-$$ with "decode|prefill" from the last
#   bench_once run (see bench_once).
# ---------------------------------------------------------------------------
bench_ctx() {
    local c="$1" b="$2" u="$3" samples="${4:-1}" mmap_mode="${5:-auto}" override_ngl="${6:-}"
    local mode="${7:-quick}" kv_k="${8:-q8_0}" kv_v="${9:-q8_0}"
    _BENCH_FAIL_TYPE=""
    echo "" > "/tmp/at-metrics-$$" 2>/dev/null || true

    if [[ $samples -eq 1 ]]; then
        local tps; tps=$(bench_once "$c" "$b" "$u" "$mmap_mode" "$override_ngl" "$mode" "$kv_k" "$kv_v") || { echo ""; return 1; }
        # Pre-check tps=0 edge-cases that bc may miss (locale, trailing whitespace).
        if [[ -z "$tps" || "$tps" == "0" || "$tps" == "0.00" || "$tps" == "0,00" ]]; then
            echo "DEBUG: bench_once raw tps=[$tps] for ctx=$c — classified as OOM" >&2
            echo ""; return 1
        fi
        tps=$(echo "$tps" | bc 2>/dev/null || echo "0"); [ -z "$tps" ] && tps=0
        if [[ $(echo "$tps <= 0" | bc 2>/dev/null || echo "1") == 1 ]]; then
            echo "DEBUG: bc-evaluated tps=[$tps] for ctx=$c — classified as OOM" >&2
            echo ""; return 1
        fi
        # Phase 1: only check for actual OOM (0 tokens). TPS floor is applied
        # at the final check — rejecting slow models mid-probe hides viable ctx.
        echo "$tps"
        return 0
    fi

    # Multi-sample (samples >= 2): drop OOM samples, then combine the rest.
    # For N >= 3 the verdict is the MEDIAN of the surviving samples — a single
    # unlucky low read cannot flip a Phase 4 floor verdict. N == 2 keeps the
    # historical mean (a "median of 2" is just a mean). bench_once already
    # warms up the server inside each call, so no extra warmup discard is
    # needed here.
    local -a vals=()
    local _i _v
    for ((_i = 0; _i < samples; _i++)); do
        _v=$(bench_once "$c" "$b" "$u" "$mmap_mode" "$override_ngl" "$mode" "$kv_k" "$kv_v") || _v=""
        _v=$(echo "$_v" | bc 2>/dev/null || echo "0")
        if [[ $(echo "$_v > 0" | bc 2>/dev/null || echo "0") == 1 ]]; then
            vals+=("$_v")
        fi
    done
    if [[ ${#vals[@]} -eq 0 ]]; then echo ""; return 1; fi

    local tps
    if [[ ${#vals[@]} -eq 1 ]]; then
        tps="${vals[0]}"
    elif [[ $samples -eq 2 ]]; then
        tps=$(echo "scale=2; (${vals[0]}+${vals[1]})/${#vals[@]}" | bc -l 2>/dev/null || echo "${vals[0]}")
    else
        # Median of the survivors (LC_ALL=C sort keeps decimals locale-safe).
        tps=$(printf '%s\n' "${vals[@]}" | LC_ALL=C sort -n | awk '{a[NR]=$1} END { if (NR%2) print a[(NR+1)/2]; else printf "%.2f\n", (a[NR/2]+a[NR/2+1])/2 }')
    fi
    tps=$(echo "scale=2; $tps / 1" | bc -l 2>/dev/null || echo "$tps"); [ -z "$tps" ] && tps=0
    # Refinement: only check for actual OOM (0 tokens). TPS floor is applied
    # at the final check — rejecting here hides the true ceiling.
    echo "$tps"
    return 0
}

#==============================================================================
# Probe
#==============================================================================

BEST_TPS="0"; BEST_COMBO=""; BEST_CTX=0; ANY_OK=false
# Profile 1's prefill tok/s (filled-cache certification) and profile 2.
BEST_PREFILL="0"
# Profile 2 (interactive): config with the highest decode TPS anywhere in the
# search, tiebreak higher ctx. Certified later with a filled-cache bench.
P2_TPS="0"; P2_CTX=0; P2_B=""; P2_U=""; P2_PREFILL="0"
# Set to 1 when the --no-mmap fallback produced the winner; the beam search,
# sweeps, and Phase 4 must then bench with mmap off too.
MMAP_FALLBACK_USED=0

# Writes to BEST_TPS/BEST_COMBO/BEST_CTX/ANY_OK globals.
#
# Success metric — lexicographic capability (replaces the old ctx×tps product):
#   1. A config that meets the TPS floor always beats one that does not.
#   2. Among configs that meet the floor: highest ctx wins (context is the
#      capability that keeps paying off once speed is acceptable); tiebreak by
#      higher TPS.
#   3. Among configs below the floor (model is too slow): highest TPS wins
#      (fastest best-effort config); tiebreak by higher ctx.
# ctx×tps conflated speed and context as interchangeable; once TPS clears the
# floor, extra speed has diminishing value while extra context does not.
record_best() {
    local c=$1 tps=$2 b=$3 u=$4

    # Profile 2 (interactive): highest decode TPS across every probed config,
    # independent of the floor — it is the "fast" profile for short-context
    # interactive flows. The prefill half is captured at certification time.
    if [[ $(echo "$tps > $P2_TPS" | bc 2>/dev/null || echo "0") == 1 ]] ||
       { [[ $(echo "$tps == $P2_TPS" | bc 2>/dev/null || echo "0") == 1 ]] &&
         [[ $(echo "$c > $P2_CTX" | bc 2>/dev/null || echo "0") == 1 ]]; }; then
        P2_TPS=$tps; P2_CTX=$c; P2_B=$b; P2_U=$u
    fi

    local above; above=$(echo "$tps >= $MIN_TPS" | bc 2>/dev/null || echo "0")
    local best_above; best_above=$(echo "$BEST_TPS >= $MIN_TPS" | bc 2>/dev/null || echo "0")

    # Rule 1: floor-meeting config always wins over a below-floor one.
    if [[ $above == 1 && $best_above == 0 ]]; then
        BEST_TPS=$tps; BEST_COMBO="$b:$u"; BEST_CTX=$c; return
    fi
    if [[ $above == 0 && $best_above == 1 ]]; then
        return  # keep current — it meets the floor, the candidate does not
    fi

    if [[ $above == 1 ]]; then
        # Rule 2: both meet floor → max ctx, tiebreak max TPS.
        if [[ $(echo "$c > $BEST_CTX" | bc 2>/dev/null || echo "0") == 1 ]] ||
           { [[ $(echo "$c == $BEST_CTX" | bc 2>/dev/null || echo "0") == 1 ]] &&
             [[ $(echo "$tps > $BEST_TPS" | bc 2>/dev/null || echo "0") == 1 ]]; }; then
            BEST_TPS=$tps; BEST_COMBO="$b:$u"; BEST_CTX=$c
        fi
    else
        # Rule 3: both below floor (best-effort) → max TPS, tiebreak max ctx.
        if [[ $(echo "$tps > $BEST_TPS" | bc 2>/dev/null || echo "0") == 1 ]] ||
           { [[ $(echo "$tps == $BEST_TPS" | bc 2>/dev/null || echo "0") == 1 ]] &&
             [[ $(echo "$c > $BEST_CTX" | bc 2>/dev/null || echo "0") == 1 ]]; }; then
            BEST_TPS=$tps; BEST_COMBO="$b:$u"; BEST_CTX=$c
        fi
    fi
}

# ---------------------------------------------------------------------------
# last_fail_type — read the last bench's failure classification from the
# metrics file. bench_ctx/bench_once run in command-substitution subshells
# where global assignment does not propagate, so the file is the reliable
# channel (REF: autotune-model.sh v4).
# @stdout "load_fail", "oom", or empty.
# ---------------------------------------------------------------------------
last_fail_type() {
    cut -d'|' -f3 "/tmp/at-metrics-$$" 2>/dev/null | head -1
}

# ---------------------------------------------------------------------------
# probe_upward — bounded ctx re-climb for a fixed config (quick benches).
# Confirms the given ctx, then up to 2 ×1.5 climb steps and one binary probe.
# Every successful test feeds record_best (max-ctx profile + profile-2
# tracking), so the caller's BEST_* may end higher than the starting ctx.
#   args: ctx batch ubatch [mmap] [ngl] [kv_k] [kv_v]
# @returns 0 when the starting ctx confirmed, 1 when it failed.
# ---------------------------------------------------------------------------
probe_upward() {
    local _pc="$1" _pb="$2" _pu="$3" _pm="${4:-auto}" _pngl="${5:-$BENCH_NGL}"
    local _pkk="${6:-q8_0}" _pkv="${7:-q8_0}"
    local _tps _lo _hi=0 _steps=0 _mid

    _tps=$(bench_ctx "$_pc" "$_pb" "$_pu" 1 "$_pm" "$_pngl" "quick" "$_pkk" "$_pkv") || return 1
    record_best "$_pc" "$_tps" "$_pb" "$_pu"
    _lo=$_pc
    while [[ $_steps -lt 2 ]]; do
        _steps=$((_steps + 1))
        _pc=$(( _lo * 3 / 2 )); [[ $_pc -gt $MAX_CTX ]] && _pc=$MAX_CTX
        [[ $_pc -eq $_lo ]] && break
        _tps=$(bench_ctx "$_pc" "$_pb" "$_pu" 1 "$_pm" "$_pngl" "quick" "$_pkk" "$_pkv") || { _hi=$_pc; break; }
        _lo=$_pc; record_best "$_lo" "$_tps" "$_pb" "$_pu"
    done
    if [[ $_hi -gt 0 ]] && [[ $(( _hi - _lo )) -ge 512 ]]; then
        _mid=$(( ( _lo + _hi ) / 2 / 512 * 512 ))
        [[ $_mid -eq $_lo ]] && return 0
        _tps=$(bench_ctx "$_mid" "$_pb" "$_pu" 1 "$_pm" "$_pngl" "quick" "$_pkk" "$_pkv") || return 0
        record_best "$_mid" "$_tps" "$_pb" "$_pu"
    fi
    return 0
}

for combo in "${COMBOS[@]}"; do
    IFS=':' read -r b u <<< "$combo"
    echo ""
    echo "  batch $(fmt "$b")/$(fmt "$u")"
    echo "  ---------------------"

    c0=$START_CTX
    if [[ $BEST_CTX -gt 0 ]]; then
        tps=$(bench_ctx "$BEST_CTX" "$b" "$u" 1) || tps=""
        if [[ -n $tps ]]; then
            echo "  ctx $(fmt "$BEST_CTX") - ${tps} tps"
            ANY_OK=true; record_best "$BEST_CTX" "$tps" "$b" "$u"
        else
            fail_label="OOM"
            [[ $(last_fail_type) == "load_fail" ]] && fail_label="unsupported model"
            echo "  ctx $(fmt "$BEST_CTX") - ${fail_label} with batch $(fmt "$b")/$(fmt "$u")"
        fi
        continue
    fi
    test_num=0; c=$c0; found=false; _ALL_LOAD_FAIL=true
    while [[ $c -ge $MIN_CTX ]]; do
        test_num=$((test_num + 1))
        tps=$(bench_ctx "$c" "$b" "$u" 1) || {
            fail_label="OOM"
            [[ $(last_fail_type) == "load_fail" ]] && fail_label="unsupported model"
            echo "  Test $test_num: ctx $(fmt "$c") - ${fail_label}: dropping to $(fmt $((c/2)))"
            [[ $(last_fail_type) != "load_fail" ]] && _ALL_LOAD_FAIL=false
            c=$((c/2)); [[ $c -lt $MIN_CTX ]] && break; continue
        }
        echo "  Test $test_num: ctx $(fmt "$c") - ${tps} tps"
        found=true; ANY_OK=true; _ALL_LOAD_FAIL=false
        record_best "$c" "$tps" "$b" "$u"

        # Phase 2: step up 50%, stop if TPS stable for 3 steps. The climb is
        # clamped at MAX_CTX — probing past the native-ctx ceiling records
        # RoPE-extended ctx values the machine cannot serve sanely.
        lo=$c; hi=0; c=$((c * 3 / 2)); [[ $c -gt $MAX_CTX ]] && c=$MAX_CTX; prev_tps=$tps; stable=0
        while true; do
            [[ $c -eq $lo ]] && break
            test_num=$((test_num + 1))
            bench_ctx "$c" "$b" "$u" 1 > /tmp/at-tps-$$; rc=$?
            tps=$(cat /tmp/at-tps-$$ 2>/dev/null)
            # REF: ubuntu-console card b564d801 — bench_ctx can return rc=0 with tps=0
            # when the server replies successfully with 0 completion tokens.
            # Catch both non-zero rc AND empty/zero tps as OOM to ensure consistent
            # classification in the binary probe.
            if [[ $rc -ne 0 ]] || [[ -z "$tps" || "$tps" == "0" || "$tps" == "0.00" || "$tps" == "0,00" ]]; then
                hi=$c
                fail_label="OOM"
                [[ $(last_fail_type) == "load_fail" ]] && fail_label="unsupported model"
                if [[ -n "$tps" && "$tps" == "0" ]]; then
                    echo "  Test $test_num: ctx $(fmt "$c") - 0 tps (${fail_label}): binary probe $(fmt $(( (lo+hi)/2/512*512 )))"
                else
                    echo "  Test $test_num: ctx $(fmt "$c") - ${fail_label}: binary probe $(fmt $(( (lo+hi)/2/512*512 )))"
                fi
                break
            fi
            lo=$c; record_best "$lo" "$tps" "$b" "$u"
            drop=$(echo "scale=4; ($prev_tps - $tps) / $prev_tps" | bc 2>/dev/null || echo "0")
            if [[ $(echo "$drop < 0.10" | bc 2>/dev/null || echo "0") == 1 ]]; then
                stable=$((stable + 1))
            else
                stable=0; prev_tps=$tps
            fi
            if [[ $stable -ge 3 ]]; then
                echo "  Test $test_num: ctx $(fmt "$c") - ${tps} tps (TPS stable, stopping climb)"
                hi=$((c * 3 / 2)); [[ $hi -gt $MAX_CTX ]] && hi=$MAX_CTX
                break
            fi
            echo "  Test $test_num: ctx $(fmt "$c") - ${tps} tps - climbing to $(fmt $((c*3/2)))"
            c=$((c * 3 / 2)); [[ $c -gt $MAX_CTX ]] && c=$MAX_CTX
        done

        # If first step-up OOM'd and TPS was marginal (< 25), skip binary probe.
        if [[ $hi -gt 0 ]] && [[ $(echo "$BEST_TPS < 25" | bc 2>/dev/null || echo "0") == 1 ]]; then
            echo "  (TPS marginal, no binary probe needed)" 
        else
        # Binary probe between lo (working) and hi (OOM) — max 5 steps
        prev_c=-1; probe_count=0
        while [[ $((hi - lo)) -ge 512 ]] && [[ $probe_count -lt 5 ]]; do
            probe_count=$((probe_count + 1))
            nsamples=1
            [[ $probe_count -gt 1 ]] && nsamples=2   # double-sample in refinement zone
            c=$(( (lo + hi) / 2 / 512 * 512 ))
            [[ $c -eq $prev_c ]] && break
            prev_c=$c
            test_num=$((test_num + 1))
            bench_ctx "$c" "$b" "$u" "$nsamples" > /tmp/at-tps-$$; rc=$?
            tps=$(cat /tmp/at-tps-$$ 2>/dev/null)
            if [[ $rc -ne 0 ]]; then
                hi=$c
                fail_label="OOM"
                [[ $(last_fail_type) == "load_fail" ]] && fail_label="unsupported model"
                echo "  Test $test_num: ctx $(fmt "$c") - ${fail_label}"
            else
                lo=$c; record_best "$lo" "$tps" "$b" "$u"
                echo "  Test $test_num: ctx $(fmt "$c") - ${tps} tps"
            fi
        done
        fi
        break
    done
    if [[ $found == false ]]; then
        fail_label="OOM"
        [[ $_ALL_LOAD_FAIL == true ]] && fail_label="unsupported model"
        echo "  Test $test_num: ctx $(fmt "$c") - ${fail_label} - model cannot run at any ctx"
        # Early abort: if the model never loaded at any ctx (load_fail at every
        # step), skip remaining combos — stepping down won't make the GGUF
        # load. Go straight to the --no-mmap fallback.
        if [[ $_ALL_LOAD_FAIL == true ]]; then
            echo "  (model cannot be loaded — skipping remaining combos)"
            break
        fi
    fi
done

# --- mmap fallback ---
# If --mmap (default) failed at all ctx for all combos, retry with --no-mmap.
# Some architectures (phi3, gemma3n) need --no-mmap for stable VRAM allocation.
if [[ $ANY_OK == false ]]; then
    echo ""
    echo "  --mmap failed at all ctx — retrying with --no-mmap"
    echo ""
    _ALL_LOAD_FAIL=true
    for combo in "${COMBOS[@]}"; do
        IFS=':' read -r b u <<< "$combo"
        echo "  batch $(fmt "$b")/$(fmt "$u")  (--no-mmap)"
        echo "  ---------------------"

        c=$START_CTX; found=false
        while [[ $c -ge $MIN_CTX ]]; do
            tps=$(bench_ctx "$c" "$b" "$u" 1 "off") || {
                fail_label="OOM"
                [[ $(last_fail_type) == "load_fail" ]] && fail_label="unsupported model"
                echo "  ctx $(fmt "$c") - ${fail_label}: dropping to $(fmt $((c/2)))"
                [[ $(last_fail_type) != "load_fail" ]] && _ALL_LOAD_FAIL=false
                c=$((c/2)); [[ $c -lt $MIN_CTX ]] && break; continue
            }
            echo "  ctx $(fmt "$c") - ${tps} tps"
            found=true; ANY_OK=true; _ALL_LOAD_FAIL=false; MMAP_FALLBACK_USED=1
            record_best "$c" "$tps" "$b" "$u"
            # Phase 2: step up, stop at first OOM (fallback path — keep it simple)
            lo=$c; c=$((c * 3 / 2)); [[ $c -gt $MAX_CTX ]] && c=$MAX_CTX
            while true; do
                [[ $c -eq $lo ]] && break
                bench_ctx "$c" "$b" "$u" 1 "off" > /tmp/at-tps-$$; rc=$?
                tps=$(cat /tmp/at-tps-$$ 2>/dev/null)
                if [[ $rc -ne 0 ]]; then
                    fail_label="OOM"
                    [[ $(last_fail_type) == "load_fail" ]] && fail_label="unsupported model"
                    echo "  ctx $(fmt "$c") - ${fail_label}"
                    break
                fi
                lo=$c; record_best "$lo" "$tps" "$b" "$u"
                echo "  ctx $(fmt "$c") - ${tps} tps - climbing to $(fmt $((c*3/2)))"
                c=$((c * 3 / 2)); [[ $c -gt $MAX_CTX ]] && c=$MAX_CTX
            done
            break
        done
        # Likewise early-abort remaining combos in the fallback path
        if [[ $_ALL_LOAD_FAIL == true ]]; then
            echo "  (model cannot be loaded even with --no-mmap — aborting)"
            break
        fi
    done
fi

# --- Beam search over batch/ubatch at the winning ctx ---
# Replaces the fixed 128/256/512 ubatch pass. Evaluates a small anchor set,
# then expands neighbors of the top performers (beam search) — the live-path
# equivalent of the richer Phase 3 in bin/model-autotune.py. All evals are
# quick single-sample benches at BEST_CTX; the floor itself is certified
# later with a filled-cache bench.
EFFECTIVE_MMAP="auto"
[[ $MMAP_FALLBACK_USED == 1 ]] && EFFECTIVE_MMAP="off"
if [[ $ANY_OK == true && -n $BEST_COMBO ]] && [[ $BEST_CTX -gt 0 ]]; then
    IFS=':' read -r BEST_B BEST_U <<< "$BEST_COMBO"

    BATCHES=()
    UBATCHES=()
    ANCHORS=()
    if [[ $MODEL_MB -lt 1000 ]]; then
        BATCHES=(1024 2048 4096); UBATCHES=(256 512 1024)
        ANCHORS=(1024:256 2048:512 4096:1024)
    else
        BATCHES=(512 1024 2048); UBATCHES=(128 256 512)
        ANCHORS=(512:128 1024:256 1024:512 2048:512)
    fi

    # Candidate space, gated by ctx (big batches need big compute buffers).
    SPACE=()
    _b=""; _u=""
    for _b in "${BATCHES[@]}"; do
        [[ $BEST_CTX -lt 8192 && $_b -gt 1024 ]] && continue
        [[ $BEST_CTX -lt 16384 && $_b -gt 1536 ]] && continue
        for _u in "${UBATCHES[@]}"; do
            [[ $_u -le $_b ]] || continue
            SPACE+=("${_b}:${_u}")
        done
    done

    declare -A SEEN=()
    declare -A COMBO_TPS=()
    BEAM=()
    FRONTIER=()

    echo ""
    echo "  beam search at ctx=$(fmt "$BEST_CTX")  (batch/ubatch)"
    echo "  ---------------------"

    beam_eval() {
        local key="$1"
        [[ -n "${SEEN[$key]:-}" ]] && return
        SEEN[$key]=1
        local _b2 _u2 tps fail_label
        IFS=':' read -r _b2 _u2 <<< "$key"
        tps=$(bench_ctx "$BEST_CTX" "$_b2" "$_u2" 1) || tps=""
        if [[ -n $tps ]]; then
            echo "  combo $_b2/$_u2 - ${tps} tps"
            COMBO_TPS[$key]="$tps"
            record_best "$BEST_CTX" "$tps" "$_b2" "$_u2"
        else
            fail_label="OOM"
            [[ $(last_fail_type) == "load_fail" ]] && fail_label="unsupported model"
            echo "  combo $_b2/$_u2 - ${fail_label}"
        fi
    }

    beam_top() {
        local k t above
        for k in "${!COMBO_TPS[@]}"; do
            t="${COMBO_TPS[$k]}"
            above=0
            [[ $(echo "$t >= $MIN_TPS" | bc 2>/dev/null || echo "0") == 1 ]] && above=1
            printf '%s|%s|%s\n' "$above" "$t" "$k"
        done | sort -t'|' -k1,1nr -k2,2nr | head -n "$BEAM_WIDTH" | cut -d'|' -f3
    }

    beam_neighbors() {
        local key="$1"
        local _b3 _u3 bi=0 ui=0 _i _nb _nu
        local -a out=()
        IFS=':' read -r _b3 _u3 <<< "$key"
        for _i in "${!BATCHES[@]}"; do [[ "${BATCHES[$_i]}" == "$_b3" ]] && bi=$_i && break; done
        for _i in "${!UBATCHES[@]}"; do [[ "${UBATCHES[$_i]}" == "$_u3" ]] && ui=$_i && break; done
        [[ $bi -gt 0 ]] && out+=("${BATCHES[$((bi-1))]}:$_u3")
        [[ $bi -lt $(( ${#BATCHES[@]} - 1 )) ]] && out+=("${BATCHES[$((bi+1))]}:$_u3")
        [[ $ui -gt 0 ]] && out+=("$_b3:${UBATCHES[$((ui-1))]}")
        [[ $ui -lt $(( ${#UBATCHES[@]} - 1 )) ]] && out+=("$_b3:${UBATCHES[$((ui+1))]}")
        # Diagonal moves jump the grid toward higher-throughput corners.
        [[ $bi -gt 0 && $ui -gt 0 ]] && out+=("${BATCHES[$((bi-1))]}:${UBATCHES[$((ui-1))]}")
        [[ $bi -lt $(( ${#BATCHES[@]} - 1 )) && $ui -lt $(( ${#UBATCHES[@]} - 1 )) ]] \
            && out+=("${BATCHES[$((bi+1))]}:${UBATCHES[$((ui+1))]}")
        printf '%s\n' "${out[@]}"
    }

    # Filter anchors to the ctx-gated space.
    FILTERED_ANCHORS=()
    _a=""; _sk=""
    for _a in "${ANCHORS[@]}"; do
        for _sk in "${SPACE[@]}"; do
            [[ "$_sk" == "$_a" ]] && FILTERED_ANCHORS+=("$_a") && break
        done
    done
    if [[ ${#FILTERED_ANCHORS[@]} -eq 0 ]]; then
        FILTERED_ANCHORS=("${SPACE[@]:0:4}")
    fi
    _a2=""
    for _a2 in "${FILTERED_ANCHORS[@]}"; do beam_eval "$_a2"; done

    mapfile -t BEAM < <(beam_top)
    _round=0
    while [[ $_round -lt $BEAM_ROUNDS ]] && [[ ${#BEAM[@]} -gt 0 ]]; do
        _round=$((_round + 1))
        FRONTIER=()
        _bk=""; _nk=""; _in=0; _dup=0
        for _bk in "${BEAM[@]}"; do
            while IFS= read -r _nk; do
                [[ -n $_nk ]] || continue
                _in=0
                for _sk in "${SPACE[@]}"; do [[ "$_sk" == "$_nk" ]] && _in=1 && break; done
                [[ $_in == 1 ]] || continue
                [[ -n "${SEEN[$_nk]:-}" ]] && continue
                _dup=0
                _fk=""
                for _fk in "${FRONTIER[@]}"; do [[ "$_fk" == "$_nk" ]] && _dup=1 && break; done
                [[ $_dup == 1 ]] && continue
                FRONTIER+=("$_nk")
            done < <(beam_neighbors "$_bk")
        done
        _nk2=""
        for _nk2 in "${FRONTIER[@]}"; do beam_eval "$_nk2"; done
        _nb2=()
        while IFS= read -r _nk3; do _nb2+=("$_nk3"); done < <(beam_top)
        if [[ "${_nb2[*]:-}" == "${BEAM[*]}" ]]; then break; fi
        BEAM=("${_nb2[@]}")
    done

    # The beam winner may enable a higher ctx ceiling (smaller ubatch → less
    # peak VRAM). Re-climb ctx for the winning combo.
    if [[ -n $BEST_COMBO ]]; then
        IFS=':' read -r BEST_B BEST_U <<< "$BEST_COMBO"
        echo "  re-climbing ctx for combo $(fmt "$BEST_B")/$(fmt "$BEST_U")"
        probe_upward "$BEST_CTX" "$BEST_B" "$BEST_U" "$EFFECTIVE_MMAP"
    fi
fi

# --- n_gpu_layers / KV-quant sweep (the "almost fits" band) ---
# The registry's __calc_gpu_layers is 999-or-0: models slightly too big for
# full offload fall to CPU-only. In the band (model is a meaningful fraction
# of free VRAM) probe alternate offload counts and cache quantizations —
# partial offload or q4_0 KV can beat pure CPU and free VRAM for a higher ctx.
WIN_NGL="$BENCH_NGL"; WIN_KVK="q8_0"; WIN_KVV="q8_0"
BAND_MIN_MB=$(awk -v f="$FREE_VRAM" -v fr="$NGL_BAND_FRAC" 'BEGIN{printf "%d", f*fr}')
if [[ $ANY_OK == true && -n $BEST_COMBO ]] && [[ $MODEL_MB -ge $BAND_MIN_MB ]]; then
    IFS=':' read -r BEST_B BEST_U <<< "$BEST_COMBO"

    # ngl candidates: runtime-max offload (999) plus a short ladder down the
    # GGUF layer count (3/4, 1/2, 1/4) — on a 4 GB card partial offload can
    # win anywhere in that band, and 999-or-half alone skips it. Dedup against
    # the registry's current value and against each other.
    NGL_CANDIDATES=()
    [[ "$BENCH_NGL" != "999" ]] && NGL_CANDIDATES+=("999")
    if [[ -n "${_n_layers:-}" ]] && [[ "$_n_layers" =~ ^[0-9]+$ ]] && [[ $_n_layers -gt 1 ]]; then
        for _frac in 3 2 1; do
            _ngl_cand=$(( _n_layers * _frac / 4 ))
            [[ $_ngl_cand -lt 1 ]] && _ngl_cand=1
            [[ "$_ngl_cand" != "$BENCH_NGL" ]] || continue
            _dup=0
            for _existing in "${NGL_CANDIDATES[@]:-}"; do
                [[ "$_existing" == "$_ngl_cand" ]] && _dup=1 && break
            done
            (( _dup )) || NGL_CANDIDATES+=("$_ngl_cand")
        done
        unset _frac _ngl_cand _dup _existing
    fi

    if [[ ${#NGL_CANDIDATES[@]} -gt 0 ]]; then
        echo ""
        echo "  n_gpu_layers sweep (band) at ctx=$(fmt "$BEST_CTX")  [${NGL_CANDIDATES[*]}]"
        echo "  ---------------------"
        _ngl=""
        for _ngl in "${NGL_CANDIDATES[@]}"; do
            _before="$BEST_CTX|$BEST_TPS"
            echo "  ngl=$_ngl:"
            probe_upward "$BEST_CTX" "$BEST_B" "$BEST_U" "$EFFECTIVE_MMAP" "$_ngl" "q8_0" "q8_0" || true
            _after="$BEST_CTX|$BEST_TPS"
            [[ "$_after" != "$_before" ]] && WIN_NGL="$_ngl"
        done
    fi

    # KV-quant candidates: e.g. "q8_0/q8_0 q4_0/q4_0" — the default pair was
    # implicitly probed by every bench so far; probe the alternates.
    KV_PAIRS=()
    _pair=""
    for _pair in $KV_QUANTS; do
        _kk="${_pair%%/*}"; _kv="${_pair##*/}"
        [[ "$_kk" == "$WIN_KVK" && "$_kv" == "$WIN_KVV" ]] && continue
        KV_PAIRS+=("$_pair")
    done

    if [[ ${#KV_PAIRS[@]} -gt 0 ]]; then
        echo ""
        echo "  KV-quant sweep (band) at ctx=$(fmt "$BEST_CTX")  [${KV_PAIRS[*]}]"
        echo "  ---------------------"
        _pair=""
        for _pair in "${KV_PAIRS[@]}"; do
            _kk="${_pair%%/*}"; _kv="${_pair##*/}"
            _before="$BEST_CTX|$BEST_TPS"
            echo "  cache k=$_kk v=$_kv:"
            probe_upward "$BEST_CTX" "$BEST_B" "$BEST_U" "$EFFECTIVE_MMAP" "$WIN_NGL" "$_kk" "$_kv" || true
            _after="$BEST_CTX|$BEST_TPS"
            if [[ "$_after" != "$_before" ]]; then WIN_KVK="$_kk"; WIN_KVV="$_kv"; fi
        done
    fi
fi

# --- Phase 4: filled-cache TPS floor recovery ---
# The probe maximises ctx, which on a 4 GB card can leave a model swapping at
# large context (high ctx, low TPS). The floor is now certified at a FILLED
# KV cache — a long prompt pre-fills the context so decode is measured under
# the cache pressure the recorded ctx actually produces. If the best config is
# below the floor (decode or the optional prefill floor), step ctx DOWN — a
# smaller KV cache raises TPS — until the floor is met or MIN_CTX is reached.
# Descending top-down means the first ctx that meets the floor is the highest
# ctx that sustains it, which is exactly the capability we record.
if [[ $ANY_OK == true && -n $BEST_COMBO ]]; then
    IFS=':' read -r BEST_B BEST_U <<< "$BEST_COMBO"
    echo ""
    echo "  Phase 4: filled-cache TPS floor recovery"
    echo "  ---------------------"
    _dc=$BEST_CTX
    _ft=""
    while true; do
        # 3-sample median verdict: one unlucky low read must not permanently
        # cost context (single-sample descent drove real decisions before).
        _ft=$(bench_ctx "$_dc" "$BEST_B" "$BEST_U" 3 "$EFFECTIVE_MMAP" "$WIN_NGL" "filled" "$WIN_KVK" "$WIN_KVV") || _ft=""
        if [[ -n $_ft ]] && [[ $(echo "$_ft > 0" | bc 2>/dev/null || echo "0") == 1 ]]; then
            _fp="0"
            IFS='|' read -r _fd _fp _ff < "/tmp/at-metrics-$$" 2>/dev/null || true
            echo "  ctx $(fmt "$_dc") - filled ${_ft} tps (prefill ${_fp:-0} tok/s)"
            BEST_CTX=$_dc; BEST_TPS=$_ft; BEST_PREFILL="${_fp:-0}"
            _dok=0; _pok=0
            [[ $(echo "$_ft >= $MIN_TPS" | bc 2>/dev/null || echo "0") == 1 ]] && _dok=1
            if [[ $MIN_PREFILL_TPS == 0 ]] \
                || [[ $(echo "${_fp:-0} >= $MIN_PREFILL_TPS" | bc 2>/dev/null || echo "0") == 1 ]]; then
                _pok=1
            fi
            [[ $_dok == 1 && $_pok == 1 ]] && break
        else
            fail_label="OOM"
            [[ $(last_fail_type) == "load_fail" ]] && fail_label="unsupported model"
            echo "  ctx $(fmt "$_dc") - filled ${fail_label}"
        fi
        [[ $_dc -le $MIN_CTX ]] && break
        _next=$(( _dc * 3 / 4 )); _next=$(( _next / 512 * 512 ))
        [[ $_next -ge $_dc ]] && _next=$(( _dc - 512 ))
        [[ $_next -lt $MIN_CTX ]] && _next=$MIN_CTX
        _dc=$_next
    done

    # Final certification: triple-sample (median) at the winner for the
    # recorded number — the persisted TPS is a robust estimate, not a burst.
    _cert=$(bench_ctx "$BEST_CTX" "$BEST_B" "$BEST_U" 3 "$EFFECTIVE_MMAP" "$WIN_NGL" "filled" "$WIN_KVK" "$WIN_KVV") || _cert=""
    if [[ -n $_cert ]] && [[ $(echo "$_cert > 0" | bc 2>/dev/null || echo "0") == 1 ]]; then
        BEST_TPS=$_cert
        IFS='|' read -r _fd2 _fp2 _ff2 < "/tmp/at-metrics-$$" 2>/dev/null || true
        BEST_PREFILL="${_fp2:-0}"
    fi
    # Record GPU thermal/clock state alongside the certified number — heat
    # soak on a laptop biases later benches; the temp explains outliers.
    if command -v nvidia-smi >/dev/null 2>&1; then
        _gpu_thermal=$(nvidia-smi --query-gpu=temperature.gpu,clocks.sm --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ')
        echo "  thermal at certification: GPU ${_gpu_thermal:-n/a} (temp °C, SM MHz)"
    fi
fi

# Profile 2 (interactive) certification: one filled bench at the max-TPS
# config so the persisted numbers are honest sustained throughput.
if [[ $ANY_OK == true && -n $BEST_COMBO ]] && [[ $P2_CTX -gt 0 ]]; then
    if [[ "$P2_CTX|$P2_B:$P2_U" != "$BEST_CTX|$BEST_B:$BEST_U" ]]; then
        echo "  certifying profile 2 (interactive) at ctx=$(fmt "$P2_CTX")  $(fmt "$P2_B")/$(fmt "$P2_U")"
        _p2t=$(bench_ctx "$P2_CTX" "$P2_B" "$P2_U" 3 "$EFFECTIVE_MMAP" "$WIN_NGL" "filled" "$WIN_KVK" "$WIN_KVV") || _p2t=""
        if [[ -n $_p2t ]] && [[ $(echo "$_p2t > 0" | bc 2>/dev/null || echo "0") == 1 ]]; then
            P2_TPS=$_p2t
            IFS='|' read -r _pd3 _pp3 _pf3 < "/tmp/at-metrics-$$" 2>/dev/null || true
            P2_PREFILL="${_pp3:-0}"
        fi
    else
        P2_TPS=$BEST_TPS; P2_PREFILL=$BEST_PREFILL
    fi
fi


# REF: ubuntu-console card ca23ec0a — cleanup_gpu uses AUTOTUNE_PORT (18082), not the production port 18081
cleanup_gpu 3 >/dev/null 2>&1 || { echo "ERROR: cleanup_gpu failed after 3 retries — port ${AUTOTUNE_PORT:-18082} still bound" >&2; exit 1; }
echo ""

if [[ $ANY_OK == true && -n $BEST_COMBO ]]; then
    IFS=':' read -r BEST_B BEST_U <<< "$BEST_COMBO"

    # Capability verdict relative to the floor (filled-cache decode TPS). We
    # always persist the best config we found (autotuned=yes ⇒ "this model has
    # been profiled"), and the recorded TPS is the honest, machine-readable
    # signal of usability:
    #   tps >= floor  → usable; ctx is the maximum that sustains the floor.
    #   tps <  floor  → too slow for our purposes even at min ctx; the saved
    #                   config is the fastest one available (best-effort).
    if [[ $(echo "$BEST_TPS >= $MIN_TPS" | bc 2>/dev/null || echo "0") == 1 ]]; then
        echo "  ✓ meets floor: ${BEST_TPS} tps >= ${MIN_TPS} at max ctx $(fmt "$BEST_CTX")"
    else
        echo "  ⚠ below floor: ${BEST_TPS} tps < ${MIN_TPS} even at min ctx — too slow for our purposes"
        echo "    recording best-effort config (max TPS) for capability profiling"
    fi
    echo "      prefill: ${BEST_PREFILL:-0} tok/s"
    if [[ $MIN_PREFILL_TPS != 0 ]] && [[ $(echo "${BEST_PREFILL:-0} < $MIN_PREFILL_TPS" | bc 2>/dev/null || echo 0) == 1 ]]; then
        echo "  ⚠ prefill ${BEST_PREFILL:-0} tok/s below prefill floor ${MIN_PREFILL_TPS}"
    fi
    if [[ $WIN_NGL != "$BENCH_NGL" ]]; then
        echo "  ✓ ngl swept: ${BENCH_NGL} -> ${WIN_NGL}"
    fi
    if [[ "$WIN_KVK:$WIN_KVV" != "q8_0:q8_0" ]]; then
        echo "  ✓ KV quant swept: cache k=$WIN_KVK v=$WIN_KVV"
    fi
    if [[ $P2_CTX -gt 0 ]]; then
        echo "  profile 2: ctx=$(fmt "$P2_CTX")  batch=$(fmt "$P2_B")/$(fmt "$P2_U")  ${P2_TPS} tps (prefill ${P2_PREFILL:-0})"
    fi

    END_TS=$(date '+%H:%M:%S')
    DURATION=$(( $(date +%s) - START_EPOCH ))
    printf '  time:    %s \u2192 %s  (%dm %ds)\n' "$START_TS" "$END_TS" $((DURATION/60)) $((DURATION%60))
    echo "  winner:  ctx=$(fmt "$BEST_CTX")  batch=$(fmt "$BEST_B")/$(fmt "$BEST_U")  ${BEST_TPS} tps"

    # Profile-2 fields only when profile 2 exists (BEST exists ⇒ P2 exists).
    _P2ARGS=("" "" "" "" "")
    [[ $P2_CTX -gt 0 ]] && _P2ARGS=("$P2_CTX" "$P2_B" "$P2_U" "$P2_TPS" "$P2_PREFILL")
    # KV quant save: "QUANT/type-k/type-v" (field 5), preserving the quant part.
    KV_QUANT_SAVE=""
    if [[ -n "${_qc%%/*}" ]]; then
        KV_QUANT_SAVE="${_qc%%/*}/${WIN_KVK}/${WIN_KVV}"
    fi
    if declare -f __llm_autotune_profile_save &>/dev/null; then
        __llm_autotune_profile_save "$MODEL" "native" "$BEST_CTX" "$BEST_B" "$BEST_U" "1" "256" "$BEST_TPS" \
            "" "$BEST_PREFILL" "${_P2ARGS[@]}" "$KV_QUANT_SAVE" "$WIN_NGL" || echo "  warning: profile save failed"
    fi
    grep "^${MODEL}|" "$LLM_REGISTRY" | awk -F'|' '{printf "  saved:   ctx=%s batch=%s/%s tps=%s prefill=%s autotuned=%s\n", $8, $10, $11, $17, $21, $18}'
    echo ""
    echo "============================================="
    echo "  done"
    exit 0
else
    echo "  failed: unsupported model — model could not be loaded at any ctx"
    exit 1
fi

# end of file

# end of file marker
