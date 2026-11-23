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
    mkdir -p "$FIX/.qwen/memories" "$FIX/.qwen/tmp" "$FIX/.qwen/tools"
    # v10: the hook enforces the store's name budget through the store's own shortener, so the
    # fixture needs those two files.  They live with the store (~/.qwen/tools), not in this repo,
    # so a box without them cannot exercise the hook at all -- say that rather than pass.
    for tool in note_name_budget.py shorten-note-names.py; do
        if [[ ! -f "$HOME/.qwen/tools/$tool" ]]; then
            skip "the store's tools/$tool is not installed, so the hook cannot be exercised"
        fi
        cp "$HOME/.qwen/tools/$tool" "$FIX/.qwen/tools/$tool"
    done
    # MD049 for the emphasis fixer, plus the two shape rules its v5 fixers claim (MD041/MD032).  The
    # set stays explicit so a failure here cannot be some other rule's fix leaking in.
    cat > "$FIX/.qwen/.markdownlint.jsonc" <<'JSONC'
{
  "default": false,
  "MD049": true,
  "MD041": true,
  "MD032": true,
  "MD047": true
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

# ── the WRITE GUARD (v6) ───────────────────────────────────────────────────────────────────
# A fixer that prints FIXED after an unchecked `mv` is a success message with no write behind it.
# `mv` is resolved through PATH, so a failing stub on PATH is the honest seam for that branch: the
# hook's own calls (awk, find, markdownlint) still run, and only the replacement step fails.

fail_mv() {
    STUB="$BATS_TEST_TMPDIR/stub"
    mkdir -p "$STUB"
    printf '#!/bin/sh\nexit 1\n' > "$STUB/mv"
    chmod +x "$STUB/mv"
}

@test "memory lint hook: an H1 it cannot write is REFUSED, never reported as FIXED" {
    printf -- '---\nname: Fixture note title\n---\n\nProse with no heading.\n' \
        > "$FIX/.qwen/memories/note.md"
    before="$(sha256sum "$FIX/.qwen/memories/note.md")"
    fail_mv
    [ -n "$(lint)" ]
    run env PATH="$STUB:$PATH" HOME="$FIX" bash "$HOOK"
    [ "$status" -eq 0 ]
    [[ "$output" == *"REFUSED to fix MD041"* ]]
    [[ "$output" != *"FIXED the missing H1"* ]]
    [ "$(sha256sum "$FIX/.qwen/memories/note.md")" = "$before" ]
}

@test "memory lint hook: an emphasis fix it cannot write is REFUSED, never reported as FIXED" {
    write_note 'A first run in _underscore_ style, then a span in *asterisk* style.'
    before="$(sha256sum "$FIX/.qwen/memories/note.md")"
    fail_mv
    [ -n "$(lint)" ]
    run env PATH="$STUB:$PATH" HOME="$FIX" bash "$HOOK"
    [ "$status" -eq 0 ]
    [[ "$output" == *"REFUSED to fix emphasis"* ]]
    [[ "$output" != *"FIXED emphasis"* ]]
    [ "$(sha256sum "$FIX/.qwen/memories/note.md")" = "$before" ]
}

# ── v10: the name budget (the store's 150-char index line) ───────────────────────────────────
# The expectation comes from the store's own rule, not from the fixer: an index line is
# `- [name](rel) — description` under 150 chars with a 25-char description reserve, so the name's
# budget is 116 - len(rel).  The fixture's path is 58 chars, so its budget is 58 and a 73-char name
# overflows it by 15 -- the exact shape measured 2026-11-23.
LONG_REL="memories/reference/qwen-gate-read-head-not-the-worktree-2.md"
LONG_NAME="The store gate reds on HEAD, so a run before the commit is a false green"

write_long_note() {
    mkdir -p "$FIX/.qwen/memories/reference"
    printf -- '---\nname: %s\ndescription: Measured in the test.\ntype: reference\ncategory: common_pitfall\nkeywords:\n  - "a keyword"\nusage_scenarios:\n  - "a scenario"\n---\n\n# %s\n\nBody.\n' \
        "$LONG_NAME" "$LONG_NAME" > "$FIX/.qwen/$LONG_REL"
    printf -- '- [%s](reference/qwen-gate-read-head-not-the-worktree-2.md) — Measured in the test.\n' \
        "$LONG_NAME" > "$FIX/.qwen/memories/MEMORY.md"
}

# The budget this fixture must exceed, asked of the STORE's own arithmetic rather than restated
# here.  The criterion is tools/note_name_budget.py -- setup() copies it into the fixture, so this
# is the same code the hook itself shells out to.  A hardcoded copy has already drifted: this case
# read "116 - 58 = 58" while the live tool answers 56 for the 60-char link below, so the number in
# the file was no longer the rule it claimed to be quoting.
name_budget() {
    (cd "$FIX/.qwen" && PYTHONPATH="$FIX/.qwen" python3 -c '
import sys

sys.path.insert(0, "tools")
import note_name_budget as n

print(n.budget_for(sys.argv[1]))
' "$LONG_REL")
}

@test "memory lint hook: an over-budget name is SHORTENED and its index line re-rendered" {
    if ! command -v python3 >/dev/null; then
        skip "python3 is not on PATH, so the store's name budget cannot be computed"
    fi
    write_long_note
    budget="$(name_budget)"
    # Refuse a fixture that cannot exercise the fixer: a budget of 0 is a broken reading, not a
    # clean note, and an in-budget name would let this case pass while testing nothing.
    [ "$budget" -gt 0 ]
    [ "${#LONG_NAME}" -gt "$budget" ]

    run run_hook
    [ "$status" -eq 0 ]
    if [[ "$output" != *"FIXED the name budget in memories"* ]]; then
        # Name the cause rather than only the expectation.  Without this the red read as "a string
        # was absent", which is a failure message and not a diagnosis: the hook's own output plus
        # the shortener's verdict when asked directly says whether the fixer was skipped, refused,
        # or found nothing to shorten.
        printf 'budget=%s name_len=%s\n' "$budget" "${#LONG_NAME}"
        printf 'hook output:\n%s\n' "$output"
        printf 'shortener, asked directly:\n'
        (cd "$FIX/.qwen" && PYTHONPATH="$FIX/.qwen" python3 tools/shorten-note-names.py \
            --store memories --apply 2>&1)
        return 1
    fi

    new_name="$(sed -n 's/^name:[[:space:]]*//p' "$FIX/.qwen/$LONG_REL" | head -n 1)"
    [ "${#new_name}" -le "$budget" ]
    # The index line follows the note: a shortened name with a stale index line is the defect the
    # store's own cap case reports, so the fix is only done when both moved.
    grep -qF "](${LONG_REL#memories/})" "$FIX/.qwen/memories/MEMORY.md"
    grep -qF "[$new_name]" "$FIX/.qwen/memories/MEMORY.md"
    ! grep -qF "[$LONG_NAME]" "$FIX/.qwen/memories/MEMORY.md"
}

@test "memory lint hook: a name inside its budget is left alone" {
    write_long_note
    short_name="A short name"
    sed -i "s/^name: .*/name: $short_name/" "$FIX/.qwen/$LONG_REL"
    printf -- '- [%s](reference/qwen-gate-read-head-not-the-worktree-2.md) — Measured in the test.\n' \
        "$short_name" > "$FIX/.qwen/memories/MEMORY.md"
    before="$(sha256sum "$FIX/.qwen/$LONG_REL")"

    run run_hook
    [ "$status" -eq 0 ]
    [[ "$output" != *"FIXED the name budget"* ]]
    [ "$(sha256sum "$FIX/.qwen/$LONG_REL")" = "$before" ]
}

# end of file

# ── v8: the final newline (card MEMORY-FORMATTER-AT-WRITE-001) ────────────────────────────────
# MD047 is the one rule here that is fully determined by the file's own last byte, so it is fixed
# rather than prescribed: the advice block only ever reached notes a later turn happened to touch.
# The expectations come from MD047's contract, not from the hook: "exactly one newline at EOF".
@test "memory lint hook: MD047 is FIXED — a missing final newline is added and reported" {
    printf -- '---\nname: fixture\n---\n\n# Fixture\n\nno final newline' > "$FIX/.qwen/memories/note.md"
    run run_hook
    [ "$status" -eq 0 ]
    [[ "$output" == *"FIXED final newline"* ]]
    [ "$(tail -c 1 "$FIX/.qwen/memories/note.md" | od -An -c | tr -d ' ')" = "\n" ]
    [ "$(lint | wc -l)" -eq 0 ]
}

@test "memory lint hook: MD047 does not fire for two trailing newlines, so the hook leaves them" {
    # CORRECTED FROM MEASUREMENT, not from my expectation.  I wrote this case believing MD047 covered
    # "a run of trailing blank lines".  markdownlint's MD047 is "no multiple blanks": a missing final
    # newline is the only error it reports for end-of-file (measured 2026-11-09 on this box — a note
    # ending in three newlines lints rc=0).  So the assertion is the OBSERVABLE the linter gives:
    # nothing is cited for MD047, nothing is rewritten, and the bytes stay as they were.  A fixer that
    # silently collapsed them would be doing work no rule asked for.
    printf -- '---\nname: fixture\n---\n\n# Fixture\n\nbody\n\n\n' > "$FIX/.qwen/memories/note.md"
    before="$(md5sum "$FIX/.qwen/memories/note.md" | cut -d' ' -f1)"
    run run_hook
    [ "$status" -eq 0 ]
    [[ "$output" != *"FIXED final newline"* ]]
    [ "$before" = "$(md5sum "$FIX/.qwen/memories/note.md" | cut -d' ' -f1)" ]
}

@test "memory lint hook: a note it cannot write is REFUSED for MD047, never reported as FIXED" {
    # The v6 lesson, applied to the new fixer: a success message must have a write behind it.
    printf -- '---\nname: fixture\n---\n\n# Fixture\n\nno final newline' > "$FIX/.qwen/memories/note.md"
    chmod 444 "$FIX/.qwen/memories/note.md"
    run run_hook
    [ "$status" -eq 0 ]
    [[ "$output" != *"FIXED final newline"* ]]
    chmod 644 "$FIX/.qwen/memories/note.md"
}

@test "memory lint hook: a clean note is still untouched and silent for MD047" {
    printf -- '---\nname: fixture\n---\n\n# Fixture\n\nfine\n' > "$FIX/.qwen/memories/note.md"
    before="$(md5sum "$FIX/.qwen/memories/note.md" | cut -d' ' -f1)"
    run run_hook
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ "$before" = "$(md5sum "$FIX/.qwen/memories/note.md" | cut -d' ' -f1)" ]
}
