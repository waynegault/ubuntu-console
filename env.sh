#!/usr/bin/env bash
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
# Modules loaded:  01-constants through 12-dashboard-help
# Modules skipped: 13-init (interactive side-effects: clear screen,
#                  completions, WSL loopback, EXIT trap)
#
# Guard:    Idempotent — safe to source multiple times. The design-tokens
#           module and this loader both use guards to prevent re-definition.
# ==============================================================================

# Prevent double-sourcing
[[ -n "${__TAC_ENV_LOADED:-}" ]] && return 0
__TAC_ENV_LOADED=1

# Mark library mode so modules can detect non-interactive sourcing if needed
export TAC_LIBRARY_MODE=1

_tac_env_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_tac_lib_dir="$_tac_env_root/scripts"

for _tac_lib_f in "$_tac_lib_dir"/[0-9][0-9]-*.sh; do
    # Skip 13-init.sh — it runs interactive side-effects (clear, completions,
    # WSL loopback fix, EXIT trap) that are not needed in library mode.
    case "$_tac_lib_f" in
        *13-init.sh) continue ;;
    esac
    [[ -f "$_tac_lib_f" ]] && source "$_tac_lib_f"
done

unset _tac_env_root _tac_lib_f _tac_lib_dir

# end of file
