"""Tests for kgraph.call_flow — Mermaid and HTML call-flow rendering."""

import unittest

from _kgraph_fixtures import _AST_GRAPH
import kgraph


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


if __name__ == "__main__":
    unittest.main()
