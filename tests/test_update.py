"""Tests for kgraph.update — incremental rebuild, AST/memory merge, and watch mode."""

import contextlib
import io
import os
import tempfile
import unittest
from unittest import mock

from _kgraph_fixtures import _SMALL_GRAPH
import kgraph


class TestUpdate(unittest.TestCase):
    def test_merge_graphs_deduplicates(self):
        base = {"nodes": [{"id": "a", "label": "A"}], "edges": []}
        overlay = {
            "nodes": [{"id": "a", "label": "A"}, {"id": "b", "label": "B"}],
            "edges": [{"from": "a", "to": "b", "label": "links"}],
        }
        merged = kgraph.merge_graphs(base, overlay)
        node_ids = {n.id for n in merged.nodes}
        self.assertEqual(node_ids, {"a", "b"})
        self.assertEqual(len(merged.edges), 1)

    def test_merge_graphs_empty_overlay(self):
        base = {"nodes": [{"id": "a", "label": "A"}], "edges": []}
        merged = kgraph.merge_graphs(base, {"nodes": [], "edges": []})
        self.assertEqual(len(merged.nodes), 1)

    def test_merge_graphs_empty_base(self):
        overlay = {"nodes": [{"id": "x", "label": "X"}], "edges": []}
        merged = kgraph.merge_graphs({"nodes": [], "edges": []}, overlay)
        self.assertEqual(len(merged.nodes), 1)

    def test_incremental_update_round_trip(self):
        with tempfile.TemporaryDirectory() as td:
            db_path = os.path.join(td, "graph.sqlite")
            # Seed with initial data
            kgraph.save_to_graph_db(db_path, _SMALL_GRAPH)
            # Run incremental update (no memory DB, no AST)
            result = kgraph.incremental_update(db_path, ast=False)
            self.assertGreater(len(result.nodes), 0)


class TestUpdateIncremental(unittest.TestCase):
    def _seed(self, td, graph=None):
        db = os.path.join(td, "graph.sqlite")
        kgraph.save_to_graph_db(db, graph if graph is not None else _SMALL_GRAPH)
        return db

    def test_merges_memory_dbs_surviving_a_failing_one(self):
        with tempfile.TemporaryDirectory() as td:
            db = self._seed(td)
            mem = os.path.join(td, "mem.sqlite")
            with open(mem, "w", encoding="utf-8") as f:
                f.write("")  # exists, so it is handed to load_from_memory_db
            with (
                mock.patch("kgraph.memory_import.load_from_memory_db",
                           side_effect=ValueError("bad db")),
                mock.patch("kgraph.update.logger") as log,
            ):
                result = kgraph.incremental_update(db, mem_db_path=mem, ast=False)
            log.warning.assert_called()
            self.assertGreater(len(result.nodes), 0)

    def test_merges_a_successful_memory_db(self):
        with tempfile.TemporaryDirectory() as td:
            db = self._seed(td, {"nodes": [], "edges": []})
            mem = os.path.join(td, "mem.sqlite")
            with open(mem, "w", encoding="utf-8") as f:
                f.write("")
            mem_graph = {"nodes": [{"id": "m1", "label": "From memory",
                                    "type": "memory"}], "edges": []}
            with mock.patch("kgraph.memory_import.load_from_memory_db",
                            return_value=mem_graph) as load_mem:
                result = kgraph.incremental_update(db, mem_db_path=mem, ast=False,
                                                   include_all=True)
            self.assertEqual(load_mem.call_args.kwargs.get("include_all"), True)
            self.assertIn("m1", {n.id for n in result.nodes})

    def test_expands_a_tilde_memory_db_path_before_the_exists_check(self):
        with tempfile.TemporaryDirectory() as td:
            db = self._seed(td)
            home = os.path.join(td, "home")
            os.makedirs(home)
            real = os.path.join(home, "mem.sqlite")
            with open(real, "w", encoding="utf-8") as f:
                f.write("")
            with (
                mock.patch.dict(os.environ, {"HOME": home}),
                mock.patch("kgraph.memory_import.load_from_memory_db",
                           return_value={"nodes": [], "edges": []}) as load_mem,
                mock.patch("kgraph.graph_db.resolve_all_memory_db_paths") as resolve,
            ):
                resolve.return_value = []
                kgraph.incremental_update(db, mem_db_path="~/mem.sqlite", ast=False)
            self.assertEqual(load_mem.call_args.args[0], real)

    def test_prunes_stale_ast_nodes_from_the_persisted_graph(self):
        with tempfile.TemporaryDirectory() as td:
            seeded = {
                "nodes": [
                    {"id": "a", "label": "Alpha", "type": "topic"},
                    {"id": "ast_func:gone", "label": "gone", "type": "function",
                     "source": "ast"},
                ],
                "edges": [{"from": "ast_func:gone", "to": "a", "label": "calls"}],
            }
            db = self._seed(td, seeded)
            with mock.patch("kgraph.graph_db.resolve_all_memory_db_paths", return_value=[]):
                result = kgraph.incremental_update(db, ast=False)
            self.assertIn("a", {n.id for n in result.nodes})
            self.assertNotIn("ast_func:gone", {n.id for n in result.nodes})

    def test_merges_ast_extraction_output(self):
        with tempfile.TemporaryDirectory() as td:
            db = self._seed(td, {"nodes": [], "edges": []})
            src = os.path.join(td, "src")
            os.makedirs(src)
            ast_graph = {
                "nodes": [{"id": "ast_func:x", "label": "x", "type": "function",
                           "source": "ast"}],
                "edges": [],
            }
            with (
                mock.patch("kgraph.graph_db.resolve_all_memory_db_paths", return_value=[]),
                mock.patch("kgraph.ast_extractor.ast_available", return_value=True),
                mock.patch("kgraph.ast_extractor.extract_repo_graph",
                           return_value=ast_graph) as extract,
            ):
                result = kgraph.incremental_update(db, source_dir=src, ast=True)
            extract.assert_called_once()
            self.assertIn("ast_func:x", {n.id for n in result.nodes})

    def test_survives_an_ast_extraction_failure(self):
        with tempfile.TemporaryDirectory() as td:
            db = self._seed(td, {"nodes": [], "edges": []})
            src = os.path.join(td, "src")
            os.makedirs(src)
            with (
                mock.patch("kgraph.graph_db.resolve_all_memory_db_paths", return_value=[]),
                mock.patch("kgraph.ast_extractor.ast_available", return_value=True),
                mock.patch("kgraph.ast_extractor.extract_repo_graph",
                           side_effect=ValueError("no parser")),
                mock.patch("kgraph.update.logger") as log,
            ):
                result = kgraph.incremental_update(db, source_dir=src, ast=True)
            log.warning.assert_called()
            self.assertEqual(len(result.nodes), 0)


