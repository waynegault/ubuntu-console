#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC2034
# AI INSTRUCTION: On ANY change to this file, increment the Module Version below.
# Module Version: 1
# ─── Module: prompt-sets ─────────────────────────────────────────────────────
# Shared SPEC-DEC-006 workload prompt sets — the investigator's real
# workloads: legal-RAG (structured, long, tool-call-shaped prompts with a
# different token distribution than generic chat) and agentic tool-call
# loops, plus the physics/chat burn prompt.  Consumed by
# spec-decode-bench.sh (per-prompt acceptance bench) and autotune-model.sh
# (scoring-payload selection, AUTOTUNE-001) so the two never drift.
# REF: "Speculative Decoding on CPUs — Nearly 4x Faster Token Generation
# with DFlash" (Intel, TDS 2026) — pitfall #7 (domain mismatch): acceptance
# and throughput collapse when the drafter's domain does not match the
# prompt, so scoring must use the workload that matters.
# https://towardsdatascience.com/speculative-decoding-on-cpus-nearly-4x-faster-token-generation-with-dflash/
# Idempotent include guard: modules are sourced both by their thin loader
# and directly by the profile/env loaders, so run the body once.
[[ -n "${__TAC_MOD_PROMPT_SETS_LOADED:-}" ]] && return 0
__TAC_MOD_PROMPT_SETS_LOADED=1

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

# Display names parallel to each prompt array (SPEC-DEC-006 bench table).
PROMPT_NAMES_PHYSICS=("physics: special-relativity burn")
PROMPT_NAMES_LEGAL=(
    "legal: mediation good-faith assessment"
    "legal: constructive dismissal elements"
    "legal: causation vs contribution"
    "legal: burden of proof in discrimination"
    "legal-RAG: statutory interpretation"
)
PROMPT_NAMES_AGENTIC=(
    "agentic: tool-call planning"
    "agentic: multi-step retrieval loop"
    "agentic: ReAct reasoning"
    "agentic: summarise-and-decide"
    "agentic: budget-aware dispatch"
)

# ---------------------------------------------------------------------------
# __resolve_prompt_set — populate PROMPT_NAMES / PROMPTS globals for a set.
# @args <all|physics|chat|legal|agentic|mix>
#   all      — every prompt (bench default)
#   physics  — the classic chat/special-relativity burn prompt
#   chat     — alias for physics (autotune scoring default)
#   legal    — SPEC-DEC-006 legal-RAG set
#   agentic  — SPEC-DEC-006 agentic tool-call set
#   mix      — interpolation across all three sets (autotune scoring)
# @sets PROMPT_NAMES, PROMPTS
# @returns 0 on a known set, 1 otherwise (globals left untouched).
# ---------------------------------------------------------------------------
function __resolve_prompt_set() {
    local _set="${1:-all}"
    case "$_set" in
        all|mix)
            PROMPT_NAMES=("${PROMPT_NAMES_PHYSICS[@]}" "${PROMPT_NAMES_LEGAL[@]}" "${PROMPT_NAMES_AGENTIC[@]}")
            PROMPTS=("${PROMPTS_PHYSICS[@]}" "${PROMPTS_LEGAL[@]}" "${PROMPTS_AGENTIC[@]}")
            ;;
        physics|chat)
            PROMPT_NAMES=("${PROMPT_NAMES_PHYSICS[@]}")
            PROMPTS=("${PROMPTS_PHYSICS[@]}")
            ;;
        legal)
            PROMPT_NAMES=("${PROMPT_NAMES_LEGAL[@]}")
            PROMPTS=("${PROMPTS_LEGAL[@]}")
            ;;
        agentic)
            PROMPT_NAMES=("${PROMPT_NAMES_AGENTIC[@]}")
            PROMPTS=("${PROMPTS_AGENTIC[@]}")
            ;;
        *)
            return 1
            ;;
    esac
    return 0
}
