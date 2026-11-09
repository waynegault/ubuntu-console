// tests/fixtures/memory-index-coreflag-scanner-chunk.js
// A MINIMAL synthetic Qwen CLI SCANNER chunk in the 0.26.x shape, carrying hunk 6 (scancap) as
// APPLIED (the scan cap raised with its marker) and the STOCK
// parseAutoMemoryTopicDocument that hunk 8a (coreflag) extends.
//
// WHY THE PARSER IS ITS OWN FIXTURE. The flag cannot be read at render time: the index builder
// receives already-parsed documents, and this function is the one place that still holds the raw
// frontmatter. On 0.26.8 it lives in a DIFFERENT chunk from the builders
// (chunk-FUBDS3AV.js vs chunk-QAEZSJL6.js), which is why it is a separate hunk -- the same split
// that made scancap its own hunk.
//
// The parser here is a faithful REDUCTION, not a copy: it keeps the returned object's shape and
// its exact final-field tail (so the patcher's anchor is the real one), and it reads `key: value`
// frontmatter lines well enough to exercise the flag end to end. The fixture is CALLABLE (CJS) so
// the suite can assert the CHAIN -- raw note text in, `core` out -- rather than only grepping for
// the assignment.
// Not production data: a fixture.
var MAX_SCANNED_MEMORY_FILES=500;/*LOCAL PATCH 2026-11-06 (qwen-memory-index-scancap)*/
var AUTO_MEMORY_INDEX_FILENAME = "MEMORY.md";
var AUTO_MEMORY_TYPES = ["user", "feedback", "reference", "project"];

function __name(fn, name) { return fn; }

function stringValue(value) {
  return typeof value === "string" ? value : undefined;
}
__name(stringValue, "stringValue");

// A `key: value` reader standing in for the shipped YAML parse. Only the keys this fixture's
// cases use; an unknown key is still PARSED (and then ignored by the parser, exactly as upstream
// ignores it), which is what makes the `index:` flag a drop-in.
function parse(frontmatter) {
  var out = {};
  for (var line of frontmatter.split("\n")) {
    var m = /^([A-Za-z_][A-Za-z0-9_]*):\s*(.*)$/.exec(line);
    if (!m) { continue; }
    var value = m[2].trim();
    if (value.length > 1 && value[0] === '"' && value[value.length - 1] === '"') {
      value = value.slice(1, -1);
    }
    out[m[1]] = value;
  }
  return out;
}
__name(parse, "parse");

function rescueUnquotedHashFields(_frontmatter, parsed) {
  return parsed;
}
__name(rescueUnquotedHashFields, "rescueUnquotedHashFields");

function parseCategory(value) { return stringValue(value); }
__name(parseCategory, "parseCategory");
function parseKeywords(value) { return Array.isArray(value) ? value : []; }
__name(parseKeywords, "parseKeywords");
function parseUsageScenarios(value) { return Array.isArray(value) ? value : []; }
__name(parseUsageScenarios, "parseUsageScenarios");

// ---------------------------------------------------------------------------
// HUNK 8a'S SUBJECT: this is the stock body, byte-for-byte at its return tail.
// ---------------------------------------------------------------------------
function parseAutoMemoryTopicDocument(filePath,content,mtimeMs=0,relativePath=filePath.split("/").pop(),scope="project"){const normalized=content.replace(/\r\n/g,"\n");const frontmatterMatch=normalized.match(/^---\n([\s\S]*?)\n---\n?([\s\S]*)$/);if(!frontmatterMatch){return null}const[,frontmatter,bodyContent]=frontmatterMatch;const parsedFrontmatter=rescueUnquotedHashFields(frontmatter,parse(frontmatter));const rawType=stringValue(parsedFrontmatter["type"]);if(!rawType||!AUTO_MEMORY_TYPES.includes(rawType)){return null}const description=stringValue(parsedFrontmatter["description"])??"";return{scope,type:rawType,filePath,relativePath,filename:filePath.split("/").pop(),title:stringValue(parsedFrontmatter["name"])??stringValue(parsedFrontmatter["title"])??rawType,description,category:parseCategory(parsedFrontmatter["category"]),keywords:parseKeywords(parsedFrontmatter["keywords"]),usageScenarios:parseUsageScenarios(parsedFrontmatter["usage_scenarios"],description),body:bodyContent.trim(),mtimeMs}}__name(parseAutoMemoryTopicDocument,"parseAutoMemoryTopicDocument");

function scanEntries(entries) {
  var docs = entries.slice(0, MAX_SCANNED_MEMORY_FILES);
  var omitted = entries.slice(MAX_SCANNED_MEMORY_FILES);
  return { docs: docs, omitted: omitted };
}
__name(scanEntries, "scanEntries");

module.exports = {
  parseAutoMemoryTopicDocument: parseAutoMemoryTopicDocument,
  scanEntries: scanEntries,
  cap: MAX_SCANNED_MEMORY_FILES,
};
