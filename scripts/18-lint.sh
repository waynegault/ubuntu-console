#!/usr/bin/env bash
# shellcheck shell=bash
# AI INSTRUCTION: On ANY change to this file, increment the Module Version below.
# Module Version: 3
# ==============================================================================
# 18-lint.sh — Static analysis for the ubuntu-console repository. (thin wrapper)
# Delegates to tools/lint.sh for canonical lint logic.
# See tools/lint.sh for details: bash -n, shellcheck, unicode, repo-boundary.
# ==============================================================================

# This wrapper must be EXECUTED, not sourced: tools/lint.sh sets strict options
# and calls `exit`, which would terminate (and could wedge) a sourcing shell.
if [[ "${BASH_SOURCE[0]}" != "$0" ]]
then
    echo "18-lint.sh must be executed, not sourced (run: scripts/18-lint.sh)" >&2
    return 1
fi

TOOLS_LINT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../tools" && pwd)/lint.sh"
if [[ -f "$TOOLS_LINT" ]]; then
    # shellcheck disable=SC1090
    source "$TOOLS_LINT"
else
    echo "Error: $TOOLS_LINT not found" >&2
    exit 1
fi

# end of file
