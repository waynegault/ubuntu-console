# shellcheck shell=bash
# shellcheck disable=SC2034,SC2059,SC2120,SC2154
# ─── Module: 11-llm-manager ───────────────────────────────────────────────────────
# AI INSTRUCTION: On ANY change to this file, increment the Module Version below.
# TACTICAL_PROFILE_VERSION auto-computes from the sum of all module versions.
# Module Version: 96
# ==============================================================================
# 11. LLM MODEL MANAGER & OPENCLAW INTEROP (THIN LOADER)
# ==============================================================================
# This module has been split into sub-modules for maintainability.  This file
# is kept as a thin loader that sources each sub-module in dependency order.
#
# @modular-section: llm-manager
# @depends: constants, design-tokens, ui-engine, hooks
# @exports: wake, model, serve, halt, mlogs, burn, explain, wtf_repl,
#   __llm_sse_core, __llm_stream, __llm_chat_send, local_chat, chat-context,
#   __gguf_metadata, __calc_gpu_layers, __calc_ctx_size, __calc_threads,
#   __quant_label, __require_llm
# @state-out: LAST_TPS, __LAST_LLM_RESPONSE, ACTIVE_LLM_FILE
# @state-in: __LLAMA_DRIVE_MOUNTED (§1), C_* design tokens (§4)
# ---------------------------------------------------------------------------

# Fallback for __LLAMA_DRIVE_MOUNTED if module load order changes or §1 is skipped.
: "${__LLAMA_DRIVE_MOUNTED:=0}"

# ── Source sub-modules in dependency order ──────────────────────────────
_MOD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

for _11_mod in \
    11a-llm-registry \
    11b-llm-autotune \
    11c-llm-server \
    11d-llm-gpu \
    11e-llm-model \
    11f-llm-runtime
do
    _11_f="$_MOD_DIR/${_11_mod}.sh"
    if [[ -f "$_11_f" ]]; then
        # shellcheck disable=SC1090
        source "$_11_f"
    fi
done
unset _MOD_DIR _11_mod _11_f
# end of file
