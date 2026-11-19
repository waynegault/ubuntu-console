#!/usr/bin/env python3
"""Convert bats TAP output into a junit XML report.

`tools/run-tests.sh` streams bats' own TAP because it reads better than a pytest
run of the same cases, but TAP has no consumer outside the runner: the terminal
scrolling past is the only record.  This writes the same results as junit, which
`scripts/pytest_junit_summary.py` (and any CI junit reader) can summarise.

Usage:

    tools/tap_to_junit.py -o .pytest_cache/bats.xml \
        tests/unit/01-refresh-keys.bats=/tmp/01.tap \
        tests/unit/02-so-startup.bats=/tmp/02.tap

One `SUITE=TAPFILE` pair per suite, so a run that executes each file in its own
process (serial or parallel) keeps the suite boundary and its file name.

Two rules are carried over from the pytest bridge's parser, because they are the
same defect when it goes wrong:

* the timing suffix sits BEFORE the trailing marker (`ok 3 skipped in 9ms # skip
  not today`), so markers are stripped first and the timing second;
* a report with no testcase is a run that executed nothing, not a pass — the
  converter exits 1 in that case so a caller cannot mistake it for success.
"""

from __future__ import annotations

import argparse
import re
import sys
import xml.etree.ElementTree as ET
from datetime import UTC, datetime
from pathlib import Path

_TAP_LINE_RE = re.compile(r"^(ok|not ok)\s+\d+\s+(.*)$")
_TAP_TIMING_RE = re.compile(r"\s+in\s+(\d+(?:\.\d+)?)(ms|s|sec)$")
_TAP_MARKERS = (" # skip", " # timeout after")


class Case:
    """One TAP case: its name, verdict, own duration and diagnostics."""

    __slots__ = ("diagnostics", "name", "seconds", "skipped", "status")

    def __init__(self, name: str, status: str) -> None:
        self.name = name
        self.status = status
        self.seconds = 0.0
        self.skipped = False
        self.diagnostics: list[str] = []


def parse_tap(text: str) -> list[Case]:
    """Return the cases in TAP *text*, in the order bats reported them."""
    cases: list[Case] = []
    current: Case | None = None
    for line in text.splitlines():
        match = _TAP_LINE_RE.match(line)
        if match:
            raw = match.group(2)
            marker_at = -1
            marker = ""
            for candidate in _TAP_MARKERS:
                found = raw.find(candidate)
                if found >= 0 and (marker_at < 0 or found < marker_at):
                    marker_at = found
                    marker = candidate
            skipped = False
            skip_reason = ""
            if marker_at >= 0:
                if marker == " # skip":
                    skipped = True
                    skip_reason = raw[marker_at + len(marker) :].strip()
                raw = raw[:marker_at]
            timing = _TAP_TIMING_RE.search(raw)
            seconds = 0.0
            if timing:
                value = float(timing.group(1))
                seconds = value / 1000 if timing.group(2) == "ms" else value
                raw = raw[: timing.start()]
            current = Case(raw, match.group(1))
            current.seconds = seconds
            current.skipped = skipped
            if skip_reason:
                current.diagnostics.append(skip_reason)
            cases.append(current)
            continue
        if current is not None and line.startswith("#"):
            text_line = line[1:].strip()
            # A skip may also arrive as its own `# skip` line rather than inline.
            if text_line.startswith("skip"):
                current.skipped = True
            current.diagnostics.append(text_line)
    return cases


def suite_name(path: str) -> str:
    """Return the dotted classname junit readers expect for *path*."""
    stem = path.removesuffix(".bats").replace("/", ".")
    return stem


def build_testcase(suite: str, case: Case) -> ET.Element:
    """Return the junit ``testcase`` element for one TAP case."""
    element = ET.Element(
        "testcase",
        {
            "classname": suite_name(suite),
            "file": suite,
            "name": case.name,
            "time": f"{case.seconds:.3f}",
        },
    )
    diagnostic = "\n".join(case.diagnostics)
    if case.status == "not ok":
        failure = ET.SubElement(
            element,
            "failure",
            {"message": case.diagnostics[0] if case.diagnostics else "not ok"},
        )
        failure.text = diagnostic
    elif case.skipped:
        ET.SubElement(
            element,
            "skipped",
            {"message": case.diagnostics[0] if case.diagnostics else "skipped"},
        )
    return element


def build_suite(suite: str, cases: list[Case], timestamp: str) -> ET.Element:
    """Return the junit ``testsuite`` element for one bats file."""
    failures = sum(1 for case in cases if case.status == "not ok")
    skipped = sum(1 for case in cases if case.skipped)
    element = ET.Element(
        "testsuite",
        {
            "name": suite,
            "timestamp": timestamp,
            "tests": str(len(cases)),
            "failures": str(failures),
            "errors": "0",
            "skipped": str(skipped),
            "time": f"{sum(case.seconds for case in cases):.3f}",
        },
    )
    for case in cases:
        element.append(build_testcase(suite, case))
    return element


def build_parser() -> argparse.ArgumentParser:
    """Return the argument parser."""
    parser = argparse.ArgumentParser(
        description="Convert bats TAP output to junit XML (one SUITE=TAP pair per file).",
    )
    parser.add_argument(
        "-o",
        "--output",
        required=True,
        help="junit XML to write.",
    )
    parser.add_argument(
        "--timestamp",
        default="",
        help="ISO timestamp for each testsuite (default: now, UTC).",
    )
    parser.add_argument(
        "pairs",
        nargs="+",
        metavar="SUITE=TAP",
        help="a bats file and the TAP file its run produced.",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    """Write the junit report and return a process exit code."""
    args = build_parser().parse_args(argv)
    timestamp = args.timestamp or datetime.now(UTC).isoformat(timespec="seconds")

    root = ET.Element("testsuites")
    total = 0
    for pair in args.pairs:
        suite, sep, tap_path = pair.partition("=")
        if not sep or not suite or not tap_path:
            print(f"expected SUITE=TAPFILE, got {pair!r}", file=sys.stderr)
            return 2
        tap = Path(tap_path)
        if not tap.is_file():
            print(f"{tap}: no such TAP file", file=sys.stderr)
            return 2
        cases = parse_tap(tap.read_text(encoding="utf-8", errors="replace"))
        total += len(cases)
        root.append(build_suite(suite, cases, timestamp))

    out = Path(args.output)
    out.parent.mkdir(parents=True, exist_ok=True)
    ET.ElementTree(root).write(out, encoding="utf-8", xml_declaration=True)

    if total == 0:
        print(
            f"{out}: 0 test cases — the TAP files carry no case, which is a run that executed nothing, not a pass.",
            file=sys.stderr,
        )
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
