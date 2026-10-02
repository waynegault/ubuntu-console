#!/usr/bin/env bash
# qwen-memory-style-patch.sh — state the memory store's Markdown style in the Qwen CLI's
# managed auto-memory extractor prompt, after a CLI or companion update reverts it.
#
# ONE HUNK (reported separately by --check; re-applied after an update):
#
#   extractor-style (LOCAL PATCH 2026-10-02 (qwen-memory-extractor-style))
#     WHERE THE VIOLATIONS COME FROM, MEASURED 2026-10-02.  The CLI's managed auto-memory
#     extractor — a forked agent run INSIDE the CLI process, `managed-auto-memory-extractor`
#     (runForkedAgent, tools read_file/grep/glob/write_file/edit, maxTurns 5), driven by
#     EXTRACTION_AGENT_SYSTEM_PROMPT — rewrites the memory notes of `~/.qwen` unattended,
#     after user turns, with no agent-visible tool call and no transcript of its own.
#     Those stores are linted by ~/.qwen/hooks/memory-markdownlint.sh under
#     ~/.qwen/.markdownlint.jsonc, where MD049 keeps its DEFAULT ("consistent"): emphasis style
#     must agree WITHIN a file, and the store's dominant style is underscore.  So a note that
#     already uses underscores and then gains an asterisk span is flagged twice per span.  The
#     extractor's prompt says NOTHING about emphasis style: measured, the words italic / emphasis /
#     underscore / markdown / lint do not appear anywhere in it.  So the model applies its
#     own default (asterisks) and the violation is re-created every time the note is
#     rewritten.  Measured on one note — file-history 2143f15343b2dc6c@v9/@v10/@v11 of
#     spec-vv-006-spec-split-and-companion-table-2026-10-01.md — the asterisk-span count
#     rose 2 -> 4 -> 7 across successive passes: the writer re-creates the violation class
#     it is editing around, which is why a hand-fix of the text alone is reverted by the
#     next pass that touches the file.
#     FIX: insert ONE rule element into EXTRACTION_AGENT_SYSTEM_PROMPT, so the last thing
#     the extractor reads before it writes states the style.  The same element also carries
#     the second class this store's linter flags (MD032, blank lines around lists): one
#     array element costs nothing extra, and its general half ("match the store's Markdown
#     style") is what a future extractor can extend.  Anything beyond those two is OWED
#     UPSTREAM (filed 2026-10-02): the durable fix is the CLI telling the extractor the
#     store's style, or linting the files the extractor writes.
#     NOT A LINTER CHANGE: the store's markdownlint config is NOT touched by this patch.
#     A warning is answered by removing its cause, never by relaxing the rule that found it.
#
# WHY A SIBLING SCRIPT AND NOT A HUNK IN qwen-memory-index-patch.sh
#   That script's whole body — its markers, its stock anchors (MAX_INDEX_LINE_CHARS), its
#   post-conditions — is about the INDEX BUILDER.  This defect is a different mechanism with
#   a different anchor, a different file selector and different post-conditions, and the two
#   have different retirement dates: the index hunks are retired when the indexer stops
#   cutting links, this one when the CLI states a style.  Separately they can each be
#   dropped on the day upstream ships, and each keeps its own --check state.  What they
#   share is the PATTERN, and the self-heal watchdog, which is the one place a new patch
#   tool has to be announced (bin/qwen-guard-selfheal.sh).
#
# WHICH COPY MATTERS
#   Every shipped copy is patched, because which copy extracts depends on where the session
#   runs: the linuxbrew CLI, the WSL-side IDE companion (this box's live session), the
#   Windows-side IDE companion, and the npm update cache.  THE BUNDLE IS FOREIGN (the Qwen
#   CLI): the patch lives on disk only, so a CLI or companion update reverts it and --check
#   goes red again — re-run this script then, or let the existing self-heal cron do it.
#
# SAFETY
#   * Patches by EXACT string match and refuses anything it does not recognise — a future
#     bundle whose prompt shape changed is REPORTED, never patched blind; the copy is left
#     byte-identical.
#   * Per-copy all-or-nothing: the extraction prompt must be present exactly once and the
#     anchor must match exactly once, or nothing is written for that copy.
#   * The pristine backup (`.orig`) is taken before the first patch and never overwritten.
#   * Runs `node --check` afterwards and rolls the copy back from its backup if the bundle
#     stops parsing.
#   * Idempotent: a copy already carrying the marker is left alone.
#
# USAGE
#   qwen-memory-style-patch.sh          # apply (or report) for every installed copy
#   qwen-memory-style-patch.sh --check  # report only; exit 1 if any copy is unpatched
#
#   QWEN_STYLE_PATCH_CHUNK_DIRS=<dir>[:<dir>…]  # scan ONLY these chunk dirs.  The test/CI
#   affordance: CI has no CLI bundle, and a fixture run must not reach the real copies.
#
# TRACKED HERE since 2026-10-02: `install.sh` links every file in `bin/` into ~/.local/bin,
# so the stable path keeps resolving while the implementation is reviewable (and this
# patcher is re-runnable by anyone) here.
#
# AI INSTRUCTION: Increment version on significant changes.
# Module Version: 1
set -euo pipefail

