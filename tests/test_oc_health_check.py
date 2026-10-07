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
#
# The port verdict PREFERS the kernel's socket table (what `so` reads) and uses a
# connect only as a fallback, so the two commands cannot disagree about one moment.
# Measured 2026-10-07 at a Gateway cold start: `ss -ltn` showed two LISTEN rows while
# the 1.5 s connect was refused by a saturated event loop, so `oc health` read FAIL
# and `so` read STARTING.


def test_tcp_port_probe_true_when_connect_succeeds(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(checker, "socket", SimpleNamespace(create_connection=lambda *a, **k: contextlib.nullcontext()))
    assert checker._check_tcp_port("127.0.0.1", 18789) is True


def test_tcp_port_probe_false_when_connect_refuses(monkeypatch: pytest.MonkeyPatch) -> None:
    def _refuse(*_a: Any, **_k: Any) -> Any:
        raise OSError("connection refused")

    monkeypatch.setattr(checker, "socket", SimpleNamespace(create_connection=_refuse))
    assert checker._check_tcp_port("127.0.0.1", 18789) is False


def _fake_run(stdout: str = "", returncode: int = 0, raises: Exception | None = None) -> Any:
    """A stand-in for `_run` answering one probe with a chosen result."""

    def _run(*_a: Any, **_k: Any) -> Any:
        if raises is not None:
            raise raises
        return _completed(returncode, stdout=stdout)

    return _run


def test_socket_table_true_when_ss_reports_a_listener(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(checker, "shutil", _fake_shutil({"ss": "/usr/bin/ss"}))
    monkeypatch.setattr(
        checker,
        "_run",
        _fake_run(stdout="State Recv-Q Send-Q Local Address:Port Peer Address:Port\nLISTEN 0 4096 127.0.0.1:18789 0.0.0.0:*\n"),
    )
    assert checker._socket_table_listening(18789) is True


def test_socket_table_false_when_ss_shows_only_the_header(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(checker, "shutil", _fake_shutil({"ss": "/usr/bin/ss"}))
    monkeypatch.setattr(
        checker,
        "_run",
        _fake_run(stdout="State Recv-Q Send-Q Local Address:Port Peer Address:Port\n"),
    )
    assert checker._socket_table_listening(18789) is False


def test_socket_table_none_without_ss(monkeypatch: pytest.MonkeyPatch) -> None:
    # `ss` absent is "could not ask", not "not bound" — the caller falls back to a
    # connect rather than inventing a verdict.
    monkeypatch.setattr(checker, "shutil", _fake_shutil({"ss": None}))
    assert checker._socket_table_listening(18789) is None


def test_socket_table_none_and_a_note_when_ss_times_out(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    monkeypatch.setattr(checker, "shutil", _fake_shutil({"ss": "/usr/bin/ss"}))
    monkeypatch.setattr(checker, "_run", _fake_run(raises=subprocess.TimeoutExpired(cmd=["ss"], timeout=3.0)))
    assert checker._socket_table_listening(18789) is None
    # The fallback is reported, not silent: the note goes to stderr so it cannot
    # corrupt the --json/--plain stdout contract.
    assert "could not be read" in capsys.readouterr().err


def test_socket_table_none_and_a_note_when_ss_exits_nonzero(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    monkeypatch.setattr(checker, "shutil", _fake_shutil({"ss": "/usr/bin/ss"}))
    monkeypatch.setattr(checker, "_run", _fake_run(stdout="", returncode=1))
    assert checker._socket_table_listening(18789) is None
    assert "exited 1" in capsys.readouterr().err


def test_port_bound_prefers_the_socket_table_and_skips_the_connect(monkeypatch: pytest.MonkeyPatch) -> None:
    consulted = False

    def _connect(*_a: Any, **_k: Any) -> bool:
        nonlocal consulted
        consulted = True
        return False

    monkeypatch.setattr(checker, "_socket_table_listening", lambda *a, **k: True)
    monkeypatch.setattr(checker, "_check_tcp_port", _connect)
    bound, evidence = checker._check_port_bound(18789)
    assert bound is True
    assert evidence == {"socket_table": True, "connect": None}
    assert consulted is False


def test_port_bound_falls_back_to_a_connect_when_the_table_cannot_be_read(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(checker, "_socket_table_listening", lambda *a, **k: None)
    monkeypatch.setattr(checker, "_check_tcp_port", lambda *a, **k: True)
    bound, evidence = checker._check_port_bound(18789)
    assert bound is True
    assert evidence == {"socket_table": None, "connect": True}


def test_gateway_port_fails_when_not_listening(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(checker, "_socket_table_listening", lambda *a, **k: False)
    check = checker._check_gateway_port(18789)
    assert check["status"] == "fail"
    assert check["details"]["listening"] is False


def test_gateway_port_ok_when_the_listener_is_bound_but_the_connect_refuses(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # The 2026-10-07 shape: the listener is bound (ss sees it) and the saturated event
    # loop refuses the connect.  `so` reads the socket table, so this must read OK
    # here too, or `oc health` and `so` disagree about whether the port is bound.
    monkeypatch.setattr(checker, "_socket_table_listening", lambda *a, **k: True)
    monkeypatch.setattr(checker, "_check_tcp_port", lambda *a, **k: False)
    check = checker._check_gateway_port(18789)
    assert check["status"] == "ok"
    assert check["details"]["listening"] is True
    assert check["details"]["socket_table"] is True
    assert check["details"]["connect"] is None


def test_llm_port_is_only_a_warning_when_absent(monkeypatch: pytest.MonkeyPatch) -> None:
    # A down LLM lane must not fail the whole report: the gateway is the live service.
    monkeypatch.setattr(checker, "_socket_table_listening", lambda *a, **k: False)
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
    monkeypatch.setattr(checker, "urllib", _fake_urllib(_raise_refused))
    # The unreachable branch consults the unit and the port to tell "starting" from
    # "failed", so pin BOTH port seams and the unit at the module-local boundary.
    # Without this the test would read the live systemd unit and the live socket table
    # — host-coupled, and green only because the box happens to be idle when it runs.
    monkeypatch.setattr(checker, "_socket_table_listening", lambda *a, **k: False)
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
# `so` was right.  These cases hold the states apart, using the SAME evidence the
# checker reads: the OC_HEALTH_GATEWAY_PHASE verdict `so`'s classifier produces, the
# unit's ActiveState, its start age, whether the port is bound, and the listener's
# bind age (OC_HEALTH_GATEWAY_BOUND_AGE_S, from __so_gateway_bound_age).
#
# The matrix a later reader must be able to re-derive from here:
#   unit inactive                                        -> FAIL
#   journal says running / degraded / draining           -> FAIL
#   unbound, elapsed inside the cold-start bound         -> STARTING
#   unbound, elapsed PAST the bound                      -> FAIL
#   bound + journal says `starting` + dark <= grace      -> STARTING (a normal post-bind
#                                                          interval: an ordinary start
#                                                          serves as it binds)
#   bound + journal says `starting` + dark > grace       -> STALLED (2026-10-07: bound
#                                                          212 s in, first /health 200
#                                                          at 542 s = 330 s dark)
#   bound + journal says `starting` + no bind age        -> STARTING (no post-bind
#                                                          evidence to measure with)
#   bound + NO journal verdict + inside the bound        -> STARTING
#   bound + NO journal verdict + PAST the bound          -> FAIL
#   listener bound but the connect refused               -> STARTING / STALLED by bind
#                                                          age, never FAIL (the 2026-10-07
#                                                          transitional case: a saturated
#                                                          event loop refuses the connect
#                                                          while `ss` sees the row)
#   /health answers ok                                   -> OK


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
    socket_table_bound: bool | None = None,
    bind_age_s: int | None = 30,
    set_bind_age: bool = True,
) -> None:
    monkeypatch.setattr(checker, "urllib", _fake_urllib(_raise_refused))
    # The port verdict comes from the socket table, so pin BOTH seams: leaving the
    # table live would read the real `ss` (and this box's real listener) and make the
    # case host-coupled.  `socket_table_bound` overrides the table alone, for the
    # transitional shape where the table and the connect disagree.
    table = port_bound if socket_table_bound is None else socket_table_bound
    monkeypatch.setattr(checker, "_socket_table_listening", lambda *a, **k: table)
    monkeypatch.setattr(checker, "_check_tcp_port", lambda *a, **k: port_bound)
    monkeypatch.setattr(checker, "_gateway_unit_start", _unit(active_state, elapsed_s))
    if unset_phase:
        monkeypatch.delenv("OC_HEALTH_GATEWAY_PHASE", raising=False)
    else:
        monkeypatch.setenv("OC_HEALTH_GATEWAY_PHASE", phase)
    # The bind age is the post-bind seam.  30 s is an ordinary post-bind interval; the
    # default keeps every existing case inside the grace, so only the STALLED cases
    # have to say so.
    if set_bind_age and bind_age_s is not None:
        monkeypatch.setenv("OC_HEALTH_GATEWAY_BOUND_AGE_S", str(bind_age_s))
    else:
        monkeypatch.delenv("OC_HEALTH_GATEWAY_BOUND_AGE_S", raising=False)


def test_health_is_starting_for_a_bound_but_not_serving_cold_start(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # 200 s in, listener up 30 s ago, still not serving: a normal post-bind interval —
    # `so` says STARTING, and so must this.
    _arm_unreachable(monkeypatch, phase="starting", elapsed_s=200, bind_age_s=30)
    check = checker._check_gateway_health(18789)
    assert check["status"] == "starting"
    assert "30s" in str(check["message"])
    assert str(checker.GATEWAY_POST_BIND_GRACE_S) in str(check["message"])
    assert check["details"]["elapsed_s"] == 200
    assert check["details"]["bind_age_s"] == 30
    assert check["details"]["port_bound"] is True
    assert check["details"]["phase"] == "starting"


def test_health_is_stalled_when_the_listener_is_bound_and_dark_past_the_grace(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # The state Wayne measured, 2026-10-07 (boot, MainPID 613675): the listener bound
    # at 05:51:40 — 212 s after the unit started — and the first /health 200 came at
    # 05:57:10.  At elapsed 470 s the listener had been bound 258 s and dark, past the
    # 150 s grace, so the verdict is its own signal — not STARTING (a normal start
    # serves as it binds) and not FAIL (the unit is active, the port is bound, and the
    # start recovered on its own).
    _arm_unreachable(monkeypatch, phase="starting", elapsed_s=470, bind_age_s=258)
    check = checker._check_gateway_health(18789)
    assert check["status"] == "stalled"
    assert "258s" in str(check["message"])
    assert "do not restart" in str(check["message"])
    assert check["details"]["bind_age_s"] == 258
    assert check["details"]["post_bind_grace_s"] == checker.GATEWAY_POST_BIND_GRACE_S
    # And at the first 200 (542 s in, 330 s of darkness) it is still stalled, not FAIL.
    _arm_unreachable(monkeypatch, phase="starting", elapsed_s=542, bind_age_s=330)
    assert checker._check_gateway_health(18789)["status"] == "stalled"


def test_health_post_bind_grace_is_the_decision_boundary(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # At the grace the post-bind interval is still "normal"; one second past it, the
    # same evidence is the stalled signal.  The bound is a decision boundary, so both
    # sides of it are pinned.
    _arm_unreachable(
        monkeypatch, phase="starting", elapsed_s=400, bind_age_s=checker.GATEWAY_POST_BIND_GRACE_S
    )
    assert checker._check_gateway_health(18789)["status"] == "starting"
    _arm_unreachable(
        monkeypatch,
        phase="starting",
        elapsed_s=400,
        bind_age_s=checker.GATEWAY_POST_BIND_GRACE_S + 1,
    )
    assert checker._check_gateway_health(18789)["status"] == "stalled"


def test_health_is_starting_when_the_grace_cannot_be_measured(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # No bind age means no post-bind evidence, so a journal-reported start is trusted
    # rather than being called stalled on evidence we do not have.  A wedge stops
    # logging, and the phase then stops saying `starting`, which is what brings the
    # elapsed bound back into play.
    _arm_unreachable(monkeypatch, phase="starting", elapsed_s=500, set_bind_age=False)
    check = checker._check_gateway_health(18789)
    assert check["status"] == "starting"
    assert check["details"]["bind_age_s"] is None


def test_health_falls_back_to_the_bound_when_the_journal_has_gone_quiet(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # The bound is what stops a WEDGED gateway reading STARTING forever: a wedge emits
    # no further lifecycle lines, so its `starting` line ages out of the classifier's
    # window and the phase it then produces is not `starting` (here: absent).  At the
    # bound the start is still "in progress"; just past it, with no journal verdict,
    # the same evidence is a fault — even though the port is bound, because a bound
    # listener with no journal verdict is not the post-bind state the grace measures.
    _arm_unreachable(
        monkeypatch, unset_phase=True, elapsed_s=checker.GATEWAY_COLD_START_BOUND_S, bind_age_s=10
    )
    assert checker._check_gateway_health(18789)["status"] == "starting"
    _arm_unreachable(
        monkeypatch,
        unset_phase=True,
        elapsed_s=checker.GATEWAY_COLD_START_BOUND_S + 1,
        bind_age_s=10,
    )
    assert checker._check_gateway_health(18789)["status"] == "fail"
    # ...and a long post-bind darkness with NO journal verdict is a fault too, not a
    # stall: nothing says a start is in progress, and it is past the bound.
    _arm_unreachable(
        monkeypatch,
        unset_phase=True,
        elapsed_s=checker.GATEWAY_COLD_START_BOUND_S + 1,
        bind_age_s=300,
    )
    assert checker._check_gateway_health(18789)["status"] == "fail"


def test_health_fails_when_no_port_is_bound_and_the_bound_is_past(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # The PRE-BIND phase keeps the elapsed bound: a listener that has not appeared by
    # then is a fault.  (Wayne's 2026-10-07 decision kept 420 and gave only the
    # POST-BIND dark state its own signal.)
    _arm_unreachable(monkeypatch, phase="starting", port_bound=False, elapsed_s=100, bind_age_s=None)
    assert checker._check_gateway_health(18789)["status"] == "starting"
    _arm_unreachable(
        monkeypatch,
        phase="starting",
        port_bound=False,
        elapsed_s=checker.GATEWAY_COLD_START_BOUND_S + 1,
        bind_age_s=None,
    )
    check = checker._check_gateway_health(18789)
    assert check["status"] == "fail"
    assert check["details"]["port_bound"] is False


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


def test_health_is_starting_when_no_port_is_bound_inside_the_bound(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # SUPERSEDED criterion (2026-10-07): a bound port is no longer a precondition for
    # STARTING.  The unit being active inside the bound is the evidence; requiring the
    # port as well made the earliest phase of a cold start (unit active, listener not
    # open yet) read FAIL — the same false red, one phase earlier.  An unbound port is
    # therefore STARTING, with the message naming the weaker evidence.
    _arm_unreachable(
        monkeypatch, phase="starting", port_bound=False, elapsed_s=200, bind_age_s=None
    )
    check = checker._check_gateway_health(18789)
    assert check["status"] == "starting"
    assert check["details"]["port_bound"] is False
    assert "port not bound yet" in str(check["message"])


def test_health_is_starting_when_the_listener_is_bound_but_the_connect_refuses(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # The 2026-10-07 report: `oc health` read FAIL while `so` read STARTING because
    # the event loop was saturated and refused the connect, though `ss` showed the
    # listener.  The socket table answers, so the connect is never consulted and the
    # verdict matches `so`.
    _arm_unreachable(
        monkeypatch,
        phase="starting",
        elapsed_s=138,
        port_bound=True,
        socket_table_bound=True,
        bind_age_s=30,
    )
    monkeypatch.setattr(checker, "_check_tcp_port", lambda *a, **k: False)  # the connect refused
    check = checker._check_gateway_health(18789)
    assert check["status"] == "starting"
    assert check["details"]["socket_table"] is True
    assert check["details"]["connect"] is None
    assert "listener bound 30s ago" in str(check["message"])
    # A bound listener whose connect refuses is NEVER FAIL, whatever the bind age: the
    # same evidence with a long post-bind darkness is the stalled signal, not a fault.
    _arm_unreachable(
        monkeypatch,
        phase="starting",
        elapsed_s=470,
        port_bound=True,
        socket_table_bound=True,
        bind_age_s=258,
    )
    monkeypatch.setattr(checker, "_check_tcp_port", lambda *a, **k: False)
    assert checker._check_gateway_health(18789)["status"] == "stalled"


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


def test_stalled_is_its_own_status_above_warn_and_below_fail() -> None:
    # Wayne's 2026-10-07 decision: the post-bind dark state gets its own SIGNAL, so it
    # must be its own status — distinguishable from STARTING (a slow-but-normal start)
    # and from FAIL (an inactive unit, an unbound port, or a start that stopped
    # producing evidence).  It is real news (bound and dark for minutes), so it outranks
    # a warning; it is short of a failure, because the start may still complete.
    assert checker._status_rank("warn") < checker._status_rank("stalled")
    assert checker._status_rank("stalled") < checker._status_rank("fail")
    assert checker._symbol("stalled") == "[STALLED]"


def test_main_exits_five_for_stalled(monkeypatch: pytest.MonkeyPatch) -> None:
    # Wayne's 2026-10-07 decision: `stalled` gets its OWN exit code.  Exiting 0 made the
    # state invisible to a consumer that reads only the status (a silent channel);
    # exiting 1 would have said "repair or restart", and a restart re-enters the drain
    # window that turned one restart into a 15.5-minute outage (2026-09-22).  5 says
    # alert and never restart.
    assert _main_with(monkeypatch, "stalled") == 5


def test_gateway_bind_age_reads_the_env_and_rejects_stale_or_bad_values(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    monkeypatch.setenv("OC_HEALTH_GATEWAY_BOUND_AGE_S", "258")
    assert checker._gateway_bind_age(470) == 258
    monkeypatch.setenv("OC_HEALTH_GATEWAY_BOUND_AGE_S", "")
    assert checker._gateway_bind_age(470) is None
    monkeypatch.delenv("OC_HEALTH_GATEWAY_BOUND_AGE_S", raising=False)
    assert checker._gateway_bind_age(470) is None
    monkeypatch.setenv("OC_HEALTH_GATEWAY_BOUND_AGE_S", "banana")
    assert checker._gateway_bind_age(470) is None
    monkeypatch.setenv("OC_HEALTH_GATEWAY_BOUND_AGE_S", "-5")
    assert checker._gateway_bind_age(470) is None
    # Older than the unit itself: a line from a PREVIOUS incarnation inside the
    # classifier's window.  Using it would fake a stall on a unit that just started.
    monkeypatch.setenv("OC_HEALTH_GATEWAY_BOUND_AGE_S", "300")
    assert checker._gateway_bind_age(100) is None
    # ...and without a unit age there is nothing to cross-check, so it is used.
    assert checker._gateway_bind_age(None) == 300
    err = capsys.readouterr().err
    assert "not an integer" in err
    assert "negative" in err
    assert "older than" in err


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


# --- the exit-code contract (Wayne's 2026-10-07 decision) -------------------
#
# WHY THE CODES ARE PINNED HERE: the exit status is the only channel a wrapper or a
# monitor reads, so the contract has to be a property of THIS module, not of a caller's
# comment.  These cases assert the CODE — the thing under test — not the summary string,
# because a mapping that returned the right code for the wrong reason would still be
# wrong the moment a status is added.
#
# 0 for the healthy/degraded/normal-start states, 5 for a stall (ALERT, NEVER RESTART),
# 1 for a fault (repair or restart is legitimate) and for anything unrecognised.


def test_exit_mapping_covers_every_status_the_checker_can_emit() -> None:
    # A status added without an exit decision must not silently inherit "success": the
    # mapping's keys are the set of summaries the checker emits, and this assertion is
    # what forces the mapping to be extended instead of going stale.  `EXIT_UNRECOGNISED`
    # is the conservative default.
    assert set(checker.EXIT_BY_SUMMARY) == {"ok", "info", "warn", "starting", "stalled", "fail"}
    assert checker.EXIT_UNRECOGNISED == 1


@pytest.mark.parametrize(
    ("summary", "expected"),
    [
        ("ok", 0),
        ("info", 0),
        ("warn", 0),
        ("starting", 0),
        ("stalled", 5),
        ("fail", 1),
        ("banana", 1),  # unrecognised -> the conservative default, never 0
    ],
)
def test_exit_code_contract(
    monkeypatch: pytest.MonkeyPatch, summary: str, expected: int
) -> None:
    assert _main_with(monkeypatch, summary) == expected


def test_exit_code_does_not_depend_on_the_output_mode(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    # `oc health --json | …` and the human row must agree on the code, or a monitor and a
    # human would read the same stall differently.
    monkeypatch.setattr(
        checker,
        "build_report",
        lambda: {"summary": "stalled", "checks": [], "ports": {}, "timestamp": 0},
    )
    assert checker.main(["--json"]) == 5
    assert checker.main(["--verbose"]) == 5
    assert checker.main([]) == 5
    capsys.readouterr()


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
