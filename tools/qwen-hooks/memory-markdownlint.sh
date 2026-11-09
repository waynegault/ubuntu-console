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
# Module Version: 9
#   v9 (2026-11-09): the §18.3 rises v8 added are cleared at source, not re-baselined — the two
#   MD047 read-back tests are `[[ … ]]` (6.7 107 -> 107) and the awk invocation's swallow marker
#   sits on the line directly above it so the code fits the 120-column bound (8.1.8 287 -> 287).
#   Same predicate, same site classified; no behaviour change.
# Module Version: 8
#   v8 (2026-11-09, card MEMORY-FORMATTER-AT-WRITE-001): MD047 is now FIXED, not prescribed.  The rule is
#   fully determined by the file's last byte, so there is nothing to interpret: a missing final newline
#   gains one and a trailing blank run collapses to one, verified by reading the file back (last byte
#   a newline, byte before it not).  Reason it moved: the v6 writer payload states the rule in the
#   extractor's prompt and held for 14 consecutive notes, yet still missed one, and the advice block
#   only reached notes a later turn happened to touch.  The fixer's FIRST verifier was itself the
#   defect — it appended a newline to a copy of the rewritten file and compared, which can never match,
#   so every note was refused as "did not read back as intended" while the rewrite was correct; that is
#   the same success-message-without-a-write family v6 closed, in reverse.  No other rule is touched:
#   MD049/MD004 remain findings, because a wrapped formula rewritten by position changes arithmetic
#   while still linting clean.
#   v7 (2026-11-01): the v6 refusal message ran to 131 characters, over §18.3 item 8.1.8's 120-column
#   bound, so it is wrapped across a continuation instead of being absorbed by the ratchet baseline.
#   Behaviour is identical; the wrapped form still matches the suite's `REFUSED to fix emphasis` glob.
#   v6 (2026-11-01): every fixer CHECKS its own write.  All three printed "FIXED …" after an
#   unchecked `mv`, which is a success message with no write behind it whenever the repaired
#   copy cannot be moved into place (a read-only note directory, an immutable file).  The
#   repair is now conditional and the failure is REFUSED by name, so the verdict matches disk.
#   A BATS case shadows `mv` with a failing stub to hold that line.
#   v5 (2026-11-01): FIXES two more shapes the extractor keeps re-creating — MD041 (no H1) and MD032
#   (a list not surrounded by blank lines) — narrowly, and refuses everything else.  The writer patch
#   ALREADY states both rules (clauses (2) and (3), see bin/qwen-memory-style-patch.sh), and a note
#   the extractor wrote the same day carried neither with that payload applied, so the prompt route
#   is exhausted for this class as it is for emphasis.  MD032 is repaired only for the pattern it
#   emits (a lone bold lead-in directly above a list); a wrapped formula read as a list marker is
#   REFUSED, because inserting a blank line there would silence a real rendering defect.  MD041 takes
#   the H1 from the note's own frontmatter `name:` and refuses when there is none.  The re-lint now
#   KEEPS the findings for notes a fixer did not touch, so a refusal cannot be swallowed by a clean
#   verdict on the repaired ones, and the MD049 refusal path's own diagnosis is no longer written to
#   the discarded temp file (it reached nobody since v1).
#   v2 (2026-10-24): names the WRAPPED-OPERATOR trap in the hand-fix advice.  Measured: a note whose
#   writer wrapped a formula left a continuation line beginning `+ 0 + 0.2·1.0 = 0.635`, and markdown
#   (correctly) reads a line-initial `+` as a list marker, so MD004 fired on prose.  The danger is the
#   generic advice "one list marker style per note": applying it rewrites `+` to `-` and changes the
#   arithmetic while the note still lints clean.  Auto-fixing the shape was REJECTED on measurement —
#   the narrow rule (operator-led line after a line whose code span is still open) matches 0 of 964
#   notes, while the wider rule that would catch it matches 96 legitimate headings and bullets, so any
#   joiner would corrupt structure.  The advice now says to REFLOW instead.  No lint-behaviour change.
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
# Resolved, not hardcoded.  /home/linuxbrew/... is the x86 box's install; the arm64 box
# has it at ~/.local/bin, so this hook told that box the linter was MISSING on every
# turn — a false alarm that also disabled the check it exists to perform (measured
# 2026-10-30).  PATH first, the old absolute path as the last resort, and the
# missing-linter branch below still treats "nowhere" as a real failure rather than
# silence.  TAC_MARKDOWNLINT overrides both, for a box with no PATH entry for it.
if [[ -n "${TAC_MARKDOWNLINT:-}" ]]; then
    LINTER="$TAC_MARKDOWNLINT"
