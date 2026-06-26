#!/home/linuxbrew/.linuxbrew/bin/bash
# shellcheck disable=SC1091
# AI INSTRUCTION: On ANY change to this file, increment the Module Version below.
# Module Version: 2
#===============================================================================
# autotune-model.sh — Find optimal ctx/batch/ubatch for one GGUF model.
#
# Phase 1: step down from start until a ctx works.
# Phase 2: step up 50% from working ctx until OOM, then binary probe
#          between the last working ctx and OOM point.
# Score  : ctx × tps (penalises VRAM-swapping configurations).
#
# Sources tactical-console functions for VRAM budget, stale process cleanup,
# GGUF metadata, and profile saving — no duplicates.
#===============================================================================

set -uo pipefail

MODEL="${1:?Usage: autotune-model.sh MODEL_NUM}"
[[ "$MODEL" =~ ^[0-9]+$ ]] || { echo "Error: MODEL_NUM must be a number"; exit 1; }

cd /home/wayne/ubuntu-console || exit 1
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
[ -f "$MODEL_PATH" ] || { echo "Error: File not found: $MODEL_PATH"; exit 1; }

SIZE_INT=${size%G}; SIZE_INT=${SIZE_INT%.*}; SIZE_INT=${SIZE_INT:-1}
[[ "$SIZE_INT" =~ ^[0-9]+$ ]] || SIZE_INT=1

CPU_COUNT=$(nproc 2>/dev/null || echo 6)
if [[ "$_thr" =~ ^[0-9]+$ ]] && [ "$_thr" -gt 0 ] && [ "$_thr" -le "$CPU_COUNT" ]; then
    TUNE_THREADS="$_thr"
else
    TUNE_THREADS="$CPU_COUNT"
fi
[ "${gpu_layers:-999}" -eq 0 ] && TUNE_THREADS="$CPU_COUNT"

echo "[${MODEL}] ${name} (${size}, ${gpu_layers:-0} gpu layers)"
echo ""

# Combos — same for all model sizes (spec needs updating but code works)
COMBOS=("1024:256" "2048:512" "4096:1024")

MIN_CTX=4096
MIN_TPS=${LLM_MIN_TPS:-20}

