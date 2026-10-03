"""Tests for the WSL restart probe's verifiable core (`oc restart-check`).

The probe's INPUTS are live /proc and nvidia-smi, so what a unit test pins is not a
measurement but the decision it feeds: which findings block a restart, that a
self-healing lane is not one of them, that an unreadable probe is never a clearance,
and the exit codes the contract publishes (0 safe, 1 not safe, 2 could not measure —
`docs/contracts/command-contracts.yaml`, entry `oc-restart-check`).

The exit-code criterion is the probe's own docstring: "a probe that cannot see is not
a probe that says 'fine'".  The regression case at the bottom is the one that can
disagree with a real defect: the self-exclusion used to key on the filename literal
`restart-safety.py`, which the rename to `oc-restart-check.py` (commit 6d44d0c8)
silently orphaned — so it no longer excluded a concurrent copy of the probe, and the
old code FAILS that case.

The module is a hyphenated script (this repo's ``scripts/*.py`` convention), so it is
loaded by path rather than imported by name.
"""

from __future__ import annotations

import json
import os
import sys
from types import SimpleNamespace
from typing import Any

import pytest

from _probe_paths import load_probe

probe = load_probe("oc_restart_check", "oc-restart-check.py")


def _report(**over: Any) -> Any:
    """A Report with every probe field empty unless overridden."""
    kwargs: dict[str, Any] = {
        "workers": [],
        "work": [],
        "lanes": [],
        "foreign_gpu": [],
        "unreadable": [],
    }
    kwargs.update(over)
    return probe.Report(**kwargs)


# --- the verdict ------------------------------------------------------------
# The words asserted here ARE the contract (output_shape: "named blockers, or an
# all-clear line"): a reader (and `oc restart-check && sudo shutdown`) decides on the
# verdict line, so a case that could not tell SAFE from NOT SAFE would be worthless.


def test_empty_report_is_safe() -> None:
    # Catches: a probe that can never say "go" (a permanent false-negative).
    report = _report()
    assert report.safe is True
    assert "SAFE to restart" in probe.render(report)


def test_ci_worker_is_a_blocker_named_in_the_verdict() -> None:
    # Catches: a self-hosted runner job hidden from the verdict, so a restart kills it
    # and reads as a cancellation in that repo's CI history.
    report = _report(workers=["pid=1 cwd=/x /home/y/Runner.Worker"])
    assert report.safe is False
    rendered = probe.render(report)
    assert "NOT SAFE to restart" in rendered
    assert "[ci-worker]" in rendered
    assert "Runner.Worker" in rendered


def test_in_flight_work_is_a_blocker_named_in_the_verdict() -> None:
    # Catches: a running bench/test losing its verdict to an unexplained death.
    report = _report(work=["pid=2 cwd=/repo: pytest -q"])
    assert report.safe is False
    rendered = probe.render(report)
    assert "[in-flight-work]" in rendered
    assert "pytest" in rendered


def test_foreign_gpu_holder_is_a_blocker_named_in_the_verdict() -> None:
    # Catches: another session's GPU run interrupted by our restart.
    report = _report(foreign_gpu=["pid=3 python train.py"])
    assert report.safe is False
    assert "[foreign-gpu]" in probe.render(report)


def test_our_own_self_healing_lane_is_not_a_blocker() -> None:
    # Catches: the watchdog-managed lane reported as a foreign holder, which inverts
    # the verdict — a restart is exactly what those lanes survive.
    report = _report(lanes=["pid=4 llama-server --port 8080"])
    assert report.safe is True
    assert "SAFE to restart" in probe.render(report)


def test_an_unreadable_probe_is_never_a_clearance() -> None:
    # The docstring's rule: a probe that cannot see must not read as an empty box.
    report = _report(unreadable=["nvidia-smi could not be run: [Errno 2]"])
    assert report.safe is False
    rendered = probe.render(report)
    assert "CANNOT SAY" in rendered
    assert "SAFE to restart" not in rendered


