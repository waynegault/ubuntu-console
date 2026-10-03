"""Tests for kgraph.report — summary/section rendering and HTML escaping."""

import contextlib
import io
import os
import tempfile
import unittest

from _kgraph_fixtures import _SMALL_GRAPH
import kgraph


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
            # The library returns data and never prints; the CLI (cmd_report)
            # owns the user-facing "Wrote" line.
            self.assertNotIn("Wrote", stdout.getvalue())

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


if __name__ == "__main__":
    unittest.main()
