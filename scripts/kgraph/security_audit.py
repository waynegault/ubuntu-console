"""Security audit for kgraph source modules.

Scans html.py for XSS vulnerabilities in template rendering,
server.py for path traversal and injection risks,
mcp_server.py for input validation gaps.

Produces an audit report with findings, severity, and recommendations.

CLI integration:
    kgraph --security-audit [--output audit.html]
"""

import ast
import json
import os
import re
import sys
from datetime import datetime
from pathlib import Path


# ── Audit finding types ────────────────────────────────────────────────

class AuditFinding:
    """A single security audit finding."""

    def __init__(self, file: str, line: int, severity: str, category: str,
                 title: str, description: str, recommendation: str,
                 code_snippet: str = ""):
        self.file = file
        self.line = line
        self.severity = severity  # CRITICAL, HIGH, MEDIUM, LOW, INFO
        self.category = category
        self.title = title
        self.description = description
        self.recommendation = recommendation
        self.code_snippet = code_snippet

    def to_dict(self) -> dict:
        return {
            "file": self.file,
            "line": self.line,
            "severity": self.severity,
            "category": self.category,
            "title": self.title,
            "description": self.description,
            "recommendation": self.recommendation,
            "code_snippet": self.code_snippet,
        }


# ── Scan: html.py (XSS vulnerabilities) ───────────────────────────────

def scan_html_for_xss(filepath: str) -> list[AuditFinding]:
    """Scan html.py for XSS vulnerabilities in template rendering."""
    findings = []
    content = _read_file(filepath)
    if not content:
        return findings

    lines = content.splitlines()

    # Check for safe JSON escaping in template generation
    found_safe_json_dump = False
    found_unsafe_string_interpolation = False

    for i, line in enumerate(lines, 1):
        stripped = line.strip()

        # Check for json.dumps usage (safe method)
        if "json.dumps" in stripped and "HTML_TMPL" not in stripped:
            found_safe_json_dump = True

        # Check for %s string interpolation (the report uses it for graph injection)
        if stripped.startswith("html = HTML_TMPL.replace('%s', payload, 1)"):
            findings.append(AuditFinding(
                file=filepath,
                line=i,
                severity="INFO",
                category="xss",
                title="String interpolation of graph payload into HTML template",
                description=(
                    "The graph JSON payload is injected into the HTML template using "
                    "string replacement. Since json.dumps escapes HTML by default, "
                    "this is safe against XSS, but labels rendered server-side should "
                    "still be validated."
                ),
                recommendation=(
                    "Consider validating all label/description fields with the "
                    "security.sanitize_label() function before rendering."
                ),
                code_snippet=line.strip()[:120],
            ))

        # Check for direct user input rendering
        if "innerHTML" in stripped or "innerhtml" in stripped.lower():
            # These are client-side Cytoscape elements, review context
            pass

    # Check for unsafe string formatting patterns
    for i, line in enumerate(lines, 1):
        stripped = line.strip()
        # Check for f-strings containing potentially unsafe content
        if any(kw in stripped for kw in ["<script>", "onerror", "onload", "javascript:", "document.cookie"]):
            findings.append(AuditFinding(
                file=filepath,
                line=i,
                severity="HIGH",
                category="xss_hardcoded",
                title="Potentially dangerous content found in template string",
                description="The template string contains raw HTML/JS content that could be dangerous if user-controlled.",
                recommendation="Ensure any user-controlled content is sanitized before reaching this template.",
                code_snippet=stripped[:120],
            ))

    if not found_safe_json_dump:
        findings.append(AuditFinding(
            file=filepath,
            line=1,
            severity="MEDIUM",
            category="xss",
            title="No json.dumps detected in template generation",
            description=(
                "The template generation may not be using safe JSON serialization. "
                "Unsafe string interpolation could introduce XSS vulnerabilities."
            ),
            recommendation="Use json.dumps() to serialize graph data into the template.",
        ))

    # Check for missing Content-Security-Policy in HTML template
    if "Content-Security-Policy" in content or "content-security-policy" in content.lower():
        pass  # CSP is present, good
    else:
        # Check if there's a meta CSP
        if '<meta http-equiv="Content-Security-Policy"' not in content:
            findings.append(AuditFinding(
                file=filepath,
                line=1,
                severity="MEDIUM",
                category="xss_csp",
                title="Missing Content-Security-Policy header/meta",
                description=(
                    "The HTML template does not include a Content-Security-Policy header "
                    "or meta tag. CSP would provide defense-in-depth against XSS attacks."
                ),
                recommendation=(
                    "Add a CSP meta tag to the HTML template that restricts script sources "
                    "to trusted CDNs and blocks inline scripts if possible."
                ),
            ))

    return findings


