"""Confidence tagging for kgraph edges.

Every edge in the graph gets one of:
- EXTRACTED — directly from source data (AST parse, memory DB import)
- INFERRED — derived via co-occurrence, semantic similarity, or implicit relationship
- AMBIGUOUS — low-confidence relationships that should be verified

Accepts and returns ``Graph`` models.  Legacy dict input is tolerated
via ``Graph.from_dict()``.
"""

from __future__ import annotations

from .models import ConfidenceLevel, Graph, GraphEdge

# Re-export for callers that imported the old string constants.
EXTRACTED = ConfidenceLevel.EXTRACTED.value
INFERRED = ConfidenceLevel.INFERRED.value
AMBIGUOUS = ConfidenceLevel.AMBIGUOUS.value

# ── Label sets for classification ─────────────────────────────────────

_AST_LABELS = frozenset({"defines", "imports", "calls", "resolves_to"})

_DIRECT_MEMORY_LABELS = frozenset({
    "covers topic", "mentions actor", "authored by", "references file",
    "contains chunk", "has project", "has decision", "has issue",
    "has outcome", "has person", "has organization", "has place",
})

_CANONICAL_RELATION_LABELS = frozenset({
    "project decision", "project issue", "project outcome", "project topic",
    "project owner", "decision addresses issue", "decision drives outcome",
    "issue affects outcome", "topic decision", "topic issue", "topic outcome",
    "actor decision", "actor issue", "actor outcome",
})


def tag_confidence(graph: Graph | dict) -> Graph:
    """Tag every edge in the graph with a confidence level.

    Rules:
    - EXTRACTED: direct AST parse, explicit memory DB relation,
      canonically defined edges, user-saved edges
    - INFERRED: semantic similarity edges, co-occurrence edges,
      summary-derived edges, inferred (cooccurrence_count) edges
    - AMBIGUOUS: low semantic_score (< 0.55), inferred + weak support,
      very short edges without source data
    """
    if isinstance(graph, dict):
        graph = Graph.from_dict(graph)

    for edge in graph.edges:
        if edge.confidence is None:
            edge.confidence = _determine_confidence(edge)
    return graph


def _determine_confidence(edge: GraphEdge) -> ConfidenceLevel:
    """Determine confidence level for a single edge."""
    label = edge.label.strip().lower()

    # Explicit user-defined edges
    if edge.explicit:
        return ConfidenceLevel.EXTRACTED

    # AST parse edges
    if edge.origin == "ast" or label in _AST_LABELS:
        return ConfidenceLevel.EXTRACTED

    # Direct memory DB edges
    if label in _DIRECT_MEMORY_LABELS:
        return ConfidenceLevel.EXTRACTED

    # Canonical/semantic relation edges
    if label in _CANONICAL_RELATION_LABELS:
        return ConfidenceLevel.INFERRED

    # Summary-derived edges
    if label.startswith("summarizes ") or label == "semantic summary":
        return ConfidenceLevel.INFERRED

    # Explicitly tagged inferred
    if edge.inferred:
        return ConfidenceLevel.INFERRED

    # Semantic similarity edges
    if edge.semantic_score is not None:
        if edge.semantic_score >= 0.55:
            return ConfidenceLevel.INFERRED
        return ConfidenceLevel.AMBIGUOUS

    # Co-occurrence edges
    if edge.cooccurrence_count is not None:
        if edge.cooccurrence_count >= 3:
            return ConfidenceLevel.INFERRED
        return ConfidenceLevel.AMBIGUOUS

    # Fallback: look at label
    if "related" in label:
        return ConfidenceLevel.AMBIGUOUS

    # Generic fallback — endpoints exist (guaranteed by model validation)
    return ConfidenceLevel.INFERRED


def confidence_stats(graph: Graph | dict) -> dict:
    """Return a breakdown of confidence levels across graph edges."""
    if isinstance(graph, dict):
        graph = Graph.from_dict(graph)

    stats: dict[str, int] = {
        ConfidenceLevel.EXTRACTED.value: 0,
        ConfidenceLevel.INFERRED.value: 0,
        ConfidenceLevel.AMBIGUOUS.value: 0,
    }
    for edge in graph.edges:
        conf = edge.confidence or _determine_confidence(edge)
        key = conf.value if isinstance(conf, ConfidenceLevel) else str(conf)
        stats[key] = stats.get(key, 0) + 1

    total = sum(stats.values())
    return {
        "total": total,
        "extracted": stats[ConfidenceLevel.EXTRACTED.value],
        "inferred": stats[ConfidenceLevel.INFERRED.value],
        "ambiguous": stats[ConfidenceLevel.AMBIGUOUS.value],
        "extracted_pct": round(stats[ConfidenceLevel.EXTRACTED.value] / total * 100, 1) if total else 0,
        "inferred_pct": round(stats[ConfidenceLevel.INFERRED.value] / total * 100, 1) if total else 0,
        "ambiguous_pct": round(stats[ConfidenceLevel.AMBIGUOUS.value] / total * 100, 1) if total else 0,
    }