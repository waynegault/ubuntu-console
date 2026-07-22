#!/home/linuxbrew/.linuxbrew/bin/bash
# shellcheck disable=SC1091
# AI INSTRUCTION: On ANY change to this file, increment the Module Version below.
# Module Version: 3
#===============================================================================
# autotune-model.sh — Find optimal ctx/batch/ubatch for one GGUF model.
#
# Phase 1: step down from start until a ctx works.
# Phase 2: step up 50% from working ctx until OOM, then binary probe
#          between the last working ctx and OOM point.
# Phase 4: TPS floor recovery — if the best config is below LLM_MIN_TPS,
#          step ctx DOWN (less KV cache → higher TPS) until the floor is
#          met or min ctx is reached. Winner = highest ctx sustaining the
#          floor; a model that cannot reach it is recorded as too slow.
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

IFS='|' read -r _num name file size _qc _arch gpu_layers _ctx _thr _ba _ub _pa _fi _be _mm _fa _tps _autotuned _isdef _vram <<< "$ENTRY"

MODEL_PATH="$LLAMA_MODEL_DIR/$file"
[[ -f "$MODEL_PATH" ]] || { echo "Error: File not found: $MODEL_PATH"; exit 1; }

SIZE_INT=${size%G}; SIZE_INT=${SIZE_INT%.*}; SIZE_INT=${SIZE_INT:-1}
[[ "$SIZE_INT" =~ ^[0-9]+$ ]] || SIZE_INT=1

CPU_COUNT=$(nproc 2>/dev/null || echo 6)
if [[ "$_thr" =~ ^[0-9]+$ ]] && [[ $_thr -gt 0 ]] && [[ $_thr -le $CPU_COUNT ]]; then
    TUNE_THREADS="$_thr"
else
    TUNE_THREADS="$CPU_COUNT"
fi
BENCH_NGL="${gpu_layers:-999}"
[[ ${gpu_layers:-999} -eq 0 ]] && TUNE_THREADS="$CPU_COUNT"

echo "[${MODEL}] ${name} (${size}, ${gpu_layers:-0} gpu layers)"
echo "  Bench NGL: ${BENCH_NGL}  — max envelope: 999"
echo ""

MIN_CTX=4096
# Uniform minimum acceptable generation speed. Sourced from env.sh (default 10).
MIN_TPS=${LLM_MIN_TPS:-10}

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

# Cap START_CTX by native training context to avoid probing into RoPE-extended
# territory where KV-cache load times explode and generation quality is unknown.
# Multiplier: 4× for <2 GB models (VRAM headroom), 2× for ≥2 GB (tight VRAM).
if [[ -n "${_native_ctx:-}" ]] && [[ "$_native_ctx" =~ ^[0-9]+$ ]] && [[ $_native_ctx -gt 0 ]]; then
    _mult=4
    [[ $MODEL_MB -ge 2000 ]] && _mult=2
    _ceiling=$(( _native_ctx * _mult ))
    [[ $START_CTX -gt $_ceiling ]] && START_CTX=$_ceiling
fi

# Comma-format numbers (standalone helpers — no outer-scope capture)
fmt() { printf "%'d" "$1"; }
fmts() { local _s; _s=$(printf "%'d" "${1%%:*}"); printf "%s:%'d" "$_s" "${1##*:}"; }

