"""Graph projection engine.

Projects a raw graph into cleaner views (overview, topics, files,
semantic, raw).  All helper functions are module-level for testability.

Accepts ``Graph`` models or legacy dicts.  Returns a plain dict for
compatibility with the HTML template and JSON serialization layers.
"""

from __future__ import annotations

import re

from .life_index import load_life_index
from .models import Graph

# ── Label / type constants ─────────────────────────────────────────────

CURATED_EDGE_LABELS = frozenset({
    "covers topic", "mentions actor", "authored by", "references file",
    "file mentions actor", "file authored by", "has project", "has decision",
    "has issue", "has outcome",
})

AST_EDGE_LABELS = frozenset({"defines", "calls", "imports", "resolves_to"})
AST_NODE_TYPES = frozenset({"function", "class", "call", "module", "variable"})

WEAK_NODE_LABELS = frozenset({
    "created", "updated", "watched", "watch", "identified", "audited",
    "added", "removed", "fixed", "changed", "summary", "overview",
    "context", "details", "notes", "status", "result", "results",
    "outcome", "outcomes", "current state", "important technical state",
    "key decisions", "next steps", "next actions", "open threads",
    "work", "project", "issue", "decision", "topic", "memory stack",
    "graph quality",
})

SEMANTIC_CORE_TYPES = frozenset({
    "actor", "topic", "summary", "project", "decision", "issue",
    "outcome", "person", "organization", "place",
})

CANONICAL_RELATION_LABELS = frozenset({
    "project decision", "project issue", "project outcome", "project topic",
    "project owner", "decision addresses issue", "decision drives outcome",
    "issue affects outcome", "topic decision", "topic issue", "topic outcome",
    "actor decision", "actor issue", "actor outcome",
})

WEAK_CLUSTER_LABELS = frozenset({
    "graph quality", "repo cleanup", "env bridge", "semantic filtering",
    "copilot token",
})

PREFERRED_CLUSTER_TYPES = (
    "project", "issue", "decision", "outcome", "topic", "actor",
    "person", "organization", "place",
)

# ── Thresholds ─────────────────────────────────────────────────────────

SEMANTIC_THRESHOLD_MIN = 0.58
SEMANTIC_THRESHOLD_MAX = 0.90
SEMANTIC_EDGE_BASE_THRESHOLD = 0.68
SEMANTIC_EDGE_HIGH_DEGREE_THRESHOLD = 0.78
SEMANTIC_EDGE_MED_DEGREE_THRESHOLD = 0.73
SEMANTIC_EDGE_OVERRIDE_THRESHOLD = 0.88
SEMANTIC_FALLBACK_MIN_SCORE = 0.36
SEMANTIC_INFERRED_NEIGHBOR_BUDGET_HIGH = 4
SEMANTIC_INFERRED_NEIGHBOR_BUDGET_LOW = 3
SEMANTIC_INFERRED_NEIGHBOR_STRENGTH_CUTOFF = 5.5


# ── Node / edge helpers ────────────────────────────────────────────────


def _node_visibility(node: dict) -> str:
    return str(node.get("visibility", node.get("view_visibility", "both")) or "both").lower()


def _node_quality(node: dict) -> str:
    return str(node.get("quality_tier", node.get("quality", "semantic")) or "semantic").lower()


def _edge_visibility(edge: dict) -> str:
    return str(edge.get("visibility", edge.get("view_visibility", "both")) or "both").lower()


def _edge_quality(edge: dict) -> str:
    return str(edge.get("quality_tier", edge.get("quality", "semantic")) or "semantic").lower()


def _is_weak_label(label: str) -> bool:
    return str(label or "").strip().lower() in WEAK_NODE_LABELS


def _is_curated_node(node: dict) -> bool:
    ntype = str(node.get("type", "") or "").lower()
    label = str(node.get("label", "") or "").strip().lower()
    if _node_visibility(node) == "raw" or _node_quality(node) == "supporting":
        return False
    if ntype == "file" and re.search(r"(?:^|/)(?:fact-|preference-|decision-|reflection-)", str(node.get("path", "") or "").lower()):
        return False
    if ntype in SEMANTIC_CORE_TYPES or ntype == "file":
        return True
    return bool(label and not _is_weak_label(label))


def _effective_semantic_threshold(semantic_threshold: float) -> float:
    return max(SEMANTIC_THRESHOLD_MIN, min(SEMANTIC_THRESHOLD_MAX, SEMANTIC_THRESHOLD_MIN + ((semantic_threshold - 0.5) * 0.6)))


def _is_curated_edge(edge: dict, effective_threshold: float) -> bool:
    label = str(edge.get("label", "") or "")
    if _edge_visibility(edge) == "raw" or _edge_quality(edge) == "supporting":
        return False
    if label in CURATED_EDGE_LABELS or label == "semantic summary" or label.startswith("summarizes "):
        return True
    if label.startswith("related") and edge.get("semantic_score") is not None:
        try:
            return float(edge.get("semantic_score")) >= effective_threshold
        except (TypeError, ValueError):
            return False
    return False


def _edge_endpoints(edge: dict) -> tuple[str | None, str | None]:
    src = edge.get("from", edge.get("source"))
    dst = edge.get("to", edge.get("target"))
    return (str(src) if src is not None else None, str(dst) if dst is not None else None)


