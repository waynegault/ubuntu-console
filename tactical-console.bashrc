# shellcheck shell=bash
# ==============================================================================
# ~/.bashrc
# ==============================================================================
# Purpose:        Tactical Console Profile (Interactive shell configuration)
# Author:         Wayne
# Last modified:  2026-08-06
# Environment:    WSL2 (Ubuntu 24.04) / RTX 3050 Ti
#
# Prerequisites:  bash >= 5.2
#                 Required tools: git; Optional tools: fzf
#
# Safety:         Do NOT store secrets or credentials in this file.
#                 Do NOT auto-execute remote scripts (curl | bash, wget | sh).
#                 Avoid privileged operations (sudo, chown, chmod 777) at startup.
#
# Loader:         This file is the CANONICAL source of truth and is versioned at:
#                   ~/ubuntu-console/tactical-console.bashrc
#                 ~/.bashrc must remain a THIN LOADER that only sources this file:
#                   source "$HOME/ubuntu-console/tactical-console.bashrc"
#                 Modular sections live under:
#                   ~/ubuntu-console/scripts/[01-15]-*.sh + 09b-gog.sh
#                   (load order: scripts/_module-list.sh, shared with env.sh)
#
# HELP INDEX:     See the HELP INDEX section below for functions, aliases, and
#                 sections with one-line descriptions and usage notes.
#
# SYNOPSIS:       Tactical Console Profile (Bash)
#                 Admin: Wayne | Environment: WSL2 (Ubuntu 24.04)
#
# FILE LAYOUT:    - Keep ~/.bashrc as a thin loader only.
#                 - This file sources the module list in scripts/_module-list.sh (never a glob).
#                 - Use the 'reload' alias to re-source the loader.
#                 - Use the 'oedit' alias to open the canonical file in VS Code.
#
# NOTES:          - Prefer longhand, explicit bash constructs for readability
#                   and future conversion to PowerShell.
#                 - Guard interactive-only code with an interactive-shell check.
#                 - Heavy or networked tasks must be lazy-loaded or moved to
#                   explicit scripts or systemd user units.
#
# ==============================================================================
# SHELLCHECK DIRECTIVES
# ==============================================================================
# SC1090: Non-constant source paths — dynamic sourcing is by design.
# SC1091: External files not available for static analysis — expected.
# shellcheck disable=SC1090,SC1091

# ==============================================================================
# INTERACTIVE GUARD
# ==============================================================================
# Prevent execution in non-interactive shells (like sftp/rsync)
case $- in
    *i*) ;;
      *) return ;;
esac

# ==============================================================================
#  0. MANDATORY INSTRUCTIONS FOR AI EDITORS
# ==============================================================================
# @modular-section: ai-instructions
# @depends: none
# @exports: TACTICAL_PROFILE_VERSION
#
# AI INSTRUCTION: Increment version on significant changes.
# When the LOADER itself changes, bump _TAC_LOADER_VERSION below.
# When a MODULE in scripts/ changes, bump its '# Module Version: N' comment.
# Never place feature logic in ~/.bashrc; keep ~/.bashrc as thin loader only.
# TACTICAL_PROFILE_VERSION is auto-computed after sourcing all modules:
#   TACTICAL_PROFILE_VERSION = _TAC_LOADER_VERSION . sum(all module versions)
#   Example: v3.63 = loader v3 + 63 total module versions
_TAC_LOADER_VERSION="9"

# AI INSTRUCTION: Follow these terminal formatting rules strictly:
# 1. A blank line must exist between the bottom of any UI border and the command prompt.
# 2. A blank line must exist between prompt lines if there is no output (e.g., hitting Enter).
# 3. If there is command output, a blank line must exist AFTER the output, before the next prompt.
# 4. Do not cut off rendering code before the comment '# end of file' is reached.
#    Never remove the comment '# end of file'. When creating a file, always ensure
#    there is a comment, 'end of file' unless the file format does not permit
#    comments (eg JSON).
#
# IMPLEMENTATION NOTE:
# - PS1 starts with "\n" — this produces exactly one blank line between any prompt pair,
#   whether the previous command had output or not. PS0 is intentionally unset.
# - DO NOT add manual `echo ""` to the end of UI functions, as PS1 natively handles the gap.
# - DO NOT set PS0 — it would add a second blank line for commands with no output.
#
# NAMING CONVENTION:
# - User-facing commands: kebab-case (oc-health, get-ip, oc-backup)
# - Internal helpers / UI primitives: __double_underscore prefix (__tac_header, __get_host_metrics)
# - Short tactical aliases: lowercase abbreviations (so, xo, cl, up, m, h)
# - NEVER use PascalCase or CamelCase for function names.
#
# DEPENDENCY NOTE:
# - jq is REQUIRED for JSON parsing and SSE stream parsing throughout this profile.
# - curl is REQUIRED for all LLM API calls (streaming and non-streaming).
# - python3 is NOT required. All LLM functions are pure bash + curl + jq.

