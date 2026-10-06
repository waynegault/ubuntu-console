"""Tests for the live enhanced health checker (`scripts/oc-health-check.py`).

WHY THIS EXISTS (card 4bc7deab, AUDIT-2026-10-02): this module is the LIVE checker —
`install.sh` links it into `~/.openclaw/workspace/scripts/` and `oc health` prefers it
over its own fallback — yet nothing executed it: no pytest test imported it, and the
two BATS references (tests/unit/28-*, 33-*) REPLACE it with a one-line stub, so its
own logic was untested at 0% coverage.

The module is a hyphenated script (this repo's ``scripts/*.py`` convention), so it is
loaded by path rather than imported by name.  Its INPUTS are the live box — a TCP
port, `openclaw --version`, a health URL via urllib — so every probe is replaced at
the MODULE-LOCAL seam (`checker.shutil`, `checker._run`, `checker.urllib`, …); no
global module is monkeypatched, so unrelated calls still run for real.

The contract asserted here is the one a caller reads:
  * `--json` emits `{"checks": [...]}` with one entry per probe;
  * the summary is the WORST status (ok < info < warn < fail);
  * exit 0 for ok/info/warn, 1 for fail.
"""

from __future__ import annotations

import contextlib
import importlib.util
import json
import subprocess
import sys
from pathlib import Path
from types import SimpleNamespace
from typing import Any

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent


def _load_checker() -> Any:
    """Import scripts/oc-health-check.py by path (its name is not a module name)."""
    spec = importlib.util.spec_from_file_location(
        "oc_health_check", REPO_ROOT / "scripts" / "oc-health-check.py"
    )
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    try:
        spec.loader.exec_module(module)
    except BaseException:
        del sys.modules[spec.name]
        raise
    return module


checker = _load_checker()


# --- module-local fakes -----------------------------------------------------


def _fake_shutil(which: dict[str, str | None]) -> SimpleNamespace:
    """A stand-in for `shutil` that only answers `which`."""
    return SimpleNamespace(which=lambda name: which.get(name))


class _FakeHTTPError(Exception):
    def __init__(self, code: int) -> None:
        super().__init__(f"HTTP {code}")
        self.code = code


class _FakeURLError(Exception):
    pass


def _fake_urllib(urlopen: Any) -> SimpleNamespace:
    """A stand-in for `urllib` with only the names the checker uses."""
    return SimpleNamespace(
        request=SimpleNamespace(urlopen=urlopen),
        error=SimpleNamespace(HTTPError=_FakeHTTPError, URLError=_FakeURLError),
    )


def _fake_response(payload: bytes) -> Any:
    return contextlib.nullcontext(SimpleNamespace(read=lambda: payload))


def _completed(returncode: int = 0, stdout: str = "", stderr: str = "") -> Any:
    return SimpleNamespace(returncode=returncode, stdout=stdout, stderr=stderr)


# --- TCP port probe ---------------------------------------------------------


