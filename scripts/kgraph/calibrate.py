"""Calibration harness for the two signals that decide INFERRED vs AMBIGUOUS.

REF: "GraphRAG with TypeSafe Jev: A System One Approach to Scalable Knowledge
     Graphs" (Partha Sarkar, TDS, 2026-09-27) —
     https://towardsdatascience.com/graphrag-with-typesafe-jev-a-system-one-approach-to-scalable-knowledge-graphs/

``confidence.SEMANTIC_INFERRED_MIN`` and ``confidence.COOCCURRENCE_INFERRED_MIN`` are
hand-picked defaults (GRAPHRAG-JEV-005).  This module is the missing other half: the
machinery that turns a LABELLED edge sample into those two numbers, so the default is
replaced by a measurement instead of by another pick.

Two modes, deliberately kept apart:

``export``
    Draws a sample from a built graph and writes **three** files — ``sample.csv``
    (edge id, endpoint labels, the relation, and a blank ``real`` column for a human),
    ``signals.json`` (edge id -> the withheld signal values) and ``provenance.json``
    (which graph, when, how big).  Splitting the judgement from the score is the whole
    point: a labeller who cannot see the score cannot grade the score, so the labels
    stay independent of the formula under test.  One file carrying both would invite
    ``real = score >= 0.5``, which measures the formula against itself.

``score``
    Joins the returned labels to the withheld signals, prints one precision/recall
    curve per signal, and names the operating point: the LOWEST threshold at which
    precision — at that threshold *and at every higher one* — stays at or above the
    floor.  Precision with its recall, never accuracy: the two errors are not
    symmetric.  An edge wrongly tagged INFERRED is asserted downstream; an AMBIGUOUS
    one is only flagged for review, so the threshold is the lowest one whose precision
    survives the cost ratio.

It refuses to derive a constant from a sample too small to support one
(:data:`MIN_SAMPLE`), and refuses one whose labels are all the same class.  A
plausible-looking threshold computed from twelve edges is worse than the recorded
"un-calibrated" state it would silently replace.

Nothing here writes a constant into the source.  The report names the numbers; putting
them into ``confidence.py`` stays a reviewed edit, so a re-run cannot change behaviour
by accident.
"""

from __future__ import annotations

import csv
import datetime
import hashlib
import json
import os
import random
import sys
from dataclasses import dataclass
from typing import Any, Iterable

from .constants import GRAPH_DB_DEFAULT
from .graph_db import load_from_graph_db, read_graph_meta_value
from .models import Graph, GraphEdge

#: Signal fields a curve can be swept over.  ``semantic_score`` is a similarity in
#: [0, 1]; ``cooccurrence_count`` is a raw pair count.  Both read "higher = more
#: likely real", which is why one sweep serves both.
SIGNAL_KEYS: tuple[str, ...] = ("semantic_score", "cooccurrence_count")

#: Smallest labelled sample this harness will derive a number from.  The article's
#: own validation set is ~200 pairs; 50 is the floor below which the curve's tails are
#: a handful of edges each and the chosen threshold is noise with a decimal point.
MIN_SAMPLE = 50

#: Cost ratio the operating point is chosen against: one wrong INFERRED edge may cost
#: at most one edge's worth of review capacity that a flagged AMBIGUOUS edge would have
#: consumed.  Expressed as a required precision, because that is what a PR curve reads.
DEFAULT_MIN_PRECISION = 0.90

_SAMPLE_FILE = "sample.csv"
_SIGNALS_FILE = "signals.json"
_PROVENANCE_FILE = "provenance.json"


# ── the export half ──────────────────────────────────────────────────────────
@dataclass(frozen=True)
class Sample:
    """A drawn sample: the rows a human fills in, and the signals they must not see."""

    rows: list[dict[str, str]]
    signals: dict[str, dict[str, float]]
    #: Scored edges in the graph when the sample was drawn (0 means nothing to draw).
    population: int
    #: How many of the drawn edges carry each signal (an edge may carry both).
    per_signal: dict[str, int]


def edge_id(edge: GraphEdge) -> str:
    """Stable short id for an edge, so a labelled row can be joined back to its signals.

    Derived from (source, label, target) rather than from the row's position: a CSV
    that a human sorts, edits or reorders still joins correctly, and two runs over the
    same graph produce the same ids.
    """
    key = f"{edge.source}\x00{edge.label}\x00{edge.target}".encode()
    return hashlib.sha1(key).hexdigest()[:12]


