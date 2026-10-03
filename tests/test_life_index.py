"""Tests for kgraph.life_index — directory scan, canonical records, relations."""

import json
import os
import tempfile
import unittest
from unittest import mock

from _kgraph_fixtures import _SMALL_GRAPH
import kgraph


class TestLifeIndex(unittest.TestCase):
    def test_resolve_life_root_default(self):
        root = kgraph.resolve_life_root()
        self.assertTrue(root.endswith("life"))

    def test_resolve_life_root_custom(self):
        root = kgraph.resolve_life_root("/tmp/custom-life")
        self.assertEqual(root, "/tmp/custom-life")

    def test_load_life_index_missing_dir(self):
        index = kgraph.load_life_index("/tmp/nonexistent-life-dir")
        self.assertEqual(index["records"], [])
        self.assertEqual(index["aliases"], {})

    def test_load_life_index_canonical_from_custom_root(self):
        # canonical-concepts.json is resolved from the passed root, not the
        # default ~/.openclaw/life — a custom root must not leak the host's
        # canonical concepts into the index.
        with tempfile.TemporaryDirectory() as td:
            with open(os.path.join(td, "canonical-concepts.json"), "w") as f:
                json.dump({"records": [{"slug": "alpha", "title": "Alpha", "type": "project"}]}, f)
            index = kgraph.load_life_index(td)
            self.assertEqual([r["slug"] for r in index["records"]], ["alpha"])

    def test_load_relations_missing_file(self):
        rels = kgraph.load_relations("/tmp/nonexistent-life-dir")
        self.assertEqual(rels["relations"], [])

    def test_merge_relations_no_relations(self):
        graph = kgraph.merge_relations(_SMALL_GRAPH, life_root="/tmp/nonexistent")
        # Should return unchanged (as Graph model)
        self.assertEqual(len(graph.edges), 2)

    def test_merge_relations_marks_origin_life_index(self):
        with tempfile.TemporaryDirectory() as td:
            with open(os.path.join(td, "relations.json"), "w") as f:
                json.dump({"relations": [{"source": "alpha", "target": "beta", "rel": "related"}]}, f)
            graph = kgraph.merge_relations(
                {"nodes": [{"id": "n1", "label": "Alpha", "slug": "alpha"},
                           {"id": "n2", "label": "Beta", "slug": "beta"}],
                 "edges": []},
                life_root=td,
            )
        self.assertEqual(len(graph.edges), 1)
        # origin is a provenance tag, never the source slug.
        self.assertEqual(graph.edges[0].origin, "life_index")
        self.assertTrue(graph.edges[0].explicit)


class TestLifeIndexScan(unittest.TestCase):
    @staticmethod
    def _write(path, text):
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as f:
            f.write(text)

    def test_dir_scan_parses_title_type_status_and_aliases(self):
        with tempfile.TemporaryDirectory() as td:
            self._write(
                os.path.join(td, "projects", "alpha.md"),
                "# Alpha Project\n- type: project\n- status: active\n"
                "- aliases:\n  - Alpha Proj\n  - ALPHA\n"
                "\nBody prose ends the alias block.\n",
            )
            index = kgraph.load_life_index(td)
            self.assertEqual([r["slug"] for r in index["records"]], ["alpha"])
            rec = index["by_slug"]["alpha"]
            self.assertEqual(rec["title"], "Alpha Project")
            self.assertEqual(rec["type"], "project")
            self.assertEqual(rec["status"], "active")
            self.assertEqual(rec["aliases"], ["Alpha Proj", "ALPHA"])
            self.assertIn("alpha proj", index["aliases"])
            self.assertEqual(index["title_aliases"]["alpha proj"], "Alpha Project")
            self.assertEqual(index["by_type"]["project"], [rec])

    def test_dir_scan_default_type_maps_people_to_person(self):
        # `people` is irregular: a blind `type_dir[:-1]` would yield "peopl",
        # while the rest of the codebase spells the type "person".
        with tempfile.TemporaryDirectory() as td:
            self._write(os.path.join(td, "people", "wayne.md"), "# Wayne\n")
            index = kgraph.load_life_index(td)
            self.assertEqual(index["by_slug"]["wayne"]["type"], "person")

    def test_singular_type_handles_irregular_and_regular_names(self):
        from kgraph import life_index

        self.assertEqual(life_index._singular_type("people"), "person")
        self.assertEqual(life_index._singular_type("projects"), "project")
        # A directory not in the map still singularises a regular plural.
        self.assertEqual(life_index._singular_type("notes"), "note")
        self.assertEqual(life_index._singular_type("misc"), "misc")

    def test_dir_scan_title_falls_back_to_the_slug(self):
        with tempfile.TemporaryDirectory() as td:
            self._write(os.path.join(td, "systems", "nas.md"), "- type: system\n")
            index = kgraph.load_life_index(td)
            self.assertEqual(index["by_slug"]["nas"]["title"], "nas")

    def test_dir_scan_ignores_non_markdown_and_unlisted_dirs(self):
        with tempfile.TemporaryDirectory() as td:
            self._write(os.path.join(td, "projects", "notes.txt"), "ignored")
            self._write(os.path.join(td, "notatype", "x.md"), "# X\n")
            self.assertEqual(kgraph.load_life_index(td)["records"], [])

    def test_unreadable_index_file_is_logged_and_skipped(self):
        with tempfile.TemporaryDirectory() as td:
            path = os.path.join(td, "projects", "broken.md")
            self._write(path, "# Broken\n")
            os.chmod(path, 0)
            if os.access(path, os.R_OK):  # e.g. running as root
                self.skipTest("chmod 0 is still readable for this user")
            with mock.patch("kgraph.life_index.logger") as log:
                index = kgraph.load_life_index(td)
            log.warning.assert_called()
            self.assertEqual(index["records"], [])

    def test_malformed_canonical_json_falls_back_to_the_dir_scan(self):
        with tempfile.TemporaryDirectory() as td:
            self._write(os.path.join(td, "canonical-concepts.json"), "{ not json")
            self._write(os.path.join(td, "projects", "alpha.md"),
                        "# Alpha\n- type: project\n")
            with mock.patch("kgraph.life_index.logger") as log:
                index = kgraph.load_life_index(td)
            log.warning.assert_called()
            self.assertEqual([r["slug"] for r in index["records"]], ["alpha"])

    def test_canonical_record_without_a_slug_is_skipped(self):
        with tempfile.TemporaryDirectory() as td:
            self._write(
                os.path.join(td, "canonical-concepts.json"),
                json.dumps({"records": [{"title": "no slug"},
                                        {"slug": "beta", "title": "Beta",
                                         "type": "project"}]}),
            )
            index = kgraph.load_life_index(td)
            self.assertEqual([r["slug"] for r in index["records"]], ["beta"])

    def test_slugless_canonical_records_fall_through_to_the_scan(self):
        with tempfile.TemporaryDirectory() as td:
            self._write(os.path.join(td, "canonical-concepts.json"),
                        json.dumps({"records": [{"title": "no slug"}]}))
            self._write(os.path.join(td, "repos", "kgraph.md"),
                        "# kgraph\n- type: repo\n")
            index = kgraph.load_life_index(td)
            self.assertEqual([r["slug"] for r in index["records"]], ["kgraph"])


