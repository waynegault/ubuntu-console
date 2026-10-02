#!/usr/bin/env python3
# Version: 1.3.1
# AI INSTRUCTION: After any code change, increment the Version value in this file.

"""Glowmarkt/Bright Smart Meter electricity collector.

Fetches half-hourly consumption data from the Glowmarkt DCC API.
Writes to InfluxDB and maintains shared state files.

API: https://api.glowmarkt.com/api/v0-1
App ID: b0f1b774-a586-4f72-9edd-27ead8aa7a8d
Auth: JWT (7-day expiry) via POST /auth
"""

from __future__ import annotations

import json
import os
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, cast

# ── Configuration ─────────────────────────────────────────────────────────────

API_BASE = "https://api.glowmarkt.com/api/v0-1"
APP_ID = "b0f1b774-a586-4f72-9edd-27ead8aa7a8d"
METER_ID = "001C550020046665"
RESOURCE_ID = "df862991-4379-4efa-9661-865b3056ec48"

SECRETS_FILE = Path(os.environ.get("SECRETS_FILE", "/home/wayne/.openclaw/secrets.json"))
TOKEN_FILE = Path(os.environ.get("GLOWMARKT_TOKEN_FILE", "/home/wayne/.openclaw/credentials/glowmarkt/token.json"))

DATA_DIR = Path(
    os.environ.get("GLOWMARKT_DATA_DIR", "/home/wayne/.openclaw/workspace/memory/shared/electricity-usage")
)
LATEST_FILE = DATA_DIR / "latest.json"
HISTORY_FILE = DATA_DIR / "events.jsonl"
CURSOR_FILE = DATA_DIR / "cursor.json"

INFLUX_HOST = os.environ.get("INFLUXDB_HOST", "192.168.33.20")
INFLUX_PORT = os.environ.get("INFLUXDB_PORT", "8086")
INFLUX_DB = os.environ.get("INFLUXDB_DB", "electricity_usage")
INFLUX_URL = f"http://{INFLUX_HOST}:{INFLUX_PORT}/write?db={INFLUX_DB}"
INFLUX_MEASUREMENT = "glowmarkt_consumption"

DATA_DIR.mkdir(parents=True, exist_ok=True)
TOKEN_FILE.parent.mkdir(parents=True, exist_ok=True)


# ── Auth ──────────────────────────────────────────────────────────────────────

def _load_creds() -> dict[str, str]:
    """Load Glowmarkt credentials: each field from env, else the secrets file.

    GLOWMARKT_PASSWORD is imported from the Windows environment by
    oc-refresh-keys; the non-secret username lives in the secrets file. Each
    field resolves independently, so either source can supply either value.
    """
    file_creds: dict[str, str] = {}
    if SECRETS_FILE.exists():
        file_creds = json.loads(SECRETS_FILE.read_text()).get("glowmarkt", {}) or {}
    username = (os.environ.get("GLOWMARKT_USERNAME") or file_creds.get("username") or "").strip()
    password = (os.environ.get("GLOWMARKT_PASSWORD") or file_creds.get("password") or "").strip()
    if username and password:
        return {"username": username, "password": password}
    return {}