def _dedupe_append(out_edges: list, seen: set, source: str | None, target: str | None, label: str, payload: dict | None = None) -> None:
    if not source or not target:
        return
    key = (source, target, label)
    if key in seen:
        return
    seen.add(key)
    item = {"from": source, "to": target, "label": label}
    if payload:
        item.update(payload)
    out_edges.append(item)


# ── Enrichment ─────────────────────────────────────────────────────────


def _enrich_graph_payload(projected: dict, current_mode: str) -> dict:
    """Add degree, importance, display labels, and cluster suggestions."""
    out: dict = {
        "nodes": [dict(n) for n in (projected.get("nodes", []) or [])],
        "edges": [dict(e) for e in (projected.get("edges", []) or [])],
    }

    life_index = load_life_index()

    # ── Semantic dedup ──
    if current_mode in {"overview", "topics", "semantic"}:
        _collapse_semantic_duplicates(out, {"topic", "project", "decision", "issue", "outcome", "organization", "place", "person"}, life_index)

    # ── Semantic edge filtering (topics/semantic modes) ──
    if current_mode in {"topics", "semantic"}:
        _filter_semantic_edges(out, current_mode, life_index)

    # ── Degree / importance ──
    adjacency: dict[str, int] = {}
    semantic_degree: dict[str, int] = {}
    type_counts: dict[str, int] = {}

    for edge in out["edges"]:
        src, dst = _edge_endpoints(edge)
        if src:
            adjacency[src] = adjacency.get(src, 0) + 1
        if dst:
            adjacency[dst] = adjacency.get(dst, 0) + 1
        if edge.get("semantic_score") is not None:
            if src:
                semantic_degree[src] = semantic_degree.get(src, 0) + 1
            if dst:
                semantic_degree[dst] = semantic_degree.get(dst, 0) + 1

    for node in out["nodes"]:
        ntype = str(node.get("type", "unknown") or "unknown").lower()
        type_counts[ntype] = type_counts.get(ntype, 0) + 1

    importance_by_id: dict[str, int] = {}
    for node in out["nodes"]:
        nid = str(node.get("id", ""))
        degree = adjacency.get(nid, 0)
        sdegree = semantic_degree.get(nid, 0)
        importance_by_id[nid] = max(1, degree + (2 * sdegree))

    top_label_nodes: set[str] = set()
    if current_mode in {"topics", "semantic"}:
        ranked_ids = sorted(importance_by_id.keys(), key=lambda nid: importance_by_id.get(nid, 0), reverse=True)
        limit = 18 if current_mode == "semantic" else 24
        top_label_nodes = set(ranked_ids[:limit])

    for node in out["nodes"]:
        nid = str(node.get("id", ""))
        ntype = str(node.get("type", "") or "").lower()
        node["degree"] = adjacency.get(nid, 0)
        node["semantic_degree"] = semantic_degree.get(nid, 0)
        node["importance"] = importance_by_id.get(nid, 1)
        node["display_group"] = ntype or "unknown"
        _set_display_label(node, nid, ntype, current_mode, top_label_nodes)

    # ── Cluster suggestions (semantic mode) ──
    cluster_suggestions: list[dict] = []
    if current_mode == "semantic":
        cluster_suggestions = _build_cluster_suggestions(out)

    out["_meta"] = dict(out.get("_meta", {}))
    out["_meta"]["typeCounts"] = type_counts
    out["_meta"]["nodeCount"] = len(out["nodes"])
    out["_meta"]["edgeCount"] = len(out["edges"])
    if cluster_suggestions:
        out["_meta"]["clusterSuggestions"] = cluster_suggestions
    return out


def _set_display_label(node: dict, nid: str, ntype: str, mode: str, top_label_nodes: set[str]) -> None:
    """Set the display_label and visual_role for a node based on mode."""
    raw_label = str(node.get("label") or nid)

    if mode == "overview":
        if ntype == "file":
            node["display_label"] = ""
            node["visual_role"] = "provenance"
        elif ntype in {"actor", "topic", "summary", "project", "decision", "issue", "outcome"}:
            node["display_label"] = raw_label[:56]
        else:
            node["display_label"] = raw_label
    elif mode == "semantic":
        if ntype == "file" or re.match(r"^\d{4}-\d{2}-\d{2}\.md$", raw_label) or raw_label.lower() in {"memory.md", "profile.md"}:
            node["display_label"] = ""
            node["visual_role"] = "provenance"
        elif nid not in top_label_nodes and node.get("importance", 0) < 6:
            node["display_label"] = ""
        elif ntype == "summary":
            node["display_label"] = raw_label[:40]
        elif ntype == "topic":
            node["display_label"] = raw_label[:22]
        elif ntype in {"project", "decision", "issue", "outcome"}:
            node["display_label"] = raw_label[:34]
        else:
            node["display_label"] = raw_label[:26]
    elif mode == "topics":
        if nid not in top_label_nodes and node.get("importance", 0) < 5:
            node["display_label"] = ""
        elif ntype == "topic":
            node["display_label"] = raw_label[:24]
        elif ntype in {"project", "decision", "issue", "outcome"}:
            node["display_label"] = raw_label[:32]
        else:
            node["display_label"] = raw_label[:24]


