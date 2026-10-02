#!/usr/bin/env python3
"""Collect Xiaomi Mi Body Composition Scale 2 readings via Bluetooth LE.

This script collects body composition metrics (weight, body fat %, BMI, muscle,
bone mass, water %) from the Mi Body Composition Scale 2 and writes canonical
shared files for Kai analysis, with optional InfluxDB writes.

Device: Xiaomi Mi Body Composition Scale 2
Bluetooth Address: d8:e7:2f:08:7c:5d
Protocol: BLE GATT with notify characteristics
"""

from __future__ import annotations

import argparse
import asyncio
import json
import os
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

try:
    from bleak import BleakClient, BleakScanner
    HAS_BLEAK = True
except ImportError:
    HAS_BLEAK = False

DEFAULT_ALIAS = os.environ.get("MI_SCALE_ALIAS", "Body composition scale")
DEFAULT_TARGET = os.environ.get("MI_SCALE_TARGET", "D8:E7:2F:08:7C:5D")
DEFAULT_OWNER = os.environ.get("MI_SCALE_OWNER", "Wayne123")
DEFAULT_RUNTIME = os.environ.get("MI_SCALE_RUNTIME", "auto")
WINDOWS_PYTHON = os.environ.get("MI_SCALE_WINDOWS_PYTHON", "py.exe")

DATA_DIR = Path(
    os.environ.get(
        "MI_SCALE_DATA_DIR",
        "/home/wayne/.openclaw/workspace/memory/shared/body-monitor",
    )
)
LATEST_FILE = DATA_DIR / "latest.json"
RAW_FILE = DATA_DIR / "latest-raw.json"
EVENTS_FILE = DATA_DIR / "events.jsonl"

INFLUX_ENV = Path(
    "/home/wayne/.openclaw/workspace/reference-docs/integrations/influxdb/health-metrics.env"
)
INFLUX_DEFAULTS = {
    "HEALTH_METRICS_HOST": "192.168.33.17",
    "HEALTH_METRICS_PORT": "8086",
    "HEALTH_METRICS_DB": "health_metrics",
}
INFLUX_MEASUREMENT = "body_composition"

# Mi Scale 2 BLE service/characteristic UUIDs discovered from live probe.
MI_SCALE_SERVICE_UUID = "181b"  # Body Composition service
MI_SCALE_BODY_MEASUREMENT_CHAR = "00002a9c-0000-1000-8000-00805f9b34fb"  # indicate
MI_SCALE_FEATURE_CHAR = "00002a9b-0000-1000-8000-00805f9b34fb"  # read
MI_SCALE_VENDOR_NOTIFY_CHARS = [
    "00002a2f-0000-3512-2118-0009af100700",
    "00001531-0000-3512-2118-0009af100700",
    "00001542-0000-3512-2118-0009af100700",
    "00001543-0000-3512-2118-0009af100700",
]


def _normalize_mac(value: str) -> str:
    if not value:
        return value
    return value.strip().upper()


def _linux_bluetooth_ready() -> bool:
    if not Path("/sys/class/bluetooth").exists():
        return False
    proc = subprocess.run(
        ["systemctl", "is-active", "bluetooth"],
        capture_output=True,
        text=True,
        check=False,
        timeout=5,
    )
    if not (proc.returncode == 0 and proc.stdout.strip() == "active"):
        return False

    # The service can be active in WSL while no adapter is exposed.
    ctrl = subprocess.run(
        ["bluetoothctl", "list"],
        capture_output=True,
        text=True,
        check=False,
        timeout=5,
    )
    return bool(ctrl.stdout.strip())


def _windows_python_ready() -> bool:
    proc = subprocess.run(
        [WINDOWS_PYTHON, "-3", "-c", "import sys; print(sys.version)"],
        capture_output=True,
        text=True,
        check=False,
        timeout=10,
    )
    return proc.returncode == 0


def _resolve_runtime(requested: str) -> str:
    runtime = requested.lower()
    if runtime not in {"auto", "linux", "windows"}:
        raise ValueError(f"unsupported runtime: {requested}")
    if runtime == "linux":
        return "linux"
    if runtime == "windows":
        return "windows"
    if _linux_bluetooth_ready():
        return "linux"
    if _windows_python_ready():
        return "windows"
    return "linux"


