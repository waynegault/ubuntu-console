"""The dead-code bar, enforced against a FRESH graph.

`tools/kgraph-deadcode-sample.tsv` stores 200 hand-verified truths. Checking the file
against its own `kgraph` column would only prove the file has not changed — a gate that
cannot fail. This builds the graph from the CURRENT tree and re-derives every verdict,
so an extractor regression that starts reporting live code as dead fails here.

Marked `slow`: extraction is ~50 s over the whole repo, which is the cost of asking a
whole-tree question.
"""

from __future__ import annotations

from pathlib import Path

import pytest

from kgraph.ast_extractor import extract_repo_graph

REPO_ROOT = Path(__file__).resolve().parent.parent
SAMPLE = REPO_ROOT / "tools" / "kgraph-deadcode-sample.tsv"


def _rows():
    rows = []
    for line in SAMPLE.read_text(encoding="utf-8").splitlines():
        if not line.strip() or line.startswith("#"):
            continue
        cells = line.split("\t")
        if cells[0] == "lang":
            continue
        rows.append(cells)
    return rows


def test_every_row_carries_a_verified_truth():
    """Detects: a sample that looks certified while rows are still unverified."""
    rows = _rows()
    assert len(rows) == 200, f"the bar is 200 rows, found {len(rows)}"
    blank = [r[1] for r in rows if len(r) < 6 or r[5] not in ("used", "unused")]
    assert not blank, f"{len(blank)} row(s) have no truth value, e.g. {blank[:5]}"
    assert all((len(r) > 6 and r[6].strip()) for r in rows), "every row needs its evidence"


@pytest.mark.slow
def test_no_false_unused_against_a_fresh_graph():
    """Detects: the extractor regressing so a USE-function is reported with no caller.

    A false-unused is the error that gets live code deleted, so it is the only
    direction that fails. False-used is tolerated by design: it hides dead code.
    """
    graph = extract_repo_graph(str(REPO_ROOT))
    called = {e["target"] for e in graph["edges"] if e.get("label") == "calls"}
    # `extract_repo_graph` returns plain dicts whose fields are first-class
    # (`type`, `id`, `label`) — not the DB's JSON `payload` column.
    functions = {n["id"] for n in graph["nodes"] if n.get("type") == "function"}

    missed = []
    for cells in _rows():
        lang, name, defined_in, _kgraph, _callers, truth = cells[0], cells[1], cells[2], cells[3], cells[4], cells[5]
        if truth != "used":
            continue
        node_id = f"ast_func:{lang}:{name}"
        if node_id not in functions:
            missed.append(f"{name} ({defined_in}) — not in the graph at all")
        elif node_id not in called:
            missed.append(f"{name} ({defined_in}) — verified used, graph reports no caller")

    assert not missed, "FALSE-UNUSED on the certified sample:\n  " + "\n  ".join(missed)
