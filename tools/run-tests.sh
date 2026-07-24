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
C_Dim=$'\e[2m'
C_BoldGreen=$'\e[1;32m'
C_BoldRed=$'\e[1;31m'

PASS_SYMBOL=$'\u2713'
FAIL_SYMBOL=$'\u2717'

# ── Drawing helpers (plain, no box) ─────────────────────────────────────────
header()     { printf '\033[1m%s\033[0m\n' "  $*"; }
subheader()  { printf '\033[2m%s\033[0m\n' "  $*"; }
test_line()  { printf '  %s\n' "$*"; }
summary()    { printf '\n\033[1m%s\033[0m\n' "  $*"; }
spacer()     { echo; }

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
                test_line "${C_Dim}${_LIVE_NUM}.${C_Reset} ${label}${test_name} ${C_Green}${PASS_SYMBOL}${C_Reset}${timing}"
            else
                _LIVE_NUM=$(( _LIVE_NUM + 1 ))
                _LIVE_FAIL=$(( _LIVE_FAIL + 1 ))
                test_line "${C_Red}${C_Dim}${_LIVE_NUM}.${C_Reset} ${label}${test_name} ${FAIL_SYMBOL}${C_Reset}${timing}"
            fi
        elif [[ "$line" =~ ^(ok|not\ ok)\ [0-9]+\ (.+)$ ]]; then
            # Fallback for lines without timing
            local status="${BASH_REMATCH[1]}"
            local test_name="${BASH_REMATCH[2]}"
            if [[ "$status" == "ok" ]]; then
                _LIVE_NUM=$(( _LIVE_NUM + 1 ))
                _LIVE_PASS=$(( _LIVE_PASS + 1 ))
                test_line "${C_Dim}${_LIVE_NUM}.${C_Reset} ${label}${test_name} ${C_Green}${PASS_SYMBOL}${C_Reset}"
            else
                _LIVE_NUM=$(( _LIVE_NUM + 1 ))
                _LIVE_FAIL=$(( _LIVE_FAIL + 1 ))
                test_line "${C_Red}${C_Dim}${_LIVE_NUM}.${C_Reset} ${label}${test_name} ${FAIL_SYMBOL}${C_Reset}"
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

header "Test Suite — ${_DESC}"
subheader "$(date '+%Y-%m-%d %H:%M:%S')"
spacer

# ── Part 1: BATS Live Stream ─────────────────────────────────────────────────

mapfile -t BATS_FILES < <(_build_bats_list "${_MODE:-}")

for bf in "${BATS_FILES[@]}"; do
    [[ -f "$bf" ]] || continue
    bf_rel="${bf#"$REPO_ROOT"/}"
    spacer
    subheader "${bf_rel}"
    _run_bats_file "$bf" ""
done

# ── Part 2: Aggregate section counts (no display) ───────────────────────────
_parse_tap "$_TAP_OUTPUT"
total=${#T_STATUS[@]}
GRAND_SKIP=$_LIVE_SKIP

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

_sum_num=0
for p in "${SEC_ORDER[@]}"; do
    local_pass=${SEC_PASS[$p]}
    local_total=${SEC_TOTAL[$p]}
    (( GRAND_PASS += local_pass ))
    (( GRAND_FAIL += local_total - local_pass ))
done

# ── Run Python tests via pytest ──────────────────────────────────────────────
_PY_EXIT=0
if [[ "${_MODE:-}" != "fast" ]]; then
    spacer
    subheader "Python Tests"

    _PY_MARKERS=""
    case "${_MODE:-}" in
        all)   ;;
        *)     _PY_MARKERS="-m not bats_integration" ;;
    esac

    cd "$REPO_ROOT" || exit 1

    # Clear Python bytecode caches so tests always run against latest code.
    find "$REPO_ROOT" -type d -name __pycache__ -exec rm -rf {} + 2>/dev/null || true
    find "$REPO_ROOT" -name "*.pyc" -delete 2>/dev/null || true

    _PYTHON="python3"
    if [[ -f "$REPO_ROOT/.venv/bin/python" ]]; then
        _PYTHON="$REPO_ROOT/.venv/bin/python"
    fi

    # Run pytest with verbose output, then strip header/summary lines
    _PY_OUTPUT=$($_PYTHON -m pytest tests/ --tb=line -v --no-header --durations=5 \
        ${_PY_MARKERS:+"$_PY_MARKERS"} \
        --ignore=tests/test_bats_bridge.py 2>&1) || _PY_EXIT=$?

    # Parse pytest output line by line, numbering continues from BATS count
    _PY_NUM=$total
    _PY_DURATIONS=""
    _in_durations=0
    while IFS= read -r _py_line; do
        [[ -z "$_py_line" ]] && continue
        # Capture slowest test durations section (starts with ===== slowest...)
        if [[ "$_py_line" == *"slowest test durations"* ]]; then
            _in_durations=1
            continue
        fi
        if (( _in_durations )); then
            _PY_DURATIONS+="$_py_line"$'\n'
            # End when we hit another === boundary
            [[ "$_py_line" == ===* ]] && _in_durations=0
            continue
        fi
        # Skip remaining header/footer/warning lines
        case "$_py_line" in
            ===*|--*|collected*|Platform*|plugins*|$'\u26a0'*) continue ;;
        esac
        # pytest verbose line format: "path::TestClass::test_name PASSED"
        if [[ "$_py_line" =~ ^(.*)::([^[]+.*[A-Za-z].*)\ (PASSED|FAILED|ERROR|SKIP|SKIPPED).*$ ]]; then
            _PY_NUM=$(( _PY_NUM + 1 ))
            _status="${BASH_REMATCH[3]}"
            _tname="${BASH_REMATCH[2]}"
            case "$_status" in
                PASSED) _sym="${C_Green}${PASS_SYMBOL}${C_Reset}"; test_line "${C_Dim}${_PY_NUM}.${C_Reset} ${_tname} ${_sym}" ;;
                FAILED|ERROR) _sym="${FAIL_SYMBOL}"; _PY_EXIT=1; test_line "${C_Red}${C_Dim}${_PY_NUM}.${C_Reset} ${_tname} ${_sym}${C_Reset}" ;;
                SKIP|SKIPPED) _sym="⊘"; test_line "${C_Yellow}${C_Dim}${_PY_NUM}.${C_Reset} ${_tname} ${_sym}${C_Reset}" ;;
                *) _sym="?"; test_line "${C_Dim}${_PY_NUM}.${C_Reset} ${_tname} ${_sym}" ;;
            esac
        fi
    done <<< "$_PY_OUTPUT"

    # Count Python tests into grand total
    _py_count=$(( _PY_NUM - total ))
    GRAND_PASS=$(( GRAND_PASS + _py_count ))

    # Show slowest Python test durations (if any)
    if [[ -n "$_PY_DURATIONS" ]]; then
        # Extract tests > 300s (5 min) for highlighting
        _slow_py=""
        while IFS= read -r _dur_line; do
            [[ -z "$_dur_line" ]] && continue
            if [[ "$_dur_line" =~ ^([0-9.]+)s[[:space:]]+(call|setup|teardown)[[:space:]]+(.*) ]]; then
                _dur_secs="${BASH_REMATCH[1]}"
                _dur_test="${BASH_REMATCH[3]}"
                if (( $(echo "$_dur_secs > 300" | bc 2>/dev/null || echo 0) )); then
                    _slow_py+="  ${C_Red}${_dur_test} took ${_dur_secs}s (>5 min)${C_Reset}"$'\n'
                fi
            fi
        done <<< "$_PY_DURATIONS"
        if [[ -n "$_slow_py" ]]; then
            header "Slow Python Tests (>5 min)"
            echo -n "$_slow_py" | while IFS= read -r _s; do test_line "$_s"; done
        fi
    fi
