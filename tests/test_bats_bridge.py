from __future__ import annotations

import os
import signal
import subprocess
import tempfile
from pathlib import Path
from typing import Any

import pytest

REPO_ROOT = Path(__file__).resolve().parents[1]
BATS_EXECUTABLE = "bats"

# ── BATS suite definitions ─────────────────────────────────────────────────
# (glob_pattern, marker_or_marks, timeout_s)
# Use markers for filtering (e.g. `pytest -m "bats_unit"`) and per-suite
# timeouts so slow suites fail fast instead of hanging the whole run.
# The `tests/*.bats` catch-all is omitted — the explicit patterns above
# already cover every bats file under tests/.

_BATS_SUITE_DEFS: list[tuple[str, pytest.MarkDecorator | pytest.Mark, int]] = [
    ("tests/unit/*.bats",               pytest.mark.bats_unit,         60),
    ("tests/tactical-console-fast.bats", pytest.mark.bats_fast,       120),
    ("tests/tactical-console.bats",      pytest.mark.bats_full,       600),
    ("tests/llm-json-output.bats",       pytest.mark.bats_llm,        600),
    ("tests/integration/*.bats",         pytest.mark.bats_integration, 120),
]


def _discover_params() -> list[Any]:
    """Build pytest.param instances with dedup, markers, and per-suite timeouts."""
    seen: set[str] = set()
    params: list[Any] = []
    for pattern, marker, timeout in _BATS_SUITE_DEFS:
        for p in sorted(REPO_ROOT.glob(pattern)):
            rel = str(p.relative_to(REPO_ROOT))
            if rel in seen:
                continue
            seen.add(rel)
            # Use just the filename as the test id — VSCode's test explorer
            # struggles with slashes and dots inside parametrized ids.
            params.append(
                pytest.param(
                    p,
                    timeout,
                    id=p.name,
                    marks=[pytest.mark.bats, marker],  # type: ignore[list-item]
                )
            )
    return params


def _timeout_tail(exc: subprocess.TimeoutExpired) -> tuple[list[str], list[str]]:
    """Extract last 40 lines of stdout/stderr from a TimeoutExpired exception."""
    stdout_tail: list[str] = []
    stderr_tail: list[str] = []
    for attr, dst in [("output", stdout_tail), ("stderr", stderr_tail)]:
        raw = getattr(exc, attr, None)
        if raw is not None:
            out: str = raw.decode() if isinstance(raw, bytes) else raw  # type: ignore[assignment]
            dst.extend(out.splitlines()[-40:])
    return stdout_tail, stderr_tail


def _read_temp_files(tf_out, tf_err) -> tuple[str, str]:
    """Seek and read both temp files, returning (stdout, stderr)."""
    tf_out.seek(0)
    tf_err.seek(0)
    return tf_out.read(), tf_err.read()


def _kill_process_group(pid: int) -> None:
    """Terminate a process group, escalating to SIGKILL if needed."""
    try:
        os.killpg(os.getpgid(pid), signal.SIGTERM)
    except (ProcessLookupError, OSError):
        return
    import time as _time
    deadline = _time.monotonic() + 5
    while _time.monotonic() < deadline:
        try:
            os.killpg(os.getpgid(pid), 0)
        except (ProcessLookupError, OSError):
            return
        _time.sleep(0.25)
    try:
        os.killpg(os.getpgid(pid), signal.SIGKILL)
    except (ProcessLookupError, OSError):
        pass


BATS_PARAMS = _discover_params()


def _run_bats(bats_file: Path, timeout_s: int) -> subprocess.CompletedProcess[str]:
    """Run a BATS file using temp files for stdout/stderr to avoid pipe deadlocks.

    ``timeout_s`` is enforced by Python's ``subprocess`` API via
    ``proc.wait(timeout=...)``. A new process session is created so that on
    timeout we can terminate the entire BATS process group, including any
    grandchildren (e.g. shellcheck, llama-server, curl) that BATS may have
    spawned.  If the GNU ``timeout`` utility is available it is also prepended
    as a last-resort safety net.

    Using temp files instead of ``stdout=PIPE`` / ``stderr=PIPE`` avoids
    deadlocks when a child process fills the pipe buffer (>64KB typical) while
    the parent hasn't yet called ``communicate()`` — standard POSIX pipe
    deadlock scenario.
    """
    env = os.environ.copy()
    env.setdefault("TERM", "xterm-256color")
    cmd = [BATS_EXECUTABLE, "--tap", str(bats_file)]

    # Last-resort external timeout: give it a small buffer so the Python
    # timeout fires first and we get a clean process-group kill.
    timeout_bin = "/usr/bin/timeout" if os.path.exists("/usr/bin/timeout") else None
    if timeout_bin is None and os.path.exists("/bin/timeout"):
        timeout_bin = "/bin/timeout"
    if timeout_bin is not None:
        cmd = [timeout_bin, "-k", "5", str(timeout_s + 15)] + cmd

    # Use temp files instead of PIPE to avoid pipe-buffer deadlocks.
    with tempfile.NamedTemporaryFile(mode="w+", suffix=".bats-stdout", delete=False) as tf_out, \
         tempfile.NamedTemporaryFile(mode="w+", suffix=".bats-stderr", delete=False) as tf_err:
        stdout_path = tf_out.name
        stderr_path = tf_err.name

        try:
            with subprocess.Popen(
                cmd,
                cwd=REPO_ROOT,
                stdout=tf_out,
                stderr=tf_err,
                text=True,
                env=env,
                start_new_session=True,
            ) as proc:
                try:
                    proc.wait(timeout=timeout_s)
                except subprocess.TimeoutExpired:
                    _kill_process_group(proc.pid)
                    stdout_data, stderr_data = _read_temp_files(tf_out, tf_err)
                    raise subprocess.TimeoutExpired(
                        cmd=cmd, timeout=timeout_s,
                        output=stdout_data, stderr=stderr_data,
                    )
            stdout_data, stderr_data = _read_temp_files(tf_out, tf_err)
        finally:
            for p in (stdout_path, stderr_path):
                try:
                    os.unlink(p)
                except OSError:
                    pass

    # Normalize the exit code from the external timeout wrapper so callers can
    # rely on 124 meaning "timed out".
    returncode = proc.returncode
    if returncode == 124:
        raise subprocess.TimeoutExpired(
            cmd=cmd,
            timeout=timeout_s,
            output=stdout_data,
            stderr=stderr_data,
        )

    return subprocess.CompletedProcess(cmd, returncode, stdout_data, stderr_data)


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
        stdout_tail, stderr_tail = _timeout_tail(exc)
        pytest.fail(
            f"BATS suite timed out ({timeout_s}s): "
            f"{bats_file.relative_to(REPO_ROOT)}\n"
            f"stdout tail:\n"
            + "\n".join(stdout_tail)
            + "\n--- stderr tail ---\n"
            + "\n".join(stderr_tail)
        )
        return

    if result.returncode != 0:
        pytest.fail(_fail_message(bats_file, result))
