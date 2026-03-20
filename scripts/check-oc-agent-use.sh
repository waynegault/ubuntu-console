#!/usr/bin/env bash
# shellcheck shell=bash
# AI INSTRUCTION: This script is a small utility used by tests and CI.
# Module Version: 1
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

sessions_total=$(jq '(.sessions // []) | map(.totalTokens // 0) | add // 0' "$SESSION_FILE")
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
