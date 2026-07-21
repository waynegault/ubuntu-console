"""Graph JSON validation using Pydantic models + security checks.

Schema validation is handled by ``Graph.from_dict()`` (Pydantic).
This module adds security validation (payload size, nesting depth,
XSS pattern detection) on top of the Pydantic schema.

CLI:
    kgraph --validate <graph.json>
"""

from __future__ import annotations

import json
import os
import re
import sys

from pydantic import ValidationError

from .models import Graph

# ── Security limits ─────────────────────────────────────────────────────

MAX_NODES = 500_000
MAX_EDGES = 1_000_000
MAX_JSON_DEPTH = 20
MAX_LABEL_LENGTH = 500
MAX_PAYLOAD_SIZE = 100 * 1024 * 1024  # 100 MB

DANGEROUS_PATTERNS = re.compile(
    r"<script[\s>]|javascript\s*:|on\w+\s*=|data\s*:\s*text/html"
    r"|vbscript\s*:|file\s*://|document\.\w+|window\.\w+"
    r"|eval\s*\(|setTimeout\s*\(|setInterval\s*\(",
    re.IGNORECASE,
)


# ── Helpers ────────────────────────────────────────────────────────────


def _json_depth(obj: object, d: int = 0) -> int:
    if d > MAX_JSON_DEPTH + 5:
        return d
    if isinstance(obj, dict):
        return max((_json_depth(v, d + 1) for v in obj.values()), default=d + 1)
    if isinstance(obj, list):
        return max((_json_depth(item, d + 1) for item in obj), default=d + 1)
    return d


def _check_xss(data: dict) -> list[dict]:
    """Scan all string values for dangerous patterns."""
    errors: list[dict] = []
    for idx, node in enumerate(data.get("nodes", [])):
        if not isinstance(node, dict):
            continue
        for key, value in node.items():
            if isinstance(value, str) and DANGEROUS_PATTERNS.search(value):
                errors.append({
                    "severity": "error",
                    "message": f"nodes[{idx}]: field '{key}' contains dangerous patterns",
                    "node_idx": idx,
                    "field": key,
                })
    for idx, edge in enumerate(data.get("edges", [])):
        if not isinstance(edge, dict):
            continue
        for key, value in edge.items():
            if isinstance(value, str) and DANGEROUS_PATTERNS.search(value):
                errors.append({
                    "severity": "error",
                    "message": f"edges[{idx}]: field '{key}' contains dangerous patterns",
                    "edge_idx": idx,
                    "field": key,
                })
    return errors


# ── Validation ──────────────────────────────────────────────────────────


def validate_graph(graph: dict) -> list[dict]:
    """Validate a graph dictionary against the Pydantic schema + security rules.

    Returns a list of error dicts with keys: severity, message.
    """
    errors: list[dict] = []

    if not isinstance(graph, dict):
        return [{"severity": "error", "message": "Graph root must be a dict with 'nodes' and 'edges'"}]

    # Nesting check
    depth = _json_depth(graph)
    if depth > MAX_JSON_DEPTH:
        errors.append({
            "severity": "error",
            "message": f"Excessive nesting depth ({depth}, max {MAX_JSON_DEPTH})",
        })

    nodes = graph.get("nodes", [])
    edges = graph.get("edges", [])

    if not isinstance(nodes, list):
        errors.append({"severity": "error", "message": "'nodes' must be a list"})
    elif len(nodes) > MAX_NODES:
        errors.append({"severity": "error", "message": f"Too many nodes ({len(nodes)}, max {MAX_NODES})"})

    if not isinstance(edges, list):
        errors.append({"severity": "error", "message": "'edges' must be a list"})
    elif len(edges) > MAX_EDGES:
        errors.append({"severity": "error", "message": f"Too many edges ({len(edges)}, max {MAX_EDGES})"})

    # XSS check on raw data
    errors.extend(_check_xss(graph))

    # Pydantic schema validation
    try:
        Graph.from_dict(graph)
    except ValidationError as exc:
        for err in exc.errors():
            loc = " → ".join(str(part) for part in err["loc"])
            errors.append({
                "severity": "error",
                "message": f"Schema: {loc}: {err['msg']}",
            })

    return errors


def validate_graph_file(filepath: str) -> list[dict]:
    """Load and validate a graph JSON file."""
    if not os.path.isfile(filepath):
        return [{"severity": "error", "message": f"File not found: {filepath}"}]

    try:
        with open(filepath, "r", encoding="utf-8") as f:
            graph = json.load(f)
    except json.JSONDecodeError as e:
        return [{"severity": "error", "message": f"JSON parse error in {filepath} at line {e.lineno}, col {e.colno}: {e.msg}"}]
    except OSError as e:
        return [{"severity": "error", "message": f"Error reading {filepath}: {e}"}]

    errors = validate_graph(graph)
    for err in errors:
        err["file"] = filepath
    return errors


def validate_graph_payload(payload: bytes | str | dict) -> tuple[bool, str]:
    """Validate an incoming graph payload for safety.

    Returns (True, '') or (False, error_reason).
    Used by mcp_server.py for pre-flight security checks.
    """
    if isinstance(payload, (bytes, str)):
        size = len(payload) if isinstance(payload, bytes) else len(payload.encode("utf-8"))
        if size > MAX_PAYLOAD_SIZE:
            return False, f"Payload too large ({size} bytes, max {MAX_PAYLOAD_SIZE})"
        try:
            data = json.loads(payload)
        except json.JSONDecodeError as e:
            return False, f"Invalid JSON: {e}"
    elif isinstance(payload, dict):
        data = payload
    else:
        return False, "Payload must be JSON string or dict"

    errors = validate_graph(data)
    if any(e.get("severity") == "error" for e in errors):
        return False, errors[0].get("message", "Validation failed")
    return True, ""


def sanitize_label(label: str) -> str:
    """Strip dangerous content from a label string."""
    if not label:
        return ""
    label = re.sub(r"<[^>]*>", "", label)
    label = DANGEROUS_PATTERNS.sub("", label)
    if len(label) > MAX_LABEL_LENGTH:
        label = label[:MAX_LABEL_LENGTH]
    return label.strip()


def main() -> None:
    """CLI entry point: python -m kgraph.validate <graph.json>"""
    if len(sys.argv) < 2:
        print("Usage: python -m kgraph.validate <graph.json>")
        sys.exit(1)
    fp = sys.argv[1]
    errors = validate_graph_file(fp)
    if errors:
        print(f"Validation: {len(errors)} issue(s)")
        for err in errors:
            ref = err.get("file", "")
            sev = err.get("severity", "error")
            print(f"  [{sev}] {ref}: {err.get('message', '')}")
        sys.exit(1)
    else:
        print(f"{fp}: validation PASSED")


if __name__ == "__main__":
    main()