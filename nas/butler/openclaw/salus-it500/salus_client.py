"""Salus iT500 async REST API client."""

import hashlib
import logging
import math
import xml.etree.ElementTree as ET
from dataclasses import dataclass
from datetime import datetime, time, timedelta
from typing import Optional

import aiohttp

_LOGGER = logging.getLogger(__name__)

_URL_LOGIN = "https://sal-emea-p01-api.arrayent.com/acc/applications/SalusService/sessions"
_URL_GET_DATA = "https://sal-emea-p01-api.arrayent.com/zdk/services/zamapi/getDeviceAttributesWithValues"
_URL_SET_DATA = "https://sal-emea-p01-api.arrayent.com/zdk/services/zamapi/setMultiDeviceAttributes2"

_APP_AUTH = "687886-679716122"

_ATTR_CURRENT_TEMP = "A84"
_ATTR_TARGET_TEMP = "A85"
_ATTR_SCHEDULE_TYPE = "A86"
_ATTR_HEATING_STATE = "A87"
_ATTR_AUTO_OR_HOLD = "A88"
_ATTR_OFF_MODE = "A89"
_ATTR_MANUAL_MODE = "A92"
_ATTR_HOT_WATER_STATUS = "C45"
_ATTR_HOT_WATER_MODE = "C42"
_ATTR_HOT_WATER_BOOST = "C43"
_ATTR_HOT_WATER_SCHEDULE_TYPE = "C44"
_ATTR_FROST_TEMP = "S09"
_ATTR_HOLIDAY_OPTION = "S10"
_ATTR_HOLIDAY_START = "S11"
_ATTR_HOLIDAY_END = "S12"

_HEATING_PROGRAM_ATTRS = [f"A0{i}" for i in range(7)]
_HOT_WATER_PROGRAM_ATTRS = [f"C0{i}" for i in range(7)]

_SCHEDULE_TYPE_NAMES = {
    "0": "all",
    "1": "five_two",
    "2": "independent",
}

_HOT_WATER_MODE_NAMES = {
    "0": "auto",
    "1": "boost",
    "2": "on",
    "3": "off",
}

_DAY_NAMES = [
    "monday",
    "tuesday",
    "wednesday",
    "thursday",
    "friday",
    "saturday",
    "sunday",
]

_TOKEN_TTL_SECONDS = 55 * 60


@dataclass
class HeatingScheduleEvent:
    day: str
    at: str
    setpoint: float


@dataclass
class HotWaterScheduleEvent:
    day: str
    at: str
    state: str
    kind: str


@dataclass
class SalusState:
    observed_at: str
    current_temperature: Optional[float]
    target_temperature: Optional[float]
    frost_temperature: Optional[float]
    hvac_mode: str
    heating_active: bool
    hot_water_enabled: Optional[bool]
    heating_control_mode: str
    heating_schedule_type: Optional[str]
    hot_water_mode: Optional[str]
    hot_water_schedule_type: Optional[str]
    hot_water_boost_remaining_hours: Optional[int]
    holiday_mode_active: bool
    holiday_start: Optional[str]
    holiday_end: Optional[str]
    next_heating_schedule_change_will_apply_automatically: bool
    next_hot_water_event_will_apply_automatically: bool
    next_heating_schedule_change: Optional[HeatingScheduleEvent]
    next_hot_water_event: Optional[HotWaterScheduleEvent]


class SalusAuthError(Exception):
    pass


class SalusAPIError(Exception):
    pass


class _DeviceAttributeResponse:
    """Parses the XML attribute response from the Salus gateway."""

    def __init__(self, xml_text: str):
        self._root = ET.fromstring(xml_text)

    def get(self, attr_name: str) -> Optional[str]:
        node = self._root.find(f"./attrList/[name='{attr_name}']/value")
        return node.text if node is not None else None


def _decode_schedule_char(char: str) -> int:
    if len(char) != 1:
        raise ValueError(f"Expected one schedule character, got {char!r}")
    value = ord(char) - 48
    if value < 0:
        raise ValueError(f"Unsupported schedule character: {char!r}")
    return value


def _parse_heating_program(program: Optional[str]) -> list[tuple[time, float]]:
    if not program:
        return []
    if len(program) % 4 != 0:
        raise ValueError(f"Unexpected heating program length: {program!r}")

    entries = []
    for index in range(0, len(program), 4):
        time_pair = program[index:index + 2]
        temp_pair = program[index + 2:index + 4]
        entries.append(
            (
                time(hour=_decode_schedule_char(time_pair[0]), minute=_decode_schedule_char(time_pair[1])),
                _decode_schedule_char(temp_pair[0]) + (_decode_schedule_char(temp_pair[1]) / 10.0),
            )
        )
    return entries


