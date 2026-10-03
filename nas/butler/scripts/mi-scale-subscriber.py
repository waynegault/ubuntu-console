#!/opt/bin/python3
"""NAS Mi Scale MQTT subscriber - lightweight, no local imports needed beyond paho"""
import json
import logging
import signal
import time

import paho.mqtt.client as mqtt
from pathlib import Path

from lib.butler_common import post_line_protocol

logger = logging.getLogger(__name__)

SHARED_FILE = Path("/mnt/HD/HD_a2/butler/shared-data/weight-monitor/latest.json")
HISTORY_FILE = Path("/mnt/HD/HD_a2/butler/shared-data/weight-monitor/history.jsonl")

INFLUX = {"host": "127.0.0.1", "port": 8086, "db": "sensor_data", "meas": "body_composition"}
running = True

def write_shared(data):
    data["sourceTimestamp"] = data.get("sourceTimestamp", time.strftime("%Y-%m-%dT%H:%M:%S.000000+00:00", time.gmtime()))
    data["source"] = "mi_scale"
    with open(SHARED_FILE, "w") as f:
        json.dump(data, f, indent=2, default=str)
    if HISTORY_FILE:
        with open(HISTORY_FILE, "a") as f:
            f.write(json.dumps(data, default=str) + "\n")

def write_influx(tags, fields, ts_ns):
    line = f"{INFLUX['meas']},{','.join(f'{k}={v}' for k,v in sorted(tags.items()))} {','.join(f'{k}={v}' for k,v in sorted(fields.items()))} {ts_ns}"
    url = f"http://{INFLUX['host']}:{INFLUX['port']}/write?db={INFLUX['db']}"
    try:
        status = post_line_protocol(url, line, timeout=5)
        if status != 204:
            # A non-204 is InfluxDB refusing the write — name it rather than
            # discarding the only signal that the point did not land.
            logger.warning("influx write returned HTTP %s (expected 204)", status)
    except Exception:
        # A failed write used to vanish here; the shared-file copy still lands, but
        # the time-series gap must be visible.
        logger.warning("influx write failed", exc_info=True)

def on_connect(c, u, f, r, p):
    c.subscribe("bt/mi_scale/#")
    c.subscribe("bt/scan/#")
    c.subscribe("mi/#")

def on_msg(c, u, m):
    try:
        data = json.loads(m.payload)
    except Exception:
        # A non-JSON payload on the topic is skipped, not fatal; log it at debug so
        # a misbehaving publisher is diagnosable.
        logger.debug("ignoring non-JSON MQTT payload on %s", m.topic, exc_info=True)
        return
    mac = data.get("mac", data.get("address", ""))
    weight = data.get("weight_kg", data.get("weight"))
    if weight and float(weight) > 1 and float(weight) < 300:
        w = float(weight)
        stab = bool(data.get("stabilized", data.get("is_stabilized", True)))
        ts_ns = int(time.time() * 1e9)
        tags = {"mac": mac, "device": "Xiaomi_Mi_Scale_2"}
        fields = {"weight_kg": w, "stabilized": 1 if stab else 0}
        write_influx(tags, fields, ts_ns)
        result = {"mac": mac, "weight_kg": w, "stabilized": stab, "topic": m.topic}
        write_shared(result)

def handler(s, f):
    global running
    running = False


def main() -> None:
    """Connect, subscribe and loop until SIGTERM/SIGINT."""
    # Deferred from module scope so importing this file has no side effect (the NAS
    # path is unwritable elsewhere), and so write_shared's directory exists first.
    SHARED_FILE.parent.mkdir(parents=True, exist_ok=True)
    signal.signal(signal.SIGTERM, handler)
    signal.signal(signal.SIGINT, handler)

    c = mqtt.Client(callback_api_version=mqtt.CallbackAPIVersion.VERSION2, client_id="nas-mi-scale-sub", clean_session=True)
    c.on_connect = on_connect
    c.on_message = on_msg
    c.connect("127.0.0.1", 1883, 60)
    c.loop_start()

    while running:
        time.sleep(1)
    c.disconnect()


if __name__ == "__main__":
    main()
