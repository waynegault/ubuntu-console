"""Query, path, and explain tools for graph navigation.

Provides CLI-friendly functions for:
- query: find nodes by label/type/pattern
- path: find a path between two nodes — fewest-hop ("bfs") or
  maximum-strength ("strongest"), with the mode named on the result
- explain: describe a node's connections and role

All functions accept ``Graph`` models or legacy dicts.
"""

from __future__ import annotations

import heapq
import itertools
import logging
import math
import re
from collections import deque
from typing import Any

from .community import community_for_node
from .models import ConfidenceLevel, Graph, GraphEdge, GraphNode

logger = logging.getLogger(__name__)

# REF: "RAG Isn't an Agent - I Built the Layer Between Retrieval and Action"
#      (Emmimal P Alexander, TDS, 2026-09-25) —
#      https://towardsdatascience.com/rag-isnt-an-agent-i-built-the-layer-between-retrieval-and-action/
# §5: the retriever must not treat the first (or any single) result as sufficient evidence,
# so the candidate set has to carry STRENGTH and not just membership.  A match is therefore
# scored and ordered here, and the score travels with the result so a caller can threshold
# it or flag a weak set.
#
# The tiers are 1.0 apart and the maximum incident-edge confidence weight is 0.9, so the
# match KIND dominates: an exact label cannot be outranked by a substring match however
# confident its edges are.  That invariant is asserted in tests/test_kgraph.py — raising a
# tier into the weight range is the edit that would silently break the ordering this
# module's docstring promises.
_MATCH_TIER: dict[str, float] = {"exact": 3.0, "substring": 2.0, "regex": 1.0}

#: Edge confidence → weight, on the repo's own three levels (confidence.py).  An untagged
#: edge takes INFERRED, which is what `confidence._determine_confidence` returns as its
#: default, so an unclassified edge never outranks a classified one.
_EDGE_WEIGHT: dict[str, float] = {
    ConfidenceLevel.EXTRACTED.value: 0.9,
    ConfidenceLevel.INFERRED.value: 0.6,
    ConfidenceLevel.AMBIGUOUS.value: 0.3,
}
_EDGE_WEIGHT_DEFAULT = 0.6


def _incident_edge_weights(graph: Graph) -> dict[str, float]:
    """{node_id: mean weight of its incident edges}.

    A node with no incident edges is ABSENT from the map rather than given a middle
    value: no edge evidence is not weak edge evidence, and the caller reads a missing id
    as 0.0.
    """
    totals: dict[str, float] = {}
    counts: dict[str, int] = {}
    for edge in graph.edges:
        level = getattr(edge.confidence, "value", edge.confidence)
        weight = _EDGE_WEIGHT.get(str(level), _EDGE_WEIGHT_DEFAULT)
        for endpoint in (str(edge.source), str(edge.target)):
            if not endpoint:
                continue
            totals[endpoint] = totals.get(endpoint, 0.0) + weight
            counts[endpoint] = counts.get(endpoint, 0) + 1
    return {nid: totals[nid] / counts[nid] for nid in totals}


def _match_kind(text: str, pattern_lower: str, regex: re.Pattern[str] | None) -> str | None:
    """How ``pattern`` matches ``text`` — the strongest of exact, substring, regex.

    An empty pattern is a substring of every text, which is the behaviour this replaced,
    so an empty query keeps matching everything rather than nothing.
    """
    if pattern_lower and text == pattern_lower:
        return "exact"
    if pattern_lower in text:
        return "substring"
    if regex is not None and regex.search(text):
        return "regex"
    return None


