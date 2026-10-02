#!/usr/bin/env python3
"""Collect CPAP data for OpenClaw and write canonical shared state.

This collector intentionally separates transport from normalization:
- adapter=file: read a JSON payload from disk (manual export or test fixture)
- adapter=command: execute an external command expected to emit JSON

The normalized output is written to:
- latest snapshot: /home/wayne/.openclaw/workspace/memory/shared/cpap-monitor/latest.json
- append-only history: /home/wayne/.openclaw/workspace/memory/shared/cpap-monitor/history.jsonl
"""

from __future__ import annotations

import argparse
import json
import os
import shlex
import subprocess
import urllib.parse
import urllib.request
from datetime import date, datetime, timezone
from pathlib import Path
from typing import Any

DATA_DIR = Path(
    os.environ.get(
        "CPAP_DATA_DIR",
        "/home/wayne/.openclaw/workspace/memory/shared/cpap-monitor",
    )
)
LATEST_FILE = DATA_DIR / "latest.json"
HISTORY_FILE = DATA_DIR / "history.jsonl"
DEFAULT_SOURCE = os.environ.get("CPAP_SOURCE", "myair")
DEFAULT_REGION = os.environ.get("CPAP_REGION", "EU")
DEFAULT_USER = os.environ.get("CPAP_MYAIR_USERNAME", "")
DEFAULT_COMMAND = os.environ.get("CPAP_COLLECT_COMMAND", "")
INFLUX_ENABLED = os.environ.get("CPAP_INFLUX_ENABLED", "true").strip().lower() in {"1", "true", "yes", "on"}
INFLUX_HOST = os.environ.get("CPAP_INFLUX_HOST", "192.168.33.17")
INFLUX_PORT = os.environ.get("CPAP_INFLUX_PORT", "8086")
INFLUX_DB = os.environ.get("CPAP_INFLUX_DB", "sensor_data")
INFLUX_MEASUREMENT = os.environ.get("CPAP_INFLUX_MEASUREMENT", "cpap_myair")


class CollectorError(RuntimeError):
    """Raised when collection fails in a controlled and explainable way."""


def _utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def _ensure_data_dir() -> None:
    DATA_DIR.mkdir(parents=True, exist_ok=True)


def _write_json(path: Path, payload: dict[str, Any]) -> None:
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(payload, indent=2, ensure_ascii=True) + "\n", encoding="utf-8")
    tmp.replace(path)


def _append_jsonl(path: Path, payload: dict[str, Any]) -> None:
    with path.open("a", encoding="utf-8") as fh:
        fh.write(json.dumps(payload, ensure_ascii=True) + "\n")


def _escape_tag(value: Any) -> str:
    return str(value).replace(" ", "\\ ").replace(",", "\\,").replace("=", "\\=")


def _influx_base() -> str:
    return f"http://{INFLUX_HOST}:{INFLUX_PORT}"


def _post_influx(line_protocol: str) -> int:
    url = f"{_influx_base()}/write?{urllib.parse.urlencode({'db': INFLUX_DB})}"
    req = urllib.request.Request(url, data=line_protocol.encode("utf-8"), method="POST")
    req.add_header("Content-Type", "application/octet-stream")
    with urllib.request.urlopen(req, timeout=5) as response:
        return int(response.status)


def _influx_line(payload: dict[str, Any]) -> str:
    metrics = payload.get("metrics", {})
    quality = payload.get("quality", {})
    device = payload.get("device", {})
    timestamp = payload.get("timestamp") or _utc_now()

    try:
        ts = datetime.fromisoformat(str(timestamp).replace("Z", "+00:00"))
        if ts.tzinfo is None:
            ts = ts.replace(tzinfo=timezone.utc)
        ts_ns = int(ts.timestamp() * 1e9)
        ts_part = f" {ts_ns}"
    except ValueError:
        ts_part = ""

    tags = [
        f"source={_escape_tag(payload.get('source') or 'unknown')}",
        f"region={_escape_tag(payload.get('region') or 'unknown')}",
        f"device_series={_escape_tag(device.get('deviceSeries') or 'unknown')}",
        f"device_family={_escape_tag(device.get('deviceFamily') or 'unknown')}",
        f"sleep_date={_escape_tag(metrics.get('latestDate') or 'unknown')}",
    ]

    field_parts: list[str] = []
    numeric_fields = {
        "ahi": metrics.get("ahi"),
        "usage_minutes": metrics.get("usageMinutes"),
        "mask_on_off_count": metrics.get("maskOnOffCount"),
        "leak_percent": metrics.get("leakPercent"),
        "myair_score": metrics.get("myAirScore"),
        "records_count": quality.get("recordsCount"),
        "days_since_latest_record": quality.get("daysSinceLatestRecord"),
    }
    integer_fields = {"mask_on_off_count", "records_count", "days_since_latest_record"}

    for key, value in numeric_fields.items():
        if value is None:
            continue
        if key in integer_fields:
            field_parts.append(f"{key}={int(value)}i")
        else:
            field_parts.append(f"{key}={float(value)}")

    field_parts.append(f"stale={str(bool(quality.get('stale', True))).lower()}")

    localized_name = device.get("localizedName")
    if localized_name:
        field_parts.append(f'localized_name="{str(localized_name).replace("\\", "\\\\").replace("\"", "\\\"")}"')

    last_report = device.get("lastSleepDataReportTime")
    if last_report:
        field_parts.append(f'last_sleep_data_report_time="{str(last_report).replace("\\", "\\\\").replace("\"", "\\\"")}"')

    return f"{INFLUX_MEASUREMENT},{','.join(tags)} {','.join(field_parts)}{ts_part}"


