#!/usr/bin/env node
// memory-index-assemble-harness.mjs — behavioural check for the PATCHED assembleIndex.
//
// WHY THIS EXISTS (2026-10-06)
//   The memory-index patcher (`bin/qwen-memory-index-patch.sh`) runs `node --check` on a
//   bundle it just edited, which proves only that the file PARSES.  It cannot see a wrong
//   `kept` / count computation — and that computation is the entire risk in hunk 3, whose
//   whole job is to stop dropping index entries silently and to NAME the loss when it still
//   must drop.  A patch that parses but miscounts would report success while still shedding.
//
// WHAT IT CHECKS (expected values come from the patch's stated CONTRACT, not from the code)
//   (cap)  the bundle declares the RAISED byte cap (256000) and keeps the other two promises
//          (MAX_INDEX_LINE_CHARS 150, MAX_INDEX_LINES 200) — the cap raise is the patch's
//          whole point, so it is read from the file and asserted, never assumed;
//   (a)    an index of ~30 KB (above the STOCK 25000 cap, below the new one) is returned
//          WHOLE: no entry dropped, no marker appended;
//   (b1)   an index past MAX_INDEX_BYTES drops only what it must AND the appended marker names
//          how many of how many entries were written, plus the byte cap that bit — with the
//          stock sentence kept as a prefix so a reader that greps for it still finds it;
//   (b2)   past the line cap, the marker names the LINE cap instead;
//   (c)    a single line longer than MAX_INDEX_LINE_CHARS is NEVER cut: under the byte cap it
//          is returned whole, and over it, it is dropped whole rather than truncated.
//
// USAGE
//   node tests/helpers/memory-index-assemble-harness.mjs <patched-chunk.js>
// Exit 0 = every assertion passed; non-zero = the first failed assertion's message.

import assert from "node:assert/strict";
import fs from "node:fs";
import vm from "node:vm";

const STOCK_BYTES = 25000;

const chunkPath = process.argv[2];
if (!chunkPath) {
  console.error("usage: memory-index-assemble-harness.mjs <patched-chunk.js>");
  process.exit(2);
}

const src = fs.readFileSync(chunkPath, "utf8");

// Read a `var NAME = <number|e-notation>;` declaration from the bundle.  Exactly one must
// match, or the file is not the shape this harness understands.
function readDecl(name) {
  const re = new RegExp(String.raw`var ${name}\s*=\s*([0-9]+(?:e[0-9]+)?)\s*;`, "g");
  const hits = [...src.matchAll(re)];
  assert.equal(hits.length, 1, `expected exactly one 'var ${name} = …;' declaration, found ${hits.length}`);
  return Number(hits[0][1]);
}

// The contract the patch promises: the byte cap is RAISED, the other two caps are untouched.
const CAP_LINE_CHARS = readDecl("MAX_INDEX_LINE_CHARS");
const CAP_LINES = readDecl("MAX_INDEX_LINES");
const CAP_BYTES = readDecl("MAX_INDEX_BYTES");
assert.equal(CAP_LINE_CHARS, 150, "MAX_INDEX_LINE_CHARS must stay 150");
assert.equal(CAP_LINES, 200, "MAX_INDEX_LINES must stay 200");
assert.equal(CAP_BYTES, 256000, "the byte cap must be the RAISED value 256000");

const start = src.indexOf("function assembleIndex(lines)");
if (start < 0) {
  console.error(`harness: ${chunkPath}: no assembleIndex function found`);
  process.exit(2);
}
// The name registration follows the body; tolerate the stock (no space) and patched (spaced)
// spellings by anchoring on the call itself and taking the statement's semicolon.
const nameIdx = src.indexOf("__name(assembleIndex", start);
const semi = nameIdx < 0 ? -1 : src.indexOf(";", nameIdx);
if (semi < 0) {
  console.error(`harness: ${chunkPath}: assembleIndex has no __name registration`);
  process.exit(2);
}
const body = src.slice(start, semi + 1);

const sandbox = {
  MAX_INDEX_LINE_CHARS: CAP_LINE_CHARS,
  MAX_INDEX_LINES: CAP_LINES,
  MAX_INDEX_BYTES: CAP_BYTES,
  __name: (fn) => fn,
};
vm.createContext(sandbox);
vm.runInContext(body, sandbox, { filename: "assembleIndex.js" });
const assembleIndex = sandbox.assembleIndex;
assert.equal(typeof assembleIndex, "function", "assembleIndex did not define a function");

function report(name, detail) {
  console.log(`  PASS ${name}: ${detail}`);
}

report("(cap) byte cap raised", `MAX_INDEX_BYTES=${CAP_BYTES} (stock ${STOCK_BYTES}); line caps unchanged`);

