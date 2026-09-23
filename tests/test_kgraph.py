import os
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

from _paths import SCRIPT_DIR

# Import the kgraph package directly; the backward-compatibility shim
# (scripts/kgraph.py) was removed during cleanup.
import kgraph


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
        self.assertIn(('ast_call:bash:helper', 'ast_func:bash:helper', 'calls'), edges)
        # calls to names with no definition are not linked.  The id carries the language
        # AND the name verbatim, so this must name `undefined_cmd` exactly — a slugged
        # `undefined-cmd` can no longer be produced, and asserting NotIn on it would
        # pass for the wrong reason.
        self.assertNotIn(('ast_call:bash:undefined_cmd', 'ast_func:bash:undefined_cmd', 'calls'), edges)

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

    def test_query_nodes_invalid_regex_falls_back_to_literal(self):
        # An invalid regex must not raise; literal substring matching applies.
        self.assertEqual(self.kgraph.query_nodes(self.small_graph, '['), [])

    def test_query_nodes_valid_regex_still_matches(self):
        results = self.kgraph.query_nodes(self.small_graph, r'^jwt')
        self.assertEqual([r['id'] for r in results], ['n3'])

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
        # beliefs: schema default status 'current' survives the default filter;
        # 'superseded' is dropped unless include_all (regression: the filter
        # compared against 'active' and dropped default-status beliefs).
        cur.execute(
            "INSERT INTO memory_beliefs VALUES (?,?,?,?,?,?,?,?)",
            ('bel-1', 'e-1', 'fact', 'Live belief', 'current', 0.9, 'mem-1', 'registry'))
        cur.execute(
            "INSERT INTO memory_beliefs VALUES (?,?,?,?,?,?,?,?)",
            ('bel-2', 'e-1', 'fact', 'Superseded belief', 'superseded', 0.9, 'mem-1', 'registry'))
        # open loops: status 'open' survives the default filter;
        # 'closed' is dropped unless include_all (regression: the filter
        # compared a 'open' default against 'active' and dropped everything).
        cur.execute(
            "INSERT INTO memory_open_loops VALUES (?,?,?,?,?,?)",
            ('loop-1', 'followup', 'Rotate gateway token', 'open', 'high', None))
        cur.execute(
            "INSERT INTO memory_open_loops VALUES (?,?,?,?,?,?)",
            ('loop-2', 'followup', 'Old closed item', 'closed', 'low', None))
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
            # beliefs: default status 'current' kept, 'superseded' dropped
            self.assertIn('belief:bel-1', nids)
            self.assertNotIn('belief:bel-2', nids)
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

    def test_claim_linked_to_its_memory(self):
        """claims nodes get an edge to the memory they were consolidated from."""
        with tempfile.TemporaryDirectory() as td:
            path = os.path.join(td, 'registry.sqlite')
            self._make_registry(path)
            nodes, edges = self._run(path)
            nids = [n.id for n in nodes]
            self.assertIn('claim:mem-1:slot-1', nids)
            self.assertTrue(
                any(e.source == 'memory:mem-1' and e.target == 'claim:mem-1:slot-1'
                    and e.label == 'claims' for e in edges),
                f'no claims edge from memory:mem-1 in {[(e.source, e.target, e.label) for e in edges]}',
            )

    def test_promoted_native_chunk_not_duplicated(self):
        """a native chunk whose content matches an imported memory is skipped."""
        with tempfile.TemporaryDirectory() as td:
            path = os.path.join(td, 'registry.sqlite')
            self._make_registry(path)
            conn = sqlite3.connect(path)
            cur = conn.cursor()
            cur.execute(
                "INSERT INTO memory_native_chunks VALUES (?,?,?,?,?,?,?,?,?)",
                ('chunk-dup', '/mem/MEMORY.md', 'memory_md', 'KG', '1', '1',
                 'NAS SSH access available', 'profile:main', 'active'))
            conn.commit()
            conn.close()
            nodes, _ = self._run(path)
            nids = [n.id for n in nodes]
            self.assertIn('memory:mem-1', nids)
            self.assertNotIn('memory:native:chunk-dup', nids)
            # unrelated chunks still import
            self.assertIn('memory:native:chunk-1', nids)

    def test_open_loop_open_status_survives_filter(self):
        """A loop with status='open' is kept by default (not silently dropped)."""
        with tempfile.TemporaryDirectory() as td:
            path = os.path.join(td, 'registry.sqlite')
            self._make_registry(path)
            nodes, _ = self._run(path)
            nids = [n.id for n in nodes]
            self.assertIn('open_loop:loop-1', nids)
            self.assertNotIn('open_loop:loop-2', nids)

    def test_open_loop_include_all_keeps_closed(self):
        """include_all keeps closed loops too."""
        with tempfile.TemporaryDirectory() as td:
            path = os.path.join(td, 'registry.sqlite')
            self._make_registry(path)
            nodes, _ = self._run(path, include_all=True)
            nids = [n.id for n in nodes]
            self.assertIn('open_loop:loop-1', nids)
            self.assertIn('open_loop:loop-2', nids)


