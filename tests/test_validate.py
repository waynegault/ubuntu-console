"""Tests for kgraph.validate — limits, XSS scan, file/payload loading, CLI."""

import json
import os
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

from _paths import REPO_ROOT
from _kgraph_fixtures import _SMALL_GRAPH
import kgraph


class TestValidateExtended(unittest.TestCase):
    def test_validate_graph_valid_payload_returns_true(self):
        valid, reason = kgraph.validate_graph_payload(_SMALL_GRAPH)
        self.assertTrue(valid)
        self.assertEqual(reason, "")

    def test_validate_graph_payload_too_large(self):
        valid, msg = kgraph.validate_graph_payload(b"x" * (101 * 1024 * 1024))
        self.assertFalse(valid)
        self.assertIn("too large", msg.lower())


class TestValidateLimits(unittest.TestCase):
    def setUp(self):
        from kgraph import validate

        self.validate = validate

    def test_non_dict_root_is_reported(self):
        errors = self.validate.validate_graph(["not", "a", "dict"])
        self.assertEqual(len(errors), 1)
        self.assertIn("must be a dict", errors[0]["message"])

    def test_excessive_nesting_is_reported(self):
        root: dict = {}
        cursor = root
        # Deeper than the scanner's own short-circuit so both the guard and the
        # depth comparison are exercised.
        for _ in range(self.validate.MAX_JSON_DEPTH + 10):
            cursor["nested"] = {}
            cursor = cursor["nested"]
        errors = self.validate.validate_graph(root)
        self.assertTrue(any("Excessive nesting" in e["message"] for e in errors))

    def test_non_list_nodes_and_edges_are_reported(self):
        errors = self.validate.validate_graph({"nodes": "x", "edges": "y"})
        messages = " ".join(e["message"] for e in errors)
        self.assertIn("'nodes' must be a list", messages)
        self.assertIn("'edges' must be a list", messages)

    def test_node_and_edge_count_limits_are_enforced(self):
        with (
            mock.patch.object(self.validate, "MAX_NODES", 1),
            mock.patch.object(self.validate, "MAX_EDGES", 1),
        ):
            errors = self.validate.validate_graph({
                "nodes": [{"id": "a", "label": "A"}, {"id": "b", "label": "B"}],
                "edges": [{"from": "a", "to": "b"}, {"from": "b", "to": "a"}],
            })
        messages = " ".join(e["message"] for e in errors)
        self.assertIn("Too many nodes", messages)
        self.assertIn("Too many edges", messages)

    def test_schema_violations_are_reported(self):
        errors = self.validate.validate_graph(
            {"nodes": [{"label": "no id"}], "edges": []})
        self.assertTrue(any(e["message"].startswith("Schema:") for e in errors))


class TestValidateXss(unittest.TestCase):
    def setUp(self):
        from kgraph import validate

        self.validate = validate

    def test_detects_a_dangerous_pattern_at_top_level(self):
        errors = self.validate.validate_graph({
            "nodes": [{"id": "x", "label": "<script>alert(1)</script>"}],
            "edges": [],
        })
        self.assertTrue(any("dangerous patterns" in e["message"] for e in errors))

    def test_detects_a_dangerous_pattern_nested_in_a_container(self):
        errors = self.validate.validate_graph({
            "nodes": [{"id": "x", "label": "ok",
                       "payload": {"deep": ["fine", "javascript:alert(1)"]}}],
            "edges": [],
        })
        self.assertTrue(any("payload" in e["message"] for e in errors))

    def test_skips_non_list_and_non_dict_items(self):
        # A non-list nodes/edges value is already reported by validate_graph;
        # the scan must not raise TypeError out of the caller.
        self.assertEqual(self.validate._check_xss({"nodes": "nope", "edges": [1, 2, "x"]}), [])

    def test_scan_dangerous_ignores_non_strings(self):
        self.assertFalse(self.validate._scan_dangerous({"n": 1, "l": [None, True, 3.5]}))
        self.assertTrue(self.validate._scan_dangerous({"n": ["<script >"]}))


