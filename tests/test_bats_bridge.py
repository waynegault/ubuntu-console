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

_BATS_SUITE_DEFS: list[tuple[str, pytest.MarkDecorator | pytest.Mark, int]] = [
    ("tests/unit/*.bats",               pytest.mark.bats_unit,         60),
    ("tests/tactical-console-fast.bats", pytest.mark.bats_fast,       120),
    ("tests/tactical-console.bats",      pytest.mark.bats_full,       600),
    ("tests/llm-json-output.bats",       pytest.mark.bats_llm,        600),
    ("tests/integration/*.bats",         pytest.mark.bats_integration, 120),
    ("tests/*.bats",                     pytest.mark.bats_default,     120),
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
            params.append(
                pytest.param(
                    p,
                    timeout,
                    id=rel,
                    marks=[pytest.mark.bats, marker],  # type: ignore[list-item]
                )
            )
    return params


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
                    # Terminate the whole process group so no orphaned grandchild can
                    # keep running after we give up on this suite.
                    try:
                        os.killpg(os.getpgid(proc.pid), signal.SIGTERM)
                    except (ProcessLookupError, OSError):
                        pass
                    try:
                        proc.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        try:
                            os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
                        except (ProcessLookupError, OSError):
                            pass
                        proc.wait()
                    # Read the temp files for the error message.
                    tf_out.seek(0)
                    tf_err.seek(0)
                    stdout_data = tf_out.read()
                    stderr_data = tf_err.read()
                    raise subprocess.TimeoutExpired(
                        cmd=cmd,
                        timeout=timeout_s,
                        output=stdout_data,
                        stderr=stderr_data,
                    )

            # Normal exit — read the temp files.
            tf_out.seek(0)
            tf_err.seek(0)
            stdout_data = tf_out.read()
            stderr_data = tf_err.read()
        finally:
            # Clean up temp files.
            try:
                os.unlink(stdout_path)
            except OSError:
                pass
            try:
                os.unlink(stderr_path)
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
        stdout_tail: list[str] = []
        stderr_tail: list[str] = []
        if exc.output is not None:
            out = exc.output.decode() if isinstance(exc.output, bytes) else exc.output
            if out is not None:
                stdout_tail = out.splitlines()[-40:]
        if exc.stderr is not None:
            err = exc.stderr.decode() if isinstance(exc.stderr, bytes) else exc.stderr
            if err is not None:
                stderr_tail = err.splitlines()[-40:]
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
