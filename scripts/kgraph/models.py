"""Pydantic models for kgraph graph data.

Canonical schema for nodes, edges, and graphs. All kgraph modules
should use these models instead of raw dicts.

Edge endpoints are canonicalised to ``source`` / ``target``.
Legacy ``from`` / ``to`` keys are accepted during deserialization
and mapped automatically.

``origin`` (singular) records WHERE an element came from (the extractor:
``"ast"``, ``"memory_db"``, ``"life_index"``).  ``sources`` (plural) records
WHICH source documents assert the element — the lineage used for citations and
for removing exactly one source.  They are deliberately separate fields.
"""

from __future__ import annotations

import re
from collections.abc import Iterable
from enum import Enum
from typing import Any

from pydantic import BaseModel, ConfigDict, Field, model_validator

from .constants import CONCEPT_ALIASES, STOPWORDS

# ── Source lineage (GRAPHRAG-ARCH-007) ─────────────────────────────────
# REF: "GraphRAG: A Practitioner's Guide to 6 Advanced Architectural Patterns"
#      (Partha Sarkar, TDS, 2026-09-20) — https://towardsdatascience.com/graphrag-a-practitioners-guide-to-6-advanced-architectural-patterns/
#
# The article's Challenge 3 (Graph Maintenance and Synchronization): "Every node
# and edge in the graph database must contain an array property of
# source_document_ids. When a document is deleted, query the graph for all
# elements containing that ID. Remove the ID from the array. If the array
# becomes empty, delete the node/edge."
#
# The console had the *origin* tag ("which extractor") and no document identity:
# an edge asserted by a source could not be cited, and a deleted document could
# not be subtracted from the graph.  The key below is the source_document_id.
#
# Shape decision — one key is a DOCUMENT identity, not a revision: ``<kind>:<locator>``
# with kind in {memory, chunk, file, life}.  No content hash is included on
# purpose: the article's protocol is "remove THIS document's id", which a hashed
# key cannot express (a hashed key would need a glob to remove, and every edit of
# a file would add a second key instead of replacing the first — the array-growth
# problem the article warns about in the same section).
SOURCE_KEY_KINDS = ("memory", "chunk", "file", "life")

# The article warns that "storing source_chunk_ids as node property may result in
# a very large array ... not recommended".  The same array is unavoidable when a
# fact has several asserting documents, so it is bounded here: the union keeps the
# lexicographically first MAX_SOURCES_PER_ELEMENT keys (stable as more arrive) and
# records the true count in ``metadata["sources_overflow"]`` so a truncated list is
# never mistaken for the whole set.
#
# Measured before choosing an inline array over a separate element→source table
# (2026-09-23, extract_repo_graph over this repo — the corpus that builds the live
# graph): 2414 nodes / 5173 edges; longest edge source array 1 (643 edges carry
# none — the derived joins), longest node source array 24 (a function name defined
# in 24 files and collapsed onto one name-keyed ``ast_func`` id).  The AST path
# therefore sits well inside a 64-entry inline array.  The memory-registry path
# could not be measured — no registry DB is present on this machine — and is the
# path that would push this toward a side table: if its aggregated pair edges
# routinely reach the bound, ``metadata["sources_overflow"]`` is what will say so.
MAX_SOURCES_PER_ELEMENT = 64

# The shortest normalised semantic key that may group two nodes.
#
# The key IS the identity: two nodes collapse only when their normalised labels
# are byte-equal, so a short key cannot merge two DIFFERENT labels — it can only
# merge labels that normalise identically.  3 is the floor because a 1-2 character
# key is a fragment left behind by stopword/punctuation stripping ("gw", "ok"),
# while a 3-character key ("git", "api", "wsl", "ceo", "sql") is a complete word
# and a legitimate concept name.  Extraction-time dedup applied this floor to the
# final key; view-time dedup applied 4 and also gated the pre-alias label at 4, so
# a 3-character key was collapsed by one path and skipped by the other — the
# disagreement card 27b55b6f records.
MIN_SEMANTIC_KEY_LEN = 3

