#!/usr/bin/env bash
# memory-markdownlint.sh — lint the Qwen memory notes once per user turn, and say NOTHING when clean.
#
# WHY THIS EXISTS (workboard card VERIFIER-GAP-008): ~/.qwen/.markdownlint.jsonc pinned a markdownlint
# rule set for the memory tree on 2026-09-28, but NOTHING invoked it — it was a ritual with extra steps,
# the exact shape the conversion was meant to remove.  Mirroring ~/.qwen/hooks/guard-patch-check.sh, the
# check now runs itself: once per user turn, over the memory notes that CHANGED since the last run.
#
# Written in POSIX shell syntax (no arrays, no mapfile, no process substitution) so both `sh -n` and
# `bash -n` parse it; it runs under the bash named in the shebang.
#
# AI INSTRUCTION: Increment version on significant changes.
# Module Version: 1
#   v1 (2026-10-08): the hook FIXES the emphasis class (MD049) itself — by cited position, refusing a
#   stale report — and re-lints what it touched, instead of prescribing a chore.  The marker is new;
#   this file carried none, which left it outside tools/check-module-versions.sh entirely.
#
# Contract:
#   * prints NOTHING when the changed notes are clean (the common case);
#   * prints a labelled failure block naming file:line + rule when a changed note has a violation;
#   * FIXES the emphasis class (MD049) itself, and says so, rather than prescribing a chore — see
#     "THE ONE CLASS THIS HOOK FIXES" below;
#   * ALWAYS exits 0.  A malformed note degrades readability, it corrupts nothing, so this is a warning
#     to act on, never a blocker — but it is LOUD, never silent;
#   * a missing markdownlint, a missing rule set or an unusable stamp directory is a REAL failure, not
#     "clean": each prints a one-line warning naming the missing path.  A silent skip would be exactly
#     the defect this card is about.
#
# THE ONE CLASS THIS HOOK FIXES (added 2026-10-08).  MD049 is the only violation here with a writer
# that re-creates it on every pass: the CLI's managed auto-memory extractor emits asterisk emphasis
# into notes whose own first run is an underscore.  Reporting it, or hand-fixing the spans, leaves a
# standing chore; the instruction that was SUPPOSED to stop it is not honoured — measured the same
# day, the style rule was present inside EXTRACTION_AGENT_SYSTEM_PROMPT, correctly placed, and LIVE in
# the daemon that ran the pass, and the extractor wrote asterisk emphasis anyway (see
# bin/qwen-memory-style-patch.sh, and QwenLM/qwen-code#13201 upstream).
#
# So the fix moved out of the model's hands and into this hook, and it is deliberately NARROWER than
# any `--fix`: the linter cites the exact DELIMITER CHARACTER of every offending span and the report
# states the style the FILE wants, so the hook flips precisely those cited characters.  One character
# in, one character out — no position can shift, so nothing else in the note can be touched, which is
# the hazard that made the full-config `--fix` unsafe here.  A cited character that is not the
# delimiter the report claimed means the report is STALE (a shape this store has recorded), and the
# file is then left alone and NAMED rather than mangled.
#
# Scope: ~/.qwen/memories/**/*.md and ~/.qwen/projects/*/memory/**/*.md ONLY.
#   MEMORY.md is deliberately EXCLUDED.  It is not a note: the host REBUILDS it from the topic documents
#   after every memory write (rebuildManagedAutoMemoryIndex / rebuildUserAutoMemoryIndex in the qwen-code
#   bundle), so its shape — no H1, no trailing newline — is set by that writer and any edit is reverted on
#   the next save.  ~/.qwen/memories/.markdownlintignore (2026-08-08) records the same exclusion, for the
#   same reason.
#
# "Changed" is mtime-based, not git-based (the memory roots are not one repository): a stamp file records
# the START of the last run, and only notes newer than it are linted.  With no stamp yet, every note is
# linted once.  Stamping the start (not the end) means a note written while the linter runs is caught
# next turn rather than skipped.
#
# Limitation, stated because the hook cannot see it: this checks the notes on disk, not what a running
# session has loaded into its context.  A note edited after that context was built stays stale there.
set -u

