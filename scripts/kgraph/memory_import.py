"""Memory DB import pipeline.

Exports load_from_memory_db() — the concept extraction pipeline
that loads nodes/edges from an OpenClaw memory SQLite database,
including topic extraction, actor mentions, semantic analysis, and
embedding-based similarity.

Returns a ``Graph`` model.
"""

from __future__ import annotations

import json
import logging
import os
import re
import sqlite3
from typing import Any

from .constants import normalize_canonical_name
from .life_index import load_life_index
from .models import Graph, GraphBuilder, slugify

logger = logging.getLogger(__name__)

# ── Concept configuration ──────────────────────────────────────────────

_CONFIG_PATH = os.path.join(os.path.dirname(__file__), "..", "..", "config", "concept-aliases.json")


def _load_concept_config() -> dict:
    """Load concept aliases and classification data from config/concept-aliases.json."""
    path = os.path.normpath(_CONFIG_PATH)
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except (OSError, json.JSONDecodeError):
        return {}


_concept_config = _load_concept_config()
SCAFFOLDING_LABELS = frozenset(_concept_config.get("scaffolding_labels", []))
CONCEPT_ALIASES = _concept_config.get("concept_aliases", {})
LOW_VALUE_CONCEPTS = frozenset(_concept_config.get("low_value_semantic_concepts", []))
WRAPPER_TERMS = frozenset(_concept_config.get("canonical_wrapper_terms", []))
AGENT_ROLES = _concept_config.get("agent_roles", {})


