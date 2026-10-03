"""Tests for kgraph.benchmark — token-reduction figures and rendering."""

import json
import os
import tempfile
import unittest

from _kgraph_fixtures import _SMALL_GRAPH
import kgraph


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

    def test_format_benchmark_renders_the_measured_figures(self):
        """The rendered report carries the header and the computed counts.

        Catches: format_benchmark dropping a figure (or formatting the wrong
        field) so `kgraph benchmark` reports a number that is not the one the
        benchmark computed.  _SMALL_GRAPH is 3 nodes / 2 edges, so the two
        counts below are the values len(result[...]) produces.
        """
        result = kgraph.benchmark_graph_vs_raw(_SMALL_GRAPH)
        self.assertEqual(result["node_count"], 3)
        self.assertEqual(result["edge_count"], 2)
        text = kgraph.format_benchmark(result)
        self.assertIn("=== Token-Reduction Benchmark ===", text)
        self.assertIn("Graph nodes: 3", text)
        self.assertIn("Graph edges: 2", text)
        self.assertIn(f'Avg tokens/node: {result["avg_tokens_per_node"]}', text)


if __name__ == "__main__":
    unittest.main()
