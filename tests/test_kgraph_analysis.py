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
