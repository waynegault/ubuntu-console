#!/usr/bin/env python3
"""Richer OpenClaw diagnostics helper used by `oc-health`.

Outputs:
- human (default): concise checklist
- --verbose: checklist + details
- --json: structured JSON for automation

EXIT CODE CONTRACT — the SUMMARY decides the code, in `EXIT_BY_SUMMARY` below:

    0   ok | info | warn | starting   healthy, merely degraded, or a NORMAL cold start
    5   stalled                        the listener is bound and dark past the post-bind
                                       grace: ALERT, NEVER RESTART
    1   fail                           an inactive unit, or a start that stopped producing
                                       evidence: repair or restart is legitimate
    1   anything else                  an unrecognised summary keeps the conservative default

Consumers MUST key on the VALUE.  1 means repair or restart is legitimate; 5 means alert and
never restart.  `!= 0 -> restart` must not be written: a stall is exactly the state that
measurement shows recovers by itself (bound 212 s in, serving at 542 s, 2026-10-07), and a
restart re-enters the drain window that turned one restart into a 15.5-minute outage
(2026-09-22).  A stall is not a plain failure, and must not be read as one.

`oc health` returns this code unchanged (scripts/09e-oc-health.sh::oc-health), so the same
contract governs the shell command.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request
from typing import Any

# The systemd user unit `so` drives and this checker observes.
GATEWAY_UNIT = "openclaw-gateway.service"

# How long a start may be called STARTING on wall-clock evidence ALONE — the elapsed
# bound used when there is NO post-bind evidence.  The cold start this host shows,
# measured 2026-10-06 and earlier: the HTTP listener opens ~58 s after the unit starts
# on an ordinary day; 102.5 s and 130.5 s on merely-busy starts (the Gateway's own
# "http server listening (…; Ns)" lines); 341 s wall time (298.7 s internal) on the
# 19:06 BST start; 347 s under heavy lane load.  This bound is the worst of those plus
# headroom, and it covers the PRE-bind phase (config, auth, broker, HTTP transport).
#
# KEPT AT 420 BY DECISION (Wayne, 2026-10-07).  The state that motivated raising it —
# unit active, listener bound, /health still dark — got its own signal instead
# (GATEWAY_POST_BIND_GRACE_S below), because a larger number only moves the same
# wall-clock deadline and would hide a stall that may warrant a FAIL.  Measured on a
# WSL boot that day (unit start 05:48:08 BST, no restart): the listener bound at
# 05:51:40 (212 s in), "ready" came at 05:57:10 (542 s in), and /health timed out at
# elapsed 470 s — past this bound.  Reaching that state now means the post-bind signal
# has already had its say, so this bound never has to fail it.
GATEWAY_COLD_START_BOUND_S = 420

# How long a BOUND listener may stay dark before the verdict is STALLED, not STARTING.
# Chosen from measurement (2026-10-07), not taste:
#   * an ordinary start SERVES AS IT BINDS — the listener and the HTTP server appear
#     together, ~58 s after the unit starts, so a normal post-bind dark interval is
#     seconds, not minutes;
#   * the worst merely-busy starts measured here are 102.5 s and 130.5 s end-to-end;
#   * the anomaly this exists for: bound at 212 s, first /health 200 at 542 s — a
#     330 s post-bind dark interval.
# 150 s is the largest non-heavy normal start (130.5 s) plus ~15% headroom: no normal
# start can reach it (a normal start is not dark for minutes after binding), and it
# fires 180 s before the measured anomaly's darkness, with margin.  The interval is
# measured from the journal's own "[gateway] http server listening" timestamp, handed
# over as OC_HEALTH_GATEWAY_BOUND_AGE_S by __so_gateway_bound_age (scripts/09a) — the
# checker receives a NUMBER, never a second lifecycle classifier.
GATEWAY_POST_BIND_GRACE_S = 150


def _note(message: str) -> None:
    """Report a non-fatal read failure on stderr, never on stdout.

    These are diagnostics, not row output: a note on stdout would corrupt the
    ``--json`` contract and the ``--plain`` pipe, both of which read stdout alone.
    """
    print(f"[oc-health-check] {message}", file=sys.stderr)


def _check_tcp_port(host: str, port: int, timeout: float = 1.5) -> bool:
    """Whether a TCP connect to ``host:port`` is accepted.

    ``OSError`` here is the probe's NEGATIVE answer (nothing accepting a connection),
    not a swallowed fault, so it carries no note.  It is a SECONDARY signal: prefer
    ``_check_port_bound``, because a saturated event loop can refuse a connect while
    the listener exists (measured 2026-10-07).
    """
    try:
        with socket.create_connection((host, port), timeout=timeout):
            return True
    except OSError:
        return False


def _socket_table_listening(port: int) -> bool | None:
    """Whether the kernel's socket table shows a listener on ``port``.

    This is the evidence ``so`` acts on: ``__test_port`` (scripts/06-hooks.sh) runs
    ``ss -tln "sport = :<port>"``.  Reading the SAME table is what stops the two
    commands disagreeing about one moment.  A connect is not equivalent — measured
    2026-10-07, during a Gateway cold start a saturated event loop refused the 1.5 s
    connect (``oc health`` -> FAIL) while ``ss -ltn`` showed two LISTEN rows and ``so``
    correctly read STARTING.

    Returns True/False when ``ss`` answered, and None when it could not be asked (no
    ``ss``, a timeout, a non-zero exit) so the caller can tell "not bound" apart from
    "could not ask" and fall back to a connect instead of inventing a verdict.
    """
    if shutil.which("ss") is None:
        return None
    try:
        # The SAME invocation __test_port uses (scripts/06-hooks.sh), so a drift in
        # either is visible as a difference between the two commands.
        result = _run(["ss", "-tln", f"sport = :{port}"], timeout=3.0)
    except (subprocess.TimeoutExpired, OSError) as exc:
        _note(f"`ss` could not be read for port {port} ({exc}); using a connect probe")
        return None
    if result.returncode != 0:
        _note(f"`ss -tln` exited {result.returncode} for port {port}; using a connect probe")
        return None
    return "LISTEN" in (result.stdout or "")


def _check_port_bound(port: int) -> tuple[bool, dict[str, object]]:
    """Whether ``port`` is bound, preferring the socket table over a connect.

    The socket table is authoritative when ``ss`` answers, because it is the source
    ``so`` reads; the connect is only a fallback for when the table could not be read,
    so a saturated event loop can no longer turn a bound port into a FAIL.  Returns the
    verdict with the evidence behind it, so a caller can name what it saw.
    """
    table = _socket_table_listening(port)
    if table is not None:
        return table, {"socket_table": table, "connect": None}
    connect = _check_tcp_port("127.0.0.1", port)
    return connect, {"socket_table": None, "connect": connect}


def _run(cmd: list[str], timeout: float = 3.0) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        cmd,
        check=False,
        text=True,
        capture_output=True,
        timeout=timeout,
    )


def _status_rank(status: str) -> int:
    # `starting` is a NORMAL transient, so it ranks above `info` (we know more than
    # "informational") but below `warn` (nothing is deviating): a gateway mid cold
    # start must not out-shout a genuine warning, and must not be a `fail`.
    # `stalled` is the post-bind anomaly — the gateway is bound but has been dark past
    # the grace, which is real news, so it outranks `warn`; it is short of `fail`
    # because the start may still complete (measured: ours did).
    order = {"ok": 0, "info": 1, "starting": 2, "warn": 3, "stalled": 4, "fail": 5}
    return order.get(status, 5)


def _summary_status(checks: list[dict[str, object]]) -> str:
    worst = "ok"
    for c in checks:
        s = str(c.get("status", "fail"))
        if _status_rank(s) > _status_rank(worst):
            worst = s
    return worst


def _check_openclaw_cli() -> dict[str, object]:
    cli_path = shutil.which("openclaw")
    if not cli_path:
        return {
            "name": "openclaw_cli",
            "status": "fail",
            "message": "openclaw not found on PATH",
            "details": {"path": None},
        }

    try:
        result = _run(["openclaw", "--version"], timeout=4.0)
    except subprocess.TimeoutExpired:
        return {
            "name": "openclaw_cli",
            "status": "warn",
            "message": "openclaw --version timed out",
            "details": {"path": cli_path},
        }

    if result.returncode == 0:
        version = (result.stdout or result.stderr).strip().splitlines()
        return {
            "name": "openclaw_cli",
            "status": "ok",
            "message": "CLI available",
            "details": {"path": cli_path, "version": version[0] if version else "unknown"},
        }

    return {
        "name": "openclaw_cli",
        "status": "warn",
        "message": f"openclaw --version failed (rc={result.returncode})",
        "details": {
            "path": cli_path,
            "stderr": (result.stderr or "").strip()[:300],
        },
    }


def _check_gateway_port(port: int) -> dict[str, object]:
    listening, evidence = _check_port_bound(port)
    return {
        "name": "gateway_port",
        "status": "ok" if listening else "fail",
        "message": f"port {port} listening" if listening else f"port {port} not listening",
        "details": {"port": port, "listening": listening, **evidence},
    }


def _gateway_unit_start() -> dict[str, object]:
    """Read the gateway unit's ActiveState and start age from systemd.

    Returns ``{"available": bool, "active_state": str, "elapsed_s": int | None}``.
    ``available`` is False when ``systemctl`` is missing or the read fails, so a
    caller can tell "the unit is not active" apart from "could not ask".
    """
    if shutil.which("systemctl") is None:
        return {"available": False, "active_state": "", "elapsed_s": None}

    try:
        result = _run(
            [
                "systemctl",
                "--user",
                "show",
                "-p",
                "ActiveState",
                "-p",
                "ExecMainStartTimestamp",
                "--timestamp=unix",
                GATEWAY_UNIT,
            ],
            timeout=3.0,
        )
    except subprocess.TimeoutExpired:
        return {
            "available": False,
            "active_state": "",
            "elapsed_s": None,
            "error": "systemctl timed out",
        }

    active_state = ""
    start_epoch: float | None = None
    for line in (result.stdout or "").splitlines():
        key, _, value = line.partition("=")
        value = value.strip()
        if key == "ActiveState":
            active_state = value
        elif key == "ExecMainStartTimestamp":
            # --timestamp=unix prints `@<epoch>`; strip the marker before parsing.
            epoch = value.lstrip("@")
            if epoch:
                try:
                    start_epoch = float(epoch)
                except ValueError:
                    start_epoch = None

    elapsed = None
    if start_epoch is not None:
        elapsed = int(max(0.0, time.time() - start_epoch))
    return {"available": True, "active_state": active_state, "elapsed_s": elapsed}


def _gateway_bind_age(elapsed: int | None) -> int | None:
    """Seconds since the HTTP listener bound, from ``OC_HEALTH_GATEWAY_BOUND_AGE_S``.

    The value is produced by ``__so_gateway_bound_age`` (scripts/09a-oc-gateway.sh),
    which reads the journal's own "[gateway] http server listening" timestamp, so the
    journal parsing stays in one module and the checker never grows a second lifecycle
    classifier.  Returns None when the variable is absent, empty or unparseable, and
    when the reported age is OLDER than the unit's own start — a line that old is from
    a previous incarnation inside the classifier's window, and using it would fake a
    stall.  ``None`` means "no post-bind evidence", which the caller answers with the
    elapsed bound.
    """
    raw = os.getenv("OC_HEALTH_GATEWAY_BOUND_AGE_S", "").strip()
    if not raw:
        return None
    try:
        age = int(raw)
    except ValueError:
        _note(f"OC_HEALTH_GATEWAY_BOUND_AGE_S is not an integer ({raw!r}); ignoring it")
        return None
    if age < 0:
        _note(f"OC_HEALTH_GATEWAY_BOUND_AGE_S is negative ({age}); ignoring it")
        return None
    if elapsed is not None and age > elapsed + 5:
        _note(f"bound age {age}s is older than the unit's own age {elapsed}s; ignoring the stale line")
        return None
    return age


def _gateway_unreachable_verdict(port: int, url: str, error: str) -> dict[str, object]:
    """Decide STARTING / STALLED / FAIL when ``/health`` did not answer.

    A bound port is not a serving gateway: on this host the port binds BEFORE the HTTP
    server serves, so a probe inside that window reports "unreachable" for a Gateway
    behaving exactly as designed.  Three states must stay apart, using the evidence
    this checker actually has — the unit's ActiveState and start age, the socket table,
    the journal classifier's verdict, and the listener's bind age:

    STARTING  the unit is active, the journal does not claim the gateway is serving,
              and the start is inside its budget for its phase: unbounded-before-bind
              gives the start ``GATEWAY_COLD_START_BOUND_S``; a bound listener has
              ``GATEWAY_POST_BIND_GRACE_S`` of post-bind darkness (an ordinary start
              serves as it binds, so a normal post-bind interval is seconds).
    STALLED   the same, except the listener has been bound and dark LONGER than that
              grace — the state measured 2026-10-07 (bound 212 s in, first /health 200
              at 542 s: 330 s of post-bind darkness).  It is neither a normal start nor
              a proven failure: the start may still complete, and a restart re-enters
              the drain window, so the row says "do not restart".
    FAIL      every other case: an inactive/failed unit, a journal that says the
              gateway is running, degraded or draining (those are not a cold start),
              or a start with no journal verdict that has run past its phase's budget.

    A bound port is NOT a precondition for STARTING: the earliest phase of a cold start
    (unit active, listener not yet open) is a start too, and requiring a bound port made
    it read FAIL — the same false red as the bound-but-refused case, one phase earlier.
    """
    phase = os.getenv("OC_HEALTH_GATEWAY_PHASE", "").strip().lower()
    port_bound, port_evidence = _check_port_bound(port)
    unit = _gateway_unit_start()
    elapsed = unit.get("elapsed_s")
    elapsed_s = elapsed if isinstance(elapsed, int) else None
    bind_age = _gateway_bind_age(elapsed_s)
    unit_active = unit.get("available") is True and unit.get("active_state") == "active"
    within_bound = elapsed_s is not None and elapsed_s <= GATEWAY_COLD_START_BOUND_S
    # `running`/`degraded` claim the gateway IS serving, and `draining` is a real
    # outage: neither is a cold start, so the endpoint being unreachable is a fault.
    phase_allows_start = phase not in {"running", "degraded", "draining"}

    details: dict[str, object] = {
        "url": url,
        "error": error,
        "phase": phase or "unknown",
        "port_bound": port_bound,
        "unit_active": unit_active,
        "elapsed_s": elapsed,
        "bound_s": GATEWAY_COLD_START_BOUND_S,
        "within_bound": within_bound,
        "bind_age_s": bind_age,
        "post_bind_grace_s": GATEWAY_POST_BIND_GRACE_S,
        **port_evidence,
    }

    if unit_active and phase_allows_start and port_bound and phase == "starting":
        # The listener is up and the journal reports a start in progress: the only
        # question left is whether the post-bind dark interval is still normal.  With no
        # bind age there is nothing to measure it with, so a journal-reported start is
        # trusted (a wedge stops logging, and the phase then stops saying `starting`).
        if bind_age is not None and bind_age > GATEWAY_POST_BIND_GRACE_S:
            return {
                "name": "gateway_health",
                "status": "stalled",
                "message": (
                    f"gateway stalled: listener bound {bind_age}s ago, /health still dark "
                    f"(post-bind grace {GATEWAY_POST_BIND_GRACE_S}s); do not restart"
                ),
                "details": details,
            }
        bound_note = (
            f"listener bound {bind_age}s ago" if bind_age is not None else "port bound"
        )
        return {
            "name": "gateway_health",
            "status": "starting",
            "message": (
                f"gateway starting: {bound_note}, not serving yet "
                f"(post-bind grace {GATEWAY_POST_BIND_GRACE_S}s)"
            ),
            "details": details,
        }

    if unit_active and phase_allows_start and within_bound:
        port_note = "port bound, " if port_bound else "port not bound yet, "
        return {
            "name": "gateway_health",
            "status": "starting",
            "message": (
                f"gateway starting: {port_note}not serving yet "
                f"(elapsed {elapsed_s}s; cold-start bound {GATEWAY_COLD_START_BOUND_S}s)"
            ),
            "details": details,
        }

    return {
        "name": "gateway_health",
        "status": "fail",
        "message": "health endpoint unreachable",
        "details": details,
    }


def _check_gateway_health(port: int) -> dict[str, object]:
    url = f"http://127.0.0.1:{port}/health"
    started = time.time()
    try:
        with urllib.request.urlopen(url, timeout=3.0) as resp:
            body = resp.read().decode("utf-8", errors="replace")
            elapsed_ms = int((time.time() - started) * 1000)
    except urllib.error.HTTPError as exc:
        return {
            "name": "gateway_health",
            "status": "warn",
            "message": f"health endpoint HTTP {exc.code}",
            "details": {"url": url, "http_status": exc.code},
        }
    except (urllib.error.URLError, OSError, ValueError) as exc:
        return _gateway_unreachable_verdict(port, url, str(exc))

    try:
        payload = json.loads(body)
    except json.JSONDecodeError:
        return {
            "name": "gateway_health",
            "status": "warn",
            "message": "health response is not valid JSON",
            "details": {"url": url, "response_ms": elapsed_ms, "body": body[:240]},
        }

    ok_val = payload.get("ok")
    status_val = str(payload.get("status", "unknown"))
    is_ok = bool(ok_val is True or status_val.lower() in {"ok", "healthy"})
    return {
        "name": "gateway_health",
        "status": "ok" if is_ok else "warn",
        "message": f"gateway health: {status_val}",
        "details": {
            "url": url,
            "response_ms": elapsed_ms,
            "ok": ok_val,
            "status": status_val,
        },
    }


def _check_llm_port(port: int) -> dict[str, object]:
    listening, evidence = _check_port_bound(port)
    return {
        "name": "llm_port",
        "status": "ok" if listening else "warn",
        "message": f"LLM port {port} listening" if listening else f"LLM port {port} not listening",
        "details": {"port": port, "listening": listening, **evidence},
    }


def _check_systemd_gateway() -> dict[str, object]:
    if shutil.which("systemctl") is None:
        return {
            "name": "gateway_service",
            "status": "info",
            "message": "systemctl unavailable; service state skipped",
            "details": {},
        }

    result = _run(["systemctl", "--user", "is-active", "openclaw-gateway.service"], timeout=2.0)
    state = (result.stdout or "").strip()

    if result.returncode == 0 and state == "active":
        status = "ok"
        msg = "openclaw-gateway.service active"
    elif state:
        status = "warn"
        msg = f"openclaw-gateway.service state: {state}"
    else:
        status = "warn"
        msg = "openclaw-gateway.service state unavailable"

    return {
        "name": "gateway_service",
        "status": status,
        "message": msg,
        "details": {
            "state": state,
            "stderr": (result.stderr or "").strip()[:240],
        },
    }


def _check_jq() -> dict[str, object]:
    jq_path = shutil.which("jq")
    return {
        "name": "jq",
        "status": "ok" if jq_path else "warn",
        "message": "jq available" if jq_path else "jq not found (some diagnostics features may degrade)",
        "details": {"path": jq_path},
    }


def build_report() -> dict[str, object]:
    oc_port = int(os.getenv("OC_PORT", "18789"))
    # Probe the PRODUCTION lane, not the scratch port.  LLM_PORT (8081) is where `so`
    # loads a duplicate on demand; the gateway actually talks to LLM_SERVICE_PORT
    # (llama-xe-minicpm5-1b-chat.service on 18081), so 8081 is closed whenever the
    # production lane is serving — checking it reported a healthy local stack as a
    # warning (same defect class already fixed in 09e-oc-health.sh).  The 18081
    # default stands alone for callers outside the console, where only
    # LLM_SERVICE_PORT is defined.
    llm_port = int(os.getenv("LLM_SERVICE_PORT", "18081"))

    checks: list[dict[str, object]] = [
        _check_openclaw_cli(),
        _check_gateway_port(oc_port),
        _check_gateway_health(oc_port),
        _check_llm_port(llm_port),
        _check_systemd_gateway(),
        _check_jq(),
    ]

    summary = _summary_status(checks)
    return {
        "timestamp": int(time.time()),
        "summary": summary,
        "ports": {"gateway": oc_port, "llm": llm_port},
        "checks": checks,
    }


def _symbol(status: str) -> str:
    return {
        "ok": "[OK]",
        "warn": "[WARN]",
        "fail": "[FAIL]",
        "info": "[INFO]",
        "starting": "[STARTING]",
        "stalled": "[STALLED]",
    }.get(status, "[FAIL]")


def print_human(report: dict[str, Any], verbose: bool = False) -> None:
    summary = str(report.get("summary", "fail")).upper()
    print(f"OpenClaw Health Summary: {summary}")
    print("")
    for check in report.get("checks", []):
        name = str(check.get("name", "unknown"))
        status = str(check.get("status", "fail"))
        msg = str(check.get("message", ""))
        print(f"{_symbol(status)} {name}: {msg}")
        if verbose:
            details = check.get("details") or {}
            if details:
                print(f"       details: {json.dumps(details, ensure_ascii=True, sort_keys=True)}")


# The consumer contract lives in ONE greppable place.  The SUMMARY decides the code (the
# module docstring states the reasoning):
#   0  ok | info | warn | starting — healthy, degraded, or a NORMAL cold start;
#   5  stalled — the listener is bound and dark past the post-bind grace: ALERT, NEVER
#      RESTART.  It has its own value because the exit status is the only channel a
#      wrapper or a monitor reads, and a stall that reads as a plain failure invites the
#      restart that re-enters the drain window (measured 2026-09-22: one restart became a
#      15.5-minute outage);
#   1  fail — an inactive unit, or a start that has stopped producing evidence, where
#      repair or restart IS legitimate.
# `EXIT_UNRECOGNISED` is the conservative default: a status added without an exit decision
# must not read as success (the tests pin the mapping's keys so it cannot go stale).
EXIT_BY_SUMMARY = {
    "ok": 0,
    "info": 0,
    "warn": 0,
    "starting": 0,
    "stalled": 5,
    "fail": 1,
}
EXIT_UNRECOGNISED = 1


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Richer OpenClaw health diagnostics",
        epilog=(
            "exit codes (consumers must key on the VALUE, never on `!= 0`):\n"
            "  0  ok | info | warn | starting — healthy, degraded, or a normal cold start\n"
            "  5  stalled — listener bound and dark past the post-bind grace: ALERT, never restart\n"
            "  1  fail — inactive unit, or a start that stopped producing evidence; also the\n"
            "     default for an unrecognised summary\n"
            "Never write `!= 0 -> restart`: a stall recovers by itself, and a restart\n"
            "re-enters the drain window."
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--json", action="store_true", help="Emit JSON report")
    parser.add_argument("--verbose", action="store_true", help="Verbose human output")
    args = parser.parse_args(argv)

    report = build_report()
    if args.json:
        print(json.dumps(report, ensure_ascii=True, separators=(",", ":")))
    else:
        print_human(report, verbose=args.verbose)

    # The code comes from the mapping, not from a boolean: `starting` (a normal cold start)
    # and `stalled` (bound, dark, may still recover) must not read as `fail`, while
    # `stalled` must NOT read as success either — that would be a silent channel.  The two
    # transients therefore get 0 and 5 respectively, and only `fail` gets 1.
    summary = str(report.get("summary"))
    return EXIT_BY_SUMMARY.get(summary, EXIT_UNRECOGNISED)


if __name__ == "__main__":
    sys.exit(main())