def query_nodes(graph: Graph | dict, pattern: str, **kwargs) -> list[dict]:
    """Find nodes matching a query pattern (label, type, or regex), strongest first.

    Each returned row carries the strength of its match, because a caller cannot tell a
    single decisive hit from a page of weak partials otherwise:

    * ``match`` — how the pattern hit: ``exact``, ``substring`` or ``regex``.
    * ``score`` — the match tier plus the node's mean incident-edge confidence weight
      (0.0 when the node has no incident edges).

    Ordering is deterministic — score descending, then ``id`` ascending — so the same
    graph yields the same order on every run (the graph is static per build).

    Args:
        graph: Graph model or dict.
        pattern: Text to match against labels and types.
        match_type: 'label', 'type', or 'any' (default 'any').
        max_results: cap on the returned rows (default 50).

    Returns:
        List of matching node dicts, each carrying ``match`` and ``score``, best first.
    """
    g = Graph.from_dict(graph) if isinstance(graph, dict) else graph

    match_type = kwargs.get("match_type", "any")
    max_results = kwargs.get("max_results", 50)

    pattern_lower = pattern.strip().lower()

    # The pattern is user-supplied: an invalid regex (e.g. "[") must not
    # crash the query.  Fall back to the literal substring test below.
    try:
        regex = re.compile(pattern, re.IGNORECASE)
    except re.error as exc:
        logger.warning("Invalid regex pattern %r, matching literally instead: %s", pattern, exc)
        regex = None

    weights = _incident_edge_weights(g)

    by_id: dict[str, dict] = {}
    for node in g.nodes:
        kinds: list[str] = []
        if match_type in ("label", "any"):
            kind = _match_kind(node.label.lower(), pattern_lower, regex)
            if kind:
                kinds.append(kind)
        if match_type in ("type", "any"):
            kind = _match_kind(node.type.lower(), pattern_lower, regex)
            if kind:
                kinds.append(kind)
        if not kinds:
            continue
        nid = str(node.id)
        if nid in by_id:
            continue
        best = max(kinds, key=lambda k: _MATCH_TIER[k])
        payload = node.model_dump(mode="json", exclude_none=True)
        payload["match"] = best
        payload["score"] = round(_MATCH_TIER[best] + weights.get(nid, 0.0), 4)
        by_id[nid] = payload

    ordered = sorted(by_id.values(), key=lambda n: (-n["score"], str(n.get("id", ""))))
    return ordered[:max_results]


# ── Path finding: two modes, both deterministic ────────────────────────
# REF: "GraphRAG with TypeSafe Jev: A System One Approach to Scalable
# Knowledge Graphs" (Partha Sarkar, TDS, 2026-09-27) —
# https://towardsdatascience.com/graphrag-with-typesafe-jev-a-system-one-approach-to-scalable-knowledge-graphs/
# `find_path` was a plain BFS, so the relationship STRENGTH the edges carry never
# entered a path answer at all.  The fewest-hop path stays the DEFAULT — a
# deterministic answer a caller can explain edge by edge — and the strength-aware
# answer is a second, NAMED mode, because the two answer different questions and
# a caller must be able to tell which one it got.

PATH_MODE_BFS = "bfs"
PATH_MODE_STRONGEST = "strongest"
_PATH_MODES = frozenset({PATH_MODE_BFS, PATH_MODE_STRONGEST})

#: Strength is clamped into this interval before its log is taken.  The floor
#: keeps ``-log(strength)`` finite for a 0.0 score (and for a negative or NaN one,
#: which the model does not forbid), so no edge has infinite cost; the ceiling
#: stops a score above 1.0 from producing a NEGATIVE cost — a free edge — which
#: would let an arbitrarily long chain of over-1 scores outrank a short direct
#: link.
_PATH_STRENGTH_MIN = 1e-6
_PATH_STRENGTH_MAX = 1.0

# Last term of the strongest-path ordering key: a strictly increasing counter, so
# two distinct paths can never compare equal and heapq never falls through to
# comparing the payloads (dicts and lists, which do not order).
_path_tiebreak = itertools.count()


