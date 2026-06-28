"""Confidence tagging for all kgraph edges.

Every edge in the graph gets one of:
- EXTRACTED — directly from source data (AST parse, memory DB import)
- INFERRED — derived via co-occurrence, semantic similarity, or implicit relationship
- AMBIGUOUS — low-confidence relationships that should be verified

Also provides a confidence-tagging pass that can be applied to any graph.
"""


# Confidence levels
EXTRACTED = 'EXTRACTED'
INFERRED = 'INFERRED'
AMBIGUOUS = 'AMBIGUOUS'


def tag_confidence(graph: dict) -> dict:
    """Tag every edge in the graph with a confidence level.

    Rules:
    - EXTRACTED: direct AST parse, explicit memory DB relation,
      canonically defined edges, user-saved edges
    - INFERRED: semantic similarity edges, co-occurrence edges,
      summary-derived edges, inferred (cooccurrence_count) edges
    - AMBIGUOUS: low semantic_score (< 0.55), inferred + weak support,
      very short edges without source data
    """
    for edge in graph.get('edges', []):
        edge.setdefault('confidence', _determine_confidence(edge))
    return graph


def _determine_confidence(edge: dict) -> str:
    """Determine confidence level for a single edge."""
    label = str(edge.get('label', '') or '').strip().lower()
    is_inferred = edge.get('inferred', False) or edge.get('inferred_type', False)
    explicit = edge.get('explicit', False)

    # Explicit user-defined edges
    if explicit:
        return EXTRACTED

    # AST parse edges
    if edge.get('source') == 'ast' or label in ('defines', 'imports', 'calls', 'resolves_to'):
        return EXTRACTED

    # Direct memory DB edges
    if label in ('covers topic', 'mentions actor', 'authored by', 'references file',
                  'contains chunk', 'has project', 'has decision', 'has issue',
                  'has outcome', 'has person', 'has organization', 'has place'):
        return EXTRACTED

    # Canonical/semantic relation edges
    if label in ('project decision', 'project issue', 'project outcome', 'project topic',
                  'project owner', 'decision addresses issue', 'decision drives outcome',
                  'issue affects outcome', 'topic decision', 'topic issue', 'topic outcome',
                  'actor decision', 'actor issue', 'actor outcome'):
        return INFERRED

    # Summary-derived edges
    if label.startswith('summarizes ') or label == 'semantic summary':
        return INFERRED

    # Explicitly tagged inferred
    if is_inferred:
        return INFERRED

    # Semantic similarity edges
    if edge.get('semantic_score') is not None:
        try:
            score = float(edge.get('semantic_score', 0) or 0)
        except (TypeError, ValueError):
            score = 0.0
        if score >= 0.55:
            return INFERRED
        return AMBIGUOUS

    # Co-occurrence edges
    if edge.get('cooccurrence_count') is not None:
        count = int(edge.get('cooccurrence_count', 0) or 0)
        if count >= 3:
            return INFERRED
        elif count >= 1:
            return AMBIGUOUS
        return AMBIGUOUS

    # Fallback: look at label
    if label in ('related concept', 'related') or 'related' in label:
        return AMBIGUOUS

    # Generic fallback
    src = str(edge.get('from', edge.get('source', '')))
    dst = str(edge.get('to', edge.get('target', '')))
    if not src or not dst:
        return AMBIGUOUS

    return INFERRED


def confidence_stats(graph: dict) -> dict:
    """Return a breakdown of confidence levels across graph edges."""
    stats = {EXTRACTED: 0, INFERRED: 0, AMBIGUOUS: 0}
    for edge in graph.get('edges', []):
        conf = edge.get('confidence', _determine_confidence(edge))
        stats[conf] = stats.get(conf, 0) + 1
    total = sum(stats.values())
    return {
        'total': total,
        'extracted': stats[EXTRACTED],
        'inferred': stats[INFERRED],
        'ambiguous': stats[AMBIGUOUS],
        'extracted_pct': round(stats[EXTRACTED] / total * 100, 1) if total else 0,
        'inferred_pct': round(stats[INFERRED] / total * 100, 1) if total else 0,
        'ambiguous_pct': round(stats[AMBIGUOUS] / total * 100, 1) if total else 0,
    }
