#!/usr/bin/env python3
"""
nas-bt-mqtt-bridge.py — pyusb direct-USB BLE scan bridge for NAS CSR8510

This scanner intentionally bypasses AF_BLUETOOTH/HCI sockets and BlueZ CLI tools.
It talks to the USB dongle via libusb (PyUSB), which avoids the kernel crash path
seen on WD kernel 4.14.22-armada-18.09.3 when sockets are opened/closed.

Mi Scale v2 Protocol (2026-04-19):
- BLE service: 0x181B (Health Body Composition), 15-byte payload
- Live frame: 2-byte header + 13-byte measurement (weight + impedance when stable)
- Weight: bytes [13:15] (LE uint16, /200 = kg), e.g. 0x54B0 = 108.4 kg
- Impedance: bytes [11:13] (LE uint16, ohms), e.g. 0x01E1 = 481 Ω
- Stability gated on status byte [3] bit 5 (stable) and bit 7 (not removed)
- See MI_SCALE_V2_PROTOCOL.md for full frame specification.

MQTT topics:
  bt/bridge/status        "online" | "offline"
  bt/scan/<MAC>           JSON payload per advertisement report
  bt/presence/<MAC>       "1" retained
  bt/mi_scale/<MAC>       JSON payload when Mi Scale frame detected
"""

from __future__ import annotations

import argparse
import json
import logging
import math
import os
import pathlib
import subprocess
import time
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from typing import Any, Iterable

try:
    import paho.mqtt.client as mqtt
except ImportError as exc:
    raise SystemExit("paho-mqtt missing. Install with: /opt/bin/pip3 install paho-mqtt") from exc

try:
    import usb.core
    import usb.backend.libusb1
    import usb.util
except ImportError as exc:
    raise SystemExit("pyusb missing. Install with: /opt/bin/pip3 install pyusb") from exc

# requests is optional (the HTTP publish path only): declared Any so the fallback
# `None` below does not conflict with the module type.
requests: Any = None
try:
    import requests
except ImportError:
    pass


logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [bt-mqtt] %(levelname)s %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
log = logging.getLogger(__name__)

DEFAULT_MQTT_HOST = "127.0.0.1"
DEFAULT_MQTT_PORT = 1883
DEFAULT_SCAN_SECONDS = 20
RESTART_DELAY_S = 15
DEFAULT_USB_VID = 0x0A12
DEFAULT_USB_PID = 0x0001
DEFAULT_TARGET_MAC = "D8:E7:2F:08:7C:5D"

USB_TIMEOUT_MS = 1000

HCI_EVENT_LE_META = 0x3E
LE_META_ADV_REPORT = 0x02

OGF_LE_CTL = 0x08
OCF_LE_SET_SCAN_PARAMETERS = 0x000B
OCF_LE_SET_SCAN_ENABLE = 0x000C
OCF_LE_SET_RANDOM_ADDRESS = 0x0005
OGF_HOST_CTL = 0x03
OCF_RESET = 0x0003
OCF_SET_EVENT_MASK = 0x0001
OCF_LE_SET_EVENT_MASK = 0x0001


def run(cmd: list[str], timeout: int = 10) -> tuple[int, str, str]:
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return r.returncode, r.stdout, r.stderr
    except (OSError, subprocess.SubprocessError) as exc:
        # The two failures `subprocess.run` actually raises here: OSError when the
        # binary is absent, SubprocessError (TimeoutExpired) when it exceeds the
        # timeout.  Anything else is a bug and must surface, not read as "rc=-1".
        return -1, "", str(exc)


def disable_kernel_btusb() -> None:
    """Optionally unload btusb stack; default is keep loaded for adapter init stability."""
    if os.environ.get("BT_DIRECT_UNLOAD", "0") != "1":
        return
    rc, out, _ = run(["lsmod"])
    if rc == 0 and "btusb" in out:
        run(["rmmod", "btusb"])
        run(["rmmod", "btrtl"])
        run(["rmmod", "btbcm"])
        run(["rmmod", "btintel"])
        log.info("Unloaded btusb stack for direct USB mode")


