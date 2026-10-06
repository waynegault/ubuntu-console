// tests/fixtures/memory-index-v025-chunk.js
// A MINIMAL synthetic Qwen CLI chunk in the 0.25.0 SHAPE, used by
// tests/unit/51-memory-index-patch.bats so the index patcher can be exercised
// without touching a real foreign bundle.  Generated 2026-10-06 from the exact
// substrings of chunk-QJ3UTSP5.js (companion 0.25.0); the assembleIndex body is
// byte-identical to that bundle's.  Not production data: a fixture.
var MAX_INDEX_LINE_CHARS=150;var MAX_INDEX_LINES=200;var MAX_INDEX_BYTES=25e3;var MAX_INDEX_FIELD_CHARS=120;var MIN_INDEX_HOOK_CHARS=24;
var INDEX_HOOK_SEPARATOR=" \u2014 ";
function __name(fn,name){return fn}
function truncateIndexField(value,limit){return value.length<=limit?value:value.slice(0,limit-1).trimEnd()+"\u2026"}
__name(truncateIndexField,"truncateIndexField");
function docIndexLine(doc,others=[]){const link2=doc.link;const room=MAX_INDEX_LINE_CHARS-link2.length;const description=doc.description;return description.length>room&&room<MIN_INDEX_HOOK_CHARS?link2:`${link2}${INDEX_HOOK_SEPARATOR}${truncateIndexField(description,room)}`}
__name(docIndexLine,"docIndexLine");
function assembleIndex(lines){const raw=lines.join("\n");const wasLineTruncated=lines.length>MAX_INDEX_LINES;let truncated=wasLineTruncated?lines.slice(0,MAX_INDEX_LINES).join("\n"):raw;if(truncated.length>MAX_INDEX_BYTES){const entries=truncated.split("\n");const kept=new Set;let size=0;for(const limit of[MAX_INDEX_LINE_CHARS,MAX_INDEX_BYTES]){for(const[index,line]of entries.entries()){if(kept.has(index)||line.length>limit){continue}const next=size+(kept.size>0?1:0)+line.length;if(next>MAX_INDEX_BYTES){continue}size=next;kept.add(index)}}truncated=entries.filter((_2,index)=>kept.has(index)).join("\n")}if(!wasLineTruncated&&truncated.length===raw.length){return truncated}return`${truncated}

> WARNING: MEMORY.md is too large; only part of it was written. Keep index entries concise and move detail into topic files.`}__name(assembleIndex,"assembleIndex");
function buildManagedAutoMemoryIndex(docs,_metadata){return assembleIndex(docs.map(doc=>docIndexLine(doc)))}
__name(buildManagedAutoMemoryIndex,"buildManagedAutoMemoryIndex");
async function rebuildManagedAutoMemoryIndex(projectRoot){const[docs,metadata]=await Promise.all([scanAutoMemoryTopicDocuments(projectRoot),readAutoMemoryMetadata(projectRoot)]);return buildManagedAutoMemoryIndex(docs,metadata)}
async function rebuildUserAutoMemoryIndex(){const docs=await scanUserAutoMemoryTopicDocuments();const content=buildManagedAutoMemoryIndex(docs);return content}
