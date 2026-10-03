"""HTTP server for the knowledge graph.

Exports resolve_serve_target() and serve_file() — the HTTP server
implementation.  The request handler is module-level and configured per
server by build_graph_handler(), so request routing and per-route logic can
be tested without starting a listener.
"""
import logging
import json
import os
import threading
import time
import webbrowser
from collections.abc import Callable
from functools import partial
from http.server import HTTPServer, SimpleHTTPRequestHandler
from urllib.parse import urlsplit

from .constants import GRAPH_DB_DEFAULT, SAMPLE_GRAPH
from .graph_db import load_from_graph_db, resolve_memory_db_path, save_to_graph_db
from .memory_import import load_from_memory_db
from .models import Graph
from .projection import project_graph
from .validate import MAX_PAYLOAD_SIZE, validate_graph_payload

logger = logging.getLogger(__name__)

# A rejection that is sent before the request body has been read leaves that body
# unread in the socket.  Closing a socket while it still holds unread data makes
# the kernel send RST rather than FIN, and an RST can discard the response that
# was just written — the client then reports ECONNRESET instead of the status
# code.  The 413 path raced intermittently for exactly this reason (2026-09-19).
# Bounded on both axes: DRAIN_LIMIT is far more than a real graph payload needs,
# and the timeout exists because this server is single-threaded, so a client that
# declares a large body and then stalls must not be able to hold up the handler.
DRAIN_LIMIT = 1024 * 1024
DRAIN_TIMEOUT_S = 2.0

# Only the Vite dev frontend may read the graph cross-origin; the bundled
# frontend is served same-origin and needs no CORS at all. A wildcard here
# let any page the user visited read the graph, so the response echoes
# Access-Control-Allow-Origin only for an exact match on this allowlist.
_ALLOWED_ORIGINS = (
    'http://localhost:5173',
    'http://127.0.0.1:5173',
)
_CORS_HEADERS = [
    ('Access-Control-Allow-Methods', 'GET, POST, OPTIONS'),
    ('Access-Control-Allow-Headers', 'Content-Type'),
]


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


# Types whose stored LABEL is a preview of the node's own content.  The GET read
# path replaces it with a non-content identifier (see _redacted_label).
# memory_import sets label = _preview_text(content) for these, so serving the
# label would serve the memory text.  This tuple is the single source of truth
# for that decision, and tests/test_memory_import.py carries a canary that
# fails when an importer starts emitting a type not classified here or in its
# non-content list (audit_security.md: keying on the type alone leaks a future
# content-derived type).
_REDACTED_LABEL_TYPES = ("memory", "summary")


def _redacted_label(node: dict) -> str:
  """Return a non-content label for a memory/summary node.

  Such a node's stored label IS a preview of its memory text — memory_import
  sets ``label = _preview_text(content)`` — so it cannot be served on the
  cross-origin read path. The node id is a stable, non-content identifier
  (e.g. ``memory:<uuid>``), so it supplies the redacted label.
  """
  kind = str(node.get('type') or 'memory').lower()
  _, _, tail = str(node.get('id') or '').partition(':')
  return f"{kind} {tail[:8]}" if tail else kind


def _redact_nodes_for_read(nodes: list) -> None:
  """Strip memory-derived free text from a served payload, in place.

  `content`, `tags` and `content_preview` are removed. A memory/summary node's
  LABEL is itself a content preview (memory_import sets
  ``label = _preview_text(content)``), so it is replaced with a non-content
  identifier built from the node id. Stripping content/tags alone did NOT close
  this channel, which is why the label is handled here too.
  """
  for node in nodes:
    if not isinstance(node, dict):
      continue
    node.pop('content', None)
    node.pop('tags', None)
    node.pop('content_preview', None)
    if str(node.get('type') or '').lower() in _REDACTED_LABEL_TYPES:
      label = _redacted_label(node)
      node['label'] = label
      if 'display_label' in node:
        node['display_label'] = label


