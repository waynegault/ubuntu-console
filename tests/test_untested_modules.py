"""Tests for previously untested kgraph modules.

Covers: call_flow, update, life_index, benchmark, mcp_server, pr_dashboard,
and the server's POST /graph.json write path.
"""

import contextlib
import http.client
import io
import json
import os
import subprocess
import sys
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


# ── report generator ───────────────────────────────────────────────────


class TestReport(unittest.TestCase):
    def test_report_title_summary_and_sections(self):
        text = kgraph.generate_report(_SMALL_GRAPH)
        self.assertIn("# Knowledge Graph Report", text)
        self.assertIn("## Summary", text)
        self.assertIn("- **Nodes:** 3", text)
        self.assertIn("- **Edges:** 2", text)
        self.assertIn("## God Nodes (Most Central)", text)
        self.assertIn("## Edge Type Distribution", text)
        self.assertIn("## Node Type Distribution", text)

    def test_report_custom_title(self):
        text = kgraph.generate_report(_SMALL_GRAPH, title="My Graph")
        self.assertIn("# My Graph", text)

    def test_report_classifies_files_concepts_chunks_and_summaries(self):
        graph = {
            "nodes": [
                {"id": "f1", "label": "a.py", "type": "file"},
                {"id": "c1", "label": "Alpha", "type": "decision"},
                {"id": "ch1", "label": "chunk", "type": "chunk"},
                {"id": "s1", "label": "sum", "type": "summary"},
            ],
            "edges": [],
        }
        text = kgraph.generate_report(graph)
        self.assertIn("- **Files:** 1", text)
        # chunk/summary are neither files nor concepts
        self.assertIn("- **Concepts (non-file):** 1", text)

    def test_report_blank_edge_label_defaults_to_related(self):
        graph = {
            "nodes": [{"id": "a", "label": "A"}, {"id": "b", "label": "B"}],
            "edges": [{"from": "a", "to": "b", "label": "   "}],
        }
        text = kgraph.generate_report(graph)
        self.assertIn("- related: 1", text)

    def test_report_writes_outpath_and_returns_the_same_text(self):
        with tempfile.TemporaryDirectory() as td:
            out = os.path.join(td, "nested", "GRAPH_REPORT.md")
            stdout = io.StringIO()
            with contextlib.redirect_stdout(stdout):
                text = kgraph.generate_report(_SMALL_GRAPH, outpath=out)
            self.assertTrue(os.path.exists(out))
            with open(out, encoding="utf-8") as f:
                self.assertEqual(f.read(), text)
            self.assertIn("Wrote", stdout.getvalue())

    def test_report_truncates_edge_types_beyond_twenty(self):
        edges = [{"from": "n0", "to": "n1", "label": f"lbl{i}"} for i in range(25)]
        graph = {
            "nodes": [{"id": "n0", "label": "N0"}, {"id": "n1", "label": "N1"}],
            "edges": edges,
        }
        text = kgraph.generate_report(graph)
        self.assertIn("and 5 more edge types", text)

    def test_find_surprising_connections_without_centrality_is_empty(self):
        from kgraph import report

        graph = kgraph.Graph.from_dict(_SMALL_GRAPH)
        self.assertEqual(report._find_surprising_connections(graph, {}, []), [])

    def test_find_surprising_connections_bridging_branch(self):
        from kgraph import report

        graph = kgraph.Graph.from_dict(_SMALL_GRAPH)
        centralities = {
            "a": {"label": "Alpha", "betweenness": 0.2, "eigenvector": 0.01},
            "b": {"label": "Beta", "betweenness": 0.3, "eigenvector": 0.02},
            "c": {"label": "Gamma", "betweenness": 0.0, "eigenvector": 0.0},
        }
        found = report._find_surprising_connections(graph, centralities, [])
        self.assertTrue(found)
        self.assertIn("different communities", found[0]["reason"])

    def test_find_surprising_connections_god_node_branch(self):
        from kgraph import report

        graph = kgraph.Graph.from_dict(_SMALL_GRAPH)
        centralities = {
            "a": {"label": "Alpha", "betweenness": 0.0, "eigenvector": 0.5},
            "b": {"label": "Beta", "betweenness": 0.0, "eigenvector": 0.0},
        }
        found = report._find_surprising_connections(graph, centralities, [{"id": "a"}])
        self.assertTrue(found)
        self.assertIn("god node", found[0]["reason"])

    def test_report_renders_surprising_connections(self):
        # Hub-and-spoke: the hub ranks as a god node while most spokes do not,
        # so hub->spoke edges qualify as surprising and must be rendered.
        nodes = [{"id": "hub", "label": "Hub", "type": "topic"}]
        edges = []
        for i in range(20):
            nodes.append({"id": f"s{i}", "label": f"Spoke {i}", "type": "topic"})
            edges.append({"from": "hub", "to": f"s{i}", "label": "links"})
        text = kgraph.generate_report({"nodes": nodes, "edges": edges})
        self.assertIn("## Surprising / Unexpected Connections", text)
        self.assertIn("→", text)

    def test_report_includes_community_structure_when_detected(self):
        nodes = [{"id": f"n{i}", "label": f"N{i}", "type": "topic"} for i in range(6)]
        edges = [
            {"from": f"n{a}", "to": f"n{b}", "label": "links"}
            for a, b in ((0, 1), (1, 2), (0, 2), (3, 4), (4, 5), (3, 5), (2, 3))
        ]
        text = kgraph.generate_report({"nodes": nodes, "edges": edges})
        self.assertIn("## Community Structure", text)
        self.assertIn("members", text)

    def test_estimate_token_savings_empty_graph_is_empty(self):
        from kgraph import report

        graph = kgraph.Graph.from_dict({"nodes": [], "edges": []})
        self.assertEqual(report._estimate_token_savings(graph), {})

    def test_estimate_token_savings_arithmetic(self):
        from kgraph import report

        graph = kgraph.Graph.from_dict(_SMALL_GRAPH)
        est = report._estimate_token_savings(graph)
        self.assertEqual(est["raw_tokens"], len(graph.nodes) * 30 + len(graph.edges) * 20)
        expected_compressed = (
            len({n.type for n in graph.nodes}) * 50
            + len({n.label for n in graph.nodes}) * 5
            + len(graph.edges) * 8
            + len(graph.nodes) * 3
        )
        self.assertEqual(est["compressed_tokens"], expected_compressed)
        self.assertIsInstance(est["savings_pct"], float)


# ── update: incremental rebuild + watch ────────────────────────────────


class TestUpdateIncremental(unittest.TestCase):
    def _seed(self, td, graph=None):
        db = os.path.join(td, "graph.sqlite")
        kgraph.save_to_graph_db(db, graph if graph is not None else _SMALL_GRAPH)
        return db

    def test_merges_memory_dbs_surviving_a_failing_one(self):
        with tempfile.TemporaryDirectory() as td:
            db = self._seed(td)
            mem = os.path.join(td, "mem.sqlite")
            with open(mem, "w", encoding="utf-8") as f:
                f.write("")  # exists, so it is handed to load_from_memory_db
            with (
                mock.patch("kgraph.memory_import.load_from_memory_db",
                           side_effect=ValueError("bad db")),
                mock.patch("kgraph.update.logger") as log,
            ):
                result = kgraph.incremental_update(db, mem_db_path=mem, ast=False)
            log.warning.assert_called()
            self.assertGreater(len(result.nodes), 0)

    def test_merges_a_successful_memory_db(self):
        with tempfile.TemporaryDirectory() as td:
            db = self._seed(td, {"nodes": [], "edges": []})
            mem = os.path.join(td, "mem.sqlite")
            with open(mem, "w", encoding="utf-8") as f:
                f.write("")
            mem_graph = {"nodes": [{"id": "m1", "label": "From memory",
                                    "type": "memory"}], "edges": []}
            with mock.patch("kgraph.memory_import.load_from_memory_db",
                            return_value=mem_graph) as load_mem:
                result = kgraph.incremental_update(db, mem_db_path=mem, ast=False,
                                                   include_all=True)
            self.assertEqual(load_mem.call_args.kwargs.get("include_all"), True)
            self.assertIn("m1", {n.id for n in result.nodes})

    def test_expands_a_tilde_memory_db_path_before_the_exists_check(self):
        with tempfile.TemporaryDirectory() as td:
            db = self._seed(td)
            home = os.path.join(td, "home")
            os.makedirs(home)
            real = os.path.join(home, "mem.sqlite")
            with open(real, "w", encoding="utf-8") as f:
                f.write("")
            with (
                mock.patch.dict(os.environ, {"HOME": home}),
                mock.patch("kgraph.memory_import.load_from_memory_db",
                           return_value={"nodes": [], "edges": []}) as load_mem,
                mock.patch("kgraph.graph_db.resolve_all_memory_db_paths") as resolve,
            ):
                resolve.return_value = []
                kgraph.incremental_update(db, mem_db_path="~/mem.sqlite", ast=False)
            self.assertEqual(load_mem.call_args.args[0], real)

    def test_prunes_stale_ast_nodes_from_the_persisted_graph(self):
        with tempfile.TemporaryDirectory() as td:
            seeded = {
                "nodes": [
                    {"id": "a", "label": "Alpha", "type": "topic"},
                    {"id": "ast_func:gone", "label": "gone", "type": "function",
                     "source": "ast"},
                ],
                "edges": [{"from": "ast_func:gone", "to": "a", "label": "calls"}],
            }
            db = self._seed(td, seeded)
            with mock.patch("kgraph.graph_db.resolve_all_memory_db_paths", return_value=[]):
                result = kgraph.incremental_update(db, ast=False)
            self.assertIn("a", {n.id for n in result.nodes})
            self.assertNotIn("ast_func:gone", {n.id for n in result.nodes})

    def test_merges_ast_extraction_output(self):
        with tempfile.TemporaryDirectory() as td:
            db = self._seed(td, {"nodes": [], "edges": []})
            src = os.path.join(td, "src")
            os.makedirs(src)
            ast_graph = {
                "nodes": [{"id": "ast_func:x", "label": "x", "type": "function",
                           "source": "ast"}],
                "edges": [],
            }
            with (
                mock.patch("kgraph.graph_db.resolve_all_memory_db_paths", return_value=[]),
                mock.patch("kgraph.ast_extractor.ast_available", return_value=True),
                mock.patch("kgraph.ast_extractor.extract_repo_graph",
                           return_value=ast_graph) as extract,
            ):
                result = kgraph.incremental_update(db, source_dir=src, ast=True)
            extract.assert_called_once()
            self.assertIn("ast_func:x", {n.id for n in result.nodes})

    def test_survives_an_ast_extraction_failure(self):
        with tempfile.TemporaryDirectory() as td:
            db = self._seed(td, {"nodes": [], "edges": []})
            src = os.path.join(td, "src")
            os.makedirs(src)
            with (
                mock.patch("kgraph.graph_db.resolve_all_memory_db_paths", return_value=[]),
                mock.patch("kgraph.ast_extractor.ast_available", return_value=True),
                mock.patch("kgraph.ast_extractor.extract_repo_graph",
                           side_effect=ValueError("no parser")),
                mock.patch("kgraph.update.logger") as log,
            ):
                result = kgraph.incremental_update(db, source_dir=src, ast=True)
            log.warning.assert_called()
            self.assertEqual(len(result.nodes), 0)


class _StubTime:
    """Module-local stand-in for update.py's `time` (see the test below)."""

    def __init__(self, on_first_tick, on_second_tick):
        self.ticks = 0
        self._first = on_first_tick
        self._second = on_second_tick

    def sleep(self, _interval):
        self.ticks += 1
        if self.ticks == 1:
            self._first()
            return
        raise KeyboardInterrupt

    def strftime(self, _fmt):
        self._second()


class TestStartWatch(unittest.TestCase):
    def test_rebuilds_when_the_source_changes(self):
        from kgraph import update

        with tempfile.TemporaryDirectory() as td:
            db = os.path.join(td, "graph.sqlite")
            src = os.path.join(td, "src")
            os.makedirs(src)
            note = os.path.join(src, "a.py")
            with open(note, "w", encoding="utf-8") as f:
                f.write("x = 1\n")
            kgraph.save_to_graph_db(db, _SMALL_GRAPH)

            def touch_note():
                with open(note, "w", encoding="utf-8") as f:
                    f.write("x = 2\n")

            # Patch update.py's module-local `time` rather than the global time
            # module: only this module's use of sleep/strftime is replaced.
            stub = _StubTime(touch_note, lambda: None)
            stdout = io.StringIO()
            with (
                mock.patch.object(update, "time", stub),
                mock.patch.object(update, "incremental_update") as upd,
                mock.patch("kgraph.graph_db.resolve_all_memory_db_paths", return_value=[]),
            ):
                with contextlib.redirect_stdout(stdout):
                    with self.assertRaises(KeyboardInterrupt):
                        kgraph.start_watch(db, source_dir=src, interval=1)

            upd.assert_called_once()
            out = stdout.getvalue()
            self.assertIn("Watching", out)
            self.assertIn("Watch mode active", out)
            self.assertIn("File changes detected, rebuilding", out)
            self.assertIn("Rebuilt: 3 nodes, 2 edges", out)

    def test_no_rebuild_when_nothing_changes(self):
        from kgraph import update

        with tempfile.TemporaryDirectory() as td:
            db = os.path.join(td, "graph.sqlite")
            src = os.path.join(td, "src")
            os.makedirs(src)
            with open(os.path.join(src, "a.py"), "w", encoding="utf-8") as f:
                f.write("x = 1\n")
            kgraph.save_to_graph_db(db, _SMALL_GRAPH)

            stub = _StubTime(lambda: None, lambda: None)
            stdout = io.StringIO()
            with (
                mock.patch.object(update, "time", stub),
                mock.patch.object(update, "incremental_update") as upd,
                mock.patch("kgraph.graph_db.resolve_all_memory_db_paths", return_value=[]),
            ):
                with contextlib.redirect_stdout(stdout):
                    with self.assertRaises(KeyboardInterrupt):
                        kgraph.start_watch(db, source_dir=src, interval=1)

            upd.assert_not_called()
            self.assertNotIn("File changes detected", stdout.getvalue())

    def test_watch_skips_ignored_dirs_and_logs_unreadable_files(self):
        from kgraph import update

        with tempfile.TemporaryDirectory() as td:
            db = os.path.join(td, "graph.sqlite")
            src = os.path.join(td, "src")
            os.makedirs(os.path.join(src, ".hidden"))
            os.makedirs(os.path.join(src, "venv"))
            for rel in (".hidden/skip.py", "venv/skip.py", "keep.py"):
                with open(os.path.join(src, rel), "w", encoding="utf-8") as f:
                    f.write("x = 1\n")
            unreadable = os.path.join(src, "unreadable.py")
            with open(unreadable, "w", encoding="utf-8") as f:
                f.write("x = 1\n")
            # No permission restore is needed: TemporaryDirectory removes the
            # dir (unlink needs only the parent's write bit), and a teardown-time
            # chmod would run after the dir is gone.
            os.chmod(unreadable, 0)
            kgraph.save_to_graph_db(db, _SMALL_GRAPH)

            stub = _StubTime(lambda: None, lambda: None)
            stdout = io.StringIO()
            with (
                mock.patch.object(update, "time", stub),
                mock.patch.object(update, "incremental_update") as upd,
                mock.patch.object(update, "logger") as log,
                mock.patch("kgraph.graph_db.resolve_all_memory_db_paths", return_value=[]),
            ):
                with contextlib.redirect_stdout(stdout):
                    with self.assertRaises(KeyboardInterrupt):
                        kgraph.start_watch(db, source_dir=src, interval=1)

            upd.assert_not_called()
            # .hidden/ and venv/ are skipped; the unreadable file is only counted
            # when this user can actually read it (not the case as non-root).
            readable = 1 + (1 if os.access(unreadable, os.R_OK) else 0)
            self.assertIn(f"({readable} files, interval=1s)", stdout.getvalue())
            if not os.access(unreadable, os.R_OK):
                log.debug.assert_called()

    def test_rebuilds_when_a_watched_memory_db_changes(self):
        from kgraph import update

        with tempfile.TemporaryDirectory() as td:
            db = os.path.join(td, "graph.sqlite")
            mem = os.path.join(td, "mem.sqlite")
            with open(mem, "w", encoding="utf-8") as f:
                f.write("")
            kgraph.save_to_graph_db(db, _SMALL_GRAPH)
            stamp = os.path.getmtime(mem)

            def bump_mtime():
                os.utime(mem, (stamp + 10, stamp + 10))

            stub = _StubTime(bump_mtime, lambda: None)
            stdout = io.StringIO()
            with (
                mock.patch.object(update, "time", stub),
                mock.patch.object(update, "incremental_update") as upd,
            ):
                with contextlib.redirect_stdout(stdout):
                    with self.assertRaises(KeyboardInterrupt):
                        kgraph.start_watch(db, mem_db_path=mem, interval=1)

            upd.assert_called_once()
            self.assertIn("File changes detected, rebuilding", stdout.getvalue())

    def test_logs_and_continues_when_a_rebuild_fails(self):
        from kgraph import update

        with tempfile.TemporaryDirectory() as td:
            db = os.path.join(td, "graph.sqlite")
            src = os.path.join(td, "src")
            os.makedirs(src)
            note = os.path.join(src, "a.py")
            with open(note, "w", encoding="utf-8") as f:
                f.write("x = 1\n")
            kgraph.save_to_graph_db(db, _SMALL_GRAPH)

            def touch_note():
                with open(note, "w", encoding="utf-8") as f:
                    f.write("x = 2\n")

            stub = _StubTime(touch_note, lambda: None)
            with (
                mock.patch.object(update, "time", stub),
                mock.patch.object(update, "incremental_update",
                                  side_effect=ValueError("boom")),
                mock.patch.object(update, "logger") as log,
                mock.patch("kgraph.graph_db.resolve_all_memory_db_paths", return_value=[]),
            ):
                with contextlib.redirect_stdout(io.StringIO()):
                    with self.assertRaises(KeyboardInterrupt):
                        kgraph.start_watch(db, source_dir=src, interval=1)

            log.warning.assert_called()


