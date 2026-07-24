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
# shellcheck disable=SC2034
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
        # shellcheck disable=SC2034
        local symbol="$PASS_SYMBOL" colour="$C_BoldGreen"
        # shellcheck disable=SC2034
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
        # Parse timing from TAP: "ok N test_name in XXXms" or "not ok N test_name in XXXs"
        local timing=""
        if [[ "$line" =~ ^(ok|not\ ok)\ [0-9]+\ (.+)\ in\ ([0-9.]+)(sec|ms)$ ]]; then
            local status="${BASH_REMATCH[1]}"
            local test_name="${BASH_REMATCH[2]}"
            local duration="${BASH_REMATCH[3]}${BASH_REMATCH[4]}"
            timing=" ${C_Dim}(${duration})${C_Reset}"
            if [[ "$status" == "ok" ]]; then
                _LIVE_NUM=$(( _LIVE_NUM + 1 ))
                _LIVE_PASS=$(( _LIVE_PASS + 1 ))
                row "  ${C_Dim}${_LIVE_NUM}.${C_Reset} ${label}${test_name} ${C_Green}${PASS_SYMBOL}${C_Reset}${timing}"
            else
                _LIVE_NUM=$(( _LIVE_NUM + 1 ))
                _LIVE_FAIL=$(( _LIVE_FAIL + 1 ))
                row "  ${C_Dim}${_LIVE_NUM}.${C_Reset} ${label}${test_name} ${C_Red}${FAIL_SYMBOL}${C_Reset}${timing}"
            fi
        elif [[ "$line" =~ ^(ok|not\ ok)\ [0-9]+\ (.+)$ ]]; then
            # Fallback for lines without timing
            local status="${BASH_REMATCH[1]}"
            local test_name="${BASH_REMATCH[2]}"
            if [[ "$status" == "ok" ]]; then
                _LIVE_NUM=$(( _LIVE_NUM + 1 ))
                _LIVE_PASS=$(( _LIVE_PASS + 1 ))
                row "  ${C_Dim}${_LIVE_NUM}.${C_Reset} ${label}${test_name} ${C_Green}${PASS_SYMBOL}${C_Reset}"
            else
                _LIVE_NUM=$(( _LIVE_NUM + 1 ))
                _LIVE_FAIL=$(( _LIVE_FAIL + 1 ))
                row "  ${C_Dim}${_LIVE_NUM}.${C_Reset} ${label}${test_name} ${C_Red}${FAIL_SYMBOL}${C_Reset}"
            fi
        elif [[ "$line" =~ ^#\ skip ]]; then
            # Skipped test diagnostic line — captured but not displayed inline
            _LIVE_NUM=$(( _LIVE_NUM + 1 ))
            _LIVE_SKIP=$(( _LIVE_SKIP + 1 ))
            _SKIPPED+=("$line")
        fi
        _TAP_OUTPUT+="$line"$'\n'
    done < <(bats --tap --timing "$bats_file" "${_EXTRA_ARGS[@]}" 2>&1) || true
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

# ── Main ─────────────────────────────────────────────────────────────────────
_TAP_OUTPUT=""
_LIVE_NUM=0 _LIVE_PASS=0 _LIVE_FAIL=0 _LIVE_SKIP=0
_SKIPPED=()
GRAND_PASS=0 GRAND_FAIL=0 GRAND_SKIP=0

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
    bf_rel="${bf#"$REPO_ROOT"/}"
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

    # Collapsed sections: header only — detail is shown in the live stream above
    (( GRAND_PASS += local_pass ))
    (( GRAND_FAIL += local_total - local_pass ))
    continue
done

# ── Run Python tests via pytest ──────────────────────────────────────────────
_PY_EXIT=0
if [[ "${_MODE:-}" != "fast" ]]; then
    row_empty
    section_header "Python Tests (pytest)" "..." "..."

    _PY_MARKERS=""
    case "${_MODE:-}" in
        all)   ;;
        *)     _PY_MARKERS="-m not bats_integration" ;;
    esac

    cd "$REPO_ROOT" || exit 1

    # Clear Python bytecode caches so tests always run against latest code.
    # Stale .pyc files cause intermittent "reimported module used old code"
    # failures when source files change between test runs.
    echo "  ${C_Dim}Clearing __pycache__...${C_Reset}" >&2
    find "$REPO_ROOT" -type d -name __pycache__ -exec rm -rf {} + 2>/dev/null || true
    find "$REPO_ROOT" -name "*.pyc" -delete 2>/dev/null || true

    # Prefer the project venv when available.
    _PYTHON="python3"
    if [[ -f "$REPO_ROOT/.venv/bin/python" ]]; then
        _PYTHON="$REPO_ROOT/.venv/bin/python"
    fi

    $_PYTHON -m pytest tests/ -v --tb=short ${_PY_MARKERS:+"$_PY_MARKERS"} \
        --ignore=tests/test_bats_bridge.py 2>&1 || _PY_EXIT=$?
fi

