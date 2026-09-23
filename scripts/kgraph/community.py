"""Community detection and clustering for kgraph using Leiden / greedy modularity.

Detects semantic communities (clusters) in a node graph, computes
centrality scores, and identifies 'god nodes' — highly central
concepts that bridge otherwise disconnected groups.

Also writes the per-community digest: the article's "community reports" —
a cached, deterministic summary of each community (central nodes, bridging
god nodes, boundary edges) that a global "what are the main themes" question
can be answered from without re-running detection.

REF: "GraphRAG: A Practitioner's Guide to 6 Advanced Architectural Patterns"
     (Partha Sarkar, TDS, 2026-09-20) — https://towardsdatascience.com/graphrag-a-practitioners-guide-to-6-advanced-architectural-patterns/
The article's Microsoft-GraphRAG section: hierarchical community detection plus
LLM-generated community reports, then a GLOBAL SEARCH map-reduce over those
reports to answer "what are the main themes in this dataset?"; community reports
"are especially important for global reasoning".  The membership and centrality
half is deterministic and local, so it is built here; no LLM call is needed to
produce the digest, and none is made at query time.

Uses networkx as the graph engine under the hood.  Accepts ``Graph``
models or legacy dicts.
"""

from __future__ import annotations

import importlib
import logging
import time
import warnings
from typing import Any

from .constants import COMMUNITY_DIGEST_VERSION
from .models import Graph

logger = logging.getLogger(__name__)

# networkx is an optional dependency with no type stubs: pre-declare the
# names as Any so the fallback path needs no `type: ignore` comments and both
# mypy and pyright stay happy.
nx: Any
greedy_modularity_communities: Any
louvain_communities: Any
try:
    nx = importlib.import_module("networkx")
    _community_mod = importlib.import_module("networkx.algorithms.community")
    greedy_modularity_communities = _community_mod.greedy_modularity_communities
    louvain_communities = _community_mod.louvain_communities
    _NX_AVAILABLE = True
except ImportError:
    _NX_AVAILABLE = False

# Louvain is expensive on large graphs (quadratic-ish refinement passes).
# Above this node count, requests for Louvain fall back to greedy modularity
# so `kgraph --update` / `--communities` cannot stall silently on a huge
# merged graph.
LOUVAIN_MAX_NODES = 10_000


def communities_available() -> bool:
    return _NX_AVAILABLE