class TestDispatcherCallEdges(unittest.TestCase):
    """A function name handed to a known dispatcher is a real call — in argument position.

    `command_name` capture cannot see it, so before the dispatcher allowlist these
    functions read as uncalled; that shape accounted for part of this repo's
    call-orphan set. The edge is the ordinary file -> ast_call -> ast_func chain, so
    the existing whole-corpus name resolution binds it with no extra machinery.
    """

    def test_dispatched_name_is_recorded_and_resolved(self):
        from kgraph.ast_extractor import _BASH_DISPATCHERS, extract_repo_graph

        dispatcher = sorted(_BASH_DISPATCHERS)[0]
        with tempfile.TemporaryDirectory() as td:
            with open(os.path.join(td, 'mod.sh'), 'w') as f:
                f.write(
                    '#!/usr/bin/env bash\n'
                    f'{dispatcher}() {{ "$@"; }}\n'
                    '__target_fn() { echo t; }\n'
                    f'run() {{ {dispatcher} __target_fn; }}\n'
                )
            graph = extract_repo_graph(td)
        edges = {(e['source'], e['label'], e['target']) for e in graph['edges']}
        self.assertIn(('ast_file:mod-sh', 'calls', 'ast_call:bash:__target_fn'), edges)
        self.assertIn(('ast_call:bash:__target_fn', 'calls', 'ast_func:bash:__target_fn'), edges)

    def test_only_bare_word_arguments_become_calls(self):
        """A quoted or substituted argument is not statically resolvable, so no edge."""
        from kgraph.ast_extractor import _BASH_DISPATCHERS, extract_repo_graph

        dispatcher = sorted(_BASH_DISPATCHERS)[0]
        with tempfile.TemporaryDirectory() as td:
            with open(os.path.join(td, 'mod.sh'), 'w') as f:
                f.write(
                    '#!/usr/bin/env bash\n'
                    f'{dispatcher}() {{ "$@"; }}\n'
                    'fn_name=some_thing\n'
                    f'run() {{ {dispatcher} "$fn_name"; }}\n'
                )
            graph = extract_repo_graph(td)
        targets = {e['target'] for e in graph['edges'] if e['label'] == 'calls'}
        self.assertNotIn('ast_call:bash:some_thing', targets)


class TestTrapHandlerCallEdges(unittest.TestCase):
    """A call inside a `trap '<handler>' SIGNAL` string is still a call.

    The handler is shell code held in a string, so a `command_name` capture never
    saw it. scripts/11e-llm-model.sh's __bench_cleanup is defined inside another
    function and invoked only from a trap, so it read as a call-orphan with no
    caller anywhere. The edge is again file -> ast_call -> ast_func, so the
    existing whole-corpus name resolution binds it with no extra machinery.
    """

    def test_quoted_handler_commands_are_recorded_and_resolved(self):
        from kgraph.ast_extractor import extract_repo_graph

        with tempfile.TemporaryDirectory() as td:
            with open(os.path.join(td, 'mod.sh'), 'w') as f:
                f.write(
                    '#!/usr/bin/env bash\n'
                    '__bench_cleanup() { :; }\n'
                    "run() { trap '__rc=0; __bench_cleanup; return 130' INT; }\n"
                )
            graph = extract_repo_graph(td)
        edges = {(e['source'], e['label'], e['target']) for e in graph['edges']}
        self.assertIn(('ast_file:mod-sh', 'calls', 'ast_call:bash:__bench_cleanup'), edges)
        self.assertIn(('ast_call:bash:__bench_cleanup', 'calls', 'ast_func:bash:__bench_cleanup'), edges)

    def test_bare_word_handler_is_recorded(self):
        from kgraph.ast_extractor import extract_repo_graph

        with tempfile.TemporaryDirectory() as td:
            with open(os.path.join(td, 'mod.sh'), 'w') as f:
                f.write(
                    '#!/usr/bin/env bash\n'
                    'cleanup() { :; }\n'
                    'trap cleanup EXIT\n'
                )
            graph = extract_repo_graph(td)
        edges = {(e['source'], e['label'], e['target']) for e in graph['edges']}
        self.assertIn(('ast_file:mod-sh', 'calls', 'ast_call:bash:cleanup'), edges)

    def test_signal_arguments_are_not_recorded_as_calls(self):
        """Only the handler is a call site — the signal names are arguments."""
        from kgraph.ast_extractor import extract_repo_graph

        with tempfile.TemporaryDirectory() as td:
            with open(os.path.join(td, 'mod.sh'), 'w') as f:
                f.write(
                    '#!/usr/bin/env bash\n'
                    "trap 'echo hi' INT TERM\n"
                )
            graph = extract_repo_graph(td)
        targets = {e['target'] for e in graph['edges'] if e['label'] == 'calls'}
        self.assertNotIn('ast_call:bash:INT', targets)
        self.assertNotIn('ast_call:bash:TERM', targets)

    def test_substituted_handler_is_not_resolved(self):
        """A handler held in a variable is not statically resolvable."""
        from kgraph.ast_extractor import extract_repo_graph

        with tempfile.TemporaryDirectory() as td:
            with open(os.path.join(td, 'mod.sh'), 'w') as f:
                f.write(
                    '#!/usr/bin/env bash\n'
                    'handler=cleanup_thing\n'
                    'trap "$handler" INT\n'
                )
            graph = extract_repo_graph(td)
        targets = {e['target'] for e in graph['edges'] if e['label'] == 'calls'}
        self.assertNotIn('ast_call:bash:cleanup_thing', targets)