# ── life_index: directory scan and relations ───────────────────────────


class TestLifeIndexScan(unittest.TestCase):
    @staticmethod
    def _write(path, text):
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as f:
            f.write(text)

    def test_dir_scan_parses_title_type_status_and_aliases(self):
        with tempfile.TemporaryDirectory() as td:
            self._write(
                os.path.join(td, "projects", "alpha.md"),
                "# Alpha Project\n- type: project\n- status: active\n"
                "- aliases:\n  - Alpha Proj\n  - ALPHA\n"
                "\nBody prose ends the alias block.\n",
            )
            index = kgraph.load_life_index(td)
            self.assertEqual([r["slug"] for r in index["records"]], ["alpha"])
            rec = index["by_slug"]["alpha"]
            self.assertEqual(rec["title"], "Alpha Project")
            self.assertEqual(rec["type"], "project")
            self.assertEqual(rec["status"], "active")
            self.assertEqual(rec["aliases"], ["Alpha Proj", "ALPHA"])
            self.assertIn("alpha proj", index["aliases"])
            self.assertEqual(index["title_aliases"]["alpha proj"], "Alpha Project")
            self.assertEqual(index["by_type"]["project"], [rec])

    def test_dir_scan_default_type_maps_people_to_person(self):
        # `people` is irregular: a blind `type_dir[:-1]` would yield "peopl",
        # while the rest of the codebase spells the type "person".
        with tempfile.TemporaryDirectory() as td:
            self._write(os.path.join(td, "people", "wayne.md"), "# Wayne\n")
            index = kgraph.load_life_index(td)
            self.assertEqual(index["by_slug"]["wayne"]["type"], "person")

    def test_singular_type_handles_irregular_and_regular_names(self):
        from kgraph import life_index

        self.assertEqual(life_index._singular_type("people"), "person")
        self.assertEqual(life_index._singular_type("projects"), "project")
        # A directory not in the map still singularises a regular plural.
        self.assertEqual(life_index._singular_type("notes"), "note")
        self.assertEqual(life_index._singular_type("misc"), "misc")

    def test_dir_scan_title_falls_back_to_the_slug(self):
        with tempfile.TemporaryDirectory() as td:
            self._write(os.path.join(td, "systems", "nas.md"), "- type: system\n")
            index = kgraph.load_life_index(td)
            self.assertEqual(index["by_slug"]["nas"]["title"], "nas")

    def test_dir_scan_ignores_non_markdown_and_unlisted_dirs(self):
        with tempfile.TemporaryDirectory() as td:
            self._write(os.path.join(td, "projects", "notes.txt"), "ignored")
            self._write(os.path.join(td, "notatype", "x.md"), "# X\n")
            self.assertEqual(kgraph.load_life_index(td)["records"], [])

    def test_unreadable_index_file_is_logged_and_skipped(self):
        with tempfile.TemporaryDirectory() as td:
            path = os.path.join(td, "projects", "broken.md")
            self._write(path, "# Broken\n")
            os.chmod(path, 0)
            if os.access(path, os.R_OK):  # e.g. running as root
                self.skipTest("chmod 0 is still readable for this user")
            with mock.patch("kgraph.life_index.logger") as log:
                index = kgraph.load_life_index(td)
            log.warning.assert_called()
            self.assertEqual(index["records"], [])

    def test_malformed_canonical_json_falls_back_to_the_dir_scan(self):
        with tempfile.TemporaryDirectory() as td:
            self._write(os.path.join(td, "canonical-concepts.json"), "{ not json")
            self._write(os.path.join(td, "projects", "alpha.md"),
                        "# Alpha\n- type: project\n")
            with mock.patch("kgraph.life_index.logger") as log:
                index = kgraph.load_life_index(td)
            log.warning.assert_called()
            self.assertEqual([r["slug"] for r in index["records"]], ["alpha"])

    def test_canonical_record_without_a_slug_is_skipped(self):
        with tempfile.TemporaryDirectory() as td:
            self._write(
                os.path.join(td, "canonical-concepts.json"),
                json.dumps({"records": [{"title": "no slug"},
                                        {"slug": "beta", "title": "Beta",
                                         "type": "project"}]}),
            )
            index = kgraph.load_life_index(td)
            self.assertEqual([r["slug"] for r in index["records"]], ["beta"])

    def test_slugless_canonical_records_fall_through_to_the_scan(self):
        with tempfile.TemporaryDirectory() as td:
            self._write(os.path.join(td, "canonical-concepts.json"),
                        json.dumps({"records": [{"title": "no slug"}]}))
            self._write(os.path.join(td, "repos", "kgraph.md"),
                        "# kgraph\n- type: repo\n")
            index = kgraph.load_life_index(td)
            self.assertEqual([r["slug"] for r in index["records"]], ["kgraph"])


class TestLifeRelations(unittest.TestCase):
    @staticmethod
    def _write(path, text):
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as f:
            f.write(text)

    def test_malformed_relations_json_is_logged(self):
        with tempfile.TemporaryDirectory() as td:
            self._write(os.path.join(td, "relations.json"), "{ nope")
            with mock.patch("kgraph.life_index.logger") as log:
                rels = kgraph.load_relations(td)
            log.warning.assert_called()
            self.assertEqual(rels, {"relations": []})

    def test_merge_relations_skips_incomplete_and_unknown_slugs(self):
        with tempfile.TemporaryDirectory() as td:
            self._write(os.path.join(td, "relations.json"), json.dumps({"relations": [
                {"source": "alpha"},                     # no target
                {"target": "beta"},                      # no source
                {"source": "ghost", "target": "beta"},   # unknown source
                {"source": "alpha", "target": "ghost"},  # unknown target
            ]}))
            graph = kgraph.merge_relations(
                {"nodes": [{"id": "n1", "label": "Alpha", "slug": "alpha"},
                           {"id": "n2", "label": "Beta", "slug": "beta"}],
                 "edges": []},
                life_root=td,
            )
        self.assertEqual(graph.edges, [])

    def test_merge_relations_matches_a_canonical_slug(self):
        with tempfile.TemporaryDirectory() as td:
            self._write(os.path.join(td, "relations.json"), json.dumps({"relations": [
                {"source": "alpha", "target": "beta", "rel": "supersedes"},
            ]}))
            graph = kgraph.merge_relations(
                {"nodes": [{"id": "n1", "label": "Alpha", "canonical_slug": "alpha"},
                           {"id": "n2", "label": "Beta", "slug": "beta"}],
                 "edges": []},
                life_root=td,
            )
        self.assertEqual(len(graph.edges), 1)
        self.assertEqual(graph.edges[0].label, "supersedes")
        self.assertEqual(graph.edges[0].origin, "life_index")
        self.assertTrue(graph.edges[0].explicit)

    def test_merge_relations_does_not_duplicate_an_existing_edge(self):
        with tempfile.TemporaryDirectory() as td:
            self._write(os.path.join(td, "relations.json"), json.dumps({"relations": [
                {"source": "alpha", "target": "beta", "rel": "related"},
            ]}))
            graph = kgraph.merge_relations(
                {"nodes": [{"id": "n1", "label": "Alpha", "slug": "alpha"},
                           {"id": "n2", "label": "Beta", "slug": "beta"}],
                 "edges": [{"from": "n1", "to": "n2", "label": "related"}]},
                life_root=td,
            )
        self.assertEqual(len(graph.edges), 1)


# ── validate: limits, XSS scan, file/payload loading, CLI ──────────────


class TestValidateLimits(unittest.TestCase):
    def setUp(self):
        from kgraph import validate

        self.validate = validate

    def test_non_dict_root_is_reported(self):
        errors = self.validate.validate_graph(["not", "a", "dict"])
        self.assertEqual(len(errors), 1)
        self.assertIn("must be a dict", errors[0]["message"])

    def test_excessive_nesting_is_reported(self):
        root: dict = {}
        cursor = root
        # Deeper than the scanner's own short-circuit so both the guard and the
        # depth comparison are exercised.
        for _ in range(self.validate.MAX_JSON_DEPTH + 10):
            cursor["nested"] = {}
            cursor = cursor["nested"]
        errors = self.validate.validate_graph(root)
        self.assertTrue(any("Excessive nesting" in e["message"] for e in errors))

    def test_non_list_nodes_and_edges_are_reported(self):
        errors = self.validate.validate_graph({"nodes": "x", "edges": "y"})
        messages = " ".join(e["message"] for e in errors)
        self.assertIn("'nodes' must be a list", messages)
        self.assertIn("'edges' must be a list", messages)

    def test_node_and_edge_count_limits_are_enforced(self):
        with (
            mock.patch.object(self.validate, "MAX_NODES", 1),
            mock.patch.object(self.validate, "MAX_EDGES", 1),
        ):
            errors = self.validate.validate_graph({
                "nodes": [{"id": "a", "label": "A"}, {"id": "b", "label": "B"}],
                "edges": [{"from": "a", "to": "b"}, {"from": "b", "to": "a"}],
            })
        messages = " ".join(e["message"] for e in errors)
        self.assertIn("Too many nodes", messages)
        self.assertIn("Too many edges", messages)

    def test_schema_violations_are_reported(self):
        errors = self.validate.validate_graph(
            {"nodes": [{"label": "no id"}], "edges": []})
        self.assertTrue(any(e["message"].startswith("Schema:") for e in errors))


class TestValidateXss(unittest.TestCase):
    def setUp(self):
        from kgraph import validate

        self.validate = validate

    def test_detects_a_dangerous_pattern_at_top_level(self):
        errors = self.validate.validate_graph({
            "nodes": [{"id": "x", "label": "<script>alert(1)</script>"}],
            "edges": [],
        })
        self.assertTrue(any("dangerous patterns" in e["message"] for e in errors))

    def test_detects_a_dangerous_pattern_nested_in_a_container(self):
        errors = self.validate.validate_graph({
            "nodes": [{"id": "x", "label": "ok",
                       "payload": {"deep": ["fine", "javascript:alert(1)"]}}],
            "edges": [],
        })
        self.assertTrue(any("payload" in e["message"] for e in errors))

    def test_skips_non_list_and_non_dict_items(self):
        # A non-list nodes/edges value is already reported by validate_graph;
        # the scan must not raise TypeError out of the caller.
        self.assertEqual(self.validate._check_xss({"nodes": "nope", "edges": [1, 2, "x"]}), [])

    def test_scan_dangerous_ignores_non_strings(self):
        self.assertFalse(self.validate._scan_dangerous({"n": 1, "l": [None, True, 3.5]}))
        self.assertTrue(self.validate._scan_dangerous({"n": ["<script >"]}))


class TestValidateFileAndPayload(unittest.TestCase):
    def setUp(self):
        from kgraph import validate

        self.validate = validate

    def test_missing_file_is_reported(self):
        errors = self.validate.validate_graph_file("/nonexistent/graph.json")
        self.assertEqual(len(errors), 1)
        self.assertIn("File not found", errors[0]["message"])

    def test_a_directory_is_reported_as_missing(self):
        with tempfile.TemporaryDirectory() as td:
            errors = self.validate.validate_graph_file(td)
        self.assertIn("File not found", errors[0]["message"])

    def test_malformed_json_reports_line_and_column(self):
        with tempfile.TemporaryDirectory() as td:
            path = os.path.join(td, "bad.json")
            with open(path, "w", encoding="utf-8") as f:
                f.write("{ not json")
            errors = self.validate.validate_graph_file(path)
        self.assertEqual(len(errors), 1)
        self.assertIn("JSON parse error", errors[0]["message"])
        self.assertIn("line", errors[0]["message"])

    def test_valid_file_is_clean_and_errors_carry_the_filename(self):
        with tempfile.TemporaryDirectory() as td:
            ok = os.path.join(td, "ok.json")
            with open(ok, "w", encoding="utf-8") as f:
                json.dump({"nodes": [{"id": "a", "label": "A"}], "edges": []}, f)
            self.assertEqual(self.validate.validate_graph_file(ok), [])

            bad = os.path.join(td, "bad.json")
            with open(bad, "w", encoding="utf-8") as f:
                json.dump({"nodes": [{"label": "no id"}], "edges": []}, f)
            errors = self.validate.validate_graph_file(bad)
        self.assertTrue(errors)
        self.assertTrue(all(e.get("file") == bad for e in errors))

    def test_an_unreadable_file_is_reported_as_an_error(self):
        with tempfile.TemporaryDirectory() as td:
            path = os.path.join(td, "locked.json")
            with open(path, "w", encoding="utf-8") as f:
                f.write("{}")
            os.chmod(path, 0)
            if os.access(path, os.R_OK):  # e.g. running as root
                self.skipTest("chmod 0 is still readable for this user")
            errors = self.validate.validate_graph_file(path)
        self.assertEqual(len(errors), 1)
        self.assertIn("Error reading", errors[0]["message"])

    def test_payload_accepts_dicts_and_json_strings(self):
        ok, reason = self.validate.validate_graph_payload({"nodes": [], "edges": []})
        self.assertTrue(ok)
        self.assertEqual(reason, "")
        ok, _ = self.validate.validate_graph_payload('{"nodes": [], "edges": []}')
        self.assertTrue(ok)

    def test_payload_rejects_oversized_bytes_and_strings(self):
        with mock.patch.object(self.validate, "MAX_PAYLOAD_SIZE", 10):
            ok, reason = self.validate.validate_graph_payload(b"x" * 11)
            self.assertFalse(ok)
            self.assertIn("too large", reason)
            ok, reason = self.validate.validate_graph_payload("x" * 11)
            self.assertFalse(ok)
            self.assertIn("too large", reason)

    def test_payload_rejects_invalid_json_and_unsupported_types(self):
        ok, reason = self.validate.validate_graph_payload(b"{ nope")
        self.assertFalse(ok)
        self.assertIn("Invalid JSON", reason)
        ok, reason = self.validate.validate_graph_payload(42)
        self.assertFalse(ok)
        self.assertIn("JSON string or dict", reason)

    def test_payload_surfaces_the_first_error_message(self):
        ok, reason = self.validate.validate_graph_payload({
            "nodes": [{"id": "x", "label": "<script>alert(1)</script>"}],
            "edges": [],
        })
        self.assertFalse(ok)
        self.assertIn("dangerous patterns", reason)


