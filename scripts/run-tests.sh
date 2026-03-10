#!/usr/bin/env bash
# ==============================================================================
# run-tests.sh — Pretty-printed BATS test runner for tactical-console
# ==============================================================================
# Wraps `bats --tap` output and regroups it into labelled sections with
# box-drawn headers matching the tactical-console UI aesthetic.
#
# Usage:
#   scripts/run-tests.sh                   # run all tests
#   scripts/run-tests.sh --filter "calc"   # pass extra args to bats
#
# AI INSTRUCTION: Increment version on significant changes.
# shellcheck disable=SC2034,SC2317
VERSION="1.0"

# NOTE: set -e intentionally omitted — bare (( )) post-increment operators
# (e.g. ((grand_fail++)) when value is 0) return exit code 1, which would
# cause premature script termination under errexit.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BATS_FILE="$REPO_ROOT/tests/tactical-console.bats"

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

W=80  # box width

# ── Drawing helpers ──────────────────────────────────────────────────────────
border_top()    { printf '%s╔%s╗%s\n' "$C_Border" "$(printf '═%.0s' $(seq 1 $((W-2))))" "$C_Reset"; }
border_mid()    { printf '%s╟%s╢%s\n' "$C_Border" "$(printf '─%.0s' $(seq 1 $((W-2))))" "$C_Reset"; }
border_bot()    { printf '%s╚%s╝%s\n' "$C_Border" "$(printf '═%.0s' $(seq 1 $((W-2))))" "$C_Reset"; }
row() {
    local text="$1"
    # Strip ANSI to measure visible length
    local plain
    plain=$(printf '%s' "$text" | sed 's/\x1b\[[0-9;]*m//g')
    local pad=$(( W - 2 - ${#plain} ))
    (( pad < 0 )) && pad=0
    printf '%s║%s %s%*s%s║%s\n' "$C_Border" "$C_Reset" "$text" "$((pad - 1))" "" "$C_Border" "$C_Reset"
}
row_empty() { row ""; }

# ── Section header ───────────────────────────────────────────────────────────
section_header() {
    local label="$1" passed="$2" total="$3"
    local colour="$C_BoldGreen"
    local symbol="✓"
    if (( passed < total ))
    then
        colour="$C_BoldRed"
        symbol="✗"
    fi
    border_mid
    row "${C_Bold}${C_Cyan}  ${label}${C_Reset}${C_Dim}  ── ${passed}/${total} ${symbol}${C_Reset}"
    border_mid
}

# ── Section display names keyed by test-name prefix ──────────────────────────
declare -A SECTION_NAMES=(
    ["bash -n"]="1. Syntax — bash -n"
    ["shellcheck"]="2. Static Analysis — ShellCheck"
    ["structure"]="3. Profile Structure"
    ["constants"]="4. Global Constants"
    ["ui"]="5. UI Helper Engine"
    ["cache"]="6. Caching Engine"
    ["port"]="7. Port Utilities"
    ["metrics"]="8. System Metrics"
    ["calc"]="9. Pure Calculations"
    ["quant"]="10. Quant-Label Mapping"
    ["health"]="11. Health Checks"
    ["maintenance"]="12. Maintenance Helpers"
    ["model"]="13. Model Management"
    ["prompt"]="14. Prompt"
    ["alias"]="15. Alias Registration"
    ["fn-avail"]="16. Function Availability"
    ["cross-script"]="17. Cross-Script Consistency"
)

# Ordered list of prefixes (bash associative arrays are unordered)
SECTION_ORDER=(
    "bash -n" "shellcheck" "structure" "constants" "ui"
    "cache" "port" "metrics" "calc" "quant"
    "health" "maintenance" "model" "prompt" "alias"
    "fn-avail" "cross-script"
)

# ── Run BATS and capture TAP output ──────────────────────────────────────────
tap_output=$(bats --tap "$BATS_FILE" "$@" 2>&1) || true

# ── Parse TAP lines into parallel arrays ─────────────────────────────────────
declare -a T_STATUS=()   # "ok" or "not ok"
declare -a T_NAME=()     # full test description
declare -a T_PREFIX=()   # section prefix (before first ':')
declare -a T_DIAG=()     # diagnostic lines (# comments after a failure)

total=0
diag_buf=""
while IFS= read -r line
do
    # TAP plan line
    [[ "$line" =~ ^1\.\.  ]] && continue

    # Diagnostic comment
    if [[ "$line" =~ ^#\  ]]
    then
        diag_buf+="${line}"$'\n'
        continue
    fi

    # Test result line
    if [[ "$line" =~ ^(ok|not\ ok)\ [0-9]+\ (.+)$ ]]
    then
        # Flush previous diag buffer
        if (( total > 0 ))
        then
            T_DIAG[total - 1]="$diag_buf"
        fi
        diag_buf=""

        local_status="${BASH_REMATCH[1]}"
        local_desc="${BASH_REMATCH[2]}"
        # Extract prefix (text before first ':')
        local_prefix="${local_desc%%:*}"

        T_STATUS+=("$local_status")
        T_NAME+=("$local_desc")
        T_PREFIX+=("$local_prefix")
        (( total++ ))
    fi
done <<< "$tap_output"

# Flush final diag
if (( total > 0 ))
then
    T_DIAG[total - 1]="$diag_buf"
fi

# ── Render ───────────────────────────────────────────────────────────────────
# Two-pass: first tally per-section counts, then render with header-first layout.

# Pass 1 — collect per-section counts
declare -A SEC_PASS=()
declare -A SEC_TOTAL=()
declare -a SEC_SEEN_ORDER=()   # maintains first-seen order of prefixes

for (( i = 0; i < total; i++ ))
do
    p="${T_PREFIX[$i]}"
    if [[ -z "${SEC_TOTAL[$p]+x}" ]]
    then
        SEC_TOTAL[$p]=0
        SEC_PASS[$p]=0
        SEC_SEEN_ORDER+=("$p")
    fi
    (( SEC_TOTAL[$p]++ ))
    [[ "${T_STATUS[$i]}" == "ok" ]] && (( SEC_PASS[$p]++ ))
done

grand_pass=0
grand_fail=0

border_top
row "${C_Bold}  TACTICAL CONSOLE — Unit Test Report${C_Reset}"
row "${C_Dim}  $(date '+%Y-%m-%d %H:%M:%S')   bats $(bats --version 2>/dev/null || echo '?')${C_Reset}"

# Pass 2 — render each section
for p in "${SEC_SEEN_ORDER[@]}"
do
    local_pass=${SEC_PASS[$p]}
    local_total=${SEC_TOTAL[$p]}
    display="${SECTION_NAMES[$p]:-$p}"

    # Section header with pass/total
    section_header "$display" "$local_pass" "$local_total"

    # Collapsed sections: fn-avail, cross-script — header only
    if [[ "$p" == "fn-avail" || "$p" == "cross-script" ]]
    then
        (( grand_pass += local_pass ))
        (( grand_fail += local_total - local_pass ))
        continue
    fi

    # Print individual test rows for this section
    for (( i = 0; i < total; i++ ))
    do
        [[ "${T_PREFIX[$i]}" != "$p" ]] && continue

        if [[ "${T_STATUS[$i]}" == "ok" ]]
        then
            (( grand_pass++ ))
            row "  ${C_Green}✓${C_Reset} ${T_NAME[$i]#*: }"
        else
            (( grand_fail++ ))
            row "  ${C_Red}✗${C_Reset} ${T_NAME[$i]#*: }"
            # Print diagnostic lines indented
            if [[ -n "${T_DIAG[$i]:-}" ]]
            then
                while IFS= read -r dline
                do
                    [[ -z "$dline" ]] && continue
                    row "    ${C_Dim}${dline}${C_Reset}"
                done <<< "${T_DIAG[$i]}"
            fi
        fi
    done
done

# ── Summary ──────────────────────────────────────────────────────────────────
border_mid
grand_total=$(( grand_pass + grand_fail ))

if (( grand_fail == 0 ))
then
    row "  ${C_BoldGreen}ALL ${grand_total} TESTS PASSED${C_Reset}"
else
    _summary="${C_BoldRed}${grand_fail} FAILED${C_Reset}"
    _summary+="  ${C_Dim}|${C_Reset}  "
    _summary+="${C_Green}${grand_pass} passed${C_Reset}"
    _summary+="  ${C_Dim}|${C_Reset}  ${grand_total} total"
    row "  $_summary"
fi

border_bot

exit $(( grand_fail > 0 ? 1 : 0 ))
# end of file
