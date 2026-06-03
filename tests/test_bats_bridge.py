from __future__ import annotations

import os
import subprocess
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[1]
BATS_EXECUTABLE = "bats"


def _discover_bats_files() -> list[Path]:
    patterns = (
        "tests/*.bats",
        "tests/unit/*.bats",
        "tests/integration/*.bats",
    )
    files: list[Path] = []
    for pattern in patterns:
        files.extend(sorted(REPO_ROOT.glob(pattern)))
    return files


BATS_FILES = _discover_bats_files()


@pytest.mark.bats
@pytest.mark.parametrize(
    "bats_file",
    BATS_FILES,
    ids=lambda p: str(p.relative_to(REPO_ROOT)),
)
def test_bats_suite(bats_file: Path) -> None:
    env = os.environ.copy()
    env.setdefault("TERM", "xterm-256color")
    results: list[subprocess.CompletedProcess[str]] = []
    for _ in range(2):
        result = subprocess.run(
            [BATS_EXECUTABLE, "--tap", str(bats_file)],
            cwd=REPO_ROOT,
            capture_output=True,
            text=True,
            env=env,
            check=False,
        )
        results.append(result)
        if result.returncode == 0:
            return

    last = results[-1]
    first = results[0]
    first_tail = "\n".join((first.stdout + "\n" + first.stderr).splitlines()[-40:])
    last_tail = "\n".join((last.stdout + "\n" + last.stderr).splitlines()[-80:])
    pytest.fail(
        f"BATS suite failed after retry: {bats_file.relative_to(REPO_ROOT)}\n"
        f"first_exit={first.returncode} retry_exit={last.returncode}\n"
        f"--- first attempt tail ---\n{first_tail}\n"
        f"--- retry attempt tail ---\n{last_tail}"
    )