# Node types eligible for semantic collapse.  One declaration: the ingest path and
# the view path grouped on their own copies of this set.
DEFAULT_SEMANTIC_TYPES = frozenset({
    "topic", "project", "decision", "issue", "outcome", "organization", "place", "person",
})


def source_key(kind: str, locator: str) -> str:
    """Canonical source key ``<kind>:<locator>`` for one source document.

    Defined once, here, because three ingest modules (``memory_import``,
    ``ast_extractor``, ``life_index``) construct keys and they must agree: a
    merge unions the lists and a removal subtracts one key, so a shape drift
    between the ingest paths would silently make both no-ops.
    """
    if kind not in SOURCE_KEY_KINDS:
        raise ValueError(f"unknown source kind {kind!r}; expected one of {SOURCE_KEY_KINDS}")
    clean = str(locator or "").strip()
    if not clean:
        raise ValueError(f"empty locator for source kind {kind!r}")
    return f"{kind}:{clean}"


# ── Confidence ─────────────────────────────────────────────────────────


class ConfidenceLevel(str, Enum):
    """Edge confidence classification."""

    EXTRACTED = "EXTRACTED"
    INFERRED = "INFERRED"
    AMBIGUOUS = "AMBIGUOUS"


# ── Node ───────────────────────────────────────────────────────────────


class SourceLineage(BaseModel):
    """Mixin carrying an element's source documents (``sources``).

    Both ``GraphNode`` and ``GraphEdge`` inherit this, so the union rule, the
    array bound and the removal rule exist once instead of twice.  ``sources``
    is a list of :func:`source_key` values — the source documents that assert
    this element; an empty list means "no lineage recorded" (an element written
    before the field existed, or one derived from other elements rather than
    from a document), NOT "no sources exist".
    """

    sources: list[str] = Field(default_factory=list)
    # Declared here because merge_sources records the array bound in it; both
    # subclasses used to declare their own identical copy.
    metadata: dict[str, Any] = Field(default_factory=dict)

    def merge_sources(self, incoming: Iterable[str]) -> None:
        """Union *incoming* source keys into this element (sorted, bounded).

        Sorted so the stored list is deterministic, and bounded by
        :data:`MAX_SOURCES_PER_ELEMENT`; when the bound truncates, the true
        count is recorded in ``metadata["sources_overflow"]`` so a reader can
        tell a complete list from a capped one.
        """
        keys = {str(s).strip() for s in incoming if str(s or "").strip()}
        if not keys:
            return
        merged = sorted(set(self.sources) | keys)
        if len(merged) > MAX_SOURCES_PER_ELEMENT:
            self.metadata["sources_overflow"] = len(merged)
            merged = merged[:MAX_SOURCES_PER_ELEMENT]
        self.sources = merged

    def drop_source(self, key: str) -> bool:
        """Remove *key* from ``sources``; True when the list became empty.

        An element that never carried the key is left alone — "no lineage" is
        not "no sources", so the removal protocol must not delete it.
        """
        if key not in self.sources:
            return False
        self.sources = [s for s in self.sources if s != key]
        return not self.sources

    def bound_sources(self) -> None:
        """Normalise and bound a freshly built element's ``sources``.

        First insertion bypasses the union path, so an element created with a
        large list (an aggregated edge with many contributing documents) has to
        be sorted and capped here or the array bound would only apply to merges.
        """
        self.merge_sources(self.sources)


