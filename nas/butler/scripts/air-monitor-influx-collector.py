#!/usr/bin/env python3
import argparse
import datetime
import json
import os
import urllib.request
from pathlib import Path

sensor_url = os.environ.get("AIRMON_SENSOR_URL", "http://192.168.33.2/data.json")
influx_url = os.environ.get("AIRMON_INFLUX_URL", "http://127.0.0.1:8086/write?db=sensor_data")
out_dir = Path("/mnt/HD/HD_a2/butler/openclaw-data/air-monitor")
out_dir.mkdir(parents=True, exist_ok=True)

parser = argparse.ArgumentParser(description="Collect Airrohr payload and write to InfluxDB")
parser.add_argument("--once", action="store_true", help="Compatibility flag for one-shot cron invocation")
parser.parse_args()

with urllib.request.urlopen(sensor_url, timeout=12) as r:
    payload = json.loads(r.read().decode("utf-8"))

metrics = {}
for item in payload.get("sensordatavalues", []):
    key = item.get("value_type")
    if not key:
        continue
    try:
        metrics[key] = float(item.get("value"))
    except Exception:
        continue

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
    raise SystemExit("No numeric sensor values found in payload")

line = "air_quality,source=nas_pull,sensor=airrohr " + ",".join(fields)
req = urllib.request.Request(influx_url, data=line.encode("utf-8"), method="POST")
req.add_header("Content-Type", "application/octet-stream")
with urllib.request.urlopen(req, timeout=8) as r:
    status = int(r.status)

now = datetime.datetime.now(datetime.timezone.utc).isoformat()
(out_dir / "latest-raw.json").write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
summary = {
    "timestamp": now,
    "pm25": pm25,
    "pm10": pm10,
    "metrics": metrics,
    "source": "nas_pull",
    "influxStatus": status,
}
(out_dir / "latest.json").write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
with (out_dir / "events.jsonl").open("a", encoding="utf-8") as f:
    f.write(json.dumps({"timestamp": now, "pm25": pm25, "pm10": pm10, "source": "nas_pull", "influxStatus": status}) + "\n")

print(json.dumps({"ok": True, "timestamp": now, "influxStatus": status, "pm25": pm25, "pm10": pm10}))
