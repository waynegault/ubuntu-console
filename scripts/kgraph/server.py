"""HTTP server for the knowledge graph.

Exports resolve_serve_target() and serve_file() — the HTTP server
implementation with the nested GraphRequestHandler class that serves
the Cytoscape frontend and handles graph.json GET/POST.
"""
import logging
import json
import os
import threading
import time
import webbrowser
from functools import partial
from http.server import HTTPServer, SimpleHTTPRequestHandler

from .constants import GRAPH_DB_DEFAULT, SAMPLE_GRAPH
from .graph_db import load_from_graph_db, resolve_memory_db_path, save_to_graph_db
from .memory_import import load_from_memory_db
from .projection import project_graph

logger = logging.getLogger(__name__)


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

  # ── Rate limiter (class-level, shared across requests) ──
  _rl_requests: list[float] = []
  _rl_max = 30

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
    memory_db = resolve_memory_db_path()

    def _send_cors_headers(self):
      for name, value in _CORS_HEADERS:
        self.send_header(name, value)

    def do_OPTIONS(self):
      self.send_response(204)
      self._send_cors_headers()
      self.end_headers()

    def _resolve_graph(self, prefer_memory: bool) -> tuple[dict, str]:
        """Try multiple graph sources and return (graph, source_name).

        Fallback chain: memory-db → graph-db → json-store → sample graph.
        """
        graph_db_path = os.path.expanduser(self.graph_db) if self.graph_db else ""
        memory_db_path = self.memory_db or ""
        has_graph_db = bool(graph_db_path and os.path.exists(graph_db_path))
        has_memory_db = bool(memory_db_path and os.path.exists(memory_db_path))
        has_store = bool(self.store and os.path.isfile(self.store))

        sources: list[tuple[str, str, bool]] = []

        if prefer_memory and has_memory_db:
            sources.append(("memory-db", memory_db_path, True))
            if has_graph_db:
                sources.append(("graph-db", graph_db_path, False))
        elif has_graph_db:
            sources.append(("graph-db", graph_db_path, False))
            if has_memory_db:
                sources.append(("memory-db", memory_db_path, True))
        elif has_memory_db:
            sources.append(("memory-db", memory_db_path, True))

        for name, path, is_memory in sources:
            try:
                if is_memory:
                    graph = load_from_memory_db(path)
                else:
                    graph = load_from_graph_db(path)
                if graph.get("nodes") or graph.get("edges"):
                    return graph, name
            except Exception as exc:
                logger.warning("Failed to load graph source %s: %s", name, exc)

        if has_store:
            with open(self.store, "r", encoding="utf-8") as f:
                return json.load(f), "json-store"

        return SAMPLE_GRAPH, "sample"

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
            prefer_memory = req_view_mode in {'semantic', 'overview', 'topics', 'files'}
            base_graph, source_name = self._resolve_graph(prefer_memory)

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
        except Exception as exc:
            logger.warning("Graph projection failed, falling back to sample: %s", exc)
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
        # ── Rate limit: max 30 POSTs per 60s sliding window ──
        now = time.monotonic()
        cutoff = now - 60.0
        self.__class__._rl_requests = [t for t in self.__class__._rl_requests if t > cutoff]
        if len(self.__class__._rl_requests) >= self.__class__._rl_max:
          self.send_response(429)
          self.send_header('Content-Type', 'text/plain')
          self.send_header('Retry-After', '60')
          self._send_cors_headers()
          self.end_headers()
          self.wfile.write(b'Rate limit exceeded. Max 30 POST requests per 60 seconds.')
          return
        self.__class__._rl_requests.append(now)

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
