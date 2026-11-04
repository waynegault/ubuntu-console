"""Pytest configuration: serialize BATS suite execution and enforce timeouts.

BATS suites run shellcheck on all ~24 scripts and source the full tactical
profile.  Running multiple suites in parallel saturates CPU/disk and causes
hangs when the thread-based timeout cannot interrupt blocked I/O.
"""

from __future__ import annotations

import fcntl
import os
import sys
import tempfile
import time
from collections.abc import Callable, Generator, Iterable
from datetime import datetime
from pathlib import Path
from typing import Any, Protocol

import pytest

# pytest must NOT collect tests/test_bats_unittest.py.  That module is the stdlib
# runner: it generates one case per BATS suite FILE and runs each whole file, so
# collecting it here as well would run every suite a second time — the same suites,
# twice, in a session that is already ~30 min long.
#
# It is a variable in conftest rather than `collect_ignore` in pytest.ini because that
# key does not exist there: pytest 9.1.1 rejects it with --strict-config and
# "Unknown config option: collect_ignore" (measured 2026-09-24; `collect_ignore_glob`
# in the ini is rejected the same way and silently collects the file anyway).
collect_ignore = ["test_bats_unittest.py"]

_LOCK_DIR = Path(tempfile.gettempdir()) / "tac-pytest-bats-locks"
# Floor for the lock wait.  The wait is bounded by the BATS file's own timeout
# (see _serialize_bats_suites): concurrent runs of the same file must
# serialise, and a single invocation is allowed to run for up to that timeout.
# A shorter cap turned legitimate contention into spurious setup errors.
_MIN_LOCK_WAIT = 60


def _lock_pid_path(lock_path: Path) -> Path:
    """Return the companion pid file for a BATS lock."""
    return lock_path.with_suffix(lock_path.suffix + ".pid")


def has_conftest_is_stale_lock(lock_path: Path, pid_path: Path) -> bool:
    """Public alias for _is_stale_lock (exported for test_bats_lock_fixture.py)."""
    return _is_stale_lock(lock_path, pid_path)


def _proc_start_time(pid: int) -> str:
    """Return field 22 (starttime) from /proc/<pid>/stat, or '' if unavailable.

    The comm field can contain spaces and parentheses, so parse from the last
    ')' in the line rather than splitting the whole record.
    """
    try:
        data = Path(f"/proc/{pid}/stat").read_text(encoding="utf-8")
    except OSError:
        return ""
    rparen = data.rfind(")")
    if rparen < 0:
        return ""
    fields = data[rparen + 2 :].split()
    return fields[19] if len(fields) > 19 else ""


def _read_holder(pid_path: Path) -> tuple[int, str]:
    """Parse a holder record: '<pid>' (legacy) or '<pid> <starttime>'."""
    try:
        parts = pid_path.read_text(encoding="utf-8").split()
    except OSError:
        return 0, ""
    if not parts:
        return 0, ""
    try:
        pid = int(parts[0])
    except ValueError:
        return 0, ""
    return pid, (parts[1] if len(parts) > 1 else "")


def _is_stale_lock(lock_path: Path, pid_path: Path) -> bool:
    """Return True when the lock owner is gone, invalid, or a recycled PID."""
    if not pid_path.exists():
        return False
    pid, recorded_start = _read_holder(pid_path)
    if pid <= 0:
        return True
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return True
    except PermissionError:
        return False
    except OSError:
        return False
    # The PID is alive, but is it still the process that took the lock? PIDs
    # are recycled (notably across reboots, since the lock dir lives in /tmp);
    # a recorded start time that no longer matches means the original holder is
    # gone and its PID now belongs to an unrelated process.
    if recorded_start:
        current_start = _proc_start_time(pid)
        if current_start and current_start != recorded_start:
            return True
    return False


def _cleanup_stale_locks() -> None:
    """Remove lock files whose owning process is no longer alive."""
    if not _LOCK_DIR.is_dir():
        return
    for f in _LOCK_DIR.iterdir():
        if f.suffix == ".pid":
            lock_path = f.with_suffix("")
            if _is_stale_lock(lock_path, f):
                lock_path.unlink(missing_ok=True)
                f.unlink(missing_ok=True)


_cleanup_stale_locks()


def _is_vscode_discovery() -> bool:
    """Return True when pytest is running discovery (VS Code --collect-only)."""
    return "--collect-only" in __import__("sys").argv