def _normalized_semantic_label(node: dict, life_index: dict) -> str:
    label = str(node.get("label", "") or "").strip().lower()
    if not label:
        return ""
    label = re.sub(r"\b(?:the|a|an)\b", " ", label)
    label = re.sub(r"\b(?:current|important|main|primary|semantic|visual|layout)\b", " ", label)
    label = re.sub(r"[^a-z0-9\s-]", " ", label)
    label = re.sub(r"\s+", " ", label).strip(" .:-")
    semantic_aliases = {
        "graph layout": "graph quality", "layout quality": "graph quality",
        "semantic graph": "graph quality", "semantic threshold": "semantic filtering",
        "semantic thresholding": "semantic filtering", "topic cleanup": "topic structure",
        "topics projection": "topic structure", "topics mode": "topic structure",
        "label cleanup": "semantic naming", "naming cleanup": "semantic naming",
    }
    for alias, canonical in semantic_aliases.items():
        if label == alias or alias in label:
            label = canonical
            break
    record = life_index.get("aliases", {}).get(label)
    if record:
        return str(record.get("title", label)).strip().lower()
    canonical_title = life_index.get("title_aliases", {}).get(label)
    if canonical_title:
        return str(canonical_title).strip().lower()
    return label


def _collapse_semantic_duplicates(graph_out: dict, allowed_types: set[str], life_index: dict) -> None:
    nodes_local = graph_out.get("nodes", []) or []
    edges_local = graph_out.get("edges", []) or []
    canonical_for: dict[str, str] = {}
    label_groups: dict[tuple[str, str], list[dict]] = {}

    for node in nodes_local:
        nid = str(node.get("id", "") or "")
        ntype = str(node.get("type", "") or "").lower()
        if not nid or ntype not in allowed_types:
            continue
        norm = _normalized_semantic_label(node, life_index)
        if not norm or len(norm) < 4:
            continue
        label_groups.setdefault((ntype, norm), []).append(node)

    for members in label_groups.values():
        if len(members) < 2:
            continue
        members_sorted = sorted(members, key=lambda n: (
            int(bool(n.get("inferred_type"))),
            -float(n.get("type_confidence", 1.0) or 1.0),
            -len(str(n.get("label", "") or "")),
            str(n.get("id", "") or ""),
        ))
        canonical = str(members_sorted[0].get("id"))
        for node in members_sorted:
            canonical_for[str(node.get("id"))] = canonical

    if not canonical_for:
        return

    deduped_nodes = []
    seen_nodes: set[str] = set()
    for node in nodes_local:
        nid = str(node.get("id", "") or "")
        cid = canonical_for.get(nid, nid)
        if cid != nid or cid in seen_nodes:
            continue
        seen_nodes.add(cid)
        deduped_nodes.append(node)

    deduped_edges = []
    seen_edges: set[tuple[str, str, str]] = set()
    for edge in edges_local:
        src, dst = _edge_endpoints(edge)
        src = canonical_for.get(src or "", src or "")
        dst = canonical_for.get(dst or "", dst or "")
        if not src or not dst or src == dst:
            continue
        label = str(edge.get("label", "") or "")
        key = (src, dst, label)
        if key in seen_edges:
            continue
        seen_edges.add(key)
        new_edge = dict(edge)
        new_edge["from"] = src
        new_edge["to"] = dst
        deduped_edges.append(new_edge)

    graph_out["nodes"] = deduped_nodes
    graph_out["edges"] = deduped_edges


def _edge_strength_value(edge: dict) -> float:
    try:
        semantic_score = float(edge.get("semantic_score", 0) or 0)
    except (TypeError, ValueError):
        semantic_score = 0.0
    try:
        cooccurrence = int(edge.get("cooccurrence_count", 0) or 0)
    except (TypeError, ValueError):
        cooccurrence = 0
    label = str(edge.get("label", "") or "").strip().lower()
    base = semantic_score
    if label in {"project decision", "project issue", "decision addresses issue", "decision drives outcome"}:
        base = max(base, 0.95)
    elif label in {"project outcome", "issue affects outcome", "project owner"}:
        base = max(base, 0.88)
    elif label in {"project topic", "topic decision", "topic issue", "topic outcome", "actor decision", "actor issue", "actor outcome"}:
        base = max(base, 0.76)
    base += min(0.08, 0.02 * cooccurrence)
    return round(min(base, 0.99), 3)