class TestSymbolIdsDoNotCollide(unittest.TestCase):
    """Two different names must never share a node id.

    Ids used to be ``slugify(name)``, which lowercases AND collapses runs of
    non-alphanumerics to '-', so `__model_recommend` and `model-recommend` — two
    different functions in this repo — both became `ast_func:model-recommend`: the
    second definition replaced the first and a call to either bound to whichever
    survived (measured 2026-09-21: 4 real collisions, 8 definitions, 4 nodes).
    """

    def test_names_that_slug_alike_get_distinct_nodes(self):
        from kgraph.ast_extractor import extract_repo_graph

        with tempfile.TemporaryDirectory() as td:
            with open(os.path.join(td, 'mod.sh'), 'w') as f:
                f.write(
                    '#!/usr/bin/env bash\n'
                    '__model_recommend() { :; }\n'
                    'model-recommend() { :; }\n'
                    'run() { __model_recommend; model-recommend; }\n'
                )
            graph = extract_repo_graph(td)
        ids = {n['id'] for n in graph['nodes']}
        self.assertIn('ast_func:bash:__model_recommend', ids)
        self.assertIn('ast_func:bash:model-recommend', ids)
        edges = {(e['source'], e['label'], e['target']) for e in graph['edges']}
        self.assertIn(('ast_call:bash:__model_recommend', 'calls', 'ast_func:bash:__model_recommend'), edges)
        self.assertIn(('ast_call:bash:model-recommend', 'calls', 'ast_func:bash:model-recommend'), edges)

    def test_case_is_preserved_in_ids(self):
        from kgraph.ast_extractor import extract_repo_graph

        with tempfile.TemporaryDirectory() as td:
            with open(os.path.join(td, 'mod.sh'), 'w') as f:
                f.write('#!/usr/bin/env bash\nLOG_ONE() { :; }\nlog_one() { :; }\n')
            graph = extract_repo_graph(td)
        ids = {n['id'] for n in graph['nodes']}
        self.assertIn('ast_func:bash:LOG_ONE', ids)
        self.assertIn('ast_func:bash:log_one', ids)

    def test_unsafe_characters_are_escaped_not_dropped(self):
        """The `:` builtin used to land on the empty id ``ast_call:``."""
        from kgraph.ast_extractor import extract_repo_graph

        with tempfile.TemporaryDirectory() as td:
            with open(os.path.join(td, 'mod.sh'), 'w') as f:
                f.write('#!/usr/bin/env bash\n: "noop"\n')
            graph = extract_repo_graph(td)
        ids = {n['id'] for n in graph['nodes']}
        self.assertNotIn('ast_call:bash:', ids)
        self.assertIn('ast_call:bash:~_3a', ids)


class TestShebangDiscovery(unittest.TestCase):
    """An extensionless script is parsed when its shebang names a shell.

    Files were discovered by extension alone, so this repo's nine extensionless
    ``bin/*`` scripts — including ``bin/tac-exec``, the dispatcher every wrapper
    routes through — were invisible to the graph, and functions invoked only from
    them read as call-orphans (a coverage gap, not dead code).
    """

    def test_extensionless_bash_script_is_parsed(self):
        from kgraph.ast_extractor import extract_repo_graph

        with tempfile.TemporaryDirectory() as td:
            bindir = os.path.join(td, 'bin')
            os.makedirs(bindir)
            with open(os.path.join(bindir, 'wrapper'), 'w') as f:
                f.write('#!/usr/bin/env bash\nhelper_fn\n')
            with open(os.path.join(bindir, 'not-a-script'), 'w') as f:
                f.write('plain text, no shebang\n')
            graph = extract_repo_graph(td)
        ids = {n['id'] for n in graph['nodes']}
        self.assertIn('ast_file:bin-wrapper', ids)
        self.assertNotIn('ast_file:bin-not-a-script', ids)
        edges = {(e['source'], e['label'], e['target']) for e in graph['edges']}
        self.assertIn(('ast_file:bin-wrapper', 'calls', 'ast_call:bash:helper_fn'), edges)

    def test_a_file_its_extension_already_claims_is_not_added_twice(self):
        from kgraph.ast_extractor import extract_repo_graph

        with tempfile.TemporaryDirectory() as td:
            with open(os.path.join(td, 'mod.sh'), 'w') as f:
                f.write('#!/usr/bin/env bash\nfn() { :; }\n')
            graph = extract_repo_graph(td)
        defines = [e for e in graph['edges']
                   if e['source'] == 'ast_file:mod-sh' and e['label'] == 'defines']
        self.assertEqual(len(defines), 1)


# ═══════════════════════════════════════════════════════════════════════


