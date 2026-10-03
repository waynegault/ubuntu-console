"""MCP (Model Context Protocol) server for kgraph.

Exposes kgraph data via MCP tools for querying the graph
from LLMs during tool-call mode.

Provides tools:
- kgraph_query: find nodes matching a pattern
- kgraph_path: path between two nodes — fewest-hop ("bfs", the default) or
  maximum-strength ("strongest"); the mode is named on the result
- kgraph_explain: describe a node and its connections
- kgraph_community: the community digest — members, central nodes, boundary edges
- kgraph_report: generate a current graph report
- kgraph_stats: basic graph statistics

The request handler is module-level and configured per server by
build_mcp_handler(), so the JSON-RPC dispatch can be exercised without
starting a listener.
"""

import json
import logging
import os
import time
from collections.abc import Callable
from http.server import BaseHTTPRequestHandler
from urllib.parse import urlsplit

from .query import (
    PATH_MODE_BFS,
    PATH_MODE_STRONGEST,
    find_path_result,
    query_nodes,
    explain_node,
)
from .community import community_view
from .report import generate_report
from .graph_db import load_from_graph_db
from .constants import GRAPH_DB_DEFAULT
from .validate import MAX_PAYLOAD_SIZE
# Lazy imports to avoid circular dependency via __init__.py

logger = logging.getLogger(__name__)

# kgraph_report writes a file; confine it to a dedicated directory so a caller
# cannot pick an arbitrary path (e.g. ~/.bashrc). Overridable via KG_REPORTS_DIR.
_REPORTS_DIR_DEFAULT = '~/.openclaw/kgraph-reports'


def _reports_dir() -> str:
    """Directory that kgraph_report may write into."""
    return os.path.expanduser(os.environ.get('KG_REPORTS_DIR', _REPORTS_DIR_DEFAULT))


def _safe_report_path(name: str | None) -> str | None:
    """Resolve *name* inside the reports dir, or None if it escapes it.

    Takes `str | None` because an absent name is not a path: an RPC that omits
    the report name must be refused with the same None as a traversal attempt
    rather than raising.  Rejects absolute paths and any ``..`` traversal.
    """
    if not name or os.path.isabs(name):
        return None
    if '..' in name.replace('\\', '/').split('/'):
        return None
    # normpath the base too: a KG_REPORTS_DIR with a trailing slash would make
    # `base + os.sep` a doubled separator, so no normalised target could ever
    # match the prefix and every legitimate name would be rejected.
    base = os.path.normpath(_reports_dir())
    target = os.path.normpath(os.path.join(base, name))
    if target != base and not target.startswith(base + os.sep):
        return None
    return target


# The tool list is long and static; keeping it out of the dispatch method keeps
# each route body short.  It is a deep-ish literal, so it lives at module level.
_TOOL_LIST: list[dict] = [
    {
        'name': 'kgraph_query',
        'description': 'Find nodes matching a pattern',
        'parameters': {
            'pattern': 'search pattern (label/type)',
            'max_results': 'max results (default 20)',
        }
    },
    {
        'name': 'kgraph_path',
        'description': (
            'Path between two nodes. Two modes, and the result names the '
            'one used: "bfs" (default) is the fewest-hop path; '
            '"strongest" maximizes the product of the edges\' '
            'semantic_score strengths (cost -log(strength) per edge). '
            'The modes can disagree — the strongest path may be longer '
            'than the shortest one.'
        ),
        'parameters': {
            'source': 'source node id or label',
            'target': 'target node id or label',
            'max_depth': 'max path length (default 6)',
            'mode': f'"{PATH_MODE_BFS}" (default) or "{PATH_MODE_STRONGEST}"',
        }
    },
    {
        'name': 'kgraph_explain',
        'description': (
            'Describe a node and its connections. Each connection carries the '
            '"sources" that asserted it (source documents, for citation), and '
            'the node carries its community when the graph has a cached '
            'community digest.'
        ),
        'parameters': {'node_id': 'node id or label'},
    },
    {
        'name': 'kgraph_community',
        'description': (
            'Community digest — "what are the main themes". Without '
            'community_id: one entry per community (label, size, central '
            'nodes, bridging god nodes, boundary-edge count). With '
            'community_id: that community\'s members, central nodes and '
            'boundary edges. Read-only, from the digest cached with the graph '
            'by kgraph update.'
        ),
        'parameters': {
            'community_id': (
                'optional community id, e.g. "community_0"; omit for the '
                'whole-graph theme list'
            ),
        },
    },
    {
        'name': 'kgraph_report',
        'description': (
            'Generate a graph report. Over HTTP this tool is reached as a '
            'JSON-RPC POST and is accepted ONLY with '
            'Content-Type: application/json (a cross-origin, '
            'form-encoded or oversized request is refused); the file is '
            'written inside the kgraph reports directory.'
        ),
        'parameters': {
            'outpath': (
                'optional path RELATIVE to the kgraph reports directory '
                '(KG_REPORTS_DIR, default ~/.openclaw/kgraph-reports); '
                'absolute paths and ".." are rejected'
            ),
        },
    },
    {
        'name': 'kgraph_stats',
        'description': 'Basic graph statistics',
        'parameters': {},
    },
]


