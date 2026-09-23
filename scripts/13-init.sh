# shellcheck shell=bash
# ─── Module: 13-init ───────────────────────────────────────────────────────
# AI INSTRUCTION: On ANY change to this file, increment the Module Version below.
# TACTICAL_PROFILE_VERSION auto-computes from the sum of all module versions.
# Module Version: 15
# ==============================================================================
# 13. INITIALIZATION
# ==============================================================================
# @modular-section: init
# @depends: constants, design-tokens, openclaw
# @exports: (none — runs startup side-effects only)

# Create required directories
# Only create OpenClaw directories if openclaw CLI is installed AND functional
if [[ "$__TAC_OPENCLAW_OK" == "1" ]]; then
    mkdir -p "$OC_ROOT" "$OC_LOGS" "$OC_BACKUPS"
fi
# Always create LLM directory (independent of OpenClaw)
mkdir -p "$HOME/.llm"

# Check for required dependencies
if ! command -v jq >/dev/null 2>&1
then
    printf '%s\n' "${C_Warning}[Tactical Profile]${C_Reset} Missing: jq (required). Run: sudo apt install -y jq"
fi

# Initialize UI (guard prevents screen-clear on re-source)
# NOTE: Banner display is deferred to tactical-console.bashrc after version
# calculation to ensure the correct TACTICAL_PROFILE_VERSION is shown.
if [[ -z "${__TAC_INITIALIZED:-}" ]]
then
    __TAC_DISPLAY_BANNER=1
    __TAC_INITIALIZED=1
fi

# Load completions safely (only once — guarded with -f check).
# $BASH_COMPLETION_SCRIPT is system/user state, not a file in this repo.
# shellcheck source=/dev/null
[[ -f "$BASH_COMPLETION_SCRIPT" ]] && . "$BASH_COMPLETION_SCRIPT"
# OpenClaw completions — generated file versioned in the repo; regenerate with
# tools/sync-openclaw-completion.sh after `openclaw update`.
[[ -f "$TACTICAL_REPO_ROOT/scripts/completions/openclaw.bash" ]] \
    && source "$TACTICAL_REPO_ROOT/scripts/completions/openclaw.bash"

# Grok CLI — PATH + completions (moved here from ~/.bashrc to keep the
# loader thin; guarded the same way the installer generated it).
if [[ -d "$HOME/.grok/bin" && ":$PATH:" != *":$HOME/.grok/bin:"* ]]
then
    export PATH="$HOME/.grok/bin:$PATH"
fi
[[ -r "$HOME/.grok/completions/bash/grok.bash" ]] && source "$HOME/.grok/completions/bash/grok.bash"

# Homebrew Node@24 — specific Node version (before general Homebrew PATH)
if [[ -d "/home/linuxbrew/.linuxbrew/opt/node@24/bin" ]] \
    && [[ ":$PATH:" != *":/home/linuxbrew/.linuxbrew/opt/node@24/bin:"* ]]
then
    export PATH="/home/linuxbrew/.linuxbrew/opt/node@24/bin:$PATH"
fi

# direnv — auto-load .envrc on directory change (silent: no loading/export messages)
export DIRENV_LOG_FORMAT=""
if command -v direnv >/dev/null 2>&1
then
    eval "$(direnv hook bash)"
    # Belt and suspenders: wrap _direnv_hook to suppress all stderr.
    # DIRENV_LOG_FORMAT="" should work but some direnv versions still leak
    # "direnv: loading …" / "direnv: export …" to stderr.
    if declare -f _direnv_hook >/dev/null 2>&1; then
        eval "_tac_orig_direnv_hook$(declare -f _direnv_hook | sed '1s/^_direnv_hook//')"
        _direnv_hook() { _tac_orig_direnv_hook "$@" 2>/dev/null; }
    fi
fi

# Loopback for WSL Mirrored Networking — CHECKED here, REPAIRED on demand.
# WSL2 mirrored networking mode doesn't create a loopback0 dummy interface, and
# without it OpenClaw's node-to-node communication on 127.0.0.2 fails.
#
# This runs at source time in every interactive shell, so it no longer REPAIRS:
# privileged work does not belong in the startup path (item 2.3.1 of
# docs/inspection.md, re-derived 2026-09-18 — five `sudo` calls used to live here,
# guarded by `sudo -n` so they could never prompt, but still privileged commands in
# a path that every shell executes).  The repair is __tac_fix_loopback below; here
# we only read state and say what is missing.
# Uses 'command ip' to call /usr/bin/ip directly, avoiding any function shadow.
if ! command ip link show loopback0 >/dev/null 2>&1
then
    printf '%s\n' "${C_Warning}[Tactical Profile]${C_Reset}" \
        "loopback0 missing — OpenClaw node-to-node traffic may fail; run 'up' or 'tac-exec __tac_fix_loopback' to create it"
elif ! command ip addr show loopback0 2>/dev/null | grep -q '127\.0\.0\.2/'
then
    # Interface exists but the address is missing (e.g. after a network reset)
    printf '%s\n' "${C_Warning}[Tactical Profile]${C_Reset}" \
        "loopback0 is up but 127.0.0.2/8 is missing — OpenClaw node-to-node traffic may fail; run 'up' or 'tac-exec __tac_fix_loopback'"
