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
from typing import Dict, List, Optional


def _check_tcp_port(host: str, port: int, timeout: float = 1.5) -> bool:
    try:
        with socket.create_connection((host, port), timeout=timeout):
            return True
    except OSError:
        return False


def _run(cmd: List[str], timeout: float = 3.0) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        cmd,
        check=False,
        text=True,
        capture_output=True,
        timeout=timeout,
    )


def _status_rank(status: str) -> int:
    order = {"ok": 0, "info": 1, "warn": 2, "fail": 3}
    return order.get(status, 3)


def _summary_status(checks: List[Dict[str, object]]) -> str:
    worst = "ok"
    for c in checks:
        s = str(c.get("status", "fail"))
        if _status_rank(s) > _status_rank(worst):
            worst = s
    return worst


def _check_openclaw_cli() -> Dict[str, object]:
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


def _check_gateway_port(port: int) -> Dict[str, object]:
    listening = _check_tcp_port("127.0.0.1", port)
    return {
        "name": "gateway_port",
        "status": "ok" if listening else "fail",
        "message": f"port {port} listening" if listening else f"port {port} not listening",
        "details": {"port": port, "listening": listening},
    }


def _check_gateway_health(port: int) -> Dict[str, object]:
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
    except Exception as exc:  # noqa: BLE001
        return {
            "name": "gateway_health",
            "status": "fail",
            "message": "health endpoint unreachable",
            "details": {"url": url, "error": str(exc)},
        }

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


def _check_llm_port(port: int) -> Dict[str, object]:
    listening = _check_tcp_port("127.0.0.1", port)
    return {
        "name": "llm_port",
        "status": "ok" if listening else "warn",
        "message": f"LLM port {port} listening" if listening else f"LLM port {port} not listening",
        "details": {"port": port, "listening": listening},
    }


def _check_systemd_gateway() -> Dict[str, object]:
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


def _check_jq() -> Dict[str, object]:
    jq_path = shutil.which("jq")
    return {
        "name": "jq",
        "status": "ok" if jq_path else "warn",
        "message": "jq available" if jq_path else "jq not found (some diagnostics features may degrade)",
        "details": {"path": jq_path},
    }


def build_report() -> Dict[str, object]:
    oc_port = int(os.getenv("OC_PORT", "18789"))
    llm_port = int(os.getenv("LLM_PORT", "8081"))

    checks: List[Dict[str, object]] = [
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
    }.get(status, "[FAIL]")


def print_human(report: Dict[str, object], verbose: bool = False) -> None:
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


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(description="Richer OpenClaw health diagnostics")
    parser.add_argument("--json", action="store_true", help="Emit JSON report")
    parser.add_argument("--verbose", action="store_true", help="Verbose human output")
    args = parser.parse_args(argv)

    report = build_report()
    if args.json:
        print(json.dumps(report, ensure_ascii=True, separators=(",", ":")))
    else:
        print_human(report, verbose=args.verbose)

    return 0 if str(report.get("summary")) in {"ok", "info", "warn"} else 1


if __name__ == "__main__":
    sys.exit(main())
