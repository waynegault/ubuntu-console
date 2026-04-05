"""Graph projection engine.

Exports project_graph() — the central graph transformation engine that
projects a raw graph into cleaner views (overview, topics, files,
semantic, raw). The nested enrich_graph_payload() function is kept
inside project_graph as in the original.
"""
import re
import json
from .constants import normalize_canonical_name
from .life_index import load_life_index


def project_graph(graph: dict, mode: str = 'overview', semantic_threshold: float = 0.82) -> dict:
    """Project a raw graph into a cleaner view for browsing.

    Modes:
      - overview: curated operational summary; suppress low-signal detail
      - files: keep only file-level structure
      - topics: keep topic/actor/file relationships
      - semantic: aggressively curated semantic-only view
      - raw: return graph unchanged
    """
    mode = (mode or 'overview').lower()
    if mode == 'raw':
        return graph

    nodes = graph.get('nodes', []) or []
    edges = graph.get('edges', []) or []
    node_by_id = {str(n.get('id')): dict(n) for n in nodes if n.get('id') is not None}

    curated_edge_labels = {'covers topic', 'mentions actor', 'authored by', 'references file', 'file mentions actor', 'file authored by', 'has project', 'has decision', 'has issue', 'has outcome'}
    weak_node_labels = {
        'created', 'updated', 'watched', 'watch', 'identified', 'audited', 'added', 'removed', 'fixed', 'changed',
        'summary', 'overview', 'context', 'details', 'notes', 'status', 'result', 'results', 'outcome', 'outcomes',
        'current state', 'important technical state', 'key decisions', 'next steps', 'next actions', 'open threads',
        'work', 'project', 'issue', 'decision', 'topic', 'outcome', 'memory stack', 'graph quality'
    }

    def node_visibility(node: dict) -> str:
        return str(node.get('visibility', node.get('view_visibility', 'both')) or 'both').lower()

    def node_quality(node: dict) -> str:
        return str(node.get('quality_tier', node.get('quality', 'semantic')) or 'semantic').lower()

    def edge_visibility(edge: dict) -> str:
        return str(edge.get('visibility', edge.get('view_visibility', 'both')) or 'both').lower()

    def edge_quality(edge: dict) -> str:
        return str(edge.get('quality_tier', edge.get('quality', 'semantic')) or 'semantic').lower()

    def is_weak_label(label: str) -> bool:
        return str(label or '').strip().lower() in weak_node_labels

    semantic_core_types = {'actor', 'topic', 'summary', 'project', 'decision', 'issue', 'outcome', 'person', 'organization', 'place'}

    def is_curated_node(node: dict) -> bool:
        ntype = str(node.get('type', '') or '').lower()
        label = str(node.get('label', '') or '').strip().lower()
        visibility = node_visibility(node)
        quality = node_quality(node)
        path = str(node.get('path', '') or '').lower()
        if visibility == 'raw' or quality == 'supporting':
            return False
        if ntype == 'file' and re.search(r'(?:^|/)(?:fact-|preference-|decision-|reflection-)', path):
            return False
        if ntype in semantic_core_types or ntype == 'file':
            return True
        if label and not is_weak_label(label):
            return True
        return False

    effective_semantic_threshold = max(0.58, min(0.9, 0.58 + ((semantic_threshold - 0.5) * 0.6)))

    def is_curated_edge(edge: dict) -> bool:
        label = str(edge.get('label', '') or '')
        visibility = edge_visibility(edge)
        quality = edge_quality(edge)
        if visibility == 'raw' or quality == 'supporting':
            return False
        if label in curated_edge_labels or label == 'semantic summary' or label.startswith('summarizes '):
            return True
        if label.startswith('related') and edge.get('semantic_score') is not None:
            try:
                return float(edge.get('semantic_score')) >= effective_semantic_threshold
            except (TypeError, ValueError):
                return False
        return False

    def edge_endpoints(edge: dict) -> tuple[str | None, str | None]:
        src = edge.get('from', edge.get('source'))
        dst = edge.get('to', edge.get('target'))
        return (str(src) if src is not None else None, str(dst) if dst is not None else None)

    def node_type(node_id: str | None) -> str:
        if node_id is None:
            return ''
        return str(node_by_id.get(node_id, {}).get('type', ''))

    def file_from_chunk(node_id: str | None) -> str | None:
        if node_id is None:
            return None
        for edge in edges:
            src, dst = edge_endpoints(edge)
            label = str(edge.get('label', ''))
            if label != 'contains chunk':
                continue
            if dst == node_id and node_type(src) == 'file':
                return src
        return None

    def dedupe_append(out_edges: list, seen: set, source: str | None, target: str | None, label: str, payload: dict | None = None):
        if not source or not target:
            return
        key = (source, target, label)
        if key in seen:
            return
        seen.add(key)
        item = {'from': source, 'to': target, 'label': label}
        if payload:
            item.update(payload)
        out_edges.append(item)

    def enrich_graph_payload(projected: dict, current_mode: str) -> dict:
        out = {
            'nodes': [dict(n) for n in (projected.get('nodes', []) or [])],
            'edges': [dict(e) for e in (projected.get('edges', []) or [])],
        }

        def edge_strength_value(edge: dict) -> float:
            try:
                semantic_score = float(edge.get('semantic_score', 0) or 0)
            except (TypeError, ValueError):
                semantic_score = 0.0
            try:
                cooccurrence = int(edge.get('cooccurrence_count', 0) or 0)
            except (TypeError, ValueError):
                cooccurrence = 0
            label = str(edge.get('label', '') or '').strip().lower()
            base = semantic_score
            if label in {'project decision', 'project issue', 'decision addresses issue', 'decision drives outcome'}:
                base = max(base, 0.95)
            elif label in {'project outcome', 'issue affects outcome', 'project owner'}:
                base = max(base, 0.88)
            elif label in {'project topic', 'topic decision', 'topic issue', 'topic outcome', 'actor decision', 'actor issue', 'actor outcome'}:
                base = max(base, 0.76)
            base += min(0.08, 0.02 * cooccurrence)
            return round(min(base, 0.99), 3)

        life_index = load_life_index()

        def normalized_semantic_label(node: dict) -> str:
            label = str(node.get('label', '') or '').strip().lower()
            if not label:
                return ''
            label = re.sub(r'\b(?:the|a|an)\b', ' ', label)
            label = re.sub(r'\b(?:current|important|main|primary|semantic|visual|layout)\b', ' ', label)
            label = re.sub(r'[^a-z0-9\s-]', ' ', label)
            label = re.sub(r'\s+', ' ', label).strip(' .:-')
            semantic_aliases = {
                'graph layout': 'graph quality',
                'layout quality': 'graph quality',
                'semantic graph': 'graph quality',
                'semantic threshold': 'semantic filtering',
                'semantic thresholding': 'semantic filtering',
                'topic cleanup': 'topic structure',
                'topics projection': 'topic structure',
                'topics mode': 'topic structure',
                'label cleanup': 'semantic naming',
                'naming cleanup': 'semantic naming',
            }
            for alias, canonical in semantic_aliases.items():
                if label == alias or alias in label:
                    label = canonical
                    break
            record = life_index.get('aliases', {}).get(label)
            if record:
                return str(record.get('title', label)).strip().lower()
            canonical_title = life_index.get('title_aliases', {}).get(label)
            if canonical_title:
                return str(canonical_title).strip().lower()
            return label

        def collapse_semantic_duplicates(graph_out: dict, allowed_types: set[str]) -> None:
            nodes_local = graph_out.get('nodes', []) or []
            edges_local = graph_out.get('edges', []) or []
            canonical_for = {}
            label_groups = {}
            for node in nodes_local:
                nid = str(node.get('id', '') or '')
                ntype = str(node.get('type', '') or '').lower()
                if not nid or ntype not in allowed_types:
                    continue
                norm = normalized_semantic_label(node)
                if not norm or len(norm) < 4:
                    continue
                key = (ntype, norm)
                label_groups.setdefault(key, []).append(node)
            for members in label_groups.values():
                if len(members) < 2:
                    continue
                members_sorted = sorted(
                    members,
                    key=lambda n: (
                        int(bool(n.get('inferred_type'))),
                        -float(n.get('type_confidence', 1.0) or 1.0),
                        -len(str(n.get('label', '') or '')),
                        str(n.get('id', '') or ''),
                    )
                )
                canonical = str(members_sorted[0].get('id'))
                for node in members_sorted:
                    canonical_for[str(node.get('id'))] = canonical
            if not canonical_for:
                return
            deduped_nodes = []
            seen_nodes = set()
            for node in nodes_local:
                nid = str(node.get('id', '') or '')
                cid = canonical_for.get(nid, nid)
                if cid != nid:
                    continue
                if cid in seen_nodes:
                    continue
                seen_nodes.add(cid)
                deduped_nodes.append(node)
            deduped_edges = []
            seen_edges = set()
            for edge in edges_local:
                src, dst = edge_endpoints(edge)
                src = canonical_for.get(src or '', src or '')
                dst = canonical_for.get(dst or '', dst or '')
                if not src or not dst or src == dst:
                    continue
                label = str(edge.get('label', '') or '')
                key = (src, dst, label)
                if key in seen_edges:
                    continue
                seen_edges.add(key)
                new_edge = dict(edge)
                new_edge['from'] = src
                new_edge['to'] = dst
                deduped_edges.append(new_edge)
            graph_out['nodes'] = deduped_nodes
            graph_out['edges'] = deduped_edges
        if current_mode in {'overview', 'topics', 'semantic'}:
            collapse_semantic_duplicates(out, {'topic', 'project', 'decision', 'issue', 'outcome', 'organization', 'place', 'person'})

        if current_mode in {'topics', 'semantic'}:
            canonical_anchor_types = {'project', 'decision', 'issue', 'outcome', 'workflow', 'system', 'repo'}
            canonical_anchor_labels = {
                normalized_semantic_label(n)
                for n in out['nodes']
                if str(n.get('type', '') or '').lower() in canonical_anchor_types
            }
            node_lookup = {str(n.get('id')): n for n in out['nodes'] if n.get('id') is not None}
            semantic_edges = []
            supporting_edges = []
            for edge in out['edges']:
                src, dst = edge_endpoints(edge)
                if not src or not dst or src not in node_lookup or dst not in node_lookup:
                    continue
                if edge.get('semantic_score') is not None or str(edge.get('label', '') or '').lower() in {
                    'project decision', 'project issue', 'project outcome', 'project topic', 'project owner',
                    'decision addresses issue', 'decision drives outcome', 'issue affects outcome',
                    'topic decision', 'topic issue', 'topic outcome', 'actor decision', 'actor issue', 'actor outcome'
                }:
                    semantic_edges.append(dict(edge))
                else:
                    supporting_edges.append(dict(edge))

            degree = {}
            scored_edges = []
            for edge in semantic_edges:
                src, dst = edge_endpoints(edge)
                strength = edge_strength_value(edge)
                src_node = node_lookup.get(src, {})
                dst_node = node_lookup.get(dst, {})
                src_label = normalized_semantic_label(src_node)
                dst_label = normalized_semantic_label(dst_node)
                src_type = str(src_node.get('type', '') or '').lower()
                dst_type = str(dst_node.get('type', '') or '').lower()
                label = str(edge.get('label', '') or '').lower()
                if label == 'semantic related':
                    if src_label in {'workspace', 'openclaw', 'gateway', 'engram', 'wayne', 'hal'} or dst_label in {'workspace', 'openclaw', 'gateway', 'engram', 'wayne', 'hal'}:
                        strength = min(strength, 0.52)
                    if canonical_anchor_labels and src_type not in canonical_anchor_types and dst_type not in canonical_anchor_types:
                        strength = min(strength, 0.62)
                if src_label in canonical_anchor_labels or dst_label in canonical_anchor_labels:
                    strength = min(0.99, strength + 0.06)
                edge['_strength'] = strength
                degree[src] = degree.get(src, 0) + 1
                degree[dst] = degree.get(dst, 0) + 1
                scored_edges.append(edge)

            neighbor_budget = {}
            for nid, deg in degree.items():
                if current_mode == 'semantic':
                    neighbor_budget[nid] = 4 if deg >= 10 else (5 if deg >= 7 else 6)
                else:
                    neighbor_budget[nid] = 5 if deg >= 10 else (6 if deg >= 7 else 7)

            kept_semantic = []
            kept_counts = {}
            seen_pairs = set()
            scored_edges_sorted = sorted(
                scored_edges,
                key=lambda e: (e.get('_strength', 0), e.get('cooccurrence_count', 0), str(e.get('label', ''))),
                reverse=True,
            )
            for edge in scored_edges_sorted:
                src, dst = edge_endpoints(edge)
                if not src or not dst:
                    continue
                pair = tuple(sorted((src, dst)))
                if pair in seen_pairs:
                    continue
                src_deg = degree.get(src, 0)
                dst_deg = degree.get(dst, 0)
                strength = float(edge.get('_strength', 0) or 0)
                threshold = 0.68
                if max(src_deg, dst_deg) >= 10:
                    threshold = 0.78 if current_mode == 'semantic' else 0.75
                elif max(src_deg, dst_deg) >= 7:
                    threshold = 0.73 if current_mode == 'semantic' else 0.71
                if strength < threshold:
                    continue
                if kept_counts.get(src, 0) >= neighbor_budget.get(src, 6) or kept_counts.get(dst, 0) >= neighbor_budget.get(dst, 6):
                    if strength < 0.88:
                        continue
                seen_pairs.add(pair)
                kept_counts[src] = kept_counts.get(src, 0) + 1
                kept_counts[dst] = kept_counts.get(dst, 0) + 1
                kept_semantic.append(edge)

            if current_mode == 'semantic' and len(kept_semantic) < 3 and scored_edges_sorted:
                fallback_counts = {}
                fallback_pairs = set()
                fallback_edges = []
                for edge in scored_edges_sorted[:24]:
                    src, dst = edge_endpoints(edge)
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

            connected_ids = set()
            for edge in kept_semantic:
                src, dst = edge_endpoints(edge)
                if src:
                    connected_ids.add(src)
                if dst:
                    connected_ids.add(dst)
            for nid, node in node_lookup.items():
                ntype = str(node.get('type', '') or '').lower()
                if ntype in canonical_anchor_types and normalized_semantic_label(node) in canonical_anchor_labels:
                    connected_ids.add(nid)

            filtered_nodes = []
            for node in out['nodes']:
                nid = str(node.get('id', '') or '')
                ntype = str(node.get('type', '') or '').lower()
                if nid in connected_ids or ntype in {'actor'}:
                    filtered_nodes.append(node)
                elif current_mode == 'topics' and ntype in {'topic', 'project', 'decision', 'issue', 'outcome'} and degree.get(nid, 0) > 0:
                    filtered_nodes.append(node)
                elif current_mode != 'semantic' and ntype in {'topic', 'project', 'decision', 'issue', 'outcome'} and adjacency.get(nid, 0) > 0:
                    filtered_nodes.append(node)

            out['nodes'] = filtered_nodes
            out['edges'] = [
                {k: v for k, v in edge.items() if k != '_strength'}
                for edge in (kept_semantic + supporting_edges)
                if (edge_endpoints(edge)[0] in {str(n.get('id')) for n in out['nodes']} and edge_endpoints(edge)[1] in {str(n.get('id')) for n in out['nodes']})
            ]

        adjacency = {}
        semantic_degree = {}
        type_counts = {}
        cluster_suggestions = []

        for edge in out['edges']:
            src, dst = edge_endpoints(edge)
            if src:
                adjacency[src] = adjacency.get(src, 0) + 1
            if dst:
                adjacency[dst] = adjacency.get(dst, 0) + 1
            if edge.get('semantic_score') is not None:
                if src:
                    semantic_degree[src] = semantic_degree.get(src, 0) + 1
                if dst:
                    semantic_degree[dst] = semantic_degree.get(dst, 0) + 1

        for node in out['nodes']:
            ntype = str(node.get('type', 'unknown') or 'unknown').lower()
            type_counts[ntype] = type_counts.get(ntype, 0) + 1

        importance_by_id = {}
        for node in out['nodes']:
            nid = str(node.get('id', ''))
            degree = adjacency.get(nid, 0)
            sdegree = semantic_degree.get(nid, 0)
            importance_by_id[nid] = max(1, degree + (2 * sdegree))

        top_label_nodes = set()
        if current_mode in {'topics', 'semantic'}:
            ranked_ids = sorted(importance_by_id.keys(), key=lambda nid: importance_by_id.get(nid, 0), reverse=True)
            limit = 18 if current_mode == 'semantic' else 24
            top_label_nodes = set(ranked_ids[:limit])

        for node in out['nodes']:
            nid = str(node.get('id', ''))
            ntype = str(node.get('type', '') or '').lower()
            degree = adjacency.get(nid, 0)
            sdegree = semantic_degree.get(nid, 0)
            node['degree'] = degree
            node['semantic_degree'] = sdegree
            node['importance'] = importance_by_id.get(nid, 1)
            node['display_group'] = ntype or 'unknown'
            if current_mode == 'overview':
                if ntype == 'file':
                    node['display_label'] = ''
                    node['visual_role'] = 'provenance'
                elif ntype in {'actor', 'topic', 'summary', 'project', 'decision', 'issue', 'outcome'}:
                    node['display_label'] = (node.get('label') or nid)[:56]
                else:
                    node['display_label'] = node.get('label') or nid
            elif current_mode == 'semantic':
                raw_label = str(node.get('label') or nid)
                if ntype == 'file' or re.match(r'^\d{4}-\d{2}-\d{2}\.md$', raw_label) or raw_label.lower() in {'memory.md', 'profile.md'}:
                    node['display_label'] = ''
                    node['visual_role'] = 'provenance'
                elif nid not in top_label_nodes and node['importance'] < 6:
                    node['display_label'] = ''
                elif ntype == 'summary':
                    node['display_label'] = raw_label[:40]
                elif ntype == 'topic':
                    node['display_label'] = raw_label[:22]
                elif ntype in {'project', 'decision', 'issue', 'outcome'}:
                    node['display_label'] = raw_label[:34]
                else:
                    node['display_label'] = raw_label[:26]
            elif current_mode == 'topics':
                raw_label = str(node.get('label') or nid)
                if nid not in top_label_nodes and node['importance'] < 5:
                    node['display_label'] = ''
                elif ntype == 'topic':
                    node['display_label'] = raw_label[:24]
                elif ntype in {'project', 'decision', 'issue', 'outcome'}:
                    node['display_label'] = raw_label[:32]
                else:
                    node['display_label'] = raw_label[:24]

        if current_mode == 'semantic':
            semantic_adj = {}
            semantic_nodes = {str(n.get('id')): n for n in out['nodes'] if n.get('id') is not None}
            strong_relation_labels = {
                'project decision', 'project issue', 'decision addresses issue', 'decision drives outcome',
                'project outcome', 'issue affects outcome', 'project owner'
            }
            medium_relation_labels = {
                'project topic', 'topic decision', 'topic issue', 'topic outcome',
                'actor decision', 'actor issue', 'actor outcome'
            }
            for edge in out['edges']:
                src, dst = edge_endpoints(edge)
                if not src or not dst or src not in semantic_nodes or dst not in semantic_nodes:
                    continue
                label = str(edge.get('label', '') or '').strip().lower()
                try:
                    semantic_score = float(edge.get('semantic_score', 0) or 0)
                except (TypeError, ValueError):
                    semantic_score = 0.0
                try:
                    cooccurrence = int(edge.get('cooccurrence_count', 0) or 0)
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

            visited = set()
            weak_cluster_labels = {'graph quality', 'repo cleanup', 'env bridge', 'semantic filtering', 'copilot token'}
            preferred_cluster_types = ('project', 'issue', 'decision', 'outcome', 'topic', 'actor', 'person', 'organization', 'place')
            for nid in semantic_nodes:
                if nid in visited or nid not in semantic_adj:
                    continue
                stack = [nid]
                component = []
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
                ranked = sorted(
                    component,
                    key=lambda cid: (
                        semantic_nodes[cid].get('semantic_degree', 0),
                        semantic_nodes[cid].get('importance', 0),
                        semantic_nodes[cid].get('degree', 0),
                        len(str(semantic_nodes[cid].get('label', '') or ''))
                    ),
                    reverse=True,
                )
                label_parts = []
                chosen_types = set()
                for preferred_type in preferred_cluster_types:
                    for cid in ranked:
                        node = semantic_nodes[cid]
                        label = str(node.get('label', '') or '').strip()
                        if not label:
                            continue
                        lowered = label.lower()
                        if lowered in weak_cluster_labels:
                            continue
                        node_type = str(node.get('type', '') or '').lower()
                        if node_type != preferred_type or node_type in chosen_types:
                            continue
                        if lowered in [x.lower() for x in label_parts]:
                            continue
                        label_parts.append(label)
                        chosen_types.add(node_type)
                        break
                    if len(label_parts) >= 2:
                        break
                if not label_parts:
                    for cid in ranked:
                        label = str(semantic_nodes[cid].get('label', '') or '').strip()
                        if not label:
                            continue
                        lowered = label.lower()
                        if lowered in weak_cluster_labels:
                            continue
                        if lowered not in [x.lower() for x in label_parts]:
                            label_parts.append(label)
                        if len(label_parts) >= 2:
                            break
                if len(label_parts) >= 2:
                    primary = label_parts[0]
                    secondary = label_parts[1]
                    cluster_label = f'{primary} · {secondary}'
                elif label_parts:
                    dominant_type = str(semantic_nodes[ranked[0]].get('type', '') or '').lower() if ranked else ''
                    type_hint = dominant_type if dominant_type and dominant_type not in {'topic', 'actor'} else 'cluster'
                    cluster_label = f'{label_parts[0]} ({type_hint})'
                else:
                    cluster_label = f'cluster {len(cluster_suggestions) + 1}'
                cluster_suggestions.append({
                    'id': f'semantic_cluster_{len(cluster_suggestions) + 1}',
                    'label': cluster_label[:64],
                    'members': component,
                    'size': len(component),
                })

        out['_meta'] = dict(out.get('_meta', {}))
        out['_meta']['typeCounts'] = type_counts
        out['_meta']['nodeCount'] = len(out['nodes'])
        out['_meta']['edgeCount'] = len(out['edges'])
        if cluster_suggestions:
            out['_meta']['clusterSuggestions'] = cluster_suggestions
        return out

    if mode == 'semantic':
        keep_edges = []
        keep_nodes = set()
        seen = set()
        concept_types = {'topic', 'project', 'decision', 'issue', 'outcome', 'actor', 'person', 'organization', 'place', 'chunk'}
        anchor_types = {'project', 'decision', 'issue', 'outcome'}
        preferred_semantic_types = {'project', 'decision', 'issue', 'outcome', 'actor', 'person', 'organization', 'place', 'chunk'}
        life_index = load_life_index()
        concept_nodes = {}
        summary_to_concepts = {}
        chunk_to_concepts = {}
        concept_to_summaries = {}
        concept_to_chunks = {}
        inferred_scores = {}

        def semantic_node_ok(node: dict) -> bool:
            if not node:
                return False
            ntype = str(node.get('type', '') or '').lower()
            if ntype not in concept_types:
                return False
            if not is_curated_node(node):
                return False
            if ntype == 'topic' and is_weak_label(node.get('label', '')):
                return False
            return True

        def apply_canonical_semantic_bias(node: dict) -> dict:
            if not node:
                return node
            updated = dict(node)
            raw_label = str(updated.get('label', '') or '').strip()
            if not raw_label:
                return updated
            norm = re.sub(r'\s+', ' ', raw_label.lower()).strip()
            record = life_index.get('aliases', {}).get(norm)
            if not record:
                return updated
            updated['label'] = str(record.get('title') or raw_label)
            record_type = str(record.get('type', '') or '').lower()
            current_type = str(updated.get('type', '') or '').lower()
            if record_type in concept_types and current_type == 'topic':
                updated['type'] = record_type
                updated['inferred_type'] = record_type
                updated['type_confidence'] = max(float(updated.get('type_confidence', 0.0) or 0.0), 0.96)
            updated['canonical_slug'] = str(record.get('slug') or '')
            updated['canonical_path'] = str(record.get('path') or '')
            return updated

        for nid, node in node_by_id.items():
            if semantic_node_ok(node):
                concept_nodes[nid] = apply_canonical_semantic_bias(node)

        direct_edges = []
        for edge in edges:
            src, dst = edge_endpoints(edge)
            src_node = node_by_id.get(src or '')
            dst_node = node_by_id.get(dst or '')
            if not src_node or not dst_node:
                continue
            src_type = str(src_node.get('type', '') or '').lower()
            dst_type = str(dst_node.get('type', '') or '').lower()

            if src in concept_nodes and dst in concept_nodes:
                payload = {}
                if edge.get('semantic_score') is not None:
                    try:
                        payload['semantic_score'] = round(float(edge.get('semantic_score') or 0), 3)
                    except (TypeError, ValueError):
                        pass
                label = str(edge.get('label', '') or '').strip().lower()
                if is_curated_edge(edge) or label in {
                    'project decision', 'project issue', 'project outcome', 'project topic', 'project owner',
                    'decision addresses issue', 'decision drives outcome', 'issue affects outcome',
                    'topic decision', 'topic issue', 'topic outcome', 'actor decision', 'actor issue', 'actor outcome'
                }:
                    direct_edges.append((src, dst, edge.get('label', 'related'), payload))
                continue

            if src_type == 'summary' and dst in concept_nodes:
                summary_to_concepts.setdefault(src, set()).add(dst)
                concept_to_summaries.setdefault(dst, set()).add(src)
                continue
            if dst_type == 'summary' and src in concept_nodes:
                summary_to_concepts.setdefault(dst, set()).add(src)
                concept_to_summaries.setdefault(src, set()).add(dst)
                continue

            if src_type == 'chunk' and dst in concept_nodes:
                chunk_to_concepts.setdefault(src, set()).add(dst)
                concept_to_chunks.setdefault(dst, set()).add(src)
                continue
            if dst_type == 'chunk' and src in concept_nodes:
                chunk_to_concepts.setdefault(dst, set()).add(src)
                concept_to_chunks.setdefault(src, set()).add(dst)
                continue

        for members in summary_to_concepts.values():
            member_list = sorted(members)
            if len(member_list) < 2:
                continue
            for i, a in enumerate(member_list):
                for b in member_list[i + 1:]:
                    pair = tuple(sorted((a, b)))
                    inferred_scores.setdefault(pair, {'summary': 0, 'chunk': 0})
                    inferred_scores[pair]['summary'] += 1

        for members in chunk_to_concepts.values():
            member_list = sorted(members)
            if len(member_list) < 2:
                continue
            for i, a in enumerate(member_list):
                for b in member_list[i + 1:]:
                    pair = tuple(sorted((a, b)))
                    inferred_scores.setdefault(pair, {'summary': 0, 'chunk': 0})
                    inferred_scores[pair]['chunk'] += 1

        node_strength = {}
        for nid, node in concept_nodes.items():
            ntype = str(node.get('type', '') or '').lower()
            strength = 1.0
            if ntype in anchor_types:
                strength += 3.0
            elif ntype in preferred_semantic_types:
                strength += 2.0
            strength += min(2.5, 0.7 * len(concept_to_summaries.get(nid, set())))
            strength += min(2.0, 0.45 * len(concept_to_chunks.get(nid, set())))
            conf = float(node.get('type_confidence', 1.0) or 1.0)
            strength += max(0.0, conf - 0.75)
            if node.get('inferred_type'):
                strength -= 0.25
            node_strength[nid] = round(strength, 3)

        direct_pairs = set()
        for src, dst, label, payload in sorted(direct_edges, key=lambda item: (
            float((item[3] or {}).get('semantic_score', 0) or 0),
            node_strength.get(item[0], 0) + node_strength.get(item[1], 0)
        ), reverse=True):
            dedupe_append(keep_edges, seen, src, dst, label, payload or None)
            direct_pairs.add(tuple(sorted((src, dst))))
            keep_nodes.add(src)
            keep_nodes.add(dst)

        inferred_edge_candidates = []
        for (a, b), support in inferred_scores.items():
            a_node = concept_nodes.get(a)
            b_node = concept_nodes.get(b)
            if not a_node or not b_node:
                continue
            a_type = str(a_node.get('type', '') or '').lower()
            b_type = str(b_node.get('type', '') or '').lower()
            summary_support = int(support.get('summary', 0) or 0)
            chunk_support = int(support.get('chunk', 0) or 0)
            if summary_support <= 0 and chunk_support <= 0:
                continue
            score = 0.0
            score += min(0.5, 0.18 * summary_support)
            score += min(0.35, 0.12 * chunk_support)
            if a_type in anchor_types or b_type in anchor_types:
                score += 0.12
            if a_type == b_type and a_type == 'topic':
                score -= 0.08
            if a_type == 'topic' or b_type == 'topic':
                score -= 0.03
            score += min(0.2, 0.02 * (node_strength.get(a, 0) + node_strength.get(b, 0)))
            if score < 0.36:
                continue
            inferred_edge_candidates.append((
                a,
                b,
                'semantic related',
                {
                    'semantic_score': round(min(score, 0.95), 3),
                    'cooccurrence_count': summary_support + chunk_support,
                    'inferred': True,
                    'support_summary_count': summary_support,
                    'support_chunk_count': chunk_support,
                }
            ))

        inferred_edge_candidates.sort(
            key=lambda item: (
                float((item[3] or {}).get('semantic_score', 0) or 0),
                (item[3] or {}).get('cooccurrence_count', 0),
                node_strength.get(item[0], 0) + node_strength.get(item[1], 0)
            ),
            reverse=True,
        )

        inferred_neighbor_counts = {}
        for src, dst, label, payload in inferred_edge_candidates:
            pair = tuple(sorted((src, dst)))
            if pair in direct_pairs:
                continue
            src_budget = 4 if node_strength.get(src, 0) >= 5.5 else 3
            dst_budget = 4 if node_strength.get(dst, 0) >= 5.5 else 3
            if inferred_neighbor_counts.get(src, 0) >= src_budget or inferred_neighbor_counts.get(dst, 0) >= dst_budget:
                if float((payload or {}).get('semantic_score', 0) or 0) < 0.72:
                    continue
            dedupe_append(keep_edges, seen, src, dst, label, payload or None)
            keep_nodes.add(src)
            keep_nodes.add(dst)
            inferred_neighbor_counts[src] = inferred_neighbor_counts.get(src, 0) + 1
            inferred_neighbor_counts[dst] = inferred_neighbor_counts.get(dst, 0) + 1

        if len(keep_edges) < 6:
            for nid, _score in sorted(node_strength.items(), key=lambda item: item[1], reverse=True)[:18]:
                keep_nodes.add(nid)
            fallback_pairs = []
            for a, b, label, payload in inferred_edge_candidates:
                fallback_pairs.append((a, b, label, payload))
                if len(fallback_pairs) >= 18:
                    break
            if not fallback_pairs:
                strong_nodes = [nid for nid, _score in sorted(node_strength.items(), key=lambda item: item[1], reverse=True)[:10]]
                for idx, src in enumerate(strong_nodes):
                    for dst in strong_nodes[idx + 1: idx + 3]:
                        if src == dst:
                            continue
                        fallback_pairs.append((src, dst, 'semantic related', {'semantic_score': 0.42, 'inferred': True, 'fallback': True}))
                        if len(fallback_pairs) >= 10:
                            break
                    if len(fallback_pairs) >= 10:
                        break
            for src, dst, label, payload in fallback_pairs:
                score = float((payload or {}).get('semantic_score', 0) or 0)
                if score < semantic_threshold:
                    continue
                dedupe_append(keep_edges, seen, src, dst, label, payload or None)
                keep_nodes.add(src)
                keep_nodes.add(dst)

        if not keep_nodes:
            for nid, _score in sorted(node_strength.items(), key=lambda item: item[1], reverse=True)[:14]:
                keep_nodes.add(nid)

        return enrich_graph_payload({
            'nodes': [node_by_id[nid] for nid in keep_nodes if nid in node_by_id],
            'edges': keep_edges,
        }, mode)

    out_nodes = {}
    out_edges = []
    seen_edges = set()

    def keep_node(nid: str | None):
        if nid and nid in node_by_id:
            out_nodes[nid] = node_by_id[nid]

    if mode == 'files':
        for nid, node in node_by_id.items():
            if str(node.get('type', '')) == 'file':
                out_nodes[nid] = node
        for edge in edges:
            src, dst = edge_endpoints(edge)
            label = str(edge.get('label', ''))
            if node_type(src) == 'file' and node_type(dst) == 'file':
                dedupe_append(out_edges, seen_edges, src, dst, label)
        return enrich_graph_payload({'nodes': list(out_nodes.values()), 'edges': out_edges}, mode)

    for nid, node in node_by_id.items():
        ntype = str(node.get('type', ''))
        if mode == 'topics':
            if ntype in {'topic', 'actor', 'project', 'decision', 'issue', 'outcome', 'person', 'organization', 'place'}:
                out_nodes[nid] = node
        elif mode == 'semantic':
            # In semantic mode, only include nodes that have semantic relationships
            if ntype in semantic_core_types or ntype in {'chunk', 'actor'}:
                out_nodes[nid] = node
        else:  # overview
            if ntype == 'chunk':
                continue
            if ntype in semantic_core_types:
                out_nodes[nid] = node
                continue
            if ntype == 'file':
                out_nodes[nid] = node
                continue
            if is_curated_node(node):
                out_nodes[nid] = node

    for edge in edges:
        src, dst = edge_endpoints(edge)
        label = str(edge.get('label', ''))
        src_type = node_type(src)
        dst_type = node_type(dst)

        if mode == 'topics':
            if src in out_nodes and dst in out_nodes:
                if label in {'project topic', 'topic decision', 'topic issue', 'topic outcome', 'actor decision', 'actor issue', 'actor outcome', 'project owner', 'project decision', 'project issue', 'project outcome', 'decision addresses issue', 'decision drives outcome', 'issue affects outcome'}:
                    payload = {'semantic_score': edge.get('semantic_score')} if edge.get('semantic_score') is not None else None
                    dedupe_append(out_edges, seen_edges, src, dst, label, payload)
                    continue
                if label in {'covers topic', 'mentions actor', 'authored by'} and src_type != 'file' and dst_type != 'file':
                    dedupe_append(out_edges, seen_edges, src, dst, label)
                    continue
            if src_type == 'chunk' and dst in out_nodes and label in {'covers topic', 'mentions actor', 'authored by', 'has project', 'has decision', 'has issue', 'has outcome', 'has person', 'has organization', 'has place'}:
                continue
            if src in out_nodes and dst_type == 'chunk' and label == 'contains chunk':
                continue
            if src_type == 'chunk' and dst_type == 'file' and label == 'references file':
                continue
        elif mode == 'semantic':
            # In semantic mode, include all edges with semantic_score for later threshold filtering
            if src in out_nodes and dst in out_nodes:
                if edge.get('semantic_score') is not None:
                    payload = {'semantic_score': edge.get('semantic_score')}
                    dedupe_append(out_edges, seen_edges, src, dst, label, payload)
                    continue
        else:  # overview
            if src in out_nodes and dst in out_nodes and label != 'contains chunk':
                if src_type == 'file' and dst_type in {'topic', 'actor', 'project', 'decision', 'issue', 'outcome'} and label in curated_edge_labels:
                    # Prefer chunk-derived lifted structure over direct file fan-out to reduce starbursts.
                    continue
                if not is_curated_edge(edge) and label not in curated_edge_labels:
                    continue
                payload = None
                if edge.get('semantic_score') is not None:
                    payload = {'semantic_score': edge.get('semantic_score')}
                dedupe_append(out_edges, seen_edges, src, dst, label, payload)
                continue
            # Handle chunk-derived edges: lift them to file level
            if src_type == 'chunk' and dst in out_nodes:
                parent_file = file_from_chunk(src)
                if parent_file and parent_file in out_nodes:
                    mapped_label = 'file ' + label if not label.startswith('file ') and label not in {'references file'} else 'references file'
                    if label in {'has project', 'has decision', 'has issue', 'has outcome'}:
                        dedupe_append(out_edges, seen_edges, parent_file, dst, label)
                    elif mapped_label in curated_edge_labels or label in curated_edge_labels:
                        dedupe_append(out_edges, seen_edges, parent_file, dst, mapped_label)
                continue
            if src in out_nodes and dst_type == 'chunk' and label == 'contains chunk':
                continue

    return enrich_graph_payload({'nodes': list(out_nodes.values()), 'edges': out_edges}, mode)