fi
# The repair itself (__tac_fix_loopback) lives in scripts/08-maintenance.sh: this
# module is excluded from the library loader, so a definition here would be
# unreachable from `tac-exec`, and privileged work belongs on the maintenance path.
if [[ -f "$OC_WORKSPACE/oc-llm-sync.sh" ]]
then
    _sync_hash=$(sha256sum "$OC_WORKSPACE/oc-llm-sync.sh" 2>/dev/null | cut -d' ' -f1)
    echo "$(date +"%Y-%m-%d %H:%M:%S") [SOURCE] oc-llm-sync.sh" \
        "SHA256=${_sync_hash:-unknown}" >> "$ErrorLogPath" 2>/dev/null
    if [[ -f "$OC_ROOT/oc-llm-sync.sha256" ]]
    then
        _trusted_hash=$(< "$OC_ROOT/oc-llm-sync.sha256")
        if [[ "$_sync_hash" != "$_trusted_hash" ]]
        then
            printf '%s\n' \
                "${C_Warning}[Tactical Profile]${C_Reset}" \
                    "oc-llm-sync.sh hash mismatch — skipped (run 'oc-trust-sync' if update is expected)"
        else
            # stderr suppressed because oc-llm-sync.sh may emit harmless
            # warnings (e.g., unbound variables from older versions), but a
            # failed source is logged and surfaced — the SHA256 entry above
            # records no outcome on its own.
            _sync_src_rc=0
            source "$OC_WORKSPACE/oc-llm-sync.sh" 2>/dev/null || _sync_src_rc=$?
            if (( _sync_src_rc != 0 ))
            then
                printf '%s\n' \
                    "${C_Warning}[Tactical Profile]${C_Reset}" \
                    "oc-llm-sync.sh failed to load (rc=$_sync_src_rc) — continuing"
                echo "$(date +"%Y-%m-%d %H:%M:%S") [SOURCE-FAILED] oc-llm-sync.sh rc=$_sync_src_rc" \
                    >> "$ErrorLogPath" 2>/dev/null
            fi
        fi
    else
        # No trusted hash — refuse to source. Run 'oc-trust-sync' first.
        printf '%s\n' \
            "${C_Warning}[Tactical Profile]${C_Reset}" \
            "oc-llm-sync.sh has no trusted hash — skipped (run 'oc-trust-sync' to establish trust)"
    fi
    # Always clean up hash variables regardless of code path
    unset _sync_hash _trusted_hash _sync_src_rc
fi

# Bridge Windows User API keys into WSL so OpenClaw fallback providers work.
# Cached in /dev/shm for 1 hour; run 'oc-refresh-keys' to force refresh.
# Call the bridge function only if it's defined to avoid noisy errors during
# partial or failed module loads (e.g., during reload).
if type __bridge_windows_api_keys >/dev/null 2>&1; then
    __bridge_windows_api_keys
fi

# Fallback: source the gateway's systemd environment file (on-disk, survives
# reboots) so API keys are available even if the bridge hasn't populated the
# cache yet.
if [[ -f "$HOME/.openclaw/gateway.systemd.env" ]]; then
    set -a; source "$HOME/.openclaw/gateway.systemd.env" 2>/dev/null; set +a
fi

# Auto-activate .venv in the current directory (if present).  The cd()
# override handles activation on directory change, but the initial shell
# open lands in PWD without an implicit cd call.  Source silently so no
# "source .venv/bin/activate" echoes to the terminal.
if [[ -f ".venv/bin/activate" && -z "${VIRTUAL_ENV:-}" ]]; then
    source .venv/bin/activate >/dev/null 2>&1 || true
fi

# Load Hugging Face token from secure file if not already set by bridge
if [[ -z "${HF_TOKEN:-}" && -f "$HOME/.config/huggingface/token" ]]
then
    HF_TOKEN=$(< "$HOME/.config/huggingface/token")
    export HF_TOKEN
fi

# Clean up background telemetry subshells on shell exit.
# Chains with any pre-existing EXIT trap to avoid silently overwriting it.
#
# The dashboard calls the getters through `_telemetry` (07-telemetry.sh), which
# runs them in THIS shell specifically so the `$!` of each background cache
# refresh reaches __TAC_BG_PIDS (a plain `$(...)` would swallow it). The refresh
# jobs are short-lived (1-5s), so by exit the array usually holds PIDs that have
# already finished — harmless, since kill on a dead PID is a no-op. PIDs are
# validated as numeric before signalling (matching env.sh's trap).
__TAC_BG_PIDS=()
function __tac_exit_cleanup() {
    local pid
    for pid in "${__TAC_BG_PIDS[@]:-}"
    do
        [[ "$pid" =~ ^[0-9]+$ ]] || continue
        kill "$pid" 2>/dev/null
    done
}
_tac_prev_exit_trap=$(trap -p EXIT | sed "s/trap -- '//;s/' EXIT//")
trap '__tac_exit_cleanup; '"${_tac_prev_exit_trap:-}" EXIT
unset _tac_prev_exit_trap


# end of file

# end of file marker