class GraphNode(SourceLineage):
    """A single node in the knowledge graph.

    Core fields (``id``, ``label``) are required.  All other fields
    carry sensible defaults so that partially-specified dicts from
    legacy sources deserialize cleanly.

    Extra fields added during processing (``degree``, ``importance``,
    ``display_label``, ``semantic_degree``, ``display_group``, ``visual_role``)
    are declared below and set by ``projection.project_graph``; an UNKNOWN field
    is REJECTED (card d25d3b8b) rather than silently kept.
    """

    model_config = ConfigDict(extra="forbid", populate_by_name=True)

    id: str
    label: str = ""
    type: str = "unknown"
    content_preview: str = ""
    path: str = ""
    role: str = ""
    confidence: str = ""
    source: str = ""
    description: str = ""
    language: str = ""
    file: str = ""
    line: int | None = None
    col: int | None = None
    parent: str = ""
    children: list[str] = Field(default_factory=list)
    slug: str = ""
    group: str = ""
    visibility: str = "both"
    quality_tier: str = "semantic"
    inferred_type: bool = False
    type_confidence: float = 1.0
    canonical_slug: str = ""
    canonical_path: str = ""
    # View-projection fields set by projection.project_graph (were extra="allow").
    degree: int = 0
    semantic_degree: int = 0
    importance: float = 1.0
    display_group: str = ""
    display_label: str = ""
    visual_role: str = ""
    # Data fields the importers/adapters attach (memory_import, ast_extractor),
    # declared so extra="forbid" rejects only genuinely UNKNOWN keys (card
    # d25d3b8b).  Nullable where the source row can be NULL.
    origin: str = ""
    rel_path: str = ""
    chunk_id: str = ""
    start_line: int | None = None
    end_line: int | None = None
    content: str | None = None
    tags: str | None = None
    memory_type: str | None = None
    source_agent: str | None = None
    source_layer: str | None = None
    registry: str = ""
    row_scope: str | None = None
    value_label: str | None = None
    # The registry column is REAL, but the row filter tolerates a non-numeric
    # value (``_registry_row_is_live`` swallows the parse error and keeps the
    # row), and the node carries the raw value through — so the field accepts the
    # string the DB can hold instead of rejecting the whole import.
    value_score: float | str | None = None
    concept: str | None = None
    created_at: str | None = None
    kind: str = ""
    aliases: str = ""
    status: str = ""
    section: str | None = None
    source_kind: str | None = None
    source_path: str | None = None
    line_start: int | str | None = None
    line_end: int | str | None = None
    summary_labels: list[str] = Field(default_factory=list)
    typed_summary: dict[str, Any] = Field(default_factory=dict)
    # Synthesis/belief-node fields set by memory_import's registry/synthesis phases.
    evidence_count: int = 0
    generated_at: str = ""
    stale: int = 0
    subject_id: str = ""
    subject_type: str = ""
    memory_tier: str = ""
    consolidation_op: str = ""
    # The live stored graph carries a string label here ("strong"), so — like
    # value_score — the field accepts the string rather than failing the load.
    source_strength: float | str | None = None
    belief_type: str = ""
    entity_id: str = ""
    source_memory_id: str = ""
    priority: str | None = None
    related_entity_id: str | None = None
    # ast_extractor's async-function flag.  Named ``is_async`` because ``async`` is
    # a Python reserved word and cannot be a field name; the emitter was renamed
    # to match (card d25d3b8b).
    is_async: bool = False

    @model_validator(mode="before")
    @classmethod
    def _coerce_id(cls, data: Any) -> Any:
        if isinstance(data, dict):
            raw = data.get("id")
            if raw is not None and not isinstance(raw, str):
                data["id"] = str(raw)
            # Legacy ast key: the reserved word ``async`` was renamed ``is_async``
            # (card d25d3b8b), so a graph.json serialized before the rename is
            # mapped rather than rejected.  Live producer: the stored graph DB.
            if "async" in data:
                if "is_async" not in data:
                    data["is_async"] = data.pop("async")
                else:
                    data.pop("async")
        return data


# ── Edge ───────────────────────────────────────────────────────────────


