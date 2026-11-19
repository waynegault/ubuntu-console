"""The junit bridge: bats TAP -> junit, and the summary that reads both halves.

The suite never saw a machine-readable record before this: `tools/run-tests.sh`
streams bats' TAP and the terminal is the only copy.  These cases pin the two
things that would make the record lie — a case counted under the wrong name, and
an empty report read as a pass — plus the merge that joins the bats half to the
pytest half.
"""

from __future__ import annotations

import xml.etree.ElementTree as ET

import pytest_junit_summary
from tools import tap_to_junit

TAP = "\n".join(
    [
        "1..4",
        "ok 1 alpha passes in 19ms",
        "not ok 2 beta fails in 2033ms",
        "# (in test file probe.bats, line 8)",
        "#   `false' failed",
        "ok 3 gamma skips in 9ms # skip not today",
        "ok 4 delta passes",
    ]
)


def test_a_tap_case_keeps_its_name_and_its_own_timing() -> None:
    """bats puts the timing BEFORE a trailing marker, so the marker must go first.

    Getting this order wrong named the case "gamma skips in 9ms" — a name no
    lookup finds — and lost the per-case duration the whole-file run needs.
    """
    cases = tap_to_junit.parse_tap(TAP)
    assert [case.name for case in cases] == [
        "alpha passes",
        "beta fails",
        "gamma skips",
        "delta passes",
    ]
    assert cases[0].seconds == 0.019
    assert cases[1].seconds == 2.033
    assert cases[2].seconds == 0.009


def test_a_failure_carries_its_diagnostics_and_a_skip_is_marked(tmp_path) -> None:
    """A red case without its `#` lines is a name with no cause, in the record."""
    tap = tmp_path / "probe.tap"
    tap.write_text(TAP, encoding="utf-8")
    out = tmp_path / "probe.xml"
    assert tap_to_junit.main(["-o", str(out), f"tests/unit/probe.bats={tap}"]) == 0

    root = ET.parse(out).getroot()
    suite = root.find("testsuite")
    assert suite is not None
    assert suite.get("tests") == "4"
    assert suite.get("failures") == "1"
    assert suite.get("skipped") == "1"
    by_name = {case.get("name"): case for case in root.iter("testcase")}
    failure = by_name["beta fails"].find("failure")
    assert failure is not None
    assert "`false' failed" in (failure.text or "")
    assert by_name["gamma skips"].find("skipped") is not None
    # The file attribute is what a summary prints, so the suite must be named.
    assert by_name["alpha passes"].get("file") == "tests/unit/probe.bats"


def test_an_empty_tap_is_a_not_run_not_a_pass(tmp_path) -> None:
    """The control: a report with no case must fail, or 'nothing ran' reads as green."""
    tap = tmp_path / "empty.tap"
    tap.write_text("1..0\n", encoding="utf-8")
    out = tmp_path / "empty.xml"
    assert tap_to_junit.main(["-o", str(out), f"tests/unit/probe.bats={tap}"]) == 1
    assert out.is_file(), "the report is still written, so a reader sees the zero"


def test_the_summary_merges_both_halves(tmp_path, capsys, monkeypatch) -> None:
    """Two files, one verdict: the bats half is not a separate run."""
    # resolve_module_path turns a dotted classname into a path only when that file
    # exists, so the pytest report needs its module on disk to be printed as one.
    monkeypatch.chdir(tmp_path)
    (tmp_path / "tests").mkdir()
    (tmp_path / "tests" / "test_x.py").write_text("", encoding="utf-8")
    bats = tmp_path / "bats.xml"
    pytest_xml = tmp_path / "pytest.xml"
    bats.write_text(
        '<?xml version="1.0"?><testsuites><testsuite name="t.bats" timestamp='
        '"2026-11-19T10:00:00+00:00" tests="2" failures="0" errors="0" skipped="0">'
        '<testcase file="t.bats" name="one" time="0.5"/>'
        '<testcase file="t.bats" name="two" time="0.5"/></testsuite></testsuites>',
        encoding="utf-8",
    )
    pytest_xml.write_text(
        '<?xml version="1.0"?><testsuites><testsuite name="pytest" timestamp='
        '"2026-11-19T10:01:00+00:00" tests="1" failures="1" errors="0" skipped="0">'
        '<testcase classname="tests.test_x" name="red" time="0.1">'
        '<failure message="boom"/></testcase></testsuite></testsuites>',
        encoding="utf-8",
    )

    assert pytest_junit_summary.main([str(bats), str(pytest_xml)]) == 1
    out = capsys.readouterr().out
    assert "3 total, 2 passed, 1 failed" in out
    assert "tests/test_x.py::red" in out


def test_the_summary_refuses_an_empty_set(tmp_path, capsys, monkeypatch) -> None:
    """No case anywhere is a not-run, and the message must say so."""
    empty = tmp_path / "empty.xml"
    empty.write_text('<?xml version="1.0"?><testsuites/>', encoding="utf-8")
    monkeypatch.chdir(tmp_path)
    assert pytest_junit_summary.main([str(empty)]) == 1
    assert "executed nothing" in capsys.readouterr().err
