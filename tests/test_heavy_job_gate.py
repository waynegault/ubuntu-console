"""The pytest runner QUEUES behind the box's heavy-job lock instead of starving.

Criteria this suite is written against, both external to this module:

* ``bin/heavy-job``'s own header: at most ONE saturating job runs at a time, and it
  names pytest among them.  Its ``--timeout`` contract is "give up rather than queue
  forever (exit 3)".
* Wayne's ruling of 2026-11-04: a test-panel (VS Code) run must WAIT behind an
  autotune instead of competing with it.  Measured the same day: load average 181,
  every bridged suite 8-15x slower, suites reported failed that pass in isolation.

Each case names the concrete wrong outcome it detects.  The lock is the real one —
these spawn ``bin/heavy-job`` and read its ``--status`` — so an implementation that
locked a private path, or leaked the lock after the session, fails here.
"""

from __future__ import annotations

import os
import subprocess
import time
from collections.abc import Callable, Iterator
from contextlib import contextmanager
from pathlib import Path
from types import SimpleNamespace
from typing import Any

import pytest

import conftest
from _test_harness import pytest_interpreter

REPO_ROOT = Path(__file__).resolve().parents[1]
HEAVY_JOB = REPO_ROOT / "bin" / "heavy-job"


class _StubConfig:
    """Stand-in for pytest.Config: only add_cleanup() is used by the gate."""

    def __init__(self) -> None:
        self.cleanups: list[Callable[[], None]] = []

    def add_cleanup(self, func: Callable[[], None]) -> None:
        self.cleanups.append(func)


class _StubItem:
    """Stand-in for a collected item: only iter_markers() is used by the gate."""

    def __init__(self, *markers: str) -> None:
        self._markers = markers

    def iter_markers(self) -> list[Any]:
        return [SimpleNamespace(name=name) for name in self._markers]


def _heavy_env(lock_path: Path) -> dict[str, str]:
    """Environment for the real binary: our temp lock, and NOT inside a session."""
    env = {**os.environ, "HEAVY_JOB_LOCK": str(lock_path)}
    env.pop("HEAVY_JOB_HELD", None)
    return env


def _status(lock_path: Path) -> str:
    result = subprocess.run(
        [str(HEAVY_JOB), "--status"],
        env=_heavy_env(lock_path),
        capture_output=True,
        text=True,
        timeout=30,
        check=False,
    )
    return result.stdout.strip()