class _StubTime:
    """Module-local stand-in for update.py's `time` (see the test below)."""

    def __init__(self, on_first_tick, on_second_tick):
        self.ticks = 0
        self._first = on_first_tick
        self._second = on_second_tick

    def sleep(self, _interval):
        self.ticks += 1
        if self.ticks == 1:
            self._first()
            return
        raise KeyboardInterrupt

    def strftime(self, _fmt):
        self._second()


class TestStartWatch(unittest.TestCase):
    def test_rebuilds_when_the_source_changes(self):
        from kgraph import update

        with tempfile.TemporaryDirectory() as td:
            db = os.path.join(td, "graph.sqlite")
            src = os.path.join(td, "src")
            os.makedirs(src)
            note = os.path.join(src, "a.py")
            with open(note, "w", encoding="utf-8") as f:
                f.write("x = 1\n")
            kgraph.save_to_graph_db(db, _SMALL_GRAPH)

            def touch_note():
                with open(note, "w", encoding="utf-8") as f:
                    f.write("x = 2\n")

            # Patch update.py's module-local `time` rather than the global time
            # module: only this module's use of sleep/strftime is replaced.
            stub = _StubTime(touch_note, lambda: None)
            stdout = io.StringIO()
            with (
                mock.patch.object(update, "time", stub),
                mock.patch.object(update, "incremental_update") as upd,
                mock.patch("kgraph.graph_db.resolve_all_memory_db_paths", return_value=[]),
            ):
                with contextlib.redirect_stdout(stdout):
                    with self.assertRaises(KeyboardInterrupt):
                        kgraph.start_watch(db, source_dir=src, interval=1, reporter=print)

            upd.assert_called_once()
            out = stdout.getvalue()
            self.assertIn("Watching", out)
            self.assertIn("Watch mode active", out)
            self.assertIn("File changes detected, rebuilding", out)
            self.assertIn("Rebuilt: 3 nodes, 2 edges", out)

    def test_no_rebuild_when_nothing_changes(self):
        from kgraph import update

        with tempfile.TemporaryDirectory() as td:
            db = os.path.join(td, "graph.sqlite")
            src = os.path.join(td, "src")
            os.makedirs(src)
            with open(os.path.join(src, "a.py"), "w", encoding="utf-8") as f:
                f.write("x = 1\n")
            kgraph.save_to_graph_db(db, _SMALL_GRAPH)

            stub = _StubTime(lambda: None, lambda: None)
            stdout = io.StringIO()
            with (
                mock.patch.object(update, "time", stub),
                mock.patch.object(update, "incremental_update") as upd,
                mock.patch("kgraph.graph_db.resolve_all_memory_db_paths", return_value=[]),
            ):
                with contextlib.redirect_stdout(stdout):
                    with self.assertRaises(KeyboardInterrupt):
                        kgraph.start_watch(db, source_dir=src, interval=1, reporter=print)

            upd.assert_not_called()
            self.assertNotIn("File changes detected", stdout.getvalue())

    def test_watch_skips_ignored_dirs_and_logs_unreadable_files(self):
        from kgraph import update

        with tempfile.TemporaryDirectory() as td:
            db = os.path.join(td, "graph.sqlite")
            src = os.path.join(td, "src")
            os.makedirs(os.path.join(src, ".hidden"))
            os.makedirs(os.path.join(src, "venv"))
            for rel in (".hidden/skip.py", "venv/skip.py", "keep.py"):
                with open(os.path.join(src, rel), "w", encoding="utf-8") as f:
                    f.write("x = 1\n")
            unreadable = os.path.join(src, "unreadable.py")
            with open(unreadable, "w", encoding="utf-8") as f:
                f.write("x = 1\n")
            # No permission restore is needed: TemporaryDirectory removes the
            # dir (unlink needs only the parent's write bit), and a teardown-time
            # chmod would run after the dir is gone.
            os.chmod(unreadable, 0)
            kgraph.save_to_graph_db(db, _SMALL_GRAPH)

            stub = _StubTime(lambda: None, lambda: None)
            stdout = io.StringIO()
            with (
                mock.patch.object(update, "time", stub),
                mock.patch.object(update, "incremental_update") as upd,
                mock.patch.object(update, "logger") as log,
                mock.patch("kgraph.graph_db.resolve_all_memory_db_paths", return_value=[]),
            ):
                with contextlib.redirect_stdout(stdout):
                    with self.assertRaises(KeyboardInterrupt):
                        kgraph.start_watch(db, source_dir=src, interval=1, reporter=print)

            upd.assert_not_called()
            # .hidden/ and venv/ are skipped; the unreadable file is only counted
            # when this user can actually read it (not the case as non-root).
            readable = 1 + (1 if os.access(unreadable, os.R_OK) else 0)
            self.assertIn(f"({readable} files, interval=1s)", stdout.getvalue())
            if not os.access(unreadable, os.R_OK):
                log.debug.assert_called()

    def test_rebuilds_when_a_watched_memory_db_changes(self):
        from kgraph import update

        with tempfile.TemporaryDirectory() as td:
            db = os.path.join(td, "graph.sqlite")
            mem = os.path.join(td, "mem.sqlite")
            with open(mem, "w", encoding="utf-8") as f:
                f.write("")
            kgraph.save_to_graph_db(db, _SMALL_GRAPH)
            stamp = os.path.getmtime(mem)

            def bump_mtime():
                os.utime(mem, (stamp + 10, stamp + 10))

            stub = _StubTime(bump_mtime, lambda: None)
            stdout = io.StringIO()
            with (
                mock.patch.object(update, "time", stub),
                mock.patch.object(update, "incremental_update") as upd,
            ):
                with contextlib.redirect_stdout(stdout):
                    with self.assertRaises(KeyboardInterrupt):
                        kgraph.start_watch(db, mem_db_path=mem, interval=1, reporter=print)

            upd.assert_called_once()
            self.assertIn("File changes detected, rebuilding", stdout.getvalue())

    def test_logs_and_continues_when_a_rebuild_fails(self):
        from kgraph import update

        with tempfile.TemporaryDirectory() as td:
            db = os.path.join(td, "graph.sqlite")
            src = os.path.join(td, "src")
            os.makedirs(src)
            note = os.path.join(src, "a.py")
            with open(note, "w", encoding="utf-8") as f:
                f.write("x = 1\n")
            kgraph.save_to_graph_db(db, _SMALL_GRAPH)

            def touch_note():
                with open(note, "w", encoding="utf-8") as f:
                    f.write("x = 2\n")

            stub = _StubTime(touch_note, lambda: None)
            with (
                mock.patch.object(update, "time", stub),
                mock.patch.object(update, "incremental_update",
                                  side_effect=ValueError("boom")),
                mock.patch.object(update, "logger") as log,
                mock.patch("kgraph.graph_db.resolve_all_memory_db_paths", return_value=[]),
            ):
                with contextlib.redirect_stdout(io.StringIO()):
                    with self.assertRaises(KeyboardInterrupt):
                        kgraph.start_watch(db, source_dir=src, interval=1, reporter=print)

            log.warning.assert_called()


if __name__ == "__main__":
    unittest.main()
