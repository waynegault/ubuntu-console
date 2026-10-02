#!/usr/bin/env python3
"""
Salus Tool Definitions for Jarvis Agent Integration

Provides callable tools that Jarvis can use to control the Salus iT500 thermostat
via the salus.py CLI. These tools are designed to be registered with an LLM-based agent.

Usage in Jarvis agent.py:
  from salus_tools import SALUS_TOOLS
  # ... register SALUS_TOOLS in your agent's tool list
"""

import json
import subprocess
import sys
from pathlib import Path
from typing import Dict, Any

# Path to the salus.py script
SALUS_SCRIPT = Path(__file__).parent / "salus.py"
PYTHON_EXECUTABLE = sys.executable


def _run_salus_command(command: str, *args: str) -> Dict[str, Any]:
    """
    Execute a salus.py command and return the JSON result.

    Args:
        command: The command name (e.g., "get-state", "adjust-temp")
        *args: Arguments to pass to the command

    Returns:
        Dictionary containing the command result or error
    """
    try:
        cmd = [str(PYTHON_EXECUTABLE), str(SALUS_SCRIPT), command] + list(args)
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=30
        )

        # Try to parse JSON from stdout
        if result.stdout.strip():
            try:
                return json.loads(result.stdout)
            except json.JSONDecodeError:
                return {"ok": False, "error": "Invalid JSON response from salus.py"}

        # If no stdout but there's stderr, return the error
        if result.stderr.strip():
            try:
                return json.loads(result.stderr)
            except json.JSONDecodeError:
                return {"ok": False, "error": result.stderr}

        return {"ok": False, "error": "No response from salus.py"}

    except subprocess.TimeoutExpired:
        return {"ok": False, "error": "Command timed out after 30 seconds"}
    except Exception as e:
        return {"ok": False, "error": str(e)}


# ============================================================================
# Tool Callables
# ============================================================================

def salus_get_state() -> Dict[str, Any]:
    """Get the current state of the Salus thermostat."""
    return _run_salus_command("get-state")


def salus_set_temperature(temperature: float) -> Dict[str, Any]:
    """
    Set the target temperature.

    Args:
        temperature: Target temperature in Celsius (5-35°C)
    """
    return _run_salus_command("set-temp", str(temperature))


def salus_adjust_temperature(delta: float) -> Dict[str, Any]:
    """
    Adjust the target temperature by a relative amount.

    Args:
        delta: Temperature change in Celsius (-10 to +10°C)
    """
    return _run_salus_command("adjust-temp", str(delta))


def salus_set_mode(mode: str) -> Dict[str, Any]:
    """
    Set heating mode.

    Args:
        mode: "heat" to enable, "off" to disable
    """
    return _run_salus_command("set-mode", mode.lower())


def salus_heat_off_for(duration_minutes: int) -> Dict[str, Any]:
    """
    Pause heating for a specified duration, with automatic resume.

    Args:
        duration_minutes: Minutes to pause (will be automatically resumed)
    """
    return _run_salus_command("heat-off-for", str(duration_minutes))


def salus_resume_heating() -> Dict[str, Any]:
    """Resume heating immediately (cancel any active pause)."""
    return _run_salus_command("resume-heating")


def salus_set_hot_water(state: str) -> Dict[str, Any]:
    """
    Turn hot water on or off.

    Args:
        state: "on" or "off"
    """
    return _run_salus_command("set-hot-water", state.lower())


def salus_set_hot_water_mode(mode: str) -> Dict[str, Any]:
    """
    Set hot water mode.

    Args:
        mode: "auto", "on", or "off"
    """
    return _run_salus_command("set-hot-water-mode", mode.lower())


def salus_boost_hot_water(duration_minutes: int) -> Dict[str, Any]:
    """
    Boost hot water for a specified duration.

    Args:
        duration_minutes: Requested duration in minutes
                         (device rounds to nearest supported hour: 1, 2, or 3)
    """
    return _run_salus_command("boost-hot-water", str(duration_minutes))


