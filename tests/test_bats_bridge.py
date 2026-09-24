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

import _bats_suites

REPO_ROOT = Path(__file__).resolve().parents[1]
BATS_EXECUTABLE = "bats"

# ── BATS suite definitions ─────────────────────────────────────────────────
# The table itself is tests/bats-suites.tsv — the file the stdlib bridge
# (tests/test_bats_unittest.py) reads too, so the two runners cannot drift on which
# suites exist or what bounds them.  tests/_bats_suites.py parses it and rejects a
# malformed row, a suite whose glob matches nothing, and a file matched by two rows.
#
# per_test_timeout_s   bounds ONE case.  It is the process timeout for a filtered
#                      run and BATS_TEST_TIMEOUT for a whole-file run, so a hung
#                      case is still reported as that case failing and the rest of
#                      the file still produces results.
# whole_file_timeout_s bounds a whole-file run of every case in the suite, so it is
#                      a different quantity from the per-test figure and must not be
#                      compared with it.
#
# The suite's marker is resolved by NAME from that same row, which is what makes the
# table's marker column load-bearing: pytest.ini registers every name it can hold, so
# a typo is the --strict-markers collection error that names it rather than a silent
# fall-through to a marker no -m selection asks for.
_BATS_SUITES: list[_bats_suites.BatsSuite] = _bats_suites.load_suites()

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


def _run_bats(
    bats_file: Path,
    timeout_s: int,
    filter_pattern: str | None = None,
    per_test_timeout_s: int | None = None,
) -> subprocess.CompletedProcess[str]:
    """Run a BATS file (or a single filtered test) using temp files.

    When *filter_pattern* is given, only tests matching that filter
    (passed via ``--filter``) are executed — much faster than running
    the entire suite when only one result is needed.

    *timeout_s* bounds this OS process.  *per_test_timeout_s* is passed to BATS as
    ``BATS_TEST_TIMEOUT`` and bounds each individual case inside it, which is what
    keeps a whole-file run (many cases in one process) from turning a single hung
    case into a file-wide failure — bats reports that case as
    ``not ok N name in Xms # timeout after Ns`` and carries on with the next one.
    """
    env = os.environ.copy()
    env.setdefault("TERM", "xterm-256color")
    if per_test_timeout_s is not None:
        env["BATS_TEST_TIMEOUT"] = str(per_test_timeout_s)
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


# TAP line shapes bats 1.11.1 emits under `--timing`, taken from real output:
#   ok 1 quick in 19ms
#   not ok 2 slow in 2033ms # timeout after 2s     <- BATS_TEST_TIMEOUT
#   ok 3 skipped in 9ms # skip not today
_TAP_LINE_RE = re.compile(r'^(ok|not ok)\s+\d+\s+(.*)$')
_TAP_TIMING_RE = re.compile(r'\s+in\s+(\d+(?:\.\d+)?)(ms|s|sec)$')
# Trailing markers bats appends after the name (and after the timing suffix).
_TAP_MARKERS = (" # skip", " # timeout after")


