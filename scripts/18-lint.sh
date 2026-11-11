#!/usr/bin/env bash
# shellcheck shell=bash
# AI INSTRUCTION: On ANY change to this file, increment the Module Version below.
# Module Version: 4
#   v4 (2026-11-11): the SC1090 disable on the tools/lint.sh source now carries its
#       rationale (inspection 1.12): the path is computed, so shellcheck cannot follow it.
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
    # SC1090: the path is computed from this script's own location, so shellcheck
    # cannot follow it statically; the -f guard above is the existence check.
    # shellcheck disable=SC1090
    source "$TOOLS_LINT"
else
    echo "Error: $TOOLS_LINT not found" >&2
    exit 1
fi

# end of file