class MCPHandler(BaseHTTPRequestHandler):
    """JSON-RPC-over-HTTP request handler for the kgraph MCP tools.

    Configuration (the pre-loaded graph and its DB path) lives on the class so
    a factory-created subclass carries it; the class itself is module-level so
    its dispatch methods can be tested without a listener.
    """

    # Per-server state, replaced by build_mcp_handler's subclass.
    graph: dict = {'nodes': [], 'edges': []}
    graph_db = ''

    # ── Inline rate limiter (class-level, shared) ──
    _rl_requests: list[float] = []

    # RPC method name → dispatch method name.
    _TOOL_METHODS = {
        'kgraph_query': '_tool_query',
        'kgraph_path': '_tool_path',
        'kgraph_explain': '_tool_explain',
        'kgraph_community': '_tool_community',
        'kgraph_report': '_tool_report',
        'kgraph_stats': '_tool_stats',
        'list_tools': '_tool_list_tools',
    }

    def _rate_limit_check(self) -> bool:
        now = time.monotonic()
        cutoff = now - 60.0
        type(self)._rl_requests = [t for t in type(self)._rl_requests if t > cutoff]
        if len(type(self)._rl_requests) >= 30:
            resp = json.dumps({
                'jsonrpc': '2.0',
                'error': {'code': -32000, 'message': 'Rate limit exceeded'},
                'id': None,
            })
            self.send_response(429)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Retry-After', '60')
            self.end_headers()
            self.wfile.write(resp.encode('utf-8'))
            return False
        type(self)._rl_requests.append(now)
        return True

    def _reload_graph(self):
        if os.path.exists(self.graph_db):
            self.graph = load_from_graph_db(self.graph_db).to_dict()
        return True

    def _origin_is_same(self) -> bool:
        """True when the request Origin matches the Host it was sent to.

        Browsers set Origin themselves and script cannot forge it, so this
        blocks cross-site POSTs.  Requests without an Origin header (MCP
        clients, curl) are not browser-originated and stay allowed.
        """
        origin = self.headers.get('Origin')
        if not origin:
            return True
        host = self.headers.get('Host', '')
        return bool(host) and urlsplit(origin).netloc == host

    def _body_or_error(self) -> bytes | None:
        """Read the request body, or answer the request and return None.

        Runs the transport guards in the order the write path relied on:
        content type, same-origin, then a Content-Length bound checked BEFORE
        any read (a negative length must never reach rfile.read(-1)).  Returns
        the raw body on success.
        """
        # Only JSON bodies are accepted.  `application/json` is not a
        # CORS-safelisted content type, so a cross-origin caller would have
        # to preflight — and do_OPTIONS refuses POST preflights.  Without
        # this a visited web page could reach kgraph_report, which writes
        # to an attacker-chosen path.
        content_type = self.headers.get('Content-Type', '')
        if content_type.split(';', 1)[0].strip().lower() != 'application/json':
            # Not draining the body would leave it queued on a keep-alive
            # connection and desync the next request, so close it.
            self.close_connection = True
            self._send_error(415, 'Unsupported Media Type: expected application/json')
            return None
        if not self._origin_is_same():
            self.close_connection = True
            self._send_error(403, 'Forbidden: cross-origin writes are not allowed')
            return None

        try:
            length = int(self.headers.get('Content-Length', 0) or 0)
        except (TypeError, ValueError):
            length = 0
        # Refuse a negative or oversized body BEFORE reading it. A negative
        # length must not reach rfile.read(-1), which reads until EOF —
        # unbounded and blocking.
        if length < 0:
            self.close_connection = True
            self._send_error(400, 'Invalid Content-Length')
            return None
        # A caller could otherwise force a multi-GB allocation that the
        # backstop size check below would never get the chance to refuse.
        if length > MAX_PAYLOAD_SIZE:
            self.close_connection = True
            self._send_error(413, 'Payload too large')
            return None
        body = self.rfile.read(length)

        # Backstop: the header may under-declare the actual body size.
        if len(body) > MAX_PAYLOAD_SIZE:
            self._send_error(413, 'Payload too large')
            return None
        return body

    def do_POST(self):
        body = self._body_or_error()
        if body is None:
            return

        # Rate limiting
        if not self._rate_limit_check():
            return

        try:
            req = json.loads(body.decode('utf-8'))
        except (json.JSONDecodeError, UnicodeDecodeError):
            self._send_error(400, 'Invalid JSON')
            return

        method = req.get('method', '')
        params = req.get('params', {})
        req_id = req.get('id', 0)

        self._reload_graph()
        try:
            result = self._dispatch(method, params)
        except Exception as exc:
            # A tool error must yield a JSON-RPC error, not a dropped
            # connection plus a traceback on the server.
            logger.error("MCP dispatch failed for %s: %s", method, exc, exc_info=True)
            self._send_json(200, json.dumps({
                'jsonrpc': '2.0',
                'error': {'code': -32603, 'message': str(exc)},
                'id': req_id,
            }))
            return

        self._send_json(200, json.dumps({'jsonrpc': '2.0', 'result': result, 'id': req_id}))

    def do_OPTIONS(self):
        # Cross-origin writes are not supported: never approve a POST
        # preflight, so a visited web page can never POST to a tool.
        if self.headers.get('Access-Control-Request-Method', '').upper() == 'POST':
            self.send_response(403)
            self.end_headers()
            return
        self.send_response(204)
        self.end_headers()

    def _send_json(self, code, payload):
        self.send_response(code)
        self.send_header('Content-Type', 'application/json')
        self.end_headers()
        self.wfile.write(payload.encode('utf-8'))

    def _send_error(self, code, msg):
        self._send_json(code, json.dumps({'error': msg}))

    def _dispatch(self, method: str, params: dict):
        handler_name = self._TOOL_METHODS.get(method)
        if handler_name is None:
            return {'error': f'Unknown method: {method}'}
        return getattr(self, handler_name)(params)

    def _tool_query(self, params: dict):
        pattern = params.get('pattern', '')
        max_results = params.get('max_results', 20)
        results = query_nodes(self.graph, pattern, max_results=max_results)
        # Return minimal representation, with the match strength so a caller can
        # threshold the set or flag a weak one instead of trusting row one.
        return [
            {'id': n.get('id'), 'label': n.get('label'), 'type': n.get('type'),
             'score': n.get('score'), 'match': n.get('match'),
             'degree': n.get('degree', 0), 'importance': n.get('importance', 1)}
            for n in results
        ]

    def _tool_path(self, params: dict):
        src = params.get('source', '')
        tgt = params.get('target', '')
        max_depth = params.get('max_depth', 6)
        # The mode is an explicit RPC parameter AND is echoed on the
        # result: a caller that cannot see which mode ran cannot tell a
        # fewest-hop path from a maximum-strength one.  An unknown mode
        # raises and comes back as a JSON-RPC error rather than being
        # silently replaced by the default.
        mode = str(params.get('mode', PATH_MODE_BFS) or PATH_MODE_BFS)
        result = find_path_result(self.graph, src, tgt, mode=mode, max_depth=max_depth)
        return {
            'mode': result['mode'],
            'path_found': result['path_found'],
            'edges': result['edges'],
        }

    def _tool_explain(self, params: dict):
        node_id = params.get('node_id', '')
        return explain_node(self.graph, node_id)

    def _tool_community(self, params: dict):
        # Answers "what are the main themes" from the cached community
        # digest (REF: "GraphRAG: A Practitioner's Guide to 6 Advanced
        # Architectural Patterns", Partha Sarkar, TDS, 2026-09-20 — the
        # community reports the article calls "especially important for
        # global reasoning").  Read-only: the digest is built by
        # `kgraph update` and stored with the graph.
        community_id = str(params.get('community_id', '') or '')
        return community_view(self.graph, community_id)

    def _tool_report(self, params: dict):
        outpath = params.get('outpath', None)
        if outpath:
            safe = _safe_report_path(str(outpath))
            if safe is None:
                return {'error': 'outpath must be a relative path inside the kgraph reports directory'}
            outpath = safe
        report = generate_report(self.graph, outpath=outpath)
        return {'report': report}

    def _tool_stats(self, params: dict):
        nodes = self.graph.get('nodes', [])
        edges = self.graph.get('edges', [])
        node_types: dict[str, int] = {}
        for n in nodes:
            t = str(n.get('type', 'unknown'))
            node_types[t] = node_types.get(t, 0) + 1
        return {
            'nodes': len(nodes),
            'edges': len(edges),
            'node_types': node_types,
        }

    def _tool_list_tools(self, params: dict):
        return _TOOL_LIST


