"""Input security and validation module for kgraph.

Validates input graph JSON against common attacks:
- Sanitizes node/edge labels (XSS prevention)
- Guards against graph JSON bombs (deeply nested objects, massive payloads)
- Rate-limits (MCP server side integration)
- Integrates with validate.py

CLI integration:
    kgraph --security-check <graph.json>
"""

import json
import os
import re
import sys
import time

# ── Security limits ─────────────────────────────────────────────────────

MAX_GRAPH_NODES = 100_000       # Maximum nodes in a graph
MAX_GRAPH_EDGES = 500_000       # Maximum edges in a graph
MAX_NESTING_DEPTH = 10          # Maximum JSON nesting depth
MAX_PAYLOAD_SIZE = 100 * 1024 * 1024  # 100 MB max payload
MAX_LABEL_LENGTH = 500          # Maximum label length
MAX_FIELD_LENGTH = 5000         # Maximum field string length

# Constants for rate limiting
RATE_LIMIT_WINDOW = 60          # seconds
RATE_LIMIT_MAX = 30             # requests per window


# ── XSS Sanitization ────────────────────────────────────────────────────

_XSS_PATTERN = re.compile(r'[<>&"\']')
_XSS_REPLACEMENTS = {
    '<': '&lt;',
    '>': '&gt;',
    '&': '&amp;',
    '"': '&quot;',
    "'": '&#x27;',
}

# Additional dangerous patterns
_DANGEROUS_HTML_PATTERNS = re.compile(
    r'javascript\s*:|<script|on\w+\s*=|data\s*:\s*text/html|'
    r'<iframe|<embed|<object|<svg|<img\s+[^>]*\bon',
    re.IGNORECASE,
)

# Path traversal patterns
_PATH_TRAVERSAL = re.compile(r'\.\./|\.\.\\|~[/\\]|/etc/|/proc/', re.IGNORECASE)

# Injection patterns for JSON fields
_INJECTION_PATTERNS = [
    (r'<\s*script[^>]*>', 'HTML script tag'),
    (r'<\s*iframe[^>]*>', 'HTML iframe tag'),
    (r'on\w+\s*=\s*["\']', 'Inline event handler'),
    (r'javascript\s*:', 'javascript: URI'),
    (r'data\s*:\s*text/html', 'data:text/html URI'),
]


def sanitize_label(label: str) -> str:
    """Sanitize a node/edge label against XSS attacks.

    Escapes HTML special characters and removes dangerous patterns.
    """
    if not isinstance(label, str):
        return str(label) if label is not None else ""

    # Escape HTML entities
    escaped = _XSS_PATTERN.sub(lambda m: _XSS_REPLACEMENTS.get(m.group(0), m.group(0)), label)

    # Truncate excessively long labels
    if len(escaped) > MAX_LABEL_LENGTH:
        escaped = escaped[:MAX_LABEL_LENGTH] + "…"

    return escaped


def sanitize_graph(graph: dict) -> dict:
    """Sanitize all node and edge labels in a graph to prevent XSS.

    Returns a new graph with sanitized labels.
    """
    sanitized = {"nodes": [], "edges": []}

    for node in graph.get("nodes", []):
        safe_node = dict(node)
        if "label" in safe_node:
            safe_node["label"] = sanitize_label(safe_node["label"])
        if "description" in safe_node:
            safe_node["description"] = sanitize_label(safe_node["description"])
        # Sanitize any string field
        for key, value in safe_node.items():
            if isinstance(value, str) and key not in ("id",):
                safe_node[key] = sanitize_label(value)
        sanitized["nodes"].append(safe_node)

    for edge in graph.get("edges", []):
        safe_edge = dict(edge)
        if "label" in safe_edge:
            safe_edge["label"] = sanitize_label(safe_edge["label"])
        for key, value in safe_edge.items():
            if isinstance(value, str) and key not in ("from", "to", "source", "target"):
                safe_edge[key] = sanitize_label(value)
        sanitized["edges"].append(safe_edge)

    return sanitized


# ── JSON bomb detection ─────────────────────────────────────────────────

