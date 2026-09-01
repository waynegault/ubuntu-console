import os
import sqlite3
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

        self.assertEqual(loaded.nodes[0].id, 'n1')
        self.assertEqual(loaded.nodes[0].type, 'topic')
        self.assertEqual(loaded.edges[0].source, 'n1')
        self.assertEqual(loaded.edges[0].semantic_score, 0.82)

    def test_prune_ast_nodes_drops_stale_ast_and_keeps_user_nodes(self):
        """prune_ast_nodes removes ast_* nodes/edges but keeps user data."""
        kgraph = load_kgraph_module()
        graph = kgraph.Graph.from_dict({
            'nodes': [
                {'id': 'ast_file:scripts-03-design-tokens-sh', 'label': '03-design-tokens.sh', 'type': 'file'},
                {'id': 'ast_file:scripts_03_design_tokens_sh', 'label': '03-design-tokens.sh', 'type': 'file'},
                {'id': 'ast_func:hello', 'label': 'hello', 'type': 'function'},
                {'id': 'memory:keep', 'label': 'keep', 'type': 'memory'},
                {'id': 'plain', 'label': 'plain'},
            ],
            'edges': [
                {'from': 'ast_file:scripts-03-design-tokens-sh', 'to': 'ast_func:hello', 'label': 'defines'},
                {'from': 'ast_func:hello', 'to': 'memory:keep', 'label': 'calls'},
                {'from': 'memory:keep', 'to': 'plain', 'label': 'relates'},
            ],
        })
        graph.prune_ast_nodes()
        ids = graph.node_ids()
        self.assertNotIn('ast_file:scripts-03-design-tokens-sh', ids)
        self.assertNotIn('ast_file:scripts_03_design_tokens_sh', ids)
        self.assertNotIn('ast_func:hello', ids)
        self.assertIn('memory:keep', ids)
        self.assertIn('plain', ids)
        # edges incident to AST nodes are dropped; user edges survive
        edge_pairs = {(e.source, e.target) for e in graph.edges}
        self.assertNotIn(('ast_file:scripts-03-design-tokens-sh', 'ast_func:hello'), edge_pairs)
        self.assertNotIn(('ast_func:hello', 'memory:keep'), edge_pairs)
        self.assertIn(('memory:keep', 'plain'), edge_pairs)

    def test_incremental_update_prunes_stale_ast_nodes(self):
        """a rebuild drops stale ast_* nodes and re-derives them from source."""
        kgraph = load_kgraph_module()
        with tempfile.TemporaryDirectory() as td:
            src = os.path.join(td, 'repo')
            os.makedirs(src)
            with open(os.path.join(src, 'main.sh'), 'w', encoding='utf-8') as f:
                f.write('function hello() { echo hi; }\n')
            db_path = os.path.join(td, 'graph.sqlite')
            kgraph.save_to_graph_db(db_path, {
                'nodes': [
                    {'id': 'ast_file:stale', 'label': 'stale.sh', 'type': 'file',
                     'path': '/gone/stale.sh', 'rel_path': 'stale.sh'},
                    {'id': 'memory:keep', 'label': 'keep', 'type': 'memory'},
                ],
                'edges': [
                    {'from': 'ast_file:stale', 'to': 'memory:keep', 'label': 'calls'},
                ],
            })
            from kgraph.update import incremental_update
            incremental_update(
                db_path,
                mem_db_path=os.path.join(td, 'missing.sqlite'),
                source_dir=src,
                ast=True,
                include_all=True,
            )
            loaded = kgraph.load_from_graph_db(db_path)
            ids = loaded.node_ids()
            self.assertNotIn('ast_file:stale', ids)
            self.assertIn('memory:keep', ids)
            # fresh AST from the temp repo is present
            self.assertTrue(
                any(i.startswith('ast_file:') for i in ids),
                f'no fresh ast nodes in {sorted(ids)}',
            )
            edge_pairs = {(e.source, e.target) for e in loaded.edges}
            self.assertNotIn(('ast_file:stale', 'memory:keep'), edge_pairs)

    def test_ast_call_links_to_function_definition(self):
        """call nodes resolve to their function definitions ('who calls X')."""
        kgraph = load_kgraph_module()
        with tempfile.TemporaryDirectory() as td:
            src = os.path.join(td, 'repo')
            os.makedirs(src)
            with open(os.path.join(src, 'lib.sh'), 'w', encoding='utf-8') as f:
                f.write('function helper() { echo hi; }\n')
            with open(os.path.join(src, 'main.sh'), 'w', encoding='utf-8') as f:
                f.write('helper\n')
                f.write('undefined_cmd\n')
            g = kgraph.extract_repo_graph(src)
        edges = {(e['source'], e['target'], e.get('label')) for e in g['edges']}
        self.assertIn(('ast_call:helper', 'ast_func:helper', 'calls'), edges)
        # calls to names with no definition are not linked
        self.assertNotIn(('ast_call:undefined-cmd', 'ast_func:undefined-cmd', 'calls'), edges)

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

        self.assertEqual(loaded.nodes[0].id, 'n1')
        self.assertEqual(loaded.edges[0].label, 'links')

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
        for e in result.edges:
            assert e.confidence is not None
            self.assertEqual(e.confidence.value, 'EXTRACTED')

    def test_tag_confidence_inferred_semantic_edges(self):
        graph = {
            'edges': [
                {'from': 'a', 'to': 'b', 'semantic_score': 0.82},
                {'from': 'c', 'to': 'd', 'semantic_score': 0.91},
            ],
        }
        result = self.kgraph.tag_confidence(graph)
        for e in result.edges:
            assert e.confidence is not None
            self.assertEqual(e.confidence.value, 'INFERRED')

    def test_tag_confidence_ambiguous_low_semantic(self):
        graph = {
            'edges': [
                {'from': 'a', 'to': 'b', 'semantic_score': 0.42},
                {'from': 'c', 'to': 'd', 'semantic_score': 0.30},
            ],
        }
        result = self.kgraph.tag_confidence(graph)
        for e in result.edges:
            assert e.confidence is not None
            self.assertEqual(e.confidence.value, 'AMBIGUOUS')

    def test_tag_confidence_explicit_flag(self):
        graph = {
            'edges': [
                {'from': 'a', 'to': 'b', 'label': 'whatever', 'explicit': True},
            ],
        }
        result = self.kgraph.tag_confidence(graph)
        conf = result.edges[0].confidence
        assert conf is not None
        self.assertEqual(conf.value, 'EXTRACTED')

    def test_tag_confidence_inferred_flag(self):
        graph = {
            'edges': [
                {'from': 'a', 'to': 'b', 'label': 'related concept', 'inferred': True},
            ],
        }
        result = self.kgraph.tag_confidence(graph)
        conf = result.edges[0].confidence
        assert conf is not None
        self.assertEqual(conf.value, 'INFERRED')

    def test_tag_confidence_cooccurrence_threshold(self):
        graph = {
            'edges': [
                {'from': 'a', 'to': 'b', 'cooccurrence_count': 5},
                {'from': 'c', 'to': 'd', 'cooccurrence_count': 1},
            ],
        }
        result = self.kgraph.tag_confidence(graph)
        conf0 = result.edges[0].confidence
        conf1 = result.edges[1].confidence
        assert conf0 is not None
        assert conf1 is not None
        self.assertEqual(conf0.value, 'INFERRED')
        self.assertEqual(conf1.value, 'AMBIGUOUS')

    def test_tag_confidence_ambiguous_fallback_related_label(self):
        graph = {
            'edges': [
                {'from': 'a', 'to': 'b', 'label': 'related concept'},
            ],
        }
        result = self.kgraph.tag_confidence(graph)
        conf = result.edges[0].confidence
        assert conf is not None
        self.assertEqual(conf.value, 'AMBIGUOUS')

    def test_tag_confidence_preserves_existing_fields(self):
        graph = {
            'nodes': [{'id': 'a', 'label': 'A'}],
            'edges': [{'from': 'a', 'to': 'b', 'label': 'imports', 'source': 'ast', 'extra': 'keep'}],
        }
        result = self.kgraph.tag_confidence(graph)
        self.assertEqual(result.nodes[0].label, 'A')
        self.assertEqual((result.edges[0].model_extra or {}).get('extra'), 'keep')
        conf = result.edges[0].confidence
        assert conf is not None
        self.assertEqual(conf.value, 'EXTRACTED')

    def test_confidence_stats_empty_graph(self):
        stats = self.kgraph.confidence_stats({'edges': []})
        self.assertEqual(stats['total'], 0)
        self.assertEqual(stats['extracted'], 0)
        self.assertEqual(stats['extracted_pct'], 0)

    def test_confidence_stats_counts_by_confidence_level(self):
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

    def test_format_path_returns_path_string_with_nodenames(self):
        path = self.kgraph.find_path(self.small_graph, 'n1', 'n2')
        text = self.kgraph.format_path(path)
        self.assertIn('Path:', text)
        self.assertIn('n1', text)
        self.assertIn('n2', text)
        self.assertIn('depends on', text)

    def test_format_path_returns_no_path_message(self):
        text = self.kgraph.format_path([])
        self.assertEqual(text, 'No path found')