class VocabularyValidationTests(unittest.TestCase):
    """validate.py reports node types / edge labels outside the declared vocabulary.

    REF: "GraphRAG: A Practitioner's Guide to 6 Advanced Architectural Patterns"
    (Partha Sarkar, TDS, 2026-09-20) — https://towardsdatascience.com/graphrag-a-practitioners-guide-to-6-advanced-architectural-patterns/
    The article's Challenge 2 discipline: one minimal, rigid ontology, so a label
    that no module understands cannot enter the graph unnoticed.
    """

    @staticmethod
    def _vocabulary_findings(graph):
        from kgraph.validate import validate_graph

        return [e for e in validate_graph(graph)
                if 'vocabulary' in e.get('message', '')]

    def test_unknown_edge_label_is_reported_once_per_label_with_a_count(self):
        findings = self._vocabulary_findings({
            'nodes': [{'id': 1, 'label': 'a'}, {'id': 2, 'label': 'b'}],
            'edges': [{'from': 1, 'to': 2, 'label': 'teleports to'},
                      {'from': 2, 'to': 1, 'label': 'teleports to'}],
        })
        self.assertEqual(len(findings), 1)
        self.assertIn("'teleports to' (2x)", findings[0]['message'])
        self.assertEqual(findings[0]['severity'], 'warning')

    def test_unknown_node_type_is_reported(self):
        findings = self._vocabulary_findings({
            'nodes': [{'id': 1, 'label': 'a', 'type': 'gadget'}],
            'edges': [],
        })
        self.assertEqual(len(findings), 1)
        self.assertIn('gadget', findings[0]['message'])

    def test_declared_vocabulary_is_not_reported(self):
        """Curated, AST, the two literals and the prefix family all stay quiet."""
        findings = self._vocabulary_findings({
            'nodes': [
                {'id': 1, 'label': 'a', 'type': 'file'},
                {'id': 2, 'label': 'b', 'type': 'topic'},
                {'id': 3, 'label': 'c', 'type': 'function'},
            ],
            'edges': [
                {'from': 1, 'to': 2, 'label': 'covers topic'},
                {'from': 1, 'to': 3, 'label': 'defines'},
                {'from': 3, 'to': 2, 'label': 'semantic summary'},
                {'from': 3, 'to': 1, 'label': 'summarizes releases'},
            ],
        })
        self.assertEqual(findings, [])

    def test_vocabulary_sets_are_one_object_across_modules(self):
        """The drift guard: the sets validate.py checks are the ones projection uses.

        This is the assertion that would have caught the concept-alias incident,
        where models.py, projection.py and memory_import.py each carried a copy
        and the copies diverged by seven keys before anyone noticed.
        """
        import kgraph.constants as constants
        import kgraph.projection as projection

        self.assertIs(projection.CURATED_EDGE_LABELS, constants.CURATED_EDGE_LABELS)
        self.assertIs(projection.AST_EDGE_LABELS, constants.AST_EDGE_LABELS)
        self.assertIs(projection.AST_NODE_TYPES, constants.AST_NODE_TYPES)
        for label_set in (constants.CURATED_EDGE_LABELS, constants.AST_EDGE_LABELS):
            self.assertTrue(label_set <= constants.EDGE_LABELS)

    def test_unknown_label_does_not_reject_the_payload(self):
        """A warning, not an error: the MCP pre-flight contract is unchanged."""
        from kgraph.validate import validate_graph_payload

        valid, msg = validate_graph_payload({
            'nodes': [{'id': 1, 'label': 'a'}],
            'edges': [{'from': 1, 'to': 1, 'label': 'teleports to'}],
        })
        self.assertTrue(valid)
        self.assertEqual(msg, '')


class VocabularyStampTests(unittest.TestCase):
    """The vocabulary version is written into the graph DB at build time.

    REF: "GraphRAG: A Practitioner's Guide to 6 Advanced Architectural Patterns"
    (Partha Sarkar, TDS, 2026-09-20) — so a graph built under an older label set
    is identifiable rather than merely wrong.
    """

    def test_save_stamps_the_current_vocabulary_version(self):
        import kgraph.constants as constants
        from kgraph.graph_db import read_vocabulary_version, save_to_graph_db

        with tempfile.TemporaryDirectory() as td:
            db = os.path.join(td, 'graph.sqlite')
            save_to_graph_db(db, {
                'nodes': [{'id': 'n1', 'label': 'a'}],
                'edges': [],
            })
            self.assertEqual(read_vocabulary_version(db), constants.VOCABULARY_VERSION)

    def test_a_table_but_no_save_reads_as_unstamped(self):
        """None means 'built under an unknown vocabulary', not 'current'."""
        from kgraph.graph_db import init_graph_db, read_vocabulary_version

        with tempfile.TemporaryDirectory() as td:
            db = os.path.join(td, 'graph.sqlite')
            init_graph_db(db)
            self.assertIsNone(read_vocabulary_version(db))

    def test_missing_database_reads_as_unstamped(self):
        from kgraph.graph_db import read_vocabulary_version

        self.assertIsNone(read_vocabulary_version('/tmp/does-not-exist-kgraph.sqlite'))


# ══════════════ GRAPHRAG-ARCH-006: community digest ══════════════
#
# REF: "GraphRAG: A Practitioner's Guide to 6 Advanced Architectural Patterns"
#      (Partha Sarkar, TDS, 2026-09-20)

_TWO_CLUSTER_GRAPH = {
    'nodes': [
        {'id': 'a', 'label': 'Alpha', 'type': 'topic'},
        {'id': 'b', 'label': 'Beta', 'type': 'topic'},
        {'id': 'c', 'label': 'Gamma', 'type': 'topic'},
        {'id': 'd', 'label': 'Delta', 'type': 'topic'},
        {'id': 'e', 'label': 'Epsilon', 'type': 'topic'},
        {'id': 'f', 'label': 'Zeta', 'type': 'topic'},
    ],
    'edges': [
        {'from': 'a', 'to': 'b', 'label': 'links', 'weight': 1.0},
        {'from': 'b', 'to': 'c', 'label': 'links', 'weight': 1.0},
        {'from': 'a', 'to': 'c', 'label': 'links', 'weight': 1.0},
        {'from': 'd', 'to': 'e', 'label': 'links', 'weight': 1.0},
        {'from': 'e', 'to': 'f', 'label': 'links', 'weight': 1.0},
        {'from': 'd', 'to': 'f', 'label': 'links', 'weight': 1.0},
        {'from': 'c', 'to': 'd', 'label': 'links', 'weight': 0.05},
    ],
}