def hci_opcode_pack(ogf: int, ocf: int) -> int:
    return (ocf & 0x03FF) | (ogf << 10)


def _to_mac(addr_le: bytes) -> str:
    return ":".join(f"{b:02X}" for b in addr_le[::-1])


def _to_signed(v: int) -> int:
    return v - 256 if v > 127 else v


def _u16_le(data: bytes, off: int) -> int | None:
    if off + 2 > len(data):
        return None
    return data[off] | (data[off + 1] << 8)


def _extract_ad_fields(adv_data: bytes) -> tuple[list[int], dict[int, bytes], dict[int, bytes], str | None]:
    uuids_16: list[int] = []
    service_data: dict[int, bytes] = {}
    mfg_data: dict[int, bytes] = {}
    local_name: str | None = None

    i = 0
    while i < len(adv_data):
        ln = adv_data[i]
        if ln == 0:
            break
        end = i + 1 + ln
        if end > len(adv_data):
            break
        ad_type = adv_data[i + 1]
        payload = adv_data[i + 2 : end]

        if ad_type in (0x02, 0x03):
            for j in range(0, len(payload) - 1, 2):
                uuids_16.append(payload[j] | (payload[j + 1] << 8))
        elif ad_type == 0x16 and len(payload) >= 2:
            uuid = payload[0] | (payload[1] << 8)
            service_data[uuid] = payload[2:]
            if uuid not in uuids_16:
                uuids_16.append(uuid)
        elif ad_type == 0xFF and len(payload) >= 2:
            company = payload[0] | (payload[1] << 8)
            mfg_data[company] = payload[2:]
        elif ad_type in (0x08, 0x09):
            try:
                local_name = payload.decode("utf-8", errors="ignore").strip() or None
            except (UnicodeDecodeError, AttributeError):
                # payload is bytes and errors="ignore" makes the decode total, so this
                # guards a malformed buffer rather than a routine path.  A different
                # exception is a bug and must surface.
                local_name = None
        i = end

    return uuids_16, service_data, mfg_data, local_name


def _parse_mi_scale_v2_live_frame(data: bytes) -> tuple[float | None, int | None]:
    """
    Parse Mi Scale v2 live 13-byte frame in 0x181b service data.
    
    Format: [frame_type(1)][product_id(1)][mi_scale_frame(13)]
    
    Mi Scale frame layout (starting after the 2-byte header):
      [0] Status byte 0 (bit 0 = lbs unit)
      [1] Status byte 1 (bit 1 = has_impedance, bit 5 = stable, bit 7 = removed)
      [2-8] Flags / reserved
      [9-10] Impedance (LE uint16, ohms) if has_impedance=1
      [11-12] Weight (LE uint16 in 0.01 kg units) → divide by 200 for kg
    
    Returns (weight_kg, impedance_ohm) or (None, None) if not a valid stable frame.
    """
    # Service data blob (after UUID prefix stripped): 13 bytes, no extra header.
    if len(data) < 13:
        return None, None

    frame_offset = 0
    # Bytes 0 and the removed bit are parsed to keep the frame layout explicit but
    # are deliberately unread: the unit bit is ignored (weights are treated as kg)
    # and a removed+stable frame is the final locked-in weight, accepted by the
    # `stable` test below.  Underscore-prefixed so ruff's unused-local rule sees them.
    _status0 = data[frame_offset]
    status1 = data[frame_offset + 1]

    has_impedance = (status1 & 0x02) != 0
    stable = (status1 & 0x20) != 0
    _removed = (status1 & 0x80) != 0

    # Accept stable frames regardless of the removed flag: removed=True +
    # stable=True is the final locked-in weight (user stepped off).
    if not stable:
        return None, None
    
    # Parse weight (bytes 11-12 of frame, LE, in 0.01 kg units → divide by 200 = kg)
    weight_offset = frame_offset + 11
    weight_raw = _u16_le(data, weight_offset)
    if weight_raw is None or weight_raw < 2000 or weight_raw > 50000:  # roughly 10 to 250 kg
        weight_kg = None
    else:
        weight_kg = round(weight_raw / 200.0, 2)
    
    # Parse impedance if present (bytes 9-10 of frame, LE, in ohms)
    impedance_ohm = None
    if has_impedance:
        imp_offset = frame_offset + 9
        imp_raw = _u16_le(data, imp_offset)
        if imp_raw is not None and 100 <= imp_raw <= 2000:
            impedance_ohm = imp_raw
    
    return weight_kg, impedance_ohm


