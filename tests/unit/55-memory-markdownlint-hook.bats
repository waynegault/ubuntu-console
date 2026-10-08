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
    LINTER="/home/linuxbrew/.linuxbrew/bin/markdownlint"
    FIX="$BATS_TEST_TMPDIR/home"
    mkdir -p "$FIX/.qwen/memories" "$FIX/.qwen/tmp"
    # Only MD049: the fixer's contract is emphasis style, and a tight rule set keeps the case honest
    # (a failure here cannot be some other rule's fix leaking in).
    cat > "$FIX/.qwen/.markdownlint.jsonc" <<'JSONC'
{
  "default": false,
  "MD049": true
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

# end of file
