#!/usr/bin/env bash
# shellcheck shell=bash
# ==============================================================================
# capture-golden-fixtures.sh
# ==============================================================================
# Purpose: Capture baseline command outputs for behavior-parity checks during
#          Bash -> PowerShell translation.
#
# Notes:
# - Non-invasive: read-only command set by default.
# - Uses bin/tac-exec to preserve non-interactive command behavior.
# - Commands that may change system state are intentionally excluded.
#
# Usage:
#   tools/capture-golden-fixtures.sh
#   tools/capture-golden-fixtures.sh --out tests/fixtures/golden
# ==============================================================================

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$REPO_ROOT/tests/fixtures/golden"
TAC_EXEC="$REPO_ROOT/bin/tac-exec"

while [[ $# -gt 0 ]]
do
    case "$1" in
        --out)
            OUT_DIR="$2"
            shift 2
            ;;
        -h|--help)
            cat <<'HELP'
Usage: tools/capture-golden-fixtures.sh [--out <dir>]

Captures selected command outputs to text fixtures for translation parity.
HELP
            exit 0
            ;;
        *)
            echo "Unknown arg: $1" >&2
            exit 1
            ;;
    esac
done

if [[ ! -x "$TAC_EXEC" ]]
then
    echo "Missing executable: $TAC_EXEC" >&2
    exit 1
fi

mkdir -p "$OUT_DIR"

# Failure tally (card 90eee0c2): a capture that failed must not be reported as a
# completed run.  capture() records every command's exit code below, and the run
# ends non-zero with a count when any of them was non-zero.
#
# EXIT 5 IS NOT A FAILURE (Wayne, 2026-10-07).  `oc health` reserves 5 for a STALLED
# gateway — the listener is bound and dark past the post-bind grace, action = ALERT,
# NEVER RESTART (scripts/oc-health-check.py::EXIT_BY_SUMMARY) — so a capture taken on
# such a box was faithful and the run still reddened.  It is counted separately as
# captured-but-STALLED; the fixture's own meta keeps `exit_code: 5`, so the format
# carries the state without being forced.  Only a non-zero, non-5 code is a failure.
CAPTURE_TOTAL=0
CAPTURE_FAILED=0
CAPTURE_STALLED=0

capture() {
    local name="$1"
    shift

    local out_file="$OUT_DIR/${name}.txt"
    local meta_file="$OUT_DIR/${name}.meta"

    {
        echo "command: $*"
        echo "captured_at_utc: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
        echo "host: $(hostname)"
    } > "$meta_file"

    # Capture both output and exit code without aborting entire run.
    set +e
    "$TAC_EXEC" "$@" > "$out_file" 2>&1
    local rc=$?
    set -e

    echo "exit_code: $rc" >> "$meta_file"
    CAPTURE_TOTAL=$((CAPTURE_TOTAL + 1))
    if (( rc == 5 ))
    then
        CAPTURE_STALLED=$((CAPTURE_STALLED + 1))
        echo "captured: $name (rc=$rc) STALLED"
    elif (( rc != 0 ))
    then
        CAPTURE_FAILED=$((CAPTURE_FAILED + 1))
        echo "captured: $name (rc=$rc) FAILED"
    else
        echo "captured: $name (rc=$rc)"
    fi
}

# Keep this list non-destructive and broadly available.
# Use canonical function/command names rather than interactive aliases.
capture "help_h" tactical_help
capture "model_list" model list
capture "model_status_plain" model status --plain
capture "oc_health_plain" oc-health --plain
capture "cleanup_report" cl --report
capture "logtrim" logtrim

# Dashboard render can include dynamic timestamps/metrics; still useful as shape fixture.
capture "dashboard_m" tactical_dashboard

CAPTURE_OK=$((CAPTURE_TOTAL - CAPTURE_FAILED))
if (( CAPTURE_FAILED > 0 ))
then
    SUMMARY="Fixture capture complete: ${CAPTURE_OK}/${CAPTURE_TOTAL} captured, ${CAPTURE_FAILED} FAILED (see above)."
elif (( CAPTURE_STALLED > 0 ))
then
    SUMMARY="Fixture capture complete: ${CAPTURE_OK}/${CAPTURE_TOTAL} captured, 0 FAILED;"
    SUMMARY+=" ${CAPTURE_STALLED} STALLED (rc=5 — gateway bound and dark: alert, do not restart)."
else
    SUMMARY="Fixture capture complete: ${CAPTURE_OK}/${CAPTURE_TOTAL} captured, 0 FAILED."
fi
cat <<EOF
$SUMMARY
Output directory: $OUT_DIR

Next step:
- Compare these fixtures against PowerShell command outputs after normalization
  (timestamps, cache age, host-specific values).
EOF

if (( CAPTURE_FAILED > 0 ))
then
    exit 1
fi

# end of file
