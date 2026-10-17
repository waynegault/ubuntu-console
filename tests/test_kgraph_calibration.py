"""Tests for kgraph.calibrate — the edge-signal calibration harness.

GRAPHRAG-JEV-005-CALIB.  These verify the HARNESS, not a calibration: the numbers in
``confidence.py`` are still hand-picked, and a synthetic set here must never be read as
evidence that they should move.  What is pinned is the machinery's honesty —

* the labelling file cannot leak the score being judged (independence),
* an unreadable label is dropped, never counted as a negative (precision never inflates),
* the sweep measures only the signal under test (no rule being measured by proxy),
* the operating point is the lowest threshold whose precision holds *everywhere above*
  (a high-threshold dip cannot justify a low threshold),
* and the harness refuses to name a number from a sample too small or single-classed to
  support one.
"""

import csv
import json
import os
import tempfile
import unittest

from _paths import SCRIPT_DIR

from kgraph.calibrate import (
    MIN_SAMPLE,
    derive,
    load_labels,
    main,
    operating_point,
    parse_label,
    precision_recall_curve,
    render_report,
    sample_scored_edges,
    write_sample,
)
from kgraph.models import Graph

if not os.path.isdir(SCRIPT_DIR):
    raise RuntimeError(f"kgraph scripts/ dir not found: {SCRIPT_DIR}")


def _graph(edges: list[dict]) -> Graph:
    """A graph whose nodes are labelled so the sample rows read like a review sheet."""
    nodes = []
    seen = set()
    for edge in edges:
        for endpoint in (edge["from"], edge["to"]):
            if endpoint in seen:
                continue
            seen.add(endpoint)
            nodes.append({"id": endpoint, "label": endpoint.split(":")[-1]})
    return Graph.from_dict({"nodes": nodes, "edges": edges})


def _semantic(pairs: list[tuple[str, str, float]]) -> Graph:
    return _graph(
        [
            {
                "from": src,
                "to": dst,
                "label": "related concept",
                "semantic_score": score,
            }
            for src, dst, score in pairs
        ]
    )


class ExportIndependenceTests(unittest.TestCase):
    """The labelling file must not carry the number the labeller is judging."""

    def test_export_never_carries_the_score(self) -> None:
        graph = _semantic([("topic:alpha", "topic:beta", 0.731)])
        sample = sample_scored_edges(graph, limit=10, seed=0)

        self.assertEqual(len(sample.rows), 1)
        row = sample.rows[0]
        self.assertEqual(
            set(row), {"edge_id", "source_label", "target_label", "relation", "real"}
        )
        self.assertEqual(row["real"], "", "the label column must start blank")
        rendered = json.dumps(row)
        self.assertNotIn("0.731", rendered, "the score leaked into the labelling row")
        self.assertNotIn("semantic", rendered.lower())
        # …and the score IS retained, just in the other file.
        self.assertEqual(sample.signals[row["edge_id"]], {"semantic_score": 0.731})

    def test_signals_file_is_written_separately_from_the_sample(self) -> None:
        graph = _semantic([("topic:alpha", "topic:beta", 0.9)])
        sample = sample_scored_edges(graph, limit=10, seed=0)
        with tempfile.TemporaryDirectory() as directory:
            paths = write_sample(
                sample, directory, provenance={"graph_db": "synthetic"}
            )
            names = sorted(os.path.basename(path) for path in paths)
            self.assertEqual(names, ["provenance.json", "sample.csv", "signals.json"])
            with open(
                os.path.join(directory, "sample.csv"), encoding="utf-8"
            ) as handle:
                text = handle.read()
            self.assertNotIn(
                "0.9", text, "the CSV with the human's column also carried the score"
            )
            with open(
                os.path.join(directory, "provenance.json"), encoding="utf-8"
            ) as handle:
                provenance = json.load(handle)
            self.assertEqual(provenance["population"], 1)

    def test_export_is_deterministic_for_a_seed(self) -> None:
        pairs = [
            (f"topic:t{index}", "topic:shared", 0.6 + index / 100)
            for index in range(30)
        ]
        first = sample_scored_edges(_semantic(pairs), limit=10, seed=7)
        second = sample_scored_edges(_semantic(list(reversed(pairs))), limit=10, seed=7)
        self.assertEqual(
            [row["edge_id"] for row in first.rows],
            [row["edge_id"] for row in second.rows],
            "the draw depends on insertion order, not just on the seed",
        )

    def test_stratified_draw_keeps_the_rare_signal(self) -> None:
        edges = [
            {
                "from": f"topic:a{index}",
                "to": f"topic:b{index}",
                "label": "related concept",
                "semantic_score": 0.7,
            }
            for index in range(200)
        ] + [
            {
                "from": f"actor:x{index}",
                "to": f"topic:c{index}",
                "label": "actor issue",
                "cooccurrence_count": index + 1,
            }
            for index in range(8)
        ]
        sample = sample_scored_edges(_graph(edges), limit=40, seed=3)
        self.assertEqual(len(sample.rows), 40)
        self.assertEqual(sample.population, 208)
        self.assertGreaterEqual(sample.per_signal["cooccurrence_count"], 1)

    def test_a_graph_with_no_scored_edges_reports_an_empty_population(self) -> None:
        graph = _graph([{"from": "f:a.py", "to": "f:b.py", "label": "imports"}])
        sample = sample_scored_edges(graph, limit=10, seed=0)
        self.assertEqual(sample.rows, [])
        self.assertEqual(sample.population, 0)