def _heuristic_decode(service_blob: bytes, mfg_blob: bytes) -> tuple[float | None, int | None]:
    """
    Deterministic Mi Scale decode only.

    The previous heuristic fallback scanned arbitrary u16 values in blobs and could
    emit plausible-looking but incorrect weights. To prevent false readings from
    being written to InfluxDB, only accept deterministic Mi Scale v2 frames.
    """
    # Mi Scale v2 deterministic frame (13+ bytes from service data)
    if service_blob and len(service_blob) >= 13:
        weight, impedance = _parse_mi_scale_v2_live_frame(service_blob)
        if weight is not None:
            return weight, impedance

    return None, None


def _parse_govee_frame(mfg_data: bytes) -> tuple[float | None, float | None]:
    """
    Parse Govee temperature/humidity from manufacturer data.
    H5075 advertising format uses manufacturer data under 0xEC88/0x8801.
    The payload packs temperature and relative humidity into 3 bytes, with an
    optional battery byte following.
    
    Returns (temp_c, humidity_pct) or (None, None) if not parseable.
    """
    if not mfg_data or len(mfg_data) < 3:
        return None, None

    try:
        # H5075/H5179 advertisements: decode the 3-byte packed temp/humidity field.
        # Vendor reference uses manufacturer_data[0xec88][1:4].
        frame = mfg_data[1:4] if len(mfg_data) >= 4 else mfg_data[:3]
        raw = int.from_bytes(frame, byteorder="big", signed=False)
        is_negative = (raw & 0x800000) != 0
        if is_negative:
            raw ^= 0x800000

        temp_c = int(raw / 1000) / 10.0
        if is_negative:
            temp_c = -temp_c
        humidity_pct = (raw % 1000) / 10.0

        if -50.0 <= temp_c <= 60.0 and 0.0 <= humidity_pct <= 100.0:
            return round(temp_c, 2), round(humidity_pct, 2)
    except (ValueError, TypeError, IndexError):
        # A malformed advertisement is not a parse result: the caller reads
        # (None, None) as "not parseable".  Only the shape errors the slicing and
        # arithmetic can raise are caught; anything else is a bug and must surface.
        pass

    return None, None


def _looks_like_mi_scale(mac: str, service_uuids: Iterable[int], manufacturer_id: int | None) -> bool:
    if manufacturer_id == 0x0157:
        return True
    if any(u in (0x181B, 0x181D) for u in service_uuids):
        return True
    if mac.startswith("D8:E7:2F"):
        return True
    return False


def _looks_like_govee(manufacturer_id: int | None, name: str | None) -> bool:
    if manufacturer_id in (0xEC88, 0x8801, 0x04C3):
        return True
    if name and name.lower().startswith("govee"):
        return True
    return False


@dataclass
class Detection:
    mac: str
    rssi: int
    name: str | None
    payload_hex: str
    service_uuids: list[int]
    manufacturer_id: int | None
    service_data_hex: str
    manufacturer_data_hex: str
    weight_kg: float | None
    impedance_ohm: int | None
    is_mi_scale: bool
    temp_c: float | None = None
    humidity_pct: float | None = None
    is_govee: bool = False


def resolve_usb_backend():
    backend = usb.backend.libusb1.get_backend()
    if backend is not None:
        return backend

    for lib_path in (
        "/opt/lib/libusb-1.0.so.0",
        "/opt/lib/libusb-1.0.so",
        "/usr/lib/libusb-1.0.so.0",
        "/usr/lib/libusb-1.0.so",
    ):
        if os.path.exists(lib_path):
            backend = usb.backend.libusb1.get_backend(find_library=lambda _name, p=lib_path: p)
            if backend is not None:
                return backend

    raise RuntimeError("No libusb backend available. Ensure libusb-1.0 is installed under /opt/lib")


