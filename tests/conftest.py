"""Pytest configuration: serialize BATS suite execution and enforce timeouts.

BATS suites run shellcheck on all ~24 scripts and source the full tactical
profile.  Running multiple suites in parallel saturates CPU/disk and causes
hangs when the thread-based timeout cannot interrupt blocked I/O.
"""
from __future__ import annotations

import fcntl
import os
import shutil
import tempfile
import time
from collections.abc import Generator
from pathlib import Path

import pytest

_LOCK_DIR = Path(tempfile.gettempdir()) / "tac-pytest-bats-locks"
# Cap lock wait to 120s — if a lock can't be acquired in 2 minutes the
# holder is stale or hung, regardless of the suite's configured timeout.
_MAX_LOCK_WAIT = 120


def _lock_pid_path(lock_path: Path) -> Path:
    """Return the companion pid file for a BATS lock."""
    return lock_path.with_suffix(lock_path.suffix + ".pid")


def has_conftest_is_stale_lock(lock_path: Path, pid_path: Path) -> bool:
    """Public alias for _is_stale_lock (exported for test_bats_lock_fixture.py)."""
    return _is_stale_lock(lock_path, pid_path)


def _is_stale_lock(lock_path: Path, pid_path: Path) -> bool:
    """Return True when a lock owner PID is gone or invalid."""
    if not pid_path.exists():
        return False
    try:
        pid = int(pid_path.read_text(encoding="utf-8").strip())
    except (OSError, ValueError):
        return True
    if pid <= 0:
        return True
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return True
    except PermissionError:
        return False
    except OSError:
        return False
    return False


def _cleanup_stale_locks() -> None:
    """Remove lock files whose owning process is no longer alive."""
    if not _LOCK_DIR.is_dir():
        return
    for f in _LOCK_DIR.iterdir():
        if f.suffix == ".pid":
            lock_path = f.with_suffix("")
            if _is_stale_lock(lock_path, f):
                lock_path.unlink(missing_ok=True)
                f.unlink(missing_ok=True)


_cleanup_stale_locks()


def _is_vscode_discovery() -> bool:
    """Return True when pytest is running discovery (VS Code --collect-only)."""
    return "--collect-only" in __import__("sys").argv


@pytest.fixture(scope="session", autouse=True)
def _protect_registry_file() -> Generator[None, None, None]:
    """Snapshot-restore ~/.llm/models.conf around the test session.

    Skips during VS Code test discovery (--collect-only) to avoid
    unnecessary I/O on every refresh.
    """
    if _is_vscode_discovery():
        yield
        return

    registry_path = Path.home() / ".llm" / "models.conf"
    snapshot_path = Path(tempfile.mktemp(suffix=".models.conf.bak"))
    if registry_path.exists():
        shutil.copy2(registry_path, snapshot_path)
    yield
    if snapshot_path.exists():
        shutil.copy2(snapshot_path, registry_path)
        snapshot_path.unlink(missing_ok=True)


