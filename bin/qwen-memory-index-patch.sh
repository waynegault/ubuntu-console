#!/usr/bin/env bash
# qwen-memory-index-patch.sh — re-apply the local fixes to the Qwen CLI's memory-index
# builder, after a CLI/companion update replaces the bundled chunk.
#
# FIVE HUNKS (each reported separately by --check; each re-applied after an update):
#
#   1. truncator (LOCAL PATCH 2026-10-01 (qwen-memory-index-patch))
#      The indexer builds every MEMORY.md line as
#         docIndexLine(doc) = `- [title](relative/path.md) — description`
#      and then passes it through
#         truncateIndexLine(text) = text.length <= 150 ? text : `${text.slice(0,149).trimEnd()}…`
#      i.e. it cuts the WHOLE line at MAX_INDEX_LINE_CHARS = 150.  Because the "[title](" and
#      the link path sit at the head, the cut lands inside the link: the path is chopped and a
#      dangling "…" is left, so the entry's link no longer resolves.  Measured 2026-10-01:
#      every MEMORY.md in every ~/.qwen store read bad=N/N under the index checker (the line
#      ends in a literal ellipsis, or has no link at all).
#      FIX: never cut the "](path)" part.  Locate the link, keep it (and any trailing
#      "(also: …)" group) byte-for-byte, shorten ONLY the trailing text — at a sentence
#      boundary, else a clause boundary, else a word boundary — and leave no trailing
#      ellipsis (a line ending in "…" is itself the defect the checker reports).  If the link
#      alone already meets the cap the line is returned whole; it may exceed 150 chars, which
#      is the point: the link must resolve.
#
#   2. pathcap (part of hunk 1's marker)
#      encodeIndexPathTarget caps the path at MAX_INDEX_FIELD_CHARS = 120
#      (`[...value].slice(0, MAX_INDEX_FIELD_CHARS)`), cutting long paths before the line cap
#      even applies.  FIX: drop that slice — the path is never capped.
#
#   3. bytecap (LOCAL PATCH 2026-10-01 (qwen-memory-index-bytecap))
#      assembleIndex applied MAX_INDEX_BYTES = 25000 and SILENTLY dropped the tail.  With
#      link-safe lines (hunk 1) the index is longer, so the cap began to bite: measured
#      2026-10-01, a 161-entry store shed 14 entries.  A silently-dropped entry is worse than
#      a truncated one — a broken line at least shows the entry exists.
#      FIX: RAISE the cap to 256000 and, if ANYTHING is still dropped (byte cap OR the
#      MAX_INDEX_LINES = 200 line cap), append a marker that NAMES the loss — how many of how
#      many entries were written and how many were dropped, and which cap caused it — so a
#      shortened index can never be mistaken for a whole one.
#      ALSO: the scan caps at MAX_SCANNED_MEMORY_FILES = 200 BEFORE assembleIndex runs, so a
#      >200-note store sheds silently and the marker above would never fire (measured
#      2026-10-01: a 250-note store produced exactly 200 lines and no marker).  The two INDEX
#      rebuilds are pointed at the uncapped scanners so the marker can name the drop; the
#      extraction agent's own capped scan is left alone, so its context budget is unchanged.
#      WHY RAISE, NOT REMOVE: the index is read into EVERY session's context, so an unbounded
#      index is an unbounded per-turn cost.  256000 B is ~10x the largest store measured here
#      (25 KB / 161 entries) — no realistic store sheds — while still bounding a pathological
#      one.  THE COST, NAMED: if a store ever reaches the cap, up to 256000 B of index
#      (roughly 64k tokens at ~4 bytes/token) is loaded into every session — that is why this
#      is a backstop rather than a target, and why the marker matters when it is hit.
#
#   4. titlecap (LOCAL PATCH 2026-10-11 (qwen-memory-index-titlecap))
#      docIndexLine budgets the HOOK around the link but never the TITLE.  The title is only
#      capped by sanitizeIndexField at MAX_INDEX_FIELD_CHARS = 120, so a long `name:` beside a
#      long relative path emits `- [title](path)` with NO hook and a length of up to ~189 —
#      MAX_INDEX_LINE_CHARS = 150 is not enforced on the line at all.  Measured 2026-10-11 on
#      real stores: every over-cap line was this shape, and it is the branch that skips the
#      hook, so the entries carrying a summary are systematically the short-titled ones.
#      FIX: budget the title from the PATH exactly as the hook is budgeted from the link —
#      truncateIndexField(title, max(8, MAX_INDEX_LINE_CHARS - 6 - target.length)) — so link2
#      always fits, room is >= MIN_INDEX_HOOK_CHARS whenever any room exists (the hook then
#      appears instead of being skipped), and the line cannot overshoot the cap.  The floor of
#      8 and the principle both follow hunk 1: a path long enough to leave less than 8 chars
#      for the title would otherwise overflow — and there the LINK wins, as it must, because a
#      resolvable long link beats a short dead one.
#      Filed upstream 2026-10-11 as QwenLM/qwen-code#13910.
#
#   5. linecap (LOCAL PATCH 2026-10-11 (qwen-memory-index-linecap))
#      MAX_INDEX_LINES = 200 is a HARD cap and it is not the note count a real project store
#      reaches: measured 2026-10-11, a 245-note store produced 200 index lines and 45 notes
#      that no index entry points at (the hunk-3 marker named them).  Shortening lines does not
#      help — the cap counts lines.  FIX: RAISE it to 400.  The byte cap (hunk 3, 256000) still
#      bounds a pathological store, so this trades a per-turn cost of at most ~60 KB for the
#      reachability of 45+ authored notes.
#
# WHICH COPY MATTERS
#   Every shipped copy is patched (this script globs the CLI, the WSL and Windows IDE
#   companions, and the npm update-cache), because which copy enforces a session depends on
#   where that session runs.  THE BUNDLE IS FOREIGN (the Qwen CLI): the patch lives on disk
#   only, so a CLI or companion update reverts it and --check goes red again — re-run this
#   script then (the self-heal style cron that calls --check will re-apply it).
#
# SAFETY
#   * Patches by EXACT string match and refuses anything it does not recognise — a future
#     bundle whose shape has changed is REPORTED, never patched blind.
#   * Per-copy all-or-nothing: every hunk a copy still needs must find its anchor, or the copy
#     is left byte-identical and reported MISMATCH.  The pristine backup is taken before the
#     first patch and is never overwritten.
#   * Runs `node --check` afterwards and rolls back the copy from its backup if the bundle
#     stops parsing.
#   * Idempotent: a copy already carrying a hunk's marker is left alone for that hunk.
#
# USAGE
#   qwen-memory-index-patch.sh          # apply (or report) for every installed copy
#   qwen-memory-index-patch.sh --check  # report only; exit 1 if any copy is unpatched
#
#   QWEN_INDEX_PATCH_CHUNK_DIRS=<dir>[:<dir>…]  # scan ONLY these chunk dirs.  The test/CI
#   affordance: CI has no CLI bundle, and a fixture run must not reach the real copies.
#
# TRACKED HERE since 2026-10-01: this script used to exist only as a loose copy at
# ~/.local/bin/qwen-memory-index-patch.sh, so a fix nobody could re-verify lived
# outside version control.  `install.sh` links every file in `bin/` into
# ~/.local/bin, so the stable path keeps resolving while the implementation is
# reviewable (and re-runnable by anyone) here.
#
# AI INSTRUCTION: Increment version on significant changes.
# Module Version: 8
#   v8 (2026-10-25): 0.26.1 SHIPS A REWRITTEN BUILDER and the tooling only half-knows it.  Two
#   predicates repaired, one blocker remains, and NO 0.26.1 COPY IS PATCHED BY THIS VERSION:
#     * the Python-side UPSTREAM test hardcoded `room=MAX_INDEX_LINE_CHARS-link2.length` while the
#       shell side had already been made regex-tolerant (v7).  So `--check` printed
#       "truncator: upstream" and the apply computed UPSTREAM=False and REFUSED -- one predicate,
#       two implementations, one of them fixed.  The report and the action disagreed about the same
#       file in the same run.  Both sides now use the same regex.
#     * the MIN title anchor hardcoded the minifier's link index (`link2`); 0.26.1 says `link4`.
#       The index is not the property, so capture the name and emit it back.
#   STILL BLOCKED: 0.26.1's assembleIndex calls trimIndexToBudget(lines,priorityPrefixLength) and
#   the bytecap post-condition ("assembleIndex definition count is not 1") fails, so a 0.26.1 chunk
#   is still REFUSED and left byte-identical (backup kept, node --check never reached).  Patching
#   0.26.1 therefore needs a fourth anchor derived before the menu item is real.  Verified on a
#   throwaway copy under a temp HOME, 2026-10-25: apply rc=1, caps still 25e3/200, chunk unchanged;
#   the five already-patched copies stay ok and byte-identical.
#   v6 (2026-10-15): embedded Python uses the shared repository-venv-first resolver.
#   v5 (2026-10-14): recognise CLI 0.25.1, which RENAMED the byte cap `MAX_INDEX_BYTES` ->
#   `MAX_INDEX_CHARS` and SPLIT assembleIndex: the kept-Set budget moved into trimIndexToBudget
#   and upstream now appends its OWN INDEX_TRUNCATION_NOTICE whenever it sheds (that notice
#   names no count).  Before this, `--check` read `bytecap: UNKNOWN` and the apply REFUSED with
#   "no known MAX_INDEX_BYTES declaration (UNKNOWN shape)"; the rename was the ONLY blocker, as
#   hunks 4-5's anchors match 0.25.1, but hunk 3 is all-or-nothing per copy, so the whole copy
#   was abandoned.  TWO TRAPS on this shape: (1) hunk 3's two UNCAPPED-SCAN rewires are SKIPPED
#   -- `MAX_SCANNED_MEMORY_FILES` is gone, so there is no cap to lift, yet the rewire anchors DO
#   match and the substitution would silently turn a working upstream call into one with the
#   wrong arguments, which `node --check` cannot detect; (2) the two "no DROPPED marker"
#   post-conditions are guarded on INDEX_TRUNCATION_NOTICE, because upstream's own notice is
#   the "never shed silently" half there and it names no count.  A new fixture
#   (tests/fixtures/memory-index-v0251-chunk.js -- the 0.25.0 fixture with the rename + the
#   split, keeping both scan-rewire anchors so the SKIP is provable) and three new cases in
#   tests/unit/51-memory-index-patch.bats prove it end to end.
#   v4 (2026-10-11): hunks 4 (titlecap) and 5 (linecap).  docIndexLine budgeted the hook around
#   the link but never the title, so MAX_INDEX_LINE_CHARS = 150 was unenforced on the line (a
#   long title plus a long path emitted a no-hook line of up to ~189); the title is now
#   budgeted from the path, in BOTH shapes (the 0.24.x pretty-printed docIndexLine and the
#   0.25.0 minified one).  MAX_INDEX_LINES is raised 200 -> 400, because a real 245-note store
#   shed 45 entries under the old cap and no amount of line shortening changes a line count.
#   The fixture gained the real 0.25.0 docIndexLine (plus sanitizeIndexField and
#   encodeIndexPathTarget) so both new hunks are exercised without a foreign bundle, and a new
#   harness (tests/helpers/memory-index-titlecap-harness.mjs) proves the title budget
#   behaviourally.  Upstream: QwenLM/qwen-code#13910.
#   v3 (2026-10-06): hunk 3 is now DERIVED for 0.25.0, which REWROTE assembleIndex.  Its body
#   no longer cuts the joined text at a newline before the byte cap; it keeps a `kept` Set of
#   entry indexes (short lines first, then longer ones that still fit) and re-joins them IN
#   INDEX ORDER, still shedding the surplus SILENTLY behind the same generic warning.  A third
#   stock spelling (STOCK_ASSEMBLE_V025) and a matching replacement (NEW_ASSEMBLE_V025) are
#   added, the byte cap is raised there too, and the marker NAMES the loss while keeping the
#   stock sentence as a prefix.  Also fixes a defect that made an APPLY to 0.25.0 impossible:
#   two post-conditions assumed hunk 1 had run and demanded a `truncateIndexLine` definition
#   and its marker, neither of which exists in the upstream-shaped copy — so the hunk-3 apply
#   would have been refused even once its anchor matched (measured 2026-10-06).  A test
#   affordance (QWEN_INDEX_PATCH_CHUNK_DIRS) and a node harness (tests/helpers/
#   memory-index-assemble-harness.mjs) now prove hunk 3's behaviour, which CI cannot reach
#   through the four real foreign bundles.
#   v2 (2026-10-06): recognise that 0.25.0 SATISFIES hunks 1 and 2 UPSTREAM.  Its builder
#   dropped `truncateIndexLine` for `truncateIndexField` and now budgets the description
#   around the link (`room = MAX_INDEX_LINE_CHARS - link.length - ...`), and
#   `encodeIndexPathTarget` no longer slices the path.  Measured 2026-10-05: both 0.25.0
#   companions reported "no known stock truncateIndexLine body (UNKNOWN shape)" and were
#   refused, which read as OUR patch being broken.  A chunk carrying both 0.25.0 spellings is
#   now reported `upstream` (satisfied, nothing to apply).  Hunk 3 remains OWED there: the
#   byte cap is still 25e3 and its assembleIndex was rewritten, so a new stock spelling and a
#   matching replacement are still to be derived -- --check says `bytecap: stock` for exactly
#   that copy rather than MISMATCH.
set -euo pipefail

