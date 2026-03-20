import os
import sys
import tempfile
import subprocess


def test_generate_html_contains_vis_and_manipulation():
    repo_root = os.path.dirname(os.path.dirname(__file__))
    script = os.path.join(repo_root, 'scripts', 'kgraph.py')
    assert os.path.exists(script), f"kgraph script not found at {script}"

    with tempfile.TemporaryDirectory() as td:
        out = os.path.join(td, 'kgraph.html')
        # Run the script to generate HTML
        res = subprocess.run([sys.executable, script, '--output', out], check=True)
        assert os.path.exists(out), 'Output HTML not created'
        txt = open(out, 'r', encoding='utf-8').read()
        # Cytoscape-based UI should be present
        assert 'cytoscape' in txt.lower()
        assert 'Knowledge Graph (Cytoscape)' in txt
