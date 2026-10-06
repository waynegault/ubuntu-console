#!/usr/bin/env bats
# ==============================================================================
# Unit — the managed-memory index checker, and the fixture that must fail it
# ==============================================================================
# `scripts/qwen-memory-index-check.py` is the re-runnable witness for the local fix to
# the Qwen CLI's memory-index builder (`bin/qwen-memory-index-patch.sh`).  The stock
# indexer truncated every MEMORY.md line at 150 characters, which cut the `](path)`
# link and left a dangling ellipsis — measured 2026-10-01, every index in every
# ~/.qwen store read broken.  The patch is against a FOREIGN bundle, so a CLI or
# companion update reverts it; a fix that cannot be re-verified is not a fix.
#
# The expected values come from the checker's stated CONTRACT — broken means
# (no link / missing target), counted once PER LINE; a trailing ellipsis is context
# for an already-broken line, never a defect on its own (refined 2026-10-06, when the
# 0.25.0 builder's truncateIndexField was found to append '…' to shortened descriptions
# while keeping the link intact).  The mixed fixture is deliberately 3 entries
# with exactly 2 defects: an assertion that only read "bad > 0" would pass on a
# checker that flagged every line, so the count is asserted exactly, and the good
# line is asserted NOT to be blamed.
#
# Hermetic: every index lives under BATS_TEST_TMPDIR.  The real ~/.qwen stores are
# never read, and nothing is ever written to one.
# ==============================================================================

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    CHECK="$REPO_ROOT/scripts/qwen-memory-index-check.py"
    WORK="$BATS_TEST_TMPDIR"
}

@test "memory index check: one missing target and one truncated link are exactly 2 bad, and it exits non-zero" {
    local d="$WORK/mixed"
    mkdir -p "$d/deep"
    : > "$d/good.md"
    {
        printf '%s\n' '- [Good](good.md) — a resolvable link'
        printf '%s\n' '- [Gone](gone.md) — the target does not exist'
        printf '%s\n' '- [Cut](deep/topic-m…'
    } > "$d/MEMORY.md"

    run python3 "$CHECK" "$d/MEMORY.md"

    [ "$status" -eq 1 ]
    [[ "$output" == *"$d/MEMORY.md: entries=3 bad=2"* ]]
    # The good line must NOT be blamed: a checker that flagged every entry would
    # still report a "bad" figure, and only the exact count catches that.
    [[ "$output" != *"line 1:"* ]]
    [[ "$output" == *"line 2:"* ]]
    [[ "$output" == *"line 3:"* ]]
}

@test "memory index check: a clean index exits 0" {
    local d="$WORK/clean"
    mkdir -p "$d"
    : > "$d/keep.md"
    {
        printf '%s\n' '# project memory'
        printf '%s\n' ''
        printf '%s\n' '- [Keep](keep.md) — present and linked'
    } > "$d/MEMORY.md"

    run python3 "$CHECK" "$d/MEMORY.md"

    [ "$status" -eq 0 ]
    [[ "$output" == *"$d/MEMORY.md: entries=1 bad=0"* ]]
}

@test "memory index check: a shortened description ending in an ellipsis is NOT a defect" {
    # The 0.25.0 builder's truncateIndexField appends '…' to a shortened DESCRIPTION while
    # keeping the link intact and resolvable; flagging that fired the guard on upstream's
    # deliberate behaviour (measured 2026-10-06: 133 such lines across three stores, every
    # link resolving).  The expected value comes from the refined contract, not the code.
    local d="$WORK/ellipsis"
    mkdir -p "$d"
    : > "$d/topic.md"
    printf '%s\n' '- [Short](topic.md) — a description that was shortened…' > "$d/MEMORY.md"

    run python3 "$CHECK" "$d/MEMORY.md"

    [ "$status" -eq 0 ]
    [[ "$output" == *"$d/MEMORY.md: entries=1 bad=0"* ]]
}

@test "memory index check: an ellipsis beside a broken link is still reported as context" {
    local d="$WORK/ellipsis-bad"
    mkdir -p "$d"
    printf '%s\n' '- [Gone](gone.md) — a description that was shortened…' > "$d/MEMORY.md"

    run python3 "$CHECK" "$d/MEMORY.md"

    [ "$status" -eq 1 ]
    [[ "$output" == *"$d/MEMORY.md: entries=1 bad=1"* ]]
    [[ "$output" == *"missing target: gone.md"* ]]
    [[ "$output" == *"line ends in an ellipsis (truncated)"* ]]
}

@test "memory index check: it discovers the root store and EVERY project store, including one it never knew" {
    # The store set is discovered, not listed: a project store the script has never
    # heard of must still be checked, or the one that is actually broken is the one
    # the check silently misses.
    local q="$WORK/qwen"
    mkdir -p "$q/memories" "$q/projects/-proj-a/memory" "$q/projects/-proj-b/memory"
    : > "$q/memories/root.md"
    : > "$q/projects/-proj-a/memory/a.md"
    printf '%s\n' '- [Root](root.md) — fine' > "$q/memories/MEMORY.md"
    printf '%s\n' '- [A](a.md) — fine' > "$q/projects/-proj-a/memory/MEMORY.md"
    printf '%s\n' '- [B](missing.md) — target absent' > "$q/projects/-proj-b/memory/MEMORY.md"

    run python3 "$CHECK" --qwen-dir "$q"

    [ "$status" -eq 1 ]
    [[ "$output" == *"$q/memories/MEMORY.md: entries=1 bad=0"* ]]
    [[ "$output" == *"$q/projects/-proj-a/memory/MEMORY.md: entries=1 bad=0"* ]]
    [[ "$output" == *"$q/projects/-proj-b/memory/MEMORY.md: entries=1 bad=1"* ]]
}

@test "memory index check: a named index that does not exist is a cannot-run, never a pass" {
    run python3 "$CHECK" "$WORK/absent/MEMORY.md"

    [ "$status" -eq 2 ]
    [[ "$output" == *"not a readable index file"* ]]
}

@test "memory index check: an empty --qwen-dir is a cannot-run, never a clean tree" {
    run python3 "$CHECK" --qwen-dir "$WORK/no-stores-here"

    [ "$status" -eq 2 ]
    [[ "$output" == *"an empty scan is not a clean tree"* ]]
}
