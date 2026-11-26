"""Tests for scripts/kgraph/analysis.py — the capability ported from graphify.

Each case names the wrong outcome it detects:

* an analysis that reads MEMORY nodes as code would flood the wiring-gap report with
  claims that cannot have callers — the first real run produced 983 such rows;
* counting call SITES as isolated symbols puts `/usr/bin/smbd` and `bats` in a list of
  unwired functions, which is how a useful signal becomes noise;
* a call that resolved to a function must not be reported unresolved — that inverts
  the whole point of the check;
* coverage that counted a test-only reference as production coverage would report a
  function as tested when no product code calls it.
"""

from __future__ import annotations

from kgraph.analysis import (
    build_report,
    call_frequency,
    format_report,
    isolated_symbols,
    test_coverage as coverage_of,
    unresolved_calls,
)
from kgraph.models import Graph


def _node(node_id: str, label: str, node_type: str, file: str = "", language: str = "python"):
    return {"id": node_id, "label": label, "type": node_type, "file": file, "language": language}


def _edge(source: str, target: str, label: str = "calls"):
    return {"source": source, "target": target, "label": label}


def _graph(nodes, edges) -> Graph:
    return Graph.from_dict({"nodes": nodes, "edges": edges})


def test_isolated_symbols_ignores_memory_nodes():
    """Detects: memory claims counted as unwired code, drowning the real signal."""
    graph = _graph(
        [
            _node("ast_func:python:lonely", "lonely", "function", "scripts/a.py"),
            _node("claim:abc", "a preference", "claim", ""),
            _node("synthesis:xyz", "current state", "synthesis", ""),
        ],
        [],
    )
    labels = {s.label for s in isolated_symbols(graph)}
    assert labels == {"lonely"}, "only code symbols belong in the wiring-gap list"


def test_isolated_symbols_ignores_call_sites():
    """Detects: external commands listed as unwired functions."""
    graph = _graph(
        [
            _node("ast_call:bash:/usr/bin/smbd", "/usr/bin/smbd", "call", "", "bash"),
            _node("ast_file:x", "x", "file", "bin/x.sh", "bash"),
        ],
        [_edge("ast_file:x", "ast_call:bash:/usr/bin/smbd")],
    )
    assert isolated_symbols(graph) == ()


def test_isolated_symbols_separates_no_edge_from_defined_only():
    """Detects: collapsing degree 0 and degree 1, which makes the count meaningless."""
    graph = _graph(
        [
            _node("ast_func:python:orphan", "orphan", "function", "a.py"),
            _node("ast_func:python:declared", "declared", "function", "a.py"),
            _node("ast_file:a", "a", "file", "a.py"),
        ],
        [_edge("ast_file:a", "ast_func:python:declared", "defines")],
    )
    by_label = {s.label: s for s in isolated_symbols(graph)}
    assert by_label["orphan"].defined_only is False, "no edge at all is the stronger signal"
    assert by_label["declared"].defined_only is True


def test_resolved_call_is_not_reported_unresolved():
    """Detects: a call with a known target listed as unresolved."""
    graph = _graph(
        [
            _node("ast_call:python:helper", "helper", "call", "scripts/a.py"),
            _node("ast_func:python:helper", "helper", "function", "scripts/a.py"),
        ],
        [_edge("ast_call:python:helper", "ast_func:python:helper")],
    )
    assert unresolved_calls(graph) == ()


def test_external_command_is_flagged_not_hidden():
    """Detects: an external program counted as a code call with no target."""
    graph = _graph(
        [
            _node("ast_call:bash:/bin/ping", "/bin/ping", "call", "bin/x.sh", "bash"),
            _node("ast_call:bash:mystery", "mystery", "call", "bin/x.sh", "bash"),
        ],
        [],
    )
    rows = {r.label: r for r in unresolved_calls(graph)}
    assert rows["/bin/ping"].external is True
    assert rows["mystery"].external is False


