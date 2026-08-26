#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2034
# AI INSTRUCTION: On ANY change to this file, increment the Module Version below.
# Module Version: 2
#===============================================================================
# spec-decode-bench.sh — Per-prompt speculative-decoding acceptance bench.
#
# SPEC-DEC-003/006: measures ACCEPTANCE LENGTH (accepted draft tokens per
# round + 1), acceptance rate, and block size PER PROMPT over the real
# workload distribution — legal-RAG and agentic-tool-call prompts — instead
# of physics/chat burn prompts, so block-size tuning (SPEC-DEC-004 autotune)
# is driven by acceptance-length data from the actual workload.
#
# The active model server (started via `model`/`__model_use`, or already
# running on $LLM_PORT) must be launched with speculative decoding enabled
# (ngram or draft flags).  Each completed request appends one
# "draft acceptance = ..." stats line to $LLM_LOG_FILE; this script sends
# the prompts sequentially and attributes the new stats lines by request
# order.  TPS is de-inflated: usage.completion_tokens counts accepted
# final-block tokens discarded at max_tokens, so the reported tokens are
# capped at the requested budget (counter-inflation guard, SPEC-DEC-003).
#
# Usage:  spec-decode-bench.sh [--max-tokens N] [--set all|physics|legal|agentic]
#   --set      prompt set (default all)
#   --max-tokens  output budget per prompt (default 256)
#
# REF: "Speculative Decoding on CPUs — Nearly 4x Faster Token Generation
# with DFlash" (Intel, TDS 2026)
# https://towardsdatascience.com/speculative-decoding-on-cpus-nearly-4x-faster-token-generation-with-dflash/
#===============================================================================

set -uo pipefail

_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$_SELF_DIR/.." || exit 1

source env.sh 2>/dev/null || { echo "Failed to source env.sh"; exit 1; }
source scripts/01-constants.sh 2>/dev/null || true
source scripts/11-llm-manager.sh 2>/dev/null || true
# SPEC-DEC-006 prompt sets (AUTOTUNE-001: single source shared with
# autotune-model.sh's scoring payload — do not redefine prompts here).
source scripts/prompt-sets.sh 2>/dev/null || true

MAX_TOKENS=256
PROMPT_SET="all"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --max-tokens) MAX_TOKENS="$2"; shift 2 ;;
        --set) PROMPT_SET="$2"; shift 2 ;;
        *) echo "Unknown arg: $1" >&2; exit 1 ;;
    esac
done
[[ "$MAX_TOKENS" =~ ^[0-9]+$ ]] && [[ $MAX_TOKENS -gt 0 ]] || MAX_TOKENS=256

# ── Prompt sets (SPEC-DEC-006) ───────────────────────────────────────────────
# Acceptance varies by content domain and collapses when the drafter's domain
# does not match the prompt; these are the investigator's real workloads.
# The arrays live in scripts/prompt-sets.sh (shared with autotune-model.sh).
# REF: DFlash TDS article, pitfall #7 (domain mismatch).

__resolve_prompt_set "$PROMPT_SET" || {
    echo "Unknown --set '$PROMPT_SET' (all|physics|legal|agentic)" >&2
    exit 1
}

# ── Pre-flight ───────────────────────────────────────────────────────────────
if ! __llm_is_healthy
then
    echo "No healthy llama-server on port ${LLM_PORT:-8080} — start a model first (model N) or launch with spec-decode flags." >&2
    exit 1
fi

local_url="http://127.0.0.1:${LLM_PORT:-8080}/v1/chat/completions"

# Snapshot the count of stats lines already in the log so per-prompt
# attribution only sees this run's requests.
before_count=$(grep -c 'draft acceptance = ' "$LLM_LOG_FILE" 2>/dev/null || echo 0)

block_size=$(__spec_block_size)
printf 'spec-decode bench: %s prompts, max_tokens=%s, block size=%s\n' \
    "${#PROMPTS[@]}" "$MAX_TOKENS" "$block_size"

results_delivered=()
results_usage=()
results_tps=()
for (( i = 0; i < ${#PROMPTS[@]}; i++ )); do
    name="${PROMPT_NAMES[$i]}"
    prompt="${PROMPTS[$i]}"
    payload=$(jq -n \
        --arg p "$prompt" \
        --argjson mt "$MAX_TOKENS" \
        '{messages: [{role: "system", content: "You are a legal analyst. Respond concisely."}, {role: "user", content: $p}], max_tokens: $mt, temperature: 0}')

    start_ns=$(date +%s%N)
    resp=$(curl -sS --max-time 300 "$local_url" -H "Content-Type: application/json" -d "$payload" 2>/dev/null) || true
    end_ns=$(date +%s%N)
    elapsed_ms=$(( (end_ns - start_ns) / 1000000 ))

    tokens_usage=$(printf '%s' "$resp" | jq -r '.usage.completion_tokens // 0' 2>/dev/null)
    [[ "$tokens_usage" =~ ^[0-9]+$ ]] || tokens_usage=0
    delivered=$tokens_usage
    (( delivered > MAX_TOKENS )) && delivered=$MAX_TOKENS
    tps=0
    if (( elapsed_ms > 0 && delivered > 0 )); then
        tps=$(awk -v t="$delivered" -v ms="$elapsed_ms" 'BEGIN { printf "%.1f", t * 1000 / ms }')
    fi
    results_delivered[i]="$delivered"
    results_usage[i]="$tokens_usage"
    results_tps[i]="$tps"
done

# ── Acceptance stats: pair new stats lines with prompts by request order ─────
after_count=$(grep -c 'draft acceptance = ' "$LLM_LOG_FILE" 2>/dev/null || echo 0)
new_count=$(( after_count - before_count ))
if (( new_count < ${#PROMPTS[@]} )); then
    printf '\nnote: %s/%s requests have acceptance stats (spec-decode must be enabled on the server)\n' \
        "$new_count" "${#PROMPTS[@]}"
fi

# Re-run the table with acceptance data when available.
if (( new_count > 0 )); then
    mapfile -t stat_lines < <(grep 'draft acceptance = ' "$LLM_LOG_FILE" 2>/dev/null | tail -n "$new_count")
    printf '\n%-44s %10s %8s %6s %8s %8s\n' "prompt" "accept_len" "rate" "block" "tps" "tok(del/use)"
    for (( i = 0; i < ${#PROMPTS[@]}; i++ )); do
        name="${PROMPT_NAMES[$i]}"
        if (( i < ${#stat_lines[@]} )); then
            _line="${stat_lines[$i]}"
            # draft acceptance = RATE (  N accepted /  M generated), mean len =  LEN
            _rate=$(echo "$_line" | sed -E 's/draft acceptance = ([0-9.]+).*/\1/')
            _len=$(echo "$_line" | sed -E 's/.*mean len = *([0-9.]+).*/\1/')
            printf '%-44s %10s %8s %6s %8s %8s\n' \
                "$name" "$_len" "$_rate" "$block_size" \
                "${results_tps[$i]}" "${results_delivered[$i]}/${results_usage[$i]}"
        else
            printf '%-44s %10s %8s %6s %8s %8s\n' \
                "$name" "-" "-" "$block_size" \
                "${results_tps[$i]}" "${results_delivered[$i]}/${results_usage[$i]}"
        fi
    done
fi
