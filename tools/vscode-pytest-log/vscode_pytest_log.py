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

WHY A RUN PRODUCED NOTHING is recorded too (2026-10-10): ``exit_status`` 4 with
``counts.total`` 0 is what a run leaves behind when pytest cannot collect the selection at
all — the Testing panel passes every selected node id explicitly, so ONE id that no longer
exists (a renamed test) is a usage error that runs nothing.  Two extra fields carry the
reason, each only when it applies:

    "usage_error":      pytest's own text for a selection it could not collect
    "collection_errors": [{"nodeid": ..., "message": ...}] for files that failed to import

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
from typing import TypedDict

# pytest is imported at module scope for the hook wrappers below (``@pytest.hookimpl`` and
# ``pytest.UsageError`` are needed when this module is REGISTERED, not when a hook runs) - this is a
# pytest plugin, loaded by the patched extension wrapper inside a pytest process.
import pytest

SCHEMA = "vscode-pytest-log/1"

#: One file per run, plus latest.json, per (repo, hash) directory.
BASE = pathlib.Path(
    os.environ.get("VSCODE_PYTEST_LOG_DIR", "~/.cache/vscode-pytest")
).expanduser()
KEEP = int(os.environ.get("VSCODE_PYTEST_LOG_KEEP", "50"))
#: A failure message is for a human to act on, not a full traceback archive.
MESSAGE_LIMIT = 4000


class _State(TypedDict, total=False):
    """The run's mutable state, one entry per field the hooks share.

    A TypedDict rather than a bare ``dict[str, object]``: with the loose annotation every
    read out of this mapping was typed ``object``, so none of the sites that USE a value —
    a path handed to ``_write``, a float, the tests table — could be checked at all, and
    one declaration produced nine separate errors.  ``total=False`` because the entries
    appear as the run progresses: ``pytest_configure`` fills them, the logreport hook
    appends, ``pytest_sessionfinish`` reads them back.
    """

    run_dir: pathlib.Path
    run_file: pathlib.Path
    cwd: str
    argv: list[str]
    started_at: str
    started_monotonic: float
    tests: dict[str, dict]
    failures: list[dict]
    collection_errors: list[dict]
    start_payload: dict


_state: _State = {}


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
    _state["run_dir"] = run_dir
    _state["run_file"] = run_dir / f"{stamp}.json"
    _state["cwd"] = cwd
    _state["argv"] = list(getattr(config, "args", []) or [])
    _state["started_at"] = _now()
    _state["started_monotonic"] = time.monotonic()
    _state["tests"] = {}
    _state["failures"] = []

    try:
        import pytest as _pytest

        pytest_version = _pytest.__version__
    except (ImportError, AttributeError) as exc:
        # A cosmetic field, so this must not fail the run — but a silently swallowed
        # failure is indistinguishable from a working recorder, so say it.  The exception
        # is narrowed rather than blind: those two are the real ways to get here (pytest
        # absent, or a build without __version__), and anything else should surface.
        print(f"Warning[vscode-pytest-log]: cannot read pytest's version: {exc!r}")
        pytest_version = ""

    # Annotated because three of the values are EMPTY containers (`counts`, `failures`,
    # `tests`) whose element type the literal itself cannot state, so mypy refused to infer
    # one.  `object` is the accurate element type for a JSON document, not a loosening:
    # every value here is a JSON scalar, container or null.
    payload: dict[str, object] = {
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


def pytest_collectreport(report) -> None:
    """Record a COLLECTION failure, so a run that collected nothing can say why.

    Only failures are kept — a report arrives per collected file, passing ones included, and
    logging those would swamp the payload to say nothing.  Measured 2026-10-10 against a
    deliberate syntax error: ``report.failed`` is True and ``str(report.longrepr)`` carries
    pytest's import traceback, which is the text a reader needs and which exists nowhere else
    in the results file.
    """
    if not report.failed:
        return
    _state.setdefault("collection_errors", []).append(
        {"nodeid": report.nodeid, "message": str(report.longrepr)[:MESSAGE_LIMIT]}
    )


@pytest.hookimpl(wrapper=True)
def pytest_cmdline_main(config):
    """Record pytest's own usage error, then re-raise so the exit status is unchanged.

    The case this exists for (measured 2026-10-10): the Testing panel passes every selected
    node id EXPLICITLY, so one id that no longer exists — a renamed test — makes pytest treat
    the whole selection as a usage error: it collects everything, runs NOTHING and exits 4,
    while the results file kept ``exit_status: 4``, ``counts.total: 0`` and no reason at all.
    None of the reporting hooks carry that text (``Session._notfound`` is already empty when
    they run, and ``terminalreporter.stats`` is empty for this whole class), so it is taken
    from the exception here — the only place pytest's own message is visible.  A re-raise
    keeps the run's outcome exactly as pytest decided it; recording never changes a verdict.
    """
    try:
        return (yield)
    except pytest.UsageError as exc:
        _amend_run_with_error("usage_error", str(exc))
        raise


def _amend_run_with_error(field: str, message: str) -> None:
    """Add *field* to this run's already-written payloads (the run file and ``latest.json``).

    It re-READS what ``pytest_sessionfinish`` wrote rather than rebuilding it, so the counts and
    the per-test outcomes it computed stay exactly as they were, and it must run late: the
    measured order on a usage error is ``sessionfinish`` (payload written) -> ``unconfigure`` ->
    ``pytest_cmdline_main``'s wrapper, so amending there is the only point where the reason is
    known.  A failure to amend is reported, never raised: a log that cannot be completed must
    not change what the run did.
    """
    run_file = _state.get("run_file")
    run_dir = _state.get("run_dir")
    if run_file is None or run_dir is None:
        _report_failure(f"cannot record {field}: the run never reached pytest_configure")
        return
    for path in (pathlib.Path(run_file), pathlib.Path(run_dir) / "latest.json"):
        try:
            payload = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            _report_failure(f"cannot read {path} to record {field}: {exc!r}")
            continue
        payload[field] = message[:MESSAGE_LIMIT]
        _write(path, payload)


def pytest_sessionfinish(session, exitstatus) -> None:
    """Publish the finished run: counts, failures, and the per-test outcomes."""
    run_file = _state.get("run_file")
    started_monotonic = _state.get("started_monotonic")
    # Both are written together by pytest_configure, so one guard covers the pair; it is
    # spelled as two lookups rather than a `.get(..., 0.0)` default so a missing start can
    # never be silently reported as a duration measured from the epoch.
    if run_file is None or started_monotonic is None:
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
            "duration_s": round(time.monotonic() - float(started_monotonic), 3),
            "exit_status": int(exitstatus),
            "counts": counts,
            "failures": _state.get("failures", []),
            "tests": tests,
        }
    )
    # Included only when it happened: a run whose collection failed must say so, and a healthy run
    # must not grow a field that would read as "no errors" without anyone checking (the class this
    # whole file exists to close is the failure that leaves no trace).
    collection_errors = _state.get("collection_errors") or []
    if collection_errors:
        payload["collection_errors"] = collection_errors
    _write(run_file, payload)
    _write(pathlib.Path(run_file).parent / "latest.json", payload)
    _prune(pathlib.Path(run_file).parent)
    failed = counts.get("failed", 0)
    print(
        f"[vscode-pytest-log] {counts.get('total', 0)} test(s), {failed} failed, "
        f"exit {int(exitstatus)} -> {run_file}"
    )
