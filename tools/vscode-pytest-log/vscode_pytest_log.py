"""Record every VS Code Testing (pytest) run to a JSON results file.

Loaded by the patched extension wrapper
(``~/.vscode-server/extensions/ms-python.python-*/python_files/vscode_pytest/run_pytest_script.py``,
wired in by ``~/.local/bin/vscode-pytest-log-patch.py``), so it applies to EVERY repo and
window, not one workspace's settings.

Why it exists (2026-09-30): a Testing run's results live only in the panel's memory — the
extension writes no results file and the extension-host log carries no TAP — so a run in
progress cannot be observed and a finished run's failures cannot be read from outside VS
Code.  This writes:

    ~/.cache/vscode-pytest/<repo>-<hash8>/latest.json      # rewritten at start and at end
    ~/.cache/vscode-pytest/<repo>-<hash8>/<utc-stamp>.json # one file per run

The first is written at ``pytest_configure`` with ``status: running``, so "is a run going,
and where is it?" is answerable while it runs; the second carries the outcomes and the
failure messages.

Environment knobs (both optional, named rather than defaulted silently):
    VSCODE_PYTEST_LOG_DIR    where to write          (default ~/.cache/vscode-pytest)
    VSCODE_PYTEST_LOG_KEEP   runs kept per repo      (default 50; 0 disables pruning)
"""

from __future__ import annotations

import hashlib
import json
import os
import pathlib
import re
import sys
import time
from datetime import datetime, timezone

SCHEMA = "vscode-pytest-log/1"

#: One file per run, plus latest.json, per (repo, hash) directory.
BASE = pathlib.Path(
    os.environ.get("VSCODE_PYTEST_LOG_DIR", "~/.cache/vscode-pytest")
).expanduser()
KEEP = int(os.environ.get("VSCODE_PYTEST_LOG_KEEP", "50"))
#: A failure message is for a human to act on, not a full traceback archive.
MESSAGE_LIMIT = 4000

_state: dict[str, object] = {}


def _now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")


def _slug(text: str) -> str:
    return re.sub(r"[^A-Za-z0-9._-]+", "-", text).strip("-") or "repo"


def _run_dir(cwd: str) -> pathlib.Path:
    """The per-repo directory, keyed by path so two repos with one name stay apart."""
    digest = hashlib.sha256(cwd.encode()).hexdigest()[:8]
    return BASE / f"{_slug(pathlib.Path(cwd).name)}-{digest}"


def _write(path: pathlib.Path, payload: dict) -> None:
    """Write payload atomically, and never raise into the test session.

    Every failure here is REPORTED and swallowed on purpose: losing a log line must never
    fail a test run.  The printed message is the signal, plus the LOAD/WRITE-ERROR file
    below, so a broken logger cannot look like a working one.
    """
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp = path.with_suffix(".tmp")
        tmp.write_text(json.dumps(payload, indent=2, sort_keys=False), encoding="utf-8")
        tmp.replace(path)
    except Exception as exc:
        _report_failure(f"cannot write {path}: {exc!r}")


def _report_failure(what: str) -> None:
    """Say it loudly on the run's output, and leave a file a later reader can find."""
    print(f"Error[vscode-pytest-log]: {what}")
    try:
        BASE.mkdir(parents=True, exist_ok=True)
        with (BASE / "ERRORS.txt").open("a", encoding="utf-8") as handle:
            handle.write(f"{_now()} {what}\n")
    except Exception as inner:
        print(f"Error[vscode-pytest-log]: cannot even record that: {inner!r}")


def _prune(run_dir: pathlib.Path) -> None:
    if KEEP <= 0:
        return
    try:
        runs = sorted(
            (p for p in run_dir.glob("*.json") if p.name != "latest.json"),
            key=lambda p: p.stat().st_mtime,
            reverse=True,
        )
        for stale in runs[KEEP:]:
            stale.unlink()
    except Exception as exc:
        _report_failure(f"cannot prune {run_dir}: {exc!r}")


def pytest_configure(config) -> None:
    """Record the run's start, and publish it as latest.json immediately."""
    cwd = os.getcwd()
    run_dir = _run_dir(cwd)
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    _state.update(
        {
            "run_dir": run_dir,
            "run_file": run_dir / f"{stamp}.json",
            "cwd": cwd,
            "argv": list(getattr(config, "args", []) or []),
            "started_at": _now(),
            "started_monotonic": time.monotonic(),
            "tests": {},
            "failures": [],
        }
    )
    try:
        import pytest as _pytest

        pytest_version = _pytest.__version__
    except Exception:  # noqa: BLE001 - cosmetic field only
        pytest_version = ""
    payload = {
        "schema": SCHEMA,
        "status": "running",
        "repo": cwd,
        "rootdir": str(getattr(config, "rootpath", "") or getattr(config, "rootdir", "")),
        "argv": _state["argv"],
        "started_at": _state["started_at"],
        "finished_at": None,
        "exit_status": None,
        "counts": {},
        "failures": [],
        "tests": [],
        "pytest": pytest_version,
        "python": sys.version.split()[0],
    }
    _state["start_payload"] = payload
    _write(run_dir / "latest.json", payload)
    _write(_state["run_file"], payload)


def pytest_runtest_logreport(report) -> None:
    """Collect one outcome per test (its worst phase), plus the failure message."""
    tests: dict = _state.setdefault("tests", {})
    entry = tests.get(report.nodeid)
    if entry is None:
        entry = {"nodeid": report.nodeid, "outcome": report.outcome, "duration_s": 0.0}
        tests[report.nodeid] = entry
    entry["duration_s"] = round(entry["duration_s"] + float(report.duration or 0.0), 3)
    rank = {"passed": 0, "skipped": 1, "failed": 2}
    if rank.get(report.outcome, 2) > rank.get(entry["outcome"], 0):
        entry["outcome"] = report.outcome
    if report.outcome == "failed" and report.when in ("setup", "call"):
        longrepr = str(getattr(report, "longrepr", "") or "")[:MESSAGE_LIMIT]
        _state.setdefault("failures", []).append(
            {"nodeid": report.nodeid, "phase": report.when, "message": longrepr}
        )


def pytest_sessionfinish(session, exitstatus) -> None:
    """Publish the finished run: counts, failures, and the per-test outcomes."""
    run_file = _state.get("run_file")
    if run_file is None:
        return
    tests = sorted(_state.get("tests", {}).values(), key=lambda t: t["nodeid"])
    counts: dict[str, int] = {}
    for test in tests:
        counts[test["outcome"]] = counts.get(test["outcome"], 0) + 1
    counts["total"] = len(tests)
    payload = dict(_state.get("start_payload") or {})
    payload.update(
        {
            "status": "done",
            "finished_at": _now(),
            "duration_s": round(time.monotonic() - float(_state["started_monotonic"]), 3),
            "exit_status": int(exitstatus),
            "counts": counts,
            "failures": _state.get("failures", []),
            "tests": tests,
        }
    )
    _write(run_file, payload)
    _write(pathlib.Path(run_file).parent / "latest.json", payload)
    _prune(pathlib.Path(run_file).parent)
    failed = counts.get("failed", 0)
    print(
        f"[vscode-pytest-log] {counts.get('total', 0)} test(s), {failed} failed, "
        f"exit {int(exitstatus)} -> {run_file}"
    )