else
    # No 2>/dev/null and no `|| true`: `command -v` keeps its own counsel when it finds
    # nothing, and an `if` tests the status without swallowing anything.
    if ! LINTER="$(command -v markdownlint)"; then
        LINTER="/home/linuxbrew/.linuxbrew/bin/markdownlint"
    fi
fi
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
                                printf "line %d col %d: expected %s, found %s\n", NR, col, wrong, ch > "/dev/stderr"
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
                elif mv "$tmp" "$note"; then
                    echo "memory-markdownlint: FIXED emphasis in $note ($cited_char -> $want_char, its own style)."
                    printf '%s\n' "$note" >> "$FIXED_LIST"
                else
                    # A FIXED line here would be a success message with no write behind it.
                    echo "memory-markdownlint: REFUSED to fix emphasis in $note —" \
                        "the repaired copy could not be moved into place."
                fi
                rm -f "$tmp" "$tmp.refused"
            else
                echo "memory-markdownlint: REFUSED to fix $note — a cited char was not the claimed delimiter:"
                sed -n '1,5p' "$tmp.refused"
                rm -f "$tmp" "$tmp.refused"
            fi
        done
}

# ── the SHAPE fixers (MD041 / MD032) ────────────────────────────────────────────────────────
# Both rules are stated in the writer patch already (clauses (2) and (3)), and the extractor still
# emits notes without them, so this is the same exhaustion that moved emphasis here.  The repairs
# are deliberately NARROWER than the rules: only the shapes the extractor produces are touched, and
# everything else is refused and NAMED, which keeps a genuine finding visible.
#
# MD032 is repaired ONLY for a lone bold lead-in line (`**What changed:**`) directly above a list.
# A general MD032 fixer would be unsafe: a wrapped formula beginning `+ 0 + …` is READ as a list
# item, so inserting a blank line there would silence a real rendering defect while the arithmetic
# still read wrongly.  That shape is refused, by name and line.
# shape_refuse — say why a cited note was left alone, naming note, rule and reason.
shape_refuse() {   # shape_refuse <note> <rule> <reason>
    echo "memory-markdownlint: REFUSED to fix $2 in $1 — ${3:-the fixer could not identify the shape}."
}

# shape_fm_name — the frontmatter's 'name:' value, empty when the note carries none.
shape_fm_name() {  # shape_fm_name <note>
    awk '
        NR == 1 && $0 != "---" { exit }
        NR > 1 && $0 == "---" { exit }
        NR > 1 && /^name:[[:space:]]/ { sub(/^name:[[:space:]]*/, ""); print; exit }
    ' "$1"
}

# fix_md032 — insert the blank line MD032 asks for, but ONLY above the extractor's own lead-in shape.
fix_md032() {  # fix_md032 <note> <cited line>
    note="$1"
    cited="$2"
    tmp="$note.md032-fix.$$"
    if awk -v cited="$cited" '
        { line[NR] = $0 }
        END {
            why = ""
            if (cited < 2 || cited > NR)
                why = sprintf("cited line %d is outside the file", cited)
            else if (line[cited] !~ /^[[:space:]]*([-*+]|[0-9]+[.)])[[:space:]]/)
                why = sprintf("line %d does not begin with a list marker", cited)
            else if (line[cited - 1] ~ /^[[:space:]]*$/)
                why = sprintf("line %d is already blank, so the report was stale", cited - 1)
            else if (line[cited - 1] !~ /^\*\*[^*]+\*\*:?[[:space:]]*$/)
                why = sprintf("line %d is not a lone bold lead-in, so the marker may be wrapped prose", cited - 1)
            if (why != "") {
                print why > "/dev/stderr"
                exit 4   # 4 = this note does not carry the shape this fixer owns: refuse it
            }
            for (i = 1; i < cited; i++) print line[i]
            print ""
            for (i = cited; i <= NR; i++) print line[i]
        }
    ' "$note" > "$tmp" 2>"$tmp.why"; then
        if mv "$tmp" "$note"; then
            rm -f "$tmp.why"
            echo "memory-markdownlint: FIXED the blank line MD032 asks for above line $cited of $note."
            printf '%s\n' "$note" >> "$FIXED_LIST"
        else
            # A FIXED line here would be a success message with no write behind it.
            shape_refuse "$note" MD032 "the repaired copy could not be moved into place"
            rm -f "$tmp" "$tmp.why"
        fi
    else
        shape_refuse "$note" MD032 "$(sed -n '1p' "$tmp.why")"
        rm -f "$tmp" "$tmp.why"
    fi
}

