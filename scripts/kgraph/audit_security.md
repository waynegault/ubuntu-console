# Security Audit — kgraph

**Date:** 2026-06-23
**Revised:** 2026-09-12 — claims re-verified against the code and corrected where
they had drifted (see each section's *Correction* note).
**Auditor:** finn
**Scope:** All modules in `/home/wayne/ubuntu-console/scripts/kgraph/`

## Attack Vectors Assessed

### 1. File:// redirect XSS (HTML viewer)
**Severity:** Medium
**Status:** Mitigated

The HTML template in `html.py` (`HTML_TMPL`) embeds graph data via `%s` printf-style substitution using `HTML_TMPL.replace('%s', payload, 1)`. The payload is JSON-serialized graph data.

**Risk:** If graph node/edge labels contain `<script>`, `onerror=`, or `javascript:` payloads, they could execute in the viewer context.

**Mitigation:**
- `validate_graph_payload()` → `validate_graph()` → `_check_xss()` rejects any node/edge string (including nested containers) matching `DANGEROUS_PATTERNS` (`<script>`, `javascript:`, `on*=`, `data:text/html`, `vbscript:`, `file://`, `document.`/`window.`, `eval(`, `setTimeout(`, `setInterval(`)
- The HTML template uses `textContent` for all dynamic label display (not `innerHTML`)
- `detail-body` is a `<textarea readonly>` not a `<div>` — prevents script injection
- Node/edge styling comes from a static Cytoscape style block — colours are not derived from node data
- The template ships a Content-Security-Policy meta (`default-src 'self' https://unpkg.com; script-src https://unpkg.com 'unsafe-inline'; style-src 'self' 'unsafe-inline' https://unpkg.com`)

*Correction (2026-09-12):* an earlier revision claimed `validate.py` sanitizes labels via `sanitize_label()`. That is not true — `sanitize_label()` had **no production caller** (it was only exported and unit-tested) and has since been removed. The actual write-path defence is `_check_xss()` inside `validate_graph_payload()`. There is likewise **no** node-id validation for `/` or `\0` (see §4).

**Recommendation:** None outstanding — the CSP header is present, and the dead `sanitize_label()` was removed rather than left implying a sanitizer that is not applied.

### 2. Graph JSON bomb
**Severity:** Medium
**Status:** Mitigated

**Risk:** Deeply nested JSON (e.g. `[[[[...]]]]`) or huge payloads could cause OOM during `json.loads()`.

**Mitigation:**
- `validate.py` enforces `MAX_NODES = 500_000`, `MAX_EDGES = 1_000_000`
- `MAX_JSON_DEPTH = 20`
- `MAX_PAYLOAD_SIZE = 100 MB`
- Both HTTP writers (`server.py`, `mcp_server.py`) reject a declared `Content-Length` greater than `MAX_PAYLOAD_SIZE` **before** reading the body, then re-check the actual body size as a backstop
- `_json_depth()` recursive check runs before the full Pydantic parse

*Correction (2026-09-12):* the earlier "add a streaming size check" recommendation is already implemented (pre-read `Content-Length` guard).

### 3. Label injection
**Severity:** Low
**Status:** Mitigated

**Risk:** Malicious label strings in graph data.

**Mitigation:**
- `validate_graph_payload()` rejects labels containing `DANGEROUS_PATTERNS`
- Confidence tagging makes all label content explicit (EXTRACTED/INFERRED/AMBIGUOUS)
- Label length is not blanket-capped (the unused `sanitize_label()` / `MAX_LABEL_LENGTH` were removed); oversized payloads are bounded by `MAX_NODES`/`MAX_PAYLOAD_SIZE`

*Correction (2026-09-12):* the earlier claim that `sanitize_label()` "strips HTML and script patterns" was misleading — the function had no production caller and has been removed (§1).

### 4. Path traversal in file references
**Severity:** Low
**Status:** Mitigated (serve root restriction only)

**Risk:** Node `path` fields like `../../etc/passwd`.

**Mitigation:**
- `resolve_serve_target()` resolves the served directory to the frontend dist dir or the graph JSON's own directory — arbitrary filesystem paths are not served
- The AST extractor only reads files within the given `repo_root`
- The HTTP server is a read surface over `graph.json` plus the static frontend; it does not fetch or serve arbitrary `path` fields

*Correction (2026-09-12):* the earlier claim that "`validate.py` rejects ids containing `/` or `\0`" was false — no such validation exists. The protection is the serve-root restriction above.

### 5. SQL injection (graph_db)
**Severity:** Low
**Status:** Mitigated (by design)

All SQLite queries use parameterized statements (`?` placeholders). No raw string interpolation in SQL.

### 6. Server-side request forgery (SSRF)
**Severity:** Low
**Status:** Mitigated

The HTTP server uses `SimpleHTTPRequestHandler` which serves local files only. No URL fetching. Both servers (REST + MCP) process local JSON only. No outbound HTTP request capability.

### 7. MCP server and REST write-path access control
**Severity:** Medium
**Status:** Mitigated

Both write surfaces bind to `127.0.0.1` by default (localhost only).

**Mitigation (POST handlers):**
- Only `Content-Type: application/json` bodies are accepted. `application/json` is not a CORS-safelisted content type, so a cross-origin caller must preflight; both handlers refuse a POST preflight in `do_OPTIONS` (403), so a visited web page cannot POST.
- Defence in depth: an `Origin` header that does not match `Host` is rejected (403). Non-browser callers (MCP clients, curl) send no `Origin` and stay allowed.
- Write responses omit the wildcard `Access-Control-Allow-Origin`.
- Sliding-window rate limit: 30 POSTs / 60s.

*Correction (2026-09-12):* the MCP server previously performed **no** Content-Type or Origin check and returned `Access-Control-Allow-Origin: *`, so any visited page could POST a `text/plain` (CORS-safelisted, no preflight) request invoking `kgraph_report` with an attacker-chosen `outpath` — an arbitrary local file write. This is closed by the checks above, and `kgraph_report`'s `outpath` is now confined to a reports directory (`KG_REPORTS_DIR`, default `~/.openclaw/kgraph-reports`): absolute paths and any `..` traversal are rejected.

### 8. GET read path CORS (accepted risk)
**Severity:** Low
**Status:** Accepted (by design), with read-path redaction

`GET /graph.json` returns `Access-Control-Allow-Origin: *`. The served projection is now redacted on the read path: `content`, `tags` and `content_preview` are dropped, and a `memory`/`summary` node's `label` — which IS a preview of its content (`memory_import.py` sets `label = _preview_text(content)`) — is replaced with a non-content identifier built from the node id (e.g. `memory abc12345`). A page the user visits therefore sees graph structure and concept labels, not raw memory text.

*Correction (2026-09-12):* two earlier revisions of this section understated the exposure. The first said the payload served "`content`, `tags`, source paths" and deferred stripping; the second claimed stripping `content`/`tags` was sufficient. It was not — the label is itself a content preview (verified against the live DB: 18 memory nodes still shipped content-derived labels after that strip). The label and `content_preview` are now redacted too, and `server.py` carries a regression test (`tests/test_untested_modules.py::TestGraphServerPost::test_get_redacts_memory_text`) that fails against the pre-redaction code.

This is deliberate: the Vite dev frontend (`frontend-g6`, port 5173) fetches the API cross-origin, while the embedded Cytoscape viewer is same-origin and needs no CORS. The read server uses an ephemeral port unless `--port` is given, which further limits exposure. Residual: the redaction is by node `type`, so a future content-derived node type that is not `memory`/`summary` would need adding to `server.py`'s redaction; the fields stripped unconditionally (`content`, `tags`, `content_preview`) are the durable part.

## Summary

| Attack Vector | Severity | Status | Notes |
|--------------|----------|--------|-------|
| File:// redirect XSS | Medium | ✅ Mitigated | CSP meta present in the template |
| JSON bomb | Medium | ✅ Mitigated | Pre-read size check + depth/node/edge caps |
| Label injection | Low | ✅ Mitigated | `DANGEROUS_PATTERNS` rejection on the write path |
| Path traversal | Low | ✅ Mitigated | Serve-root restriction (no id validation) |
| SQL injection | Low | ✅ Mitigated | Parameterized queries always |
| SSRF | Low | ✅ Mitigated | No outbound fetch capability |
| MCP / REST write path | Medium | ✅ Mitigated | JSON Content-Type + same-origin + preflight refusal + rate limit |
| GET read CORS | Low | ⚠️ Accepted | Wildcard CORS for the dev frontend; ephemeral port; read path redacts memory text (§8) |

## Recommendations

1. **CSP header** — present in the HTML template (see §1).
2. **`sanitize_label()`** — removed (had no production caller). If node `path`/`id` values are ever used to touch the filesystem, add explicit id validation.
3. **Memory free text** — closed. `content`, `tags` and `content_preview` are stripped from the served GET payload and `memory`/`summary` labels are redacted to a node-id-derived identifier (§8), with a regression test that fails against the pre-redaction code. Residual: redaction is keyed on node `type`, so a new content-derived type must be added to the list in `server.py`.
4. **Consider MCP auth** if the MCP server is ever exposed beyond localhost. (`kgraph_report`'s `outpath` is already confined to the reports directory.)

# end of file
