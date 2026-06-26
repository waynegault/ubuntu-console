#!/usr/bin/env bash
# shellcheck shell=bash
# ==============================================================================
# run-tests.sh — Tactical Console Test Runner
# ==============================================================================
# Runs Python tests via pytest and BATS suites directly with live TAP display.
#
# Usage:
#   tools/run-tests.sh                    # all tests (default)
#   tools/run-tests.sh --fast             # fast static-analysis tests only
#   tools/run-tests.sh --llm              # with LLM-dependent tests
#   tools/run-tests.sh --integration      # with integration tests
#   tools/run-tests.sh -- --filter "bash" # pass extra args to bats
# ==============================================================================
# Module Version: 3
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# ── Parse flags ──────────────────────────────────────────────────────────────
_MODE="all"
_EXTRA_ARGS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --all)          _MODE="all";          shift ;;
        --llm)          _MODE="llm";          shift ;;
        --integration)  _MODE="integration";  shift ;;
        --fast)         _MODE="fast";         shift ;;
        --)             shift; _EXTRA_ARGS+=("$@"); break ;;
        *)              _EXTRA_ARGS+=("$1");   shift ;;
    esac
done

# ── Colours ──────────────────────────────────────────────────────────────────
C_Reset=$'\e[0m'
C_Green=$'\e[32m'
C_Red=$'\e[31m'
C_Yellow=$'\e[33m'
C_Cyan=$'\e[36m'
C_Dim=$'\e[2m'
C_Bold=$'\e[1m'
C_BoldGreen=$'\e[1;32m'
C_BoldRed=$'\e[1;31m'
C_Border=$'\e[38;5;245m'

W=80
PASS_SYMBOL=$'\u2713'
FAIL_SYMBOL=$'\u2717'

