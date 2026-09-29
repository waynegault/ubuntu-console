"""Confidence tagging for kgraph edges.

Every edge in the graph gets one of:
- EXTRACTED — directly from source data (AST parse, memory DB import)
- INFERRED — derived via co-occurrence, semantic similarity, or implicit relationship
- AMBIGUOUS — low-confidence relationships that should be verified

Accepts and returns ``Graph`` models.  Legacy dict input is tolerated
via ``Graph.from_dict()``.
"""

from __future__ import annotations

from .constants import is_summary_edge_label
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

# ── UN-CALIBRATED classification thresholds (GRAPHRAG-JEV-005) ─────────
# REF: "GraphRAG with TypeSafe Jev: A System One Approach to Scalable Knowledge
#      Graphs" (Partha Sarkar, TDS, 2026-09-27) —
#      https://towardsdatascience.com/graphrag-with-typesafe-jev-a-system-one-approach-to-scalable-knowledge-graphs/
# Both numbers below are hand-picked defaults, NOT measured values, and this pass
# deliberately leaves them as they are rather than calibrating them, because the
# prerequisite is missing: calibration needs a LABELLED edge set — a sample of
# edges each carrying an independent judgement of whether the asserted
# relationship is real — and no such set exists in this repo.  Fabricating a
# fixture set and reporting it as calibration is forbidden here, so the honest
# state is "un-calibrated", written down, rather than a plausible-looking number.
#
# What a calibration would need, concretely:
#   * a labelled sample of edges (label = real / not-real), drawn from the same
#     emitters that produce `semantic_score` and `cooccurrence_count` — for
#     instance a JSON/CSV of (source, target, label, semantic_score,
#     cooccurrence_count, real) exported from a built graph and hand-reviewed;
#   * one PRECISION-RECALL curve per signal: precision and recall as the
#     threshold sweeps `semantic_score` (and, separately, `cooccurrence_count`).
#     The metric is precision-at-threshold with its recall, not accuracy: the two
#     errors are not symmetric — a wrong INFERRED edge is asserted downstream and
#     costs more than an AMBIGUOUS one flagged for review — so the threshold is
#     the lowest one whose precision stays at or above that cost ratio.
# Until that set exists, every value here is a default someone picked; treat a
# change to one as an unmeasured change, not an improvement.
SEMANTIC_INFERRED_MIN = 0.55
COOCCURRENCE_INFERRED_MIN = 3


def tag_confidence(graph: Graph | dict) -> Graph:
    """Tag every edge in the graph with a confidence level.

    Rules:
    - EXTRACTED: direct AST parse, explicit memory DB relation,
      canonically defined edges, user-saved edges
    - INFERRED: semantic similarity edges, co-occurrence edges,
      summary-derived edges, inferred (cooccurrence_count) edges
    - AMBIGUOUS: low semantic_score (< :data:`SEMANTIC_INFERRED_MIN`), inferred
      + weak support, very short edges without source data

    The two numeric cut-offs (:data:`SEMANTIC_INFERRED_MIN` and
    :data:`COOCCURRENCE_INFERRED_MIN`) are UN-CALIBRATED hand-picked defaults —
    see the note above them for what a real calibration would need.
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

    # Summary-derived edges — one predicate, shared with projection.py so the
    # two cannot drift apart on what counts as a summary edge
    if is_summary_edge_label(label):
        return ConfidenceLevel.INFERRED

    # Explicitly tagged inferred
    if edge.inferred:
        return ConfidenceLevel.INFERRED

    # Semantic similarity edges
    if edge.semantic_score is not None:
        if edge.semantic_score >= SEMANTIC_INFERRED_MIN:
            return ConfidenceLevel.INFERRED
        return ConfidenceLevel.AMBIGUOUS

    # Co-occurrence edges
    if edge.cooccurrence_count is not None:
        if edge.cooccurrence_count >= COOCCURRENCE_INFERRED_MIN:
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
