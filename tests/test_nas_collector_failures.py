"""NAS collector failure paths must be visible (card b296c75c).

These are PYTHON, so the shell swallow gate never saw them.  The criterion for each
case is the card's acceptance: a failed dependency write cannot exit 0, and no
fallback path is silent.  Each expected value is the documented behaviour (the
module docstring / the card), not the current output.

The nas scripts are hyphenated (``nas/butler/scripts/*.py``), so they are loaded by
path.  mi-scale needs a fake paho because the real package is a NAS-only dep.
"""

from __future__ import annotations

import importlib.util
import json
import logging
import re
import sys
import types
from pathlib import Path
from typing import Any

import pytest

from _paths import REPO_ROOT

NAS = Path(REPO_ROOT) / "nas" / "butler" / "scripts"


def _load(module_name: str, filename: str) -> Any:
    spec = importlib.util.spec_from_file_location(module_name, NAS / filename)
    assert spec is not None and spec.loader is not None, f"cannot load {filename}"
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    try:
        spec.loader.exec_module(module)
    except BaseException:
        del sys.modules[spec.name]
        raise
    return module


class _URLError(Exception):
    """Stand-in for urllib.error.URLError in the fake urllib namespace."""


class _Resp:
    def __init__(self, status: int = 204, body: bytes = b"") -> None:
        self.status = status
        self._body = body

    def __enter__(self) -> "_Resp":
        return self

    def __exit__(self, *exc: Any) -> None:
        return None

    def read(self) -> bytes:
        return self._body


def _fake_urllib(*, fail: bool = False, status: int = 204, body: bytes = b"") -> Any:
    """A module-local replacement for the ``urllib`` package name."""
    ns = types.SimpleNamespace()

    class _Request:
        def __init__(self, *a: Any, **k: Any) -> None:
            pass

        def add_header(self, *a: Any, **k: Any) -> None:
            pass

    def _urlopen(*a: Any, **k: Any) -> Any:
        if fail:
            raise _URLError("influx unreachable")
        return _Resp(status, body)

    ns.request = types.SimpleNamespace(Request=_Request, urlopen=_urlopen)
    ns.error = types.SimpleNamespace(URLError=_URLError)
    return ns


# ── glowmarkt: ok must come from the write, not a hardcoded True ──────────────


