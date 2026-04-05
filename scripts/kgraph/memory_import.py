"""Memory DB import pipeline.

Exports load_from_memory_db() — the large concept extraction pipeline
that loads nodes/edges from an OpenClaw memory SQLite database,
including topic extraction, actor mentions, semantic analysis, and
embedding-based similarity.
"""
import os
import re
import json
import sqlite3
from .constants import normalize_canonical_name, load_canonical_data
from .life_index import load_life_index


def load_from_memory_db(dbpath: str) -> dict:
    """Load nodes/edges from an OpenClaw memory SQLite DB into graph dict."""
    conn = sqlite3.connect(os.path.expanduser(dbpath))
    cur = conn.cursor()
    graph = {'nodes': [], 'edges': []}
    node_ids = set()
    edge_ids = set()

    def has_table(name: str) -> bool:
        cur.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name=? LIMIT 1", (name,))
        return cur.fetchone() is not None

    def add_node(node: dict):
        node_id = str(node.get('id', ''))
        if not node_id or node_id in node_ids:
            return
        node_ids.add(node_id)
        graph['nodes'].append(node)

    def add_edge(edge: dict):
        source = str(edge.get('from', ''))
        target = str(edge.get('to', ''))
        label = str(edge.get('label', ''))
        edge_key = (source, target, label)
        if not source or not target or edge_key in edge_ids:
            return
        edge_ids.add(edge_key)
        graph['edges'].append(edge)

    # Legacy schema: nodes/edges tables.
    if has_table('nodes') and has_table('edges'):
        try:
            cur.execute("SELECT id, name, canonical_text FROM nodes")
            for row in cur.fetchall():
                nid, name, canonical = row
                label = name or canonical or str(nid)
                add_node({'id': str(nid), 'label': label})
        except sqlite3.Error:
            pass
        try:
            cur.execute("SELECT src_id, dst_id, rel FROM edges")
            for row in cur.fetchall():
                src, dst, rel = row
                add_edge({'from': str(src), 'to': str(dst), 'label': rel or ''})
        except sqlite3.Error:
            pass

    # Current OpenClaw memory schema: files/chunks tables.
    elif has_table('files') and has_table('chunks'):
        life_index = load_life_index()
        file_paths = set()
        file_node_ids = {}
        file_path_by_basename = {}

        def _preview_text(value: str, limit: int = 72) -> str:
            text = (value or '').replace('\n', ' ').replace('\r', ' ').strip()
            text = ' '.join(text.split())
            if len(text) > limit:
                return text[: limit - 1] + '…'
            return text

        def _slug(value: str) -> str:
            return re.sub(r'[^a-z0-9]+', '-', value.lower()).strip('-')

        def add_actor_node(name: str, role: str = '') -> str:
            actor_id = f"actor:{_slug(name)}"
            add_node({
                'id': actor_id,
                'label': name,
                'type': 'actor',
                'role': role,
                'content_preview': role or f'Actor: {name}',
            })
            return actor_id

        def add_topic_node(heading_text: str) -> 'str | None':
            """Create a topic node from a markdown heading; returns id or None for trivial headings."""
            clean = re.sub(r'[^\x00-\x7E]', '', heading_text).strip()
            clean = re.sub(r'\s+', ' ', clean)
            if len(clean) < 4:
                return None
            tid = f'topic:{_slug(clean[:60])}'
            add_node({
                'id': tid,
                'label': clean[:60],
                'type': 'topic',
                'content_preview': clean,
            })
            return tid

        scaffolding_labels = {
            'summary', 'overview', 'context', 'details', 'notes', 'durable notes', 'working style',
            'memory routing', 'memory architecture', 'memory layers', 'core identity', 'what changed',
            'current state', 'important technical state', 'audit findings', 'key decisions', 'rationale',
            'next actions', 'next action', 'next steps', 'next step', 'open threads', 'open thread',
            'open items', 'todo', 'todos', 'status', 'result', 'results', 'outcome', 'outcomes',
            'memory md', 'profile md', 'daily note', 'daily notes', 'semantic', 'files', 'overview', 'raw'
        }
        concept_aliases = {
            'graph quality': 'graph quality',
            'graph layout quality': 'graph quality',
            'layout quality': 'graph quality',
            'semantic graph quality': 'graph quality',
            'semantic graph': 'graph quality',
            'graph layout': 'graph quality',
            'layout readability': 'graph quality',
            'memory stack': 'memory stack',
            'repo cleanup': 'repo cleanup',
            'repository cleanup': 'repo cleanup',
            'clean repo state': 'repo cleanup',
            'history rewrite': 'repo cleanup',
            'force push': 'repo cleanup',
            'git cleanup': 'repo cleanup',
            'git history rewrite': 'repo cleanup',
            'gateway token rotation': 'gateway token rotation',
            'token rotation': 'gateway token rotation',
            'rotate gateway token': 'gateway token rotation',
            'semantic filtering': 'semantic filtering',
            'semantic suppression': 'semantic filtering',
            'semantic projection': 'semantic filtering',
            'semantic decluttering': 'semantic filtering',
            'semantic thresholding': 'semantic filtering',
            'semantic threshold': 'semantic filtering',
            'oauth secret refs': 'oauth secret refs',
            'oauth refs': 'oauth secret refs',
            'secret refs': 'oauth secret refs',
            'oauth ref support': 'oauth secret refs',
            'env bridge': 'env bridge',
            'environment bridge': 'env bridge',
            'windows env bridge': 'env bridge',
            'wsl env bridge': 'env bridge',
            'systemd env bridge': 'env bridge',
            'bridge generation': 'env bridge',
            'copilot token exchange': 'copilot token',
            'github copilot token': 'copilot token',
            'copilot token': 'copilot token',
            'copilot auth': 'copilot token',
            'profile duplication': 'profile deduplication',
            'duplicate profile bullets': 'profile deduplication',
            'profile dedupe': 'profile deduplication',
            'profile deduplication': 'profile deduplication',
            'launcher fix': 'launcher reliability',
            'launcher behavior': 'launcher reliability',
            'oc g launcher': 'launcher reliability',
            'graph source selection': 'semantic source routing',
            'semantic source bug': 'semantic source routing',
            'source routing': 'semantic source routing',
            'naming cleanup': 'semantic naming',
            'node naming': 'semantic naming',
            'label cleanup': 'semantic naming',
            'naming quality': 'semantic naming',
            'synthetic labels': 'semantic naming',
            'topic cleanup': 'topic structure',
            'topics projection': 'topic structure',
            'topics mode': 'topic structure',
        }
        low_value_semantic_concepts = {
            'workspace', 'openclaw', 'gateway', 'engram', 'wayne', 'hal',
            'linux', 'ubuntu', 'windows', 'wsl', 'wsl2', 'systemd'
        }
        canonical_wrapper_terms = {'workspace', 'openclaw', 'gateway', 'engram', 'wayne', 'hal'}

        def canonicalize_concept(kind: str, label: str) -> str | None:
            clean = re.sub(r'[^\x00-\x7E]', '', label or '').strip(' .:-')
            clean = re.sub(r'\s+', ' ', clean)
            if '|' in clean:
                parts = [p.strip() for p in clean.split('|') if p.strip()]
                preferred = []
                for part in parts:
                    lowered = part.lower().strip(' .:-')
                    if lowered.startswith(('issue:', 'decision:', 'outcome:')):
                        preferred.append(re.sub(r'^(?:issue|decision|outcome)\s*:\s*', '', part, flags=re.IGNORECASE).strip())
                    else:
                        preferred.append(part)
                clean = max(preferred, key=lambda p: (len(p.split()), len(p))) if preferred else clean
            if re.search(r'(?:^|/)(?:memory|profile|\d{4}-\d{2}-\d{2})\.md$', clean, flags=re.IGNORECASE):
                return None
            if re.match(r'^\d{4}-\d{2}-\d{2}$', clean):
                return None
            clean = re.sub(r'^(?:decision|decisions|issue|issues|problem|problems|risk|risks|blocker|blockers|concern|concerns|project|projects|workstream|workstreams|initiative|initiatives|goal|goals|focus|outcome|outcomes|result|results|status|next step|next steps)\s*[:\-]\s*', '', clean, flags=re.IGNORECASE)
            clean = clean.strip(' .:-').lower()
            if not clean or clean in scaffolding_labels:
                return None
            clean = re.sub(r'^(?:the|a|an)\s+', '', clean)
            clean = re.sub(r'^(?:work on|working on|fixing|fix|issue with|problem with|problem of|question of|question about|discussion of|notes on|notes about|update on)\s+', '', clean)
            clean = re.sub(r'\b(?:for now|currently|today|later|again|properly|correctly|carefully|really|very|fairly|quite|actual|exact|honest|remaining|new|old)\b', '', clean)
            clean = re.sub(r'\bfix launcher\b', 'launcher reliability', clean)
            clean = re.sub(r'\blauncher fix\b', 'launcher reliability', clean)
            clean = re.sub(r'\bimprove(?:d)? naming\b', 'semantic naming', clean)
            clean = re.sub(r'\bnode labels?\b', 'semantic naming', clean)
            clean = re.sub(r'\b(?:is|are|was|were|be|been|being|looks|look|seems|seem|felt|feel|using|used|showing|shows|showed|becomes|became|stays|stayed)\b', '', clean)
            clean = re.sub(r'\b(?:current|current state|important|technical|key|main|primary|secondary|future|likely|semantic|visual|layout)\b', '', clean)
            clean = re.sub(r'\b(?:that|which|still|just|basically|really)\b', '', clean)
            clean = re.sub(r'[^a-z0-9\s-]', ' ', clean)
            clean = re.sub(r'\s+', ' ', clean).strip(' .:-')
            if not clean or clean in scaffolding_labels:
                return None

            # Morphological flattening for common operational variants.
            clean = re.sub(r'\b(cleaning|cleaned)\b', 'cleanup', clean)
            clean = re.sub(r'\b(rotating|rotated)\b', 'rotation', clean)
            clean = re.sub(r'\b(duplicated|duplicate|dedupe|deduped|deduplicated)\b', 'deduplication', clean)
            clean = re.sub(r'\b(filtered|filtering)\b', 'filtering', clean)
            clean = re.sub(r'\b(layout|rendering|renderer)\b', 'layout', clean)
            clean = re.sub(r'\b(validated|validating|verify|verified|verification)\b', 'validation', clean)
            clean = re.sub(r'\b(named|naming|labels?)\b', 'naming', clean)

            words = [w for w in clean.split() if len(w) > 1 and not w.isdigit()]
            if not words:
                return None
            clean = ' '.join(words)

            # Prefer noun-phrase-like tails over action-heavy prefixes.
            clean = re.sub(r'^(?:make|making|improve|improving|improved|reduce|reducing|reduced|tighten|tightening|tightened|clean up|cleaning up|cleaned up|rewrite|rewriting|rewritten|redesign|redesigning|redesigned|rebalance|rebalancing|rebalanced|demote|demoting|demoted|collapse|collapsing|collapsed|merge|merging|merged)\s+', '', clean)
            clean = re.sub(r'^(?:carry on|continue|continuing|continued)\s+', '', clean)
            clean = re.sub(r'\b(?:too noisy|too shallow|fairly meaningless|non empty|concept led|file led|background provenance|visual hierarchy|mode specific)\b', '', clean)
            clean = re.sub(r'\s+', ' ', clean).strip(' .:-')
            if len(clean.split()) >= 3 and any(tok in clean.split() for tok in canonical_wrapper_terms):
                substantive = [w for w in clean.split() if w not in canonical_wrapper_terms]
                if len(substantive) >= 2:
                    clean = ' '.join(substantive)

            for alias, canonical in concept_aliases.items():
                if clean == alias or clean.startswith(alias + ' ') or clean.endswith(' ' + alias) or alias in clean:
                    clean = canonical
                    break

            canon_record = life_index.get('aliases', {}).get(normalize_canonical_name(clean))
            if canon_record:
                clean = str(canon_record.get('title') or clean).strip().lower()

            if clean in low_value_semantic_concepts and not canon_record and kind in {'topic', 'project', 'issue', 'decision', 'outcome', 'person', 'organization', 'place'}:
                return None

            if len(clean) < 4:
                return None
            words = clean.split()
            if len(words) > 4:
                clean = ' '.join(words[:4])
            return clean.strip(' .:-') or None

        def infer_concept_kind(kind: str, clean: str, preview: str = '') -> str:
            text = f"{clean} {preview or ''}".lower()
            canon_record = life_index.get('aliases', {}).get(normalize_canonical_name(clean))
            if canon_record and canon_record.get('type'):
                mapped = str(canon_record.get('type') or '').strip().lower()
                if mapped in {'person', 'organization', 'place', 'project', 'decision', 'issue', 'outcome', 'workflow', 'system', 'repo', 'preference', 'agent'}:
                    return mapped
            if kind == 'topic':
                if re.search(r'\b(?:decision|decided|approve|approved|choose|chose|keep|kept|replace|switched|migrate|migrated|use|using)\b', text):
                    return 'decision'
                if re.search(r'\b(?:issue|problem|risk|blocker|bug|broken|failure|failed|wrong|mismatch|noise|duplicate|duplication|shallow)\b', text):
                    return 'issue'
                if re.search(r'\b(?:result|outcome|worked|working|fixed|clean|improved|validated|verified|aligned|ready|complete|completed|passed)\b', text):
                    return 'outcome'
                if re.search(r'\b(?:repo|repository|graph|env bridge|oauth|token|memory|profile|launcher|copilot|qwen)\b', text):
                    return 'project'
            return kind

        def add_theme_node(kind: str, label: str, preview: str = '') -> str | None:
            clean = canonicalize_concept(kind, label)
            if not clean:
                return None
            canon_record = life_index.get('aliases', {}).get(normalize_canonical_name(clean))
            inferred_kind = infer_concept_kind(kind, clean, preview)
            if canon_record and canon_record.get('type'):
                canonical_type = str(canon_record.get('type') or '').strip().lower()
                if canonical_type in {'person', 'organization', 'place', 'project', 'decision', 'issue', 'outcome', 'workflow', 'system', 'repo', 'preference', 'agent'}:
                    inferred_kind = canonical_type
            inferred = inferred_kind != kind
            canonical_label = str(canon_record.get('title') or clean) if canon_record else clean
            node_id = f'{inferred_kind}:{_slug(canonical_label[:80])}'
            payload = {
                'id': node_id,
                'label': canonical_label[:80],
                'type': inferred_kind,
                'content_preview': preview or canonical_label,
                'inferred_type': inferred,
                'type_confidence': 0.96 if canon_record else (0.78 if inferred else 1.0),
            }
            if canon_record:
                payload['canonical_slug'] = str(canon_record.get('slug') or '')
                payload['canonical_path'] = str(canon_record.get('path') or '')
            add_node(payload)
            return node_id

        def concept_worthy_line(text: str) -> bool:
            line = re.sub(r'\s+', ' ', (text or '').strip())
            if not line:
                return False
            if len(line) < 10 or len(line) > 120:
                return False
            low = line.lower()
            if re.search(r'\b(?:click|button|reload|refresh|compile|py_compile|grep|sqlite|json|http|ui|screenshot|view mode|source:|semantic >=|no output|successfully replaced text)\b', low):
                return False
            if re.search(r'\b(?:\.md|/home/|kgraph\.py|graph\.json|memory-db|graph-db|json-store)\b', low):
                return False
            token_hits = [tok for tok in re.findall(r'[a-zA-Z]{3,}', low) if tok in low_value_semantic_concepts]
            alpha_words = re.findall(r'[a-zA-Z]{3,}', line)
            if token_hits and len(alpha_words) <= len(token_hits) + 1:
                return False
            return len(alpha_words) >= 2

        def extract_semantic_entities(text: str) -> list[tuple[str, str]]:
            found = []
            seen = set()
            for entity_kind, pat in (semantic_entity_patterns + canonical_entity_patterns):
                for match in pat.finditer(text or ''):
                    raw = match.group(0).strip()
                    label = canonicalize_concept(entity_kind, raw) or raw.strip().lower()
                    if not label:
                        continue
                    canon_record = life_index.get('aliases', {}).get(normalize_canonical_name(label))
                    if canon_record:
                        label = str(canon_record.get('title') or label).strip().lower()
                        entity_kind = str(canon_record.get('type') or entity_kind).strip().lower()
                    key = (entity_kind, label)
                    if key in seen:
                        continue
                    seen.add(key)
                    found.append((entity_kind, label))
            return found

        def build_chunk_semantic_summary(concept_ids: list[str], chunk_text: str) -> tuple[str, list[str], dict[str, str]]:
            buckets = {
                'project': [],
                'issue': [],
                'decision': [],
                'outcome': [],
                'actor': [],
                'organization': [],
                'place': [],
                'person': [],
            }
            seen = set()
            for cid in concept_ids:
                node = next((n for n in graph['nodes'] if str(n.get('id')) == cid), None)
                if not node:
                    continue
                label = str(node.get('label', '') or '').strip()
                ntype = str(node.get('type', '') or '').lower()
                if not label or ntype not in buckets:
                    continue
                key = (ntype, label.lower())
                if key in seen:
                    continue
                seen.add(key)
                buckets[ntype].append(label)
            typed = {}
            for key in ('project', 'issue', 'decision', 'outcome', 'actor', 'organization', 'place', 'person'):
                if buckets[key]:
                    typed[key] = buckets[key][0]
            parts = []
            if typed.get('project'):
                parts.append(typed['project'])
            if typed.get('issue'):
                parts.append(f"issue: {typed['issue']}")
            if typed.get('decision'):
                parts.append(f"decision: {typed['decision']}")
            if typed.get('outcome'):
                parts.append(f"outcome: {typed['outcome']}")
            if not parts:
                fallback = []
                for key in ('actor', 'organization', 'place', 'person'):
                    if typed.get(key):
                        fallback.append(typed[key])
                parts = fallback[:3]
            summary = ' | '.join(parts[:4]) if parts else ''
            labels = list(typed.values())[:4]
            return summary[:180], labels, typed

        def iter_actor_mentions(text: str):
            if not text:
                return

            direct_pattern = re.compile(
                r'\b([A-Z][a-z]+)\s+\(([^)]+(?:Director|CEO|Ops|Researcher|Marketing|Finance|Sales|Agent))\)'
            )
            reverse_pattern = re.compile(
                r'\b((?:[A-Z][a-z]+(?:\s*&\s*[A-Z][a-z]+)?\s+)?(?:Finance|Sales|Marketing|Ops|Research|Chief|CEO)[A-Za-z\s&-]*)\s+\(([A-Z][a-z]+)\)'
            )

            for name, role in direct_pattern.findall(text):
                yield name.strip(), role.strip()
            for role, name in reverse_pattern.findall(text):
                if any(keyword in role for keyword in ('Director', 'CEO', 'Ops', 'Research', 'Finance', 'Sales', 'Marketing', 'Agent', 'Chief')):
                    yield name.strip(), role.strip()

        def resolve_file_reference(reference: str) -> str | None:
            ref = reference.strip().strip('`')
            if not ref:
                return None
            if ref in file_node_ids:
                return ref
            if ref in file_paths:
                return ref
            base = os.path.basename(ref)
            matches = file_path_by_basename.get(base, [])
            if len(matches) == 1:
                return matches[0]
            return None

        file_ref_pattern = re.compile(r'`([^`]+\.md)`|\b((?:memory/)?[A-Za-z0-9._-]+\.md)\b')
        heading_pattern = re.compile(r'^#{2,3}\s+(.+)', re.MULTILINE)
        activate_pat = re.compile(r'^#\s+([A-Z][a-z]+)-Activate\s+Report', re.MULTILINE)
        thematic_patterns = [
            ('decision', re.compile(r'^(?:[-*]\s*)?(?:decision|decided|decision made)\s*[:\-]\s*(.+)$', re.IGNORECASE | re.MULTILINE)),
            ('issue', re.compile(r'^(?:[-*]\s*)?(?:issue|problem|risk|blocker|concern)\s*[:\-]\s*(.+)$', re.IGNORECASE | re.MULTILINE)),
            ('project', re.compile(r'^(?:[-*]\s*)?(?:project|workstream|initiative|goal|focus)\s*[:\-]\s*(.+)$', re.IGNORECASE | re.MULTILINE)),
            ('outcome', re.compile(r'^(?:[-*]\s*)?(?:outcome|result|status|next step|next steps)\s*[:\-]\s*(.+)$', re.IGNORECASE | re.MULTILINE)),
        ]
        thematic_line_patterns = [
            ('decision', re.compile(r'^(?:[-*]\s*)?(?:we\s+)?(?:decided to|will|should|need to|plan to)\s+(.+)$', re.IGNORECASE)),
            ('issue', re.compile(r'^(?:[-*]\s*)?(?:the\s+)?(?:main\s+)?(?:issue|problem|risk|blocker|concern)\s+(?:is|was|remains)\s+(.+)$', re.IGNORECASE)),
            ('project', re.compile(r'^(?:[-*]\s*)?(?:work\s+on|working\s+on|focused\s+on|focus\s+on)\s+(.+)$', re.IGNORECASE)),
            ('outcome', re.compile(r'^(?:[-*]\s*)?(?:result|outcome|status|next\s+step|next\s+steps)\s+(?:is|was|remains)\s+(.+)$', re.IGNORECASE)),
        ]
        semantic_entity_patterns = [
            ('person', re.compile(r'\b(?:Wayne|Hal|Jarvis|Nexus|Marlowe|Del|Rook|Vigil|Chief|Sarah|Juno|Kai)\b')),
            ('organization', re.compile(r'\b(?:OpenClaw|Gigabrain|LCM|OpenStinger|Engram|GitHub|Tailscale|WhatsApp|Qwen|Copilot|systemd)\b', re.IGNORECASE)),
            ('place', re.compile(r'\b(?:WSL|WSL2|Windows|Ubuntu|Linux|workspace|gateway)\b', re.IGNORECASE)),
        ]
        canonical_entity_patterns = []
        for alias, record in life_index.get('aliases', {}).items():
            rtype = str(record.get('type') or '').strip().lower()
            if rtype not in {'person', 'organization', 'place', 'project', 'system', 'repo', 'workflow', 'decision', 'issue', 'outcome', 'preference', 'agent'}:
                continue
            if not alias or len(alias) < 3:
                continue
            canonical_entity_patterns.append((rtype, re.compile(rf'\b{re.escape(alias)}\b', re.IGNORECASE)))
        thematic_heading_patterns = [
            ('decision', re.compile(r'^(?:decision|decisions)\b\s*[:\-]?\s*(.+)?$', re.IGNORECASE)),
            ('issue', re.compile(r'^(?:issue|issues|problem|problems|risk|risks|blocker|blockers)\b\s*[:\-]?\s*(.+)?$', re.IGNORECASE)),
            ('project', re.compile(r'^(?:project|projects|workstream|workstreams|initiative|initiatives|focus)\b\s*[:\-]?\s*(.+)?$', re.IGNORECASE)),
            ('outcome', re.compile(r'^(?:outcome|outcomes|status|next step|next steps|result|results)\b\s*[:\-]?\s*(.+)?$', re.IGNORECASE)),
        ]
        AGENT_ROLES = {
            'Jarvis': 'Operations Director',
            'Nexus': 'Ops Director',
            'Marlowe': 'Finance Director',
            'Del': 'Sales Director',
            'Rook': 'Researcher',
            'Vigil': 'Sentinel',
            'Hal': 'CEO',
        }

        try:
            cur.execute("SELECT path FROM files")
            for (path,) in cur.fetchall():
                if not path:
                    continue
                file_name = os.path.basename(path) or path
                file_paths.add(path)
                file_path_by_basename.setdefault(file_name, []).append(path)
                file_node_ids[path] = f'file:{path}'
                add_node({
                    'id': f'file:{path}',
                    'label': file_name,
                    'type': 'file',
                    'path': path,
                    'content_preview': f'File: {path}',
                })
        except sqlite3.Error:
            pass

        chunk_embeddings = []
        try:
            semantic_link_labels = {
                ('project', 'decision'): 'project decision',
                ('project', 'issue'): 'project issue',
                ('project', 'outcome'): 'project outcome',
                ('project', 'topic'): 'project topic',
                ('project', 'actor'): 'project owner',
                ('decision', 'issue'): 'decision addresses issue',
                ('decision', 'outcome'): 'decision drives outcome',
                ('issue', 'outcome'): 'issue affects outcome',
                ('topic', 'decision'): 'topic decision',
                ('topic', 'issue'): 'topic issue',
                ('topic', 'outcome'): 'topic outcome',
                ('actor', 'decision'): 'actor decision',
                ('actor', 'issue'): 'actor issue',
                ('actor', 'outcome'): 'actor outcome',
            }
            semantic_link_weights = {
                'project decision': 1.0,
                'project issue': 1.0,
                'project outcome': 0.97,
                'decision addresses issue': 1.0,
                'decision drives outcome': 0.97,
                'issue affects outcome': 0.92,
                'project owner': 0.84,
                'project topic': 0.6,
                'topic decision': 0.54,
                'topic issue': 0.52,
                'topic outcome': 0.5,
                'actor decision': 0.64,
                'actor issue': 0.6,
                'actor outcome': 0.6,
                'related concept': 0.22,
            }
            semantic_pair_stats = {}
            node_type_cache = {}

            def node_type_for(node_id: str) -> str:
                if node_id in node_type_cache:
                    return node_type_cache[node_id]
                node_type_cache[node_id] = str(next((n.get('type', '') for n in graph['nodes'] if str(n.get('id')) == node_id), '') or '')
                return node_type_cache[node_id]

            def connect_semantic_concepts(concept_ids: list[str]):
                ordered = []
                seen_ids = set()
                for cid in concept_ids:
                    if cid and cid not in seen_ids:
                        seen_ids.add(cid)
                        ordered.append(cid)
                for i in range(len(ordered)):
                    for j in range(i + 1, len(ordered)):
                        a = ordered[i]
                        b = ordered[j]
                        a_type = node_type_for(a)
                        b_type = node_type_for(b)
                        if not a_type or not b_type:
                            continue
                        label = semantic_link_labels.get((a_type, b_type)) or semantic_link_labels.get((b_type, a_type)) or 'related concept'
                        pair = tuple(sorted((a, b)))
                        stat = semantic_pair_stats.setdefault(pair, {'count': 0, 'score': 0.0, 'labels': {}})
                        stat['count'] += 1
                        stat['score'] += semantic_link_weights.get(label, 0.4)
                        stat['labels'][label] = stat['labels'].get(label, 0) + 1

            cur.execute("SELECT id, path, start_line, end_line, text, embedding FROM chunks")
            for chunk_id, path, start_line, end_line, chunk_text, emb_blob in cur.fetchall():
                chunk_key = str(chunk_id)
                file_name = os.path.basename(path) if path else 'chunk'

                line_range = ''
                if isinstance(start_line, int) and isinstance(end_line, int):
                    line_range = f'L{start_line}-{end_line}'
                elif isinstance(start_line, int):
                    line_range = f'L{start_line}'

                preview = _preview_text(chunk_text)
                chunk_label = f'{file_name} {line_range}'.strip() if line_range else file_name
                if preview:
                    chunk_label = f'{chunk_label}: {preview}'

                add_node({
                    'id': f'chunk:{chunk_key}',
                    'label': chunk_label,
                    'type': 'chunk',
                    'path': path or '',
                    'start_line': start_line,
                    'end_line': end_line,
                    'chunk_id': chunk_key,
                    'content_preview': preview,
                })

                chunk_concepts = []

                if path:
                    if path not in file_paths:
                        file_paths.add(path)
                        file_name = os.path.basename(path) or path
                        file_path_by_basename.setdefault(file_name, []).append(path)
                        file_node_ids[path] = f'file:{path}'
                        add_node({
                            'id': f'file:{path}',
                            'label': file_name,
                            'type': 'file',
                            'path': path,
                            'content_preview': f'File: {path}',
                        })
                    add_edge({
                        'from': f'file:{path}',
                        'to': f'chunk:{chunk_key}',
                        'label': 'contains chunk',
                    })

                for name, role in iter_actor_mentions(chunk_text or ''):
                    actor_id = add_actor_node(name, role)
                    chunk_concepts.append(actor_id)
                    add_edge({
                        'from': f'chunk:{chunk_key}',
                        'to': actor_id,
                        'label': 'mentions actor',
                    })
                    if path:
                        add_edge({
                            'from': f'file:{path}',
                            'to': actor_id,
                            'label': 'mentions actor',
                        })

                for ref_a, ref_b in file_ref_pattern.findall(chunk_text or ''):
                    ref = ref_a or ref_b
                    target_path = resolve_file_reference(ref)
                    if not target_path or target_path == path:
                        continue
                    add_edge({
                        'from': f'chunk:{chunk_key}',
                        'to': f'file:{target_path}',
                        'label': 'references file',
                    })
                    if path:
                        add_edge({
                            'from': f'file:{path}',
                            'to': f'file:{target_path}',
                            'label': 'references file',
                        })

                # Collect embedding vector for semantic similarity pass
                if emb_blob and isinstance(emb_blob, str):
                    try:
                        vec = json.loads(emb_blob)
                        if isinstance(vec, list) and len(vec) > 0:
                            mag = sum(x * x for x in vec) ** 0.5
                            if mag > 0:
                                chunk_embeddings.append((f'chunk:{chunk_key}', path or '', vec, mag))
                    except (json.JSONDecodeError, ValueError):
                        pass

                # Extract H2/H3 headings as topic nodes
                for hm in heading_pattern.finditer(chunk_text or ''):
                    topic_id = add_topic_node(hm.group(1))
                    if topic_id:
                        chunk_concepts.append(topic_id)
                        add_edge({
                            'from': f'chunk:{chunk_key}',
                            'to': topic_id,
                            'label': 'covers topic',
                        })
                        if path:
                            add_edge({
                                'from': f'file:{path}',
                                'to': topic_id,
                                'label': 'covers topic',
                            })

                # Lift higher-level semantic themes from headings and explicit summary lines
                for hm in heading_pattern.finditer(chunk_text or ''):
                    heading_text = (hm.group(1) or '').strip()
                    for kind, pat in thematic_heading_patterns:
                        m = pat.match(heading_text)
                        if not m:
                            continue
                        derived = (m.group(1) or '').strip()
                        if not derived:
                            continue
                        theme_id = add_theme_node(kind, derived, preview=heading_text)
                        if theme_id:
                            chunk_concepts.append(theme_id)
                            add_edge({
                                'from': f'chunk:{chunk_key}',
                                'to': theme_id,
                                'label': f'has {kind}',
                            })
                            if path:
                                add_edge({
                                    'from': f'file:{path}',
                                    'to': theme_id,
                                    'label': f'has {kind}',
                                })

                for kind, pat in thematic_patterns:
                    for match in pat.finditer(chunk_text or ''):
                        derived = (match.group(1) or '').strip()
                        theme_id = add_theme_node(kind, derived, preview=derived)
                        if theme_id:
                            chunk_concepts.append(theme_id)
                            add_edge({
                                'from': f'chunk:{chunk_key}',
                                'to': theme_id,
                                'label': f'has {kind}',
                            })
                            if path:
                                add_edge({
                                    'from': f'file:{path}',
                                    'to': theme_id,
                                    'label': f'has {kind}',
                                })

                for raw_line in (chunk_text or '').splitlines():
                    line = raw_line.strip()
                    if not concept_worthy_line(line):
                        continue
                    for kind, pat in thematic_line_patterns:
                        m = pat.match(line)
                        if not m:
                            continue
                        derived = (m.group(1) or '').strip(' .:-')
                        theme_id = add_theme_node(kind, derived, preview=line)
                        if theme_id:
                            chunk_concepts.append(theme_id)
                            add_edge({
                                'from': f'chunk:{chunk_key}',
                                'to': theme_id,
                                'label': f'has {kind}',
                            })
                            if path:
                                add_edge({
                                    'from': f'file:{path}',
                                    'to': theme_id,
                                    'label': f'has {kind}',
                                })
                            break

                # Detect activation-report authorship from H1 title
                for am in activate_pat.finditer(chunk_text or ''):
                    agent_name = am.group(1)
                    role = AGENT_ROLES.get(agent_name, 'Agent')
                    actor_id = add_actor_node(agent_name, role)
                    chunk_concepts.append(actor_id)
                    add_edge({
                        'from': f'chunk:{chunk_key}',
                        'to': actor_id,
                        'label': 'authored by',
                    })
                    if path:
                        add_edge({
                            'from': f'file:{path}',
                            'to': actor_id,
                            'label': 'authored by',
                        })

                for entity_kind, entity_label in extract_semantic_entities(chunk_text or ''):
                    entity_id = add_theme_node(entity_kind, entity_label, preview=entity_label)
                    if entity_id:
                        chunk_concepts.append(entity_id)
                        add_edge({
                            'from': f'chunk:{chunk_key}',
                            'to': entity_id,
                            'label': f'has {entity_kind}',
                        })

                semantic_summary, summary_labels, typed_summary = build_chunk_semantic_summary(chunk_concepts, chunk_text or '')
                if semantic_summary:
                    summary_slug = _slug(semantic_summary[:120])
                    summary_id = f'summary:{chunk_key}:{summary_slug}'
                    add_node({
                        'id': summary_id,
                        'label': semantic_summary[:180],
                        'type': 'summary',
                        'content_preview': semantic_summary,
                        'visibility': 'semantic',
                        'quality_tier': 'semantic',
                        'summary_labels': summary_labels,
                        'typed_summary': typed_summary,
                    })
                    chunk_concepts.append(summary_id)
                    add_edge({
                        'from': f'chunk:{chunk_key}',
                        'to': summary_id,
                        'label': 'semantic summary',
                        'visibility': 'semantic',
                        'quality_tier': 'semantic',
                    })
                    for summary_kind, summary_label in typed_summary.items():
                        summary_theme_id = add_theme_node(summary_kind if summary_kind != 'actor' else 'actor', summary_label, preview=semantic_summary)
                        if summary_theme_id:
                            add_edge({
                                'from': summary_id,
                                'to': summary_theme_id,
                                'label': f'summarizes {summary_kind}',
                                'visibility': 'semantic',
                                'quality_tier': 'semantic',
                            })

                connect_semantic_concepts(chunk_concepts)

            for (a, b), stat in semantic_pair_stats.items():
                best_label = max(stat['labels'].items(), key=lambda item: (item[1], semantic_link_weights.get(item[0], 0.0)))[0]
                avg_score = stat['score'] / max(stat['count'], 1)
                keep = stat['count'] >= 2 or avg_score >= 0.95
                if best_label in {'project topic', 'topic decision', 'topic issue', 'topic outcome', 'actor issue', 'actor outcome'}:
                    keep = keep and stat['count'] >= 2 and avg_score >= 0.58
                if best_label == 'related concept':
                    keep = stat['count'] >= 3 and avg_score >= 0.45
                if not keep:
                    continue
                semantic_score = round(min(0.99, 0.55 + (0.12 * min(stat['count'], 3)) + (0.18 * avg_score)), 3)
                add_edge({
                    'from': a,
                    'to': b,
                    'label': best_label,
                    'visibility': 'both',
                    'quality_tier': 'semantic',
                    'semantic_score': semantic_score,
                    'cooccurrence_count': stat['count'],
                    'label_visibility': 'visible' if semantic_score >= 0.86 or stat['count'] >= 3 else 'hover',
                })

            # Embedding-based semantic similarity (cross-file only)
            SEMANTIC_THRESHOLD = 0.75
            for i in range(len(chunk_embeddings)):
                cid_a, path_a, vec_a, mag_a = chunk_embeddings[i]
                for j in range(i + 1, len(chunk_embeddings)):
                    cid_b, path_b, vec_b, mag_b = chunk_embeddings[j]
                    if path_a == path_b:
                        continue
                    dot = sum(a * b for a, b in zip(vec_a, vec_b))
                    sim = dot / (mag_a * mag_b)
                    if sim >= SEMANTIC_THRESHOLD:
                        rounded = round(sim, 3)
                        add_edge({
                            'from': cid_a,
                            'to': cid_b,
                            'label': f'related ({sim:.2f})',
                            'semantic_score': rounded,
                        })
                        if path_a and path_b:
                            add_edge({
                                'from': f'file:{path_a}',
                                'to': f'file:{path_b}',
                                'label': f'related ({sim:.2f})',
                                'semantic_score': rounded,
                            })
        except sqlite3.Error:
            pass

    conn.close()
    return graph


if __name__ == '__main__':
    main()
