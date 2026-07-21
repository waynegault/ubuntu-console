"""Query, path, and explain tools for graph navigation.

Provides CLI-friendly functions for:
- query: find nodes by label/type/pattern
- path: find shortest paths between two nodes
- explain: describe a node's connections and role

All functions accept ``Graph`` models or legacy dicts.
"""

from __future__ import annotations

import re
from collections import deque

from .models import Graph, GraphEdge, GraphNode


def query_nodes(graph: Graph | dict, pattern: str, **kwargs) -> list[dict]:
    """Find nodes matching a query pattern (label, type, or regex).

    Args:
        graph: Graph model or dict.
        pattern: Text to match against labels and types.
        match_type: 'label', 'type', or 'any' (default 'any').

    Returns:
        List of matching node dicts.
    """
    if isinstance(graph, dict):
        graph = Graph.from_dict(graph)

    match_type = kwargs.get("match_type", "any")
    max_results = kwargs.get("max_results", 50)

    pattern_lower = pattern.strip().lower()
    results: list[dict] = []

    for n in graph.nodes:
        label = n.label.lower()
        ntype = n.type.lower()

        if match_type in ("label", "any"):
            if pattern_lower in label or re.search(pattern, label, re.IGNORECASE):
                results.append(n.model_dump(mode="json", exclude_none=True))
                continue
        if match_type in ("type", "any"):
            if pattern_lower in ntype or re.search(pattern, ntype, re.IGNORECASE):
                if not results or results[-1].get("id") != n.id:
                    results.append(n.model_dump(mode="json", exclude_none=True))
                    continue

    # Deduplicate
    seen: set[str] = set()
    deduped: list[dict] = []
    for n in results:
        nid = str(n.get("id", ""))
        if nid and nid not in seen:
            seen.add(nid)
            deduped.append(n)

    return deduped[:max_results]


def find_path(graph: Graph | dict, source: str, target: str, **kwargs) -> list[dict]:
    """Find the shortest path between two nodes by id or label.

    Args:
        graph: Graph model or dict.
        source: Starting node id or label substring.
        target: Ending node id or label substring.

    Returns:
        List of edge dicts forming the path, or empty list.
    """
    if isinstance(graph, dict):
        graph = Graph.from_dict(graph)

    max_depth = kwargs.get("max_depth", 10)

    # Resolve node ids from labels if needed
    node_by_id: dict[str, GraphNode] = {}
    id_by_label: dict[str, str] = {}
    for n in graph.nodes:
        node_by_id[n.id] = n
        if n.label:
            id_by_label.setdefault(n.label.lower(), n.id)

    src_id = source
    tgt_id = target
    if source not in node_by_id:
        for label, nid in id_by_label.items():
            if source.lower() in label:
                src_id = nid
                break
    if target not in node_by_id:
        for label, nid in id_by_label.items():
            if target.lower() in label:
                tgt_id = nid
                break

    if src_id not in node_by_id or tgt_id not in node_by_id:
        return []

    # BFS
    adj: dict[str, list[tuple[str, str, GraphEdge]]] = {}
    for e in graph.edges:
        adj.setdefault(e.source, []).append((e.target, e.label, e))
        adj.setdefault(e.target, []).append((e.source, e.label, e))

    visited = {src_id}
    queue: deque[tuple[str, list[dict]]] = deque([(src_id, [])])
    while queue:
        current, path_edges = queue.popleft()
        if current == tgt_id:
            return path_edges
        if len(path_edges) >= max_depth:
            continue
        for neighbor, _lbl, edge in adj.get(current, []):
            if neighbor not in visited:
                visited.add(neighbor)
                queue.append((neighbor, path_edges + [edge.model_dump(mode="json", exclude_none=True)]))

    return []


def explain_node(graph: Graph | dict, node_id: str) -> dict:
    """Describe a node's connections, type, and role in the graph.

    Args:
        graph: Graph model or dict.
        node_id: Node id or label substring.

    Returns:
        Dict with node info, connections, and centrality context.
    """
    if isinstance(graph, dict):
        graph = Graph.from_dict(graph)

    # Find node
    target_node: GraphNode | None = graph.node_by_id(node_id)
    if not target_node:
        for n in graph.nodes:
            if node_id.lower() in n.label.lower():
                target_node = n
                break

    if not target_node:
        return {"error": f'Node "{node_id}" not found'}

    nid = target_node.id
    outbound: list[dict] = []
    inbound: list[dict] = []

    for e in graph.edges:
        conf = e.confidence.value if e.confidence else "INFERRED"
        if e.source == nid:
            outbound.append({
                "target": e.target,
                "label": e.label,
                "confidence": conf,
                "semantic_score": e.semantic_score,
            })
        elif e.target == nid:
            inbound.append({
                "source": e.source,
                "label": e.label,
                "confidence": conf,
                "semantic_score": e.semantic_score,
            })

    # Build label lookup
    label_map = {n.id: n.label for n in graph.nodes}

    for item in outbound:
        item["target_label"] = label_map.get(item["target"], item["target"])
    for item in inbound:
        item["source_label"] = label_map.get(item["source"], item["source"])

    return {
        "node": {
            "id": nid,
            "label": target_node.label,
            "type": target_node.type,
            "content_preview": target_node.content_preview,
        },
        "outbound_connections": outbound,
        "inbound_connections": inbound,
        "total_connections": len(outbound) + len(inbound),
        "outbound_count": len(outbound),
        "inbound_count": len(inbound),
    }


def format_explain(explanation: dict) -> str:
    """Format an explain_node result as human-readable text."""
    if "error" in explanation:
        return f'Error: {explanation["error"]}'

    node = explanation["node"]
    lines = [
        f'Node: {node["label"]} ({node["id"]})',
        f'Type: {node["type"]}',
        f'Connections: {explanation["total_connections"]} '
        f'({explanation["outbound_count"]} out, {explanation["inbound_count"]} in)',
    ]

    if node.get("content_preview"):
        lines.append(f'Preview: {node["content_preview"]}')

    if explanation["outbound_connections"]:
        lines.append("")
        lines.append("Outbound:")
        for c in explanation["outbound_connections"]:
            score = f' [{c.get("semantic_score")}]' if c.get("semantic_score") else ""
            conf = f' ({c["confidence"]})' if c.get("confidence") else ""
            lines.append(f'  → {c["target_label"]} ({c["label"]}){score}{conf}')

    if explanation["inbound_connections"]:
        lines.append("")
        lines.append("Inbound:")
        for c in explanation["inbound_connections"]:
            score = f' [{c.get("semantic_score")}]' if c.get("semantic_score") else ""
            conf = f' ({c["confidence"]})' if c.get("confidence") else ""
            lines.append(f'  ← {c["source_label"]} ({c["label"]}){score}{conf}')

    return "\n".join(lines)


def format_path(path_edges: list[dict]) -> str:
    """Format a find_path result as human-readable text."""
    if not path_edges:
        return "No path found"

    lines = ["Path:"]
    for e in path_edges:
        src = str(e.get("source", e.get("from", "")))
        dst = str(e.get("target", e.get("to", "")))
        lbl = str(e.get("label", ""))
        conf = e.get("confidence", "")
        score = e.get("semantic_score", "")
        details = f" ({conf})" if conf else ""
        details += f" [{score}]" if score else ""
        lines.append(f"  {src} → {dst}: {lbl}{details}")

    return "\n".join(lines)