def scored_edges(graph: Graph) -> list[GraphEdge]:
    """Edges whose confidence depends on one of :data:`SIGNAL_KEYS`.

    Everything else in a graph is EXTRACTED (an AST ``calls``/``defines`` edge, a
    direct memory relation) and needs no threshold: it asserts what a document said.
    """
    return [
        edge
        for edge in graph.edges
        if edge.semantic_score is not None or edge.cooccurrence_count is not None
    ]


def _signal_value(edge: GraphEdge, signal: str) -> float | None:
    value = getattr(edge, signal)
    return None if value is None else float(value)


def _stratified_pick(
    scored: list[GraphEdge],
    limit: int,
    rng: random.Random,
    by_signal: dict[str, list[GraphEdge]],
) -> list[GraphEdge]:
    """Sample *limit* edges, keeping a proportional share of each signal family.

    Plain uniform sampling fails the rarer signal: with co-occurrence edges at 4% of
    the population a 200-edge draw would contain ~8 of them, and the tail of that curve
    — exactly where the INFERRED boundary sits — would be one or two edges wide.
    Stratifying by family makes the rare signal's curve usable without over-weighting it
    in the population totals (the curve itself is still computed over all labelled
    edges carrying that signal).
    """
    if limit >= len(scored):
        return scored
    picks: list[GraphEdge] = []
    seen: set[str] = set()
    for signal in SIGNAL_KEYS:
        family = by_signal.get(signal) or []
        if not family:
            continue
        quota = max(1, round(limit * len(family) / len(scored)))
        for edge in rng.sample(family, min(quota, len(family))):
            if edge_id(edge) not in seen:
                seen.add(edge_id(edge))
                picks.append(edge)
    remainder = [edge for edge in scored if edge_id(edge) not in seen]
    if len(picks) < limit and remainder:
        picks.extend(rng.sample(remainder, min(limit - len(picks), len(remainder))))
    return picks


def sample_scored_edges(graph: Graph, *, limit: int, seed: int) -> Sample:
    """Draw a labelling sample from *graph*.

    Deterministic for a given (graph, limit, seed): the ordering is sorted first, so an
    insertion-order difference in the input cannot change the draw.
    """
    scored = sorted(scored_edges(graph), key=lambda e: (e.source, e.label, e.target))
    by_signal: dict[str, list[GraphEdge]] = {
        signal: [edge for edge in scored if _signal_value(edge, signal) is not None]
        for signal in SIGNAL_KEYS
    }
    if not scored:
        return Sample(
            rows=[], signals={}, population=0, per_signal={k: 0 for k in SIGNAL_KEYS}
        )

    rng = random.Random(seed)
    picked = _stratified_pick(scored, max(1, limit), rng, by_signal)
    labels = {node.id: (node.label or node.id) for node in graph.nodes}

    rows: list[dict[str, str]] = []
    signals: dict[str, dict[str, float]] = {}
    for edge in picked:
        ident = edge_id(edge)
        # The blank `real` column is the deliverable: fill it with true / false.
        rows.append(
            {
                "edge_id": ident,
                "source_label": labels.get(edge.source, edge.source),
                "target_label": labels.get(edge.target, edge.target),
                "relation": edge.label,
                "real": "",
            }
        )
        values = {
            k: v for k in SIGNAL_KEYS if (v := _signal_value(edge, k)) is not None
        }
        signals[ident] = values

    return Sample(
        rows=rows,
        signals=signals,
        population=len(scored),
        per_signal={k: len(v) for k, v in by_signal.items()},
    )