def _authenticate(username: str, password: str, timeout: int = 45) -> dict[str, Any]:
    """Authenticate to Glowmarkt API and return JWT token."""
    data = json.dumps({"username": username, "password": password}).encode()
    req = urllib.request.Request(
        f"{API_BASE}/auth",
        data=data,
        method="POST",
        headers={
            "Content-Type": "application/json",
            "applicationId": APP_ID,
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            body = resp.read().decode()
            result = json.loads(body)
            if result.get("valid") is False:
                raise RuntimeError("Authentication failed: invalid credentials")
            return result
    except urllib.error.HTTPError as e:
        body = e.read().decode()
        raise RuntimeError(f"Auth HTTP {e.code}: {body}")
    except urllib.error.URLError as e:
        raise RuntimeError(f"Auth connection failed: {e.reason}")


def _load_cached_token() -> str | None:
    """Load cached JWT token if still valid."""
    if not TOKEN_FILE.exists():
        return None
    try:
        data = json.loads(TOKEN_FILE.read_text())
        token = data.get("token", "")
        valid_to = data.get("validTo", "")
        if token and valid_to:
            expiry = datetime.fromisoformat(valid_to.replace("Z", "+00:00"))
            if datetime.now(timezone.utc) < expiry - timedelta(hours=1):
                return token
    except (json.JSONDecodeError, KeyError, ValueError):
        pass
    return None


def _save_token(token_data: dict[str, Any]) -> None:
    """Cache JWT token to file."""
    TOKEN_FILE.write_text(json.dumps(token_data, indent=2))
    TOKEN_FILE.chmod(0o600)


def get_token(force_refresh: bool = False) -> str:
    """Get a valid Glowmarkt JWT token, cached or fresh."""
    if not force_refresh:
        cached = _load_cached_token()
        if cached:
            return cached

    creds = _load_creds()
    if not creds:
        raise RuntimeError("No Glowmarkt credentials found in secrets.json")

    result = _authenticate(creds["username"], creds["password"])
    token = result.get("token", "")
    if not token:
        raise RuntimeError(f"Auth response missing token: {result}")

    _save_token(result)
    return token


# ── Data Retrieval ────────────────────────────────────────────────────────────

def _api_get(path: str, token: str, timeout: int = 45) -> dict[str, Any]:
    """Make authenticated GET request to Glowmarkt API."""
    req = urllib.request.Request(
        f"{API_BASE}/{path.lstrip('/')}",
        method="GET",
        headers={
            "Accept": "application/json",
            "applicationId": APP_ID,
            "token": token,
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return json.loads(resp.read().decode())
    except urllib.error.HTTPError as e:
        body = e.read().decode()
        raise RuntimeError(f"API GET {path} HTTP {e.code}: {body}")


def fetch_resources(token: str) -> list[dict[str, Any]]:
    """Fetch available resources (virtual meters)."""
    return cast(list[dict[str, Any]], _api_get("resource", token))


def fetch_consumption(
    token: str,
    resource_id: str,
    from_iso: str,
    to_iso: str,
    period: str = "PT30M",
) -> dict[str, Any]:
    """Fetch consumption readings for a time range."""
    path = f"resource/{resource_id}/readings?period={period}&from={from_iso}&to={to_iso}&function=sum"
    return _api_get(path, token)


# ── InfluxDB ──────────────────────────────────────────────────────────────────

def write_influx(lines: list[str]) -> int | None:
    """Write line protocol data to InfluxDB. Returns HTTP status or None."""
    if not lines:
        return None
    data = "\n".join(lines).encode()
    try:
        req = urllib.request.Request(
            INFLUX_URL,
            data=data,
            method="POST",
            headers={"Content-Type": "application/octet-stream"},
        )
        with urllib.request.urlopen(req, timeout=10) as resp:
            return int(resp.status)
    except urllib.error.URLError:
        return None


# ── State Management ─────────────────────────────────────────────────────────

def _load_cursor() -> dict[str, Any]:
    """Load the last successful cursor position."""
    if CURSOR_FILE.exists():
        try:
            return json.loads(CURSOR_FILE.read_text())
        except json.JSONDecodeError:
            pass
    return {"lastIntervalEnd": None, "updatedAt": None}


def _save_cursor(last_interval_end: str) -> None:
    """Save cursor position after successful collection."""
    cursor = {
        "lastIntervalEnd": last_interval_end,
        "updatedAt": datetime.now(timezone.utc).isoformat(),
    }
    CURSOR_FILE.write_text(json.dumps(cursor, indent=2))


def _append_history(record: dict[str, Any]) -> None:
    """Append a collection result to the append-only history file."""
    with HISTORY_FILE.open("a") as f:
        f.write(json.dumps(record) + "\n")


# ── Main ─────────────────────────────────────────────────────────────────────

def collect_once() -> dict[str, Any]:
    """Perform one collection cycle and return results."""
    token = get_token()

    # Check available resources to verify auth and discover meter
    resources = fetch_resources(token)

    # Find the consumption resource
    resource_id = RESOURCE_ID
    for r in resources:
        if r.get("resourceId") == RESOURCE_ID:
            resource_id = r["resourceId"]
            break
    # If our resource isn't found, use the first one
    if not resource_id and resources:
        resource_id = resources[0].get("resourceId", "")

    if not resource_id:
        return {"ok": False, "error": "No consumption resource found"}

    # Determine time range
    cursor = _load_cursor()
    now = datetime.now(timezone.utc)

    if cursor.get("lastIntervalEnd"):
        from_dt = datetime.fromisoformat(cursor["lastIntervalEnd"].replace("Z", "+00:00"))
    else:
        # Default: last 7 days (API limit is ~10 days per call)
        from_dt = now - timedelta(days=7)

    to_dt = now

    # API limit: max 10 days per query for 30-min aggregation
    # If the range exceeds 10 days, use the last 10 days
    if (to_dt - from_dt).days > 9:
        from_dt = to_dt - timedelta(days=9, hours=23)

    # Glowmarkt format: YYYY-MM-DDTHH:MM:SS
    from_iso = from_dt.strftime("%Y-%m-%dT%H:%M:%S")
    to_iso = to_dt.strftime("%Y-%m-%dT%H:%M:%S")

    # Fetch consumption readings
    api_result = fetch_consumption(token, resource_id, from_iso, to_iso)
    data_points = api_result.get("data", [])
    units = api_result.get("units", "kWh")

    if not data_points:
        return {
            "ok": True,
            "timestamp": now.isoformat(),
            "resource": resource_id,
            "readings": 0,
            "from": from_iso,
            "to": to_iso,
            "units": units,
            "influx": None,
        }

    # Write to InfluxDB
    influx_lines = []
    last_timestamp = None
    for dp in data_points:
        if not isinstance(dp, (list, tuple)) or len(dp) < 2:
            continue
        ts_unix = dp[0]
        val = dp[1]
        if val is None or val == 0:
            continue  # Skip zero readings (no consumption in that interval)
        try:
            val = float(val)
        except (ValueError, TypeError):
            continue
        iso_ts = datetime.fromtimestamp(ts_unix, tz=timezone.utc).isoformat()
        tags = f"source=glowmarkt,resource={resource_id},meter={METER_ID}"
        fields = [f"consumption_{units}={val}"]
        # FIX 1.1.0 (2026-08-22): append the reading timestamp in nanoseconds.
        # Without it, every point gets InfluxDB server write-time, so a batch of
        # readings collapses onto ~one timestamp and dedupes to a single point.
        # The electricity stream was never a true time series until this fix.
        ts_ns = int(ts_unix * 1_000_000_000)
        influx_lines.append(f"{INFLUX_MEASUREMENT},{tags} {','.join(fields)} {ts_ns}")
        last_timestamp = iso_ts

    influx_status = write_influx(influx_lines)

    result = {
        "ok": True,
        "timestamp": now.isoformat(),
        "resource": resource_id,
        "readings": len(data_points),
        "from": from_iso,
        "to": to_iso,
        "influx": {
            "host": INFLUX_HOST,
            "port": INFLUX_PORT,
            "db": INFLUX_DB,
            "measurement": INFLUX_MEASUREMENT,
            "writes": len(influx_lines) if influx_lines else 0,
            "status": influx_status,
        },
    }

    # Update cursor
    if last_timestamp:
        _save_cursor(last_timestamp)

    # Update result with correct counts and units
    result["readings"] = len(influx_lines)
    result["units"] = units
    result["latest_timestamp"] = last_timestamp

    # Append to history
    _append_history(result)

    # Write latest
    LATEST_FILE.write_text(json.dumps(result, indent=2) + "\n")

    return result


def main() -> int:
    import argparse
    parser = argparse.ArgumentParser(description="Glowmarkt electricity collector")
    parser.add_argument("--force-auth", action="store_true", help="Force re-authentication")
    parser.add_argument("--test-auth", action="store_true", help="Test authentication only")
    args = parser.parse_args()

    if args.test_auth:
        try:
            creds = _load_creds()
            if not creds:
                print(json.dumps({"ok": False, "error": "No credentials found"}))
                return 1
            result = _authenticate(creds["username"], creds["password"])
            print(json.dumps({"ok": True, "valid": result.get("valid"), "token": result.get("token", "")[:20] + "..."}))
            return 0
        except Exception as e:
            print(json.dumps({"ok": False, "error": str(e)}))
            return 1

    try:
        result = collect_once()
        print(json.dumps(result, indent=2))

        if not result.get("ok"):
            return 1
        return 0
    except RuntimeError as e:
        payload = {"ok": False, "error": str(e)}
        print(json.dumps(payload))
        return 1
    except Exception as e:
        payload = {"ok": False, "error": str(e)}
        print(json.dumps(payload))
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
