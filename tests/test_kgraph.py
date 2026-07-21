import os
import subprocess
import sys
import tempfile
import unittest


REPO_ROOT = os.path.dirname(os.path.dirname(__file__))
SCRIPT_DIR = os.path.join(REPO_ROOT, 'scripts')
# Import the kgraph package directly; the backward-compatibility shim
# (scripts/kgraph.py) was removed during cleanup.
sys.path.insert(0, SCRIPT_DIR)
import kgraph  # noqa: E402


def load_kgraph_module():
    return kgraph


class KGraphTests(unittest.TestCase):
    def test_generate_html_contains_cytoscape_markup(self):
        with tempfile.TemporaryDirectory() as td:
            out = os.path.join(td, 'nested', 'kgraph.html')
            subprocess.run([sys.executable, '-m', 'kgraph', '--output', out], check=True, cwd=SCRIPT_DIR)

            self.assertTrue(os.path.exists(out), 'Output HTML not created')
            with open(out, 'r', encoding='utf-8') as handle:
                text = handle.read()

            self.assertIn('cytoscape', text.lower())
            self.assertIn('Knowledge Graph (Cytoscape)', text)

    def test_resolve_serve_target_respects_embed_flag(self):
        kgraph = load_kgraph_module()

        with tempfile.TemporaryDirectory() as td:
            out = os.path.join(td, 'kgraph.html')
            serve_dir, filename, using_built_frontend = kgraph.resolve_serve_target(out, force_embed=True)

            self.assertEqual(serve_dir, os.path.abspath(td))
            self.assertEqual(filename, 'kgraph.html')
            self.assertFalse(using_built_frontend)

    def test_graph_db_round_trip_preserves_extra_payload(self):
        kgraph = load_kgraph_module()

        graph = {
            'nodes': [
                {'id': 'n1', 'label': 'Node 1', 'type': 'topic', 'content_preview': 'preview'},
            ],
            'edges': [
                {'from': 'n1', 'to': 'n2', 'label': 'relates to', 'semantic_score': 0.82},
            ],
        }

        with tempfile.TemporaryDirectory() as td:
            db_path = os.path.join(td, 'graph.sqlite')
            kgraph.save_to_graph_db(db_path, graph)
            loaded = kgraph.load_from_graph_db(db_path)

        self.assertEqual(loaded['nodes'][0]['id'], 'n1')
        self.assertEqual(loaded['nodes'][0]['type'], 'topic')
        self.assertEqual(loaded['edges'][0]['from'], 'n1')
        self.assertEqual(loaded['edges'][0]['semantic_score'], 0.82)

    def test_graph_db_round_trip_supports_basename_path(self):
        kgraph = load_kgraph_module()

        graph = {
            'nodes': [{'id': 'n1', 'label': 'Node 1'}],
            'edges': [{'from': 'n1', 'to': 'n2', 'label': 'links'}],
        }

        with tempfile.TemporaryDirectory() as td:
            old_cwd = os.getcwd()
            os.chdir(td)
            try:
                kgraph.save_to_graph_db('graph.sqlite', graph)
                loaded = kgraph.load_from_graph_db('graph.sqlite')
            finally:
                os.chdir(old_cwd)

        self.assertEqual(loaded['nodes'][0]['id'], 'n1')
        self.assertEqual(loaded['edges'][0]['label'], 'links')

    def test_install_flag_is_not_supported(self):
        # The legacy --install flag was a backward-compatibility shim feature
        # and is no longer supported. The package CLI should reject it.
        with tempfile.TemporaryDirectory() as td:
            out = os.path.join(td, 'kgraph.py')
            result = subprocess.run(
                [sys.executable, '-m', 'kgraph', '--install', out],
                cwd=SCRIPT_DIR,
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(os.path.exists(out))

    def test_project_graph_overview_hides_chunks_and_remaps_edges(self):
        kgraph = load_kgraph_module()
        graph = {
            'nodes': [
                {'id': 'file:a', 'label': 'A.md', 'type': 'file'},
                {'id': 'chunk:1', 'label': 'chunk', 'type': 'chunk'},
                {'id': 'topic:x', 'label': 'Topic X', 'type': 'topic'},
            ],
            'edges': [
                {'from': 'file:a', 'to': 'chunk:1', 'label': 'contains chunk'},
                {'from': 'chunk:1', 'to': 'topic:x', 'label': 'covers topic'},
            ],
        }
        projected = kgraph.project_graph(graph, mode='overview')
        node_ids = {n['id'] for n in projected['nodes']}
        self.assertIn('file:a', node_ids)
        self.assertIn('topic:x', node_ids)
        self.assertNotIn('chunk:1', node_ids)
        self.assertEqual(projected['edges'][0]['label'], 'file covers topic')

    def test_project_graph_semantic_filters_by_threshold(self):
        kgraph = load_kgraph_module()
        graph = {
            'nodes': [
                {'id': 'chunk:a', 'label': 'A', 'type': 'chunk'},
                {'id': 'chunk:b', 'label': 'B', 'type': 'chunk'},
                {'id': 'chunk:c', 'label': 'C', 'type': 'chunk'},
            ],
            'edges': [
                {'from': 'chunk:a', 'to': 'chunk:b', 'label': 'related (0.90)', 'semantic_score': 0.90},
                {'from': 'chunk:a', 'to': 'chunk:c', 'label': 'related (0.78)', 'semantic_score': 0.78},
            ],
        }
        projected = kgraph.project_graph(graph, mode='semantic', semantic_threshold=0.85)
        self.assertEqual(len(projected['edges']), 1)
        self.assertEqual(projected['edges'][0]['to'], 'chunk:b')


class TestConfidence(unittest.TestCase):
    """Tests for kgraph.confidence — tag_confidence / confidence_stats."""

    def setUp(self):
        self.kgraph = load_kgraph_module()

    def test_tag_confidence_extracted_ast_edges(self):
        graph = {
            'edges': [
                {'from': 'mod.py', 'to': 'os', 'label': 'imports', 'source': 'ast'},
                {'from': 'mod.py', 'to': 'func', 'label': 'defines'},
            ],
        }
        result = self.kgraph.tag_confidence(graph)
        for e in result['edges']:
            self.assertEqual(e['confidence'], 'EXTRACTED')

    def test_tag_confidence_inferred_semantic_edges(self):
        graph = {
            'edges': [
                {'from': 'a', 'to': 'b', 'semantic_score': 0.82},
                {'from': 'c', 'to': 'd', 'semantic_score': 0.91},
            ],
        }
        result = self.kgraph.tag_confidence(graph)
        for e in result['edges']:
            self.assertEqual(e['confidence'], 'INFERRED')

    def test_tag_confidence_ambiguous_low_semantic(self):
        graph = {
            'edges': [
                {'from': 'a', 'to': 'b', 'semantic_score': 0.42},
                {'from': 'c', 'to': 'd', 'semantic_score': 0.30},
            ],
        }
        result = self.kgraph.tag_confidence(graph)
        for e in result['edges']:
            self.assertEqual(e['confidence'], 'AMBIGUOUS')

    def test_tag_confidence_explicit_flag(self):
        graph = {
            'edges': [
                {'from': 'a', 'to': 'b', 'label': 'whatever', 'explicit': True},
            ],
        }
        result = self.kgraph.tag_confidence(graph)
        self.assertEqual(result['edges'][0]['confidence'], 'EXTRACTED')

    def test_tag_confidence_inferred_flag(self):
        graph = {
            'edges': [
                {'from': 'a', 'to': 'b', 'label': 'related concept', 'inferred': True},
            ],
        }
        result = self.kgraph.tag_confidence(graph)
        self.assertEqual(result['edges'][0]['confidence'], 'INFERRED')

    def test_tag_confidence_cooccurrence_threshold(self):
        graph = {
            'edges': [
                {'from': 'a', 'to': 'b', 'cooccurrence_count': 5},
                {'from': 'c', 'to': 'd', 'cooccurrence_count': 1},
            ],
        }
        result = self.kgraph.tag_confidence(graph)
        self.assertEqual(result['edges'][0]['confidence'], 'INFERRED')
        self.assertEqual(result['edges'][1]['confidence'], 'AMBIGUOUS')

    def test_tag_confidence_ambiguous_fallback_related_label(self):
        graph = {
            'edges': [
                {'from': 'a', 'to': 'b', 'label': 'related concept'},
            ],
        }
        result = self.kgraph.tag_confidence(graph)
        self.assertEqual(result['edges'][0]['confidence'], 'AMBIGUOUS')

    def test_tag_confidence_preserves_existing_fields(self):
        graph = {
            'nodes': [{'id': 'a', 'label': 'A'}],
            'edges': [{'from': 'a', 'to': 'b', 'label': 'imports', 'source': 'ast', 'extra': 'keep'}],
        }
        result = self.kgraph.tag_confidence(graph)
        self.assertEqual(result['nodes'][0]['label'], 'A')
        self.assertEqual(result['edges'][0]['extra'], 'keep')
        self.assertEqual(result['edges'][0]['confidence'], 'EXTRACTED')

    def test_confidence_stats_empty_graph(self):
        stats = self.kgraph.confidence_stats({'edges': []})
        self.assertEqual(stats['total'], 0)
        self.assertEqual(stats['extracted'], 0)
        self.assertEqual(stats['extracted_pct'], 0)

    def test_confidence_stats_counts(self):
        graph = {
            'edges': [
                {'from': 'a', 'to': 'b', 'source': 'ast', 'label': 'calls'},
                {'from': 'c', 'to': 'd', 'semantic_score': 0.91},
                {'from': 'e', 'to': 'f', 'semantic_score': 0.30},
            ],
        }
        self.kgraph.tag_confidence(graph)
        stats = self.kgraph.confidence_stats(graph)
        self.assertEqual(stats['total'], 3)
        self.assertEqual(stats['extracted'], 1)
        self.assertEqual(stats['inferred'], 1)
        self.assertEqual(stats['ambiguous'], 1)
        self.assertEqual(stats['extracted_pct'], 33.3)
        self.assertEqual(stats['inferred_pct'], 33.3)
        self.assertEqual(stats['ambiguous_pct'], 33.3)

    def test_confidence_stats_before_tagging(self):
        """confidence_stats calls _determine_confidence for untagged edges."""
        graph = {
            'edges': [
                {'from': 'a', 'to': 'b', 'source': 'ast', 'label': 'imports'},
                {'from': 'c', 'to': 'd', 'semantic_score': 0.99},
            ],
        }
        stats = self.kgraph.confidence_stats(graph)
        self.assertEqual(stats['extracted'], 1)
        self.assertEqual(stats['inferred'], 1)


class TestQuery(unittest.TestCase):
    """Tests for kgraph.query — query_nodes / find_path / explain_node / format_*."""

    def setUp(self):
        self.kgraph = load_kgraph_module()
        self.small_graph = {
            'nodes': [
                {'id': 'n1', 'label': 'Authentication', 'type': 'topic'},
                {'id': 'n2', 'label': 'Login Flow', 'type': 'topic'},
                {'id': 'n3', 'label': 'JWT Token', 'type': 'concept'},
                {'id': 'n4', 'label': 'Database', 'type': 'topic'},
            ],
            'edges': [
                {'from': 'n1', 'to': 'n2', 'label': 'depends on'},
                {'from': 'n2', 'to': 'n3', 'label': 'uses'},
                {'from': 'n1', 'to': 'n3', 'label': 'produces'},
            ],
        }

    # ── query_nodes ────────────────────────────────────────────────

    def test_query_nodes_by_label_substring(self):
        results = self.kgraph.query_nodes(self.small_graph, 'auth')
        self.assertEqual(len(results), 1)
        self.assertEqual(results[0]['id'], 'n1')

    def test_query_nodes_by_type(self):
        results = self.kgraph.query_nodes(self.small_graph, 'concept', match_type='type')
        self.assertEqual(len(results), 1)
        self.assertEqual(results[0]['id'], 'n3')

    def test_query_nodes_case_insensitive(self):
        results = self.kgraph.query_nodes(self.small_graph, 'jwt')
        self.assertEqual(len(results), 1)
        self.assertEqual(results[0]['id'], 'n3')

    def test_query_nodes_no_match(self):
        results = self.kgraph.query_nodes(self.small_graph, 'zzzznotfound')
        self.assertEqual(results, [])

    def test_query_nodes_max_results(self):
        graph = {
            'nodes': [{'id': f'n{i}', 'label': 'Alpha'} for i in range(10)],
        }
        results = self.kgraph.query_nodes(graph, 'alpha', max_results=3)
        self.assertEqual(len(results), 3)

    def test_query_nodes_deduplicates(self):
        graph = {
            'nodes': [
                {'id': 'x', 'label': 'X', 'type': 'topic'},
            ],
        }
        # Searching 'any' by label AND type should return the node once
        results = self.kgraph.query_nodes(graph, 'x', match_type='any')
        self.assertEqual(len(results), 1)

    # ── find_path ───────────────────────────────────────────────────

    def test_find_path_direct_edge(self):
        path = self.kgraph.find_path(self.small_graph, 'n1', 'n2')
        self.assertEqual(len(path), 1)
        self.assertEqual(path[0]['label'], 'depends on')

    def test_find_path_multi_hop(self):
        path = self.kgraph.find_path(self.small_graph, 'n1', 'n3')
        # Two possible paths: n1→n3 (direct) is shorter — BFS
        self.assertEqual(len(path), 1)
        self.assertEqual(path[0]['label'], 'produces')

    def test_find_path_no_path_exists(self):
        graph = {
            'nodes': [{'id': 'a'}, {'id': 'b'}],
            'edges': [],
        }
        path = self.kgraph.find_path(graph, 'a', 'b')
        self.assertEqual(path, [])

    def test_find_path_no_such_node(self):
        path = self.kgraph.find_path(self.small_graph, 'n1', 'nonexistent')
        self.assertEqual(path, [])

    def test_find_path_by_label(self):
        path = self.kgraph.find_path(self.small_graph, 'Authentication', 'JWT Token')
        self.assertGreater(len(path), 0)

    def test_find_path_max_depth_limit(self):
        # Longer graph: a → b → c → d → e (single chain)
        graph = {
            'nodes': [{'id': f'n{i}'} for i in range(5)],
            'edges': [{'from': f'n{i}', 'to': f'n{i+1}', 'label': 'next'}
                      for i in range(4)],
        }
        # max_depth=1 should prevent reaching n4 from n0
        path = self.kgraph.find_path(graph, 'n0', 'n4', max_depth=1)
        self.assertEqual(path, [])

        # max_depth=10 should find the path
        path = self.kgraph.find_path(graph, 'n0', 'n4', max_depth=10)
        self.assertEqual(len(path), 4)

    # ── explain_node ────────────────────────────────────────────────

    def test_explain_node_by_id(self):
        expl = self.kgraph.explain_node(self.small_graph, 'n1')
        self.assertEqual(expl['node']['id'], 'n1')
        self.assertEqual(expl['node']['label'], 'Authentication')

    def test_explain_node_by_label_substring(self):
        expl = self.kgraph.explain_node(self.small_graph, 'Login')
        self.assertEqual(expl['node']['id'], 'n2')

    def test_explain_node_not_found(self):
        expl = self.kgraph.explain_node(self.small_graph, 'Zork')
        self.assertIn('error', expl)

    def test_explain_node_connection_counts(self):
        expl = self.kgraph.explain_node(self.small_graph, 'n1')
        # n1 → n2 (depends on), n1 → n3 (produces) = 2 outbound, 0 inbound
        self.assertEqual(expl['outbound_count'], 2)
        self.assertEqual(expl['inbound_count'], 0)
        self.assertEqual(expl['total_connections'], 2)

    def test_explain_node_inbound_connections(self):
        expl = self.kgraph.explain_node(self.small_graph, 'n3')
        # inbound edges appear in edge-list order:
        #   n2 → n3 (uses)  → source_label = 'Login Flow'
        #   n1 → n3 (produces) → source_label = 'Authentication'
        self.assertEqual(expl['outbound_count'], 0)
        self.assertEqual(expl['inbound_count'], 2)
        source_labels = {c['source_label'] for c in expl['inbound_connections']}
        self.assertIn('Authentication', source_labels)
        self.assertIn('Login Flow', source_labels)

    # ── format_explain ──────────────────────────────────────────────

    def test_format_explain(self):
        expl = self.kgraph.explain_node(self.small_graph, 'n1')
        text = self.kgraph.format_explain(expl)
        self.assertIn('Authentication', text)
        self.assertIn('n1', text)
        self.assertIn('Outbound:', text)
        self.assertIn('Login Flow', text)

    def test_format_explain_error(self):
        text = self.kgraph.format_explain({'error': 'Node "Zork" not found'})
        self.assertIn('Error:', text)
        self.assertIn('Zork', text)

    # ── format_path ─────────────────────────────────────────────────

    def test_format_path_found(self):
        path = self.kgraph.find_path(self.small_graph, 'n1', 'n2')
        text = self.kgraph.format_path(path)
        self.assertIn('Path:', text)
        self.assertIn('n1', text)
        self.assertIn('n2', text)
        self.assertIn('depends on', text)

    def test_format_path_empty(self):
        text = self.kgraph.format_path([])
        self.assertEqual(text, 'No path found')


if __name__ == '__main__':
    unittest.main()