class GraphEdge(SourceLineage):
    """A directed edge between two graph nodes.

    Endpoints are canonicalised to ``source`` / ``target``.
    Legacy ``from`` / ``to`` keys are accepted and mapped during
    deserialization.

    The ``origin`` field records *where* the edge was extracted from
    (e.g. ``"ast"``, ``"memory_db"``).  This was previously stored
    under the ``source`` key, which conflicted with the endpoint name.

    ``sources`` (inherited from :class:`SourceLineage`) records *which source
    documents* assert the edge — the citation and removal identity.  An edge a
    derived pass invented rather than a document asserting (an import resolved
    by name matching, a call linked to its definition) carries none, because no
    single document asserted it; the endpoints' own sources remain reachable.

    Relationship STRENGTH is ``semantic_score`` — the single continuous strength
    vocabulary the package declares, and the only one a consumer reads.  An edge
    that asserts a relationship rather than scoring one (an AST ``defines`` /
    ``calls`` edge) carries no score, and a consumer reads that as strength 1.0.

    REF: "GraphRAG with TypeSafe Jev: A System One Approach to Scalable
    Knowledge Graphs" (Partha Sarkar, TDS, 2026-09-27) —
    https://towardsdatascience.com/graphrag-with-typesafe-jev-a-system-one-approach-to-scalable-knowledge-graphs/
    The former ``weight: float = 1.0`` field was REMOVED (GRAPHRAG-JEV-005): the
    one dependency-strength consumer (community detection) already preferred
    ``semantic_score`` and fell back to ``weight``, whose default made the
    fallback a constant — so the field could only ever disagree with the score it
    shadowed, and nothing else read it.  ``weight`` is popped in the validator
    below and EXPLICITLY IGNORED (never mapped onto a score) when a ``graph.json``
    serialized by an older build still carries it; with ``extra="forbid"`` it would
    otherwise reject the whole edge.
    """

    model_config = ConfigDict(extra="forbid", populate_by_name=True)

    source: str
    target: str
    label: str = "related"
    origin: str = ""
    semantic_score: float | None = None
    cooccurrence_count: int | None = None
    confidence: ConfidenceLevel | None = None
    inferred: bool = False
    explicit: bool = False
    visibility: str = "both"
    quality_tier: str = "semantic"
    # Projection/ingest annotations (were extra="allow"): label_visibility is set
    # by memory_import's semantic edges; the support counts and fallback by
    # projection.
    label_visibility: str = ""
    support_chunk_count: int = 0
    support_summary_count: int = 0
    fallback: bool = False
    registry: str = ""
    role: str = ""
    evidence_count: int = 0

    @model_validator(mode="before")
    @classmethod
    def _canonicalise_endpoints(cls, data: Any) -> Any:
        """Map legacy ``from``/``to`` keys → ``source``/``target``.

        Also resolves the overloaded ``source`` key: when it looks like
        a provenance tag (``"ast"``, ``"memory_db"``) rather than a node
        id, it is moved to ``origin``.
        """
        if not isinstance(data, dict):
            return data

        # ── endpoint mapping ──
        # Priority: explicit source/target > from/to
        src = data.get("source")
        dst = data.get("target")
        frm = data.pop("from", None)
        to = data.pop("to", None)
        # ``weight`` was REMOVED in GRAPHRAG-JEV-005 (see the class docstring): an
        # older serialized graph may still carry it, and it is ignored — dropped
        # here so extra="forbid" does not reject the edge.
        data.pop("weight", None)
        # ``_strength`` is projection's INTERNAL sort key (projection.py strips it
        # from the emitted dict); it is never part of the wire format, so a dict
        # that still carries it does not make it a model field.
        data.pop("_strength", None)

        # If source/target are missing but from/to exist, use them
        if src is None and frm is not None:
            src = frm
        if dst is None and to is not None:
            dst = to

        # Coerce to str
        if src is not None:
            data["source"] = str(src)
        if dst is not None:
            data["target"] = str(dst)

        # ── resolve overloaded 'source' as provenance ──
        _PROVENANCE_VALUES = {"ast", "memory_db", "json_store", "user", "life_index"}
        if src is not None and isinstance(src, str) and src.lower() in _PROVENANCE_VALUES:
            data["origin"] = src
            if frm is not None:
                # source was a provenance tag, not an endpoint — the real
                # endpoint comes from 'from'
                data["source"] = str(frm)
            else:
                # Provenance-only 'source' with no endpoint: leaving it as the
                # endpoint would point the edge at a literal "ast" node.
                raise ValueError(
                    "edge 'source' is a provenance tag but no endpoint was "
                    "given (use 'from'/'to' or an explicit source id)"
                )

        return data


