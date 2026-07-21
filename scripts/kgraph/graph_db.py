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

from .constants import MEMORY_DB_CANDIDATES
from .html import ensure_parent_dir
from .models import Graph, GraphBuilder

logger = logging.getLogger(__name__)


def resolve_memory_db_path(preferred: str | None = None) -> str | None:
    """Resolve the path to an OpenClaw memory database."""
    if preferred:
        p = os.path.expanduser(preferred)
        return p if os.path.exists(p) else None
    for candidate in MEMORY_DB_CANDIDATES:
        p = os.path.expanduser(candidate)
        if os.path.exists(p):
            return p
    return None


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
        conn.commit()
    finally:
        conn.close()


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

    return builder.build()


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

        conn.commit()
    finally:
        conn.close()