if __name__ == '__main__':
    unittest.main()


class TestBenchmark(unittest.TestCase):
    """Tests for kgraph/benchmark.py — token estimation and benchmark reports."""

    def _get_benchmark(self):
        from kgraph.benchmark import benchmark_graph_vs_raw, estimate_tokens
        return estimate_tokens, benchmark_graph_vs_raw

    def test_estimate_tokens_empty_text(self):
        estimate_tokens, _ = self._get_benchmark()
        self.assertEqual(estimate_tokens(''), 1)

    def test_estimate_tokens_short_text(self):
        estimate_tokens, _ = self._get_benchmark()
        self.assertEqual(estimate_tokens('hi'), 1)

    def test_estimate_tokens_four_chars(self):
        estimate_tokens, _ = self._get_benchmark()
        self.assertEqual(estimate_tokens('test'), 1)

    def test_estimate_tokens_eight_chars(self):
        estimate_tokens, _ = self._get_benchmark()
        self.assertEqual(estimate_tokens('testword'), 2)

    def test_estimate_tokens_long_text(self):
        estimate_tokens, _ = self._get_benchmark()
        text = 'hello world ' * 100
        self.assertEqual(estimate_tokens(text), 300)

    def test_benchmark_empty_graph(self):
        _, benchmark_graph_vs_raw = self._get_benchmark()
        result = benchmark_graph_vs_raw({'nodes': [], 'edges': []})
        self.assertIn('graph_tokens', result)
        self.assertEqual(result['graph_tokens'], 0)
        self.assertEqual(result['node_count'], 0)

    def test_benchmark_simple_graph_returns_expected_counts(self):
        _, benchmark_graph_vs_raw = self._get_benchmark()
        graph = {
            'nodes': [{'id': 'n1', 'label': 'Node One'}],
            'edges': [{'from': 'n1', 'to': 'n2', 'label': 'links to'}],
        }
        result = benchmark_graph_vs_raw(graph)
        self.assertGreater(result['graph_tokens'], 0)
        self.assertIn('node_count', result)
        self.assertEqual(result['node_count'], 1)