def _parse_hot_water_program(program: Optional[str]) -> list[tuple[time, str]]:
    if not program:
        return []
    if len(program) % 2 != 0:
        raise ValueError(f"Unexpected hot water program length: {program!r}")

    pairs = [program[index:index + 2] for index in range(0, len(program), 2)]
    entries = []
    for index, pair in enumerate(pairs):
        event_time = time(hour=_decode_schedule_char(pair[0]), minute=_decode_schedule_char(pair[1]))
        entries.append((event_time, "on" if index % 2 == 0 else "off"))
    return entries


def _next_heating_event(programs: list[list[tuple[time, float]]], now: datetime) -> Optional[HeatingScheduleEvent]:
    for day_offset in range(8):
        day_dt = now + timedelta(days=day_offset)
        day_events = programs[day_dt.weekday()]
        for event_time, setpoint in day_events:
            scheduled_at = datetime.combine(day_dt.date(), event_time, tzinfo=now.tzinfo)
            if scheduled_at > now:
                return HeatingScheduleEvent(
                    day=_DAY_NAMES[day_dt.weekday()],
                    at=scheduled_at.isoformat(),
                    setpoint=round(setpoint, 1),
                )
    return None


def _next_hot_water_event(
    programs: list[list[tuple[time, str]]],
    now: datetime,
    hot_water_mode: Optional[str],
    boost_remaining_hours: Optional[int],
) -> Optional[HotWaterScheduleEvent]:
    if hot_water_mode == "boost" and boost_remaining_hours and boost_remaining_hours > 0:
        boost_end = now + timedelta(hours=boost_remaining_hours)
        return HotWaterScheduleEvent(
            day=_DAY_NAMES[boost_end.weekday()],
            at=boost_end.isoformat(),
            state="off",
            kind="boost_end",
        )

    for day_offset in range(8):
        day_dt = now + timedelta(days=day_offset)
        day_events = programs[day_dt.weekday()]
        for event_time, state in day_events:
            scheduled_at = datetime.combine(day_dt.date(), event_time, tzinfo=now.tzinfo)
            if scheduled_at > now:
                return HotWaterScheduleEvent(
                    day=_DAY_NAMES[day_dt.weekday()],
                    at=scheduled_at.isoformat(),
                    state=state,
                    kind=f"schedule_{state}",
                )
    return None


def _parse_salus_timestamp(value: Optional[str], tzinfo) -> Optional[datetime]:
    if value in (None, "", "0"):
        return None
    try:
        return datetime.strptime(value, "%Y%m%d%H%M").replace(tzinfo=tzinfo)
    except ValueError:
        _LOGGER.warning("Unexpected Salus timestamp value: %r", value)
        return None


def _format_salus_timestamp(value: datetime) -> str:
    return value.astimezone().strftime("%Y%m%d%H%M")


