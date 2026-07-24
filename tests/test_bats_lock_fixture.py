from __future__ import annotations

from pathlib import Path

# pytest loads conftest.py as a plugin, not the regular Python module.
# Use a direct import of the test helper rather than going through the
# module namespace, which can alias differently under pytest's loader.
from conftest import has_conftest_is_stale_lock  # noqa: F811


def test_detects_stale_lock_pid(tmp_path: Path) -> None:
    lock_path = tmp_path / "tactical-console.lock"
    pid_path = lock_path.with_suffix(lock_path.suffix + ".pid")
    pid_path.write_text("999999")

    assert has_conftest_is_stale_lock(lock_path, pid_path)
