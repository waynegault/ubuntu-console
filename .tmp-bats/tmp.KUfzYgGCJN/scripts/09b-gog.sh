# shellcheck shell=bash
# shellcheck disable=SC2034,SC2059,SC2154,SC2317
# ─── Module: 09b-gog ───────────────────────────────────────────────────────
# AI INSTRUCTION: On ANY change to this file, increment the Module Version below.
# TACTICAL_PROFILE_VERSION auto-computes from the sum of all module versions.
# Module Version: 1
# ==============================================================================
# 9b. GOG (Google CLI) MANAGER
# ==============================================================================
# @modular-section: gog
# @depends: constants, design-tokens, ui-engine
# @exports: gog-status, gog-login, gog-logout, gog-version,
#   __is_gog_installed

# ==============================================================================
# GOG INSTALLATION CHECK (Evaluated once at profile load time)
# ==============================================================================
# __TAC_GOG_OK is set to 1 only if gog CLI exists AND responds to --version.
# This functional check is performed once when this module loads.
# All code should check __TAC_GOG_OK instead of running `command -v gog`.
if command -v gog >/dev/null 2>&1 && command gog --version >/dev/null 2>&1; then
    __TAC_GOG_OK=1
else
    __TAC_GOG_OK=0
fi

# ---------------------------------------------------------------------------
# __is_gog_installed — Check if gog CLI is installed AND functional.
# Returns 0 if __TAC_GOG_OK is set (gog responded to --version), 1 otherwise.
# This uses the cached result from profile load time for efficiency.
# ---------------------------------------------------------------------------
function __is_gog_installed() {
    [[ "$__TAC_GOG_OK" == "1" ]]
}

# ---------------------------------------------------------------------------
# gog-status — Show gog authentication status and configuration.
# Displays config file location, keyring backend, and authorized accounts.
# ---------------------------------------------------------------------------
function gog-status() {
    if [[ "$__TAC_GOG_OK" != "1" ]]; then
        echo "${C_Error}gog CLI is not installed.${C_Reset}"
        echo "${C_Dim}Install via: brew install gog  or  go install github.com/gogcli/gog@latest${C_Reset}"
        return 1
    fi

    echo "${C_Warning}═══ GOG STATUS ═══${C_Reset}"
    echo ""

    # Show version
    local gog_ver
    gog_ver=$(command gog version 2>/dev/null | head -1)
    echo "${C_Success}Version:${C_Reset} $gog_ver"
    echo ""

    # Show config file location
    local config_file="$HOME/.config/gogcli/config.json"
    if [[ -f "$config_file" ]]; then
        echo "${C_Success}Config:${C_Reset} $config_file"
        echo ""

        # Show keyring backend if available
        local backend
        backend=$(jq -r '.keyring.backend // "auto"' "$config_file" 2>/dev/null)
        if [[ -n "$backend" && "$backend" != "null" ]]; then
            echo "${C_Success}Keyring Backend:${C_Reset} $backend"
            echo ""
        fi

        # Show authorized accounts
        echo "${C_Warning}Authorized Accounts:${C_Reset}"
        local accounts
        accounts=$(jq -r '.accounts[]?.email // empty' "$config_file" 2>/dev/null)
        if [[ -n "$accounts" ]]; then
            while IFS= read -r email; do
                echo "  ${C_Success}✓${C_Reset} $email"
            done <<< "$accounts"
        else
            echo "  ${C_Dim}No accounts configured${C_Reset}"
        fi
    else
        echo "${C_Warning}Config file not found:${C_Reset} $config_file"
        echo "${C_Dim}Run 'gog login <email>' to set up${C_Reset}"
    fi
}

# ---------------------------------------------------------------------------
# gog-login — Authorize and store a refresh token for a Google account.
# Wrapper around 'gog login <email>' with status feedback.
# ---------------------------------------------------------------------------
function gog-login() {
    if [[ "$__TAC_GOG_OK" != "1" ]]; then
        echo "${C_Error}gog CLI is not installed.${C_Reset}"
        return 1
    fi

    if [[ -z "$1" ]]; then
        echo "${C_Warning}Usage: gog-login <email>${C_Reset}"
        echo "${C_Dim}Example: gog-login user@gmail.com${C_Reset}"
        return 1
    fi

    echo "${C_Warning}Authorizing Google account: $1${C_Reset}"
    echo "${C_Dim}Opening browser for OAuth...${C_Reset}"
    command gog login "$1"
    local rc=$?
    if [[ $rc -eq 0 ]]; then
        echo "${C_Success}✓ Successfully authorized $1${C_Reset}"
    else
        echo "${C_Error}✗ Authorization failed (exit code: $rc)${C_Reset}"
    fi
    return $rc
}

# ---------------------------------------------------------------------------
# gog-logout — Remove stored credentials for a Google account.
# Wrapper around 'gog logout <email>' with confirmation.
# ---------------------------------------------------------------------------
function gog-logout() {
    if [[ "$__TAC_GOG_OK" != "1" ]]; then
        echo "${C_Error}gog CLI is not installed.${C_Reset}"
        return 1
    fi

    if [[ -z "$1" ]]; then
        echo "${C_Warning}Usage: gog-logout <email>${C_Reset}"
        return 1
    fi

    echo "${C_Warning}Removing credentials for: $1${C_Reset}"
    command gog logout "$1" -y
    local rc=$?
    if [[ $rc -eq 0 ]]; then
        echo "${C_Success}✓ Successfully logged out $1${C_Reset}"
    else
        echo "${C_Error}✗ Logout failed (exit code: $rc)${C_Reset}"
    fi
    return $rc
}

# ---------------------------------------------------------------------------
# gog-version — Print gog version information.
# ---------------------------------------------------------------------------
function gog-version() {
    if [[ "$__TAC_GOG_OK" != "1" ]]; then
        echo "${C_Error}gog CLI is not installed.${C_Reset}"
        return 1
    fi

    command gog version
}

# ---------------------------------------------------------------------------
# gog-help — Display gog help information in the tactical console style.
# ---------------------------------------------------------------------------
function gog-help() {
    if [[ "$__TAC_GOG_OK" != "1" ]]; then
        echo "${C_Error}gog CLI is not installed.${C_Reset}"
        return 1
    fi

    command gog --help
}

# end of file
