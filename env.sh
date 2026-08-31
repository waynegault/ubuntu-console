#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091
# AI INSTRUCTION: On ANY change to this file, increment the Module Version below.
# Module Version: 11
# ==============================================================================
# env.sh — Tactical Console Library Loader (Non-Interactive)
# ==============================================================================
# Purpose:  Source all function-defining modules so that bash functions
#           (oc, so, xo, model, serve, etc.) are available in non-interactive
#           contexts: MCP tool scripts, AI exec environments, cron jobs.
#
# Usage:    source ~/ubuntu-console/env.sh
#     or:   ~/ubuntu-console/bin/tac-exec <command> [args...]
#
# Modules loaded:  01-constants through 15-model-recommender (including 09b-gog)
# Standalone executables under scripts/ (for example 18-lint) are skipped.
# Modules skipped: 13-init (interactive side-effects: clear screen,
#                  completions, WSL loopback, EXIT trap)
#                  Utility scripts (tools/) are not in scripts/ so are never
#                  picked up by the glob — no explicit exclusions needed.
#
# SC1090/SC1091: Dynamic sourcing by design — modules discovered at runtime
#
# AI INSTRUCTION: Keep this file in sync with tactical-console.bashrc's module
# sourcing loop. When modules are added or removed from scripts/, update the
# skip list below. This file must never contain interactive side-effects
# (clear screen, prompt changes, completions, EXIT trap, WSL loopback).
# ==============================================================================

# Prevent double-sourcing
[[ -n "${__TAC_ENV_LOADED:-}" ]] && return 0
__TAC_ENV_LOADED=1

# Signal to functions/hooks that we are running in library (non-interactive)
# mode.  Functions that would normally take interactive actions (clear screen,
# set PS1, register completions) can check this variable to skip them.
export TAC_LIBRARY_MODE=1

# Startup optimizations (NODE_COMPILE_CACHE / OPENCLAW_NO_RESPAWN / NODE_OPTIONS).
# Shared fragment — single source of truth, also sourced by tactical-console.bashrc.
_tac_env_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1090
source "$_tac_env_root/scripts/_startup-env.sh"

# Minimum acceptable generation speed (tokens/second), uniform for every model.
# Autotune seeks the highest ctx that sustains this TPS; a model that cannot
# reach it even at minimum ctx is recorded as too slow for our purposes.
# 10 TPS keeps up with agentic/interactive flows while preserving enough ctx
# for accuracy on context-heavy flows (a higher floor would starve ctx on the
# 3-4B models that are the sweet spot for this 4GB GPU).
export LLM_MIN_TPS="${LLM_MIN_TPS:-10}"

# ── Autotune v4 knobs (scripts/autotune-model.sh) ────────────────────────────
# The TPS floor is certified at a *filled* KV cache: the scoring bench pre-fills
# the context with a long prompt (ratio x ctx, capped) before measuring decode,
# so the recorded TPS reflects sustained throughput at the ctx being certified,
# not a burst on an empty cache. Prefill tokens/sec is captured from the server
# timings and persisted in the registry (field 21).
#
# FILL_MAX_TOKENS caps that pre-fill. 16384 was chosen (was 32768) to halve the
# wall time of Phase-4 descent benches at huge ctx, where the KV cache spills
# into host RAM and prefill crawls (~50 tok/s => 11 min/bench at 32K). The
# tradeoff: at recorded ctx above ~22K the certification runs with less cache
# pressure, so descents stop slightly higher and the floor check is a bit
# looser. On a 4 GB card that is the right balance for a full-fleet overnight
# sweep.
export LLM_AUTOTUNE_FILL_RATIO="${LLM_AUTOTUNE_FILL_RATIO:-0.75}"
export LLM_AUTOTUNE_FILL_MAX_TOKENS="${LLM_AUTOTUNE_FILL_MAX_TOKENS:-16384}"
export LLM_AUTOTUNE_FILL_MIN_TOKENS="${LLM_AUTOTUNE_FILL_MIN_TOKENS:-2048}"

