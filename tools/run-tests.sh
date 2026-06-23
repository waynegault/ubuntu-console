#!/usr/bin/env bash
# shellcheck shell=bash
# ==============================================================================
# run-tests.sh — Tactical Console Unit Test Runner
# ==============================================================================
# Runs all unit tests via pytest (which bridges BATS through test_bats_bridge.py).
# Usage:
#   tools/run-tests.sh                    # all unit & fast tests (default)
#   tools/run-tests.sh --all              # everything including LLM/integration
#   tools/run-tests.sh --llm              # with LLM-dependent tests
#   tools/run-tests.sh --integration      # with integration tests
#   tools/run-tests.sh --fast             # fast static-analysis tests only
#   tools/run-tests.sh -- --filter "bash" # pass extra args to pytest
# ==============================================================================
# Module Version: 2
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Parse flags
_MODE=""
_EXTRA_ARGS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --all)      _MODE="all";      shift ;;
        --llm)      _MODE="llm";      shift ;;
        --integration) _MODE="integration"; shift ;;
        --fast)     _MODE="fast";     shift ;;
        --)         shift; _EXTRA_ARGS+=("$@"); break ;;
        *)          _EXTRA_ARGS+=("$1"); shift ;;
    esac
done

# Select pytest markers based on mode
case "${_MODE:-}" in
    all)
        PYTEST_ARGS=()
        DESC="ALL TESTS"
        ;;
    llm)
        PYTEST_ARGS=(-m "bats_llm or not bats_llm")
        DESC="with LLM tests"
        ;;
    integration)
        PYTEST_ARGS=(-m "bats_integration or not bats_integration")
        DESC="with integration tests"
        ;;
    fast)
        PYTEST_ARGS=(-m "bats_fast")
        DESC="fast static-analysis only"
        ;;
    *)
        PYTEST_ARGS=(-m "not bats_llm and not bats_integration")
        DESC="unit & fast tests"
        ;;
esac

# ── Colours ──────────────────────────────────────────────────────────────────
C_Reset=$'\e[0m'
C_Green=$'\e[32m'
C_Red=$'\e[31m'
C_Cyan=$'\e[36m'
C_Dim=$'\e[2m'
C_Bold=$'\e[1m'
C_Border=$'\e[38;5;245m'
W=80

border_top()    { printf '%s+%s+%s\n' "$C_Border" "$(printf '%*s' "$((W-2))" '' | tr ' ' '-')" "$C_Reset"; }
border_bot()    { printf '%s+%s+%s\n' "$C_Border" "$(printf '%*s' "$((W-2))" '' | tr ' ' '-')" "$C_Reset"; }
row() {
    local text="$1"
    local plain; plain=$(printf '%s' "$text" | sed 's/\x1b\[[0-9;]*m//g')
    local pad=$(( W - 2 - ${#plain} )); (( pad < 0 )) && pad=0
    printf '%s| %s%*s |%s\n' "$C_Border" "$text" "$((pad - 1))" "" "$C_Reset"
}

# ── Run Tests ────────────────────────────────────────────────────────────────
border_top
row "${C_Bold}  TACTICAL CONSOLE - Test Suite${C_Reset}"
row "${C_Dim}  $(date '+%Y-%m-%d %H:%M:%S')   mode: ${DESC}${C_Reset}"
printf '%s|%s|%s\n' "$C_Border" "$(printf '%*s' "$((W-2))" '' | tr ' ' '-')" "$C_Reset"

cd "$REPO_ROOT"
python3 -m pytest tests/ "${PYTEST_ARGS[@]}" -v --tb=short "${_EXTRA_ARGS[@]}"
PY_EXIT=$?

border_bot
exit $PY_EXIT
# end of file