def _check_nesting_depth(obj, current_depth: int = 0, max_depth: int = MAX_NESTING_DEPTH) -> int:
    """Recursively check the maximum nesting depth of a JSON structure."""
    if not isinstance(obj, (dict, list)):
        return current_depth
    if current_depth > max_depth:
        return current_depth
    max_found = current_depth
    if isinstance(obj, dict):
        for value in obj.values():
            depth = _check_nesting_depth(value, current_depth + 1, max_depth)
            if depth > max_found:
                max_found = depth
    elif isinstance(obj, list):
        for item in obj:
            depth = _check_nesting_depth(item, current_depth + 1, max_depth)
            if depth > max_found:
                max_found = depth
    return max_found


def detect_json_bomb(payload: str | bytes | dict) -> list[dict]:
    """Check for JSON bombs (deeply nested, massive payloads).

    Returns a list of issue dicts.
    """
    issues = []

    if isinstance(payload, (str, bytes)):
        raw_size = len(payload)
    else:
        raw_size = len(json.dumps(payload))

    if raw_size > MAX_PAYLOAD_SIZE:
        issues.append({
            "severity": "error",
            "type": "json_bomb",
            "message": f"Payload size {raw_size} bytes exceeds limit of {MAX_PAYLOAD_SIZE}",
            "size": raw_size,
            "limit": MAX_PAYLOAD_SIZE,
        })

    # Parse if needed
    if isinstance(payload, (str, bytes)):
        try:
            obj = json.loads(payload)
        except json.JSONDecodeError as e:
            issues.append({
                "severity": "error",
                "type": "parse_error",
                "message": f"JSON parse error: {e}",
            })
            return issues
    else:
        obj = payload

    # Check nesting depth
    if isinstance(obj, (dict, list)):
        depth = _check_nesting_depth(obj)
        if depth > MAX_NESTING_DEPTH:
            issues.append({
                "severity": "error",
                "type": "excessive_nesting",
                "message": f"Nesting depth {depth} exceeds limit of {MAX_NESTING_DEPTH}",
                "depth": depth,
                "limit": MAX_NESTING_DEPTH,
            })

    # Check node/edge counts
    nodes = obj.get("nodes", []) if isinstance(obj, dict) else []
    edges = obj.get("edges", []) if isinstance(obj, dict) else []

    if len(nodes) > MAX_GRAPH_NODES:
        issues.append({
            "severity": "error",
            "type": "too_many_nodes",
            "message": f"Node count {len(nodes)} exceeds limit of {MAX_GRAPH_NODES}",
            "count": len(nodes),
            "limit": MAX_GRAPH_NODES,
        })

    if len(edges) > MAX_GRAPH_EDGES:
        issues.append({
            "severity": "error",
            "type": "too_many_edges",
            "message": f"Edge count {len(edges)} exceeds limit of {MAX_GRAPH_EDGES}",
            "count": len(edges),
            "limit": MAX_GRAPH_EDGES,
        })

    # Check for injection patterns
    if isinstance(obj, dict):
        for item in nodes:
            injection_issues = _check_injection(item)
            issues.extend(injection_issues)
        for item in edges:
            injection_issues = _check_injection(item)
            issues.extend(injection_issues)

    return issues


def _check_injection(item: dict) -> list[dict]:
    """Check a single node or edge for injection patterns."""
    issues = []
    for key, value in item.items():
        if isinstance(value, str):
            for pattern, desc in _INJECTION_PATTERNS:
                if re.search(pattern, value):
                    issues.append({
                        "severity": "warning",
                        "type": "injection",
                        "message": f"Possible {desc} in field '{key}'",
                        "field": key,
                    })
    return issues


# ── Path traversal detection ────────────────────────────────────────────

def detect_path_traversal(path: str) -> list[dict]:
    """Check a file path for traversal or injection attempts.

    Returns a list of issue dicts.
    """
    issues = []
    if _PATH_TRAVERSAL.search(path):
        issues.append({
            "severity": "error",
            "type": "path_traversal",
            "message": f"Path contains traversal sequences: {path}",
            "path": path,
        })
    return issues


# ── Rate Limiter (MCP server side) ──────────────────────────────────────