class GraphRequestHandler(SimpleHTTPRequestHandler):
  """Serve the Cytoscape frontend and the graph.json GET/POST endpoints.

  Configuration (store path, graph DB, view mode, ...) lives on the class so a
  factory-created subclass carries it; the class itself is module-level so it
  can be constructed directly in tests.  The base defaults are inert and are
  always replaced by build_graph_handler() before a server is started.
  """

  # Rate limiter state lives on the class so all request instances share it.
  _rl_requests: list[float] = []
  _rl_max = 30

  # Per-server configuration, replaced by build_graph_handler's subclass.
  serve_dir = '.'
  store = ''
  graph_db = ''
  view_mode = 'overview'
  semantic_threshold = 0.82
  memory_db: str | None = None

  def __init__(self, *args, directory=None, **kwargs):
    super().__init__(*args, directory=directory or self.serve_dir, **kwargs)

  # ── CORS / connection hygiene ──

  def _allowed_origin(self) -> str | None:
    """The request Origin when it is an allowlisted dev frontend, else None.

    Browsers set Origin themselves and script cannot forge it, so echoing it
    back only for a known origin is what makes the read path safe: any other
    page gets no Access-Control-Allow-Origin and cannot read the response.
    Requests without an Origin header (curl, MCP clients) are unaffected —
    CORS is enforced by the browser, not by this server.
    """
    origin = self.headers.get('Origin')
    if not origin:
      return None
    return origin if origin in _ALLOWED_ORIGINS else None

  def _send_cors_headers(self, allow_origin: str | None = None):
    """Send the CORS headers for this response.

    `allow_origin` is echoed as Access-Control-Allow-Origin when set; when it
    is None no origin is approved, so the browser blocks a cross-origin read.
    `Vary: Origin` is sent because the response depends on the request Origin.
    """
    for name, value in _CORS_HEADERS:
      self.send_header(name, value)
    if allow_origin is not None:
      self.send_header('Access-Control-Allow-Origin', allow_origin)
    self.send_header('Vary', 'Origin')

  def _declared_content_length(self) -> int:
    """The request's Content-Length, or 0 when it is absent or malformed."""
    raw = self.headers.get('Content-Length')
    try:
      return int(raw or 0)
    except (TypeError, ValueError):
      logger.debug('ignoring a malformed Content-Length header: %r', raw, exc_info=True)
      return 0

  def _drain_request_body(self, length: int) -> None:
    """Consume a request body this handler is not going to use.

    Closing a socket that still holds unread request data makes the kernel
    send RST rather than FIN, and an RST can discard a response already in
    flight.  Every branch that reads the body for its own reasons is safe;
    only the early rejections were exposed.  A body larger than DRAIN_LIMIT
    necessarily stays partly unread, which is the residual of the bound.
    """
    remaining = min(length, DRAIN_LIMIT)
    if remaining <= 0:
      return
    previous_timeout = self.connection.gettimeout()
    self.connection.settimeout(DRAIN_TIMEOUT_S)
    try:
      while remaining > 0:
        chunk = self.rfile.read(min(65536, remaining))
        if not chunk:
          return
        remaining -= len(chunk)
    except OSError:
      # The client stalled or vanished mid-body.  The response is already
      # written, so there is nothing left to correct — but say so.
      logger.debug('draining a rejected request body ended early', exc_info=True)
    finally:
      self.connection.settimeout(previous_timeout)

  def _reject_post(self, code: int, message: bytes, *,
                   cors: bool = False, extra_headers: tuple = ()) -> None:
    """Answer a POST with a short body and leave the connection clean.

    Two things must both hold or the client can lose the response.  The body
    needs an explicit Content-Length, because without one the client reads to
    EOF to find where the body ends; and the request body must be drained
    before the caller returns, because a socket closed with unread data in it
    resets.  See the note above DRAIN_LIMIT.
    """
    self.send_response(code)
    self.send_header('Content-Type', 'text/plain')
    self.send_header('Content-Length', str(len(message)))
    for name, value in extra_headers:
      self.send_header(name, value)
    if cors:
      self._send_cors_headers()
    self.end_headers()
    self.wfile.write(message)
    self._drain_request_body(self._declared_content_length())

  def _origin_is_same(self) -> bool:
    """True when the request Origin matches the Host it was sent to.

    Browsers set Origin themselves and script cannot forge it, so this
    blocks cross-site POSTs.  Requests without an Origin header (curl,
    CLI, MCP clients) are not browser-originated and stay allowed.
    """
    origin = self.headers.get('Origin')
    if not origin:
      return True
    host = self.headers.get('Host', '')
    return bool(host) and urlsplit(origin).netloc == host

  def do_OPTIONS(self):
    # Cross-origin writes are not supported: refuse to approve a POST
    # preflight so a visited web page can never POST to /graph.json.
    # Same-origin requests never preflight, so the bundled frontend is
    # unaffected.
    if self.headers.get('Access-Control-Request-Method', '').upper() == 'POST':
      self.send_response(403)
      self.end_headers()
      return
    self.send_response(204)
    self._send_cors_headers(self._allowed_origin())
    self.end_headers()

  # ── read path ──

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
          loaded = load_from_memory_db(path)
        else:
          loaded = load_from_graph_db(path)
        graph = loaded.to_dict()
        if graph.get("nodes") or graph.get("edges"):
          return graph, name
      except (OSError, ValueError, KeyError) as exc:
        logger.warning("Failed to load graph source %s: %s", name, exc)

    if has_store:
      # An unreadable/corrupt store must not break the fallback chain:
      # OSError (permissions, EIO), JSONDecodeError and a pydantic
      # ValidationError (both ValueError subclasses) fall through to the
      # sample graph with a log.  The payload is VALIDATED here apart from
      # every other source above, which all go through Graph.from_dict —
      # returning json.load(f) raw handed a malformed graph straight to
      # project_graph (card 79d69304).
      try:
        with open(self.store, "r", encoding="utf-8") as f:
          return Graph.from_dict(json.load(f)).to_dict(), "json-store"
      except (OSError, ValueError) as exc:
        logger.warning(
          "Failed to load graph store %s: %s; falling back to sample graph",
          self.store, exc,
        )

    return SAMPLE_GRAPH, "sample"

  def _query_params(self) -> dict[str, str]:
    """Parse the request's query string into a flat key→value map."""
    query: dict[str, str] = {}
    if '?' not in self.path:
      return query
    for part in self.path.split('?', 1)[1].split('&'):
      if not part:
        continue
      key, _, value = part.partition('=')
      query[key] = value
    return query

  def _read_view_params(self) -> tuple[str, float]:
    """The requested view mode and semantic threshold, with defaults applied."""
    query = self._query_params()
    req_view_mode = query.get('view', self.view_mode)
    try:
      req_semantic = float(query.get('semantic', self.semantic_threshold))
    except (TypeError, ValueError):
      req_semantic = self.semantic_threshold
    return req_view_mode, req_semantic

  def _read_payload(self, req_view_mode: str, req_semantic: float) -> str:
    """Resolve, project and redact the graph, returning a JSON body string.

    The GET path is readable cross-origin by the allowlisted Vite dev
    frontend, so memory-derived free text is stripped from the served payload
    (see _redact_nodes_for_read).  A projection failure falls back to the
    sample graph rather than erroring the request.
    """
    try:
      prefer_memory = req_view_mode in {'semantic', 'overview', 'topics', 'files'}
      base_graph, source_name = self._resolve_graph(prefer_memory)
      projected = project_graph(base_graph, mode=req_view_mode, semantic_threshold=req_semantic)
      payload = dict(projected)
      payload['_meta'] = dict(payload.get('_meta', {}))
      payload['_meta'].update({
        'viewMode': req_view_mode,
        'semanticThreshold': req_semantic,
        'source': source_name,
      })
      _redact_nodes_for_read(payload.get('nodes', []))
      return json.dumps(payload)
    except (ValueError, KeyError, TypeError) as exc:
      logger.warning("Graph projection failed, falling back to sample: %s", exc)
      fallback = project_graph(SAMPLE_GRAPH, mode=req_view_mode, semantic_threshold=req_semantic)
      fallback['_meta'] = {
        'viewMode': req_view_mode,
        'semanticThreshold': req_semantic,
        'source': 'sample'
      }
      return json.dumps(fallback)

  def do_GET(self):
    if self.path.split('?', 1)[0] == '/graph.json':
      req_view_mode, req_semantic = self._read_view_params()
      data = self._read_payload(req_view_mode, req_semantic)
      self.send_response(200)
      self.send_header('Content-Type', 'application/json')
      self._send_cors_headers(self._allowed_origin())
      self.end_headers()
      self.wfile.write(data.encode('utf-8'))
      return
    return super().do_GET()

  # ── write path ──

  def _rate_limit_ok(self) -> bool:
    """Record this request against the sliding window; False when over limit."""
    now = time.monotonic()
    cutoff = now - 60.0
    cls = type(self)
    cls._rl_requests = [t for t in cls._rl_requests if t > cutoff]
    if len(cls._rl_requests) >= cls._rl_max:
      return False
    cls._rl_requests.append(now)
    return True

  def _read_json_object(self, length: int) -> dict:
    """Read and decode the request body into a graph payload dict."""
    body = self.rfile.read(length)
    payload = json.loads(body.decode('utf-8'))
    if not isinstance(payload, dict):
      raise ValueError('graph payload must be an object')
    payload.setdefault('nodes', [])
    payload.setdefault('edges', [])
    return payload

  def _store_validated_graph(self, payload: dict) -> None:
    """Validate the payload, then persist it to the graph DB.

    Security validation (size, node/edge caps, nesting depth, XSS patterns)
    runs before any DB write.  save_to_graph_db then validates the schema
    (Graph.from_dict) before its DELETE, so neither a malformed nor a hostile
    body can wipe the existing graph.
    """
    ok, reason = validate_graph_payload(payload)
    if not ok:
      raise ValueError(reason)
    save_to_graph_db(self.graph_db, payload)

  def _handle_graph_post(self) -> None:
    """Write path for POST /graph.json."""
    # Only JSON bodies are accepted.  `application/json` is not a
    # CORS-safelisted content type, so a cross-origin caller would have
    # to preflight — and do_OPTIONS refuses POST preflights.  This
    # stops a visited web page from silently overwriting the graph DB.
    content_type = self.headers.get('Content-Type', '')
    if content_type.split(';', 1)[0].strip().lower() != 'application/json':
      self._reject_post(415, b'Unsupported Media Type: expected application/json')
      return
    # Cross-site requests are rejected outright (defence in depth for
    # the safelisted-content-type case above).
    if not self._origin_is_same():
      self._reject_post(403, b'Forbidden: cross-origin writes are not allowed')
      return
    # Parsed before the early rejections, which drain the body they never
    # read (see _drain_request_body).
    length = self._declared_content_length()
    # ── Rate limit: max 30 POSTs per 60s sliding window ──
    if not self._rate_limit_ok():
      self._reject_post(
        429,
        b'Rate limit exceeded. Max 30 POST requests per 60 seconds.',
        cors=True, extra_headers=(('Retry-After', '60'),))
      return
    # Reject an oversized body before reading it: without this a caller
    # can force a multi-GB allocation that the size validator (which runs
    # on the parsed object) would never get the chance to refuse.
    if length > MAX_PAYLOAD_SIZE:
      self._reject_post(413, b'Payload too large', cors=True)
      return
    try:
      payload = self._read_json_object(length)
      self._store_validated_graph(payload)

      self.send_response(200)
      # No Access-Control-Allow-Origin on write responses: a cross-origin
      # caller must not be able to read the result either.
      self._send_cors_headers()
      self.end_headers()
      self.wfile.write(b'OK')
    except (json.JSONDecodeError, ValueError, OSError) as e:
      self.send_response(400)
      self.send_header('Content-Type', 'text/plain')
      self._send_cors_headers()
      self.end_headers()
      self.wfile.write(str(e).encode())

  def do_POST(self):
    if self.path == '/graph.json':
      self._handle_graph_post()
      return
    # SimpleHTTPRequestHandler has no do_POST — respond 404 for unknown paths.
    self.send_error(404, "Not Found")