class CommunityDigestTests(unittest.TestCase):
    """The article's community report: digest_communities + its consumers."""

    def _digested(self):
        graph = kgraph.detect_communities(_TWO_CLUSTER_GRAPH, method='greedy')
        return kgraph.digest_communities(graph)

    def test_digest_adds_the_report_fields_to_every_community(self):
        graph = self._digested()
        self.assertTrue(graph.meta.communities, 'fixture produced no communities')
        for community in graph.meta.communities:
            self.assertIn('central_nodes', community)
            self.assertIn('god_nodes', community)
            self.assertIn('boundary_edges', community)
            self.assertIn('boundary_edge_count', community)
            self.assertTrue(community['central_nodes'], community)
            for entry in community['central_nodes']:
                self.assertEqual(set(entry), {'id', 'label', 'composite_score'})
                self.assertIn(entry['id'], community['members'])

    def test_digest_is_deterministic(self):
        first = self._digested().meta.communities
        second = self._digested().meta.communities
        self.assertEqual(first, second)

    def test_boundary_edges_cross_the_community_and_are_capped(self):
        graph = self._digested()
        community = max(graph.meta.communities, key=lambda c: c['size'])
        members = set(community['members'])
        for edge in community['boundary_edges']:
            self.assertIn(edge['direction'], ('out', 'in'))
            inside = edge['source'] in members
            self.assertNotEqual(inside, edge['target'] in members, edge)
        # The reported total is the true count, independent of the rendered cap.
        self.assertGreaterEqual(community['boundary_edge_count'],
                                len(community['boundary_edges']))

    def test_digest_leaves_a_graph_without_communities_untouched(self):
        graph = kgraph.Graph.from_dict({'nodes': [{'id': 'a', 'label': 'A'}], 'edges': []})
        self.assertIs(kgraph.digest_communities(graph), graph)
        self.assertEqual(graph.meta.communities, [])

    def test_community_for_node_finds_the_containing_community(self):
        graph = self._digested()
        community = kgraph.community_for_node(graph, 'a')
        self.assertIsNotNone(community)
        assert community is not None  # narrows for the type checker
        self.assertIn('a', community['members'])
        self.assertIsNone(kgraph.community_for_node(graph, 'no-such-node'))


class CommunityViewTests(unittest.TestCase):
    """``community_view`` — the read path kgraph_community is built on."""

    def test_summary_reads_the_cached_digest_rather_than_recomputing(self):
        # A digest whose membership no detection could produce: if the view
        # recomputed, these ids could not appear.
        graph = kgraph.Graph.from_dict({
            'nodes': [{'id': 'a', 'label': 'A'}],
            'edges': [],
            'meta': {'community_method': 'cached-greedy',
                     'communities': [{'id': 'community_0', 'label': 'Cached · Theme',
                                      'size': 1, 'members': ['a'],
                                      'central_nodes': [{'id': 'a', 'label': 'A',
                                                         'composite_score': 0.5}],
                                      'god_nodes': [], 'boundary_edges': [],
                                      'boundary_edge_count': 0}]},
        })
        result = kgraph.community_view(graph)
        self.assertEqual(result['source'], 'digest')
        self.assertEqual(result['method'], 'cached-greedy')
        self.assertEqual([c['label'] for c in result['communities']], ['Cached · Theme'])
        self.assertEqual(result['communities'][0]['central_nodes'][0]['id'], 'a')

    def test_single_community_returns_members_and_boundary_edges(self):
        graph = kgraph.digest_communities(
            kgraph.detect_communities(_TWO_CLUSTER_GRAPH, method='greedy'))
        community_id = graph.meta.communities[0]['id']
        result = kgraph.community_view(graph, community_id)
        self.assertEqual(result['source'], 'digest')
        self.assertEqual(result['community']['id'], community_id)
        self.assertIn('members', result['community'])
        self.assertIn('boundary_edges', result['community'])

    def test_unknown_community_id_reports_the_ids_it_does_have(self):
        graph = self._cached()
        result = kgraph.community_view(graph, 'community_99')
        self.assertIn('error', result)
        self.assertEqual(result['community_ids'], ['community_0'])

    def test_a_graph_with_no_cached_digest_computes_and_says_so(self):
        result = kgraph.community_view(_TWO_CLUSTER_GRAPH)
        self.assertEqual(result['source'], 'computed')
        self.assertGreater(result['count'], 0)

    @staticmethod
    def _cached():
        return kgraph.Graph.from_dict({
            'nodes': [{'id': 'a', 'label': 'A'}],
            'meta': {'communities': [{'id': 'community_0', 'label': 'T', 'size': 1,
                                      'members': ['a']}]},
        })


