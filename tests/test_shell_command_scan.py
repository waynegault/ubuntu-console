"""Tests for the shell-command-scan PostToolUse hook (card 07a1516a).

``tools/qwen-hooks/shell-command-scan.py`` runs on every ``run_shell_command`` on
this box (``install.sh`` links ``tools/qwen-hooks/*`` into ``~/.qwen/hooks/``) and
classifies the COMMAND TEXT, so a broken classifier fails silently and invisibly —
the worst place for an unwatched heuristic.  This module drives the classifier's
own ``main()`` with a table of command strings and asserts the published contract:
a documented hazard is named, a clean command prints NOTHING, and the hook is
advisory (exit status always 0).

The module is a hyphenated script, so it is loaded by path rather than imported by
name.  ``main()`` reads JSON from stdin and prints to stdout; both are supplied
per case, and the module-local ``sys`` reference is patched rather than the global
``sys`` module so no other code in the process is affected.
"""

from __future__ import annotations

import importlib.util
import io
import json
import sys
import types
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent


def _load_scan() -> types.ModuleType:
    """Import tools/qwen-hooks/shell-command-scan.py by path (not a module name)."""
    spec = importlib.util.spec_from_file_location(
        "shell_command_scan", REPO_ROOT / "tools" / "qwen-hooks" / "shell-command-scan.py"
    )
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    try:
        spec.loader.exec_module(module)
    except BaseException:
        del sys.modules[spec.name]
        raise
    return module


scan = _load_scan()


def _run(
    command: str, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> tuple[int, str]:
    """Run the hook's main() over a shell command; return (exit status, stdout)."""
    payload = json.dumps({"tool_input": {"command": command}})
    # Module-local patch ONLY (Wayne's rule): main() reads the module's own `sys`
    # global, so patching that leaves the real sys module — and every other
    # consumer's stdin — untouched.
    monkeypatch.setattr(scan, "sys", types.SimpleNamespace(stdin=io.StringIO(payload)))
    status = scan.main()
    return status, capsys.readouterr().out


# ── the documented hazards the classifier must name ────────────────────────
# (command, the substring the finding MUST carry).  Every row is a shape the
# module docstring documents; a classifier that misses one lets the hazard
# through, which is exactly the failure that hung markdownlint for 120 s.
_FLAGGED: list[tuple[str, str]] = [
    ('markdownlint "$note"', "markdownlint"),   # empty-variable operand
    ("jq", "jq"),                               # a linter with no target at all
    ('jq "$file"', "jq"),                       # operand that is ONLY a variable
    ("sudo jq", "jq"),                          # wrapper stripped before the tool
    ("FOO=bar jq", "jq"),                       # leading env assignment
    ("echo hi; jq", "jq"),                      # a second simple command
    ("python3", "python3"),                     # a bare REPL
    ("node", "node"),                           # a bare REPL
]


@pytest.mark.parametrize(("command", "needle"), _FLAGGED, ids=[c for c, _ in _FLAGGED])
def test_flagged_commands_are_named(
    command: str, needle: str, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    """A documented hazard the classifier does not flag is an unguarded hang.

    Catches: a classifier that returns no finding (empty output) for a stdin-reading
    tool with no operand — the exact miss that let `markdownlint "$note"` block for
    the full 120 s tool timeout.
    """
    status, out = _run(command, monkeypatch, capsys)
    assert status == 0, "the hook is advisory and must always exit 0"
    assert needle in out, f"expected a finding naming {needle!r} for {command!r}, got {out!r}"


# ── commands that supply an operand / stdin must print NOTHING ─────────────
_CLEAN: list[str] = [
    "jq . file.json",                 # a real file operand
    "markdownlint README.md",         # a real target
    "python3 -c 'print(1)'",          # -c supplies the program
    "python3 -m pytest tests/",       # -m supplies the module
    "python3 -",                      # program on stdin, by design
    "node -e 'console.log(1)'",       # -e supplies the program
    "python3 script.py",              # a file operand
    "jq --version",                   # info flag: prints and exits
    "cat data.json | jq .",           # piped in: stdin is provided
    "markdownlint <<EOF\n# t\nEOF",   # heredoc supplies stdin
    "echo hi",                        # an unrelated command
]


@pytest.mark.parametrize("command", _CLEAN, ids=lambda c: c.replace("\n", "\\n"))
def test_clean_commands_print_nothing(
    command: str, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    """The hook's contract is silence when clean (same as post-edit-check.sh).

    Catches: a classifier that flags an operand-bearing or piped invocation, which
    would train the reader to ignore the hook — and, at the other end, one that
    emits a reassuring line on every clean command instead of nothing.
    """
    status, out = _run(command, monkeypatch, capsys)
    assert status == 0
    assert out == "", f"expected NO output for clean command {command!r}, got {out!r}"


# ── the masked-exit-status class ───────────────────────────────────────────

_MASKED: list[str] = [
    "git commit -m 'x' | tail -5",
    "git push origin main | tail -5",
    "./scripts/git_commit.sh -m x | tail",
]


@pytest.mark.parametrize("command", _MASKED, ids=lambda c: c.replace(" ", "_"))
def test_stateful_git_piped_status_is_flagged(
    command: str, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    """A piped stateful git command reports the pipe's status, not the commit's.

    Catches: the measured 2026-09-29 miss where `git_commit.sh … | tail` read as
    "exit 0" while the wrapper had returned 1, hiding a mypy failure behind two
    nine-minute hook chains.
    """
    status, out = _run(command, monkeypatch, capsys)
    assert status == 0
    assert "EXIT STATUS is masked" in out, f"expected a masked-status finding, got {out!r}"


def test_masked_status_is_not_flagged_for_a_redirect(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    """A redirect is NOT masking — the status still reaches the caller.

    Catches: a classifier that fires on any git commit with a redirection, which
    would be the false-positive class the module docstring warns against.
    """
    status, out = _run("git commit -m 'x' > /tmp/log 2>&1", monkeypatch, capsys)
    assert status == 0
    assert out == "", f"a redirect does not mask the status; got {out!r}"


# ── input robustness ───────────────────────────────────────────────────────

@pytest.mark.parametrize("raw", ["", "not json", "{}", '{"tool_input": {}}'])
def test_unusable_input_is_silent(
    raw: str, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    """Malformed or command-less payloads must not print or raise.

    Catches: a hook that crashes (non-zero exit blocks the tool round) or prints a
    spurious finding when there is no command to judge.
    """
    monkeypatch.setattr(scan, "sys", types.SimpleNamespace(stdin=io.StringIO(raw)))
    assert scan.main() == 0
    assert capsys.readouterr().out == ""