class TestValidateCli(unittest.TestCase):
    def _run(self, *args):
        env = dict(os.environ, PYTHONPATH=os.path.join(REPO_ROOT, "scripts"))
        return subprocess.run(
            [sys.executable, "-m", "kgraph.validate", *args],
            capture_output=True, text=True, env=env, cwd=REPO_ROOT,
        )

    def test_usage_without_arguments(self):
        proc = self._run()
        self.assertEqual(proc.returncode, 1)
        self.assertIn("Usage:", proc.stdout)

    def test_valid_file_passes(self):
        with tempfile.TemporaryDirectory() as td:
            path = os.path.join(td, "ok.json")
            with open(path, "w", encoding="utf-8") as f:
                json.dump({"nodes": [{"id": "a", "label": "A"}], "edges": []}, f)
            proc = self._run(path)
        self.assertEqual(proc.returncode, 0)
        self.assertIn("validation PASSED", proc.stdout)

    def test_invalid_file_exits_nonzero_with_issues(self):
        with tempfile.TemporaryDirectory() as td:
            path = os.path.join(td, "bad.json")
            with open(path, "w", encoding="utf-8") as f:
                json.dump({"nodes": [{"label": "no id"}], "edges": []}, f)
            proc = self._run(path)
        self.assertEqual(proc.returncode, 1)
        self.assertIn("issue(s)", proc.stdout)


# ── pr_dashboard: git gathering, correlation, HTML ─────────────────────


class _FailingSubprocess:
    """Module-local stand-in for pr_dashboard.subprocess whose run() always fails.

    Replacing pr_dashboard's own `subprocess` NAME keeps the real subprocess
    module (and everything else in the process) untouched.
    """

    class SubprocessError(Exception):
        pass

    @staticmethod
    def run(*_args, **_kwargs):
        raise OSError("git unavailable")


class TestPRDashboardGitData(unittest.TestCase):
    @staticmethod
    def _git_env(td):
        # Isolate from the user's global/system git config.
        return dict(
            os.environ,
            HOME=td,
            GIT_CONFIG_NOSYSTEM="1",
            GIT_AUTHOR_NAME="Dash Tester",
            GIT_AUTHOR_EMAIL="dash@example.test",
            GIT_COMMITTER_NAME="Dash Tester",
            GIT_COMMITTER_EMAIL="dash@example.test",
        )

    @classmethod
    def _make_repo(cls, td):
        env = cls._git_env(td)

        def git(*args):
            subprocess.run(["git", *args], cwd=td, env=env, check=True,
                           capture_output=True, text=True)

        git("init", "-q")
        with open(os.path.join(td, "a.txt"), "w", encoding="utf-8") as f:
            f.write("one\n")
        git("add", "-A")
        git("commit", "-q", "-m", "initial commit")
        base = subprocess.run(
            ["git", "rev-parse", "--abbrev-ref", "HEAD"],
            cwd=td, env=env, capture_output=True, text=True, check=True,
        ).stdout.strip()
        git("checkout", "-q", "-b", "feature")
        with open(os.path.join(td, "b.txt"), "w", encoding="utf-8") as f:
            f.write("two\n")
        git("add", "-A")
        git("commit", "-q", "-m", "feature commit")
        git("checkout", "-q", base)
        git("merge", "--no-ff", "-q", "-m", "merge feature", "feature")
        return base

    def test_gathers_commits_files_branches_and_authors(self):
        from kgraph import pr_dashboard

        with tempfile.TemporaryDirectory() as td:
            self._make_repo(td)
            data = pr_dashboard._gather_git_data(td, 30, None, 30)

        self.assertGreaterEqual(data["total_commits"], 2)
        self.assertGreaterEqual(data["total_merges"], 1)
        paths = {f["path"] for f in data["recent_files"]}
        self.assertIn("a.txt", paths)
        self.assertIn("b.txt", paths)
        self.assertTrue(any(b["current"] for b in data["branches"]))
        self.assertIn("Dash Tester", data["authors"])
        self.assertEqual(data["total_files_changed"], len(data["recent_files"]))

    def test_author_filter_is_applied(self):
        from kgraph import pr_dashboard

        with tempfile.TemporaryDirectory() as td:
            self._make_repo(td)
            data = pr_dashboard._gather_git_data(td, 30, "Nobody At All", 30)
        self.assertEqual(data["total_commits"], 0)

    def test_git_failures_are_logged_and_reported_as_an_error_entry(self):
        from kgraph import pr_dashboard

        with tempfile.TemporaryDirectory() as td:
            os.makedirs(os.path.join(td, ".git"))
            with (
                mock.patch.object(pr_dashboard, "subprocess", _FailingSubprocess()),
                mock.patch.object(pr_dashboard, "logger") as log,
            ):
                data = pr_dashboard._gather_git_data(td, 30, None, 30)

        self.assertEqual(data["merges"], [{"error": "git unavailable"}])
        for key in ("commits", "recent_files", "branches"):
            self.assertEqual(data[key], [])
        self.assertEqual(data["authors"], {})
        self.assertGreaterEqual(log.warning.call_count, 3)

    def test_generate_pr_dashboard_on_a_non_repo_reports_an_error(self):
        with tempfile.TemporaryDirectory() as td:
            html = kgraph.generate_pr_dashboard(td)
        self.assertIn("Not a git repository", html)
        self.assertIn("Error", html)

    def test_generate_pr_dashboard_writes_the_output_file(self):
        with tempfile.TemporaryDirectory() as td:
            self._make_repo(td)
            out = os.path.join(td, "nested", "dashboard.html")
            stdout = io.StringIO()
            with contextlib.redirect_stdout(stdout):
                html = kgraph.generate_pr_dashboard(td, days=7, output_path=out)
            self.assertTrue(os.path.exists(out))
            with open(out, encoding="utf-8") as f:
                self.assertEqual(f.read(), html)
        self.assertIn("PR dashboard written to", stdout.getvalue())
        self.assertIn("Merges", html)
        self.assertIn("PR Dashboard", html)


class TestPRDashboardCorrelation(unittest.TestCase):
    @staticmethod
    def _git_data(paths):
        return {"recent_files": [{"status": "M", "path": p} for p in paths]}

    def test_matches_in_both_directions_and_skips_nodes_without_a_path(self):
        from kgraph import pr_dashboard

        git_data = self._git_data(["scripts/kgraph/server.py"])
        graph = {"nodes": [
            {"id": "n1", "label": "server", "type": "file", "path": "server.py"},
            {"id": "n2", "label": "pkg", "type": "file",
             "path": "scripts/kgraph/server.py"},
            {"id": "n3", "label": "no path", "type": "topic"},
        ]}
        found = pr_dashboard._correlate_with_graph(git_data, graph)
        self.assertEqual({c["node_id"] for c in found}, {"n1", "n2"})
        self.assertEqual(found[0]["node_type"], "file")

    def test_deduplicates_and_caps_the_result(self):
        from kgraph import pr_dashboard

        one = {"nodes": [{"id": "n1", "label": "N", "path": "f.py"}] * 3}
        self.assertEqual(
            len(pr_dashboard._correlate_with_graph(self._git_data(["f.py"]), one)), 1)

        many = {"nodes": [{"id": f"n{i}", "label": "N", "path": f"p{i}.py"}
                          for i in range(60)]}
        git_many = self._git_data([f"p{i}.py" for i in range(60)])
        self.assertEqual(
            len(pr_dashboard._correlate_with_graph(git_many, many)), 50)

    def test_empty_graph_yields_no_correlations(self):
        from kgraph import pr_dashboard

        self.assertEqual(
            pr_dashboard._correlate_with_graph(self._git_data(["f.py"]), {}), [])
        self.assertEqual(
            pr_dashboard._correlate_with_graph(self._git_data(["f.py"]), None), [])


class TestPRDashboardHtml(unittest.TestCase):
    @staticmethod
    def _build(git_data, correlations=None):
        from kgraph import pr_dashboard

        return pr_dashboard._build_dashboard_html(
            git_data, correlations or [], "/tmp/repo", 30)

    def test_status_badges_cover_every_branch(self):
        html = self._build({"recent_files": [
            {"status": "A", "path": "added.py"},
            {"status": "D", "path": "deleted.py"},
            {"status": "M", "path": "modified.py"},
            {"status": "R100", "path": "renamed.py"},
            {"status": "?", "path": "odd.py"},
        ]})
        self.assertIn('class="badge added"', html)
        self.assertIn('class="badge deleted"', html)
        self.assertIn('class="badge modified"', html)
        self.assertIn('class="badge renamed"', html)
        self.assertIn('<span class="badge">?</span>', html)

    def test_marks_the_current_branch(self):
        html = self._build({"branches": [{"name": "main", "current": True},
                                         {"name": "old", "current": False}]})
        self.assertIn("<strong>▶</strong> main", html)
        self.assertIn("<li>old</li>", html)

    def test_row_limits_are_applied(self):
        html = self._build({
            "merges": [{"hash": f"h{i}", "author_name": "A", "subject": "s",
                        "date": "2026-01-01"} for i in range(25)],
            "commits": [{"hash": f"c{i}", "author_name": "A", "subject": "s",
                         "date": "2026-01-01"} for i in range(35)],
            "recent_files": [{"status": "M", "path": f"f{i}.py"} for i in range(45)],
            "branches": [{"name": f"b{i}", "current": False} for i in range(20)],
        })
        self.assertNotIn("h24", html)     # merges capped at 20
        self.assertNotIn("c34", html)     # commits capped at 30
        self.assertNotIn("f44.py", html)  # files capped at 40
        self.assertNotIn("b19", html)     # branches capped at 15

    def test_correlation_count_renders(self):
        html = self._build({"total_merges": 0, "total_commits": 0}, [
            {"file": "a.py", "node_label": "A", "node_type": "file"},
            {"file": "b.py", "node_label": "B", "node_type": "file"},
        ])
        self.assertIn("Graph Correlations (2)", html)
        self.assertIn("a.py", html)


# ── memory_import: files/chunks memory-store branch ─────────────────────

# Synthetic life index pinned into the module so the import never reads the
# host's ~/.openclaw/life tree.  "openclaw" proves canonical-type mapping,
# "gateway token rotation" proves alias → canonical record resolution, and the
# last two entries prove non-entity types and sub-3-char aliases never become
# canonical entity patterns.
_LIFE_INDEX = {
    "by_slug": {}, "by_type": {}, "records": [], "title_aliases": {},
    "aliases": {
        "openclaw": {"slug": "openclaw", "title": "OpenClaw", "type": "organization",
                     "path": "/life/organizations/openclaw.md", "aliases": [], "status": "active"},
        "gateway token rotation": {"slug": "gateway-token-rotation",
                                   "title": "Gateway Token Rotation", "type": "system",
                                   "path": "/life/systems/gateway-token-rotation.md",
                                   "aliases": [], "status": "active"},
        "notes": {"slug": "notes", "title": "Notes", "type": "note",
                  "path": "/life/notes/notes.md", "aliases": [], "status": "active"},
        "gw": {"slug": "gw", "title": "Gateway Watch", "type": "system",
               "path": "/life/systems/gateway-watch.md", "aliases": [], "status": "active"},
    },
}

_STORE_NOTES = """# Operations Notes
## Project: Launcher reliability
Project: Launcher reliability
Decision: token rotation
Decision: issue: gateway flapping | resolve by rotation
Jarvis (Operations Director) reviewed the launcher.
Finance Director (Marlowe) approved the budget.
We decided to keep the semantic naming.
Issue: duplicated nodes in graph
Outcome: launcher reliability validated
Work on gateway token rotation
The main issue is shallow topic labels
Result was launcher reliability validated
See `memory/notes.md` for details and also unknown/thing.md.
gateway openclaw wsl2 ubuntu linux
OpenClaw runs the registry here.
"""

_STORE_REPORT = """# Hal-Activate Report
## A
## Notes
## Status
We decided to rotate the gateway token
"""

_STORE_LINKS = "Links back to `memory/notes.md` for context.\nVigil (Sentinel) monitors the desk.\n"

_STORE_TERMS = """Decision: status
Project: profile.md
Decision: 2026-01-02
Issue: gateway
Outcome: results
Decision: raw!
Decision: 1 2 3 4
Decision: alpha bravo charlie delta echo
grep -n foo bar
gw

This line is deliberately made far longer than one hundred and twenty characters so that the concept_worthy_line length guard rejects it outright.
Sarah (Marketing) owns the launch.
See other.md and notes.md for context.
"""

_STORE_ACTIVATION = "# Lyra-Activate Report\nNothing much to report today.\n"

_STORE_FILES = ["memory/notes.md", "/abs/docs/other.md", "/docs/notes.md", None, ""]

# (id, path, start_line, end_line, text, embedding)
_STORE_CHUNKS = [
    ("c1", "memory/notes.md", 1, 5, _STORE_NOTES, "[1.0, 0.0, 0.0]"),
    ("c2", "memory/notes.md", 7, None, _STORE_REPORT, "[1.0, 0.0, 0.0]"),
    ("c3", "/abs/docs/other.md", None, None, _STORE_LINKS, "[1.0, 0.0, 0.0]"),
    ("c4", None, None, None, None, None),
    ("c5", "/abs/docs/third.md", 3, None, _STORE_TERMS, "not-json"),
    ("c6", "/abs/docs/fourth.md", None, None, "nothing to see", "[1.0, 0.0]"),
    ("c7", "/abs/docs/fifth.md", None, None, "zero vector", "[0.0, 0.0]"),
    ("c8", "/abs/docs/sixth.md", None, None, "bad element", '[1.0, "x"]'),
    ("c9", "/abs/docs/seventh.md", None, None, _STORE_ACTIVATION, '{"a": 1}'),
    ("c10", "/abs/docs/eighth.md", None, None, "empty vector", "[]"),
]


def _create_store_db(path):
    """Create a synthetic files/chunks memory-store DB with the live schema."""
    import sqlite3

    conn = sqlite3.connect(path)
    try:
        cur = conn.cursor()
        cur.execute("CREATE TABLE files (path TEXT)")
        cur.execute("CREATE TABLE chunks (id TEXT, path TEXT, start_line INT,"
                    " end_line INT, text TEXT, embedding TEXT)")
        cur.executemany("INSERT INTO files VALUES (?)", [(p,) for p in _STORE_FILES])
        cur.executemany("INSERT INTO chunks VALUES (?,?,?,?,?,?)", _STORE_CHUNKS)
        conn.commit()
    finally:
        conn.close()


def _node_ids(graph):
    return {n.id for n in graph.nodes}


def _edge_keys(graph):
    return {(e.source, e.target, e.label) for e in graph.edges}


def _node(graph, node_id):
    return next(n for n in graph.nodes if n.id == node_id)


