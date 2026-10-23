#!/usr/bin/env bats
# ==============================================================================
# Unit — a caller's agent-root pin survives sourcing the library
# ==============================================================================
# WHY (T-JARVIS-018, 2026-10-23): `scripts/01-constants.sh` exported OC_AGENTS unconditionally, so
# this shape was destructive:
#
#     export OC_AGENTS=/tmp/tb-agents-$$
#     ... build a fixture ...
#     source ./env.sh          # silently re-points OC_AGENTS at /home/wayne/.openclaw/agents
#     rm -rf "$OC_AGENTS"      # deletes the LIVE tree
#
# That ran for real on 2026-10-23: 579 deletes across all 14 lanes, 303 tracked files, recovered only
# because they were versioned and worktree-deleted (git restore). A sandbox set before a `source` is
# not a sandbox. These cases pin the property that failed — and the incident case is the load-bearing
# one, not the default.
#
# Exit shape under test: OC_AGENTS honours a pre-set value; OC_AGENTS_SANDBOXED marks it;
# OC_AGENTS_CANONICAL always holds the real root so a caller can reach the live tree deliberately.
#
# Hermetic: HOME is a temp dir per test, so OC_ROOT is never the real ~/.openclaw.
setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    FAKE_HOME="$BATS_TEST_TMPDIR/home"
    mkdir -p "$FAKE_HOME"
    FIXTURE="$BATS_TEST_TMPDIR/fixture-agents"
    mkdir -p "$FIXTURE"
}

# source_env <pinned-or-empty> — sources the public loader in a clean subshell and prints the three
# values of interest, one per line, so a case can assert each independently.
source_env() {
    local pinned="${1:-}"
    if [[ -n "$pinned" ]]; then
        OC_AGENTS="$pinned" HOME="$FAKE_HOME" bash -c \
            'source "$1/env.sh" >/dev/null 2>&1; printf "%s\n" "${OC_AGENTS-}" "${OC_AGENTS_CANONICAL-}" "${OC_AGENTS_SANDBOXED:-unset}"' \
            _ "$REPO_ROOT"
    else
        env -u OC_AGENTS -u OC_AGENTS_SANDBOXED HOME="$FAKE_HOME" bash -c \
            'source "$1/env.sh" >/dev/null 2>&1; printf "%s\n" "${OC_AGENTS-}" "${OC_AGENTS_CANONICAL-}" "${OC_AGENTS_SANDBOXED:-unset}"' \
            _ "$REPO_ROOT"
    fi
}

@test "no pin: OC_AGENTS is the canonical root and nothing is flagged" {
    run source_env ""
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "$FAKE_HOME/.openclaw/agents" ]
    [ "${lines[1]}" = "$FAKE_HOME/.openclaw/agents" ]
    [ "${lines[2]}" = "unset" ]
}

# THE LOAD-BEARING CASE. Before v41 this printed the live root on line 1, and the caller's next line
# (`rm -rf "$OC_AGENTS"`) deleted it. Reverting the constants change must fail exactly this test.
@test "a pin made BEFORE the source survives it (the 2026-10-23 incident shape)" {
    run source_env "$FIXTURE"
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "$FIXTURE" ]                       # the sandbox is still the sandbox
    [ "${lines[2]}" = "1" ]                              # and it is not silent
}

@test "OC_AGENTS_CANONICAL still names the live root while a pin is active" {
    run source_env "$FIXTURE"
    [ "$status" -eq 0 ]
    [ "${lines[1]}" = "$FAKE_HOME/.openclaw/agents" ]
    [ "${lines[1]}" != "$FIXTURE" ]
}

@test "a pin that IS the canonical root is not treated as sandboxed (trailing slash included)" {
    run source_env "$FAKE_HOME/.openclaw/agents/"
    [ "$status" -eq 0 ]
    [ "${lines[1]}" = "$FAKE_HOME/.openclaw/agents" ]
    [ "${lines[2]}" = "unset" ]
}