QWEN_DIR="$HOME/.qwen"
CONFIG="$QWEN_DIR/.markdownlint.jsonc"
FIX_CONFIG="$QWEN_DIR/.markdownlint-fixable.jsonc"
LINTER="/home/linuxbrew/.linuxbrew/bin/markdownlint"
STAMP_DIR="$QWEN_DIR/tmp"
STAMP="$STAMP_DIR/memory-markdownlint.stamp"
LIST="$STAMP_DIR/.memory-markdownlint.files.$$"
MAX_LINES=20

if [[ ! -x "$LINTER" ]]; then
    echo "memory-markdownlint: $LINTER is missing or not executable — the memory notes were NOT checked."
    exit 0
fi

if [[ ! -f "$CONFIG" ]]; then
    echo "memory-markdownlint: $CONFIG is missing — the memory notes were NOT checked."
    exit 0
fi

if ! mkdir -p "$STAMP_DIR"; then
    echo "memory-markdownlint: cannot create $STAMP_DIR — the memory notes were NOT checked."
    exit 0
fi

# Marker = the start of this run; it becomes the next run's stamp.
marker="$STAMP_DIR/.memory-markdownlint.run.$$"
if ! (umask 077 && : > "$marker"); then
    echo "memory-markdownlint: cannot create $marker — the memory notes were NOT checked."
    exit 0
fi

cd "$QWEN_DIR" || {
    echo "memory-markdownlint: cannot enter $QWEN_DIR — the memory notes were NOT checked."
    rm -f "$marker"
    exit 0
}

# Relative paths on purpose: the linter's ignore/config resolution is reliable for files under its own
# working directory, and unreliable for paths that point outside it.
# The projects branch is pinned to `*/memory/*`: other .md files under ~/.qwen/projects (chat exports,
# audit reports) are NOT memory notes and are outside this gate's declared scope.
# ── the emphasis fixer (see "THE ONE CLASS THIS HOOK FIXES" in the header) ───────────────────
# Only reached when the report carries MD049.  Per cited note: flip exactly the cited delimiter
# characters to the style the report says the FILE wants, and refuse anything else.  The list of
# notes acted on goes to a FILE rather than a variable, because the loop reads a pipe and a
# pipeline runs in a subshell — a variable set in there would be lost to the caller.
FIXED_LIST="$STAMP_DIR/.memory-markdownlint.fixed.$$"
: > "$FIXED_LIST"
fix_emphasis() {
    printf '%s\n' "$report" | grep -F 'MD049' | cut -d: -f1 | sort -u |
        while IFS= read -r note; do
            [[ -f "$note" ]] || continue
            expected="$(printf '%s\n' "$report" | grep -F 'MD049' | grep -F "$note:" |
                sed -n 's/.*Expected: \([a-z]*\).*/\1/p' | head -n 1)"
            case "$expected" in
                underscore) want_char="_"; cited_char="*" ;;
                asterisk)   want_char="*"; cited_char="_" ;;
                *)
                    echo "memory-markdownlint: cannot fix $note — the report names no emphasis style for it."
                    continue
                    ;;
            esac
            cited="$(printf '%s\n' "$report" | grep -F 'MD049' | grep -F "$note:" | cut -d: -f2,3)"
            tmp="$note.emphasis-fix.$$"
            if awk -v cited="$cited" -v want="$want_char" -v wrong="$cited_char" '
                BEGIN {
                    n = split(cited, pairs, "\n")
                    for (i = 1; i <= n; i++) {
                        if (pairs[i] == "") continue
                        split(pairs[i], p, ":")
                        line = p[1] + 0
                        col = p[2] + 0
                        if (line <= 0 || col <= 0) continue
                        cols[line] = (cols[line] == "" ? col : cols[line] "," col)
                    }
                    bad = 0
                }
                {
                    if (cols[NR] != "") {
                        m = split(cols[NR], cc, ",")
                        for (j = 1; j <= m; j++) {
                            col = cc[j] + 0
                            ch = substr($0, col, 1)
                            if (ch != wrong) {
                                printf "line %d col %d: expected %s, found %s\n", NR, col, wrong, ch
                                bad = 1
                                next
                            }
                            $0 = substr($0, 1, col - 1) want substr($0, col + 1)
                        }
                    }
                    print
                }
                END { if (bad) exit 3 }   # 3 = a cited position was not the delimiter: refuse the note
            ' "$note" > "$tmp" 2>"$tmp.refused"; then
                if cmp -s "$note" "$tmp"; then
                    echo "memory-markdownlint: $note was cited for MD049 but nothing changed — the report was stale."
                else
                    mv "$tmp" "$note"
                    echo "memory-markdownlint: FIXED emphasis in $note ($cited_char -> $want_char, its own style)."
                    printf '%s\n' "$note" >> "$FIXED_LIST"
                fi
                rm -f "$tmp" "$tmp.refused"
            else
                echo "memory-markdownlint: REFUSED to fix $note — a cited char was not the claimed delimiter:"
                sed -n '1,5p' "$tmp.refused"
                rm -f "$tmp" "$tmp.refused"
            fi
        done
}