class TestMemoryImportStore(unittest.TestCase):
    """files/chunks memory-store import against a real synthetic SQLite DB."""

    def _graph(self, include_all=False):
        """Import the standard synthetic store DB, cleaning up the temp DB."""
        from kgraph import memory_import

        with tempfile.TemporaryDirectory() as td:
            db = os.path.join(td, "store.db")
            _create_store_db(db)
            with mock.patch("kgraph.memory_import.load_life_index", return_value=_LIFE_INDEX):
                return memory_import.load_from_memory_db(db, include_all=include_all)

    def test_files_chunks_nodes_containment_and_references(self):
        graph = self._graph()
        ids = _node_ids(graph)
        edges = _edge_keys(graph)

        self.assertIn("file:memory/notes.md", ids)
        self.assertIn("file:/abs/docs/other.md", ids)
        self.assertNotIn("file:", ids)  # NULL/blank paths are skipped, not nodes
        # Label carries file + line range + whitespace-collapsed preview.
        c1 = _node(graph, "chunk:c1")
        self.assertTrue(c1.label.startswith("notes.md L1-5: # Operations Notes"))
        self.assertTrue(c1.label.endswith("…"), c1.label)
        # Only start_line is an int → single-ended range.
        self.assertTrue(_node(graph, "chunk:c2").label.startswith("notes.md L7:"))
        # No path and no text → bare "chunk" label, still a node.
        self.assertEqual(_node(graph, "chunk:c4").label, "chunk")
        self.assertIn(("file:memory/notes.md", "chunk:c1", "contains chunk"), edges)
        # A chunk path absent from `files` still gets a containing file node.
        self.assertIn("file:/abs/docs/third.md", ids)
        self.assertIn(("file:/abs/docs/third.md", "chunk:c5", "contains chunk"), edges)
        # File references: explicit path, unique basename, ambiguous, self, unknown.
        self.assertIn(("chunk:c3", "file:memory/notes.md", "references file"), edges)
        self.assertIn(("file:/abs/docs/other.md", "file:memory/notes.md", "references file"), edges)
        self.assertIn(("chunk:c5", "file:/abs/docs/other.md", "references file"), edges)
        self.assertNotIn(("chunk:c5", "file:memory/notes.md", "references file"), edges)
        self.assertNotIn(("chunk:c1", "file:memory/notes.md", "references file"), edges)
        self.assertNotIn("file:unknown/thing.md", ids)

    def test_every_emitted_node_type_is_classified_for_label_redaction(self):
        # audit_security.md residual: the GET read path redacts a node's LABEL
        # only when its type is in server._REDACTED_LABEL_TYPES, because for
        # those types label IS a preview of the node's own content
        # (memory_import sets label = _preview_text(content)).  A future
        # importer type that is content-derived but not listed there would leak
        # it.  This drives the real importer and requires every type it emits to
        # be classified — content-derived (redacted) or explicitly not — so a
        # new type fails here until someone decides.
        from kgraph import server as kgraph_server

        redacted = set(kgraph_server._REDACTED_LABEL_TYPES)
        # Types whose label cannot reconstruct their content (file paths, ids,
        # slugs, display names, short editorial titles).
        label_is_not_content = {
            "actor", "chunk", "decision", "file", "issue", "organization",
            "outcome", "person", "project", "system", "topic",
        }

        # The known content-derived types must stay redacted, and the two
        # classifications must not overlap.
        self.assertIn("memory", redacted)
        self.assertIn("summary", redacted)
        self.assertEqual(redacted & label_is_not_content, set())

        emitted = {
            str(getattr(n, "type", "") or "").lower()
            for n in self._graph(include_all=True).nodes
        }
        unclassified = sorted(emitted - redacted - label_is_not_content)
        self.assertEqual(
            unclassified, [],
            "importer node type(s) not classified for label redaction: "
            f"{unclassified} — add to server._REDACTED_LABEL_TYPES if the label "
            "is content-derived, otherwise to label_is_not_content here",
        )

    def test_actor_mentions_and_activation_authorship(self):
        graph = self._graph()
        edges = _edge_keys(graph)

        self.assertEqual(_node(graph, "actor:jarvis").role, "Operations Director")
        # Reverse pattern "Finance Director (Marlowe)" also yields an actor.
        self.assertEqual(_node(graph, "actor:marlowe").label, "Marlowe")
        # "# Hal-Activate Report" → role from AGENT_ROLES; unknown H1 → 'Agent'.
        self.assertEqual(_node(graph, "actor:hal").role, "CEO")
        self.assertEqual(_node(graph, "actor:lyra").role, "Agent")
        self.assertIn(("chunk:c1", "actor:jarvis", "mentions actor"), edges)
        self.assertIn(("file:memory/notes.md", "actor:jarvis", "mentions actor"), edges)
        self.assertIn(("chunk:c2", "actor:hal", "authored by"), edges)

    def test_theme_canonicalization_aliases_and_rejections(self):
        graph = self._graph()
        ids = _node_ids(graph)

        self.assertEqual(_node(graph, "project:launcher-reliability").label, "launcher reliability")
        # CONCEPT_ALIASES maps "token rotation" → "gateway token rotation", and
        # the life index remaps it to a system node with canonical provenance.
        gw = _node(graph, "system:gateway-token-rotation")
        self.assertEqual(gw.label, "Gateway Token Rotation")
        self.assertEqual(gw.canonical_slug, "gateway-token-rotation")
        self.assertEqual(gw.type_confidence, 0.96)
        # Pipe alternatives, morphological flattening, stopword stripping,
        # 4-word truncation, and heading-derived topic nodes.
        for present in ("decision:resolve-by-rotation", "issue:deduplication-nodes-in-graph",
                        "decision:keep-the-naming", "issue:shallow-topic-naming",
                        "decision:alpha-bravo-charlie-delta", "topic:project-launcher-reliability"):
            self.assertIn(present, ids)
        self.assertNotIn("topic:a", ids)  # 1-char heading produces no topic
        # Rejected: scaffolding, file/date labels, numeric-only labels, low-value
        # concepts, and aliases excluded from entity patterns by type/length.
        for absent in ("issue:gateway", "decision:raw", "decision:1-2-3-4",
                       "note:notes", "system:gateway-watch"):
            self.assertNotIn(absent, ids)
        labels = {n.label for n in graph.nodes}
        for rejected in ("status", "results", "gateway", "profile.md", "2026-01-02"):
            self.assertNotIn(rejected, labels)

    def test_semantic_summary_and_scored_pair_edges(self):
        graph = self._graph()

        summaries = [n for n in graph.nodes if n.id.startswith("summary:c1:")]
        self.assertEqual(len(summaries), 1)
        summary = summaries[0]
        self.assertEqual(
            summary.label,
            "launcher reliability | issue: deduplication nodes in graph | "
            "decision: resolve by rotation | outcome: launcher reliability validation",
        )
        self.assertEqual(summary.visibility, "semantic")
        self.assertEqual(summary.model_extra["summary_labels"][0], "launcher reliability")
        summary_edges = [e for e in graph.edges if e.source == summary.id]
        self.assertIn("summarizes project", {e.label for e in summary_edges})
        self.assertTrue(all(e.visibility == "semantic" for e in summary_edges))
        semantic = [e for e in graph.edges if e.source == "chunk:c1" and e.label == "semantic summary"]
        self.assertEqual([(e.visibility, e.quality_tier) for e in semantic],
                         [("semantic", "semantic")])
        # Fallback path: an actor-only chunk still summarises from its actor.
        fallback = [n for n in graph.nodes if n.id.startswith("summary:c3:")]
        self.assertEqual([n.label for n in fallback], ["vigil"])
        # A single co-occurrence of strongly-linked types is scored and kept.
        scored = [e for e in graph.edges if e.source == "decision:resolve-by-rotation"
                  and e.target == "project:launcher-reliability"]
        self.assertEqual([(e.label, e.semantic_score, e.cooccurrence_count) for e in scored],
                         [("project decision", 0.85, 1)])
        self.assertEqual(scored[0].model_extra["label_visibility"], "hover")

    def test_embedding_similarity_links_cross_file_chunks_only(self):
        graph = self._graph()
        edges = _edge_keys(graph)

        self.assertIn(("chunk:c1", "chunk:c3", "related (1.00)"), edges)
        self.assertIn(("file:memory/notes.md", "file:/abs/docs/other.md", "related (1.00)"), edges)
        sim = next(e for e in graph.edges if e.source == "chunk:c1" and e.target == "chunk:c3")
        self.assertEqual(sim.semantic_score, 1.0)
        # Same file → no similarity edge, even at identical vectors.
        self.assertNotIn(("chunk:c1", "chunk:c2", "related (1.00)"), edges)
        # Malformed ('not-json', '[1.0, "x"]'), non-list ('{"a": 1}'), empty
        # ('[]'), zero-magnitude and mismatched-dimension vectors are skipped
        # without aborting the import.
        skipped = {"chunk:c5", "chunk:c6", "chunk:c7", "chunk:c8", "chunk:c9", "chunk:c10"}
        similarity = [e for e in graph.edges if e.label.startswith("related (")
                      and (e.source in skipped or e.target in skipped)]
        self.assertEqual(similarity, [])
        self.assertIn("chunk:c8", _node_ids(graph))

    def test_unmigrated_store_schema_degrades_to_empty_graph(self):
        import sqlite3

        from kgraph import memory_import

        with tempfile.TemporaryDirectory() as td:
            db = os.path.join(td, "unmigrated.db")
            conn = sqlite3.connect(db)
            conn.execute("CREATE TABLE files (name TEXT)")
            conn.execute("CREATE TABLE chunks (id TEXT)")
            conn.commit()
            conn.close()
            with (
                mock.patch("kgraph.memory_import.load_life_index", return_value=_LIFE_INDEX),
                self.assertLogs("kgraph.memory_import", level="WARNING") as logs,
            ):
                graph = memory_import.load_from_memory_db(db)
        self.assertEqual(graph.nodes, [])
        self.assertEqual(graph.edges, [])
        self.assertTrue(any("Failed to read 'files' table" in line for line in logs.output),
                        logs.output)
        self.assertTrue(any("Failed to import chunks" in line for line in logs.output),
                        logs.output)


class TestMemoryImportSchemaDetection(unittest.TestCase):
    """Behaviour on DBs that are not a memory registry at all."""

    def _load(self, db):
        from kgraph import memory_import

        with mock.patch("kgraph.memory_import.load_life_index", return_value=_LIFE_INDEX):
            return memory_import.load_from_memory_db(db)

    def test_empty_or_missing_db_yields_empty_graph(self):
        import sqlite3

        with tempfile.TemporaryDirectory() as td:
            empty = os.path.join(td, "empty.db")
            with open(empty, "w", encoding="utf-8"):
                pass
            missing = os.path.join(td, "does-not-exist.db")
            for db in (empty, missing):
                graph = self._load(db)
                self.assertEqual(graph.nodes, [], db)
                self.assertEqual(graph.edges, [], db)
            # sqlite3.connect() creates the file; a bogus path is not an error.
            self.assertTrue(os.path.exists(missing))
            # A directory is not an openable database.
            with self.assertRaises(sqlite3.OperationalError):
                self._load(td)

    def test_partial_schema_needs_both_files_and_chunks(self):
        import sqlite3

        with tempfile.TemporaryDirectory() as td:
            for name, ddl, insert in (
                ("only_files.db", "CREATE TABLE files (path TEXT)",
                 "INSERT INTO files VALUES ('memory/notes.md')"),
                ("only_chunks.db", "CREATE TABLE chunks (id TEXT)",
                 "INSERT INTO chunks VALUES ('c1')"),
            ):
                db = os.path.join(td, name)
                conn = sqlite3.connect(db)
                conn.execute(ddl)
                conn.execute(insert)
                conn.commit()
                conn.close()
                graph = self._load(db)
                self.assertEqual(graph.nodes, [], name)
                self.assertEqual(graph.edges, [], name)


class TestMemoryImportConceptConfig(unittest.TestCase):
    """_load_concept_config() must warn loudly, not fail silently."""

    def test_unreadable_or_malformed_config_warns_and_disables_filtering(self):
        from kgraph import memory_import

        with tempfile.TemporaryDirectory() as td:
            bad = os.path.join(td, "concept-aliases.json")
            with open(bad, "w", encoding="utf-8") as fh:
                fh.write('{"scaffolding_labels": [')
            for path in (os.path.join(td, "absent.json"), bad):
                with (
                    # The loader now lives in constants.py, which owns the single
                    # source for concept classification (item 11.14) — so the path
                    # to patch and the logger to watch moved there with it.
                    mock.patch("kgraph.constants._CONCEPT_CONFIG_PATH", path),
                    self.assertLogs("kgraph.constants", level="WARNING") as logs,
                ):
                    self.assertEqual(memory_import._load_concept_config(), {})
                self.assertIn("concept config unavailable", logs.output[0])


# ── memory_import: registry branch rows ─────────────────────────────────

_LONG_MEMORY_CONTENT = "Long " + ("memory content " * 8)

_REGISTRY_DDL = [
    "CREATE TABLE memories (id TEXT, type TEXT, content TEXT, source_agent TEXT, scope TEXT, tags TEXT, confidence REAL, created_at TEXT, concept TEXT, value_score REAL, value_label TEXT, source_layer TEXT, status TEXT)",
    "CREATE TABLE memory_native_chunks (chunk_id TEXT, source_path TEXT, source_kind TEXT, section TEXT, line_start TEXT, line_end TEXT, content TEXT, scope TEXT, status TEXT)",
    "CREATE TABLE memory_entities (entity_id TEXT, kind TEXT, display_name TEXT, normalized_name TEXT, status TEXT, confidence REAL, aliases TEXT)",
    "CREATE TABLE memory_entity_mentions (memory_id TEXT, entity_key TEXT, entity_display TEXT, role TEXT, confidence REAL, scope TEXT)",
    "CREATE TABLE memory_entity_relationships (entity_id_a TEXT, entity_id_b TEXT, relationship_type TEXT, evidence_count INT, source_memory_ids TEXT, confidence REAL)",
    "CREATE TABLE memory_syntheses (synthesis_id TEXT, kind TEXT, subject_type TEXT, subject_id TEXT, content TEXT, stale INT, confidence REAL, generated_at TEXT)",
    "CREATE TABLE memory_claims (memory_id TEXT, memory_tier TEXT, claim_slot TEXT, consolidation_op TEXT, source_strength REAL, surface_candidate TEXT)",
    "CREATE TABLE memory_beliefs (belief_id TEXT, entity_id TEXT, type TEXT, content TEXT, status TEXT, confidence REAL, source_memory_id TEXT, source_layer TEXT)",
    "CREATE TABLE memory_open_loops (loop_id TEXT, kind TEXT, title TEXT, status TEXT, priority TEXT, related_entity_id TEXT)",
    "CREATE TABLE memory_events (event_id TEXT, timestamp TEXT, component TEXT, action TEXT, reason_codes TEXT, memory_id TEXT, payload TEXT)",
]

_REGISTRY_ROWS = [
    ("INSERT INTO memories VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)", [
        ("mem-1", "FACT", "Live memory", "jarvis", "jarvis", "[]", 0.9, "2026-04-01", None, None, None, "registry", "active"),
        ("mem-2", "FACT", "Archived memory", "jarvis", "jarvis", "[]", 0.9, "2026-04-01", None, None, None, "registry", "archived"),
        ("mem-3", "FACT", "Odd score memory", "jarvis", "jarvis", "[]", 0.9, "2026-04-01", None, "high", None, "registry", "active"),
        ("mem-4", "FACT", None, "jarvis", "jarvis", "[]", 0.9, "2026-04-01", None, None, None, "registry", "active"),
        ("mem-5", "FACT", "Low value memory", "jarvis", "jarvis", "[]", 0.9, "2026-04-01", None, 0.3, None, "registry", "active"),
        ("mem-6", "FACT", _LONG_MEMORY_CONTENT, "jarvis", "jarvis", "[]", 0.9, "2026-04-01", None, None, None, "registry", "active"),
    ]),
    ("INSERT INTO memory_native_chunks VALUES (?,?,?,?,?,?,?,?,?)", [
        ("chunk-1", "/mem/MEMORY.md", "memory_md", "KG", "4", "4", "Native fact", "profile:main", "active"),
        ("chunk-2", "/mem/MEMORY.md", "memory_md", "KG", "5", "5", "Archived native fact", "profile:main", "archived"),
        ("chunk-3", "/mem/MEMORY.md", "memory_md", "KG", "6", "6", "Live memory", "profile:main", "active"),
    ]),
    ("INSERT INTO memory_entities VALUES (?,?,?,?,?,?,?)", [
        ("e-blank", "person", None, "blank", "active", 0.5, "[]"),
        ("e-1", "person", "Rook", "rook", "active", 0.9, "[]"),
    ]),
    ("INSERT INTO memory_entity_mentions VALUES (?,?,?,?,?,?)", [
        (None, None, None, "general", 0.8, "profile:main"),
        ("mem-1", "database", "database", "general", 0.8, "profile:main"),
        ("mem-1", "rook", "Rook", "general", 0.9, "profile:main"),
        ("mem-1", "vigil", "Vigil", "general", 0.9, "profile:main"),
        ("native:chunk-1", "juno", "Juno", "general", 0.9, "profile:main"),
    ]),
    ("INSERT INTO memory_entity_relationships VALUES (?,?,?,?,?,?)", [
        ("a", "b", "depends_on", 2, '["mem-1"]', 0.8),
        (None, "b", "depends_on", 1, None, 0.5),
        ("c", None, "depends_on", 1, None, 0.5),
    ]),
    ("INSERT INTO memory_syntheses VALUES (?,?,?,?,?,?,?,?)", [
        ("synth-ok", "current_state", "global", "global", "Current State", 0, 0.9, "2026-04-01"),
        ("synth-stale", "old_report", "global", "global", "Old", 1, 0.8, "2026-04-01"),
    ]),
    ("INSERT INTO memory_claims VALUES (?,?,?,?,?,?)", [
        ("mem-1", "durable", "slot-1", "op", 0.9, "Claim text"),
        ("mem-missing", "durable", "slot-2", "op", 0.9, None),
    ]),
    ("INSERT INTO memory_beliefs VALUES (?,?,?,?,?,?,?,?)", [
        ("bel-1", "e-1", "fact", "Live belief", "current", 0.9, "mem-1", "registry"),
        ("bel-2", "e-1", "fact", "Superseded belief", "superseded", 0.9, "mem-1", "registry"),
    ]),
    ("INSERT INTO memory_open_loops VALUES (?,?,?,?,?,?)", [
        ("loop-1", "followup", "Rotate gateway token", "open", "high", None),
        ("loop-2", "followup", "Old closed item", "closed", "low", None),
    ]),
    ("INSERT INTO memory_events VALUES (?,?,?,?,?,?,?)", [
        ("evt-1", "2026-04-01", "capture", "capture_inserted", "[]", "mem-1", "{}"),
        ("evt-2", "2026-04-01", "capture", "capture_inserted", "[]", "mem-1", "{}"),
    ]),
]


