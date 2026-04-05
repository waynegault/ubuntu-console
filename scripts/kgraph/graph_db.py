"""Graph database persistence layer.

Exports resolve_memory_db_path(), init_graph_db(), load_from_graph_db(),
and save_to_graph_db() — functions for storing and retrieving graph
data from SQLite.
"""
import os
import json
import sqlite3
from .constants import GRAPH_DB_DEFAULT, MEMORY_DB_CANDIDATES
from .html import ensure_parent_dir


def resolve_memory_db_path(preferred: str | None = None) -> str | None:
  if preferred:
    p = os.path.expanduser(preferred)
    return p if os.path.exists(p) else None
  for candidate in MEMORY_DB_CANDIDATES:
    p = os.path.expanduser(candidate)
    if os.path.exists(p):
      return p
  return None


def init_graph_db(dbpath: str):
  path = os.path.expanduser(dbpath)
  ensure_parent_dir(path)
  conn = sqlite3.connect(path)
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
  conn.close()


def load_from_graph_db(dbpath: str) -> dict:
  path = os.path.expanduser(dbpath)
  if not os.path.exists(path):
    return {'nodes': [], 'edges': []}

  conn = sqlite3.connect(path)
  cur = conn.cursor()
  graph = {'nodes': [], 'edges': []}

  try:
    cur.execute("SELECT id, label, payload FROM graph_nodes")
    for node_id, label, payload in cur.fetchall():
      node = {'id': str(node_id), 'label': label or ''}
      if payload:
        try:
          extra = json.loads(payload)
          if isinstance(extra, dict):
            node.update(extra)
        except Exception:
          pass
      graph['nodes'].append(node)
  except sqlite3.Error:
    pass

  try:
    cur.execute("SELECT source, target, label, payload FROM graph_edges")
    for source, target, label, payload in cur.fetchall():
      edge = {'from': str(source), 'to': str(target), 'label': label or ''}
      if payload:
        try:
          extra = json.loads(payload)
          if isinstance(extra, dict):
            edge.update(extra)
        except Exception:
          pass
      graph['edges'].append(edge)
  except sqlite3.Error:
    pass

  conn.close()
  return graph


def save_to_graph_db(dbpath: str, graph: dict):
  init_graph_db(dbpath)
  path = os.path.expanduser(dbpath)
  conn = sqlite3.connect(path)
  cur = conn.cursor()

  cur.execute("DELETE FROM graph_edges")
  cur.execute("DELETE FROM graph_nodes")

  for node in graph.get('nodes', []):
    node_id = str(node.get('id', ''))
    if not node_id:
      continue
    label = node.get('label', '')
    payload = {k: v for k, v in node.items() if k not in ('id', 'label')}
    cur.execute(
      "INSERT OR REPLACE INTO graph_nodes(id, label, payload) VALUES (?, ?, ?)",
      (node_id, label, json.dumps(payload) if payload else None),
    )

  for edge in graph.get('edges', []):
    source = edge.get('from', edge.get('source'))
    target = edge.get('to', edge.get('target'))
    if source is None or target is None:
      continue
    label = edge.get('label', '')
    payload = {k: v for k, v in edge.items() if k not in ('from', 'to', 'source', 'target', 'label')}
    cur.execute(
      "INSERT OR REPLACE INTO graph_edges(source, target, label, payload) VALUES (?, ?, ?, ?)",
      (str(source), str(target), label, json.dumps(payload) if payload else None),
    )

  conn.commit()
  conn.close()
