#!/opt/bin/python3
"""NAS Mi Scale MQTT subscriber - lightweight, no local imports needed beyond paho"""
import json
import signal
import time
import urllib.parse
import urllib.request

import paho.mqtt.client as mqtt
from pathlib import Path

SHARED_FILE = Path("/mnt/HD/HD_a2/butler/shared-data/weight-monitor/latest.json")
HISTORY_FILE = Path("/mnt/HD/HD_a2/butler/shared-data/weight-monitor/history.jsonl")
SHARED_FILE.parent.mkdir(parents=True, exist_ok=True)

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
        req = urllib.request.Request(url, data=line.encode())
        with urllib.request.urlopen(req, timeout=5) as r:
            if r.status != 204:
                pass
    except Exception:
        pass

def on_connect(c, u, f, r, p):
    c.subscribe("bt/mi_scale/#")
    c.subscribe("bt/scan/#")
    c.subscribe("mi/#")

def on_msg(c, u, m):
    try:
        data = json.loads(m.payload)
    except Exception:
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