def _run_windows_python(code: str, args: list[str], *, timeout: int = 90) -> str:
    proc = subprocess.run(
        [WINDOWS_PYTHON, "-3", "-c", code] + args,
        capture_output=True,
        text=True,
        check=False,
        timeout=timeout,
    )
    if proc.returncode != 0:
        stderr = proc.stderr.strip() or "(no stderr)"
        if "No module named 'bleak'" in stderr:
            raise RuntimeError(
                "Windows Python is missing bleak. Install with: py -3 -m pip install bleak. "
                f"Raw error: {stderr}"
            )
        raise RuntimeError(f"Windows BLE helper failed ({proc.returncode}): {stderr}")
    return proc.stdout


def _scan_windows_devices() -> list[dict[str, Any]]:
    code = "\n".join(
        [
            "import asyncio",
            "import json",
            "from bleak import BleakScanner",
            "",
            "async def main():",
            "    devices = await BleakScanner.discover(timeout=8.0)",
            "    out = [{'address': d.address, 'name': d.name} for d in devices]",
            "    print(json.dumps(out))",
            "",
            "asyncio.run(main())",
        ]
    )
    stdout = _run_windows_python(code, [], timeout=30)
    try:
        payload = json.loads(stdout)
        if isinstance(payload, list):
            return payload
    except json.JSONDecodeError:
        pass
    return []


def _connect_and_read_windows(device_address: str) -> dict[str, Any] | None:
    device_address = _normalize_mac(device_address)
    code = "\n".join(
        [
            "import asyncio",
            "import json",
            "import sys",
            "from bleak import BleakClient",
            "",
            "TARGET = sys.argv[1]",
            "BODY_CHAR = '00002a9c-0000-1000-8000-00805f9b34fb'",
            "VENDOR_CHARS = [",
            "  '00002a2f-0000-3512-2118-0009af100700',",
            "  '00001531-0000-3512-2118-0009af100700',",
            "  '00001542-0000-3512-2118-0009af100700',",
            "  '00001543-0000-3512-2118-0009af100700',",
            "]",
            "",
            "async def main():",
            "    payload = {'ok': False, 'notifications': [], 'feature': None, 'error': None}",
            "    done = asyncio.Event()",
            "",
            "    def on_notify(sender, data):",
            "        payload['notifications'].append({'char': str(sender), 'data': list(data)})",
            "        if '2a9c' in str(sender).lower():",
            "            done.set()",
            "",
            "    async with BleakClient(TARGET) as client:",
            "        if not client.is_connected:",
            "            payload['error'] = 'not_connected'",
            "            print(json.dumps(payload))",
            "            return",
            "        try:",
            "            try:",
            "                feat = await client.read_gatt_char('00002a9b-0000-1000-8000-00805f9b34fb')",
            "                payload['feature'] = list(feat)",
            "            except Exception:",
            "                pass",
            "",
            "            started = []",
            "            for char in [BODY_CHAR] + VENDOR_CHARS:",
            "                try:",
            "                    await client.start_notify(char, on_notify)",
            "                    started.append(char)",
            "                except Exception:",
            "                    pass",
            "",
            "            try:",
            "                await asyncio.wait_for(done.wait(), timeout=20.0)",
            "            except asyncio.TimeoutError:",
            "                await asyncio.sleep(1.0)",
            "",
            "            for char in started:",
            "                try:",
            "                    await client.stop_notify(char)",
            "                except Exception:",
            "                    pass",
            "",
            "            payload['ok'] = len(payload['notifications']) > 0",
            "            if not payload['ok']:",
            "                payload['error'] = 'no_notifications'",
            "            print(json.dumps(payload))",
            "        except Exception as e:",
            "            payload['error'] = str(e)",
            "            print(json.dumps(payload))",
            "",
            "asyncio.run(main())",
        ]
    )
    try:
        stdout = _run_windows_python(code, [device_address], timeout=60)
        payload = json.loads(stdout.strip() or "{}")
    except Exception as e:
        print(f"Windows BLE connection error: {e}", file=sys.stderr)
        return None

    if not payload.get("ok"):
        err = payload.get("error", "unknown")
        print(f"Windows BLE read error: {err}", file=sys.stderr)
        return None

    return _parse_notification_payloads(
        payload.get("notifications", []),
        feature=payload.get("feature"),
    )