echo "============================================="
echo ""
echo "  threads=$(fmt "$TUNE_THREADS")  cpu=$(fmt "$CPU_COUNT")"
echo "  combos: $(fmts "${COMBOS[*]}")"
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
    local cleanup_port="${AUTOTUNE_PORT:-18081}"
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
# bench_once — start server, run benchmark, return TPS on stdout.
#   args: ctx batch ubatch [mmap_mode]
#   mmap_mode: "auto" (--mmap, default) or "off" (--no-mmap)
#   Defaults to --mmap to avoid CUDA malloc ghost-VRAM OOM on WSL2.
# ---------------------------------------------------------------------------
# Nested function — captures $MODEL from parent scope for temp-tag naming
bench_once() {
    local c="$1" b="$2" u="$3" mmap_mode="${4:-auto}" override_ngl="${5:-}"
    local tag="/tmp/at-vram-${MODEL}-${c}"
    local effective_ngl="${override_ngl:-${BENCH_NGL:-999}}"

    cleanup_gpu 2>/dev/null || { echo ""; return 1; }

    if [[ ! -f $tag ]]; then
        local g; g=$(nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ')
        echo "  VRAM cleared: $(fmt "${g:-?}") MiB free" >&2
        touch "$tag"
    fi

    local mmap_flag=""
    [[ $mmap_mode == off ]] && mmap_flag="--no-mmap"

    # REF: ubuntu-console card ca23ec0a — Use AUTOTUNE_PORT (default 18081)
    # to avoid conflicting with the watchdog daemon on LLM_PORT (8081).
    # The bench uses LLM_PORT which preserves the watchdog's port.
    local autotune_port="${AUTOTUNE_PORT:-18081}"
    # Update all curl/http references to use the same port
    local health_url="http://127.0.0.1:$autotune_port"
    "$LLAMA_BIN" --model "$MODEL_PATH" --port "$autotune_port" --host 127.0.0.1 \
        --ctx-size "$c" --batch-size "$b" --ubatch-size "$u" \
        --threads "$TUNE_THREADS" --n-gpu-layers "$effective_ngl" \
        --parallel 1 --fit off --flash-attn on --kv-offload \
        --cache-type-k q8_0 $mmap_flag \
        > "/tmp/at-${MODEL}-c${c}-b${b}.log" 2>&1 &
    local pid=$!

    local hw=0
    while [[ $hw -lt 90 ]]; do
        sleep 1; hw=$((hw + 1))
        kill -0 "$pid" 2>/dev/null || { echo ""; return 1; }
        curl -sS --max-time 2 "$health_url/health" 2>/dev/null | grep -q 'ok' && break
    done
    if [[ $hw -ge 90 ]]; then
        kill "$pid" 2>/dev/null; sleep 1; kill -9 "$pid" 2>/dev/null
        echo ""; return 1
    fi

    # Pre-flight: confirm model slot is actually ready to serve.
    # WSL2 drvfs: /health returns OK before the GGUF memory-map completes,
    # so the first real completion can stall or return 0 tokens.
    local pf_ok=0 pf_w=0
    while [[ $pf_w -lt 60 ]]; do
        if curl -sS --max-time 5 "$health_url/v1/chat/completions" \
            -H "Content-Type: application/json" \
            -d '{"messages":[{"role":"user","content":"hi"}],"max_tokens":1,"temperature":0}' \
            2>/dev/null | "$TAC_PYTHON" -c "import sys,json; d=json.load(sys.stdin); print(d.get('usage',{}).get('completion_tokens',0))" 2>/dev/null | grep -q '[1-9]'; then
            pf_ok=1; break
        fi
        kill -0 "$pid" 2>/dev/null || { echo ""; return 1; }
        sleep 1; pf_w=$((pf_w + 1))
    done
    if [[ $pf_ok -ne 1 ]]; then
        kill "$pid" 2>/dev/null; sleep 1; kill -9 "$pid" 2>/dev/null
        echo ""; return 1
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

    local start_ns; start_ns=$(date +%s%N)
    local resp; resp=$(curl -sS --max-time 180 "$health_url/v1/chat/completions" \
        -H "Content-Type: application/json" -d @"$PAYLOAD_FILE" 2>/dev/null) || true
    local end_ns; end_ns=$(date +%s%N)
    kill "$pid" 2>/dev/null; sleep 1; kill -9 "$pid" 2>/dev/null

    local elapsed_ms=$(( (end_ns - start_ns) / 1000000 ))
    local tokens; tokens=$(echo "$resp" | "$TAC_PYTHON" -c "
import sys, json
try: d=json.load(sys.stdin); print(d.get('usage',{}).get('completion_tokens',0))
except: print(0)" 2>/dev/null) || tokens=0
    [[ "$tokens" =~ ^[0-9]+$ ]] || tokens=0

    if [[ $elapsed_ms -gt 0 && $tokens -gt 0 ]]; then
        echo "scale=2; $tokens * 1000 / $elapsed_ms" | bc 2>/dev/null || echo "0"
        return 0
    fi
    echo ""
    return 1
}

# ---------------------------------------------------------------------------
# bench_ctx — returns TPS on stdout, empty on failure. RC 0/1.
#   args: ctx batch ubatch [samples] [mmap_mode]
# ---------------------------------------------------------------------------
bench_ctx() {
    local c="$1" b="$2" u="$3" samples="${4:-1}" mmap_mode="${5:-auto}" override_ngl="${6:-}"

    if [[ $samples -eq 1 ]]; then
        local tps; tps=$(bench_once "$c" "$b" "$u" "$mmap_mode" "$override_ngl") || { echo ""; return 1; }
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

    local t1; t1=$(bench_once "$c" "$b" "$u" "$mmap_mode" "$override_ngl") || t1=""
    t1=$(echo "$t1" | bc 2>/dev/null || echo "0")
    local t2; t2=$(bench_once "$c" "$b" "$u" "$mmap_mode" "$override_ngl") || t2=""
    t2=$(echo "$t2" | bc 2>/dev/null || echo "0")

    local o=0
    [[ $(echo "$t1 <= 0" | bc 2>/dev/null || echo "1") == 1 ]] && o=$((o+1))
    [[ $(echo "$t2 <= 0" | bc 2>/dev/null || echo "1") == 1 ]] && o=$((o+1))
    if [[ $o -ge 2 ]]; then echo ""; return 1; fi

    local tps
    if [[ $o -eq 0 ]]; then
        tps=$(echo "($t1+$t2)/2" | bc -l 2>/dev/null || echo "$t1")
    else
        [[ $(echo "$t1 > 0" | bc 2>/dev/null || echo "0") == 1 ]] && tps=$t1 || tps=$t2
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
            echo "  ctx $(fmt "$BEST_CTX") - OOM with batch $(fmt "$b")/$(fmt "$u")"
        fi
        continue
    fi
    test_num=0; c=$c0; found=false
    while [[ $c -ge $MIN_CTX ]]; do
        test_num=$((test_num + 1))
        tps=$(bench_ctx "$c" "$b" "$u" 1) || {
            echo "  Test $test_num: ctx $(fmt "$c") - OOM: dropping to $(fmt $((c/2)))"
            c=$((c/2)); [[ $c -lt $MIN_CTX ]] && break; continue
        }
        echo "  Test $test_num: ctx $(fmt "$c") - ${tps} tps"
        found=true; ANY_OK=true
        record_best "$c" "$tps" "$b" "$u"

        # Phase 2: step up 50%, stop if TPS stable for 3 steps
        lo=$c; hi=0; c=$((c * 3 / 2)); prev_tps=$tps; stable=0
        while true; do
            test_num=$((test_num + 1))
            bench_ctx "$c" "$b" "$u" 1 > /tmp/at-tps-$$; rc=$?
            tps=$(cat /tmp/at-tps-$$ 2>/dev/null)
            # REF: ubuntu-console card b564d801 — bench_ctx can return rc=0 with tps=0
            # when the server replies successfully with 0 completion tokens.
            # Catch both non-zero rc AND empty/zero tps as OOM to ensure consistent
            # classification in the binary probe.
            if [[ $rc -ne 0 ]] || [[ -z "$tps" || "$tps" == "0" || "$tps" == "0.00" || "$tps" == "0,00" ]]; then
                hi=$c
                if [[ -n "$tps" && "$tps" == "0" ]]; then
                    echo "  Test $test_num: ctx $(fmt "$c") - 0 tps (OOM): binary probe $(fmt $(( (lo+hi)/2/512*512 )))"
                else
                    echo "  Test $test_num: ctx $(fmt "$c") - OOM: binary probe $(fmt $(( (lo+hi)/2/512*512 )))"
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
                hi=$((c * 3 / 2))
                break
            fi
            echo "  Test $test_num: ctx $(fmt "$c") - ${tps} tps - climbing to $(fmt $((c*3/2)))"
            c=$((c * 3 / 2))
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
                echo "  Test $test_num: ctx $(fmt "$c") - OOM"
            else
                lo=$c; record_best "$lo" "$tps" "$b" "$u"
                echo "  Test $test_num: ctx $(fmt "$c") - ${tps} tps"
            fi
        done
        fi
        break
    done
    [[ $found == false ]] && echo "  Test $test_num: ctx $(fmt "$c") - OOM - model cannot run at any ctx"
done

# --- mmap fallback ---
# If --mmap (default) failed at all ctx for all combos, retry with --no-mmap.
# Some architectures (phi3, gemma3n) need --no-mmap for stable VRAM allocation.
if [[ $ANY_OK == false ]]; then
    echo ""
    echo "  --mmap failed at all ctx — retrying with --no-mmap"
    echo ""
    for combo in "${COMBOS[@]}"; do
        IFS=':' read -r b u <<< "$combo"
        echo "  batch $(fmt "$b")/$(fmt "$u")  (--no-mmap)"
        echo "  ---------------------"

        c=$START_CTX; found=false
        while [[ $c -ge $MIN_CTX ]]; do
            tps=$(bench_ctx "$c" "$b" "$u" 1 "off") || {
                echo "  ctx $(fmt "$c") - OOM: dropping to $(fmt $((c/2)))"
                c=$((c/2)); [[ $c -lt $MIN_CTX ]] && break; continue
            }
            echo "  ctx $(fmt "$c") - ${tps} tps"
            found=true; ANY_OK=true
            record_best "$c" "$tps" "$b" "$u"
            # Phase 2: step up, stop at first OOM (fallback path — keep it simple)
            lo=$c; c=$((c * 3 / 2))
            while true; do
                bench_ctx "$c" "$b" "$u" 1 "off" > /tmp/at-tps-$$; rc=$?
                tps=$(cat /tmp/at-tps-$$ 2>/dev/null)
                if [[ $rc -ne 0 ]]; then
                    echo "  ctx $(fmt "$c") - OOM"
                    break
                fi
                lo=$c; record_best "$lo" "$tps" "$b" "$u"
                echo "  ctx $(fmt "$c") - ${tps} tps - climbing to $(fmt $((c*3/2)))"
                c=$((c * 3 / 2))
            done
            break
        done
    done
fi

# --- Ubatch ratio testing ---
if [[ $ANY_OK == true && -n $BEST_COMBO ]]; then
    IFS=':' read -r BEST_B BEST_U <<< "$BEST_COMBO"
    echo ""
    echo "  ubatch testing at ctx=$(fmt "$BEST_CTX") batch=$(fmt "$BEST_B")"
    echo "  ---------------------"
    for ub in 128 256 512; do
        [[ $ub -eq $BEST_U ]] && continue
        [[ $ub -gt $BEST_B ]] && continue
        tps=$(bench_ctx "$BEST_CTX" "$BEST_B" "$ub" 1) || tps=""
        if [[ -n $tps ]]; then
            echo "  ubatch $ub - ${tps} tps"
            record_best "$BEST_CTX" "$tps" "$BEST_B" "$ub"
        else
            echo "  ubatch $ub - OOM"
        fi
    done
fi

# --- Phase 4: TPS floor recovery ---
# The probe maximises ctx, which on a 4 GB card can leave a model swapping at
# large context (high ctx, low TPS). If the best config is below the floor,
# step ctx DOWN — a smaller KV cache raises TPS — until we meet the floor or
# hit MIN_CTX. Descending top-down means the first ctx that meets the floor is
# the highest ctx that sustains it, which is exactly the capability we want to
# record. A model still below floor at MIN_CTX is genuinely too slow.
if [[ $ANY_OK == true && -n $BEST_COMBO ]] && [[ $(echo "$BEST_TPS < $MIN_TPS" | bc 2>/dev/null || echo 0) == 1 ]]; then
    IFS=':' read -r BEST_B BEST_U <<< "$BEST_COMBO"
    echo ""
    echo "  TPS ${BEST_TPS} below floor ${MIN_TPS} — downshifting ctx to recover TPS"
    echo "  ---------------------"
    _dc=$BEST_CTX
    while [[ $(echo "$BEST_TPS < $MIN_TPS" | bc 2>/dev/null || echo 0) == 1 ]] && [[ $_dc -gt $MIN_CTX ]]; do
        next=$(( _dc * 3 / 4 ))
        next=$(( next / 512 * 512 ))
        [[ $next -ge $_dc ]] && next=$(( _dc - 512 ))
        [[ $next -lt $MIN_CTX ]] && next=$MIN_CTX
        tps=$(bench_ctx "$next" "$BEST_B" "$BEST_U" 1) || tps=""
        if [[ -n $tps ]]; then
            echo "  ctx $(fmt "$next") - ${tps} tps"
            BEST_CTX=$next; BEST_TPS=$tps
        else
            echo "  ctx $(fmt "$next") - OOM"
        fi
        _dc=$next
    done
fi


# REF: ubuntu-console card ca23ec0a — cleanup_gpu uses AUTOTUNE_PORT, not 8081
cleanup_gpu 3 >/dev/null 2>&1 || { echo "ERROR: cleanup_gpu failed after 3 retries — port ${AUTOTUNE_PORT:-18081} still bound" >&2; exit 1; }
echo ""

if [[ $ANY_OK == true && -n $BEST_COMBO ]]; then
    IFS=':' read -r BEST_B BEST_U <<< "$BEST_COMBO"

    # Capability verdict relative to the floor. We always persist the best
    # config we found (autotuned=yes ⇒ "this model has been profiled"), and the
    # recorded TPS is the honest, machine-readable signal of usability:
    #   tps >= floor  → usable; ctx is the maximum that sustains the floor.
    #   tps <  floor  → too slow for our purposes even at min ctx; the saved
    #                   config is the fastest one available (best-effort).
    if [[ $(echo "$BEST_TPS >= $MIN_TPS" | bc 2>/dev/null || echo "0") == 1 ]]; then
        echo "  ✓ meets floor: ${BEST_TPS} tps >= ${MIN_TPS} at max ctx $(fmt "$BEST_CTX")"
    else
        echo "  ⚠ below floor: ${BEST_TPS} tps < ${MIN_TPS} even at min ctx — too slow for our purposes"
        echo "    recording best-effort config (max TPS) for capability profiling"
    fi

    END_TS=$(date '+%H:%M:%S')
    DURATION=$(( $(date +%s) - START_EPOCH ))
    printf '  time:    %s \u2192 %s  (%dm %ds)\n' "$START_TS" "$END_TS" $((DURATION/60)) $((DURATION%60))
    echo "  winner:  ctx=$(fmt "$BEST_CTX")  batch=$(fmt "$BEST_B")/$(fmt "$BEST_U")  ${BEST_TPS} tps"
    if declare -f __llm_autotune_profile_save &>/dev/null; then
        __llm_autotune_profile_save "$MODEL" "native" "$BEST_CTX" "$BEST_B" "$BEST_U" "1" "256" "$BEST_TPS" || echo "  warning: profile save failed"
    fi
    grep "^${MODEL}|" "$LLM_REGISTRY" | awk -F'|' '{printf "  saved:   ctx=%s batch=%s/%s tps=%s autotuned=%s\n", $8, $10, $11, $17, $18}'
    echo ""
    echo "============================================="
    echo "  done"
    exit 0
else
    echo "  failed: no working config"
    exit 1
fi

# end of file