def _parse_bats_tap(stdout: str) -> dict[str, dict[str, Any]]:
    """Parse BATS TAP output into a per-test results dict.

    Handles "ok N test_name in Xms" / "not ok N test_name in Xms" lines,
    "# skip (reason)" markers (before or after the name), the
    "# timeout after Ns" marker BATS_TEST_TIMEOUT adds to a case that overran, and
    "# ..." diagnostic lines that follow a failed test.

    Each result also carries ``seconds`` — the "in Xms" suffix, in seconds — when
    bats reported one, so a caller can attribute a case's OWN runtime instead of
    the wall clock of whatever invocation produced it.  That matters for a
    whole-file run, whose wall clock belongs to every case in the file.

    The timing suffix sits BEFORE the trailing marker, verified against bats
    1.11.1 output: ``ok 3 skipped in 9ms # skip not today`` and
    ``not ok 2 slow in 2033ms # timeout after 2s``.  The name is therefore taken
    as everything up to the first marker, with the timing stripped from its tail —
    a pattern anchored to the end of the line instead keeps the timing glued to
    the name, which is how a skipped case came back as "skipped in 9ms" and was
    then reported to the caller as "not found in output".
    """
    diagnostic_re = re.compile(r'^#\s+(.*)')
    results: dict[str, dict[str, Any]] = {}
    current_test: str | None = None
    diagnostics: dict[str, list[str]] = {}
    for line in stdout.splitlines():
        m = _TAP_LINE_RE.match(line)
        if m:
            status = m.group(1)
            raw_name = m.group(2)
            if status is None or raw_name is None:
                # _TAP_LINE_RE captures both groups, so this cannot happen; fail
                # loudly rather than index `results` with a None name if the
                # pattern is ever edited to make a group optional.
                raise ValueError(f"TAP line matched without its captures: {line!r}")
            seconds: float | None = None
            marker_at = -1
            for marker in _TAP_MARKERS:
                found = raw_name.find(marker)
                if found >= 0 and (marker_at < 0 or found < marker_at):
                    marker_at = found
            if marker_at >= 0:
                raw_name = raw_name[:marker_at]
            elif raw_name.startswith("# skip"):
                close_paren = raw_name.find(") ", 7)
                raw_name = raw_name[close_paren + 2:] if close_paren >= 0 else ""
            timing = _TAP_TIMING_RE.search(raw_name)
            if timing:
                value = float(timing.group(1))
                seconds = value / 1000 if timing.group(2) == "ms" else value
                raw_name = raw_name[: timing.start()]
            current_test = raw_name
            results[raw_name] = {
                "passed": status == "ok",
                "output": line,
                "seconds": seconds,
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


def _run_and_cache_bats(
    bats_file: Path,
    per_test_timeout_s: int,
    file_timeout_s: int,
    test_name: str | None = None,
    run_whole_file: bool = False,
) -> dict[str, dict[str, Any]]:
    """Run a BATS file and return a per-test results dict (cached by file stem).

    Two execution modes, chosen by the caller's selection:

    * *run_whole_file* — one ``bats`` process runs every case in the file.  Each
      invocation pays a large fixed cost (bats startup plus the file's
      ``setup_file``), measured at ~8.8 s per spawn for tests/tactical-console.bats:
      eight of its cases cost 69.0 s as eight filtered invocations and 7.5 s as one
      whole-file invocation.  A one-process-per-case run therefore spends nearly all
      of its time re-paying that cost — which is what made a full pytest run take
      over an hour.  ``BATS_TEST_TIMEOUT`` still bounds each case individually, so a
      hung case fails alone and the rest of the file still reports.
    * *filtered* (``--filter``) — exactly one case, used when the session did NOT
      select the whole file (a single VS Code launch, ``-k``, ``--deselect``):
      running 387 cases because two were asked for would be slower, not faster.
      The result is cached by file stem so follow-up tests sharing the cache
      benefit, and a cache hit that lacks the requested test is treated as a miss,
      so an individual VS Code launch never falls back to the full suite.
    """
    stem = bats_file.stem
    if stem in _bats_results_cache and test_name in _bats_results_cache[stem]:
        return _bats_results_cache[stem]

    results: dict[str, dict[str, Any]] = {}
    if run_whole_file:
        try:
            result = _run_bats(
                bats_file, file_timeout_s, per_test_timeout_s=per_test_timeout_s
            )
        except subprocess.TimeoutExpired as exc:
            # Keep whatever the run managed to report: BATS_TEST_TIMEOUT marks the
            # cases that overran, and the process budget only proves the file as a
            # whole did not finish.  Blaming every case for it would hide which part
            # of the file was healthy.
            results = _parse_bats_tap(_timeout_output(exc))
            for name in _parse_bats_tests(bats_file):
                if name not in results:
                    results[name] = {
                        "passed": False,
                        "output": f"BATS file timed out ({file_timeout_s}s)",
                    }
            _bats_results_cache[stem] = results
            return results

        results = _parse_bats_tap(result.stdout)
        for name in _parse_bats_tests(bats_file):
            if name not in results:
                results[name] = {"passed": False, "output": f"BATS test '{name}' not found in output"}
        _bats_results_cache[stem] = results
        return results

    if test_name is None:
        raise AssertionError(
            "a BATS run needs either a test_name (filtered) or run_whole_file: "
            "falling through to a whole-file run here would silently run the "
            "entire suite for every case"
        )

    filter_ = re.escape(test_name)

    # A filtered run can occasionally come back with no TAP line for the
    # requested test (transient process/resource hiccup rather than a real
    # test failure, since a genuine failure still emits a "not ok" line).
    # Retry once before giving up so these flakes don't fail the build.
    for _attempt in range(2):
        try:
            result = _run_bats(bats_file, per_test_timeout_s, filter_pattern=filter_)
        except subprocess.TimeoutExpired:
            # Only the requested case is blamed: the other cases in the file were
            # never asked for, and recording them as failed would turn one hung
            # case into a file-wide failure that the cache then hands to every
            # later case.
            _bats_results_cache[stem] = {
                test_name: {
                    "passed": False,
                    "output": f"BATS test timed out ({per_test_timeout_s}s)",
                }
            }
            return _bats_results_cache[stem]

        results = _parse_bats_tap(result.stdout)
        if test_name in results:
            break

    _bats_results_cache[stem] = results
    return results


def _timeout_output(exc: subprocess.TimeoutExpired) -> str:
    """The stdout captured before a timed-out BATS run was killed."""
    raw = exc.output
    if raw is None:
        return ""
    return raw.decode() if isinstance(raw, bytes) else raw


# ── Generate one pytest test per individual BATS @test block ──────────────

# (stem, test_name, suite_marker, per_test_s, file_s)
_INDIVIDUAL_TESTS: list[tuple[str, str, pytest.MarkDecorator, int, int]] = []
# stem -> file, resolved in ONE pass.  `_make_test` used to search with a recursive
# glob per test (654 of them); `**/` walks the whole repo, so the search was already
# wasteful and making it deterministic with sorted() turned that into 654 full-tree
# walks — collection appeared to hang.  Every BATS file comes from the suite table,
# and a stem claimed by two rows is an error there, so one indexed pass is exact.
_BATS_BY_STEM: dict[str, Path] = {}
# stem -> number of @test cases, so a caller asked for every case can be answered
# without re-reading the file per test.
_CASE_COUNT_BY_STEM: dict[str, int] = {}

for _suite, _p in _bats_suites.suite_files(_BATS_SUITES):
    _stem = _p.stem
    _BATS_BY_STEM.setdefault(_stem, _p)
    _case_names = _parse_bats_tests(_p)
    _CASE_COUNT_BY_STEM.setdefault(_stem, len(_case_names))
    _marker = getattr(pytest.mark, _suite.marker)
    for _tname in _case_names:
        _INDIVIDUAL_TESTS.append(
            (_stem, _tname, _marker, _suite.per_case_timeout_s, _suite.file_timeout_s)
        )


def _session_selected_every_case(request: pytest.FixtureRequest, bats_file: Path) -> bool:
    """True when this session selected every @test case in *bats_file*.

    Selecting all of them is the normal full-suite run, and then one whole-file
    BATS invocation does exactly the work the per-case invocations would do, minus
    one fixed cost per case.  A partial selection (`-k`, `--deselect`, `--last-failed`,
    or a single VS Code test launch) keeps the filtered path — running 387 cases
    because two were asked for would be slower, not faster.

    A one-case file is always filtered: the whole-file run would do the same work,
    so there is no reason to give up the "one launch runs one case" property.
    """
    total = _CASE_COUNT_BY_STEM.get(bats_file.stem, 0)
    if total < 2:
        return False
    selected = 0
    for item in request.session.items:
        if getattr(getattr(item, "function", None), "_bats_file", None) == bats_file:
            selected += 1
            if selected >= total:
                # Can't exceed total (ids are unique per case), so stop early: this
                # runs once per case, against a session of over a thousand items.
                return True
    return False


def _make_test(
    stem: str,
    test_name: str,
    marker: pytest.MarkDecorator,
    per_test_timeout_s: int,
    file_timeout_s: int,
):
    """Generate a pytest test function for a single BATS test case."""
    bats_file = _BATS_BY_STEM[stem]

    def _test(request: pytest.FixtureRequest):
        results = _run_and_cache_bats(
            bats_file,
            per_test_timeout_s,
            file_timeout_s,
            test_name=test_name,
            run_whole_file=_session_selected_every_case(request, bats_file),
        )
        r = results.get(test_name, {"passed": False, "output": "test not found"})
        # conftest's duration tracker reads this: when the file ran as one process
        # this item's wall clock is the whole file, so the case's own TAP time is
        # the honest measurement (and for a cache hit it is the only one there is).
        setattr(request.node, "_bats_case_seconds", r.get("seconds"))
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

    # Expose BATS file and the file-level budget for conftest's lock fixture: a
    # whole-file run holds the per-file lock for the whole file, so the wait for
    # that lock has to cover it.
    setattr(_test, "_bats_file", bats_file)
    setattr(_test, "_bats_timeout", file_timeout_s)

    # Apply markers via decoration so pytest -m filtering works.  The suite marker is
    # the one its own table row names, never a lookup by timeout: two rows may share a
    # timeout, and matching on that picked a marker by table position rather than by
    # what the table said.
    _test = pytest.mark.bats(_test)
    _test = marker(_test)
    if per_test_timeout_s >= 600:
        _test = pytest.mark.slow(_test)

    # pytest.ini's --timeout is a per-item backstop.  In whole-file mode the first
    # case of a file carries that file's entire run, which for
    # tests/tactical-console.bats exceeds the 1000 s default — and pytest-timeout's
    # thread method kills the whole session, so the default would abort the run
    # rather than report a result.  The real per-case bound is BATS_TEST_TIMEOUT
    # (and _run_bats' own process timeout); this only has to be looser than the
    # file budget so it never fires first.
    _test = pytest.mark.timeout(file_timeout_s + 60)(_test)
    _test.__name__ = _final
    _test.__qualname__ = _final
    return _test


for _stem, _tname, _marker, _per_test_s, _file_s in _INDIVIDUAL_TESTS:
    _fn = _make_test(_stem, _tname, _marker, _per_test_s, _file_s)
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
    for _suite, bats_file in _bats_suites.suite_files(_BATS_SUITES):
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


def test_bridge_parse_names_cases_despite_trailing_markers() -> None:
    """A case is keyed by its NAME, not by the text bats glues onto the line.

    bats 1.11.1 with ``--timing`` emits the timing BEFORE the trailing marker —
    ``ok 3 skipped in 9ms # skip not today`` and, under BATS_TEST_TIMEOUT,
    ``not ok 2 slow in 2033ms # timeout after 2s``.  A pattern anchored at the line
    end cannot match the timing there, so the name came back as
    ``skipped in 9ms``: the caller's lookup missed and the case was reported as
    "not found in output" instead of with its real result.  The per-case ``seconds``
    is what a whole-file run needs to attribute a case's own runtime, and is
    captured here too.
    """
    tap = "\n".join(
        [
            "1..4",
            "ok 1 quick in 19ms",
            "not ok 2 slow in 2033ms # timeout after 2s",
            "# (in test file probe.bats, line 8)",
            "#   `sleep 30' failed due to timeout",
            "ok 3 skipped in 9ms # skip not today",
            "not ok 4 fails in 6ms",
            "#   `false' failed",
        ]
    )
    results = _parse_bats_tap(tap)

    assert set(results) == {"quick", "slow", "skipped", "fails"}
    assert results["quick"]["passed"] is True
    assert results["slow"]["passed"] is False
    assert results["skipped"]["passed"] is True
    assert results["fails"]["passed"] is False
    # Supplied by the run's "in Xms" suffix, in seconds.
    assert results["quick"]["seconds"] == 0.019
    assert results["slow"]["seconds"] == 2.033
    # The diagnostics after a failure stay attached to that failure.
    assert "failed due to timeout" in results["slow"]["output"]
    assert "`false' failed" in results["fails"]["output"]


def test_bridge_long_name_ids_carry_a_digest_of_the_full_name() -> None:
    """A truncated id still depends on the WHOLE name, not on definition order.

    Two of these names share their first 60 characters, so a bare truncation makes
    the id ambiguous and the tie-break was previously "whichever is defined first".
    """
    generated = _generated_tests()
    checked = 0
    for stem, test_name, _marker, _per_test_s, _file_s in _INDIVIDUAL_TESTS:
        safe_name = re.sub(r"_+", "_", re.sub(r"[^a-zA-Z0-9_]", "_", test_name)).strip("_")
        if len(safe_name) <= 60:
            continue
        digest = hashlib.sha1(test_name.encode("utf-8")).hexdigest()[:8]
        expected = f"test_{re.sub(r'[^a-zA-Z0-9_]', '_', stem)}_{safe_name[:60]}_{digest}"
        assert expected in generated, f"missing generated id {expected!r} for {test_name!r}"
        checked += 1
    assert checked, "expected some BATS test names longer than 60 characters"
