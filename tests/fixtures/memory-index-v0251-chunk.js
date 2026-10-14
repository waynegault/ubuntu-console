// tests/fixtures/memory-index-v0251-chunk.js
// A MINIMAL synthetic Qwen CLI chunk in the 0.25.1 SHAPE, used by
// tests/unit/51-memory-index-patch.bats so the index patcher can be exercised
// without touching a real foreign bundle.  Generated 2026-10-14 from
// tests/fixtures/memory-index-v025-chunk.js by making the two changes CLI 0.25.1
// itself made (measured against chunks/chunk-WCM7H5HK.js):
//   1. the byte cap is RENAMED  MAX_INDEX_BYTES  ->  MAX_INDEX_CHARS  (same 25e3 value);
//   2. assembleIndex is SPLIT: the kept-Set budget moved into trimIndexToBudget, and
//      upstream appends its own INDEX_TRUNCATION_NOTICE (which names NO count) whenever
//      it sheds -- so at 0.25.1 the lock on "never shed silently" is upstream's.
// MAX_SCANNED_MEMORY_FILES does NOT exist here (as upstream dropped it), so hunk 3's
// uncapped-scan rewires have no premise -- but BOTH of their anchors are left IN PLACE
// exactly as upstream has them, so the patcher's SKIP of that rewire is provable rather
// than vacuous.  Not production data: a fixture.
var MAX_INDEX_LINE_CHARS=150;var MAX_INDEX_LINES=200;var MAX_INDEX_CHARS=25e3;var MAX_INDEX_FIELD_CHARS=120;var MIN_INDEX_HOOK_CHARS=24;
var INDEX_HOOK_SEPARATOR=" \u2014 ";
var INDEX_TRUNCATION_WARNING="> WARNING: MEMORY.md is too large; only part of it was written. Keep index entries concise and move detail into topic files.";
var INDEX_TRUNCATION_NOTICE=`

${INDEX_TRUNCATION_WARNING}`;
function __name(fn,name){return fn}
function truncateIndexField(value,limit){return value.length<=limit?value:value.slice(0,limit-1).trimEnd()+"\u2026"}
__name(truncateIndexField,"truncateIndexField");
function sanitizeIndexField(value){const c=value.replace(/[\u0000-\u001f\u007f-\u009f]/g," ").replace(/`/g,"'").replace(/\]\(/g,"] (").replace(/\s+/g," ").trim();return truncateIndexField(c,MAX_INDEX_FIELD_CHARS)}
__name(sanitizeIndexField,"sanitizeIndexField");
function encodeIndexPathTarget(value){return value}
__name(encodeIndexPathTarget,"encodeIndexPathTarget");
function docIndexLine(doc,others=[]){const title=sanitizeIndexField(doc.title)||doc.type;const link2=`- [${title}](${encodeIndexPathTarget(doc.relativePath)})`;const room=MAX_INDEX_LINE_CHARS-link2.length-INDEX_HOOK_SEPARATOR.length;const description=sanitizeIndexField(doc.description)||doc.type;return description.length>room&&room<MIN_INDEX_HOOK_CHARS?link2:`${link2}${INDEX_HOOK_SEPARATOR}${truncateIndexField(description,room)}`}
__name(docIndexLine,"docIndexLine");
function trimIndexToBudget(lines){const entries=lines.slice(0,MAX_INDEX_LINES);const raw=entries.join("\n");if(raw.length<=MAX_INDEX_CHARS){return raw}const kept=new Set;let size=0;for(const limit of[MAX_INDEX_LINE_CHARS,MAX_INDEX_CHARS]){for(const[index,line]of entries.entries()){if(kept.has(index)||line.length>limit){continue}const next=size+(kept.size>0?1:0)+line.length;if(next>MAX_INDEX_CHARS){continue}size=next;kept.add(index)}}return entries.filter((_2,index)=>kept.has(index)).join("\n")}
__name(trimIndexToBudget,"trimIndexToBudget");
function assembleIndex(lines){const raw=lines.join("\n");const wasLineTruncated=lines.length>MAX_INDEX_LINES;const truncated=trimIndexToBudget(lines);if(!wasLineTruncated&&truncated.length===raw.length){return truncated}return`${truncated}${INDEX_TRUNCATION_NOTICE}`}
__name(assembleIndex,"assembleIndex");
function buildManagedAutoMemoryIndex(docs,_metadata){return assembleIndex(docs.map(doc=>docIndexLine(doc)))}
__name(buildManagedAutoMemoryIndex,"buildManagedAutoMemoryIndex");
async function rebuildManagedAutoMemoryIndex(projectRoot){const[docs,metadata]=await Promise.all([scanAutoMemoryTopicDocuments(projectRoot),readAutoMemoryMetadata(projectRoot)]);return buildManagedAutoMemoryIndex(docs,metadata)}
async function rebuildUserAutoMemoryIndex(){const docs=await scanUserAutoMemoryTopicDocuments();const content=buildManagedAutoMemoryIndex(docs);return content}