def _glowmarkt(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> Any:
    # Env is read at import, so point the module's paths at the tmp dir BEFORE load.
    monkeypatch.setenv("GLOWMARKT_DATA_DIR", str(tmp_path))
    monkeypatch.setenv("GLOWMARKT_TOKEN_FILE", str(tmp_path / "token.json"))
    return _load("nas_glowmarkt", "glowmarkt-collector.py")


def _stub_glowmarkt(monkeypatch: pytest.MonkeyPatch, mod: Any, tmp_path: Path,
                    *, write_result: int | None, data: list[Any]) -> None:
    monkeypatch.setattr(mod, "get_token", lambda force_refresh=False: "tok")
    monkeypatch.setattr(mod, "fetch_resources", lambda token: [{"resourceId": mod.RESOURCE_ID}])
    monkeypatch.setattr(mod, "fetch_consumption",
                        lambda *a, **k: {"data": data, "units": "kWh"})
    monkeypatch.setattr(mod, "write_influx", lambda lines: write_result)
    monkeypatch.setattr(mod, "_save_cursor", lambda last: None)
    monkeypatch.setattr(mod, "_append_history", lambda record: None)
    monkeypatch.setattr(mod, "LATEST_FILE", tmp_path / "latest.json")


def test_glowmarkt_not_ok_when_the_influx_write_fails(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    # Catches the shipped defect: a total InfluxDB outage was recorded as ok:True
    # (and main() then exited 0), so the collector reported success while every
    # reading was lost.
    mod = _glowmarkt(monkeypatch, tmp_path)
    _stub_glowmarkt(monkeypatch, mod, tmp_path, write_result=None,
                    data=[[1_700_000_000, 1.5]])
    result = mod.collect_once()
    assert result["ok"] is False
    assert result["influx"]["status"] is None


def test_glowmarkt_ok_when_the_write_lands(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    # The control: a 204 write is success — a "fix" that always fails would be a
    # different defect.
    mod = _glowmarkt(monkeypatch, tmp_path)
    _stub_glowmarkt(monkeypatch, mod, tmp_path, write_result=204,
                    data=[[1_700_000_000, 1.5]])
    result = mod.collect_once()
    assert result["ok"] is True
    assert result["influx"]["status"] == 204


def test_glowmarkt_ok_when_there_is_nothing_to_write(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    # An empty result set attempts no write, so it is not a write failure.
    mod = _glowmarkt(monkeypatch, tmp_path)
    _stub_glowmarkt(monkeypatch, mod, tmp_path, write_result=None, data=[])
    assert mod.collect_once()["ok"] is True


# ── nas_health: the Influx write reports its failure ──────────────────────────


def test_nas_health_influx_write_returns_false_and_names_the_failure(
    monkeypatch: pytest.MonkeyPatch, capsys: Any
) -> None:
    # Catches: a URLError swallowed into a success, so "wrote N series — OK" prints
    # over an outage.
    mod = _load("nas_health", "nas_health_collector.py")
    monkeypatch.setattr(mod, "urllib", _fake_urllib(fail=True))
    assert mod.influx_write(["m f=1 1"]) is False
    assert "InfluxDB write failed" in capsys.readouterr().err


def test_nas_health_influx_write_true_on_204(monkeypatch: pytest.MonkeyPatch) -> None:
    mod = _load("nas_health", "nas_health_collector.py")
    monkeypatch.setattr(mod, "urllib", _fake_urllib(status=204))
    assert mod.influx_write(["m f=1 1"]) is True


# ── mi-scale: the failed write is logged, not swallowed ───────────────────────


def _mi_scale(monkeypatch: pytest.MonkeyPatch) -> Any:
    paho = types.ModuleType("paho")
    mqtt = types.ModuleType("paho.mqtt")
    client = types.ModuleType("paho.mqtt.client")
    client.CallbackAPIVersion = types.SimpleNamespace(VERSION2=2)  # type: ignore[attr-defined]
    client.Client = lambda **k: types.SimpleNamespace()  # type: ignore[attr-defined]
    mqtt.client = client  # type: ignore[attr-defined]
    paho.mqtt = mqtt  # type: ignore[attr-defined]
    monkeypatch.setitem(sys.modules, "paho", paho)
    monkeypatch.setitem(sys.modules, "paho.mqtt", mqtt)
    monkeypatch.setitem(sys.modules, "paho.mqtt.client", client)
    return _load("nas_mi_scale", "mi-scale-subscriber.py")


def test_mi_scale_write_influx_logs_a_failed_write(
    monkeypatch: pytest.MonkeyPatch, caplog: Any
) -> None:
    # Catches: `except Exception: pass` — the write failure used to vanish entirely.
    mod = _mi_scale(monkeypatch)
    monkeypatch.setattr(mod, "urllib", _fake_urllib(fail=True))
    with caplog.at_level(logging.WARNING, logger="nas_mi_scale"):
        mod.write_influx({"mac": "x"}, {"weight_kg": 70.0}, 1)
    assert any("influx write failed" in r.getMessage() for r in caplog.records)


def test_mi_scale_write_influx_warns_on_a_non_204(
    monkeypatch: pytest.MonkeyPatch, caplog: Any
) -> None:
    # Catches: `if r.status != 204: pass` — a rejected write looked like a stored one.
    mod = _mi_scale(monkeypatch)
    monkeypatch.setattr(mod, "urllib", _fake_urllib(status=500))
    with caplog.at_level(logging.WARNING, logger="nas_mi_scale"):
        mod.write_influx({"mac": "x"}, {"weight_kg": 70.0}, 1)
    assert any("HTTP 500" in r.getMessage() for r in caplog.records)


def test_mi_scale_import_has_no_side_effect(monkeypatch: pytest.MonkeyPatch) -> None:
    # The daemon connect loop now lives under main(), so importing the file cannot
    # touch the MQTT broker (or mkdir the NAS path) — that is what makes the cases
    # above loadable at all.
    mod = _mi_scale(monkeypatch)
    assert callable(mod.main)
    assert mod.running is True


# ── air-monitor: an Influx outage propagates; a bad field is skipped ──────────


def test_air_monitor_influx_failure_propagates(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    # Catches: a write failure wrapped into an ok:true printout.  The criterion is
    # that the run cannot report success while the series is missing.
    mod = _load("nas_air", "air-monitor-influx-collector.py")
    monkeypatch.setattr(mod, "OUT_DIR", tmp_path)
    payload = json.dumps({"sensordatavalues": [{"value_type": "SDS_P1", "value": "11"}]}).encode()
    calls = {"n": 0}
    ns = _fake_urllib()

    def _urlopen(*a: Any, **k: Any) -> Any:
        calls["n"] += 1
        if calls["n"] == 1:
            return _Resp(status=200, body=payload)
        raise OSError("influx unreachable")

    ns.request.urlopen = _urlopen
    monkeypatch.setattr(mod, "urllib", ns)
    with pytest.raises(OSError):
        mod.collect_once()


def test_air_monitor_skips_a_non_numeric_field_and_logs_it(caplog: Any) -> None:
    # The one genuinely benign site: a single optional field that will not parse is
    # skipped, and the remaining metrics still post — named at DEBUG so it is not
    # silent (a genuinely benign site is classified, not silenced).
    mod = _load("nas_air2", "air-monitor-influx-collector.py")
    with caplog.at_level(logging.DEBUG, logger="nas_air2"):
        out = mod._parse_metrics({"sensordatavalues": [
            {"value_type": "bad", "value": "n/a"},
            {"value_type": "good", "value": "2"},
        ]})
    assert out == {"good": 2.0}
    assert any("skipping non-numeric" in r.getMessage() for r in caplog.records)


# ── read-myair-otp-imap: an undecodable part is named ─────────────────────────


def test_read_myair_logs_an_undecodable_mime_part(caplog: Any) -> None:
    # Catches: a decode failure swallowed, so "No OTP found" is reported with no
    # clue that a part could not be read.
    mod = _load("nas_myair", "read-myair-otp-imap.py")

    class _Part:
        def get_content_type(self) -> str:
            return "text/plain"

        def get_payload(self, decode: bool = False) -> bytes:
            raise ValueError("bad base64")

    class _Msg:
        def is_multipart(self) -> bool:
            return True

        def walk(self) -> list[Any]:
            return [_Part()]

    with caplog.at_level(logging.DEBUG, logger="nas_myair"):
        assert mod._iter_message_text(_Msg()) == ""
    assert any("undecodable MIME part" in r.getMessage() for r in caplog.records)


def test_read_myair_extracts_the_otp() -> None:
    mod = _load("nas_myair2", "read-myair-otp-imap.py")
    assert mod._extract_otp("Your one-time code is 482913") == "482913"
    assert mod._extract_otp("no code here") is None


# ── acceptance: no bare `except: pass` in the five fixed files ────────────────

_FIXED = [
    "mi-scale-subscriber.py",
    "glowmarkt-collector.py",
    "nas_health_collector.py",
    "air-monitor-influx-collector.py",
    "read-myair-otp-imap.py",
]


@pytest.mark.parametrize("filename", _FIXED)
def test_no_bare_except_pass(filename: str) -> None:
    # The card's acceptance: "No bare `except: pass`".  Every fallback path now logs
    # (or is gone), so a reintroduced silent swallow fails here.
    source = (NAS / filename).read_text()
    bare = re.findall(r"except[^\n]*:\s*\n\s*pass\b", source)
    assert bare == [], f"{filename} still swallows: {bare}"