# ── Summary ──────────────────────────────────────────────────────────────────
border_mid
grand_total=$(( GRAND_PASS + GRAND_FAIL ))
grand_skipped=${GRAND_SKIP:-0}

# Compute total duration from tap timing data
total_duration_s=0
for (( i = 0; i < total; i++ )); do
    tname="${T_NAME[$i]}"
    # Extract timing from name if present (appended by bats --timing)
    if [[ "$tname" =~ ^(.+)\ in\ ([0-9.]+)(sec|ms)$ ]]; then
        val="${BASH_REMATCH[2]}"
        unit="${BASH_REMATCH[3]}"
        if [[ "$unit" == "sec" ]]; then
            total_duration_s=$(echo "$total_duration_s + $val" | bc 2>/dev/null || echo "$total_duration_s")
        else
            total_duration_s=$(echo "$total_duration_s + $val / 1000" | bc 2>/dev/null || echo "$total_duration_s")
        fi
    fi
done

if (( GRAND_FAIL == 0 && _PY_EXIT == 0 )); then
    _msg="${C_BoldGreen}ALL ${grand_total} TESTS PASSED ${PASS_SYMBOL}${C_Reset}"
    [[ "$grand_skipped" -gt 0 ]] && _msg+="  ${C_Dim}(${grand_skipped} skipped)${C_Reset}"
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
    if [[ "$grand_skipped" -gt 0 ]]; then
        _summary+="  ${C_Dim}|${C_Reset}  ${C_Yellow}${grand_skipped} skipped${C_Reset}"
    fi
    [[ "$_PY_EXIT" != "0" ]] && _summary+="  ${C_Dim}|${C_Reset}  ${C_Red}Python tests FAILED${C_Reset}"
    row "  $_summary"

    # Show failing test details with diagnostics
    if (( GRAND_FAIL > 0 )); then
        row_empty
        row "  ${C_BoldRed}Failed Tests:${C_Reset}"
        for (( i = 0; i < total; i++ )); do
            if [[ "${T_STATUS[$i]}" != "ok" ]]; then
                row "  ${C_Red}${FAIL_SYMBOL}${C_Reset} ${C_Bold}${T_NAME[$i]}${C_Reset}"
                if [[ -n "${T_DIAG[$i]:-}" ]]; then
                    while IFS= read -r dline; do
                        [[ -z "$dline" ]] && continue
                        # Strip ANSI codes for diagnostic lines
                        dline_clean="${dline//$'\033'[\[0-9;]*m/}"
                        row "    ${C_Dim}${dline_clean}${C_Reset}"
                    done <<< "${T_DIAG[$i]}"
                fi
            fi
        done
    fi

    # Show skipped test details
    if [[ "$grand_skipped" -gt 0 ]]; then
        row_empty
        row "  ${C_Yellow}Skipped Tests:${C_Reset}"
        for sk in "${_SKIPPED[@]}"; do
            # Extract test name from "# skip (reason) test_name"
            sk_clean="${sk#\# skip (*) }"
            sk_clean="${sk_clean#\# skip }"
            row "  ${C_Yellow}⊘${C_Reset} ${C_Dim}${sk_clean}${C_Reset}"
        done
    fi
fi

# Duration summary
row_empty
if command -v bc &>/dev/null && (( total > 0 )); then
    total_duration_s=$(printf "%.0f" "$total_duration_s" 2>/dev/null || echo "$total")
    row "  ${C_Dim}Duration: ${total_duration_s}s for ${grand_total} tests${C_Reset}"
else
    row "  ${C_Dim}Duration: ${grand_total} tests executed${C_Reset}"
fi

# Duration anomaly detection (if tac-durations.json exists)
_dur_file="$REPO_ROOT/.pytest_cache/tac-durations.json"
if [[ -f "$_dur_file" ]]; then
    anomalies=$(python3 -c "
import json, sys
try:
    d = json.load(open('$_dur_file'))
except: sys.exit(0)
warnings = []
for key, times in d.items():
    if len(times) < 2:
        continue
    last = times[-1]
    median = sorted(times)[len(times)//2]
    if median > 0 and last > median * 2 and last > 0.5:
        warnings.append((key, last, median, last/median))
if warnings:
    # Show top 3 anomalies
    warnings.sort(key=lambda x: -x[3])
    for key, last, median, ratio in warnings[:3]:
        short = key.split('::')[-1][:80]
        print(f'  ⚠ {short}  took {last:.1f}s ({ratio:.1f}× median {median:.1f}s)')
" 2>/dev/null)
    if [[ -n "$anomalies" ]]; then
        row "  ${C_Yellow}Duration Anomalies:${C_Reset}"
        echo "$anomalies" | while IFS= read -r line; do
            row "  ${C_Yellow}${line}${C_Reset}"
        done
    fi
fi

border_bot

exit_code=0
(( GRAND_FAIL > 0 )) && exit_code=1
(( _PY_EXIT != 0 )) && exit_code=1
exit $exit_code
# end of file

# end of file marker
