from __future__ import annotations

from pathlib import Path

from tests import conftest as bats_conftest


def test_detects_stale_lock_pid(tmp_path: Path) -> None:
    lock_path = tmp_path / "tactical-console.lock"
    pid_path = lock_path.with_suffix(lock_path.suffix + ".pid")
    pid_path.write_text("999999")

    assert bats_conftest._is_stale_lock(lock_path, pid_path)
