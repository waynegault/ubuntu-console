from __future__ import annotations

import os
import re
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
_BATS_SUITE_DEFS: list[tuple[str, pytest.MarkDecorator | pytest.Mark, int]] = [
    ("tests/unit/*.bats",                 pytest.mark.bats_unit,         120),
    ("tests/tactical-console.bats",        pytest.mark.bats_full,       900),
    ("tests/tactical-console-fast.bats",   pytest.mark.bats_fast,       180),
    ("tests/integration/*.bats",           pytest.mark.bats_integration, 300),
]

# Cache: maps file stem -> {test_name: {"passed": bool, "output": str}}
_bats_results_cache: dict[str, dict[str, dict[str, Any]]] = {}


def _parse_bats_tests(bats_file: Path) -> list[str]:
    """Extract individual @test names from a .bats file."""
    text = bats_file.read_text(encoding="utf-8")
    names: list[str] = []
    for m in re.finditer(r'@test\s+["\'](.*)["\']\s+{', text):
        names.append(m.group(1))
    return names


def _timeout_tail(exc: subprocess.TimeoutExpired) -> tuple[list[str], list[str]]:
    stdout_tail: list[str] = []
    stderr_tail: list[str] = []
    for attr, dst in [("output", stdout_tail), ("stderr", stderr_tail)]:
        raw = getattr(exc, attr, None)
        if raw is not None:
            out: str = raw.decode() if isinstance(raw, bytes) else raw
            dst.extend(out.splitlines()[-40:])
    return stdout_tail, stderr_tail


def _read_temp_files(tf_out, tf_err) -> tuple[str, str]:
    tf_out.seek(0)
    tf_err.seek(0)
    return tf_out.read(), tf_err.read()


def _kill_process_group(pid: int) -> None:
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


def _run_bats(bats_file: Path, timeout_s: int) -> subprocess.CompletedProcess[str]:
    """Run a BATS file using temp files, returning stdout/stderr."""
    env = os.environ.copy()
    env.setdefault("TERM", "xterm-256color")
    cmd = [BATS_EXECUTABLE, "--tap", "--timing", str(bats_file)]

    timeout_bin = "/usr/bin/timeout" if os.path.exists("/usr/bin/timeout") else None
    if timeout_bin is None and os.path.exists("/bin/timeout"):
        timeout_bin = "/bin/timeout"
    if timeout_bin is not None:
        cmd = [timeout_bin, "-k", "5", str(timeout_s + 15)] + cmd

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
                    raise subprocess.TimeoutExpired(cmd=cmd, timeout=timeout_s, output=stdout_data, stderr=stderr_data)
            stdout_data, stderr_data = _read_temp_files(tf_out, tf_err)
        finally:
            for p in (stdout_path, stderr_path):
                try:
                    os.unlink(p)
                except OSError:
                    pass

    returncode = proc.returncode
    if returncode == 124:
        raise subprocess.TimeoutExpired(cmd=cmd, timeout=timeout_s, output=stdout_data, stderr=stderr_data)
    return subprocess.CompletedProcess(cmd, returncode, stdout_data, stderr_data)


