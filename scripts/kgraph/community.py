"""Community detection and clustering for kgraph using Leiden / greedy modularity.

Detects semantic communities (clusters) in a node graph, computes
centrality scores, and identifies 'god nodes' — highly central
concepts that bridge otherwise disconnected groups.

Uses networkx as the graph engine under the hood.  Accepts ``Graph``
models or legacy dicts.
"""

from __future__ import annotations

import logging

from .models import Graph

logger = logging.getLogger(__name__)

try:
    import networkx as nx
    from networkx.algorithms.community import (
        greedy_modularity_communities,
        louvain_communities,
    )
    _NX_AVAILABLE = True
except ImportError:
    nx = None  # type: ignore[assignment]
    _NX_AVAILABLE = False


def communities_available() -> bool:
    return _NX_AVAILABLE


def _build_nx_graph(graph: Graph) -> "nx.Graph":
    """Build a networkx Graph from a kgraph Graph model."""
    G = nx.Graph()
    for n in graph.nodes:
        G.add_node(n.id)
    for e in graph.edges:
        if G.has_node(e.source) and G.has_node(e.target):
            weight = e.semantic_score if e.semantic_score is not None else e.weight
            G.add_edge(e.source, e.target, weight=weight)
    return G


def detect_communities(graph: Graph | dict, method: str = "leiden_like", **kwargs) -> Graph:
    """Detect communities in a graph.

    Args:
        graph: Graph model or dict.
        method: 'louvain' or 'greedy' (greedy modularity).
        min_community_size: drop communities below this size.

    Returns:
        Updated Graph with meta.communities populated.
    """
    if isinstance(graph, dict):
        graph = Graph.from_dict(graph)

    if not _NX_AVAILABLE:
        return graph

    min_community_size = kwargs.get("min_community_size", 2)
    G = _build_nx_graph(graph)

    if G.number_of_nodes() < 3 or G.number_of_edges() < 2:
        return graph

    node_labels = {n.id: (n.label or n.id) for n in graph.nodes}

    try:
        if method == "louvain":
            comms = list(louvain_communities(G, weight="weight", seed=42))
        else:
            comms = list(greedy_modularity_communities(G, weight="weight"))
    except Exception as exc:
        logger.warning("Community detection failed, returning unclustered graph: %s", exc)
        return graph

    graph.meta.community_method = method
    community_list = []
    for idx, members in enumerate(comms):
        if len(members) < min_community_size:
            continue
        mlist = sorted(members)
        labels = [node_labels.get(m, m) for m in mlist[:3]]
        label = " · ".join(labels) if len(labels) >= 2 else (labels[0] if labels else f"community_{idx}")
        if len(mlist) > 3:
            label += f" (+{len(mlist) - 3})"
        community_list.append({
            "id": f"community_{idx}",
            "label": label[:80],
            "members": mlist,
            "size": len(mlist),
        })

    if community_list:
        graph.meta.communities = community_list

    return graph


def compute_centrality(graph: Graph | dict) -> dict:
    """Compute degree, betweenness, and eigenvector centrality.

    Returns a dict mapping node_id -> {degree, betweenness, eigenvector, label}.
    """
    if isinstance(graph, dict):
        graph = Graph.from_dict(graph)

    if not _NX_AVAILABLE:
        return {}

    G = _build_nx_graph(graph)
    if G.number_of_nodes() < 2:
        return {}

    node_labels = {n.id: (n.label or n.id) for n in graph.nodes}
    result: dict[str, dict] = {}

    degree = dict(G.degree())
    try:
        betweenness = nx.betweenness_centrality(G, weight="weight", k=min(200, G.number_of_nodes()))
    except Exception as exc:
        logger.warning("Betweenness centrality computation failed: %s", exc)
        betweenness = {}

    try:
        eigenvector = nx.eigenvector_centrality_numpy(G, weight="weight")
    except Exception as exc:
        logger.warning("Eigenvector centrality (numpy) failed, trying fallback: %s", exc)
        try:
            eigenvector = nx.eigenvector_centrality(G, max_iter=200)
        except Exception as exc2:
            logger.warning("Eigenvector centrality fallback also failed: %s", exc2)
            eigenvector = {}

    for nid in G.nodes():
        result[nid] = {
            "id": nid,
            "label": node_labels.get(nid, nid),
            "degree": degree.get(nid, 0),
            "betweenness": round(betweenness.get(nid, 0.0), 4),
            "eigenvector": round(eigenvector.get(nid, 0.0), 4),
        }

    return result


def find_god_nodes(graph: Graph | dict, top_n: int = 10) -> list[dict]:
    """Identify 'god nodes' — the most central, highly-connected nodes.

    Combines degree, betweenness, and eigenvector centrality into a
    composite score.  Returns sorted list with scores.
    """
    centralities = compute_centrality(graph)
    if not centralities:
        return []

    scored = []
    for nid, data in centralities.items():
        degree_norm = min(1.0, data["degree"] / 20.0)
        btw_norm = data["betweenness"] * 5.0
        eig_norm = data["eigenvector"] * 3.0
        composite = round((degree_norm * 0.3 + btw_norm * 0.4 + eig_norm * 0.3), 4)
        scored.append({
            "id": nid,
            "label": data["label"],
            "composite_score": composite,
            "degree": data["degree"],
            "betweenness": data["betweenness"],
            "eigenvector": data["eigenvector"],
        })

    scored.sort(key=lambda x: x["composite_score"], reverse=True)
    return scored[:top_n]