def _create_registry_db(path):
    """Synthetic memory-registry DB exercising every filter/skip path."""
    import sqlite3

    conn = sqlite3.connect(path)
    try:
        cur = conn.cursor()
        for statement in _REGISTRY_DDL:
            cur.execute(statement)
        for statement, rows in _REGISTRY_ROWS:
            cur.executemany(statement, rows)
        conn.commit()
    finally:
        conn.close()


class TestMemoryImportRegistryRows(unittest.TestCase):
    """Registry rows: status/value filters, entity resolution, provenance."""

    def _graph(self, include_all=False, subdir="registry.db"):
        from kgraph import memory_import

        with tempfile.TemporaryDirectory() as td:
            db = os.path.join(td, subdir)
            os.makedirs(os.path.dirname(db), exist_ok=True)
            _create_registry_db(db)
            with mock.patch("kgraph.memory_import.load_life_index", return_value=_LIFE_INDEX):
                return memory_import.load_from_memory_db(db, include_all=include_all)

    def test_filters_drop_non_live_rows(self):
        with self.assertLogs("kgraph.memory_import", level="INFO") as logs:
            graph = self._graph()
        ids = _node_ids(graph)

        # status != 'active' drops memories and native chunks; a native chunk
        # duplicating an imported memory is suppressed; low value_score drops;
        # stale syntheses, superseded beliefs and closed loops drop.
        for present in ("memory:mem-1", "memory:native:chunk-1", "memory:mem-3",
                        "synthesis:synth-ok", "belief:bel-1", "open_loop:loop-1"):
            self.assertIn(present, ids)
        for absent in ("memory:mem-2", "memory:native:chunk-2", "memory:native:chunk-3",
                       "memory:mem-5", "synthesis:synth-stale", "belief:bel-2",
                       "open_loop:loop-2"):
            self.assertNotIn(absent, ids)
        # Blank content becomes an empty label without crashing.
        self.assertEqual(_node(graph, "memory:mem-4").label, "")
        # Long content is truncated to 72 chars including the ellipsis.
        long_label = _node(graph, "memory:mem-6").label
        self.assertEqual(len(long_label), 72)
        self.assertTrue(long_label.endswith("…"))
        self.assertTrue(any("2 events skipped" in line for line in logs.output), logs.output)

    def test_include_all_keeps_filtered_rows(self):
        graph = self._graph(include_all=True)
        ids = _node_ids(graph)

        for node_id in ("memory:mem-2", "memory:mem-5", "memory:native:chunk-2",
                        "synthesis:synth-stale", "belief:bel-2", "open_loop:loop-2"):
            self.assertIn(node_id, ids)
        # Promoted-content suppression is unconditional, not a status filter.
        self.assertNotIn("memory:native:chunk-3", ids)

    def test_entity_and_claim_resolution(self):
        graph = self._graph()
        ids = _node_ids(graph)

        # memory_entities with a blank display name creates no node; the noise
        # keyword mention is dropped; unknown keys are synthesized and native:
        # sources are rewritten to the memory:native: node.
        self.assertNotIn("", ids)
        self.assertIn("entity:person:rook", ids)
        self.assertNotIn("entity:database", ids)
        mentions = sorted((e.source, e.target) for e in graph.edges if e.label == "mentions")
        self.assertEqual(mentions, [("memory:mem-1", "entity:person:rook"),
                                    ("memory:mem-1", "entity:vigil"),
                                    ("memory:native:chunk-1", "entity:juno")])
        # Relationships with a missing endpoint are skipped.
        rel = [(e.source, e.target) for e in graph.edges if e.label == "depends_on"]
        self.assertEqual(rel, [("entity:a", "entity:b")])
        # Claims link to their source memory when it survived the filter, and
        # fall back to a slot label when no surface candidate exists.
        self.assertIn(("memory:mem-1", "claim:mem-1:slot-1", "claims"), _edge_keys(graph))
        self.assertEqual(_node(graph, "claim:mem-missing:slot-2").label, "claim slot-2")
        self.assertNotIn(("memory:mem-missing", "claim:mem-missing:slot-2", "claims"),
                         _edge_keys(graph))

    def test_registry_provenance_follows_db_path(self):
        self.assertEqual(_node(self._graph(), "memory:mem-1").model_extra["registry"], "home")
        rook = self._graph(subdir=os.path.join("workspace-rook", "registry.db"))
        self.assertEqual(_node(rook, "memory:mem-1").model_extra["registry"], "rook")

    def test_damaged_events_table_degrades_to_minus_one(self):
        # A corrupted memory_events table must not abort the import: the
        # provenance count degrades to -1 and the rest of the registry lands.
        import sqlite3

        from kgraph import memory_import

        with tempfile.TemporaryDirectory() as td:
            db = os.path.join(td, "registry.db")
            _create_registry_db(db)
            conn = sqlite3.connect(db)
            conn.execute("PRAGMA writable_schema=ON")
            conn.execute("UPDATE sqlite_master SET rootpage=0 WHERE name='memory_events'")
            conn.commit()
            conn.execute("PRAGMA writable_schema=OFF")
            conn.close()
            with (
                mock.patch("kgraph.memory_import.load_life_index", return_value=_LIFE_INDEX),
                self.assertLogs("kgraph.memory_import", level="INFO") as logs,
            ):
                graph = memory_import.load_from_memory_db(db)
        self.assertIn("memory:mem-1", _node_ids(graph))
        self.assertTrue(any("-1 events skipped" in line for line in logs.output), logs.output)


# ── projection.py ──────────────────────────────────────────────────────

# Fixed life index so these tests never read the host's ~/.openclaw/life.
_PROJECTION_LIFE_INDEX = {
    "aliases": {"graph layout": {"title": "Graph Quality", "type": "project",
                                 "slug": "graph-quality", "path": "life/projects/graph-quality.md"}},
    "title_aliases": {"alpha project": "Alpha Canonical"},
    "by_slug": {}, "by_type": {}, "records": [],
}


def _n(node_id, label, node_type, **extra):
    return {"id": node_id, "label": label, "type": node_type, **extra}


def _e(source, target, label, **extra):
    return {"from": source, "to": target, "label": label, **extra}


def _project(graph, **kwargs):
    """project_graph with the host life-index load replaced by _PROJECTION_LIFE_INDEX."""
    with mock.patch("kgraph.projection.load_life_index", return_value=_PROJECTION_LIFE_INDEX):
        return kgraph.project_graph(graph, **kwargs)


class TestProjectionHelpers(unittest.TestCase):
    def test_threshold_label_and_strength_helpers(self):
        from kgraph import projection
        for given, expected in [(0.0, 0.58), (0.5, 0.58), (0.82, 0.772), (1.0, 0.88), (2.0, 0.90)]:
            self.assertAlmostEqual(projection._effective_semantic_threshold(given), expected, msg=given)
        for label, expected in [("The Current Graph Layout", "graph"), ("Topic cleanup", "topic structure"),
                                ("Alpha Project", "alpha canonical"), ("!!!", ""), ("", "")]:
            self.assertEqual(projection._normalized_semantic_label(_n("x", label, "topic"), _PROJECTION_LIFE_INDEX),
                             expected, msg=label)
        alias = {"aliases": {"widget": {"title": "Widget Canonical"}}, "title_aliases": {"gadget": "Gadget C"}}
        self.assertEqual(projection._normalized_semantic_label(_n("x", "Widget", "topic"), alias), "widget canonical")
        self.assertEqual(projection._normalized_semantic_label(_n("x", "Gadget", "topic"), alias), "gadget c")
        for edge, expected in [(_e("a", "b", "project decision", semantic_score=0.1), 0.95),
                               (_e("a", "b", "project outcome"), 0.88),
                               (_e("a", "b", "actor issue"), 0.76),
                               (_e("a", "b", "related", semantic_score=0.5, cooccurrence_count=3), 0.56),
                               (_e("a", "b", "x", semantic_score="bad", cooccurrence_count="no"), 0.0)]:
            self.assertEqual(projection._edge_strength_value(edge), expected, msg=edge["label"])
        self.assertLessEqual(projection._edge_strength_value(
            _e("a", "b", "project decision", semantic_score=0.99, cooccurrence_count=9)), 0.99)

    def test_visibility_curation_endpoint_helpers(self):
        from kgraph import projection
        self.assertEqual((projection._node_visibility({"view_visibility": "RAW"}),
                          projection._node_visibility({})), ("raw", "both"))
        self.assertEqual((projection._node_quality({"quality": "Supporting"}),
                          projection._node_quality({})), ("supporting", "semantic"))
        self.assertEqual((projection._edge_visibility({"view_visibility": "Raw"}),
                          projection._edge_quality({"quality": "SUPPORTING"})), ("raw", "supporting"))
        self.assertTrue(projection._is_weak_label("  Summary "))
        self.assertFalse(projection._is_weak_label("Real Thing"))
        for node, expected in [(_n("x", "summary", "note"), False),
                               (_n("x", "f", "file", visibility="raw"), False),
                               (_n("x", "t", "topic", quality_tier="supporting"), False),
                               (_n("x", "f", "file", path="life/decision-x.md"), False),
                               (_n("x", "anything", "topic"), True),
                               (_n("x", "f", "file", path="src/a.py"), True),
                               (_n("x", "Real Thing", "note"), True)]:
            self.assertEqual(projection._is_curated_node(node), expected, msg=str(node))
        for edge, expected in [(_e("a", "b", "covers topic"), True),
                               (_e("a", "b", "summarizes project"), True),
                               (_e("a", "b", "related (0.9)", semantic_score=0.9), True),
                               (_e("a", "b", "related (0.5)", semantic_score=0.5), False),
                               (_e("a", "b", "related x", semantic_score="nope"), False),
                               (_e("a", "b", "calls"), False),
                               (_e("a", "b", "covers topic", visibility="raw"), False)]:
            self.assertEqual(projection._is_curated_edge(edge, 0.77), expected, msg=str(edge))
        self.assertEqual(projection._edge_endpoints({"source": "s", "target": "t"}), ("s", "t"))
        self.assertEqual(projection._edge_endpoints(_e("f", "g", "x")), ("f", "g"))
        self.assertEqual(projection._edge_endpoints({}), (None, None))
        out, seen = [], set()
        projection._dedupe_append(out, seen, None, "b", "x")
        projection._dedupe_append(out, seen, "a", None, "x")
        projection._dedupe_append(out, seen, "a", "b", "x")
        projection._dedupe_append(out, seen, "a", "b", "x")
        projection._dedupe_append(out, seen, "a", "b", "y", {"semantic_score": 0.5})
        self.assertEqual(out, [_e("a", "b", "x"), _e("a", "b", "y", semantic_score=0.5)])

    def test_set_display_label_per_mode(self):
        from kgraph import projection
        long_label = "x" * 90
        cases = [
            (_n("f1", "a.md", "file"), "f1", "file", "overview", set(), "", "provenance"),
            (_n("p1", long_label, "project"), "p1", "project", "overview", set(), long_label[:56], None),
            (_n("p1", long_label, "project", importance=9), "p1", "project", "semantic", {"p1"}, long_label[:34], None),
            (_n("p1", long_label, "project", importance=1), "p1", "project", "semantic", set(), "", None),
            (_n("s1", long_label, "summary", importance=9), "s1", "summary", "semantic", {"s1"}, long_label[:40], None),
            (_n("t1", long_label, "topic", importance=9), "t1", "topic", "semantic", {"t1"}, long_label[:22], None),
            (_n("c1", long_label, "chunk", importance=9), "c1", "chunk", "semantic", {"c1"}, long_label[:26], None),
            (_n("t1", long_label, "topic", importance=9), "t1", "topic", "topics", {"t1"}, long_label[:24], None),
            (_n("t2", long_label, "topic", importance=2), "t2", "topic", "topics", {"t1"}, "", None),
        ]
        for node, nid, ntype, mode, top, expected, role in cases:
            projection._set_display_label(node, nid, ntype, mode, top)
            self.assertEqual(node["display_label"], expected, msg=(mode, ntype))
            if role:
                self.assertEqual(node["visual_role"], role)
        for label in ("2024-01-01.md", "memory.md", "profile.md"):
            node = _n("m", label, "topic")
            projection._set_display_label(node, "m", "topic", "semantic", {"m"})
            self.assertEqual((node["display_label"], node["visual_role"]), ("", "provenance"), msg=label)

    def test_collapse_semantic_duplicates_merges_and_drops_self_loops(self):
        from kgraph import projection
        out = {"nodes": [_n("a1", "The Graph Layout", "topic"),
                         _n("a2", "Graph Layout", "topic", inferred_type=True),
                         _n("b1", "Other", "topic")],
               "edges": [_e("a1", "a2", "covers topic"), _e("a1", "b1", "covers topic"),
                         _e("a2", "b1", "covers topic")]}
        projection._collapse_semantic_duplicates(out, {"topic"}, _PROJECTION_LIFE_INDEX)
        # The non-inferred duplicate survives as canonical; its self-loop and the
        # parallel a2 -> b1 edge are dropped.
        self.assertEqual([n["id"] for n in out["nodes"]], ["a1", "b1"])
        self.assertEqual(out["edges"], [_e("a1", "b1", "covers topic")])

    def test_build_cluster_suggestions_labels_and_fallbacks(self):
        from kgraph import projection
        def cluster(nodes, edges):
            return projection._build_cluster_suggestions({"nodes": nodes, "edges": edges})
        bases = [_n("a", "Alpha", "project", degree=2, semantic_degree=2),
                 _n("b", "Beta", "decision", degree=2, semantic_degree=2),
                 _n("c", "Gamma", "issue", degree=2, semantic_degree=2)]
        strong = [_e("a", "b", "project decision", semantic_score=0.9),
                  _e("b", "c", "decision addresses issue", semantic_score=0.9),
                  _e("a", "c", "project issue", semantic_score=0.9)]
        self.assertEqual([(s["label"], s["size"]) for s in cluster(bases, strong)], [("Alpha · Gamma", 3)])
        # Unknown endpoints are ignored; a two-node component is not a cluster.
        self.assertEqual(len(cluster(bases, strong + [_e("a", "ghost", "project decision")])), 1)
        self.assertEqual(cluster(bases[:2], strong), [])
        # Weak labels and bad numeric fields fall through to a generic name.
        weak = [_n("w1", "Repo cleanup", "topic", degree=2), _n("w2", "Env bridge", "topic", degree=2),
                _n("w3", "Copilot token", "topic", degree=2)]
        weak_edges = [_e("w1", "w2", "related (0.9)", semantic_score=0.9),
                      _e("w2", "w3", "related (0.9)", semantic_score=0.9),
                      _e("w1", "w3", "related (0.9)", semantic_score=0.9)]
        self.assertEqual([s["label"] for s in cluster(weak, weak_edges)], ["cluster 1"])
        chunk_edges = [_e("c1", "c2", "related (0.9)", semantic_score=0.9),
                       _e("c2", "c3", "related (0.9)", semantic_score=0.9),
                       _e("c1", "c3", "related (0.9)", semantic_score=0.9)]
        chunks = [_n("c1", "Chunk one", "chunk", degree=2), _n("c2", "Chunk two", "chunk", degree=2),
                  _n("c3", "Chunk three", "chunk", degree=2)]
        self.assertEqual([s["label"] for s in cluster(chunks, chunk_edges)], ["Chunk three · Chunk one"])
        single = [_n("a", "Alpha", "project", degree=2), _n("b", "Graph quality", "topic", degree=2),
                  _n("c", "Env bridge", "decision", degree=2)]
        bad_numeric = [_e("a", "b", "project decision", semantic_score="bad", cooccurrence_count="bad"),
                       _e("b", "c", "decision addresses issue", cooccurrence_count=3),
                       _e("a", "c", "project issue", cooccurrence_count=2)]
        self.assertEqual([s["label"] for s in cluster(single, bad_numeric)], ["Alpha (cluster)"])
        repeated = [_n("a", "Same", "project", degree=2), _n("b", "Same", "decision", degree=2),
                    _n("c", "Graph quality", "issue", degree=2)]
        self.assertEqual([s["label"] for s in cluster(repeated, strong)], ["Same (issue)"])
        # Cooccurrence-only relations stay below the 0.74 cluster bar.
        self.assertEqual(cluster(single, [_e("a", "b", "related", cooccurrence_count=3),
                                          _e("b", "c", "related", cooccurrence_count=2)]), [])

    def test_filter_semantic_edges_selection_rules(self):
        from kgraph import projection
        gateway = {"nodes": [_n("s1", "Gateway", "topic"), _n("p1", "Proj", "project")],
                   "edges": [_e("s1", "p1", "semantic related", semantic_score=0.9)]}
        projection._filter_semantic_edges(gateway, "topics", _PROJECTION_LIFE_INDEX)
        # The topic->gateway cap drops the edge; topics mode keeps both nodes.
        self.assertEqual(gateway["edges"], [])
        self.assertEqual({n["id"] for n in gateway["nodes"]}, {"s1", "p1"})
        unknown = {"nodes": [_n("t1", "Topic one", "topic")], "edges": [_e("ghost", "t1", "covers topic")]}
        projection._filter_semantic_edges(unknown, "semantic", _PROJECTION_LIFE_INDEX)
        self.assertEqual(unknown["edges"], [])
        reverse = {"nodes": [_n("p1", "Proj", "project"), _n("d1", "Dec", "decision")],
                   "edges": [_e("p1", "d1", "project decision", semantic_score=0.9),
                             _e("d1", "p1", "project decision", semantic_score=0.9)]}
        projection._filter_semantic_edges(reverse, "topics", _PROJECTION_LIFE_INDEX)
        self.assertEqual(len(reverse["edges"]), 1)  # reverse pairs dedupe
        hub = [_n("h", "Hub project", "project")] + [_n(f"l{i}", f"Leaf {i}", "topic") for i in range(12)]
        budget = {"nodes": list(hub),
                  "edges": [_e("h", f"l{i}", "related", semantic_score=0.8) for i in range(12)]}
        projection._filter_semantic_edges(budget, "semantic", _PROJECTION_LIFE_INDEX)
        # Degree >= 10 gives budget 4 and strength 0.86, under the 0.88 override.
        self.assertEqual(len(budget["edges"]), 4)
        medium = {"nodes": hub[:9],
                  "edges": [_e("h", f"l{i}", "related", semantic_score=0.8) for i in range(8)]}
        projection._filter_semantic_edges(medium, "topics", _PROJECTION_LIFE_INDEX)
        self.assertEqual(len(medium["edges"]), 6)  # medium-degree budget
        sparse = {"nodes": [_n(f"t{i:02d}", f"Topic {i:02d}", "topic") for i in range(20)],
                  "edges": [_e(f"t{i:02d}", f"t{i + 1:02d}", "related (0.5)", semantic_score=0.5)
                            for i in range(0, 20, 2)] +
                           [_e("t00", "t01", "related (0.55)", semantic_score=0.55)]}
        projection._filter_semantic_edges(sparse, "semantic", _PROJECTION_LIFE_INDEX)
        # All edges are sub-threshold, so the sparse fallback rescues them: the
        # duplicate pair is skipped and the result stops at the ten-edge cap.
        pairs = [(e["from"], e["to"]) for e in sparse["edges"]]
        self.assertEqual((len(pairs), len(set(pairs))), (10, 10))
        unanchored = {"nodes": [_n("p1", "Alpha project", "project"), _n("t1", "Topic one", "topic"),
                                _n("t2", "Topic two", "topic")],
                      "edges": [_e("t1", "t2", "semantic related", semantic_score=0.9),
                                _e("t1", "p1", "project topic", semantic_score=0.9)]}
        projection._filter_semantic_edges(unanchored, "topics", _PROJECTION_LIFE_INDEX)
        self.assertEqual({(e["from"], e["to"]) for e in unanchored["edges"]}, {("t1", "p1")})