# ── Scan: server.py (path traversal, injection) ──────────────────────

def scan_server_for_risks(filepath: str) -> list[AuditFinding]:
    """Scan server.py for path traversal, injection risks, and other issues."""
    findings = []
    content = _read_file(filepath)
    if not content:
        return findings

    lines = content.splitlines()

    # Check path traversal in URL handling
    for i, line in enumerate(lines, 1):
        stripped = line.strip()

        # Check for path operations on URL
        if "self.path" in stripped and any(kw in stripped for kw in ["open(", "read(", "file(", "Path(", "os.path"]):
            findings.append(AuditFinding(
                file=filepath,
                line=i,
                severity="HIGH",
                category="path_traversal",
                title="Potential path traversal via URL path",
                description=(
                    "The server uses the URL path directly for file operations. "
                    "While SimpleHTTPRequestHandler provides basic path validation, "
                    "direct file access from URL paths should be audited."
                ),
                recommendation=(
                    "Ensure URL paths are validated and restricted to known directories. "
                    "Consider using os.path.realpath() to resolve symlinks and check "
                    "the resolved path remains within the allowed serve directory."
                ),
                code_snippet=stripped[:120],
            ))

        # Check for shell injection via subprocess
        if "subprocess" in stripped and ("shell=True" in stripped or "shell = True" in stripped):
            findings.append(AuditFinding(
                file=filepath,
                line=i,
                severity="CRITICAL",
                category="shell_injection",
                title="Shell injection risk: shell=True in subprocess call",
                description=(
                    "The use of shell=True in subprocess calls risks command injection "
                    "if any arguments contain user-controlled input."
                ),
                recommendation="Avoid shell=True. Use subprocess with argument lists instead.",
                code_snippet=stripped[:120],
            ))

        # Check for open() with user-controlled paths
        if re.search(r'open\(.*self\.', stripped) or re.search(r'open\(.*path', stripped, re.IGNORECASE):
            findings.append(AuditFinding(
                file=filepath,
                line=i,
                severity="MEDIUM",
                category="path_traversal",
                title="File open with dynamic path",
                description="File opened using a path that may be dynamically constructed.",
                recommendation="Validate that the path is within the expected directory and does not contain '..'.",
                code_snippet=stripped[:120],
            ))

        # Check path normalization
        if "os.path.abspath" in stripped and "self.path" in stripped:
            findings.append(AuditFinding(
                file=filepath,
                line=i,
                severity="INFO",
                category="path_traversal",
                title="Path normalization present (good)",
                description="Path is being normalized via os.path.abspath, which helps prevent traversal.",
                recommendation="Good practice. Also consider os.path.realpath() to resolve symlinks.",
                code_snippet=stripped[:120],
            ))

        # Check for eval/exec
        if "eval(" in stripped or "exec(" in stripped:
            findings.append(AuditFinding(
                file=filepath,
                line=i,
                severity="CRITICAL",
                category="code_injection",
                title="Dynamic code execution detected",
                description="Use of eval() or exec() creates code injection vulnerabilities.",
                recommendation="Remove or replace eval()/exec() with safer alternatives.",
                code_snippet=stripped[:120],
            ))

    return findings


# ── Scan: mcp_server.py (input validation gaps) ─────────────────────

