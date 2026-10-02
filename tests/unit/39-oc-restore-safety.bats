#!/usr/bin/env bats
# ==============================================================================
# Unit — oc restore: a FAILED swap must not delete the only pre-restore copy
# ==============================================================================
# WHY THIS EXISTS (AUDIT-2026-10-02, card cb501472): oc-restore's workspace and
# agents blocks renamed the current directory aside to <dir>.bak, moved the
# staged copy into place, and then unconditionally `rm -rf`'d the .bak — but the
# safety check in between only ever guarded that CLEANUP (it tested whether the
# path was under /home, /tmp or /dev/shm).  It never checked whether the restore
# `mv` had SUCCEEDED.  If that move failed, the original was sitting in .bak, the
# path test was false for a perfectly valid path, and the `else` deleted the only
# surviving copy: the comment above the block claimed the exact opposite ("If the
# move fails, the .bak can be manually restored").
#
# These cases seed that failure and assert the PROPERTY — the original bytes are
# still on disk and the command reports failure — because "the row mentions
# FAILED" is not the thing that matters.
#
# HERMETIC: HOME, OC_ROOT and the snapshot dir are sandboxed, the prompt is fed a
# `y` on stdin, and the gateway stop / pkill are stubbed to no-ops so no case can
# touch the real gateway or a real openclaw process.
# ==============================================================================

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    export REPO_ROOT
    SANDBOX="$(mktemp -d)"
    export SANDBOX
    export HOME="$SANDBOX/home"
    export TAC_TEST_TMPDIR="$SANDBOX/tac"
    export TAC_CACHE_DIR="$SANDBOX/cache"
    mkdir -p "$HOME" "$TAC_TEST_TMPDIR" "$TAC_CACHE_DIR"

    # shellcheck source=env.sh
    source "$REPO_ROOT/env.sh"

    # Stubs AFTER the source: a loader re-defines the real functions on top of
    # anything stubbed earlier.  __tac_info is flattened so assertions can match
    # the status words without colour codes.
    __tac_info() { printf 'INFO %s\n' "$*"; }
    __tac_line() { printf 'LINE %s\n' "$*"; }

    # The restore path calls these for real before it swaps anything; stub them or
    # a test would stop the live gateway and reap live openclaw processes.
    openclaw() { return 0; }
    pkill() { return 0; }

    # Sandbox every path the swap touches, AFTER the source so 01-constants.sh
    # cannot win.
    export OC_ROOT="$SANDBOX/.openclaw"
    export OC_WORKSPACE="$OC_ROOT/workspace"
    export OC_AGENTS="$OC_ROOT/agents"
    export OC_BACKUPS="$OC_ROOT/backups"
    export LLM_REGISTRY="$HOME/.llm/models.conf"
    mkdir -p "$OC_WORKSPACE" "$OC_AGENTS" "$OC_BACKUPS"
    printf 'ORIGINAL\n' > "$OC_WORKSPACE/original.txt"
    printf 'ORIGINAL-AGENTS\n' > "$OC_AGENTS/original.txt"

    # mv stub: fail ONLY the staging → target move whose destination is
    # FAIL_MOVE_DEST, so the rename-aside and the roll-back still run the real mv
    # — which is the half that has to work for the original to survive.  All mv
    # calls on this path have two operands.
    FAIL_MOVE_DEST=""
    mv() {
        if [[ -n "$FAIL_MOVE_DEST" && "$2" == "$FAIL_MOVE_DEST" && "$1" == *"/oc-restore-"* ]]
        then
            return 1
        fi
        command mv "$@"
    }
}

teardown() {
    FAIL_MOVE_DEST=""
    cd /
    rm -rf "$SANDBOX"
}

# _snapshot <archive-name> <relative-dir> — build a one-entry snapshot archive so
# oc-restore's own selection, extraction and validation all run for real.
_snapshot() {
    local name="$1" rel="$2"
    local stage="$SANDBOX/stage-snapshot"
    rm -rf "$stage"
    mkdir -p "$stage/$rel"
    printf 'RESTORED\n' > "$stage/$rel/new.txt"
    ( cd "$stage" && zip -qr "$OC_BACKUPS/$name" "$rel" )
}