def _filter_semantic_edges(out: dict, current_mode: str, life_index: dict) -> None:
    """Filter and score semantic edges for topics/semantic modes."""
    canonical_anchor_types = {"project", "decision", "issue", "outcome", "workflow", "system", "repo"}
    canonical_anchor_labels = {
        _normalized_semantic_label(n, life_index)
        for n in out["nodes"]
        if str(n.get("type", "") or "").lower() in canonical_anchor_types
    }
    node_lookup = {str(n.get("id")): n for n in out["nodes"] if n.get("id") is not None}
    semantic_edges = []
    supporting_edges = []

    for edge in out["edges"]:
        src, dst = _edge_endpoints(edge)
        if not src or not dst or src not in node_lookup or dst not in node_lookup:
            continue
        if edge.get("semantic_score") is not None or str(edge.get("label", "") or "").lower() in CANONICAL_RELATION_LABELS:
            semantic_edges.append(dict(edge))
        else:
            supporting_edges.append(dict(edge))

    degree: dict[str, int] = {}
    scored_edges = []
    for edge in semantic_edges:
        src, dst = _edge_endpoints(edge)
        strength = _edge_strength_value(edge)
        src_node = node_lookup.get(src, {})
        dst_node = node_lookup.get(dst, {})
        src_label = _normalized_semantic_label(src_node, life_index)
        dst_label = _normalized_semantic_label(dst_node, life_index)
        src_type = str(src_node.get("type", "") or "").lower()
        dst_type = str(dst_node.get("type", "") or "").lower()
        label = str(edge.get("label", "") or "").lower()

        if label == "semantic related":
            if src_label in {"workspace", "openclaw", "gateway", "engram", "wayne", "hal"} or dst_label in {"workspace", "openclaw", "gateway", "engram", "wayne", "hal"}:
                strength = min(strength, 0.52)
            if canonical_anchor_labels and src_type not in canonical_anchor_types and dst_type not in canonical_anchor_types:
                strength = min(strength, 0.62)
        if src_label in canonical_anchor_labels or dst_label in canonical_anchor_labels:
            strength = min(0.99, strength + 0.06)

        edge["_strength"] = strength
        degree[src] = degree.get(src, 0) + 1
        degree[dst] = degree.get(dst, 0) + 1
        scored_edges.append(edge)

    # Budget-based edge selection
    neighbor_budget: dict[str, int] = {}
    for nid, deg in degree.items():
        if current_mode == "semantic":
            neighbor_budget[nid] = 4 if deg >= 10 else (5 if deg >= 7 else 6)
        else:
            neighbor_budget[nid] = 5 if deg >= 10 else (6 if deg >= 7 else 7)

    kept_semantic = []
    kept_counts: dict[str, int] = {}
    seen_pairs: set[tuple[str, str]] = set()
    scored_edges_sorted = sorted(scored_edges, key=lambda e: (e.get("_strength", 0), e.get("cooccurrence_count", 0), str(e.get("label", ""))), reverse=True)

    for edge in scored_edges_sorted:
        src, dst = _edge_endpoints(edge)
        if not src or not dst:
            continue
        pair = tuple(sorted((src, dst)))
        if pair in seen_pairs:
            continue
        src_deg = degree.get(src, 0)
        dst_deg = degree.get(dst, 0)
        strength = float(edge.get("_strength", 0) or 0)
        threshold = SEMANTIC_EDGE_BASE_THRESHOLD
        if max(src_deg, dst_deg) >= 10:
            threshold = SEMANTIC_EDGE_HIGH_DEGREE_THRESHOLD if current_mode == "semantic" else 0.75
        elif max(src_deg, dst_deg) >= 7:
            threshold = SEMANTIC_EDGE_MED_DEGREE_THRESHOLD if current_mode == "semantic" else 0.71
        if strength < threshold:
            continue
        if kept_counts.get(src, 0) >= neighbor_budget.get(src, 6) or kept_counts.get(dst, 0) >= neighbor_budget.get(dst, 6):
            if strength < SEMANTIC_EDGE_OVERRIDE_THRESHOLD:
                continue
        seen_pairs.add(pair)
        kept_counts[src] = kept_counts.get(src, 0) + 1
        kept_counts[dst] = kept_counts.get(dst, 0) + 1
        kept_semantic.append(edge)

    # Fallback for sparse results
    if current_mode == "semantic" and len(kept_semantic) < 3 and scored_edges_sorted:
        fallback_edges = []
        fallback_counts: dict[str, int] = {}
        fallback_pairs: set[tuple[str, str]] = set()
        for edge in scored_edges_sorted[:24]:
            src, dst = _edge_endpoints(edge)
            if not src or not dst:
                continue
            pair = tuple(sorted((src, dst)))
            if pair in fallback_pairs:
                continue
            if fallback_counts.get(src, 0) >= 3 or fallback_counts.get(dst, 0) >= 3:
                continue
            fallback_pairs.add(pair)
            fallback_counts[src] = fallback_counts.get(src, 0) + 1
            fallback_counts[dst] = fallback_counts.get(dst, 0) + 1
            fallback_edges.append(edge)
            if len(fallback_edges) >= 10:
                break
        if fallback_edges:
            kept_semantic = fallback_edges

    # Filter nodes to connected set
    connected_ids: set[str] = set()
    for edge in kept_semantic:
        src, dst = _edge_endpoints(edge)
        if src:
            connected_ids.add(src)
        if dst:
            connected_ids.add(dst)
    for nid, node in node_lookup.items():
        ntype = str(node.get("type", "") or "").lower()
        if ntype in canonical_anchor_types and _normalized_semantic_label(node, life_index) in canonical_anchor_labels:
            connected_ids.add(nid)

    filtered_nodes = []
    for node in out["nodes"]:
        nid = str(node.get("id", "") or "")
        ntype = str(node.get("type", "") or "").lower()
        if nid in connected_ids or ntype in {"actor"}:
            filtered_nodes.append(node)
        elif ntype in {"topic", "project", "decision", "issue", "outcome"} and degree.get(nid, 0) > 0:
            filtered_nodes.append(node)

    node_id_set = {str(n.get("id")) for n in filtered_nodes}
    out["nodes"] = filtered_nodes
    out["edges"] = [
        {k: v for k, v in edge.items() if k != "_strength"}
        for edge in (kept_semantic + supporting_edges)
        if _edge_endpoints(edge)[0] in node_id_set and _edge_endpoints(edge)[1] in node_id_set
    ]