def scan_mcp_server(filepath: str) -> list[AuditFinding]:
    """Scan mcp_server.py for input validation gaps."""
    findings = []
    content = _read_file(filepath)
    if not content:
        return findings

    lines = content.splitlines()

    # Check for payload size limits
    found_content_length_check = False
    found_json_decode = False
    found_param_validation = False

    for i, line in enumerate(lines, 1):
        stripped = line.strip()

        # Check Content-Length validation
        if "Content-Length" in stripped and ("int(" in stripped or "MAX" in stripped or "limit" in stripped.lower()):
            found_content_length_check = True

        # Check JSON decode handling
        if "json.loads" in stripped or "json.load" in stripped:
            found_json_decode = True

        # Check parameter validation
        if "params.get" in stripped or "params[" in stripped:
            found_param_validation = True

        # Check for exception handling around JSON parsing
        if "try:" in stripped and i + 1 < len(lines):
            next_line = lines[i] if i < len(lines) else ""
            if "json.loads" in next_line or "json.load" in next_line:
                findings.append(AuditFinding(
                    file=filepath,
                    line=i,
                    severity="INFO",
                    category="input_validation",
                    title="JSON parsing is wrapped in try/except (good)",
                    description="JSON parsing is properly wrapped in exception handling, which prevents malformed input from crashing the server.",
                    recommendation="Good practice. Continue to validate parsed fields.",
                    code_snippet=stripped[:120],
                ))

    if not found_content_length_check:
        # Check if they at least have Content-Length usage
        for i, line in enumerate(lines, 1):
            if "Content-Length" in line.strip():
                findings.append(AuditFinding(
                    file=filepath,
                    line=i,
                    severity="INFO",
                    category="input_validation",
                    title="Content-Length is read but may not be validated",
                    description="Content-Length header is read, but there is no explicit size limit check.",
                    recommendation=(
                        "Add a maximum Content-Length validation to prevent "
                        "memory exhaustion from oversized payloads."
                    ),
                    code_snippet=line.strip()[:120],
                ))
                break

    if not found_param_validation:
        findings.append(AuditFinding(
            file=filepath,
            line=1,
            severity="HIGH",
            category="input_validation",
            title="Method parameters may not be validated",
            description=(
                "The MCP server dispatches method calls without type-checking "
                "parameters. Unvalidated parameters could lead to injection or "
                "logic errors."
            ),
            recommendation=(
                "Add type validation and bounds checking for all method parameters. "
                "Use the security module's sanitize_label() on string inputs."
            ),
        ))

    # Check for method name injection
    for i, line in enumerate(lines, 1):
        if method_match := re.search(r"method\s*=\s*req\.get\(['\"]method['\"],\s*['\"]", line):
            if "method = req.get('method', '')" in line or 'method = req.get("method", "")' in line:
                findings.append(AuditFinding(
                    file=filepath,
                    line=i,
                    severity="MEDIUM",
                    category="input_validation",
                    title="Method name should be validated against allowed methods",
                    description=(
                        "The method name from the JSON-RPC request is used directly "
                        "for dispatch. While the dispatch function filters unknown methods, "
                        "validating against an allowlist upfront is safer."
                    ),
                    recommendation=(
                        "Validate the method name against an allowlist "
                        "before dispatching."
                    ),
                    code_snippet=line.strip()[:120],
                ))

    return findings


# ── Utilities ──────────────────────────────────────────────────────────

def _read_file(filepath: str) -> str | None:
    """Read a file, returning None if it doesn't exist."""
    if not os.path.isfile(filepath):
        return None
    try:
        with open(filepath, "r", encoding="utf-8", errors="replace") as f:
            return f.read()
    except Exception:
        return None


def _severity_score(severity: str) -> int:
    return {"CRITICAL": 4, "HIGH": 3, "MEDIUM": 2, "LOW": 1, "INFO": 0}.get(severity, 0)


# ── Main audit function ────────────────────────────────────────────────