_SMALL_CONNECTED_GRAPH = {
    'nodes': [
        {'id': 'a', 'label': 'Alpha'},
        {'id': 'b', 'label': 'Beta'},
        {'id': 'c', 'label': 'Gamma'},
        {'id': 'd', 'label': 'Delta'},
        {'id': 'e', 'label': 'Epsilon'},
    ],
    'edges': [
        {'from': 'a', 'to': 'b', 'weight': 1.0},
        {'from': 'a', 'to': 'c', 'weight': 0.5},
        {'from': 'b', 'to': 'c', 'weight': 0.8},
        {'from': 'd', 'to': 'e', 'weight': 0.9},
    ],
}

class CommunityDetectionTests(unittest.TestCase):
    """Tests for community.py: detect_communities, compute_centrality, find_god_nodes."""

    def test_communities_available_returns_bool(self):
        """communities_available() returns True when networkx is installed."""
        result = kgraph.communities_available()
        self.assertIsInstance(result, bool)
        self.assertTrue(result)

    # ── detect_communities ──────────────────────────────────────────

    def test_detect_communities_empty_graph_returns_as_is(self):
        """detect_communities on empty graph returns graph with no communities."""
        graph = {'nodes': [], 'edges': []}
        result = kgraph.detect_communities(graph, method='greedy')
        self.assertEqual(result.meta.communities, [])

    def test_detect_communities_too_few_nodes_returns_as_is(self):
        """detect_communities with <3 nodes returns graph with no communities."""
        graph = {
            'nodes': [{'id': 'a', 'label': 'A'}, {'id': 'b', 'label': 'B'}],
            'edges': [{'from': 'a', 'to': 'b'}],
        }
        result = kgraph.detect_communities(graph, method='greedy')
        self.assertEqual(result.meta.communities, [])

    def test_detect_communities_too_few_edges_returns_as_is(self):
        """detect_communities with <2 edges returns graph with no communities."""
        graph = {
            'nodes': [
                {'id': 'a', 'label': 'A'},
                {'id': 'b', 'label': 'B'},
                {'id': 'c', 'label': 'C'},
            ],
            'edges': [{'from': 'a', 'to': 'b'}],
        }
        result = kgraph.detect_communities(graph, method='greedy')
        self.assertEqual(result.meta.communities, [])

    def test_detect_communities_greedy_adds_communities(self):
        """greedy modularity detection populates meta.communities."""
        result = kgraph.detect_communities(_SMALL_CONNECTED_GRAPH, method='greedy')
        self.assertGreater(len(result.meta.communities), 0)
        for comm in result.meta.communities:
            self.assertIn('id', comm)
            self.assertIn('label', comm)
            self.assertIn('members', comm)
            self.assertIn('size', comm)

    def test_detect_communities_louvain_adds_communities(self):
        """louvain detection populates meta.communities."""
        result = kgraph.detect_communities(_SMALL_CONNECTED_GRAPH, method='louvain')
        self.assertGreater(len(result.meta.communities), 0)

    def test_detect_communities_method_defaults_to_leiden_like(self):
        """default method ('leiden_like') falls through to greedy modularity."""
        result = kgraph.detect_communities(_SMALL_CONNECTED_GRAPH)
        self.assertEqual(result.meta.community_method, 'leiden_like')

    def test_detect_communities_label_truncation(self):
        """community labels are truncated to 80 chars."""
        long_label_graph = {
            'nodes': [
                {'id': 'a', 'label': 'A' * 60},
                {'id': 'b', 'label': 'B' * 60},
                {'id': 'c', 'label': 'C' * 60},
                {'id': 'd', 'label': 'D'},
                {'id': 'e', 'label': 'E'},
            ],
            'edges': [
                {'from': 'a', 'to': 'b', 'weight': 1.0},
                {'from': 'a', 'to': 'c', 'weight': 0.5},
                {'from': 'b', 'to': 'c', 'weight': 0.8},
                {'from': 'd', 'to': 'e', 'weight': 0.9},
            ],
        }
        result = kgraph.detect_communities(long_label_graph, method='greedy')
        for comm in result.meta.communities:
            self.assertLessEqual(len(comm['label']), 80)

    def test_detect_communities_min_community_size_filters(self):
        """min_community_size drops smaller communities."""
        graph = {
            'nodes': [
                {'id': 'a', 'label': 'A'},
                {'id': 'b', 'label': 'B'},
                {'id': 'c', 'label': 'C'},
                {'id': 'd', 'label': 'D'},
                {'id': 'e', 'label': 'E'},
            ],
            'edges': [
                {'from': 'a', 'to': 'b', 'weight': 1.0},
                {'from': 'a', 'to': 'c', 'weight': 0.5},
                {'from': 'b', 'to': 'c', 'weight': 0.8},
                {'from': 'd', 'to': 'e', 'weight': 0.9},
            ],
        }
        result = kgraph.detect_communities(graph, method='greedy', min_community_size=5)
        self.assertEqual(len(result.meta.communities), 0)

    def test_detect_communities_missing_graph_keys(self):
        """detect_communities handles missing 'nodes'/'edges' keys gracefully."""
        result = kgraph.detect_communities({'foo': 'bar'}, method='greedy')
        self.assertEqual(result.meta.communities, [])

    def test_detect_communities_edge_source_target_aliases(self):
        """edges can use 'source'/'target' keys instead of 'from'/'to'."""
        graph = {
            'nodes': [
                {'id': 'a', 'label': 'A'},
                {'id': 'b', 'label': 'B'},
                {'id': 'c', 'label': 'C'},
                {'id': 'd', 'label': 'D'},
                {'id': 'e', 'label': 'E'},
            ],
            'edges': [
                {'source': 'a', 'target': 'b', 'weight': 1.0},
                {'source': 'a', 'target': 'c', 'weight': 0.5},
                {'source': 'b', 'target': 'c', 'weight': 0.8},
                {'source': 'd', 'target': 'e', 'weight': 0.9},
            ],
        }
        result = kgraph.detect_communities(graph, method='greedy')
        self.assertGreater(len(result.meta.communities), 0)

    def test_detect_communities_edge_semantic_score_as_weight(self):
        """edges can use semantic_score instead of weight."""
        graph = {
            'nodes': [
                {'id': 'a', 'label': 'A'},
                {'id': 'b', 'label': 'B'},
                {'id': 'c', 'label': 'C'},
                {'id': 'd', 'label': 'D'},
                {'id': 'e', 'label': 'E'},
            ],
            'edges': [
                {'from': 'a', 'to': 'b', 'semantic_score': 0.95},
                {'from': 'a', 'to': 'c', 'semantic_score': 0.50},
                {'from': 'b', 'to': 'c', 'semantic_score': 0.85},
                {'from': 'd', 'to': 'e', 'semantic_score': 0.80},
            ],
        }
        result = kgraph.detect_communities(graph, method='greedy')
        self.assertGreater(len(result.meta.communities), 0)

    def test_detect_communities_preserves_existing_meta(self):
        """existing meta fields are preserved in the output."""
        graph = dict(_SMALL_CONNECTED_GRAPH)
        graph['_meta'] = {'source': 'test', 'version': 1}
        result = kgraph.detect_communities(graph, method='greedy')
        meta_extra = result.meta.model_extra or {}
        self.assertEqual(meta_extra.get('source'), 'test')
        self.assertEqual(meta_extra.get('version'), 1)
        self.assertGreater(len(result.meta.communities), 0)

    # ── compute_centrality ──────────────────────────────────────────

    def test_compute_centrality_empty_graph(self):
        """compute_centrality on empty graph returns empty dict."""
        self.assertEqual(kgraph.compute_centrality({'nodes': [], 'edges': []}), {})

    def test_compute_centrality_single_node(self):
        """compute_centrality with <2 nodes returns empty dict."""
        graph = {
            'nodes': [{'id': 'a', 'label': 'A'}],
            'edges': [],
        }
        self.assertEqual(kgraph.compute_centrality(graph), {})

    def test_compute_centrality_returns_all_keys(self):
        """each node entry has id, label, degree, betweenness, eigenvector."""
        graph = {
            'nodes': [{'id': 'a', 'label': 'A'}, {'id': 'b', 'label': 'B'}],
            'edges': [{'from': 'a', 'to': 'b', 'weight': 1.0}],
        }
        result = kgraph.compute_centrality(graph)
        self.assertIn('a', result)
        self.assertIn('b', result)
        for key in ('id', 'label', 'degree', 'betweenness', 'eigenvector'):
            self.assertIn(key, result['a'])
        self.assertEqual(result['a']['degree'], 1)
        self.assertEqual(result['b']['degree'], 1)

    def test_compute_centrality_missing_labels(self):
        """nodes without labels use their id as the label."""
        graph = {
            'nodes': [{'id': 'a'}, {'id': 'b'}, {'id': 'c'}],
            'edges': [
                {'from': 'a', 'to': 'b'},
                {'from': 'b', 'to': 'c'},
            ],
        }
        result = kgraph.compute_centrality(graph)
        self.assertEqual(result['a']['label'], 'a')

    def test_compute_centrality_missing_graph_keys(self):
        """compute_centrality handles missing 'nodes'/'edges' keys."""
        result = kgraph.compute_centrality({'foo': 'bar'})
        self.assertEqual(result, {})

    # ── find_god_nodes ──────────────────────────────────────────────

    def test_find_god_nodes_empty_graph(self):
        """find_god_nodes on empty graph returns empty list."""
        self.assertEqual(kgraph.find_god_nodes({'nodes': [], 'edges': []}), [])

    def test_find_god_nodes_returns_sorted(self):
        """god nodes are sorted by composite_score descending."""
        graph = {
            'nodes': [
                {'id': 'a', 'label': 'Hub'},
                {'id': 'b', 'label': 'B'},
                {'id': 'c', 'label': 'C'},
                {'id': 'd', 'label': 'D'},
            ],
            'edges': [
                {'from': 'a', 'to': 'b', 'weight': 1.0},
                {'from': 'a', 'to': 'c', 'weight': 0.8},
                {'from': 'a', 'to': 'd', 'weight': 0.6},
                {'from': 'b', 'to': 'c', 'weight': 0.5},
            ],
        }
        result = kgraph.find_god_nodes(graph, top_n=5)
        self.assertGreater(len(result), 0)
        scores = [r['composite_score'] for r in result]
        self.assertEqual(scores, sorted(scores, reverse=True))
        # 'a' (Hub) has 3 edges — should be top
        self.assertEqual(result[0]['id'], 'a')

    def test_compute_centrality_disconnected_graph(self):
        """disconnected graphs must not raise AmbiguousSolution; all nodes get keys."""
        graph = {
            'nodes': [
                {'id': 'a', 'label': 'A'}, {'id': 'b', 'label': 'B'},
                {'id': 'x', 'label': 'X'}, {'id': 'y', 'label': 'Y'},
                {'id': 'solo', 'label': 'Solo'},
            ],
            'edges': [
                {'from': 'a', 'to': 'b', 'weight': 1.0},
                {'from': 'x', 'to': 'y', 'weight': 1.0},
            ],
        }
        result = kgraph.compute_centrality(graph)
        self.assertEqual(set(result), {'a', 'b', 'x', 'y', 'solo'})
        for nid, data in result.items():
            for key in ('id', 'label', 'degree', 'betweenness', 'eigenvector'):
                self.assertIn(key, data)
        # Singleton component has no adjacency → eigenvector and degree are 0.
        self.assertEqual(result['solo']['eigenvector'], 0.0)
        self.assertEqual(result['solo']['degree'], 0)

    def test_find_god_nodes_disconnected_graph(self):
        """god nodes on a disconnected graph do not raise."""
        graph = {
            'nodes': [
                {'id': 'hub', 'label': 'Hub'},
                {'id': 'b', 'label': 'B'},
                {'id': 'c', 'label': 'C'},
                {'id': 'lone', 'label': 'Lone'},
            ],
            'edges': [
                {'from': 'hub', 'to': 'b', 'weight': 1.0},
                {'from': 'hub', 'to': 'c', 'weight': 1.0},
            ],
        }
        result = kgraph.find_god_nodes(graph, top_n=5)
        self.assertGreater(len(result), 0)
        self.assertEqual(result[0]['id'], 'hub')

    def test_find_god_nodes_top_n_limit(self):
        """find_god_nodes respects the top_n parameter."""
        graph = {
            'nodes': [
                {'id': 'a', 'label': 'A'},
                {'id': 'b', 'label': 'B'},
                {'id': 'c', 'label': 'C'},
                {'id': 'd', 'label': 'D'},
            ],
            'edges': [
                {'from': 'a', 'to': 'b'},
                {'from': 'a', 'to': 'c'},
                {'from': 'a', 'to': 'd'},
            ],
        }
        result = kgraph.find_god_nodes(graph, top_n=2)
        self.assertLessEqual(len(result), 2)

    def test_find_god_nodes_contains_all_score_keys(self):
        """each god node entry has composite_score, degree, betweenness, eigenvector."""
        graph = {
            'nodes': [
                {'id': 'a', 'label': 'A'},
                {'id': 'b', 'label': 'B'},
                {'id': 'c', 'label': 'C'},
            ],
            'edges': [
                {'from': 'a', 'to': 'b'},
                {'from': 'b', 'to': 'c'},
            ],
        }
        result = kgraph.find_god_nodes(graph, top_n=5)
        self.assertGreater(len(result), 0)
        for key in ('composite_score', 'degree', 'betweenness', 'eigenvector'):
            self.assertIn(key, result[0])


