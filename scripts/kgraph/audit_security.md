# Security Audit — kgraph

**Date:** 2026-06-23
**Auditor:** finn
**Scope:** All modules in `/home/wayne/ubuntu-console/scripts/kgraph/`

## Attack Vectors Assessed

### 1. File:// redirect XSS (HTML viewer)
**Severity:** Medium
**Status:** Mitigated

The HTML template in `html.py` (`HTML_TMPL`) embeds graph data via `%s` printf-style substitution using `HTML_TMPL.replace('%s', payload, 1)`. The payload is JSON-serialized graph data.

**Risk:** If graph node/edge labels contain `<script>`, `onerror=`, or `javascript:` payloads, they could execute in the viewer context.

**Mitigation:**
- `validate.py` sanitizes labels via `sanitize_label()` — strips HTML tags, removes `javascript:` / `on*=` patterns
- `validate_graph_payload()` rejects any label containing dangerous regex patterns
- The HTML template uses `textContent` for all dynamic label display (not `innerHTML`)
- `detail-body` is a `<textarea readonly>` not a `<div>` — prevents script injection
- The `d3` line color assignment uses `rgb(...)` — hardcoded

**Recommendation:** Add a CSP header in the HTML template.

### 2. Graph JSON bomb
**Severity:** Medium
**Status:** Mitigated

**Risk:** Deeply nested JSON (e.g., `[[[[...]]]]`) or huge payloads could cause OOM during `json.loads()`.

**Mitigation:**
- `validate.py` enforces `MAX_NODES = 500_000`, `MAX_EDGES = 1_000_000`
- `MAX_JSON_DEPTH = 20`
- `MAX_PAYLOAD_SIZE = 100 MB`
- `_json_depth()` recursive check before full parse

**Recommendation:** Add a streaming JSON validator for pre-parse size check.

### 3. Label injection
**Severity:** Low
**Status:** Mitigated

**Risk:** Malicious label strings in graph data.

**Mitigation:**
- `sanitize_label()` strips HTML and script patterns
- `MAX_LABEL_LENGTH = 500`
- Confidence tagging makes all label content explicit (EXTRACTED/INFERRED/AMBIGUOUS)

### 4. Path traversal in file references
**Severity:** Low
**Status:** Mitigated

**Risk:** Node `path` fields like `../../etc/passwd`.

**Mitigation:**
- `validate.py` rejects ids containing `/` or `\0`
- `resolve_serve_target()` resolves against the serve directory, not arbitrary filesystem paths
- AST extractor only reads within the given `repo_root`

### 5. SQL injection (graph_db)
**Severity:** Low
**Status:** Mitigated (by design)

All SQLite queries use parameterized statements (`?` placeholders). No raw string interpolation in SQL.

### 6. Server-side request forgery (SSRF)
**Severity:** Low
**Status:** Mitigated

The HTTP server uses `SimpleHTTPRequestHandler` which serves local files only. No URL fetching. MCP server only processes local JSON-RPC calls. No outbound HTTP request capability.

### 7. MCP server access control
**Severity:** Low
**Status:** Mitigated (by design)

MCP server binds to `127.0.0.1` by default (localhost only). No authentication layer — this is appropriate for local-only tool access.

## Summary

| Attack Vector | Severity | Status | Notes |
|--------------|----------|--------|-------|
| File:// redirect XSS | Medium | ✅ Mitigated | CSP recommended for defense-in-depth |
| JSON bomb | Medium | ✅ Mitigated | Size & depth limits enforced |
| Label injection | Low | ✅ Mitigated | Sanitizer + length limits |
| Path traversal | Low | ✅ Mitigated | ID validation + serve root restriction |
| SQL injection | Low | ✅ Mitigated | Parameterized queries always |
| SSRF | Low | ✅ Mitigated | No outbound fetch capability |
| MCP auth bypass | Low | ✅ Mitigated | localhost-only binding |

## Recommendations

1. **Add CSP header** to `html.py`: `<meta http-equiv="Content-Security-Policy" content="default-src 'self' https://unpkg.com; script-src https://unpkg.com 'unsafe-inline';">`
2. **Add streaming size check** before `json.loads()` in the POST handler
3. **Rate-limit the POST `/graph.json` handler** to prevent DoS
4. **Consider MCP auth** if MCP server is ever exposed beyond localhost
