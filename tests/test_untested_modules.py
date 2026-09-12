"""Tests for previously untested kgraph modules.

Covers: call_flow, update, life_index, benchmark, mcp_server, pr_dashboard,
and the server's POST /graph.json write path.
"""

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

from _paths import REPO_ROOT

import kgraph


# ── Shared fixtures ────────────────────────────────────────────────────

_AST_GRAPH = {
    "nodes": [
        {"id": "ast_file:main_py", "label": "main.py", "type": "file", "source": "ast"},
        {"id": "ast_func:hello", "label": "hello", "type": "function", "source": "ast", "language": "python"},
        {"id": "ast_class:greeter", "label": "Greeter", "type": "class", "source": "ast", "language": "python"},
        {"id": "ast_module:os", "label": "os", "type": "module", "source": "ast"},
        {"id": "ast_call:print", "label": "print", "type": "call", "source": "ast"},
    ],
    "edges": [
        {"from": "ast_file:main_py", "to": "ast_func:hello", "label": "defines"},
        {"from": "ast_file:main_py", "to": "ast_class:greeter", "label": "defines"},
        {"from": "ast_file:main_py", "to": "ast_module:os", "label": "imports"},
        {"from": "ast_file:main_py", "to": "ast_call:print", "label": "calls"},
        {"from": "ast_func:hello", "to": "ast_call:print", "label": "calls"},
    ],
}

_SMALL_GRAPH = {
    "nodes": [
        {"id": "a", "label": "Alpha", "type": "topic"},
        {"id": "b", "label": "Beta", "type": "project"},
        {"id": "c", "label": "Gamma", "type": "decision"},
    ],
    "edges": [
        {"from": "a", "to": "b", "label": "project topic", "semantic_score": 0.9},
        {"from": "b", "to": "c", "label": "project decision", "semantic_score": 0.85},
    ],
}


# ── call_flow ──────────────────────────────────────────────────────────


class TestCallFlow(unittest.TestCase):
    def test_mermaid_contains_ast_nodes(self):
        result = kgraph.generate_call_flow_mermaid(_AST_GRAPH)
        self.assertIn("```mermaid", result)
        self.assertIn("hello", result)
        self.assertIn("Greeter", result)

    def test_mermaid_no_ast_data(self):
        result = kgraph.generate_call_flow_mermaid({"nodes": [], "edges": []})
        self.assertIn("NoAST", result)

    def test_mermaid_edge_styles(self):
        result = kgraph.generate_call_flow_mermaid(_AST_GRAPH)
        self.assertIn("calls", result)
        self.assertIn("defines", result)
        self.assertIn("imports", result)

    def test_html_contains_mermaid_script(self):
        html = kgraph.generate_call_flow_html(_AST_GRAPH)
        self.assertIn("mermaid", html)
        self.assertIn("<!doctype html>", html)
        self.assertIn("AST Nodes", html)

    def test_html_node_table(self):
        html = kgraph.generate_call_flow_html(_AST_GRAPH)
        self.assertIn("hello", html)
        self.assertIn("python", html)

    def test_html_escapes_injected_node_label(self):
        graph = {
            "nodes": [{
                "id": "ast_func:x",
                "label": "</script><script>alert(1)</script>",
                "type": "function",
                "source": "ast",
            }],
            "edges": [],
        }
        html = kgraph.generate_call_flow_html(graph)
        self.assertNotIn("<script>alert(1)</script>", html)
        self.assertIn("&lt;/script&gt;", html)


# ── update ─────────────────────────────────────────────────────────────


