"""Tests for the two capabilities added from graphify's set: report-in-HTML and the diff.

Each case names the wrong outcome it detects:

* a report injected WITHOUT escaping would let a node label containing `<script>` break
  the page — the payload is escaped for exactly that reason, and the narrative must be
  too;
* a diff that reads the stored verdict instead of both graphs cannot see a change at all;
* a diff that counts a lost caller as "dead" would turn a structural fact into a verdict
  the tool has no evidence for — the line says so and the gate keys on the fact only.
"""

from __future__ import annotations

import json

from kgraph.diff_report import diff, format_report
from kgraph.html import _report_html, generate_html


def _graph(nodes, edges):
    return {"nodes": nodes, "edges": edges}


def _node(nid, label, ntype="function"):
    return {"id": nid, "label": label, "type": ntype}


def _edge(src, dst, label="calls"):
    return {"source": src, "target": dst, "label": label}


def test_report_html_escapes_a_label_that_looks_like_markup():
    """Detects: an unescaped label injecting markup into the viewer page."""
    rendered = _report_html("# T\n\n- <script>alert(1)</script>")
    assert "<script>" not in rendered
    assert "&lt;script&gt;" in rendered


def test_report_html_renders_headings_bullets_and_bold():
    """Detects: a renderer that drops the structure, leaving a wall of text."""
    rendered = _report_html("# Title\n\n## Summary\n- **Nodes:** 5\n")
    assert "<h2>Title</h2>" in rendered
    assert "<h3>Summary</h3>" in rendered
    assert "<strong>Nodes:</strong> 5" in rendered


def test_generate_html_embeds_the_report_when_given(tmp_path):
    """Detects: the page written without the narrative, which was the whole gap."""
    out = tmp_path / "g.html"
    generate_html(_graph([], []), str(out), report_text="# Title\n\n## Summary\n- x")
    page = out.read_text()
    assert 'id="kgraph-report"' in page
    assert "<h2>Title</h2>" in page


def test_generate_html_without_a_report_is_unchanged(tmp_path):
    """Detects: the narrative section appearing when none was asked for."""
    out = tmp_path / "g.html"
    generate_html(_graph([], []), str(out))
    assert 'id="kgraph-report"' not in out.read_text()


def test_diff_reports_a_lost_last_caller(tmp_path):
    """Detects: a change that orphans a function going unnoticed."""
    before = tmp_path / "b.json"
    after = tmp_path / "a.json"
    nodes = [_node("ast_func:python:helper", "helper"), _node("ast_file:a", "a", "file")]
    before.write_text(json.dumps(_graph(nodes, [_edge("ast_file:a", "ast_func:python:helper")])))
    after.write_text(json.dumps(_graph(nodes, [])))
    report = diff(before, after)
    assert report.lost_last_caller == ["helper"]
    assert report.has_orphaning is True


def test_diff_treats_a_registers_edge_as_a_use(tmp_path):
    """Detects: a decorator registration removed read as no change at all."""
    before = tmp_path / "b.json"
    after = tmp_path / "a.json"
    nodes = [_node("ast_func:python:tool", "tool")]
    before.write_text(json.dumps(_graph(nodes, [_edge("ast_file:a", "ast_func:python:tool", "registers")])))
    after.write_text(json.dumps(_graph(nodes, [])))
    assert diff(before, after).lost_last_caller == ["tool"]


def test_diff_counts_added_and_removed_edges_by_label(tmp_path):
    """Detects: a diff that reports only a total and cannot say WHAT appeared."""
    before = tmp_path / "b.json"
    after = tmp_path / "a.json"
    nodes = [_node("ast_func:python:x", "x"), _node("ast_func:python:y", "y")]
    before.write_text(json.dumps(_graph(nodes, [_edge("ast_func:python:x", "ast_func:python:y", "calls")])))
    after.write_text(json.dumps(_graph(nodes, [_edge("ast_func:python:x", "ast_func:python:y", "imports")])))
    report = diff(before, after)
    assert report.added["imports"] == 1
    assert report.removed["calls"] == 1
    text = format_report(report)
    assert "imports: 1" in text and "calls: 1" in text


def test_format_report_says_a_loss_is_not_a_death_claim():
    """Detects: the diff read as a dead-code verdict."""
    before = __import__("pathlib").Path("/tmp/_kg_diff_b.json")
    after = __import__("pathlib").Path("/tmp/_kg_diff_a.json")
    nodes = [_node("ast_func:python:gone", "gone")]
    before.write_text(json.dumps(_graph(nodes, [_edge("ast_file:a", "ast_func:python:gone")])))
    after.write_text(json.dumps(_graph(nodes, [])))
    text = format_report(diff(before, after))
    assert "NOT a claim that the function is dead" in text
