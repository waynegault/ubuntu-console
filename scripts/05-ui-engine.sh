# shellcheck shell=bash
# shellcheck disable=SC2034,SC2059,SC2154
# ─── Module: 05-ui-engine ───────────────────────────────────────────────────────
# AI INSTRUCTION: On ANY change to this file, increment the Module Version below.
# TACTICAL_PROFILE_VERSION auto-computes from the sum of all module versions.
# Module Version: 3
# ==============================================================================
# 5. UI HELPER ENGINE
# ==============================================================================
# @modular-section: ui-engine
# @depends: constants, design-tokens
# @depended-on-by: telemetry (§7), maintenance (§8), openclaw (§9),
#   deployment (§10), llm-manager (§11), dashboard (§12)
# @exports: __strip_ansi, __tac_header, __tac_footer, __tac_divider, __tac_info,
#   __tac_line, __fRow, __hSection, __hRow, __show_header, clear_tactical,
#   __vsc_open, __save_nullglob, __restore_nullglob, __require_openclaw, __usage
#
# All __tac_* functions render box-drawn UI elements using the UIWidth constant.
# They use printf -v for padding generation (no subshells / no seq) for speed.
# Helper functions (__fRow, __hRow, __hSection) are defined here to keep all
# UI primitives in one section. They are prefixed with __ to signal "internal".
#
# DIVIDER STYLES (intentional distinction):
#   ╠═══╣  Frame-level break (double-line) — __tac_header open, dashboard blocks
#   ╟───╢  Within-section divider (single-line) — __tac_divider(), used in up()

# ---------------------------------------------------------------------------
# __threshold_color — Return a color token based on standard thresholds.
# Usage: local color; color=$(__threshold_color <value>)
#   >90 = C_Error (red), >75 = C_Warning (yellow), else = C_Success (green)
#   Deduplicates the repeated threshold pattern (dashboard, sysinfo, gpu-status).
# ---------------------------------------------------------------------------
function __threshold_color() {
    local val=$1
    if (( val > 90 ))
    then
        echo "$C_Error"
    elif (( val > 75 ))
    then
        echo "$C_Warning"
    else
        echo "$C_Success"
    fi
}

# ---------------------------------------------------------------------------
# __vsc_open — Open a file in VS Code with lazy-resolved path.
# Usage: __vsc_open <filepath> [confirmation_message]
# Deduplicates the repeated __resolve_vscode_bin + "$VSCODE_BIN" pattern
# used by oedit, llmconf, oclogs, occonf, mlogs, and any future wrappers.
# ---------------------------------------------------------------------------
function __vsc_open() {
    local target="$1"
    local msg="${2:-VS Code opened...}"

    __resolve_vscode_bin
    if [[ -z "${VSCODE_BIN:-}" || ! -x "$VSCODE_BIN" ]]
    then
        __tac_info "VS Code" "[NOT FOUND]" "$C_Error"
        return 1
    fi
    "$VSCODE_BIN" "$target"
    printf '%s\n' "$msg"
}

# ---------------------------------------------------------------------------
# __save_nullglob / __restore_nullglob — Save and restore the nullglob state.
# Deduplicates the repeated pattern across __cleanup_temps, logtrim,
# oc-cache-clear, and any future glob-dependent loops.
# Usage:
#   __save_nullglob
#   shopt -s nullglob
#   ... loop ...
#   __restore_nullglob
# ---------------------------------------------------------------------------
function __save_nullglob() {
    __tac_had_nullglob=0
    if shopt -q nullglob
    then
        __tac_had_nullglob=1
    fi
    shopt -s nullglob
}

# __restore_nullglob — Undo nullglob set by __save_nullglob.
function __restore_nullglob() {
    if (( ! __tac_had_nullglob ))
    then
        shopt -u nullglob
    fi
}