fi

# ── Summary ──────────────────────────────────────────────────────────────────
spacer
grand_total=$(( GRAND_PASS + GRAND_FAIL ))
grand_skipped=${GRAND_SKIP:-0}

# Compute total duration from tap timing data
total_duration_s=0
for (( i = 0; i < total; i++ )); do
    tname="${T_NAME[$i]}"
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
    summary "$_msg"
else
    if (( GRAND_FAIL > 0 )); then
        summary "${C_BoldRed}${GRAND_FAIL} FAILED  ${C_Dim}|${C_Reset}  ${grand_total} total${C_Reset}"
    else
        summary "${C_Green}${GRAND_PASS} passed${C_Reset}"
    fi

    # Show failing test details with diagnostics
    if (( GRAND_FAIL > 0 )); then
        spacer
        header "Failed Tests"
        for (( i = 0; i < total; i++ )); do
            if [[ "${T_STATUS[$i]}" != "ok" ]]; then
                test_line "  ${C_Red}${FAIL_SYMBOL}${C_Reset} ${T_NAME[$i]}"
                if [[ -n "${T_DIAG[$i]:-}" ]]; then
                    while IFS= read -r dline; do
                        [[ -z "$dline" ]] && continue
                        dline_clean="${dline//$'\033'[\[0-9;]*m/}"
                        test_line "    ${C_Dim}${dline_clean}${C_Reset}"
                    done <<< "${T_DIAG[$i]}"
                fi
            fi
        done
    fi

    # Show skipped test details
    if [[ "$grand_skipped" -gt 0 ]]; then
        spacer
        header "Skipped Tests"
        for sk in "${_SKIPPED[@]}"; do
            sk_clean="${sk#\# skip (*) }"
            sk_clean="${sk_clean#\# skip }"
            test_line "  ${C_Yellow}⊘${C_Reset} ${C_Dim}${sk_clean}${C_Reset}"
        done
    fi
fi

# Duration summary
spacer
if command -v bc &>/dev/null && (( total > 0 )); then
    total_duration_s=$(printf "%.0f" "$total_duration_s" 2>/dev/null || echo "$total")
    subheader "Duration: ${total_duration_s}s for ${grand_total} tests"
else
    subheader "Duration: ${grand_total} tests executed"
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
    warnings.sort(key=lambda x: -x[3])
    for key, last, median, ratio in warnings[:3]:
        short = key.split('::')[-1][:80]
        print(f'  {short}  took {last:.1f}s ({ratio:.1f}x median {median:.1f}s)')
" 2>/dev/null)
    if [[ -n "$anomalies" ]]; then
        header "Duration Anomalies"
        echo "$anomalies" | while IFS= read -r line; do
            test_line "  ${C_Yellow}${line}${C_Reset}"
        done
    else
        subheader "No duration anomalies detected"
    fi
fi

exit_code=0
(( GRAND_FAIL > 0 )) && exit_code=1
(( _PY_EXIT != 0 )) && exit_code=1
exit $exit_code
# end of file

# end of file marker