# ═══════════════════════════════════════════════════════════════════════
# Heavy-job serialisation: a pytest run QUEUES, it does not starve
# ═══════════════════════════════════════════════════════════════════════
# bin/heavy-job exists because two lanes running mypy/pytest/kgraph together
# oversubscribe all 16 cores — its own header names pytest.  tools/run-tests.sh
# routes through it, but the test panel's runner does not, so a VS Code run
# competed with whatever heavy job already held the box: measured 2026-11-04, load
# average 181 while bin/autotune-rows.sh swept three models, every bridged suite
# 8-15x slower, and suites reported failed that pass in isolation.
#
# Taking the SAME lock makes such a run wait for its turn instead.  It is taken once,
# at collection, so the wait is charged to no test's timeout, and HEAVY_JOB_HELD is
# exported for the whole session: a heavy entry point invoked *inside* a test then
# passes through rather than blocking on the lock its own session holds.  That is
# bin/heavy-job's nested-invocation rule, and it is not an optimisation — flock is held
# per open file description, so a descendant taking the lock again would deadlock
# against its own session, not re-enter it.

_HEAVY_JOB_FD: int | None = None


class HeavyJobBusy(RuntimeError):
    """The box's heavy-job lock stayed held for the whole bounded wait."""


class _CleanupRegistrar(Protocol):
    """The one Config capability this module needs (tests pass a stub)."""

    def add_cleanup(self, func: Callable[[], None]) -> None: ...


def heavy_job_lock_path() -> Path:
    """Return the lock bin/heavy-job uses, read from the same variable it reads."""
    return Path(os.environ.get("HEAVY_JOB_LOCK", "/tmp/heavy-job.lock"))


def _holder_text(lock_path: Path) -> str:
    """The holder's advisory record, or '' when it cannot be read.

    Advisory only: the flock decides that the lock is busy, and this text only NAMES the
    process that took it, so an unreadable record must not make the wait fail.
    """
    try:
        return lock_path.read_text(encoding="utf-8").strip()
    except OSError:
        # swallow-ok: advisory as bin/heavy-job's own read says — an unreadable record means "no holder named", and the flock, never this text, decided the lock was busy
        return ""


def _is_interactive_runner() -> bool:
    """True for a VS Code Testing run, false for a terminal or CI pytest.

    The Python extension's ``run_pytest_script.py`` exports TEST_RUN_PIPE (and
    RUN_TEST_IDS_PIPE) for the run it spawns; nothing else does.  It names the runner in
    the wait's own line, so an operator reading the panel can tell which launch is queued.
    """
    return bool(os.environ.get("TEST_RUN_PIPE") or os.environ.get("RUN_TEST_IDS_PIPE"))


def heavy_job_wait_s() -> int:
    """How long this session queues for the heavy-job lock.

    An hour for every runner: that is the 2026-11-04 ruling — a panel run WAITS behind a
    heavy job instead of competing with it, and giving up is `bin/heavy-job`'s own
    ``--timeout`` contract, not the default here.  `TAC_HEAVY_JOB_WAIT_S` overrides it for
    a caller that would rather fail fast than queue.
    """
    return int(os.environ.get("TAC_HEAVY_JOB_WAIT_S", "3600"))


def acquire_heavy_job_lock(
    lock_path: Path, wait_s: int, owner: str, announce: Callable[[str], None] | None = None
) -> int:
    """Take the heavy-job lock, waiting up to ``wait_s`` seconds.

    Raises :class:`HeavyJobBusy` rather than hanging: a bounded poll is what lets the
    message name the job still holding the box instead of dying at the harness timeout.

    *announce* is called once, with the holder's own advisory record, if the first
    attempt finds the lock busy.  The VS Code Testing panel shows nothing while a
    collection-time wait runs, so without it an interactive run sits silent for the whole
    bound and reads as hung (measured 2026-11-04: a panel run queued behind
    tools/run-tests.sh and ran no test for six minutes).
    """
    deadline = time.monotonic() + wait_s
    announced = False
    while True:
        fd = os.open(lock_path, os.O_RDWR | os.O_CREAT | os.O_CLOEXEC, 0o644)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            os.close(fd)
            if not announced:
                announced = True
                if announce is not None:
                    announce(_holder_text(lock_path))
            if time.monotonic() >= deadline:
                raise HeavyJobBusy(
                    f"the heavy-job lock {lock_path} was still held after {wait_s}s"
                    + (f" (holder: {_holder_text(lock_path)})" if _holder_text(lock_path) else "")
                ) from None
            time.sleep(1)
            continue
        # Advisory record in bin/heavy-job's own format, so its --status attributes the
        # box to this session rather than to the previous holder.
        started = datetime.now().astimezone().isoformat(timespec="seconds")
        os.ftruncate(fd, 0)
        os.write(fd, f"pid={os.getpid()} started={started} cmd={owner}\n".encode())
        return fd


def release_heavy_job_lock(fd: int) -> None:
    """Release and close a lock returned by :func:`acquire_heavy_job_lock`."""
    fcntl.flock(fd, fcntl.LOCK_UN)
    os.close(fd)


def _is_bats_item(item: Any) -> bool:
    """Return True for a test item carrying any ``bats*`` marker."""
    return any(marker.name.startswith("bats") for marker in item.iter_markers())