# Prefill floor (tokens/sec), enabled by default. A model whose prompt
# ingestion is too slow for long-context use is treated like a below-floor
# model — Phase 4 descends ctx until prefill meets this floor too.
# HARNESS-PREFILL-001 (2026-08-31): the bench's phase-4 main-generation
# prompt is ~14K tokens; with the 65536 certified ctx on a 4 GB card the KV
# cache spills to host RAM and prefill crawls below ~50 tok/s — >5 min to
# the first token, which killed every case with FirstTokenTimeout.  The
# decode TPS floor alone certified these configs because it measures a
# short decode, not the prefill.  Default 50 tok/s (~4.7 min for a 14K
# prompt) keeps the certified ctx usable end-to-end; set 0 to disable.
export LLM_MIN_PREFILL_TPS="${LLM_MIN_PREFILL_TPS:-50}"

# Batch/ubatch beam search at the winning ctx (replaces the fixed ubatch list).
export LLM_AUTOTUNE_BEAM_WIDTH="${LLM_AUTOTUNE_BEAM_WIDTH:-2}"
export LLM_AUTOTUNE_BEAM_ROUNDS="${LLM_AUTOTUNE_BEAM_ROUNDS:-2}"

# n_gpu_layers / KV-quant search band: models whose GGUF is at least this
# fraction of free VRAM are probed with alternate offload counts and cache
# quantizations (partial offload can beat pure CPU on borderline models).
export LLM_AUTOTUNE_NGL_BAND_FRAC="${LLM_AUTOTUNE_NGL_BAND_FRAC:-0.55}"
export LLM_AUTOTUNE_KV_QUANTS="${LLM_AUTOTUNE_KV_QUANTS:-q8_0/q8_0 q4_0/q4_0}"

# Cap on a single scoring bench's wall time (filled-cache prefill is slow on
# CPU-only models).
export LLM_AUTOTUNE_BENCH_TIMEOUT="${LLM_AUTOTUNE_BENCH_TIMEOUT:-300}"

# AUTOTUNE-001: scoring workload for autotune-model.sh (chat|legal|agentic|
# mix).  The ctx/batch/TPS winner and the sustained-TPS floor are certified
# against the payload of THIS workload's SPEC-DEC-006 prompt set — the
# investigator-relevant profile sets this to "legal" (legal-RAG); the chat
# default is unchanged for generic use.  Recorded per-model in the registry
# (column 33).
export LLM_AUTOTUNE_WORKLOAD="${LLM_AUTOTUNE_WORKLOAD:-chat}"