def _build_cluster_suggestions(out: dict) -> list[dict]:
    """Build semantic cluster suggestions from connected components."""
    semantic_adj: dict[str, set[str]] = {}
    semantic_nodes = {str(n.get("id")): n for n in out["nodes"] if n.get("id") is not None}

    strong_relation_labels = {
        "project decision", "project issue", "decision addresses issue", "decision drives outcome",
        "project outcome", "issue affects outcome", "project owner",
    }
    medium_relation_labels = {
        "project topic", "topic decision", "topic issue", "topic outcome",
        "actor decision", "actor issue", "actor outcome",
    }

    for edge in out["edges"]:
        src, dst = _edge_endpoints(edge)
        if not src or not dst or src not in semantic_nodes or dst not in semantic_nodes:
            continue
        label = str(edge.get("label", "") or "").strip().lower()
        try:
            semantic_score = float(edge.get("semantic_score", 0) or 0)
        except (TypeError, ValueError):
            semantic_score = 0.0
        try:
            cooccurrence = int(edge.get("cooccurrence_count", 0) or 0)
        except (TypeError, ValueError):
            cooccurrence = 0
        edge_strength = semantic_score
        if label in strong_relation_labels:
            edge_strength = max(edge_strength, 0.92)
        elif label in medium_relation_labels:
            edge_strength = max(edge_strength, 0.78)
        elif cooccurrence >= 3:
            edge_strength = max(edge_strength, 0.72)
        elif cooccurrence >= 2:
            edge_strength = max(edge_strength, 0.66)
        if edge_strength < 0.74:
            continue
        semantic_adj.setdefault(src, set()).add(dst)
        semantic_adj.setdefault(dst, set()).add(src)

    visited: set[str] = set()
    cluster_suggestions: list[dict] = []

    for nid in semantic_nodes:
        if nid in visited or nid not in semantic_adj:
            continue
        stack = [nid]
        component: list[str] = []
        visited.add(nid)
        while stack:
            cur = stack.pop()
            component.append(cur)
            for nxt in semantic_adj.get(cur, set()):
                if nxt not in visited:
                    visited.add(nxt)
                    stack.append(nxt)
        if len(component) < 3:
            continue

        ranked = sorted(component, key=lambda cid: (
            semantic_nodes[cid].get("semantic_degree", 0),
            semantic_nodes[cid].get("importance", 0),
            semantic_nodes[cid].get("degree", 0),
            len(str(semantic_nodes[cid].get("label", "") or "")),
        ), reverse=True)

        label_parts: list[str] = []
        chosen_types: set[str] = set()
        for preferred_type in PREFERRED_CLUSTER_TYPES:
            for cid in ranked:
                node = semantic_nodes[cid]
                label = str(node.get("label", "") or "").strip()
                if not label or label.lower() in WEAK_CLUSTER_LABELS:
                    continue
                node_type = str(node.get("type", "") or "").lower()
                if node_type != preferred_type or node_type in chosen_types:
                    continue
                if label.lower() in [x.lower() for x in label_parts]:
                    continue
                label_parts.append(label)
                chosen_types.add(node_type)
                break
            if len(label_parts) >= 2:
                break

        if not label_parts:
            for cid in ranked:
                label = str(semantic_nodes[cid].get("label", "") or "").strip()
                if label and label.lower() not in WEAK_CLUSTER_LABELS and label.lower() not in [x.lower() for x in label_parts]:
                    label_parts.append(label)
                if len(label_parts) >= 2:
                    break

        if len(label_parts) >= 2:
            cluster_label = f"{label_parts[0]} · {label_parts[1]}"
        elif label_parts:
            dominant_type = str(semantic_nodes[ranked[0]].get("type", "") or "").lower() if ranked else ""
            type_hint = dominant_type if dominant_type and dominant_type not in {"topic", "actor"} else "cluster"
            cluster_label = f"{label_parts[0]} ({type_hint})"
        else:
            cluster_label = f"cluster {len(cluster_suggestions) + 1}"

        cluster_suggestions.append({
            "id": f"semantic_cluster_{len(cluster_suggestions) + 1}",
            "label": cluster_label[:64],
            "members": component,
            "size": len(component),
        })

    return cluster_suggestions


# ── Main projection ────────────────────────────────────────────────────