def salus_stop_hot_water_boost() -> Dict[str, Any]:
    """Stop an active hot water boost and return to automatic mode."""
    return _run_salus_command("stop-hot-water-boost")


def salus_get_air_sensor() -> Dict[str, Any]:
    """Get current air sensor readings (temperature, humidity, pressure, PM levels)."""
    return _run_salus_command("get-air-sensor")


def salus_get_delta_temperature() -> Dict[str, Any]:
    """Calculate the temperature difference between indoor and outdoor."""
    return _run_salus_command("get-delta-temp")


def salus_heat_if_outside_below(threshold_celsius: float) -> Dict[str, Any]:
    """
    Conditionally control heating based on outside temperature.
    Enables heating if outside temp is below threshold, disables otherwise.

    Args:
        threshold_celsius: Temperature threshold in Celsius
    """
    return _run_salus_command("heat-if-outside-below", str(threshold_celsius))


def salus_delay_command(delay_seconds: int, command: str, *args: str) -> Dict[str, Any]:
    """
    Schedule a Salus command to run after a delay.

    Args:
        delay_seconds: Seconds to delay before execution
        command: The command to schedule (e.g., "boost-hot-water")
        *args: Arguments for the command

    Returns:
        Dictionary with task_id for later status checking
    """
    cmd_args = [str(delay_seconds), command] + list(args)
    return _run_salus_command("delay-command", *cmd_args)


def salus_list_scheduled() -> Dict[str, Any]:
    """List all scheduled commands (pending, running, completed, failed)."""
    return _run_salus_command("list-scheduled")


def salus_schedule_status(task_id: str) -> Dict[str, Any]:
    """
    Get the status of a scheduled command.

    Args:
        task_id: The task ID returned by delay_command
    """
    return _run_salus_command("schedule-status", task_id)


# ============================================================================
# Tool Definitions for LLM Agent Registration
# ============================================================================