def ensure_heavy_job_session(
    config: _CleanupRegistrar,
    items: Iterable[Any],
    *,
    collect_only: bool = False,
) -> None:
    """Queue this session behind any heavy job holding the box, once.

    No-op when the selection carries no BATS suite (pure-Python runs are not
    saturating), during discovery, or when an enclosing job already holds the lock.
    """
    global _HEAVY_JOB_FD
    if _HEAVY_JOB_FD is not None:
        return
    if collect_only or os.environ.get("HEAVY_JOB_HELD"):
        return
    if not any(_is_bats_item(item) for item in items):
        return

    wait_s = heavy_job_wait_s()
    owner = f"pytest {' '.join(sys.argv[1:])}"[:160]
    lock_path = heavy_job_lock_path()

    def _announce(holder: str) -> None:
        # Stderr and unbuffered: a collection-time wait produces no test output, so this
        # line is the only thing that says the run is QUEUED rather than hung.
        runner = "VS Code panel" if _is_interactive_runner() else "pytest"
        print(
            f"heavy-job: {runner} queued behind {holder or 'an unnamed holder'} — waiting up to {wait_s}s",
            file=sys.stderr,
            flush=True,
        )

    try:
        _HEAVY_JOB_FD = acquire_heavy_job_lock(lock_path, wait_s, owner, announce=_announce)
    except HeavyJobBusy as exc:
        pytest.exit(
            f"heavy-job: {exc}\nheavy-job: refusing to start a saturating run beside it — see `bin/heavy-job --status`",
            returncode=3,
        )
    os.environ["HEAVY_JOB_HELD"] = "1"
    config.add_cleanup(_release_heavy_job_session)


def _release_heavy_job_session() -> None:
    """Release the session's heavy-job lock, if this session took one."""
    global _HEAVY_JOB_FD
    if _HEAVY_JOB_FD is not None:
        release_heavy_job_lock(_HEAVY_JOB_FD)
        _HEAVY_JOB_FD = None


def pytest_collection_finish(session: pytest.Session) -> None:
    """Gate a BATS-carrying SELECTION behind the box's heavy-job lock.

    Deliberately NOT pytest_collection_modifyitems: that hook sees every item the
    session COLLECTED, before -k/--deselect remove any, and importing
    tests/test_bats_bridge.py registers one item per BATS case (~1000 of them) in
    ``globals()``.  So a `-k one_python_test` selection collected the whole BATS table
    and queued for the heavy-job lock anyway — measured 2026-11-04, a one-test Python run
    waiting behind a full tools/run-tests.sh.  ``session.items`` here is the selection
    after deselection, which is what the gate's "no BATS item, no queue" rule means.
    """
    ensure_heavy_job_session(session.config, session.items, collect_only=_is_vscode_discovery())


@pytest.fixture(autouse=True)
def _serialize_bats_suites(request: pytest.FixtureRequest):
    """Acquire a per-BATS-file lock so BATS suites never run concurrently.

    Only gates suites that carry a ``bats`` marker — pure-Python tests are
    not serialised.

    The lock name is derived from the **BATS file's stem** (not the test file's
    stem), so different BATS files (unit, integration, tactical-console) can
    run concurrently without blocking each other.
    """
    # Skip entirely during VS Code test discovery
    if _is_vscode_discovery():
        yield
        return

    is_bats = _is_bats_item(request.node)
    if not is_bats:
        yield
        return

    _LOCK_DIR.mkdir(mode=0o700, exist_ok=True)

    # Read _bats_file / _bats_timeout from the test function's own attributes
    # (set by test_bats_bridge.py's _make_test).  For a bridged BATS case the
    # budget is the FILE-level one, because a whole-file run holds this lock for
    # the whole file.  Falls back to the old callspec.params path for any
    # remaining parametrized BATS tests.
    fn = request.node.function
    bats_file: Path | None = getattr(fn, "_bats_file", None)
    timeout_s: int = getattr(fn, "_bats_timeout", 60)
    if bats_file is None and hasattr(request.node, "callspec"):
        bats_file = request.node.callspec.params.get("bats_file")
        timeout_s = int(request.node.callspec.params.get("timeout_s", 60))

    lock_name = Path(bats_file).stem if bats_file else Path(request.path).stem
    lock_path = _LOCK_DIR / f"{lock_name}.lock"
    pid_path = _lock_pid_path(lock_path)

    wait_s = max(_MIN_LOCK_WAIT, timeout_s)
    deadline = time.monotonic() + wait_s
    fd: int | None = None
    while True:
        # Open a fresh fd every attempt so a stale-cleanup unlink below never
        # leaves us flocking an unlinked inode that a third process has since
        # replaced with a new file (which would break mutual exclusion).
        fd = os.open(lock_path, os.O_RDWR | os.O_CREAT | os.O_CLOEXEC, 0o600)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            break
        except BlockingIOError:
            os.close(fd)
            fd = None
            if _is_stale_lock(lock_path, pid_path):
                lock_path.unlink(missing_ok=True)
                pid_path.unlink(missing_ok=True)
                continue
            if time.monotonic() > deadline:
                holder_pid = "unknown"
                try:
                    holder_pid = pid_path.read_text(encoding="utf-8").strip()
                except OSError:
                    pass
                pytest.fail(
                    f"Could not acquire BATS serialisation lock within "
                    f"{wait_s}s — another BATS suite may be hung. "
                    f"Check for stale processes holding {lock_path} "
                    f"(lock owner pid: {holder_pid})"
                )
            time.sleep(1)
    # Record the holder only after acquisition, so the pid file identifies
    # the actual lock owner for stale detection and error messages.  The
    # process start time is stored alongside the pid so a recycled PID is
    # detected as stale rather than mistaken for a live holder.
    _self_pid = os.getpid()
    pid_path.write_text(f"{_self_pid} {_proc_start_time(_self_pid)}".strip(), encoding="utf-8")
    try:
        yield
    finally:
        if fd is not None:
            fcntl.flock(fd, fcntl.LOCK_UN)
            os.close(fd)
        pid_path.unlink(missing_ok=True)