def _path_strength(edge: GraphEdge) -> float:
    """The edge's relationship strength, clamped into ``(0, 1]``.

    ``semantic_score`` is the package's single continuous strength vocabulary
    (declared in constants.py); this reads it and adds no parallel score field.
    An edge that asserts rather than scores a relationship — an AST
    ``defines``/``calls`` edge — carries no score and is read as strength 1.0,
    not as a weak tie.

    A non-finite score reads as 1.0 with a warning: NaN compares False against
    every bound, so clamping it would otherwise silently return whatever the
    argument order of ``min``/``max`` happened to produce.
    """
    raw = edge.semantic_score if edge.semantic_score is not None else 1.0
    value = float(raw)
    if not math.isfinite(value):
        logger.warning(
            "Non-finite semantic_score %r on edge %s → %s; reading it as strength 1.0",
            raw, edge.source, edge.target,
        )
        return 1.0
    return min(_PATH_STRENGTH_MAX, max(_PATH_STRENGTH_MIN, value))


def _path_cost(edge: GraphEdge) -> float:
    """Traversal cost of *edge* in the ``"strongest"`` mode: ``-log(strength)``.

    Minimizing the summed cost maximizes the PRODUCT of the path's strengths.
    The product is the defensible combination because edge strengths are
    independent similarities: a chain is only as strong as the joint strength of
    its links, whereas a sum would let one weak link be averaged away by a strong
    one.  Every cost is non-negative, which is what makes Dijkstra applicable.
    """
    return -math.log(_path_strength(edge))


def _neighbourhood(graph: Graph) -> dict[str, list[tuple[str, str, GraphEdge]]]:
    """Undirected adjacency: node id → ``[(neighbour, label, edge), ...]``.

    Edge order is preserved, and both modes build their adjacency here, so a BFS
    answer and a strongest-path answer cannot disagree about which edges exist.
    """
    adj: dict[str, list[tuple[str, str, GraphEdge]]] = {}
    for e in graph.edges:
        adj.setdefault(e.source, []).append((e.target, e.label, e))
        adj.setdefault(e.target, []).append((e.source, e.label, e))
    return adj


def _resolve_endpoint(
    node_by_id: dict[str, GraphNode], id_by_label: dict[str, str], name: str,
) -> str | None:
    """A node id for *name*: the id itself, else the first label containing it.

    "First" is ``graph.nodes`` order, so the answer is deterministic for a given
    graph; an unmatched name returns None and the caller reports no path.
    """
    if name in node_by_id:
        return name
    lowered = str(name).lower()
    for label, nid in id_by_label.items():
        if lowered in label:
            return nid
    return None


def _shortest_path_edges(
    adj: dict[str, list[tuple[str, str, GraphEdge]]], src_id: str, tgt_id: str, max_depth: int,
) -> list[dict]:
    """BFS: the fewest-hop path, ties broken by edge order in ``graph.edges``.

    Deterministic for a given graph, and explainable edge by edge — every step is
    an edge a reader can check, with no hidden arithmetic.

    Returns the path's edges as JSON-ready dicts, or ``[]``.
    """
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
                queue.append((
                    neighbor,
                    path_edges + [edge.model_dump(mode="json", exclude_none=True)],
                ))

    return []


def _strongest_path_edges(
    adj: dict[str, list[tuple[str, str, GraphEdge]]], src_id: str, tgt_id: str, max_depth: int,
) -> list[dict]:
    """Dijkstra over ``-log(strength)``: the maximum-product-strength path.

    Tie-break, explicit and total: paths are ordered by
    ``(total cost, hop count, node-id sequence)`` — lower cost first, then fewer
    hops, then the lexicographically smallest node sequence.  The hop term is
    load-bearing, not cosmetic: an edge with no ``semantic_score`` costs exactly
    0.0, so without it a longer detour through unscored edges would tie with a
    short path at the same cost and the answer would depend on relaxation order.

    A node is visited at most once along a path, which also anchors the search on
    a graph whose zero-cost edges form a cycle.

    Returns the path's edges as JSON-ready dicts, or ``[]``.
    """
    ordering = (0.0, 0, (src_id,), next(_path_tiebreak))
    best: dict[str, tuple[float, int, tuple[str, ...]]] = {src_id: ordering[:3]}
    heap: list[tuple[tuple[float, int, tuple[str, ...], int], str, list[dict]]] = [
        (ordering, src_id, []),
    ]
    while heap:
        key, node, edges = heapq.heappop(heap)
        if key[:3] != best.get(node):
            # A cheaper label for this node was already expanded; this entry is
            # the stale one Dijkstra's lazy deletion leaves behind.
            continue
        if node == tgt_id:
            return edges
        if key[1] >= max_depth:
            continue
        for neighbor, _lbl, edge in adj.get(node, []):
            if neighbor in key[2]:
                continue
            candidate = (
                key[0] + _path_cost(edge),
                key[1] + 1,
                key[2] + (neighbor,),
            )
            current = best.get(neighbor)
            if current is not None and current <= candidate:
                continue
            best[neighbor] = candidate
            heapq.heappush(heap, (
                candidate + (next(_path_tiebreak),),
                neighbor,
                edges + [edge.model_dump(mode="json", exclude_none=True)],
            ))

    return []