def _utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def _load_influx_env() -> dict[str, str]:
    config = dict(INFLUX_DEFAULTS)
    if INFLUX_ENV.exists():
        with open(INFLUX_ENV) as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                if "=" in line:
                    key, val = line.split("=", 1)
                    config[key.strip()] = val.strip()
    return config


def _write_influxdb(measurement: str, tags: dict[str, str], fields: dict[str, int | float]) -> bool:
    """Write a measurement to InfluxDB via HTTP using health_metrics database."""
    config = _load_influx_env()
    host = config.get("HEALTH_METRICS_HOST", "192.168.33.17")
    port = config.get("HEALTH_METRICS_PORT", "8086")
    db = config.get("HEALTH_METRICS_DB", "health_metrics")
    
    url = f"http://{host}:{port}/write?db={db}"
    
    # Build line protocol with proper tag escaping
    tag_parts = []
    for k, v in tags.items():
        # Escape tag values: spaces, commas, equals signs
        escaped_v = str(v).replace(" ", "\\ ").replace(",", "\\,").replace("=", "\\=")
        tag_parts.append(f"{k}={escaped_v}")
    
    field_parts: list[str] = []
    for fkey, fval in fields.items():
        if isinstance(fval, float):
            field_parts.append(f"{fkey}={fval}")
        elif isinstance(fval, int):
            field_parts.append(f"{fkey}={fval}i")
    
    if not tag_parts or not field_parts:
        return False
    
    tag_str = ",".join(tag_parts)
    field_str = ",".join(field_parts)
    line = f"{measurement},{tag_str} {field_str}"
    
    try:
        import urllib.request
        req = urllib.request.Request(
            url,
            data=line.encode(),
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=5) as response:
            return response.status == 204
    except Exception as e:
        print(f"InfluxDB write failed: {e}", file=sys.stderr)
        return False


async def _connect_and_read_linux(device_address: str) -> dict[str, Any] | None:
    """Connect to Mi Scale 2 via BLE and read weight/composition data."""
    device_address = _normalize_mac(device_address)
    if not HAS_BLEAK:
        print("Error: bleak library not available. Install with: pip install bleak", file=sys.stderr)
        return None
    
    try:
        async with BleakClient(device_address) as client:
            if not client.is_connected:
                print(f"Failed to connect to {device_address}", file=sys.stderr)
                return None
            
            print(f"Connected to {device_address}", file=sys.stderr)

            notifications: list[dict[str, Any]] = []
            done = asyncio.Event()

            def on_notify(sender: Any, data: bytearray) -> None:
                notifications.append({"char": str(sender), "data": list(bytes(data))})
                if "2a9c" in str(sender).lower():
                    done.set()

            started: list[str] = []
            for char in [MI_SCALE_BODY_MEASUREMENT_CHAR] + MI_SCALE_VENDOR_NOTIFY_CHARS:
                try:
                    await client.start_notify(char, on_notify)
                    started.append(char)
                except Exception:
                    continue

            if not started:
                print("Failed to subscribe to any Mi Scale notify/indicate characteristic", file=sys.stderr)
                return None

            try:
                await asyncio.wait_for(done.wait(), timeout=20.0)
            except asyncio.TimeoutError:
                await asyncio.sleep(1.0)

            for char in started:
                try:
                    await client.stop_notify(char)
                except Exception:
                    pass

            if not notifications:
                print("No Mi Scale notifications received", file=sys.stderr)
                return None

            feature: list[int] | None = None
            try:
                feature = list(await client.read_gatt_char(MI_SCALE_FEATURE_CHAR))
            except Exception:
                feature = None

            return _parse_notification_payloads(notifications, feature=feature)
                
    except Exception as e:
        print(f"BLE connection error: {e}", file=sys.stderr)
        return None


async def _connect_and_read(device_address: str, runtime: str) -> dict[str, Any] | None:
    if runtime == "windows":
        return _connect_and_read_windows(device_address)
    return await _connect_and_read_linux(device_address)


def _u16(data: bytes, offset: int) -> int | None:
    if offset + 2 > len(data):
        return None
    return data[offset] | (data[offset + 1] << 8)


