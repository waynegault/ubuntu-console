"""Shared fixtures for the kgraph test modules.

``_AST_GRAPH``, ``_SMALL_GRAPH`` and ``_FakeHTTPServer`` were split out of the
former ``tests/test_untested_modules.py`` so each per-module test file can import
them without duplication.  Importing this module also runs the ``_paths``
bootstrap that puts the repo's ``scripts/`` directory on ``sys.path``, so a test
module need only import a fixture (or ``kgraph`` directly) to get ``import
kgraph`` working.
"""

import os

from _paths import SCRIPT_DIR

# `_paths` puts the repo's scripts/ on sys.path; assert the bootstrap ran rather
# than letting a later `import kgraph` fail with a confusing ImportError.
if not os.path.isdir(SCRIPT_DIR):
    raise RuntimeError(f"kgraph scripts/ dir not found: {SCRIPT_DIR}")

_AST_GRAPH = {
    "nodes": [
        {"id": "ast_file:main_py", "label": "main.py", "type": "file", "source": "ast"},
        {"id": "ast_func:hello", "label": "hello", "type": "function", "source": "ast", "language": "python"},
        {"id": "ast_class:greeter", "label": "Greeter", "type": "class", "source": "ast", "language": "python"},
        {"id": "ast_module:os", "label": "os", "type": "module", "source": "ast"},
        {"id": "ast_call:print", "label": "print", "type": "call", "source": "ast"},
    ],
    "edges": [
        {"from": "ast_file:main_py", "to": "ast_func:hello", "label": "defines"},
        {"from": "ast_file:main_py", "to": "ast_class:greeter", "label": "defines"},
        {"from": "ast_file:main_py", "to": "ast_module:os", "label": "imports"},
        {"from": "ast_file:main_py", "to": "ast_call:print", "label": "calls"},
        {"from": "ast_func:hello", "to": "ast_call:print", "label": "calls"},
    ],
}

_SMALL_GRAPH = {
    "nodes": [
        {"id": "a", "label": "Alpha", "type": "topic"},
        {"id": "b", "label": "Beta", "type": "project"},
        {"id": "c", "label": "Gamma", "type": "decision"},
    ],
    "edges": [
        {"from": "a", "to": "b", "label": "project topic", "semantic_score": 0.9},
        {"from": "b", "to": "c", "label": "project decision", "semantic_score": 0.85},
    ],
}


class _FakeHTTPServer:
    """Captures the handler class serve_file builds, without listening."""

    captured: dict = {}

    def __init__(self, addr, handler):
        _FakeHTTPServer.captured["handler"] = handler
        self.server_address = (addr[0], addr[1] or 1)

    def serve_forever(self):
        pass

    def shutdown(self):
        pass

# end of file
