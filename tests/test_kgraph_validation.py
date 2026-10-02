"""Tests for kgraph's two validation gaps (card 79d69304).

1. ``server._resolve_graph``'s json-store branch returned ``json.load(f)`` RAW,
   unlike the memory-db / graph-db branches which return ``Graph.from_dict(...)``
   models.  A malformed store was therefore handed straight to ``project_graph``.
2. ``cli._load_graph`` validated the ``--graph`` file with ``Graph.from_dict`` and
   then returned the RAW dict, discarding the model it had just built.

Both tests feed a MALFORMED payload and assert it is rejected (or that the
validated model is the thing returned); the pre-fix code accepts/rejects them
differently — see the docstrings for the exact wrong outcome each catches.
"""

from __future__ import annotations

import argparse
import json
import os
import tempfile
from unittest import mock

from _paths import SCRIPT_DIR

import kgraph


class _FakeHTTPServer:
    """Captures the handler class serve_file builds, without listening.

    Mirrors the stub in tests/test_untested_modules.py: serve_file blocks in
    serve_forever, so its (module-local) HTTPServer is replaced to obtain the real
    handler class.  Only the module-local name is patched.
    """

    captured: dict = {}

    def __init__(self, addr, handler):
        _FakeHTTPServer.captured["handler"] = handler
        self.server_address = (addr[0], addr[1] or 1)

    def serve_forever(self):
        pass

    def shutdown(self):
        pass


def test_kgraph_is_importable_from_the_repo_scripts_dir() -> None:
    """The bootstrap the other tests rely on really put the package on sys.path.

    Catches: a broken/relocated scripts/ dir making `import kgraph` succeed for the
    wrong reason (an unrelated installed package).
    """
    assert os.path.isfile(os.path.join(SCRIPT_DIR, "kgraph", "__init__.py"))


def _handler_class(store_path: str, graph_db_path: str | None = None):
    """Build the REAL handler class serve_file constructs, without listening."""
    from kgraph import server as kgraph_server

    captured: dict = {}
    _FakeHTTPServer.captured = captured
    with (
        mock.patch.object(kgraph_server, "HTTPServer", _FakeHTTPServer),
        mock.patch.object(kgraph_server, "webbrowser"),
        mock.patch.object(kgraph_server, "resolve_memory_db_path", return_value=None),
    ):
        kgraph_server.serve_file(
            store_path, host="127.0.0.1", force_embed=True,
            graph_db_path=graph_db_path, store_path=store_path,
        )
    # serve_file hands HTTPServer a partial(GraphRequestHandler, directory=...),
    # so unwrap to the class itself.
    handler = captured["handler"]
    return getattr(handler, "func", handler)


def _resolve_graph(handler_cls, store_path: str, graph_db_path: str | None = None):
    """Call the real _resolve_graph on a bare instance (no socket, no __init__)."""
    handler = object.__new__(handler_cls)
    handler.memory_db = None
    handler.graph_db = graph_db_path
    handler.store = store_path
    return handler_cls._resolve_graph(handler, False)


def test_malformed_json_store_is_rejected_not_projected() -> None:
    """A schema-invalid json-store must fall through to the sample graph.

    Catches: the pre-fix json-store branch returning the raw payload — `source`
    was "json-store" and project_graph received a malformed graph.  The payload
    used is an edge with no endpoints, the exact provenance-tag shape the CLI's
    own validator names.
    """
    with tempfile.TemporaryDirectory() as td:
        store = os.path.join(td, "bad-store.json")
        with open(store, "w", encoding="utf-8") as f:
            json.dump({"nodes": [], "edges": [{"label": "asserts"}]}, f)

        handler_cls = _handler_class(store)
        graph, source = _resolve_graph(handler_cls, store)

        assert source != "json-store", "a malformed json-store was projected, not rejected"
        assert source == "sample"
        assert graph == kgraph.SAMPLE_GRAPH


def test_valid_json_store_is_still_served() -> None:
    """The control: a valid store is still served from "json-store".

    Catches: a "fix" that rejects every json-store (e.g. a blanket refusal),
    which would break the fallback chain's last real source.
    """
    with tempfile.TemporaryDirectory() as td:
        store = os.path.join(td, "ok-store.json")
        with open(store, "w", encoding="utf-8") as f:
            json.dump({"nodes": [], "edges": []}, f)

        handler_cls = _handler_class(store)
        graph, source = _resolve_graph(handler_cls, store)

        assert source == "json-store"
        assert graph.get("nodes") == []
        assert graph.get("edges") == []


def test_cli_graph_path_returns_the_validated_model() -> None:
    """_load_graph must USE the model it validated, not discard it.

    Catches: the pre-fix `return data`.  The legacy ``_meta`` key alone does NOT
    distinguish the two — the model's validator mutates its input dict in place,
    so the raw dict already shows ``meta``.  What the raw dict never has is the
    SCHEMA's defaults, which only ``Graph.to_dict()`` supplies: a node carrying
    just an id comes back with the model's default ``type``.
    """
    from kgraph import cli

    with tempfile.TemporaryDirectory() as td:
        path = os.path.join(td, "graph.json")
        with open(path, "w", encoding="utf-8") as f:
            json.dump({"nodes": [{"id": "n1"}], "edges": [], "_meta": {"view_mode": "topics"}}, f)

        args = argparse.Namespace(graph=path, graph_db=None, import_db=None)
        result = cli._load_graph(args)

        assert result["meta"]["view_mode"] == "topics"
        # Only the validated model's to_dict() fills this default; the raw file had
        # a node with no `type` at all.
        assert result["nodes"][0]["type"] == "unknown"
