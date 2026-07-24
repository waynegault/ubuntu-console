"""Tests for previously untested kgraph modules.

Covers: call_flow, update, life_index, benchmark, mcp_server, pr_dashboard.
"""

import json
import os
import sys
import tempfile
import unittest

REPO_ROOT = os.path.dirname(os.path.dirname(__file__))
SCRIPT_DIR = os.path.join(REPO_ROOT, "scripts")
sys.path.insert(0, SCRIPT_DIR)

import kgraph  # noqa: E402


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

    def test_load_relations_missing_file(self):
        rels = kgraph.load_relations("/tmp/nonexistent-life-dir")
        self.assertEqual(rels["relations"], [])

    def test_merge_relations_no_relations(self):
        graph = kgraph.merge_relations(_SMALL_GRAPH, life_root="/tmp/nonexistent")
        # Should return unchanged (as Graph model)
        self.assertEqual(len(graph.edges), 2)


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
    def test_sanitize_label_strips_html(self):
        self.assertEqual(kgraph.sanitize_label("<b>bold</b>"), "bold")

    def test_sanitize_label_strips_xss(self):
        result = kgraph.sanitize_label('<script>alert(1)</script>')
        self.assertNotIn("script", result.lower())

    def test_sanitize_label_truncates(self):
        long = "x" * 600
        self.assertLessEqual(len(kgraph.sanitize_label(long)), 500)

    def test_sanitize_label_empty(self):
        self.assertEqual(kgraph.sanitize_label(""), "")

    def test_validate_graph_valid_payload_returns_true(self):
        errors = kgraph.validate_graph_payload(_SMALL_GRAPH)
        self.assertTrue(errors[0])

    def test_validate_graph_payload_too_large(self):
        valid, msg = kgraph.validate_graph_payload(b"x" * (101 * 1024 * 1024))
        self.assertFalse(valid)
        self.assertIn("too large", msg.lower())


if __name__ == "__main__":
    unittest.main()