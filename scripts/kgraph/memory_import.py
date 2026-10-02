"""Memory DB import pipeline.

Exports load_from_memory_db() — the concept extraction pipeline
that loads nodes/edges from an OpenClaw memory SQLite database,
including topic extraction, actor mentions, semantic analysis, and
embedding-based similarity.

The work is split into PHASES, each callable on its own:

* schema / table detection — ``_detect_schema``
* memory-row import        — ``_import_registry_*`` (one function per registry table)
* chunk + embedding import — ``_MemoryStoreIngest.ingest_files`` / ``.ingest_chunks``
* co-occurrence scoring    — ``_MemoryStoreIngest.connect_semantic_concepts`` /
                             ``.emit_semantic_edges``
* semantic synthesis / node typing — ``_MemoryStoreIngest.add_theme_node`` and the
                             ``canonicalize_concept`` / ``infer_concept_kind`` pair

Every phase uses the existing ``GraphBuilder``; nothing here re-implements the
graph model.

Returns a ``Graph`` model.
"""

from __future__ import annotations

import json
import logging
import os
import re
import sqlite3
from typing import Any

from .constants import (
    AGENT_ROLES,
    CONCEPT_ALIASES,
    LOW_VALUE_CONCEPTS,
    SCAFFOLDING_LABELS,
    WRAPPER_TERMS,
    load_concept_config,
    normalize_canonical_name,
)
from .life_index import load_life_index
from .models import Graph, GraphBuilder, slugify, source_key

logger = logging.getLogger(__name__)

# ── Concept configuration ──────────────────────────────────────────────
# Owned by constants.py now: ONE loader for config/concept-aliases.json, shared
# with models.py and projection.py, which each used to carry their own hardcoded
# subset (item 11.14).  The names stay module-level so existing readers of
# `memory_import.SCAFFOLDING_LABELS` and friends keep working.
_load_concept_config = load_concept_config


# ══════════════════════════════════════════════════════════════════════════════
# Phase 1 — schema / table detection
# ══════════════════════════════════════════════════════════════════════════════
def _has_table(cur: sqlite3.Cursor, name: str) -> bool:
    """Whether the connected database carries a table called *name*."""
    cur.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name=? LIMIT 1", (name,))
    return cur.fetchone() is not None


# The two memory schemas this module knows, and the signal each is recognised by.
_MEMORY_STORE_TABLES = ('files', 'chunks')
_REGISTRY_TABLES = ('memories', 'memory_entities')


def _detect_schema(cur: sqlite3.Cursor) -> str:
    """Which import branch this database needs: 'files-chunks' | 'registry' | 'unknown'.

    Both tables of a pair must be present: a database with only ``files`` (or
    only ``memories``) is not a memory schema, and treating a partial schema as
    a match would run one branch's SQL against the other's columns.
    """
    if all(_has_table(cur, name) for name in _MEMORY_STORE_TABLES):
        return 'files-chunks'
    if all(_has_table(cur, name) for name in _REGISTRY_TABLES):
        return 'registry'
    return 'unknown'


# ══════════════════════════════════════════════════════════════════════════════
# Shared text helpers
# ══════════════════════════════════════════════════════════════════════════════
def _preview_text(value: Any, limit: int = 72) -> str:
    """Whitespace-collapsed preview, ellipsised at *limit*.

    ONE implementation for both branches (the memory-store branch used to carry
    its own).  Non-str values are coerced rather than raising: SQLite columns are
    dynamically typed, and the previous memory-store copy would have raised an
    AttributeError outside the ``sqlite3.Error`` guard.
    """
    if not isinstance(value, str):
        value = str(value or '')
    text = value.replace('\n', ' ').replace('\r', ' ').strip()
    text = ' '.join(text.split())
    if len(text) > limit:
        return text[: limit - 1] + '…'
    return text


def _bind_edge_sources(edge: dict, chunk_source: str, file_source: str) -> dict:
    """Record which documents assert *edge*, in place (GRAPHRAG-ARCH-007).

    Bound once per chunk by the caller rather than repeated at each of the ~20
    emission sites: a site that forgot would silently produce a lineage-less edge
    and nothing in the graph would say so.  A file-level roll-up asserted by a
    chunk of that file carries BOTH keys, so deleting the file or the chunk
    subtracts the right assertion.
    """
    keys = set(edge.get('sources') or [])
    src = str(edge.get('from') or edge.get('source') or '')
    if src.startswith('file:') and file_source:
        keys.update({chunk_source, file_source})
    elif chunk_source:
        keys.add(chunk_source)
    edge['sources'] = sorted(keys)
    return edge


def iter_actor_mentions(text: str):
    """Yield (name, role) for the two actor-mention spellings in chunk text."""
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


def concept_worthy_line(text: str) -> bool:
    """Whether a raw chunk line is substantive enough to mine a theme from."""
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
    token_hits = [tok for tok in re.findall(r'[a-zA-Z]{3,}', low) if tok in LOW_VALUE_CONCEPTS]
    alpha_words = re.findall(r'[a-zA-Z]{3,}', line)
    if token_hits and len(alpha_words) <= len(token_hits) + 1:
        return False
    return len(alpha_words) >= 2


def _resolve_file_reference(reference: str, *, file_node_ids: dict[str, str],
                            file_paths: set[str],
                            file_path_by_basename: dict[str, list[str]]) -> str | None:
    """Resolve a ``*.md`` reference to a known file path, or None when ambiguous."""
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


def _build_chunk_semantic_summary(builder: GraphBuilder, concept_ids: list[str]) -> tuple[str, list[str], dict[str, str]]:
    """Summarise a chunk from the typed concept nodes it already produced."""
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


