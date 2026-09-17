from __future__ import annotations

import hashlib
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
_BATS_SUITE_DEFS: list[tuple[str, pytest.MarkDecorator, int]] = [
    ("tests/unit/*.bats",                 pytest.mark.bats_unit,         120),
    ("tests/tactical-console.bats",        pytest.mark.bats_full,       900),
    ("tests/tactical-console-fast.bats",   pytest.mark.bats_fast,       180),
    ("tests/tactical-console-function-availability.bats", pytest.mark.bats_fast, 60),
    ("tests/integration/*.bats",           pytest.mark.bats_integration, 300),
]

# Cache: maps file stem -> {test_name: {"passed": bool, "output": str}}
_bats_results_cache: dict[str, dict[str, dict[str, Any]]] = {}


def _parse_bats_tests(bats_file: Path) -> list[str]:
    """Extract individual @test names from a .bats file.

    Anchored to the start of a line, with the opening `{` REQUIRED.  An unanchored
    match also captures @test text that is not a declaration, and two real cases in
    tests/tactical-console-fast.bats proved it: line 98 is a comment about
    `@test "name" {`, and line 113 prints `@test "unterminated" {` into a fixture
    file.  Both fabricated a pytest test for a BATS case that does not exist, so the
    bridge reported "test not found" for two tests that never ran — and made the
    suite look like 64 cases when `bats --count` says 62.  The oracle that catches
    this class is `bats --count`; see test_bridge_parse_matches_bats_count.

    The closing quote must match the opening quote (backreference) so a name
    containing an apostrophe inside double quotes — e.g. "...last request's stats" —
    is not truncated at the inner quote.
    """
    text = bats_file.read_text(encoding="utf-8")
    names: list[str] = []
    for m in re.finditer(r'^[ \t]*@test[ \t]+(["\'])(.*?)\1[ \t]*\{', text, re.MULTILINE):
        names.append(m.group(2))
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


def _run_bats(bats_file: Path, timeout_s: int, filter_pattern: str | None = None) -> subprocess.CompletedProcess[str]:
    """Run a BATS file (or a single filtered test) using temp files.

    When *filter_pattern* is given, only tests matching that filter
    (passed via ``--filter``) are executed — much faster than running
    the entire suite when only one result is needed.
    """
    env = os.environ.copy()
    env.setdefault("TERM", "xterm-256color")
    cmd = [BATS_EXECUTABLE, "--tap", "--timing", str(bats_file)]
    if filter_pattern is not None:
        cmd += ["--filter", filter_pattern]

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


def _parse_bats_tap(stdout: str) -> dict[str, dict[str, Any]]:
    """Parse BATS TAP output into a per-test results dict.

    Handles "ok N test_name in Xms" / "not ok N test_name in Xms" lines,
    "# skip (reason)" markers (before or after the name), and "# ..."
    diagnostic lines that follow a failed test.
    """
    tap_line_re = re.compile(r'^(ok|not ok)\s+\d+\s+(.*?)(?:\s+in\s+\d+(?:\.\d+)?(?:sec|ms|s))?$')
    diagnostic_re = re.compile(r'^#\s+(.*)')
    results: dict[str, dict[str, Any]] = {}
    current_test: str | None = None
    diagnostics: dict[str, list[str]] = {}
    for line in stdout.splitlines():
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

    return results