def _write_influx(payload: dict[str, Any]) -> dict[str, Any]:
    if not INFLUX_ENABLED:
        return {"enabled": False}
    line = _influx_line(payload)
    try:
        status = _post_influx(line)
    except Exception as exc:
        raise CollectorError(f"influx write failed: {exc}") from exc
    return {
        "enabled": True,
        "host": INFLUX_HOST,
        "db": INFLUX_DB,
        "measurement": INFLUX_MEASUREMENT,
        "status": status,
    }


def _load_input_file(path: Path) -> dict[str, Any]:
    if not path.exists():
        raise CollectorError(f"input file not found: {path}")
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        raise CollectorError(f"invalid JSON in input file {path}: {exc}") from exc


def _collect_timeout_seconds() -> int:
    """Timeout for the external collection command (CPAP_COLLECT_TIMEOUT_SECONDS).

    It must exceed the fetcher's OTP delivery window: since 2026-10-02 the fetcher
    triggers the email-MFA challenge and then polls for the code -- up to
    CPAP_MYAIR_OTP_INITIAL_DELAY_SECONDS + POLL_INTERVAL x (POLL_ATTEMPTS - 1), i.e.
    510s on this host. The previous hardcoded 120s would have SIGKILLed the fetch
    before a slow code mail could arrive (a 2026-09-22 run measured ~5.5 min mail
    latency). Falls back to 120s when the knob is unset or unparseable.
    """
    try:
        return max(1, int(os.environ.get("CPAP_COLLECT_TIMEOUT_SECONDS", "120")))
    except ValueError:
        return 120


def _run_external_json(command: str) -> dict[str, Any]:
    if not command.strip():
        raise CollectorError("CPAP_COLLECT_COMMAND is empty")

    proc = subprocess.run(
        shlex.split(command),
        capture_output=True,
        text=True,
        check=False,
        timeout=_collect_timeout_seconds(),
    )
    if proc.returncode != 0:
        stderr = proc.stderr.strip() or "(no stderr)"
        raise CollectorError(f"external command failed ({proc.returncode}): {stderr}")

    stdout = proc.stdout.strip()
    if not stdout:
        raise CollectorError("external command produced no JSON output")

    try:
        return json.loads(stdout)
    except json.JSONDecodeError as exc:
        raise CollectorError(f"external command produced invalid JSON: {exc}") from exc


def _parse_date(value: str | None) -> date | None:
    if not value:
        return None
    try:
        return date.fromisoformat(value)
    except ValueError:
        try:
            normalized = value.replace("Z", "+00:00")
            return datetime.fromisoformat(normalized).date()
        except ValueError:
            return None