# ═══════════════════════════════════════════════════════════════════════
# Duration tracking + regression detection
# ═══════════════════════════════════════════════════════════════════════
# Stores per-test durations in .pytest_cache/tac-durations.json and
# warns when a test is >2x slower than its historical baseline.

_DURATIONS_FILE = Path(".pytest_cache/tac-durations.json")
_DURATIONS: dict[str, list[float]] = {}
_REGRESSION_THRESHOLD = 2.0  # warn if duration exceeds baseline × this


def _load_durations() -> dict[str, list[float]]:
    """Load historical duration baselines from cache."""
    path = Path(__file__).resolve().parent.parent / _DURATIONS_FILE
    if not path.exists():
        return {}
    try:
        import json

        return json.loads(path.read_text(encoding="utf-8"))
    except OSError, ValueError:
        return {}


def _save_durations(durations: dict[str, list[float]]) -> None:
    """Persist duration baselines to cache."""
    import json

    path = Path(__file__).resolve().parent.parent / _DURATIONS_FILE
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(durations, indent=2), encoding="utf-8")


def _collect_duration(item: pytest.Item, duration_s: float) -> None:
    """Record a test duration and flag regressions."""
    # A bridged BATS case reports its own TAP duration ("in 2033ms").  Its wall
    # clock here is not a per-case measurement: the first case of a file carries
    # that file's whole-file BATS run, and every later case is a cache lookup near
    # zero.  Prefer the reported figure when the test provided one.
    reported = getattr(item, "_bats_case_seconds", None)
    if reported is not None:
        duration_s = reported
    key = f"{item.nodeid.split('::')[0]}::{getattr(item, 'originalname', None) or item.name}"
    _DURATIONS.setdefault(key, []).append(duration_s)


def _check_regression(item: pytest.Item, duration_s: float) -> str | None:
    """Return a warning string if *duration_s* is a significant regression."""
    baselines = _load_durations()
    key = f"{item.nodeid.split('::')[0]}::{getattr(item, 'originalname', None) or item.name}"
    history = baselines.get(key)
    if not history or len(history) < 2:
        return None
    # Use median of historical runs as the stable baseline
    sorted_hist = sorted(history)
    median = sorted_hist[len(sorted_hist) // 2]
    ratio = duration_s / median if median > 0 else 0
    if ratio > _REGRESSION_THRESHOLD:
        return f"\033[33m⚠ {key} took {duration_s:.1f}s ({ratio:.1f}× historical median {median:.1f}s)\033[0m"
    return None


@pytest.hookimpl(hookwrapper=True)
def pytest_runtest_protocol(item: pytest.Item) -> Generator[None, None, None]:
    """Wrap each test to capture its wall-clock duration."""
    import time as _time

    start = _time.monotonic()
    yield
    elapsed = _time.monotonic() - start
    if not _is_vscode_discovery():
        _collect_duration(item, elapsed)
        warning = _check_regression(item, elapsed)
        if warning:
            import sys as _sys

            print(warning, file=_sys.stderr)


def pytest_sessionfinish(session: pytest.Session) -> None:
    """Persist accumulated durations at the end of a successful run."""
    if not _is_vscode_discovery() and _DURATIONS:
        baselines = _load_durations()
        for key, times in _DURATIONS.items():
            baselines.setdefault(key, []).extend(times)
            # Keep only the last 20 runs to avoid unbounded growth
            baselines[key] = baselines[key][-20:]
        _save_durations(baselines)