def _run_and_cache_bats(bats_file: Path, timeout_s: int, test_name: str | None = None) -> dict[str, dict[str, Any]]:
    """Run a BATS file and return per-test results dict.

    When *test_name* is given, only that single test is executed
    (via ``--filter``) instead of the entire file.  The result is
    still cached by file stem so follow-up tests sharing the cache
    (e.g. from a full pytest run) benefit.

    A cache hit that lacks the requested test is treated as a miss:
    we run a filtered execution for that one test so individual
    VS Code test launches never fall back to the full suite.
    """
    stem = bats_file.stem
    if stem in _bats_results_cache and test_name in _bats_results_cache[stem]:
        return _bats_results_cache[stem]

    filter_ = None
    if test_name is not None:
        filter_ = re.escape(test_name)

    # A filtered run can occasionally come back with no TAP line for the
    # requested test (transient process/resource hiccup rather than a real
    # test failure, since a genuine failure still emits a "not ok" line).
    # Retry once before giving up so these flakes don't fail the build.
    attempts = 2 if test_name is not None else 1
    results: dict[str, dict[str, Any]] = {}
    for attempt in range(attempts):
        results = {}
        try:
            result = _run_bats(bats_file, timeout_s, filter_pattern=filter_)
        except subprocess.TimeoutExpired:
            for name in _parse_bats_tests(bats_file):
                results[name] = {"passed": False, "output": f"BATS suite timed out ({timeout_s}s)"}
            _bats_results_cache[stem] = results
            return results

        results = _parse_bats_tap(result.stdout)
        if test_name is None or test_name in results:
            break

    # Mark any test not found in output as failed.
    # When a specific test was requested (--filter), skip this check
    # because only that test appears in the output.
    if test_name is None:
        for name in _parse_bats_tests(bats_file):
            if name not in results:
                results[name] = {"passed": False, "output": f"BATS test '{name}' not found in output"}

    _bats_results_cache[stem] = results
    return results


# ── Generate one pytest test per individual BATS @test block ──────────────

_INDIVIDUAL_TESTS: list[tuple[str, str, int]] = []  # (stem, test_name, timeout_s)
# stem -> file, resolved in ONE pass.  `_make_test` used to search with a recursive
# glob per test (654 of them); `**/` walks the whole repo, so the search was already
# wasteful and making it deterministic with sorted() turned that into 654 full-tree
# walks — collection appeared to hang.  Every BATS file comes from the suite
# patterns above, and stems are unique, so one indexed pass is exact.
_BATS_BY_STEM: dict[str, Path] = {}

for _pattern, _marker, _timeout in _BATS_SUITE_DEFS:
    for _p in sorted(REPO_ROOT.glob(_pattern)):
        _stem = _p.stem
        _BATS_BY_STEM.setdefault(_stem, _p)
        for _tname in _parse_bats_tests(_p):
            _INDIVIDUAL_TESTS.append((_stem, _tname, _timeout))


def _make_test(stem: str, test_name: str, timeout_s: int):
    """Generate a pytest test function for a single BATS test case."""
    bats_file = _BATS_BY_STEM[stem]

    def _test():
        results = _run_and_cache_bats(bats_file, timeout_s, test_name=test_name)
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
    safe_name = re.sub(r'[^a-zA-Z0-9_]', '_', test_name)
    safe_name = re.sub(r'_+', '_', safe_name).strip('_') or "unnamed"

    # Long names are truncated for readability, but the truncation must NOT be the
    # only thing distinguishing two tests.  It used to be: the name was cut at 60
    # characters and a collision was broken by an appended counter, which depends on
    # DEFINITION ORDER.  Two consequences, both real:
    #   * inserting a test whose truncated name shared a prefix renumbered unrelated
    #     tests, so a saved node id could silently point at a DIFFERENT test
    #     (12-gpu-exclusivity has such a pair today);
    #   * any rename changed the id, so an editor's cached node id went stale — on
    #     2026-09-15 VS Code asked for `..._is_no`, a 60-character cut of a name that
    #     no longer existed, and its test runner errored out.
    # A digest of the FULL name makes every id depend only on the file stem and the
    # test's own name: unique, order-independent, and still readable.
    if len(safe_name) > 60:
        _digest = hashlib.sha1(test_name.encode("utf-8")).hexdigest()[:8]
        safe_name = f"{safe_name[:60]}_{_digest}"

    _final = f"test_{safe_stem}_{safe_name}"

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


def _get_marker_for_timeout(timeout_s: int) -> pytest.MarkDecorator:
    for pattern, marker, to in _BATS_SUITE_DEFS:
        if to == timeout_s:
            return marker
    return pytest.mark.bats_default


