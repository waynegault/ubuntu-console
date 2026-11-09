// tests/fixtures/memory-index-coreflag-builder-chunk.js
// A MINIMAL synthetic Qwen CLI INDEX-BUILDER chunk in the 0.26.x shape, carrying hunks 1-7
// (markers AND properties, so `--check` reads them applied) and the STOCK builder bodies hunk 8
// (corefilter) replaces.  The point is to isolate hunk 8 the way the scancap fixture isolates
// hunk 6: the subject under test is the emit-side filter, not the caps.
//
// Modelled on the live 0.26.8 chunk measured 2026-11-06 (chunk-QAEZSJL6.js):
//   * the two builders are byte-identical to upstream (buildManagedAutoMemoryIndex,
//     buildTeamAutoMemoryIndex), because hunk 8's anchors are those exact bodies;
//   * the frontmatter parser is NOT here -- it lives in the scanner chunk, which is why the flag
//     is a second hunk (see memory-index-coreflag-scanner-chunk.js);
//   * `INDEX_TRUNCATION_NOTICE` is present because 0.26.x ships it, and the patcher's
//     never-shed-silently guards key on it.
//
// module.exports is CJS so a test can CALL the builders; the shipped chunk is ESM, and the
// patcher only does text replacement plus `node --check`, which both pass either way.
// Not production data: a fixture.
var MAX_INDEX_LINE_CHARS = 150;
var MAX_INDEX_FIELD_CHARS = 120;
var MAX_INDEX_CHARS = 256000; /* LOCAL PATCH 2026-10-01 (qwen-memory-index-bytecap) */
var MAX_INDEX_LINES = 500; /* LOCAL PATCH 2026-10-11 (qwen-memory-index-linecap) */
var MIN_INDEX_HOOK_CHARS = 40;
var INDEX_HOOK_SEPARATOR = " \u2014 ";
var INDEX_TRUNCATION_NOTICE = "\n\n> WARNING: MEMORY.md is too large; only part of it was written.";
var MAX_NAMED_DROPPED_ENTRIES = 10;

function __name(fn, name) { return fn; }

function sanitizeIndexField(value) {
  return String(value == null ? "" : value).replace(/\s+/g, " ").trim().slice(0, MAX_INDEX_FIELD_CHARS);
}
__name(sanitizeIndexField, "sanitizeIndexField");

function truncateIndexField(value, max) {
  var text = String(value == null ? "" : value);
  if (max <= 0) { return ""; }
  if (text.length <= max) { return text; }
  return text.slice(0, Math.max(0, max - 1)).trimEnd() + "\u2026";
}
__name(truncateIndexField, "truncateIndexField");

function encodeIndexPathTarget(relativePath) {
  return String(relativePath == null ? "" : relativePath)
    .split("/")
    .map(function (part) { return encodeURIComponent(part); })
    .join("/");
}
__name(encodeIndexPathTarget, "encodeIndexPathTarget");

function isImportedMemoryDocument(doc) {
  return String(doc.relativePath || "").indexOf("imported/") === 0;
}
__name(isImportedMemoryDocument, "isImportedMemoryDocument");

// hunk 4 (titlecap) already applied: the title is budgeted from the path.
function docIndexLine(doc, others = []) {
  const target = encodeIndexPathTarget(doc.relativePath);
  const title = truncateIndexField(sanitizeIndexField(doc.title) || doc.type,
    Math.max(8, MAX_INDEX_LINE_CHARS - 6 - target.length));
  const link2 = `- [${title}](${target})`;
  const room=MAX_INDEX_LINE_CHARS-link2.length-INDEX_HOOK_SEPARATOR.length;
  const description = sanitizeIndexField(doc.description) || doc.type;
  if (description.length > room && room < MIN_INDEX_HOOK_CHARS) { return link2; }
  return `${link2}${INDEX_HOOK_SEPARATOR}${truncateIndexField(description, room)}`;
}
__name(docIndexLine, "docIndexLine");