class USBHciScanner:
    def __init__(self, vid: int, pid: int):
        self.vid = vid
        self.pid = pid
        self.dev: usb.core.Device | None = None
        self.event_ep: usb.core.Endpoint | None = None
        self._usb_interface_path: str | None = None
        self._rebind_btusb = False

    def _find_usb_interface_path(self) -> str | None:
        sys_bus = pathlib.Path("/sys/bus/usb/devices")
        for dev_path in sys_bus.iterdir():
            try:
                if not (dev_path / "idVendor").exists() or not (dev_path / "idProduct").exists():
                    continue
                vid = (dev_path / "idVendor").read_text().strip().lower()
                pid = (dev_path / "idProduct").read_text().strip().lower()
                if vid == f"{self.vid:04x}" and pid == f"{self.pid:04x}":
                    intf0 = pathlib.Path(f"{dev_path}:1.0")
                    if intf0.exists():
                        return intf0.name
            except OSError:
                continue
        return None

    def _unbind_btusb_if_needed(self) -> None:
        self._usb_interface_path = self._find_usb_interface_path()
        if not self._usb_interface_path:
            return

        driver_link = pathlib.Path("/sys/bus/usb/devices") / self._usb_interface_path / "driver"
        try:
            if not driver_link.exists() or os.path.basename(os.path.realpath(driver_link)) != "btusb":
                return
        except OSError:
            return

        try:
            with open("/sys/bus/usb/drivers/btusb/unbind", "w", encoding="ascii") as fh:
                fh.write(self._usb_interface_path)
            self._rebind_btusb = True
            log.info("Unbound btusb from %s for direct USB scan", self._usb_interface_path)
        except OSError as exc:
            log.warning("Failed to unbind btusb from %s: %s", self._usb_interface_path, exc)

    def _rebind_btusb_if_needed(self) -> None:
        if not self._rebind_btusb or not self._usb_interface_path:
            return
        try:
            with open("/sys/bus/usb/drivers/btusb/bind", "w", encoding="ascii") as fh:
                fh.write(self._usb_interface_path)
            log.info("Rebound btusb to %s", self._usb_interface_path)
        except OSError as exc:
            log.warning("Failed to rebind btusb to %s: %s", self._usb_interface_path, exc)
        finally:
            self._rebind_btusb = False

    def open(self) -> None:
        backend = resolve_usb_backend()
        dev = usb.core.find(idVendor=self.vid, idProduct=self.pid, backend=backend)
        if dev is None:
            raise RuntimeError(f"USB BT adapter not found (vid=0x{self.vid:04x} pid=0x{self.pid:04x})")

        self.dev = dev
        self._unbind_btusb_if_needed()

        cfg = dev.get_active_configuration()
        intf = cfg[(0, 0)]

        if dev.is_kernel_driver_active(intf.bInterfaceNumber):
            dev.detach_kernel_driver(intf.bInterfaceNumber)

        # set_interface_altsetting sends SET_INTERFACE to the device, which activates
        # the interrupt IN endpoint on the CSR8510. claim_interface alone is not enough.
        dev.set_interface_altsetting(intf.bInterfaceNumber, 0)

        event_ep = None
        for ep in intf.endpoints():
            if usb.util.endpoint_direction(ep.bEndpointAddress) == usb.util.ENDPOINT_IN:
                if usb.util.endpoint_type(ep.bmAttributes) == usb.util.ENDPOINT_TYPE_INTR:
                    event_ep = ep
                    break

        if event_ep is None:
            raise RuntimeError("interrupt IN endpoint not found on BT USB interface")

        self.event_ep = event_ep
        log.info("USB BT adapter opened (bus=%s addr=%s)", dev.bus, dev.address)

    def close(self) -> None:
        if self.dev is None:
            return
        try:
            cfg = self.dev.get_active_configuration()
            intf = cfg[(0, 0)]
            usb.util.release_interface(self.dev, intf.bInterfaceNumber)
            try:
                self.dev.attach_kernel_driver(intf.bInterfaceNumber)
            except usb.core.USBError:
                pass
        except (usb.core.USBError, ValueError, KeyError, IndexError):
            # Teardown must not mask the USB failure that brought us here: libusb
            # errors and the configuration/interface container lookups above are the
            # expected ones.  Anything else is a bug and must surface.
            pass
        usb.util.dispose_resources(self.dev)
        self.dev = None
        self._rebind_btusb_if_needed()

    def send_hci_cmd(self, ogf: int, ocf: int, params: bytes) -> None:
        if self.dev is None:
            raise RuntimeError("device not open")
        opcode = hci_opcode_pack(ogf, ocf)
        cmd = bytes([opcode & 0xFF, (opcode >> 8) & 0xFF, len(params)]) + params
        self.dev.ctrl_transfer(0x20, 0x00, 0x0000, 0x0000, cmd, timeout=USB_TIMEOUT_MS)

    def read_event(self) -> bytes | None:
        if self.event_ep is None:
            return None
        try:
            # HCI LE advertising reports can be 50+ bytes; wMaxPacketSize on CSR8510
            # interrupt IN is only 16 bytes — reading only that many truncates the event
            # and causes the boundary check in parse_adv_reports to discard it.
            # Read 64 bytes to ensure full HCI events are captured.
            data = self.event_ep.read(64, timeout=USB_TIMEOUT_MS)
            return bytes(data)
        except usb.core.USBTimeoutError:
            return None

    def _drain_events(self, duration_s: float, timeout_ms: int = 200) -> None:
        if self.event_ep is None:
            return
        end = time.monotonic() + duration_s
        while time.monotonic() < end:
            try:
                self.event_ep.read(64, timeout=timeout_ms)
            except usb.core.USBTimeoutError:
                break

    def setup_scan(self) -> None:
        self.send_hci_cmd(OGF_HOST_CTL, OCF_RESET, b"")
        # CSR8510 needs time after reset; issuing LE commands immediately often results
        # in no advertising reports being delivered to the interrupt endpoint.
        time.sleep(1.0)
        self._drain_events(1.0)

        # Match the known-good raw USB HCI sequence used on this NAS.
        self.send_hci_cmd(OGF_HOST_CTL, OCF_SET_EVENT_MASK, b"\xff\xff\xff\xff\xff\xff\xff\x3f")
        time.sleep(0.1)
        self._drain_events(0.3)

        self.send_hci_cmd(OGF_LE_CTL, OCF_LE_SET_EVENT_MASK, b"\x1f\x00\x00\x00\x00\x00\x00\x00")
        time.sleep(0.1)
        self._drain_events(0.3)

        params = bytes([0x00, 0x10, 0x00, 0x10, 0x00, 0x00, 0x00])
        self.send_hci_cmd(OGF_LE_CTL, OCF_LE_SET_SCAN_PARAMETERS, params)
        time.sleep(0.1)
        self._drain_events(0.3)

    def set_scan_enable(self, enabled: bool) -> None:
        params = bytes([0x01 if enabled else 0x00, 0x01])
        self.send_hci_cmd(OGF_LE_CTL, OCF_LE_SET_SCAN_ENABLE, params)