def project_graph(graph: Graph | dict, mode: str = "overview", semantic_threshold: float = 0.82) -> dict:
    """Project a raw graph into a cleaner view for browsing.

    Modes: overview, files, topics, semantic, raw.
    Returns a plain dict for JSON serialization.
    """
    if isinstance(graph, Graph):
        graph = graph.to_dict()

    mode = (mode or "overview").lower()
    if mode == "raw":
        return graph

    nodes = graph.get("nodes", []) or []
    edges = graph.get("edges", []) or []
    node_by_id = {str(n.get("id")): dict(n) for n in nodes if n.get("id") is not None}
    effective_threshold = _effective_semantic_threshold(semantic_threshold)

    def node_type(node_id: str | None) -> str:
        if node_id is None:
            return ""
        return str(node_by_id.get(node_id, {}).get("type", ""))

    def file_from_chunk(node_id: str | None) -> str | None:
        if node_id is None:
            return None
        for edge in edges:
            src, dst = _edge_endpoints(edge)
            if str(edge.get("label", "")) == "contains chunk" and dst == node_id and node_type(src) == "file":
                return src
        return None

    # ── Semantic mode (dedicated path) ──
    if mode == "semantic":
        return _project_semantic(node_by_id, edges, effective_threshold, semantic_threshold, _is_curated_node, _is_curated_edge, _edge_endpoints, _dedupe_append, _enrich_graph_payload)

    # ── Files mode ──
    if mode == "files":
        return _project_files(node_by_id, edges, node_type, _dedupe_append, _enrich_graph_payload)

    # ── Overview / Topics modes ──
    out_nodes: dict[str, dict] = {}
    out_edges: list[dict] = []
    seen_edges: set[tuple[str, str, str]] = set()

    for nid, node in node_by_id.items():
        ntype = str(node.get("type", ""))
        if mode == "topics":
            if ntype in {"topic", "actor", "project", "decision", "issue", "outcome", "person", "organization", "place"}:
                out_nodes[nid] = node
        else:  # overview
            if ntype == "chunk":
                continue
            if ntype in SEMANTIC_CORE_TYPES or ntype == "file" or ntype in AST_NODE_TYPES:
                out_nodes[nid] = node
                continue
            if _is_curated_node(node):
                out_nodes[nid] = node

    for edge in edges:
        src, dst = _edge_endpoints(edge)
        label = str(edge.get("label", ""))
        src_type = node_type(src)
        dst_type = node_type(dst)

        if mode == "topics":
            if src in out_nodes and dst in out_nodes:
                if label in CANONICAL_RELATION_LABELS:
                    payload = {"semantic_score": edge.get("semantic_score")} if edge.get("semantic_score") is not None else None
                    _dedupe_append(out_edges, seen_edges, src, dst, label, payload)
                    continue
                if label in {"covers topic", "mentions actor", "authored by"} and src_type != "file" and dst_type != "file":
                    _dedupe_append(out_edges, seen_edges, src, dst, label)
                    continue
        else:  # overview
            if src in out_nodes and dst in out_nodes and label != "contains chunk":
                if label in AST_EDGE_LABELS:
                    _dedupe_append(out_edges, seen_edges, src, dst, label)
                    continue
                if src_type == "file" and dst_type in {"topic", "actor", "project", "decision", "issue", "outcome"} and label in CURATED_EDGE_LABELS:
                    continue
                if not _is_curated_edge(edge, effective_threshold) and label not in CURATED_EDGE_LABELS:
                    continue
                payload = {"semantic_score": edge.get("semantic_score")} if edge.get("semantic_score") is not None else None
                _dedupe_append(out_edges, seen_edges, src, dst, label, payload)
                continue
            # Lift chunk-derived edges to file level
            if src_type == "chunk" and dst in out_nodes:
                parent_file = file_from_chunk(src)
                if parent_file and parent_file in out_nodes:
                    mapped_label = "file " + label if not label.startswith("file ") and label != "references file" else "references file"
                    if label in {"has project", "has decision", "has issue", "has outcome"}:
                        _dedupe_append(out_edges, seen_edges, parent_file, dst, label)
                    elif mapped_label in CURATED_EDGE_LABELS or label in CURATED_EDGE_LABELS:
                        _dedupe_append(out_edges, seen_edges, parent_file, dst, mapped_label)

    return _enrich_graph_payload({"nodes": list(out_nodes.values()), "edges": out_edges}, mode)


def _project_files(node_by_id, edges, node_type, dedupe_append, enrich):
    """Files mode: keep file-level structure + AST code nodes."""
    out_nodes: dict[str, dict] = {}
    out_edges: list[dict] = []
    seen_edges: set[tuple[str, str, str]] = set()

    for nid, node in node_by_id.items():
        ntype = str(node.get("type", ""))
        if ntype == "file" or ntype in AST_NODE_TYPES:
            out_nodes[nid] = node

    for edge in edges:
        src, dst = _edge_endpoints(edge)
        label = str(edge.get("label", ""))
        if node_type(src) == "file" and node_type(dst) == "file":
            dedupe_append(out_edges, seen_edges, src, dst, label)
        elif node_type(src) == "file" and dst in out_nodes and label in AST_EDGE_LABELS:
            dedupe_append(out_edges, seen_edges, src, dst, label)
        elif src in out_nodes and dst in out_nodes and label in AST_EDGE_LABELS:
            dedupe_append(out_edges, seen_edges, src, dst, label)

    return enrich({"nodes": list(out_nodes.values()), "edges": out_edges}, "files")


