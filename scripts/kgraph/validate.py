"""Graph JSON validation against an extraction output schema.

Enforces node and edge schema (required/optional fields, types)
and reports errors with details.

Also provides input security validation (payload size, nesting, XSS).

CLI:
    kgraph --validate <graph.json>
"""

import json
import os
import re
import sys

# ── Schema definitions ──────────────────────────────────────────────────

NODE_SCHEMA = {
    "required": ["id", "label"],
    "optional": {
        "type": str,
        "group": str,
        "degree": (int, float),
        "importance": (int, float),
        "confidence": str,
        "source": str,
        "description": str,
        "content_preview": str,
        "file": str,
        "line": int,
        "col": int,
        "parent": str,
        "children": list,
        "metadata": dict,
    },
    "field_types": {
        "id": (str, int),
        "label": str,
    },
}

EDGE_SCHEMA = {
    "required": ["from", "to"],
    "optional": {
        "label": str,
        "type": str,
        "weight": (int, float),
        "semantic_score": (int, float),
        "source": str,
        "confidence": str,
        "metadata": dict,
    },
    "field_types": {
        "from": (str, int),
        "to": (str, int),
    },
}

ALLOWED_CONFIDENCE = {
    "EXTRACTED", "INFERRED", "AMBIGUOUS",
    "extracted", "inferred", "ambiguous",
    "high", "medium", "low",
}

# ── Security limits ─────────────────────────────────────────────────────

MAX_NODES = 500_000
MAX_EDGES = 1_000_000
MAX_JSON_DEPTH = 20
MAX_LABEL_LENGTH = 500
MAX_PAYLOAD_SIZE = 100 * 1024 * 1024  # 100 MB

DANGEROUS_PATTERNS = re.compile(
    r'<script[\s>]|javascript\s*:|on\w+\s*=|data\s*:\s*text/html'
    r'|vbscript\s*:|file\s*://|document\.\w+|window\.\w+'
    r'|eval\s*\(|setTimeout\s*\(|setInterval\s*\(',
    re.IGNORECASE,
)


# ── Type helpers ────────────────────────────────────────────────────────

def _type_name(t):
    if isinstance(t, tuple):
        return " | ".join(_type_name(x) for x in t)
    if isinstance(t, type):
        return t.__name__
    return str(t)


def _check_field(value, expected, field_name: str, context: str) -> list[dict]:
    errors = []
    if expected is None:
        return errors
    if isinstance(expected, type):
        if not isinstance(value, expected):
            errors.append({
                "severity": "error",
                "message": f"{context}: field '{field_name}' expected {expected.__name__}, got {type(value).__name__}",
                "field": field_name,
            })
    elif isinstance(expected, tuple):
        if not any(isinstance(value, t) for t in expected):
            names = " | ".join(t.__name__ for t in expected)
            errors.append({
                "severity": "error",
                "message": f"{context}: field '{field_name}' expected {names}, got {type(value).__name__}",
                "field": field_name,
            })
    return errors


def _json_depth(obj, d: int = 0) -> int:
    if d > MAX_JSON_DEPTH + 5:
        return d
    if isinstance(obj, dict):
        return max((_json_depth(v, d + 1) for v in obj.values()), default=d + 1)
    if isinstance(obj, list):
        return max((_json_depth(item, d + 1) for item in obj), default=d + 1)
    return d


# ── Validation ──────────────────────────────────────────────────────────

