#!/usr/bin/env python3
"""
NAS Health Metrics Collector for WD MyCloud EX2 Ultra
Writes to InfluxDB 1.8 health_metrics database (line protocol over HTTP).

Collected metrics:
  - nas_drive:  temp_c, power_on_hours, load_cycles, reallocated_sectors,
                pending_sectors, uncorrectable, udma_crc_errors, raw_read_errors
  - nas_system: cpu_temp_c, mem_available_mb, mem_total_mb, load_1m, load_5m, load_15m
  - nas_net:    rx_bytes, tx_bytes (per interface)

Usage:
  python3 nas_health_collector.py [--once]

  --once  Run a single collection cycle and exit (default: loop every 60s).

Deploy:
  /mnt/HD/HD_a2/butler/nas_health_collector.py
  Started by fun_plug v1.7+ or run manually.
"""

import subprocess
import re
import time
import urllib.error
import os
import sys
import logging

from lib.butler_common import post_line_protocol

logger = logging.getLogger(__name__)

INFLUX_URL = "http://localhost:8086/write?db=health_metrics&precision=s"
HOST = "MyCloudEX2Ultra"
DRIVES = ["/dev/sda", "/dev/sdb"]
INTERVAL = 60  # seconds

SMART_FIELDS = {
    "194": "temp_c",
    "9":   "power_on_hours",
    "193": "load_cycles",
    "5":   "reallocated_sectors",
    "197": "pending_sectors",
    "198": "uncorrectable",
    "199": "udma_crc_errors",
    "1":   "raw_read_errors",
}


def smart_data(dev):
    """Return dict of SMART attribute values for a drive."""
    result: dict = {}
    try:
        out = subprocess.check_output(
            ["smartctl", "-A", dev],
            stderr=subprocess.DEVNULL,
            timeout=10,
        ).decode()
    except Exception:
        # A drive whose SMART cannot be read loses its row for this cycle; name it
        # rather than returning an empty dict as if the drive had no attributes.
        logger.warning("smartctl read failed for %s", dev, exc_info=True)
        return result
    for line in out.splitlines():
        parts = line.split()
        if len(parts) < 10:
            continue
        attr_id = parts[0]
        if attr_id in SMART_FIELDS:
            raw = parts[9]
            # Raw value may have parenthetical annotations — take first token
            val = raw.split("(")[0].strip()
            try:
                result[SMART_FIELDS[attr_id]] = int(val)
            except ValueError:
                # A raw SMART value that is not a plain integer (some firmwares
                # annotate it) drops just that one attribute; name it at debug.
                logger.debug("non-integer SMART value for attribute %s: %r", attr_id, val, exc_info=True)
    return result


def cpu_temp_c():
    """Read CPU temperature from thermal_zone0 (millidegrees → degrees)."""
    try:
        for zone in sorted(os.listdir("/sys/class/thermal")):
            path = f"/sys/class/thermal/{zone}/temp"
            if os.path.exists(path):
                with open(path) as f:
                    return round(int(f.read().strip()) / 1000.0, 1)
    except Exception:
        # No thermal zone readable (some firmwares expose none): cpu_temp_c is
        # simply absent this cycle, so its field is omitted, not zeroed.
        logger.debug("no readable thermal zone for cpu_temp_c", exc_info=True)
    return None


def memory_stats():
    """Return (available_mb, total_mb) from /proc/meminfo."""
    try:
        with open("/proc/meminfo") as f:
            text = f.read()
        m_total = re.search(r"MemTotal:\s+(\d+)", text)
        m_avail = re.search(r"MemAvailable:\s+(\d+)", text)
        if m_total is None or m_avail is None:
            return None, None
        total = int(m_total.group(1)) // 1024
        avail = int(m_avail.group(1)) // 1024
        return avail, total
    except Exception:
        # An unreadable /proc/meminfo (unexpected on Linux) omits the memory fields;
        # log so the omission is diagnosable rather than looking like a normal cycle.
        logger.debug("could not read /proc/meminfo", exc_info=True)
        return None, None


def load_avg():
    """Return (load_1m, load_5m, load_15m)."""
    try:
        with open("/proc/loadavg") as f:
            parts = f.read().split()
        return float(parts[0]), float(parts[1]), float(parts[2])
    except Exception:
        # /proc/loadavg is standard on Linux; a failure omits the load fields.
        logger.debug("could not read /proc/loadavg", exc_info=True)
        return None, None, None


def net_stats():
    """Return {iface: (rx_bytes, tx_bytes)} from /proc/net/dev."""
    result = {}
    try:
        with open("/proc/net/dev") as f:
            lines = f.readlines()[2:]  # skip header
        for line in lines:
            parts = line.split()
            iface = parts[0].rstrip(":")
            if iface in ("lo",):
                continue
            rx = int(parts[1])
            tx = int(parts[9])
            result[iface] = (rx, tx)
    except Exception:
        # A malformed /proc/net/dev line drops the per-interface rows for this cycle;
        # name it so a partial cycle is not read as "no interfaces".
        logger.debug("could not parse /proc/net/dev", exc_info=True)
    return result


def influx_write(lines):
    """POST line-protocol data to InfluxDB."""
    try:
        status = post_line_protocol(INFLUX_URL, "\n".join(lines), timeout=5)
        return status in (200, 204)
    except urllib.error.URLError as e:
        print(f"[ERROR] InfluxDB write failed: {e}", file=sys.stderr)
        return False


def collect():
    """Run one collection cycle; return list of line-protocol strings."""
    lines = []
    ts = int(time.time())

    # Drive metrics
    for i, dev in enumerate(DRIVES):
        label = dev.split("/")[-1]  # sda, sdb
        data = smart_data(dev)
        if data:
            fields = ",".join(f"{k}={v}i" for k, v in data.items())
            lines.append(f"nas_drive,host={HOST},drive={label} {fields} {ts}")

    # System metrics
    cpu = cpu_temp_c()
    mem_avail, mem_total = memory_stats()
    l1, l5, l15 = load_avg()
    sys_fields = []
    if cpu is not None:
        sys_fields.append(f"cpu_temp_c={cpu}")
    if mem_avail is not None:
        sys_fields.append(f"mem_available_mb={mem_avail}i,mem_total_mb={mem_total}i")
    if l1 is not None:
        sys_fields.append(f"load_1m={l1},load_5m={l5},load_15m={l15}")
    if sys_fields:
        lines.append(f"nas_system,host={HOST} {','.join(sys_fields)} {ts}")

    # Network metrics
    for iface, (rx, tx) in net_stats().items():
        lines.append(
            f"nas_net,host={HOST},iface={iface} rx_bytes={rx}i,tx_bytes={tx}i {ts}"
        )

    return lines


def main():
    once = "--once" in sys.argv
    print(f"[NAS health collector] host={HOST} influx={INFLUX_URL} interval={INTERVAL}s")
    while True:
        lines = collect()
        if lines:
            ok = influx_write(lines)
            status = "OK" if ok else "FAIL"
            print(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] wrote {len(lines)} series — {status}")
        else:
            print(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] no data collected")
        if once:
            break
        time.sleep(INTERVAL)


if __name__ == "__main__":
    main()
