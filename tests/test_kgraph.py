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


if __name__ == '__main__':
    unittest.main()