class TestLifeRelations(unittest.TestCase):
    @staticmethod
    def _write(path, text):
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as f:
            f.write(text)

    def test_malformed_relations_json_is_logged(self):
        with tempfile.TemporaryDirectory() as td:
            self._write(os.path.join(td, "relations.json"), "{ nope")
            with mock.patch("kgraph.life_index.logger") as log:
                rels = kgraph.load_relations(td)
            log.warning.assert_called()
            self.assertEqual(rels, {"relations": []})

    def test_merge_relations_skips_incomplete_and_unknown_slugs(self):
        with tempfile.TemporaryDirectory() as td:
            self._write(os.path.join(td, "relations.json"), json.dumps({"relations": [
                {"source": "alpha"},                     # no target
                {"target": "beta"},                      # no source
                {"source": "ghost", "target": "beta"},   # unknown source
                {"source": "alpha", "target": "ghost"},  # unknown target
            ]}))
            graph = kgraph.merge_relations(
                {"nodes": [{"id": "n1", "label": "Alpha", "slug": "alpha"},
                           {"id": "n2", "label": "Beta", "slug": "beta"}],
                 "edges": []},
                life_root=td,
            )
        self.assertEqual(graph.edges, [])

    def test_merge_relations_matches_a_canonical_slug(self):
        with tempfile.TemporaryDirectory() as td:
            self._write(os.path.join(td, "relations.json"), json.dumps({"relations": [
                {"source": "alpha", "target": "beta", "rel": "supersedes"},
            ]}))
            graph = kgraph.merge_relations(
                {"nodes": [{"id": "n1", "label": "Alpha", "canonical_slug": "alpha"},
                           {"id": "n2", "label": "Beta", "slug": "beta"}],
                 "edges": []},
                life_root=td,
            )
        self.assertEqual(len(graph.edges), 1)
        self.assertEqual(graph.edges[0].label, "supersedes")
        self.assertEqual(graph.edges[0].origin, "life_index")
        self.assertTrue(graph.edges[0].explicit)

    def test_merge_relations_does_not_duplicate_an_existing_edge(self):
        with tempfile.TemporaryDirectory() as td:
            self._write(os.path.join(td, "relations.json"), json.dumps({"relations": [
                {"source": "alpha", "target": "beta", "rel": "related"},
            ]}))
            graph = kgraph.merge_relations(
                {"nodes": [{"id": "n1", "label": "Alpha", "slug": "alpha"},
                           {"id": "n2", "label": "Beta", "slug": "beta"}],
                 "edges": [{"from": "n1", "to": "n2", "label": "related"}]},
                life_root=td,
            )
        self.assertEqual(len(graph.edges), 1)


if __name__ == "__main__":
    unittest.main()
