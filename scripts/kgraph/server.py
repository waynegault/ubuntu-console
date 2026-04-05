"""HTTP server for the knowledge graph.

Exports resolve_serve_target() and serve_file() — the HTTP server
implementation with the nested GraphRequestHandler class that serves
the Cytoscape frontend and handles graph.json GET/POST.
"""
import os
import json
from functools import partial
from http.server import SimpleHTTPRequestHandler, HTTPServer
import threading
import webbrowser
from .constants import GRAPH_DB_DEFAULT, SAMPLE_GRAPH
from .graph_db import resolve_memory_db_path, load_from_graph_db, save_to_graph_db
from .html import ensure_parent_dir
from .projection import project_graph
from .memory_import import load_from_memory_db


def resolve_serve_target(path: str, force_embed: bool = False) -> tuple[str, str, bool]:
  """Return the directory, filename, and frontend mode used for serving."""
  repo_root = os.path.abspath(os.path.join(os.path.dirname(__file__), '..'))
  static_dir = os.path.join(repo_root, 'frontend-g6', 'dist')
  use_built_frontend = (not force_embed) and os.path.isdir(static_dir)

  if use_built_frontend:
    return static_dir, 'index.html', True

  dirname = os.path.abspath(os.path.dirname(path) or '.')
  filename = os.path.basename(path)
  return dirname, filename, False