def run_security_audit(kgraph_dir: str | None = None) -> dict:
    """Run a full security audit of the kgraph package.

    Args:
        kgraph_dir: Directory containing kgraph source files. Defaults to
                    the directory of this file.

    Returns:
        Audit report dict with findings grouped by module.
    """
    source_dir = kgraph_dir or os.path.dirname(__file__)

    html_path = os.path.join(source_dir, "html.py")
    server_path = os.path.join(source_dir, "server.py")
    mcp_path = os.path.join(source_dir, "mcp_server.py")

    all_findings: list[AuditFinding] = []

    # Scan each module
    all_findings.extend(scan_html_for_xss(html_path))
    all_findings.extend(scan_server_for_risks(server_path))
    all_findings.extend(scan_mcp_server(mcp_path))

    # Sort by severity (highest first)
    all_findings.sort(key=lambda f: _severity_score(f.severity), reverse=True)

    # Group by module file
    by_file: dict[str, list[dict]] = {}
    for finding in all_findings:
        by_file.setdefault(finding.file, []).append(finding.to_dict())

    # Stats
    severity_counts = {"CRITICAL": 0, "HIGH": 0, "MEDIUM": 0, "LOW": 0, "INFO": 0}
    for f in all_findings:
        severity_counts[f.severity] = severity_counts.get(f.severity, 0) + 1

    report = {
        "audit_timestamp": datetime.now().isoformat(),
        "audited_modules": [
            "html.py (XSS vulnerability scan)",
            "server.py (path traversal, injection scan)",
            "mcp_server.py (input validation scan)",
        ],
        "severity_summary": severity_counts,
        "total_findings": len(all_findings),
        "findings_by_file": by_file,
        "findings_flat": [f.to_dict() for f in all_findings],
    }

    return report