# ── Drawing helpers ──────────────────────────────────────────────────────────
border_top()    { printf '%s+%s+%s\n' "$C_Border" "$(printf '%*s' "$((W-2))" '' | tr ' ' '-')" "$C_Reset"; }
border_mid()    { printf '%s|%s|%s\n' "$C_Border" "$(printf '%*s' "$((W-2))" '' | tr ' ' '-')" "$C_Reset"; }
border_bot()    { printf '%s+%s+%s\n' "$C_Border" "$(printf '%*s' "$((W-2))" '' | tr ' ' '-')" "$C_Reset"; }
row() {
    local text="$1"
    local plain; plain=$(printf '%s' "$text" | sed 's/\x1b\[[0-9;]*m//g')
    local pad=$(( W - 2 - ${#plain} )); (( pad < 0 )) && pad=0
    printf '%s| %s%*s |%s\n' "$C_Border" "$text" "$((pad - 1))" "" "$C_Reset"
}
row_empty() { row ""; }

section_header() {
    local label="$1" passed="$2" total="$3"
    border_mid
    if [[ "$passed" =~ ^[0-9]+$ && "$total" =~ ^[0-9]+$ ]]
    then
        local symbol="$PASS_SYMBOL" colour="$C_BoldGreen"
        (( passed < total )) && { symbol="$FAIL_SYMBOL"; colour="$C_BoldRed"; }
        row "${C_Bold}${C_Cyan}  ${label}${C_Reset}${C_Dim}  - ${passed}/${total} ${symbol}${C_Reset}"
    else
        row "${C_Bold}${C_Cyan}  ${label}${C_Reset}"
    fi
    border_mid
}

# ── Determine BATS files to run ──────────────────────────────────────────────
_build_bats_list() {
    local mode="$1"
    local files=()

    case "$mode" in
        fast)
            files=( "$REPO_ROOT/tests/tactical-console-fast.bats" )
            ;;
        all|llm|integration)
            for f in "$REPO_ROOT/tests"/*.bats \
                     "$REPO_ROOT/tests"/unit/*.bats \
                     "$REPO_ROOT/tests"/integration/*.bats; do
                [[ -f "$f" ]] && files+=("$f")
            done
            ;;
        *)
            # default: unit & fast — exclude full suite, LLM, and integration
            for f in "$REPO_ROOT/tests"/unit/*.bats \
                     "$REPO_ROOT/tests"/tactical-console-fast.bats; do
                [[ -f "$f" ]] && files+=("$f")
            done
            ;;
    esac

    printf '%s\n' "${files[@]}"
}

# ── Run a single BATS file and stream TAP ────────────────────────────────────
_run_bats_file() {
    local bats_file="$1"
    local label="$2"  # optional label prefix for display

    while IFS= read -r line; do
        if [[ "$line" =~ ^ok\ [0-9]+\ (.+)$ ]]; then
            _LIVE_NUM=$(( _LIVE_NUM + 1 ))
            _LIVE_PASS=$(( _LIVE_PASS + 1 ))
            row "  ${C_Dim}${_LIVE_NUM}.${C_Reset} ${label}${BASH_REMATCH[1]} ${C_Green}${PASS_SYMBOL}${C_Reset}"
        elif [[ "$line" =~ ^not\ ok\ [0-9]+\ (.+)$ ]]; then
            _LIVE_NUM=$(( _LIVE_NUM + 1 ))
            _LIVE_FAIL=$(( _LIVE_FAIL + 1 ))
            row "  ${C_Dim}${_LIVE_NUM}.${C_Reset} ${label}${BASH_REMATCH[1]} ${C_Red}${FAIL_SYMBOL}${C_Reset}"
        fi
        _TAP_OUTPUT+="$line"$'\n'
    done < <(bats --tap "$bats_file" "${_EXTRA_ARGS[@]}" 2>&1) || true
}

# ── Parse TAP output into section arrays ─────────────────────────────────────
_parse_tap() {
    local tap="$1"
    T_STATUS=(); T_NAME=(); T_PREFIX=(); T_DIAG=()
    local total=0 diag_buf=""

    while IFS= read -r line; do
        [[ "$line" =~ ^1\.\.  ]] && continue
        if [[ "$line" =~ ^#\  ]]; then
            diag_buf+="${line}"$'\n'
            continue
        fi
        if [[ "$line" =~ ^(ok|not\ ok)\ [0-9]+\ (.+)$ ]]; then
            if (( total > 0 )); then T_DIAG[total - 1]="$diag_buf"; fi
            diag_buf=""
            T_STATUS+=("${BASH_REMATCH[1]}")
            T_NAME+=("${BASH_REMATCH[2]}")
            T_PREFIX+=("${BASH_REMATCH[2]%%:*}")
            (( total++ ))
        fi
    done <<< "$tap"
    if (( total > 0 )); then T_DIAG[total - 1]="$diag_buf"; fi
}

# ── Section display names ────────────────────────────────────────────────────
declare -A SECTION_NAMES=(
    ["bash -n"]="Syntax — bash -n"
    ["shellcheck"]="Static Analysis — ShellCheck"
    ["structure"]="Profile Structure"
    ["constants"]="Global Constants"
    ["ui"]="UI Helper Engine"
    ["cache"]="Caching Engine"
    ["port"]="Port Utilities"
    ["metrics"]="System Metrics"
    ["calc"]="Pure Calculations"
    ["quant"]="Quant-Label Mapping"
    ["health"]="Health Checks"
    ["maintenance"]="Maintenance Helpers"
    ["model"]="Model Management"
    ["prompt"]="Prompt Engine"
    ["alias"]="Aliases"
    ["fn-avail"]="Function Availability"
    ["cross-script"]="Cross-Script Consistency"
    ["bin"]="Bin Scripts"
    ["hygiene"]="Code Hygiene"
    ["systemd"]="Systemd Units"
    ["install"]="Install Script"
    ["gog"]="GOG Integration"
    ["autotune"]="Autotune"
    ["module-version"]="Module Versions"
)

# ── Collapsed sections (header only, no individual lines) ────────────────────
COLLAPSED_SECTIONS=("fn-avail" "cross-script")

# ── Main ─────────────────────────────────────────────────────────────────────
_TAP_OUTPUT=""
_LIVE_NUM=0 _LIVE_PASS=0 _LIVE_FAIL=0
GRAND_PASS=0 GRAND_FAIL=0

case "${_MODE:-}" in
    fast)  _DESC="fast static-analysis only" ;;
    all)   _DESC="ALL TESTS" ;;
    llm)   _DESC="with LLM tests" ;;
    integration) _DESC="with integration tests" ;;
    *)     _DESC="unit & fast tests" ;;
esac

border_top
row "${C_Bold}  TACTICAL CONSOLE - Test Suite${C_Reset}"
row "${C_Dim}  $(date '+%Y-%m-%d %H:%M:%S')   mode: ${_DESC}${C_Reset}"

# ── Part 1: BATS Live Stream ─────────────────────────────────────────────────
section_header "Test Live Stream" "..." "..."

mapfile -t BATS_FILES < <(_build_bats_list "${_MODE:-}")

for bf in "${BATS_FILES[@]}"; do
    [[ -f "$bf" ]] || continue
    bf_rel="${bf#$REPO_ROOT/}"
    row_empty
    row "  ${C_Bold}${bf_rel}${C_Reset}"
    _run_bats_file "$bf" ""
done

# ── Part 2: Section Summaries ────────────────────────────────────────────────
_parse_tap "$_TAP_OUTPUT"
total=${#T_STATUS[@]}

# Tally per-section counts
declare -A SEC_PASS=() SEC_TOTAL=()
declare -a SEC_ORDER=()

for (( i = 0; i < total; i++ )); do
    p="${T_PREFIX[$i]}"
    if [[ -z "${SEC_TOTAL[$p]+x}" ]]; then
        SEC_TOTAL[$p]=0; SEC_PASS[$p]=0
        SEC_ORDER+=("$p")
    fi
    (( SEC_TOTAL[$p]++ ))
    [[ "${T_STATUS[$i]}" == "ok" ]] && (( SEC_PASS[$p]++ ))
done

section_header "Section Summaries" "..." "..."

_sum_num=0
for p in "${SEC_ORDER[@]}"; do
    local_pass=${SEC_PASS[$p]}
    local_total=${SEC_TOTAL[$p]}
    display="${SECTION_NAMES[$p]:-$p}"

    section_header "$display" "$local_pass" "$local_total"

    # Collapsed sections: header only
    _collapsed=0
    for cs in "${COLLAPSED_SECTIONS[@]}"; do
        [[ "$p" == "$cs" ]] && { _collapsed=1; break; }
    done
    if (( _collapsed )); then
        (( GRAND_PASS += local_pass ))
        (( GRAND_FAIL += local_total - local_pass ))
        continue
    fi

    for (( i = 0; i < total; i++ )); do
        [[ "${T_PREFIX[$i]}" != "$p" ]] && continue
        _tname="${T_NAME[$i]#*: }"
        if [[ "${T_STATUS[$i]}" == "ok" ]]; then
            (( GRAND_PASS++ ))
            (( _sum_num++ ))
            row "  ${C_Dim}${_sum_num}.${C_Reset} ${_tname} ${C_Green}${PASS_SYMBOL}${C_Reset}"
        else
            (( GRAND_FAIL++ ))
            (( _sum_num++ ))
            row "  ${C_Dim}${_sum_num}.${C_Reset} ${_tname} ${C_Red}${FAIL_SYMBOL}${C_Reset}"
            if [[ -n "${T_DIAG[$i]:-}" ]]; then
                while IFS= read -r dline; do
                    [[ -z "$dline" ]] && continue
                    row "    ${C_Dim}${dline}${C_Reset}"
                done <<< "${T_DIAG[$i]}"
            fi
        fi
    done
done

# ── Run Python tests via pytest ──────────────────────────────────────────────
_PY_EXIT=0
if [[ "${_MODE:-}" != "fast" ]]; then
    row_empty
    section_header "Python Tests (pytest)" "..." "..."

    _PY_MARKERS=""
    case "${_MODE:-}" in
        all)   ;;
        *)     _PY_MARKERS="-m not (bats_llm or bats_integration)" ;;
    esac

    cd "$REPO_ROOT"
    python3 -m pytest tests/ -v --tb=short ${_PY_MARKERS:+"$_PY_MARKERS"} \
        --ignore=tests/test_bats_bridge.py 2>&1 || _PY_EXIT=$?
fi

# ── Summary ──────────────────────────────────────────────────────────────────
border_mid
grand_total=$(( GRAND_PASS + GRAND_FAIL ))

if (( GRAND_FAIL == 0 && _PY_EXIT == 0 )); then
    _msg="${C_BoldGreen}ALL ${grand_total} TESTS PASSED ${PASS_SYMBOL}${C_Reset}"
    [[ "${_MODE:-}" != "fast" ]] && _msg+="  ${C_Dim}(+ Python tests OK)${C_Reset}"
    row "  $_msg"
else
    _summary=""
    if (( GRAND_FAIL > 0 )); then
        _summary+="${C_BoldRed}${GRAND_FAIL} FAILED ${FAIL_SYMBOL}${C_Reset}"
    else
        _summary+="${C_Green}${GRAND_PASS} passed ${PASS_SYMBOL}${C_Reset}"
    fi
    _summary+="  ${C_Dim}|${C_Reset}  ${grand_total} total"
    [[ "$_PY_EXIT" != "0" ]] && _summary+="  ${C_Dim}|${C_Reset}  ${C_Red}Python tests FAILED${C_Reset}"
    row "  $_summary"

    # Show failing test details
    for (( i = 0; i < total; i++ )); do
        if [[ "${T_STATUS[$i]}" != "ok" ]]; then
            row "  ${C_Red}${FAIL_SYMBOL}${C_Reset} ${T_NAME[$i]}"
            if [[ -n "${T_DIAG[$i]:-}" ]]; then
                while IFS= read -r dline; do
                    [[ -z "$dline" ]] && continue
                    row "    ${C_Dim}${dline}${C_Reset}"
                done <<< "${T_DIAG[$i]}"
            fi
        fi
    done
fi

border_bot

exit_code=0
(( GRAND_FAIL > 0 )) && exit_code=1
(( _PY_EXIT != 0 )) && exit_code=1
exit $exit_code
# end of file