# ---------------------------------------------------------------------------
# __require_command — Verify a command is installed.
# Usage: __require_command <command_name>
# Prints an error and returns 1 if missing. Deduplicates the repeated
# `command -v X >/dev/null 2>&1` pattern across multiple modules.
# ---------------------------------------------------------------------------
function __require_command() {
    local _cmd="$1"
    if ! command -v "$_cmd" >/dev/null 2>&1
    then
        __tac_info "$_cmd" "[NOT INSTALLED]" "$C_Error"
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# __require_openclaw — Verify openclaw CLI is installed.
# Prints an error and returns 1 if missing. Deduplicates the repeated
# `command -v openclaw >/dev/null` checks across §9 functions.
# ---------------------------------------------------------------------------
function __require_openclaw() {
    if ! command -v openclaw >/dev/null 2>&1
    then
        __tac_info "OpenClaw CLI" "[NOT INSTALLED]" "$C_Error"
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# __usage — Print a formatted usage-hint line using design tokens.
# Usage: __usage "oc-config get <key> | set <key> <value> | unset <key>"
# Deduplicates the repeated  echo -e "${C_Dim}Usage:..."  pattern.
# ---------------------------------------------------------------------------
function __usage() {
    printf '%s%sUsage:%s %s\n' "$C_Dim" "" "$C_Reset" "$1"
}

# ---------------------------------------------------------------------------
# __strip_ansi — Strip ANSI escape codes from a string (pure bash, zero forks).
# Usage: __strip_ansi "string_with_colors" result_var
#   Sets the named variable to the stripped text using bash regex only.
#   No subshells, no sed — critical for dashboard render speed (called 20+ times).
#
# Regex breakdown: $'\e\['[0-9\;]*[mK]
#   $'\e\['  — ESC + literal [ (the CSI introducer)
#   [0-9\;]* — zero or more digits/semicolons (SGR parameters)
#   [mK]     — the terminator: 'm' for colours, 'K' for erase-line
#
# Trade-off (I1): The while-loop + global substitution is O(n²) worst-case for
# strings with many distinct escape sequences, but in practice dashboard values
# have at most 2-3 distinct sequences so this is faster than forking to sed.
#
# Security (S3): Validates varname to prevent indirect variable injection.
#   - Must be non-empty
#   - Must start with letter or underscore
#   - Must contain only alphanumeric and underscore
#   - Max 64 characters (prevents DoS via long variable names)
#   - Must not be a bash reserved word
# ---------------------------------------------------------------------------
function __strip_ansi() {
    local input="$1" varname="$2" tmp
    # Safety: validate varname is a legal bash identifier (S3 — prevents
    # indirect variable injection if callers ever pass untrusted data).

    # Reject empty or missing varname
    if [[ -z "$varname" ]]
    then
        return 1
    fi

    # Reject excessively long variable names (DoS prevention)
    if [[ ${#varname} -gt 64 ]]
    then
        return 1
    fi

    # Reject bash reserved words to prevent shadowing attacks
    case "$varname" in
        if|then|else|elif|fi|case|'esac'|for|while|until|do|done|in|function|\
        select|time|coproc|return|exit|break|continue|local|declare|\
        typeset|readonly|export|unset|shift|getopts|eval|exec|trap|\
        wait|kill|bg|fg|jobs|disown|suspend|logout|hash|pwd|cd|pushd|popd|\
        dirs|set|shopt|umask|alias|unalias|bind|builtin|caller|\
        command|compgen|complete|compopt|echo|enable|help|let|mapfile|\
        printf|read|readarray|source|type|ulimit|fc|history|times)
            return 1
            ;;
    esac

    # Validate format: must start with letter or underscore, contain only
    # alphanumeric and underscore
    if [[ ! "$varname" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]
    then
        return 1
    fi

    # Regex stored in a variable to avoid bash 5.x $'...' serialisation quirk
    # where declare -f adds a spurious backslash before '[' in the ANSI token.
    local _ansi_re=$'\e\[[0-9;]*[mK]'
    tmp="$input"
    while [[ "$tmp" =~ $_ansi_re ]]
    do
        tmp="${tmp//${BASH_REMATCH[0]}/}"
    done
    printf -v "$varname" '%s' "$tmp"
}

# ---------------------------------------------------------------------------
# __tac_header — Render a 3-row box header: ╔═╗ / ║ title ║ / ╚═╝ or ╠═╣.
# Usage: __tac_header "TITLE" [open|closed] [version]
#   open   → bottom is ╠═╣ (more content follows inside the box)
#   closed → bottom is ╚═╝ (standalone header)
# ---------------------------------------------------------------------------
function __tac_header() {
    local title="$1"
    local style="${2:-closed}"
    local version="${3:-}"

    local inner_width=$((UIWidth - 2))
    local line
    printf -v line '%*s' "$inner_width" ''
    line="${line// /$BOX_H}"

    printf "%s%s%s%s%s\n" "$C_BoxBg" "$BOX_TL" "$line" "$BOX_TR" "$C_Reset"

    if [[ -n "$version" ]]
    then
        # Three-column layout: Bash version (grey) | title (highlight) | version (grey)
        local left_text=" Bash v${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}"
        local center_text="${title}"
        local right_text="v${version}"

        local center_start=$(( (inner_width - ${#center_text}) / 2 ))
        local gap1=$(( center_start - ${#left_text} ))
        local gap2=$(( inner_width - center_start - ${#center_text} - ${#right_text} ))

        local pad1=""; (( gap1 > 0 )) && printf -v pad1 '%*s' "$gap1" ""
        local pad2=""; (( gap2 > 0 )) && printf -v pad2 '%*s' "$gap2" ""

        local _hdr_fmt="${C_BoxBg}${BOX_V}${C_Reset}${C_Dim}%s${C_Reset}%s"
        _hdr_fmt+="${C_Highlight}%s${C_Reset}%s"
        _hdr_fmt+="${C_Dim}%s${C_Reset}${C_BoxBg}${BOX_V}${C_Reset}\n"
        printf "$_hdr_fmt" \
            "$left_text" "$pad1" "$center_text" "$pad2" "$right_text"
    else
        # Centred title only
        local display_text="- ${title} -"
        local pad_left=$(( (inner_width - ${#display_text}) / 2 ))
        local pad_right=$(( inner_width - ${#display_text} - pad_left ))
        local lpad="" rpad=""
        (( pad_left  > 0 )) && printf -v lpad  '%*s' "$pad_left"  ""
        (( pad_right > 0 )) && printf -v rpad '%*s' "$pad_right" ""

        printf "${C_BoxBg}${BOX_V}${C_Reset}%s${C_Highlight}%s${C_Reset}%s${C_BoxBg}${BOX_V}${C_Reset}\n" \
            "$lpad" "$display_text" "$rpad"
    fi

    if [[ "$style" == "open" ]]
    then
        printf "%s%s%s%s%s\n" "$C_BoxBg" "$BOX_LM" "$line" "$BOX_RM" "$C_Reset"
    elif [[ "$style" == "closed" ]]
    then
        printf "%s%s%s%s%s\n" "$C_BoxBg" "$BOX_BL" "$line" "$BOX_BR" "$C_Reset"
    fi
}

# ---------------------------------------------------------------------------
# __tac_footer — Render the closing bottom border of a box.
# ---------------------------------------------------------------------------
function __tac_footer() {
    local inner_width=$((UIWidth - 2))
    local line; printf -v line '%*s' "$inner_width" ''; line="${line// /${BOX_H}}"
    printf "%s%s%s%s%s\n" "$C_BoxBg" "$BOX_BL" "$line" "$BOX_BR" "$C_Reset"
}

# ---------------------------------------------------------------------------
# __tac_divider — Render a single-line horizontal divider within a box.
# ---------------------------------------------------------------------------
function __tac_divider() {
    local inner_width=$((UIWidth - 2))
    local line; printf -v line '%*s' "$inner_width" ''; line="${line// /$BOX_SL}"
    printf "%s%s%s%s%s\n" "$C_BoxBg" "$BOX_SLC" "$line" "$BOX_SRC" "$C_Reset"
}

# ---------------------------------------------------------------------------
# __tac_info — Borderless status line for quick command feedback.
# Usage: __tac_info "Label" "[STATUS]" "$C_Color"
# ---------------------------------------------------------------------------
function __tac_info() {
    local label="$1" status="$2" color="${3:-$C_Text}"
    local cleanLabel; __strip_ansi "$label" cleanLabel
    local cleanStatus; __strip_ansi "$status" cleanStatus
    local padLen=$(( UIWidth - ${#cleanLabel} - ${#cleanStatus} ))
    (( padLen < 1 )) && padLen=1
    local pad; printf -v pad '%*s' "$padLen" ""
    printf "${C_Dim}%b${C_Reset}%s${color}%b${C_Reset}\n" "$label" "$pad" "$status"
}

# ---------------------------------------------------------------------------
# __tac_line — Render a bordered row with action text and right-aligned status.
# Usage: __tac_line "Action text" "[STATUS]" "$C_Color"
# Inner text area = UIWidth - 4 (borders + 1-space padding each side).
# ---------------------------------------------------------------------------
function __tac_line() {
    local action="$1" status="$2" color="${3:-$C_Text}"
    local inner_text=$(( UIWidth - 4 ))  # borders + 1-space padding each side
    local cleanAction; __strip_ansi "$action" cleanAction
    local cleanStatus; __strip_ansi "$status" cleanStatus

    local contentLen=$(( ${#cleanAction} + ${#cleanStatus} ))
    local padLength=$(( inner_text - contentLen ))
    (( padLength < 1 )) && padLength=1

    local padding; printf -v padding '%*s' "$padLength" ""
    printf "%s" "${C_BoxBg}${BOX_V}${C_Reset} "
    printf "%b" "$action"
    printf "%s" "$padding"
    printf "%s" "$color"
    printf "%s" "$status"
    printf "%s\n" " ${C_Reset}${C_BoxBg}${BOX_V}${C_Reset}"
}

# ---------------------------------------------------------------------------
# __fRow — Dashboard row: "LABEL      :: value" inside box borders.
# Truncates values to prevent border overflow.
# Layout: 2 indent + 12 label + 4 " :: " + val_width + border = UIWidth
# val_width = UIWidth - 20  (the 20 comes from: 2 borders + 2 indent + 12 label + 4 separator)
# Usage: __fRow "LABEL" "value" "$C_Color"
# ---------------------------------------------------------------------------
function __fRow() {
    local label="$1"
    local val="$2"
    local color="${3:-$C_Text}"
    local val_width=$(( UIWidth - 20 ))  # 2 indent + 12 label + 4 sep + 2 borders
    # Strip ANSI codes to measure visible length
    local cleanVal; __strip_ansi "$val" cleanVal
    # Primary truncation: cap at val_width visible chars
    if (( ${#cleanVal} > val_width ))
    then
        cleanVal="${cleanVal:0:$((val_width - 3))}..."
        val="$cleanVal"
    fi
    local labelPad=$(( 12 - ${#label} ))
    local valPad=$(( val_width - ${#cleanVal} ))
    # Belt-and-suspenders guard — should never trigger after primary truncation.
    # Kept as a defensive safety net: if __strip_ansi miscounts (e.g., partial
    # escape sequences), this prevents printf from overflowing the box border.
    if (( valPad < 0 ))
    then
        val="${val:0:$((${#val} + valPad - 3))}..."
        cleanVal="${cleanVal:0:$((${#cleanVal} + valPad))}..."
        valPad=0
    fi

    local lPadStr=""; (( labelPad > 0 )) && printf -v lPadStr '%*s' "$labelPad" ""
    local vPadStr=""; (( valPad  > 0 )) && printf -v vPadStr '%*s' "$valPad"  ""

    printf "${C_BoxBg}${BOX_V}${C_Reset}"
    printf "  ${C_Dim}%s%s :: ${C_Reset}" "$label" "$lPadStr"
    if [[ -n "$color" ]]; then
        printf "%s%s%s" "$color" "$val" "$C_Reset"
    else
        printf "%s" "$val"
    fi
    printf "%s${C_BoxBg}${BOX_V}${C_Reset}\n" "$vPadStr"
}

# ---------------------------------------------------------------------------
# __hSection — Help index section header (centred, double-line border).
# Usage: __hSection "SECTION TITLE"
# ---------------------------------------------------------------------------
function __hSection() {
    local title="$1"
    local inner_width=$((UIWidth - 2))
    local sep; printf -v sep '%*s' "$inner_width" ''; sep="${sep// /${BOX_H}}"
    local pad_left=$(( (inner_width - ${#title}) / 2 ))
    local pad_right=$(( inner_width - ${#title} - pad_left ))

    local left_space=""; (( pad_left  > 0 )) && printf -v left_space  '%*s' "$pad_left"  ""
    local right_space=""; (( pad_right > 0 )) && printf -v right_space '%*s' "$pad_right" ""

    printf "%s%s%s%s%s\n" "$C_BoxBg" "$BOX_LM" "$sep" "$BOX_RM" "$C_Reset"
    printf "${C_BoxBg}${BOX_V}${C_Reset}${C_Warning}%s%s%s${C_Reset}${C_BoxBg}${BOX_V}${C_Reset}\n" \
        "$left_space" "$title" "$right_space"
}

# ---------------------------------------------------------------------------
# __hRow — Help index row renderer with safe wrapping for long command/help text.
# Layout derived from UIWidth: cmd_width=32, desc_width = UIWidth - 37.
# Usage: __hRow "command" "Description of what it does"
# ---------------------------------------------------------------------------
function __hRow() {
    local cmd="${1:-}"
    local desc="${2:-}"
    local cmd_width=32
    local desc_width=$(( UIWidth - 37 ))  # 2 borders + 2 indent + 32 cmd + 1 spacer

    local first_line=1
    while [[ -n "$cmd" || -n "$desc" || $first_line -eq 1 ]]
    do
        local cmd_chunk="${cmd:0:$cmd_width}"
        local desc_chunk="${desc:0:$desc_width}"
        cmd="${cmd:$cmd_width}"
        desc="${desc:$desc_width}"

        local cmd_pad=$(( cmd_width - ${#cmd_chunk} ))
        local desc_pad=$(( desc_width - ${#desc_chunk} ))
        local cmd_pad_str=""
        local desc_pad_str=""
        (( cmd_pad > 0 )) && printf -v cmd_pad_str '%*s' "$cmd_pad" ""
        (( desc_pad > 0 )) && printf -v desc_pad_str '%*s' "$desc_pad" ""

        printf "%b%s%s%b%s%s%b\n" \
            "${C_BoxBg}${BOX_V}  " \
            "${C_Highlight}" "$cmd_chunk" \
            "${C_Text}" "$cmd_pad_str $desc_chunk" \
            "$desc_pad_str" \
            "${C_BoxBg}${BOX_V}${C_Reset}"

        first_line=0
        [[ -n "$cmd" || -n "$desc" ]] || break
    done
}

# ---------------------------------------------------------------------------
# __show_header — Display the oneliner startup banner.
# ---------------------------------------------------------------------------
function __show_header() {
    local inner_width=$((UIWidth - 2))
    local line; printf -v line '%*s' "$inner_width" ''; line="${line// /$BOX_H}"

    local left_text=" Bash v${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}"
    local center_text="- Wayne's Ubuntu Terminal -"

    # Ensure `TACTICAL_PROFILE_VERSION` is exported so other tools/tests
    # relying on its presence see a sensible value when this module is
    # sourced standalone. Prefer the module's comment version, then
    # the loader version, finally '0.0'. Do not override an existing value.
    if [[ -z "${TACTICAL_PROFILE_VERSION:-}" ]]; then
        local _src="${BASH_SOURCE[0]:-$0}"
        local _mod_ver
        _mod_ver=$(grep -m1 '^# Module Version:' "$_src" 2>/dev/null | awk '{print $NF}')
        if [[ "$_mod_ver" =~ ^[0-9]+$ ]]; then
            export TACTICAL_PROFILE_VERSION="${_TAC_LOADER_VERSION:-0}.${_mod_ver}"
        else
            export TACTICAL_PROFILE_VERSION="${_TAC_LOADER_VERSION:-0}.0"
        fi
        unset _src _mod_ver
    fi

    # Right-hand version: prefer global profile version, else fall back to
    # the module's declared "Module Version" comment in this file, then
    # to the loader version, finally 'unknown'. Ensures the header shows a
    # useful version even when running modules standalone.
    local right_text=""
    if [[ -n "${TACTICAL_PROFILE_VERSION:-}" ]]; then
        right_text="v${TACTICAL_PROFILE_VERSION} "
    else
        local _src="${BASH_SOURCE[0]:-$0}"
        local _mod_ver
        _mod_ver=$(grep -m1 '^# Module Version:' "$_src" 2>/dev/null | awk '{print $NF}')
        if [[ "$_mod_ver" =~ ^[0-9]+$ ]]; then
            right_text="v${_mod_ver} "
        else
            right_text="v${_TAC_LOADER_VERSION:-unknown} "
        fi
        unset _src _mod_ver
    fi

    local center_start=$(( (inner_width - ${#center_text}) / 2 ))
    local gap1=$(( center_start - ${#left_text} ))
    local gap2=$(( inner_width - center_start - ${#center_text} - ${#right_text} ))

    local pad1=""; (( gap1 > 0 )) && printf -v pad1 '%*s' "$gap1" ""
    local pad2=""; (( gap2 > 0 )) && printf -v pad2 '%*s' "$gap2" ""

    printf "%s%s%s%s%s\n" "$C_BoxBg" "$BOX_TL" "$line" "$BOX_TR" "$C_Reset"
    local _hdr_fmt="${C_BoxBg}${BOX_V}${C_Reset}${C_Dim}%s${C_Reset}%s"
    _hdr_fmt+="${C_Highlight}%s${C_Reset}%s"
    _hdr_fmt+="${C_Dim}%s${C_Reset}${C_BoxBg}${BOX_V}${C_Reset}\n"
    printf "$_hdr_fmt" \
        "$left_text" "$pad1" "$center_text" "$pad2" "$right_text"
    printf "%s%s%s%s%s\n" "$C_BoxBg" "$BOX_BL" "$line" "$BOX_BR" "$C_Reset"
}

# ---------------------------------------------------------------------------
# clear_tactical — Clear screen and redraw the startup banner.
# ---------------------------------------------------------------------------
function clear_tactical() {
    command clear
    __show_header
}


# end of file
