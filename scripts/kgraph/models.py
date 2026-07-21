"""Pydantic models for kgraph graph data.

Canonical schema for nodes, edges, and graphs. All kgraph modules
should use these models instead of raw dicts.

Edge endpoints are canonicalised to ``source`` / ``target``.
Legacy ``from`` / ``to`` keys are accepted during deserialization
and mapped automatically.
"""

from __future__ import annotations

import re
from enum import Enum
from typing import Any

from pydantic import BaseModel, ConfigDict, Field, model_validator


# ── Confidence ─────────────────────────────────────────────────────────


class ConfidenceLevel(str, Enum):
    """Edge confidence classification."""

    EXTRACTED = "EXTRACTED"
    INFERRED = "INFERRED"
    AMBIGUOUS = "AMBIGUOUS"


# ── Node ───────────────────────────────────────────────────────────────


class GraphNode(BaseModel):
    """A single node in the knowledge graph.

    Core fields (``id``, ``label``) are required.  All other fields
    carry sensible defaults so that partially-specified dicts from
    legacy sources deserialize cleanly.

    Extra fields added during processing (``degree``, ``importance``,
    ``display_label``, …) are permitted via ``extra="allow"``.
    """

    model_config = ConfigDict(extra="allow", populate_by_name=True)

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
    metadata: dict[str, Any] = Field(default_factory=dict)
    slug: str = ""
    group: str = ""
    visibility: str = "both"
    quality_tier: str = "semantic"
    inferred_type: bool = False
    type_confidence: float = 1.0
    canonical_slug: str = ""
    canonical_path: str = ""

    @model_validator(mode="before")
    @classmethod
    def _coerce_id(cls, data: Any) -> Any:
        if isinstance(data, dict):
            raw = data.get("id")
            if raw is not None and not isinstance(raw, str):
                data["id"] = str(raw)
        return data


# ── Edge ───────────────────────────────────────────────────────────────


class GraphEdge(BaseModel):
    """A directed edge between two graph nodes.

    Endpoints are canonicalised to ``source`` / ``target``.
    Legacy ``from`` / ``to`` keys are accepted and mapped during
    deserialization.

    The ``origin`` field records *where* the edge was extracted from
    (e.g. ``"ast"``, ``"memory_db"``).  This was previously stored
    under the ``source`` key, which conflicted with the endpoint name.
    """

    model_config = ConfigDict(extra="allow", populate_by_name=True)

    source: str
    target: str
    label: str = "related"
    origin: str = ""
    semantic_score: float | None = None
    cooccurrence_count: int | None = None
    confidence: ConfidenceLevel | None = None
    weight: float = 1.0
    inferred: bool = False
    explicit: bool = False
    visibility: str = "both"
    quality_tier: str = "semantic"
    metadata: dict[str, Any] = Field(default_factory=dict)

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
            # source was a provenance tag, not an endpoint — clear it
            # so the endpoint comes from 'from'
            if frm is not None:
                data["source"] = str(frm)

        return data


# ── Graph ──────────────────────────────────────────────────────────────


class GraphMeta(BaseModel):
    """Metadata attached to a graph projection."""

    model_config = ConfigDict(extra="allow")

    view_mode: str = "overview"
    semantic_threshold: float = 0.82
    data_source: str = ""
    community_method: str = ""
    communities: list[dict[str, Any]] = Field(default_factory=list)


class Graph(BaseModel):
    """A complete knowledge graph with nodes, edges, and metadata.

    This is the canonical container passed between all kgraph modules.
    Legacy ``_meta`` keys are mapped to ``meta`` during deserialization.
    """

    model_config = ConfigDict(extra="allow")

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

    def to_dict(self) -> dict[str, Any]:
        """Serialize to a plain dict (for JSON output, SQLite storage)."""
        return self.model_dump(mode="json", exclude_none=True)

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> Graph:
        """Deserialize from a plain dict, tolerating legacy keys."""
        return cls.model_validate(data)


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
        if node.id and node.id not in self._nodes:
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
        if edge.source and edge.target and key not in self._edges:
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