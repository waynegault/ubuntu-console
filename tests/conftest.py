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


def _lock_pid_path(lock_path: Path) -> Path:
    """Return the companion pid file for a BATS lock."""
    return lock_path.with_suffix(lock_path.suffix + ".pid")


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


@pytest.fixture(scope="session", autouse=True)
def _protect_registry_file() -> Generator[None, None, None]:
    """Snapshot-restore ~/.llm/models.conf around the test session.

    Tests must never mutate the real registry file.  This fixture snapshots
    the file before the session and restores it after, so any test that
    accidentally writes to ~/.llm/models.conf is automatically rolled back.
    """
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
    is_bats = any(
        marker.name.startswith("bats") for marker in request.node.iter_markers()
    )
    if not is_bats:
        yield
        return

    _LOCK_DIR.mkdir(mode=0o700, exist_ok=True)

    # Derive lock name from the actual BATS file being run, not the test file.
    bats_file: Path | None = None
    timeout_s = 60
    if hasattr(request.node, "callspec"):
        if "bats_file" in request.node.callspec.params:
            bats_file = request.node.callspec.params["bats_file"]
        if "timeout_s" in request.node.callspec.params:
            timeout_s = int(request.node.callspec.params["timeout_s"])

    lock_name = Path(bats_file).stem if bats_file else Path(request.path).stem
    lock_path = _LOCK_DIR / f"{lock_name}.lock"
    pid_path = _lock_pid_path(lock_path)

    with open(lock_path, "w", encoding="utf-8") as lf:
        pid_path.write_text(str(os.getpid()), encoding="utf-8")
        wait_s = max(60, timeout_s + 60)
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