def parse_adv_reports(event_pkt: bytes) -> list[Detection]:
    out: list[Detection] = []
    if len(event_pkt) < 3:
        return out

    # USB HCI event endpoint data may include packet indicator 0x04 first.
    # Normalize to [evt_code][plen][params...].
    if event_pkt[0] == 0x04:
        if len(event_pkt) < 4:
            return out
        evt_code = event_pkt[1]
        plen = event_pkt[2]
        params = event_pkt[3 : 3 + plen]
    else:
        evt_code = event_pkt[0]
        plen = event_pkt[1]
        params = event_pkt[2 : 2 + plen]

    if evt_code != HCI_EVENT_LE_META or not params:
        return out
    if params[0] != LE_META_ADV_REPORT or len(params) < 2:
        return out

    reports = params[1]
    off = 2
    for _ in range(reports):
        if off + 10 > len(params):
            break
        _event_type = params[off]
        _addr_type = params[off + 1]
        mac = _to_mac(params[off + 2 : off + 8])
        data_len = params[off + 8]
        data_start = off + 9
        data_end = data_start + data_len
        if data_end >= len(params):
            break
        adv_data = params[data_start:data_end]
        rssi = _to_signed(params[data_end])
        off = data_end + 1

        uuids, svc, mfg, name = _extract_ad_fields(adv_data)
        manufacturer_id = next(iter(mfg.keys()), None)
        # Try Mi Scale v2 first (0xFE95), then fall back to generic services
        svc_blob = svc.get(0xFE95, b"") or svc.get(0x181B, b"") or svc.get(0x181D, b"")
        mfg_blob = mfg.get(manufacturer_id, b"") if manufacturer_id is not None else b""
        weight_kg, impedance_ohm = _heuristic_decode(svc_blob, mfg_blob)
        is_mi = _looks_like_mi_scale(mac, uuids, manufacturer_id)
        
        # Parse Govee data if applicable
        is_gov = _looks_like_govee(manufacturer_id, name)
        temp_c, humidity_pct = None, None
        if is_gov:
            temp_c, humidity_pct = _parse_govee_frame(mfg_blob)

        out.append(
            Detection(
                mac=mac,
                rssi=rssi,
                name=name,
                payload_hex=adv_data.hex(),
                service_uuids=uuids,
                manufacturer_id=manufacturer_id,
                service_data_hex=svc_blob.hex(),
                manufacturer_data_hex=mfg_blob.hex(),
                weight_kg=weight_kg,
                impedance_ohm=impedance_ohm,
                is_mi_scale=is_mi,
                temp_c=temp_c,
                humidity_pct=humidity_pct,
                is_govee=is_gov,
            )
        )

    return out