_BIN_PATH="$(readlink -f -- "${BASH_SOURCE[0]}")"
REPO_ROOT="$(cd "$(dirname "$_BIN_PATH")/.." && pwd)"
# shellcheck source=tools/python-runtime.sh
source "$REPO_ROOT/tools/python-runtime.sh"
PYTHON_BIN="$(_tac_python_path "$REPO_ROOT")"

MARKER_TRUNC="LOCAL PATCH 2026-10-01 (qwen-memory-index-patch)"
MARKER_BYTES="LOCAL PATCH 2026-10-01 (qwen-memory-index-bytecap)"
MARKER_TITLE="LOCAL PATCH 2026-10-11 (qwen-memory-index-titlecap)"
MARKER_LINES="LOCAL PATCH 2026-10-11 (qwen-memory-index-linecap)"

# Stock anchors used only for state detection in --check.
PATHCAP_STOCK_SPACED='const chars = [...value].slice(0, MAX_INDEX_FIELD_CHARS);'
PATHCAP_STOCK_MIN='const chars=[...value].slice(0,MAX_INDEX_FIELD_CHARS);'
BYTES_STOCK_SPACED='var MAX_INDEX_BYTES = 25e3;'
BYTES_STOCK_MIN='var MAX_INDEX_BYTES=25e3;'
# 0.25.1 RENAMED the byte cap (measured 2026-10-14): the same 25e3 value under a new name.  A
# copy whose cap is UNKNOWN while titlecap/linecap read `stock` is a 0.25.1 copy.
BYTES_STOCK_V0251_SPACED='var MAX_INDEX_CHARS = 25e3;'
BYTES_STOCK_V0251_MIN='var MAX_INDEX_CHARS=25e3;'
FUNC_TRUNC_STOCK='function truncateIndexLine(text)'
# hunks 4-5 (measured 2026-10-11 on the 0.24.4 linuxbrew CLI and the 0.25.0 companions).
TITLE_STOCK_SPACED='const title = sanitizeIndexField(doc.title) || doc.type;'
TITLE_STOCK_MIN='const title=sanitizeIndexField(doc.title)||doc.type;'
LINES_STOCK_SPACED='var MAX_INDEX_LINES = 200;'
LINES_STOCK_MIN='var MAX_INDEX_LINES=200;'
# 0.25.0 REWROTE the builder (measured 2026-10-05 on the IDE companion's
# chunk-QJ3UTSP5.js): `truncateIndexLine` is GONE, `docIndexLine` now budgets the
# description AROUND the link (`room = MAX_INDEX_LINE_CHARS - link.length - suffix.length -
# separator.length`) so the link is never cut, and `encodeIndexPathTarget` no longer slices
# the path at all.  Hunks 1 and 2 are therefore SATISFIED BY UPSTREAM in this shape: there is
# nothing to patch, and a patch that is missing because upstream fixed it must not be
# reported as a broken bundle.  Both spellings are required, so a chunk that merely happens
# to define a helper named truncateIndexField is not mistaken for the fixed builder.
UPSTREAM_FIELD_TRUNC='function truncateIndexField('
# The room calculation is the PROPERTY; the minifier's variable index is not. 0.26.1
# renamed link2 -> link4 (measured 2026-10-25: 0.26.0 has `-link2.length`, 0.26.1 has
# `-link4.length`, same builder) and that rename alone made a correctly-fixed upstream
# bundle report `truncator: UNKNOWN` -> the guard red every tick. An anchor spelled with a
# build-specific index turns a re-minified-but-correct bundle into a defect report, which is
# a fixture standing in for its subject. Match the shape, wildcard the index.
UPSTREAM_ROOM_CALC='room=MAX_INDEX_LINE_CHARS-link[0-9]*\.length'