def _build_nx_graph(graph: Graph) -> Any:
    """Build a networkx Graph from a kgraph Graph model."""
    G = nx.Graph()
    for n in graph.nodes:
        G.add_node(n.id)
    for e in graph.edges:
        if G.has_node(e.source) and G.has_node(e.target):
            weight = e.semantic_score if e.semantic_score is not None else e.weight
            # `weight` is a similarity/strength (higher = stronger tie) and is
            # used as tie-strength by Louvain/eigenvector. networkx shortest-path
            # algorithms instead treat a `weight` attribute as a *distance*, so
            # store an explicit `distance` (stronger = shorter) and use that for
            # betweenness; otherwise a strong-linked hub is scored as a weak
            # bridge.
            G.add_edge(e.source, e.target, weight=weight,
                       distance=1.0 / max(float(weight), 1e-9))
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

    # Louvain on a huge merged graph is what makes builds appear hung: fall
    # back to greedy modularity (still good clusters, far faster) above the
    # size threshold, and always report elapsed time.
    effective_method = method
    if method == "louvain" and G.number_of_nodes() > LOUVAIN_MAX_NODES:
        logger.warning(
            "Graph has %d nodes — Louvain too slow at this size; using greedy modularity",
            G.number_of_nodes(),
        )
        effective_method = "greedy"

    started = time.monotonic()
    try:
        if effective_method == "louvain":
            comms = list(louvain_communities(G, weight="weight", seed=42))
        else:
            comms = list(greedy_modularity_communities(G, weight="weight"))
    except (ValueError, ZeroDivisionError) as exc:
        logger.warning("Community detection failed, returning unclustered graph: %s", exc)
        return graph
    elapsed = time.monotonic() - started
    logger.info(
        "Community detection (%s) on %d nodes, %d edges: %.1fs",
        effective_method, G.number_of_nodes(), G.number_of_edges(), elapsed,
    )

    graph.meta.community_method = effective_method
    community_list = []
    for idx, members in enumerate(comms):
        if len(members) < min_community_size:
            continue
        mlist = sorted(members)
        labels = [str(node_labels.get(m, m) or m) for m in mlist[:3]]
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
        betweenness = nx.betweenness_centrality(G, weight="distance", k=min(200, G.number_of_nodes()))
    except (ValueError, ZeroDivisionError) as exc:
        logger.warning("Betweenness centrality computation failed: %s", exc)
        betweenness = {}

    # Capture — and log — any warnings numpy emits for ill-conditioned /
    # disconnected graphs rather than hiding them behind a blanket filter.
    # (A `simplefilter("ignore")` would silence a real signal; here every
    # captured warning is logged with its source location.)  The exception
    # path below still falls back to per-component power iteration.
    eigenvector: dict[str, float] = {}
    with warnings.catch_warnings(record=True) as caught_warnings:
        warnings.simplefilter("always")
        try:
            eigenvector = nx.eigenvector_centrality_numpy(G, weight="weight")
        except (nx.AmbiguousSolution, ValueError, TypeError, ZeroDivisionError, ArithmeticError) as exc:
            # numpy eigenvector centrality is undefined for disconnected graphs
            # (nx.AmbiguousSolution). Fall back to per-component power iteration:
            # each connected component is scored on its own dominant-eigenvector
            # scale; isolated nodes stay at 0.0.
            logger.warning(
                "Eigenvector centrality (numpy) failed (%s); using per-component fallback", exc
            )
            eigenvector = {}
            for component in nx.connected_components(G):
                if len(component) < 2:
                    continue
                try:
                    ev = nx.eigenvector_centrality(
                        G.subgraph(component), max_iter=200, weight="weight"
                    )
                except (nx.PowerIterationFailedConvergence, ValueError, TypeError,
                        ZeroDivisionError, ArithmeticError) as exc2:
                    logger.warning(
                        "Eigenvector centrality fallback failed for component of %d nodes: %s",
                        len(component), exc2,
                    )
                    continue
                eigenvector.update(ev)
    for warning in caught_warnings:
        logger.warning(
            "eigenvector_centrality_numpy warning at %s:%s: %s",
            warning.filename, warning.lineno, warning.message,
        )

    for nid in G.nodes():
        result[nid] = {
            "id": nid,
            "label": node_labels.get(nid, nid),
            "degree": degree.get(nid, 0),
            "betweenness": round(betweenness.get(nid, 0.0), 4),
            "eigenvector": round(eigenvector.get(nid, 0.0), 4),
        }

    return result


def _rank_nodes(centralities: dict) -> list[dict]:
    """Rank nodes by the composite centrality score, highest first.

    One definition of the composite formula: ``find_god_nodes`` and
    ``digest_communities`` both rank with it, and the digest reuses a single
    ``compute_centrality`` pass rather than running betweenness twice.
    """
    scored = []
    for nid, data in centralities.items():
        degree_norm = min(1.0, data["degree"] / 20.0)
        # NB: btw_norm/eig_norm are unbounded multipliers, so composite_score
        # is a relative ranking value, not a normalised 0–1 metric — even
        # though the report prints it with 3 decimals.
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

    # id as the tie-break, so two runs on the same graph order identically.
    scored.sort(key=lambda x: (-x["composite_score"], x["id"]))
    return scored


def find_god_nodes(graph: Graph | dict, top_n: int = 10) -> list[dict]:
    """Identify 'god nodes' — the most central, highly-connected nodes.

    Combines degree, betweenness, and eigenvector centrality into a
    composite score.  Returns sorted list with scores.
    """
    centralities = compute_centrality(graph)
    if not centralities:
        return []
    return _rank_nodes(centralities)[:top_n]


# ── Community digest (the article's community report) ──────────────────

DEFAULT_CENTRAL_NODES = 3
DEFAULT_BOUNDARY_EDGES = 5


