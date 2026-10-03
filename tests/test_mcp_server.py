"""Tests for kgraph.mcp_server — JSON-RPC dispatch, guards, report paths, shutdown."""

import contextlib
import http.client
import io
import json
import os
import tempfile
import threading
import unittest
from http.server import HTTPServer
from unittest import mock

from _kgraph_fixtures import _SMALL_GRAPH, _FakeHTTPServer
import kgraph


class TestMCPServer(unittest.TestCase):
    def test_safe_report_path_confines_writes(self):
        """kgraph_report outpath stays inside the reports directory."""
        from kgraph.mcp_server import _safe_report_path
        with mock.patch.dict(os.environ, {"KG_REPORTS_DIR": "/tmp/kg-reports"}):
            self.assertEqual(_safe_report_path("r.md"), "/tmp/kg-reports/r.md")
            self.assertEqual(_safe_report_path("sub/r.md"), "/tmp/kg-reports/sub/r.md")
            self.assertIsNone(_safe_report_path("/etc/passwd"))
            self.assertIsNone(_safe_report_path(""))
            self.assertIsNone(_safe_report_path("../escape.md"))
            self.assertIsNone(_safe_report_path("a/../../escape.md"))


class _MCPHarness(unittest.TestCase):
    """The real handler on an ephemeral port; one handler class per test, so
    the class-level rate limiter cannot leak between tests."""

    def setUp(self):
        td = tempfile.TemporaryDirectory()
        self.addCleanup(td.cleanup)
        self.tmp = td.name
        self.db = os.path.join(self.tmp, "graph.sqlite")
        self.reports = os.path.join(self.tmp, "reports")
        os.makedirs(self.reports)
        kgraph.save_to_graph_db(self.db, _SMALL_GRAPH)
        env = mock.patch.dict(os.environ, {"KG_REPORTS_DIR": self.reports})
        env.start()
        self.addCleanup(env.stop)

        from kgraph import mcp_server

        captured: dict = {}
        _FakeHTTPServer.captured = captured
        stdout = io.StringIO()
        # mcp_server imports HTTPServer *inside* serve_mcp (no module-level name
        # to patch), so http.server, which owns the symbol, is stubbed for this
        # synchronous call only; the stub hands back the real handler class,
        # which is then served for real on an ephemeral port below.
        with (mock.patch("http.server.HTTPServer", _FakeHTTPServer),
              contextlib.redirect_stdout(stdout)):
            mcp_server.serve_mcp(host="127.0.0.1", graph_db=self.db, reporter=print)
        self.serve_stdout = stdout.getvalue()

        httpd = HTTPServer(("127.0.0.1", 0), captured["handler"])
        self.addCleanup(httpd.server_close)
        threading.Thread(target=httpd.serve_forever, daemon=True).start()
        self.addCleanup(httpd.shutdown)
        self.port = httpd.server_address[1]

    def _post(self, body, content_type="application/json", origin=None, length=None):
        headers = {}
        if content_type is not None:
            headers["Content-Type"] = content_type
        if origin is not None:
            headers["Origin"] = origin
        if length is not None:
            headers["Content-Length"] = str(length)
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        try:
            conn.request("POST", "/", body=body, headers=headers)
            resp = conn.getresponse()
            return resp.status, resp.read(), dict(resp.getheaders())
        finally:
            conn.close()

    def _post_retrying_reset(self, *args, **kwargs):
        """POST, retrying ONCE only on a ConnectionResetError.

        The server refuses an over-long (or negative) Content-Length by replying
        and closing WITHOUT draining the request body, so under coverage load the
        client can see the RST instead of the response (observed twice:
        socket.py ConnectionResetError).  ONLY that documented socket error is
        retried — any other error propagates — and the retried response is still
        returned, so a server that stopped answering fails on the second attempt
        rather than being excused.
        """
        try:
            return self._post(*args, **kwargs)
        except ConnectionResetError:
            return self._post(*args, **kwargs)

    def _call(self, method, params=None, req_id=1):
        status, raw, _ = self._post(json.dumps(
            {"jsonrpc": "2.0", "method": method, "params": params or {}, "id": req_id}))
        self.assertEqual(status, 200)
        return json.loads(raw)