class CommunityDigestPersistenceTests(unittest.TestCase):
    """The digest is cached WITH the graph, so a read is a read."""

    def test_save_and_load_round_trip_the_digest(self):
        from kgraph.graph_db import load_from_graph_db, read_community_digest, save_to_graph_db

        graph = kgraph.digest_communities(
            kgraph.detect_communities(_TWO_CLUSTER_GRAPH, method='greedy'))
        with tempfile.TemporaryDirectory() as td:
            db = os.path.join(td, 'graph.sqlite')
            save_to_graph_db(db, graph)
            digest = read_community_digest(db)
            loaded = load_from_graph_db(db)
        self.assertIsNotNone(digest)
        assert digest is not None  # narrows for the type checker
        self.assertEqual(digest['method'], graph.meta.community_method)
        self.assertEqual([c['id'] for c in loaded.meta.communities],
                         [c['id'] for c in graph.meta.communities])
        self.assertEqual(loaded.meta.communities[0]['central_nodes'],
                         graph.meta.communities[0]['central_nodes'])
        self.assertEqual(loaded.meta.community_method, graph.meta.community_method)

    def test_saving_without_communities_clears_a_stale_digest(self):
        """A graph with no communities must not leave the old digest behind."""
        from kgraph.graph_db import (load_from_graph_db, read_community_digest,
                                     save_to_graph_db)

        graph = kgraph.digest_communities(
            kgraph.detect_communities(_TWO_CLUSTER_GRAPH, method='greedy'))
        with tempfile.TemporaryDirectory() as td:
            db = os.path.join(td, 'graph.sqlite')
            save_to_graph_db(db, graph)
            self.assertIsNotNone(read_community_digest(db))
            save_to_graph_db(db, {'nodes': [{'id': 'a', 'label': 'A'}], 'edges': []})
            self.assertIsNone(read_community_digest(db))
            self.assertEqual(load_from_graph_db(db).meta.communities, [])

    def test_a_graph_written_before_the_digest_existed_reads_as_no_communities(self):
        from kgraph.graph_db import init_graph_db, load_from_graph_db

        with tempfile.TemporaryDirectory() as td:
            db = os.path.join(td, 'graph.sqlite')
            init_graph_db(db)
            conn = sqlite3.connect(db)
            try:
                conn.execute("INSERT INTO graph_nodes(id, label, payload) VALUES (?, ?, ?)",
                             ('a', 'Alpha', '{"type": "topic"}'))
                conn.commit()
            finally:
                conn.close()
            loaded = load_from_graph_db(db)
        self.assertEqual(loaded.meta.communities, [])
        self.assertEqual([n.id for n in loaded.nodes], ['a'])

    def test_report_renders_the_cached_digest_without_recomputing(self):
        from kgraph import report

        graph = self._cached()
        with mock.patch.object(report, 'detect_communities',
                               side_effect=AssertionError('report recomputed communities')):
            text = report.generate_report(graph)
        self.assertIn('- **Cached · Theme** — 1 members', text)
        self.assertIn('central: Alpha', text)
        self.assertIn('- **Communities detected:** 1', text)

    def test_incremental_update_writes_a_digest_a_later_read_uses(self):
        """--update caches the digest; the reload answers from it, not by computing."""
        from kgraph.update import incremental_update

        with tempfile.TemporaryDirectory() as td:
            src = os.path.join(td, 'repo')
            os.makedirs(src)
            with open(os.path.join(src, 'lib.py'), 'w', encoding='utf-8') as f:
                f.write('"""lib."""\ndef helper() -> int:\n    return 1\n')
            with open(os.path.join(src, 'main.py'), 'w', encoding='utf-8') as f:
                f.write('"""main."""\nfrom lib import helper\n\n'
                        'def run() -> int:\n    return helper()\n')
            db_path = os.path.join(td, 'graph.sqlite')
            incremental_update(db_path, mem_db_path=os.path.join(td, 'missing.sqlite'),
                               source_dir=src, ast=True, include_all=True)
            loaded = kgraph.load_from_graph_db(db_path)
            self.assertTrue(loaded.meta.communities,
                            '--update left no community digest for a 2-file repo')
            result = kgraph.community_view(loaded.to_dict())
            self.assertEqual(result['source'], 'digest')
            # The cache carries the method it was built with, not a default.
            self.assertEqual(loaded.meta.community_method, 'leiden_like')

    @staticmethod
    def _cached():
        return kgraph.Graph.from_dict({
            'nodes': [{'id': 'a', 'label': 'Alpha', 'type': 'topic'}],
            'meta': {'communities': [{'id': 'community_0', 'label': 'Cached · Theme',
                                      'size': 1, 'members': ['a'],
                                      'central_nodes': [{'id': 'a', 'label': 'Alpha',
                                                         'composite_score': 0.5}],
                                      'god_nodes': [], 'boundary_edges': [],
                                      'boundary_edge_count': 0}]},
        })


class CommunityDigestValidationTests(unittest.TestCase):
    def test_a_digest_naming_absent_nodes_is_reported_as_stale(self):
        from kgraph.validate import validate_graph

        findings = validate_graph({
            'nodes': [{'id': 'a', 'label': 'A'}],
            'meta': {'communities': [{'id': 'community_0', 'label': 'T', 'size': 2,
                                      'members': ['a', 'ghost']}]},
        })
        warnings = [f['message'] for f in findings if f['severity'] == 'warning']
        self.assertTrue(any('stale' in msg and 'ghost' in msg for msg in warnings), warnings)
        # A stale digest is a warning, never a rejection: the payload is valid.
        self.assertFalse([f for f in findings if f['severity'] == 'error'])

    def test_a_fresh_digest_produces_no_staleness_finding(self):
        from kgraph.validate import validate_graph

        findings = validate_graph({
            'nodes': [{'id': 'a', 'label': 'A'}],
            'meta': {'communities': [{'id': 'community_0', 'label': 'T', 'size': 1,
                                      'members': ['a']}]},
        })
        self.assertFalse([f for f in findings if 'stale' in f.get('message', '')])


# ══════════════ GRAPHRAG-ARCH-007: source lineage ══════════════