def _project_semantic(node_by_id, edges, effective_threshold, semantic_threshold,
                       is_curated_node, is_curated_edge, edge_endpoints, dedupe_append, enrich):
    """Semantic mode: aggressive curation with inferred co-occurrence edges."""
    concept_types = {"topic", "project", "decision", "issue", "outcome", "actor", "person", "organization", "place", "chunk"}
    anchor_types = {"project", "decision", "issue", "outcome"}
    preferred_semantic_types = {"project", "decision", "issue", "outcome", "actor", "person", "organization", "place", "chunk"}
    life_index = load_life_index()

    concept_nodes: dict[str, dict] = {}
    summary_to_concepts: dict[str, set[str]] = {}
    chunk_to_concepts: dict[str, set[str]] = {}
    concept_to_summaries: dict[str, set[str]] = {}
    concept_to_chunks: dict[str, set[str]] = {}
    inferred_scores: dict[tuple[str, str], dict[str, int]] = {}

    def semantic_node_ok(node: dict) -> bool:
        if not node:
            return False
        ntype = str(node.get("type", "") or "").lower()
        if ntype not in concept_types or not is_curated_node(node):
            return False
        return not (ntype == "topic" and _is_weak_label(node.get("label", "")))

    def apply_canonical_bias(node: dict) -> dict:
        updated = dict(node)
        raw_label = str(updated.get("label", "") or "").strip()
        if not raw_label:
            return updated
        norm = re.sub(r"\s+", " ", raw_label.lower()).strip()
        record = life_index.get("aliases", {}).get(norm)
        if not record:
            return updated
        updated["label"] = str(record.get("title") or raw_label)
        record_type = str(record.get("type", "") or "").lower()
        current_type = str(updated.get("type", "") or "").lower()
        if record_type in concept_types and current_type == "topic":
            updated["type"] = record_type
            updated["inferred_type"] = record_type
            updated["type_confidence"] = max(float(updated.get("type_confidence", 0.0) or 0.0), 0.96)
        updated["canonical_slug"] = str(record.get("slug") or "")
        updated["canonical_path"] = str(record.get("path") or "")
        return updated

    for nid, node in node_by_id.items():
        if semantic_node_ok(node):
            concept_nodes[nid] = apply_canonical_bias(node)

    direct_edges: list[tuple] = []
    for edge in edges:
        src, dst = edge_endpoints(edge)
        src_node = node_by_id.get(src or "")
        dst_node = node_by_id.get(dst or "")
        if not src_node or not dst_node:
            continue
        src_type = str(src_node.get("type", "") or "").lower()
        dst_type = str(dst_node.get("type", "") or "").lower()

        if src in concept_nodes and dst in concept_nodes:
            payload = {}
            if edge.get("semantic_score") is not None:
                try:
                    payload["semantic_score"] = round(float(edge.get("semantic_score") or 0), 3)
                except (TypeError, ValueError):
                    pass
            label = str(edge.get("label", "") or "").strip().lower()
            if is_curated_edge(edge, effective_threshold) or label in CANONICAL_RELATION_LABELS:
                direct_edges.append((src, dst, edge.get("label", "related"), payload))
            continue

        if src_type == "summary" and dst in concept_nodes:
            summary_to_concepts.setdefault(src, set()).add(dst)
            concept_to_summaries.setdefault(dst, set()).add(src)
        elif dst_type == "summary" and src in concept_nodes:
            summary_to_concepts.setdefault(dst, set()).add(src)
            concept_to_summaries.setdefault(src, set()).add(dst)
        elif src_type == "chunk" and dst in concept_nodes:
            chunk_to_concepts.setdefault(src, set()).add(dst)
            concept_to_chunks.setdefault(dst, set()).add(src)
        elif dst_type == "chunk" and src in concept_nodes:
            chunk_to_concepts.setdefault(dst, set()).add(src)
            concept_to_chunks.setdefault(src, set()).add(dst)

    # Co-occurrence scoring
    for members in summary_to_concepts.values():
        member_list = sorted(members)
        for i, a in enumerate(member_list):
            for b in member_list[i + 1:]:
                pair = tuple(sorted((a, b)))
                inferred_scores.setdefault(pair, {"summary": 0, "chunk": 0})
                inferred_scores[pair]["summary"] += 1

    for members in chunk_to_concepts.values():
        member_list = sorted(members)
        for i, a in enumerate(member_list):
            for b in member_list[i + 1:]:
                pair = tuple(sorted((a, b)))
                inferred_scores.setdefault(pair, {"summary": 0, "chunk": 0})
                inferred_scores[pair]["chunk"] += 1

    # Node strength
    node_strength: dict[str, float] = {}
    for nid, node in concept_nodes.items():
        ntype = str(node.get("type", "") or "").lower()
        strength = 1.0
        if ntype in anchor_types:
            strength += 3.0
        elif ntype in preferred_semantic_types:
            strength += 2.0
        strength += min(2.5, 0.7 * len(concept_to_summaries.get(nid, set())))
        strength += min(2.0, 0.45 * len(concept_to_chunks.get(nid, set())))
        conf = float(node.get("type_confidence", 1.0) or 1.0)
        strength += max(0.0, conf - 0.75)
        if node.get("inferred_type"):
            strength -= 0.25
        node_strength[nid] = round(strength, 3)

    # Direct edges
    keep_edges: list[dict] = []
    keep_nodes: set[str] = set()
    seen: set[tuple[str, str, str]] = set()
    direct_pairs: set[tuple[str, str]] = set()

    for src, dst, label, payload in sorted(direct_edges, key=lambda item: (
        float((item[3] or {}).get("semantic_score", 0) or 0),
        node_strength.get(item[0], 0) + node_strength.get(item[1], 0),
    ), reverse=True):
        dedupe_append(keep_edges, seen, src, dst, label, payload or None)
        direct_pairs.add(tuple(sorted((src, dst))))
        keep_nodes.add(src)
        keep_nodes.add(dst)

    # Inferred edges
    inferred_candidates = []
    for (a, b), support in inferred_scores.items():
        a_node = concept_nodes.get(a)
        b_node = concept_nodes.get(b)
        if not a_node or not b_node:
            continue
        a_type = str(a_node.get("type", "") or "").lower()
        b_type = str(b_node.get("type", "") or "").lower()
        summary_support = int(support.get("summary", 0) or 0)
        chunk_support = int(support.get("chunk", 0) or 0)
        if summary_support <= 0 and chunk_support <= 0:
            continue
        score = min(0.5, 0.18 * summary_support) + min(0.35, 0.12 * chunk_support)
        if a_type in anchor_types or b_type in anchor_types:
            score += 0.12
        if a_type == b_type == "topic":
            score -= 0.08
        if a_type == "topic" or b_type == "topic":
            score -= 0.03
        score += min(0.2, 0.02 * (node_strength.get(a, 0) + node_strength.get(b, 0)))
        if score < SEMANTIC_FALLBACK_MIN_SCORE:
            continue
        inferred_candidates.append((a, b, "semantic related", {
            "semantic_score": round(min(score, 0.95), 3),
            "cooccurrence_count": summary_support + chunk_support,
            "inferred": True,
            "support_summary_count": summary_support,
            "support_chunk_count": chunk_support,
        }))

    inferred_candidates.sort(key=lambda item: (
        float((item[3] or {}).get("semantic_score", 0) or 0),
        (item[3] or {}).get("cooccurrence_count", 0),
        node_strength.get(item[0], 0) + node_strength.get(item[1], 0),
    ), reverse=True)

    inferred_neighbor_counts: dict[str, int] = {}
    for src, dst, label, payload in inferred_candidates:
        pair = tuple(sorted((src, dst)))
        if pair in direct_pairs:
            continue
        src_budget = SEMANTIC_INFERRED_NEIGHBOR_BUDGET_HIGH if node_strength.get(src, 0) >= SEMANTIC_INFERRED_NEIGHBOR_STRENGTH_CUTOFF else SEMANTIC_INFERRED_NEIGHBOR_BUDGET_LOW
        dst_budget = SEMANTIC_INFERRED_NEIGHBOR_BUDGET_HIGH if node_strength.get(dst, 0) >= SEMANTIC_INFERRED_NEIGHBOR_STRENGTH_CUTOFF else SEMANTIC_INFERRED_NEIGHBOR_BUDGET_LOW
        if inferred_neighbor_counts.get(src, 0) >= src_budget or inferred_neighbor_counts.get(dst, 0) >= dst_budget:
            if float((payload or {}).get("semantic_score", 0) or 0) < 0.72:
                continue
        dedupe_append(keep_edges, seen, src, dst, label, payload or None)
        keep_nodes.add(src)
        keep_nodes.add(dst)
        inferred_neighbor_counts[src] = inferred_neighbor_counts.get(src, 0) + 1
        inferred_neighbor_counts[dst] = inferred_neighbor_counts.get(dst, 0) + 1

    # Fallback for sparse results
    if len(keep_edges) < 6:
        for nid, _score in sorted(node_strength.items(), key=lambda item: item[1], reverse=True)[:18]:
            keep_nodes.add(nid)
        fallback_pairs = list(inferred_candidates[:18])
        if not fallback_pairs:
            strong_nodes = [nid for nid, _score in sorted(node_strength.items(), key=lambda item: item[1], reverse=True)[:10]]
            fallback_pairs = []
            for idx, src in enumerate(strong_nodes):
                for dst in strong_nodes[idx + 1:idx + 3]:
                    if src != dst:
                        fallback_pairs.append((src, dst, "semantic related", {"semantic_score": 0.42, "inferred": True, "fallback": True}))
                    if len(fallback_pairs) >= 10:
                        break
                if len(fallback_pairs) >= 10:
                    break
        for src, dst, label, payload in fallback_pairs:
            if float((payload or {}).get("semantic_score", 0) or 0) >= semantic_threshold:
                dedupe_append(keep_edges, seen, src, dst, label, payload or None)
                keep_nodes.add(src)
                keep_nodes.add(dst)

    if not keep_nodes:
        for nid, _score in sorted(node_strength.items(), key=lambda item: item[1], reverse=True)[:14]:
            keep_nodes.add(nid)

    return enrich({
        "nodes": [node_by_id[nid] for nid in keep_nodes if nid in node_by_id],
        "edges": keep_edges,
    }, "semantic")