for _stem, _tname, _timeout in _INDIVIDUAL_TESTS:
    _fn = _make_test(_stem, _tname, _timeout)
    if _fn.__name__ in globals():
        # Ids are unique by construction (unique file stems + a digest of the full
        # name), so this can only fire if two @test blocks in one file share a name —
        # where a silent overwrite would drop one of them from the suite entirely.
        raise RuntimeError(
            f"duplicate generated test id {_fn.__name__!r}: two @test blocks in one "
            f"file share a name. Give them distinct names — the id is derived from "
            f"stem + name, so a duplicate collides and would silently overwrite."
        )
    globals()[_fn.__name__] = _fn


# ── The generated ids are an interface: keep them unique and order-independent ──
# VS Code's test explorer, `pytest <node-id>`, and every saved "run this test"
# action key off these strings.  They were derived from a 60-character cut plus a
# position-dependent counter, which is what broke on 2026-09-15.

def _generated_tests() -> dict[str, Any]:
    """The bridge's generated per-BATS-case tests (identified by their attributes)."""
    return {
        name: obj
        for name, obj in globals().items()
        if name.startswith("test_") and callable(obj) and hasattr(obj, "_bats_file")
    }


def test_bridge_generates_one_distinct_test_per_bats_case() -> None:
    """Every @test block gets its own id — no silent overwrite."""
    generated = _generated_tests()
    assert len(generated) == len(_INDIVIDUAL_TESTS), (
        f"{len(_INDIVIDUAL_TESTS)} BATS cases but {len(generated)} generated tests: "
        f"ids collided and one test overwrote another"
    )


def test_bridge_parse_matches_bats_count() -> None:
    """The parser's case count must equal `bats --count` for every suite.

    This is the oracle for the whole class: the bridge decides what to generate from
    its OWN regex, so a parser that invents a case produces a pytest test for a BATS
    case that does not exist, and running it fails "test not found" (the real
    2026-09-17 failure: tactical-console-fast parsed 64 cases against bats' 62 —
    a comment about `@test "name" {` and a printf string `@test "unterminated" {`
    were both counted as declarations).  Comparing against the runner makes any such
    parse drift a test failure instead of a phantom test.
    """
    checked = 0
    for _pattern, _marker, _timeout in _BATS_SUITE_DEFS:
        for bats_file in sorted(REPO_ROOT.glob(_pattern)):
            real = int(
                subprocess.run(
                    [BATS_EXECUTABLE, "--count", str(bats_file)],
                    cwd=REPO_ROOT,
                    capture_output=True,
                    text=True,
                    check=True,
                ).stdout.strip()
            )
            parsed = len(_parse_bats_tests(bats_file))
            assert parsed == real, (
                f"{bats_file.relative_to(REPO_ROOT)}: parsed {parsed} @test cases but "
                f"bats --count says {real} — the parser is matching text that is not a "
                f"declaration (comment, string, or heredoc)"
            )
            checked += 1
    assert checked, "expected at least one BATS suite to compare against"


def test_bridge_long_name_ids_carry_a_digest_of_the_full_name() -> None:
    """A truncated id still depends on the WHOLE name, not on definition order.

    Two of these names share their first 60 characters, so a bare truncation makes
    the id ambiguous and the tie-break was previously "whichever is defined first".
    """
    generated = _generated_tests()
    checked = 0
    for stem, test_name, _timeout in _INDIVIDUAL_TESTS:
        safe_name = re.sub(r"_+", "_", re.sub(r"[^a-zA-Z0-9_]", "_", test_name)).strip("_")
        if len(safe_name) <= 60:
            continue
        digest = hashlib.sha1(test_name.encode("utf-8")).hexdigest()[:8]
        expected = f"test_{re.sub(r'[^a-zA-Z0-9_]', '_', stem)}_{safe_name[:60]}_{digest}"
        assert expected in generated, f"missing generated id {expected!r} for {test_name!r}"
        checked += 1
    assert checked, "expected some BATS test names longer than 60 characters"