# ==============================================================================
# ARCHITECTURE MAP
# ==============================================================================
# Modules are sourced from ~/ubuntu-console/scripts/ in numeric order.
# Each module has @modular-section, @depends, and @exports annotations.
#
# -  01-constants.sh       - All paths, ports, env vars (single truth)
# -  02-error-handling.sh   - Bash ERR trap -> bash-errors.log
# -  03-design-tokens.sh    - ANSI color constants (readonly)
# -  04-aliases.sh          - Short commands, VS Code wrappers
# -  05-ui-engine.sh        - Box-drawing primitives (__tac_* family)
# -  06-hooks.sh            - cd override, prompt (PS1), port test
# -  07-telemetry.sh        - CPU, GPU, battery, git, disk, tokens
# -  08-maintenance.sh      - get-ip, up, cl, cpwd, sysinfo, logtrim
# -  09-openclaw.sh         - Gateway, backup, cron, skills, plugins
# -  09b-gog.sh             - Google CLI (gog) detection and helpers
# -  10-deployment.sh       - mkproj scaffold, git commit+push
# -  11-llm-manager.sh      - model mgmt, chat, burn, explain
# -  12-dashboard-help.sh   - Tactical Dashboard ('m') and Help ('h')
# -  13-init.sh             - mkdir, completions, WSL loopback fix
# -  14-wsl-extras.sh       - WSL/X11 startup helpers
# -  15-model-recommender.sh - AI model recommendations by use case
#
# CROSS-CUTTING STATE:
# - LAST_TPS: written by burn/llm_stream (§11) → read by dashboard (§12) via LLM_TPS_CACHE
# - __LAST_LLM_RESPONSE: written by __llm_chat_send (§11) → read by local_chat (§11)
# - ACTIVE_LLM_FILE: written by model start (§11) → read by oc-local-llm (§9), dashboard (§12)
# - __resolve_vscode_bin: defined in constants (§1) → called by aliases (§3)
# - _TAC_ADMIN_BADGE: set in hooks (§6) → read by custom_prompt_command (§6)
# - CooldownDB: defined in constants (§1) → read/written by maintenance (§8)
# - __TAC_HAS_BATTERY: set in constants (§1) → read by __get_battery (§7)
# - VSCODE_BIN: lazy-init by __resolve_vscode_bin (§1) → used by aliases (§3)
# - __TAC_INITIALIZED: set by init (§13) → guards re-source idempotency
# - __LLAMA_DRIVE_MOUNTED: set in constants (§1) → read by model scan/download (§11)
# ==============================================================================

# ==============================================================================
# SOURCE MODULES
# ==============================================================================
# The module list lives in scripts/_module-list.sh (shared with env.sh) so the
# interactive and library loaders can never drift. Order enforces the
# dependency chain declared in each module's @depends annotation: design-tokens
# (03) loads before aliases (04) so hooks (06) can read C_* variables at source
# time when setting _TAC_ADMIN_BADGE.

_tac_repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export TACTICAL_REPO_ROOT="${TACTICAL_REPO_ROOT:-$_tac_repo_root}"
_tac_module_dir="$TACTICAL_REPO_ROOT/scripts"

# Shared startup environment (NODE_COMPILE_CACHE / OPENCLAW_NO_RESPAWN /
# NODE_OPTIONS) plus the __tac_source_submodules helper the thin loaders
# (09-openclaw, 11-llm-manager) use — must load BEFORE the module loop.
source "$_tac_repo_root/scripts/_startup-env.sh"

# Canonical module list, shared with env.sh (the library loader) so the two
# module sets can never drift. Each thin loader (09-openclaw, 11-llm-manager)
# sources its own sub-modules. Losing the list would silently disable every
# function below, so report it loudly.
if ! source "$_tac_module_dir/_module-list.sh"
then
    printf '%s\n' "${C_Warning:-}[Tactical Profile]${C_Reset:-}" \
        "cannot load the shared module list: $_tac_module_dir/_module-list.sh" >&2
fi
mapfile -t _tac_expected_modules < <(__tac_module_list 2>/dev/null)