def test_coverage_counts_a_test_reference_only():
    """Detects: production calls inflating coverage, or test calls missed."""
    graph = _graph(
        [
            _node("ast_file:tests", "tests/test_a.py", "file", "tests/test_a.py"),
            _node("ast_call:python:covered", "covered", "call", "tests/test_a.py"),
            _node("ast_func:python:covered", "covered", "function", "scripts/a.py"),
            _node("ast_func:python:untested", "untested", "function", "scripts/b.py"),
            _node("ast_file:prod", "prod", "file", "scripts/b.py"),
            _node("ast_call:python:untested", "untested", "call", "scripts/b.py"),
            _node("ast_func:python:untested2", "untested2", "function", "scripts/b.py"),
        ],
        [
            _edge("ast_file:tests", "ast_call:python:covered"),
            _edge("ast_call:python:covered", "ast_func:python:covered"),
            _edge("ast_file:prod", "ast_call:python:untested"),
            _edge("ast_call:python:untested", "ast_func:python:untested2"),
        ],
    )
    report = coverage_of(graph)
    assert "ast_func:python:covered" in report.covered
    assert "ast_func:python:untested2" in report.uncovered
    assert report.total == 3


def test_format_report_states_what_each_section_does_not_mean():
    """Detects: a report read as a dead-code verdict."""
    text = format_report(build_report(_graph([], [])))
    for phrase in ("not dead code", "NOT a dead-code claim", "not execution"):
        assert phrase in text, f"the report must caveat itself: missing {phrase!r}"


def test_call_frequency_counts_real_occurrences(tmp_path):
    """Detects: a frequency table built from one edge per pair, i.e. all counts 1."""
    (tmp_path / "a.py").write_text(
        "def helper():\n    return 1\n\n\ndef caller():\n    helper()\n    helper()\n    helper()\n",
        encoding="utf-8",
    )
    graph = _graph(
        [
            _node("ast_func:python:helper", "helper", "function", "a.py"),
            _node("ast_func:python:caller", "caller", "function", "a.py"),
        ],
        [],
    )
    freq = call_frequency(graph, tmp_path)
    pairs = {(c, e): n for c, e, n in freq.pairs}
    assert pairs[("caller", "helper")] == 3, "the count must be occurrences, not edges"
    assert freq.total_calls == 3


def test_call_frequency_excludes_command_names_and_unknown_callees(tmp_path):
    """Detects: `grep x63` in the table — a callee no graph edge could ever weight."""
    (tmp_path / "b.sh").write_text(
        "#!/usr/bin/env bash\nhelper() { :; }\ncaller() { helper; helper; grep x /dev/null; }\n",
        encoding="utf-8",
    )
    graph = _graph(
        [
            _node("ast_func:bash:helper", "helper", "function", "b.sh", "bash"),
            _node("ast_func:bash:caller", "caller", "function", "b.sh", "bash"),
        ],
        [],
    )
    freq = call_frequency(graph, tmp_path)
    pairs = {(c, e): n for c, e, n in freq.pairs}
    assert pairs[("caller", "helper")] == 2
    assert not any(callee == "grep" for _, callee, _ in freq.pairs)


def test_report_without_a_source_root_says_so_rather_than_printing_zero():
    """Detects: a missing root rendered as '0 call sites', i.e. a false measurement."""
    text = format_report(build_report(_graph([], [])))
    assert "pass --repo" in text


def test_coverage_against_the_real_extractor_is_not_zero(tmp_path):
    """Detects: a coverage figure that is 0% because it keyed on a field the real
    graph leaves empty.  The hand-built fixture above sets `file` on the file node and
    therefore could not disagree with the implementation — this one runs the extractor
    that actually produces the graph, so a wrong field access shows up as 0/2.
    """
    from kgraph.ast_extractor import extract_repo_graph

    (tmp_path / "scripts").mkdir()
    (tmp_path / "tests").mkdir()
    (tmp_path / "scripts" / "a.py").write_text("def helper():\n    return 1\n", encoding="utf-8")
    (tmp_path / "tests" / "test_a.py").write_text(
        "from scripts.a import helper\n\n\ndef test_it():\n    helper()\n", encoding="utf-8"
    )
    graph = Graph.from_dict(extract_repo_graph(str(tmp_path)))
    report = coverage_of(graph)
    assert report.total >= 2, "the extractor must see both functions"
    assert report.covered, "a function called from tests/ cannot be 0% covered"
    assert len(report.covered) < report.total, "and the untested one must stay uncovered"