def find_path_result(
    graph: Graph | dict,
    source: str,
    target: str,
    mode: str = PATH_MODE_BFS,
    **kwargs: Any,
) -> dict:
    """Find a path between two nodes and NAME the mode that produced it.

    Args:
        graph: Graph model or dict.
        source: Starting node id or label substring.
        target: Ending node id or label substring.
        mode: ``"bfs"`` (default) — the fewest-hop path, ties broken by edge
            order in ``graph.edges`` — or ``"strongest"`` — the path maximizing
            the product of its edges' strengths, at cost ``-log(strength)`` per
            edge, with the tie-break documented on
            :func:`_strongest_path_edges`.
        max_depth: cap on the number of hops (default 10).

    Returns:
        ``{"mode": <mode>, "path_found": bool, "edges": [...]}``.  ``mode`` is
        always present and is the mode actually used, because "no path" under one
        mode is not "no path" under the other: a caller that cannot see which one
        ran cannot interpret the answer.  An unknown mode raises ``ValueError``
        rather than silently answering with a different one.
    """
    if isinstance(graph, dict):
        graph = Graph.from_dict(graph)

    normalized = str(mode).strip().lower()
    if normalized not in _PATH_MODES:
        raise ValueError(
            f"unknown path mode {mode!r}: expected one of {sorted(_PATH_MODES)}"
        )

    max_depth = kwargs.get("max_depth", 10)

    # Resolve node ids from labels if needed
    node_by_id: dict[str, GraphNode] = {}
    id_by_label: dict[str, str] = {}
    for n in graph.nodes:
        node_by_id[n.id] = n
        if n.label:
            id_by_label.setdefault(n.label.lower(), n.id)

    src_id = _resolve_endpoint(node_by_id, id_by_label, source)
    tgt_id = _resolve_endpoint(node_by_id, id_by_label, target)
    if src_id is None or tgt_id is None:
        return {"mode": normalized, "path_found": False, "edges": []}

    adj = _neighbourhood(graph)
    if normalized == PATH_MODE_STRONGEST:
        edges = _strongest_path_edges(adj, src_id, tgt_id, max_depth)
    else:
        edges = _shortest_path_edges(adj, src_id, tgt_id, max_depth)
    return {"mode": normalized, "path_found": bool(edges), "edges": edges}


def find_path(graph: Graph | dict, source: str, target: str, **kwargs: Any) -> list[dict]:
    """Find the shortest path between two nodes by id or label.

    The fewest-hop path by default; the same call that also reports which mode
    produced the edges — and accepts ``mode="strongest"`` for the
    maximum-product-strength path — is :func:`find_path_result`.  Kept as the
    list-returning entry point so a caller that only wants the edges is not
    forced to unpack a result dict.

    Args:
        graph: Graph model or dict.
        source: Starting node id or label substring.
        target: Ending node id or label substring.
        mode: passed through to :func:`find_path_result` (default ``"bfs"``).
        max_depth: cap on the number of hops (default 10).

    Returns:
        List of edge dicts forming the path, or empty list.
    """
    return find_path_result(graph, source, target, **kwargs)["edges"]


