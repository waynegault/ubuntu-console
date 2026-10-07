#!/usr/bin/env python3
"""Richer OpenClaw diagnostics helper used by `oc-health`.

Outputs:
- human (default): concise checklist
- --verbose: checklist + details
- --json: structured JSON for automation
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

# How long a start may be called STARTING on wall-clock evidence ALONE.  The cold
# start this host actually shows, measured 2026-10-06 and earlier: the HTTP listener
# opens ~58 s after the unit starts on an ordinary day; 102.5 s and 130.5 s on
# merely-busy starts (the Gateway's own "http server listening (…; Ns)" lines); 341 s
# wall time (298.7 s internal) on the 19:06 BST start; 347 s under heavy lane load.
# This bound is the worst of those plus headroom.
#
# It is the FALLBACK, not the only evidence.  Measured 2026-10-07 on a WSL boot (unit
# start 05:48:08 BST, MainPID 613675, no restart, no suspend; btime+uptime == now):
# the listener bound at 05:51:40 and "ready" came at 05:57:10 — a 542 s time-to-ready
# — with /health timing out at elapsed 470 s.  This bound had already expired, so a
# rule keyed on it alone read FAIL for a Gateway that was mid-start and then recovered
# by itself, while `so` (whose classifier carries no elapsed bound) read STARTING.
# The repair is the phase precondition in `_gateway_unreachable_verdict`, NOT a larger
# bound: raising it only moves the same wall-clock deadline and would swallow a stall
# that may warrant a FAIL.  This bound still decides whenever the journal cannot — no
# phase verdict, or one that is not `starting`.
GATEWAY_COLD_START_BOUND_S = 420


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
    order = {"ok": 0, "info": 1, "starting": 2, "warn": 3, "fail": 4}
    return order.get(status, 4)


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


def _gateway_unreachable_verdict(port: int, url: str, error: str) -> dict[str, object]:
    """Decide STARTING vs FAIL when ``/health`` did not answer.

    A bound port is not a serving gateway: on this host the port binds BEFORE the
    HTTP server serves (cold start measured 58-542 s), so a probe inside that window
    reports "unreachable" for a Gateway behaving exactly as designed.  STARTING needs
    an ACTIVE unit and a journal verdict that does not claim the gateway is already
    serving; the wall-clock bound is the FALLBACK evidence, used when the journal
    cannot decide (no phase verdict, or one that is not `starting`).

    A phase verdict of `starting` outranks the bound, because the bound exists only to
    stop a WEDGED gateway reading STARTING forever — and a wedge emits no further
    lifecycle lines, so its `starting` line ages out of the classifier's journal
    window, the phase then reads `unknown`, and the bound decides again.  Measured
    2026-10-07: a 542 s time-to-ready with /health timing out at elapsed 470 s, past
    the 420 s bound, for a Gateway that recovered by itself — while `so`, whose
    classifier has no elapsed bound, correctly read STARTING.

    A bound port STRENGTHENS that evidence and is named in the message, but it is not
    a precondition.  The earliest phase of a cold start — unit active, listener not
    yet open — is a start too, and requiring a bound port made it read FAIL here: the
    same false red as the bound-but-refused case, one phase earlier.

    FAIL is the verdict for every other case: an inactive/failed unit, a start past
    the bound with no journal verdict saying otherwise, or a journal that says the
    gateway is running, degraded or draining (those are not a cold start).
    """
    phase = os.getenv("OC_HEALTH_GATEWAY_PHASE", "").strip().lower()
    port_bound, port_evidence = _check_port_bound(port)
    unit = _gateway_unit_start()
    elapsed = unit.get("elapsed_s")
    unit_active = unit.get("available") is True and unit.get("active_state") == "active"
    within_bound = isinstance(elapsed, int) and elapsed <= GATEWAY_COLD_START_BOUND_S
    # `running`/`degraded` claim the gateway IS serving, and `draining` is a real
    # outage: neither is a cold start, so the endpoint being unreachable is a fault.
    phase_allows_start = phase not in {"running", "degraded", "draining"}
    phase_in_progress = phase == "starting"

    details: dict[str, object] = {
        "url": url,
        "error": error,
        "phase": phase or "unknown",
        "port_bound": port_bound,
        "unit_active": unit_active,
        "elapsed_s": elapsed,
        "bound_s": GATEWAY_COLD_START_BOUND_S,
        "within_bound": within_bound,
        **port_evidence,
    }

    if unit_active and phase_allows_start and (within_bound or phase_in_progress):
        port_note = "port bound, " if port_bound else "port not bound yet, "
        if phase_in_progress and not within_bound:
            bound_note = (
                f"elapsed {elapsed}s is past the {GATEWAY_COLD_START_BOUND_S}s fallback "
                "bound, but the journal still reports a start in progress"
            )
        else:
            bound_note = (
                f"elapsed {elapsed}s; cold-start bound {GATEWAY_COLD_START_BOUND_S}s"
            )
        return {
            "name": "gateway_health",
            "status": "starting",
            "message": f"gateway starting: {port_note}not serving yet ({bound_note})",
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


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Richer OpenClaw health diagnostics")
    parser.add_argument("--json", action="store_true", help="Emit JSON report")
    parser.add_argument("--verbose", action="store_true", help="Verbose human output")
    args = parser.parse_args(argv)

    report = build_report()
    if args.json:
        print(json.dumps(report, ensure_ascii=True, separators=(",", ":")))
    else:
        print_human(report, verbose=args.verbose)

    # `starting` is a transient, not a failure: it must not exit 1, or a wrapper's
    # `oc health && …` treats a cold start as a red box (the defect this verdict
    # exists to remove).
    return 0 if str(report.get("summary")) in {"ok", "info", "starting", "warn"} else 1


if __name__ == "__main__":
    sys.exit(main())
