"""Graph JSON validation using Pydantic models + security checks.

Schema validation is handled by ``Graph.from_dict()`` (Pydantic).
This module adds security validation (payload size, nesting depth,
XSS pattern detection) on top of the Pydantic schema.

CLI:
    python -m kgraph.validate <graph.json>
"""

from __future__ import annotations

import json
import os
import re
from typing import Any
import sys

from pydantic import ValidationError

from .constants import (
    EDGE_LABEL_PREFIXES,
    EDGE_LABELS,
    NODE_TYPES,
    VOCABULARY_VERSION,
)
from .models import Graph

# ── Security limits ─────────────────────────────────────────────────────

MAX_NODES = 500_000
MAX_EDGES = 1_000_000
MAX_JSON_DEPTH = 20
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


def _scan_dangerous(value: object) -> bool:
    """True when any string anywhere inside *value* matches a dangerous pattern."""
    if isinstance(value, str):
        return bool(DANGEROUS_PATTERNS.search(value))
    if isinstance(value, dict):
        return any(_scan_dangerous(v) for v in value.values())
    if isinstance(value, (list, tuple)):
        return any(_scan_dangerous(v) for v in value)
    return False


def _check_xss(data: dict) -> list[dict]:
    """Scan node/edge string values, including nested ones, for dangerous patterns."""
    errors: list[dict] = []
    for kind, items in (("nodes", data.get("nodes", [])),
                        ("edges", data.get("edges", []))):
        if not isinstance(items, list):
            # A non-list nodes/edges value is already reported by
            # validate_graph; skip the scan instead of raising TypeError
            # (which would escape callers and drop the HTTP response).
            continue
        for idx, item in enumerate(items):
            if not isinstance(item, dict):
                continue
            for key, value in item.items():
                # Recurse into nested containers (payload, typed_summary,
                # summary_labels, …) — scanning only top-level strings let a
                # dangerous value one level down pass validation.
                if _scan_dangerous(value):
                    errors.append({
                        "severity": "error",
                        "message": f"{kind}[{idx}]: field '{key}' contains dangerous patterns",
                        f"{kind[:-1]}_idx": idx,
                        "field": key,
                    })
    return errors


# ── Vocabulary ──────────────────────────────────────────────────────────


def _check_vocabulary(graph: dict) -> list[dict]:
    """Report node types and edge labels outside the declared vocabulary.

    REF: "GraphRAG: A Practitioner's Guide to 6 Advanced Architectural Patterns"
         (Partha Sarkar, TDS, 2026-09-20) — https://towardsdatascience.com/graphrag-a-practitioners-guide-to-6-advanced-architectural-patterns/

    Challenge 2 of the article: "a minimal, rigid ontology ... version control
    and strict governance ... the LLM should be restricted from inventing new
    node labels on the fly".  Before this check the graph could carry a label no
    module understood, and the only symptom was that the element silently
    dropped out of whichever view applied the matching rule — the same way the
    concept-alias sets drifted here undetected.

    Reported at WARNING, not error, on purpose: an unrecognised label does not
    make a payload unsafe, and failing here would reject an otherwise valid
    graph instead of making the drift visible.  validate_graph_payload() still
    rejects only severity == "error", so the MCP pre-flight contract is
    unchanged.
    """
    findings: list[dict] = []
    checks = (
        ("nodes", "type", NODE_TYPES, ()),
        ("edges", "label", EDGE_LABELS, EDGE_LABEL_PREFIXES),
    )
    for collection, field, declared, prefixes in checks:
        items = graph.get(collection, [])
        if not isinstance(items, list):
            continue
        counts: dict[str, int] = {}
        for item in items:
            if not isinstance(item, dict):
                continue
            value = item.get(field)
            if not isinstance(value, str) or not value:
                continue
            if value in declared or (prefixes and value.startswith(prefixes)):
                continue
            counts[value] = counts.get(value, 0) + 1
        for value, count in sorted(counts.items()):
            findings.append({
                "severity": "warning",
                "message": (
                    f"{collection}[{field}] '{value}' ({count}x) is not in the "
                    f"declared vocabulary v{VOCABULARY_VERSION} — no projection "
                    f"or confidence rule will match it"
                ),
            })
    return findings


# ── Validation ──────────────────────────────────────────────────────────


def _check_community_digest(graph: dict) -> list[dict]:
    """Report a cached community digest that names nodes the graph does not have.

    REF: "GraphRAG: A Practitioner's Guide to 6 Advanced Architectural Patterns"
         (Partha Sarkar, TDS, 2026-09-20) — the article's community reports are a
         CACHE of derived structure, and a cache that has drifted from the graph it
         describes is worse than no cache: an agent asking "what are the main
         themes" would be told about members that no longer exist.  The update path
         writes the digest from the same graph it saves, so drift here means a
         hand-edited, merged or partially-exported graph.

    Reported at WARNING for the same reason the vocabulary check is: a stale digest
    does not make a payload unsafe, and rejecting the graph would be the wrong
    remedy.  One finding per community, bounded, so a wholesale rebuild does not
    produce a finding per member.
    """
    meta = graph.get("meta", {})
    if not isinstance(meta, dict):
        return []
    communities = meta.get("communities")
    if not isinstance(communities, list):
        return []

    node_ids = {
        str(item.get("id")) for item in graph.get("nodes", [])
        if isinstance(item, dict) and item.get("id") is not None
    }

    findings: list[dict] = []
    for idx, community in enumerate(communities):
        if not isinstance(community, dict):
            continue
        members = community.get("members")
        if not isinstance(members, list):
            continue
        missing = [str(m) for m in members if str(m) not in node_ids]
        if not missing:
            continue
        shown = ", ".join(sorted(missing)[:3])
        more = f" (+{len(missing) - 3} more)" if len(missing) > 3 else ""
        findings.append({
            "severity": "warning",
            "message": (
                f"meta.communities[{idx}] '{community.get('id', '?')}' lists "
                f"{len(missing)} member(s) absent from the graph: {shown}{more} — "
                f"the cached digest is stale; rebuild (kgraph --update) to redigest"
            ),
        })
    return findings


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

    # Vocabulary membership — the declared set lives in constants.py
    errors.extend(_check_vocabulary(graph))

    # Community digest freshness — a cached digest is derived structure
    errors.extend(_check_community_digest(graph))

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


def validate_graph_payload(payload: Any) -> tuple[bool, str]:
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