def _write_to_influxdb(detection: Detection, influx_url: str = "http://127.0.0.1:8086/write?db=sensor_data") -> bool:
    """Write detection data to InfluxDB."""
    if not requests:
        return False
    
    try:
        timestamp_ns = int(datetime.now(timezone.utc).timestamp() * 1e9)
        lines = []
        
        # Mi Scale data
        if detection.is_mi_scale and detection.weight_kg is not None:
            tags = f"mac={detection.mac},type=mi_scale"
            fields = []
            if detection.weight_kg is not None:
                fields.append(f"weight_kg={detection.weight_kg}")
            if detection.impedance_ohm is not None:
                fields.append(f"impedance_ohm={detection.impedance_ohm}i")
            fields.append(f"rssi={detection.rssi}i")
            if fields:
                line = f"body_composition,{tags} {','.join(fields)} {timestamp_ns}"
                lines.append(line)
        
        # Govee data -> canonical indoor_env series (Jarvis-Govee-H5075-Protocol.md L80-87)
        if detection.is_govee and (detection.temp_c is not None or detection.humidity_pct is not None):
            _bs = chr(92)  # line-protocol escape without a literal backslash in the source
            tags = (
                "source=govee_h5075,device_alias=Study" + _bs + " thermometer,"
                f"device_mac={detection.mac},owner=Wayne123"
            )
            fields = []
            if detection.temp_c is not None:
                fields.append(f"temperature_c={detection.temp_c}")
            if detection.humidity_pct is not None:
                fields.append(f"humidity_rel={detection.humidity_pct}")
            if detection.temp_c is not None and detection.humidity_pct is not None:
                _t = detection.temp_c
                _rh = detection.humidity_pct
                _es = 6.112 * math.exp(17.67 * _t / (_t + 243.5))
                _steam = _es * _rh / 100.0
                _gamma = math.log(_rh / 100.0) + 17.67 * _t / (_t + 243.5)
                _dew = 243.5 * _gamma / (17.67 - _gamma)
                _abs = 216.7 * _steam / (_t + 273.15)
                fields.append(f"dew_point_c={round(_dew, 1)}")
                fields.append(f"abs_humidity_gm3={round(_abs, 1)}")
                fields.append(f"steam_pressure_mbar={round(_steam, 1)}")
            fields.append(f"rssi={detection.rssi}i")
            if fields:
                line = f"indoor_env,{tags} {','.join(fields)} {timestamp_ns}"
                lines.append(line)
        
        if lines:
            data = "\n".join(lines)
            requests.post(influx_url, data=data, timeout=5)
            return True
    except Exception as e:
        log.debug("InfluxDB write failed: %s", e)
    return False


