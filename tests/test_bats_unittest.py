"""Run the BATS suites through the standard library's unittest.

WHY THIS EXISTS: tests/test_bats_bridge.py gives pytest one test per BATS ``@test``
case, and pytest was the only way in.  On 2026-09-23 the apt ``python3-pytest`` was
removed from this box and PEP 668 blocked a pip replacement for the system
interpreter, so an interpreter with bats but no pytest had no way to run the suites at
all.  This module is that path, and it reads the same suite table the pytest bridge
reads (tests/bats-suites.tsv, parsed by tests/_bats_suites.py), so neither the suite
list nor the timeouts are stated twice.

GRANULARITY, stated because it is a real difference from the pytest bridge: a case
here is a suite FILE, not a BATS case, and a failure reports the file, its exit status,
the failing cases from its TAP output and the run's last lines.  Per-case granularity
would mean either one ``bats`` spawn per case — the fixed cost is ~8.8 s each, measured
on tests/tactical-console.bats, where eight filtered invocations took 69.0 s against
7.5 s as one whole-file run — or re-implementing the pytest bridge's whole-file cache,
which is the piece of it that took the most work to get right and the last thing that
should exist in two places.

EXCLUDED BY DEFAULT: 04-llama-cpp-inventory (live downloads; mutates the host) and
12-gpu-exclusivity (takes the CUDA card lock this box shares with the investigator — a
test run must never be the reason a measurement is refused).  CI excludes the same two
files for the same reasons.  Each exclusion is a SKIP that states its reason rather
than a case that quietly does not exist, and ``TAC_UNITTEST_ALL=1`` runs them too.

COST: the whole set is the 20-40 min the suites cost anywhere — one whole-file run of
tests/tactical-console.bats alone is ~11-35 min.  ``unittest discover`` picks this
module up (the name matches ``test*.py``), so a bare discover runs the suites as well;
select a single one with ``python -m unittest test_bats_unittest.BatsSuites.<method>``
from the tests/ directory.
"""
from __future__ import annotations

import os
import re
import signal
import subprocess
import time
import unittest
from collections.abc import Callable
from pathlib import Path

import _bats_suites

REPO_ROOT = _bats_suites.REPO_ROOT
BATS_EXECUTABLE = "bats"
TESTS_DIR = REPO_ROOT / "tests"
# Set to 1 to run the suites that are excluded by default (see the module docstring).
RUN_ALL_ENV = "TAC_UNITTEST_ALL"

# Keyed by file stem, with the reason CI excludes the same file.  An entry whose file
# has left the table skips nothing and runs nothing, which is why it is a name here
# rather than a pattern: the skip says which file it is about.
_EXCLUDED_BY_DEFAULT = {
    "04-llama-cpp-inventory": "performs live downloads and mutates the host",
    "12-gpu-exclusivity": "takes the CUDA card lock this box shares with the investigator",
}

# bats' own naming of a case that failed: "not ok 7 name in 12ms" (--tap).
_FAILED_CASE_RE = re.compile(r"^not ok \d+ (.*)$", re.MULTILINE)
# How long a case may refuse to die between SIGTERM and SIGKILL.
_GROUP_STOP_GRACE_S = 5


def _stop_process_group(pid: int) -> None:
    """Take a timed-out run's whole process group down: SIGTERM, then SIGKILL.

    Group-wide on purpose: bats starts each case's own subprocesses, so signalling only
    the bats process would leave those behind on a box these suites share.  The wait
    polls the GROUP rather than calling ``wait()``, because nothing is draining the
    child's output pipe here and a full pipe would block it forever instead of exiting.
    """
    try:
        pgid = os.getpgid(pid)
    except OSError:
        return
    for sig in (signal.SIGTERM, signal.SIGKILL):
        try:
            os.killpg(pgid, sig)
        except OSError:
            return
        deadline = time.monotonic() + _GROUP_STOP_GRACE_S
        while time.monotonic() < deadline:
            try:
                os.killpg(pgid, 0)
            except OSError:
                return
            time.sleep(0.25)