// --- (a) a ~30 KB index is returned whole -----------------------------------
{
  const lines = [];
  for (let i = 0; i < 199; i++) {
    const head = `- [Title ${i}](topic-${i}.md) — `;
    lines.push(head + "x".repeat(CAP_LINE_CHARS - head.length));
  }
  const raw = lines.join("\n");
  assert(
    raw.length > STOCK_BYTES,
    `(a) fixture must exceed the STOCK cap ${STOCK_BYTES} to be meaningful (got ${raw.length})`,
  );
  assert(raw.length <= CAP_BYTES, "(a) fixture must sit under the new cap");
  const out = assembleIndex(lines);
  assert.equal(out, raw, "(a) a 30 KB index must be returned whole once the cap is raised");
  assert(!out.includes("WARNING"), "(a) no loss marker may appear when nothing was dropped");
  assert(!out.includes("DROPPED"), "(a) no DROPPED marker may appear when nothing was dropped");
  report("(a) ~30 KB index returned whole", `${raw.length} bytes, no marker`);
}

// --- (b1) past the BYTE cap: drops only what it must, names the loss + the cap ---
{
  const L = 2000;
  const lines = [];
  for (let i = 0; i < 200; i++) lines.push("y".repeat(L));
  // Independent closed form for the maximum number of equal-length lines that fit:
  //   kept * L + (kept - 1) newlines <= CAP_BYTES  =>  kept = floor((CAP_BYTES + 1) / (L + 1))
  const expectedKept = Math.floor((CAP_BYTES + 1) / (L + 1));
  const out = assembleIndex(lines);
  assert(
    out.includes("WARNING: MEMORY.md is too large; only part of it was written."),
    "(b1) the marker must keep the stock sentence as a prefix",
  );
  const m = out.match(/wrote (\d+) of (\d+) entries, (\d+) DROPPED \(([^)]*)\)/);
  assert(
    m,
    `(b1) the marker must name 'wrote N of M entries, K DROPPED (reasons)' (got tail ${JSON.stringify(out.slice(-160))})`,
  );
  const kept = Number(m[1]);
  const total = Number(m[2]);
  const dropped = Number(m[3]);
  const reasons = m[4];
  assert.equal(total, lines.length, "(b1) the marker must count all source entries");
  assert.equal(kept, expectedKept, `(b1) must keep the maximum that fits (${expectedKept})`);
  assert.equal(kept + dropped, total, "(b1) kept + dropped must equal the total");
  assert(reasons.includes(`byte cap MAX_INDEX_BYTES=${CAP_BYTES}`), "(b1) must name the byte cap");
  const markerAt = out.indexOf("\n\n> WARNING:");
  const written = out.slice(0, markerAt);
  assert(written.length <= CAP_BYTES, "(b1) the written index must not exceed the byte cap");
  const entryLines = written === "" ? 0 : written.split("\n").length;
  assert.equal(entryLines, kept, "(b1) the marker's kept count must match the entries written");
  report("(b1) byte cap: drops only what it must", `kept ${kept}/${total}, ${dropped} dropped, names the byte cap`);
}

// --- (b2) past the LINE cap: the marker names the line cap -------------------
{
  const lines = [];
  for (let i = 0; i < CAP_LINES + 5; i++) lines.push(`- [E${i}](e${i}.md) — short`);
  const out = assembleIndex(lines);
  const m = out.match(/wrote (\d+) of (\d+) entries, (\d+) DROPPED \(([^)]*)\)/);
  assert(m, "(b2) the marker must name the loss");
  assert.equal(Number(m[1]), CAP_LINES, "(b2) the line cap keeps exactly MAX_INDEX_LINES entries");
  assert.equal(Number(m[2]), lines.length, "(b2) the total must be the source count");
  assert(m[4].includes(`line cap MAX_INDEX_LINES=${CAP_LINES}`), "(b2) must name the line cap");
  report("(b2) line cap: marker names the line cap", `${m[1]} of ${m[2]} written`);
}

// --- (c) a single line longer than MAX_INDEX_LINE_CHARS is never cut ---------
{
  const long = "- [Long](long.md) — " + "z".repeat(3000);
  const out = assembleIndex(["- [A](a.md) — one", long, "- [B](b.md) — two"]);
  assert(out.includes(long), "(c) under the byte cap a >150-char line is returned WHOLE, never cut");
  assert.equal(out.split("\n").length, 3, "(c) no line may be synthesised by truncation");

  const huge = "w".repeat(CAP_BYTES + 1000);
  const out2 = assembleIndex([huge, "- [B](b.md) — two"]);
  assert(!out2.includes(huge), "(c) an over-budget line is dropped whole");
  assert(!out2.includes("w".repeat(1000)), "(c) an over-budget line must not appear partially (no cutting)");
  report("(c) over-long line: kept whole under the cap, dropped whole over it", "never truncated");
}

console.log("memory-index-assemble-harness: all assertions passed");