@pytest.fixture(autouse=True)
def _serialize_bats_suites(request: pytest.FixtureRequest):
    """Acquire a per-BATS-file lock so BATS suites never run concurrently.

    Only gates suites that carry a ``bats`` marker — pure-Python tests are
    not serialised.

    The lock name is derived from the **BATS file's stem** (not the test file's
    stem), so different BATS files (unit, integration, tactical-console) can
    run concurrently without blocking each other.
    """
    # Skip entirely during VS Code test discovery
    if _is_vscode_discovery():
        yield
        return

    is_bats = any(
        marker.name.startswith("bats") for marker in request.node.iter_markers()
    )
    if not is_bats:
        yield
        return

    _LOCK_DIR.mkdir(mode=0o700, exist_ok=True)

    # Read _bats_file / _bats_timeout from the test function's own attributes
    # (set by test_bats_bridge.py's _make_test).  Falls back to the old
    # callspec.params path for any remaining parametrized BATS tests.
    fn = request.node.function
    bats_file: Path | None = getattr(fn, "_bats_file", None)
    timeout_s: int = getattr(fn, "_bats_timeout", 60)
    if bats_file is None and hasattr(request.node, "callspec"):
        bats_file = request.node.callspec.params.get("bats_file")
        timeout_s = int(request.node.callspec.params.get("timeout_s", 60))

    lock_name = Path(bats_file).stem if bats_file else Path(request.path).stem
    lock_path = _LOCK_DIR / f"{lock_name}.lock"
    pid_path = _lock_pid_path(lock_path)

    with open(lock_path, "w", encoding="utf-8") as lf:
        pid_path.write_text(str(os.getpid()), encoding="utf-8")
        wait_s = min(_MAX_LOCK_WAIT, max(60, timeout_s))
        deadline = time.monotonic() + wait_s
        while True:
            try:
                fcntl.flock(lf.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if _is_stale_lock(lock_path, pid_path):
                    lock_path.unlink(missing_ok=True)
                    pid_path.unlink(missing_ok=True)
                    pid_path.write_text(str(os.getpid()), encoding="utf-8")
                    continue
                if time.monotonic() > deadline:
                    pytest.fail(
                        f"Could not acquire BATS serialisation lock within "
                        f"{wait_s}s — another BATS suite may be hung. "
                        f"Check for stale processes holding {lock_path}"
                    )
                time.sleep(1)
        try:
            yield
        finally:
            fcntl.flock(lf.fileno(), fcntl.LOCK_UN)
            pid_path.unlink(missing_ok=True)


# ═══════════════════════════════════════════════════════════════════════
# Duration tracking + regression detection
# ═══════════════════════════════════════════════════════════════════════
# Stores per-test durations in .pytest_cache/tac-durations.json and
# warns when a test is >2x slower than its historical baseline.

_DURATIONS_FILE = Path(".pytest_cache/tac-durations.json")
_DURATIONS: dict[str, list[float]] = {}
_REGRESSION_THRESHOLD = 2.0  # warn if duration exceeds baseline × this


def _load_durations() -> dict[str, list[float]]:
    """Load historical duration baselines from cache."""
    path = Path(__file__).resolve().parent.parent / _DURATIONS_FILE
    if not path.exists():
        return {}
    try:
        import json
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}


def _save_durations(durations: dict[str, list[float]]) -> None:
    """Persist duration baselines to cache."""
    import json
    path = Path(__file__).resolve().parent.parent / _DURATIONS_FILE
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(durations, indent=2), encoding="utf-8")


def _collect_duration(item: pytest.Item, duration_s: float) -> None:
    """Record a test duration and flag regressions."""
    key = f"{item.nodeid.split('::')[0]}::{item.originalname or item.name}"
    _DURATIONS.setdefault(key, []).append(duration_s)


def _check_regression(item: pytest.Item, duration_s: float) -> str | None:
    """Return a warning string if *duration_s* is a significant regression."""
    baselines = _load_durations()
    key = f"{item.nodeid.split('::')[0]}::{item.originalname or item.name}"
    history = baselines.get(key)
    if not history or len(history) < 2:
        return None
    # Use median of historical runs as the stable baseline
    sorted_hist = sorted(history)
    median = sorted_hist[len(sorted_hist) // 2]
    ratio = duration_s / median if median > 0 else 0
    if ratio > _REGRESSION_THRESHOLD:
        return (
            f"\033[33m⚠ {key} took {duration_s:.1f}s "
            f"({ratio:.1f}× historical median {median:.1f}s)\033[0m"
        )
    return None


@pytest.hookimpl(hookwrapper=True)
def pytest_runtest_protocol(item: pytest.Item) -> object | None:
    """Wrap each test to capture its wall-clock duration."""
    import time as _time
    start = _time.monotonic()
    yield
    elapsed = _time.monotonic() - start
    if not _is_vscode_discovery():
        _collect_duration(item, elapsed)
        warning = _check_regression(item, elapsed)
        if warning:
            import sys as _sys
            print(warning, file=_sys.stderr)


def pytest_sessionfinish(session: pytest.Session) -> None:
    """Persist accumulated durations at the end of a successful run."""
    if not _is_vscode_discovery() and _DURATIONS:
        baselines = _load_durations()
        for key, times in _DURATIONS.items():
            baselines.setdefault(key, []).extend(times)
            # Keep only the last 20 runs to avoid unbounded growth
            baselines[key] = baselines[key][-20:]
        _save_durations(baselines)