class TestMCPServerTools(_MCPHarness):
    def test_banner_unknown_method_and_tool_list(self):
        self.assertIn("MCP server listening on 127.0.0.1:", self.serve_stdout)
        self.assertIn("kgraph_query, kgraph_path, kgraph_explain", self.serve_stdout)
        self.assertEqual(self._call("initialize")["result"],
                         {"error": "Unknown method: initialize"})
        tools = {t["name"]: t for t in self._call("list_tools")["result"]}
        self.assertEqual(set(tools), {"kgraph_query", "kgraph_path", "kgraph_explain",
                                      "kgraph_community",
                                      "kgraph_report", "kgraph_stats"})
        self.assertIn("pattern", tools["kgraph_query"]["parameters"])
        self.assertIn("source", tools["kgraph_path"]["parameters"])
        self.assertIn("mode", tools["kgraph_path"]["parameters"])
        self.assertIn("node_id", tools["kgraph_explain"]["parameters"])
        self.assertIn("KG_REPORTS_DIR", tools["kgraph_report"]["parameters"]["outpath"])
        self.assertEqual(tools["kgraph_stats"]["parameters"], {})

    def test_query_path_and_explain(self):
        result = self._call("kgraph_query", {"pattern": "Alpha"})["result"]
        self.assertEqual([{k: result[0][k] for k in ("id", "label", "type")}],
                         [{"id": "a", "label": "Alpha", "type": "topic"}])
        # An empty pattern matches every node, so max_results decides the cap.
        self.assertEqual(len(self._call("kgraph_query", {"pattern": ""})["result"]), 3)
        self.assertEqual(self._call("kgraph_query", {"pattern": "", "max_results": 0})["result"], [])
        found = self._call("kgraph_path", {"source": "a", "target": "c"})["result"]
        self.assertEqual([(e["source"], e["target"]) for e in found["edges"]],
                         [("a", "b"), ("b", "c")])
        # The payload names the mode that ran — the default here — and the same
        # tool takes the strength-weighted mode; neither may be left implicit,
        # because the two modes answer differently on a graph where they differ.
        self.assertEqual(found["mode"], "bfs")
        self.assertEqual(
            self._call("kgraph_path",
                       {"source": "a", "target": "c", "mode": "strongest"})["result"]["mode"],
            "strongest")
        self.assertEqual(self._call("kgraph_path", {"source": "a", "target": "zzz"})["result"],
                         {"mode": "bfs", "path_found": False, "edges": []})
        explained = self._call("kgraph_explain", {"node_id": "a"})["result"]
        self.assertEqual(explained["node"]["id"], "a")
        self.assertEqual((explained["outbound_count"], explained["inbound_count"]), (1, 0))
        self.assertEqual(explained["outbound_connections"][0]["target_label"], "Beta")

    def test_report_inline_confined_and_rejected(self):
        result = self._call("kgraph_report")["result"]
        self.assertTrue(result["report"].startswith("# Knowledge Graph Report"))
        self.assertIn("- **Nodes:** 3", result["report"])
        self.assertEqual(os.listdir(self.reports), [])
        result = self._call("kgraph_report", {"outpath": "sub/r.md"})["result"]
        with open(os.path.join(self.reports, "sub", "r.md"), encoding="utf-8") as f:
            self.assertEqual(f.read(), result["report"])
        message = {"error": "outpath must be a relative path inside the kgraph reports directory"}
        for bad in ("../escape.md", "/tmp/kgraph-abs-escape.md", "sub/../../escape.md"):
            self.assertEqual(self._call("kgraph_report", {"outpath": bad})["result"], message)
        self.assertFalse(os.path.exists(os.path.join(self.tmp, "escape.md")))

    def test_explain_reports_the_community_and_each_edges_sources(self):
        """GRAPHRAG-ARCH-006/007: lineage, its cap, and theme reach the MCP read path."""
        # b -> c is asserted by a source file; the graph carries a digest naming
        # a and b as one theme.
        kgraph.save_to_graph_db(self.db, {
            "nodes": [{"id": "a", "label": "Alpha", "type": "topic"},
                      {"id": "b", "label": "Beta", "type": "topic"},
                      {"id": "c", "label": "Gamma", "type": "topic"}],
            "edges": [{"from": "a", "to": "b", "label": "links", "sources": ["file:one.md"]},
                      # The list hit the array bound, so the true count is in the
                      # metadata and the payload has to carry it: 64 keys look exactly
                      # like a complete list otherwise.
                      {"from": "b", "to": "c", "label": "links", "sources": ["file:two.md"],
                       "metadata": {"sources_overflow": 900}}],
            "meta": {"communities": [{"id": "community_0", "label": "Cached · Theme",
                                      "size": 2, "members": ["a", "b"],
                                      "central_nodes": [{"id": "a", "label": "Alpha",
                                                         "composite_score": 0.5}],
                                      "god_nodes": [], "boundary_edges": [],
                                      "boundary_edge_count": 0}]},
        })
        explained = self._call("kgraph_explain", {"node_id": "b"})["result"]
        self.assertEqual(explained["node"]["community"],
                         {"id": "community_0", "label": "Cached · Theme", "size": 2})
        self.assertEqual(explained["inbound_connections"][0]["sources"], ["file:one.md"])
        self.assertEqual(explained["outbound_connections"][0]["sources"], ["file:two.md"])
        self.assertEqual(explained["outbound_connections"][0]["sources_overflow"], 900)
        # A complete list must NOT claim a cap, or the key means nothing.
        self.assertNotIn("sources_overflow", explained["inbound_connections"][0])

    def test_kgraph_community_answers_from_the_cached_digest(self):
        """The community tool exists, is listed, and does not recompute."""
        kgraph.save_to_graph_db(self.db, {
            "nodes": [{"id": "a", "label": "Alpha", "type": "topic"},
                      {"id": "b", "label": "Beta", "type": "topic"}],
            "edges": [{"from": "a", "to": "b", "label": "links"}],
            "meta": {"community_method": "cached-greedy",
                     "communities": [{"id": "community_0", "label": "Cached · Theme",
                                      "size": 2, "members": ["a", "b"],
                                      "central_nodes": [{"id": "a", "label": "Alpha",
                                                         "composite_score": 0.5}],
                                      "god_nodes": [{"id": "a", "label": "Alpha"}],
                                      "boundary_edges": [{"source": "a", "target": "z",
                                                          "label": "links",
                                                          "direction": "out"}],
                                      "boundary_edge_count": 1}]},
        })
        result = self._call("kgraph_community")["result"]
        self.assertEqual(result["source"], "digest")
        self.assertEqual(result["method"], "cached-greedy")
        self.assertEqual([c["label"] for c in result["communities"]], ["Cached · Theme"])
        single = self._call("kgraph_community", {"community_id": "community_0"})["result"]
        self.assertEqual(single["community"]["members"], ["a", "b"])
        self.assertEqual(single["community"]["boundary_edges"][0]["target"], "z")
        self.assertIn("error", self._call("kgraph_community",
                                         {"community_id": "community_9"})["result"])

    def test_stats_counts_types_and_reloads_the_db_per_request(self):
        self.assertEqual(self._call("kgraph_stats")["result"],
                         {"nodes": 3, "edges": 2,
                          "node_types": {"topic": 1, "project": 1, "decision": 1}})
        kgraph.save_to_graph_db(self.db, {"nodes": [{"id": "only", "label": "Only",
                                                    "type": "topic"}], "edges": []})
        self.assertEqual(self._call("kgraph_stats")["result"]["node_types"], {"topic": 1})

    def test_a_tool_failure_becomes_a_jsonrpc_error(self):
        with (mock.patch("kgraph.mcp_server.query_nodes", side_effect=RuntimeError("boom")),
              mock.patch("kgraph.mcp_server.logger") as log):
            status, raw, _ = self._post(json.dumps(
                {"jsonrpc": "2.0", "method": "kgraph_query", "params": {}, "id": 7}))
        self.assertEqual((status, json.loads(raw)),
                         (200, {"jsonrpc": "2.0", "id": 7,
                                "error": {"code": -32603, "message": "boom"}}))
        log.error.assert_called_once()

    def test_rate_limiter_refuses_the_thirty_first_post(self):
        self.assertEqual([self._call("kgraph_stats")["id"] for _ in range(30)], [1] * 30)
        status, raw, headers = self._post(json.dumps(
            {"jsonrpc": "2.0", "method": "kgraph_stats", "id": 31}))
        self.assertEqual((status, headers.get("Retry-After")), (429, "60"))
        self.assertEqual((json.loads(raw)["error"]["code"], json.loads(raw)["id"]), (-32000, None))


