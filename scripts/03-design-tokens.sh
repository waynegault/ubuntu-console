# shellcheck shell=bash
# shellcheck disable=SC2034
# ─── Module: 03-design-tokens ───────────────────────────────────────────────────────
# AI INSTRUCTION: On ANY change to this file, increment the Module Version below.
# TACTICAL_PROFILE_VERSION auto-computes from the sum of all module versions.
# Module Version: 1
# ==============================================================================
# 4. DESIGN TOKENS
# ==============================================================================
# @modular-section: design-tokens
# @depends: none
# @depended-on-by: ui-engine (§5), hooks (§6), telemetry (§7), maintenance (§8),
#   openclaw (§9), deployment (§10), llm-manager (§11), dashboard (§12), init (§13)
# @exports: C_Reset, C_BoxBg, C_Border, C_Text, C_Dim, C_Highlight, C_Success,
#   C_Warning, C_Error, C_Info (all readonly)
#
# ANSI colour constants for the tactical UI. Declared readonly so they cannot be
# accidentally mutated. They are NOT exported — child processes do not need them.
# C_BoxBg uses 256-color (38;5;30) for the unique teal border tone; all others
# use basic 16-color codes for maximum terminal compatibility.
if [[ -z "${C_Reset:-}" ]]
then
    readonly C_Reset=$'\e[0m'
    readonly C_BoxBg=$'\e[38;5;30m'    # DarkCyan (256-color)
    readonly C_Border=$'\e[36m'        # Cyan
    readonly C_Text=$'\e[37m'          # White
    readonly C_Dim=$'\e[90m'           # Gray
    readonly C_Highlight=$'\e[96m'     # Light Cyan
    readonly C_Success=$'\e[32m'       # Green
    readonly C_Warning=$'\e[33m'       # Yellow
    readonly C_Error=$'\e[31m'         # Red
    readonly C_Info=$'\e[34m'          # Blue
fi

# __require_design_tokens — Assert design tokens are loaded.
# Call at the top of any module that uses C_* tokens after modularisation.
# In the monolith this is a no-op (tokens are always above), but when sections
# become separate files it catches missing source-order dependencies early.
function __require_design_tokens() {
    [[ -n "${C_Reset:-}" ]] && return 0
    printf '%s\n' \
        "[Tactical Profile] FATAL: design tokens not loaded." \
        "Source 04-design-tokens.sh before this module." >&2
    return 1
}


# end of file