# ── files/chunks branch: the patterns the chunk phase reads ─────────────
_FILE_REF_PATTERN = re.compile(r'`([^`]+\.md)`|\b((?:memory/)?[A-Za-z0-9._-]+\.md)\b')
_HEADING_PATTERN = re.compile(r'^#{2,3}\s+(.+)', re.MULTILINE)
_ACTIVATE_PATTERN = re.compile(r'^#\s+([A-Z][a-z]+)-Activate\s+Report', re.MULTILINE)
_THEMATIC_PATTERNS = [
    ('decision', re.compile(r'^(?:[-*]\s*)?(?:decision|decided|decision made)\s*[:\-]\s*(.+)$', re.IGNORECASE | re.MULTILINE)),
    ('issue', re.compile(r'^(?:[-*]\s*)?(?:issue|problem|risk|blocker|concern)\s*[:\-]\s*(.+)$', re.IGNORECASE | re.MULTILINE)),
    ('project', re.compile(r'^(?:[-*]\s*)?(?:project|workstream|initiative|goal|focus)\s*[:\-]\s*(.+)$', re.IGNORECASE | re.MULTILINE)),
    ('outcome', re.compile(r'^(?:[-*]\s*)?(?:outcome|result|status|next step|next steps)\s*[:\-]\s*(.+)$', re.IGNORECASE | re.MULTILINE)),
]
_THEMATIC_LINE_PATTERNS = [
    ('decision', re.compile(r'^(?:[-*]\s*)?(?:we\s+)?(?:decided to|will|should|need to|plan to)\s+(.+)$', re.IGNORECASE)),
    ('issue', re.compile(r'^(?:[-*]\s*)?(?:the\s+)?(?:main\s+)?(?:issue|problem|risk|blocker|concern)\s+(?:is|was|remains)\s+(.+)$', re.IGNORECASE)),
    ('project', re.compile(r'^(?:[-*]\s*)?(?:work\s+on|working\s+on|focused\s+on|focus\s+on)\s+(.+)$', re.IGNORECASE)),
    ('outcome', re.compile(r'^(?:[-*]\s*)?(?:result|outcome|status|next\s+step|next\s+steps)\s+(?:is|was|remains)\s+(.+)$', re.IGNORECASE)),
]
_SEMANTIC_ENTITY_PATTERNS = [
    ('person', re.compile(r'\b(?:Wayne|Hal|Jarvis|Nexus|Marlowe|Del|Rook|Vigil|Chief|Sarah|Juno|Kai)\b')),
    ('organization', re.compile(r'\b(?:OpenClaw|Gigabrain|LCM|OpenStinger|Engram|GitHub|Tailscale|WhatsApp|Qwen|Copilot|systemd)\b', re.IGNORECASE)),
    ('place', re.compile(r'\b(?:WSL|WSL2|Windows|Ubuntu|Linux|workspace|gateway)\b', re.IGNORECASE)),
]
_THEMATIC_HEADING_PATTERNS = [
    ('decision', re.compile(r'^(?:decision|decisions)\b\s*[:\-]?\s*(.+)?$', re.IGNORECASE)),
    ('issue', re.compile(r'^(?:issue|issues|problem|problems|risk|risks|blocker|blockers)\b\s*[:\-]?\s*(.+)?$', re.IGNORECASE)),
    ('project', re.compile(r'^(?:project|projects|workstream|workstreams|initiative|initiatives|focus)\b\s*[:\-]?\s*(.+)?$', re.IGNORECASE)),
    ('outcome', re.compile(r'^(?:outcome|outcomes|status|next step|next steps|result|results)\b\s*[:\-]?\s*(.+)?$', re.IGNORECASE)),
]
_SEMANTIC_LINK_LABELS = {
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
_SEMANTIC_LINK_WEIGHTS = {
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
_EMBEDDING_SIMILARITY_THRESHOLD = 0.75


def _canonical_entity_patterns(life_index: dict) -> list[tuple[str, re.Pattern[str]]]:
    """Entity patterns derived from the life index's typed aliases."""
    patterns: list[tuple[str, re.Pattern[str]]] = []
    for alias, record in life_index.get('aliases', {}).items():
        rtype = str(record.get('type') or '').strip().lower()
        if rtype not in {'person', 'organization', 'place', 'project', 'system', 'repo', 'workflow', 'decision', 'issue', 'outcome', 'preference', 'agent'}:
            continue
        if not alias or len(alias) < 3:
            continue
        patterns.append((rtype, re.compile(rf'\b{re.escape(alias)}\b', re.IGNORECASE)))
    return patterns


def load_from_memory_db(dbpath: str, include_all: bool = False) -> Graph:
    """Load nodes/edges from an OpenClaw memory SQLite DB into a Graph model.

    ``include_all`` skips the default registry filter (status/value_score/stale)
    — used by ``kgraph update --include-all`` for audit runs.
    """
    conn = sqlite3.connect(os.path.expanduser(dbpath))
    try:
        return _load_from_memory_db_conn(conn, dbpath, include_all)
    finally:
        conn.close()


class _MemoryStoreIngest:
    """Import the files/chunks memory-store schema, phase by phase.

    Phases — each callable on its own against fixture rows:

    * ``ingest_files``   ``files`` table → file nodes + the path/basename index
    * ``ingest_chunks``  ``chunks`` table → chunk nodes, their derived
      actor/topic/theme/summary nodes, mentions/reference/coverage edges and the
      embedding vectors for the similarity pass (the co-occurrence accumulator
      runs here too)
    * ``emit_semantic_edges``   the accumulated co-occurrence → scored edges
    * ``emit_embedding_edges``  cross-file embedding similarity → related edges

    Node typing is ``add_actor_node`` / ``add_topic_node`` / ``add_theme_node``,
    built on ``canonicalize_concept`` (label → canonical form or None) and
    ``infer_concept_kind`` (topic → decision/issue/outcome/project/…).
    """

    def __init__(self, builder: GraphBuilder) -> None:
        self.builder = builder
        self.life_index = load_life_index()
        self.entity_patterns = _SEMANTIC_ENTITY_PATTERNS + _canonical_entity_patterns(self.life_index)
        # File lookup tables, populated by ingest_files and extended by
        # ingest_chunks when a referenced path is not in the ``files`` table.
        self.file_paths: set[str] = set()
        self.file_node_ids: dict[str, str] = {}
        self.file_path_by_basename: dict[str, list[str]] = {}
        # GRAPHRAG-ARCH-007: the documents asserting whatever is emitted next.
        # Bound once per chunk by ingest_chunks and cleared after the loop.
        self.chunk_source = ''
        self.file_source = ''
        # Co-occurrence accumulation (phase 4) and its node-type cache.
        self.pair_stats: dict[tuple[str, str], dict[str, Any]] = {}
        self._node_type_cache: dict[str, str] = {}

    # ── emitters ───────────────────────────────────────────────────────
    def add_node(self, node: dict) -> None:
        self.builder.add_node(node)

    def add_edge(self, edge: dict) -> None:
        self.builder.add_edge(_bind_edge_sources(edge, self.chunk_source, self.file_source))

    # ── node typing ────────────────────────────────────────────────────
    def add_actor_node(self, name: str, role: str = '') -> str:
        actor_id = f"actor:{slugify(name)}"
        self.add_node({
            'id': actor_id,
            'label': name,
            'type': 'actor',
            'role': role,
            'content_preview': role or f'Actor: {name}',
        })
        return actor_id

    def add_topic_node(self, heading_text: str) -> 'str | None':
        """Create a topic node from a markdown heading; returns id or None for trivial headings."""
        clean = re.sub(r'[^\x00-\x7E]', '', heading_text).strip()
        clean = re.sub(r'\s+', ' ', clean)
        if len(clean) < 4:
            return None
        tid = f'topic:{slugify(clean[:60])}'
        self.add_node({
            'id': tid,
            'label': clean[:60],
            'type': 'topic',
            'content_preview': clean,
        })
        return tid

    def canonicalize_concept(self, kind: str, label: str) -> str | None:
        """Canonical form of a concept label, or None when it is not concept-worthy."""
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
        if not clean or clean in SCAFFOLDING_LABELS:
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
        if not clean or clean in SCAFFOLDING_LABELS:
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
        if len(clean.split()) >= 3 and any(tok in clean.split() for tok in WRAPPER_TERMS):
            substantive = [w for w in clean.split() if w not in WRAPPER_TERMS]
            if len(substantive) >= 2:
                clean = ' '.join(substantive)

        for alias, canonical in CONCEPT_ALIASES.items():
            if clean == alias or clean.startswith(alias + ' ') or clean.endswith(' ' + alias) or alias in clean:
                clean = canonical
                break

        canon_record = self.life_index.get('aliases', {}).get(normalize_canonical_name(clean))
        if canon_record:
            clean = str(canon_record.get('title') or clean).strip().lower()

        if clean in LOW_VALUE_CONCEPTS and not canon_record and kind in {'topic', 'project', 'issue', 'decision', 'outcome', 'person', 'organization', 'place'}:
            return None

        if len(clean) < 4:
            return None
        words = clean.split()
        if len(words) > 4:
            clean = ' '.join(words[:4])
        return clean.strip(' .:-') or None

    def infer_concept_kind(self, kind: str, clean: str, preview: str = '') -> str:
        """Refine a generic 'topic' into decision/issue/outcome/project from its text."""
        text = f"{clean} {preview or ''}".lower()
        canon_record = self.life_index.get('aliases', {}).get(normalize_canonical_name(clean))
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

    def add_theme_node(self, kind: str, label: str, preview: str = '') -> str | None:
        """Canonicalise + type a concept and emit its node; None when not worthy."""
        clean = self.canonicalize_concept(kind, label)
        if not clean:
            return None
        canon_record = self.life_index.get('aliases', {}).get(normalize_canonical_name(clean))
        inferred_kind = self.infer_concept_kind(kind, clean, preview)
        if canon_record and canon_record.get('type'):
            canonical_type = str(canon_record.get('type') or '').strip().lower()
            if canonical_type in {'person', 'organization', 'place', 'project', 'decision', 'issue', 'outcome', 'workflow', 'system', 'repo', 'preference', 'agent'}:
                inferred_kind = canonical_type
        inferred = inferred_kind != kind
        canonical_label = str(canon_record.get('title') or clean) if canon_record else clean
        node_id = f'{inferred_kind}:{slugify(canonical_label[:80])}'
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
        self.add_node(payload)
        return node_id

    def extract_semantic_entities(self, text: str) -> list[tuple[str, str]]:
        """Known people/orgs/places named in the text, canonicalised and de-duped."""
        found = []
        seen = set()
        for entity_kind, pat in self.entity_patterns:
            for match in pat.finditer(text or ''):
                raw = match.group(0).strip()
                label = self.canonicalize_concept(entity_kind, raw) or raw.strip().lower()
                if not label:
                    continue
                canon_record = self.life_index.get('aliases', {}).get(normalize_canonical_name(label))
                if canon_record:
                    label = str(canon_record.get('title') or label).strip().lower()
                    entity_kind = str(canon_record.get('type') or entity_kind).strip().lower()
                key = (entity_kind, label)
                if key in seen:
                    continue
                seen.add(key)
                found.append((entity_kind, label))
        return found

    # ── co-occurrence scoring (phase 4) ────────────────────────────────
    def node_type_for(self, node_id: str) -> str:
        if node_id in self._node_type_cache:
            return self._node_type_cache[node_id]
        n = self.builder.get_node(node_id)
        self._node_type_cache[node_id] = (n.type if n and hasattr(n, 'type') else '')
        return self._node_type_cache[node_id]

    def connect_semantic_concepts(self, concept_ids: list[str], chunk_source: str) -> None:
        """Accumulate every ordered concept pair seen in ONE chunk."""
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
                a_type = self.node_type_for(a)
                b_type = self.node_type_for(b)
                if not a_type or not b_type:
                    continue
                label = _SEMANTIC_LINK_LABELS.get((a_type, b_type)) or _SEMANTIC_LINK_LABELS.get((b_type, a_type)) or 'related concept'
                pair = (a, b) if a <= b else (b, a)
                stat = self.pair_stats.setdefault(
                    pair, {'count': 0, 'score': 0.0, 'labels': {}, 'sources': set()})
                stat['count'] += 1
                stat['score'] += _SEMANTIC_LINK_WEIGHTS.get(label, 0.4)
                stat['labels'][label] = stat['labels'].get(label, 0) + 1
                if chunk_source:
                    stat['sources'].add(chunk_source)

    def emit_semantic_edges(self) -> None:
        """Phase 4: score the accumulated pairs and emit the ones that clear the cut."""
        for (a, b), stat in self.pair_stats.items():
            best_label = max(stat['labels'].items(), key=lambda item: (item[1], _SEMANTIC_LINK_WEIGHTS.get(item[0], 0.0)))[0]
            avg_score = stat['score'] / max(stat['count'], 1)
            keep = stat['count'] >= 2 or avg_score >= 0.95
            if best_label in {'project topic', 'topic decision', 'topic issue', 'topic outcome', 'actor issue', 'actor outcome'}:
                keep = keep and stat['count'] >= 2 and avg_score >= 0.58
            if best_label == 'related concept':
                keep = stat['count'] >= 3 and avg_score >= 0.45
            if not keep:
                continue
            # semantic_score and the label-visibility cut-off below are
            # UN-CALIBRATED hand-picked defaults (GRAPHRAG-JEV-005), kept as
            # they are in this pass: calibrating them needs a LABELLED edge
            # set — sampled edges each judged real / not-real by hand, drawn
            # from these same emitters — which this repo does not have, and
            # inventing one to justify the numbers is forbidden.  A real
            # calibration is a precision-recall curve over `semantic_score`
            # (precision at the threshold with its recall, not accuracy),
            # choosing the lowest threshold whose precision stays above the
            # cost of asserting a wrong edge; see scripts/kgraph/confidence.py
            # for the same note on the classification thresholds.
            #
            # REF: "GraphRAG with TypeSafe Jev: A System One Approach to
            # Scalable Knowledge Graphs" (Partha Sarkar, TDS, 2026-09-27) —
            # https://towardsdatascience.com/graphrag-with-typesafe-jev-a-system-one-approach-to-scalable-knowledge-graphs/
            # 0.55 base + 0.12/co-occurrence (capped at 3) + 0.18*avg_score,
            # capped at 0.99: the coefficients are picked, not fitted.
            semantic_score = round(min(0.99, 0.55 + (0.12 * min(stat['count'], 3)) + (0.18 * avg_score)), 3)
            self.add_edge({
                'from': a,
                'to': b,
                'label': best_label,
                'visibility': 'both',
                'quality_tier': 'semantic',
                'semantic_score': semantic_score,
                'cooccurrence_count': stat['count'],
                # 0.86 is another UN-CALIBRATED pick (see the note above): it
                # decides which labels are shown by default rather than on
                # hover, and no labelled set has measured where that line
                # should fall.
                'label_visibility': 'visible' if semantic_score >= 0.86 or stat['count'] >= 3 else 'hover',
                # Every chunk that produced this pair — the aggregate's whole
                # evidence set, which is exactly the case the article warns
                # can grow into a very large array (bounded in models.py).
                'sources': sorted(stat['sources']),
            })

    def emit_embedding_edges(self, chunk_embeddings: list[tuple[str, str, list[float], float]]) -> None:
        """Phase 4: cross-file-only embedding similarity → 'related (…)' edges."""
        for i in range(len(chunk_embeddings)):
            cid_a, path_a, vec_a, mag_a = chunk_embeddings[i]
            for j in range(i + 1, len(chunk_embeddings)):
                cid_b, path_b, vec_b, mag_b = chunk_embeddings[j]
                if path_a == path_b:
                    continue
                # Cosine similarity is undefined for mismatched dimensions
                # (zip() would silently truncate and yield a bogus score).
                if len(vec_a) != len(vec_b):
                    continue
                dot = sum(a * b for a, b in zip(vec_a, vec_b))
                sim = dot / (mag_a * mag_b)
                if sim >= _EMBEDDING_SIMILARITY_THRESHOLD:
                    rounded = round(sim, 3)
                    # The similarity is asserted by the two chunks it joins:
                    # take their own recorded sources rather than rebuilding a
                    # key from the node id (which already carries the prefix).
                    endpoint_nodes = [self.builder.get_node(cid) for cid in (cid_a, cid_b)]
                    pair_sources = sorted({
                        key for node in endpoint_nodes if node is not None
                        for key in node.sources
                    })
                    self.add_edge({
                        'from': cid_a,
                        'to': cid_b,
                        'label': f'related ({sim:.2f})',
                        'semantic_score': rounded,
                        'sources': pair_sources,
                    })
                    if path_a and path_b:
                        self.add_edge({
                            'from': f'file:{path_a}',
                            'to': f'file:{path_b}',
                            'label': f'related ({sim:.2f})',
                            'semantic_score': rounded,
                            'sources': [source_key('file', path_a), source_key('file', path_b)],
                        })

    # ── phase: files table → file nodes + the reference index ──────────
    def ingest_files(self, cur: sqlite3.Cursor) -> None:
        try:
            cur.execute("SELECT path FROM files")
            for (path,) in cur.fetchall():
                if not path:
                    continue
                file_name = os.path.basename(path) or path
                self.file_paths.add(path)
                self.file_path_by_basename.setdefault(file_name, []).append(path)
                self.file_node_ids[path] = f'file:{path}'
                self.add_node({
                    'id': f'file:{path}',
                    'label': file_name,
                    'type': 'file',
                    'path': path,
                    'content_preview': f'File: {path}',
                    # A file node IS a document, so it names itself as its source.
                    'sources': [source_key('file', path)],
                })
        except sqlite3.Error as exc:
            logger.warning("Failed to read 'files' table from memory DB: %s", exc)

    # ── phase: chunks table → nodes, derived edges, embeddings ────────
    def ingest_chunks(self, cur: sqlite3.Cursor) -> list[tuple[str, str, list[float], float]]:
        chunk_embeddings: list[tuple[str, str, list[float], float]] = []
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

            # The two documents that can assert anything in this chunk:
            # the chunk record itself (which carries path + line range, so a
            # citation resolves) and the file it belongs to.
            chunk_source = source_key('chunk', chunk_key)
            file_source = source_key('file', path) if path else ''
            self.chunk_source = chunk_source
            self.file_source = file_source

            self.add_node({
                'id': f'chunk:{chunk_key}',
                'label': chunk_label,
                'type': 'chunk',
                'path': path or '',
                'start_line': start_line,
                'end_line': end_line,
                'chunk_id': chunk_key,
                'content_preview': preview,
                'sources': [chunk_source],
            })

            chunk_concepts = []

            if path:
                if path not in self.file_paths:
                    self.file_paths.add(path)
                    file_name = os.path.basename(path) or path
                    self.file_path_by_basename.setdefault(file_name, []).append(path)
                    self.file_node_ids[path] = f'file:{path}'
                    self.add_node({
                        'id': f'file:{path}',
                        'label': file_name,
                        'type': 'file',
                        'path': path,
                        'content_preview': f'File: {path}',
                    })
                self.add_edge({
                    'from': f'file:{path}',
                    'to': f'chunk:{chunk_key}',
                    'label': 'contains chunk',
                })

            for name, role in iter_actor_mentions(chunk_text or ''):
                actor_id = self.add_actor_node(name, role)
                chunk_concepts.append(actor_id)
                self.add_edge({
                    'from': f'chunk:{chunk_key}',
                    'to': actor_id,
                    'label': 'mentions actor',
                })
                if path:
                    self.add_edge({
                        'from': f'file:{path}',
                        'to': actor_id,
                        'label': 'mentions actor',
                    })

            for ref_a, ref_b in _FILE_REF_PATTERN.findall(chunk_text or ''):
                ref = ref_a or ref_b
                target_path = _resolve_file_reference(
                    ref,
                    file_node_ids=self.file_node_ids,
                    file_paths=self.file_paths,
                    file_path_by_basename=self.file_path_by_basename,
                )
                if not target_path or target_path == path:
                    continue
                self.add_edge({
                    'from': f'chunk:{chunk_key}',
                    'to': f'file:{target_path}',
                    'label': 'references file',
                })
                if path:
                    self.add_edge({
                        'from': f'file:{path}',
                        'to': f'file:{target_path}',
                        'label': 'references file',
                    })

            # Collect embedding vector for semantic similarity pass
            if emb_blob and isinstance(emb_blob, str):
                try:
                    vec = json.loads(emb_blob)
                    if isinstance(vec, list) and vec:
                        # Coerce to floats so non-numeric elements raise
                        # here (and are skipped) rather than corrupting the
                        # dot product later.
                        vec = [float(x) for x in vec]
                        mag = sum(x * x for x in vec) ** 0.5
                        if mag > 0:
                            chunk_embeddings.append((f'chunk:{chunk_key}', path or '', vec, mag))
                except (json.JSONDecodeError, ValueError, TypeError) as exc:
                    # One malformed embedding must not abort the whole import.
                    logger.debug(
                        "skipping malformed embedding for chunk %s: %s",
                        chunk_key, exc, exc_info=True,
                    )

            # Extract H2/H3 headings as topic nodes
            for hm in _HEADING_PATTERN.finditer(chunk_text or ''):
                topic_id = self.add_topic_node(hm.group(1))
                if topic_id:
                    chunk_concepts.append(topic_id)
                    self.add_edge({
                        'from': f'chunk:{chunk_key}',
                        'to': topic_id,
                        'label': 'covers topic',
                    })
                    if path:
                        self.add_edge({
                            'from': f'file:{path}',
                            'to': topic_id,
                            'label': 'covers topic',
                        })

            # Lift higher-level semantic themes from headings and explicit summary lines
            for hm in _HEADING_PATTERN.finditer(chunk_text or ''):
                heading_text = (hm.group(1) or '').strip()
                for kind, pat in _THEMATIC_HEADING_PATTERNS:
                    m = pat.match(heading_text)
                    if not m:
                        continue
                    derived = (m.group(1) or '').strip()
                    if not derived:
                        continue
                    theme_id = self.add_theme_node(kind, derived, preview=heading_text)
                    if theme_id:
                        chunk_concepts.append(theme_id)
                        self.add_edge({
                            'from': f'chunk:{chunk_key}',
                            'to': theme_id,
                            'label': f'has {kind}',
                        })
                        if path:
                            self.add_edge({
                                'from': f'file:{path}',
                                'to': theme_id,
                                'label': f'has {kind}',
                            })

            for kind, pat in _THEMATIC_PATTERNS:
                for match in pat.finditer(chunk_text or ''):
                    derived = (match.group(1) or '').strip()
                    theme_id = self.add_theme_node(kind, derived, preview=derived)
                    if theme_id:
                        chunk_concepts.append(theme_id)
                        self.add_edge({
                            'from': f'chunk:{chunk_key}',
                            'to': theme_id,
                            'label': f'has {kind}',
                        })
                        if path:
                            self.add_edge({
                                'from': f'file:{path}',
                                'to': theme_id,
                                'label': f'has {kind}',
                            })

            for raw_line in (chunk_text or '').splitlines():
                line = raw_line.strip()
                if not concept_worthy_line(line):
                    continue
                for kind, pat in _THEMATIC_LINE_PATTERNS:
                    m = pat.match(line)
                    if not m:
                        continue
                    derived = (m.group(1) or '').strip(' .:-')
                    theme_id = self.add_theme_node(kind, derived, preview=line)
                    if theme_id:
                        chunk_concepts.append(theme_id)
                        self.add_edge({
                            'from': f'chunk:{chunk_key}',
                            'to': theme_id,
                            'label': f'has {kind}',
                        })
                        if path:
                            self.add_edge({
                                'from': f'file:{path}',
                                'to': theme_id,
                                'label': f'has {kind}',
                            })
                        break

            # Detect activation-report authorship from H1 title
            for am in _ACTIVATE_PATTERN.finditer(chunk_text or ''):
                agent_name = am.group(1)
                role = AGENT_ROLES.get(agent_name, 'Agent')
                actor_id = self.add_actor_node(agent_name, role)
                chunk_concepts.append(actor_id)
                self.add_edge({
                    'from': f'chunk:{chunk_key}',
                    'to': actor_id,
                    'label': 'authored by',
                })
                if path:
                    self.add_edge({
                        'from': f'file:{path}',
                        'to': actor_id,
                        'label': 'authored by',
                    })

            for entity_kind, entity_label in self.extract_semantic_entities(chunk_text or ''):
                entity_id = self.add_theme_node(entity_kind, entity_label, preview=entity_label)
                if entity_id:
                    chunk_concepts.append(entity_id)
                    self.add_edge({
                        'from': f'chunk:{chunk_key}',
                        'to': entity_id,
                        'label': f'has {entity_kind}',
                    })

            semantic_summary, summary_labels, typed_summary = _build_chunk_semantic_summary(self.builder, chunk_concepts)
            if semantic_summary:
                summary_slug = slugify(semantic_summary[:120])
                summary_id = f'summary:{chunk_key}:{summary_slug}'
                self.add_node({
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
                self.add_edge({
                    'from': f'chunk:{chunk_key}',
                    'to': summary_id,
                    'label': 'semantic summary',
                    'visibility': 'semantic',
                    'quality_tier': 'semantic',
                })
                for summary_kind, summary_label in typed_summary.items():
                    summary_theme_id = self.add_theme_node(summary_kind if summary_kind != 'actor' else 'actor', summary_label, preview=semantic_summary)
                    if summary_theme_id:
                        self.add_edge({
                            'from': summary_id,
                            'to': summary_theme_id,
                            'label': f'summarizes {summary_kind}',
                            'visibility': 'semantic',
                            'quality_tier': 'semantic',
                        })

            self.connect_semantic_concepts(chunk_concepts, chunk_source)

        # Past the per-chunk loop: nothing below is asserted by "the last
        # chunk read", so clear the per-chunk binding and give these
        # aggregated edges their own explicit source lists.
        self.chunk_source = ''
        self.file_source = ''
        return chunk_embeddings


def _load_from_memory_db_conn(conn: sqlite3.Connection, dbpath: str, include_all: bool) -> Graph:
    """Build a Graph from an open memory-DB connection (caller closes it).

    Orchestrator only: detect the schema, run that branch's phases, then resolve
    cross-chunk duplicates and build.  Each phase lives in ``_MemoryStoreIngest``
    or the ``_import_registry_*`` functions.
    """
    cur = conn.cursor()
    builder = GraphBuilder()

    schema = _detect_schema(cur)
    if schema == 'files-chunks':
        ingest = _MemoryStoreIngest(builder)
        ingest.ingest_files(cur)
        try:
            chunk_embeddings = ingest.ingest_chunks(cur)
            ingest.emit_semantic_edges()
            ingest.emit_embedding_edges(chunk_embeddings)
        except sqlite3.Error as exc:
            logger.warning("Failed to import chunks from memory DB: %s", exc)
    elif schema == 'registry':
        _load_from_registry_db(conn, builder, registry=_registry_db_path_label(dbpath), include_all=include_all)

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


# A memory-system reference that is safe to turn into a source key: the ids the
# registry writes are uuids, slugs and ``native:<chunk_id>`` values.  Anything
# else came from an unparsed blob, and using it would fabricate lineage.
_SOURCE_ID_RE = re.compile(r'^[A-Za-z0-9][A-Za-z0-9._:@+-]*$')


def _memory_source_key(memory_reference: str) -> str:
    """Source key for a memory-system reference.

    A registry reference is either a memory uuid or ``native:<chunk_id>`` for a
    native chunk; the second becomes a ``chunk:`` key so it matches the key the
    files/chunks branch (and the native-chunk node here) records for the same
    document.
    """
    ref = str(memory_reference or '').strip()
    if ref.startswith('native:'):
        return source_key('chunk', ref[len('native:'):])
    return source_key('memory', ref)


def _parse_source_memory_ids(value: Any) -> list[str]:
    """Best-effort parse of ``memory_entity_relationships.source_memory_ids``.

    The column is TEXT and its contents are not documented anywhere in this
    repo; readers upstream pass it through as-is into edge ``metadata``.  The
    shapes a memory registry plausibly writes are accepted (a list of ids, a
    JSON array, a comma-separated string) and every candidate is then required
    to LOOK like an id — anything else is dropped with a DEBUG line, because
    inventing lineage from a value that failed to parse is worse than recording
    none.
    """
    if value is None:
        return []

    if isinstance(value, (list, tuple, set)):
        candidates = [str(v) for v in value]
    else:
        text = str(value).strip()
        if not text:
            return []
        if text.startswith('['):
            try:
                parsed = json.loads(text)
            except json.JSONDecodeError as exc:
                logger.debug("unparseable source_memory_ids %r: %s", text, exc, exc_info=True)
                return []
            if not isinstance(parsed, list):
                logger.debug("source_memory_ids JSON is %s, not a list", type(parsed).__name__)
                return []
            candidates = [str(v) for v in parsed]
        else:
            candidates = text.split(',') if ',' in text else [text]

    ids = []
    rejected = []
    for candidate in candidates:
        ref = candidate.strip()
        if not ref:
            continue
        if _SOURCE_ID_RE.match(ref):
            ids.append(ref)
        else:
            rejected.append(ref)
    if rejected:
        logger.debug("ignored %d non-id source_memory_ids value(s), e.g. %r",
                     len(rejected), rejected[0])
    return ids


class _RegistrySink:
    """A ``GraphBuilder`` plus the node/edge counters the registry INFO line reports.

    ``add_node`` counts only a node id that was not already present; ``add_edge``
    counts every emitted edge, whether or not the builder stored it (a missing
    endpoint is dropped by ``GraphBuilder.add_edge``).
    """

    def __init__(self, builder: GraphBuilder) -> None:
        self.builder = builder
        self.nodes = 0
        self.edges = 0

    def add_node(self, node: dict) -> None:
        node_id = node.get('id')
        if node_id and not self.builder.has_node(node_id):
            self.nodes += 1
        self.builder.add_node(node)

    def add_edge(self, edge: dict) -> None:
        self.builder.add_edge(edge)
        self.edges += 1


def _registry_row_is_live(row: dict, include_all: bool) -> bool:
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


def _registry_promoted_contents(cur: sqlite3.Cursor) -> set[str]:
    """Canonicalised contents of the ``memories`` rows ('' when the table is absent).

    A promoted memory (``memories.source_layer='promoted_native'``) and its raw
    native chunk are the same fact in two tables; importing both creates an
    unconnected duplicate, so ``_import_registry_native_chunks`` skips chunks
    already imported as memories.
    """
    promoted: set[str] = set()
    if not _has_table(cur, 'memories'):
        return promoted
    for r in cur.execute("SELECT content FROM memories"):
        content = (r['content'] or '').strip()
        if content:
            promoted.add(normalize_canonical_name(content))
    return promoted


def _import_registry_memories(cur: sqlite3.Cursor, sink: _RegistrySink,
                              registry: str, include_all: bool) -> None:
    """Phase: memories → memory:{uuid} nodes."""
    for row in cur.execute(
        "SELECT id, type, content, source_agent, scope, tags, confidence, created_at,"
        "       concept, value_score, value_label, source_layer, status"
        "  FROM memories"
    ):
        d = dict(row)
        if not _registry_row_is_live(d, include_all):
            continue
        sink.add_node({
            'id': f"memory:{d['id']}",
            'label': _preview_text(d.get('content')),
            'type': 'memory',
            'origin': 'memory_db',
            # A memory node IS the source document; it names itself.
            'sources': [source_key('memory', d['id'])],
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


def _import_registry_native_chunks(cur: sqlite3.Cursor, sink: _RegistrySink,
                                   registry: str, include_all: bool,
                                   promoted_contents: set[str]) -> None:
    """Phase: memory_native_chunks → memory:native:{chunk_id} nodes."""
    for row in cur.execute(
        "SELECT chunk_id, source_path, source_kind, section, line_start, line_end,"
        "       content, scope, status"
        "  FROM memory_native_chunks"
    ):
        d = dict(row)
        if not _registry_row_is_live(d, include_all):
            continue
        chunk_content = (d.get('content') or '').strip()
        if chunk_content and normalize_canonical_name(chunk_content) in promoted_contents:
            continue
        sink.add_node({
            'id': f"memory:native:{d['chunk_id']}",
            'label': _preview_text(d.get('content')),
            'type': 'memory',
            'origin': 'memory_db',
            # The native chunk is a chunk of a source document, so it carries
            # the same key shape the files/chunks branch uses for chunks.
            'sources': [source_key('chunk', d['chunk_id'])],
            'registry': registry,
            'row_scope': d.get('scope'),
            'content': d.get('content'),
            'source_path': d.get('source_path'),
            'source_kind': d.get('source_kind'),
            'section': d.get('section'),
            'line_start': d.get('line_start'),
            'line_end': d.get('line_end'),
        })


def _import_registry_entities(cur: sqlite3.Cursor, sink: _RegistrySink, registry: str) -> dict[str, str]:
    """Phase: memory_entities → entity:{kind}:{slug} nodes; returns key→node-id."""
    entity_row_ids: dict[str, str] = {}  # normalized_name → preferred id
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
        sink.add_node({
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
    return entity_row_ids


def _import_registry_mentions(cur: sqlite3.Cursor, sink: _RegistrySink,
                              registry: str, entity_row_ids: dict[str, str]) -> None:
    """Phase: memory_entity_mentions → entity nodes + mentions edges."""
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
            sink.add_node({
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
            native_id = mem_id[len('native:'):]
            src = f"memory:native:{native_id}"
            mention_source = source_key('chunk', native_id)
        else:
            src = f"memory:{mem_id}"
            mention_source = source_key('memory', mem_id)
        sink.add_edge({
            'from': src,
            'to': ent_id,
            'label': 'mentions',
            'origin': 'memory_db',
            # The memory (or native chunk) whose text mentioned the entity.
            'sources': [mention_source],
            'registry': registry,
            'role': d.get('role'),
            'metadata': {'confidence': d.get('confidence')},
        })


def _import_registry_relationships(cur: sqlite3.Cursor, sink: _RegistrySink, registry: str) -> None:
    """Phase: memory_entity_relationships → entity→entity edges."""
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
        sink.add_edge({
            'from': f"entity:{src}",
            'to': f"entity:{tgt}",
            'label': rel,
            'origin': 'memory_db',
            # The relationship row names its own evidence in
            # source_memory_ids — lift it out of metadata so the edge can be
            # cited and so removing one of those memories subtracts this edge
            # only when it was the last one supporting it.
            'sources': sorted({
                _memory_source_key(mid)
                for mid in _parse_source_memory_ids(d.get('source_memory_ids'))
                if str(mid or '').strip()
            }),
            'registry': registry,
            'evidence_count': d.get('evidence_count'),
            'metadata': {
                'source_memory_ids': d.get('source_memory_ids'),
                'confidence': d.get('confidence'),
            },
        })


def _import_registry_syntheses(cur: sqlite3.Cursor, sink: _RegistrySink,
                               registry: str, include_all: bool) -> None:
    """Phase: memory_syntheses → synthesis:{id} nodes (stale=0 unless include_all)."""
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
        sink.add_node({
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


def _import_registry_claims(cur: sqlite3.Cursor, sink: _RegistrySink, registry: str) -> None:
    """Phase: memory_claims → claim:{memory_id}:{slot} nodes (+ claims edges)."""
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
        sink.add_node({
            'id': claim_id,
            'label': label,
            'type': 'claim',
            'origin': 'memory_db',
            # The claim was consolidated out of that memory, so the memory is
            # the document that asserts it.
            'sources': [source_key('memory', mem_id)],
            'registry': registry,
            'memory_tier': d.get('memory_tier'),
            'consolidation_op': d.get('consolidation_op'),
            'source_strength': d.get('source_strength'),
        })
        # Link the claim to the memory it was consolidated from; the
        # claim id embeds the memory uuid but the edge makes the
        # relationship traversable ("who claims what").
        memory_id = f"memory:{mem_id}"
        if sink.builder.has_node(memory_id):
            sink.add_edge({'from': memory_id, 'to': claim_id, 'label': 'claims',
                           'confidence': 'EXTRACTED',
                           'sources': [source_key('memory', mem_id)]})


def _import_registry_beliefs(cur: sqlite3.Cursor, sink: _RegistrySink,
                             registry: str, include_all: bool) -> None:
    """Phase: memory_beliefs → belief:{id} nodes."""
    for row in cur.execute(
        "SELECT belief_id, entity_id, type, content, status, confidence,"
        "       source_memory_id, source_layer"
        "  FROM memory_beliefs"
    ):
        d = dict(row)
        # Schema default is 'current' (memory_beliefs.status), so a belief
        # with the default status is live; only superseded/retracted drop.
        if not include_all and str(d.get('status') or 'current') != 'current':
            continue
        sink.add_node({
            'id': f"belief:{d['belief_id']}",
            'label': _preview_text(d.get('content')),
            'type': 'belief',
            'origin': 'memory_db',
            # The belief row names the memory it came from; carry it as
            # lineage when it is present, and nothing when it is NULL.
            'sources': ([_memory_source_key(d['source_memory_id'])]
                        if d.get('source_memory_id') else []),
            'registry': registry,
            'entity_id': d.get('entity_id'),
            'belief_type': d.get('type'),
            'confidence': str(d.get('confidence')) if d.get('confidence') is not None else None,
            'source_memory_id': d.get('source_memory_id'),
            'source_layer': d.get('source_layer'),
        })


def _import_registry_open_loops(cur: sqlite3.Cursor, sink: _RegistrySink,
                                registry: str, include_all: bool) -> None:
    """Phase: memory_open_loops → open_loop:{id} nodes."""
    for row in cur.execute(
        "SELECT loop_id, kind, title, status, priority, related_entity_id"
        "  FROM memory_open_loops"
    ):
        d = dict(row)
        if not include_all and str(d.get('status') or 'open') != 'open':
            continue
        sink.add_node({
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


def _registry_events_skipped(cur: sqlite3.Cursor) -> int:
    """Count memory_events rows (never imported), or -1 when the table is unreadable."""
    try:
        return cur.execute("SELECT COUNT(*) FROM memory_events").fetchone()[0]
    except sqlite3.Error:
        return -1


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

    Orchestrator only: each table's mapping lives in an ``_import_registry_*``
    function so it can be exercised on its own; this function sequences them and
    reports the totals.

    Logs node/edge counts at INFO (Hal review note §3.3a) so a future
    "KG is empty" alarm has a trace.
    """
    # Registry branch consumes rows as dicts; the files/chunks branch uses
    # tuple indexing on the same connection — Row supports both, so set it
    # before creating the cursor (idempotent).
    conn.row_factory = sqlite3.Row
    cur = conn.cursor()
    sink = _RegistrySink(builder)

    if _has_table(cur, 'memories'):
        _import_registry_memories(cur, sink, registry, include_all)

    promoted_contents = _registry_promoted_contents(cur)
    if _has_table(cur, 'memory_native_chunks'):
        _import_registry_native_chunks(cur, sink, registry, include_all, promoted_contents)

    entity_row_ids: dict[str, str] = {}
    if _has_table(cur, 'memory_entities'):
        entity_row_ids = _import_registry_entities(cur, sink, registry)

    if _has_table(cur, 'memory_entity_mentions'):
        _import_registry_mentions(cur, sink, registry, entity_row_ids)

    if _has_table(cur, 'memory_entity_relationships'):
        _import_registry_relationships(cur, sink, registry)

    if _has_table(cur, 'memory_syntheses'):
        _import_registry_syntheses(cur, sink, registry, include_all)

    if _has_table(cur, 'memory_claims'):
        _import_registry_claims(cur, sink, registry)

    if _has_table(cur, 'memory_beliefs'):
        _import_registry_beliefs(cur, sink, registry, include_all)

    if _has_table(cur, 'memory_open_loops'):
        _import_registry_open_loops(cur, sink, registry, include_all)

    events_skipped = 0
    if _has_table(cur, 'memory_events'):
        events_skipped = _registry_events_skipped(cur)

    logger.info(
        "registry import (registry=%s, include_all=%s): %d nodes, %d edges, "
        "%d events skipped",
        registry, include_all, sink.nodes, sink.edges, events_skipped,
    )