def digest_communities(graph: Graph | dict,
                       central_nodes: int = DEFAULT_CENTRAL_NODES,
                       boundary_edges: int = DEFAULT_BOUNDARY_EDGES) -> Graph:
    """Write a short, deterministic community report onto each community.

    REF: "GraphRAG: A Practitioner's Guide to 6 Advanced Architectural
    Patterns" (Partha Sarkar, TDS, 2026-09-20) — the article's community reports
    "are especially important for global reasoning".

    Adds, per ``graph.meta.communities`` entry (in place):

    ``central_nodes``
        the community's ``central_nodes`` most central members, by the same
        composite score ``find_god_nodes`` ranks with, each with its label.
    ``god_nodes``
        the members that are also global god nodes — the bridging concepts.
    ``boundary_edges``
        up to ``boundary_edges`` edges with exactly one endpoint inside the
        community (its interface to the rest of the graph), with ``direction``
        ``"out"``/``"in"``, plus ``boundary_edge_count`` for the true total.
    ``digest_version``
        :data:`~kgraph.constants.COMMUNITY_DIGEST_VERSION`, so a stored digest
        written to an older shape is identifiable.

    Deterministic and local: membership comes from ``detect_communities``,
    centrality from ``compute_centrality``, and the ordering is fixed by
    (score desc, id asc) / (source, target, label).  Nothing here calls an LLM
    and nothing here is recomputed per query — the update path stores the
    result with the graph.

    A graph with no detected communities is returned unchanged.
    """
    if isinstance(graph, dict):
        graph = Graph.from_dict(graph)

    if not graph.meta.communities:
        return graph

    centralities = compute_centrality(graph)
    if not centralities:
        # networkx unavailable, or fewer than two nodes: membership may still
        # exist (it was cached with the graph), but the digest fields cannot be
        # derived, so leave the records as they are rather than writing empty
        # lists that read like "no central nodes".
        logger.info("No centrality available — community digest fields left unset")
        return graph

    ranked = _rank_nodes(centralities)
    god_ids = {entry["id"] for entry in ranked[:10]}
    rank_by_id = {entry["id"]: entry for entry in ranked}

    for community in graph.meta.communities:
        members = [str(m) for m in (community.get("members") or [])]
        member_set = set(members)

        picks = [rank_by_id[m] for m in members if m in rank_by_id]
        picks.sort(key=lambda r: (-r["composite_score"], r["id"]))
        community["central_nodes"] = [
            {"id": r["id"], "label": r["label"], "composite_score": r["composite_score"]}
            for r in picks[:central_nodes]
        ]
        community["god_nodes"] = [
            {"id": r["id"], "label": r["label"]}
            for r in picks if r["id"] in god_ids
        ]

        boundary = []
        for e in graph.edges:
            src_in = e.source in member_set
            dst_in = e.target in member_set
            if src_in == dst_in:
                continue
            boundary.append({
                "source": e.source,
                "target": e.target,
                "label": e.label,
                "direction": "out" if src_in else "in",
            })
        boundary.sort(key=lambda b: (b["source"], b["target"], b["label"]))
        community["boundary_edge_count"] = len(boundary)
        community["boundary_edges"] = boundary[:boundary_edges]
        community["digest_version"] = COMMUNITY_DIGEST_VERSION

    return graph


def community_for_node(graph: Graph | dict, node_id: str) -> dict | None:
    """The community record containing *node_id*, or None when it is unclustered."""
    if isinstance(graph, dict):
        graph = Graph.from_dict(graph)
    for community in graph.meta.communities:
        if node_id in (community.get("members") or []):
            return community
    return None


def community_view(graph: Graph | dict, community_id: str = "") -> dict:
    """Read-only answer to "what are the main themes" from the community digest.

    REF: "GraphRAG: A Practitioner's Guide to 6 Advanced Architectural
    Patterns" (Partha Sarkar, TDS, 2026-09-20) — the global-search side of the
    article, scoped to what the structure already holds: this is a READ over the
    cached digest, not an LLM map-reduce (the article itself calls full global
    search "not a universal solution").

    With *community_id* empty, returns the digest's own summary list — one entry
    per community, small enough to put in a prompt.  With an id, returns that
    community's full record (members, central nodes, god/bridging nodes, boundary
    edges).  ``source`` names where the membership came from: ``"digest"`` when
    it was cached with the graph, ``"computed"`` when this call had to detect it.
    """
    if isinstance(graph, dict):
        graph = Graph.from_dict(graph)

    source = "digest"
    if not graph.meta.communities:
        # A graph saved before the digest existed, or one passed in as a plain
        # JSON file: compute membership so the tool still answers, and say so.
        source = "computed"
        graph = detect_communities(graph)

    records = graph.meta.communities
    if community_id:
        for community in records:
            if str(community.get("id")) == community_id:
                return {"source": source, "community": community}
        return {
            "source": source,
            "error": f'Community "{community_id}" not found',
            "community_ids": [str(c.get("id")) for c in records],
        }

    return {
        "source": source,
        "method": graph.meta.community_method,
        "count": len(records),
        "communities": [
            {
                "id": str(c.get("id")),
                "label": c.get("label", ""),
                "size": c.get("size", len(c.get("members") or [])),
                "central_nodes": c.get("central_nodes", []),
                "god_nodes": c.get("god_nodes", []),
                "boundary_edge_count": c.get("boundary_edge_count", 0),
            }
            for c in records
        ],
    }
