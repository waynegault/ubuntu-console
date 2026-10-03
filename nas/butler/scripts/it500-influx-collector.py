#!/usr/bin/env python3
"""Stdlib-only Salus iT500 collector for NAS cron use.

This script avoids aiohttp and other third-party dependencies so it can run on
minimal NAS Python environments.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from datetime import datetime, timezone
from pathlib import Path

from lib.butler_common import post_line_protocol

URL_LOGIN = "https://sal-emea-p01-api.arrayent.com/acc/applications/SalusService/sessions"
URL_GET_DATA = "https://sal-emea-p01-api.arrayent.com/zdk/services/zamapi/getDeviceAttributesWithValues"
APP_AUTH = "687886-679716122"

ATTR_CURRENT_TEMP = "A84"
ATTR_TARGET_TEMP = "A85"
ATTR_HEATING_STATE = "A87"
ATTR_OFF_MODE = "A89"
ATTR_HOT_WATER_STATUS = "C45"

SECRETS = Path("/mnt/HD/HD_a2/butler/openclaw/secrets.json")
INFLUX_URL = os.environ.get("THERMOSTAT_INFLUX_URL", "http://127.0.0.1:8086/write?db=sensor_data")
OUT_DIR = Path("/mnt/HD/HD_a2/butler/openclaw-data/thermostat")
OUT_DIR.mkdir(parents=True, exist_ok=True)


def _json_request(url: str, *, method: str = "GET", headers: dict[str, str] | None = None, payload: dict | None = None, timeout: int = 30) -> dict:
    data = None
    req_headers = dict(headers or {})
    if payload is not None:
        data = json.dumps(payload).encode("utf-8")
        req_headers.setdefault("Content-Type", "application/json")
    req = urllib.request.Request(url, data=data, headers=req_headers, method=method)
    with urllib.request.urlopen(req, timeout=timeout) as response:
        body = response.read().decode("utf-8", errors="replace")
    return json.loads(body)


def _xml_get(url: str, params: dict[str, str], timeout: int = 30) -> ET.Element:
    full_url = f"{url}?{urllib.parse.urlencode(params)}"
    req = urllib.request.Request(full_url, method="GET")
    with urllib.request.urlopen(req, timeout=timeout) as response:
        body = response.read().decode("utf-8", errors="replace")
    return ET.fromstring(body)


def _xml_attr(root: ET.Element, name: str) -> str | None:
    node = root.find(f"./attrList/[name='{name}']/value")
    return node.text if node is not None else None


def _to_celsius(raw: str | None) -> float | None:
    if raw in (None, ""):
        return None
    return float(raw) * 0.01


def _post_influx(line: str) -> int:
    return post_line_protocol(INFLUX_URL, line, timeout=10)


def main() -> int:
    parser = argparse.ArgumentParser(description="Stdlib Salus iT500 collector")
    parser.add_argument("--once", action="store_true", help="Compatibility flag for one-shot invocation")
    parser.parse_args()

    if not SECRETS.exists():
        print(json.dumps({"ok": False, "error": "Missing secrets file", "path": str(SECRETS)}))
        return 2

    creds = json.loads(SECRETS.read_text(encoding="utf-8")).get("salus", {})
    username = (creds.get("username") or "").strip()
    password = (creds.get("password") or "").strip()
    device_id = (creds.get("device_id") or "").strip()
    if not (username and password and device_id):
        print(json.dumps({"ok": False, "error": "Missing salus credentials in secrets", "path": str(SECRETS)}))
        return 2

    password_hash = hashlib.md5(password.encode("utf-8")).hexdigest()
    login = _json_request(
        URL_LOGIN,
        method="POST",
        headers={"Authorization": APP_AUTH, "Accept": "application/json"},
        payload={"username": username, "password": password_hash},
    )
    token = (login.get("securityToken") or "").strip()
    if not token:
        print(json.dumps({"ok": False, "error": "Salus login returned no securityToken"}))
        return 2

    root = _xml_get(
        URL_GET_DATA,
        {
            "devId": device_id,
            "deviceTypeId": "1",
            "secToken": token,
        },
    )

    current_temp = _to_celsius(_xml_attr(root, ATTR_CURRENT_TEMP))
    target_temp = _to_celsius(_xml_attr(root, ATTR_TARGET_TEMP))
    heating_active = _xml_attr(root, ATTR_HEATING_STATE) == "1"
    hot_water_status = _xml_attr(root, ATTR_HOT_WATER_STATUS)
    hot_water_enabled = None if hot_water_status is None else (hot_water_status != "0")
    hvac_mode = "off" if _xml_attr(root, ATTR_OFF_MODE) == "1" else "heat"

    tags = "source=salus_it500,device_alias=it500,owner=Wayne123"
    fields = [
        f"current_temp={current_temp if current_temp is not None else 0.0}",
        f"target_temp={target_temp if target_temp is not None else 0.0}",
        f"heating_active={1 if heating_active else 0}i",
        f"hot_water_enabled={1 if hot_water_enabled else 0}i",
        f'hvac_mode="{hvac_mode}"',
    ]
    status = _post_influx(f"it500_env,{tags} {','.join(fields)}")

    observed_at = datetime.now(timezone.utc).isoformat()
    out = {
        "timestamp": observed_at,
        "current_temperature": current_temp,
        "target_temperature": target_temp,
        "hvac_mode": hvac_mode,
        "heating_active": heating_active,
        "hot_water_enabled": hot_water_enabled,
        "influxStatus": status,
    }
    (OUT_DIR / "latest.json").write_text(json.dumps(out, indent=2) + "\n", encoding="utf-8")
    with (OUT_DIR / "events.jsonl").open("a", encoding="utf-8") as fh:
        fh.write(json.dumps(out) + "\n")

    print(json.dumps({"ok": True, "influxStatus": status, "timestamp": observed_at}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
