"""Pytest configuration: serialize BATS suite execution and enforce timeouts.

BATS suites run shellcheck on all ~24 scripts and source the full tactical
profile.  Running multiple suites in parallel saturates CPU/disk and causes
hangs when the thread-based timeout cannot interrupt blocked I/O.
"""
from __future__ import annotations

import fcntl
import tempfile
from pathlib import Path

import pytest

_LOCK_DIR = Path(tempfile.gettempdir()) / "tac-pytest-bats-locks"


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
        fcntl.flock(lf.fileno(), fcntl.LOCK_EX)
        yield
        fcntl.flock(lf.fileno(), fcntl.LOCK_UN)