SALUS_TOOLS = [
    {
        "name": "salus_get_state",
        "description": (
            "Get the current state of the Salus iT500 thermostat, including current temperature, "
            "target temperature, heating mode, hot water status, and next scheduled events."
        ),
        "callable": salus_get_state,
        "parameters": {},
    },
    {
        "name": "salus_set_temperature",
        "description": (
            "Set the target temperature for the heating system. "
            "This overrides the schedule until the next scheduled event."
        ),
        "callable": salus_set_temperature,
        "parameters": {
            "temperature": (
                "Target temperature in Celsius (must be between 5°C and 35°C). "
                "Example: 20.5 for 20.5 degrees."
            ),
        },
    },
    {
        "name": "salus_adjust_temperature",
        "description": (
            "Adjust the current target temperature up or down by a relative amount. "
            "Use this for phrases like 'increase temperature 2 degrees' or 'decrease by 1.5 degrees'."
        ),
        "callable": salus_adjust_temperature,
        "parameters": {
            "delta": (
                "Temperature change in Celsius (must be between -10°C and +10°C). "
                "Positive values increase temperature, negative values decrease it."
            ),
        },
    },
    {
        "name": "salus_set_mode",
        "description": "Enable or disable heating.",
        "callable": salus_set_mode,
        "parameters": {
            "mode": "Either 'heat' to enable heating or 'off' to disable it.",
        },
    },
    {
        "name": "salus_heat_off_for",
        "description": (
            "Pause heating for a specified duration, with automatic resume. "
            "This uses the device's built-in holiday mode for reliable timed pause."
        ),
        "callable": salus_heat_off_for,
        "parameters": {
            "duration_minutes": (
                "Number of minutes to pause heating (must be greater than 0). "
                "The system will automatically resume heating when the time expires."
            ),
        },
    },
    {
        "name": "salus_resume_heating",
        "description": "Resume heating immediately, cancelling any active pause or holiday mode.",
        "callable": salus_resume_heating,
        "parameters": {},
    },
    {
        "name": "salus_set_hot_water",
        "description": "Turn hot water on or off permanently.",
        "callable": salus_set_hot_water,
        "parameters": {
            "state": "Either 'on' to enable or 'off' to disable hot water.",
        },
    },
    {
        "name": "salus_set_hot_water_mode",
        "description": (
            "Set hot water operating mode: auto (follows schedule), on (always on), or off (always off)."
        ),
        "callable": salus_set_hot_water_mode,
        "parameters": {
            "mode": "One of: 'auto', 'on', or 'off'.",
        },
    },
    {
        "name": "salus_boost_hot_water",
        "description": (
            "Boost hot water for a specified duration. "
            "Note: The device only supports 1, 2, or 3-hour boosts. "
            "Requests are rounded up to the nearest supported duration, which is returned in the response."
        ),
        "callable": salus_boost_hot_water,
        "parameters": {
            "duration_minutes": (
                "Requested boost duration in minutes. "
                "The device will round to nearest supported hour (min 1 hour = 60 min, max 3 hours = 180 min). "
                "The effective duration is returned in the response."
            ),
        },
    },
    {
        "name": "salus_stop_hot_water_boost",
        "description": "Stop an active hot water boost and return to automatic mode.",
        "callable": salus_stop_hot_water_boost,
        "parameters": {},
    },
    {
        "name": "salus_get_air_sensor",
        "description": (
            "Get current outside air sensor readings including temperature, humidity, pressure, "
            "and particulate matter (PM2.5 and PM10). Useful for informing heating decisions."
        ),
        "callable": salus_get_air_sensor,
        "parameters": {},
    },
    {
        "name": "salus_get_delta_temperature",
        "description": (
            "Calculate the difference between indoor and outdoor temperature. "
            "Returns how many degrees warmer the house is compared to outside."
        ),
        "callable": salus_get_delta_temperature,
        "parameters": {},
    },
    {
        "name": "salus_heat_if_outside_below",
        "description": (
            "Conditionally control heating based on outside temperature. "
            "If outside temperature is below the threshold, heating is enabled. "
            "If above, heating is disabled. Useful for responding to weather changes."
        ),
        "callable": salus_heat_if_outside_below,
        "parameters": {
            "threshold_celsius": (
                "Temperature threshold in Celsius. "
                "Heating will be enabled if outside temperature falls below this value."
            ),
        },
    },
    {
        "name": "salus_delay_command",
        "description": (
            "Schedule a Salus command to run at a future time. "
            "Use this for delayed execution like 'boost hot water in 30 minutes'. "
            "Returns a task_id which can be used to check status later."
        ),
        "callable": salus_delay_command,
        "parameters": {
            "delay_seconds": "Number of seconds to wait before executing the command.",
            "command": "The Salus command to schedule (e.g., 'boost-hot-water', 'adjust-temp').",
            "args": "Arguments for the command as a space-separated string (e.g., '30' for 30 minutes).",
        },
    },
    {
        "name": "salus_list_scheduled",
        "description": (
            "List all scheduled Salus commands (pending, running, completed, or failed). "
            "Use this to see what commands are queued for future execution."
        ),
        "callable": salus_list_scheduled,
        "parameters": {},
    },
    {
        "name": "salus_schedule_status",
        "description": (
            "Check the status of a previously scheduled command by its task_id. "
            "Shows whether it's pending, running, completed, failed, or cancelled."
        ),
        "callable": salus_schedule_status,
        "parameters": {
            "task_id": "The task_id returned by salus_delay_command.",
        },
    },
]

if __name__ == "__main__":
    # Example: Show all available tools
    print("Available Salus Tools for Jarvis:")
    print("=" * 60)
    for tool in SALUS_TOOLS:
        print(f"\n{tool['name']}")
        print(f"  Description: {tool['description']}")
        if tool['parameters']:
            print(f"  Parameters: {tool['parameters']}")
