#!/usr/bin/env bash
# shellcheck shell=bash
# AI INSTRUCTION: On ANY change to this file, increment the Module Version below.
# Module Version: 2
# ==============================================================================
# 18-lint.sh — Static analysis for the ubuntu-console repository. (thin wrapper)
# Delegates to tools/lint.sh for canonical lint logic.
# See tools/lint.sh for details: bash -n, shellcheck, unicode, repo-boundary.
# ==============================================================================

TOOLS_LINT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../tools" && pwd)/lint.sh"
if [[ -f "$TOOLS_LINT" ]]; then
    # shellcheck disable=SC1090
    source "$TOOLS_LINT"
else
    echo "Error: $TOOLS_LINT not found" >&2
    exit 1
fi
# end of file

# end of file marker