class TestProjectGraphModes(unittest.TestCase):
    def test_raw_and_empty_modes(self):
        graph = {"nodes": [_n("a", "A", "topic")], "edges": []}
        self.assertIs(kgraph.project_graph(graph, mode="raw"), graph)
        for mode in ("overview", "files", "topics", "semantic"):
            out = _project({"nodes": [], "edges": []}, mode=mode)
            self.assertEqual((out["nodes"], out["edges"], out["_meta"]["nodeCount"]), ([], [], 0), mode)

    def test_overview_filters_nodes_and_lifts_chunk_edges(self):
        out = _project({"nodes": [_n("n1", "Custom", "custom", visibility="raw"),
                                  _n("n2", "Custom2", "custom"), _n("n3", "summary", "note"),
                                  _n("n4", "T", "topic", visibility="raw"), _n("f1", "A.md", "file"),
                                  _n("c1", "chunk", "chunk"), _n("p1", "P", "project")],
                        "edges": [_e("f1", "c1", "contains chunk"), _e("c1", "p1", "has project"),
                                  _e("f1", "n4", "covers topic"), _e("n2", "p1", "links")]},
                       mode="overview")
        # Weak/raw nodes go, chunks go, the chunk edge lifts to the file, and
        # file->topic curated plus uncurated edges are dropped.
        self.assertEqual({n["id"] for n in out["nodes"]}, {"n2", "n4", "f1", "p1"})
        self.assertEqual([(e["from"], e["to"], e["label"]) for e in out["edges"]], [("f1", "p1", "has project")])
        self.assertEqual(out["_meta"]["edgeCount"], 1)

    def test_overview_keeps_ast_structure_and_reports_meta(self):
        out = _project(_AST_GRAPH, mode="overview")
        self.assertEqual({n["id"] for n in out["nodes"]}, {
            "ast_file:main_py", "ast_func:hello", "ast_class:greeter",
            "ast_module:os", "ast_call:print"})
        self.assertEqual(len(out["edges"]), 5)
        file_node = next(n for n in out["nodes"] if n["id"] == "ast_file:main_py")
        self.assertEqual((file_node["display_label"], file_node["visual_role"]), ("", "provenance"))
        self.assertEqual((out["_meta"]["nodeCount"], out["_meta"]["edgeCount"]), (5, 5))
        self.assertEqual((out["_meta"]["typeCounts"]["function"], out["_meta"]["typeCounts"]["file"]), (1, 1))

    def test_overview_edge_selection_and_lifting(self):
        scored = _project({"nodes": [_n("t1", "Topic one", "topic"), _n("t2", "Topic two", "topic")],
                           "edges": [_e("t1", "t2", "related (0.9)", semantic_score=0.9)]}, mode="overview")
        self.assertEqual([(e["from"], e["to"], e["label"], e["semantic_score"]) for e in scored["edges"]],
                         [("t1", "t2", "related (0.9)", 0.9)])
        # Without a "contains chunk" parent edge the chunk edge cannot be lifted,
        # and endpoint-less/unknown/non-curated edges are all skipped.
        dangling = _project({"nodes": [_n("c1", "chunk", "chunk"), _n("t1", "Topic one", "topic")],
                             "edges": [{"label": "covers topic"}, _e("c1", "t1", "covers topic"),
                                       _e("ghost", "t1", "covers topic")]}, mode="overview")
        self.assertEqual(dangling["edges"], [])
        self.assertEqual({n["id"] for n in dangling["nodes"]}, {"t1"})
        non_curated = _project({"nodes": [_n("t1", "Topic one", "topic"), _n("t2", "Topic two", "topic")],
                                "edges": [_e("t1", "t2", "links")]}, mode="overview")
        self.assertEqual(non_curated["edges"], [])
        lifted = _project({"nodes": [_n("f1", "a.md", "file"), _n("c1", "chunk", "chunk"),
                                     _n("a1", "Actor", "actor")],
                           "edges": [_e("f1", "c1", "contains chunk"), _e("c1", "a1", "mentions actor")]},
                          mode="overview")
        self.assertEqual([(e["from"], e["to"], e["label"]) for e in lifted["edges"]],
                         [("f1", "a1", "file mentions actor")])

    def test_files_and_topics_modes_filter_by_type(self):
        ast = dict(_AST_GRAPH)
        files = _project({"nodes": ast["nodes"] + [_n("topic:x", "T", "topic")],
                          "edges": ast["edges"] + [_e("ast_file:main_py", "topic:x", "covers topic")]},
                         mode="files")
        self.assertEqual({n["id"] for n in files["nodes"]}, {
            "ast_file:main_py", "ast_func:hello", "ast_class:greeter",
            "ast_module:os", "ast_call:print"})
        self.assertEqual(len(files["edges"]), 5)
        pair = _project({"nodes": [_n("f1", "a.py", "file"), _n("f2", "b.sh", "file")],
                         "edges": [_e("f1", "f2", "references")]}, mode="files")
        self.assertEqual([(e["from"], e["to"], e["label"]) for e in pair["edges"]],
                         [("f1", "f2", "references")])
        topics = _project({"nodes": [_n("t1", "Topic one", "topic"), _n("p1", "Proj", "project"),
                                     _n("f1", "f.py", "file"), _n("a1", "Actor", "actor")],
                           "edges": [_e("p1", "t1", "project topic", semantic_score=0.9),
                                     _e("t1", "a1", "covers topic"), _e("f1", "t1", "covers topic")]},
                          mode="topics")
        self.assertEqual({n["id"] for n in topics["nodes"]}, {"t1", "p1", "a1"})
        self.assertEqual([(e["from"], e["to"], e["label"]) for e in topics["edges"]],
                         [("p1", "t1", "project topic"), ("t1", "a1", "covers topic")])

    def test_project_graph_accepts_graph_model(self):
        from kgraph.models import Graph
        out = _project(Graph.from_dict(_AST_GRAPH), mode="overview")
        self.assertEqual((out["_meta"]["nodeCount"], out["_meta"]["edgeCount"]), (5, 5))

    def test_semantic_mode_curated_edges_and_canonical_bias(self):
        out = _project({"nodes": [_n("t1", "Graph Layout", "topic"), _n("p1", "Proj", "project")],
                        "edges": [_e("p1", "t1", "project topic", semantic_score=0.9)]}, mode="semantic")
        topic = next(n for n in out["nodes"] if n["id"] == "t1")
        # The life-index alias rewrites label/type and flags the inference.
        self.assertEqual((topic["label"], topic["type"], topic["inferred_type"]), ("Graph Quality", "project", True))
        self.assertEqual((topic["canonical_slug"], topic["canonical_path"]),
                         ("graph-quality", "life/projects/graph-quality.md"))
        self.assertEqual([(e["from"], e["to"], e["label"]) for e in out["edges"]],
                         [("p1", "t1", "project topic")])
        empty = _project({"nodes": [_n("p1", "", "project"), _n("p2", "Beta project", "project")],
                          "edges": [_e("p1", "p2", "project decision", semantic_score=0.9)]}, mode="semantic")
        self.assertEqual(({n["id"] for n in empty["nodes"]}, len(empty["edges"])), ({"p1", "p2"}, 1))

    def test_semantic_mode_infers_cooccurrence_edges(self):
        out = _project({"nodes": [_n("s1", "Weekly", "summary"), _n("p1", "Alpha project", "project"),
                                  _n("d1", "Beta decision", "decision"), _n("i1", "Gamma issue", "issue")],
                        "edges": [_e("s1", "p1", "summarizes project"),
                                  _e("s1", "d1", "summarizes decision"),
                                  _e("s1", "i1", "summarizes issue")]}, mode="semantic")
        # The summary is support, never emitted; its concepts form inferred edges.
        self.assertEqual({n["id"] for n in out["nodes"]}, {"p1", "d1", "i1"})
        for edge in out["edges"]:
            self.assertEqual((edge["label"], edge["inferred"], edge["cooccurrence_count"],
                              edge["support_summary_count"]), ("semantic related", True, 1, 1))

    def test_semantic_mode_summary_and_chunk_support(self):
        out = _project({"nodes": [_n("p1", "Alpha project", "project"), _n("p2", "Beta project", "project"),
                                  _n("p3", "Gamma project", "project"), _n("p4", "Delta project", "project"),
                                  _n("s1", "Weekly notes", "summary"), _n("c1", "summary", "chunk")],
                        "edges": [_e("s1", "p1", "summarizes project"), _e("s1", "p2", "summarizes project"),
                                  _e("c1", "p3", "covers topic"), _e("p4", "c1", "covers topic"),
                                  _e("p1", "p2", "project decision", semantic_score=0.9)]}, mode="semantic")
        self.assertEqual({n["id"] for n in out["nodes"]}, {"p1", "p2", "p3", "p4"})
        edge = next(e for e in out["edges"] if {e["from"], e["to"]} == {"p3", "p4"})
        # p3/p4 co-occur only through the chunk, traversed in both directions.
        self.assertEqual((edge["label"], edge["support_summary_count"], edge["support_chunk_count"]),
                         ("semantic related", 0, 1))
        # A concept can also be reached through the summary in either direction.
        linked = _project({"nodes": [_n("p1", "Alpha project", "project"), _n("p2", "Beta project", "project"),
                                     _n("s1", "Weekly notes", "summary")],
                           "edges": [_e("p1", "s1", "summarizes project"), _e("s1", "p2", "summarizes project"),
                                     _e("p1", "p2", "project decision", semantic_score=0.9)]}, mode="semantic")
        self.assertEqual(({n["id"] for n in linked["nodes"]}, len(linked["edges"])), ({"p1", "p2"}, 1))

    def test_semantic_mode_topic_penalty_and_unknown_endpoints(self):
        nodes = [_n("t1", "Topic one", "topic"), _n("t2", "Topic two", "topic"), _n("t3", "Topic three", "topic"),
                 _n("p1", "Alpha project", "project")] + \
                [_n(f"s{i}", f"Notes {i}", "summary") for i in range(3)]
        edges = []
        for summary in ("s0", "s1", "s2"):
            edges += [_e(summary, "t1", "summarizes topic"),
                      _e(summary, "t2", "summarizes topic"),
                      _e(summary, "p1", "summarizes project")]
        edges.append(_e("s0", "t3", "summarizes topic"))
        out = _project({"nodes": nodes, "edges": edges}, mode="semantic")
        related = {(e["from"], e["to"]): e for e in out["edges"] if e["label"] == "semantic related"}
        self.assertIn(("t1", "t2"), related)
        # Two topics cost an extra penalty, so they score below the anchor pair.
        self.assertLess(related[("t1", "t2")]["semantic_score"],
                        related[("p1", "t1")]["semantic_score"])
        bad = _project({"nodes": [_n("p1", "Alpha project", "project"), _n("d1", "Beta decision", "decision")],
                        "edges": [_e("ghost", "d1", "project decision", semantic_score=0.9),
                                  _e("p1", "d1", "project decision", semantic_score="bad")]}, mode="semantic")
        self.assertEqual([(e["from"], e["to"], e["label"]) for e in bad["edges"]],
                         [("p1", "d1", "project decision")])

    def test_semantic_mode_filters_unconnected_and_weak_nodes(self):
        out = _project({"nodes": [_n("p1", "Alpha project", "project"), _n("t1", "Topic one", "topic"),
                                  _n("p2", "Graph quality", "topic"), _n("p3", "Beta project", "project"),
                                  _n("z1", "Lonely thing", "topic"), _n("a1", "Alice Actor", "actor")],
                        "edges": [_e("p1", "t1", "project topic", semantic_score=0.9),
                                  _e("p1", "a1", "project owner", semantic_score=0.9)]}, mode="semantic")
        # p2 (weak label) and z1 (unconnected topic) go; anchors and actors stay.
        self.assertEqual({n["id"] for n in out["nodes"]}, {"p1", "t1", "p3", "a1"})

    def test_semantic_mode_fallback_and_threshold(self):
        two = {"nodes": [_n("p1", "Alpha project", "project"), _n("p2", "Beta project", "project")], "edges": []}
        low = _project(two, mode="semantic", semantic_threshold=0.4)
        self.assertEqual([(e["from"], e["to"], e["label"], e["semantic_score"], e["fallback"])
                          for e in low["edges"]], [("p1", "p2", "semantic related", 0.42, True)])
        high = _project(two, mode="semantic", semantic_threshold=0.95)
        self.assertEqual((high["edges"], {n["id"] for n in high["nodes"]}), ([], {"p1", "p2"}))
        many = _project({"nodes": [_n(f"p{i:02d}", f"Project {i:02d}", "project") for i in range(10)],
                         "edges": []}, mode="semantic", semantic_threshold=0.4)
        self.assertLessEqual(len(many["edges"]), 10)  # strong-node fallback caps pairs
        self.assertGreater(len(many["edges"]), 0)

    def test_semantic_mode_applies_inferred_neighbor_budget(self):
        nodes = [_n("p1", "Alpha project", "project")] + \
                [_n(f"d{i}", f"Decision {i}", "decision") for i in range(6)] + \
                [_n(f"s{i}", f"Notes {i}", "summary") for i in range(6)]
        edges = []
        for i in range(6):
            edges += [_e(f"s{i}", "p1", "summarizes project"), _e(f"s{i}", f"d{i}", "summarizes decision")]
        out = _project({"nodes": nodes, "edges": edges}, mode="semantic")
        # Every decision co-occurs only with p1; its inferred-neighbour budget
        # caps how many of these weak 0.5 pairs survive.
        self.assertEqual(len(out["edges"]), 3)
        self.assertTrue(all("p1" in (e["from"], e["to"]) and e["semantic_score"] == 0.5
                            for e in out["edges"]))

    def test_semantic_mode_small_graph(self):
        out = _project(_SMALL_GRAPH, mode="semantic")
        self.assertEqual({n["id"] for n in out["nodes"]}, {"a", "b", "c"})
        self.assertEqual({(e["from"], e["to"]) for e in out["edges"]}, {("a", "b"), ("b", "c")})
        self.assertTrue(all(n["importance"] >= 1 for n in out["nodes"]))
        suggestions = out["_meta"]["clusterSuggestions"]
        self.assertEqual([(s["id"], s["size"], set(s["members"])) for s in suggestions],
                         [("semantic_cluster_1", 3, {"a", "b", "c"})])