# ── Graph ──────────────────────────────────────────────────────────────


class GraphMeta(BaseModel):
    """Metadata attached to a graph projection."""

    model_config = ConfigDict(extra="forbid")

    view_mode: str = "overview"
    semantic_threshold: float = 0.82
    data_source: str = ""
    community_method: str = ""
    communities: list[dict[str, Any]] = Field(default_factory=list)
    # Projection counters set by projection.project_graph (were extra="allow"):
    # kgraph.html reads payload._meta.typeCounts / .nodeCount / .edgeCount.
    typeCounts: dict[str, int] = Field(default_factory=dict)
    nodeCount: int = 0
    edgeCount: int = 0
    clusterSuggestions: list[dict[str, Any]] = Field(default_factory=list)
    # ast_extractor's result metadata (result["_meta"]).
    source: str = ""
    files_parsed: int = 0
    languages: list[str] = Field(default_factory=list)


class Graph(BaseModel):
    """A complete knowledge graph with nodes, edges, and metadata.

    This is the canonical container passed between all kgraph modules.
    Legacy ``_meta`` keys are mapped to ``meta`` during deserialization.
    """

    model_config = ConfigDict(extra="forbid")

    nodes: list[GraphNode] = Field(default_factory=list)
    edges: list[GraphEdge] = Field(default_factory=list)
    meta: GraphMeta = Field(default_factory=GraphMeta)

    @model_validator(mode="before")
    @classmethod
    def _map_legacy_meta(cls, data: Any) -> Any:
        if isinstance(data, dict) and "_meta" in data:
            data["meta"] = data.pop("_meta")
        return data

    # ── convenience accessors ──

    def node_by_id(self, node_id: str) -> GraphNode | None:
        for n in self.nodes:
            if n.id == node_id:
                return n
        return None

    def node_ids(self) -> set[str]:
        return {n.id for n in self.nodes}

    def prune_ast_nodes(self) -> None:
        """Drop AST-derived nodes (id prefix ``ast_``) and their edges.

        AST nodes are derived data owned by the most recent extraction
        (``extract_repo_graph``).  Stale copies from earlier builds — old
        slug formats, deleted files, or other source directories — would
        otherwise accumulate across incremental rebuilds.
        """
        ast_ids = {n.id for n in self.nodes if n.id and n.id.startswith("ast_")}
        if not ast_ids:
            return
        self.nodes = [n for n in self.nodes if n.id not in ast_ids]
        self.edges = [
            e for e in self.edges
            if e.source not in ast_ids and e.target not in ast_ids
        ]

    def remove_source(self, key: str) -> dict[str, int]:
        """Subtract exactly one source document from the graph.

        REF: "GraphRAG: A Practitioner's Guide to 6 Advanced Architectural
        Patterns" (Partha Sarkar, TDS, 2026-09-20) — Challenge 3: "When a
        document is deleted, query the graph for all elements containing that
        ID. Remove the ID from the array. If the array becomes empty, delete
        the node/edge."

        This is the fining half of the protocol the graph was missing: the only
        removal path was ``prune_ast_nodes()``, which drops every AST node
        wholesale, and a re-import that replaces the graph.  Nothing could delete
        "the facts ONE document asserted" while leaving what other documents
        still support.

        Elements that never carried *key* are untouched — an element with an
        empty ``sources`` list has no lineage recorded, which is not the same as
        having no sources, and deleting it here would be a silent data loss.

        Returns counts (the caller already knows *key*), so a caller can report
        what it removed.
        """
        removed_node_ids: set[str] = set()
        kept_nodes: list[GraphNode] = []
        nodes_updated = 0
        for node in self.nodes:
            had_key = key in node.sources
            if node.drop_source(key):
                removed_node_ids.add(node.id)
                continue
            if had_key:
                nodes_updated += 1
            kept_nodes.append(node)

        kept_edges: list[GraphEdge] = []
        edges_updated = 0
        edges_removed = 0
        for edge in self.edges:
            if edge.source in removed_node_ids or edge.target in removed_node_ids:
                # An edge to a deleted node cannot survive it.
                edges_removed += 1
                continue
            had_key = key in edge.sources
            if edge.drop_source(key):
                edges_removed += 1
                continue
            if had_key:
                edges_updated += 1
            kept_edges.append(edge)

        self.nodes = kept_nodes
        self.edges = kept_edges
        # The cached community digest describes the structure just changed, so it must
        # not survive the change.  ``save_to_graph_db`` re-writes ``meta.communities``
        # verbatim, so a digest left in place names deleted nodes as members with a
        # stale size — the exact failure that function's own DELETE branch exists to
        # prevent, and what ``_check_community_digest`` reports as drift.  Clearing it
        # makes readers re-detect on demand, which is what every reader already does
        # when a graph carries no digest.  Recomputing here instead would make a
        # removal require networkx.
        self.meta.communities = []
        self.meta.community_method = ""
        return {
            "nodes_removed": len(removed_node_ids),
            "nodes_updated": nodes_updated,
            "edges_removed": edges_removed,
            "edges_updated": edges_updated,
        }

    def to_dict(self) -> dict[str, Any]:
        """Serialize to a plain dict (for JSON output, SQLite storage)."""
        return self.model_dump(mode="json", exclude_none=True)

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> Graph:
        """Deserialize from a plain dict, tolerating legacy keys."""
        return cls.model_validate(data)


