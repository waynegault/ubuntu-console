// Fixture for tests/unit/54-qwen-memory-style-patch.bats — a minimal chunk shaped like the
// Qwen CLI bundle that bin/qwen-memory-style-patch.sh edits.  It carries the three things the
// patcher anchors on, and nothing else:
//
//   1. the extractor sentence it uses to FIND a candidate chunk,
//   2. the format-reference anchor it inserts before — the array's last two entries with no
//      whitespace between them (spelled out only here in prose, because writing the anchor
//      string in a comment would make it match twice and the patcher refuses that), and
//   3. ONE style rule element — carrying the SUPERSEDED v2 payload, so a run must UPGRADE it
//      in place (leaving the array with one style element) rather than insert beside it.
//
// The real prompt array is long; length is not what the patcher reads.  Its pre-conditions are
// "the extractor sentence exactly once" and "exactly one anchor spelling matches exactly once",
// and its post-conditions re-check both plus the payload's uniqueness — so a MINIMAL fixture
// exercises the same contract, and can be read in full by whoever has to diagnose a failure.
//
// The v2 payload below is byte-identical to V2_RULE_TEXT in the patcher; if that ever stops
// being true the suite's upgrade case fails, which is the point (it is a payload match, and a
// payload mismatch is exactly what the patcher must refuse).
const MEMORY_FRONTMATTER_EXAMPLE = ["---", "name: example", "---"];

const EXTRACTION_AGENT_SYSTEM_PROMPT = [
  "You are now acting as the managed memory extraction subagent",
  "",
  /* LOCAL PATCH 2026-10-02 (qwen-memory-extractor-style) */
  "- Match the store's Markdown style: emphasis with underscores (_like this_), never asterisks (*like this*); a blank line before and after every list and heading; the single H1 repeats the frontmatter name value; and every code block is fenced with a language tag, never indented.",
  "Memory file format reference:",...MEMORY_FRONTMATTER_EXAMPLE];

module.exports = { EXTRACTION_AGENT_SYSTEM_PROMPT, MEMORY_FRONTMATTER_EXAMPLE };
