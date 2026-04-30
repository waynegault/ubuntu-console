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
    echo "captured: $name (rc=$rc)"
}

# Keep this list non-destructive and broadly available.
# Use canonical function/command names rather than interactive aliases.
capture "help_h" tactical_help
capture "model_list" model list
capture "model_status_plain" model status --plain
capture "oc_health_plain" oc-health --plain
capture "cleanup_dry_run" cl --dry-run
capture "logtrim" logtrim

# Dashboard render can include dynamic timestamps/metrics; still useful as shape fixture.
capture "dashboard_m" tactical_dashboard

cat <<EOF
Fixture capture complete.
Output directory: $OUT_DIR

Next step:
- Compare these fixtures against PowerShell command outputs after normalization
  (timestamps, cache age, host-specific values).
EOF

# end of file