# ── Semantic identity: ONE normaliser, ONE collapse ────────────────────
# Both the extraction/merge path (GraphBuilder.deduplicate_semantic) and the
# view path (projection._enrich_graph_payload) call these, so "is this the same
# concept?" can only be answered one way (card 27b55b6f).

def normalize_semantic_label(label: str, life_index: dict | None = None) -> str:
    """The normalised grouping key for *label*: stopwords/punctuation, then aliases.

    Deliberately has NO length gate: the caller applies
    :data:`MIN_SEMANTIC_KEY_LEN` to the FINAL key.  The extraction path used to
    gate the PRE-alias label at 4 characters, before the alias map could see it —
    and since no alias key or canonical in ``config/concept-aliases.json`` is
    shorter than 4 characters, that gate never bought a correct grouping while
    making the two paths disagree about 3-character labels.
    """
    text = (label or "").strip().lower()
    if not text:
        return ""
    # Stopwords and aliases come from config/concept-aliases.json via constants.py,
    # the single source for concept classification (item 11.14); `sorted` keeps the
    # generated alternation deterministic across runs.
    text = re.sub(r"\b(?:%s)\b" % "|".join(sorted(STOPWORDS)), " ", text)
    text = re.sub(r"[^a-z0-9\s-]", " ", text)
    text = re.sub(r"\s+", " ", text).strip(" .:-")
    if not text:
        return ""
    for alias, canonical in CONCEPT_ALIASES.items():
        if text == alias or alias in text:
            text = canonical
            break
    if life_index:
        record = life_index.get("aliases", {}).get(text)
        if record:
            title = str(record.get("title", text)).strip().lower()
            if title and title != text:
                return title
        canonical_title = life_index.get("title_aliases", {}).get(text)
        if canonical_title:
            return str(canonical_title).strip().lower()
    return text