# --- exit codes (a caller runs `oc restart-check && sudo shutdown`) ----------


def test_main_exits_zero_only_when_safe(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(probe, "gather", lambda: _report())
    monkeypatch.setattr(sys, "argv", ["oc-restart-check.py"])
    assert probe.main([]) == 0


def test_main_exits_one_when_a_blocker_is_present(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(probe, "gather", lambda: _report(work=["pid=2 cwd=/repo: pytest -q"]))
    assert probe.main([]) == 1


def test_main_exits_two_when_a_probe_could_not_run(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # Precedence, pinned: an unmeasurable probe is 2 even when a blocker was also seen,
    # because "could not measure" is the weaker claim and must win for a shell `&&`.
    monkeypatch.setattr(
        probe,
        "gather",
        lambda: _report(work=["pid=2 cwd=/repo: pytest -q"], unreadable=["nvidia-smi: ENOENT"]),
    )
    assert probe.main([]) == 2


def test_json_mode_carries_the_same_verdict(monkeypatch: pytest.MonkeyPatch, capsys: Any) -> None:
    # Catches: a --json consumer (a script) seeing a different answer than the human.
    monkeypatch.setattr(probe, "gather", lambda: _report(workers=["pid=1 cwd=/x Runner.Worker"]))
    rc = probe.main(["--json"])
    payload = json.loads(capsys.readouterr().out)
    assert rc == 1
    assert payload["safe"] is False
    assert payload["blockers"] == [
        {"kind": "ci-worker", "detail": "pid=1 cwd=/x Runner.Worker"}
    ]


def test_help_exits_zero(capsys: Any) -> None:
    # Catches: `--help` reaching the probes (and touching /proc) or exiting non-zero.
    assert probe.main(["--help"]) == 0
    assert "Exit codes" in capsys.readouterr().out


# --- the self-exclusion regression (commit 6d44d0c8 renamed the file) -------


def _scan_one(monkeypatch: pytest.MonkeyPatch, argv: list[str]) -> Any:
    """Run scan_work over exactly one synthetic process with this argv."""
    monkeypatch.setattr(probe, "_pids", lambda: [4242])
    monkeypatch.setattr(probe, "_argv", lambda pid: argv)
    monkeypatch.setattr(probe, "_cwd", lambda pid: "/x")
    report = _report()
    probe.scan_work(report)
    return report


def test_scan_work_excludes_a_concurrent_copy_of_this_probe(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # Catches the rename defect directly: a second copy of the probe, invoked while its
    # cmdline carries a marker word, must not be reported as the work it looks for.
    # The old `a.endswith("restart-safety.py")` literal failed this case.
    report = _scan_one(
        monkeypatch, ["/usr/bin/python3", "/tmp/copy/oc-restart-check.py", "pytest"]
    )
    assert report.work == []
    assert report.safe is True


def test_scan_work_still_reports_a_marker_process_under_another_name(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # The control for the case above: the exclusion must be narrow, or it would hide
    # real work (a different script whose cmdline mentions a marker).
    report = _scan_one(monkeypatch, ["/usr/bin/python3", "/tmp/copy/other.py", "pytest"])
    assert len(report.work) == 1
    assert report.safe is False


def test_self_name_is_this_script_not_a_stale_literal() -> None:
    # The literal can only be right if it is this file's own name.
    assert probe.SELF_NAME == "oc-restart-check.py"


# --- /proc readers ----------------------------------------------------------
# Criterion: each reader returns the kernel value it names, and an UNREADABLE value
# is reported as absent ("?" / 0 / []) rather than guessed - the docstring's rule that
# a probe which cannot see must not read as an empty box.  Where a real pid works the
# test uses one; the unreadable arm uses a pid that cannot exist.


def _missing_pid() -> int:
    """A pid that is not in /proc (max pid is bounded well below this)."""
    return 2**30


def test_argv_and_cwd_read_a_real_process() -> None:
    pid = os.getpid()
    argv = probe._argv(pid)
    assert argv and argv[0]
    assert isinstance(probe._cwd(pid), str)


def test_argv_cwd_ppid_degrade_when_the_process_is_gone() -> None:
    # Catches: a reader that raises (crashing the whole probe) or invents a value on a
    # pid it cannot read - here, a process that has exited between the two reads.
    gone = _missing_pid()
    assert probe._argv(gone) == []
    assert probe._cwd(gone) == "?"
    assert probe._ppid(gone) == 0


def test_ppid_reads_a_real_parent() -> None:
    ppid = probe._ppid(os.getpid())
    assert isinstance(ppid, int)
    assert ppid >= 0


def test_parent_is_systemd_true_from_exe(monkeypatch: pytest.MonkeyPatch) -> None:
    # Catches: the exe fast path not recognising the service manager, which would
    # report our own self-healing lanes as foreign holders and invert the verdict.
    fake_os = SimpleNamespace(path=os.path, readlink=lambda _p: "/usr/lib/systemd/systemd")
    monkeypatch.setattr(probe, "os", fake_os)
    assert probe._parent_is_systemd(4242) is True


def test_parent_is_systemd_false_for_a_non_systemd_parent(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    fake_os = SimpleNamespace(path=os.path, readlink=lambda _p: "/usr/bin/python3")
    monkeypatch.setattr(probe, "os", fake_os)
    # /proc/<this test process>/comm is the interpreter, so the fallback answers False.
    assert probe._parent_is_systemd(os.getpid()) is False


def test_parent_is_systemd_falls_back_to_comm_when_exe_is_unreadable(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # The load-bearing fallback (docstring): the user manager's /proc/PID/exe is EACCES
    # for an ordinary reader, so exe being unreadable must fall through to comm.
    def _raise(_p: str) -> str:
        raise OSError(13, "permission denied")

    fake_os = SimpleNamespace(path=os.path, readlink=_raise)
    monkeypatch.setattr(probe, "os", fake_os)
    # pid 1 is the systemd service manager on this box; its comm is readable.
    assert probe._parent_is_systemd(1) is True


def test_is_systemd_managed_uses_the_parent(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(probe, "_ppid", lambda pid: 1)
    monkeypatch.setattr(probe, "_parent_is_systemd", lambda parent: True)
    assert probe._is_systemd_managed(50) is True
    monkeypatch.setattr(probe, "_ppid", lambda pid: 0)
    assert probe._is_systemd_managed(50) is False
    monkeypatch.setattr(probe, "_ppid", lambda pid: 123)
    monkeypatch.setattr(probe, "_parent_is_systemd", lambda parent: False)
    assert probe._is_systemd_managed(50) is False


def test_pids_are_sorted_ints_and_include_this_process() -> None:
    pids = probe._pids()
    assert pids == sorted(pids)
    assert all(isinstance(p, int) for p in pids)
    assert os.getpid() in pids


# --- scanners over a fixture process table ----------------------------------


def _argv_map(monkeypatch: pytest.MonkeyPatch, mapping: dict[int, list[str]]) -> None:
    monkeypatch.setattr(probe, "_pids", lambda: [probe.SELF, *mapping])
    monkeypatch.setattr(probe, "_argv", lambda pid: mapping.get(pid, []))
    monkeypatch.setattr(probe, "_cwd", lambda pid: "/cwd")


def test_scan_workers_matches_argv0_and_excludes_itself(monkeypatch: pytest.MonkeyPatch) -> None:
    # Catches: a worker hidden from the report (a runner job killed by the restart reads
    # as a cancellation), and the probe reporting itself as a worker.
    _argv_map(monkeypatch, {
        4242: ["/home/runner/Runner.Worker"],
        4243: ["/usr/bin/python3", "Runner.Worker"],  # marker NOT in argv[0]
    })
    report = _report()
    probe.scan_workers(report)
    assert report.workers == ["pid=4242 cwd=/cwd /home/runner/Runner.Worker"]


def test_scan_work_skips_empty_and_unrelated_then_reports_a_marker(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # Catches: an unrelated process reported as work (a false blocker) and real bench
    # work missed (a false clearance).
    _argv_map(monkeypatch, {
        5001: [],                                   # nothing to read
        5002: ["/bin/cat", "notes.txt"],            # no marker
        5003: ["/usr/bin/python3", "bench-rows.sh"],  # marker in the command line
    })
    report = _report()
    probe.scan_work(report)
    assert len(report.work) == 1
    assert "bench-rows.sh" in report.work[0]


def _fake_subprocess_run(returncode: int = 0, stdout: str = "", stderr: str = "",
                         raise_exc: Exception | None = None) -> Any:
    module = type(sys)("subprocess")

    class SubprocessError(Exception):
        pass

    module.SubprocessError = SubprocessError  # type: ignore[attr-defined]

    class Proc:
        def __init__(self) -> None:
            self.returncode = returncode
            self.stdout = stdout
            self.stderr = stderr

    def run(*args: Any, **kwargs: Any) -> Any:
        if raise_exc is not None:
            raise raise_exc
        return Proc()

    module.run = run  # type: ignore[attr-defined]
    return module


def test_scan_gpu_splits_lanes_from_foreign_holders(monkeypatch: pytest.MonkeyPatch) -> None:
    # Catches: our self-healing lanes counted as blockers (inverting the verdict) or
    # another session's holder counted as benign (a destructive restart).
    monkeypatch.setattr(probe, "subprocess", _fake_subprocess_run(stdout="111\n222\n"))
    monkeypatch.setattr(probe, "_argv", lambda pid: ["llama-server", f"--pid={pid}"])
    monkeypatch.setattr(probe, "_is_systemd_managed", lambda pid: pid == 111)
    report = _report()
    probe.scan_gpu(report)
    assert len(report.lanes) == 1 and "pid=111" in report.lanes[0]
    assert len(report.foreign_gpu) == 1 and "pid=222" in report.foreign_gpu[0]


def test_scan_gpu_reports_an_unreadable_card_rather_than_zero(monkeypatch: pytest.MonkeyPatch) -> None:
    # Catches: nvidia-smi failing and the report reading "0 apps" as an all-clear.
    monkeypatch.setattr(probe, "subprocess", _fake_subprocess_run(returncode=9, stderr="driver lost"))
    report = _report()
    probe.scan_gpu(report)
    assert report.unreadable and "exited 9" in report.unreadable[0]
    assert report.safe is False

    monkeypatch.setattr(probe, "subprocess", _fake_subprocess_run(raise_exc=OSError("ENOENT")))
    report2 = _report()
    probe.scan_gpu(report2)
    assert report2.unreadable and "could not be run" in report2.unreadable[0]


def test_scan_gpu_ignores_non_numeric_lines(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(probe, "subprocess", _fake_subprocess_run(stdout="\nN/A\n333\n"))
    monkeypatch.setattr(probe, "_argv", lambda pid: [])
    monkeypatch.setattr(probe, "_is_systemd_managed", lambda pid: False)
    report = _report()
    probe.scan_gpu(report)
    assert len(report.foreign_gpu) == 1
    assert "cmdline unreadable" in report.foreign_gpu[0]


def test_gather_runs_every_scanner(monkeypatch: pytest.MonkeyPatch) -> None:
    # Catches: a scanner added to gather() but never invoked - its findings would be
    # invisible while the verdict still looked complete.
    def _workers(report: Any) -> None:
        report.workers.append("w")

    def _work(report: Any) -> None:
        report.work.append("j")

    def _gpu(report: Any) -> None:
        report.lanes.append("l")

    monkeypatch.setattr(probe, "scan_workers", _workers)
    monkeypatch.setattr(probe, "scan_work", _work)
    monkeypatch.setattr(probe, "scan_gpu", _gpu)
    report = probe.gather()
    assert (report.workers, report.work, report.lanes) == (["w"], ["j"], ["l"])