def generate_audit_html_report(report: dict) -> str:
    """Generate an HTML audit report."""
    summary = report.get("severity_summary", {})
    total = report.get("total_findings", 0)

    findings_rows = ""
    for finding in report.get("findings_flat", []):
        sev = finding.get("severity", "INFO")
        sev_colors = {
            "CRITICAL": "#f87171", "HIGH": "#fb923c",
            "MEDIUM": "#facc15", "LOW": "#94a3b8", "INFO": "#38bdf8",
        }
        color = sev_colors.get(sev, "#94a3b8")
        snippet = finding.get("code_snippet", "")
        snippet_html = f'<pre><code>{snippet}</code></pre>' if snippet else ""

        findings_rows += f"""\
<tr>
  <td><span class="sev-dot" style="background:{color}"></span>{sev}</td>
  <td>{finding.get("category", "")}</td>
  <td><strong>{finding.get("title", "")}</strong><br>
      <span class="finding-desc">{finding.get("description", "")}</span></td>
  <td><span class="finding-rec">{finding.get("recommendation", "")}</span></td>
  <td>{os.path.basename(finding.get("file", ""))}:{finding.get("line", "?")}</td>
</tr>"""

    def _sev_card(label, count, color):
        return f"""\
<div class="card">
  <div class="card-num" style="color:{color}">{count}</div>
  <div class="card-label">{label}</div>
</div>"""

    return f"""\
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>kgraph Security Audit Report</title>
<style>
  :root {{ --bg: #0f172a; --surface: #1e293b; --border: #334155; --text: #e2e8f0; --dim: #94a3b8; }}
  * {{ box-sizing: border-box; margin: 0; padding: 0; }}
  body {{ background: var(--bg); color: var(--text); font-family: system-ui, sans-serif; padding: 24px; }}
  h1 {{ font-size: 1.6rem; margin-bottom: 4px; }}
  .subtitle {{ color: var(--dim); font-size: 0.85rem; margin-bottom: 20px; }}
  .grid {{ display: grid; grid-template-columns: repeat(auto-fit, minmax(140px, 1fr)); gap: 12px; margin-bottom: 24px; }}
  .card {{ background: var(--surface); border: 1px solid var(--border); border-radius: 8px; padding: 16px; text-align: center; }}
  .card-num {{ font-size: 1.8rem; font-weight: 700; }}
  .card-label {{ font-size: 0.75rem; color: var(--dim); text-transform: uppercase; margin-top: 4px; }}
  table {{ width: 100%; border-collapse: collapse; }}
  th, td {{ padding: 10px 12px; text-align: left; border-bottom: 1px solid var(--border); font-size: 0.85rem; vertical-align: top; }}
  th {{ color: var(--dim); text-transform: uppercase; font-size: 0.75rem; white-space: nowrap; }}
  tr:hover {{ background: rgba(255,255,255,0.03); }}
  .sev-dot {{ display: inline-block; width: 8px; height: 8px; border-radius: 50%; margin-right: 6px; }}
  .finding-desc {{ font-size: 0.8rem; color: var(--dim); }}
  .finding-rec {{ font-size: 0.8rem; color: #c084fc; }}
  pre {{ background: #111827; padding: 8px; border-radius: 4px; overflow-x: auto; font-size: 0.75rem; }}
  code {{ color: #e2e8f0; }}
  .modules {{ padding: 12px; background: var(--surface); border: 1px solid var(--border); border-radius: 8px; margin-bottom: 20px; }}
  .modules li {{ margin-left: 20px; color: var(--dim); font-size: 0.85rem; }}
</style>
</head>
<body>
<h1>🔒 kgraph Security Audit Report</h1>
<p class="subtitle">{report.get("audit_timestamp", "")}</p>

<div class="modules">
  <strong>Audited Modules:</strong>
  <ul>{"".join(f"<li>{m}</li>" for m in report.get("audited_modules", []))}</ul>
</div>

<div class="grid">
  {_sev_card("CRITICAL", summary.get("CRITICAL", 0), "#f87171")}
  {_sev_card("HIGH", summary.get("HIGH", 0), "#fb923c")}
  {_sev_card("MEDIUM", summary.get("MEDIUM", 0), "#facc15")}
  {_sev_card("LOW", summary.get("LOW", 0), "#94a3b8")}
  {_sev_card("INFO", summary.get("INFO", 0), "#38bdf8")}
  <div class="card"><div class="card-num">{total}</div><div class="card-label">Total Findings</div></div>
</div>

<h2>Findings</h2>
<table>
<thead><tr><th>Severity</th><th>Category</th><th>Description</th><th>Recommendation</th><th>Location</th></tr></thead>
<tbody>{findings_rows}</tbody>
</table>
</body>
</html>
"""


def main():
    """CLI entry point: kgraph-audit [--output audit.html]"""
    output = None
    if len(sys.argv) > 1:
        for i, arg in enumerate(sys.argv[1:]):
            if arg == "--output" and i + 2 < len(sys.argv):
                output = sys.argv[i + 2]
            elif arg.startswith("--output="):
                output = arg.split("=", 1)[1]

    report = run_security_audit()

    if output:
        if output.endswith(".html") or output.endswith(".htm"):
            html = generate_audit_html_report(report)
            with open(output, "w", encoding="utf-8") as f:
                f.write(html)
            print(f"HTML audit report written to {output}")
        else:
            with open(output, "w", encoding="utf-8") as f:
                json.dump(report, f, indent=2)
            print(f"JSON audit report written to {output}")
    else:
        print(f"\n=== kgraph Security Audit Report ===")
        print(f"Timestamp: {report.get('audit_timestamp', '')}")
        print(f"Total findings: {report.get('total_findings', 0)}")
        sev = report.get("severity_summary", {})
        for level in ["CRITICAL", "HIGH", "MEDIUM", "LOW", "INFO"]:
            if sev.get(level, 0):
                print(f"  {level}: {sev[level]}")
        print()

        for finding in report.get("findings_flat", []):
            print(f"  [{finding['severity']}] {finding['title']}")
            print(f"    File: {os.path.basename(finding.get('file', ''))}:{finding.get('line', '?')}")
            print(f"    {finding['description'][:100]}...")
            print()

    return report


if __name__ == "__main__":
    main()