def load_from_memory_db(dbpath: str, include_all: bool = False) -> Graph:
    """Load nodes/edges from an OpenClaw memory SQLite DB into a Graph model.

    ``include_all`` skips the default registry filter (status/value_score/stale)
    — used by ``kgraph --update --include-all`` for audit runs.
    """
    conn = sqlite3.connect(os.path.expanduser(dbpath))
    cur = conn.cursor()
    builder = GraphBuilder()

    def has_table(name: str) -> bool:
        cur.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name=? LIMIT 1", (name,))
        return cur.fetchone() is not None

    def add_node(node: dict):
        builder.add_node(node)

    def add_edge(edge: dict):
        builder.add_edge(edge)

    # Current OpenClaw memory schema: files/chunks tables.
    if has_table('files') and has_table('chunks'):
        life_index = load_life_index()
        file_paths = set()
        file_node_ids: dict[str, str] = {}
        file_path_by_basename: dict[str, list[str]] = {}

        def _preview_text(value: str, limit: int = 72) -> str:
            text = (value or '').replace('\n', ' ').replace('\r', ' ').strip()
            text = ' '.join(text.split())
            if len(text) > limit:
                return text[: limit - 1] + '…'
            return text

        def _slug(value: str) -> str:
            return slugify(value)

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

        scaffolding_labels = SCAFFOLDING_LABELS
        concept_aliases = CONCEPT_ALIASES
        low_value_semantic_concepts = LOW_VALUE_CONCEPTS
        canonical_wrapper_terms = WRAPPER_TERMS

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
            buckets: dict[str, list[str]] = {
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
                node = builder.get_node(cid)
                if not node:
                    continue
                label = (node.label or '').strip()
                ntype = (node.type or '').lower()
                if not label or ntype not in buckets:
                    continue
                pair = (ntype, label.lower())
                if pair in seen:
                    continue
                seen.add(pair)
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
            semantic_pair_stats: dict[tuple[str, str], dict[str, Any]] = {}
            node_type_cache: dict[str, str] = {}

            def node_type_for(node_id: str) -> str:
                if node_id in node_type_cache:
                    return node_type_cache[node_id]
                n = builder.get_node(node_id)
                node_type_cache[node_id] = (n.type if n and hasattr(n, 'type') else '')
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
                        pair = (a, b) if a <= b else (b, a)
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

    # OpenClaw memory registry schema: memories/memory_entities/memory_syntheses
    # tables (distinct from the files/chunks memory-store schema above).
    elif has_table('memories') and has_table('memory_entities'):
        registry = _registry_db_path_label(dbpath)
        _load_from_registry_db(conn, builder, registry=registry, include_all=include_all)

    conn.close()

    # Cross-chunk entity resolution: collapse same-concept nodes discovered
    # across different chunks (e.g. "Decision: X" from chunk 1 and chunk 2)
    # into a single canonical node.  Uses life_index aliases for resolution.
    # Source: rahulnyk/graph_maker review — chunk-independence information loss
    # mitigation.
    builder.deduplicate_semantic(life_index=load_life_index())

    return builder.build()


# ── Registry-schema adapter (T-ROOK-006) ────────────────────────────────

# Agent/known-person names that must survive mention filtering even when
# they appear in LOW_VALUE_CONCEPTS (verified: 'hal', 'wayne' are in the
# low-value list but are real entities the graph should keep).
_AGENT_NAMES = frozenset({
    'hal', 'wayne', 'rook', 'jarvis', 'sarah', 'finn', 'aris', 'kai',
    'juno', 'marlowe', 'vigil', 'nexus', 'del', 'chief', 'lyra', 'don',
})

# Mention entity_keys that are keyword noise (verified from live registries:
# "database", "integrity", "weekly", "sunday", "dislikes", "relations"...).
_MENTION_NOISE_WORDS = frozenset({
    'database', 'integrity', 'weekly', 'sunday', 'dislikes', 'relations',
    'values', 'wants', 'report', 'research', 'share', 'review', 'remove',
    'cite', 'connect', 'workspace', 'gateway', 'linux', 'ubuntu', 'windows',
    'wsl', 'wsl2', 'systemd', 'openclaw', 'engram', 'memory', 'profile',
    'current', 'state', 'context', 'summary', 'notes', 'overview', 'status',
    'general', 'none', 'todo', 'todos', 'task', 'tasks', 'issue', 'issues',
    'item', 'items', 'file', 'files', 'chunk', 'chunks', 'line', 'lines',
    'section', 'content', 'text', 'data', 'info', 'information', 'details',
    'list', 'lists', 'thing', 'things', 'stuff', 'something', 'someone',
    'anyone', 'everyone', 'nobody', 'people', 'person', 'group', 'team',
    'work', 'working', 'works', 'done', 'doing', 'go', 'going', 'went',
    'get', 'got', 'make', 'made', 'take', 'took', 'put', 'set', 'let',
    'look', 'see', 'show', 'tell', 'ask', 'help', 'need', 'want', 'like',
    'know', 'think', 'say', 'said', 'use', 'used', 'using', 'find', 'found',
    'keep', 'kept', 'start', 'started', 'stop', 'stopped', 'try', 'tried',
    'call', 'called', 'give', 'gave', 'send', 'sent', 'come', 'came',
    'leave', 'left', 'turn', 'turned', 'bring', 'brought', 'hold', 'held',
    'run', 'ran', 'running', 'move', 'moved', 'open', 'opened', 'close',
    'closed', 'add', 'added', 'remove', 'removed', 'change', 'changed',
    'fix', 'fixed', 'broken', 'error', 'errors', 'bug', 'bugs', 'test',
    'tests', 'tested', 'build', 'built', 'deploy', 'deployed', 'push',
    'pushed', 'pull', 'pulled', 'merge', 'merged', 'commit', 'committed',
    'branch', 'branches', 'repo', 'repos', 'code', 'codes', 'function',
    'functions', 'class', 'classes', 'module', 'modules', 'import',
    'imports', 'export', 'exports', 'return', 'returns', 'value', 'values',
    'bool', 'int', 'str', 'list', 'dict', 'tuple', 'none', 'true', 'false',
    'null', 'undefined', 'ok', 'okay', 'yes', 'no', 'maybe', 'perhaps',
    'later', 'now', 'today', 'tomorrow', 'yesterday', 'week', 'month',
    'year', 'day', 'days', 'time', 'times', 'hour', 'hours', 'minute',
    'minutes', 'second', 'seconds', 'new', 'old', 'good', 'bad', 'best',
    'worst', 'better', 'worse', 'great', 'nice', 'fine', 'cool', 'awesome',
    'amazing', 'interesting', 'important', 'main', 'primary', 'secondary',
    'key', 'major', 'minor', 'big', 'small', 'large', 'little', 'high',
    'low', 'top', 'bottom', 'left', 'right', 'front', 'back', 'middle',
    'center', 'inside', 'outside', 'above', 'below', 'over', 'under',
    'between', 'among', 'during', 'before', 'after', 'since', 'until',
    'while', 'because', 'although', 'though', 'unless', 'whether', 'either',
    'neither', 'both', 'all', 'any', 'each', 'every', 'few', 'more', 'most',
    'other', 'some', 'such', 'only', 'own', 'same', 'so', 'than', 'too',
    'very', 'just', 'also', 'again', 'then', 'there', 'here', 'where',
    'when', 'why', 'how', 'what', 'which', 'who', 'whom', 'whose', 'this',
    'that', 'these', 'those', 'i', 'me', 'my', 'mine', 'we', 'us', 'our',
    'ours', 'you', 'your', 'yours', 'he', 'him', 'his', 'she', 'her',
    'hers', 'it', 'its', 'they', 'them', 'their', 'theirs', 'a', 'an',
    'the', 'and', 'or', 'but', 'if', 'else', 'for', 'with', 'without',
    'by', 'from', 'to', 'into', 'onto', 'at', 'in', 'on', 'off', 'out',
    'up', 'down', 'about', 'across', 'against', 'along', 'around',
    'behind', 'beside', 'beyond', 'near', 'past', 'through', 'toward',
    'towards', 'underneath', 'upon', 'via', 'per', 'am', 'is', 'are',
    'was', 'were', 'be', 'been', 'being', 'have', 'has', 'had', 'having',
    'do', 'does', 'did', 'done', 'will', 'would', 'shall', 'should',
    'can', 'could', 'may', 'might', 'must', 'ought', 'need', 'needs',
    'dare', 'dared', 'shall', 'am', 'not', 'no', 'nor', 'never',
    'don', 'cannot', "can't", "won't", "don't", "doesn't", "didn't",
    "isn't", "aren't", "wasn't", "weren't", "haven't", "hasn't", "hadn't",
    "won't", "wouldn't", "shouldn't", "couldn't", "mightn't", "mustn't",
    'etc', 'eg', 'ie', 'vs', 'via', 'per', 'etcetera', 'example',
    'examples', 'case', 'cases', 'point', 'points', 'part', 'parts',
    'piece', 'pieces', 'bit', 'bits', 'way', 'ways', 'kind', 'kinds',
    'type', 'types', 'sort', 'sorts', 'form', 'forms', 'method',
    'methods', 'approach', 'approaches', 'strategy', 'strategies',
    'plan', 'plans', 'goal', 'goals', 'objective', 'objectives',
    'target', 'targets', 'aim', 'aims', 'purpose', 'purposes', 'reason',
    'reasons', 'cause', 'causes', 'effect', 'effects', 'result',
    'results', 'outcome', 'outcomes', 'impact', 'impacts', 'benefit',
    'benefits', 'cost', 'costs', 'price', 'prices', 'value', 'values',
})


def _registry_db_path_label(dbpath: str) -> str:
    """Return 'home' or 'rook' based on the registry path."""
    expanded = os.path.expanduser(dbpath)
    if 'workspace-rook' in expanded:
        return 'rook'
    return 'home'


def _load_from_registry_db(conn: sqlite3.Connection, builder: GraphBuilder,
                           registry: str, include_all: bool = False) -> None:
    """Adapter for the OpenClaw memory registry schema.

    Maps registry tables → Graph nodes/edges (T-ROOK-006 design v2):
      memories                → memory:{uuid} nodes
      memory_native_chunks    → memory:native:{chunk_id} nodes
      memory_entities         → entity:{kind}:{slug} nodes (0 rows today; coded)
      memory_entity_mentions  → synthesized entity:{slug} nodes + mentions edges
      memory_entity_relationships → entity→entity edges
      memory_syntheses        → synthesis:{id} nodes (stale=0 unless include_all)
      memory_claims           → claim:{memory_id}:{slot} nodes
      memory_beliefs          → belief:{id} nodes
      memory_open_loops       → open_loop:{id} nodes
      memory_events           → skipped (provenance/audit noise)

    Logs node/edge counts at INFO (Hal review note §3.3a) so a future
    "KG is empty" alarm has a trace.
    """
    # Registry branch consumes rows as dicts; the files/chunks branch uses
    # tuple indexing on the same connection — Row supports both, so set it
    # before creating the cursor (idempotent).
    conn.row_factory = sqlite3.Row
    cur = conn.cursor()
    nodes_added = 0
    edges_added = 0
    events_skipped = 0

    def _has_table(name: str) -> bool:
        cur.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name=? LIMIT 1", (name,))
        return cur.fetchone() is not None

    def _preview_text(value, limit: int = 72) -> str:
        if not isinstance(value, str):
            value = str(value or '')
        text = value.replace('\n', ' ').replace('\r', ' ').strip()
        text = ' '.join(text.split())
        if len(text) > limit:
            return text[: limit - 1] + '…'
        return text

    def _add_node(node: dict) -> None:
        nonlocal nodes_added
        node_id = node.get('id')
        if node_id and not builder.has_node(node_id):
            nodes_added += 1
        builder.add_node(node)

    def _add_edge(edge: dict) -> None:
        nonlocal edges_added
        builder.add_edge(edge)
        edges_added += 1

    def _filtered_row(row: dict) -> bool:
        """Jarvis ruling 3: status='active' AND (value_score IS NULL OR >= 0.5)."""
        if include_all:
            return True
        if str(row.get('status') or 'active') != 'active':
            return False
        vs = row.get('value_score')
        if vs is not None:
            try:
                if float(vs) < 0.5:
                    return False
            except (TypeError, ValueError):
                pass
        return True

    # ── memories → memory:{uuid} ──
    if _has_table('memories'):
        for row in cur.execute(
            "SELECT id, type, content, source_agent, scope, tags, confidence, created_at,"
            "       concept, value_score, value_label, source_layer, status"
            "  FROM memories"
        ):
            d = dict(row)
            if not _filtered_row(d):
                continue
            _add_node({
                'id': f"memory:{d['id']}",
                'label': _preview_text(d.get('content')),
                'type': 'memory',
                'origin': 'memory_db',
                'registry': registry,
                'row_scope': d.get('scope'),
                'content': d.get('content'),
                'source_agent': d.get('source_agent'),
                'tags': d.get('tags'),
                'confidence': str(d.get('confidence')) if d.get('confidence') is not None else None,
                'created_at': d.get('created_at'),
                'concept': d.get('concept'),
                'value_score': d.get('value_score'),
                'value_label': d.get('value_label'),
                'source_layer': d.get('source_layer'),
                'memory_type': d.get('type'),
            })

    # ── memory_native_chunks → memory:native:{chunk_id} ──
    # A promoted memory (memories.source_layer='promoted_native') and its raw
    # native chunk are the same fact in two tables; importing both creates an
    # unconnected duplicate.  Skip chunks already imported as memories.
    promoted_contents: set[str] = set()
    if _has_table('memories'):
        for r in cur.execute("SELECT content FROM memories"):
            content = (r['content'] or '').strip()
            if content:
                promoted_contents.add(normalize_canonical_name(content))
    if _has_table('memory_native_chunks'):
        for row in cur.execute(
            "SELECT chunk_id, source_path, source_kind, section, line_start, line_end,"
            "       content, scope, status"
            "  FROM memory_native_chunks"
        ):
            d = dict(row)
            if not _filtered_row(d):
                continue
            chunk_content = (d.get('content') or '').strip()
            if chunk_content and normalize_canonical_name(chunk_content) in promoted_contents:
                continue
            _add_node({
                'id': f"memory:native:{d['chunk_id']}",
                'label': _preview_text(d.get('content')),
                'type': 'memory',
                'origin': 'memory_db',
                'registry': registry,
                'row_scope': d.get('scope'),
                'content': d.get('content'),
                'source_path': d.get('source_path'),
                'source_kind': d.get('source_kind'),
                'section': d.get('section'),
                'line_start': d.get('line_start'),
                'line_end': d.get('line_end'),
            })

    # ── memory_entities → entity:{kind}:{slug} (0 rows today; coded for future) ──
    entity_row_ids: dict[str, str] = {}  # normalized_name → preferred id
    if _has_table('memory_entities'):
        for row in cur.execute(
            "SELECT entity_id, kind, display_name, normalized_name, status, confidence, aliases"
            "  FROM memory_entities"
        ):
            d = dict(row)
            display = (d.get('display_name') or '').strip()
            if not display:
                continue
            kind = (d.get('kind') or 'entity').strip().lower() or 'entity'
            nid = f"entity:{kind}:{slugify(display)}"
            _add_node({
                'id': nid,
                'label': display,
                'type': 'entity',
                'origin': 'memory_db',
                'registry': registry,
                'row_scope': None,
                'kind': kind,
                'aliases': d.get('aliases'),
                'confidence': str(d.get('confidence')) if d.get('confidence') is not None else None,
                'status': d.get('status'),
            })
            key = normalize_canonical_name(d.get('normalized_name') or display)
            entity_row_ids.setdefault(key, nid)

    # ── memory_entity_mentions → entity nodes + mentions edges ──
    if _has_table('memory_entity_mentions'):
        mention_entity_ids: dict[str, str] = {}
        for row in cur.execute(
            "SELECT memory_id, entity_key, entity_display, role, confidence, scope"
            "  FROM memory_entity_mentions"
        ):
            d = dict(row)
            key = (d.get('entity_key') or '').strip().lower()
            display = (d.get('entity_display') or key).strip()
            if not key or not display:
                continue
            # Noise filter: agent names survive even if in LOW_VALUE_CONCEPTS;
            # everything keyword-like is dropped (Jarvis gap fix 1 + review).
            if key in _AGENT_NAMES:
                pass
            elif key in _MENTION_NOISE_WORDS or key in LOW_VALUE_CONCEPTS or len(key) < 3:
                continue
            # Prefer a real memory_entities row id if one exists (Jarvis note 1);
            # otherwise synthesize entity:{slug}.
            ent_id = entity_row_ids.get(key)
            if ent_id is None:
                ent_id = f"entity:{slugify(key)}"
            if ent_id not in mention_entity_ids:
                mention_entity_ids[ent_id] = display
                _add_node({
                    'id': ent_id,
                    'label': display,
                    'type': 'entity',
                    'origin': 'memory_db',
                    'registry': registry,
                    'row_scope': d.get('scope'),
                    'kind': 'mention-derived',
                    'role': str(d.get('role')) if d.get('role') is not None else None,
                })
            # Resolve source memory id: native:{chunk_id} → memory:native:{chunk_id}
            mem_id = d.get('memory_id') or ''
            if mem_id.startswith('native:'):
                src = f"memory:native:{mem_id[len('native:'):]}"
            else:
                src = f"memory:{mem_id}"
            _add_edge({
                'from': src,
                'to': ent_id,
                'label': 'mentions',
                'origin': 'memory_db',
                'registry': registry,
                'role': d.get('role'),
                'metadata': {'confidence': d.get('confidence')},
            })

    # ── memory_entity_relationships → entity→entity edges ──
    if _has_table('memory_entity_relationships'):
        for row in cur.execute(
            "SELECT entity_id_a, entity_id_b, relationship_type, evidence_count,"
            "       source_memory_ids, confidence"
            "  FROM memory_entity_relationships"
        ):
            d = dict(row)
            src = d.get('entity_id_a') or ''
            tgt = d.get('entity_id_b') or ''
            rel = str(d.get('relationship_type') or '').strip() or 'related'
            if not src or not tgt:
                continue
            _add_edge({
                'from': f"entity:{src}",
                'to': f"entity:{tgt}",
                'label': rel,
                'origin': 'memory_db',
                'registry': registry,
                'evidence_count': d.get('evidence_count'),
                'metadata': {
                    'source_memory_ids': d.get('source_memory_ids'),
                    'confidence': d.get('confidence'),
                },
            })

    # ── memory_syntheses → synthesis:{id} (stale=0 unless include_all) ──
    if _has_table('memory_syntheses'):
        for row in cur.execute(
            "SELECT synthesis_id, kind, subject_type, subject_id, content, stale,"
            "       confidence, generated_at"
            "  FROM memory_syntheses"
        ):
            d = dict(row)
            if not include_all and d.get('stale'):
                continue
            kind = (d.get('kind') or 'synthesis').strip()
            subject = f"{d.get('subject_type') or '?'}:{d.get('subject_id') or '?'}"
            _add_node({
                'id': f"synthesis:{d['synthesis_id']}",
                'label': f"{kind} · {subject}"[:72],
                'type': 'synthesis',
                'origin': 'memory_db',
                'registry': registry,
                'kind': kind,
                'subject_type': d.get('subject_type'),
                'subject_id': d.get('subject_id'),
                'content': d.get('content'),
                'confidence': str(d.get('confidence')) if d.get('confidence') is not None else None,
                'generated_at': d.get('generated_at'),
                'stale': d.get('stale'),
            })

    # ── memory_claims → claim:{memory_id}:{slot} ──
    if _has_table('memory_claims'):
        for row in cur.execute(
            "SELECT memory_id, memory_tier, claim_slot, consolidation_op,"
            "       source_strength, surface_candidate"
            "  FROM memory_claims"
        ):
            d = dict(row)
            mem_id = d.get('memory_id') or 'unknown'
            slot = d.get('claim_slot') or 'unknown'
            candidate = d.get('surface_candidate')
            label = _preview_text(candidate)
            if not label:
                label = f"claim {slot}"[:72]
            claim_id = f"claim:{mem_id}:{slot}"
            _add_node({
                'id': claim_id,
                'label': label,
                'type': 'claim',
                'origin': 'memory_db',
                'registry': registry,
                'memory_tier': d.get('memory_tier'),
                'consolidation_op': d.get('consolidation_op'),
                'source_strength': d.get('source_strength'),
            })
            # Link the claim to the memory it was consolidated from; the
            # claim id embeds the memory uuid but the edge makes the
            # relationship traversable ("who claims what").
            memory_id = f"memory:{mem_id}"
            if builder.has_node(memory_id):
                _add_edge({'from': memory_id, 'to': claim_id, 'label': 'claims',
                           'confidence': 'EXTRACTED'})

    # ── memory_beliefs → belief:{id} ──
    if _has_table('memory_beliefs'):
        for row in cur.execute(
            "SELECT belief_id, entity_id, type, content, status, confidence,"
            "       source_memory_id, source_layer"
            "  FROM memory_beliefs"
        ):
            d = dict(row)
            if not include_all and str(d.get('status') or 'active') != 'active':
                continue
            _add_node({
                'id': f"belief:{d['belief_id']}",
                'label': _preview_text(d.get('content')),
                'type': 'belief',
                'origin': 'memory_db',
                'registry': registry,
                'entity_id': d.get('entity_id'),
                'belief_type': d.get('type'),
                'confidence': str(d.get('confidence')) if d.get('confidence') is not None else None,
                'source_memory_id': d.get('source_memory_id'),
                'source_layer': d.get('source_layer'),
            })

    # ── memory_open_loops → open_loop:{id} ──
    if _has_table('memory_open_loops'):
        for row in cur.execute(
            "SELECT loop_id, kind, title, status, priority, related_entity_id"
            "  FROM memory_open_loops"
        ):
            d = dict(row)
            if not include_all and str(d.get('status') or 'open') != 'active':
                continue
            _add_node({
                'id': f"open_loop:{d['loop_id']}",
                'label': _preview_text(d.get('title')),
                'type': 'open_loop',
                'origin': 'memory_db',
                'registry': registry,
                'kind': d.get('kind'),
                'status': d.get('status'),
                'priority': d.get('priority'),
                'related_entity_id': d.get('related_entity_id'),
            })

    # ── memory_events → skipped (provenance/audit noise) ──
    if _has_table('memory_events'):
        try:
            events_skipped = cur.execute("SELECT COUNT(*) FROM memory_events").fetchone()[0]
        except sqlite3.Error:
            events_skipped = -1

    logger.info(
        "registry import (registry=%s, include_all=%s): %d nodes, %d edges, "
        "%d events skipped",
        registry, include_all, nodes_added, edges_added, events_skipped,
    )