class TestMCPServerPostGuards(_MCPHarness):
    def test_content_type_guard(self):
        status, raw, _ = self._post("{}", content_type="text/plain")
        self.assertEqual((status, json.loads(raw)["error"]),
                         (415, "Unsupported Media Type: expected application/json"))
        self.assertEqual(self._post('{"method": "kgraph_stats", "id": 1}',
                                    content_type="application/json; charset=utf-8")[0], 200)

    def test_origin_guard(self):
        body = '{"jsonrpc": "2.0", "method": "kgraph_stats", "id": 1}'
        status, raw, _ = self._post(body, origin="http://evil.example")
        self.assertEqual(status, 403)
        self.assertIn("cross-origin", json.loads(raw)["error"])
        self.assertEqual(self._post(body, origin=f"http://127.0.0.1:{self.port}")[0], 200)
        self.assertEqual(self._post(body)[0], 200)  # no Origin (MCP client)

    def test_content_length_oversized_and_malformed_bodies(self):
        # Malformed/over-long Content-Length makes the server reply and close
        # without draining the body, so the client can see a RST under load; the
        # retry helper tolerates ONLY that socket error, and every status below is
        # still asserted (the well-formed oversized case included).
        status, raw, _ = self._post_retrying_reset(None, length=-1)
        self.assertEqual((status, json.loads(raw)), (400, {"error": "Invalid Content-Length"}))
        # A non-numeric length becomes 0, so the empty body cannot be parsed.
        status, raw, _ = self._post_retrying_reset("{", length="not-a-number")
        self.assertEqual((status, json.loads(raw)), (400, {"error": "Invalid JSON"}))
        with mock.patch("kgraph.mcp_server.MAX_PAYLOAD_SIZE", 10):
            status, raw, _ = self._post_retrying_reset("x" * 100)
        self.assertEqual((status, json.loads(raw)), (413, {"error": "Payload too large"}))
        status, raw, _ = self._post("{ not json")
        self.assertEqual((status, json.loads(raw)), (400, {"error": "Invalid JSON"}))

    def test_options_refuses_post_preflight(self):
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        try:
            conn.request("OPTIONS", "/", headers={
                "Origin": "http://evil.example", "Access-Control-Request-Method": "POST"})
            self.assertEqual(conn.getresponse().status, 403)
            conn.request("OPTIONS", "/", headers={
                "Origin": f"http://127.0.0.1:{self.port}",
                "Access-Control-Request-Method": "GET"})
            self.assertEqual(conn.getresponse().status, 204)
        finally:
            conn.close()