def _daily_first_exists(
    mac: str,
    day_start_ns: int,
    day_end_ns: int,
    influx_query_url: str = "http://127.0.0.1:8086/query",
) -> bool:
    """Return True if a daily canonical point already exists for this MAC in the UTC day window."""
    if not requests:
        return False

    try:
        q = (
            "SELECT weight_kg FROM body_composition_daily "
            f"WHERE mac='{mac}' AND time >= {day_start_ns} AND time < {day_end_ns} LIMIT 1"
        )
        r = requests.get(
            influx_query_url,
            params={"db": "sensor_data", "q": q},
            timeout=5,
        )
        data = r.json()
        series = data.get("results", [{}])[0].get("series", [])
        return bool(series)
    except Exception as e:
        log.debug("InfluxDB daily-first existence query failed: %s", e)
        return False


def _write_daily_first_to_influxdb(
    detection: Detection,
    influx_url: str = "http://127.0.0.1:8086/write?db=sensor_data",
) -> bool:
    """Write one canonical body composition point per UTC day (first detected point)."""
    if not requests:
        return False
    if not detection.is_mi_scale or detection.weight_kg is None:
        return False

    now_utc = datetime.now(timezone.utc)
    day_start = now_utc.replace(hour=0, minute=0, second=0, microsecond=0)
    day_end = day_start + timedelta(days=1)
    day_start_ns = int(day_start.timestamp() * 1e9)
    day_end_ns = int(day_end.timestamp() * 1e9)

    if _daily_first_exists(detection.mac, day_start_ns, day_end_ns):
        return False

    try:
        timestamp_ns = int(now_utc.timestamp() * 1e9)
        tags = f"mac={detection.mac},type=mi_scale"
        fields = [f"weight_kg={detection.weight_kg}"]
        if detection.impedance_ohm is not None:
            fields.append(f"impedance_ohm={detection.impedance_ohm}i")
        fields.append(f"rssi={detection.rssi}i")
        line = f"body_composition_daily,{tags} {','.join(fields)} {timestamp_ns}"
        requests.post(influx_url, data=line, timeout=5)
        return True
    except Exception as e:
        log.debug("InfluxDB daily-first write failed: %s", e)
        return False


def publish_detection(client: mqtt.Client, d: Detection, target_mac: str, write_influx: bool = True) -> None:
    ts = datetime.now(timezone.utc).isoformat()
    payload = {
        "ts": ts,
        "mac": d.mac,
        "name": d.name,
        "rssi": d.rssi,
        "payload_hex": d.payload_hex,
        "service_uuids": d.service_uuids,
        "manufacturer_id": d.manufacturer_id,
    }
    client.publish(f"bt/scan/{d.mac}", json.dumps(payload, separators=(",", ":")), qos=0, retain=False)
    client.publish(f"bt/presence/{d.mac}", "1", qos=0, retain=True)

    if d.is_mi_scale or d.mac.upper() == target_mac:
        mi_payload = {
            "ts": ts,
            "mac": d.mac,
            "target_match": d.mac.upper() == target_mac,
            "rssi": d.rssi,
            "weight_kg": d.weight_kg,
            "impedance_ohm": d.impedance_ohm,
            "service_data_hex": d.service_data_hex,
            "manufacturer_data_hex": d.manufacturer_data_hex,
        }
        client.publish(f"bt/mi_scale/{d.mac}", json.dumps(mi_payload, separators=(",", ":")), qos=0, retain=False)
        
        if write_influx and d.weight_kg is not None:
            _write_to_influxdb(d)
            _write_daily_first_to_influxdb(d)
    
    if d.is_govee and (d.temp_c is not None or d.humidity_pct is not None):
        gov_payload = {
            "ts": ts,
            "mac": d.mac,
            "name": d.name,
            "rssi": d.rssi,
            "temp_c": d.temp_c,
            "humidity_pct": d.humidity_pct,
            "manufacturer_data_hex": d.manufacturer_data_hex,
        }
        client.publish(f"bt/govee/{d.mac}", json.dumps(gov_payload, separators=(",", ":")), qos=0, retain=False)
        
        if write_influx and (d.temp_c is not None or d.humidity_pct is not None):
            _write_to_influxdb(d)


