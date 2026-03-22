import importlib.util
import os
import subprocess
import sys
import tempfile
import unittest


REPO_ROOT = os.path.dirname(os.path.dirname(__file__))
SCRIPT_PATH = os.path.join(REPO_ROOT, 'scripts', 'kgraph.py')


def load_kgraph_module():
    spec = importlib.util.spec_from_file_location('kgraph', SCRIPT_PATH)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


class KGraphTests(unittest.TestCase):
    def test_generate_html_contains_cytoscape_markup(self):
        self.assertTrue(os.path.exists(SCRIPT_PATH), f'kgraph script not found at {SCRIPT_PATH}')

        with tempfile.TemporaryDirectory() as td:
            out = os.path.join(td, 'nested', 'kgraph.html')
            subprocess.run([sys.executable, SCRIPT_PATH, '--output', out], check=True)

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

    def test_install_supports_basename_target(self):
        with tempfile.TemporaryDirectory() as td:
            out = os.path.join(td, 'kgraph.py')
            subprocess.run([sys.executable, SCRIPT_PATH, '--install', out], check=True, cwd=td)
            self.assertTrue(os.path.exists(out))


if __name__ == '__main__':
    unittest.main()
