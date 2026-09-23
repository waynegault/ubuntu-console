"""Graph database persistence layer.

Stores and retrieves ``Graph`` models from SQLite.  Accepts both
``Graph`` instances and legacy dicts (auto-converted via
``Graph.from_dict()``).
"""

from __future__ import annotations

import json
import logging
import os
import sqlite3

from .constants import (
    COMMUNITY_DIGEST_VERSION,
    MEMORY_DB_CANDIDATES,
    SOURCES_VERSION,
    VOCABULARY_VERSION,
)
from .html import ensure_parent_dir
from .models import Graph, GraphBuilder

logger = logging.getLogger(__name__)


def resolve_memory_db_path(preferred: str | None = None) -> str | None:
    """Resolve the path to an OpenClaw memory database (first existing candidate)."""
    if preferred:
        p = os.path.expanduser(preferred)
        return p if os.path.exists(p) else None
    for candidate in MEMORY_DB_CANDIDATES:
        p = os.path.expanduser(candidate)
        if os.path.exists(p):
            return p
    return None


def resolve_all_memory_db_paths() -> list[str]:
    """Resolve ALL existing memory database candidates (multi-registry support).

    Returns every candidate path that exists, in declaration order.  Used by
    the update pipeline so all registries (home, rook, …) merge into one graph.
    """
    found: list[str] = []
    for candidate in MEMORY_DB_CANDIDATES:
        p = os.path.expanduser(candidate)
        if os.path.exists(p):
            found.append(p)
    return found


def init_graph_db(dbpath: str) -> None:
    """Create the graph tables if they do not exist."""
    path = os.path.expanduser(dbpath)
    ensure_parent_dir(path)
    conn = sqlite3.connect(path)
    try:
        cur = conn.cursor()
        cur.execute("""
            CREATE TABLE IF NOT EXISTS graph_nodes (
                id TEXT PRIMARY KEY,
                label TEXT,
                payload TEXT
            )
        """)
        cur.execute("""
            CREATE TABLE IF NOT EXISTS graph_edges (
                source TEXT NOT NULL,
                target TEXT NOT NULL,
                label TEXT,
                payload TEXT,
                UNIQUE(source, target, label)
            )
        """)
        # REF: "GraphRAG: A Practitioner's Guide to 6 Advanced Architectural
        # Patterns" (Partha Sarkar, TDS, 2026-09-20) — the article's Challenge 2
        # asks for ontology governance including versioning, "so a graph built
        # under an older label set is identifiable".  Key/value rather than
        # PRAGMA user_version so the stamp is self-describing and can carry more
        # than one build fact later.
        cur.execute("""
            CREATE TABLE IF NOT EXISTS graph_meta (
                key TEXT PRIMARY KEY,
                value TEXT
            )
        """)
        conn.commit()
    finally:
        conn.close()


def read_graph_meta_value(dbpath: str, key: str) -> str | None:
    """Return one ``graph_meta`` value from *dbpath*, or None when absent.

    None covers all three "not there" cases on purpose: no database (yet), an
    older database whose graph_meta table predates the key, and a key never
    written.  Every caller treats None as "built before this stamp existed".
    """
    path = os.path.expanduser(dbpath)
    if not os.path.exists(path):
        return None
    conn = sqlite3.connect(path)
    try:
        cur = conn.cursor()
        cur.execute("SELECT value FROM graph_meta WHERE key = ?", (key,))
        row = cur.fetchone()
        return row[0] if row else None
    except sqlite3.Error as exc:
        logger.debug("No %s readable in %s: %s", key, path, exc, exc_info=True)
        return None
    finally:
        conn.close()


def read_vocabulary_version(dbpath: str) -> str | None:
    """Return the vocabulary version stamped into *dbpath*, or None if absent.

    None means the graph predates the stamp (or was written by another tool), so
    its labels were produced under an unknown vocabulary.
    """
    return read_graph_meta_value(dbpath, "vocabulary_version")


def read_sources_version(dbpath: str) -> str | None:
    """Return the source-lineage version stamped into *dbpath*, or None.

    The version stamp, not the absence of ``sources`` on individual elements:
    an element with an empty source list is a legitimate state (a derived node),
    so the graph itself has to say whether lineage was ever recorded.
    """
    return read_graph_meta_value(dbpath, "sources_version")


def read_community_digest(dbpath: str) -> dict | None:
    """Return the cached community digest from *dbpath*, or None.

    The digest is the article's "community report" set, written by the update
    path and read back here so a global "what are the main themes" question is a
    READ rather than a re-run of community detection.  A value that cannot be
    parsed is reported and treated as absent, never as an empty digest.
    """
    raw = read_graph_meta_value(dbpath, "community_digest")
    if not raw:
        return None
    try:
        parsed = json.loads(raw)
    except json.JSONDecodeError as exc:
        logger.warning("Unparseable community digest in %s: %s", dbpath, exc)
        return None
    if not isinstance(parsed, dict):
        logger.warning("Community digest in %s is %s, not an object", dbpath, type(parsed).__name__)
        return None
    return parsed


