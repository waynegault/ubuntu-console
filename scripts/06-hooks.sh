# shellcheck shell=bash
# shellcheck disable=SC1091,SC2034,SC2059,SC2154
# ─── Module: 06-hooks ───────────────────────────────────────────────────────
# AI INSTRUCTION: On ANY change to this file, increment the Module Version below.
# TACTICAL_PROFILE_VERSION auto-computes from the sum of all module versions.
# Module Version: 1
# ==============================================================================
# 6. SYSTEM HOOKS & OVERRIDES
# ==============================================================================
# @modular-section: hooks
# @depends: constants, design-tokens, ui-engine
# @exports: cd (override), custom_prompt_command, __test_port,
#   _TAC_ADMIN_BADGE, PROMPT_COMMAND

# ---------------------------------------------------------------------------
# cd — Override to auto-activate/deactivate Python virtual environments.
# Activates .venv/bin/activate when entering a directory that contains one.
# Deactivates when leaving the project root (trailing-slash check prevents
# false positives like /home/wayne/project2 matching /home/wayne/project).
# ---------------------------------------------------------------------------
function cd() {
    # Validate arguments before passing to builtin
    if [[ $# -eq 0 ]]
    then
        builtin cd || return $?
    else
        builtin cd "$@" || return $?
    fi

    # Auto-activate .venv if present in new directory
    if [[ -f "$VENV_DIR/bin/activate" ]]
    then
        # Activate AFTER the cd has completed (builtin cd above already changed PWD).
        # If activation fails, warn but do not abort (the cd itself succeeded).
        if ! source "$VENV_DIR/bin/activate" 2>/dev/null
        then
            printf '%sWarning: .venv/bin/activate failed to source%s\n' "$C_Warning" "$C_Reset" >&2
            # Clear VIRTUAL_ENV to avoid confusion (activation didn't happen)
            unset VIRTUAL_ENV PS1
        fi
        return
    fi

    # Auto-deactivate if we left the project root
    if [[ -n "$VIRTUAL_ENV" ]]
    then
        local venv_root
        venv_root=$(dirname "$VIRTUAL_ENV")
        local current_wd
        current_wd=$(pwd -P)
        if [[ "$current_wd" != "$venv_root" && "$current_wd" != "$venv_root/"* ]]
        then
            type deactivate >/dev/null 2>&1 && deactivate
        fi
    fi
}

if [[ " $(id -nG 2>/dev/null) " == *" sudo "* ]]
then
    _TAC_ADMIN_BADGE=" \[${C_Warning}\]${TRI_DOWN}\[${C_Reset}\]"
else
    _TAC_ADMIN_BADGE=""
fi

# Ensure design tokens and glyphs exist so PS1 builds reliably.
# Some environments or partial sources can leave C_* or glyph vars empty;
# provide conservative fallbacks here to avoid producing an empty prompt.
if [[ -z "${C_Reset:-}" ]]
then
    C_Reset=$'\e[0m'
    C_BoxBg=$'\e[38;5;30m'
    C_Border=$'\e[36m'
    C_Text=$'\e[37m'
    C_Dim=$'\e[90m'
    C_Highlight=$'\e[96m'
    C_Success=$'\e[32m'
    C_Warning=$'\e[33m'
    C_Error=$'\e[31m'
    C_Info=$'\e[34m'
fi

# Glyph fallbacks (printable characters; do NOT wrap these in \[ \])
: "${CHECK_MARK:=$'\u2713'}"
: "${CROSS_MARK:=$'\u2717'}"
: "${TRI_DOWN:=$'\u25BC'}"

# custom_prompt_command — PROMPT_COMMAND handler: updates PS1, history, error badge.
function custom_prompt_command() {
    local lastExit=$?
    __tac_preexec_fired=0
    history -a

    # If history number hasn't changed, user pressed Enter with no command —
    # clear the error badge so × doesn't persist across empty prompts.
    local -a _hist_arr=()
    read -ra _hist_arr <<< "$(history 1 2>/dev/null)"
    local hist_num="${_hist_arr[0]}"
    if [[ "$hist_num" == "${__tac_last_hist_num:-}" ]]
    then
        lastExit=0
    fi
    __tac_last_hist_num="$hist_num"

    local ps1_user="\[${C_Highlight}\]\u\[${C_Reset}\]"
    local exit_badge=" \[${C_Error}\]${CROSS_MARK}\[${C_Reset}\] "
    (( lastExit == 0 )) && exit_badge=" \[${C_Success}\]${CHECK_MARK}\[${C_Reset}\] "
    local ps1_path="\[${C_Info}\]\w\[${C_Reset}\]"
    local ps1_venv=""
    [[ -n "$VIRTUAL_ENV" ]] && ps1_venv=" \[${C_Success}\]($(basename "$VIRTUAL_ENV"))\[${C_Reset}\]"

    PS1="\n${ps1_user}${_TAC_ADMIN_BADGE}${exit_badge}${ps1_path}${ps1_venv} \[${C_Dim}\]> \[${C_Reset}\]"
}

# Prepend custom_prompt_command to PROMPT_COMMAND if not already present.
# Uses the ${var:+;$var} idiom to avoid a leading semicolon when PROMPT_COMMAND
# is empty. This chains with any pre-existing PROMPT_COMMAND entries.
if [[ "$PROMPT_COMMAND" != *"custom_prompt_command"* ]]
then
    PROMPT_COMMAND="custom_prompt_command${PROMPT_COMMAND:+;$PROMPT_COMMAND}"
fi

# Print a blank line before every command's output so there is visual breathing
# room between the prompt and the result.  The __tac_preexec_fired guard ensures
# the newline prints only once per interactive command (not again for each
# pipeline segment, PROMPT_COMMAND, or subshell).
__tac_preexec_fired=0
trap '[[ "$BASH_COMMAND" == "$PROMPT_COMMAND" || "$BASH_COMMAND" == custom_prompt_command ]] || \
      (( __tac_preexec_fired )) || { __tac_preexec_fired=1; echo; }' DEBUG

# ---------------------------------------------------------------------------
# __test_port — Instant port check via kernel socket table (returns 0 if listening).
# Usage: __test_port <port_number>
# ---------------------------------------------------------------------------
function __test_port() {
    ss -tln "sport = :$1" 2>/dev/null | grep -q LISTEN
}

# ---------------------------------------------------------------------------
# __wait_for_port — Wait for a port to become available (or timeout).
# Usage: __wait_for_port <port> <timeout_seconds>
# Returns: 0 if port becomes available, 1 on timeout
# ---------------------------------------------------------------------------
function __wait_for_port() {
    local port=$1 timeout=${2:-10} elapsed=0
    while (( elapsed < timeout ))
    do
        __test_port "$port" && return 0
        sleep 1
        ((elapsed++))
    done
    return 1
}


# end of file