def test_tcp_port_probe_true_when_connect_succeeds(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(checker, "socket", SimpleNamespace(create_connection=lambda *a, **k: contextlib.nullcontext()))
    assert checker._check_tcp_port("127.0.0.1", 18789) is True


def test_tcp_port_probe_false_when_connect_refuses(monkeypatch: pytest.MonkeyPatch) -> None:
    def _refuse(*_a: Any, **_k: Any) -> Any:
        raise OSError("connection refused")

    monkeypatch.setattr(checker, "socket", SimpleNamespace(create_connection=_refuse))
    assert checker._check_tcp_port("127.0.0.1", 18789) is False


def test_gateway_port_fails_when_not_listening(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(checker, "_check_tcp_port", lambda *a, **k: False)
    check = checker._check_gateway_port(18789)
    assert check["status"] == "fail"
    assert check["details"]["listening"] is False


def test_llm_port_is_only_a_warning_when_absent(monkeypatch: pytest.MonkeyPatch) -> None:
    # A down LLM lane must not fail the whole report: the gateway is the live service.
    monkeypatch.setattr(checker, "_check_tcp_port", lambda *a, **k: False)
    check = checker._check_llm_port(8081)
    assert check["status"] == "warn"


# --- openclaw CLI probe -----------------------------------------------------


def test_cli_missing_is_a_failure(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(checker, "shutil", _fake_shutil({"openclaw": None}))
    check = checker._check_openclaw_cli()
    assert check["status"] == "fail"
    assert check["details"]["path"] is None


def test_cli_version_reports_ok(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(checker, "shutil", _fake_shutil({"openclaw": "/usr/bin/openclaw"}))
    monkeypatch.setattr(checker, "_run", lambda *a, **k: _completed(0, stdout="2026.9.7\n"))
    check = checker._check_openclaw_cli()
    assert check["status"] == "ok"
    assert check["details"]["version"] == "2026.9.7"


def test_cli_timeout_is_a_warning(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(checker, "shutil", _fake_shutil({"openclaw": "/usr/bin/openclaw"}))

    def _timeout(*_a: Any, **_k: Any) -> Any:
        raise subprocess.TimeoutExpired(cmd=["openclaw"], timeout=4.0)

    monkeypatch.setattr(checker, "_run", _timeout)
    check = checker._check_openclaw_cli()
    assert check["status"] == "warn"
    assert "timed out" in str(check["message"])


def test_cli_nonzero_exit_is_a_warning_naming_the_code(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(checker, "shutil", _fake_shutil({"openclaw": "/usr/bin/openclaw"}))
    monkeypatch.setattr(checker, "_run", lambda *a, **k: _completed(2, stderr="boom\n"))
    check = checker._check_openclaw_cli()
    assert check["status"] == "warn"
    assert "rc=2" in str(check["message"])


# --- gateway health URL -----------------------------------------------------


def test_health_ok_when_payload_says_ok(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(checker, "time", SimpleNamespace(time=lambda: 100.0))
    monkeypatch.setattr(
        checker,
        "urllib",
        _fake_urllib(lambda *a, **k: _fake_response(b'{"ok": true, "status": "healthy"}')),
    )
    check = checker._check_gateway_health(18789)
    assert check["status"] == "ok"
    assert check["details"]["response_ms"] == 0


def test_health_warns_when_payload_status_is_not_ok(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(
        checker,
        "urllib",
        _fake_urllib(lambda *a, **k: _fake_response(b'{"status": "degraded"}')),
    )
    check = checker._check_gateway_health(18789)
    assert check["status"] == "warn"
    assert "degraded" in str(check["message"])


def test_health_http_error_is_a_warning_with_the_code(monkeypatch: pytest.MonkeyPatch) -> None:
    def _raise(*_a: Any, **_k: Any) -> Any:
        raise _FakeHTTPError(503)

    monkeypatch.setattr(checker, "urllib", _fake_urllib(_raise))
    check = checker._check_gateway_health(18789)
    assert check["status"] == "warn"
    assert check["details"]["http_status"] == 503


def test_health_unreachable_is_a_failure(monkeypatch: pytest.MonkeyPatch) -> None:
    def _raise(*_a: Any, **_k: Any) -> Any:
        raise _FakeURLError("connection refused")

    monkeypatch.setattr(checker, "urllib", _fake_urllib(_raise))
    # The unreachable branch now consults the unit and the port to tell "starting"
    # from "failed", so pin BOTH at the module-local seam.  Without this the test
    # would read the live systemd unit and the live port — host-coupled, and green
    # only because the box happens to be serving (or idle) when it runs.
    monkeypatch.setattr(checker, "_check_tcp_port", lambda *a, **k: False)
    monkeypatch.setattr(checker, "_gateway_unit_start", _inactive_unit)
    check = checker._check_gateway_health(18789)
    assert check["status"] == "fail"
    assert "connection refused" in str(check["details"]["error"])


# --- the STARTING verdict (the 2026-10-06 false-red fix) --------------------
#
# WHY THIS EXISTS: this host's port binds BEFORE the HTTP server serves, and the
# cold start measured here runs 58 s (ordinary), 102.5/130.5 s (busy) and 341 s
# (2026-10-06 19:06 BST start, 298.7 s internal) to 347 s (heavy load).  `oc health`
# reported FAIL for a Gateway inside that window while `so` reported STARTING, and
# `so` was right.  These cases hold the three states apart, using the SAME evidence
# the checker reads: the OC_HEALTH_GATEWAY_PHASE verdict `so`'s classifier produces,
# the unit's ActiveState, its start age, and whether the port is bound.


def _raise_refused(*_a: Any, **_k: Any) -> Any:
    raise _FakeURLError("connection refused")


def _unit(active_state: str = "active", elapsed_s: int | None = 200) -> Any:
    return lambda: {
        "available": True,
        "active_state": active_state,
        "elapsed_s": elapsed_s,
    }


def _inactive_unit() -> dict[str, object]:
    return {"available": True, "active_state": "inactive", "elapsed_s": 200}


def _arm_unreachable(
    monkeypatch: pytest.MonkeyPatch,
    *,
    phase: str = "starting",
    elapsed_s: int | None = 200,
    active_state: str = "active",
    port_bound: bool = True,
    unset_phase: bool = False,
) -> None:
    monkeypatch.setattr(checker, "urllib", _fake_urllib(_raise_refused))
    monkeypatch.setattr(checker, "_check_tcp_port", lambda *a, **k: port_bound)
    monkeypatch.setattr(checker, "_gateway_unit_start", _unit(active_state, elapsed_s))
    if unset_phase:
        monkeypatch.delenv("OC_HEALTH_GATEWAY_PHASE", raising=False)
    else:
        monkeypatch.setenv("OC_HEALTH_GATEWAY_PHASE", phase)


def test_health_is_starting_for_a_bound_but_not_serving_cold_start(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # 200 s in, still not serving: `so` says STARTING, and so must this.
    _arm_unreachable(monkeypatch, phase="starting", elapsed_s=200)
    check = checker._check_gateway_health(18789)
    assert check["status"] == "starting"
    assert "200s" in str(check["message"])
    assert str(checker.GATEWAY_COLD_START_BOUND_S) in str(check["message"])
    assert check["details"]["elapsed_s"] == 200
    assert check["details"]["port_bound"] is True
    assert check["details"]["phase"] == "starting"


def test_health_starting_at_the_bound_but_failing_just_past_it(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # The bound is the decision boundary: at it the start is still "in progress",
    # past it the same evidence is a fault.
    _arm_unreachable(monkeypatch, elapsed_s=checker.GATEWAY_COLD_START_BOUND_S)
    assert checker._check_gateway_health(18789)["status"] == "starting"
    _arm_unreachable(monkeypatch, elapsed_s=checker.GATEWAY_COLD_START_BOUND_S + 1)
    assert checker._check_gateway_health(18789)["status"] == "fail"


def test_health_is_starting_on_the_minimum_evidence_without_a_phase_verdict(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # A direct run of this script (or a box with no readable journal) has no phase.
    # The minimum — unit active, port bound, start recent — still reads STARTING.
    _arm_unreachable(monkeypatch, unset_phase=True, elapsed_s=200)
    check = checker._check_gateway_health(18789)
    assert check["status"] == "starting"
    assert check["details"]["phase"] == "unknown"


def test_health_fails_when_the_unit_is_inactive(monkeypatch: pytest.MonkeyPatch) -> None:
    _arm_unreachable(monkeypatch, phase="starting", active_state="inactive")
    check = checker._check_gateway_health(18789)
    assert check["status"] == "fail"
    assert check["details"]["unit_active"] is False


def test_health_fails_when_no_port_is_bound(monkeypatch: pytest.MonkeyPatch) -> None:
    _arm_unreachable(monkeypatch, phase="starting", port_bound=False)
    check = checker._check_gateway_health(18789)
    assert check["status"] == "fail"
    assert check["details"]["port_bound"] is False


def test_health_fails_when_the_journal_says_the_gateway_is_running(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # A journal that claims the gateway IS serving while /health refuses is a real
    # fault, not a cold start — the same rule that keeps a drain an outage.
    _arm_unreachable(monkeypatch, phase="running")
    assert checker._check_gateway_health(18789)["status"] == "fail"
    _arm_unreachable(monkeypatch, phase="draining")
    assert checker._check_gateway_health(18789)["status"] == "fail"


def test_starting_ranks_between_info_and_warn_and_has_its_own_symbol() -> None:
    assert checker._status_rank("info") < checker._status_rank("starting")
    assert checker._status_rank("starting") < checker._status_rank("warn")
    assert checker._symbol("starting") == "[STARTING]"


def test_main_exits_zero_for_starting(monkeypatch: pytest.MonkeyPatch) -> None:
    # A cold start must not be a red box for `oc health && …`.
    assert _main_with(monkeypatch, "starting") == 0


def test_human_output_prints_a_starting_row(capsys: pytest.CaptureFixture[str]) -> None:
    report = {
        "summary": "starting",
        "checks": [
            {
                "name": "gateway_health",
                "status": "starting",
                "message": "gateway starting: port bound, not serving yet (elapsed 200s; cold-start bound 420s)",
                "details": {},
            }
        ],
    }
    checker.print_human(report)
    out = capsys.readouterr().out
    assert "OpenClaw Health Summary: STARTING" in out
    assert "[STARTING] gateway_health: gateway starting" in out


def test_health_non_json_body_is_a_warning(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(checker, "urllib", _fake_urllib(lambda *a, **k: _fake_response(b"<html>nope</html>")))
    check = checker._check_gateway_health(18789)
    assert check["status"] == "warn"
    assert "not valid JSON" in str(check["message"])


# --- systemd + jq -----------------------------------------------------------


def test_systemd_skipped_info_when_systemctl_absent(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(checker, "shutil", _fake_shutil({"systemctl": None}))
    check = checker._check_systemd_gateway()
    assert check["status"] == "info"


def test_systemd_active_is_ok(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(checker, "shutil", _fake_shutil({"systemctl": "/bin/systemctl"}))
    monkeypatch.setattr(checker, "_run", lambda *a, **k: _completed(0, stdout="active\n"))
    check = checker._check_systemd_gateway()
    assert check["status"] == "ok"


def test_systemd_inactive_is_a_warning_naming_the_state(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(checker, "shutil", _fake_shutil({"systemctl": "/bin/systemctl"}))
    monkeypatch.setattr(checker, "_run", lambda *a, **k: _completed(3, stdout="inactive\n"))
    check = checker._check_systemd_gateway()
    assert check["status"] == "warn"
    assert "inactive" in str(check["message"])


def test_systemd_empty_state_is_a_warning(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(checker, "shutil", _fake_shutil({"systemctl": "/bin/systemctl"}))
    monkeypatch.setattr(checker, "_run", lambda *a, **k: _completed(1, stdout="", stderr="no such unit"))
    check = checker._check_systemd_gateway()
    assert check["status"] == "warn"
    assert "unavailable" in str(check["message"])


def test_jq_absent_is_a_warning(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(checker, "shutil", _fake_shutil({"jq": None}))
    assert checker._check_jq()["status"] == "warn"


def test_jq_present_is_ok(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(checker, "shutil", _fake_shutil({"jq": "/usr/bin/jq"}))
    check = checker._check_jq()
    assert check["status"] == "ok"
    assert check["details"]["path"] == "/usr/bin/jq"


# --- status ranking ---------------------------------------------------------


def test_status_rank_order_and_unknown_defaults_to_worst() -> None:
    assert checker._status_rank("ok") < checker._status_rank("info")
    assert checker._status_rank("info") < checker._status_rank("warn")
    assert checker._status_rank("warn") < checker._status_rank("fail")
    assert checker._status_rank("banana") == checker._status_rank("fail")


def test_summary_is_the_worst_status() -> None:
    checks = [{"status": "ok"}, {"status": "warn"}, {"status": "info"}]
    assert checker._summary_status(checks) == "warn"
    assert checker._summary_status([]) == "ok"
    assert checker._summary_status([{"status": "fail"}]) == "fail"


def test_symbol_covers_every_status() -> None:
    assert checker._symbol("ok") == "[OK]"
    assert checker._symbol("warn") == "[WARN]"
    assert checker._symbol("fail") == "[FAIL]"
    assert checker._symbol("info") == "[INFO]"
    assert checker._symbol("banana") == "[FAIL]"


# --- report assembly --------------------------------------------------------


def test_build_report_shape_and_ports(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("OC_PORT", "19000")
    monkeypatch.setenv("LLM_SERVICE_PORT", "9000")
    for name in (
        "_check_openclaw_cli",
        "_check_gateway_port",
        "_check_gateway_health",
        "_check_llm_port",
        "_check_systemd_gateway",
        "_check_jq",
    ):
        monkeypatch.setattr(checker, name, lambda *_a, **_k: {"name": "x", "status": "ok", "message": "", "details": {}})

    report = checker.build_report()

    assert report["ports"] == {"gateway": 19000, "llm": 9000}


def test_build_report_follows_the_production_llm_lane(monkeypatch: pytest.MonkeyPatch) -> None:
    # Regression: the row must NOT follow LLM_PORT (8081), the scratch port `so`
    # loads a duplicate on. The gateway talks to LLM_SERVICE_PORT (18081), so probing
    # the scratch port read a healthy production stack as a warning (2026-10-06).
    monkeypatch.setenv("LLM_PORT", "8081")
    monkeypatch.delenv("LLM_SERVICE_PORT", raising=False)
    for name in (
        "_check_openclaw_cli",
        "_check_gateway_port",
        "_check_gateway_health",
        "_check_llm_port",
        "_check_systemd_gateway",
        "_check_jq",
    ):
        monkeypatch.setattr(checker, name, lambda *_a, **_k: {"name": "x", "status": "ok", "message": "", "details": {}})

    report = checker.build_report()

    assert report["ports"]["llm"] == 18081
    assert report["summary"] == "ok"
    assert isinstance(report["timestamp"], int)
    assert len(report["checks"]) == 6
    # The --json contract: a top-level checks list, each entry carrying name/status/message.
    assert {"timestamp", "summary", "ports", "checks"} <= set(report)
    for entry in report["checks"]:
        assert {"name", "status", "message"} <= set(entry)


def test_build_report_summary_is_worst_of_the_probes(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(checker, "_check_openclaw_cli", lambda: {"name": "a", "status": "ok", "message": "", "details": {}})
    monkeypatch.setattr(checker, "_check_gateway_port", lambda p: {"name": "b", "status": "fail", "message": "", "details": {}})
    monkeypatch.setattr(checker, "_check_gateway_health", lambda p: {"name": "c", "status": "ok", "message": "", "details": {}})
    monkeypatch.setattr(checker, "_check_llm_port", lambda p: {"name": "d", "status": "ok", "message": "", "details": {}})
    monkeypatch.setattr(checker, "_check_systemd_gateway", lambda: {"name": "e", "status": "ok", "message": "", "details": {}})
    monkeypatch.setattr(checker, "_check_jq", lambda: {"name": "f", "status": "ok", "message": "", "details": {}})
    assert checker.build_report()["summary"] == "fail"


# --- human output -----------------------------------------------------------


def test_human_output_lists_each_check(capsys: pytest.CaptureFixture[str]) -> None:
    report = {
        "summary": "warn",
        "checks": [
            {"name": "gateway_port", "status": "ok", "message": "port 18789 listening", "details": {"port": 18789}},
            {"name": "gateway_health", "status": "warn", "message": "gateway health: degraded", "details": {}},
        ],
    }
    checker.print_human(report)
    out = capsys.readouterr().out
    assert "OpenClaw Health Summary: WARN" in out
    assert "[OK] gateway_port: port 18789 listening" in out
    assert "[WARN] gateway_health: gateway health: degraded" in out


def test_human_verbose_prints_details(capsys: pytest.CaptureFixture[str]) -> None:
    report = {
        "summary": "ok",
        "checks": [{"name": "jq", "status": "ok", "message": "jq available", "details": {"path": "/usr/bin/jq"}}],
    }
    checker.print_human(report, verbose=True)
    out = capsys.readouterr().out
    assert "details:" in out


# --- the subprocess runner and the script entrypoint ------------------------


def test_run_returns_the_completed_process() -> None:
    # _run is the one seam every subprocess probe goes through; exercise it for real
    # with a harmless command rather than mocking subprocess itself.
    result = checker._run(["/bin/true"], timeout=5.0)
    assert result.returncode == 0


def test_script_entrypoint_runs() -> None:
    # The `if __name__ == "__main__": sys.exit(main())` block, reached the way the
    # installed symlink reaches it.  --help exits before any probe runs.
    proc = subprocess.run(
        [sys.executable, str(REPO_ROOT / "scripts" / "oc-health-check.py"), "--help"],
        capture_output=True,
        text=True,
        timeout=30,
    )
    assert proc.returncode == 0
    assert "OpenClaw health diagnostics" in proc.stdout


# --- main / exit codes ------------------------------------------------------


def _main_with(monkeypatch: pytest.MonkeyPatch, summary: str) -> int:
    monkeypatch.setattr(checker, "build_report", lambda: {"summary": summary, "checks": [], "ports": {}, "timestamp": 0})
    return checker.main([])


def test_main_exits_zero_for_ok(monkeypatch: pytest.MonkeyPatch) -> None:
    assert _main_with(monkeypatch, "ok") == 0


def test_main_exits_zero_for_warn(monkeypatch: pytest.MonkeyPatch) -> None:
    # "degraded" is a warn, not a failure: a down LLM lane must not fail `oc health`.
    assert _main_with(monkeypatch, "warn") == 0


def test_main_exits_one_for_fail(monkeypatch: pytest.MonkeyPatch) -> None:
    assert _main_with(monkeypatch, "fail") == 1


def test_main_json_mode_emits_the_report(monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]) -> None:
    monkeypatch.setattr(
        checker,
        "build_report",
        lambda: {"summary": "ok", "checks": [{"name": "jq", "status": "ok", "message": "jq available", "details": {}}], "ports": {}, "timestamp": 0},
    )
    rc = checker.main(["--json"])
    payload = json.loads(capsys.readouterr().out)
    assert rc == 0
    assert payload["summary"] == "ok"
    assert isinstance(payload["checks"], list)


def test_main_help_exits_zero(capsys: pytest.CaptureFixture[str]) -> None:
    with pytest.raises(SystemExit) as excinfo:
        checker.main(["--help"])
    assert excinfo.value.code == 0
    assert "OpenClaw health diagnostics" in capsys.readouterr().out