# collect_all — every note in scope, used when there is no stamp yet.
collect_all() {
    find memories -type f -name '*.md' -not -name 'MEMORY.md'
    find projects -type f -name '*.md' -path '*/memory/*' -not -name 'MEMORY.md' \
        -not -path '*/.git/*' -not -path '*/node_modules/*'
}

collect_changed() {
    find memories -type f -name '*.md' -not -name 'MEMORY.md' -newer "$STAMP"
    find projects -type f -name '*.md' -path '*/memory/*' -not -name 'MEMORY.md' \
        -not -path '*/.git/*' -not -path '*/node_modules/*' -newer "$STAMP"
}

if [[ -f "$STAMP" ]]; then
    # swallow-ok: find may hit an unreadable subdir; the hook must not abort on one — an empty list exits early below
    collect_changed > "$LIST" 2>/dev/null
else
    # No stamp yet: lint everything once, then start tracking.
    # swallow-ok: same find walk — an unreadable subdir is skipped and an empty list exits early below
    collect_all > "$LIST" 2>/dev/null
fi

# Drop anything that vanished between the scan and the lint (another session consolidating memory).
rm -f "$LIST.keep"
checked=0
while IFS= read -r candidate; do
    [[ -n "$candidate" ]] || continue
    if [[ -f "$candidate" ]]; then
        printf '%s\n' "$candidate" >> "$LIST.keep"
        checked=$((checked + 1))
    fi
done < "$LIST"
rm -f "$LIST"

if [[ "$checked" -eq 0 ]]; then
    touch -r "$marker" "$STAMP"
    rm -f "$marker"
    rm -f "$LIST.keep"
    exit 0
fi

report="$(xargs -d '\n' -a "$LIST.keep" "$LINTER" --config "$CONFIG" 2>&1)"
status=$?
rm -f "$LIST.keep"

if printf '%s\n' "$report" | grep -qF 'MD049'; then
    fix_emphasis
fi

# Re-lint the notes the fixer touched, so the verdict below describes the tree AS IT NOW IS rather
# than the tree it was.  A fix that is not re-measured is a claim, not a result.
if [[ -s "$FIXED_LIST" ]]; then
    report="$(xargs -d '\n' -a "$FIXED_LIST" "$LINTER" --config "$CONFIG" 2>&1)"
    status=$?
fi
rm -f "$FIXED_LIST"

