#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091
# AI INSTRUCTION: On ANY change to this file, increment the Module Version below.
# Module Version: 7
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

# Startup optimizations for faster CLI performance
# NODE_COMPILE_CACHE: Cache compiled JS for repeated CLI runs
export NODE_COMPILE_CACHE="${NODE_COMPILE_CACHE:-/var/tmp/openclaw-compile-cache}"
mkdir -p "$NODE_COMPILE_CACHE" 2>/dev/null || true

# OPENCLAW_NO_RESPAWN: Skip self-respawn overhead
export OPENCLAW_NO_RESPAWN="${OPENCLAW_NO_RESPAWN:-1}"

# LLM autotune context retention guardrail: keep selected ctx at or above a
# fraction of the max stable ctx discovered per model.
export LLM_AUTOTUNE_MIN_CTX_FRACTION="${LLM_AUTOTUNE_MIN_CTX_FRACTION:-0.60}"

_tac_env_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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
