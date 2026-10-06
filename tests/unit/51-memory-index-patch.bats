#!/usr/bin/env bats
# ==============================================================================
# Unit — the memory-index patcher's hunk 3 (byte cap), and the fixture that proves it
# ==============================================================================
# `bin/qwen-memory-index-patch.sh` patches a FOREIGN bundle (the Qwen CLI), so it cannot be
# exercised in CI against the four real copies — there is no bundle there, and a test must
# not reach the ones on this box.  Since v3 the script carries a fixture affordance
# (`QWEN_INDEX_PATCH_CHUNK_DIRS`) for exactly that, and this suite is its consumer.
#
# WHY A BEHAVIOURAL HARNESS AND NOT `node --check`.  The patcher runs `node --check` on each
# bundle it edits, which proves only that the file PARSES.  Hunk 3's whole job is to stop
# dropping index entries silently and to NAME the loss when it still must drop, and the risk
# is a wrong `kept`/count computation — which parses cleanly.  tests/helpers/
# memory-index-assemble-harness.mjs extracts the PATCHED function and asserts its three
# promised behaviours under pinned caps; its expected values come from the patch's stated
# contract (raise the cap to 256000; name the loss and the cap that bit; never cut a line),
# not from the function's output.
#
# Hermetic: the fixture is copied into BATS_TEST_TMPDIR and every run points the patcher at
# that copy.  The real ~/.vscode-server and /mnt/c bundles are never read or written.
#
# 0.25.0 REWROTE assembleIndex (a `kept` Set of entry indexes instead of a newline cut) and
# FIXED the truncator and the path cap upstream, so the fixture is an UPSTREAM-shaped chunk:
# `--check` must read `truncator: upstream` and `bytecap: stock`, and the apply must touch
# ONLY hunk 3.  The fixture's assembleIndex body is byte-identical to the companion's.
# ==============================================================================

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    PATCHER="$REPO_ROOT/bin/qwen-memory-index-patch.sh"
    HARNESS="$REPO_ROOT/tests/helpers/memory-index-assemble-harness.mjs"
    FIXTURE="$REPO_ROOT/tests/fixtures/memory-index-v025-chunk.js"
    WORK="$BATS_TEST_TMPDIR"
    CHUNKS="$WORK/chunks"
    mkdir -p "$CHUNKS"
    cp "$FIXTURE" "$CHUNKS/"
    PATCHED="$CHUNKS/memory-index-v025-chunk.js"
    # node is the patcher's OWN dependency (it runs `node --check` after every edit), and the
    # repo's runtime prepends linuxbrew to PATH (scripts/01-constants.sh).  Do the same here so
    # the suite is full-strength under a runner whose PATH does not already carry it.
    if ! command -v node >/dev/null 2>&1 && [[ -d /home/linuxbrew/.linuxbrew/bin ]]; then
        PATH="/home/linuxbrew/.linuxbrew/bin:$PATH"
        export PATH
    fi
}

@test "index patch: the 0.25.0 fixture reads NEEDS on --check (truncator upstream, bytecap stock)" {
    run env QWEN_INDEX_PATCH_CHUNK_DIRS="$CHUNKS" bash "$PATCHER" --check
    [ "$status" -eq 1 ]
    [[ "$output" == *"truncator: upstream"* ]]
    [[ "$output" == *"bytecap: stock"* ]]
}

@test "index patch: hunk 3 applies to a 0.25.0 fixture, backs it up, and --check then reads ok" {
    command -v node >/dev/null || skip "node is required by the patcher's own syntax check"
    run env QWEN_INDEX_PATCH_CHUNK_DIRS="$CHUNKS" bash "$PATCHER"
    [ "$status" -eq 0 ]
    [[ "$output" == *"patched  bytecap"* ]]
    # The backup must be the PRISTINE stock bytes, byte-identical to the fixture.
    [ -f "$PATCHED.orig" ]
    cmp -s "$PATCHED.orig" "$FIXTURE"
    # The cap is raised and the loss is NAMED (and the stock sentence survives as a prefix).
    grep -qF 'var MAX_INDEX_BYTES=256000;' "$PATCHED"
    grep -qF 'INCOMPLETE: wrote' "$PATCHED"
    grep -qF '> WARNING: MEMORY.md is too large; only part of it was written.' "$PATCHED"
    # hunk 1 must NOT have run: an upstream-shaped copy keeps truncateIndexField, gains no
    # truncateIndexLine, and carries no truncator marker.
    grep -qF 'function truncateIndexField(' "$PATCHED"
    run grep -qF 'function truncateIndexLine(text)' "$PATCHED"
    [ "$status" -ne 0 ]

    run env QWEN_INDEX_PATCH_CHUNK_DIRS="$CHUNKS" bash "$PATCHER" --check
    [ "$status" -eq 0 ]
    [[ "$output" == *"bytecap: applied"* ]]
}

@test "index patch: the patched assembleIndex passes the behavioural harness" {
    command -v node >/dev/null || skip "node is required to run the harness"
    run env QWEN_INDEX_PATCH_CHUNK_DIRS="$CHUNKS" bash "$PATCHER"
    [ "$status" -eq 0 ]
    run node "$HARNESS" "$PATCHED"
    [ "$status" -eq 0 ]
    [[ "$output" == *"(a) ~30 KB index returned whole"* ]]
    [[ "$output" == *"(b1) byte cap"* ]]
    [[ "$output" == *"(c) over-long line"* ]]
    [[ "$output" == *"all assertions passed"* ]]
}

@test "index patch: a second apply is idempotent (nothing changes, --check still ok)" {
    command -v node >/dev/null || skip "node is required by the patcher's own syntax check"
    run env QWEN_INDEX_PATCH_CHUNK_DIRS="$CHUNKS" bash "$PATCHER"
    [ "$status" -eq 0 ]
    local before after
    before="$(sha256sum "$PATCHED" | awk '{print $1}')"
    run env QWEN_INDEX_PATCH_CHUNK_DIRS="$CHUNKS" bash "$PATCHER"
    [ "$status" -eq 0 ]
    after="$(sha256sum "$PATCHED" | awk '{print $1}')"
    [ "$before" = "$after" ]
}

@test "index patch: an unknown assembleIndex shape is refused, not patched blind" {
    # A chunk whose assembleIndex has drifted matches no known stock spelling: the patch must
    # NAME the refusal and leave the bytes UNCHANGED (an all-or-nothing apply).
    local bad="$WORK/bad"
    mkdir -p "$bad"
    sed 's/function assembleIndex(lines){const raw/function assembleIndex(lines){  \/*drift*\/const raw/' \
        "$FIXTURE" > "$bad/chunk-bad.js"
    grep -qF '/*drift*/' "$bad/chunk-bad.js"

    run env QWEN_INDEX_PATCH_CHUNK_DIRS="$bad" bash "$PATCHER"
    [ "$status" -eq 1 ]
    [[ "$output" == *"UNKNOWN shape"* ]]
    # the drift marker still stands: the file was not rewritten
    grep -qF '/*drift*/' "$bad/chunk-bad.js"
}

# end of file
