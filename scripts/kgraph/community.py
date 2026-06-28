"""Community detection and clustering for kgraph using Leiden / greedy modularity.

Detects semantic communities (clusters) in a node graph, computes
centrality scores, and identifies 'god nodes' — highly central
concepts that bridge otherwise disconnected groups.

Uses networkx as the graph engine under the hood. Pure offline.
"""


try:
    import networkx as nx
    from networkx.algorithms.community import (
        greedy_modularity_communities,
        louvain_communities,
    )
    _NX_AVAILABLE = True
except ImportError:
    nx = None
    _NX_AVAILABLE = False


def communities_available() -> bool:
    return _NX_AVAILABLE


def detect_communities(graph: dict, method: str = "leiden_like", **kwargs) -> dict:
    """Detect communities in a graph dict.

    Args:
        graph: dict with 'nodes' and 'edges'.
        method: 'louvain' or 'greedy' (greedy modularity).
        min_community_size: drop communities below this size.

    Returns:
        Updated graph dict with _meta.communities populated.
    """
    if not _NX_AVAILABLE:
        return graph

    min_community_size = kwargs.get('min_community_size', 2)
    kwargs.get('min_zoom', 0.30)

    G = nx.Graph()
    node_labels = {}

    for n in graph.get('nodes', []):
        nid = str(n.get('id', ''))
        if not nid:
            continue
        G.add_node(nid)
        node_labels[nid] = str(n.get('label') or nid)

    for e in graph.get('edges', []):
        src = str(e.get('from', e.get('source', '')))
        dst = str(e.get('to', e.get('target', '')))
        if not src or not dst:
            continue
        weight = 1.0
        try:
            weight = float(e.get('semantic_score', e.get('weight', 1.0)) or 1.0)
        except (TypeError, ValueError):
            pass
        if G.has_node(src) and G.has_node(dst):
            G.add_edge(src, dst, weight=weight)

    if G.number_of_nodes() < 3 or G.number_of_edges() < 2:
        return graph

    try:
        if method == 'louvain':
            comms = list(louvain_communities(G, weight='weight', seed=42))
        else:
            comms = list(greedy_modularity_communities(G, weight='weight'))
    except Exception:
        return graph

    _meta = dict(graph.get('_meta', {}))
    _meta['community_method'] = method

    community_list = []
    for idx, members in enumerate(comms):
        if len(members) < min_community_size:
            continue
        mlist = sorted(members)
        labels = [node_labels.get(m, m) for m in mlist[:3]]
        label = ' · '.join(labels) if len(labels) >= 2 else (labels[0] if labels else f'community_{idx}')
        if len(mlist) > 3:
            label += f' (+{len(mlist) - 3})'
        community_list.append({
            'id': f'community_{idx}',
            'label': label[:80],
            'members': mlist,
            'size': len(mlist),
        })

    if community_list:
        _meta['communities'] = community_list

    graph['_meta'] = _meta
    return graph


def compute_centrality(graph: dict) -> dict:
    """Compute degree, betweenness, and eigenvector centrality.

    Returns a dict mapping node_id -> {degree, betweenness, eigenvector, label}.
    """
    if not _NX_AVAILABLE:
        return {}

    G = nx.Graph()
    node_labels = {}

    for n in graph.get('nodes', []):
        nid = str(n.get('id', ''))
        if not nid:
            continue
        G.add_node(nid)
        node_labels[nid] = str(n.get('label') or nid)

    for e in graph.get('edges', []):
        src = str(e.get('from', e.get('source', '')))
        dst = str(e.get('to', e.get('target', '')))
        if not src or not dst:
            continue
        if G.has_node(src) and G.has_node(dst):
            weight = 1.0
            try:
                weight = float(e.get('semantic_score', e.get('weight', 1.0)) or 1.0)
            except (TypeError, ValueError):
                pass
            G.add_edge(src, dst, weight=weight)

    if G.number_of_nodes() < 2:
        return {}

    result = {}

    degree = dict(G.degree())
    try:
        betweenness = nx.betweenness_centrality(G, weight='weight', k=min(200, G.number_of_nodes()))
    except Exception:
        betweenness = {}

    try:
        eigenvector = nx.eigenvector_centrality_numpy(G, weight='weight')
    except Exception:
        try:
            eigenvector = nx.eigenvector_centrality(G, max_iter=200)
        except Exception:
            eigenvector = {}

    for nid in G.nodes():
        result[nid] = {
            'id': nid,
            'label': node_labels.get(nid, nid),
            'degree': degree.get(nid, 0),
            'betweenness': round(betweenness.get(nid, 0.0), 4),
            'eigenvector': round(eigenvector.get(nid, 0.0), 4),
        }

    return result


def find_god_nodes(graph: dict, top_n: int = 10) -> list[dict]:
    """Identify 'god nodes' — the most central, highly-connected nodes.

    Combines degree, betweenness, and eigenvector centrality into a
    composite score. Returns sorted list with scores.
    """
    centralities = compute_centrality(graph)
    if not centralities:
        return []

    scored = []
    for nid, data in centralities.items():
        degree_norm = min(1.0, data['degree'] / 20.0)
        btw_norm = data['betweenness'] * 5.0
        eig_norm = data['eigenvector'] * 3.0
        composite = round((degree_norm * 0.3 + btw_norm * 0.4 + eig_norm * 0.3), 4)
        scored.append({
            'id': nid,
            'label': data['label'],
            'composite_score': composite,
            'degree': data['degree'],
            'betweenness': data['betweenness'],
            'eigenvector': data['eigenvector'],
        })

    scored.sort(key=lambda x: x['composite_score'], reverse=True)
    return scored[:top_n]
