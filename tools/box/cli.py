"""CLI bridge for the Box Awareness subsystem (`python3 -m tools.box`).

Module Version: 1 (2026-11-10)
Provides:
- `export-env`: outputs sanitized `export KEY="VALUE"` lines for shell sourcing
- `query <key>`: resolves profile attributes or environment variables by key path
- `detect`: outputs active profile identifier or JSON representation
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from enum import Enum
from typing import Any

from tools.box.models import HardwareProfile
from tools.box.prober import get_hardware_profile

_SAFE_KEY_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")


def _sanitize_shell_value(val: str) -> str:
    """Sanitize a value for safe single-line double-quoted bash export."""
    cleaned = val.replace("\r\n", " ").replace("\n", " ")
    for forbidden in ("`", "$(", ";", "|", "&", "\x00"):
        if forbidden in cleaned and forbidden != "|":
            cleaned = cleaned.replace(forbidden, "")
    escaped = cleaned.replace("\\", "\\\\").replace('"', '\\"')
    return f'"{escaped}"'


def format_shell_exports(profile: HardwareProfile) -> str:
    """Format a HardwareProfile as single-line bash export statements."""
    env = profile.to_env_dict()
    lines: list[str] = []
    for key, val in env.items():
        if not _SAFE_KEY_RE.match(key):
            continue
        lines.append(f"export {key}={_sanitize_shell_value(str(val))}")
    return "\n".join(lines)


def query_profile_value(profile: HardwareProfile, key_path: str) -> Any:
    """Resolve a dotted attribute path or environment variable name on a profile."""
    cleaned = key_path.strip()
    if not cleaned:
        raise KeyError("Empty query key")

    # 1. Check direct or dotted attribute traversal on HardwareProfile
    current: Any = profile
    parts = cleaned.split(".")
    found = True
    for part in parts:
        if isinstance(current, dict) and part in current:
            current = current[part]
        elif hasattr(current, part):
            current = getattr(current, part)
        else:
            found = False
            break

    if found:
        if isinstance(current, Enum):
            return current.value
        return current

    # 2. Check environment dictionary mapping
    env = profile.to_env_dict()
    if cleaned in env:
        return env[cleaned]

    raise KeyError(f"Unknown query key: {key_path!r}")


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="python3 -m tools.box",
        description="Unified Box Awareness CLI bridge",
    )
    parser.add_argument(
        "--profile",
        default=None,
        help="Explicit profile ID override (e.g. asus-n1n-rtx-spark or intel-xe-cuda)",
    )
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("export-env", help="Emit bash export statements for the active hardware profile")

    q_parser = sub.add_parser("query", help="Query a specific attribute or env key from the profile")
    q_parser.add_argument("key", help="Dotted attribute path (e.g. serving.primary_port) or env key")

    d_parser = sub.add_parser("detect", help="Detect and display the active hardware profile")
    d_parser.add_argument("--json", action="store_true", help="Output full profile as JSON")

    return parser


def main(argv: list[str] | None = None) -> int:
    parser = _build_parser()
    args = parser.parse_args(argv)

    try:
        profile = get_hardware_profile(override_id=args.profile)
    except ValueError as exc:
        print(f"tools.box: error: {exc}", file=sys.stderr)
        return 2

    if args.command == "export-env":
        print(format_shell_exports(profile))
        return 0

    if args.command == "query":
        try:
            val = query_profile_value(profile, args.key)
        except KeyError as exc:
            print(f"tools.box: error: {exc}", file=sys.stderr)
            return 1
        if isinstance(val, (dict, list)):
            print(json.dumps(val))
        elif hasattr(val, "model_dump"):
            print(val.model_dump_json())
        else:
            print(val)
        return 0

    if args.command == "detect":
        if args.json:
            print(profile.model_dump_json(indent=2))
        else:
            print(profile.id)
        return 0

    return 2


if __name__ == "__main__":
    raise SystemExit(main())
