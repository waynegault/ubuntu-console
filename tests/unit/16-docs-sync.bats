#!/usr/bin/env bats
# ==============================================================================
# Unit Tests — the documented test counts match the tree
# ==============================================================================
# `tools/docs-sync-check.sh` gates the literal count strings in README.md: the grand
# total, the per-directory breakdown, and the per-file phrases.  It is its own CI job,
# but NOTHING in pytest ran it — so a green local run proved nothing about the counts,
# and that coupling is invisible from the test you are writing.  Three drifts were
# committed that way (2026-09-20, 2026-09-21 — one of them because verification steps
# were chained with `;` instead of `&&`, so the failing gate did not stop the commit).
#
# Why a BATS test rather than a Python one: this repo's shell gates are tested here,
# and tests/conftest.py exposes every BATS @test as a pytest test — so this appears in
# `pytest` and in the VS Code Testing panel with no Python shim and no duplicated logic.
# ==============================================================================

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"

@test "tools/docs-sync-check.sh passes: the documented counts match the tree" {
    # Exit 0 with a summary, or 1 naming the exact README string that drifted.  The
    # drift lines ARE the gate's value, so print them on failure rather than letting
    # the assertion fail silently.
    run "$REPO_ROOT/tools/docs-sync-check.sh"
    if [ "$status" -ne 0 ]; then
        printf '%s\n' "$output" >&2
    fi
    [ "$status" -eq 0 ]
}
