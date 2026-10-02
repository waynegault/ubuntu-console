#!/usr/bin/env python3
"""CLI for controlling a Salus iT500 thermostat via the REST API."""

import asyncio
from dataclasses import asdict, is_dataclass
import json
import logging
import os
import sys
from datetime import timedelta

import aiohttp

_SECRETS_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "../../secrets.json")


def _load_credentials() -> tuple[str, str, str]:
    """Load Salus credentials from secrets.json."""
    try:
        with open(_SECRETS_PATH, "r", encoding="utf-8") as f:
            secrets = json.load(f)
    except FileNotFoundError:
        _die(f"secrets.json not found at {_SECRETS_PATH}")
    except json.JSONDecodeError as exc:
        _die(f"secrets.json is not valid JSON: {exc}")

    salus = secrets.get("salus")
    if not salus:
        _die("No 'salus' key in secrets.json")

    username = salus.get("username")
    password = salus.get("password")
    device_id = salus.get("device_id")

    missing = [k for k, v in [("username", username), ("password", password), ("device_id", device_id)] if not v]
    if missing:
        _die(f"Missing Salus credential(s) in secrets.json: {', '.join(missing)}")

    return username, password, device_id


def _die(msg: str, code: int = 1) -> None:
    print(json.dumps({"error": msg}), file=sys.stderr)
    sys.exit(code)


def _out(data: dict) -> None:
    print(json.dumps(data, indent=2))


def _jsonable(value):
    if is_dataclass(value):
        return asdict(value)
    return value


def _parse_temperature(raw: str) -> float:
    try:
        temperature = float(raw)
    except ValueError:
        _die(f"Invalid temperature: {raw!r}")
    if not (5.0 <= temperature <= 35.0):
        _die(f"Temperature {temperature} is out of safe range (5-35C)")
    return temperature


def _parse_delta(raw: str) -> float:
    try:
        delta = float(raw)
    except ValueError:
        _die(f"Invalid temperature delta: {raw!r}")
    if delta == 0:
        _die("Temperature delta must not be zero")
    if not (-10.0 <= delta <= 10.0):
        _die(f"Temperature delta {delta} is out of safe range (-10 to 10C)")
    return delta


def _parse_minutes(raw: str, label: str) -> int:
    try:
        minutes = int(raw)
    except ValueError:
        _die(f"Invalid {label}: {raw!r}")
    if minutes <= 0:
        _die(f"{label} must be greater than zero")
    return minutes