# ── ast_extractor.py ───────────────────────────────────────────────────


class TestAstExtractor(unittest.TestCase):
    """Exercise tree-sitter extraction on a synthetic repo.

    The parser is an optional extra; without it these tests skip rather than
    asserting parser output that cannot exist.
    """

    def setUp(self):
        if not kgraph.ast_available():
            self.skipTest("tree-sitter grammars not installed")
        td = tempfile.TemporaryDirectory()
        self.addCleanup(td.cleanup)
        self.root = td.name
        self._write("main.py", "import os\nimport helper\n\n"
                               "class Greeter:\n    pass\n\n"
                               "def hello(name):\n    print(name)\n    return len(name)\n\n"
                               "async def aio():\n    pass\n")
        self._write("helper.py", "def hello():\n    return 1\n")
        self._write("run.sh", "#!/bin/bash\nMY_VAR=1\ngreet() {\n  echo hi\n}\ngreet\n")
        self._write("pkg/mod.py", "def pkgfunc():\n    pass\n")
        self._write("pkg/sub/deep.py", "def deepfunc():\n    pass\n")
        self._write(".hidden/h.py", "def hiddenfunc():\n    pass\n")

    def _write(self, rel, text):
        path = os.path.join(self.root, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as f:
            f.write(text)

    def _ids(self, result):
        return {n["id"] for n in result["nodes"]}

    def _edges(self, result):
        return {(e["source"], e["target"], e["label"]) for e in result["edges"]}

    def test_extracts_python_definitions_imports_and_calls(self):
        result = kgraph.extract_repo_graph(self.root)
        ids = self._ids(result)
        for nid in ("ast_file:main-py", "ast_func:hello", "ast_class:greeter", "ast_module:os",
                    "ast_module:helper", "ast_call:print"):
            self.assertIn(nid, ids)
        edges = self._edges(result)
        for edge in (("ast_file:main-py", "ast_func:hello", "defines"),
                     ("ast_file:main-py", "ast_class:greeter", "defines"),
                     ("ast_file:main-py", "ast_module:os", "imports"),
                     ("ast_file:main-py", "ast_call:print", "calls")):
            self.assertIn(edge, edges)
        by_id = {n["id"]: n for n in result["nodes"]}
        self.assertTrue(by_id["ast_func:aio"]["async"])
        self.assertFalse(by_id["ast_func:hello"]["async"])
        # Two identical calls collapse onto one node and one edge.
        self._write("twice.py", "def go():\n    pass\n\ngo()\ngo()\n")
        calls = [(e["source"], e["target"], e["label"])
                 for e in kgraph.extract_repo_graph(self.root)["edges"]
                 if e["source"] == "ast_file:twice-py" and e["label"] == "calls"]
        self.assertEqual(calls, [("ast_file:twice-py", "ast_call:go", "calls")])

    def test_extracts_bash_variables_imports_and_call_links(self):
        result = kgraph.extract_repo_graph(self.root, include_variables=True)
        self.assertIn("ast_func:greet", self._ids(result))
        self.assertIn("ast_var:my-var", self._ids(result))
        self.assertNotIn("ast_var:my-var", self._ids(kgraph.extract_repo_graph(self.root)))
        edges = self._edges(result)
        self.assertIn(("ast_file:run-sh", "ast_func:greet", "defines"), edges)
        self.assertIn(("ast_module:helper", "ast_file:helper-py", "resolves_to"), edges)
        self.assertIn(("ast_call:greet", "ast_func:greet", "calls"), edges)
        # print() has no definition in the tree, so it stays unlinked.
        self.assertNotIn(("ast_call:print", "ast_func:print", "calls"), edges)

    def test_maps_extra_extensions_and_skips_hidden_and_unreadable(self):
        self._write("script.zsh", "greet_zsh() {\n  echo hi\n}\n")
        self._write("thing.pyw", "def pywfunc():\n    pass\n")
        self._write("locked.py", "def locked():\n    pass\n")
        locked = os.path.join(self.root, "locked.py")
        os.chmod(locked, 0o000)
        self.addCleanup(os.chmod, locked, 0o644)
        ids = self._ids(kgraph.extract_repo_graph(self.root))
        self.assertIn("ast_func:greet-zsh", ids)  # .zsh maps to the bash grammar
        self.assertIn("ast_func:pywfunc", ids)  # .pyw maps to the python grammar
        self.assertNotIn("ast_func:locked", ids)  # unreadable file is skipped
        self.assertIn("ast_func:hello", ids)  # other files still parse
        self.assertNotIn("ast_func:hiddenfunc", ids)  # .hidden/ is ignored

    def test_subdirs_max_files_empty_and_meta(self):
        subdirs = kgraph.extract_repo_graph(self.root, subdirs=["pkg"])
        self.assertIn("ast_func:pkgfunc", self._ids(subdirs))
        self.assertIn("ast_func:deepfunc", self._ids(subdirs))
        self.assertNotIn("ast_func:hello", self._ids(subdirs))
        self.assertEqual(kgraph.extract_repo_graph(self.root, max_files=1)["_meta"]["files_parsed"], 1)
        with tempfile.TemporaryDirectory() as empty:
            result = kgraph.extract_repo_graph(empty)
        self.assertEqual((result["nodes"], result["_meta"]["files_parsed"]), ([], 0))
        full = kgraph.extract_repo_graph(self.root)
        self.assertEqual((full["_meta"]["source"], set(full["_meta"]["languages"])),
                         ("ast", {"python", "bash"}))

    def test_skips_files_whose_grammar_is_not_loaded(self):
        from kgraph import ast_extractor
        with mock.patch.object(ast_extractor, "_LANGUAGES", {"bash": ast_extractor._LANGUAGES["bash"]}):
            ids = self._ids(kgraph.extract_repo_graph(self.root))
        self.assertNotIn("ast_func:hello", ids)  # python grammar dropped
        self.assertIn("ast_func:greet", ids)


class TestAstExtractorWithoutParser(unittest.TestCase):
    def test_node_text_returns_empty_on_decode_failure(self):
        from kgraph import ast_extractor
        fake = type("N", (), {"start_byte": 0, "end_byte": 2})()
        self.assertEqual(ast_extractor._node_text(fake, b"\xff\xfe"), "")

    def test_ast_available_false_without_grammars(self):
        from kgraph import ast_extractor
        with mock.patch.object(ast_extractor, "_LANGUAGES", {}), \
                mock.patch.object(ast_extractor, "_load_grammars", return_value={}):
            self.assertFalse(ast_extractor.ast_available())

    def test_grammar_import_failure_disables_availability(self):
        from kgraph import ast_extractor
        with mock.patch.object(ast_extractor, "_LANGUAGES", {}), \
                mock.patch.object(ast_extractor, "_AST_AVAILABLE", True), \
                mock.patch.dict(sys.modules, {"tree_sitter_bash": None}):
            self.assertFalse(ast_extractor.ast_available())

    def test_extract_repo_graph_without_parser_returns_error(self):
        from kgraph import ast_extractor
        with mock.patch.object(ast_extractor, "_AST_AVAILABLE", False), \
                mock.patch.object(ast_extractor, "_LANGUAGES", {}):
            result = kgraph.extract_repo_graph("/tmp/does-not-exist-kgraph")
        self.assertEqual((result["nodes"], result["_meta"]["error"]), ([], "tree-sitter not available"))

    def test_extraction_helpers_guard_missing_grammars_and_languages(self):
        from kgraph import ast_extractor
        from kgraph.models import GraphBuilder
        builder = GraphBuilder()
        with mock.patch.object(ast_extractor, "_LANGUAGES", {}):
            ast_extractor._extract_bash_defs(None, b"", "a.sh", "f", builder, True)
            ast_extractor._extract_python_defs(None, b"", "a.py", "f", builder, True)
            ast_extractor._extract_calls(None, b"", "python", "a.py", "f", builder)
        self.assertEqual(builder.nodes_list, [])
        with mock.patch.object(ast_extractor, "_LANGUAGES", {"ruby": object()}):
            ast_extractor._extract_calls(None, b"", "ruby", "a.rb", "f", builder)
        self.assertEqual(builder.nodes_list, [])

    def test_link_call_defs_skips_unnamed_call_nodes(self):
        from kgraph import ast_extractor
        from kgraph.models import GraphBuilder
        builder = GraphBuilder()
        builder.add_node({"id": "ast_call:x", "label": "  ", "type": "call"})
        ast_extractor._link_call_defs(builder)
        self.assertFalse(builder.has_edge("ast_call:x", "ast_func:", "calls"))


# ══════════════ mcp_server: JSON-RPC dispatch ══════════════


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
            mcp_server.serve_mcp(host="127.0.0.1", graph_db=self.db)
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
                                      "kgraph_report", "kgraph_stats"})
        self.assertIn("pattern", tools["kgraph_query"]["parameters"])
        self.assertIn("source", tools["kgraph_path"]["parameters"])
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
        self.assertEqual(self._call("kgraph_path", {"source": "a", "target": "zzz"})["result"],
                         {"path_found": False, "edges": []})
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
        status, raw, _ = self._post(None, length=-1)
        self.assertEqual((status, json.loads(raw)), (400, {"error": "Invalid Content-Length"}))
        # A non-numeric length becomes 0, so the empty body cannot be parsed.
        status, raw, _ = self._post("{", length="not-a-number")
        self.assertEqual((status, json.loads(raw)), (400, {"error": "Invalid JSON"}))
        with mock.patch("kgraph.mcp_server.MAX_PAYLOAD_SIZE", 10):
            status, raw, _ = self._post("x" * 100)
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
            last = None

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
                                                       "kgraph-missing.sqlite"))
        self.assertTrue(_InterruptingHTTPServer.last.shutdown_called)
        self.assertIn("MCP server listening on 127.0.0.1:9999", stdout.getvalue())


# ══════════════ cli: graph loading and main() dispatch ══════════════


class _CliHarness(unittest.TestCase):
    """Drives cli.main() directly; no subprocess."""

    def _run(self, argv):
        from kgraph import cli

        stdout, stderr = io.StringIO(), io.StringIO()
        # cli.main() takes no argv and argparse reads sys.argv itself, so the
        # sys.argv *list* is swapped for the duration of the call (restored on
        # exit); nothing else in this process reads argv while it is patched.
        with (mock.patch.object(sys, "argv", argv),
              contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr)):
            try:
                cli.main()
            except SystemExit as exc:
                return exc.code, stdout.getvalue(), stderr.getvalue()
        return 0, stdout.getvalue(), stderr.getvalue()

    def _graph_file(self, td, graph=None):
        path = os.path.join(td, "graph.json")
        with open(path, "w", encoding="utf-8") as f:
            json.dump(_SMALL_GRAPH if graph is None else graph, f)
        return path


class TestCliLoadGraphFallbacks(unittest.TestCase):
    def _args(self, graph=None, graph_db=None, import_db=None):
        import argparse

        from kgraph.cli import _load_graph

        return _load_graph(argparse.Namespace(graph=graph, graph_db=graph_db,
                                             import_db=import_db))

    def test_a_graph_file_wins_and_the_graph_db_is_the_fallback(self):
        with tempfile.TemporaryDirectory() as td:
            path = os.path.join(td, "g.json")
            with open(path, "w", encoding="utf-8") as f:
                json.dump(_AST_GRAPH, f)
            db = os.path.join(td, "graph.sqlite")
            kgraph.save_to_graph_db(db, _SMALL_GRAPH)
            from_file = self._args(graph=path, graph_db=db)
            from_db = self._args(graph_db=db, import_db=os.path.join(td, "no-mem.db"))
        self.assertEqual({n["id"] for n in from_file["nodes"]},
                         {n["id"] for n in _AST_GRAPH["nodes"]})
        self.assertEqual({n["id"] for n in from_db["nodes"]}, {"a", "b", "c"})

    def test_an_empty_graph_db_falls_through_to_the_memory_db(self):
        from kgraph import cli

        with tempfile.TemporaryDirectory() as td:
            db = os.path.join(td, "graph.sqlite")
            kgraph.save_to_graph_db(db, {"nodes": [], "edges": []})
            mem = os.path.join(td, "mem.sqlite")
            with open(mem, "w", encoding="utf-8") as f:
                f.write("")
            with (mock.patch.object(cli, "resolve_memory_db_path", return_value=mem),
                  mock.patch.object(cli, "load_from_memory_db",
                                    return_value=kgraph.Graph.from_dict(_AST_GRAPH))):
                loaded = self._args(graph_db=db, import_db=None)
        self.assertEqual(len(loaded["nodes"]), len(_AST_GRAPH["nodes"]))

    def test_failing_sources_are_logged_and_the_sample_graph_is_used(self):
        from kgraph import cli

        with tempfile.TemporaryDirectory() as td:
            db = os.path.join(td, "graph.sqlite")
            mem = os.path.join(td, "mem.sqlite")
            for path in (db, mem):
                with open(path, "w", encoding="utf-8") as f:
                    f.write("not a sqlite db")
            with (mock.patch.object(cli, "load_from_graph_db", side_effect=OSError("locked")),
                  mock.patch.object(cli, "resolve_memory_db_path", return_value=mem),
                  mock.patch.object(cli, "load_from_memory_db", side_effect=ValueError("bad db")),
                  self.assertLogs("kgraph.cli", level="WARNING") as captured):
                loaded = self._args(graph_db=db, import_db=None)
            self.assertTrue(any("Failed to load graph from graph DB" in m for m in captured.output))
            self.assertTrue(any("Failed to load graph from memory DB" in m for m in captured.output))
            # Nothing exists and nothing is resolvable: the sample graph.
            loaded = self._args(graph_db=os.path.join(td, "missing.sqlite"),
                                import_db=os.path.join(td, "missing-mem.db"))
        self.assertEqual({n["id"] for n in loaded["nodes"]},
                         {n["id"] for n in kgraph.SAMPLE_GRAPH["nodes"]})