def write_sample(
    sample: Sample, directory: str, *, provenance: dict[str, Any]
) -> list[str]:
    """Write ``sample.csv`` / ``signals.json`` / ``provenance.json``; return the paths.

    The signals file is written with the ids in the CSV, never merged into it — see the
    module docstring for why the split is load-bearing rather than cosmetic.
    """
    os.makedirs(directory, exist_ok=True)
    paths = {
        name: os.path.join(directory, name)
        for name in (_SAMPLE_FILE, _SIGNALS_FILE, _PROVENANCE_FILE)
    }
    with open(paths[_SAMPLE_FILE], "w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(
            handle,
            fieldnames=["edge_id", "source_label", "target_label", "relation", "real"],
        )
        writer.writeheader()
        writer.writerows(sample.rows)
    with open(paths[_SIGNALS_FILE], "w", encoding="utf-8") as handle:
        json.dump(sample.signals, handle, indent=2, sort_keys=True)
    with open(paths[_PROVENANCE_FILE], "w", encoding="utf-8") as handle:
        json.dump(
            {
                **provenance,
                "population": sample.population,
                "drawn": len(sample.rows),
                "per_signal": sample.per_signal,
            },
            handle,
            indent=2,
            sort_keys=True,
        )
    return [paths[_SAMPLE_FILE], paths[_SIGNALS_FILE], paths[_PROVENANCE_FILE]]


# ── the scoring half ─────────────────────────────────────────────────────────
@dataclass(frozen=True)
class CurvePoint:
    """One threshold on a precision/recall curve."""

    threshold: float
    predicted: int
    true_positives: int
    false_positives: int
    false_negatives: int
    #: ``None`` when the sweep predicts nothing at this threshold (no precision exists).
    precision: float | None
    #: ``None`` when the labelled sample carries no positive for this signal.
    recall: float | None


@dataclass(frozen=True)
class Derived:
    """What the sample supports — or the reason it supports nothing."""

    labelled: int
    positives: int
    signal: str
    curve: list[CurvePoint]
    point: CurvePoint | None
    refusal: str | None


def parse_label(raw: str | None) -> bool | None:
    """Read a hand-filled ``real`` cell.  Anything unrecognised is None, never False.

    An unreadable cell must not silently count as a negative: that inflates precision at
    every threshold, which is the one direction this harness must never err in.
    """
    text = (raw or "").strip().lower()
    if text in {"true", "t", "yes", "y", "1", "real"}:
        return True
    if text in {"false", "f", "no", "n", "0", "not real", "not-real", "fake"}:
        return False
    return None


def load_labels(
    directory: str,
) -> tuple[dict[str, bool], dict[str, dict[str, float]], list[str]]:
    """Read the filled sample back.  Returns (labels, signals, rejected ids)."""
    sample_path = os.path.join(directory, _SAMPLE_FILE)
    signals_path = os.path.join(directory, _SIGNALS_FILE)
    with open(signals_path, encoding="utf-8") as handle:
        signals: dict[str, dict[str, float]] = json.load(handle)
    labels: dict[str, bool] = {}
    rejected: list[str] = []
    with open(sample_path, newline="", encoding="utf-8") as handle:
        for row in csv.DictReader(handle):
            ident = (row.get("edge_id") or "").strip()
            if not ident or ident not in signals:
                if ident:
                    rejected.append(ident)
                continue
            value = parse_label(row.get("real"))
            if value is None:
                rejected.append(ident)
                continue
            labels[ident] = value
    return labels, signals, rejected


def precision_recall_curve(
    labels: dict[str, bool],
    signals: dict[str, dict[str, float]],
    signal: str,
) -> list[CurvePoint]:
    """Sweep *signal* over every distinct observed value, ascending.

    The population is the labelled edges that CARRY the signal: an edge with no
    ``semantic_score`` is decided by a different rule, so counting it as a negative here
    would measure the rule that is not under test.
    """
    pairs = [
        (values[signal], labels[ident])
        for ident, values in signals.items()
        if signal in values and ident in labels
    ]
    if not pairs:
        return []
    thresholds = sorted({value for value, _ in pairs})
    positives = sum(1 for _, real in pairs if real)
    points: list[CurvePoint] = []
    for threshold in thresholds:
        true_positives = sum(1 for value, real in pairs if value >= threshold and real)
        false_positives = sum(
            1 for value, real in pairs if value >= threshold and not real
        )
        false_negatives = positives - true_positives
        predicted = true_positives + false_positives
        points.append(
            CurvePoint(
                threshold=threshold,
                predicted=predicted,
                true_positives=true_positives,
                false_positives=false_positives,
                false_negatives=false_negatives,
                precision=(true_positives / predicted) if predicted else None,
                recall=(true_positives / positives) if positives else None,
            )
        )
    return points


