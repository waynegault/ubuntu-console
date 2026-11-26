"""Call-site identity: the graph must name WHO calls a function, not just which file.

Each case names the wrong outcome it detects:

* without caller identity, a call made only from dead code keeps its target looking
  live, and no per-call analysis (frequency, unused call edges) can be attributed;
* without argument-call detection, a function dispatched as `run_it helper` looks
  callerless — measured 2026-11-26 on `_oc_promote_pass`, which is only ever invoked
  as an argument and was reported dead;
* if ANY argument word became a call, a path or a flag would invent a caller for a
  function of the same name, so a dead function could hide behind an unrelated string.
"""

from __future__ import annotations

import textwrap

import pytest

from _paths import SCRIPT_DIR  # noqa: F401  (import puts scripts/ on sys.path)

from kgraph.ast_extractor import extract_repo_graph


def _graph(tmp_path, filename: str, body: str):
    (tmp_path / filename).write_text(textwrap.dedent(body).lstrip(), encoding="utf-8")
    return extract_repo_graph(str(tmp_path))


def _edges(graph):
    """(source, target, label) for every edge, in either serialisation."""
    out = set()
    for e in graph["edges"]:
        src = e.get("source") or e.get("from")
        dst = e.get("target") or e.get("to")
        out.add((src, dst, e.get("label")))
    return out


def test_bash_caller_is_the_enclosing_function(tmp_path):
    """Detects: a call attributed only to the file, so "who calls it" is unanswerable."""
    g = _graph(
        tmp_path,
        "a.sh",
        """
        #!/usr/bin/env bash
        helper() { echo hi; }
        caller() { helper; }
        """,
    )
    edges = _edges(g)
    assert ("ast_func:bash:caller", "ast_call:bash:helper", "calls") in edges, (
        "the enclosing function must be recorded as the caller"
    )
    assert ("ast_call:bash:helper", "ast_func:bash:helper", "calls") in edges


def test_bash_function_passed_as_an_argument_is_a_call(tmp_path):
    """Detects: `run_it helper` leaving `helper` with no caller at all."""
    g = _graph(
        tmp_path,
        "a.sh",
        """
        #!/usr/bin/env bash
        callback() { echo hi; }
        run_it() { "$@"; }
        main() { run_it callback; }
        """,
    )
    edges = _edges(g)
    assert ("ast_func:bash:main", "ast_call:bash:callback", "calls") in edges
    assert ("ast_call:bash:callback", "ast_func:bash:callback", "calls") in edges


def test_an_argument_that_is_not_a_known_function_is_not_a_call(tmp_path):
    """Detects: over-matching, where a path or flag invents a caller for a dead function."""
    g = _graph(
        tmp_path,
        "a.sh",
        """
        #!/usr/bin/env bash
        callback() { echo hi; }
        run_it() { "$@"; }
        main() { run_it /tmp/some/path --flag; }
        """,
    )
    edges = _edges(g)
    assert not any(dst == "ast_call:bash:callback" for _, dst, _ in edges), (
        "no real call site exists, so no call node may be created"
    )
    assert ("ast_func:bash:main", "ast_call:bash:callback", "calls") not in edges


def test_python_caller_is_the_enclosing_function(tmp_path):
    """Detects: Python calls attributed to the file only, as bash was."""
    g = _graph(
        tmp_path,
        "m.py",
        """
        def helper():
            return 1


        def caller():
            return helper()
        """,
    )
    edges = _edges(g)
    assert ("ast_func:python:caller", "ast_call:python:helper", "calls") in edges


@pytest.mark.parametrize("lang_file", ["a.sh"])
def test_file_level_edges_are_retained(tmp_path, lang_file):
    """Detects: the caller edge replacing the file edge instead of joining it."""
    g = _graph(
        tmp_path,
        lang_file,
        """
        #!/usr/bin/env bash
        helper() { echo hi; }
        caller() { helper; }
        """,
    )
    edges = _edges(g)
    assert any(src.startswith("ast_file:") and dst == "ast_call:bash:helper" for src, dst, _ in edges), (
        "the file -> call edge must survive; consumers count callers by file"
    )


def test_python_function_used_as_a_table_value_is_a_call(tmp_path):
    """Detects: a CLI dispatch handler looked dead because it is only NAMED in a dict.

    `"benchmark": cmd_benchmark,` reaches the function; no call syntax exists, so a
    call-only extractor reports it unused (measured 2026-11-26: cmd_benchmark,
    cmd_audit and cmd_serve were all in the unused list).
    """
    g = _graph(
        tmp_path,
        "cli.py",
        """
        def cmd_benchmark():
            return 1


        COMMANDS = {"benchmark": cmd_benchmark}
        """,
    )
    edges = _edges(g)
    assert ("ast_call:python:cmd_benchmark", "ast_func:python:cmd_benchmark", "calls") in edges
    assert any(dst == "ast_call:python:cmd_benchmark" for _, dst, _ in edges), (
        "the file that names it must be recorded as a caller"
    )


def test_a_definition_name_is_not_a_reference(tmp_path):
    """Detects: a function credited with calling itself because its `def` line matches."""
    g = _graph(
        tmp_path,
        "m.py",
        """
        def lonely():
            return 1
        """,
    )
    edges = _edges(g)
    assert not any(src == "ast_call:python:lonely" for src, _, _ in edges), (
        "the definition name must not create a call node"
    )


def test_a_registration_decorator_makes_the_function_used(tmp_path):
    """Detects: `@mcp.tool()` registering a function by name, which no textual
    reference can see — investigator's `retrieval_coverage` read as dead this way."""
    g = _graph(
        tmp_path,
        "tools.py",
        """
        from pipeline._mcp_app import mcp


        @mcp.tool()
        def retrieval_coverage(settings=None):
            return "{}"
        """,
    )
    edges = _edges(g)
    assert ("ast_file:tools-py", "ast_func:python:retrieval_coverage", "registers") in edges


def test_a_non_registration_decorator_does_not_register(tmp_path):
    """Detects: every decorator counting as registration, which would hide real dead code."""
    g = _graph(
        tmp_path,
        "m.py",
        """
        import functools


        @functools.cache
        def memoised():
            return 1
        """,
    )
    edges = _edges(g)
    assert not any(label == "registers" for _, _, label in edges)