def _source_overflow(element: GraphEdge | GraphNode) -> dict[str, Any]:
    """The ``sources_overflow`` key for an element, present only when it applies.

    ``SourceLineage.merge_sources`` keeps the first MAX_SOURCES_PER_ELEMENT keys and
    records the TRUE count in ``metadata['sources_overflow']``.  Nothing read it, so a
    capped list of 64 arrived at a caller looking exactly like a complete one — the
    models' own docstring promised a reader could tell them apart, and this is where a
    reader does.  The key is omitted rather than set to null when nothing was
    truncated, so its presence carries the meaning.
    """
    overflow = element.metadata.get("sources_overflow")
    if overflow is None:
        return {}
    return {"sources_overflow": overflow}


def explain_node(graph: Graph | dict, node_id: str) -> dict:
    """Describe a node's connections, type, and role in the graph.

    Args:
        graph: Graph model or dict.
        node_id: Node id or label substring.

    Returns:
        Dict with node info, connections, and centrality context.

    Each connection carries the ``sources`` that asserted that edge, so a caller
    can cite the source document rather than assert the fact anonymously, and the
    node's ``community`` (when the graph carries a cached community digest) so a
    single explain answers "which theme is this part of" as well.  A connection whose
    source list hit the array bound also carries ``sources_overflow`` — the true count
    — so a truncated list is never read as the whole set.
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
                "sources": list(e.sources),
                **_source_overflow(e),
            })
        elif e.target == nid:
            inbound.append({
                "source": e.source,
                "label": e.label,
                "confidence": conf,
                "semantic_score": e.semantic_score,
                "sources": list(e.sources),
                **_source_overflow(e),
            })

    # Build label lookup
    label_map = {n.id: n.label for n in graph.nodes}

    for item in outbound:
        item["target_label"] = label_map.get(item["target"], item["target"])
    for item in inbound:
        item["source_label"] = label_map.get(item["source"], item["source"])

    community = community_for_node(graph, nid)

    return {
        "node": {
            "id": nid,
            "label": target_node.label,
            "type": target_node.type,
            "content_preview": target_node.content_preview,
            "community": None if community is None else {
                "id": str(community.get("id")),
                "label": community.get("label", ""),
                "size": community.get("size", len(community.get("members") or [])),
            },
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

    community = node.get("community")
    if community:
        lines.append(f'Community: {community["label"]} ({community["id"]}, {community["size"]} members)')

    if node.get("content_preview"):
        lines.append(f'Preview: {node["content_preview"]}')

    if explanation["outbound_connections"]:
        lines.append("")
        lines.append("Outbound:")
        for c in explanation["outbound_connections"]:
            score = f' [{c.get("semantic_score")}]' if c.get("semantic_score") else ""
            conf = f' ({c["confidence"]})' if c.get("confidence") else ""
            src = f' — source: {", ".join(c["sources"])}' if c.get("sources") else ""
            if c.get("sources_overflow"):
                src += f' (capped: {len(c["sources"])} of {c["sources_overflow"]})'
            lines.append(f'  → {c["target_label"]} ({c["label"]}){score}{conf}{src}')

    if explanation["inbound_connections"]:
        lines.append("")
        lines.append("Inbound:")
        for c in explanation["inbound_connections"]:
            score = f' [{c.get("semantic_score")}]' if c.get("semantic_score") else ""
            conf = f' ({c["confidence"]})' if c.get("confidence") else ""
            src = f' — source: {", ".join(c["sources"])}' if c.get("sources") else ""
            if c.get("sources_overflow"):
                src += f' (capped: {len(c["sources"])} of {c["sources_overflow"]})'
            lines.append(f'  ← {c["source_label"]} ({c["label"]}){score}{conf}{src}')

    return "\n".join(lines)


def format_path(path_edges: list[dict], mode: str = "") -> str:
    """Format a find_path result as human-readable text.

    *mode*, when given, is named under the header, because "the path" means two
    different things in :func:`find_path_result`'s two modes: an output that does
    not say which one ran cannot be interpreted.  Omitted (the default), the text
    is unchanged.
    """
    if not path_edges:
        return "No path found" if not mode else f"No path found (mode: {mode})"

    lines = ["Path:"]
    if mode:
        lines.append(f"  mode: {mode}")
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