# ── Speculative decoding (SPEC-DEC-001..006) ────────────────────────────────
# Speculative decoding trades spare CPU compute for saved memory bandwidth and
# is LOSSLESS (rejection sampling recovers the target distribution exactly) —
# preferred over lossy quantization for quality-critical paths (legal
# evidence).  It is a net LOSS once concurrency consumes the spare compute
# (DFlash article pitfall #1); the SPEC-DEC-005 policy is: ON for
# low-concurrency latency-bound paths (agentic loops, interactive), OFF under
# concurrent load.  The knobs below mirror the per-model registry fields
# (schema v5, columns 27-32) which `model use` and autotune read.
#
# LLM_SPEC_DRAFT_ENABLED: 0 disables ALL speculative-decoding flags at launch
# (per-server knob; restart the model after flipping).
export LLM_SPEC_DRAFT_ENABLED="${LLM_SPEC_DRAFT_ENABLED:-1}"
# LLM_SPEC_TYPE: "ngram" = VRAM-free ngram spec-decode (no extra model — the
# natural first step on the 4 GB card); empty = draft-model spec-decode when
# LLM_SPEC_DRAFT_MODEL is set.
export LLM_SPEC_TYPE="${LLM_SPEC_TYPE:-}"
# LLM_SPEC_DRAFT_MODEL: draft GGUF path.  A draft model must NEVER steal VRAM
# from the target on the 4 GB RTX 3050 Ti — the default placement is CPU-only
# (--spec-draft-device none); set LLM_SPEC_DRAFT_NGL>0 or LLM_SPEC_DRAFT_DEVICE
# to override explicitly.
export LLM_SPEC_DRAFT_MODEL="${LLM_SPEC_DRAFT_MODEL:-}"
# LLM_SPEC_DRAFT_N_MAX: block size (num_speculative_tokens).  Autotune sweeps
# this (LLM_AUTOTUNE_SPEC_N_MAX_LIST) and records the winner per model.
export LLM_SPEC_DRAFT_N_MAX="${LLM_SPEC_DRAFT_N_MAX:-}"
export LLM_SPEC_DRAFT_NGL="${LLM_SPEC_DRAFT_NGL:-0}"
export LLM_SPEC_DRAFT_DEVICE="${LLM_SPEC_DRAFT_DEVICE:-}"
# Autotune block-size sweep candidates (SPEC-DEC-004).
export LLM_AUTOTUNE_SPEC_N_MAX_LIST="${LLM_AUTOTUNE_SPEC_N_MAX_LIST:-4 8 16 32}"
#
# REF: "Speculative Decoding on CPUs — Nearly 4x Faster Token Generation with
# DFlash" (Intel, TDS 2026)
# https://towardsdatascience.com/speculative-decoding-on-cpus-nearly-4x-faster-token-generation-with-dflash/

_tac_lib_dir="$_tac_env_root/scripts"

for _tac_lib_f in "$_tac_lib_dir"/[0-9][0-9]-*.sh "$_tac_lib_dir"/[0-9][0-9][a-z]-*.sh; do
    # Skip 13-init.sh — it runs interactive side-effects (clear, completions,
    # WSL loopback fix, trusted sync loader, and UI traps) not needed in library mode.
    # Utility scripts under tools/ are not matched by this glob.
    case "$_tac_lib_f" in
        *18-lint.sh) continue ;;
        *13-init.sh) continue ;;
        *) ;;  # all other modules loaded normally
    esac
    if [[ -f "$_tac_lib_f" ]]
    then
        if ! source "$_tac_lib_f"
        then
            echo "[tac-env] failed sourcing module: $_tac_lib_f" >&2
            return 1
        fi
    fi
done

# Sub-modules with non-numeric prefixes are matched by the glob above
# (e.g. 11a-llm-registry.sh).  Only truly numeric-module names need
# explicit sourcing: 09b-gog.sh is kept here for backward compat.

# 09b-gog.sh is handled by the [0-9][0-9][a-z]-*.sh glob above.
# if [[ -f "$_tac_lib_dir/09b-gog.sh" ]]
# then
#     if ! source "$_tac_lib_dir/09b-gog.sh"
#     then
#         echo "[tac-env] failed sourcing module: $_tac_lib_dir/09b-gog.sh" >&2
#         return 1
#     fi
# fi

# Library mode skips 13-init, but core helpers still expect the OpenClaw
# state directories to exist for cooldown and error-log writes.
mkdir -p "$OC_ROOT" "$OC_LOGS" "$OC_BACKUPS" 2>/dev/null || true

# Initialize background PID array required by telemetry functions.
# In interactive mode, this is set by 13-init.sh; in library mode (non-interactive),
# 13-init.sh is skipped so we must initialize it here.
__TAC_BG_PIDS=()

# Library mode skips 13-init.sh, so install a lightweight cleanup trap here.
function __tac_env_cleanup_bg_pids() {
    local _pid
    for _pid in "${__TAC_BG_PIDS[@]:-}"
    do
        [[ "$_pid" =~ ^[0-9]+$ ]] || continue
        kill "$_pid" 2>/dev/null || true
    done
}
trap __tac_env_cleanup_bg_pids EXIT

unset _tac_env_root _tac_lib_f _tac_lib_dir

# end of file
