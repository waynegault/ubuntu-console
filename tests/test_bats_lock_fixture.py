from __future__ import annotations

import os
from pathlib import Path

import conftest

# pytest loads conftest.py as a plugin, not the regular Python module.
# Use a direct import of the test helper rather than going through the
# module namespace, which can alias differently under pytest's loader.
from conftest import has_conftest_is_stale_lock


def _lock_paths(tmp_path: Path) -> tuple[Path, Path]:
    lock_path = tmp_path / "tactical-console.lock"
    return lock_path, lock_path.with_suffix(lock_path.suffix + ".pid")


def test_detects_stale_lock_pid(tmp_path: Path) -> None:
    lock_path, pid_path = _lock_paths(tmp_path)
    pid_path.write_text("999999")

    assert has_conftest_is_stale_lock(lock_path, pid_path)


def test_recycled_pid_is_stale(tmp_path: Path) -> None:
    # Our own PID is alive, but a recorded start time that cannot match it
    # means the PID was recycled by an unrelated process.
    lock_path, pid_path = _lock_paths(tmp_path)
    pid_path.write_text(f"{os.getpid()} 1")

    assert has_conftest_is_stale_lock(lock_path, pid_path)


def test_live_holder_with_matching_start_time_is_not_stale(tmp_path: Path) -> None:
    lock_path, pid_path = _lock_paths(tmp_path)
    start = conftest._proc_start_time(os.getpid())
    assert start, "expected /proc to expose a process start time on Linux"
    pid_path.write_text(f"{os.getpid()} {start}")

    assert not has_conftest_is_stale_lock(lock_path, pid_path)
