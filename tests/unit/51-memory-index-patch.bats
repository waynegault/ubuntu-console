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
    TITLE_HARNESS="$REPO_ROOT/tests/helpers/memory-index-titlecap-harness.mjs"
    FIXTURE="$REPO_ROOT/tests/fixtures/memory-index-v025-chunk.js"
    # The 0.25.1 shape (2026-10-14): the cap renamed MAX_INDEX_BYTES -> MAX_INDEX_CHARS and
    # assembleIndex split.  Kept in its OWN dir so each --check sees exactly one copy.
    FIXTURE_0251="$REPO_ROOT/tests/fixtures/memory-index-v0251-chunk.js"
    WORK="$BATS_TEST_TMPDIR"
    CHUNKS="$WORK/chunks"
    mkdir -p "$CHUNKS"
    cp "$FIXTURE" "$CHUNKS/"
    PATCHED="$CHUNKS/memory-index-v025-chunk.js"
    CHUNKS_0251="$WORK/chunks-0251"
    mkdir -p "$CHUNKS_0251"
    cp "$FIXTURE_0251" "$CHUNKS_0251/"
    PATCHED_0251="$CHUNKS_0251/memory-index-v0251-chunk.js"
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
    [[ "$output" == *"titlecap: stock"* ]]
    [[ "$output" == *"linecap: stock"* ]]
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
    # Hunk 5 raises the LINE cap, and hunk 4 leaves its marker on the title budget.
    grep -qF 'var MAX_INDEX_LINES=400;' "$PATCHED"
    grep -qF 'LOCAL PATCH 2026-10-11 (qwen-memory-index-titlecap)' "$PATCHED"
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
    [[ "$output" == *"titlecap: applied"* ]]
    [[ "$output" == *"linecap: applied"* ]]
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

@test "index patch: the patched docIndexLine passes the title-budget harness" {
    command -v node >/dev/null || skip "node is required to run the harness"
    run env QWEN_INDEX_PATCH_CHUNK_DIRS="$CHUNKS" bash "$PATCHER"
    [ "$status" -eq 0 ]
    run node "$TITLE_HARNESS" "$PATCHED"
    [ "$status" -eq 0 ]
    [[ "$output" == *"(1) long title + long path"* ]]
    [[ "$output" == *"(3) title budget follows the path"* ]]
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

# ------------------------------------------------------------------------------
# 0.25.1 (2026-10-14): the cap renamed MAX_INDEX_BYTES -> MAX_INDEX_CHARS, and
# assembleIndex split into trimIndexToBudget + upstream's own INDEX_TRUNCATION_NOTICE.
# ------------------------------------------------------------------------------

@test "index patch: the 0.25.1 fixture reads NEEDS on --check (cap renamed, bytecap stock)" {
    # Before this shape was recognised, --check read `bytecap: UNKNOWN` and the apply REFUSED the
    # whole copy ("no known MAX_INDEX_BYTES declaration").  On 0.25.1 the bytecap reads `stock`
    # -- not UNKNOWN -- beside titlecap/linecap `stock`, and the cap is present under its new name.
    run env QWEN_INDEX_PATCH_CHUNK_DIRS="$CHUNKS_0251" bash "$PATCHER" --check
    [ "$status" -eq 1 ]
    [[ "$output" == *"truncator: upstream"* ]]
    [[ "$output" == *"bytecap: stock"* ]]
    [[ "$output" == *"titlecap: stock"* ]]
    [[ "$output" == *"linecap: stock"* ]]
}

@test "index patch: hunk 3 renames the 0.25.1 cap and SKIPS the rewires it has no premise for" {
    command -v node >/dev/null || skip "node is required by the patcher's own syntax check"
    run env QWEN_INDEX_PATCH_CHUNK_DIRS="$CHUNKS_0251" bash "$PATCHER"
    [ "$status" -eq 0 ]
    [[ "$output" == *"patched  bytecap"* ]]
    [ -f "$PATCHED_0251.orig" ]
    cmp -s "$PATCHED_0251.orig" "$FIXTURE_0251"
    # The cap is RAISED under its 0.25.1 name; the stock 25e3 value is gone.
    grep -qF 'var MAX_INDEX_CHARS=256000;' "$PATCHED_0251"
    run grep -qF 'var MAX_INDEX_CHARS=25e3;' "$PATCHED_0251"
    [ "$status" -ne 0 ]
    # Hunks 4-5 still apply here (their anchors match 0.25.1).
    grep -qF 'var MAX_INDEX_LINES=400;' "$PATCHED_0251"
    grep -qF 'LOCAL PATCH 2026-10-11 (qwen-memory-index-titlecap)' "$PATCHED_0251"

    # TRAP 1: the two uncapped-scan rewires must be SKIPPED.  Both anchors EXIST in this fixture
    # exactly as in the real bundle, so if the rewire ran it would rewrite these call sites onto
    # a scanAll* name the fixture does not define -- a bundle that still PARSES (node --check
    # cannot see a call to a missing function) and throws at runtime.  Assert the call sites are
    # untouched AND nothing was introduced.
    grep -qF 'scanAutoMemoryTopicDocuments(projectRoot)' "$PATCHED_0251"
    grep -qF 'await scanUserAutoMemoryTopicDocuments()' "$PATCHED_0251"
    run grep -qF 'scanAllAutoMemoryTopicDocuments' "$PATCHED_0251"
    [ "$status" -ne 0 ]

    # TRAP 2: upstream's own notice is the never-shed-silently half on this shape, so no
    # DROPPED-count marker of ours may be invented: the assemble body is left entirely alone.
    grep -qF 'trimIndexToBudget(lines)' "$PATCHED_0251"
    grep -qF 'INDEX_TRUNCATION_NOTICE' "$PATCHED_0251"
    run grep -qF 'INCOMPLETE: wrote' "$PATCHED_0251"
    [ "$status" -ne 0 ]

    run env QWEN_INDEX_PATCH_CHUNK_DIRS="$CHUNKS_0251" bash "$PATCHER" --check
    [ "$status" -eq 0 ]
    [[ "$output" == *"bytecap: applied"* ]]
}

@test "index patch: a second 0.25.1 apply is idempotent (the notice-keyed guards hold)" {
    command -v node >/dev/null || skip "node is required by the patcher's own syntax check"
    run env QWEN_INDEX_PATCH_CHUNK_DIRS="$CHUNKS_0251" bash "$PATCHER"
    [ "$status" -eq 0 ]
    local before after
    before="$(sha256sum "$PATCHED_0251" | awk '{print $1}')"
    run env QWEN_INDEX_PATCH_CHUNK_DIRS="$CHUNKS_0251" bash "$PATCHER"
    [ "$status" -eq 0 ]
    after="$(sha256sum "$PATCHED_0251" | awk '{print $1}')"
    [ "$before" = "$after" ]
}

@test "index patch: the patched 0.25.1 docIndexLine passes the title-budget harness" {
    command -v node >/dev/null || skip "node is required to run the harness"
    run env QWEN_INDEX_PATCH_CHUNK_DIRS="$CHUNKS_0251" bash "$PATCHER"
    [ "$status" -eq 0 ]
    run node "$TITLE_HARNESS" "$PATCHED_0251"
    [ "$status" -eq 0 ]
    [[ "$output" == *"(1) long title + long path"* ]]
    [[ "$output" == *"(3) title budget follows the path"* ]]
    [[ "$output" == *"all assertions passed"* ]]
}

# end of file
