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
import sys
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
