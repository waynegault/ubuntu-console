#!/usr/bin/env bats
# ==============================================================================
# Unit Tests — the hooks that judge this tree must be this tree's hooks
# ==============================================================================
# THE INCIDENT (card 3604e43f, 2026-11-06T23:0xZ): core.hooksPath pointed into a
# linked WORKTREE of the same repository. The gates stayed green about a different
# tree — the module-version checker resolved its repo from its own path and refused a
# commit for a bump that was present in the index; the pre-push hook judged that
# worktree's HEAD. The inverse is worse: when the worktree is removed, git skips the
# missing hooks with NO error, so the gates stop running and nothing says so.
#
# Every case builds its own throwaway repository, so this file never touches the real
# tree's config or worktrees.
# ==============================================================================

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
GUARD="$REPO_ROOT/tools/check-hooks-path.sh"

setup() {
    TMP="$(mktemp -d)"
    REPO="$TMP/repo"
    git init -q "$REPO"
    git -C "$REPO" config user.email "t@example.invalid"
    git -C "$REPO" config user.name "Test"
    mkdir -p "$REPO/tools/hooks"
    printf '#!/bin/sh\nexit 0\n' > "$REPO/tools/hooks/pre-commit"
    printf '#!/bin/sh\nexit 0\n' > "$REPO/tools/hooks/pre-push"
    chmod +x "$REPO/tools/hooks/pre-commit" "$REPO/tools/hooks/pre-push"
    printf 'x\n' > "$REPO/file.txt"
    git -C "$REPO" add -A
    git -C "$REPO" commit -qm init
    # CI must be unset here or the guard skips by design.
    unset CI GITHUB_ACTIONS
}

teardown() {
    rm -rf "$TMP"
}

@test "this tree's own tools/hooks is accepted" {
    git -C "$REPO" config core.hooksPath "$REPO/tools/hooks"
    run bash "$GUARD" --repo "$REPO"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK — hooks resolve to this tree's own tools/hooks"* ]]
}

@test "a PEER WORKTREE is refused and named with the revision it would judge" {
    git -C "$REPO" worktree add -q -b peer "$TMP/peer"
    git -C "$REPO" config core.hooksPath "$TMP/peer/tools/hooks"
    run bash "$GUARD" --repo "$REPO"
    [ "$status" -eq 1 ]
    [[ "$output" == *"PEER WORKTREE"* ]]
    [[ "$output" == *"$TMP/peer"* ]]
    # The peer's HEAD, not this tree's — that is the whole point of naming it.
    peer_head="$(git -C "$TMP/peer" rev-parse --short HEAD)"
    [[ "$output" == *"HEAD $peer_head"* ]]
}

@test "an unset core.hooksPath is refused, not treated as the default" {
    run bash "$GUARD" --repo "$REPO"
    [ "$status" -eq 1 ]
    [[ "$output" == *"core.hooksPath is unset"* ]]
    [[ "$output" == *"silent green"* ]]
}

@test "a relative core.hooksPath is refused" {
    git -C "$REPO" config core.hooksPath "tools/hooks"
    run bash "$GUARD" --repo "$REPO"
    [ "$status" -eq 1 ]
    [[ "$output" == *"relative"* ]]
}

@test "a missing or non-executable half of the gate is refused by name" {
    git -C "$REPO" config core.hooksPath "$REPO/tools/hooks"
    chmod -x "$REPO/tools/hooks/pre-push"
    run bash "$GUARD" --repo "$REPO"
    [ "$status" -eq 1 ]
    [[ "$output" == *"'pre-push' is"* ]]
    [[ "$output" == *"skipped silently"* ]]
}

@test "a path outside the repository is refused" {
    mkdir -p "$TMP/elsewhere/hooks"
    cp "$REPO/tools/hooks/pre-commit" "$TMP/elsewhere/hooks/pre-commit"
    cp "$REPO/tools/hooks/pre-push" "$TMP/elsewhere/hooks/pre-push"
    git -C "$REPO" config core.hooksPath "$TMP/elsewhere/hooks"
    run bash "$GUARD" --repo "$REPO"
    [ "$status" -eq 1 ]
    [[ "$output" == *"points outside this repository"* ]]
}

@test "CI is skipped by design rather than going red on something it cannot fix" {
    CI=1 run bash "$GUARD" --repo "$REPO"
    [ "$status" -eq 0 ]
    [[ "$output" == *"skipped — CI runs the gates directly"* ]]
}

@test "a directory that is not a git tree is skipped, not refused" {
    mkdir -p "$TMP/plain"
    run bash "$GUARD" --repo "$TMP/plain"
    [ "$status" -eq 0 ]
    [[ "$output" == *"not a git working tree"* ]]
}

# Criterion (2026-11-07): the pre-push hook materialises HEAD into a throwaway worktree and runs
# the gates there when the tree and the commit disagree. That copy is read, never committed in,
# and its core.hooksPath correctly names the real tree — so the peer-worktree refusal must not
# fire on it. Measured: it did, on the first push made from a tree another lane was editing, so
# every such push was refused. Fails if: the guard refuses a scratch checkout the hook declared,
# OR (case above) stops refusing a real peer when nothing declared it.
@test "the pre-push scratch checkout is skipped, not refused as a peer worktree" {
    git -C "$REPO" worktree add -q -b scratch "$TMP/scratch"
    git -C "$REPO" config core.hooksPath "$REPO/tools/hooks"

    # WITHOUT the marker this is the peer-worktree case: the hook path belongs to another tree.
    run bash "$GUARD" --repo "$TMP/scratch"
    [ "$status" -eq 1 ]
    [[ "$output" == *"PEER WORKTREE"* ]]

    # WITH the marker — the only thing the hook sets — the same layout is a judgement-only copy.
    run env TAC_GATES_SCRATCH_WORKTREE=1 bash "$GUARD" --repo "$TMP/scratch"
    [ "$status" -eq 0 ]
    [[ "$output" == *"scratch checkout, which never commits"* ]]

    # The MARKER is what skips, not the layout: remove it and the unset config is refused again.
    git -C "$REPO" config --unset core.hooksPath
    run bash "$GUARD" --repo "$TMP/scratch"
    [ "$status" -eq 1 ]
    [[ "$output" == *"core.hooksPath is unset"* ]]
    run env TAC_GATES_SCRATCH_WORKTREE=1 bash "$GUARD" --repo "$TMP/scratch"
    [ "$status" -eq 0 ]
    [[ "$output" == *"scratch checkout, which never commits"* ]]
}
