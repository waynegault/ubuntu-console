#!/usr/bin/env node
// memory-index-titlecap-harness.mjs — behavioural check for the PATCHED docIndexLine (hunk 4).
//
// WHY THIS EXISTS (2026-10-11)
//   `node --check` proves a patched bundle PARSES; it cannot see whether the title budget was
//   actually applied, or whether it was applied in a way that breaks the link.  Hunk 4's whole
//   job is to make MAX_INDEX_LINE_CHARS true of the emitted line when the stock code let a long
//   title push it over — so the expected values here come from that criterion (the constant, and
//   "the link must resolve"), never from the function's current output.
//
// WHAT IT CHECKS
//   (1) a long title beside a long path — the stock shape that overflowed — emits a line no
//       longer than MAX_INDEX_LINE_CHARS, with `](path)` byte-intact.  The fixture asserts the
//       input really was over the cap first, so the case cannot pass vacuously;
//   (2) a short title with a long description still gets a hook, and still fits;
//   (3) the budget follows the PATH: the same long title is cut shorter for a longer path.
//
// USAGE
//   node tests/helpers/memory-index-titlecap-harness.mjs <patched-chunk.js>
// Exit 0 = every assertion passed; non-zero = the first failed assertion's message.

import assert from "node:assert/strict";
import fs from "node:fs";
import vm from "node:vm";

const chunkPath = process.argv[2];
if (!chunkPath) {
  console.error("usage: memory-index-titlecap-harness.mjs <patched-chunk.js>");
  process.exit(2);
}

const src = fs.readFileSync(chunkPath, "utf8");
const sandbox = { console };
vm.createContext(sandbox);
vm.runInContext(src, sandbox, { filename: "memory-index-chunk.js" });

const docIndexLine = sandbox.docIndexLine;
assert.equal(typeof docIndexLine, "function", "the chunk must define docIndexLine");
const CAP = sandbox.MAX_INDEX_LINE_CHARS;
assert.equal(CAP, 150, "MAX_INDEX_LINE_CHARS must be 150 for these expectations to mean anything");

function report(name, detail) {
  console.log(`  PASS ${name}: ${detail}`);
}

// (1) long title + long path — the shape that overflowed before the fix.
{
  const title = "A deliberately very long memory note title that no reasonable index line can carry in full";
  const path = "reference/a-deliberately-long-relative-path-for-this-fixture.md";
  const stockLen = 2 + 1 + title.length + 2 + path.length + 1; // `- [title](path)`
  assert(
    stockLen > CAP,
    `(1) the fixture must exceed the cap BEFORE the fix (stock length ${stockLen} <= ${CAP})`,
  );
  const line = docIndexLine({ title, relativePath: path, description: "short", type: "reference" });
  assert(line.length <= CAP, `(1) the line must be <= ${CAP} (got ${line.length}): ${JSON.stringify(line)}`);
  assert(line.includes(`](${path})`), `(1) the link must survive byte-for-byte: ${JSON.stringify(line)}`);
  report("(1) long title + long path", `stock ${stockLen} -> ${line.length} chars, link intact`);
}

// (2) short title + long description — a hook must still be emitted, and fit.
{
  const path = "topic.md";
  const line = docIndexLine({ title: "Short note", relativePath: path, description: "x".repeat(400), type: "reference" });
  assert(line.length <= CAP, `(2) the line must be <= ${CAP} (got ${line.length})`);
  assert(line.includes(" \u2014 "), "(2) a hook must still be emitted when there is room for one");
  assert(line.includes(`](${path})`), "(2) the link must survive");
  report("(2) short title, long description", `${line.length} chars, hook present`);
}

// (3) the budget follows the PATH, not a constant.
{
  const title = "T".repeat(120);
  const shortPath = "a.md";
  const longPath = "reference/" + "d".repeat(110) + ".md";
  const a = docIndexLine({ title, relativePath: shortPath, description: "", type: "reference" });
  const b = docIndexLine({ title, relativePath: longPath, description: "", type: "reference" });
  assert(a.length <= CAP, `(3) the short-path line must fit (got ${a.length})`);
  assert(b.length <= CAP, `(3) the long-path line must fit (got ${b.length})`);
  const titleA = a.slice(a.indexOf("[") + 1, a.indexOf("]("));
  const titleB = b.slice(b.indexOf("[") + 1, b.indexOf("]("));
  assert(
    titleB.length < titleA.length,
    `(3) a longer path must budget a SHORTER title (${titleB.length} !< ${titleA.length})`,
  );
  report("(3) title budget follows the path", `${titleA.length} chars for ${shortPath}, ${titleB.length} for the 120-char path`);
}

console.log("memory-index-titlecap-harness: all assertions passed");