# ═══════════════════════════════════════════════════════════════════════
# Tests for kgraph/validate.py — input validation and sanitization
# ═══════════════════════════════════════════════════════════════════════


class ValidatePayloadTests(unittest.TestCase):
    """Tests for validate.py: validate_graph_payload."""

    def test_validate_payload_valid_dict(self):
        """validate_graph_payload accepts a valid dict."""
        valid, msg = kgraph.validate_graph_payload({
            'nodes': [{'id': 1, 'label': 'one'}],
            'edges': [{'from': 1, 'to': 2}],
        })
        self.assertTrue(valid)
        self.assertEqual(msg, '')

    def test_validate_payload_valid_json_string(self):
        """validate_graph_payload accepts a valid JSON string."""
        payload = '{"nodes": [{"id": "n1", "label": "Node 1"}], "edges": [{"from": "n1", "to": "n2"}]}'
        valid, msg = kgraph.validate_graph_payload(payload)
        self.assertTrue(valid)
        self.assertEqual(msg, '')

    def test_validate_payload_valid_bytes(self):
        """validate_graph_payload accepts bytes payload."""
        payload = b'{"nodes": [{"id": "x", "label": "X"}], "edges": [{"from": "x", "to": "y"}]}'
        valid, msg = kgraph.validate_graph_payload(payload)
        self.assertTrue(valid)
        self.assertEqual(msg, '')

    def test_validate_payload_invalid_type(self):
        """validate_graph_payload rejects non-JSON, non-dict types."""
        valid, msg = kgraph.validate_graph_payload(42)
        self.assertFalse(valid)
        self.assertIn('Payload must be JSON string or dict', msg)

    def test_validate_payload_invalid_json(self):
        """validate_graph_payload rejects malformed JSON."""
        valid, msg = kgraph.validate_graph_payload('{"nodes": broken')
        self.assertFalse(valid)
        self.assertIn('Invalid JSON', msg)

    def test_validate_payload_too_large(self):
        """validate_graph_payload rejects payloads exceeding MAX_PAYLOAD_SIZE."""
        # Build a payload > 100MB (MAX_PAYLOAD_SIZE)
        large = '{"nodes": [' + ','.join(
            f'{{"id": {i}, "label": "n{i}"}}' for i in range(10_000_000)
        ) + '], "edges": []}'
        valid, msg = kgraph.validate_graph_payload(large)
        self.assertFalse(valid)
        self.assertIn('Payload too large', msg)

    def test_validate_payload_nodes_not_a_list(self):
        """validate_graph_payload rejects payload where nodes is not a list."""
        valid, msg = kgraph.validate_graph_payload({'nodes': 'bad', 'edges': []})
        self.assertFalse(valid)
        self.assertIn('must be a list', msg)

    def test_validate_payload_missing_required_node_field(self):
        """validate_graph_payload catches missing required fields (id)."""
        valid, msg = kgraph.validate_graph_payload({
            'nodes': [{'label': 'No ID'}],  # missing 'id'
            'edges': [],
        })
        self.assertFalse(valid)

    def test_validate_payload_xss_detection(self):
        """validate_graph_payload flags nodes with XSS patterns."""
        valid, msg = kgraph.validate_graph_payload({
            'nodes': [{'id': 1, 'label': '<script>alert(1)</script>'}],
            'edges': [],
        })
        self.assertFalse(valid)
        self.assertIn('dangerous patterns', msg)

    def test_validate_payload_warning_downgrade(self):
        """warnings alone (no errors) do not fail validation."""
        valid, msg = kgraph.validate_graph_payload({
            'nodes': [{'id': 1, 'label': 'ok', 'nonsense_field': 'x'}],
            'edges': [],
        })
        self.assertTrue(valid)
        self.assertEqual(msg, '')