class TestValidateFileAndPayload(unittest.TestCase):
    def setUp(self):
        from kgraph import validate

        self.validate = validate

    def test_missing_file_is_reported(self):
        errors = self.validate.validate_graph_file("/nonexistent/graph.json")
        self.assertEqual(len(errors), 1)
        self.assertIn("File not found", errors[0]["message"])

    def test_a_directory_is_reported_as_missing(self):
        with tempfile.TemporaryDirectory() as td:
            errors = self.validate.validate_graph_file(td)
        self.assertIn("File not found", errors[0]["message"])

    def test_malformed_json_reports_line_and_column(self):
        with tempfile.TemporaryDirectory() as td:
            path = os.path.join(td, "bad.json")
            with open(path, "w", encoding="utf-8") as f:
                f.write("{ not json")
            errors = self.validate.validate_graph_file(path)
        self.assertEqual(len(errors), 1)
        self.assertIn("JSON parse error", errors[0]["message"])
        self.assertIn("line", errors[0]["message"])

    def test_valid_file_is_clean_and_errors_carry_the_filename(self):
        with tempfile.TemporaryDirectory() as td:
            ok = os.path.join(td, "ok.json")
            with open(ok, "w", encoding="utf-8") as f:
                json.dump({"nodes": [{"id": "a", "label": "A"}], "edges": []}, f)
            self.assertEqual(self.validate.validate_graph_file(ok), [])

            bad = os.path.join(td, "bad.json")
            with open(bad, "w", encoding="utf-8") as f:
                json.dump({"nodes": [{"label": "no id"}], "edges": []}, f)
            errors = self.validate.validate_graph_file(bad)
        self.assertTrue(errors)
        self.assertTrue(all(e.get("file") == bad for e in errors))

    def test_an_unreadable_file_is_reported_as_an_error(self):
        with tempfile.TemporaryDirectory() as td:
            path = os.path.join(td, "locked.json")
            with open(path, "w", encoding="utf-8") as f:
                f.write("{}")
            os.chmod(path, 0)
            if os.access(path, os.R_OK):  # e.g. running as root
                self.skipTest("chmod 0 is still readable for this user")
            errors = self.validate.validate_graph_file(path)
        self.assertEqual(len(errors), 1)
        self.assertIn("Error reading", errors[0]["message"])

    def test_payload_accepts_dicts_and_json_strings(self):
        ok, reason = self.validate.validate_graph_payload({"nodes": [], "edges": []})
        self.assertTrue(ok)
        self.assertEqual(reason, "")
        ok, _ = self.validate.validate_graph_payload('{"nodes": [], "edges": []}')
        self.assertTrue(ok)

    def test_payload_rejects_oversized_bytes_and_strings(self):
        with mock.patch.object(self.validate, "MAX_PAYLOAD_SIZE", 10):
            ok, reason = self.validate.validate_graph_payload(b"x" * 11)
            self.assertFalse(ok)
            self.assertIn("too large", reason)
            ok, reason = self.validate.validate_graph_payload("x" * 11)
            self.assertFalse(ok)
            self.assertIn("too large", reason)

    def test_payload_rejects_invalid_json_and_unsupported_types(self):
        ok, reason = self.validate.validate_graph_payload(b"{ nope")
        self.assertFalse(ok)
        self.assertIn("Invalid JSON", reason)
        ok, reason = self.validate.validate_graph_payload(42)
        self.assertFalse(ok)
        self.assertIn("JSON string or dict", reason)

    def test_payload_surfaces_the_first_error_message(self):
        ok, reason = self.validate.validate_graph_payload({
            "nodes": [{"id": "x", "label": "<script>alert(1)</script>"}],
            "edges": [],
        })
        self.assertFalse(ok)
        self.assertIn("dangerous patterns", reason)


class TestValidateCli(unittest.TestCase):
    def _run(self, *args):
        env = dict(os.environ, PYTHONPATH=os.path.join(REPO_ROOT, "scripts"))
        return subprocess.run(
            [sys.executable, "-m", "kgraph.validate", *args],
            capture_output=True, text=True, env=env, cwd=REPO_ROOT,
        )

    def test_usage_without_arguments(self):
        proc = self._run()
        self.assertEqual(proc.returncode, 1)
        self.assertIn("Usage:", proc.stdout)

    def test_valid_file_passes(self):
        with tempfile.TemporaryDirectory() as td:
            path = os.path.join(td, "ok.json")
            with open(path, "w", encoding="utf-8") as f:
                json.dump({"nodes": [{"id": "a", "label": "A"}], "edges": []}, f)
            proc = self._run(path)
        self.assertEqual(proc.returncode, 0)
        self.assertIn("validation PASSED", proc.stdout)

    def test_invalid_file_exits_nonzero_with_issues(self):
        with tempfile.TemporaryDirectory() as td:
            path = os.path.join(td, "bad.json")
            with open(path, "w", encoding="utf-8") as f:
                json.dump({"nodes": [{"label": "no id"}], "edges": []}, f)
            proc = self._run(path)
        self.assertEqual(proc.returncode, 1)
        self.assertIn("issue(s)", proc.stdout)


if __name__ == "__main__":
    unittest.main()