# Source modules (timed when DEBUG_TAC_STARTUP is set) and accumulate
# module versions from their "# Module Version: N" comment.
_tac_mod_sum=0
_tac_found_count=0
_tac_version_files=()
for _tac_mod in "${_tac_expected_modules[@]}"; do
    _tac_f="$_tac_module_dir/${_tac_mod}.sh"
    if [[ -f "$_tac_f" ]]; then
        ((_tac_found_count++))
        _tac_version_files+=("$_tac_f")
        if [[ -n "${DEBUG_TAC_STARTUP:-}" ]]; then
            printf 'Sourcing %s ... ' "$_tac_f" >&2
            _tac_start_ns=$(date +%s%N 2>/dev/null || echo 0)
            source "$_tac_f"
            _tac_end_ns=$(date +%s%N 2>/dev/null || echo 0)
            if [[ "$_tac_start_ns" != "0" && "$_tac_end_ns" != "0" ]]; then
                _tac_ms=$(( (_tac_end_ns - _tac_start_ns) / 1000000 ))
                printf 'done (%d ms)\n' "$_tac_ms" >&2
            else
                printf 'done\n' >&2
            fi
            unset _tac_start_ns _tac_end_ns _tac_ms
        else
            source "$_tac_f"
        fi
    fi
done
unset _tac_mod

# Sum module versions in a single grep pass (order-independent) instead of
# forking awk once per module — saves ~80 ms on every shell start.
if (( ${#_tac_version_files[@]} > 0 ))
then
    while IFS= read -r _tac_line
    do
        _tac_mv="${_tac_line##* }"
        [[ "$_tac_mv" =~ ^[0-9]+$ ]] && (( _tac_mod_sum += _tac_mv ))
    done < <(grep -h '^# Module Version:' "${_tac_version_files[@]}" 2>/dev/null)
fi

# Warn if expected modules are missing (incomplete profile load)
if (( _tac_found_count < ${#_tac_expected_modules[@]} ))
then
    printf '%s\n' "${C_Warning:-}[Tactical Profile]${C_Reset:-}" \
        "Expected ${#_tac_expected_modules[@]} modules, found $_tac_found_count" >&2
    printf '%s\n' "  ${C_Dim:-}Some modules may be missing — check ~/ubuntu-console/scripts/${C_Reset:-}" >&2
fi

export TACTICAL_PROFILE_VERSION="${_TAC_LOADER_VERSION}.${_tac_mod_sum}"

# ==============================================================================
#  Gateway Auth Tokens
# ==============================================================================
# Credentials are NOT stored here. Set OPENCLAW_TOKEN, OPENCLAW_PASSWORD, and
# OPENCLAW_GATEWAY_PASSWORD in ~/.openclaw/secrets.env (chmod 600, not tracked
# by git). This file is sourced below if it exists.
if [[ -f "$HOME/.openclaw/secrets.env" ]]; then
    source "$HOME/.openclaw/secrets.env"
fi

# systemd user-environment drop-in (~/.config/environment.d/90-openclaw.conf).
# This is NOT the Windows-bridged store, and NOT refreshed by `oc-refresh-keys`
# (that refreshes /dev/shm/tac_win_api_keys): systemd imports this file into the
# user manager at start, and 21 of its ~30 keys have no other source, so it is
# their sole provider -- do not delete it. Source it as well so env-backed
# gateway SecretRefs (OPENCLAW_GATEWAY_PASSWORD/OPENCLAW_GATEWAY_TOKEN) resolve
# for CLI commands even when the /dev/shm bridge cache is stale or pwsh is
# unavailable at shell start.
if [[ -f "$HOME/.config/environment.d/90-openclaw.conf" ]]; then
    set -a
    source "$HOME/.config/environment.d/90-openclaw.conf"
    set +a
fi

# ==============================================================================
#  Startup Optimizations (faster CLI performance)
# ==============================================================================
# _startup-env.sh is sourced above, before the module loop (the thin loaders
# need __tac_source_submodules); see the "Shared startup environment" block.

unset _tac_f _tac_module_dir _tac_mod_sum _tac_mv _tac_line _tac_version_files _tac_repo_root _tac_expected_modules _tac_found_count

# Display the initial banner now that TACTICAL_PROFILE_VERSION is set.
# This ensures the correct version is shown on first terminal open.
if [[ -n "${__TAC_DISPLAY_BANNER:-}" ]]; then
    clear_tactical
    unset __TAC_DISPLAY_BANNER
fi

# end of file