# fix_md041 — add the H1 the store's convention takes from the note's own frontmatter name.
fix_md041() {  # fix_md041 <note>
    note="$1"
    title="$(shape_fm_name "$note")"
    if [[ -z "$title" ]]; then
        shape_refuse "$note" MD041 "its frontmatter carries no 'name:' to take the H1 from"
        return
    fi
    tmp="$note.md041-fix.$$"
    if awk -v title="$title" '
        { line[NR] = $0 }
        END {
            why = ""
            if (line[1] != "---") {
                why = "the file does not open with frontmatter"
            } else {
                endfm = 0
                for (i = 2; i <= NR; i++) if (line[i] == "---") { endfm = i; break }
                if (!endfm) {
                    why = "its frontmatter never closes"
                } else {
                    first = 0
                    for (i = endfm + 1; i <= NR; i++)
                        if (line[i] !~ /^[[:space:]]*$/) { first = i; break }
                    if (!first)
                        why = "it has no content line below the frontmatter"
                    else if (line[first] ~ /^#[[:space:]]/)
                        why = sprintf("line %d already opens with an H1, so the report was stale", first)
                }
            }
            if (why != "") {
                print why > "/dev/stderr"
                exit 4   # 4 = this note does not carry the shape this fixer owns: refuse it
            }
            for (i = 1; i <= endfm; i++) print line[i]
            print ""
            print "# " title
            print ""
            for (i = first; i <= NR; i++) print line[i]
        }
    ' "$note" > "$tmp" 2>"$tmp.why"; then
        if mv "$tmp" "$note"; then
            rm -f "$tmp.why"
            echo "memory-markdownlint: FIXED the missing H1 in $note (MD041, from its frontmatter name)."
            printf '%s\n' "$note" >> "$FIXED_LIST"
        else
            # A FIXED line here would be a success message with no write behind it.
            shape_refuse "$note" MD041 "the repaired copy could not be moved into place"
            rm -f "$tmp" "$tmp.why"
        fi
    else
        shape_refuse "$note" MD041 "$(sed -n '1p' "$tmp.why")"
        rm -f "$tmp" "$tmp.why"
    fi
}

# shape_cites — the report's cites for one rule as "<note> <line>", HIGHER line first within a note,
# because an MD032 fix inserts a line and would shift every cite below it.
shape_cites() {  # shape_cites <rule>
    printf '%s\n' "$report" | grep -F " error $1/" |
        sed -nE 's/^([^:]+):([0-9]+)(:[0-9]+)? error .*/\1 \2/p' |
        sort -k1,1 -k2,2nr
}

# fix_shape — drive both repairs; MD041 last because it inserts lines too, though it ignores its cite.
fix_shape() {
    for rule in MD032 MD041; do
        shape_cites "$rule" | while read -r note cited; do
            [[ -n "$note" ]] || continue
            [[ -f "$note" ]] || continue
            case "$rule" in
                # shape_cites selects only these two rules, so no other arm is reachable.
                MD032) fix_md032 "$note" "$cited" ;;
                MD041) fix_md041 "$note" ;;
            esac
        done
    done
}

