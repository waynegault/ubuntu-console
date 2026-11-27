"""Structural diff between two kgraph snapshots — the `diff_report` capability.

WHY (2026-11-27).  graphify ships a graph-to-graph delta; kgraph regenerates its graph on
every commit and had no way to say what a change DID to the wiring.  This answers the
question a commit cannot: which edges appeared, which disappeared, and which functions
lost their last caller.

INPUT.  Two JSON documents in kgraph's `Graph.to_dict()` shape.  `--before` may also be
a store path (a sqlite `graph_nodes`/`graph_edges` DB) so a commit can be compared with
what the box held before it.

WHAT IT REPORTS, and why each line is a measurement rather than a verdict:
  * edges added / removed, grouped by label;
  * functions that gained a caller, and functions that LOST their last one — the second
    is the only line that can precede dead code, and it is a fact about the two graphs,
    not a claim that the function is dead;
  * a `--fail-on-orphan` mode for a gate: exit 1 when a function that had a caller in
    `before` has none in `after`.
"""

from __future__ import annotations

import argparse
import json
import sqlite3
import sys
from collections import Counter
from dataclasses import dataclass, field
from pathlib import Path

# A `registers` edge is a USE (a decorator or dispatch-by-name reaches the function), so
# losing one matters exactly as much as losing a call.
_USE_LABELS = ("calls", "registers")


def _load(path: Path) -> tuple[set[tuple[str, str, str]], dict[str, str]]:
    """(edges as (source, target, label), node_id -> label) from JSON or a store."""
    if path.suffix in (".sqlite", ".db"):
        con = sqlite3.connect(path)
        con.row_factory = sqlite3.Row
        edges = {
            (r["source"], r["target"], r["label"]) for r in con.execute("select source, target, label from graph_edges")
        }
        nodes = {r[0]: r[0] for r in con.execute("select id from graph_nodes")}
        con.close()
        return edges, nodes

    doc = json.loads(path.read_text(encoding="utf-8"))
    edges = {(e["source"], e["target"], e.get("label") or "") for e in doc.get("edges", [])}
    nodes = {n["id"]: (n.get("label") or n["id"]) for n in doc.get("nodes", [])}
    return edges, nodes


def _functions_with_a_use(edges: set[tuple[str, str, str]], nodes: dict[str, str]) -> set[str]:
    """Function node ids that some USE edge targets."""
    return {t for (_, t, label) in edges if label in _USE_LABELS and t.startswith("ast_func:")}


@dataclass
class DiffReport:
    added: Counter[str] = field(default_factory=Counter)
    removed: Counter[str] = field(default_factory=Counter)
    gained_caller: list[str] = field(default_factory=list)
    lost_last_caller: list[str] = field(default_factory=list)
    new_nodes: int = 0
    gone_nodes: int = 0

    @property
    def has_orphaning(self) -> bool:
        return bool(self.lost_last_caller)


def diff(before: Path, after: Path) -> DiffReport:
    b_edges, b_nodes = _load(before)
    a_edges, a_nodes = _load(after)

    report = DiffReport()
    added = a_edges - b_edges
    removed = b_edges - a_edges
    report.added = Counter(label for _, _, label in added)
    report.removed = Counter(label for _, _, label in removed)
    report.new_nodes = len(set(a_nodes) - set(b_nodes))
    report.gone_nodes = len(set(b_nodes) - set(a_nodes))

    b_used = _functions_with_a_use(b_edges, b_nodes)
    a_used = _functions_with_a_use(a_edges, a_nodes)

    def _name(nid: str) -> str:
        return a_nodes.get(nid) or b_nodes.get(nid) or nid

    report.gained_caller = sorted(_name(n) for n in a_used - b_used)
    report.lost_last_caller = sorted(_name(n) for n in b_used - a_used)
    return report


def format_report(r: DiffReport) -> str:
    lines = ["# Graph diff", ""]
    lines.append(f"- nodes: +{r.new_nodes} / -{r.gone_nodes}")
    for side, counter in (("added", r.added), ("removed", r.removed)):
        total = sum(counter.values())
        lines.append(f"- edges {side}: {total}")
        for label, n in sorted(counter.items(), key=lambda kv: -kv[1]):
            lines.append(f"    {label}: {n}")
    lines.append("")
    lines.append(f"## Functions that GAINED a caller ({len(r.gained_caller)})")
    for n in r.gained_caller[:25]:
        lines.append(f"  {n}")
    if len(r.gained_caller) > 25:
        lines.append(f"  ... {len(r.gained_caller) - 25} more")
    lines.append("")
    lines.append(f"## Functions that LOST their last caller ({len(r.lost_last_caller)})")
    lines.append("  a fact about the two graphs, NOT a claim that the function is dead")
    for n in r.lost_last_caller[:25]:
        lines.append(f"  {n}")
    if len(r.lost_last_caller) > 25:
        lines.append(f"  ... {len(r.lost_last_caller) - 25} more")
    return "\n".join(lines)


def main(argv: list[str] | None = None) -> tuple[int, str]:
    ap = argparse.ArgumentParser(description="Structural diff between two kgraph snapshots")
    ap.add_argument("--before", type=Path, required=True, help="graph JSON, or a kgraph sqlite store")
    ap.add_argument("--after", type=Path, required=True, help="graph JSON, or a kgraph sqlite store")
    ap.add_argument(
        "--fail-on-orphan",
        action="store_true",
        help="exit 1 when a function that had a caller in --before has none in --after",
    )
    args = ap.parse_args(argv)
    return diff_text(args.before, args.after, args.fail_on_orphan)


def diff_text(before: Path, after: Path, fail_on_orphan: bool = False) -> tuple[int, str]:
    """(exit code, report text) — pure data, no printing.

    The library rule (tests/test_kgraph_package.py) allows `print` only in `cli.py` or
    inside a `__main__` block, so this module returns text and the entry point prints it.
    Measured 2026-11-27: printing here was the only red in a 3,614-case run.
    """
    report = diff(before, after)
    text = format_report(report)
    if fail_on_orphan and report.has_orphaning:
        text += f"\nFAIL — {len(report.lost_last_caller)} function(s) lost their last caller"
        return 1, text
    return 0, text


if __name__ == "__main__":
    _rc, _text = main()
    print(_text)
    sys.exit(_rc)
