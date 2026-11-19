#!/usr/bin/env python3
"""Summarise one or more pytest/bats junit XML reports.

Written for a suite whose results arrive in two files: the bats half is streamed
as TAP (it reads better than a pytest run of the same cases) and converted by
`tools/tap_to_junit.py`, while the Python half comes from pytest's own
`--junitxml`.  Several paths are accepted so the caller passes whichever files
this run produced, and the counts are summed across them.

Why a junit record at all: the terminal scrolls away.  `tests/bats-unittest.xml`
and `tests/pytest-unittest.xml` are the machine-readable record of the last run,
which is what a CI job can upload and what this reads.

A report with no testcase is a run that executed nothing: it is reported as a
failure, never as a pass.
"""

from __future__ import annotations

import argparse
import sys
import xml.etree.ElementTree as ET
from datetime import UTC, datetime
from pathlib import Path
from zoneinfo import ZoneInfo

DEFAULT_XML = Path(".pytest_cache/unittest.xml")
# The bats half is converted from TAP by tools/tap_to_junit.py (pytest cannot see
# it: tools/run-tests.sh streams bats directly, and the bridge is excluded there).
DEFAULT_BATS_XML = Path(".pytest_cache/bats.xml")
DEFAULT_REPORTS = (DEFAULT_BATS_XML, DEFAULT_XML)
LOCAL_ZONE = ZoneInfo("Europe/London")


def resolve_module_path(classname: str) -> str:
    """Return ``classname`` rewritten to a pytest-shaped ``path::Class`` when possible.

    junit's ``classname`` is dotted (``tests.config.test_x.TestX``) and pytest does
    not always emit ``file``, so the longest dotted prefix that exists on disk as a
    ``.py`` file is turned back into a path and the remainder kept as the class
    chain.  An unresolvable name is returned unchanged rather than guessed at.
    """
    parts = classname.split(".")
    for cut in range(len(parts), 0, -1):
        candidate = Path(*parts[:cut]).with_suffix(".py")
        if candidate.is_file():
            return "::".join([str(candidate), *parts[cut:]])
    return classname


def node_id(case: ET.Element) -> str:
    """Return a pytest-shaped node id for one junit ``testcase`` element."""
    name = case.get("name", "")
    file = case.get("file")
    if file:
        return f"{file}::{name}"
    classname = case.get("classname", "")
    if not classname:
        return name
    return f"{resolve_module_path(classname)}::{name}"


def outcome_message(case: ET.Element, tag: str) -> str:
    """Return the failure/error message, falling back to the first text line."""
    element = case.find(tag)
    if element is None:
        return ""
    message = (element.get("message") or "").strip()
    if message:
        return message
    for line in (element.text or "").splitlines():
        if line.strip():
            return line.strip()
    return ""


def run_timestamp(roots: list[ET.Element]) -> str:
    """Return the report's start time in UTC and Europe/London, or ``""``."""
    parsed: list[datetime] = []
    for root in roots:
        for suite in root.iter("testsuite"):
            stamp = suite.get("timestamp")
            if not stamp:
                continue
            try:
                parsed.append(datetime.fromisoformat(stamp))
            except ValueError:
                # Third-party junit producers emit non-ISO stamps; a missing
                # header line is not worth failing the report over.
                continue
    if not parsed:
        return ""
    start = min(parsed)
    utc = start.astimezone(UTC).strftime("%Y-%m-%d %H:%M")
    local = start.astimezone(LOCAL_ZONE).strftime("%Y-%m-%d %H:%M %Z")
    return f"{utc} UTC = {local}"


def format_seconds(seconds: float) -> str:
    """Return a duration as ``H:MM:SS`` or ``M:SS``."""
    whole = int(round(seconds))
    hours, rest = divmod(whole, 3600)
    minutes, secs = divmod(rest, 60)
    if hours:
        return f"{hours}:{minutes:02d}:{secs:02d}"
    return f"{minutes}:{secs:02d}"


def case_seconds(case: ET.Element) -> float:
    """Return one case's duration in seconds (0.0 when the attribute is absent)."""
    try:
        return float(case.get("time") or 0.0)
    except ValueError:
        return 0.0


def build_parser() -> argparse.ArgumentParser:
    """Return the argument parser for the summary command."""
    parser = argparse.ArgumentParser(
        description="Summarise pytest/bats junit XML reports (counts, failures, slowest).",
    )
    parser.add_argument(
        "xml",
        nargs="*",
        help=(
            "junit XML report(s) to read.  With none given, the reports a run "
            f"leaves are used: {', '.join(str(p) for p in DEFAULT_REPORTS)}."
        ),
    )
    parser.add_argument(
        "-n",
        "--slowest",
        type=int,
        default=10,
        help="How many slowest tests to list (default: 10; 0 to skip the section).",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    """Print the report and return a process exit code."""
    args = build_parser().parse_args(argv)

    if args.xml:
        paths = [Path(raw) for raw in args.xml]
    else:
        paths = [path for path in DEFAULT_REPORTS if path.is_file()]
        if not paths:
            print(
                "No junit reports found: "
                + ", ".join(str(p) for p in DEFAULT_REPORTS)
                + ". Run `tools/run-tests.sh` (which writes both halves), or name "
                "the reports explicitly.",
                file=sys.stderr,
            )
            return 2

    roots: list[ET.Element] = []
    for path in paths:
        if not path.is_file():
            print(
                f"No junit report at {path}. Pass each report the run produced; "
                "a pytest run writes one because --junitxml is in pytest.ini addopts.",
                file=sys.stderr,
            )
            return 2
        roots.append(ET.parse(path).getroot())

    cases = [case for root in roots for case in root.iter("testcase")]
    if not cases:
        print(
            "0 test cases across "
            + ", ".join(str(path) for path in paths)
            + " — a report with no cases is a run that executed nothing, not a pass.",
            file=sys.stderr,
        )
        return 1

    skipped = [case for case in cases if case.find("skipped") is not None]
    failures = [case for case in cases if case.find("failure") is not None]
    errors = [case for case in cases if case.find("error") is not None]
    passed = len(cases) - len(skipped) - len(failures) - len(errors)
    total_seconds = sum(case_seconds(case) for case in cases)

    print(f"Report: {', '.join(str(path) for path in paths)}")
    stamp = run_timestamp(roots)
    if stamp:
        print(f"Run:    {stamp}")
    print(
        f"Tests:  {len(cases)} total, {passed} passed, {len(failures)} failed, "
        f"{len(errors)} errors, {len(skipped)} skipped "
        f"({format_seconds(total_seconds)} of test time)"
    )

    bad = [(case, "failure") for case in failures] + [(case, "error") for case in errors]
    if bad:
        print("\nFAILURES")
        for case, tag in bad:
            print(f"  {node_id(case)}")
            message = outcome_message(case, tag)
            for line in message.splitlines():
                print(f"      {line}")

    slowest = sorted(cases, key=case_seconds, reverse=True)[: max(args.slowest, 0)]
    if slowest:
        print(f"\nSLOWEST ({len(slowest)})")
        for case in slowest:
            print(f"  {case_seconds(case):8.2f}s  {node_id(case)}")

    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