def _parse_2a9c_body_measurement(data: bytes) -> dict[str, Any]:
    """Parse Body Composition Measurement (2A9C) indication payload.

    The observed device exposes 181B/2A9C (indicate). We parse core fields
    conservatively and keep raw bytes for future protocol refinement.
    """
    if len(data) < 4:
        return {}

    flags = _u16(data, 0)
    body_fat_raw = _u16(data, 2)
    if flags is None or body_fat_raw is None:
        return {}

    out: dict[str, Any] = {
        "flags": flags,
        "body_fat_pct": round(body_fat_raw / 10.0, 2),
    }

    cursor = 4

    # Optional fields based on 2A9C bit flags.
    if flags & (1 << 1):  # Timestamp present (7 bytes)
        if cursor + 7 <= len(data):
            year = _u16(data, cursor) or 0
            month = data[cursor + 2]
            day = data[cursor + 3]
            hour = data[cursor + 4]
            minute = data[cursor + 5]
            second = data[cursor + 6]
            out["measurement_timestamp"] = f"{year:04d}-{month:02d}-{day:02d}T{hour:02d}:{minute:02d}:{second:02d}"
        cursor += 7

    if flags & (1 << 2):  # User ID present (1 byte)
        if cursor < len(data):
            out["user_id"] = data[cursor]
        cursor += 1

    def parse_u16_field(name: str, scale: float | None = None) -> None:
        nonlocal cursor
        raw = _u16(data, cursor)
        if raw is not None:
            if scale is None:
                out[name] = raw
            else:
                out[name] = round(raw / scale, 3)
        cursor += 2

    if flags & (1 << 3):
        parse_u16_field("basal_metabolism_kcal")
    if flags & (1 << 4):
        parse_u16_field("muscle_pct", 10.0)
    if flags & (1 << 5):
        parse_u16_field("muscle_mass_kg", 200.0)
    if flags & (1 << 6):
        parse_u16_field("fat_free_mass_kg", 200.0)
    if flags & (1 << 7):
        parse_u16_field("soft_lean_mass_kg", 200.0)
    if flags & (1 << 8):
        parse_u16_field("body_water_mass_kg", 200.0)
    if flags & (1 << 9):
        parse_u16_field("impedance_ohm")
    if flags & (1 << 10):
        # Weight uses metric/imperial bit in flags bit0.
        weight_raw = _u16(data, cursor)
        if weight_raw is not None:
            if flags & 0x01:
                out["weight_lb"] = round(weight_raw / 100.0, 2)
                out["weight_kg"] = round((weight_raw / 100.0) * 0.45359237, 2)
            else:
                out["weight_kg"] = round(weight_raw / 200.0, 2)
        cursor += 2
    if flags & (1 << 11):
        parse_u16_field("height_m", 100.0)

    return out


def _parse_vendor_notification(data: bytes) -> dict[str, Any]:
    """Best-effort parse for Xiaomi vendor notify payloads.

    The exact vendor frame layout is not fully reverse engineered here.
    We expose plausible weight/impedance candidates when values fall within
    realistic ranges and always preserve raw bytes for auditing.
    """
    out: dict[str, Any] = {}
    if len(data) >= 4:
        for offset in range(0, min(len(data) - 1, 20), 2):
            raw = _u16(data, offset)
            if raw is None:
                continue
            kg_200 = raw / 200.0
            kg_100 = raw / 100.0
            if 20 <= kg_200 <= 250 and "weight_kg" not in out:
                out["weight_kg"] = round(kg_200, 2)
            elif 20 <= kg_100 <= 250 and "weight_kg" not in out:
                out["weight_kg"] = round(kg_100, 2)
            if 100 <= raw <= 2000 and "impedance_ohm" not in out:
                out["impedance_ohm"] = raw
    return out


def _parse_notification_payloads(
    notifications: list[dict[str, Any]],
    *,
    feature: list[int] | None,
) -> dict[str, Any]:
    parsed: dict[str, Any] = {
        "rawNotifications": notifications,
    }
    if feature is not None:
        parsed["featureRaw"] = feature

    # Prefer standard 2A9C body composition indication when available.
    for item in notifications:
        char = str(item.get("char", "")).lower()
        data = bytes(item.get("data", []))
        if "2a9c" in char:
            parsed.update(_parse_2a9c_body_measurement(data))
            break

    # Fill any missing core fields from vendor notifications as fallback.
    if "weight_kg" not in parsed or "impedance_ohm" not in parsed:
        for item in notifications:
            char = str(item.get("char", "")).lower()
            if "2a9c" in char:
                continue
            fallback = _parse_vendor_notification(bytes(item.get("data", [])))
            for key in ("weight_kg", "impedance_ohm"):
                if key not in parsed and key in fallback:
                    parsed[key] = fallback[key]

    return parsed


