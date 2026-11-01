#!/usr/bin/env bats
# ==============================================================================
# Unit — the memory lint hook's emphasis fixer (tools/qwen-hooks/memory-markdownlint.sh)
# ==============================================================================
# The hook runs once per user turn over ~/.qwen's memory notes and, since v1, FIXES the one class
# whose writer re-creates it every pass: the CLI's auto-memory extractor emits asterisk emphasis into
# notes whose own first run is an underscore.  Reporting it left a standing chore, and the instruction
# meant to stop it is not honoured (the style rule is present, correctly placed and live in the
# serving daemon, and the extractor writes asterisks anyway — see bin/qwen-memory-style-patch.sh).
#
# WHY THE EXPECTATIONS ARE NOT READ OFF THE HOOK.  They come from markdownlint's own MD049 contract,
# which is per FILE: emphasis must agree with the file's first run.  So the fixer must be able to go
# BOTH ways — asterisks become underscores in a file whose first run is an underscore, and the reverse
# in a file whose first run is an asterisk — and it must not touch STRONG, whose style in this store
# stays the asterisk (MD050 is the mirror rule).  A one-directional fixer would look correct against
# the case that prompted it and be wrong against the mirror case, which is why case 3 exists.
#
# Hermetic: the hook derives every path from $HOME, so each case points HOME at a fixture tree — its
# own .qwen, its own rule set, its own note.  The real ~/.qwen notes are never read or written.
# ==============================================================================

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    HOOK="$REPO_ROOT/tools/qwen-hooks/memory-markdownlint.sh"
    # Resolved, not hardcoded: the linuxbrew path is the x86 box's install. Measured
    # 2026-10-30 — the arm64 box has markdownlint at ~/.local/bin, so every case in
    # this file failed there with "no such file" while passing on the other box. A test
    # that names one machine's install directory is a test about that machine.
    LINTER="$(command -v markdownlint 2>/dev/null || true)"
    if [[ -z "$LINTER" && -x /home/linuxbrew/.linuxbrew/bin/markdownlint ]]; then
        LINTER=/home/linuxbrew/.linuxbrew/bin/markdownlint
    fi
    if [[ -z "$LINTER" ]]; then
        skip "markdownlint is not installed on this box, so the hook cannot be exercised"
    fi
    FIX="$BATS_TEST_TMPDIR/home"
    mkdir -p "$FIX/.qwen/memories" "$FIX/.qwen/tmp"
    # MD049 for the emphasis fixer, plus the two shape rules its v5 fixers claim (MD041/MD032).  The
    # set stays explicit so a failure here cannot be some other rule's fix leaking in.
    cat > "$FIX/.qwen/.markdownlint.jsonc" <<'JSONC'
{
  "default": false,
  "MD049": true,
  "MD041": true,
  "MD032": true
}
JSONC
}

# write_note <body line>
write_note() {
    printf -- '---\nname: fixture\n---\n\n# Fixture\n\n%s\n' "$1" > "$FIX/.qwen/memories/note.md"
}

run_hook() {
    HOME="$FIX" bash "$HOOK"
}

lint() {
    (cd "$FIX/.qwen" && "$LINTER" --config .markdownlint.jsonc memories/note.md 2>&1)
}

@test "memory lint hook: it CONVERTS a cited span to the file's own style, then reports nothing" {
    write_note 'A first run in _underscore_ style, then a span in *asterisk* style.'
    # Assert the fixture really IS a violation before fixing it: a case that only checked the
    # post-state could pass over a linter that had stopped flagging emphasis at all.
    [ -n "$(lint)" ]

    run run_hook
    [ "$status" -eq 0 ]
    [[ "$output" == *"FIXED emphasis"* ]]
    # The cited characters became underscores...
    [[ "$(cat "$FIX/.qwen/memories/note.md")" == *"_asterisk_"* ]]
    # ...and the file is clean afterwards, which is the fix's own success condition.
    [ -z "$(lint)" ]
}