def build_mcp_handler(graph_payload: dict, graph_db_path: str) -> type[MCPHandler]:
    """Create the handler class for one server, carrying its graph state.

    The returned subclass owns a fresh rate-limiter list so two servers never
    share the sliding window.
    """
    class _ConfiguredMCPHandler(MCPHandler):
        graph = graph_payload
        graph_db = graph_db_path
        _rl_requests: list[float] = []

    return _ConfiguredMCPHandler


def serve_mcp(host: str = '127.0.0.1', port: int = 0, graph_db: str | None = None,
              reporter: Callable[[str], None] | None = None):
    """Serve MCP-style JSON-RPC over HTTP.

    This is a lightweight implementation. For a full MCP spec server,
    consider using the official MCP Python SDK.
    """
    graph_db_path = os.path.expanduser(graph_db or GRAPH_DB_DEFAULT)
    graph_payload: dict = {'nodes': [], 'edges': []}
    if os.path.exists(graph_db_path):
        graph_payload = load_from_graph_db(graph_db_path).to_dict()

    # Imported here (not at module level) so a test can stub the HTTPServer the
    # module actually uses at call time without a real listener.
    from http.server import HTTPServer

    httpd = HTTPServer((host, port), build_mcp_handler(graph_payload, graph_db_path))
    # server_address host may be bytes per typeshed; only used for display.
    addr = httpd.server_address[0]
    used_port = httpd.server_address[1]
    if isinstance(addr, (bytes, bytearray)):
        addr = addr.decode()
    # The banner is emitted through the reporter the CLI passes in (cli.cmd_mcp
    # passes `print`); a library caller that omits it gets no stdout side effect.
    if reporter is not None:
        reporter(f'MCP server listening on {addr}:{used_port}')
        reporter('  Tools: kgraph_query, kgraph_path, kgraph_explain, kgraph_community, '
                 'kgraph_report, kgraph_stats')
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        httpd.shutdown()
