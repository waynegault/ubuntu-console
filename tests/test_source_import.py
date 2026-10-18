"""Tests for kgraph.source_import — source adapters and the files/chunks store."""

import json
import os
import sqlite3
import tempfile
import unittest

from _paths import SCRIPT_DIR

# `_paths` puts the repo's scripts/ on sys.path; assert the bootstrap ran
# rather than letting a later `import kgraph` fail with a confusing ImportError.
if not os.path.isdir(SCRIPT_DIR):
    raise RuntimeError(f"kgraph scripts/ dir not found: {SCRIPT_DIR}")


_MD = """# 2026-10-02

Intro.

## First section <!-- project: github.com/x/y -->

Wayne measured the gateway.
Jarvis reviewed it.

## Second section

Jarvis approved it.
"""

# The body is the proven concept fixture: the repeated Decision/Issue/Outcome
# markers and the actors are what the co-occurrence pass turns into scored edges.
_CONCEPTS = """# 2026-10-04

## Project: Launcher reliability

Project: Launcher reliability
Decision: token rotation
Issue: gateway flapping | resolve by rotation
Jarvis (Operations Director) reviewed the launcher.
Finance Director (Marlowe) approved the budget.
We decided to keep the semantic naming.
Issue: duplicated nodes in graph
Outcome: launcher reliability validated
Work on gateway token rotation
The main issue is shallow topic labels
Result was launcher reliability validated
See `memory/notes.md` for details and also unknown/thing.md.
gateway openclaw wsl2 ubuntu linux
OpenClaw runs the registry here.

## Notes

We decided to rotate the gateway token
"""


class TestMarkdownSource(unittest.TestCase):
    def test_splits_sections_and_keeps_line_ranges(self):
        from kgraph.source_import import MarkdownMemorySource

        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "2026-10-02.md")
            with open(path, "w", encoding="utf-8") as handle:
                handle.write(_MD)
            records = list(MarkdownMemorySource(tmp).iter_records())

        self.assertEqual(len(records), 2)
        first, second = records
        self.assertEqual((first.start_line, first.end_line), (5, 8))
        self.assertEqual(first.section, "First section")
        self.assertEqual(first.metadata, {"project": "github.com/x/y"})
        self.assertEqual(first.source_date, "2026-10-02")
        self.assertIn("Wayne measured the gateway.", first.text)
        self.assertEqual((second.start_line, second.end_line), (10, 12))
        self.assertEqual(second.section, "Second section")

    def test_falls_back_to_one_record_without_sections(self):
        from kgraph.source_import import MarkdownMemorySource

        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "2026-10-03.md")
            with open(path, "w", encoding="utf-8") as handle:
                handle.write("# 2026-10-03\n\nOnly a body.\n")
            records = list(MarkdownMemorySource(tmp).iter_records())

        self.assertEqual(len(records), 1)
        self.assertEqual((records[0].start_line, records[0].end_line), (2, 3))
        self.assertEqual(records[0].text, "Only a body.")


class TestStoreWriter(unittest.TestCase):
    def test_write_is_idempotent_and_prunes_stale_sections(self):
        from kgraph.source_import import MarkdownMemorySource, import_source

        with tempfile.TemporaryDirectory() as tmp:
            src = os.path.join(tmp, "memory")
            os.makedirs(src)
            path = os.path.join(src, "2026-10-02.md")
            with open(path, "w", encoding="utf-8") as handle:
                handle.write(_MD)
            db = os.path.join(tmp, "source.sqlite")

            first = import_source(MarkdownMemorySource(src), db, prune_prefix=src)
            second = import_source(MarkdownMemorySource(src), db, prune_prefix=src)
            self.assertEqual((first.files, first.chunks), (1, 2))
            self.assertEqual((second.files, second.chunks), (1, 2))

            with open(path, "w", encoding="utf-8") as handle:
                handle.write(_MD.split("## Second section")[0])
            third = import_source(MarkdownMemorySource(src), db, prune_prefix=src)
            self.assertEqual(third.chunks, 1)

            conn = sqlite3.connect(db)
            try:
                self.assertEqual(
                    conn.execute("SELECT count(*) FROM chunks").fetchone()[0], 1)
                self.assertEqual(
                    conn.execute("SELECT count(*) FROM source_meta").fetchone()[0], 1)
            finally:
                conn.close()

    def test_source_meta_records_layer_provenance(self):
        from kgraph.source_import import SourceRecord, write_files_chunks

        with tempfile.TemporaryDirectory() as tmp:
            db = os.path.join(tmp, "source.sqlite")
            write_files_chunks([
                SourceRecord(
                    path="investigator/layer1/case-1.md",
                    start_line=1,
                    end_line=2,
                    text="Case 1 fact",
                    source_kind="investigator-layer1",
                    source_date="2026-10-01",
                    section="Facts",
                    scope="case",
                    metadata={"layer": "1", "case": "1"},
                ),
            ], db)
            conn = sqlite3.connect(db)
            try:
                row = conn.execute(
                    "SELECT source_kind, source_date, section, scope, metadata"
                    "  FROM source_meta"
                ).fetchone()
            finally:
                conn.close()

        self.assertEqual(row[0], "investigator-layer1")
        self.assertEqual(row[1], "2026-10-01")
        self.assertEqual(row[2], "Facts")
        self.assertEqual(row[3], "case")
        self.assertEqual(json.loads(row[4]), {"layer": "1", "case": "1"})


class TestScoredEdgePath(unittest.TestCase):
    def test_imported_store_emits_scored_edges_and_a_sample(self):
        from kgraph.calibrate import sample_scored_edges
        from kgraph.memory_import import load_from_memory_db
        from kgraph.source_import import MarkdownMemorySource, import_source

        with tempfile.TemporaryDirectory() as tmp:
            src = os.path.join(tmp, "memory")
            os.makedirs(src)
            with open(os.path.join(src, "2026-10-04.md"), "w",
                      encoding="utf-8") as handle:
                handle.write(_CONCEPTS)
            db = os.path.join(tmp, "source.sqlite")
            import_source(MarkdownMemorySource(src), db, prune_prefix=src)
            graph = load_from_memory_db(db)

        scored = [
            edge for edge in graph.edges
            if edge.cooccurrence_count is not None or edge.semantic_score is not None
        ]
        self.assertTrue(scored, "the imported store must feed the scored-edge path")
        sample = sample_scored_edges(graph, limit=5, seed=0)
        self.assertGreater(sample.population, 0)
        self.assertTrue(sample.rows)


class TestCliSeam(unittest.TestCase):
    def test_import_source_writes_and_dry_run_does_not(self):
        from kgraph.cli import main

        with tempfile.TemporaryDirectory() as tmp:
            src = os.path.join(tmp, "memory")
            os.makedirs(src)
            with open(os.path.join(src, "2026-10-05.md"), "w",
                      encoding="utf-8") as handle:
                handle.write("# 2026-10-05\n\n## One\n\nA body.\n")
            db = os.path.join(tmp, "source.sqlite")
            main([
                "import-source", "--source", "markdown",
                "--source-path", src, "--source-db", db,
            ])
            self.assertTrue(os.path.exists(db))
            conn = sqlite3.connect(db)
            try:
                self.assertEqual(
                    conn.execute("SELECT count(*) FROM chunks").fetchone()[0], 1)
            finally:
                conn.close()

            dry = os.path.join(tmp, "dry.sqlite")
            main([
                "import-source", "--source", "markdown",
                "--source-path", src, "--source-db", dry, "--dry-run",
            ])
            self.assertFalse(os.path.exists(dry))