@test "memory lint hook: a **strong** run is never touched (MD050 is the mirror rule)" {
    write_note 'A run in _underscore_ style, a span in *asterisk* style, and a **strong** run.'
    run run_hook
    [[ "$(cat "$FIX/.qwen/memories/note.md")" == *"**strong**"* ]]
}

@test "memory lint hook: the REVERSE direction works — the file's first run is the asterisk" {
    write_note 'First a *starred* run, then an _underscored_ span.'
    run run_hook
    [[ "$output" == *"FIXED emphasis"* ]]
    [[ "$(cat "$FIX/.qwen/memories/note.md")" == *"*underscored*"* ]]
    [ -z "$(lint)" ]
}

@test "memory lint hook: a clean note prints NOTHING (the contract's silent case)" {
    write_note 'A note with _one_ style throughout.'
    [ -z "$(lint)" ]
    run run_hook
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# ── the SHAPE fixers (v5) ───────────────────────────────────────────────────────────────────
# The expectations come from markdownlint's own contracts, not from the fixer: MD041 wants the first
# line of the document to be a top-level heading, and this store's convention makes that heading the
# frontmatter's `name:` value; MD032 wants a list surrounded by blank lines.  The two refusal cases
# exist because the narrowness IS the design — repairing a shape the extractor did not produce would
# silence a real rendering defect, so the fixer must leave the note byte-identical and name it.

@test "memory lint hook: a note with no H1 gets one taken from its frontmatter name (MD041)" {
    printf -- '---\nname: Fixture note title\n---\n\nProse with no heading.\n' \
        > "$FIX/.qwen/memories/note.md"
    [ -n "$(lint)" ]      # the fixture really violates MD041 before the fix
    run run_hook
    [ "$status" -eq 0 ]
    [[ "$output" == *"FIXED the missing H1"* ]]
    [[ "$(cat "$FIX/.qwen/memories/note.md")" == *"# Fixture note title"* ]]
    [ -z "$(lint)" ]
}

@test "memory lint hook: a note whose frontmatter has no name is REFUSED, not given an H1" {
    printf -- '---\ntype: project\n---\n\nProse without a name field.\n' \
        > "$FIX/.qwen/memories/note.md"
    before="$(sha256sum "$FIX/.qwen/memories/note.md")"
    [ -n "$(lint)" ]
    run run_hook
    [ "$status" -eq 0 ]
    [[ "$output" == *"REFUSED to fix MD041"* ]]
    # Byte-identical: a refusal that still wrote something would be the silent-failure shape.
    [ "$(sha256sum "$FIX/.qwen/memories/note.md")" = "$before" ]
    # ...and the finding is still reported, not dropped by the re-lint of the files that were fixed.
    [[ "$output" == *"MD041"* ]]
}

@test "memory lint hook: a list under a bold lead-in gets its blank line (MD032)" {
    printf -- '---\nname: n\n---\n\n# N\n\n**What changed:**\n- one item\n' \
        > "$FIX/.qwen/memories/note.md"
    [ -n "$(lint)" ]
    run run_hook
    [ "$status" -eq 0 ]
    [[ "$output" == *"FIXED the blank line MD032"* ]]
    [ -z "$(lint)" ]
}

@test "memory lint hook: a wrapped formula read as a list is REFUSED (MD032 stays visible)" {
    printf -- '---\nname: n\n---\n\n# N\n\nThe total is the sum of the parts\n+ 0 + 0.2 = 0.2 of them.\n' \
        > "$FIX/.qwen/memories/note.md"
    before="$(sha256sum "$FIX/.qwen/memories/note.md")"
    [ -n "$(lint)" ]
    run run_hook
    [ "$status" -eq 0 ]
    [[ "$output" == *"REFUSED to fix MD032"* ]]
    [ "$(sha256sum "$FIX/.qwen/memories/note.md")" = "$before" ]
    [[ "$output" == *"MD032"* ]]
}

# end of file
