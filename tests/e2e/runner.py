"""Standalone CLI and programmatic test runner for E2E tests.

Usage:
    python3 -m tests.e2e.runner --tier 1
    python3 -m tests.e2e.runner --tier all -v
    python3 -m tests.e2e.runner --feature F7
    python3 -m tests.e2e.runner --help
"""

from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path
from typing import Sequence
import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent.parent

TIER_FILES = {
    "1": "tests/e2e/test_tier1_feature_coverage.py",
    "2": "tests/e2e/test_tier2_boundary_corner.py",
    "3": "tests/e2e/test_tier3_cross_feature.py",
    "4": "tests/e2e/test_tier4_workloads.py",
}


def build_pytest_args(
    tier: str = "all",
    feature: str | None = None,
    verbose: bool = False,
    quiet: bool = False,
    keyword: str | None = None,
    durations: int | None = None,
    failfast: bool = False,
    extra_args: Sequence[str] | None = None,
) -> list[str]:
    """Construct pytest argument list for E2E execution."""
    args: list[str] = ["-W", "error"]

    # Target selection
    if tier in TIER_FILES:
        target_path = REPO_ROOT / TIER_FILES[tier]
        if target_path.exists():
            args.append(str(target_path))
        else:
            # Fall back to e2e directory with tier marker
            args.append(str(REPO_ROOT / "tests/e2e"))
            tier_marker = f"tier{tier}"
            args.extend(["-m", tier_marker])
    else:
        # tier == "all"
        args.append(str(REPO_ROOT / "tests/e2e"))

    # Feature filter
    feature_expr: str | None = None
    if feature:
        clean_feat = feature.strip().lower()
        if clean_feat.startswith("f") and clean_feat[1:].isdigit():
            feat_num = clean_feat[1:]
            feature_expr = f"f{feat_num} or F{feat_num}"
        else:
            feature_expr = feature.strip()

    if keyword and feature_expr:
        args.extend(["-k", f"({keyword}) and ({feature_expr})"])
    elif keyword:
        args.extend(["-k", keyword])
    elif feature_expr:
        args.extend(["-k", feature_expr])

    if verbose:
        args.append("-v")
    if quiet:
        args.append("-q")
    if failfast:
        args.append("-x")
    if durations is not None and durations > 0:
        args.append(f"--durations={durations}")

    if extra_args:
        args.extend(extra_args)

    return args


def run_e2e_tests(
    tier: str = "all",
    feature: str | None = None,
    verbose: bool = False,
    quiet: bool = False,
    keyword: str | None = None,
    durations: int | None = None,
    failfast: bool = False,
    extra_args: Sequence[str] | None = None,
) -> int:
    """Run E2E test suite programmatically."""
    args = build_pytest_args(
        tier=tier,
        feature=feature,
        verbose=verbose,
        quiet=quiet,
        keyword=keyword,
        durations=durations,
        failfast=failfast,
        extra_args=extra_args,
    )
    # Ensure current working directory is repo root
    os.chdir(str(REPO_ROOT))

    result = pytest.main(args)

    # Map pytest ExitCode to project specification
    # 0 = Pass, 1 = Assertion fail, 2 = Usage/config error, 3 = Abort/timeout/warning
    if result == pytest.ExitCode.OK:
        return 0
    if result == pytest.ExitCode.TESTS_FAILED:
        return 1
    if result in (pytest.ExitCode.INTERRUPTED, pytest.ExitCode.USAGE_ERROR):
        return 2
    if result == pytest.ExitCode.INTERNAL_ERROR:
        return 3
    if result == pytest.ExitCode.NO_TESTS_COLLECTED:
        return 0
    return int(result)


def create_parser() -> argparse.ArgumentParser:
    """Create command-line argument parser."""
    parser = argparse.ArgumentParser(
        prog="python -m tests.e2e.runner",
        description="E2E Test Runner for Tactical Console Box Awareness & Architecture Suite",
    )
    parser.add_argument(
        "--tier",
        choices=["1", "2", "3", "4", "all"],
        default="all",
        help="Run specific test tier (default: all)",
    )
    parser.add_argument(
        "--feature",
        type=str,
        default=None,
        help="Filter tests by feature identifier (F1 through F25)",
    )
    parser.add_argument(
        "-v",
        "--verbose",
        action="store_true",
        help="Verbose test execution output",
    )
    parser.add_argument(
        "-q",
        "--quiet",
        action="store_true",
        help="Quiet test execution output",
    )
    parser.add_argument(
        "-k",
        "--keyword",
        type=str,
        default=None,
        help="Pass keyword expression to pytest",
    )
    parser.add_argument(
        "--durations",
        type=int,
        default=None,
        metavar="N",
        help="Show N slowest test durations",
    )
    parser.add_argument(
        "-x",
        "--failfast",
        action="store_true",
        help="Exit immediately on first test failure",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Print pytest invocation arguments and exit without running",
    )
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    """CLI entry point for tests.e2e.runner."""
    parser = create_parser()
    args, unknown = parser.parse_known_args(argv)

    if args.dry_run:
        pytest_args = build_pytest_args(
            tier=args.tier,
            feature=args.feature,
            verbose=args.verbose,
            quiet=args.quiet,
            keyword=args.keyword,
            durations=args.durations,
            failfast=args.failfast,
            extra_args=unknown,
        )
        print("Dry-run pytest command: pytest " + " ".join(pytest_args))
        return 0

    return run_e2e_tests(
        tier=args.tier,
        feature=args.feature,
        verbose=args.verbose,
        quiet=args.quiet,
        keyword=args.keyword,
        durations=args.durations,
        failfast=args.failfast,
        extra_args=unknown,
    )


if __name__ == "__main__":
    sys.exit(main())