@test "oc-restore: a failed workspace move keeps the original and exits non-zero" {
    _snapshot snapshot_ws.zip .openclaw/workspace
    FAIL_MOVE_DEST="$OC_WORKSPACE"

    # `<<< y` answers the destructive-confirmation prompt without a tty.
    run oc-restore <<< "y"

    [ "$status" -ne 0 ]
    [[ "$output" == *"FAILED"* ]]
    # The property, not the row: the original bytes are still at the target,
    # and the .bak was CONSUMED by the roll-back rather than deleted.
    run cat "$OC_WORKSPACE/original.txt"
    [ "$output" = "ORIGINAL" ]
    [ ! -e "$OC_WORKSPACE/new.txt" ]
    [ ! -e "$OC_WORKSPACE.bak" ]
}

@test "oc-restore: a failed agents move keeps the original and exits non-zero" {
    # Same defect, second block — a fix applied to workspace only would pass the
    # case above and still lose the agents directory.
    _snapshot snapshot_ag.zip .openclaw/agents
    FAIL_MOVE_DEST="$OC_AGENTS"

    run oc-restore <<< "y"

    [ "$status" -ne 0 ]
    [[ "$output" == *"FAILED"* ]]
    run cat "$OC_AGENTS/original.txt"
    [ "$output" = "ORIGINAL-AGENTS" ]
    [ ! -e "$OC_AGENTS/new.txt" ]
    [ ! -e "$OC_AGENTS.bak" ]
}

@test "oc-restore: a successful swap replaces the directory and leaves no .bak" {
    # The other direction: a guard that turned the working restore into a failure
    # would be a different bug, so the healthy path is asserted too.
    _snapshot snapshot_ok.zip .openclaw/workspace

    run oc-restore <<< "y"

    [ "$status" -eq 0 ]
    [[ "$output" == *"COMPLETE"* ]]
    run cat "$OC_WORKSPACE/new.txt"
    [ "$output" = "RESTORED" ]
    [ ! -e "$OC_WORKSPACE/original.txt" ]
    [ ! -e "$OC_WORKSPACE.bak" ]
}

@test "swap: an empty replacement is refused and the original rolled back" {
    # `rm -rf .bak` is only safe once the replacement has ARRIVED.  An empty
    # directory is not a replacement: deleting the aside copy for it loses the
    # original just as surely as a failed move does.
    mkdir -p "$SANDBOX/empty-stage/workspace"

    run __oc_restore_dir "$OC_WORKSPACE" "$SANDBOX/empty-stage/workspace" "workspace"

    [ "$status" -ne 0 ]
    [[ "$output" == *"empty"* ]]
    run cat "$OC_WORKSPACE/original.txt"
    [ "$output" = "ORIGINAL" ]
    [ ! -e "$OC_WORKSPACE.bak" ]
}

@test "swap: an unsafe destination is refused before anything is moved" {
    # The old check ran only AFTER the swap, so an unsafe path had already been
    # destroyed by the time it was refused.  It now runs first.
    mkdir -p "$SANDBOX/stage-unsafe/workspace"
    printf 'RESTORED\n' > "$SANDBOX/stage-unsafe/workspace/new.txt"

    run __oc_restore_dir "/" "$SANDBOX/stage-unsafe/workspace" "workspace"

    [ "$status" -ne 0 ]
    [[ "$output" == *"REFUSED"* ]]
    # The staged copy was not consumed by a half-done swap.
    [ -f "$SANDBOX/stage-unsafe/workspace/new.txt" ]
}

@test "swap: a pre-existing .bak is refused, leaving both copies alone" {
    # A leftover .bak is already the only copy of a previous original; renaming
    # the current directory onto it (mv into an existing dir) and then
    # `rm -rf`ing it would destroy both.  Refuse instead.
    mkdir -p "$SANDBOX/stage-bak/workspace"
    printf 'RESTORED\n' > "$SANDBOX/stage-bak/workspace/new.txt"
    mkdir -p "$OC_WORKSPACE.bak"
    printf 'OLD-BAK\n' > "$OC_WORKSPACE.bak/keep.txt"

    run __oc_restore_dir "$OC_WORKSPACE" "$SANDBOX/stage-bak/workspace" "workspace"

    [ "$status" -ne 0 ]
    [[ "$output" == *"REFUSED"* ]]
    run cat "$OC_WORKSPACE/original.txt"
    [ "$output" = "ORIGINAL" ]
    run cat "$OC_WORKSPACE.bak/keep.txt"
    [ "$output" = "OLD-BAK" ]
}

# end of file
