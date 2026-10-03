"""Tests for kgraph.server — the POST /graph.json write path and handler construction."""

import http.client
import json
import os
import tempfile
import threading
import unittest
from http.server import HTTPServer
from unittest import mock

from _kgraph_fixtures import _SMALL_GRAPH, _FakeHTTPServer
import kgraph


class TestGraphServerPost(unittest.TestCase):
    """Hermetic coverage of the POST /graph.json write path.

    ``serve_file`` blocks in serve_forever, so its (module-local)
    HTTPServer is replaced with a capturing stub to obtain the real handler
    class; a real server is then started on an ephemeral port for the test.
    Only the module-local names are patched, so no global object is mocked.
    """

    def setUp(self):
        td = tempfile.TemporaryDirectory()
        self.addCleanup(td.cleanup)
        self.db_path = os.path.join(td.name, "graph.sqlite")
        self.store_path = os.path.join(td.name, "store.json")
        with open(self.store_path, "w", encoding="utf-8") as f:
            json.dump({"nodes": [], "edges": []}, f)
        kgraph.save_to_graph_db(self.db_path, _SMALL_GRAPH)

        from kgraph import server as kgraph_server

        captured: dict = {}
        _FakeHTTPServer.captured = captured
        with (
            mock.patch.object(kgraph_server, "HTTPServer", _FakeHTTPServer),
            mock.patch.object(kgraph_server, "webbrowser"),
            mock.patch.object(kgraph_server, "resolve_memory_db_path", return_value=None),
        ):
            kgraph_server.serve_file(
                self.store_path, host="127.0.0.1", force_embed=True,
                graph_db_path=self.db_path, store_path=self.store_path,
            )

        httpd = HTTPServer(("127.0.0.1", 0), captured["handler"])
        self.addCleanup(httpd.server_close)
        threading.Thread(target=httpd.serve_forever, daemon=True).start()
        self.addCleanup(httpd.shutdown)
        self.port = httpd.server_address[1]

    def _request(self, method, path, body=None, headers=None):
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        try:
            conn.request(method, path, body=body, headers=headers or {})
            resp = conn.getresponse()
            return resp.status, resp.read(), dict(resp.getheaders())
        finally:
            conn.close()

    def _post(self, body, content_type="application/json", origin=None):
        headers = {"Content-Type": content_type} if content_type else {}
        if origin:
            headers["Origin"] = origin
        return self._request("POST", "/graph.json", body=body, headers=headers)

    def _node_ids(self):
        return {n.id for n in kgraph.load_from_graph_db(self.db_path).nodes}

    def test_get_read_path_echoes_allowlisted_origin(self):
        # The Vite dev frontend is the one cross-origin reader the read path is
        # meant to serve, so its Origin is echoed back.
        status, body, headers = self._request(
            "GET", "/graph.json?view=raw",
            headers={"Origin": "http://localhost:5173"},
        )
        self.assertEqual(status, 200)
        self.assertEqual(headers.get("Access-Control-Allow-Origin"),
                         "http://localhost:5173")
        self.assertEqual(headers.get("Vary"), "Origin")
        self.assertIn("nodes", json.loads(body))

    def test_get_read_path_withholds_cors_from_foreign_origin(self):
        # No allowlisted match => no Access-Control-Allow-Origin, so a page the
        # user visits cannot read the graph. Regression guard for the old
        # `Access-Control-Allow-Origin: *`.
        status, body, headers = self._request(
            "GET", "/graph.json?view=raw",
            headers={"Origin": "http://evil.example"},
        )
        self.assertEqual(status, 200)
        self.assertIsNone(headers.get("Access-Control-Allow-Origin"))
        self.assertIn("nodes", json.loads(body))

    def test_get_read_path_without_origin_needs_no_cors(self):
        # curl and MCP clients send no Origin; CORS is browser-enforced, so the
        # read path still serves them — just with no allow-origin header.
        status, body, headers = self._request("GET", "/graph.json?view=raw")
        self.assertEqual(status, 200)
        self.assertIsNone(headers.get("Access-Control-Allow-Origin"))
        self.assertIn("nodes", json.loads(body))

    def test_get_redacts_memory_text(self):
        # A memory node's stored label IS a preview of its content
        # (memory_import sets label = _preview_text(content)), so the
        # cross-origin read path must not serve it, nor the content fields.
        graph = {
            "nodes": [
                {"id": "memory:abc12345-6789-4abc",
                 "label": "NAS SSH access available for storage management",
                 "type": "memory",
                 "content": "NAS SSH access available for storage management",
                 "tags": "infra",
                 "content_preview": "NAS SSH access available ..."},
                {"id": "summary:def99999-1111",
                 "label": "Weekly legal briefing",
                 "type": "summary",
                 "content_preview": "Weekly legal briefing body"},
                {"id": "topic:keep", "label": "Legal research", "type": "topic",
                 "content_preview": "Legal research notes"},
            ],
            "edges": [],
        }
        kgraph.save_to_graph_db(self.db_path, graph)

        status, body, _ = self._request("GET", "/graph.json?view=raw")
        self.assertEqual(status, 200)
        nodes = {n["id"]: n for n in json.loads(body)["nodes"]}

        mem = nodes["memory:abc12345-6789-4abc"]
        self.assertEqual(mem["label"], "memory abc12345")
        self.assertNotIn("content", mem)
        self.assertNotIn("tags", mem)
        self.assertNotIn("content_preview", mem)

        summary = nodes["summary:def99999-1111"]
        self.assertEqual(summary["label"], "summary def99999")
        self.assertNotIn("content_preview", summary)

        # A non-memory node keeps its label, but still loses the content preview.
        topic = nodes["topic:keep"]
        self.assertEqual(topic["label"], "Legal research")
        self.assertNotIn("content_preview", topic)

    def test_valid_post_replaces_graph(self):
        payload = {"nodes": [{"id": "only", "label": "Only"}], "edges": []}
        status, body, _ = self._post(json.dumps(payload))
        self.assertEqual(status, 200)
        self.assertEqual(body, b"OK")
        self.assertEqual(self._node_ids(), {"only"})

    def test_malformed_body_does_not_wipe_graph(self):
        status, _, _ = self._post(b"{ this is not json")
        self.assertEqual(status, 400)
        self.assertEqual(self._node_ids(), {"a", "b", "c"})

    def test_schema_invalid_body_does_not_wipe_graph(self):
        status, _, _ = self._post(json.dumps({"nodes": "not-a-list"}))
        self.assertEqual(status, 400)
        self.assertEqual(self._node_ids(), {"a", "b", "c"})

    def test_non_json_content_type_rejected(self):
        status, _, _ = self._post(json.dumps({"nodes": []}), content_type="text/plain")
        self.assertEqual(status, 415)
        self.assertEqual(self._node_ids(), {"a", "b", "c"})

    def test_cross_origin_post_rejected(self):
        status, _, _ = self._post(
            json.dumps({"nodes": []}), origin="http://evil.example",
        )
        self.assertEqual(status, 403)
        self.assertEqual(self._node_ids(), {"a", "b", "c"})

    def test_write_response_omits_cors_header(self):
        status, _, headers = self._post(
            json.dumps({"nodes": [{"id": "x", "label": "X"}], "edges": []}),
        )
        self.assertEqual(status, 200)
        self.assertIsNone(headers.get("Access-Control-Allow-Origin"))

    def test_options_refuses_post_preflight(self):
        status, _, headers = self._request(
            "OPTIONS", "/graph.json",
            headers={"Origin": "http://evil.example", "Access-Control-Request-Method": "POST"},
        )
        self.assertEqual(status, 403)
        self.assertIsNone(headers.get("Access-Control-Allow-Origin"))

    def test_oversized_body_rejected(self):
        from kgraph import server as kgraph_server

        big = json.dumps({"nodes": [{"id": "big", "label": "x" * 200}], "edges": []})
        with mock.patch.object(kgraph_server, "MAX_PAYLOAD_SIZE", 10):
            status, _, _ = self._post(big)
        self.assertEqual(status, 413)
        self.assertEqual(self._node_ids(), {"a", "b", "c"})

    def test_xss_label_rejected_and_graph_intact(self):
        payload = {"nodes": [{"id": "x", "label": "<script>alert(1)</script>"}], "edges": []}
        status, _, _ = self._post(json.dumps(payload))
        self.assertEqual(status, 400)
        self.assertEqual(self._node_ids(), {"a", "b", "c"})

    def test_nested_xss_rejected_and_graph_intact(self):
        payload = {
            "nodes": [{"id": "x", "label": "ok",
                       "payload": {"note": "<script>alert(1)</script>"}}],
            "edges": [],
        }
        status, _, _ = self._post(json.dumps(payload))
        self.assertEqual(status, 400)
        self.assertEqual(self._node_ids(), {"a", "b", "c"})


