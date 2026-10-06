#!/usr/bin/env bash
# qwen-memory-index-patch.sh — re-apply the local fixes to the Qwen CLI's memory-index
# builder, after a CLI/companion update replaces the bundled chunk.
#
# THREE HUNKS (each reported separately by --check; each re-applied after an update):
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
# Module Version: 3
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

MARKER_TRUNC="LOCAL PATCH 2026-10-01 (qwen-memory-index-patch)"
MARKER_BYTES="LOCAL PATCH 2026-10-01 (qwen-memory-index-bytecap)"

# Stock anchors used only for state detection in --check.
PATHCAP_STOCK_SPACED='const chars = [...value].slice(0, MAX_INDEX_FIELD_CHARS);'
PATHCAP_STOCK_MIN='const chars=[...value].slice(0,MAX_INDEX_FIELD_CHARS);'
BYTES_STOCK_SPACED='var MAX_INDEX_BYTES = 25e3;'
BYTES_STOCK_MIN='var MAX_INDEX_BYTES=25e3;'
FUNC_TRUNC_STOCK='function truncateIndexLine(text)'
# 0.25.0 REWROTE the builder (measured 2026-10-05 on the IDE companion's
# chunk-QJ3UTSP5.js): `truncateIndexLine` is GONE, `docIndexLine` now budgets the
# description AROUND the link (`room = MAX_INDEX_LINE_CHARS - link.length - suffix.length -
# separator.length`) so the link is never cut, and `encodeIndexPathTarget` no longer slices
# the path at all.  Hunks 1 and 2 are therefore SATISFIED BY UPSTREAM in this shape: there is
# nothing to patch, and a patch that is missing because upstream fixed it must not be
# reported as a broken bundle.  Both spellings are required, so a chunk that merely happens
# to define a helper named truncateIndexField is not mistaken for the fixed builder.
UPSTREAM_FIELD_TRUNC='function truncateIndexField('
UPSTREAM_ROOM_CALC='room=MAX_INDEX_LINE_CHARS-link2.length'

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
    elif grep -qF "$UPSTREAM_FIELD_TRUNC" "$f" && grep -qF "$UPSTREAM_ROOM_CALC" "$f"; then st_trunc="upstream"; fi

    st_path="applied"
    if grep -qF "$PATHCAP_STOCK_SPACED" "$f" || grep -qF "$PATHCAP_STOCK_MIN" "$f"; then st_path="stock"; fi

    st_bytes="UNKNOWN"
    if grep -qF "$MARKER_BYTES" "$f"; then st_bytes="applied"
    elif grep -qF "$BYTES_STOCK_SPACED" "$f" || grep -qF "$BYTES_STOCK_MIN" "$f"; then st_bytes="stock"; fi

    # `upstream` counts as satisfied: on 0.25.0 the builder already does what hunks 1-2 asked
    # for, so there is nothing to apply and reporting it as missing would be false.
    if [[ "$st_trunc" == "applied" || "$st_trunc" == "upstream" ]] \
       && [[ "$st_path" == "applied" ]] \
       && [[ "$st_bytes" == "applied" ]]; then
        echo "  ok       $name (truncator: $st_trunc; pathcap: $st_path; bytecap: $st_bytes)"
        continue
    fi

    if (( check_only )); then
        echo "  NEEDS    $name (truncator: $st_trunc; pathcap: $st_path; bytecap: $st_bytes)" >&2
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
    if ! PATCH_FILE="$f" PATCH_MARKER_TRUNC="$MARKER_TRUNC" PATCH_MARKER_BYTES="$MARKER_BYTES" python3 - <<'PY'
import os, pathlib, re

p = pathlib.Path(os.environ["PATCH_FILE"])
marker_trunc = os.environ["PATCH_MARKER_TRUNC"]
marker_bytes = os.environ["PATCH_MARKER_BYTES"]
src = p.read_text(encoding="utf-8")

# 0.25.0's builder already keeps the link, so hunks 1-2 are upstream-satisfied there.
# Recognised by the same two spellings the shell side uses; without this a copy that needs
# ONLY hunk 3 is refused with "no known stock truncateIndexLine body".
UPSTREAM = ("function truncateIndexField(" in src
            and "room=MAX_INDEX_LINE_CHARS-link2.length" in src)

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

# --- hunk 3: raise MAX_INDEX_BYTES and never shed silently (two spellings of the cap decl) ---
BYTES = {
    "var MAX_INDEX_BYTES = 25e3;": "var MAX_INDEX_BYTES = 256000;",
    "var MAX_INDEX_BYTES=25e3;": "var MAX_INDEX_BYTES=256000;",
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
            src = src.replace(old, new)
            b = new
            break
    if b is None:
        raise SystemExit("refusing to patch: no known MAX_INDEX_BYTES declaration (UNKNOWN shape)")
    # Three known stock shapes now: the 0.24.x pretty-printed and minified bodies, and the
    # 0.25.0 rewrite.  Each is matched EXACTLY ONCE, so a chunk carrying two of them (or two
    # copies of one) is refused rather than half-patched.
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
    if not hit:
        raise SystemExit("refusing to patch: no known stock assembleIndex body (UNKNOWN shape)")

    # The SCAN itself caps at MAX_SCANNED_MEMORY_FILES = 200, BEFORE assembleIndex runs - so a
    # store with more than 200 notes sheds silently and the marker above never fires (measured
    # 2026-10-01: a 250-note store produced exactly 200 lines and NO marker). Point the two
    # INDEX rebuilds at the uncapped scanners so the index sees every note and the marker can
    # name whatever is then dropped. The extraction agent's own capped scan is left untouched,
    # so its context budget is unchanged.
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
if "var MAX_INDEX_BYTES = 25e3;" in src or "var MAX_INDEX_BYTES=25e3;" in src:
    raise SystemExit("refusing to patch: the stock MAX_INDEX_BYTES declaration is still present")
if src.count("function assembleIndex(lines)") != 1:
    raise SystemExit("refusing to patch: the assembleIndex definition count is not 1")
if UPSTREAM:
    if "function truncateIndexField(" not in src:
        raise SystemExit("refusing to patch: the upstream truncateIndexField is absent from the result")
    if "function truncateIndexLine(text)" in src:
        raise SystemExit("refusing to patch: truncateIndexLine appeared in an upstream-shaped result")
elif src.count("function truncateIndexLine(text)") != 1:
    raise SystemExit("refusing to patch: the truncateIndexLine definition count is not 1")
if "DROPPED (" not in src:
    raise SystemExit("refusing to patch: the explicit drop marker is absent from the result")
if "scanAllAutoMemoryTopicDocuments(projectRoot)" not in src or "scanAllUserAutoMemoryTopicDocuments()" not in src:
    raise SystemExit("refusing to patch: the uncapped index scan is not wired")

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
