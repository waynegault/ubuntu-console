// tests/fixtures/memory-index-scancap-chunk.js
// A MINIMAL synthetic Qwen CLI SCANNER chunk in the 0.26.5+ shape, used by
// tests/unit/51-memory-index-patch.bats so hunk 6 (scancap) can be exercised
// without touching a real foreign bundle.  Modelled on the live chunk measured
// 2026-11-06 (chunk-FUBDS3AV.js): the notes-scanned cap sits in a DIFFERENT
// chunk from the index builder, so the patcher's builder-selected loop never
// sees it.
//
// The cap is applied by a real consumer (`scanEntries`, the shape of
// scanAutoMemoryIndexDocumentsFromRoot's slice) so the suite can assert the
// OBSERVABLE -- how many entries survive a scan -- rather than only the literal.
// module.exports is CJS so the test can call it; the shipped chunk is ESM, and
// the patcher only ever does text replacement plus `node --check`, which both
// pass either way.  Not production data: a fixture.
var MAX_SCANNED_MEMORY_FILES=200;

function __name(fn, name) { return fn; }

function scanEntries(entries) {
  var docs = entries.slice(0, MAX_SCANNED_MEMORY_FILES);
  var omitted = entries.slice(MAX_SCANNED_MEMORY_FILES);
  return { docs: docs, omitted: omitted };
}
__name(scanEntries, "scanEntries");

module.exports = { scanEntries: scanEntries, cap: MAX_SCANNED_MEMORY_FILES };