class TestGraphHandlerConstruction(unittest.TestCase):
    """The HTTP handler is module-level and buildable without serve_file.

    Catches: a refactor that re-nests request handling inside serve_file (the
    card's original 312-line nested class), which makes the handler unreachable
    from tests and forces every case through a listener.  Also catches a
    factory that shares one rate-limiter list across servers.
    """

    def test_module_level_handler_serves_without_serve_file(self):
        from kgraph.server import GraphRequestHandler, build_graph_handler

        td = tempfile.TemporaryDirectory()
        self.addCleanup(td.cleanup)
        db = os.path.join(td.name, "graph.sqlite")
        kgraph.save_to_graph_db(db, _SMALL_GRAPH)

        handler_cls = build_graph_handler(
            serve_dir=os.getcwd(), store=os.path.join(td.name, "missing.json"),
            graph_db=db, view_mode="topics", semantic_threshold=0.9, memory_db=None)
        self.assertTrue(issubclass(handler_cls, GraphRequestHandler))

        httpd = HTTPServer(("127.0.0.1", 0), handler_cls)
        self.addCleanup(httpd.server_close)
        threading.Thread(target=httpd.serve_forever, daemon=True).start()
        self.addCleanup(httpd.shutdown)
        conn = http.client.HTTPConnection("127.0.0.1", httpd.server_address[1], timeout=5)
        try:
            conn.request("GET", "/graph.json?view=topics")
            resp = conn.getresponse()
            body = resp.read()
        finally:
            conn.close()
        self.assertEqual(resp.status, 200)
        self.assertIn("nodes", json.loads(body))

    def test_factory_gives_each_handler_its_own_rate_limiter(self):
        from kgraph.server import build_graph_handler

        first = build_graph_handler(
            serve_dir=".", store="", graph_db="", view_mode="overview",
            semantic_threshold=0.82, memory_db=None)
        second = build_graph_handler(
            serve_dir=".", store="", graph_db="", view_mode="raw",
            semantic_threshold=0.5, memory_db=None)
        self.assertEqual((first.view_mode, second.view_mode), ("overview", "raw"))
        first._rl_requests.append(1.0)
        # A list inherited from the base would leak the sliding window across
        # servers, so the second factory's class must still be empty.
        self.assertEqual(second._rl_requests, [])