def _normalise_payload(raw: dict[str, Any], *, source: str, region: str, username: str) -> dict[str, Any]:
    device = raw.get("device") or raw.get("device_data") or {}
    records = raw.get("sleep_records") or raw.get("records") or []
    if not isinstance(records, list):
        records = []

    latest_record: dict[str, Any] = {}
    for item in records:
        if not isinstance(item, dict):
            continue
        start_date = _parse_date(item.get("startDate"))
        if not latest_record:
            latest_record = item
            continue
        current_best = _parse_date(latest_record.get("startDate"))
        if start_date and (current_best is None or start_date > current_best):
            latest_record = item

    latest_date = _parse_date(latest_record.get("startDate"))
    today = datetime.now(timezone.utc).date()
    days_since_latest = None
    if latest_date:
        days_since_latest = (today - latest_date).days

    normalized = {
        "timestamp": _utc_now(),
        "source": source,
        "region": region,
        "usernameHint": username,
        "device": {
            "serialNumber": device.get("serialNumber"),
            "localizedName": device.get("localizedName"),
            "deviceSeries": device.get("deviceSeries"),
            "deviceFamily": device.get("deviceFamily"),
            "lastSleepDataReportTime": device.get("lastSleepDataReportTime"),
        },
        "metrics": {
            "latestDate": latest_date.isoformat() if latest_date else latest_record.get("startDate"),
            "ahi": latest_record.get("ahi"),
            "usageMinutes": latest_record.get("totalUsage"),
            "maskOnOffCount": latest_record.get("maskPairCount"),
            "leakPercent": latest_record.get("leakPercentile"),
            "myAirScore": latest_record.get("sleepScore"),
        },
        "quality": {
            "recordsCount": len(records),
            "daysSinceLatestRecord": days_since_latest,
            "stale": days_since_latest is None or days_since_latest > 1,
        },
        "raw": {
            "latestRecord": latest_record,
        },
    }
    return normalized


def collect_once(adapter: str, input_file: Path | None, command: str, source: str, region: str, username: str) -> dict[str, Any]:
    if adapter == "file":
        if input_file is None:
            raise CollectorError("--input-file is required when adapter=file")
        raw = _load_input_file(input_file)
    elif adapter == "command":
        raw = _run_external_json(command)
    else:
        raise CollectorError(f"unsupported adapter: {adapter}")

    return _normalise_payload(raw, source=source, region=region, username=username)


def cmd_collect_once(args: argparse.Namespace) -> int:
    try:
        payload = collect_once(
            adapter=args.adapter,
            input_file=args.input_file,
            command=args.command,
            source=args.source,
            region=args.region,
            username=args.username_hint,
        )
    except CollectorError as exc:
        print(json.dumps({"ok": False, "error": str(exc)}, ensure_ascii=True))
        return 2

    _ensure_data_dir()
    _write_json(LATEST_FILE, payload)
    _append_jsonl(HISTORY_FILE, payload)
    influx_result = _write_influx(payload)
    print(
        json.dumps(
            {
                "ok": True,
                "latest": str(LATEST_FILE),
                "history": str(HISTORY_FILE),
                "influx": influx_result,
            },
            ensure_ascii=True,
        )
    )
    return 0


def cmd_status(_: argparse.Namespace) -> int:
    if not LATEST_FILE.exists():
        print(json.dumps({"ok": False, "error": "latest file missing", "path": str(LATEST_FILE)}, ensure_ascii=True))
        return 1

    try:
        payload = json.loads(LATEST_FILE.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        print(json.dumps({"ok": False, "error": f"latest file invalid JSON: {exc}"}, ensure_ascii=True))
        return 2

    timestamp = payload.get("timestamp")
    age_seconds = None
    if isinstance(timestamp, str):
        try:
            ts = datetime.fromisoformat(timestamp)
            if ts.tzinfo is None:
                ts = ts.replace(tzinfo=timezone.utc)
            age_seconds = int((datetime.now(timezone.utc) - ts).total_seconds())
        except ValueError:
            age_seconds = None

    summary = {
        "ok": True,
        "latest": str(LATEST_FILE),
        "history": str(HISTORY_FILE),
        "timestamp": timestamp,
        "ageSeconds": age_seconds,
        "metrics": payload.get("metrics", {}),
        "quality": payload.get("quality", {}),
    }
    print(json.dumps(summary, ensure_ascii=True))
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Jarvis CPAP myAir collector")
    sub = parser.add_subparsers(dest="command", required=True)

    collect = sub.add_parser("collect-once", help="Collect one payload and write shared state")
    collect.add_argument("--adapter", choices=["file", "command"], default="command")
    collect.add_argument("--input-file", type=Path, default=None)
    collect.add_argument("--command", default=DEFAULT_COMMAND)
    collect.add_argument("--source", default=DEFAULT_SOURCE)
    collect.add_argument("--region", default=DEFAULT_REGION)
    collect.add_argument("--username-hint", default=DEFAULT_USER)
    collect.set_defaults(func=cmd_collect_once)

    status = sub.add_parser("status", help="Print machine-readable collector status")
    status.set_defaults(func=cmd_status)

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    return int(args.func(args))


if __name__ == "__main__":
    raise SystemExit(main())
