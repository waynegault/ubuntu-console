"""HTML template generation for the knowledge graph viewer.

The Cytoscape.js frontend template lives in ``templates/kgraph.html``.
This module loads it at import time and provides ``generate_html()``
to inject graph data and write the output file.
"""

from __future__ import annotations

import json
import os

_TEMPLATE_PATH = os.path.join(os.path.dirname(__file__), "templates", "kgraph.html")


def _load_template() -> str:
    try:
        with open(_TEMPLATE_PATH, "r", encoding="utf-8") as f:
            return f.read()
    except OSError:
        return "<html><body><h1>Template not found</h1><p>Expected at %s</p></body></html>" % _TEMPLATE_PATH


HTML_TMPL = _load_template()


def ensure_parent_dir(path: str) -> None:
    parent = os.path.dirname(os.path.abspath(os.path.expanduser(path)))
    if parent:
        os.makedirs(parent, exist_ok=True)


def generate_html(graph: dict, outpath: str) -> None:
    payload = json.dumps(graph)
    html = HTML_TMPL.replace("%s", payload, 1)
    ensure_parent_dir(outpath)
    with open(outpath, "w", encoding="utf-8") as f:
        f.write(html)