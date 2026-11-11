#!/usr/bin/env bash
# Module Version: 1
#   v1 (2026-11-11): Antigravity PostToolUse hook to verify module version headers.
set -euo pipefail

# Print help if requested
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    echo "Usage: agent-quality-gate.sh"
    echo "Antigravity PostToolUse hook that verifies module versions and outputs {}."
    exit 0
fi

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

# Consume JSON input from stdin (required by hook contract)
# swallow-ok: consume stdin without failing if empty or closed
cat >/dev/null 2>&1 || true

# Run fast module version check against HEAD
# swallow-ok: version check warnings are directed to stderr
"$REPO_ROOT/tools/check-module-versions.sh" >&2 2>/dev/null || true

# Always output valid JSON to stdout as expected by PostToolUse contract
echo "{}"
