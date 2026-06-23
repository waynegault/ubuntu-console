"""Input security and validation for kgraph.

Prevents:
- File:// redirect XSS in graph data
- Graph JSON bombs (deeply nested structures, huge payloads)
- Label injection (HTML/JS in node labels)
- Path traversal in file references

All validation functions return (is_valid, error_message).
"""

import json
import re

# ── Limits ─────────────────────────────────────────────────────────────

MAX_NODES = 500_000
MAX_EDGES = 1_000_000
MAX_JSON_DEPTH = 20
MAX_LABEL_LENGTH = 500
MAX_EDGE_LABEL_LENGTH = 200
MAX_STRING_LENGTH = 10_000
MAX_PAYLOAD_SIZE = 100 * 1024 * 1024  # 100 MB

# ── Dangerous patterns ─────────────────────────────────────────────────

DANGEROUS_PATTERNS = re.compile(
    r'<script[\s>]|javascript\s*:|on\w+\s*=|data\s*:\s*text/html'
    r'|vbscript\s*:|file\s*://|document\.\w+|window\.\w+'
    r'|eval\s*\(|setTimeout\s*\(|setInterval\s*\(',
    re.IGNORECASE,
)


def validate_graph_payload(payload: bytes | str | dict) -> tuple[bool, str]:
    """Validate an incoming graph payload for safety.

    Returns (True, '') or (False, error_reason).
    """
    if isinstance(payload, (bytes, str)):
        if isinstance(payload, bytes):
            size = len(payload)
        else:
            size = len(payload.encode('utf-8'))
        if size > MAX_PAYLOAD_SIZE:
            return False, f'Payload too large ({size} bytes, max {MAX_PAYLOAD_SIZE})'
        try:
            data = json.loads(payload)
        except json.JSONDecodeError as e:
            return False, f'Invalid JSON: {e}'
    elif isinstance(payload, dict):
        data = payload
    else:
        return False, 'Payload must be JSON string or dict'

    return _validate_graph_dict(data)


def _validate_graph_dict(data: dict) -> tuple[bool, str]:
    """Validate a parsed graph dict."""
    depth = _json_depth(data)
    if depth > MAX_JSON_DEPTH:
        return False, f'Excessive nesting depth ({depth}, max {MAX_JSON_DEPTH})'

    nodes = data.get('nodes', []) or []
    edges = data.get('edges', []) or []

    if len(nodes) > MAX_NODES:
        return False, f'Too many nodes ({len(nodes)}, max {MAX_NODES})'
    if len(edges) > MAX_EDGES:
        return False, f'Too many edges ({len(edges)}, max {MAX_EDGES})'

    # Validate each node
    for i, node in enumerate(nodes):
        if not isinstance(node, dict):
            return False, f'Node[{i}] is not an object'
        ok, err = _validate_node(node)
        if not ok:
            return False, f'Node[{i}]: {err}'

    # Validate each edge
    for i, edge in enumerate(edges):
        if not isinstance(edge, dict):
            return False, f'Edge[{i}] is not an object'
        ok, err = _validate_edge(edge)
        if not ok:
            return False, f'Edge[{i}]: {err}'

    return True, ''


def _validate_node(node: dict) -> tuple[bool, str]:
    """Validate a single node dict."""
    for key, value in node.items():
        if isinstance(value, str):
            if len(value) > MAX_STRING_LENGTH:
                return False, f'Field "{key}" exceeds max string length ({len(value)})'
            if DANGEROUS_PATTERNS.search(value):
                return False, f'Field "{key}" contains dangerous patterns'
            if key == 'label' and len(value) > MAX_LABEL_LENGTH:
                return False, f'Label too long ({len(value)}, max {MAX_LABEL_LENGTH})'
            if key == 'id' and re.search(r'[/\0]', value):
                return False, f'Node id contains invalid characters: {value!r}'
    return True, ''


def _validate_edge(edge: dict) -> tuple[bool, str]:
    """Validate a single edge dict."""
    for key, value in edge.items():
        if isinstance(value, str):
            if len(value) > MAX_STRING_LENGTH:
                return False, f'Field "{key}" exceeds max string length ({len(value)})'
            if DANGEROUS_PATTERNS.search(value):
                return False, f'Field "{key}" contains dangerous patterns'
            if key == 'label' and len(value) > MAX_EDGE_LABEL_LENGTH:
                return False, f'Edge label too long ({len(value)}, max {MAX_EDGE_LABEL_LENGTH})'
            if key in ('from', 'to', 'source', 'target') and re.search(r'[/\0]', value):
                return False, f'Edge endpoint id contains invalid characters: {value!r}'
    return True, ''


def _json_depth(obj, current_depth=0) -> int:
    """Compute maximum nesting depth of a JSON-compatible object."""
    if current_depth > MAX_JSON_DEPTH + 5:
        return current_depth
    if isinstance(obj, dict):
        if not obj:
            return current_depth + 1
        return max(_json_depth(v, current_depth + 1) for v in obj.values())
    if isinstance(obj, list):
        if not obj:
            return current_depth + 1
        return max(_json_depth(item, current_depth + 1) for item in obj)
    return current_depth


def sanitize_label(label: str) -> str:
    """Strip dangerous content from a label string."""
    if not label:
        return ''
    # Strip HTML tags
    label = re.sub(r'<[^>]*>', '', label)
    # Remove script patterns
    label = DANGEROUS_PATTERNS.sub('', label)
    # Truncate
    if len(label) > MAX_LABEL_LENGTH:
        label = label[:MAX_LABEL_LENGTH]
    return label.strip()