@contextmanager
def _held_by_heavy_job(lock_path: Path) -> Iterator[None]:
    """Hold the lock with the real binary until ``--status`` demonstrably says BUSY."""
    env = _heavy_env(lock_path)
    proc = subprocess.Popen(
        [str(HEAVY_JOB), "sleep", "30"],
        env=env,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    try:
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            if "BUSY" in _status(lock_path):
                break
            time.sleep(0.05)
        else:
            raise AssertionError(
                f"bin/heavy-job never reported {lock_path} as BUSY — the premise of this case could not be established"
            )
        yield
    finally:
        proc.terminate()
        proc.wait(timeout=20)


@pytest.fixture(autouse=True)
def _isolate_gate(monkeypatch: pytest.MonkeyPatch) -> None:
    """Reset the module's session state and the variables the gate reads."""
    monkeypatch.setattr(conftest, "_HEAVY_JOB_FD", None)
    monkeypatch.delenv("HEAVY_JOB_HELD", raising=False)
    monkeypatch.delenv("TAC_HEAVY_JOB_WAIT_S", raising=False)


def test_a_saturating_session_queues_instead_of_starting_beside_a_heavy_job(
    tmp_path: Path,
) -> None:
    """Catches a run that starts beside an autotune: it must wait, and say who holds the box.

    Wrong outcome detected: acquire_heavy_job_lock() returns a descriptor while
    bin/heavy-job holds the same file — which is what the pre-fix runner did.
    """
    lock_path = tmp_path / "heavy-job.lock"
    with _held_by_heavy_job(lock_path):
        with pytest.raises(conftest.HeavyJobBusy) as excinfo:
            conftest.acquire_heavy_job_lock(lock_path, wait_s=1, owner="test")

    message = str(excinfo.value)
    assert "still held after 1s" in message
    # The holder is read from bin/heavy-job's own advisory record, so this also proves
    # we contend on ITS file and not on a look-alike.
    assert "pid=" in message


def test_the_gate_takes_the_lock_heavy_job_reports_and_releases_it(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Catches taking a lock nobody honours, and leaking it past the session.

    Wrong outcome detected: `bin/heavy-job --status` reads free while a gated pytest
    session runs (so a heavy job would start beside it), or still BUSY after the
    session's cleanup ran (so the next heavy job never gets the box).
    """
    lock_path = tmp_path / "heavy-job.lock"
    monkeypatch.setenv("HEAVY_JOB_LOCK", str(lock_path))

    config = _StubConfig()
    conftest.ensure_heavy_job_session(config, [_StubItem("bats_unit")])

    busy = _status(lock_path)
    assert "BUSY" in busy, f"the session should hold the box, but --status said: {busy}"
    assert "cmd=pytest" in busy, f"the holder should be named as pytest, got: {busy}"

    assert config.cleanups, "the session must register a cleanup to release the lock"
    for cleanup in config.cleanups:
        cleanup()

    assert _status(lock_path).startswith("heavy-job: free")


def test_inside_a_heavy_session_the_gate_does_not_queue(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    """Catches the deadlock: a nested run must pass through, never re-take the lock.

    Wrong outcome detected: tools/run-tests.sh (which holds the lock and exports
    HEAVY_JOB_HELD) starting pytest that blocks on the lock its own parent holds —
    the whole flow then hangs until a timeout kills it.
    """
    lock_path = tmp_path / "heavy-job.lock"
    monkeypatch.setenv("HEAVY_JOB_LOCK", str(lock_path))
    monkeypatch.setenv("HEAVY_JOB_HELD", "1")
    monkeypatch.setenv("TAC_HEAVY_JOB_WAIT_S", "1")

    config = _StubConfig()
    with _held_by_heavy_job(lock_path):
        conftest.ensure_heavy_job_session(config, [_StubItem("bats_unit")])

    assert conftest._HEAVY_JOB_FD is None, "a nested session must not take the lock"
    assert config.cleanups == [], "a pass-through registers nothing to release"


def test_a_python_only_selection_does_not_queue(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    """Catches making every pure-Python run wait behind an autotune.

    Wrong outcome detected: a one-test Python run (no BATS marker) blocking for the
    full wait budget while the box is busy — pure-Python tests are not saturating.
    """
    lock_path = tmp_path / "heavy-job.lock"
    monkeypatch.setenv("HEAVY_JOB_LOCK", str(lock_path))
    monkeypatch.setenv("TAC_HEAVY_JOB_WAIT_S", "1")

    config = _StubConfig()
    with _held_by_heavy_job(lock_path):
        conftest.ensure_heavy_job_session(config, [_StubItem()])

    assert conftest._HEAVY_JOB_FD is None
    assert config.cleanups == []


def test_a_queued_run_says_so_instead_of_costing_silence(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    """Catches the measured 2026-11-04 shape: a panel run that queues INVISIBLY.

    A panel run queued behind tools/run-tests.sh and executed no test for six minutes
    with nothing in its output; the run read as hung, and the operator's report was
    "so many tests are not running".  Wrong outcome detected: the wait begins and
    nothing names the holder, or the wait is not bounded.
    """
    lock_path = tmp_path / "heavy-job.lock"
    monkeypatch.setenv("HEAVY_JOB_LOCK", str(lock_path))
    monkeypatch.setenv("TAC_HEAVY_JOB_WAIT_S", "1")
    monkeypatch.setenv("TEST_RUN_PIPE", "/run/user/1000/python-test-results-test")

    config = _StubConfig()
    with _held_by_heavy_job(lock_path):
        with pytest.raises(Exception) as excinfo:
            conftest.ensure_heavy_job_session(config, [_StubItem("bats_unit")])

    err = capsys.readouterr().err
    assert "VS Code panel queued behind" in err, err
    assert "pid=" in err, f"the holder must be NAMED, got: {err!r}"
    # Bounded: the failure names the budget rather than hanging out the hour.
    assert "still held after 1s" in str(excinfo.value)


def test_the_queue_bound_is_an_hour_for_every_runner(monkeypatch: pytest.MonkeyPatch) -> None:
    """Wayne's 2026-11-04 ruling: the panel WAITS, it does not get a shorter leash.

    Catches: a later "make it fail fast" edit that quietly gives the interactive runner a
    smaller default, so a panel run refuses while a suite is still working.
    """
    monkeypatch.delenv("TAC_HEAVY_JOB_WAIT_S", raising=False)
    monkeypatch.delenv("TEST_RUN_PIPE", raising=False)
    monkeypatch.delenv("RUN_TEST_IDS_PIPE", raising=False)
    assert conftest.heavy_job_wait_s() == 3600
    monkeypatch.setenv("TEST_RUN_PIPE", "/run/user/1000/python-test-results-test")
    assert conftest.heavy_job_wait_s() == 3600
    monkeypatch.setenv("TAC_HEAVY_JOB_WAIT_S", "7")
    assert conftest.heavy_job_wait_s() == 7


def test_a_dash_k_python_selection_does_not_queue_behind_a_held_lock(tmp_path: Path) -> None:
    """Catches the measured 2026-11-04 queue: a one-test Python selection waiting an hour.

    Importing tests/test_bats_bridge.py registers one item per BATS case (~1000) in its
    module globals, and the gate used to run in pytest_collection_modifyitems — BEFORE
    -k removes any — so `pytest tests -k one_python_test` saw a BATS-carrying collection
    and queued behind whatever held the heavy-job lock.  That is what made a panel run
    execute no test at all.

    This runs the real conftest in a subprocess against a lock the real bin/heavy-job
    holds, with a 2 s wait budget: a gate that still fired would exit 3, and the selected
    test would never run.  Wrong outcome detected: rc != 0, or the case not reported.
    """
    lock_path = tmp_path / "heavy-job.lock"
    env = _heavy_env(lock_path)
    env["TAC_HEAVY_JOB_WAIT_S"] = "2"
    env.pop("TEST_RUN_PIPE", None)
    # The interpreter that RUNS this suite, not a hardcoded .venv: a CI runner has no
    # repo venv, and its tool python carries a pytest install missing pluggy (measured
    # 2026-11-11: FileNotFoundError here, ModuleNotFoundError in the sibling case).
    with _held_by_heavy_job(lock_path):
        proc = subprocess.run(
            [
                pytest_interpreter(),
                "-m",
                "pytest",
                "tests",
                "-k",
                "test_the_queue_bound_is_an_hour_for_every_runner",
                "-q",
                "--no-header",
                "-p",
                "no:cacheprovider",
            ],
            cwd=REPO_ROOT,
            env=env,
            capture_output=True,
            text=True,
            timeout=300,
            check=False,
        )
    combined = proc.stdout + proc.stderr
    assert proc.returncode == 0, f"the selection queued or failed (rc={proc.returncode}):\n{combined}"
    assert "1 passed" in combined, combined