class TestUpdate(unittest.TestCase):
    def test_merge_graphs_deduplicates(self):
        base = {"nodes": [{"id": "a", "label": "A"}], "edges": []}
        overlay = {
            "nodes": [{"id": "a", "label": "A"}, {"id": "b", "label": "B"}],
            "edges": [{"from": "a", "to": "b", "label": "links"}],
        }
        merged = kgraph.merge_graphs(base, overlay)
        node_ids = {n.id for n in merged.nodes}
        self.assertEqual(node_ids, {"a", "b"})
        self.assertEqual(len(merged.edges), 1)

    def test_merge_graphs_empty_overlay(self):
        base = {"nodes": [{"id": "a", "label": "A"}], "edges": []}
        merged = kgraph.merge_graphs(base, {"nodes": [], "edges": []})
        self.assertEqual(len(merged.nodes), 1)

    def test_merge_graphs_empty_base(self):
        overlay = {"nodes": [{"id": "x", "label": "X"}], "edges": []}
        merged = kgraph.merge_graphs({"nodes": [], "edges": []}, overlay)
        self.assertEqual(len(merged.nodes), 1)

    def test_incremental_update_round_trip(self):
        with tempfile.TemporaryDirectory() as td:
            db_path = os.path.join(td, "graph.sqlite")
            # Seed with initial data
            kgraph.save_to_graph_db(db_path, _SMALL_GRAPH)
            # Run incremental update (no memory DB, no AST)
            result = kgraph.incremental_update(db_path, ast=False)
            self.assertGreater(len(result.nodes), 0)


# ── life_index ─────────────────────────────────────────────────────────


class TestLifeIndex(unittest.TestCase):
    def test_resolve_life_root_default(self):
        root = kgraph.resolve_life_root()
        self.assertTrue(root.endswith("life"))

    def test_resolve_life_root_custom(self):
        root = kgraph.resolve_life_root("/tmp/custom-life")
        self.assertEqual(root, "/tmp/custom-life")

    def test_load_life_index_missing_dir(self):
        index = kgraph.load_life_index("/tmp/nonexistent-life-dir")
        self.assertEqual(index["records"], [])
        self.assertEqual(index["aliases"], {})

    def test_load_life_index_canonical_from_custom_root(self):
        # canonical-concepts.json is resolved from the passed root, not the
        # default ~/.openclaw/life — a custom root must not leak the host's
        # canonical concepts into the index.
        with tempfile.TemporaryDirectory() as td:
            with open(os.path.join(td, "canonical-concepts.json"), "w") as f:
                json.dump({"records": [{"slug": "alpha", "title": "Alpha", "type": "project"}]}, f)
            index = kgraph.load_life_index(td)
            self.assertEqual([r["slug"] for r in index["records"]], ["alpha"])

    def test_load_relations_missing_file(self):
        rels = kgraph.load_relations("/tmp/nonexistent-life-dir")
        self.assertEqual(rels["relations"], [])

    def test_merge_relations_no_relations(self):
        graph = kgraph.merge_relations(_SMALL_GRAPH, life_root="/tmp/nonexistent")
        # Should return unchanged (as Graph model)
        self.assertEqual(len(graph.edges), 2)

    def test_merge_relations_marks_origin_life_index(self):
        with tempfile.TemporaryDirectory() as td:
            with open(os.path.join(td, "relations.json"), "w") as f:
                json.dump({"relations": [{"source": "alpha", "target": "beta", "rel": "related"}]}, f)
            graph = kgraph.merge_relations(
                {"nodes": [{"id": "n1", "label": "Alpha", "slug": "alpha"},
                           {"id": "n2", "label": "Beta", "slug": "beta"}],
                 "edges": []},
                life_root=td,
            )
        self.assertEqual(len(graph.edges), 1)
        # origin is a provenance tag, never the source slug.
        self.assertEqual(graph.edges[0].origin, "life_index")
        self.assertTrue(graph.edges[0].explicit)


# ── benchmark ──────────────────────────────────────────────────────────