class CurveTests(unittest.TestCase):
    """Precision/recall, computed by hand on four edges."""

    LABELS = {"e1": True, "e2": True, "e3": False, "e4": False}
    SIGNALS = {
        "e1": {"semantic_score": 0.50},
        "e2": {"semantic_score": 0.90},
        "e3": {"semantic_score": 0.60},
        "e4": {"semantic_score": 0.20},
    }

    def test_precision_and_recall_at_each_threshold(self) -> None:
        curve = precision_recall_curve(self.LABELS, self.SIGNALS, "semantic_score")
        by_threshold = {point.threshold: point for point in curve}
        self.assertEqual(sorted(by_threshold), [0.2, 0.5, 0.6, 0.9])

        at_half = by_threshold[0.5]
        self.assertEqual((at_half.true_positives, at_half.false_positives), (2, 1))
        assert at_half.precision is not None and at_half.recall is not None
        self.assertAlmostEqual(at_half.precision, 2 / 3)
        self.assertAlmostEqual(at_half.recall, 1.0)

        at_ninety = by_threshold[0.9]
        self.assertEqual((at_ninety.true_positives, at_ninety.false_positives), (1, 0))
        assert at_ninety.precision is not None and at_ninety.recall is not None
        self.assertAlmostEqual(at_ninety.precision, 1.0)
        self.assertAlmostEqual(at_ninety.recall, 0.5)

    def test_the_sweep_ignores_edges_without_the_signal(self) -> None:
        labels = {**self.LABELS, "e5": False}
        signals: dict[str, dict[str, float]] = {
            **self.SIGNALS,
            "e5": {"cooccurrence_count": 9},
        }
        curve = precision_recall_curve(labels, signals, "semantic_score")
        self.assertTrue(curve)
        # An edge with no semantic_score is decided by another rule; counting it as a
        # negative would measure that rule instead of this signal.
        self.assertTrue(
            all(point.predicted <= 4 for point in curve),
            "an edge outside the signal's population entered the sweep",
        )

    def test_operating_point_sits_above_the_highest_violation(self) -> None:
        # Precision holds at 0.5, dips at 0.6 (a false positive lands), recovers at 0.9.
        curve = precision_recall_curve(self.LABELS, self.SIGNALS, "semantic_score")
        point = operating_point(curve, 0.90)
        self.assertIsNotNone(point)
        assert point is not None
        self.assertEqual(
            point.threshold,
            0.9,
            "a low threshold was justified by edges above a high-threshold dip",
        )

    def test_operating_point_is_none_when_the_floor_is_unreachable(self) -> None:
        curve = precision_recall_curve(self.LABELS, self.SIGNALS, "semantic_score")
        self.assertIsNone(operating_point(curve, 1.01))

    def test_operating_point_at_the_lowest_value_is_reported_as_no_boundary(
        self,
    ) -> None:
        # 19 real + 1 not-real, the negative carrying the LOWEST score: precision holds
        # at 95% even with everything predicted, so the sweep lands on the lowest value —
        # the case where the floor does not actually locate a boundary.
        labels = {f"e{index}": index > 0 for index in range(20)}
        signals = {
            f"e{index}": {"semantic_score": 0.5 + index / 100} for index in range(20)
        }
        derived = derive(labels, signals, "semantic_score", min_sample=2)
        self.assertIsNotNone(derived.point)
        assert derived.point is not None
        self.assertEqual(derived.point.threshold, 0.5)
        report = render_report(
            [derived], min_precision=0.9, provenance={"sample": "unit"}
        )
        self.assertIn("does not locate a boundary", report)