check_only=0
[[ "${1:-}" == "--check" ]] && check_only=1

shopt -s nullglob
if [[ -n "${QWEN_INDEX_PATCH_CHUNK_DIRS:-}" ]]; then
    IFS=: read -r -a chunk_dirs <<<"$QWEN_INDEX_PATCH_CHUNK_DIRS"
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
        # the indexer is the only construct carrying this constant
        # swallow-ok: the loop above already skipped a missing dir, so this hides only grep's own I/O error on a chunk that vanished mid-glob
        if grep -qF "MAX_INDEX_LINE_CHARS" "$f" 2>/dev/null; then
            files+=("$f")
        fi
    done
done

if (( ${#files[@]} == 0 )); then
    echo "qwen-memory-index-patch: no Qwen memory-index chunk found — nothing to do"
    exit 0
fi

rc=0
for f in "${files[@]}"; do
    name="${f/#$HOME/~}"

    st_trunc="UNKNOWN"
    if grep -qF "$MARKER_TRUNC" "$f"; then st_trunc="applied"
    elif grep -qF "$FUNC_TRUNC_STOCK" "$f"; then st_trunc="stock"
    elif grep -qF "$UPSTREAM_FIELD_TRUNC" "$f" && grep -qE "$UPSTREAM_ROOM_CALC" "$f"; then st_trunc="upstream"; fi

    st_path="applied"
    if grep -qF "$PATHCAP_STOCK_SPACED" "$f" || grep -qF "$PATHCAP_STOCK_MIN" "$f"; then st_path="stock"; fi

    st_bytes="UNKNOWN"
    if grep -qF "$MARKER_BYTES" "$f"; then st_bytes="applied"
    elif grep -qF "$BYTES_STOCK_SPACED" "$f" || grep -qF "$BYTES_STOCK_MIN" "$f" \
      || grep -qF "$BYTES_STOCK_V0251_SPACED" "$f" || grep -qF "$BYTES_STOCK_V0251_MIN" "$f"; then
        st_bytes="stock"
    fi

    st_title="UNKNOWN"
    if grep -qF "$MARKER_TITLE" "$f"; then st_title="applied"
    elif grep -qF "$TITLE_STOCK_SPACED" "$f" || grep -qF "$TITLE_STOCK_MIN" "$f"; then st_title="stock"; fi

    st_lines="UNKNOWN"
    if grep -qF "$MARKER_LINES" "$f"; then st_lines="applied"
    elif grep -qF "$LINES_STOCK_SPACED" "$f" || grep -qF "$LINES_STOCK_MIN" "$f"; then st_lines="stock"; fi

    # `upstream` counts as satisfied: on 0.25.0 the builder already does what hunks 1-2 asked
    # for, so there is nothing to apply and reporting it as missing would be false.
    states="truncator: $st_trunc; pathcap: $st_path; bytecap: $st_bytes"
    states="$states; titlecap: $st_title; linecap: $st_lines"
    if [[ "$st_trunc" == "applied" || "$st_trunc" == "upstream" ]] \
       && [[ "$st_path" == "applied" ]] \
       && [[ "$st_bytes" == "applied" ]] \
       && [[ "$st_title" == "applied" ]] \
       && [[ "$st_lines" == "applied" ]]; then
        echo "  ok       $name ($states)"
        continue
    fi

    if (( check_only )); then
        echo "  NEEDS    $name ($states)" >&2
        rc=1
        continue
    fi

    backup="$f.orig"
    if [[ ! -f "$backup" ]]; then
        cp -p "$f" "$backup"
        echo "  backup   ${backup/#$HOME/~}"
    fi

    # Exact-match, per-copy all-or-nothing: every hunk this copy still needs must find its
    # anchor exactly once, or nothing is written.  Post-conditions then re-check the promises.
    if ! PATCH_FILE="$f" PATCH_MARKER_TRUNC="$MARKER_TRUNC" PATCH_MARKER_BYTES="$MARKER_BYTES" \
         PATCH_MARKER_TITLE="$MARKER_TITLE" PATCH_MARKER_LINES="$MARKER_LINES" "$PYTHON_BIN" - <<'PY'
import os, pathlib, re

p = pathlib.Path(os.environ["PATCH_FILE"])
marker_trunc = os.environ["PATCH_MARKER_TRUNC"]
marker_bytes = os.environ["PATCH_MARKER_BYTES"]
marker_title = os.environ["PATCH_MARKER_TITLE"]
marker_lines = os.environ["PATCH_MARKER_LINES"]
src = p.read_text(encoding="utf-8")

# 0.25.1 (measured 2026-10-14) RENAMED the byte cap MAX_INDEX_BYTES -> MAX_INDEX_CHARS and SPLIT
# assembleIndex: the kept-Set budget moved into trimIndexToBudget, and upstream now appends its
# OWN INDEX_TRUNCATION_NOTICE whenever it sheds (that notice names no count).  MAX_SCANNED_MEMORY_
# FILES is GONE there, so hunk 3's two uncapped-scan rewires have no premise.  The notice is the
# fingerprint: our patch never touches it, so it identifies the shape on a RE-APPLY as well as on
# a first apply (the MAX_INDEX_CHARS spelling does not -- this patch renames it away).
bytes_v0251 = "INDEX_TRUNCATION_NOTICE" in src

# 0.25.0's builder already keeps the link, so hunks 1-2 are upstream-satisfied there.
# Recognised by the same two spellings the shell side uses; without this a copy that needs
# ONLY hunk 3 is refused with "no known stock truncateIndexLine body".
# The room calculation is spelled `-link2.length` in 0.25.0 and `-link4.length` in 0.26.1 -- the
# minifier renumbered the variable.  The shell side learned this on 2026-10-25 (UPSTREAM_ROOM_CALC
# was made a regex for exactly this reason) and the Python side did NOT, so for 0.26.1 the report
# printed "truncator: upstream" while the apply computed UPSTREAM=False, fell through to the stock
# bodies and refused the chunk.  One predicate, two implementations, one of them fixed: the guard
# said the build was fine and the tool refused to touch it, about the same file, in the same run.
UPSTREAM = ("function truncateIndexField(" in src
            and re.search(r"room=MAX_INDEX_LINE_CHARS-link[0-9]*\.length", src) is not None)

# --- hunk 2: drop the 120-char path cap in encodeIndexPathTarget (two spellings) ---
PATHCAP = {
    "const chars = [...value].slice(0, MAX_INDEX_FIELD_CHARS);": "const chars = [...value];",
    "const chars=[...value].slice(0,MAX_INDEX_FIELD_CHARS);": "const chars=[...value];",
}

# --- hunk 1: link-preserving truncateIndexLine (two spellings of the stock body) ---
STOCK_TRUNC_SPACED = (
    "function truncateIndexLine(text) {\n"
    "  if (text.length <= MAX_INDEX_LINE_CHARS) {\n"
    "    return text;\n"
    "  }\n"
    "  return `${text.slice(0, MAX_INDEX_LINE_CHARS - 1).trimEnd()}\\u2026`;\n"
    "}\n"
    '__name(truncateIndexLine, "truncateIndexLine");'
)
STOCK_TRUNC_MIN = (
    "function truncateIndexLine(text){if(text.length<=MAX_INDEX_LINE_CHARS){return text}"
    "return`${text.slice(0,MAX_INDEX_LINE_CHARS-1).trimEnd()}\\u2026`}"
    '__name(truncateIndexLine,"truncateIndexLine");'
)
NEW_TRUNC = r'''function truncateIndexLine(text) {
  // LOCAL PATCH 2026-10-01 (qwen-memory-index-patch): the stock function cut the WHOLE line at
  // MAX_INDEX_LINE_CHARS, so it chopped the "](relative/path)" link target and left a dangling
  // ellipsis. Never cut the link: keep "](...)" (and any trailing "(also: ...)" group)
  // byte-for-byte and shorten only the trailing text - at a sentence boundary, else a clause
  // boundary, else a word boundary - and leave no trailing ellipsis (a line ending in an
  // ellipsis is itself the defect the index checker reports). If the link alone already meets
  // the cap the line is returned whole, so it may exceed 150 chars: the link must resolve.
  let out = text;
  if (text.length > MAX_INDEX_LINE_CHARS) {
    const linkOpen = text.indexOf("](");
    let linkEnd = 0;
    if (linkOpen !== -1) {
      const linkClose = text.indexOf(")", linkOpen + 2);
      if (linkClose !== -1) {
        linkEnd = linkClose + 1;
        const alsoMatch = text.slice(linkEnd).match(/^ \(also: [^)]*\)/);
        if (alsoMatch) {
          linkEnd += alsoMatch[0].length;
        }
      }
    }
    const head = text.slice(0, linkEnd);
    const tail = text.slice(linkEnd);
    const budget = MAX_INDEX_LINE_CHARS - head.length;
    if (tail.length > budget && budget > 0) {
      const balanced = (s) => {
        const stack = [];
        const pairs = { ")": "(", "]": "[", "}": "{" };
        for (const ch of s) {
          if (ch === "(" || ch === "[" || ch === "{") { stack.push(ch); }
          else if (pairs[ch]) { if (stack.pop() !== pairs[ch]) { return false; } }
        }
        return stack.length === 0 && (s.match(/"/g) || []).length % 2 === 0;
      };
      let cut = tail.slice(0, budget);
      const sentence = Math.max(cut.lastIndexOf(". "), cut.lastIndexOf("! "), cut.lastIndexOf("? "));
      if (sentence >= 40) {
        cut = cut.slice(0, sentence + 1);
      } else {
        let clause = -1;
        for (const sep of ["; ", " — ", " – ", ": ", ", "]) {
          clause = Math.max(clause, cut.lastIndexOf(sep));
        }
        if (clause >= 40) {
          cut = cut.slice(0, clause);
        }
        cut = cut.replace(/\s+\S*$/, "").trimEnd().replace(/[ ,;:\u2014\u2013-]+$/, "").trimEnd();
      }
      while (cut && !balanced(cut)) {
        const sp = cut.lastIndexOf(" ");
        if (sp < 0) { cut = ""; break; }
        cut = cut.slice(0, sp).trimEnd();
      }
      out = head + cut;
    }
  }
  while (out.endsWith("\u2026")) {
    out = out.slice(0, -1).trimEnd();
  }
  return out;
}
__name(truncateIndexLine, "truncateIndexLine");'''

# --- hunk 3: raise the byte cap and never shed silently (the cap-declaration spellings) ---
BYTES = {
    "var MAX_INDEX_BYTES = 25e3;": "var MAX_INDEX_BYTES = 256000;",
    "var MAX_INDEX_BYTES=25e3;": "var MAX_INDEX_BYTES=256000;",
    # 0.25.1 renamed the cap.  There the assembleIndex rewrite is SKIPPED (see below), so this
    # replacement must itself carry `marker_bytes` -- that string is what the `applied`
    # detection and the byte-cap post-condition look for, and without NEW_ASSEMBLE nothing else
    # would add it.  The marker's date stays 2026-10-01: the hunk's introduction, not this fix's.
    "var MAX_INDEX_CHARS = 25e3;": "var MAX_INDEX_CHARS = 256000;/* " + marker_bytes + " */",
    "var MAX_INDEX_CHARS=25e3;": "var MAX_INDEX_CHARS=256000;/*" + marker_bytes + "*/",
}
STOCK_ASSEMBLE_SPACED = (
    "function assembleIndex(lines) {\n"
    '  const raw = lines.join("\\n");\n'
    "  const wasLineTruncated = lines.length > MAX_INDEX_LINES;\n"
    '  let truncated = wasLineTruncated ? lines.slice(0, MAX_INDEX_LINES).join("\\n") : raw;\n'
    "  if (truncated.length > MAX_INDEX_BYTES) {\n"
    '    const cutAt = truncated.lastIndexOf("\\n", MAX_INDEX_BYTES);\n'
    "    truncated = truncated.slice(0, cutAt > 0 ? cutAt : MAX_INDEX_BYTES);\n"
    "  }\n"
    "  if (!wasLineTruncated && truncated.length === raw.length) {\n"
    "    return truncated;\n"
    "  }\n"
    "  return `${truncated}\n\n> WARNING: MEMORY.md is too large; only part of it was written. "
    "Keep index entries concise and move detail into topic files.`;\n"
    "}\n"
    '__name(assembleIndex, "assembleIndex");'
)
STOCK_ASSEMBLE_MIN = (
    'function assembleIndex(lines){const raw=lines.join("\\n");'
    "const wasLineTruncated=lines.length>MAX_INDEX_LINES;"
    'let truncated=wasLineTruncated?lines.slice(0,MAX_INDEX_LINES).join("\\n"):raw;'
    "if(truncated.length>MAX_INDEX_BYTES){const cutAt=truncated.lastIndexOf(\"\\n\",MAX_INDEX_BYTES);"
    "truncated=truncated.slice(0,cutAt>0?cutAt:MAX_INDEX_BYTES)}"
    "if(!wasLineTruncated&&truncated.length===raw.length){return truncated}"
    "return`${truncated}\n\n> WARNING: MEMORY.md is too large; only part of it was written. "
    "Keep index entries concise and move detail into topic files.`}"
    '__name(assembleIndex,"assembleIndex");'
)
# 0.25.0 REWROTE assembleIndex.  Instead of cutting the joined text at a newline before the
# byte cap, it keeps a `kept` Set of entry indexes (short lines first, then longer ones that
# still fit) and re-joins them IN INDEX ORDER -- and still sheds the surplus SILENTLY behind
# the same generic warning.  Measured 2026-10-06: both 0.25.0 companions carry this body
# byte-for-byte.  Its warning template literal holds REAL newlines (unlike the source-escaped
# "\n" in join/split), so this literal uses \n for the former and \\n for the latter.
STOCK_ASSEMBLE_V025 = (
    'function assembleIndex(lines){const raw=lines.join("\\n");'
    "const wasLineTruncated=lines.length>MAX_INDEX_LINES;"
    'let truncated=wasLineTruncated?lines.slice(0,MAX_INDEX_LINES).join("\\n"):raw;'
    'if(truncated.length>MAX_INDEX_BYTES){const entries=truncated.split("\\n");'
    "const kept=new Set;let size=0;"
    "for(const limit of[MAX_INDEX_LINE_CHARS,MAX_INDEX_BYTES]){"
    "for(const[index,line]of entries.entries()){"
    "if(kept.has(index)||line.length>limit){continue}"
    "const next=size+(kept.size>0?1:0)+line.length;"
    "if(next>MAX_INDEX_BYTES){continue}size=next;kept.add(index)}}"
    'truncated=entries.filter((_2,index)=>kept.has(index)).join("\\n")}'
    "if(!wasLineTruncated&&truncated.length===raw.length){return truncated}"
    'return`${truncated}\n\n> WARNING: MEMORY.md is too large; only part of it was written. '
    "Keep index entries concise and move detail into topic files.`}"
    '__name(assembleIndex,"assembleIndex");'
)
NEW_ASSEMBLE = r'''function assembleIndex(lines) {
  // LOCAL PATCH 2026-10-01 (qwen-memory-index-bytecap): the stock 25000-byte cap silently
  // dropped the tail of the index (measured 2026-10-01: a 161-entry store shed 14 entries).
  // A silently-dropped entry is worse than a truncated line - a broken line at least shows the
  // entry exists. The cap is raised so a realistic store is kept whole, and whenever ANYTHING
  // is still dropped the marker below NAMES the loss, so a shortened index can never be read as
  // a whole one. A byte cap is kept (rather than removed) because this index is read into every
  // session's context; it is a backstop, not a target.
  const raw = lines.join("\n");
  const byLines = lines.length > MAX_INDEX_LINES ? lines.slice(0, MAX_INDEX_LINES) : lines;
  let joined = byLines.join("\n");
  let byteShed = false;
  if (joined.length > MAX_INDEX_BYTES) {
    const cutAt = joined.lastIndexOf("\n", MAX_INDEX_BYTES);
    joined = joined.slice(0, cutAt > 0 ? cutAt : MAX_INDEX_BYTES);
    byteShed = true;
  }
  const kept = byteShed ? joined.split("\n").length : byLines.length;
  const dropped = lines.length - kept;
  if (dropped <= 0) {
    return raw;
  }
  const reasons = [];
  if (lines.length > MAX_INDEX_LINES) {
    reasons.push(`line cap MAX_INDEX_LINES=${MAX_INDEX_LINES}`);
  }
  if (byteShed) {
    reasons.push(`byte cap MAX_INDEX_BYTES=${MAX_INDEX_BYTES}`);
  }
  return `${joined}\n\n> WARNING: MEMORY.md index is INCOMPLETE — ${kept} of ${lines.length} entries written, ${dropped} DROPPED (${reasons.join("; ")}). Do not read this index as whole; move detail into topic files or raise the caps.`;
}
__name(assembleIndex, "assembleIndex");'''

# The 0.25.0 replacement: same promise, adapted to the `kept`-Set body.  The byte cap is raised
# (BYTES above) and the marker NAMES the loss while KEEPING THE STOCK SENTENCE AS A PREFIX, so a
# reader or tool that greps for the stock wording still finds it.  Upstream never TRUNCATES an
# individual line (it drops a line whole or keeps it whole), and this keeps that property; a
# line longer than MAX_INDEX_LINE_CHARS is merely deprioritised in the byte-cap pass.
NEW_ASSEMBLE_V025 = (
    r'''function assembleIndex(lines) {
  // LOCAL PATCH 2026-10-01 (qwen-memory-index-bytecap): the stock 25000-byte cap silently
  // dropped the tail of the index (measured 2026-10-01: a 161-entry store shed 14 entries).
  // A silently-dropped entry is worse than a truncated line - a broken line at least shows the
  // entry exists. The cap is raised so a realistic store is kept whole, and whenever ANYTHING
  // is still dropped the marker below NAMES the loss, so a shortened index can never be read as
  // a whole one. A byte cap is kept (rather than removed) because this index is read into every
  // session's context; it is a backstop, not a target.
  const raw = lines.join("\n");
  const lineShed = lines.length > MAX_INDEX_LINES;
  const byLines = lineShed ? lines.slice(0, MAX_INDEX_LINES) : lines;
  let truncated = byLines.join("\n");
  let byteShed = false;
  if (truncated.length > MAX_INDEX_BYTES) {
    const entries = truncated.split("\n");
    const kept = new Set;
    let size = 0;
    for (const limit of [MAX_INDEX_LINE_CHARS, MAX_INDEX_BYTES]) {
      for (const [index, line] of entries.entries()) {
        if (kept.has(index) || line.length > limit) { continue; }
        const next = size + (kept.size > 0 ? 1 : 0) + line.length;
        if (next > MAX_INDEX_BYTES) { continue; }
        size = next;
        kept.add(index);
      }
    }
    truncated = entries.filter((_2, index) => kept.has(index)).join("\n");
    byteShed = true;
  }
  const keptCount = byteShed ? (truncated === "" ? 0 : truncated.split("\n").length) : byLines.length;
  const dropped = lines.length - keptCount;
  if (dropped <= 0) {
    return raw;
  }
  const reasons = [];
  if (lineShed) {
    reasons.push(`line cap MAX_INDEX_LINES=${MAX_INDEX_LINES}`);
  }
  if (byteShed) {
    reasons.push(`byte cap MAX_INDEX_BYTES=${MAX_INDEX_BYTES}`);
  }
  return `${truncated}\n\n> WARNING: MEMORY.md is too large; only part of it was written. '''
    # Split so this marker line stays inside the §18.3 120-char count; implicit raw-string
    # concatenation reproduces the exact JS characters (no newline is introduced).
    r'''Keep index entries concise and move detail into topic files. INCOMPLETE: wrote '''
    r'''${keptCount} of ${lines.length} entries, ${dropped} DROPPED (${reasons.join("; ")}).`;
}
__name(assembleIndex, "assembleIndex");'''
)

# --- hunk 4: budget the TITLE so the link always fits MAX_INDEX_LINE_CHARS (two shapes) ---
# The stock docIndexLine caps the title only via sanitizeIndexField (MAX_INDEX_FIELD_CHARS
# = 120) and budgets the DESCRIPTION around the link, never the title; a long title beside a
# long path therefore emits a no-hook line longer than MAX_INDEX_LINE_CHARS (measured 2026-10-11:
# every over-cap line on this box was that shape, up to 189 chars).  The replacement derives the
# title limit from the path, so `- [title](path)` can never exceed the cap and `room` stays
# >= MIN_INDEX_HOOK_CHARS whenever any room exists.
TITLE_STOCK_SPACED = (
    "function docIndexLine(doc) {\n"
    "  const title = sanitizeIndexField(doc.title) || doc.type;\n"
    "  const description = sanitizeIndexField(doc.description) || doc.type;\n"
    "  return `- [${title}](${encodeIndexPathTarget(doc.relativePath)}) \\u2014 ${description}`;\n"
    "}"
)
NEW_TITLE_SPACED = (
    "/* LOCAL PATCH 2026-10-11 (qwen-memory-index-titlecap) */\n"
    "function docIndexLine(doc) {\n"
    "  const target = encodeIndexPathTarget(doc.relativePath);\n"
    "  const titleLimit = Math.max(8, MAX_INDEX_LINE_CHARS - 6 - target.length);\n"
    "  const titleRaw = sanitizeIndexField(doc.title) || doc.type;\n"
    "  const titleHead = titleRaw.slice(0, titleLimit);\n"
    "  const title = titleHead.length < titleRaw.length\n"
    '    ? `${titleHead.slice(0, titleLimit - 1).replace(/\\s+\\S*$/, "").trimEnd()}\\u2026`\n'
    "    : titleHead;\n"
    "  const description = sanitizeIndexField(doc.description) || doc.type;\n"
    "  return `- [${title}](${target}) \\u2014 ${description}`;\n"
    "}"
)
TITLE_STOCK_MIN = (
    "function docIndexLine(doc,others=[]){const title=sanitizeIndexField(doc.title)||doc.type;"
    "const link2=`- [${title}](${encodeIndexPathTarget(doc.relativePath)})`;"
)
NEW_TITLE_MIN = (
    "function docIndexLine(doc,others=[]){"
    "/* LOCAL PATCH 2026-10-11 (qwen-memory-index-titlecap) */"
    "const target=encodeIndexPathTarget(doc.relativePath);"
    "const title=truncateIndexField(sanitizeIndexField(doc.title)||doc.type,"
    "Math.max(8,MAX_INDEX_LINE_CHARS-6-target.length));"
    "const link2=`- [${title}](${target})`;"
)

# --- hunk 5: raise MAX_INDEX_LINES so a real store is not truncated at 200 (two spellings) ---
# The line cap counts LINES, so no amount of shortening an entry's text frees a slot: measured
# 2026-10-11, a 245-note store produced 200 index lines and 45 notes that nothing pointed at.
# 400 keeps the reachability of those notes; the hunk-3 byte cap (256000) is the backstop that
# still bounds a pathological store (400 lines x ~150 chars is ~60 KB).
LINES = {
    "var MAX_INDEX_LINES = 200;":
        "var MAX_INDEX_LINES = 400; /* LOCAL PATCH 2026-10-11 (qwen-memory-index-linecap) */",
    "var MAX_INDEX_LINES=200;":
        "var MAX_INDEX_LINES=400;/* LOCAL PATCH 2026-10-11 (qwen-memory-index-linecap) */",
}

# --- apply, per-copy all-or-nothing (nothing is written unless every needed anchor matches) ---
applied = []
already = []

# hunk 1 (truncator)
if marker_trunc in src:
    already.append("truncator")
elif UPSTREAM:
    already.append("truncator (upstream 0.25.0)")
elif STOCK_TRUNC_SPACED in src:
    src = src.replace(STOCK_TRUNC_SPACED, NEW_TRUNC)
    applied.append("truncator")
elif STOCK_TRUNC_MIN in src:
    src = src.replace(STOCK_TRUNC_MIN, NEW_TRUNC)
    applied.append("truncator")
else:
    raise SystemExit("refusing to patch: no known stock truncateIndexLine body (UNKNOWN shape)")

# hunk 2 (pathcap)
pc = None
for old, new in PATHCAP.items():
    if old in src:
        if src.count(old) != 1:
            raise SystemExit(f"refusing to patch: path-cap anchor occurs {src.count(old)} times")
        src = src.replace(old, new)
        pc = new
        break
if pc is not None:
    applied.append("pathcap")
elif UPSTREAM:
    already.append("pathcap (upstream: the path is no longer capped)")
elif marker_trunc in src and not re.search(r"\[\.\.\.value\]\.slice\(0,\s*MAX_INDEX_FIELD_CHARS\)", src):
    already.append("pathcap")
else:
    raise SystemExit("refusing to patch: no known encodeIndexPathTarget path-cap anchor (UNKNOWN shape)")

# hunk 3 (bytecap)
if marker_bytes in src:
    already.append("bytecap")
else:
    b = None
    for old, new in BYTES.items():
        if old in src:
            if src.count(old) != 1:
                raise SystemExit(f"refusing to patch: MAX_INDEX_BYTES anchor occurs {src.count(old)} times")
            # Renaming the 0.25.1 cap is only safe when the split's own notice is present: that
            # notice IS the "never shed silently" half there, so without it we would be raising a
            # cap and silently dropping the tail -- the exact defect hunk 3 exists to stop.
            if old.startswith("var MAX_INDEX_CHARS") and not bytes_v0251:
                raise SystemExit(
                    "refusing to patch: a MAX_INDEX_CHARS chunk lacks INDEX_TRUNCATION_NOTICE (UNKNOWN shape)"
                )
            src = src.replace(old, new)
            b = new
            break
    if b is None:
        raise SystemExit("refusing to patch: no known MAX_INDEX_BYTES declaration (UNKNOWN shape)")
    # Four known stock shapes: the 0.24.x pretty-printed and minified bodies, the 0.25.0 rewrite,
    # and 0.25.1 (whose cap rename we just made, and where NO assembleIndex body of ours applies
    # -- see the post-conditions).  Each is matched EXACTLY ONCE, so a chunk carrying two of them
    # (or two copies of one) is refused rather than half-patched.
    assemble_forms = (
        (STOCK_ASSEMBLE_SPACED, NEW_ASSEMBLE),
        (STOCK_ASSEMBLE_MIN, NEW_ASSEMBLE),
        (STOCK_ASSEMBLE_V025, NEW_ASSEMBLE_V025),
    )
    hit = False
    for old, new in assemble_forms:
        if old not in src:
            continue
        if src.count(old) != 1:
            raise SystemExit(
                f"refusing to patch: assembleIndex anchor occurs {src.count(old)} times (expected 1)"
            )
        src = src.replace(old, new)
        hit = True
        break
    # On 0.25.1 there is no body of ours to rewrite: upstream's trimIndexToBudget + its own
    # INDEX_TRUNCATION_NOTICE already do the "never shed silently" half, so the missing anchor is
    # BY DESIGN, not drift.  (Third instance of this precedent -- v2/v3 did the same for hunks 1-2.)
    if not hit and not bytes_v0251:
        raise SystemExit("refusing to patch: no known stock assembleIndex body (UNKNOWN shape)")

    # The SCAN itself caps at MAX_SCANNED_MEMORY_FILES = 200, BEFORE assembleIndex runs - so a
    # store with more than 200 notes sheds silently and the marker above never fires (measured
    # 2026-10-01: a 250-note store produced exactly 200 lines and NO marker). Point the two
    # INDEX rebuilds at the uncapped scanners so the index sees every note and the marker can
    # name whatever is then dropped. The extraction agent's own capped scan is left untouched,
    # so its context budget is unchanged.
    # TRAP: on 0.25.1 these two anchors DO match, so the rewrite is NOT prevented by the anchor
    # -- it simply has no premise there (MAX_SCANNED_MEMORY_FILES is gone, so there is no cap to
    # lift) and it is actively harmful: it would swap a working upstream call for one with the
    # wrong arguments (the 0.25.1 scanAll* signature differs).  `node --check` cannot see that,
    # so the bundle would pass its syntax gate and throw at runtime.  The rewires are therefore
    # SKIPPED on that shape -- skipped, not merely tolerated, because `re.subn` would rewrite it
    # whether or not the raise fires.
    if not bytes_v0251:
        managed_scan = re.subn(
            r"scanAutoMemoryTopicDocuments\(projectRoot\)(\s*,\s*)readAutoMemoryMetadata\(projectRoot\)",
            r"scanAllAutoMemoryTopicDocuments(projectRoot)\1readAutoMemoryMetadata(projectRoot)",
            src,
        )
        if managed_scan[1] != 1:
            raise SystemExit(
                f"refusing to patch: managed-rebuild scan anchor occurred {managed_scan[1]} times (expected 1)"
            )
        src = managed_scan[0]
        user_scan = re.subn(
            r"await scanUserAutoMemoryTopicDocuments\(\)"
            r"(\s*;\s*const content\s*=\s*buildManagedAutoMemoryIndex\(docs\))",
            r"await scanAllUserAutoMemoryTopicDocuments()\1",
            src,
        )
        if user_scan[1] != 1:
            raise SystemExit(
                f"refusing to patch: user-rebuild scan anchor occurred {user_scan[1]} times (expected 1)"
            )
        src = user_scan[0]
    applied.append("bytecap")

# hunk 4 (titlecap)
if marker_title in src:
    already.append("titlecap")
else:
    t = None
    for old, new in ((TITLE_STOCK_SPACED, NEW_TITLE_SPACED), (TITLE_STOCK_MIN, NEW_TITLE_MIN)):
        if old not in src:
            continue
        if src.count(old) != 1:
            raise SystemExit(
                f"refusing to patch: docIndexLine title anchor occurs {src.count(old)} times (expected 1)"
            )
        src = src.replace(old, new)
        t = new
        break
    if t is None:
        # 0.26.1: the same minified builder, with the link variable renumbered link2 -> link4 and
        # the title left UNCAPPED in docIndexLine (sanitizeIndexField trims it to 120, so a long
        # title eats the description's room instead of being shortened to fit the line).  The
        # minifier's index is not the property -- measured 2026-10-25 across 0.25.1 (link2) and
        # 0.26.1 (link4) -- so capture the NAME and emit it back unchanged.
        mt = re.search(
            r"function docIndexLine\(doc,others=\[\]\)\{"
            r"const title=sanitizeIndexField\(doc\.title\)\|\|doc\.type;"
            r"const (link[0-9]+)=`- \[\$\{title\}\]\(\$\{encodeIndexPathTarget\(doc\.relativePath\)\}\)`;",
            src,
        )
        if mt is None:
            raise SystemExit("refusing to patch: no known docIndexLine title anchor (UNKNOWN shape)")
        lv = mt.group(1)
        t = (
            "function docIndexLine(doc,others=[]){"
            "/* LOCAL PATCH 2026-10-11 (qwen-memory-index-titlecap) */"
            "const target=encodeIndexPathTarget(doc.relativePath);"
            "const title=truncateIndexField(sanitizeIndexField(doc.title)||doc.type,"
            "Math.max(8,MAX_INDEX_LINE_CHARS-6-target.length));"
            "const " + lv + "=`- [${title}](${target})`;"
        )
        src = src[:mt.start()] + t + src[mt.end():]
    applied.append("titlecap")

# hunk 5 (linecap)
if marker_lines in src:
    already.append("linecap")
else:
    ln = None
    for old, new in LINES.items():
        if old not in src:
            continue
        if src.count(old) != 1:
            raise SystemExit(
                f"refusing to patch: MAX_INDEX_LINES anchor occurs {src.count(old)} times (expected 1)"
            )
        src = src.replace(old, new)
        ln = new
        break
    if ln is None:
        raise SystemExit("refusing to patch: no known MAX_INDEX_LINES declaration (UNKNOWN shape)")
    applied.append("linecap")

# Post-conditions: everything this patch promises must be present in the text about to be written.
# The truncator marker and its definition are required ONLY where our hunk 1 ran: a 0.25.0-shaped
# copy has no `truncateIndexLine` at all (upstream keeps the link itself), so demanding them there
# would refuse a hunk-3-only apply -- the defect fixed in v3.
if marker_bytes not in src:
    raise SystemExit("refusing to patch: the byte-cap marker is absent from the result")
if not UPSTREAM and marker_trunc not in src:
    raise SystemExit("refusing to patch: the truncator marker is absent from the result")
if re.search(r"\[\.\.\.value\]\.slice\(0,\s*MAX_INDEX_FIELD_CHARS\)", src):
    raise SystemExit("refusing to patch: path cap still present in result")
if ("var MAX_INDEX_BYTES = 25e3;" in src or "var MAX_INDEX_BYTES=25e3;" in src
        or "var MAX_INDEX_CHARS = 25e3;" in src or "var MAX_INDEX_CHARS=25e3;" in src):
    raise SystemExit("refusing to patch: the stock byte-cap declaration is still present")
if src.count("function assembleIndex(lines)") != 1:
    raise SystemExit("refusing to patch: the assembleIndex definition count is not 1")
if UPSTREAM:
    if "function truncateIndexField(" not in src:
        raise SystemExit("refusing to patch: the upstream truncateIndexField is absent from the result")
    if "function truncateIndexLine(text)" in src:
        raise SystemExit("refusing to patch: truncateIndexLine appeared in an upstream-shaped result")
elif src.count("function truncateIndexLine(text)") != 1:
    raise SystemExit("refusing to patch: the truncateIndexLine definition count is not 1")
# The two "we rewired it" promises hold only where our own body ran.  On 0.25.1 hunk 3 skipped
# both by design: upstream's INDEX_TRUNCATION_NOTICE is the never-shed-silently half (and it
# names no count -- so there is no `DROPPED (` marker), and MAX_SCANNED_MEMORY_FILES is gone, so
# there is no scan to lift.  Guarding on bytes_v0251 is what keeps a lawful skip from reading as
# a broken apply -- and, keyed on the notice, it holds on a re-apply too.
if "DROPPED (" not in src and not bytes_v0251:
    raise SystemExit("refusing to patch: the explicit drop marker is absent from the result")
if ("scanAllAutoMemoryTopicDocuments(projectRoot)" not in src
        or "scanAllUserAutoMemoryTopicDocuments()" not in src) and not bytes_v0251:
    raise SystemExit("refusing to patch: the uncapped index scan is not wired")
if marker_title not in src:
    raise SystemExit("refusing to patch: the title-cap marker is absent from the result")
if marker_lines not in src:
    raise SystemExit("refusing to patch: the line-cap marker is absent from the result")
if "var MAX_INDEX_LINES = 200;" in src or "var MAX_INDEX_LINES=200;" in src:
    raise SystemExit("refusing to patch: the stock MAX_INDEX_LINES declaration is still present")
if src.count("function docIndexLine") != 1:
    raise SystemExit("refusing to patch: the docIndexLine definition count is not 1")

for label in applied:
    print(f"  patched  {label}")
for label in already:
    print(f"  already  {label}")

p.write_text(src, encoding="utf-8")
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
    echo "qwen-memory-index-patch: done. The Qwen CLI bundle is FOREIGN — a CLI/companion update reverts this; re-run this script (or let a --check self-heal cron do it) after any update."
fi
exit "$rc"
# end of file