def operating_point(curve: list[CurvePoint], min_precision: float) -> CurvePoint | None:
    """Lowest threshold whose precision holds at or above *min_precision* everywhere above it.

    "Everywhere above" is the part that matters: precision is not monotone, and a curve
    that dips at a high threshold would otherwise let the sweep pick a low threshold
    justified only by edges above the dip.  So the answer is the first threshold above
    the HIGHEST violating one.
    """
    if not curve:
        return None
    highest_violation = -1
    for index, point in enumerate(curve):
        if point.precision is not None and point.precision < min_precision:
            highest_violation = index
    candidate = (
        curve[highest_violation + 1] if highest_violation + 1 < len(curve) else None
    )
    return candidate


def derive(
    labels: dict[str, bool],
    signals: dict[str, dict[str, float]],
    signal: str,
    *,
    min_precision: float = DEFAULT_MIN_PRECISION,
    min_sample: int = MIN_SAMPLE,
) -> Derived:
    """One signal's curve and operating point, or the reason there is none."""
    curve = precision_recall_curve(labels, signals, signal)
    positives = sum(1 for real in labels.values() if real)
    if not curve:
        return Derived(
            len(labels),
            positives,
            signal,
            [],
            None,
            f"no labelled edge carries {signal}",
        )
    if len(labels) < min_sample:
        return Derived(
            len(labels),
            positives,
            signal,
            curve,
            None,
            f"only {len(labels)} labelled edges; {min_sample} are required before "
            f"this harness will name a threshold",
        )
    if positives == 0 or positives == len(labels):
        return Derived(
            len(labels),
            positives,
            signal,
            curve,
            None,
            "the labels are one class only, so no threshold separates anything",
        )
    point = operating_point(curve, min_precision)
    refusal = (
        None
        if point is not None
        else (f"no threshold reaches precision {min_precision:.2f} anywhere above it")
    )
    return Derived(len(labels), positives, signal, curve, point, refusal)


def render_report(
    derived: Iterable[Derived],
    *,
    min_precision: float,
    provenance: dict[str, Any],
    rejected: Iterable[str] = (),
) -> str:
    """Markdown report: provenance, one curve per signal, the operating point, the caveat."""
    rejected = list(rejected)
    lines: list[str] = [
        "# kgraph edge-signal calibration",
        "",
        "GENERATED — re-run the harness rather than editing this by hand.",
        "",
        "## Provenance",
        "",
    ]
    for key in sorted(provenance):
        lines.append(f"- **{key}**: {provenance[key]}")
    lines.append(f"- **precision floor**: {min_precision:.2f}")
    if rejected:
        lines.append(f"- **unlabelled / unreadable rows dropped**: {len(rejected)}")
    for item in derived:
        lines += ["", f"## {item.signal}", ""]
        point = item.point
        if item.refusal or point is None:
            lines.append(
                f"**No threshold named.** {item.refusal or 'the sweep produced no point'}."
            )
        else:
            lines += [
                f"**Operating point: {point.threshold:g}** — precision "
                f"{_pct(point.precision)}, recall {_pct(point.recall)} over "
                f"{item.labelled} labelled edges ({item.positives} real).",
                "",
                "The floor holds at this threshold and every higher one. Apply it to "
                "`confidence.py` by hand, with this report as the review evidence.",
            ]
        lines += [
            "",
            "| threshold | predicted | TP | FP | FN | precision | recall |",
            "|---:|---:|---:|---:|---:|---:|---:|",
        ]
        for point in item.curve:
            lines.append(
                f"| {point.threshold:g} | {point.predicted} | {point.true_positives} | "
                f"{point.false_positives} | {point.false_negatives} | "
                f"{_pct(point.precision)} | {_pct(point.recall)} |"
            )
        lowest = item.curve[0].threshold if item.curve else None
        if (
            item.point is not None
            and lowest is not None
            and item.point.threshold == lowest
        ):
            lines += [
                "",
                "> The operating point is the LOWEST observed value, so the floor "
                "holds across the whole range: this sample does not locate a "
                "boundary. Do not move a constant on this evidence alone.",
            ]
    return "\n".join(lines) + "\n"


def _pct(value: float | None) -> str:
    return "—" if value is None else f"{value * 100:.1f}%"


