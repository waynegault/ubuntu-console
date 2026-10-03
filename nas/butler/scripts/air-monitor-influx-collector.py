#!/usr/bin/env python3
"""Collect an Airrohr sensor payload and write it to InfluxDB.

The InfluxDB write is deliberately NOT wrapped: a failed write raises, so the run
cannot print `ok: true` while the series was never stored.
"""
import argparse
import datetime
import json
import logging
import os
import sys
import urllib.request
from pathlib import Path
from typing import Any

logger = logging.getLogger(__name__)

SENSOR_URL = os.environ.get("AIRMON_SENSOR_URL", "http://192.168.33.2/data.json")
INFLUX_URL = os.environ.get("AIRMON_INFLUX_URL", "http://127.0.0.1:8086/write?db=sensor_data")
OUT_DIR = Path("/mnt/HD/HD_a2/butler/openclaw-data/air-monitor")


def _parse_metrics(payload: dict) -> dict[str, float]:
    """Numeric sensor fields from the Airrohr payload."""
    metrics: dict[str, float] = {}
    for item in payload.get("sensordatavalues", []):
        key = item.get("value_type")
        if not key:
            continue
        try:
            metrics[key] = float(item.get("value"))
        except Exception:
            # A non-numeric value for one field is skipped; that field is optional
            # and the remaining metrics still post.  Benign by construction — the
            # alternative is dropping the whole sample over one bad field.
            logger.debug("skipping non-numeric sensor field %r=%r", key, item.get("value"), exc_info=True)
            continue
    return metrics


def _write_influx(influx_url: str, line: str) -> int:
    """POST line protocol and return the HTTP status (raises on failure)."""
    req = urllib.request.Request(influx_url, data=line.encode("utf-8"), method="POST")
    req.add_header("Content-Type", "application/octet-stream")
    with urllib.request.urlopen(req, timeout=8) as r:
        return int(r.status)


def collect_once() -> dict[str, Any]:
    """Fetch one sample, write it to InfluxDB and to the shared files."""
    with urllib.request.urlopen(SENSOR_URL, timeout=12) as r:
        payload = json.loads(r.read().decode("utf-8"))

    metrics = _parse_metrics(payload)
    pm10 = metrics.get("SDS_P1")
    pm25 = metrics.get("SDS_P2")
    fields = []
    for key, value in metrics.items():
        safe_key = key.replace(" ", "_").replace(",", "_").replace("=", "_")
        # Always write numeric fields as float to avoid Influx field-type conflicts across samples.
        fields.append(safe_key + "=" + str(float(value)))
    if pm10 is not None:
        fields.append("pm10=" + str(float(pm10)))
    if pm25 is not None:
        fields.append("pm25=" + str(float(pm25)))

    if not fields:
        raise ValueError("No numeric sensor values found in payload")

    line = "air_quality,source=nas_pull,sensor=airrohr " + ",".join(fields)
    # Not wrapped: an InfluxDB outage must propagate, not exit 0 with ok:true.
    status = _write_influx(INFLUX_URL, line)

    now = datetime.datetime.now(datetime.timezone.utc).isoformat()
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    (OUT_DIR / "latest-raw.json").write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    summary = {
        "timestamp": now,
        "pm25": pm25,
        "pm10": pm10,
        "metrics": metrics,
        "source": "nas_pull",
        "influxStatus": status,
    }
    (OUT_DIR / "latest.json").write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
    with (OUT_DIR / "events.jsonl").open("a", encoding="utf-8") as f:
        f.write(json.dumps({"timestamp": now, "pm25": pm25, "pm10": pm10, "source": "nas_pull", "influxStatus": status}) + "\n")

    return {"ok": True, "timestamp": now, "influxStatus": status, "pm25": pm25, "pm10": pm10}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Collect Airrohr payload and write to InfluxDB")
    parser.add_argument("--once", action="store_true", help="Compatibility flag for one-shot cron invocation")
    parser.parse_args(argv)
    try:
        result = collect_once()
    except ValueError as exc:
        # Preserve the old `raise SystemExit("No numeric sensor values found ...")`
        # contract: the message on stderr and a non-zero exit.
        print(str(exc), file=sys.stderr)
        return 1
    print(json.dumps(result))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
