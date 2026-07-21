"""Pytest configuration: serialize BATS suite execution and enforce timeouts.

BATS suites run shellcheck on all ~24 scripts and source the full tactical
profile.  Running multiple suites in parallel saturates CPU/disk and causes
hangs when the thread-based timeout cannot interrupt blocked I/O.
"""
from __future__ import annotations

import fcntl
import shutil
import tempfile
import time
from collections.abc import Generator
from pathlib import Path

import pytest

_LOCK_DIR = Path(tempfile.gettempdir()) / "tac-pytest-bats-locks"


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
    """Acquire a per-suite file lock so BATS suites never run concurrently.

    Only gates suites that carry a ``bats`` marker — pure-Python tests are
    not serialised.
    """
    is_bats = False
    for marker in request.node.iter_markers():
        if marker.name.startswith("bats"):
            is_bats = True
            break
    if not is_bats:
        yield
        return

    _LOCK_DIR.mkdir(mode=0o700, exist_ok=True)
    lock_path = _LOCK_DIR / "suite.lock"
    with open(lock_path, "w") as lf:
        # Non-blocking poll so we surface a clear error instead of hanging
        # forever when a previous run left a stuck process holding the lock.
        deadline = time.monotonic() + 300  # 5 min grace for a running suite
        while True:
            try:
                fcntl.flock(lf.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() > deadline:
                    pytest.fail(
                        "Could not acquire BATS serialisation lock within 300 s — "
                        "another BATS suite may be hung. Check for stale "
                        f"processes holding {lock_path}"
                    )
                time.sleep(1)
        try:
            yield
        finally:
            fcntl.flock(lf.fileno(), fcntl.LOCK_UN)