# ── CLI ──────────────────────────────────────────────────────────────────────
def _provenance(graph_db: str, *, seed: int, limit: int) -> dict[str, Any]:
    path = os.path.expanduser(graph_db)
    stat: dict[str, Any] = {}
    if os.path.exists(path):
        stat = {
            "graph_db": path,
            "graph_mtime": datetime.datetime.fromtimestamp(
                os.path.getmtime(path)
            ).isoformat(timespec="seconds"),
            "graph_bytes": os.path.getsize(path),
        }
    return {
        **stat,
        "seed": seed,
        "limit": limit,
        "vocabulary_version": read_graph_meta_value(path, "vocabulary_version"),
    }


@dataclass(frozen=True)
class Result:
    """What the CLI boundary should emit.  ``main`` returns it; the ``__main__`` block prints.

    The package invariant is that only ``cli.py`` prints (tests/test_kgraph_package.py):
    a library module returns data, and a ``python -m kgraph.<module>`` block IS a CLI
    boundary.  Returning the text keeps that invariant true while leaving the argv
    handling and the exit code testable in-process.
    """

    output: str = ""
    error: str = ""
    code: int = 0


def main(argv: list[str] | None = None) -> Result:
    """``python -m kgraph.calibrate`` — export a sample, or score a returned one."""
    import argparse

    parser = argparse.ArgumentParser(
        prog="kgraph-calibrate",
        description="Calibrate the INFERRED/AMBIGUOUS edge thresholds from a labelled sample.",
    )
    parser.add_argument("--graph-db", default=GRAPH_DB_DEFAULT)
    parser.add_argument(
        "--export", metavar="DIR", help="write a labelling sample into DIR"
    )
    parser.add_argument(
        "--score", metavar="DIR", help="score the sample in DIR (real filled)"
    )
    parser.add_argument(
        "--limit", type=int, default=200, help="edges to draw (default 200)"
    )
    parser.add_argument("--seed", type=int, default=0)
    parser.add_argument("--min-precision", type=float, default=DEFAULT_MIN_PRECISION)
    parser.add_argument(
        "--report", metavar="PATH", help="write the markdown report here"
    )
    args = parser.parse_args(sys.argv[1:] if argv is None else argv)

    if args.export:
        graph = load_from_graph_db(args.graph_db)
        sample = sample_scored_edges(graph, limit=args.limit, seed=args.seed)
        if not sample.rows:
            return Result(
                error=(
                    f"Nothing to calibrate: {len(graph.edges)} edges, none carry "
                    f"{' or '.join(SIGNAL_KEYS)} — the scored edges this calibration is "
                    f"for are not in this graph."
                ),
                code=2,
            )
        paths = write_sample(
            sample,
            args.export,
            provenance=_provenance(args.graph_db, seed=args.seed, limit=args.limit),
        )
        return Result(
            output=(
                f"Drew {len(sample.rows)} of {sample.population} scored edges "
                f"({', '.join(f'{k}={v}' for k, v in sample.per_signal.items())}).\n"
                f"Next: fill the `real` column (true / false) in {paths[0]}, "
                f"then run --score {args.export}.\n"
            )
        )

    if args.score:
        labels, signals, rejected = load_labels(args.score)
        derived = [
            derive(labels, signals, signal, min_precision=args.min_precision)
            for signal in SIGNAL_KEYS
        ]
        provenance = {
            "sample": os.path.join(args.score, _SAMPLE_FILE),
            "labelled": len(labels),
        }
        report = render_report(
            derived,
            min_precision=args.min_precision,
            provenance=provenance,
            rejected=rejected,
        )
        if args.report:
            with open(args.report, "w", encoding="utf-8") as handle:
                handle.write(report)
        return Result(
            output=report, code=0 if any(item.point for item in derived) else 2
        )

    return Result(error=parser.format_help(), code=1)


if __name__ == "__main__":  # CLI boundary: the only place this module emits
    _RESULT = main()
    if _RESULT.output:
        sys.stdout.write(_RESULT.output)
    if _RESULT.error:
        sys.stderr.write(
            _RESULT.error if _RESULT.error.endswith("\n") else _RESULT.error + "\n"
        )
    raise SystemExit(_RESULT.code)