def _run_and_cache_bats(bats_file: Path, timeout_s: int) -> dict[str, dict[str, Any]]:
    """Run a BATS file and return per-test results dict: {name: {"passed": bool, "output": str}}."""
    stem = bats_file.stem
    if stem in _bats_results_cache:
        return _bats_results_cache[stem]

    results: dict[str, dict[str, Any]] = {}
    try:
        result = _run_bats(bats_file, timeout_s)
    except subprocess.TimeoutExpired:
        for name in _parse_bats_tests(bats_file):
            results[name] = {"passed": False, "output": f"BATS suite timed out ({timeout_s}s)"}
        _bats_results_cache[stem] = results
        return results

    # Parse TAP output: "ok N test_name in Xms" or "not ok N test_name in Xms"
    # Skipped tests have "# skip (reason)" before or after the test name.
    # Handle both formats:
    #   ok 165 test_name # skip (reason)   — skip AFTER name
    #   ok 165 # skip (reason) test_name   — skip BEFORE name
    # Diagnostic context (file/line/assertion) follows failed tests on lines
    # starting with "# " — capture those into per-test diagnostics.
    tap_line_re = re.compile(r'^(ok|not ok)\s+\d+\s+(.*?)(?:\s+in\s+\d+(?:sec|ms))?$')
    diagnostic_re = re.compile(r'^#\s+(.*)')
    current_test: str | None = None
    diagnostics: dict[str, list[str]] = {}
    for line in result.stdout.splitlines():
        m = tap_line_re.match(line)
        if m:
            raw_name: str = m.group(2)
            # Strip "# skip (reason)" — BATS may put it before or after the name
            skip_marker = raw_name.find(" # skip")
            if skip_marker >= 0:
                current_test = raw_name[:skip_marker]
            elif raw_name.startswith("# skip"):
                close_paren = raw_name.find(") ", 7)
                if close_paren >= 0:
                    current_test = raw_name[close_paren + 2:]
                else:
                    current_test = ""
            else:
                current_test = raw_name
            status = m.group(1)
            if current_test is not None:
                results[current_test] = {
                    "passed": status == "ok",
                    "output": line,
                }
        elif current_test is not None:
            dm = diagnostic_re.match(line)
            if dm:
                diagnostics.setdefault(current_test, []).append(dm.group(1))

    # Append diagnostics to the output of failed tests
    for tname, diags in diagnostics.items():
        if tname in results and not results[tname]["passed"]:
            results[tname]["output"] += "\n" + "\n".join(diags)

    # Mark any test not found in output as failed
    for name in _parse_bats_tests(bats_file):
        if name not in results:
            results[name] = {"passed": False, "output": f"BATS test '{name}' not found in output"}

    _bats_results_cache[stem] = results
    return results


# ── Generate one pytest test per individual BATS @test block ──────────────

_INDIVIDUAL_TESTS: list[tuple[str, str, int]] = []  # (stem, test_name, timeout_s)

for _pattern, _marker, _timeout in _BATS_SUITE_DEFS:
    for _p in sorted(REPO_ROOT.glob(_pattern)):
        _stem = _p.stem
        for _tname in _parse_bats_tests(_p):
            _INDIVIDUAL_TESTS.append((_stem, _tname, _timeout))


def _make_test(stem: str, test_name: str, timeout_s: int):
    """Generate a pytest test function for a single BATS test case."""
    bats_file = next(p for p in REPO_ROOT.glob(f"**/{stem}.bats"))

    def _test():
        results = _run_and_cache_bats(bats_file, timeout_s)
        r = results.get(test_name, {"passed": False, "output": "test not found"})
        if not r["passed"]:
            # Show the failing line + surrounding context
            bats_tests = _parse_bats_tests(bats_file)
            try:
                idx = bats_tests.index(test_name)
            except ValueError:
                idx = -1
            prefix = f"FAILED: {stem} / {test_name}\n"
            if idx >= 0:
                prefix += f"  (test #{idx + 1} of {len(bats_tests)} in {stem}.bats)\n"
            pytest.fail(prefix + r["output"])

    # Sanitize: VS Code's vscode_pytest plugin chokes on test IDs with
    # spaces, colons, slashes, asterisks, or other special characters.
    safe_stem = re.sub(r'[^a-zA-Z0-9_]', '_', stem)
    safe_name = re.sub(r'[^a-zA-Z0-9_]', '_', test_name[:60])
    safe_name = re.sub(r'_+', '_', safe_name).strip('_')

    # Ensure uniqueness: if the truncated name collides with an existing
    # function, append a counter suffix.
    _base = f"test_{safe_stem}_{safe_name}"
    _final = _base
    _counter = 1
    while _final in globals():
        _final = f"{_base}_{_counter}"
        _counter += 1

    # Expose BATS file and timeout for conftest's lock fixture
    setattr(_test, "_bats_file", bats_file)
    setattr(_test, "_bats_timeout", timeout_s)

    # Apply markers via decoration so pytest -m filtering works
    _test = pytest.mark.bats(_test)
    _test = _get_marker_for_timeout(timeout_s)(_test)
    if timeout_s >= 600:
        _test = pytest.mark.slow(_test)
    _test.__name__ = _final
    _test.__qualname__ = _final
    return _test


def _get_marker_for_timeout(timeout_s: int) -> pytest.MarkDecorator | pytest.Mark:
    for pattern, marker, to in _BATS_SUITE_DEFS:
        if to == timeout_s:
            return marker
    return pytest.mark.bats_default


for _stem, _tname, _timeout in _INDIVIDUAL_TESTS:
    _fn = _make_test(_stem, _tname, _timeout)
    globals()[_fn.__name__] = _fn