def _write_canonical_files(
    measurement: dict[str, Any],
    *,
    alias: str,
    owner: str,
    device_address: str,
    runtime: str,
) -> None:
    """Write normalized measurement to canonical shared files."""
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    
    timestamp = _utc_now()
    latest_data = {
        "timestamp": timestamp,
        "sourceTimestamp": timestamp,
        "source": "mi_scale_2",
        "deviceAlias": alias,
        "owner": owner,
        "deviceAddress": device_address,
        "model": "Mi Body Composition Scale 2",
        "runtime": runtime,
        **measurement,
    }
    
    # Write latest.json
    with open(LATEST_FILE, "w") as f:
        json.dump(latest_data, f, indent=2)
    
    # Write latest-raw.json
    with open(RAW_FILE, "w") as f:
        json.dump(latest_data, f, indent=2)
    
    # Append to events.jsonl
    with open(EVENTS_FILE, "a") as f:
        f.write(json.dumps(latest_data) + "\n")
    
    print(f"Wrote {LATEST_FILE}")


def _write_influx(measurement: dict[str, Any], *, alias: str, owner: str, device_address: str) -> None:
    """Write measurement to InfluxDB health_metrics database with cross-reference tags."""
    # Get measurement date in YYYY-MM-DD format for cross-referencing with CPAP sleep_date
    measurement_date = datetime.now(timezone.utc).date().isoformat()
    
    tags = {
        "source": "mi_scale_2",
        "device_alias": alias.replace(" ", "_"),
        "owner": owner,
        "address": device_address,
        "measurement_date": measurement_date,  # For cross-referencing with CPAP sleep_date
    }
    
    fields = {k: v for k, v in measurement.items() if isinstance(v, (int, float))}
    
    if _write_influxdb(INFLUX_MEASUREMENT, tags, fields):
        print(f"Wrote {INFLUX_MEASUREMENT} to health_metrics database")
    else:
        print("InfluxDB write skipped or failed")


async def main():
    parser = argparse.ArgumentParser(
        description="Collect Mi Body Composition Scale 2 body composition data"
    )
    parser.add_argument(
        "--target",
        default=DEFAULT_TARGET,
        help=f"Device address or alias (default: {DEFAULT_TARGET})",
    )
    parser.add_argument(
        "--alias",
        default=DEFAULT_ALIAS,
        help=f"Device alias for tracking (default: {DEFAULT_ALIAS})",
    )
    parser.add_argument(
        "--owner",
        default=DEFAULT_OWNER,
        help=f"Owner identifier (default: {DEFAULT_OWNER})",
    )
    parser.add_argument(
        "--runtime",
        default=DEFAULT_RUNTIME,
        choices=["auto", "linux", "windows"],
        help=f"BLE runtime selection (default: {DEFAULT_RUNTIME})",
    )
    parser.add_argument(
        "--no-influx",
        action="store_true",
        help="Skip InfluxDB write",
    )
    parser.add_argument(
        "--scan",
        action="store_true",
        help="Scan for nearby BLE devices",
    )
    
    args = parser.parse_args()
    args.target = _normalize_mac(args.target)
    
    runtime = _resolve_runtime(args.runtime)

    if args.scan:
        print(f"Scanning for BLE devices using runtime={runtime}...")
        if runtime == "windows":
            devices = _scan_windows_devices()
            for device in devices:
                print(f"  {device.get('address')}: {device.get('name')}")
            return
        if not HAS_BLEAK:
            print("Error: bleak library not available", file=sys.stderr)
            sys.exit(1)
        devices = await BleakScanner.discover()
        for device in devices:
            print(f"  {device.address}: {device.name}")
        return

    measurement = await _connect_and_read(args.target, runtime)
    if not measurement:
        print("Failed to read from scale", file=sys.stderr)
        sys.exit(1)
    
    print(f"Measurement: {json.dumps(measurement, indent=2)}")
    
    _write_canonical_files(
        measurement,
        alias=args.alias,
        owner=args.owner,
        device_address=_normalize_mac(args.target),
        runtime=runtime,
    )
    
    if not args.no_influx:
        _write_influx(
            measurement,
            alias=args.alias,
            owner=args.owner,
            device_address=_normalize_mac(args.target),
        )


if __name__ == "__main__":
    asyncio.run(main())
