"""Tests for the NAS BLE bridge's exception handling (card 887c1d65).

``nas/butler/bt-bridge/nas-bt-mqtt-bridge.py`` carried six ``except Exception``
handlers each silenced with ``# noqa: BLE001``.  Narrowing them is the point of the
card: a blind ``except`` turns a programming error into a plausible return value —
measured here on ``run()``, where the old handler reported a bad call as ``rc=-1``
("the binary failed") instead of letting the bug surface.

The module imports paho-mqtt and pyusb at load time and ``raise SystemExit`` when
they are absent (they are NAS-only runtime deps, never in this repo's venv).  The
stubs below install exactly those names so the module can be loaded by path; they
are not mocks of the code under test, and setattr is used so no attribute-access
suppression is needed.
"""

from __future__ import annotations

import importlib.util
import sys
import types
from pathlib import Path
from typing import Any, cast

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent


def _install_nas_dep_stubs() -> None:
    """Register minimal paho + pyusb modules so the bridge module can import.

    Only the names the module touches at import time are provided.  usb.core.USBError
    is a real class so the two narrowed handlers that name it are constructible.
    """

    class USBError(Exception):
        """Stand-in for pyusb's usb.core.USBError."""

    usb = types.ModuleType("usb")
    usb_core = types.ModuleType("usb.core")
    setattr(usb_core, "USBError", USBError)
    setattr(usb, "core", usb_core)

    usb_backend = types.ModuleType("usb.backend")
    usb_libusb1 = types.ModuleType("usb.backend.libusb1")
    setattr(usb, "backend", usb_backend)
    setattr(usb_backend, "libusb1", usb_libusb1)

    usb_util = types.ModuleType("usb.util")
    setattr(usb, "util", usb_util)

    paho = types.ModuleType("paho")
    paho_mqtt = types.ModuleType("paho.mqtt")
    paho_client = types.ModuleType("paho.mqtt.client")
    setattr(paho, "mqtt", paho_mqtt)
    setattr(paho_mqtt, "client", paho_client)

    for name, module in (
        ("usb", usb),
        ("usb.core", usb_core),
        ("usb.backend", usb_backend),
        ("usb.backend.libusb1", usb_libusb1),
        ("usb.util", usb_util),
        ("paho", paho),
        ("paho.mqtt", paho_mqtt),
        ("paho.mqtt.client", paho_client),
    ):
        sys.modules.setdefault(name, module)


def _load_bridge() -> types.ModuleType:
    """Import the hyphenated bridge script by path (its name is not a module name)."""
    _install_nas_dep_stubs()
    spec = importlib.util.spec_from_file_location(
        "nas_bt_bridge", REPO_ROOT / "nas" / "butler" / "bt-bridge" / "nas-bt-mqtt-bridge.py"
    )
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    try:
        spec.loader.exec_module(module)
    except BaseException:
        del sys.modules[spec.name]
        raise
    return module


#: The loaded module.  Typed Any so the tests reach its functions without naming a
#: stub package, and so no attribute-access suppression is needed.
bridge: Any = _load_bridge()


def test_run_reports_a_missing_binary_as_rc_minus_one() -> None:
    """The narrowed handler still covers the expected spawn failure.

    Catches: a narrowing that is TOO tight — a missing binary (FileNotFoundError, an
    OSError) must keep returning ``(-1, "", reason)`` rather than propagating, because
    the callers treat ``rc=-1`` as "could not run".
    """
    rc, out, err = bridge.run(["definitely-not-a-real-binary-xyz"])
    assert rc == -1
    assert out == ""
    assert err, "the OSError reason should be reported in stderr"


def test_run_does_not_swallow_an_unexpected_exception() -> None:
    """A programming error must surface, not be laundered into rc=-1.

    Catches the pre-fix blind handler: ``subprocess.run(123)`` raises TypeError
    ("'int' object is not iterable"), which is NOT a spawn failure.  The old
    ``except Exception`` returned ``(-1, "", "'int' object is not iterable")`` — a
    plausible-looking "the command failed" for a caller bug.  The narrowed handler
    must let it raise.
    """
    with pytest.raises(TypeError):
        bridge.run(cast(Any, 123))


def test_parse_govee_frame_rejects_a_malformed_payload_without_raising() -> None:
    """A malformed advertisement is (None, None), the documented "not parseable".

    Catches: a narrowing that drops a shape error the parser legitimately meets — an
    out-of-range byte makes int.from_bytes raise ValueError, and the caller must keep
    reading (None, None) rather than seeing the exception escape.
    """
    assert bridge._parse_govee_frame(cast(Any, [1, 2, 300])) == (None, None)