class TestBenchmark(unittest.TestCase):
    def test_benchmark_returns_node_edge_and_token_counts(self):
        result = kgraph.benchmark_graph_vs_raw(_SMALL_GRAPH)
        self.assertEqual(result["node_count"], 3)
        self.assertEqual(result["edge_count"], 2)
        self.assertGreater(result["graph_tokens"], 0)
        self.assertGreater(result["compressed_graph_tokens"], 0)

    def test_benchmark_with_source_files(self):
        with tempfile.NamedTemporaryFile(mode="w", suffix=".txt", delete=False) as f:
            f.write("Hello world " * 100)
            f.flush()
            result = kgraph.benchmark_graph_vs_raw(_SMALL_GRAPH, source_files=[f.name])
        os.unlink(f.name)
        self.assertEqual(result["files_scanned"], 1)
        self.assertIsInstance(result["raw_file_tokens"], int)
        self.assertIn("savings_pct_vs_raw", result)

    def test_benchmark_output_file(self):
        with tempfile.TemporaryDirectory() as td:
            out = os.path.join(td, "bench.json")
            kgraph.benchmark_graph_vs_raw(_SMALL_GRAPH, output_path=out)
            self.assertTrue(os.path.exists(out))
            with open(out) as f:
                data = json.load(f)
            self.assertEqual(data["node_count"], 3)

    def test_print_benchmark_outputs_without_error(self):
        result = kgraph.benchmark_graph_vs_raw(_SMALL_GRAPH)
        # Should not raise
        kgraph.print_benchmark(result)


# ── mcp_server ─────────────────────────────────────────────────────────


class TestMCPServer(unittest.TestCase):
    def test_serve_mcp_is_callable(self):
        """serve_mcp is importable and callable."""
        self.assertTrue(callable(kgraph.serve_mcp))

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


# ── pr_dashboard ───────────────────────────────────────────────────────


class TestPRDashboard(unittest.TestCase):
    def test_generate_pr_dashboard_not_a_repo(self):
        with tempfile.TemporaryDirectory() as td:
            html = kgraph.generate_pr_dashboard(td)
            self.assertIn("Error", html)
            self.assertIn("Not a git repository", html)

    def test_generate_pr_dashboard_real_repo(self):
        html = kgraph.generate_pr_dashboard(REPO_ROOT, days=7)
        self.assertIn("PR Dashboard", html)
        self.assertIn("<!doctype html>", html)

    def test_generate_pr_dashboard_output_file(self):
        with tempfile.TemporaryDirectory() as td:
            out = os.path.join(td, "dashboard.html")
            kgraph.generate_pr_dashboard(REPO_ROOT, days=7, output_path=out)
            self.assertTrue(os.path.exists(out))


# ── validate (extended) ───────────────────────────────────────────────


class TestValidateExtended(unittest.TestCase):
    def test_validate_graph_valid_payload_returns_true(self):
        valid, reason = kgraph.validate_graph_payload(_SMALL_GRAPH)
        self.assertTrue(valid)
        self.assertEqual(reason, "")

    def test_validate_graph_payload_too_large(self):
        valid, msg = kgraph.validate_graph_payload(b"x" * (101 * 1024 * 1024))
        self.assertFalse(valid)
        self.assertIn("too large", msg.lower())


# ── server POST /graph.json ────────────────────────────────────────────


class _FakeHTTPServer:
    """Captures the handler class serve_file builds, without listening."""

    captured: dict = {}

    def __init__(self, addr, handler):
        _FakeHTTPServer.captured["handler"] = handler
        self.server_address = (addr[0], addr[1] or 1)

    def serve_forever(self):
        pass

    def shutdown(self):
        pass


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

    def test_get_read_path_still_served_with_cors(self):
        status, body, headers = self._request("GET", "/graph.json?view=raw")
        self.assertEqual(status, 200)
        self.assertEqual(headers.get("Access-Control-Allow-Origin"), "*")
        self.assertIn("nodes", json.loads(body))

    def test_get_redacts_memory_text(self):
        # A memory node's stored label IS a preview of its content
        # (memory_import sets label = _preview_text(content)), so the
        # wildcard-CORS read path must not serve it, nor the content fields.
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

    def test_write_response_omits_wildcard_cors(self):
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


# ── report HTML escaping ───────────────────────────────────────────────


