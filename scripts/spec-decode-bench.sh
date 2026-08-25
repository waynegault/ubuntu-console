#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2034
# AI INSTRUCTION: On ANY change to this file, increment the Module Version below.
# Module Version: 1
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
# REF: DFlash TDS article, pitfall #7 (domain mismatch).

PROMPTS_PHYSICS=(
    "Explain the complete theory of special relativity in extreme detail, including the mathematical derivations for time dilation."
)

PROMPTS_LEGAL=(
    "Analyse whether the employer engaged with the mediation process in good faith, attending the scheduled mediation meeting and responding substantively to Alex Morgan's formal mediation request, which set out four reasonable expectations consistent with the National Health Services Workforce Governance Standard. Cite the passages that support your verdict."
    "Does the respondent have a prima facie case for constructive dismissal? Consider the implied term of mutual trust and confidence, the final straw doctrine, and whether the employee resigned in response to a repudiatory breach. Assess each element against the evidence and state which allegations are VALIDATED, CONTRADICTED, or UNVERIFIED."
    "The tribunal found the employer's failure to make reasonable adjustments caused the claimant's detriment, but the employer argues the claimant's own delay contributed 40%. Weigh the causation evidence against the contributory-conduct evidence and determine the appropriate reduction, citing the relevant case law on apportionment."
    "In this indirect discrimination claim the burden shifts once a prima facie case is established. Assess whether the PCP (presence requirement) put the claimant at a particular disadvantage, whether the employer's justification evidence meets the proportionality test, and who bears the evidential burden at each stage."
    "Section 111 of the Employment Rights Act 1996 provides that a complaint of unfair dismissal must be presented within three months. Interpret 'such other period as the tribunal considers reasonable' in the context of the ACAS early-conciliation extension, and explain how the time limit is calculated when conciliation certificates are involved."
)

PROMPTS_AGENTIC=(
    "You have tools: search_corpus(query), fetch_document(id), summarize(text). Plan the minimal sequence of tool calls to determine whether the workplace policy on annual leave was amended between March and September 2023. Return a JSON array of tool calls with arguments."
    "You are investigating whether a respondent fabricated meeting minutes. Step 1: search the corpus for 'meeting minutes March 2023'. Step 2: fetch the top result and extract the attendees. Step 3: cross-reference the attendees against the HR system export. Step 4: decide whether the minutes are consistent with the export and output a structured finding."
    "Answer the question: was the disciplinary hearing held within a reasonable time after the alleged misconduct? Use the ReAct pattern: first think about what evidence you need, then call search_corpus('disciplinary hearing date'), then reason about the gap between the incident date (12 March) and the hearing date you found, then conclude."
    "A witness statement claims the claimant was 'pressured to resign'. Retrieve the full statement, identify the three passages that support or contradict the pressure claim, and produce a verdict for the allegation '[FACT] The claimant was pressured to resign' with a confidence score."
    "You have a 200-token output budget. Given the retrieved chunk pool on the 'reasonable adjustments' claim, select the three most decision-relevant chunks, then answer whether the employer's step-down of the claimant's duties constituted a reasonable adjustment. Do not exceed the budget."
)

case "$PROMPT_SET" in
    all)      PROMPT_NAMES=("physics: special-relativity burn" "legal: mediation good-faith assessment" "legal: constructive dismissal elements" "legal: causation vs contribution" "legal: burden of proof in discrimination" "legal-RAG: statutory interpretation" "agentic: tool-call planning" "agentic: multi-step retrieval loop" "agentic: ReAct reasoning" "agentic: summarise-and-decide" "agentic: budget-aware dispatch")
              PROMPTS=("${PROMPTS_PHYSICS[@]}" "${PROMPTS_LEGAL[@]}" "${PROMPTS_AGENTIC[@]}") ;;
    physics)  PROMPT_NAMES=("physics: special-relativity burn")
              PROMPTS=("${PROMPTS_PHYSICS[@]}") ;;
    legal)    PROMPT_NAMES=("legal: mediation good-faith assessment" "legal: constructive dismissal elements" "legal: causation vs contribution" "legal: burden of proof in discrimination" "legal-RAG: statutory interpretation")
              PROMPTS=("${PROMPTS_LEGAL[@]}") ;;
    agentic)  PROMPT_NAMES=("agentic: tool-call planning" "agentic: multi-step retrieval loop" "agentic: ReAct reasoning" "agentic: summarise-and-decide" "agentic: budget-aware dispatch")
              PROMPTS=("${PROMPTS_AGENTIC[@]}") ;;
    *) echo "Unknown --set '$PROMPT_SET' (all|physics|legal|agentic)" >&2; exit 1 ;;
esac

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
