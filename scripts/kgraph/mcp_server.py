"""MCP (Model Context Protocol) server for kgraph.

Exposes kgraph data via MCP tools for querying the graph
from LLMs during tool-call mode.

Provides tools:
- kgraph_query: find nodes matching a pattern
- kgraph_path: shortest path between two nodes
- kgraph_explain: describe a node and its connections
- kgraph_report: generate a current graph report
- kgraph_stats: basic graph statistics
"""

import json
import os
import sys
from .query import query_nodes, find_path, explain_node, format_explain, format_path
from .report import generate_report
from .graph_db import load_from_graph_db
from .constants import GRAPH_DB_DEFAULT
# Lazy imports to avoid circular dependency via __init__.py


def serve_mcp(host: str = '127.0.0.1', port: int = 0, graph_db: str | None = None):
    """Serve MCP-style JSON-RPC over HTTP.

    This is a lightweight implementation. For a full MCP spec server,
    consider using the official MCP Python SDK.
    """
    # Lazy imports to avoid circular dependency
    from .security import RateLimiter, detect_json_bomb, sanitize_graph

    _security = {
        'rate_limiter': RateLimiter(max_requests=30, window=60),
        'detect_json_bomb': detect_json_bomb,
    }

    graph_db_path = os.path.expanduser(graph_db or GRAPH_DB_DEFAULT)
    graph = load_from_graph_db(graph_db_path) if os.path.exists(graph_db_path) else {'nodes': [], 'edges': []}

    from http.server import HTTPServer, BaseHTTPRequestHandler
    import urllib.parse

    class MCPHandler(BaseHTTPRequestHandler):
        graph = graph
        graph_db = graph_db_path
        _rate_limiter = _security['rate_limiter']
        _detect_bomb = _security['detect_json_bomb']

        def _reload_graph(self):
            if os.path.exists(self.graph_db):
                self.graph = load_from_graph_db(self.graph_db)

        def _rate_limit_check(self) -> bool:
            if not self._rate_limiter.allow():
                resp = json.dumps({
                    'jsonrpc': '2.0',
                    'error': {'code': -32000, 'message': 'Rate limit exceeded'},
                    'id': None,
                })
                self.send_response(429)
                self.send_header('Content-Type', 'application/json')
                self.send_header('Access-Control-Allow-Origin', '*')
                self.send_header('Retry-After', '60')
                self.end_headers()
                self.wfile.write(resp.encode('utf-8'))
                return False
            return True

        def do_POST(self):
            length = int(self.headers.get('Content-Length', 0))
            body = self.rfile.read(length)

            # Check for JSON bombs / oversized payloads
            bomb_issues = self._detect_bomb(body)
            has_fatal = any(i.get('severity') == 'error' for i in bomb_issues)
            if has_fatal:
                self.send_response(413)
                self.send_header('Content-Type', 'application/json')
                self.send_header('Access-Control-Allow-Origin', '*')
                self.end_headers()
                self.wfile.write(json.dumps({
                    'error': 'Payload rejected: ' + bomb_issues[0].get('message', 'oversize'),
                }).encode('utf-8'))
                return

            # Rate limiting
            if not self._rate_limit_check():
                return

            try:
                req = json.loads(body.decode('utf-8'))
            except Exception:
                self._send_error(400, 'Invalid JSON')
                return

            method = req.get('method', '')
            params = req.get('params', {})
            req_id = req.get('id', 0)

            self._reload_graph()
            result = self._dispatch(method, params)

            resp = json.dumps({'jsonrpc': '2.0', 'result': result, 'id': req_id})
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Access-Control-Allow-Origin', '*')
            self.end_headers()
            self.wfile.write(resp.encode('utf-8'))

        def do_OPTIONS(self):
            self.send_response(204)
            self.send_header('Access-Control-Allow-Origin', '*')
            self.send_header('Access-Control-Allow-Methods', 'POST, OPTIONS')
            self.send_header('Access-Control-Allow-Headers', 'Content-Type')
            self.end_headers()

        def _send_error(self, code, msg):
            self.send_response(code)
            self.end_headers()
            self.wfile.write(json.dumps({'error': msg}).encode())

        def _dispatch(self, method: str, params: dict):
            if method == 'kgraph_query':
                pattern = params.get('pattern', '')
                max_results = params.get('max_results', 20)
                results = query_nodes(self.graph, pattern, max_results=max_results)
                # Return minimal representation
                return [
                    {'id': n.get('id'), 'label': n.get('label'), 'type': n.get('type'),
                     'degree': n.get('degree', 0), 'importance': n.get('importance', 1)}
                    for n in results
                ]

            elif method == 'kgraph_path':
                src = params.get('source', '')
                tgt = params.get('target', '')
                max_depth = params.get('max_depth', 6)
                path = find_path(self.graph, src, tgt, max_depth=max_depth)
                return {'path_found': bool(path), 'edges': path}

            elif method == 'kgraph_explain':
                node_id = params.get('node_id', '')
                explanation = explain_node(self.graph, node_id)
                return explanation

            elif method == 'kgraph_report':
                outpath = params.get('outpath', None)
                report = generate_report(self.graph, outpath=outpath)
                return {'report': report}

            elif method == 'kgraph_stats':
                nodes = self.graph.get('nodes', [])
                edges = self.graph.get('edges', [])
                node_types = {}
                for n in nodes:
                    t = str(n.get('type', 'unknown'))
                    node_types[t] = node_types.get(t, 0) + 1
                return {
                    'nodes': len(nodes),
                    'edges': len(edges),
                    'node_types': node_types,
                }

            elif method == 'list_tools':
                return [
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
                        'description': 'Shortest path between two nodes',
                        'parameters': {
                            'source': 'source node id or label',
                            'target': 'target node id or label',
                            'max_depth': 'max path length (default 6)',
                        }
                    },
                    {
                        'name': 'kgraph_explain',
                        'description': 'Describe a node and its connections',
                        'parameters': {'node_id': 'node id or label'},
                    },
                    {
                        'name': 'kgraph_report',
                        'description': 'Generate a graph report',
                        'parameters': {'outpath': 'optional output path'},
                    },
                    {
                        'name': 'kgraph_stats',
                        'description': 'Basic graph statistics',
                        'parameters': {},
                    },
                ]

            else:
                return {'error': f'Unknown method: {method}'}

    httpd = HTTPServer((host, port), MCPHandler)
    addr, used_port = httpd.server_address
    print(f'MCP server listening on {addr}:{used_port}')
    print(f'  Tools: kgraph_query, kgraph_path, kgraph_explain, kgraph_report, kgraph_stats')
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        httpd.shutdown()
