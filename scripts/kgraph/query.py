"""Query, path, and explain tools for graph navigation.

Provides CLI-friendly functions for:
- query: find nodes by label/type/pattern
- path: find shortest paths between two nodes
- explain: describe a node's connections and role

All functions accept the same graph dict format as other kgraph modules.
"""

import re
from collections import deque


def query_nodes(graph: dict, pattern: str, **kwargs) -> list[dict]:
    """Find nodes matching a query pattern (label, type, or regex).

    Args:
        graph: Graph dict with nodes.
        pattern: Text to match against labels and types.
        match_type: 'label', 'type', or 'any' (default 'any').

    Returns:
        List of matching node dicts.
    """
    match_type = kwargs.get('match_type', 'any')
    max_results = kwargs.get('max_results', 50)

    pattern_lower = pattern.strip().lower()
    results = []

    for n in graph.get('nodes', []):
        label = str(n.get('label', '') or '').lower()
        ntype = str(n.get('type', '') or '').lower()

        if match_type == 'label' or match_type == 'any':
            if pattern_lower in label or re.search(pattern, label, re.IGNORECASE):
                results.append(n)
                continue
        if match_type == 'type' or match_type == 'any':
            if pattern_lower in ntype or re.search(pattern, ntype, re.IGNORECASE):
                if not results or results[-1].get('id') != n.get('id'):
                    results.append(n)
                    continue

    # Deduplicate
    seen = set()
    deduped = []
    for n in results:
        nid = str(n.get('id', ''))
        if nid and nid not in seen:
            seen.add(nid)
            deduped.append(n)

    return deduped[:max_results]


def find_path(graph: dict, source: str, target: str, **kwargs) -> list[dict]:
    """Find the shortest path between two nodes by id or label.

    Args:
        graph: Graph dict.
        source: Starting node id or label substring.
        target: Ending node id or label substring.

    Returns:
        List of edge dicts forming the path, or empty list.
    """
    max_depth = kwargs.get('max_depth', 10)

    nodes = graph.get('nodes', [])
    edges = graph.get('edges', [])

    # Resolve node ids from labels if needed
    node_by_id = {}
    id_by_label = {}
    for n in nodes:
        nid = str(n.get('id', ''))
        if nid:
            node_by_id[nid] = n
        label = str(n.get('label', '') or '').lower()
        if label and nid:
            id_by_label.setdefault(label, nid)

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
    adj = {}
    for e in edges:
        src = str(e.get('from', e.get('source', '')))
        dst = str(e.get('to', e.get('target', '')))
        lbl = str(e.get('label', ''))
        if src and dst:
            adj.setdefault(src, []).append((dst, lbl, e))
            adj.setdefault(dst, []).append((src, lbl, e))

    visited = {src_id}
    queue = deque([(src_id, [])])
    while queue:
        current, path_edges = queue.popleft()
        if current == tgt_id:
            return path_edges
        if len(path_edges) >= max_depth:
            continue
        for neighbor, lbl, edge in adj.get(current, []):
            if neighbor not in visited:
                visited.add(neighbor)
                queue.append((neighbor, path_edges + [edge]))

    return []


def explain_node(graph: dict, node_id: str) -> dict:
    """Describe a node's connections, type, and role in the graph.

    Args:
        graph: Graph dict.
        node_id: Node id or label substring.

    Returns:
        Dict with node info, connections, and centrality context.
    """
    nodes = graph.get('nodes', [])
    edges = graph.get('edges', [])

    # Find node
    target = None
    for n in nodes:
        nid = str(n.get('id', ''))
        if nid == node_id:
            target = n
            break
    if not target:
        # Try label match
        for n in nodes:
            if node_id.lower() in str(n.get('label', '') or '').lower():
                target = n
                break

    if not target:
        return {'error': f'Node "{node_id}" not found'}

    nid = str(target.get('id', ''))
    outbound = []
    inbound = []

    for e in edges:
        src = str(e.get('from', e.get('source', '')))
        dst = str(e.get('to', e.get('target', '')))
        lbl = str(e.get('label', ''))
        conf = e.get('confidence', 'INFERRED')

        if src == nid:
            outbound.append({
                'target': dst,
                'label': lbl,
                'confidence': conf,
                'semantic_score': e.get('semantic_score'),
            })
        elif dst == nid:
            inbound.append({
                'source': src,
                'label': lbl,
                'confidence': conf,
                'semantic_score': e.get('semantic_score'),
            })

    # Build label lookup
    label_map = {}
    for n in nodes:
        label_map[str(n.get('id', ''))] = str(n.get('label', str(n.get('id', ''))))

    # Resolve neighbor labels
    for item in outbound:
        item['target_label'] = label_map.get(item['target'], item['target'])
    for item in inbound:
        item['source_label'] = label_map.get(item['source'], item['source'])

    return {
        'node': {
            'id': nid,
            'label': str(target.get('label', '')),
            'type': str(target.get('type', '')),
            'content_preview': str(target.get('content_preview', '')),
        },
        'outbound_connections': outbound,
        'inbound_connections': inbound,
        'total_connections': len(outbound) + len(inbound),
        'outbound_count': len(outbound),
        'inbound_count': len(inbound),
    }


def format_explain(explanation: dict) -> str:
    """Format an explain_node result as human-readable text."""
    if 'error' in explanation:
        return f'Error: {explanation["error"]}'

    node = explanation['node']
    lines = [
        f'Node: {node["label"]} ({node["id"]})',
        f'Type: {node["type"]}',
        f'Connections: {explanation["total_connections"]} '
        f'({explanation["outbound_count"]} out, {explanation["inbound_count"]} in)',
    ]

    if node.get('content_preview'):
        lines.append(f'Preview: {node["content_preview"]}')

    if explanation['outbound_connections']:
        lines.append('')
        lines.append('Outbound:')
        for c in explanation['outbound_connections']:
            score = f' [{c.get("semantic_score")}]' if c.get('semantic_score') else ''
            conf = f' ({c["confidence"]})' if c.get('confidence') else ''
            lines.append(f'  → {c["target_label"]} ({c["label"]}){score}{conf}')

    if explanation['inbound_connections']:
        lines.append('')
        lines.append('Inbound:')
        for c in explanation['inbound_connections']:
            score = f' [{c.get("semantic_score")}]' if c.get('semantic_score') else ''
            conf = f' ({c["confidence"]})' if c.get('confidence') else ''
            lines.append(f'  ← {c["source_label"]} ({c["label"]}){score}{conf}')

    return '\n'.join(lines)


def format_path(path_edges: list[dict]) -> str:
    """Format a find_path result as human-readable text."""
    if not path_edges:
        return 'No path found'

    lines = ['Path:']
    for e in path_edges:
        src = str(e.get('from', e.get('source', '')))
        dst = str(e.get('to', e.get('target', '')))
        lbl = str(e.get('label', ''))
        conf = e.get('confidence', '')
        score = e.get('semantic_score', '')
        details = f' ({conf})' if conf else ''
        details += f' [{score}]' if score else ''
        lines.append(f'  {src} → {dst}: {lbl}{details}')

    return '\n'.join(lines)
