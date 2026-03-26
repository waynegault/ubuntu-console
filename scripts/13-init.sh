# shellcheck shell=bash
# shellcheck disable=SC1090,SC1091,SC2034,SC2154
# ─── Module: 13-init ───────────────────────────────────────────────────────
# AI INSTRUCTION: On ANY change to this file, increment the Module Version below.
# TACTICAL_PROFILE_VERSION auto-computes from the sum of all module versions.
# Module Version: 1
# ==============================================================================
# 13. INITIALIZATION
# ==============================================================================
# @modular-section: init
# @depends: all sections above
# @exports: (none — runs startup side-effects only)

# Create required directories
# Only create OpenClaw directories if openclaw CLI is installed AND functional
if [[ "$__TAC_OPENCLAW_OK" == "1" ]]; then
    mkdir -p "$OC_ROOT" "$OC_LOGS" "$OC_BACKUPS"
fi
# Always create LLM directory (independent of OpenClaw)
mkdir -p "$LLAMA_DRIVE_ROOT/.llm"

# Check for required dependencies
if ! command -v jq >/dev/null 2>&1
then
    printf '%s\n' "${C_Warning}[Tactical Profile]${C_Reset} Missing: jq (required). Run: sudo apt install -y jq"
fi

# Initialize UI (guard prevents screen-clear on re-source)
if [[ -z "${__TAC_INITIALIZED:-}" ]]
then
    clear_tactical
    __TAC_INITIALIZED=1
fi

# Load completions safely (only once — guarded with -f check)
[[ -f "$BASH_COMPLETION_SCRIPT" ]] && . "$BASH_COMPLETION_SCRIPT"
[[ -f "$OC_ROOT/completions/openclaw.bash" ]] && source "$OC_ROOT/completions/openclaw.bash"

# Fix Loopback for WSL Mirrored Networking (Idempotent & Pulse-Free).
# WSL2 mirrored networking mode doesn't create a loopback0 dummy interface.
# Without it, OpenClaw's node-to-node communication on 127.0.0.2 fails.
# Uses 'command ip' to call /usr/bin/ip directly, avoiding any function shadow.
# Checks both interface existence AND the specific address to be truly idempotent.
if ! command ip link show loopback0 >/dev/null 2>&1
then
    if sudo -n true 2>/dev/null
    then
        sudo ip link add loopback0 type dummy 2>/dev/null
        sudo ip link set loopback0 up 2>/dev/null
        sudo ip addr add 127.0.0.2/8 dev loopback0 2>/dev/null
    fi
elif ! command ip addr show loopback0 2>/dev/null | grep -q '127\.0\.0\.2/'
then
    # Interface exists but address is missing (e.g., after network reset)
    if sudo -n true 2>/dev/null
    then
        sudo ip addr add 127.0.0.2/8 dev loopback0 2>/dev/null
    fi
fi

# OpenClaw LLM sync function (added by Hal).
# Vault mechanism: This sources oc-llm-sync.sh, which registers OC's LLM
# providers (API keys, endpoints) from a credential store into the current
# session. The file is verified against a trusted SHA-256 hash before
# sourcing — if the hash doesn't match (tampered/updated), it's skipped
# with a warning and the shell continues to load without LLM sync.
#
# SECURITY NOTE: The trusted hash ($OC_ROOT/oc-llm-sync.sha256) should be
# created by a trusted administrator and have restricted permissions (chmod 400).
# If an attacker can write to both $OC_WORKSPACE and $OC_ROOT, they could
# replace both the script and hash. For stronger security:
#   - Store the trusted hash in a read-only location
#   - Use GPG signatures instead of SHA-256
#   - Run 'oc-trust-sync' after any verified update to refresh the hash
#
# NOTE: This silently sources an external script. If the file is compromised,
# it executes in the interactive shell. Hash is verified against a trusted
# reference file and logged for auditability.
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
            # C7: stderr suppressed because oc-llm-sync.sh may emit harmless
            # warnings (e.g., unbound variables from older versions). The || true
            # prevents a failing sync from aborting shell init. Errors are still
            # logged above via the SHA256 entry in bash-errors.log.
            source "$OC_WORKSPACE/oc-llm-sync.sh" 2>/dev/null || true
        fi
    else
        # No trusted hash — refuse to source. Run 'oc-trust-sync' first.
        printf '%s\n' \
            "${C_Warning}[Tactical Profile]${C_Reset}" \
            "oc-llm-sync.sh has no trusted hash — skipped (run 'oc-trust-sync' to establish trust)"
    fi
    # Always clean up hash variables regardless of code path
    unset _sync_hash _trusted_hash
fi

# Bridge Windows User API keys into WSL so OpenClaw fallback providers work.
# Cached in /dev/shm for 1 hour; run 'oc-refresh-keys' to force refresh.
# Call the bridge function only if it's defined to avoid noisy errors during
# partial or failed module loads (e.g., during reload).
if type __bridge_windows_api_keys >/dev/null 2>&1; then
    __bridge_windows_api_keys
fi

# Load Hugging Face token from secure file if not already set by bridge
if [[ -z "${HF_TOKEN:-}" && -f "$HOME/.config/huggingface/token" ]]
then
    HF_TOKEN=$(< "$HOME/.config/huggingface/token")
    export HF_TOKEN
fi

# Clean up background telemetry subshells on shell exit.
# Only kills PIDs we spawned for caching — not user-started background jobs.
# Chains with any pre-existing EXIT trap to avoid silently overwriting it.
#
# Lifecycle:
#   1. Each __get_* telemetry function appends its background PID to __TAC_BG_PIDS
#   2. tactical_dashboard resets the array at the start of each render
#   3. On shell exit, __tac_exit_cleanup kills any lingering background subshells
#   4. The trap chains with any prior EXIT trap so other cleanup still runs
__TAC_BG_PIDS=()
# Clean up background telemetry subshells on shell exit.
function __tac_exit_cleanup() {
    local pid
    for pid in "${__TAC_BG_PIDS[@]}"
    do
        kill "$pid" 2>/dev/null
    done
}
_tac_prev_exit_trap=$(trap -p EXIT | sed "s/trap -- '//;s/' EXIT//")
trap '__tac_exit_cleanup; '"${_tac_prev_exit_trap:-}" EXIT
unset _tac_prev_exit_trap


# end of file