# Advance the stamp whether or not the notes were clean: the report belongs to THIS change, and repeating
# it every turn until someone edits the note is noise, not signal.
touch -r "$marker" "$STAMP"
rm -f "$marker"

if [[ "$status" -eq 0 ]] && [[ -z "$report" ]]; then
    exit 0
fi

total="$(printf '%s\n' "$report" | grep -cE 'MD[0-9]+')"

echo "MEMORY-MARKDOWNLINT: a memory note changed since the last turn does not satisfy $CONFIG."
if [[ "$total" -eq 0 ]] && [[ "$status" -ne 0 ]]; then
    # Non-zero status with no MD finding means the linter never RAN — a missing interpreter, a
    # bad rule set, an unreadable file.  Say that rather than "0 violation(s)", which reads as a
    # clean tree: measured 2026-10-03, a node-less PATH made every run print exactly that over an
    # empty check.  The linter's own words follow below.
    echo "Checked $checked changed note(s); the linter did NOT run — its own words follow:"
else
    echo "Checked $checked changed note(s); $total violation(s):"
fi
printf '%s\n' "$report" | grep -E 'MD[0-9]+' | head -n "$MAX_LINES"
if [[ "$total" -gt "$MAX_LINES" ]]; then
    echo "  ... and $((total - MAX_LINES)) more."
fi
if [[ "$total" -eq 0 ]]; then
    # The linter itself failed (unreadable file, bad config) — show its own words rather than nothing.
    printf '%s\n' "$report" | head -n "$MAX_LINES"
fi
# CHANGED 2026-09-30: this used to prescribe a FULL-config `--fix`.  That REWRITES PROSE.  Measured
# on a note whose wrapped lines began with a marker: it turned a quoted "+ maintenance lease
# released" into "- …" (MD004), inserted the space that makes a wrapped "#144627/#143932/#146315"
# a real heading (MD018 — which then reported MD022/MD025/MD026, so a second run would have
# deleted the sentence's full stop), and swapped a quoted "* not a list item…" to "- …".  Every
# one of those notes still linted clean afterwards.  A fixer cannot tell prose that wrapped onto a
# marker from real structure, so the automatic rewrite is now limited to whitespace rules, which
# cannot arise from a misreading: the same three lines come back byte-identical under it.
if [[ -f "$FIX_CONFIG" ]]; then
    echo "Fix with the restricted config (whitespace rules only, safe) — run it from the STORE ROOT with a"
    echo "path RELATIVE to it, which is the shape this hook itself uses ($QWEN_DIR):"
    echo "  (cd $QWEN_DIR && $LINTER --config .markdownlint-fixable.jsonc --fix <path relative to ~/.qwen>)"
    echo "An ABSOLUTE <file> crashes markdownlint-cli's ignore filter with a Node RangeError (\"path should be"
    echo "a 'path.relative()'d string\") whenever the run starts from another directory — measured 2026-09-30."
    echo "There is no --no-ignore option; the cd-plus-relative-path form is the working one."
    echo "Do NOT fix with --config $CONFIG --fix: a full fix rewrites prose that wrapped onto a marker."
    echo "(The markdownlint shim in ~/.local/bin refuses that form anyway - see bin/markdownlint.)"
else
    echo "Fix by hand: $FIX_CONFIG is missing, and a full --fix rewrites prose that wrapped onto a marker."
fi
echo "Then hand-fix what no fixer can: MD049 (emphasis) is handled above, deterministically and by"
echo "position; the classes below have no safe fixer — a bare URL becomes <https://…>, a space inside"
echo "emphasis or a code span goes outside it, one list marker style per note (by hand — the fixer"
echo "gets it wrong), a fenced block names its language, and a note starts with an H1 taken from its"
echo "frontmatter 'name:'."
echo "Always re-read every line a fixer touched: a clean exit code is not evidence the text survived."
exit 0