class TestReportEscaping(unittest.TestCase):
    def test_generate_html_guards_against_script_breakout(self):
        graph = {
            "nodes": [{"id": "x", "label": "</script><script>alert(1)</script>"}],
            "edges": [],
        }
        with tempfile.TemporaryDirectory() as td:
            out = os.path.join(td, "graph.html")
            kgraph.generate_html(graph, out)
            with open(out, encoding="utf-8") as f:
                text = f.read()
        self.assertNotIn("</script><script>alert(1)", text)
        self.assertIn("\\u003c/script\\u003e", text)

    def test_pr_dashboard_escapes_git_metadata(self):
        from kgraph.pr_dashboard import _build_dashboard_html

        git_data = {
            "merges": [{
                "hash": "abc12345",
                "author_name": "<script>alert(1)</script>",
                "subject": "</td><script>alert(2)</script>",
                "date": "2026-09-11",
            }],
            "commits": [],
            "recent_files": [{"status": "M", "path": "<img src=x onerror=alert(3)>"}],
            "branches": [{"name": "<script>alert(5)</script>", "current": True}],
            "authors": {"<script>alert(6)</script>": "a@b.c"},
            "total_commits": 0,
            "total_merges": 1,
            "total_files_changed": 1,
            "total_branches": 1,
        }
        html = _build_dashboard_html(git_data, [], "/tmp/<script>repo", 30)
        for injected in (
            "<script>alert(1)</script>",
            "<script>alert(2)</script>",
            "<script>alert(5)</script>",
            "<script>alert(6)</script>",
            "<img src=x onerror=alert(3)>",
        ):
            self.assertNotIn(injected, html)
        self.assertIn("&lt;script&gt;alert(1)&lt;/script&gt;", html)


# ── cli --graph loading ────────────────────────────────────────────────


class TestCliGraphLoad(unittest.TestCase):
    def _load(self, graph_path):
        import argparse

        from kgraph.cli import _load_graph

        args = argparse.Namespace(
            graph=graph_path, graph_db=os.path.join(tempfile.gettempdir(), "kgraph-missing.sqlite"),
            import_db=None,
        )
        return _load_graph(args)

    def test_missing_graph_file_exits_with_message(self):
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            with self.assertRaises(SystemExit) as ctx:
                self._load("/nonexistent/definitely-not-here.json")
        self.assertEqual(ctx.exception.code, 1)
        self.assertIn("failed to load graph file", stderr.getvalue())

    def test_schema_invalid_graph_file_exits_with_message(self):
        # A provenance tag in `source` with no `from` has no real endpoint; the
        # CLI must report it cleanly rather than letting a pydantic traceback
        # escape from a renderer.
        with tempfile.TemporaryDirectory() as td:
            path = os.path.join(td, "bad-schema.json")
            with open(path, "w", encoding="utf-8") as f:
                json.dump({"nodes": [], "edges": [{"source": "ast", "target": "n2"}]}, f)
            stderr = io.StringIO()
            with contextlib.redirect_stderr(stderr):
                with self.assertRaises(SystemExit) as ctx:
                    self._load(path)
        self.assertEqual(ctx.exception.code, 1)
        self.assertIn("invalid graph", stderr.getvalue())

    def test_malformed_graph_file_exits_with_message(self):
        with tempfile.TemporaryDirectory() as td:
            path = os.path.join(td, "bad.json")
            with open(path, "w", encoding="utf-8") as f:
                f.write("{ not valid json")
            stderr = io.StringIO()
            with contextlib.redirect_stderr(stderr):
                with self.assertRaises(SystemExit) as ctx:
                    self._load(path)
        self.assertEqual(ctx.exception.code, 1)
        self.assertIn("bad.json", stderr.getvalue())


# ── memory_import connection lifecycle ─────────────────────────────────


class TestMemoryImportConnection(unittest.TestCase):
    def test_connection_closed_when_import_raises(self):
        from kgraph import memory_import

        fake_conn = mock.MagicMock()
        fake_sqlite = mock.MagicMock()
        fake_sqlite.connect.return_value = fake_conn
        with (
            mock.patch.object(memory_import, "sqlite3", fake_sqlite),
            mock.patch.object(
                memory_import, "_load_from_memory_db_conn",
                side_effect=RuntimeError("boom"),
            ),
        ):
            with self.assertRaises(RuntimeError):
                memory_import.load_from_memory_db("/tmp/whatever.db")
        fake_conn.close.assert_called_once()


if __name__ == "__main__":
    unittest.main()