def collapse_semantic_duplicates(graph: Graph, life_index: dict | None = None,
                                 allowed_types: set[str] | frozenset[str] | None = None) -> Graph:
    """Collapse semantically-equivalent nodes, remapping and merging their edges.

    Nodes are grouped by ``(type, normalize_semantic_label(label))``; a group is
    collapsed only when its key is at least :data:`MIN_SEMANTIC_KEY_LEN`
    characters.  The canonical member is the non-inferred, highest-confidence,
    longest-labelled one; a dropped member's source documents union into it
    through :meth:`SourceLineage.merge_sources`, so the array bound and the
    ``sources_overflow`` record apply here too.

    AST nodes (function, class, call, …) are never collapsed: their identity
    carries semantic meaning.  Returns a new ``Graph``; the input is unchanged
    apart from the canonical nodes/edges it mutates in place.
    """
    if allowed_types is None:
        allowed_types = DEFAULT_SEMANTIC_TYPES

    groups: dict[tuple[str, str], list[GraphNode]] = {}
    for node in graph.nodes:
        ntype = (node.type or "unknown").lower()
        if ntype not in allowed_types:
            continue
        key = normalize_semantic_label(node.label, life_index)
        if len(key) < MIN_SEMANTIC_KEY_LEN:
            continue
        groups.setdefault((ntype, key), []).append(node)

    canonical_for: dict[str, str] = {}
    for members in groups.values():
        if len(members) < 2:
            continue
        members.sort(key=lambda n: (
            bool(n.inferred_type) if n.inferred_type is not None else False,  # non-inferred first
            -(float(n.type_confidence) if n.type_confidence is not None else 1.0),  # highest confidence first
            -len(n.label or ""),  # longest label first
            n.id or "",
        ))
        canonical = members[0]
        cid = canonical.id or ""
        merged_desc_parts: list[str] = []
        for node in members[1:]:
            nid = node.id or ""
            if nid:
                canonical_for[nid] = cid
            # The collapsed node's evidence moves to the canonical node —
            # otherwise dedup would silently drop the sources that only the
            # dropped spelling carried.
            canonical.merge_sources(node.sources)
            # Merge description from dropped nodes
            if node.description and node.description != canonical.description:
                merged_desc_parts.append(node.description)
        if merged_desc_parts and canonical.description:
            canonical.description = "\n".join([canonical.description] + merged_desc_parts)
        elif merged_desc_parts:
            canonical.description = "\n".join(merged_desc_parts)

    if not canonical_for:
        return graph

    kept_nodes = [n for n in graph.nodes if (n.id or "") not in canonical_for]

    new_edges: dict[tuple[str, str, str], GraphEdge] = {}
    for edge in graph.edges:
        src = canonical_for.get(edge.source, edge.source)
        dst = canonical_for.get(edge.target, edge.target)
        if not src or not dst or src == dst:
            continue  # drop self-loops
        edge.source = src
        edge.target = dst
        new_key = (src, dst, edge.label or "related")
        kept = new_edges.get(new_key)
        if kept is not None:
            # Two edges became the same edge: keep the first, but carry the
            # dropped one's source documents across.
            kept.merge_sources(edge.sources)
            continue  # deduplicate edges
        new_edges[new_key] = edge

    return Graph(nodes=kept_nodes, edges=list(new_edges.values()), meta=graph.meta)


# ── GraphBuilder ───────────────────────────────────────────────────────