class LabelReadingTests(unittest.TestCase):
    """Labels are read conservatively: an unreadable cell is dropped, never a negative."""

    def test_parse_label_accepts_the_obvious_spellings(self) -> None:
        for text in ("true", "TRUE", " t ", "yes", "1", "real"):
            self.assertIs(parse_label(text), True)
        for text in ("false", "F", "no", "0", "not real"):
            self.assertIs(parse_label(text), False)
        unreadable: list[str | None] = [None, "", "?", "maybe", "true-ish"]
        for candidate in unreadable:
            self.assertIsNone(parse_label(candidate))

    def test_unreadable_and_unknown_rows_are_dropped(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            with open(
                os.path.join(directory, "signals.json"), "w", encoding="utf-8"
            ) as handle:
                json.dump(
                    {
                        "a1": {"semantic_score": 0.8},
                        "a2": {"semantic_score": 0.3},
                        "a3": {"semantic_score": 0.6},
                    },
                    handle,
                )
            with open(
                os.path.join(directory, "sample.csv"), "w", newline="", encoding="utf-8"
            ) as handle:
                writer = csv.DictWriter(
                    handle,
                    fieldnames=[
                        "edge_id",
                        "source_label",
                        "target_label",
                        "relation",
                        "real",
                    ],
                )
                writer.writeheader()
                writer.writerow({"edge_id": "a1", "real": "true"})
                writer.writerow({"edge_id": "a2", "real": ""})  # left blank
                writer.writerow({"edge_id": "a3", "real": "probably"})  # unreadable
                writer.writerow({"edge_id": "zz", "real": "true"})  # not in signals

            labels, signals, rejected = load_labels(directory)
            self.assertEqual(labels, {"a1": True})
            self.assertEqual(sorted(rejected), ["a2", "a3", "zz"])
            self.assertIn("a1", signals)


class RefusalTests(unittest.TestCase):
    """The harness must refuse to name a threshold it cannot support."""

    def test_a_sample_below_the_floor_is_refused(self) -> None:
        labels = {f"e{index}": index % 2 == 0 for index in range(12)}
        signals = {
            ident: {"semantic_score": 0.5 + index / 100}
            for index, ident in enumerate(labels)
        }
        derived = derive(labels, signals, "semantic_score")
        self.assertIsNone(derived.point)
        self.assertIn("12 labelled edges", derived.refusal or "")
        self.assertIn(str(MIN_SAMPLE), derived.refusal or "")

    def test_a_single_class_sample_is_refused(self) -> None:
        labels = {f"e{index}": True for index in range(MIN_SAMPLE + 10)}
        signals = {ident: {"semantic_score": 0.9} for ident in labels}
        derived = derive(labels, signals, "semantic_score")
        self.assertIsNone(derived.point)
        self.assertIn("one class", derived.refusal or "")

    def test_a_signal_absent_from_the_sample_is_refused(self) -> None:
        labels = {"e1": True, "e2": False}
        signals = {"e1": {"semantic_score": 0.9}, "e2": {"semantic_score": 0.1}}
        derived = derive(labels, signals, "cooccurrence_count")
        self.assertIsNone(derived.point)
        self.assertIn("no labelled edge carries", derived.refusal or "")


class CliBoundaryTests(unittest.TestCase):
    """``main`` returns the text and the exit code; only the ``__main__`` block prints."""

    def _db(self, directory: str, edges: list[dict]) -> str:
        from kgraph.graph_db import save_to_graph_db

        path = os.path.join(directory, "graph.sqlite")
        save_to_graph_db(path, _graph(edges))
        return path

    def test_an_unscored_graph_exits_2_with_the_reason(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            db = self._db(
                directory, [{"from": "f:a.py", "to": "f:b.py", "label": "imports"}]
            )
            result = main(
                ["--export", os.path.join(directory, "sample"), "--graph-db", db]
            )
            self.assertEqual(result.code, 2)
            self.assertIn("Nothing to calibrate", result.error)
            self.assertFalse(
                os.path.exists(os.path.join(directory, "sample", "sample.csv"))
            )

    def test_an_export_names_the_next_step(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            db = self._db(
                directory,
                [
                    {
                        "from": "topic:a",
                        "to": "topic:b",
                        "label": "related concept",
                        "semantic_score": 0.8,
                    }
                ],
            )
            out = os.path.join(directory, "sample")
            result = main(["--export", out, "--graph-db", db])
            self.assertEqual(result.code, 0)
            self.assertIn("Next: fill the `real` column", result.output)
            self.assertTrue(os.path.exists(os.path.join(out, "signals.json")))

    def test_scoring_a_small_sample_exits_2(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            with open(
                os.path.join(directory, "signals.json"), "w", encoding="utf-8"
            ) as handle:
                json.dump(
                    {"a1": {"semantic_score": 0.8}, "a2": {"semantic_score": 0.2}},
                    handle,
                )
            with open(
                os.path.join(directory, "sample.csv"), "w", newline="", encoding="utf-8"
            ) as handle:
                writer = csv.DictWriter(
                    handle,
                    fieldnames=[
                        "edge_id",
                        "source_label",
                        "target_label",
                        "relation",
                        "real",
                    ],
                )
                writer.writeheader()
                writer.writerow({"edge_id": "a1", "real": "true"})
                writer.writerow({"edge_id": "a2", "real": "false"})
            result = main(["--score", directory])
            self.assertEqual(result.code, 2)
            self.assertIn("No threshold named", result.output)


if __name__ == "__main__":
    unittest.main()