class SourceLineageReadPathTests(unittest.TestCase):
    """Lineage is returned per edge, and an element without it does not crash."""

    def test_explain_node_returns_sources_per_edge(self):
        graph = {
            'nodes': [{'id': 'a', 'label': 'Alpha'}, {'id': 'b', 'label': 'Beta'},
                      {'id': 'c', 'label': 'Gamma'}],
            'edges': [
                {'from': 'a', 'to': 'b', 'label': 'links', 'sources': ['file:one.md']},
                {'from': 'a', 'to': 'c', 'label': 'links',
                 'sources': ['file:one.md', 'memory:m1']},
            ],
        }
        explanation = kgraph.explain_node(graph, 'a')
        by_target = {c['target']: c for c in explanation['outbound_connections']}
        self.assertEqual(by_target['b']['sources'], ['file:one.md'])
        self.assertEqual(by_target['c']['sources'], ['file:one.md', 'memory:m1'])

    def test_explain_node_reports_a_missing_source_list_as_empty(self):
        """An edge written before the field existed must not crash the reader."""
        graph = {
            'nodes': [{'id': 'a', 'label': 'Alpha'}, {'id': 'b', 'label': 'Beta'}],
            'edges': [{'from': 'a', 'to': 'b', 'label': 'links'}],
        }
        explanation = kgraph.explain_node(graph, 'a')
        self.assertEqual(explanation['outbound_connections'][0]['sources'], [])
        self.assertIsNone(explanation['node']['community'])

    def test_explain_node_names_the_nodes_community(self):
        graph = kgraph.Graph.from_dict({
            'nodes': [{'id': 'a', 'label': 'Alpha'}],
            'meta': {'communities': [{'id': 'community_0', 'label': 'Cached · Theme',
                                      'size': 1, 'members': ['a']}]},
        })
        explanation = kgraph.explain_node(graph, 'a')
        self.assertEqual(explanation['node']['community'],
                         {'id': 'community_0', 'label': 'Cached · Theme', 'size': 1})
        self.assertIn('Community: Cached · Theme (community_0, 1 members)',
                      kgraph.format_explain(explanation))

    def test_format_explain_prints_the_asserting_source(self):
        graph = {
            'nodes': [{'id': 'a', 'label': 'Alpha'}, {'id': 'b', 'label': 'Beta'}],
            'edges': [{'from': 'a', 'to': 'b', 'label': 'links', 'sources': ['file:one.md']}],
        }
        text = kgraph.format_explain(kgraph.explain_node(graph, 'a'))
        self.assertIn('source: file:one.md', text)


class SourceLineagePersistenceTests(unittest.TestCase):
    def test_round_trip_preserves_sources_and_the_version_stamp(self):
        from kgraph.graph_db import (load_from_graph_db, read_sources_version,
                                     save_to_graph_db)
        from kgraph.constants import SOURCES_VERSION

        with tempfile.TemporaryDirectory() as td:
            db = os.path.join(td, 'graph.sqlite')
            save_to_graph_db(db, {
                'nodes': [{'id': 'a', 'label': 'Alpha', 'sources': ['file:one.md']}],
                'edges': [{'from': 'a', 'to': 'b', 'label': 'links',
                           'sources': ['file:one.md']}],
            })
            self.assertEqual(read_sources_version(db), SOURCES_VERSION)
            loaded = load_from_graph_db(db)
        self.assertEqual(loaded.nodes[0].sources, ['file:one.md'])
        self.assertEqual(loaded.edges[0].sources, ['file:one.md'])

    def test_a_row_without_sources_loads_as_unknown_and_is_announced(self):
        from kgraph.graph_db import init_graph_db, load_from_graph_db

        with tempfile.TemporaryDirectory() as td:
            db = os.path.join(td, 'graph.sqlite')
            init_graph_db(db)
            conn = sqlite3.connect(db)
            try:
                # A graph written before the lineage field existed: no
                # sources_version stamp and no sources key in the payload.
                conn.execute("INSERT INTO graph_nodes(id, label, payload) VALUES (?, ?, ?)",
                             ('a', 'Alpha', '{"type": "topic"}'))
                conn.execute("INSERT INTO graph_edges(source, target, label, payload)"
                             " VALUES (?, ?, ?, ?)", ('a', 'b', 'links', None))
                conn.commit()
            finally:
                conn.close()
            with self.assertLogs('kgraph.graph_db', level='WARNING') as captured:
                loaded = load_from_graph_db(db)
        self.assertEqual(loaded.nodes[0].sources, [])
        self.assertEqual(loaded.edges[0].sources, [])
        self.assertTrue(any('no source lineage' in line for line in captured.output),
                        captured.output)

    def test_removing_a_source_from_the_persisted_graph_subtracts_one(self):
        from kgraph.graph_db import load_from_graph_db, save_to_graph_db

        with tempfile.TemporaryDirectory() as td:
            db = os.path.join(td, 'graph.sqlite')
            save_to_graph_db(db, {
                'nodes': [
                    {'id': 'a', 'label': 'Alpha', 'sources': ['file:one.md']},
                    {'id': 'b', 'label': 'Beta', 'sources': ['file:one.md', 'file:two.md']},
                ],
                'edges': [{'from': 'b', 'to': 'a', 'label': 'links',
                           'sources': ['file:one.md']}],
            })
            graph = load_from_graph_db(db)
            graph.remove_source('file:one.md')
            save_to_graph_db(db, graph)
            reloaded = load_from_graph_db(db)
        self.assertEqual([n.id for n in reloaded.nodes], ['b'])
        self.assertEqual(reloaded.nodes[0].sources, ['file:two.md'])
        self.assertEqual(reloaded.edges, [])


class AstSourceLineageTests(unittest.TestCase):
    def test_ast_nodes_and_edges_carry_the_defining_file_as_source(self):
        with tempfile.TemporaryDirectory() as td:
            src = os.path.join(td, 'repo')
            os.makedirs(src)
            with open(os.path.join(src, 'lib.sh'), 'w', encoding='utf-8') as f:
                f.write('function helper() { echo hi; }\n')
            with open(os.path.join(src, 'main.sh'), 'w', encoding='utf-8') as f:
                f.write('helper\n')
            graph = kgraph.extract_repo_graph(src)

        nodes = {n['id']: n for n in graph['nodes']}
        self.assertEqual(nodes['ast_file:lib-sh']['sources'], ['file:lib.sh'])
        self.assertEqual(nodes['ast_func:bash:helper']['sources'], ['file:lib.sh'])
        # A name-keyed call node aggregates every caller, so it carries no source.
        self.assertEqual(nodes['ast_call:bash:helper']['sources'], [])

        edges = {(e['source'], e['target'], e.get('label')): e for e in graph['edges']}
        self.assertEqual(edges[('ast_file:lib-sh', 'ast_func:bash:helper', 'defines')]['sources'],
                         ['file:lib.sh'])
        self.assertEqual(edges[('ast_file:main-sh', 'ast_call:bash:helper', 'calls')]['sources'],
                         ['file:main.sh'])
        # Derived by name resolution, not asserted by a document.
        self.assertEqual(edges[('ast_call:bash:helper', 'ast_func:bash:helper', 'calls')]['sources'],
                         [])

    def test_ast_source_key_is_repo_relative_not_absolute(self):
        with tempfile.TemporaryDirectory() as td:
            src = os.path.join(td, 'repo')
            os.makedirs(os.path.join(src, 'nested'))
            with open(os.path.join(src, 'nested', 'lib.sh'), 'w', encoding='utf-8') as f:
                f.write('function helper() { echo hi; }\n')
            graph = kgraph.extract_repo_graph(src)
        node = next(n for n in graph['nodes'] if n['id'].startswith('ast_file:'))
        self.assertEqual(node['sources'], ['file:nested/lib.sh'])
        self.assertNotIn(str(src), node['sources'][0])