class GraphBuilder:
    """Incremental graph construction with deduplication.

    Replaces the four independent ``add_node`` / ``add_edge`` /
    ``merge_graphs`` implementations scattered across
    ``memory_import.py``, ``update.py``, ``graph_db.py``, and
    ``ast_extractor.py``.
    """

    def __init__(self) -> None:
        self._nodes: dict[str, GraphNode] = {}
        self._edges: dict[tuple[str, str, str], GraphEdge] = {}

    # ── node operations ──

    def add_node(self, node: GraphNode | dict[str, Any]) -> GraphNode:
        if isinstance(node, dict):
            node = GraphNode.model_validate(node)
        existing = self._nodes.get(node.id) if node.id else None
        if existing is not None:
            # A second ingest of the same node is evidence, not a duplicate: keep
            # the first node's fields but union its source documents, so a merge
            # cannot silently drop one source's assertion.
            existing.merge_sources(node.sources)
            return existing
        if node.id:
            node.bound_sources()
            self._nodes[node.id] = node
        return node

    def has_node(self, node_id: str) -> bool:
        return node_id in self._nodes

    def get_node(self, node_id: str) -> GraphNode | None:
        return self._nodes.get(node_id)

    @property
    def nodes_list(self) -> list[GraphNode]:
        """Current nodes as a list (for lookups during construction)."""
        return list(self._nodes.values())

    # ── edge operations ──

    def add_edge(self, edge: GraphEdge | dict[str, Any]) -> GraphEdge:
        if isinstance(edge, dict):
            edge = GraphEdge.model_validate(edge)
        key = (edge.source, edge.target, edge.label)
        if not (edge.source and edge.target):
            return edge
        existing = self._edges.get(key)
        if existing is not None:
            # Same as add_node: union sources rather than dropping the second
            # assertion (this is what makes a re-merge additive).
            existing.merge_sources(edge.sources)
            return existing
        edge.bound_sources()
        self._edges[key] = edge
        return edge

    def has_edge(self, source: str, target: str, label: str) -> bool:
        return (source, target, label) in self._edges

    # ── merge ──

    def merge(self, other: Graph | dict[str, Any]) -> None:
        """Merge another graph into this builder, deduplicating."""
        if isinstance(other, dict):
            other = Graph.from_dict(other)
        for node in other.nodes:
            self.add_node(node)
        for edge in other.edges:
            self.add_edge(edge)

    # ── semantic deduplication ──

    def deduplicate_semantic(self,
                              life_index: dict | None = None,
                              allowed_types: set[str] | None = None) -> None:
        """Collapse semantically-equivalent nodes in the builder state, merging edges.

        Use *before* ``build()`` so the persisted graph carries no semantic
        duplicates.  A thin wrapper over :func:`collapse_semantic_duplicates` —
        the ONE implementation, shared with the view path in ``projection.py`` —
        which writes the collapsed graph back into the builder.

        Sources of a collapsed node move to its canonical node through
        :meth:`SourceLineage.merge_sources`, so the array bound and the
        ``sources_overflow`` record apply on this path too.  Metadata from
        dropped nodes merges into the canonical node's ``description``.
        """
        collapsed = collapse_semantic_duplicates(
            self.build(), life_index=life_index, allowed_types=allowed_types)
        self._nodes = {n.id: n for n in collapsed.nodes if n.id}
        self._edges = {(e.source, e.target, e.label or "related"): e for e in collapsed.edges}

    # ── build ──

    def build(self) -> Graph:
        return Graph(
            nodes=list(self._nodes.values()),
            edges=list(self._edges.values()),
        )

    def __len__(self) -> int:
        return len(self._nodes) + len(self._edges)


# ── Helpers ────────────────────────────────────────────────────────────

_SLUG_RE = re.compile(r"[^a-z0-9]+")


def slugify(text: str) -> str:
    """Canonical slug: lowercase, non-alphanumeric → hyphen."""
    return _SLUG_RE.sub("-", (text or "").lower()).strip("-")


def estimate_tokens(text: str) -> int:
    """Rough token estimate (~4 chars per token for English)."""
    return max(1, len(text or "") // 4)