class TestCliMainModes(_CliHarness):
    def test_reporting_modes_print_and_write_expected_output(self):
        with tempfile.TemporaryDirectory() as td:
            graph = self._graph_file(td)
            bench, report, html = (os.path.join(td, n) for n in
                                   ("bench.json", "r.md", "flow.html"))
            cases = [
                (["--query", "Alpha"], ["1 matching nodes:", "[topic] Alpha (a)"]),
                (["--query", "zzz-nope"], ['No nodes matching "zzz-nope"']),
                (["--path", "a", "c"], ["Path:", "a → b: project topic [0.9]"]),
                (["--explain", "a"], ["Node: Alpha (a)", "Connections: 1 (1 out, 0 in)"]),
                (["--confidence"], ["Edge confidence:", "INFERRED:  2 (100.0%)"]),
                (["--communities"], ["1 communities:", "Alpha · Beta · Gamma — 3 members"]),
                (["--god-nodes", "--top-god-nodes", "2"], ["Top 2 god nodes:", "Beta"]),
                (["--call-flow"], ["```mermaid"]),
                (["--call-flow", "--output", html], [f"Written to {html}"]),
                (["--benchmark", "--output", bench], ["Token-Reduction Benchmark"]),
                (["--report", "--report-path", report], ["# Knowledge Graph Report"]),
                (["--audit"], ["# Security Audit — kgraph"]),
            ]
            for extra, expected in cases:
                with self.subTest(flag=extra[0]):
                    code, out, _ = self._run(["kgraph", *extra, "--graph", graph])
                    self.assertEqual(code, 0)
                    for want in expected:
                        self.assertIn(want, out)
            self.assertTrue(os.path.exists(html))
            with open(bench, encoding="utf-8") as f:
                self.assertEqual(json.load(f)["node_count"], 3)
            with open(report, encoding="utf-8") as f:
                self.assertIn("- **Edges:** 2", f.read())

    def test_communities_and_god_nodes_edge_cases(self):
        from kgraph import cli

        with tempfile.TemporaryDirectory() as td:
            graph = self._graph_file(td)
            empty = self._graph_file(td, {"nodes": [], "edges": []})
            _, out, _ = self._run(["kgraph", "--communities", "--graph", empty])
            self.assertIn("No communities detected", out)
            _, out, _ = self._run(["kgraph", "--god-nodes", "--graph", empty])
            self.assertIn("No god nodes found", out)
            for flag in ("--communities", "--god-nodes"):
                with mock.patch.object(cli, "communities_available", return_value=False):
                    code, _, err = self._run(["kgraph", flag, "--graph", graph])
                self.assertEqual(code, 1)
                self.assertIn("networkx not available", err)

    def test_audit_reports_a_missing_file(self):
        from kgraph import cli

        # cli's own `os` binding is swapped so the audit file looks absent;
        # os.path.join (which builds the path) still runs for real.
        fake_os = mock.MagicMock(wraps=os)
        fake_os.path.exists.return_value = False
        with mock.patch.object(cli, "os", fake_os):
            _, out, _ = self._run(["kgraph", "--audit"])
        self.assertIn("Security audit report not found at", out)

    def test_pr_dashboard_forwards_options(self):
        with tempfile.TemporaryDirectory() as td:
            graph = self._graph_file(td)
            target = os.path.join(td, "dash.html")
            with mock.patch("kgraph.pr_dashboard.generate_pr_dashboard") as build:
                code, out, _ = self._run([
                    "kgraph", "--pr-dashboard", "--graph", graph, "--output", target,
                    "--days", "7", "--author", "Wayne", "--max-prs", "5"])
            self.assertEqual(code, 0)
            self.assertIn(f"Written to {target}", out)
            kwargs = build.call_args.kwargs
            self.assertEqual((kwargs["output_path"], kwargs["days"], kwargs["author"],
                              kwargs["max_prs"]), (target, 7, "Wayne", 5))
            self.assertEqual(len(kwargs["graph_data"]["nodes"]), 3)

    def test_update_and_watch_forward_their_options(self):
        from kgraph import cli

        with tempfile.TemporaryDirectory() as td:
            db, mem = (os.path.join(td, n) for n in ("graph.sqlite", "mem.sqlite"))
            out_json = os.path.join(td, "updated.json")
            graph = kgraph.Graph.from_dict(_SMALL_GRAPH)
            with mock.patch.object(cli, "incremental_update", return_value=graph) as upd:
                code, out, _ = self._run([
                    "kgraph", "--update", "--graph-db", db, "--import-db", mem,
                    "--source-dir", td, "--ast-vars", "--ast-max-files", "5",
                    "--include-all", "--output", out_json])
            self.assertEqual(code, 0)
            self.assertIn("Update complete: 3 nodes, 2 edges", out)
            self.assertIn("EXTRACTED: 0, INFERRED: 2, AMBIGUOUS: 0", out)
            kwargs = upd.call_args.kwargs
            self.assertEqual((upd.call_args.args[0], kwargs["mem_db_path"], kwargs["source_dir"]),
                             (db, mem, td))
            self.assertTrue((kwargs["ast"], kwargs["ast_vars"], kwargs["include_all"]))
            self.assertEqual(kwargs["ast_max_files"], 5)
            with open(out_json, encoding="utf-8") as f:
                self.assertEqual(len(json.load(f)["nodes"]), 3)
            with mock.patch.object(cli, "incremental_update", return_value=graph) as upd:
                self._run(["kgraph", "--update", "--graph-db", db, "--import-db", mem])
            # No source dir means no AST pass, and no --output means no file.
            self.assertEqual((upd.call_args.kwargs["ast"],
                              upd.call_args.kwargs["source_dir"]), (False, None))
            with mock.patch.object(cli, "start_watch") as watch:
                self.assertEqual(self._run([
                    "kgraph", "--watch", "--graph-db", db, "--import-db", mem,
                    "--source-dir", td, "--watch-interval", "7", "--ast-vars",
                    "--ast-max-files", "3", "--ast-subdirs", "sub"])[0], 0)
            kwargs = watch.call_args.kwargs
            self.assertEqual((watch.call_args.args[0], kwargs["mem_db_path"],
                              kwargs["source_dir"], kwargs["interval"]), (db, mem, td, 7))
            self.assertTrue((kwargs["ast"], kwargs["ast_vars"]))
            self.assertEqual((kwargs["ast_max_files"], kwargs["ast_subdirs"]), (3, ["sub"]))

    def test_mcp_default_and_explicit_port(self):
        with tempfile.TemporaryDirectory() as td:
            with mock.patch("kgraph.mcp_server.serve_mcp") as serve:
                self.assertEqual(self._run(["kgraph", "--mcp"])[0], 0)
            self.assertEqual((serve.call_args.kwargs["port"], serve.call_args.kwargs["graph_db"]),
                             (8331, kgraph.GRAPH_DB_DEFAULT))
            with mock.patch("kgraph.mcp_server.serve_mcp") as serve:
                self._run(["kgraph", "--mcp", "--host", "0.0.0.0", "--port", "9000",
                           "--graph-db", os.path.join(td, "g.sqlite")])
        self.assertEqual((serve.call_args.kwargs["host"], serve.call_args.kwargs["port"],
                          serve.call_args.kwargs["graph_db"]),
                         ("0.0.0.0", 9000, os.path.join(td, "g.sqlite")))

    def test_ast_errors_and_a_real_extraction(self):
        from kgraph import cli

        code, _, err = self._run(["kgraph", "--ast"])
        self.assertEqual(code, 1)
        self.assertIn("--repo is required for AST extraction", err)
        with tempfile.TemporaryDirectory() as td:
            with mock.patch.object(cli, "ast_available", return_value=False):
                code, _, err = self._run(["kgraph", "--ast", "--repo", td])
            self.assertEqual((code, "tree-sitter not available" in err), (1, True))
            os.makedirs(os.path.join(td, "parser"))
            with open(os.path.join(td, "parser", "mod.py"), "w", encoding="utf-8") as f:
                f.write("def hello():\n    print('hi')\n")
            with open(os.path.join(td, "other.py"), "w", encoding="utf-8") as f:
                f.write("def other():\n    pass\n")
            _, out, _ = self._run(["kgraph", "--ast", "--repo", td])
            self.assertIn('"ast_func:hello"', out)
            target = os.path.join(td, "ast.json")
            _, out, _ = self._run(["kgraph", "--ast", "--repo", td, "--ast-vars",
                                   "--ast-max-files", "5", "--ast-subdirs", "parser",
                                   "--output", target])
            self.assertIn(f"Saved to {target}", out)
            with open(target, encoding="utf-8") as f:
                ids = {n["id"] for n in json.load(f)["nodes"]}
        self.assertIn("ast_func:hello", ids)
        self.assertNotIn("ast_func:other", ids)  # --ast-subdirs restricted the scan

    def test_wiring_errors_summary_and_show_all(self):
        from kgraph import wiring

        code, _, err = self._run(["kgraph", "--wiring"])
        self.assertEqual((code, "--repo is required" in err), (1, True))
        with tempfile.TemporaryDirectory() as td:
            with open(os.path.join(td, "mod.py"), "w", encoding="utf-8") as f:
                f.write("x = 1\n")
            _, out, _ = self._run(["kgraph", "--wiring", "--repo", td])
            self.assertIn("Wiring analysis:", out)
            self.assertIn("'orphans': 1", out)
            with mock.patch.object(wiring, "format_wiring_report",
                                   return_value="FULL REPORT") as fmt:
                _, out, _ = self._run(["kgraph", "--wiring", "--repo", td, "--wiring-all"])
        self.assertIn("FULL REPORT", out)
        self.assertTrue(fmt.call_args.kwargs["show_all"])

    def test_default_mode_writes_html_and_serve_flag_serves_it(self):
        from kgraph import cli

        with tempfile.TemporaryDirectory() as td:
            graph = self._graph_file(td)
            target = os.path.join(td, "out.html")
            code, out, _ = self._run(["kgraph", "--graph", graph, "--output", target])
            self.assertEqual((code, out.splitlines()[0]), (0, f"Wrote {target}"))
            self.assertIn("usage: kgraph", out)
            with mock.patch.object(cli, "serve_file") as serve:
                code, out, _ = self._run([
                    "kgraph", "--graph", graph, "--output", target, "--serve",
                    "--host", "0.0.0.0", "--port", "8123", "--store",
                    os.path.join(td, "store.json"), "--embed", "--view", "topics",
                    "--semantic-threshold", "0.5"])
            self.assertEqual(code, 0)
            self.assertNotIn("usage: kgraph", out)
            kwargs = serve.call_args.kwargs
            self.assertEqual(serve.call_args.args[0], target)
            self.assertEqual((kwargs["host"], kwargs["port"], kwargs["store_path"]),
                             ("0.0.0.0", 8123, os.path.join(td, "store.json")))
            self.assertTrue(kwargs["force_embed"])
            self.assertEqual((kwargs["view_mode"], kwargs["semantic_threshold"]), ("topics", 0.5))
            self.assertEqual(kwargs["graph_db_path"], os.path.expanduser(kgraph.GRAPH_DB_DEFAULT))


class TestCliGitHooks(_CliHarness):
    def _hooks_dir(self, td):
        hooks = os.path.join(td, "hooks")
        os.makedirs(hooks)
        return hooks

    def test_install_writes_executable_hooks_and_respects_existing_ones(self):
        from kgraph import cli

        with tempfile.TemporaryDirectory() as td:
            hooks = self._hooks_dir(td)
            with mock.patch.object(cli, "_find_git_hooks_dir", return_value=hooks):
                code, out, err = self._run(["kgraph", "--install-hook"])
                self.assertEqual((code, err), (0, ""))
                self.assertIn(f"Installed post-commit hook in {hooks}", out)
                for name in ("post-commit", "post-merge"):
                    path = os.path.join(hooks, name)
                    self.assertEqual(os.stat(path).st_mode & 0o777, 0o755)
                    with open(path, encoding="utf-8") as f:
                        content = f.read()
                    self.assertIn("kgraph auto-rebuild", content)
                    self.assertIn("kgraph --update --source-dir", content)
                # A pre-existing kgraph hook is rewritten, not refused.
                self.assertNotIn("not installed by kgraph",
                                 self._run(["kgraph", "--install-hook"])[2])

            foreign = os.path.join(hooks, "post-commit")
            with open(foreign, "w", encoding="utf-8") as f:
                f.write("#!/bin/bash\n# husky\n")
            os.remove(os.path.join(hooks, "post-merge"))
            os.makedirs(os.path.join(hooks, "post-merge"))  # unreadable (a dir)
            with mock.patch.object(cli, "_find_git_hooks_dir", return_value=hooks):
                code, _, err = self._run(["kgraph", "--install-hook"])
            self.assertEqual(code, 0)
            with open(foreign, encoding="utf-8") as f:
                self.assertEqual(f.read(), "#!/bin/bash\n# husky\n")
            self.assertIn("existing hook was not installed by kgraph", err)
            self.assertIn("cannot read existing hook", err)
            self.assertTrue(os.path.isdir(os.path.join(hooks, "post-merge")))

    def test_uninstall_removes_only_its_own_hooks(self):
        from kgraph import cli

        with tempfile.TemporaryDirectory() as td:
            hooks = self._hooks_dir(td)
            ours, theirs = (os.path.join(hooks, n) for n in ("post-commit", "post-merge"))
            with open(ours, "w", encoding="utf-8") as f:
                f.write("#!/bin/bash\n# kgraph auto-rebuild\n")
            with open(theirs, "w", encoding="utf-8") as f:
                f.write("#!/bin/bash\n# husky\n")
            with mock.patch.object(cli, "_find_git_hooks_dir", return_value=hooks):
                code, out, err = self._run(["kgraph", "--uninstall-hook"])
            self.assertEqual(code, 0)
            self.assertEqual((os.path.exists(ours), os.path.exists(theirs)), (False, True))
            self.assertIn(f"Removed {ours}", out)
            self.assertIn("not a kgraph hook", err)

        with tempfile.TemporaryDirectory() as td:
            hooks = self._hooks_dir(td)
            unreadable = os.path.join(hooks, "post-commit")
            os.makedirs(unreadable)
            with mock.patch.object(cli, "_find_git_hooks_dir", return_value=hooks):
                code, _, err = self._run(["kgraph", "--uninstall-hook"])
            self.assertEqual((code, "cannot read hook" in err, os.path.isdir(unreadable)),
                             (0, True, True))

    def test_hook_commands_exit_when_not_in_a_git_repo(self):
        from kgraph import cli

        for flag in ("--install-hook", "--uninstall-hook"):
            with mock.patch.object(cli, "_find_git_hooks_dir", return_value=None):
                code, _, err = self._run(["kgraph", flag])
            self.assertEqual(code, 1)
            self.assertIn("not in a git repository", err)


class TestCliFindGitHooksDir(unittest.TestCase):
    def setUp(self):
        self._cwd = os.getcwd()
        self.addCleanup(os.chdir, self._cwd)

    def test_walks_up_to_the_git_hooks_directory_and_none_without_one(self):
        from kgraph.cli import _find_git_hooks_dir

        with tempfile.TemporaryDirectory() as td:
            hooks = os.path.join(td, ".git", "hooks")
            nested = os.path.join(td, "a", "b")
            os.makedirs(hooks)
            os.makedirs(nested)
            os.chdir(nested)
            self.assertEqual(_find_git_hooks_dir(), hooks)
        with tempfile.TemporaryDirectory() as td:
            os.chdir(td)
            self.assertIsNone(_find_git_hooks_dir())

    def test_core_hooks_path_wins_over_the_git_dir(self):
        """A repo that tracks its hooks sets core.hooksPath, and git then
        ignores .git/hooks — so a hook installed there would never run."""
        from kgraph.cli import _find_git_hooks_dir

        with tempfile.TemporaryDirectory() as td:
            repo = os.path.join(td, "repo")
            os.makedirs(repo)
            subprocess.run(["git", "-C", repo, "init", "-q"], check=True, capture_output=True)
            tracked = os.path.join(td, "tracked-hooks")
            os.makedirs(tracked)
            subprocess.run(["git", "-C", repo, "config", "core.hooksPath", tracked],
                           check=True, capture_output=True)
            os.chdir(repo)
            self.assertEqual(_find_git_hooks_dir(), tracked)

    def test_relative_core_hooks_path_resolves_against_the_repo(self):
        """git accepts a relative core.hooksPath; it must not be read as a
        path relative to whatever directory the process happens to be in."""
        from kgraph.cli import _find_git_hooks_dir

        with tempfile.TemporaryDirectory() as td:
            repo = os.path.join(td, "repo")
            os.makedirs(repo)
            subprocess.run(["git", "-C", repo, "init", "-q"], check=True, capture_output=True)
            subprocess.run(["git", "-C", repo, "config", "core.hooksPath", "tools/hooks"],
                           check=True, capture_output=True)
            os.chdir(repo)
            self.assertEqual(_find_git_hooks_dir(), os.path.join(repo, "tools", "hooks"))


class TestKgrapModuleEntryPoint(unittest.TestCase):
    """`python -m kgraph` — the __main__.py shim into cli.main()."""

    def test_module_entry_point_prints_usage(self):
        # __main__.py is only reachable in a subprocess, so coverage cannot
        # attribute it in-process; this proves the entry point at least works.
        env = dict(os.environ, PYTHONPATH=os.path.join(REPO_ROOT, "scripts"))
        proc = subprocess.run([sys.executable, "-m", "kgraph", "--help"],
                              capture_output=True, text=True, env=env, cwd=REPO_ROOT)
        self.assertEqual(proc.returncode, 0)
        self.assertIn("usage: kgraph", proc.stdout)


if __name__ == "__main__":
    unittest.main()