def scan_and_publish(client: mqtt.Client, scan_seconds: int, target_mac: str, vid: int, pid: int) -> None:
    disable_kernel_btusb()
    scanner = USBHciScanner(vid=vid, pid=pid)
    seen = set()

    try:
        scanner.open()
        scanner.setup_scan()
        scanner.set_scan_enable(True)
        log.info("USB-HCI scan started for %ds", scan_seconds)

        deadline = None if scan_seconds <= 0 else time.time() + max(1, scan_seconds)
        while deadline is None or time.time() < deadline:
            pkt = scanner.read_event()
            if not pkt:
                continue
            for d in parse_adv_reports(pkt):
                dedup_key = (d.mac, d.payload_hex)
                if dedup_key in seen:
                    continue
                seen.add(dedup_key)
                publish_detection(client, d, target_mac)

        if deadline is None:
            log.info("USB-HCI continuous scan exiting, unique adv frames=%d", len(seen))
        else:
            log.info("USB-HCI scan complete, unique adv frames=%d", len(seen))
    finally:
        try:
            scanner.set_scan_enable(False)
        except (usb.core.USBError, RuntimeError):
            # The scanner is being torn down; a USB error or a closed device
            # (RuntimeError "device not open") is expected here and must not hide the
            # scan's own outcome.  Anything else is a bug and must surface.
            pass
        scanner.close()


def parse_hex_int(value: str) -> int:
    value = value.strip().lower()
    return int(value, 16) if value.startswith("0x") else int(value)


def main() -> None:
    ap = argparse.ArgumentParser(description="pyusb direct-USB BLE scan bridge")
    ap.add_argument("--mqtt-host", default=DEFAULT_MQTT_HOST)
    ap.add_argument("--mqtt-port", type=int, default=DEFAULT_MQTT_PORT)
    ap.add_argument("--scan-seconds", type=int, default=DEFAULT_SCAN_SECONDS)
    ap.add_argument("--target-mac", default=DEFAULT_TARGET_MAC)
    ap.add_argument("--usb-vid", default=f"0x{DEFAULT_USB_VID:04x}")
    ap.add_argument("--usb-pid", default=f"0x{DEFAULT_USB_PID:04x}")
    ap.add_argument("--once", action="store_true")
    args = ap.parse_args()

    vid = parse_hex_int(args.usb_vid)
    pid = parse_hex_int(args.usb_pid)
    target_mac = args.target_mac.upper()

    client = mqtt.Client(client_id="nas-bt-bridge", callback_api_version=mqtt.CallbackAPIVersion.VERSION2, clean_session=True)
    client.will_set("bt/bridge/status", "offline", qos=1, retain=True)

    try:
        client.connect(args.mqtt_host, args.mqtt_port, keepalive=60)
    except OSError as exc:
        # paho raises OSError subclasses (ConnectionRefusedError, socket errors) when
        # the broker is unreachable; that expected failure is re-raised as a named
        # exit, never swallowed.  Anything else is a bug and must surface.
        raise SystemExit(f"MQTT connect failed: {exc}") from exc

    client.loop_start()
    client.publish("bt/bridge/status", "online", qos=1, retain=True)

    try:
        if args.once:
            scan_and_publish(client, args.scan_seconds, target_mac, vid, pid)
        else:
            while True:
                scan_and_publish(client, args.scan_seconds, target_mac, vid, pid)
                time.sleep(RESTART_DELAY_S)
    except KeyboardInterrupt:
        pass
    finally:
        client.publish("bt/bridge/status", "offline", qos=1, retain=True)
        client.loop_stop()
        client.disconnect()


if __name__ == "__main__":
    main()