# ---------------------------------------------------------------------------
# VRAM-based start ctx using shared __kv_mb_per_1k when available
# Falls back to simple size-class factor if functions unavailable.
# ---------------------------------------------------------------------------
MODEL_BYTES=$(stat --format=%s "$MODEL_PATH" 2>/dev/null || echo 0)
FREE_VRAM=$(nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ')
FREE_VRAM=${FREE_VRAM:-3965}
MODEL_MB=$(( MODEL_BYTES / 1048576 ))
BUDGET=$(( FREE_VRAM - MODEL_MB - 200 ))

if declare -f __kv_mb_per_1k &>/dev/null && declare -f __gguf_metadata &>/dev/null; then
    # Shared function path — architecture-aware estimate
    _meta=$(__gguf_metadata "$MODEL_PATH" 2>/dev/null || true)
    if [[ -n "$_meta" ]]; then
        _n_layers=$(echo "$_meta" | cut -d'|' -f3)
        _kv_mb=$(__kv_mb_per_1k "${_n_layers:-0}")
    else
        _kv_mb=$(__kv_mb_per_1k "0")
    fi
    if (( BUDGET > 0 )); then
        START_CTX=$(awk -v b="$BUDGET" -v k="$_kv_mb" 'BEGIN{c=int((b/k)*1000); print c<4096?4096:c}')
    else
        START_CTX=$MIN_CTX
    fi
else
    # Standalone fallback: size-class factor heuristic
    if [ "$MODEL_MB" -gt 3000 ]; then FACTOR=50
    elif [ "$MODEL_MB" -gt 2000 ]; then FACTOR=100
    elif [ "$MODEL_MB" -gt 1000 ]; then FACTOR=500
    else FACTOR=1000; fi
    if [ "$BUDGET" -gt 0 ]; then START_CTX=$(( BUDGET * FACTOR ))
    else START_CTX=$MIN_CTX; fi
fi

START_CTX=$(( (START_CTX / 1024) * 1024 ))
[ "$START_CTX" -lt "$MIN_CTX" ] && START_CTX=$MIN_CTX
[ "$START_CTX" -gt 4194304 ] && START_CTX=4194304

# Comma-format numbers
fmt() { echo "$1" | sed ':a;s/\B[0-9]\{3\}\>/,&/;ta'; }
fmts() { echo "$1" | sed 's/1024/1,024/g; s/2048/2,048/g; s/4096/4,096/g; s/:256/:256/g; s/:512/:512/g; s/:1024/:1,024/g'; }

echo "============================================="
echo ""
echo "  threads=$(fmt "$TUNE_THREADS")  cpu=$(fmt "$CPU_COUNT")"
echo "  combos: $(fmts "${COMBOS[*]}")"
echo "  probe:  start=$(fmt "$START_CTX") min_tps=${MIN_TPS}"
START_TS=$(date '+%H:%M:%S')
echo "  start:  ${START_TS}"
echo ""
START_EPOCH=$(date +%s)

LLAMA_BIN="${LLAMA_SERVER_BIN:-/home/wayne/llama.cpp/build/bin/llama-server}"
PAYLOAD_FILE="/tmp/autotune-payload-${MODEL}.json"
cat > "$PAYLOAD_FILE" << 'PAYLOAD'
{"messages":[{"role":"user","content":"Explain special relativity: time dilation, length contraction, mass-energy equivalence."}],"max_tokens":256,"temperature":0}
PAYLOAD

#==============================================================================
# Helpers
#==============================================================================

# Shared cleanup — kills llama-server AND stale python/CUDA processes
cleanup_gpu() {
    if declare -f __gpu_clear_stale_processes &>/dev/null; then
        pkill -9 -x llama-server 2>/dev/null || true
        sleep 1
        __gpu_clear_stale_processes
    else
        pkill -9 -x llama-server 2>/dev/null || true
    fi
    local waited=0
    while [ "$waited" -lt 20 ]; do
        if ! ss -ltn 2>/dev/null | awk '{print $4}' | grep -Eq '(^|:)8081$'; then return 0; fi
        sleep 1; waited=$((waited + 1))
    done
    return 1
}

# ---------------------------------------------------------------------------
# bench_once — start server, run benchmark, return TPS on stdout.
# ---------------------------------------------------------------------------
bench_once() {
    local c="$1" b="$2" u="$3"
    local tag="/tmp/at-vram-${MODEL}-${c}"

    cleanup_gpu 2>/dev/null || { echo ""; return 1; }

    if [ ! -f "$tag" ]; then
        local g; g=$(nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ')
        echo "  VRAM cleared: $(fmt "${g:-?}") MiB free" >&2
        touch "$tag"
    fi

    "$LLAMA_BIN" --model "$MODEL_PATH" --port 8081 --host 127.0.0.1 \
        --ctx-size "$c" --batch-size "$b" --ubatch-size "$u" \
        --threads "$TUNE_THREADS" --n-gpu-layers "${gpu_layers:-999}" \
        --parallel 1 --fit off --flash-attn on --kv-offload \
        --cache-type-k q8_0 --no-mmap \
        > "/tmp/at-${MODEL}-c${c}-b${b}.log" 2>&1 &
    local pid=$!

    local hw=0
    while [ "$hw" -lt 90 ]; do
        sleep 1; hw=$((hw + 1))
        kill -0 "$pid" 2>/dev/null || { echo ""; return 1; }
        curl -sS --max-time 2 http://127.0.0.1:8081/health 2>/dev/null | grep -q 'ok' && break
    done
    if [ "$hw" -ge 90 ]; then
        kill "$pid" 2>/dev/null; sleep 1; kill -9 "$pid" 2>/dev/null
        echo ""; return 1
    fi

    local start_ns; start_ns=$(date +%s%N)
    local resp; resp=$(curl -sS --max-time 180 http://127.0.0.1:8081/v1/chat/completions \
        -H "Content-Type: application/json" -d @"$PAYLOAD_FILE" 2>/dev/null) || true
    local end_ns; end_ns=$(date +%s%N)
    kill "$pid" 2>/dev/null; sleep 1; kill -9 "$pid" 2>/dev/null

    local elapsed_ms=$(( (end_ns - start_ns) / 1000000 ))
    local tokens; tokens=$(echo "$resp" | python3 -c "
import sys, json
try: d=json.load(sys.stdin); print(d.get('usage',{}).get('completion_tokens',0))
except: print(0)" 2>/dev/null) || tokens=0
    [[ "$tokens" =~ ^[0-9]+$ ]] || tokens=0

    if [ "$elapsed_ms" -gt 0 ] && [ "$tokens" -gt 0 ]; then
        echo "scale=1; $tokens * 1000 / $elapsed_ms" | bc 2>/dev/null || echo "0"
        return 0
    fi
    echo ""
    return 1
}

# ---------------------------------------------------------------------------
# bench_ctx — returns TPS on stdout, empty on failure. RC 0/1.
# ---------------------------------------------------------------------------
bench_ctx() {
    local c="$1" b="$2" u="$3" samples="${4:-1}"

    if [ "$samples" -eq 1 ]; then
        local tps; tps=$(bench_once "$c" "$b" "$u") || { echo ""; return 1; }
        tps=$(echo "$tps" | bc 2>/dev/null || echo "0"); [ -z "$tps" ] && tps=0
        if [ "$(echo "$tps <= 0" | bc 2>/dev/null || echo "1")" = "1" ]; then echo ""; return 1; fi
        if [ "$(echo "$tps < $MIN_TPS" | bc 2>/dev/null || echo "0")" = "1" ]; then echo ""; return 1; fi
        echo "$tps"
        return 0
    fi

    local t1; t1=$(bench_once "$c" "$b" "$u") || t1=""
    t1=$(echo "$t1" | bc 2>/dev/null || echo "0")
    local t2; t2=$(bench_once "$c" "$b" "$u") || t2=""
    t2=$(echo "$t2" | bc 2>/dev/null || echo "0")

    local o=0
    [ "$(echo "$t1 <= 0" | bc 2>/dev/null || echo "1")" = "1" ] && o=$((o+1))
    [ "$(echo "$t2 <= 0" | bc 2>/dev/null || echo "1")" = "1" ] && o=$((o+1))
    if [ "$o" -ge 2 ]; then echo ""; return 1; fi

    local tps
    if [ "$o" -eq 0 ]; then
        tps=$(echo "($t1+$t2)/2" | bc -l 2>/dev/null || echo "$t1")
    else
        [ "$(echo "$t1 > 0" | bc 2>/dev/null || echo "0")" = "1" ] && tps=$t1 || tps=$t2
    fi
    tps=$(echo "scale=2; $tps / 1" | bc -l 2>/dev/null || echo "$tps"); [ -z "$tps" ] && tps=0
    if [ "$(echo "$tps < $MIN_TPS" | bc 2>/dev/null || echo "0")" = "1" ]; then echo ""; return 1; fi
    echo "$tps"
    return 0
}

#==============================================================================
# Probe
#==============================================================================

BEST_SCORE=0; BEST_TPS="0"; BEST_COMBO=""; BEST_CTX=0; ANY_OK=false

record_best() {
    local c=$1 tps=$2 b=$3 u=$4
    local s; s=$(echo "$c * $tps" | bc 2>/dev/null || echo "0")
    [ "$(echo "$s > $BEST_SCORE" | bc 2>/dev/null || echo "0")" = "1" ] && \
        { BEST_SCORE=$s; BEST_TPS=$tps; BEST_COMBO="$b:$u"; BEST_CTX=$c; }
}

for combo in "${COMBOS[@]}"; do
    IFS=':' read -r b u <<< "$combo"
    echo ""
    echo "  batch $(fmt "$b")/$(fmt "$u")"
    echo "  ---------------------"

    c0=$START_CTX
    if [ "$BEST_CTX" -gt 0 ]; then
        tps=$(bench_ctx "$BEST_CTX" "$b" "$u" 1) || tps=""
        if [ -n "$tps" ]; then
            echo "  ctx $(fmt "$BEST_CTX") - ${tps} tps"
            ANY_OK=true; record_best "$BEST_CTX" "$tps" "$b" "$u"
        else
            echo "  ctx $(fmt "$BEST_CTX") - OOM with batch $(fmt "$b")/$(fmt "$u")"
        fi
        continue
    fi
    test_num=0; c=$c0; found=false
    while [ "$c" -ge "$MIN_CTX" ]; do
        test_num=$((test_num + 1))
        tps=$(bench_ctx "$c" "$b" "$u" 1) || {
            echo "  Test $test_num: ctx $(fmt "$c") - OOM: dropping to $(fmt $((c/2)))"
            c=$((c/2)); [ "$c" -lt "$MIN_CTX" ] && break; continue
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
            if [ "$rc" -ne 0 ]; then
                hi=$c
                echo "  Test $test_num: ctx $(fmt "$c") - OOM: binary probe $(fmt $(( (lo+hi)/2/512*512 )))"
                break
            fi
            lo=$c; record_best "$lo" "$tps" "$b" "$u"
            drop=$(echo "scale=4; ($prev_tps - $tps) / $prev_tps" | bc 2>/dev/null || echo "0")
            if [ "$(echo "$drop < 0.10" | bc 2>/dev/null || echo "0")" = "1" ]; then
                stable=$((stable + 1))
            else
                stable=0; prev_tps=$tps
            fi
            if [ "$stable" -ge 3 ]; then
                echo "  Test $test_num: ctx $(fmt "$c") - ${tps} tps (TPS stable, stopping climb)"
                hi=$((c * 3 / 2))
                break
            fi
            echo "  Test $test_num: ctx $(fmt "$c") - ${tps} tps - climbing to $(fmt $((c*3/2)))"
            c=$((c * 3 / 2))
        done

        # If first step-up OOM'd and TPS was marginal (< 25), skip binary probe.
        if [ "$hi" -gt 0 ] && [ "$(echo "$BEST_TPS < 25" | bc 2>/dev/null || echo "0")" = "1" ]; then
            echo "  (TPS marginal, no binary probe needed)" 
        else
        # Binary probe between lo (working) and hi (OOM) — max 5 steps
        prev_c=-1; probe_count=0
        while [ $((hi - lo)) -ge 512 ] && [ "$probe_count" -lt 5 ]; do
            probe_count=$((probe_count + 1))
            c=$(( (lo + hi) / 2 / 512 * 512 ))
            [ "$c" -eq "$prev_c" ] && break
            prev_c=$c
            test_num=$((test_num + 1))
            bench_ctx "$c" "$b" "$u" 1 > /tmp/at-tps-$$; rc=$?
            tps=$(cat /tmp/at-tps-$$ 2>/dev/null)
            if [ "$rc" -ne 0 ]; then
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
    [ "$found" = false ] && echo "  Test $test_num: ctx $(fmt "$c") - OOM - model cannot run at any ctx"
done

# --- Ubatch ratio testing ---
if [ "$ANY_OK" = true ] && [ -n "$BEST_COMBO" ]; then
    IFS=':' read -r BEST_B BEST_U <<< "$BEST_COMBO"
    echo ""
    echo "  ubatch testing at ctx=$(fmt "$BEST_CTX") batch=$(fmt "$BEST_B")"
    echo "  ---------------------"
    for ub in 128 256 512; do
        [ "$ub" -eq "$BEST_U" ] && continue
        [ "$ub" -gt "$BEST_B" ] && continue
        tps=$(bench_ctx "$BEST_CTX" "$BEST_B" "$ub" 1) || tps=""
        if [ -n "$tps" ]; then
            echo "  ubatch $ub - ${tps} tps"
            record_best "$BEST_CTX" "$tps" "$BEST_B" "$ub"
        else
            echo "  ubatch $ub - OOM"
        fi
    done
fi


cleanup_gpu >/dev/null 2>&1 || true
echo ""

if [ "$ANY_OK" = true ] && [ -n "$BEST_COMBO" ]; then
    IFS=':' read -r BEST_B BEST_U <<< "$BEST_COMBO"
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