class TestGraphServerRefusesSample(unittest.TestCase):
    """A read with no real source is refused, not answered with the sample graph.

    Catches (card 0a5f97d5): the server returned HTTP 200 with the synthetic
    SAMPLE_GRAPH and ``_meta.source == "sample"``, so fabricated data looked
    real.  The CLI may still print SAMPLE_GRAPH as its explicit default demo; the
    server must not serve it as a production graph.
    """

    def _get(self, handler_cls, path="/graph.json?view=raw"):
        httpd = HTTPServer(("127.0.0.1", 0), handler_cls)
        self.addCleanup(httpd.server_close)
        threading.Thread(target=httpd.serve_forever, daemon=True).start()
        self.addCleanup(httpd.shutdown)
        conn = http.client.HTTPConnection("127.0.0.1", httpd.server_address[1], timeout=5)
        try:
            conn.request("GET", path)
            resp = conn.getresponse()
            return resp.status, resp.read()
        finally:
            conn.close()

    def test_no_real_source_is_503_not_200_with_the_sample_graph(self):
        from kgraph.server import build_graph_handler

        handler = build_graph_handler(
            serve_dir=os.getcwd(), store="", graph_db="", view_mode="raw",
            semantic_threshold=0.5, memory_db=None)
        status, body = self._get(handler)
        self.assertEqual(status, 503)
        payload = json.loads(body)
        self.assertEqual(payload["error"], "graph unavailable")
        self.assertIn("sample graph", payload["detail"])
        self.assertNotIn("nodes", payload)

    def test_projection_failure_is_503_not_a_sample_fallback(self):
        from kgraph import server as kgraph_server

        td = tempfile.TemporaryDirectory()
        self.addCleanup(td.cleanup)
        db = os.path.join(td.name, "graph.sqlite")
        kgraph.save_to_graph_db(db, _SMALL_GRAPH)
        handler = kgraph_server.build_graph_handler(
            serve_dir=os.getcwd(), store="", graph_db=db, view_mode="raw",
            semantic_threshold=0.5, memory_db=None)
        with mock.patch.object(kgraph_server, "project_graph", side_effect=ValueError("boom")):
            status, body = self._get(handler)
        self.assertEqual(status, 503)
        self.assertIn("projection failed", json.loads(body)["detail"])

    def test_a_real_source_still_serves_200(self):
        # The control: a real graph DB is served as before, so the refusal did not
        # become a blanket failure.
        from kgraph.server import build_graph_handler

        td = tempfile.TemporaryDirectory()
        self.addCleanup(td.cleanup)
        db = os.path.join(td.name, "graph.sqlite")
        kgraph.save_to_graph_db(db, _SMALL_GRAPH)
        handler = build_graph_handler(
            serve_dir=os.getcwd(), store="", graph_db=db, view_mode="raw",
            semantic_threshold=0.5, memory_db=None)
        status, body = self._get(handler)
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body)["_meta"]["source"], "graph-db")


if __name__ == "__main__":
    unittest.main()