MARKER="LOCAL PATCH 2026-10-02 (qwen-memory-extractor-style)"
EXTRACTOR_NAME="You are now acting as the managed memory extraction subagent"

check_only=0
[[ "${1:-}" == "--check" ]] && check_only=1

shopt -s nullglob
if [[ -n "${QWEN_STYLE_PATCH_CHUNK_DIRS:-}" ]]; then
    IFS=: read -r -a chunk_dirs <<<"$QWEN_STYLE_PATCH_CHUNK_DIRS"
else
    chunk_dirs=(
        # CLI on PATH (linuxbrew node_modules)
        /home/linuxbrew/.linuxbrew/lib/node_modules/@qwen-code/qwen-code/chunks
        # other global node_modules the CLI may be installed into
        "$HOME"/.local/lib/node_modules/@qwen-code/qwen-code/chunks
        "$HOME"/.npm-global/lib/node_modules/@qwen-code/qwen-code/chunks
        # WSL-side (remote) IDE companion — a WSL session runs this copy
        "$HOME"/.vscode-server/extensions/qwenlm.qwen-code-vscode-ide-companion-*/dist/qwen-cli/chunks
        # Windows-side IDE companion — a Windows-hosted session runs this copy
        /mnt/c/Users/*/.vscode/extensions/qwenlm.qwen-code-vscode-ide-companion-*/dist/qwen-cli/chunks
        # npm update cache
        "$HOME"/.qwen/updates/npm/*/versions/*/node_modules/@qwen-code/qwen-code/chunks
    )
fi