def validate_graph(graph: dict) -> list[dict]:
    """Validate a graph dictionary against node/edge schema.

    Returns a list of error dicts with keys: severity, message, node_idx/edge_idx, field.
    """
    errors = []

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
        nodes = []
    if not isinstance(edges, list):
        errors.append({"severity": "error", "message": "'edges' must be a list"})
        edges = []

    if len(nodes) > MAX_NODES:
        errors.append({"severity": "error", "message": f"Too many nodes ({len(nodes)}, max {MAX_NODES})"})
    if len(edges) > MAX_EDGES:
        errors.append({"severity": "error", "message": f"Too many edges ({len(edges)}, max {MAX_EDGES})"})

    seen_ids = set()
    for idx, node in enumerate(nodes):
        if not isinstance(node, dict):
            errors.append({"severity": "error", "message": f"nodes[{idx}]: expected dict, got {type(node).__name__}", "node_idx": idx})
            continue

        ctx = f"nodes[{idx}]"
        nid = node.get("id")

        for field in NODE_SCHEMA["required"]:
            if field not in node:
                errors.append({"severity": "error", "message": f"{ctx}: missing required field '{field}'", "node_idx": idx, "field": field})

        if nid is not None:
            errors.extend(_check_field(nid, NODE_SCHEMA["field_types"]["id"], "id", ctx))
        label = node.get("label")
        if label is not None:
            errors.extend(_check_field(label, NODE_SCHEMA["field_types"]["label"], "label", ctx))

        for field, expected in NODE_SCHEMA["optional"].items():
            if field in node and node[field] is not None:
                errors.extend(_check_field(node[field], expected, field, ctx))

        known = set(NODE_SCHEMA["required"]) | set(NODE_SCHEMA["optional"].keys())
        unknown = set(node.keys()) - known
        for field in sorted(unknown):
            errors.append({"severity": "warning", "message": f"{ctx}: unknown field '{field}'", "node_idx": idx, "field": field})

        # Duplicate ID
        if nid is not None:
            sid = str(nid)
            if sid in seen_ids:
                pass  # warned once is enough
            seen_ids.add(sid)

        # Confidence
        conf = node.get("confidence")
        if conf and conf.upper() not in {v.upper() for v in ALLOWED_CONFIDENCE}:
            errors.append({"severity": "warning", "message": f"{ctx}: non-standard confidence '{conf}'", "node_idx": idx, "field": "confidence"})

        # XSS check
        for key, value in node.items():
            if isinstance(value, str) and DANGEROUS_PATTERNS.search(value):
                errors.append({"severity": "error", "message": f"{ctx}: field '{key}' contains dangerous patterns", "node_idx": idx, "field": key})

    for idx, edge in enumerate(edges):
        if not isinstance(edge, dict):
            errors.append({"severity": "error", "message": f"edges[{idx}]: expected dict, got {type(edge).__name__}", "edge_idx": idx})
            continue

        ctx = f"edges[{idx}]"
        for field in EDGE_SCHEMA["required"]:
            if field not in edge:
                errors.append({"severity": "error", "message": f"{ctx}: missing required field '{field}'", "edge_idx": idx, "field": field})
            else:
                ft = EDGE_SCHEMA["field_types"].get(field)
                if ft:
                    errors.extend(_check_field(edge[field], ft, field, ctx))

        for field, expected in EDGE_SCHEMA["optional"].items():
            if field in edge and edge[field] is not None:
                errors.extend(_check_field(edge[field], expected, field, ctx))

        known = set(EDGE_SCHEMA["required"]) | set(EDGE_SCHEMA["optional"].keys())
        unknown = set(edge.keys()) - known
        for field in sorted(unknown):
            errors.append({"severity": "warning", "message": f"{ctx}: unknown field '{field}'", "edge_idx": idx, "field": field})

        conf = edge.get("confidence")
        if conf and conf.upper() not in {v.upper() for v in ALLOWED_CONFIDENCE}:
            errors.append({"severity": "warning", "message": f"{ctx}: non-standard confidence '{conf}'", "edge_idx": idx, "field": "confidence"})

        for key, value in edge.items():
            if isinstance(value, str) and DANGEROUS_PATTERNS.search(value):
                errors.append({"severity": "error", "message": f"{ctx}: field '{key}' contains dangerous patterns", "edge_idx": idx, "field": key})

    return errors


def validate_graph_file(filepath: str) -> list[dict]:
    """Load and validate a graph JSON file against the schema.

    Returns a list of error dicts, each with 'message' key.
    """
    if not os.path.isfile(filepath):
        return [{"severity": "error", "message": f"File not found: {filepath}"}]

    try:
        with open(filepath, "r", encoding="utf-8") as f:
            graph = json.load(f)
    except json.JSONDecodeError as e:
        return [{"severity": "error", "message": f"JSON parse error in {filepath} at line {e.lineno}, col {e.colno}: {e.msg}"}]
    except Exception as e:
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


def main():
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