def _run_suite(path: Path, timeout_s: int) -> tuple[int, str]:
    """Run one suite file whole.  Returns (returncode, combined output).

    The run gets its own session so a timeout can take the whole group down; *timeout_s*
    is the file budget from tests/bats-suites.tsv, which is why a hung case cannot hang
    the run.
    """
    env = os.environ.copy()
    env.setdefault("TERM", "xterm-256color")
    cmd = [BATS_EXECUTABLE, "--tap", str(path)]
    proc = subprocess.Popen(
        cmd,
        cwd=REPO_ROOT,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        env=env,
        start_new_session=True,
    )
    try:
        out, _ = proc.communicate(timeout=timeout_s)
    except subprocess.TimeoutExpired:
        _stop_process_group(proc.pid)
        out, _ = proc.communicate()
        raise AssertionError(
            f"{path.relative_to(REPO_ROOT)} did not finish within its {timeout_s}s "
            f"whole-file budget (tests/bats-suites.tsv) and was stopped.\n"
            f"{_failure_detail(out)}"
        ) from None
    return proc.returncode, out


def _failure_detail(tap_output: str) -> str:
    """What to show when a suite file does not exit 0.

    The failing cases from TAP, plus the run's last lines: a suite that died before
    emitting any ``not ok`` — bats refusing to parse the file, a missing tool — has only
    that output to explain itself.
    """
    failed = [f"  not ok {name}" for name in _FAILED_CASE_RE.findall(tap_output)]
    if not failed:
        failed = ["  (no 'not ok' line — the run did not get that far)"]
    tail = tap_output.splitlines()[-15:]
    return "\n".join([*failed, "", f"  last {len(tail)} line(s):", *(f"  {ln}" for ln in tail)])


def _case_id(path: Path) -> str:
    """A unique method name for one suite file.

    The path below tests/ is used, not the bare stem, because two files in different
    directories may share a stem — and two setattr calls landing on one name would drop
    a suite silently, which is the failure this whole table exists to prevent.
    """
    return "test_" + re.sub(r"[^0-9a-zA-Z_]", "_", path.relative_to(TESTS_DIR).with_suffix("").as_posix())


def _make_case(suite: _bats_suites.BatsSuite, path: Path) -> Callable[[unittest.TestCase], None]:
    """Generate one unittest case that runs *path* as a whole file."""

    def _case(self: unittest.TestCase) -> None:
        excluded = _EXCLUDED_BY_DEFAULT.get(path.stem)
        if excluded is not None and os.environ.get(RUN_ALL_ENV) != "1":
            self.skipTest(f"excluded by default: {excluded} (set {RUN_ALL_ENV}=1 to run it)")
        returncode, output = _run_suite(path, suite.file_timeout_s)
        if returncode != 0:
            self.fail(f"{path.relative_to(REPO_ROOT)} exited {returncode}\n{_failure_detail(output)}")

    _case.__doc__ = (
        f"{suite.marker} — {path.relative_to(REPO_ROOT)} "
        f"(whole-file budget {suite.file_timeout_s}s, per case {suite.per_case_timeout_s}s)"
    )
    return _case


class BatsSuites(unittest.TestCase):
    """One generated case per suite file in tests/bats-suites.tsv.

    The methods are attached below rather than written out, because the file list is
    data: a hand-written method list would be a second copy of the table, and the copies
    would drift the first time a suite was added.
    """


for _suite, _path in _bats_suites.suite_files():
    _id = _case_id(_path)
    if hasattr(BatsSuites, _id):
        raise RuntimeError(
            f"two suite files generate the same unittest id {_id!r}; the ids come from "
            f"paths below tests/, so this means two files with the same relative path"
        )
    setattr(BatsSuites, _id, _make_case(_suite, _path))


if __name__ == "__main__":
    unittest.main()