files=()
for d in "${chunk_dirs[@]}"; do
    [[ -d "$d" ]] || continue
    for f in "$d"/*.js; do
        # the extractor's system prompt is the only construct carrying this sentence
        # swallow-ok: the loop above already skipped a missing dir, so this hides only grep's own I/O error on a chunk that vanished mid-glob
        if grep -qF "$EXTRACTOR_NAME" "$f" 2>/dev/null; then
            files+=("$f")
        fi
    done
done

if (( ${#files[@]} == 0 )); then
    echo "qwen-memory-style-patch: no Qwen auto-memory extractor chunk found — nothing to do"
    exit 0
fi

rc=0
for f in "${files[@]}"; do
    name="${f/#$HOME/~}"

    state="UNKNOWN"
    if grep -qF "$MARKER" "$f"; then state="applied"
    elif grep -qF "\"Memory file format reference:\",...MEMORY_FRONTMATTER_EXAMPLE]" "$f" \
      || grep -qF "\"Memory file format reference:\"," "$f"; then state="stock"; fi

    if [[ "$state" == "applied" ]]; then
        echo "  ok       $name (extractor-style: applied)"
        continue
    fi

    if (( check_only )); then
        echo "  NEEDS    $name (extractor-style: $state)" >&2
        rc=1
        continue
    fi

    backup="$f.orig"
    if [[ ! -f "$backup" ]]; then
        cp -p "$f" "$backup"
        echo "  backup   ${backup/#$HOME/~}"
    fi

    # Exact-match, per-copy all-or-nothing: the anchor must occur exactly once, or nothing
    # is written.  Post-conditions then re-check the promises before the file is replaced.
    if ! PATCH_FILE="$f" PATCH_MARKER="$MARKER" python3 - <<'PY'
import os
import pathlib

p = pathlib.Path(os.environ["PATCH_FILE"])
marker = os.environ["PATCH_MARKER"]
EXTRACTOR = "You are now acting as the managed memory extraction subagent"

# The rule element, as a JS string literal.  One line, imperative, in the prompt's own
# voice (the surrounding rules all begin "- ").  Emphasis is the measured defect; the
# blank-line clause is this store's other flagged class (MD032); the first half is the
# general instruction a future extractor can extend.
rule_text = (
    "- Match the store's Markdown style: emphasis with underscores (_like this_), never "
    "asterisks (*like this*), and a blank line before and after every list."
)
rule_literal = '"' + rule_text + '"'

MIN_ANCHOR = '"Memory file format reference:",...MEMORY_FRONTMATTER_EXAMPLE]'
SPACED_ANCHOR = '"Memory file format reference:",\n  ...MEMORY_FRONTMATTER_EXAMPLE\n]'

src = p.read_text(encoding="utf-8")

# Pre-conditions: the extractor prompt is present exactly once, and exactly one of the two
# anchor spellings matches exactly once.
if src.count(EXTRACTOR) != 1:
    raise SystemExit(
        f"refusing to patch: the extractor prompt sentence occurs {src.count(EXTRACTOR)} times (expected 1)"
    )
min_hits = src.count(MIN_ANCHOR)
spaced_hits = src.count(SPACED_ANCHOR)
if min_hits + spaced_hits != 1:
    raise SystemExit(
        f"refusing to patch: no single anchor matched (minified={min_hits}, pretty-printed={spaced_hits})"
    )

if min_hits == 1:
    new = "/* %s */%s," % (marker, rule_literal) + MIN_ANCHOR
    src = src.replace(MIN_ANCHOR, new)
else:
    new = "/* %s */\n  %s,\n  " % (marker, rule_literal) + SPACED_ANCHOR
    src = src.replace(SPACED_ANCHOR, new)

# Post-conditions: everything this patch promises must be present in the text about to be
# written, and the anchor must survive it.
if src.count(marker) != 1:
    raise SystemExit("refusing to patch: the marker is not present exactly once in the result")
if src.count(rule_literal) != 1:
    raise SystemExit("refusing to patch: the rule element is not present exactly once in the result")
if src.count(EXTRACTOR) != 1:
    raise SystemExit("refusing to patch: the extractor prompt sentence did not survive the edit")
if src.count(MIN_ANCHOR) + src.count(SPACED_ANCHOR) != 1:
    raise SystemExit("refusing to patch: the anchor did not survive the edit")
if src.index(marker) > src.index(MIN_ANCHOR if min_hits == 1 else SPACED_ANCHOR):
    raise SystemExit("refusing to patch: the rule landed after the format reference, not before it")

p.write_text(src, encoding="utf-8")
print("  patched  extractor-style")
PY
    then
        echo "  MISMATCH $name — an anchor did not match; the chunk is UNCHANGED (backup kept)" >&2
        rc=1
        continue
    fi

    if node --check "$f"; then
        echo "  patched  $name (syntax verified)"
    else
        echo "  BROKEN   $name — rolling back from ${backup/#$HOME/~}" >&2
        cp -p "$backup" "$f"
        rc=1
    fi
done

if (( rc == 0 )); then
    echo "qwen-memory-style-patch: done. The Qwen CLI bundle is FOREIGN — a CLI/companion update reverts this; re-run this script (or let the --check self-heal cron do it) after any update."
fi
exit "$rc"
# end of file