def serve_file(path: str, host: str = '127.0.0.1', port: int = 0, store_path: str | None = None, force_embed: bool = False, graph_db_path: str | None = None, view_mode: str = 'overview', semantic_threshold: float = 0.82):
  serve_dir, filename, using_built_frontend = resolve_serve_target(path, force_embed=force_embed)

  _CORS_HEADERS = [
    ('Access-Control-Allow-Origin', '*'),
    ('Access-Control-Allow-Methods', 'GET, POST, OPTIONS'),
    ('Access-Control-Allow-Headers', 'Content-Type'),
  ]

  initial_view_mode = (view_mode or 'overview').lower()
  initial_semantic_threshold = float(semantic_threshold)

  class GraphRequestHandler(SimpleHTTPRequestHandler):
    def __init__(self, *args, directory=None, **kwargs):
      super().__init__(*args, directory=directory or serve_dir, **kwargs)

    store = store_path or os.path.expanduser('~/.openclaw/kgraph.json')
    graph_db = graph_db_path or os.path.expanduser(GRAPH_DB_DEFAULT)
    view_mode = initial_view_mode
    semantic_threshold = initial_semantic_threshold
    # Path to OpenClaw memory DB to use as fallback source.
    # Supports legacy and current OpenClaw layouts.
    memory_db = resolve_memory_db_path()

    def _send_cors_headers(self):
      for name, value in _CORS_HEADERS:
        self.send_header(name, value)

    def do_OPTIONS(self):
      self.send_response(204)
      self._send_cors_headers()
      self.end_headers()

    def do_GET(self):
      request_path = self.path.split('?', 1)[0]
      if request_path == '/graph.json':
        query = {}
        if '?' in self.path:
          for part in self.path.split('?', 1)[1].split('&'):
            if not part:
              continue
            key, _, value = part.partition('=')
            query[key] = value
        req_view_mode = query.get('view', self.view_mode)
        try:
          req_semantic = float(query.get('semantic', self.semantic_threshold))
        except (TypeError, ValueError):
          req_semantic = self.semantic_threshold
        try:
            graph_db_exists = bool(self.graph_db and os.path.exists(os.path.expanduser(self.graph_db)))
            memory_db_exists = bool(self.memory_db and os.path.exists(self.memory_db))

            # Semantic / overview / topics / files should project from memory-derived graph when available.
            # Raw is the place where user-edited graph DB should dominate.
            prefer_memory_projection = req_view_mode in {'semantic', 'overview', 'topics', 'files'}

            base_graph = None
            source_name = 'sample'

            if prefer_memory_projection and memory_db_exists:
              try:
                base_graph = load_from_memory_db(self.memory_db)
                source_name = 'memory-db'
              except Exception:
                base_graph = {'nodes': [], 'edges': []}
              if (not base_graph.get('nodes')) and (not base_graph.get('edges')) and graph_db_exists:
                user_graph = load_from_graph_db(self.graph_db)
                if user_graph.get('nodes') or user_graph.get('edges'):
                  base_graph = user_graph
                  source_name = 'graph-db'
              if (not base_graph.get('nodes')) and (not base_graph.get('edges')) and os.path.isfile(self.store):
                with open(self.store, 'r', encoding='utf-8') as f:
                  base_graph = json.load(f)
                source_name = 'json-store'
              if base_graph is None or ((not base_graph.get('nodes')) and (not base_graph.get('edges')) and not os.path.isfile(self.store)):
                base_graph = SAMPLE_GRAPH
                source_name = 'sample'
            elif graph_db_exists:
              user_graph = load_from_graph_db(self.graph_db)
              if user_graph.get('nodes') or user_graph.get('edges'):
                base_graph = user_graph
                source_name = 'graph-db'
              elif memory_db_exists:
                try:
                  base_graph = load_from_memory_db(self.memory_db)
                  source_name = 'memory-db'
                except Exception:
                  base_graph = {'nodes': [], 'edges': []}
                if (not base_graph.get('nodes')) and (not base_graph.get('edges')) and os.path.isfile(self.store):
                  with open(self.store, 'r', encoding='utf-8') as f:
                    base_graph = json.load(f)
                  source_name = 'json-store'
                elif (not base_graph.get('nodes')) and (not base_graph.get('edges')):
                  base_graph = SAMPLE_GRAPH
                  source_name = 'sample'
              elif os.path.isfile(self.store):
                with open(self.store, 'r', encoding='utf-8') as f:
                  base_graph = json.load(f)
                source_name = 'json-store'
              else:
                base_graph = SAMPLE_GRAPH
                source_name = 'sample'
            elif memory_db_exists:
              try:
                base_graph = load_from_memory_db(self.memory_db)
                source_name = 'memory-db'
              except Exception:
                base_graph = {'nodes': [], 'edges': []}
              if (not base_graph.get('nodes')) and (not base_graph.get('edges')) and os.path.isfile(self.store):
                with open(self.store, 'r', encoding='utf-8') as f:
                  base_graph = json.load(f)
                source_name = 'json-store'
              elif (not base_graph.get('nodes')) and (not base_graph.get('edges')):
                base_graph = SAMPLE_GRAPH
                source_name = 'sample'
            elif os.path.isfile(self.store):
              with open(self.store, 'r', encoding='utf-8') as f:
                base_graph = json.load(f)
              source_name = 'json-store'
            else:
              base_graph = SAMPLE_GRAPH
              source_name = 'sample'

            projected = project_graph(base_graph, mode=req_view_mode, semantic_threshold=req_semantic)
            meta = {
              'viewMode': req_view_mode,
              'semanticThreshold': req_semantic,
              'source': source_name
            }
            payload = dict(projected)
            payload['_meta'] = dict(payload.get('_meta', {}))
            payload['_meta'].update(meta)
            data = json.dumps(payload)
        except Exception:
            # final fallback to sample graph
            fallback = project_graph(SAMPLE_GRAPH, mode=req_view_mode, semantic_threshold=req_semantic)
            fallback['_meta'] = {
              'viewMode': req_view_mode,
              'semanticThreshold': req_semantic,
              'source': 'sample'
            }
            data = json.dumps(fallback)
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self._send_cors_headers()
        self.end_headers()
        self.wfile.write(data.encode('utf-8'))
        return
      return super().do_GET()

    def do_POST(self):
      if self.path == '/graph.json':
        length = int(self.headers.get('Content-Length', 0))
        body = self.rfile.read(length)
        try:
          payload = json.loads(body.decode('utf-8'))
          if not isinstance(payload, dict):
            raise ValueError('graph payload must be an object')
          payload.setdefault('nodes', [])
          payload.setdefault('edges', [])

          # Primary persistence target: dedicated SQLite graph DB.
          save_to_graph_db(self.graph_db, payload)

          # Backward-compat mirror for tooling expecting kgraph.json.
          ensure_parent_dir(self.store)
          with open(self.store, 'w', encoding='utf-8') as f:
            json.dump(payload, f)

          self.send_response(200)
          self._send_cors_headers()
          self.end_headers()
          self.wfile.write(b'OK')
        except Exception as e:
          self.send_response(500)
          self._send_cors_headers()
          self.end_headers()
          self.wfile.write(str(e).encode())
        return
      return super().do_POST()

  handler = partial(GraphRequestHandler, directory=serve_dir)
  httpd = HTTPServer((host, port), handler)
  addr, used_port = httpd.server_address
  # If serving the built frontend, point root to index.html
  if using_built_frontend:
    url = f'http://{addr}:{used_port}/'
  else:
    url = f'http://{addr}:{used_port}/{filename}'
  # Open browser in background if available but don't block
  try:
    threading.Thread(target=webbrowser.open, args=(url,), daemon=True).start()
  except Exception:
    pass

  print('Serving', url)
  try:
    httpd.serve_forever()
  except KeyboardInterrupt:
    httpd.shutdown()