# ── fix_final_newline (MD047) ──────────────────────────────────────────────────────────────
# THE QUARANTINE IS NOW A FIX.  Every other shape this hook can repair is reported by the turn hook
# and then repaired by a later turn — but MD047 is fully determined by the file's own last byte, so
# there is nothing to interpret and nothing to be wrong about.  Leaving it to the advice block meant
# one MD047 per extraction wave, each cleared by hand in whichever turn the hook happened to fire,
# and a note never touched again kept its finding.  v6 of the writer payload states the rule in the
# extractor's prompt; this repairs what a prompt cannot guarantee.
#
# TWO SHAPES, BOTH CLOSED: a missing final newline (append one) and a run of trailing blank lines
# (collapse to one).  Exactly one "\n" is the contract, so the fix is a byte operation on the tail,
# never a re-render. NO --fix, NO FULL CONFIG: the restricted config the advice block recommends is
# right for whitespace only, but it cannot even express "exactly one", and running the linter here
# would put a formatter in the write path of every turn's verdict.  awk rewrites the tail; the whole
# note is read back and compared byte-for-byte with what was intended.
fix_final_newline() {
    printf '%s\n' "$report" | grep -F 'MD047' | cut -d: -f1 | sort -u |
        while IFS= read -r note; do
            [[ -f "$note" ]] || continue
            [[ -r "$note" && -w "$note" ]] || {
                shape_refuse "$note" MD047 "the note is not readable and writable"
                continue
            }
            tmp="$note.finalnewline-fix.$$"
            # Keep every line, then emit exactly one newline at the end. printf '%s\n' per line
            # without the trailing blank run: awk drops trailing empty lines by construction,
            # because the last non-empty line is the last thing it prints.
            # The long awk invocation is split so the swallow marker sits on its own line:
            # the 120-column bound counts the code, not the comment that justifies it.
            if awk '
                { lines[NR] = $0 }
                END {
                    last = NR
                    while (last > 0 && lines[last] == "") last--
                    for (i = 1; i <= last; i++) print lines[i]
                }
            ' "$note" > "$tmp" 2>/dev/null  # swallow-ok: a failed rewrite is REFUSED by name below
            then
                # HOLD THE RESULT TO THE CONTRACT, NOT TO A COPY OF ITSELF.  The first version
                # appended a newline to a copy of the rewritten file and compared — but that file
                # already ends in one, so the two could never match and every note was refused with
                # "did not read back as intended" while the rewrite was in fact correct.  The
                # contract is narrower than a copy: the last byte is a newline and the byte before
                # it is not.  Both are read back from the file after the move.
                if mv "$tmp" "$note" &&
                    [[ "$(tail -c 1 "$note" | od -An -c | tr -d ' ')" == '\n' ]] &&
                    [[ "$(tail -c 2 "$note" | od -An -c | tr -d ' ')" != '\n\n' ]]; then
                    echo "memory-markdownlint: FIXED final newline in $note (MD047)."
                    printf '%s\n' "$note" >> "$FIXED_LIST"
                else
                    echo "memory-markdownlint: REFUSED to fix MD047 in $note —" \
                        "the note does not read back as ending in exactly one newline."
                fi
            else
                shape_refuse "$note" MD047 "the note could not be rewritten"
            fi
            rm -f "$tmp"
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
if printf '%s\n' "$report" | grep -qE 'MD041/|MD032/'; then
    fix_shape
fi
if printf '%s\n' "$report" | grep -qF 'MD047'; then
    fix_final_newline
fi

# Re-lint the notes a fixer touched, so the verdict below describes the tree AS IT NOW IS rather
# than the tree it was.  A fix that is not re-measured is a claim, not a result.  Findings for notes
# NO fixer touched are KEPT: otherwise a refusal would be replaced by a clean re-lint of the notes
# that were repaired, and the defect would drop out of the verdict while still sitting on disk.
if [[ -s "$FIXED_LIST" ]]; then
    relint="$(xargs -d '\n' -a "$FIXED_LIST" "$LINTER" --config "$CONFIG" 2>&1)"
    status=$?
    kept="$(printf '%s\n' "$report" | grep -vF -f "$FIXED_LIST")"
    report="${kept}${relint}"
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
echo "ONE MD004 IS A TRAP FOR THAT LAST RULE: if a line BEGINS with + - or * because the writer wrapped a"
echo "formula or a code span, that marker is TEXT, not a list marker. REFLOW it onto the previous line —"
echo "rewriting it to the note's list style changes the arithmetic while the note still lints clean."
echo "Always re-read every line a fixer touched: a clean exit code is not evidence the text survived."
exit 0

# end of file
