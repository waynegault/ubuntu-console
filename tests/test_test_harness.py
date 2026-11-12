"""Tests for tests/_test_harness.py — the shared helper every subprocess-spawning suite uses.

The helper is load-bearing across four e2e suites and the heavy-job gate, and its
interpreter selector had a failure mode that only appeared on a runner: it raised rather
than answering, and the case it served was reported red for a reason describing the probe
rather than the tree (nightly 43148425686, 2026-11-12).
"""

from __future__ import annotations

import subprocess
import sys
from types import SimpleNamespace

import _test_harness as harness


def _fake_run(can_run: set[str]):
    """A subprocess.run double whose probe succeeds only for the named executables."""

    def run(argv, **_kw):
        return SimpleNamespace(returncode=0 if argv[0] in can_run else 1)

    return run


def test_the_probe_asks_the_capability_not_an_import_list(monkeypatch) -> None:
    """Catches: a probe that reverts to `import pytest, pluggy` and so couples the helper
    to pytest's dependency list.  The question asked is `python -m pytest --version`."""
    seen: list[list[str]] = []

    def run(argv, **_kw):
        seen.append(list(argv))
        return SimpleNamespace(returncode=0)

    monkeypatch.setattr(harness.subprocess, "run", run)
    assert harness.pytest_interpreter() == sys.executable
    assert seen, "the helper must probe at least once"
    assert seen[0][1:] == ["-m", "pytest", "--version"], seen[0]


def test_a_failing_probe_falls_back_to_the_running_interpreter(monkeypatch) -> None:
    """Catches: the RuntimeError that failed a nightly case on a job whose own
    `python -m pytest` had just run 1272 tests.

    Every candidate probe fails here (a masked child environment), and the helper must
    still name the interpreter this suite is executing under — refusing is not the more
    honest answer, and it fails a case for a reason that describes the probe.
    """
    monkeypatch.setattr(harness.subprocess, "run", _fake_run(set()))
    monkeypatch.setattr(harness.shutil, "which", lambda _name: None)
    assert harness.pytest_interpreter() == sys.executable


def test_a_working_candidate_on_PATH_is_preferred_over_the_fallback(monkeypatch) -> None:
    """Catches: a helper that always returns sys.executable, i.e. a probe that proves
    nothing.  When a PATH interpreter really can run pytest it must be the one chosen."""
    monkeypatch.setattr(harness.shutil, "which", lambda name: "/opt/py/bin/python3" if name == "python3" else None)
    monkeypatch.setattr(harness.subprocess, "run", _fake_run({"/opt/py/bin/python3"}))
    assert harness.pytest_interpreter() == "/opt/py/bin/python3"


def test_the_real_probe_runs_for_the_interpreter_running_this_suite() -> None:
    """The un-stubbed control: whatever this suite runs under can run pytest, so the
    helper must return an interpreter that really does answer.  A stub-only suite could
    pass while the shipped probe was broken."""
    chosen = harness.pytest_interpreter()
    result = subprocess.run([chosen, "-m", "pytest", "--version"], capture_output=True, text=True, timeout=60)
    assert result.returncode == 0, result.stderr
