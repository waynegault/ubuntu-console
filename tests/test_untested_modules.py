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

    def test_canonical_loader_hook_is_used_when_available(self):
        # constants.load_canonical_data is None today, so the file is read
        # directly; the hook branch must still work when one is supplied.
        payload = {"records": [{"slug": "gamma", "title": "Gamma", "type": "system"}]}
        with tempfile.TemporaryDirectory() as td:
            self._write(os.path.join(td, "canonical-concepts.json"), "{}")
            with mock.patch("kgraph.life_index.load_canonical_data",
                            return_value=payload) as loader:
                index = kgraph.load_life_index(td)
            loader.assert_called_once()
            self.assertEqual(index["by_slug"]["gamma"]["type"], "system")

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


if __name__ == "__main__":
    unittest.main()