class TestMCPReportsPath(unittest.TestCase):
    def test_trailing_slash_tilde_empty_and_traversing_report_dirs(self):
        from kgraph.mcp_server import _reports_dir, _safe_report_path
        with mock.patch.dict(os.environ, {"KG_REPORTS_DIR": "/tmp/kg-reports/"}):
            self.assertEqual(_safe_report_path("r.md"), "/tmp/kg-reports/r.md")
            self.assertEqual(_safe_report_path("sub/r.md"), "/tmp/kg-reports/sub/r.md")
            self.assertIsNone(_safe_report_path("../escape.md"))
        with mock.patch.dict(os.environ, {"KG_REPORTS_DIR": "~/kg-reports"}):
            self.assertEqual(_reports_dir(), os.path.join(os.path.expanduser("~"), "kg-reports"))
        with mock.patch.dict(os.environ, {"KG_REPORTS_DIR": "/tmp/kg-reports"}):
            for bad in ("a\\..\\b.md", "sub/..", "", None):
                self.assertIsNone(_safe_report_path(bad))
        # "" normalises to ".", which can never prefix a joined name: the tool
        # refuses rather than resolving a report path against the cwd.
        with mock.patch.dict(os.environ, {"KG_REPORTS_DIR": ""}):
            self.assertIsNone(_safe_report_path("r.md"))


class TestMCPServerShutdown(unittest.TestCase):
    def test_keyboard_interrupt_shuts_the_server_down(self):
        from kgraph import mcp_server

        class _InterruptingHTTPServer:
            # Quoted annotation: the class names itself, and this module does not
            # import `annotations` from __future__, so an unquoted form would be
            # evaluated while the name is still being bound.
            last: "_InterruptingHTTPServer | None" = None

            def __init__(self, addr, handler):
                type(self).last = self
                self.server_address = (b"127.0.0.1", addr[1] or 1)  # bytes host
                self.shutdown_called = False

            def serve_forever(self):
                raise KeyboardInterrupt

            def shutdown(self):
                self.shutdown_called = True

        stdout = io.StringIO()
        with (mock.patch("http.server.HTTPServer", _InterruptingHTTPServer),
              contextlib.redirect_stdout(stdout)):
            mcp_server.serve_mcp(host="127.0.0.1", port=9999,
                                 graph_db=os.path.join(tempfile.gettempdir(),
                                                       "kgraph-missing.sqlite"),
                                 reporter=print)
        last_server = _InterruptingHTTPServer.last
        assert last_server is not None, "serve_mcp must have constructed the server"
        self.assertTrue(last_server.shutdown_called)
        self.assertIn("MCP server listening on 127.0.0.1:9999", stdout.getvalue())


if __name__ == "__main__":
    unittest.main()