def build_graph_handler(*, serve_dir: str, store: str, graph_db: str,
                        view_mode: str, semantic_threshold: float,
                        memory_db: str | None) -> type[GraphRequestHandler]:
  """Create the handler class for one server, carrying its configuration.

  The returned subclass owns a fresh rate-limiter list, so two servers (or
  two tests) never share the sliding window.
  """
  class _ConfiguredGraphRequestHandler(GraphRequestHandler):
    _rl_requests: list[float] = []

  _ConfiguredGraphRequestHandler.serve_dir = serve_dir
  _ConfiguredGraphRequestHandler.store = store
  _ConfiguredGraphRequestHandler.graph_db = graph_db
  _ConfiguredGraphRequestHandler.view_mode = view_mode
  _ConfiguredGraphRequestHandler.semantic_threshold = semantic_threshold
  _ConfiguredGraphRequestHandler.memory_db = memory_db
  return _ConfiguredGraphRequestHandler


def serve_file(path: str, host: str = '127.0.0.1', port: int = 0, store_path: str | None = None, force_embed: bool = False, graph_db_path: str | None = None, view_mode: str = 'overview', semantic_threshold: float = 0.82, reporter: Callable[[str], None] | None = None):
  """Serve the graph and frontend until interrupted.

  Builds the configured handler, starts an HTTPServer on (host, port), and
  blocks in serve_forever.  The lifecycle is kept separate from request
  handling so the handler class can be exercised without a listener.
  """
  serve_dir, filename, using_built_frontend = resolve_serve_target(path, force_embed=force_embed)
  handler_cls = build_graph_handler(
    serve_dir=serve_dir,
    store=store_path or os.path.expanduser('~/.openclaw/kgraph.json'),
    graph_db=graph_db_path or os.path.expanduser(GRAPH_DB_DEFAULT),
    view_mode=(view_mode or 'overview').lower(),
    semantic_threshold=float(semantic_threshold),
    memory_db=resolve_memory_db_path(),
  )
  handler = partial(handler_cls, directory=serve_dir)
  httpd = HTTPServer((host, port), handler)
  # server_address may be a 4-tuple (IPv6) and the host may be bytes per
  # typeshed; only host/port are used here.
  addr = httpd.server_address[0]
  used_port = httpd.server_address[1]
  if isinstance(addr, (bytes, bytearray)):
    addr = addr.decode()
  if using_built_frontend:
    url = f'http://{addr}:{used_port}/'
  else:
    url = f'http://{addr}:{used_port}/{filename}'
  # Open browser in background if available but don't block
  try:
    threading.Thread(target=webbrowser.open, args=(url,), daemon=True).start()
  except OSError:
    logger.debug('could not open a browser for %s', url, exc_info=True)

  # The banner goes through the reporter the CLI passes in (cli.cmd_render passes
  # `print`); a library caller that omits it gets no stdout side effect.
  if reporter is not None:
    reporter(f'Serving {url}')
  try:
    httpd.serve_forever()
  except KeyboardInterrupt:
    httpd.shutdown()