class MemoryRegistrySourceLineageTests(unittest.TestCase):
    """The registry ingest path populates sources on records, nodes and edges."""

    def _import(self, path, include_all=False):
        import kgraph.memory_import as mi
        from kgraph.models import GraphBuilder

        conn = sqlite3.connect(path)
        builder = GraphBuilder()
        try:
            mi._load_from_registry_db(conn, builder, registry='home', include_all=include_all)
        finally:
            conn.close()
        return builder.build()

    def test_memory_and_chunk_records_name_themselves_as_sources(self):
        with tempfile.TemporaryDirectory() as td:
            path = os.path.join(td, 'registry.sqlite')
            TestRegistryAdapter()._make_registry(path)
            graph = self._import(path)
        nodes = {n.id: n for n in graph.nodes}
        self.assertEqual(nodes['memory:mem-1'].sources, ['memory:mem-1'])
        self.assertEqual(nodes['memory:native:chunk-1'].sources, ['chunk:chunk-1'])
        # A claim is consolidated out of its memory, so the memory asserts it.
        self.assertEqual(nodes['claim:mem-1:slot-1'].sources, ['memory:mem-1'])
        self.assertEqual(nodes['belief:bel-1'].sources, ['memory:mem-1'])

    def test_derived_edges_carry_the_record_that_asserted_them(self):
        with tempfile.TemporaryDirectory() as td:
            path = os.path.join(td, 'registry.sqlite')
            TestRegistryAdapter()._make_registry(path)
            graph = self._import(path)
        edges = {(e.source, e.target, e.label): e for e in graph.edges}
        # The native chunk (not a uuid) is what mentioned the actor.
        self.assertEqual(edges[('memory:native:chunk-1', 'entity:hal', 'mentions')].sources,
                         ['chunk:chunk-1'])
        self.assertEqual(edges[('memory:mem-1', 'claim:mem-1:slot-1', 'claims')].sources,
                         ['memory:mem-1'])

    def test_entity_relationship_evidence_is_lifted_out_of_metadata(self):
        with tempfile.TemporaryDirectory() as td:
            path = os.path.join(td, 'registry.sqlite')
            TestRegistryAdapter()._make_registry(path)
            conn = sqlite3.connect(path)
            try:
                conn.execute("INSERT INTO memory_entity_relationships VALUES (?,?,?,?,?,?)",
                             ('a', 'b', 'related_to', 2, '["mem-1", "native:chunk-1"]', 0.8))
                conn.commit()
            finally:
                conn.close()
            graph = self._import(path)
        edge = next(e for e in graph.edges if (e.source, e.target) == ('entity:a', 'entity:b'))
        self.assertEqual(edge.sources, ['chunk:chunk-1', 'memory:mem-1'])

    def test_unparseable_evidence_leaves_the_edge_without_lineage(self):
        with tempfile.TemporaryDirectory() as td:
            path = os.path.join(td, 'registry.sqlite')
            TestRegistryAdapter()._make_registry(path)
            conn = sqlite3.connect(path)
            try:
                conn.execute("INSERT INTO memory_entity_relationships VALUES (?,?,?,?,?,?)",
                             ('a', 'b', 'related_to', 1, '{not json}', 0.5))
                conn.commit()
            finally:
                conn.close()
            graph = self._import(path)
        edge = next(e for e in graph.edges if (e.source, e.target) == ('entity:a', 'entity:b'))
        self.assertEqual(edge.sources, [])


class SourceLineageCliTests(unittest.TestCase):
    def test_remove_source_subcommand_subtracts_one_and_reports_counts(self):
        from kgraph.graph_db import load_from_graph_db, save_to_graph_db

        with tempfile.TemporaryDirectory() as td:
            db = os.path.join(td, 'graph.sqlite')
            save_to_graph_db(db, {
                'nodes': [
                    {'id': 'a', 'label': 'Alpha', 'sources': ['file:one.md']},
                    {'id': 'b', 'label': 'Beta', 'sources': ['file:two.md']},
                ],
                'edges': [{'from': 'b', 'to': 'a', 'label': 'links', 'sources': ['file:two.md']}],
            })
            result = subprocess.run(
                [sys.executable, '-m', 'kgraph', '--graph-db', db,
                 '--remove-source', 'file:one.md'],
                cwd=SCRIPT_DIR, capture_output=True, text=True,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("Removed source 'file:one.md'", result.stdout)
            self.assertIn('1 nodes deleted', result.stdout)
            reloaded = load_from_graph_db(db)
        self.assertEqual([n.id for n in reloaded.nodes], ['b'])
        self.assertEqual(reloaded.edges, [])
