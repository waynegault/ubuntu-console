#!/usr/bin/env bats
# ==============================================================================
# Unit — the auto-memory extractor's style rule (bin/qwen-memory-style-patch.sh)
# ==============================================================================
# The patcher edits a FOREIGN bundle (the Qwen CLI), so CI cannot exercise it against the four
# real copies: there is no bundle there, and a test must never reach the ones on this box.  The
# script carries `QWEN_STYLE_PATCH_CHUNK_DIRS` for exactly that, and this suite is its consumer
# (until now the affordance was documented and unused).
#
# THE CLASS THIS SUITE EXISTS FOR IS UPGRADE-AWARE-NESS, not "does it insert a string".  The
# rule text is the patch's PAYLOAD and the marker only records that SOME version ran, so a copy
# carrying an older payload must be UPGRADED IN PLACE.  Inserting the new element beside the old
# one would leave a stale rule the extractor still reads — a silent half-fix — and the patch's
# own post-condition forbids it.  That failure mode is invisible to `node --check` (the file
# still parses), which is why these cases assert on CONTENT.
#
# The expected values come from the patcher's stated contract, not from its output:
#   * a superseded payload reads NEEDS on --check, and a current one reads applied;
#   * an upgrade leaves exactly ONE style element, the current one;
#   * a chunk missing the anchor is REFUSED and left byte-identical (the safety promise);
#   * a second apply is idempotent.
#
# Hermetic: the fixture is copied into BATS_TEST_TMPDIR and every run points the patcher at that
# copy, so the real CLI, companion and /mnt/c bundles are never read or written.
# ==============================================================================

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    PATCHER="$REPO_ROOT/bin/qwen-memory-style-patch.sh"
    FIXTURE="$REPO_ROOT/tests/fixtures/qwen-memory-extractor-style-chunk.js"
    WORK="$BATS_TEST_TMPDIR"
    CHUNKS="$WORK/chunks"
    mkdir -p "$CHUNKS"
    cp "$FIXTURE" "$CHUNKS/"
    TARGET="$CHUNKS/qwen-memory-extractor-style-chunk.js"
    # node is the patcher's OWN dependency (it runs `node --check` after every edit); make the
    # suite full-strength on a runner whose PATH does not carry it.
    if ! command -v node >/dev/null 2>&1 && [[ -d /home/linuxbrew/.linuxbrew/bin ]]; then
        PATH="/home/linuxbrew/.linuxbrew/bin:$PATH"
        export PATH
    fi
}

# The v3 clause — the phrase that distinguishes the current payload from every earlier one.
V3_CLAUSE="The asterisk must NEVER delimit emphasis"
# The v2 payload's opening, absent from v3, so "0 occurrences" is the upgrade's proof.
V2_OPENING="Match the store's Markdown style: emphasis with underscores"

@test "style patch: a chunk carrying the superseded payload reads NEEDS, not applied" {
    run env QWEN_STYLE_PATCH_CHUNK_DIRS="$CHUNKS" bash "$PATCHER" --check
    [ "$status" -eq 1 ]
    [[ "$output" == *"superseded"* ]]
}

@test "style patch: applying UPGRADES the payload in place — v3 present once, v2 gone, and it still parses" {
    run env QWEN_STYLE_PATCH_CHUNK_DIRS="$CHUNKS" bash "$PATCHER"
    [ "$status" -eq 0 ]
    [[ "$output" == *"upgraded extractor-style (superseded payload -> v3)"* ]]
    [[ "$output" == *"syntax verified"* ]]

    # The upgrade's whole point: one style element, and it is the current one.
    [ "$(grep -cF "$V3_CLAUSE" "$TARGET")" -eq 1 ]
    [ "$(grep -cF "$V2_OPENING" "$TARGET")" -eq 0 ]
    # ...and the element the patch inserts BEFORE must have survived.
    [ "$(grep -cF '"Memory file format reference:",...MEMORY_FRONTMATTER_EXAMPLE]' "$TARGET")" -eq 1 ]
    node --check "$TARGET"

    run env QWEN_STYLE_PATCH_CHUNK_DIRS="$CHUNKS" bash "$PATCHER" --check
    [ "$status" -eq 0 ]
    [[ "$output" == *"extractor-style: applied"* ]]
}

@test "style patch: a second apply is idempotent and leaves the bytes alone" {
    env QWEN_STYLE_PATCH_CHUNK_DIRS="$CHUNKS" bash "$PATCHER" >/dev/null 2>&1
    before="$(sha256sum "$TARGET" | awk '{print $1}')"
    run env QWEN_STYLE_PATCH_CHUNK_DIRS="$CHUNKS" bash "$PATCHER"
    [ "$status" -eq 0 ]
    [ "$(sha256sum "$TARGET" | awk '{print $1}')" = "$before" ]
}

@test "style patch: a chunk with no anchor is REFUSED, and left byte-identical" {
    # The safety promise: an unrecognised shape is REPORTED, never patched blind.
    sed -i 's/"Memory file format reference:",\.\.\.MEMORY_FRONTMATTER_EXAMPLE\]/"Memory file format reference:"/' "$TARGET"
    before="$(sha256sum "$TARGET" | awk '{print $1}')"
    run env QWEN_STYLE_PATCH_CHUNK_DIRS="$CHUNKS" bash "$PATCHER"
    [ "$status" -eq 1 ]
    [[ "$output" == *"MISMATCH"* ]]
    [ "$(sha256sum "$TARGET" | awk '{print $1}')" = "$before" ]
}

@test "style patch: the v1 payload upgrades too, so no copy is skipped by its marker" {
    # v1 differs from v2 only in its clauses; the patcher must recognise BOTH, because a copy
    # that reads as "already patched" and is skipped is how a new clause never lands.
    sed -i 's|never asterisks (\*like this\*); a blank line before and after every list and heading; the single H1 repeats the frontmatter name value; and every code block is fenced with a language tag, never indented\.|never asterisks (*like this*), and a blank line before and after every list.|' "$TARGET"
    run env QWEN_STYLE_PATCH_CHUNK_DIRS="$CHUNKS" bash "$PATCHER"
    [ "$status" -eq 0 ]
    [[ "$output" == *"upgraded extractor-style"* ]]
    [ "$(grep -cF "$V3_CLAUSE" "$TARGET")" -eq 1 ]
    node --check "$TARGET"
}

# end of file