class RateLimiter:
    """Simple sliding-window rate limiter for MCP server use."""

    def __init__(self, max_requests: int = RATE_LIMIT_MAX, window: float = RATE_LIMIT_WINDOW):
        self.max_requests = max_requests
        self.window = window
        self.requests: list[float] = []

    def allow(self) -> bool:
        """Check if a request is allowed. Returns True if within limit."""
        now = time.monotonic()
        cutoff = now - self.window
        self.requests = [t for t in self.requests if t > cutoff]
        if len(self.requests) < self.max_requests:
            self.requests.append(now)
            return True
        return False

    def remaining(self) -> int:
        """Return the number of remaining requests in the current window."""
        now = time.monotonic()
        cutoff = now - self.window
        self.requests = [t for t in self.requests if t > cutoff]
        return max(0, self.max_requests - len(self.requests))

    def reset(self):
        """Reset the rate limiter."""
        self.requests.clear()


# ── Security check ─────────────────────────────────────────────────────

def check_graph_security(filepath: str) -> list[dict]:
    """Run all security checks on a graph file.

    Returns a combined list of issue dicts (validate errors + security issues).
    """
    if not os.path.isfile(filepath):
        return [{
            "severity": "error",
            "type": "file_not_found",
            "message": f"File not found: {filepath}",
        }]

    # Read raw payload for size check
    try:
        with open(filepath, "rb") as f:
            raw = f.read()
    except Exception as e:
        return [{
            "severity": "error",
            "type": "read_error",
            "message": f"Error reading {filepath}: {e}",
        }]

    # JSON bomb detection
    bomb_issues = detect_json_bomb(raw)
    security_issues = list(bomb_issues)

    # If bomb detected, stop further processing
    has_fatal = any(i.get("severity") == "error" for i in bomb_issues)
    if has_fatal:
        return security_issues

    # Parse and validate
    try:
        graph = json.loads(raw)
    except json.JSONDecodeError as e:
        security_issues.append({
            "severity": "error",
            "type": "parse_error",
            "message": f"JSON parse error in {filepath} at line {e.lineno}, col {e.colno}: {e.msg}",
        })
        return security_issues

    # Schema validation (from validate.py) — lazy import to avoid circular dep
    from .validate import validate_graph
    schema_errors = validate_graph(graph)
    security_issues.extend(schema_errors)

    # Sanitize as a safety check — report potential XSS
    for node in graph.get("nodes", []):
        for key, value in node.items():
            if isinstance(value, str):
                sanitized = sanitize_label(value)
                if sanitized != value:
                    security_issues.append({
                        "severity": "warning",
                        "type": "xss_potential",
                        "message": f"XSS-suspect content in node field '{key}': {value[:100]}",
                    })

    for edge in graph.get("edges", []):
        for key, value in edge.items():
            if isinstance(value, str):
                sanitized = sanitize_label(value)
                if sanitized != value:
                    security_issues.append({
                        "severity": "warning",
                        "type": "xss_potential",
                        "message": f"XSS-suspect content in edge field '{key}': {value[:100]}",
                    })

    return security_issues


def main():
    """CLI entry point: kgraph-security <graph.json>"""
    if len(sys.argv) < 2:
        print("Usage: python -m kgraph.security <graph.json>")
        print("       python -m kgraph.security --sanitize <graph.json>")
        sys.exit(1)

    args = sys.argv[1:]
    do_sanitize = "--sanitize" in args or "-s" in args
    filepath = [a for a in args if not a.startswith("-")][0] if [a for a in args if not a.startswith("-")] else None

    if not filepath:
        print("Error: no file specified")
        sys.exit(1)

    if do_sanitize:
        try:
            with open(filepath, "r", encoding="utf-8") as f:
                graph = json.load(f)
        except Exception as e:
            print(f"Error reading {filepath}: {e}")
            sys.exit(1)

        sanitized = sanitize_graph(graph)
        outpath = filepath.replace(".json", "_sanitized.json")
        with open(outpath, "w", encoding="utf-8") as f:
            json.dump(sanitized, f, indent=2)
        print(f"Sanitized graph written to {outpath}")
        return

    issues = check_graph_security(filepath)
    if issues:
        print(f"Security check: {len(issues)} issue(s)")
        for issue in issues:
            print(f"  [{issue.get('severity', 'info')}] [{issue.get('type', 'unknown')}] {issue.get('message', '')}")
        sys.exit(1)
    else:
        print(f"{filepath}: security check PASSED")


if __name__ == "__main__":
    main()