class SanitizeLabelTests(unittest.TestCase):
    """Tests for validate.py: sanitize_label."""

    def test_sanitize_label_empty_string(self):
        """sanitize_label('') returns ''."""
        self.assertEqual(kgraph.sanitize_label(''), '')

    def test_sanitize_label_none(self):
        """sanitize_label(None) returns ''."""
        self.assertEqual(kgraph.sanitize_label(None), '')

    def test_sanitize_label_strips_html_tags(self):
        """sanitize_label removes HTML tags."""
        result = kgraph.sanitize_label('Hello <b>world</b>')
        self.assertNotIn('<b>', result)
        self.assertNotIn('</b>', result)
        self.assertIn('Hello world', result)

    def test_sanitize_label_strips_script_tag(self):
        """sanitize_label removes <script> tags."""
        result = kgraph.sanitize_label('before <script>doEvil()</script> after')
        self.assertNotIn('<script>', result)
        self.assertNotIn('</script>', result)
        self.assertIn('after', result)

    def test_sanitize_label_removes_javascript_protocol(self):
        """sanitize_label strips javascript: URIs."""
        result = kgraph.sanitize_label('click javascript:alert(1)')
        self.assertNotIn('javascript:', result)

    def test_sanitize_label_removes_onclick_handler(self):
        """sanitize_label strips onclick= patterns."""
        result = kgraph.sanitize_label('click onclick=alert')
        self.assertNotIn('onclick', result)

    def test_sanitize_label_keeps_safe_text(self):
        """sanitize_label preserves normal text."""
        label = 'Hello, World! This is a safe label.'
        self.assertEqual(kgraph.sanitize_label(label), label)

    def test_sanitize_label_truncates_long(self):
        """sanitize_label truncates labels exceeding MAX_LABEL_LENGTH (500)."""
        long_label = 'x' * 600
        result = kgraph.sanitize_label(long_label)
        self.assertLessEqual(len(result), 500)

    def test_sanitize_label_strips_trailing_whitespace(self):
        """sanitize_label strips leading/trailing whitespace."""
        result = kgraph.sanitize_label('  hello world  ')
        self.assertEqual(result, 'hello world')

    def test_sanitize_label_mixed_dangerous_content(self):
        """sanitize_label handles mixed HTML + JS patterns."""
        result = kgraph.sanitize_label(
            '<img src=x onerror=alert(1)> safe text <a href="javascript:void(0)">link</a>'
        )
        self.assertNotIn('onerror', result)
        self.assertNotIn('javascript:', result)
        self.assertNotIn('<img', result)
        self.assertNotIn('</a>', result)
        self.assertIn('safe text', result)




