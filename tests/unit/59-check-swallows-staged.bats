#!/usr/bin/env bats
# ==============================================================================
# Unit — tools/check-swallows-staged.sh: the swallow ratchet, scoped to the STAGED
# set the commit actually carries.
# ==============================================================================
# WHY THIS EXISTS.  tools/hooks/pre-commit runs this tool, so its verdict is what
# refuses an author's OWN commit for a swallow they just added — while a PEER's
# in-flight file must NOT refuse it.  That is the failure it was written to remove:
# measured 2026-10-14, a peer's bin/openclaw-update-capture-prune.sh (13 unclassified
# sites, no baseline row) refused EVERY pusher, because the check then lived only in
# the whole-tree lint that pre-push runs.
#
# The suite drives a throwaway git repo through the tool's own documented test seam,
# `--repo DIR` (its Usage block), so this tree is never touched, and each case's
# expected value comes from the tool's header CONTRACT rather than from its current
# output:
#
#   Exit 0 = no staged file carries a NEW unclassified swallow.
#   Exit 1 = at least one staged file does (named with its count and its baseline).
#   Exit 2 = the check could not run (not a git repository, or the scanner could not run).
#
# FALSIFICATION.  Case 2 is the regression net for the fix that shipped with this
# suite (Module Version 2): the tool printed `is_staged: bad array subscript` on
# stderr whenever the scanner reported NO unclassified site at all, because an empty
# `measured` set still makes `printf '%s\n' "${!measured[@]}"` emit ONE blank line, so
# the verdict loop then ran once with an empty `rel`.  Against v1 that case fails.
# ==============================================================================

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    export REPO_ROOT
    TOOL="$REPO_ROOT/tools/check-swallows-staged.sh"
    export TOOL
    SANDBOX="$(mktemp -d)"
    export SANDBOX

    # The scanner's corpus is a CONFIGURED set of directories (contracts_check.py:
    # scripts/*.sh, bin/*, tools/*.sh, tools/hooks/*, tools/qwen-hooks/*, nas/**/*.sh),
    # so the fixture carries every one of them: a missing group is only a WARNING, and
    # each case should exercise the VERDICT, not the missing-group chatter.
    mkdir -p "$SANDBOX/scripts" "$SANDBOX/bin" "$SANDBOX/tools/hooks" \
        "$SANDBOX/tools/qwen-hooks" "$SANDBOX/nas"
    : > "$SANDBOX/tools/contracts-swallows-baseline.tsv"
    git -C "$SANDBOX" init --quiet
    git -C "$SANDBOX" -c user.email=t@example.invalid -c user.name=test \
        commit --quiet --allow-empty -m base
}

teardown() {
    rm -rf "$SANDBOX"
}

# Run the tool with stderr MERGED into stdout: its FAIL lines are written to stderr,
# and case 2 also asserts the ABSENCE of a shell error there.
_tool() {
    bash -c '"$1" --repo "$2" 2>&1' _ "$TOOL" "$SANDBOX"
}

_git() {
    git -C "$SANDBOX" -c user.email=t@example.invalid -c user.name=test "$@"
}

@test "swallows-staged: a staged swallow with no baseline row is refused" {
    printf '#!/usr/bin/env bash\nrm -f /tmp/throwaway 2>/dev/null\n' > "$SANDBOX/scripts/new.sh"
    _git add scripts/new.sh

    run _tool
    [ "$status" -eq 1 ]
    [[ "$output" == *"scripts/new.sh"* ]]
    [[ "$output" == *"no baseline row"* ]]
}

@test "swallows-staged: a marked site is accepted, and the clean path raises no shell error" {
    # The v2 regression net: a corpus with no unclassified site at all is the ordinary
    # clean case, and it used to print a bash error (see FALSIFICATION above).
    printf '#!/usr/bin/env bash\n# swallow-ok: best-effort probe by design\nrm -f /tmp/x 2>/dev/null\n' \
        > "$SANDBOX/scripts/marked.sh"
    _git add scripts/marked.sh

    run _tool
    [ "$status" -eq 0 ]
    [[ "$output" != *"bad array subscript"* ]]
    [[ "$output" == *"OK"* ]]
}

@test "swallows-staged: a count equal to the file's baseline row is accepted" {
    printf 'unclassified\tscripts/known.sh\t1\n' > "$SANDBOX/tools/contracts-swallows-baseline.tsv"
    printf '#!/usr/bin/env bash\nrm -f /tmp/x 2>/dev/null\n' > "$SANDBOX/scripts/known.sh"
    _git add scripts/known.sh

    run _tool
    [ "$status" -eq 0 ]
}

@test "swallows-staged: a count ABOVE the file's baseline row is refused, naming both" {
    printf 'unclassified\tscripts/grown.sh\t1\n' > "$SANDBOX/tools/contracts-swallows-baseline.tsv"
    printf '#!/usr/bin/env bash\nrm -f /tmp/x 2>/dev/null\nrm -f /tmp/y 2>/dev/null\n' \
        > "$SANDBOX/scripts/grown.sh"
    _git add scripts/grown.sh

    run _tool
    [ "$status" -eq 1 ]
    [[ "$output" == *"against a baseline of 1"* ]]
}

@test "swallows-staged: a corpus file that is NOT staged cannot refuse the commit" {
    # The entire point of the staged scope (the tool's own NOT-A-WHOLE-TREE-VERDICT
    # section): a peer session's in-flight file lives in this shared tree.
    printf '#!/usr/bin/env bash\nrm -f /tmp/peer 2>/dev/null\n' > "$SANDBOX/scripts/peer.sh"
    _git add scripts/peer.sh
    _git commit --quiet -m peer
    printf '#!/usr/bin/env bash\n# no swallow here\necho ok\n' > "$SANDBOX/scripts/mine.sh"
    _git add scripts/mine.sh

    run _tool
    [ "$status" -eq 0 ]
    [[ "$output" != *"scripts/peer.sh"* ]]
}

@test "swallows-staged: no staged files is not a failure" {
    run _tool
    [ "$status" -eq 0 ]
    [[ "$output" == *"no staged files"* ]]
}

@test "swallows-staged: a directory that is not a git repository cannot be scoped" {
    not_a_repo="$(mktemp -d)"
    run bash -c '"$1" --repo "$2" 2>&1' _ "$TOOL" "$not_a_repo"
    rm -rf "$not_a_repo"

    [ "$status" -eq 2 ]
    [[ "$output" == *"not a git repository"* ]]
}

# end of file