async def _run(args: list[str]) -> None:
    try:
        from salus_client import SalusClient, SalusAuthError, SalusAPIError
    except ImportError as exc:
        _die(f"Could not import salus_client: {exc}. Run: pip install aiohttp")

    if not args:
        _die(
            "Usage: salus.py <get-state|set-temp|adjust-temp|set-mode|heat-off-for|resume-heating|set-hot-water|set-hot-water-mode|boost-hot-water|stop-hot-water-boost|get-air-sensor|get-delta-temp|heat-if-outside-below|delay-command|list-scheduled> [options]"
        )

    command = args[0]
    username, password, device_id = _load_credentials()

    async with aiohttp.ClientSession() as session:
        client = SalusClient(session, username, password, device_id)

        try:
            if command == "get-state":
                state = await client.get_state()
                _out(
                    {
                        "observed_at": state.observed_at,
                        "current_temperature": state.current_temperature,
                        "target_temperature": state.target_temperature,
                        "frost_temperature": state.frost_temperature,
                        "hvac_mode": state.hvac_mode,
                        "heating_active": state.heating_active,
                        "hot_water_enabled": state.hot_water_enabled,
                        "heating_control_mode": state.heating_control_mode,
                        "heating_schedule_type": state.heating_schedule_type,
                        "hot_water_mode": state.hot_water_mode,
                        "hot_water_schedule_type": state.hot_water_schedule_type,
                        "hot_water_boost_remaining_hours": state.hot_water_boost_remaining_hours,
                        "holiday_mode_active": state.holiday_mode_active,
                        "holiday_start": state.holiday_start,
                        "holiday_end": state.holiday_end,
                        "next_heating_schedule_change_will_apply_automatically": state.next_heating_schedule_change_will_apply_automatically,
                        "next_hot_water_event_will_apply_automatically": state.next_hot_water_event_will_apply_automatically,
                        "next_heating_schedule_change": _jsonable(state.next_heating_schedule_change),
                        "next_hot_water_event": _jsonable(state.next_hot_water_event),
                    }
                )

            elif command == "set-temp":
                if len(args) < 2:
                    _die("set-temp requires a temperature value, e.g. set-temp 20.5")
                temperature = _parse_temperature(args[1])
                await client.set_temperature(temperature)
                _out({"ok": True, "command": "set-temp", "value": temperature})

            elif command == "adjust-temp":
                if len(args) < 2:
                    _die("adjust-temp requires a delta value, e.g. adjust-temp 2 or adjust-temp -1.5")
                delta = _parse_delta(args[1])
                new_temperature = await client.adjust_temperature(delta)
                _out(
                    {
                        "ok": True,
                        "command": "adjust-temp",
                        "delta": delta,
                        "target_temperature": new_temperature,
                    }
                )

            elif command == "set-mode":
                if len(args) < 2:
                    _die("set-mode requires a mode: heat or off")
                mode = args[1].lower()
                if mode not in ("heat", "off"):
                    _die(f"Invalid mode {mode!r}. Use 'heat' or 'off'")
                await client.set_hvac_mode(mode)
                _out({"ok": True, "command": "set-mode", "value": mode})

            elif command == "heat-off-for":
                if len(args) < 2:
                    _die("heat-off-for requires minutes, e.g. heat-off-for 60")
                minutes = _parse_minutes(args[1], "duration minutes")
                start_at, end_at = await client.set_heat_off_for(timedelta(minutes=minutes))
                _out(
                    {
                        "ok": True,
                        "command": "heat-off-for",
                        "duration_minutes": minutes,
                        "holiday_start": start_at.isoformat(),
                        "holiday_end": end_at.isoformat(),
                    }
                )

            elif command == "resume-heating":
                await client.clear_holiday_mode()
                _out({"ok": True, "command": "resume-heating"})

            elif command == "set-hot-water":
                if len(args) < 2:
                    _die("set-hot-water requires: on or off")
                value = args[1].lower()
                if value not in ("on", "off"):
                    _die(f"Invalid value {value!r}. Use 'on' or 'off'")
                await client.set_hot_water(value == "on")
                _out({"ok": True, "command": "set-hot-water", "value": value})

            elif command == "set-hot-water-mode":
                if len(args) < 2:
                    _die("set-hot-water-mode requires: auto, on, or off")
                mode = args[1].lower()
                if mode not in ("auto", "on", "off"):
                    _die(f"Invalid mode {mode!r}. Use 'auto', 'on', or 'off'")
                await client.set_hot_water_mode(mode)
                _out({"ok": True, "command": "set-hot-water-mode", "value": mode})

            elif command == "boost-hot-water":
                if len(args) < 2:
                    _die("boost-hot-water requires minutes, e.g. boost-hot-water 60")
                requested_minutes = _parse_minutes(args[1], "boost minutes")
                effective_minutes = await client.boost_hot_water(requested_minutes)
                _out(
                    {
                        "ok": True,
                        "command": "boost-hot-water",
                        "requested_minutes": requested_minutes,
                        "effective_minutes": effective_minutes,
                        "rounded_to_device_supported_duration": effective_minutes != requested_minutes,
                    }
                )

            elif command == "stop-hot-water-boost":
                await client.stop_hot_water_boost()
                _out({"ok": True, "command": "stop-hot-water-boost", "value": "auto"})

            elif command == "get-air-sensor":
                air_data = await client.get_air_sensor_reading()
                if not air_data:
                    _die("Air sensor data unavailable")
                _out(
                    {
                        "ok": True,
                        "command": "get-air-sensor",
                        "timestamp": air_data.get("timestamp"),
                        "outside_temperature": air_data.get("outside_temperature"),
                        "humidity": air_data.get("humidity"),
                        "pressure": air_data.get("pressure"),
                        "pm25": air_data.get("pm25"),
                        "pm10": air_data.get("pm10"),
                        "age_seconds": air_data.get("age_seconds"),
                    }
                )

            elif command == "get-delta-temp":
                delta = await client.get_delta_temperature()
                if delta is None:
                    _die("Cannot calculate delta temperature (missing data)")
                _out(
                    {
                        "ok": True,
                        "command": "get-delta-temp",
                        "delta_temperature": delta,
                        "description": f"Indoor temperature is {delta}°C higher than outdoor",
                    }
                )

            elif command == "heat-if-outside-below":
                if len(args) < 2:
                    _die("heat-if-outside-below requires a temperature threshold, e.g. heat-if-outside-below 10")
                threshold = _parse_temperature(args[1])
                changed = await client.heat_if_outside_below(threshold)
                state = await client.get_state()
                _out(
                    {
                        "ok": True,
                        "command": "heat-if-outside-below",
                        "threshold": threshold,
                        "heating_changed": changed,
                        "heating_now_enabled": state.hvac_mode != "off",
                    }
                )

            elif command == "delay-command":
                if len(args) < 3:
                    _die("delay-command requires: <seconds> <command> [args...]\n"
                         "Example: delay-command 1800 boost-hot-water 30")
                try:
                    delay_seconds = int(args[1])
                except ValueError:
                    _die(f"Invalid delay seconds: {args[1]!r}")
                if delay_seconds <= 0:
                    _die("Delay must be greater than zero seconds")

                from salus_scheduler import get_scheduler
                scheduler = get_scheduler()
                command_parts = args[2:]
                task_id = scheduler.schedule_command(
                    command_parts,
                    delay_seconds,
                    description=f"{' '.join(command_parts)} (scheduled for {delay_seconds}s from now)"
                )
                _out(
                    {
                        "ok": True,
                        "command": "delay-command",
                        "task_id": task_id,
                        "delay_seconds": delay_seconds,
                        "scheduled_command": command_parts,
                        "note": "Run with asyncio event loop to actually execute: asyncio.run(scheduler.wait_and_execute(task_id))"
                    }
                )

            elif command == "list-scheduled":
                from salus_scheduler import get_scheduler
                scheduler = get_scheduler()
                tasks = scheduler.list_tasks()
                _out(
                    {
                        "ok": True,
                        "command": "list-scheduled",
                        "total_tasks": len(tasks),
                        "pending": len([t for t in tasks if t.status == "pending"]),
                        "tasks": [
                            {
                                "task_id": t.task_id,
                                "status": t.status,
                                "scheduled_time": t.scheduled_time,
                                "command": t.command,
                                "description": t.description,
                                "created_at": t.created_at,
                            }
                            for t in tasks
                        ]
                    }
                )

            elif command == "schedule-status":
                if len(args) < 2:
                    _die("schedule-status requires a task_id")
                from salus_scheduler import get_scheduler
                scheduler = get_scheduler()
                task = scheduler.get_task(args[1])
                if not task:
                    _die(f"Task {args[1]!r} not found")
                _out(
                    {
                        "ok": True,
                        "command": "schedule-status",
                        "task_id": task.task_id,
                        "status": task.status,
                        "scheduled_time": task.scheduled_time,
                        "command": task.command,
                        "description": task.description,
                        "created_at": task.created_at,
                        "executed_at": task.executed_at,
                        "result": task.result,
                        "error": task.error,
                    }
                )

            else:
                _die(
                    f"Unknown command: {command!r}. Use: get-state, set-temp, adjust-temp, set-mode, heat-off-for, resume-heating, set-hot-water, set-hot-water-mode, boost-hot-water, stop-hot-water-boost, get-air-sensor, get-delta-temp, heat-if-outside-below, delay-command, list-scheduled, schedule-status"
                )

        except SalusAuthError as exc:
            _die(f"Authentication error: {exc}")
        except SalusAPIError as exc:
            _die(f"API error: {exc}")
        except Exception as exc:
            _die(f"Unexpected error: {exc}")


def main() -> None:
    logging.basicConfig(
        level=logging.WARNING,
        format="%(levelname)s %(name)s: %(message)s",
        stream=sys.stderr,
    )
    asyncio.run(_run(sys.argv[1:]))


if __name__ == "__main__":
    main()
