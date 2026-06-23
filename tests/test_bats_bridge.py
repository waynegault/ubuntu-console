from __future__ import annotations

import os
import subprocess
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[1]
BATS_EXECUTABLE = "bats"

# ── BATS suite definitions ─────────────────────────────────────────────────
# (glob_pattern, marker_or_marks, timeout_s)
# Use markers for filtering (e.g. `pytest -m "bats_unit"`) and per-suite
# timeouts so slow suites fail fast instead of hanging the whole run.

_BATS_SUITE_DEFS: list[tuple[str, object, int]] = [
    ("tests/unit/*.bats",               pytest.mark.bats_unit,         60),
    ("tests/tactical-console-fast.bats", pytest.mark.bats_fast,       120),
    ("tests/tactical-console.bats",      pytest.mark.bats_full,       600),
    ("tests/llm-json-output.bats",       pytest.mark.bats_llm,        120),
    ("tests/integration/*.bats",         pytest.mark.bats_integration, 120),
    ("tests/*.bats",                     pytest.mark.bats_default,     120),
]


def _discover_params() -> list[pytest.param]:
    """Build pytest.param instances with dedup, markers, and per-suite timeouts."""
    seen: set[str] = set()
    params: list[pytest.param] = []
    for pattern, marker, timeout in _BATS_SUITE_DEFS:
        for p in sorted(REPO_ROOT.glob(pattern)):
            rel = str(p.relative_to(REPO_ROOT))
            if rel in seen:
                continue
            seen.add(rel)
            params.append(
                pytest.param(
                    p,
                    timeout,
                    id=rel,
                    marks=[pytest.mark.bats, marker],
                )
            )
    return params


BATS_PARAMS = _discover_params()


def _run_bats(bats_file: Path, timeout_s: int) -> subprocess.CompletedProcess[str]:
    """Run a BATS file with process-group-scoped timeout."""
    env = os.environ.copy()
    env.setdefault("TERM", "xterm-256color")
    cmd = [BATS_EXECUTABLE, "--tap", str(bats_file)]
    if os.path.exists("/usr/bin/timeout") or os.path.exists("/bin/timeout"):
        cmd = ["timeout", "-k", "5", str(timeout_s)] + cmd
    result = subprocess.run(
        cmd,
        cwd=REPO_ROOT,
        capture_output=True,
        text=True,
        env=env,
        check=False,
    )
    if result.returncode == 124:
        raise subprocess.TimeoutExpired(
            cmd,
            timeout=timeout_s,
            output=result.stdout,
            stderr=result.stderr,
        )
    return result


def _fail_message(bats_file: Path, result: subprocess.CompletedProcess[str]) -> str:
    """Build a readable failure message from a BATS run result."""
    lines: list[str] = []
    rel = bats_file.relative_to(REPO_ROOT)
    if result.returncode == 124:
        return f"BATS suite timed out: {rel}"
    lines.append(f"BATS suite failed (exit={result.returncode}): {rel}")
    output_lines = (result.stdout + "\n" + result.stderr).splitlines()
    lines.extend(output_lines[-40:])
    return "\n".join(lines)


@pytest.mark.parametrize(
    "bats_file,timeout_s",
    BATS_PARAMS,
)
def test_bats_suite(bats_file: Path, timeout_s: int) -> None:
    try:
        result = _run_bats(bats_file, timeout_s)
    except subprocess.TimeoutExpired as exc:
        pytest.fail(
            f"BATS suite timed out ({timeout_s}s): "
            f"{bats_file.relative_to(REPO_ROOT)}\n"
            f"stdout tail:\n"
            + "\n".join((exc.output or "").splitlines()[-40:])
            + "\n--- stderr tail ---\n"
            + "\n".join((exc.stderr or "").splitlines()[-40:])
        )
        return

    if result.returncode != 0:
        pytest.fail(_fail_message(bats_file, result))