def load_from_graph_db(dbpath: str) -> Graph:
    """Load a ``Graph`` from the SQLite graph database."""
    path = os.path.expanduser(dbpath)
    if not os.path.exists(path):
        return Graph()

    conn = sqlite3.connect(path)
    builder = GraphBuilder()
    try:
        cur = conn.cursor()

        try:
            cur.execute("SELECT id, label, payload FROM graph_nodes")
            for node_id, label, payload in cur.fetchall():
                node_data: dict = {"id": str(node_id), "label": label or ""}
                if payload:
                    try:
                        extra = json.loads(payload)
                        if isinstance(extra, dict):
                            node_data.update(extra)
                    except (json.JSONDecodeError, TypeError) as exc:
                        logger.warning("Failed to parse node payload JSON: %s", exc)
                builder.add_node(node_data)
        except sqlite3.Error as exc:
            logger.warning("Failed to read graph_nodes table: %s", exc)

        try:
            cur.execute("SELECT source, target, label, payload FROM graph_edges")
            for source, target, label, payload in cur.fetchall():
                edge_data: dict = {
                    "source": str(source),
                    "target": str(target),
                    "label": label or "",
                }
                if payload:
                    try:
                        extra = json.loads(payload)
                        if isinstance(extra, dict):
                            edge_data.update(extra)
                    except (json.JSONDecodeError, TypeError) as exc:
                        logger.warning("Failed to parse edge payload JSON: %s", exc)
                builder.add_edge(edge_data)
        except sqlite3.Error as exc:
            logger.warning("Failed to read graph_edges table: %s", exc)
    finally:
        conn.close()

    # A graph built under a different vocabulary may carry labels this build's
    # projection and confidence rules no longer match, so say so rather than
    # letting the elements silently drop out of the derived views.
    stamped = read_vocabulary_version(path)
    if stamped != VOCABULARY_VERSION:
        logger.warning(
            "Graph %s was built under vocabulary %s, current is %s — labels may not "
            "match the current projection/confidence rules; rebuild to restamp",
            path, stamped if stamped is not None else "unstamped", VOCABULARY_VERSION,
        )

    # Same question for lineage: elements written before the field existed read
    # back with an empty source list, which is indistinguishable from "this
    # element has no recorded source".  Announce it rather than let a citation or
    # a by-source removal quietly operate on nothing.
    sources_stamp = read_sources_version(path)
    if sources_stamp != SOURCES_VERSION:
        logger.warning(
            "Graph %s carries no source lineage (stamp %s, current %s) — rebuild "
            "(kgraph --update) so edges can be cited and removed by source",
            path, sources_stamp if sources_stamp is not None else "unstamped",
            SOURCES_VERSION,
        )

    graph = builder.build()

    # Cached community digest — read, not computed.  Absent is not an error (a
    # small graph has no communities), so it is logged at DEBUG; a digest written
    # to a different shape is called out.
    digest = read_community_digest(path)
    if digest is None:
        logger.debug("No cached community digest in %s", path)
    elif str(digest.get("version") or "") != COMMUNITY_DIGEST_VERSION:
        logger.warning(
            "Cached community digest in %s is version %s, current is %s — community "
            "answers may be stale; rebuild to redigest",
            path, digest.get("version"), COMMUNITY_DIGEST_VERSION,
        )
    else:
        graph.meta.community_method = str(digest.get("method") or "")
        graph.meta.communities = list(digest.get("communities") or [])

    return graph


def save_to_graph_db(dbpath: str, graph: Graph | dict) -> None:
    """Persist a ``Graph`` (or legacy dict) to the SQLite graph database."""
    if isinstance(graph, dict):
        graph = Graph.from_dict(graph)

    init_graph_db(dbpath)
    path = os.path.expanduser(dbpath)
    conn = sqlite3.connect(path)
    try:
        cur = conn.cursor()
        cur.execute("DELETE FROM graph_edges")
        cur.execute("DELETE FROM graph_nodes")

        for node in graph.nodes:
            payload = {
                k: v
                for k, v in node.model_dump(mode="json", exclude_none=True).items()
                if k not in ("id", "label")
            }
            cur.execute(
                "INSERT OR REPLACE INTO graph_nodes(id, label, payload) VALUES (?, ?, ?)",
                (node.id, node.label, json.dumps(payload) if payload else None),
            )

        for edge in graph.edges:
            payload = {
                k: v
                for k, v in edge.model_dump(mode="json", exclude_none=True).items()
                if k not in ("source", "target", "label")
            }
            cur.execute(
                "INSERT OR REPLACE INTO graph_edges(source, target, label, payload) VALUES (?, ?, ?, ?)",
                (edge.source, edge.target, edge.label, json.dumps(payload) if payload else None),
            )

        # Stamp which label vocabulary built this graph, so a reader can tell a
        # graph written under an older set from a current one.
        cur.execute(
            "INSERT OR REPLACE INTO graph_meta(key, value) VALUES ('vocabulary_version', ?)",
            (VOCABULARY_VERSION,),
        )
        # And that this build DOES record per-element source lineage, so an
        # empty sources list on an element means "no document asserts this",
        # not "written before the field existed".
        cur.execute(
            "INSERT OR REPLACE INTO graph_meta(key, value) VALUES ('sources_version', ?)",
            (SOURCES_VERSION,),
        )

        # Cache the community digest with the graph.  Writing it here is what
        # makes the community answers a READ: today meta.communities is dropped
        # on save, so every reader (report, MCP tool) has to re-run detection.
        # Saving a graph with no communities DELETES the old key rather than
        # leaving the previous digest in place — a stale digest would answer
        # "what are the main themes" from a structure that no longer exists.
        communities = graph.meta.communities
        if communities:
            cur.execute(
                "INSERT OR REPLACE INTO graph_meta(key, value) VALUES ('community_digest', ?)",
                (json.dumps({
                    "version": COMMUNITY_DIGEST_VERSION,
                    "method": graph.meta.community_method,
                    "communities": communities,
                }),),
            )
        else:
            cur.execute("DELETE FROM graph_meta WHERE key = 'community_digest'")

        conn.commit()
    finally:
        conn.close()