class SalusClient:
    """Async client for the Salus iT500 thermostat REST API."""

    def __init__(
        self,
        session: aiohttp.ClientSession,
        username: str,
        password: str,
        device_id: str,
    ):
        self._session = session
        self._username = username
        self._password_hash = hashlib.md5(password.encode()).hexdigest()
        self._device_id = device_id
        self._security_token: Optional[str] = None
        self._token_age: float = 0.0

    async def _ensure_token(self) -> str:
        """Return a valid security token, refreshing if needed."""
        import time
        if self._security_token and time.time() - self._token_age < _TOKEN_TTL_SECONDS:
            return self._security_token
        await self._refresh_token()
        return self._security_token

    async def _refresh_token(self) -> None:
        import time
        _LOGGER.debug("Refreshing Salus security token...")
        headers = {"Authorization": _APP_AUTH, "Accept": "application/json"}
        payload = {"username": self._username, "password": self._password_hash}
        try:
            resp = await self._session.post(_URL_LOGIN, json=payload, headers=headers, timeout=aiohttp.ClientTimeout(total=30))
            resp.raise_for_status()
            data = await resp.json()
        except aiohttp.ClientResponseError as exc:
            raise SalusAuthError(f"Login failed ({exc.status}): {exc.message}") from exc
        except Exception as exc:
            raise SalusAuthError(f"Login error: {exc}") from exc

        token = data.get("securityToken")
        if not token:
            raise SalusAuthError(f"No securityToken in login response: {data}")
        self._security_token = token
        self._token_age = time.time()
        _LOGGER.debug("Token refreshed OK")

    async def get_state(self) -> SalusState:
        """Fetch current thermostat state."""
        token = await self._ensure_token()
        params = {
            "devId": self._device_id,
            "deviceTypeId": "1",
            "secToken": token,
        }
        try:
            resp = await self._session.get(_URL_GET_DATA, params=params, timeout=aiohttp.ClientTimeout(total=30))
            resp.raise_for_status()
            body = await resp.text()
        except aiohttp.ClientResponseError as exc:
            raise SalusAPIError(f"get_state failed ({exc.status}): {exc.message}") from exc

        attrs = _DeviceAttributeResponse(body)

        def _temp(attr: str) -> Optional[float]:
            val = attrs.get(attr)
            return float(val) * 0.01 if val is not None else None

        off_mode = attrs.get(_ATTR_OFF_MODE)
        auto_or_hold = attrs.get(_ATTR_AUTO_OR_HOLD)
        manual_mode = attrs.get(_ATTR_MANUAL_MODE)
        heating_state = attrs.get(_ATTR_HEATING_STATE)
        hw_status = attrs.get(_ATTR_HOT_WATER_STATUS)
        schedule_type = attrs.get(_ATTR_SCHEDULE_TYPE)
        hot_water_mode = attrs.get(_ATTR_HOT_WATER_MODE)
        hot_water_boost = attrs.get(_ATTR_HOT_WATER_BOOST)
        hot_water_schedule_type = attrs.get(_ATTR_HOT_WATER_SCHEDULE_TYPE)
        holiday_option = attrs.get(_ATTR_HOLIDAY_OPTION)

        if off_mode == "1":
            heating_control_mode = "off"
        elif manual_mode == "1":
            heating_control_mode = "manual"
        elif auto_or_hold == "1":
            heating_control_mode = "temp_hold"
        else:
            heating_control_mode = "auto"

        now = datetime.now().astimezone()
        heating_programs = [_parse_heating_program(attrs.get(attr_name)) for attr_name in _HEATING_PROGRAM_ATTRS]
        hot_water_programs = [_parse_hot_water_program(attrs.get(attr_name)) for attr_name in _HOT_WATER_PROGRAM_ATTRS]
        hot_water_mode_name = _HOT_WATER_MODE_NAMES.get(hot_water_mode) if hot_water_mode is not None else None
        hot_water_boost_remaining_hours = int(hot_water_boost) if hot_water_boost not in (None, "") else None
        holiday_start = _parse_salus_timestamp(attrs.get(_ATTR_HOLIDAY_START), now.tzinfo)
        holiday_end = _parse_salus_timestamp(attrs.get(_ATTR_HOLIDAY_END), now.tzinfo)
        holiday_mode_active = holiday_option == "1" and holiday_end is not None and holiday_end > now
        if not holiday_mode_active:
            holiday_start = None
            holiday_end = None

        return SalusState(
            observed_at=now.isoformat(),
            current_temperature=_temp(_ATTR_CURRENT_TEMP),
            target_temperature=_temp(_ATTR_TARGET_TEMP),
            frost_temperature=_temp(_ATTR_FROST_TEMP),
            hvac_mode="off" if off_mode == "1" else "heat",
            heating_active=heating_state == "1",
            hot_water_enabled=None if hw_status is None else (hw_status != "0"),
            heating_control_mode=heating_control_mode,
            heating_schedule_type=_SCHEDULE_TYPE_NAMES.get(schedule_type),
            hot_water_mode=hot_water_mode_name,
            hot_water_schedule_type=_SCHEDULE_TYPE_NAMES.get(hot_water_schedule_type),
            hot_water_boost_remaining_hours=hot_water_boost_remaining_hours,
            holiday_mode_active=holiday_mode_active,
            holiday_start=holiday_start.isoformat() if holiday_start is not None else None,
            holiday_end=holiday_end.isoformat() if holiday_end is not None else None,
            next_heating_schedule_change_will_apply_automatically=(heating_control_mode == "auto" and not holiday_mode_active),
            next_hot_water_event_will_apply_automatically=hot_water_mode_name == "auto",
            next_heating_schedule_change=_next_heating_event(heating_programs, now),
            next_hot_water_event=_next_hot_water_event(
                hot_water_programs,
                now,
                hot_water_mode_name,
                hot_water_boost_remaining_hours,
            ),
        )

    async def _set_attrs(self, **kwargs) -> None:
        """Set one or more device attributes."""
        token = await self._ensure_token()
        payload = {"secToken": token, "devId": self._device_id, **kwargs}
        headers = {"Content-Type": "application/x-www-form-urlencoded"}
        try:
            resp = await self._session.put(
                _URL_SET_DATA,
                data=payload,
                headers=headers,
                timeout=aiohttp.ClientTimeout(total=30),
            )
            resp.raise_for_status()
            body = await resp.text()
        except aiohttp.ClientResponseError as exc:
            raise SalusAPIError(f"set_attrs failed ({exc.status}): {exc.message}") from exc

        xml = ET.fromstring(body)
        err_node = xml.find("./errorMsg")
        if err_node is not None:
            raise SalusAPIError(f"API error: {err_node.text}")
        ret_node = xml.find("./retCode")
        if ret_node is None or int(ret_node.text) != 0:
            raise SalusAPIError(f"Unexpected retCode: {ET.tostring(xml, encoding='unicode')}")

    async def set_temperature(self, temperature: float) -> None:
        """Set target temperature (°C). Puts device into temp-hold mode."""
        _LOGGER.info("Setting temperature to %.1f°C", temperature)
        await self.clear_holiday_mode()
        await self._set_attrs(
            name1=_ATTR_AUTO_OR_HOLD,
            value1="1",
            name2=_ATTR_TARGET_TEMP,
            value2=int(round(temperature, 1) * 100),
        )

    async def adjust_temperature(self, delta: float) -> float:
        """Adjust the target temperature relative to the current target."""
        state = await self.get_state()
        if state.target_temperature is None:
            raise SalusAPIError("Current target temperature is unavailable")

        new_temperature = round(state.target_temperature + delta, 1)
        await self.set_temperature(new_temperature)
        return new_temperature

    async def set_hvac_mode(self, mode: str) -> None:
        """Set HVAC mode. mode must be heat or off."""
        if mode not in ("heat", "off"):
            raise ValueError(f"mode must be 'heat' or 'off', got: {mode!r}")
        _LOGGER.info("Setting HVAC mode to %s", mode)
        if mode == "heat":
            await self.clear_holiday_mode()
        value = "1" if mode == "off" else "0"
        await self._set_attrs(name1=_ATTR_OFF_MODE, value1=value)

    async def set_heat_off_for(self, duration: timedelta, start_delay: timedelta = timedelta(0)) -> tuple[datetime, datetime]:
        """Pause heating via holiday mode, which auto-resumes at the end time."""
        if duration <= timedelta(0):
            raise ValueError("duration must be greater than zero")
        if start_delay < timedelta(0):
            raise ValueError("start_delay cannot be negative")

        now = datetime.now().astimezone()
        start_at = now + start_delay
        end_at = start_at + duration
        if end_at - now > timedelta(days=31):
            raise ValueError("Salus holiday mode supports at most 31 days from now")

        await self._set_attrs(
            name1=_ATTR_HOLIDAY_START,
            value1=_format_salus_timestamp(start_at),
            name2=_ATTR_HOLIDAY_END,
            value2=_format_salus_timestamp(end_at),
            name3=_ATTR_HOLIDAY_OPTION,
            value3="1",
        )
        return start_at, end_at

    async def clear_holiday_mode(self) -> None:
        """Disable holiday mode so heating can resume normally."""
        await self._set_attrs(name1=_ATTR_HOLIDAY_OPTION, value1="0")

    async def set_hot_water_mode(self, mode: str) -> None:
        """Set hot water mode. mode must be auto, boost, on, or off."""
        mode_map = {
            "auto": "0",
            "boost": "1",
            "on": "2",
            "off": "3",
        }
        if mode not in mode_map:
            raise ValueError(f"mode must be one of {sorted(mode_map)}, got: {mode!r}")

        _LOGGER.info("Setting hot water mode to %s", mode)
        await self._set_attrs(name1=_ATTR_HOT_WATER_MODE, value1=mode_map[mode])

    async def set_hot_water(self, enabled: bool) -> None:
        """Backward-compatible helper for permanent on/off control."""
        await self.set_hot_water_mode("on" if enabled else "off")

    async def boost_hot_water(self, requested_minutes: int) -> int:
        """Enable hot water boost using the device's whole-hour boost control."""
        if requested_minutes <= 0:
            raise ValueError("requested_minutes must be greater than zero")

        effective_hours = min(3, max(1, math.ceil(requested_minutes / 60)))
        effective_minutes = effective_hours * 60
        _LOGGER.info(
            "Setting hot water boost to %d hour(s) for requested %d minute(s)",
            effective_hours,
            requested_minutes,
        )
        await self._set_attrs(
            name1=_ATTR_HOT_WATER_MODE,
            value1="1",
            name2=_ATTR_HOT_WATER_BOOST,
            value2=str(effective_hours),
        )
        return effective_minutes

    async def stop_hot_water_boost(self) -> None:
        """Stop hot water boost and return to the automatic schedule."""
        state = await self.get_state()
        if state.hot_water_mode == "boost":
            await self.set_hot_water_mode("auto")

    # =========================================================================
    # Air Sensor Integration
    # =========================================================================

    def _load_air_sensor_reading(self) -> Optional[dict]:
        """
        Load the latest air sensor reading from the shared cache file.

        Returns:
            Dictionary with air sensor data or None if unavailable
        """
        from pathlib import Path
        import json

        air_sensor_file = Path("/home/wayne/.openclaw/workspace/memory/shared/air-monitor/latest.json")
        if not air_sensor_file.exists():
            _LOGGER.warning(f"Air sensor file not found: {air_sensor_file}")
            return None

        try:
            with open(air_sensor_file, "r") as f:
                return json.load(f)
        except Exception as e:
            _LOGGER.error(f"Failed to read air sensor data: {e}")
            return None

    async def get_air_sensor_reading(self) -> Optional[dict]:
        """
        Get the current air sensor reading with parsed metrics.

        Returns:
            Dictionary containing:
            - timestamp: When the reading was taken
            - outside_temperature: °C
            - humidity: %
            - pressure: Pa
            - pm25: PM2.5 µg/m³
            - pm10: PM10 µg/m³
            - age_seconds: How long ago the reading was taken
        """
        reading = self._load_air_sensor_reading()
        if not reading:
            return None

        now = datetime.now(tz=datetime.now().astimezone().tzinfo)
        reading_time = datetime.fromisoformat(reading.get("timestamp", ""))
        age = (now - reading_time).total_seconds()

        return {
            "timestamp": reading.get("timestamp"),
            "outside_temperature": reading.get("metrics", {}).get("BME280_temperature"),
            "humidity": reading.get("metrics", {}).get("BME280_humidity"),
            "pressure": reading.get("metrics", {}).get("BME280_pressure"),
            "pm25": reading.get("pm25"),
            "pm10": reading.get("pm10"),
            "age_seconds": age,
        }

    async def get_delta_temperature(self) -> Optional[float]:
        """
        Calculate the difference between indoor and outdoor temperature.

        Returns:
            indoor_temp - outdoor_temp, or None if data unavailable
        """
        state = await self.get_state()
        air_data = await self.get_air_sensor_reading()

        if not state.current_temperature or not air_data or not air_data.get("outside_temperature"):
            _LOGGER.warning("Insufficient data for delta temperature calculation")
            return None

        delta = state.current_temperature - air_data["outside_temperature"]
        return round(delta, 1)

    async def heat_if_outside_below(self, threshold_temp: float) -> bool:
        """
        Turn heating on if outside temperature is below threshold, off otherwise.

        Args:
            threshold_temp: Temperature threshold in Celsius

        Returns:
            True if heating mode changed, False if already in desired state
        """
        air_data = await self.get_air_sensor_reading()
        if not air_data or air_data.get("outside_temperature") is None:
            _LOGGER.error("Cannot check outside temperature")
            return False

        outside_temp = air_data["outside_temperature"]
        state = await self.get_state()

        should_heat = outside_temp < threshold_temp
        is_currently_heating = state.hvac_mode != "off"

        if should_heat and not is_currently_heating:
            _LOGGER.info(f"Activating heating: outside {outside_temp}°C < threshold {threshold_temp}°C")
            await self.set_heating_mode("on")
            return True
        elif not should_heat and is_currently_heating:
            _LOGGER.info(f"Disabling heating: outside {outside_temp}°C >= threshold {threshold_temp}°C")
            await self.set_heating_mode("off")
            return True

        return False
