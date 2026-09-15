#!/usr/bin/env bash
# shellcheck shell=bash
# ==============================================================================
# 16. CHECK-OC-AGENT-USE — Agent usage regression checker
# ==============================================================================
# AI INSTRUCTION: Regression checker. It reads $TAC_CACHE_DIR (default /dev/shm);
# tests/unit/09-check-agent-use.bats points that at a fixture dir so it runs
# hermetically in CI. Run it on a live machine for a real check.
# Module Version: 3
# @modular-section: check-oc-agent-use
# @depends: none (standalone; reads TAC_CACHE_DIR files)
# @exports: (none — standalone script, not sourced)
set -euo pipefail

# Simple regression check: verify aggregated totals in oc_agent_stats.tsv
# match the sum of session totalTokens in oc_sessions.json

TAC_CACHE_DIR=${TAC_CACHE_DIR:-/dev/shm}
SESSION_FILE="$TAC_CACHE_DIR/oc_sessions.json"
STATS_FILE="$TAC_CACHE_DIR/oc_agent_stats.tsv"

if [[ ! -f "$SESSION_FILE" ]]; then
    echo "ERROR: sessions file not found: $SESSION_FILE" >&2
    exit 2
fi
if [[ ! -f "$STATS_FILE" ]]; then
    echo "ERROR: stats file not found: $STATS_FILE" >&2
    exit 2
fi

sessions_total=$(jq '(.sessions // []) | map(.totalTokens // 0) | add // 0' "$SESSION_FILE" 2>&1) || {
    # Without this the failure surfaced as "integer expression expected" from the
    # comparison below, naming neither the file nor the cause.
    echo "ERROR: could not read $SESSION_FILE: $sessions_total" >&2
    exit 2
}
stats_total=$(awk '{s += ($4+0)} END {print (s+0)}' "$STATS_FILE")

echo "sessions_total=$sessions_total"
echo "stats_total=$stats_total"

if [[ "$sessions_total" -ne "$stats_total" ]]; then
    echo "MISMATCH: aggregated stats do not equal sessions total" >&2
    exit 1
fi

echo "OK: aggregated stats match sessions total"
exit 0
# end of file
