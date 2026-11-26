"""Tests for tools/kgraph_deadcode_audit.py — the dead-code certification harness.

Each case names the wrong outcome it detects:

* a false-unused that PASSES would be the whole failure mode this tool exists to
  catch — the graph calling live code dead, with a green tick in front of it;
* a blank truth cell that PASSES would make the bar vacuous: two thirds of the
  sample is never verified, and the suite still reads green;
* an emit that pre-fills truth would let the tool certify itself from the verdict
  it is supposed to be checking.
"""

from __future__ import annotations

import json
import sqlite3
from pathlib import Path

import pytest

from tools import kgraph_deadcode_audit as audit

HEADER = "\t".join(audit.COLUMNS)


def _db(path: Path) -> Path:
    """A graph holding two bash and two Python functions, one of each called."""
    con = sqlite3.connect(path)
    con.execute("create table graph_nodes(id text, label text, payload text)")
    con.execute("create table graph_edges(source text, target text, label text, payload text)")
    for lang, name, called in (
        ("bash", "called_fn", True),
        ("bash", "dead_fn", False),
        ("python", "called_py", True),
        ("python", "dead_py", False),
    ):
        con.execute(
            "insert into graph_nodes values(?,?,?)",
            (
                f"ast_func:{lang}:{name}",
                name,
                json.dumps({"type": "function", "language": lang, "file": f"{name}.sh"}),
            ),
        )
        if called:
            con.execute(
                "insert into graph_edges values(?,?,?,?)",
                ("ast_file:caller", f"ast_func:{lang}:{name}", "calls", "{}"),
            )
        # the `defines` edge must never count as a call
        con.execute(
            "insert into graph_edges values(?,?,?,?)",
            (f"ast_file:{name}", f"ast_func:{lang}:{name}", "defines", "{}"),
        )
    con.commit()
    con.close()
    return path


def test_check_passes_when_the_graph_and_the_sample_agree(tmp_path, capsys):
    db = _db(tmp_path / "g.sqlite")
    sample = tmp_path / "s.tsv"
    sample.write_text(
        "\n".join(
            [
                HEADER,
                "bash\tcalled_fn\tcalled_fn.sh\tused\tast_file:caller\tused\ta.sh:1",
                "bash\tdead_fn\tdead_fn.sh\tunused\t-\tunused\tno call site",
            ]
        )
        + "\n"
    )
    assert audit.main(["--db", str(db), "--check", str(sample)]) == 0
    assert "PASS" in capsys.readouterr().out


def test_check_fails_on_a_false_unused_and_names_it(tmp_path, capsys):
    """The bar: a function the sample proves is called must not read as dead."""
    db = _db(tmp_path / "g.sqlite")
    sample = tmp_path / "s.tsv"
    sample.write_text(
        "\n".join(
            [
                HEADER,
                # `dead_fn` has no calls edge in the graph, but the sample verified a call.
                "bash\tdead_fn\tdead_fn.sh\tunused\t-\tused\tscripts/x.sh:42 dead_fn",
            ]
        )
        + "\n"
    )
    assert audit.main(["--db", str(db), "--check", str(sample)]) == 1
    out = capsys.readouterr().out
    assert "FALSE-UNUSED" in out
    assert "dead_fn" in out
    assert "scripts/x.sh:42" in out


def test_check_refuses_a_blank_truth_cell(tmp_path, capsys):
    """An unverified row is unfinished, never a pass."""
    db = _db(tmp_path / "g.sqlite")
    sample = tmp_path / "s.tsv"
    sample.write_text("\n".join([HEADER, "bash\tdead_fn\tdead_fn.sh\tunused\t-\t\t"]) + "\n")
    assert audit.main(["--db", str(db), "--check", str(sample)]) == 2
    assert "CANNOT CERTIFY" in capsys.readouterr().err


def test_emit_leaves_truth_blank_and_counts_per_language(tmp_path):
    db = _db(tmp_path / "g.sqlite")
    out = tmp_path / "sample.tsv"
    assert audit.main(["--db", str(db), "--emit", str(out), "--sample", "1"]) == 0
    rows = [ln.split("\t") for ln in out.read_text().splitlines() if ln.strip()]
    assert rows[0] == list(audit.COLUMNS)
    data = rows[1:]
    assert len(data) == 2, "one bash and one python at --sample 1"
    assert {r[0] for r in data} == {"bash", "python"}
    assert all(r[5] == "" for r in data), "truth must be blank for a human to fill"


def test_missing_graph_db_is_cannot_run(tmp_path):
    with pytest.raises(SystemExit) as exc:
        audit.main(["--db", str(tmp_path / "absent.sqlite"), "--report"])
    assert "no graph DB" in str(exc.value)