// hunk 7 (linebudget) already applied: `const capped=entries.map` caps each line before joining.
function trimIndexToBudgetDetailed(lines, priorityPrefixLength = 0) {
  const entries = lines.slice(0, MAX_INDEX_LINES);
  const overLineCap = lines.slice(MAX_INDEX_LINES);
  const capped = entries.map(function (line2) {
    return line2.length > MAX_INDEX_LINE_CHARS ? line2.slice(0, MAX_INDEX_LINE_CHARS) : line2;
  });
  const raw = capped.join("\n");
  if (raw.length <= MAX_INDEX_CHARS) { return { content: raw, dropped: overLineCap }; }
  const kept = [];
  let size = 0;
  for (const [index, line2] of entries.entries()) {
    if (line2.length > MAX_INDEX_LINE_CHARS) { continue; }
    const next = size + (kept.length > 0 ? 1 : 0) + line2.length;
    if (next > MAX_INDEX_CHARS) { continue; }
    size = next;
    kept.push(index);
  }
  const surviving = [];
  const dropped = [];
  for (const [index, line2] of entries.entries()) {
    (kept.indexOf(index) >= 0 ? surviving : dropped).push(line2);
  }
  return { content: surviving.join("\n"), dropped: [...dropped, ...overLineCap] };
}
__name(trimIndexToBudgetDetailed, "trimIndexToBudgetDetailed");

function describeDroppedIndexEntries(lines, total, kind, count) {
  return ` ${count} ${kind} not listed (${total} total).`;
}
__name(describeDroppedIndexEntries, "describeDroppedIndexEntries");

function assembleIndex(lines, scanNotice = "", scanOmitted = 0, priorityPrefixLength = 0) {
  const { content, dropped } = trimIndexToBudgetDetailed(lines, priorityPrefixLength);
  if (dropped.length === 0 && !scanNotice) { return content; }
  return `${content}${INDEX_TRUNCATION_NOTICE}`;
}
__name(assembleIndex, "assembleIndex");

function describeScanOmissions(docs, omitted) {
  if (omitted.length === 0) { return ""; }
  return describeDroppedIndexEntries(
    omitted.slice(0, MAX_NAMED_DROPPED_ENTRIES).map(function (doc) { return docIndexLine(doc); }),
    docs.length + omitted.length, "topic files", omitted.length,
  );
}
__name(describeScanOmissions, "describeScanOmissions");

function groupTeamDocsByDescription(docs) {
  const groups = new Map();
  const order = [];
  for (const doc of docs) {
    const key = String(doc.description || "").toLowerCase() || doc.relativePath;
    let members = groups.get(key);
    if (!members) { members = []; groups.set(key, members); order.push(key); }
    members.push(doc);
  }
  return order.map(function (key) {
    const members = groups.get(key);
    return { primary: members[0], others: members.slice(1) };
  });
}
__name(groupTeamDocsByDescription, "groupTeamDocsByDescription");

// ---------------------------------------------------------------------------
// HUNK 8'S SUBJECT: these two bodies are upstream, byte-for-byte.
// ---------------------------------------------------------------------------
function buildManagedAutoMemoryIndex(docs,_metadata,omitted=[]){const ordered=[...docs].sort((a,b2)=>Number(isImportedMemoryDocument(a))-Number(isImportedMemoryDocument(b2)));const firstImported=ordered.findIndex(isImportedMemoryDocument);return assembleIndex(ordered.map(doc=>docIndexLine(doc)),describeScanOmissions(ordered,omitted),omitted.length,firstImported<0?0:firstImported)}__name(buildManagedAutoMemoryIndex,"buildManagedAutoMemoryIndex");

function buildTeamAutoMemoryIndex(docs,omitted=[]){return assembleIndex(groupTeamDocsByDescription(docs).map(({primary,others})=>docIndexLine(primary,others)),describeScanOmissions(docs,omitted),omitted.length)}__name(buildTeamAutoMemoryIndex,"buildTeamAutoMemoryIndex");

module.exports = {
  buildManagedAutoMemoryIndex: buildManagedAutoMemoryIndex,
  buildTeamAutoMemoryIndex: buildTeamAutoMemoryIndex,
  docIndexLine: docIndexLine,
};