class TestRegistryAdapter(unittest.TestCase):
    """T-ROOK-006: memory registry schema adapter tests.

    Mirrors live registry row counts (memory_entities empty, native chunks
    present, NULL value_score, stale syntheses) per design §6.
    """

    def _make_registry(self, path):
        conn = sqlite3.connect(path)
        cur = conn.cursor()
        cur.execute("""CREATE TABLE memories (
            id TEXT, type TEXT, content TEXT, source_agent TEXT, scope TEXT,
            tags TEXT, confidence REAL, created_at TEXT, concept TEXT,
            value_score REAL, value_label TEXT, source_layer TEXT, status TEXT)""")
        cur.execute("""CREATE TABLE memory_native_chunks (
            chunk_id TEXT, source_path TEXT, source_kind TEXT, section TEXT,
            line_start TEXT, line_end TEXT, content TEXT, scope TEXT, status TEXT)""")
        cur.execute("""CREATE TABLE memory_entities (
            entity_id TEXT, kind TEXT, display_name TEXT, normalized_name TEXT,
            status TEXT, confidence REAL, aliases TEXT)""")
        cur.execute("""CREATE TABLE memory_entity_mentions (
            memory_id TEXT, entity_key TEXT, entity_display TEXT, role TEXT,
            confidence REAL, scope TEXT)""")
        cur.execute("""CREATE TABLE memory_entity_relationships (
            entity_id_a TEXT, entity_id_b TEXT, relationship_type TEXT,
            evidence_count INT, source_memory_ids TEXT, confidence REAL)""")
        cur.execute("""CREATE TABLE memory_syntheses (
            synthesis_id TEXT, kind TEXT, subject_type TEXT, subject_id TEXT,
            content TEXT, stale INT, confidence REAL, generated_at TEXT)""")
        cur.execute("""CREATE TABLE memory_claims (
            memory_id TEXT, memory_tier TEXT, claim_slot TEXT,
            consolidation_op TEXT, source_strength REAL,
            surface_candidate TEXT)""")
        cur.execute("""CREATE TABLE memory_beliefs (
            belief_id TEXT, entity_id TEXT, type TEXT, content TEXT,
            status TEXT, confidence REAL, source_memory_id TEXT,
            source_layer TEXT)""")
        cur.execute("""CREATE TABLE memory_open_loops (
            loop_id TEXT, kind TEXT, title TEXT, status TEXT, priority TEXT,
            related_entity_id TEXT)""")
        cur.execute("""CREATE TABLE memory_events (
            event_id TEXT, timestamp TEXT, component TEXT, action TEXT,
            reason_codes TEXT, memory_id TEXT, payload TEXT)""")
        # memories: NULL value_score must survive the filter (live case)
        cur.execute(
            "INSERT INTO memories VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)",
            ('mem-1', 'CONTEXT', 'NAS SSH access available', 'jarvis', 'jarvis',
             '[]', 0.9, '2026-04-01', None, None, None, 'registry', 'active'))
        cur.execute(
            "INSERT INTO memories VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)",
            ('mem-2', 'FACT', 'Low value stale memory', 'rook', 'rook',
             '[]', 0.3, '2026-04-01', None, 0.3, None, 'registry', 'active'))
        # native chunks → memory:native:{chunk_id}
        cur.execute(
            "INSERT INTO memory_native_chunks VALUES (?,?,?,?,?,?,?,?,?)",
            ('chunk-1', '/mem/MEMORY.md', 'memory_md', 'KG', '4', '4',
             'Integrity checks: Weekly Sunday 04:00', 'profile:main', 'active'))
        # memory_entities stays EMPTY (live condition) → synthesis from mentions
        # mentions: hal survives (agent), database dropped (noise)
        cur.execute(
            "INSERT INTO memory_entity_mentions VALUES (?,?,?,?,?,?)",
            ('native:chunk-1', 'hal', 'hal', 'general', 0.8, 'profile:main'))
        cur.execute(
            "INSERT INTO memory_entity_mentions VALUES (?,?,?,?,?,?)",
            ('native:chunk-1', 'database', 'database', 'general', 0.8, 'profile:main'))
        # syntheses: one stale=0 (kept), one stale=1 (dropped unless include_all)
        cur.execute(
            "INSERT INTO memory_syntheses VALUES (?,?,?,?,?,?,?,?)",
            ('synth:ok', 'current_state', 'global', 'global', 'Current State', 0, 0.9, '2026-04-01'))
        cur.execute(
            "INSERT INTO memory_syntheses VALUES (?,?,?,?,?,?,?,?)",
            ('synth:stale', 'old_report', 'global', 'global', 'Old', 1, 0.8, '2026-04-01'))
        cur.execute(
            "INSERT INTO memory_claims VALUES (?,?,?,?,?,?)",
            ('mem-1', 'durable', 'slot-1', 'op', 0.9, 'claim text'))
        cur.execute(
            "INSERT INTO memory_events VALUES (?,?,?,?,?,?,?)",
            ('evt-1', '2026-04-01', 'capture', 'capture_inserted', '[]', 'mem-1', '{}'))
        conn.commit()
        conn.close()

    def _run(self, path, include_all=False):
        import kgraph.memory_import as mi
        from kgraph.models import GraphBuilder
        conn = sqlite3.connect(path)
        builder = GraphBuilder()
        mi._load_from_registry_db(conn, builder, registry='home', include_all=include_all)
        conn.close()
        g = builder.build()
        return (g.nodes, g.edges)

    def test_basic_import_and_filter(self):
        with tempfile.TemporaryDirectory() as td:
            path = os.path.join(td, 'registry.sqlite')
            self._make_registry(path)
            nodes, edges = self._run(path)
            nids = [n.id for n in nodes]
            # memories: mem-1 kept (NULL value_score), mem-2 dropped (0.3 < 0.5)
            self.assertIn('memory:mem-1', nids)
            self.assertNotIn('memory:mem-2', nids)
            # native chunk mapped
            self.assertIn('memory:native:chunk-1', nids)
            # syntheses: ok kept, stale dropped
            self.assertIn('synthesis:synth:ok', nids)
            self.assertNotIn('synthesis:synth:stale', nids)
            # claim + event skipped
            self.assertIn('claim:mem-1:slot-1', nids)
            # entity synthesis: hal kept, database (noise) dropped
            ent_ids = [n.id for n in nodes if n.type == 'entity']
            self.assertIn('entity:hal', ent_ids)
            self.assertNotIn('entity:database', ent_ids)
            # mentions edge resolves native: → memory:native:chunk-1
            self.assertTrue(any(e.source == 'memory:native:chunk-1' and e.target == 'entity:hal'
                                for e in edges))

    def test_include_all_bypasses_filter(self):
        with tempfile.TemporaryDirectory() as td:
            path = os.path.join(td, 'registry.sqlite')
            self._make_registry(path)
            nodes, _ = self._run(path, include_all=True)
            nids = [n.id for n in nodes]
            self.assertIn('memory:mem-2', nids)          # low value now included
            self.assertIn('synthesis:synth:stale', nids)  # stale now included

    def test_entity_row_preferred_over_mention_synthesis(self):
        """Jarvis note 1: when memory_entities has a row, edge targets its id."""
        with tempfile.TemporaryDirectory() as td:
            path = os.path.join(td, 'registry.sqlite')
            self._make_registry(path)
            conn = sqlite3.connect(path)
            cur = conn.cursor()
            cur.execute(
                "INSERT INTO memory_entities VALUES (?,?,?,?,?,?,?)",
                ('e-1', 'person', 'Hal', 'hal', 'active', 0.95, '[]'))
            conn.commit()
            conn.close()
            nodes, edges = self._run(path)
            ent_ids = [n.id for n in nodes if n.type == 'entity']
            self.assertIn('entity:person:hal', ent_ids)
            self.assertTrue(any(e.target == 'entity:person:hal' for e in edges))
