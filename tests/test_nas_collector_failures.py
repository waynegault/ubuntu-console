"""NAS collector failure paths must be visible (card b296c75c) and the shared
butler primitives must behave (card 974f99ff).

These are PYTHON, so the shell swallow gate never saw them.  The criterion for each
case is the documented behaviour (the card / the module docstring), not the current
output.

The nas scripts are hyphenated (``nas/butler/scripts/*.py``) and import the shared
``lib.butler_common``, so the test mirrors the run-time sys.path (the script dir) and
loads modules by path.  mi-scale needs a fake paho because the real package is a
NAS-only dep.
"""

from __future__ import annotations

import importlib
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


def _ensure_path() -> None:
    if str(NAS) not in sys.path:
        sys.path.insert(0, str(NAS))


def _butler_common() -> Any:
    _ensure_path()
    return importlib.import_module("lib.butler_common")


def _load(module_name: str, filename: str) -> Any:
    _ensure_path()
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


class _URLError(OSError):
    """Stand-in for urllib.error.URLError."""


class _HTTPError(Exception):
    """Stand-in for urllib.error.HTTPError (carries .code and .read())."""

    def __init__(self, code: int, body: bytes = b"") -> None:
        super().__init__(code)
        self.code = code
        self._body = body

    def read(self) -> bytes:
        return self._body


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


class _Request:
    def __init__(self, *a: Any, **k: Any) -> None:
        self.headers: dict[str, str] = {}
        self.data = k.get("data")
        self.method = k.get("method")

    def add_header(self, name: str, value: str) -> None:
        self.headers[name] = value


def _fake_urllib(*, fail: bool = False, status: int = 204, body: bytes = b"",
                 http_error: tuple[int, bytes] | None = None,
                 requests: list[_Request] | None = None) -> Any:
    """A module-local replacement for the ``urllib`` package name."""
    ns = types.SimpleNamespace()

    def _urlopen(req: Any, *a: Any, **k: Any) -> Any:
        if requests is not None and isinstance(req, _Request):
            requests.append(req)
        if http_error is not None:
            raise _HTTPError(http_error[0], http_error[1])
        if fail:
            raise _URLError("influx unreachable")
        return _Resp(status, body)

    ns.request = types.SimpleNamespace(Request=_Request, urlopen=_urlopen)
    ns.error = types.SimpleNamespace(URLError=_URLError, HTTPError=_HTTPError)
    return ns


# ── lib/butler_common: one extractor, one Graph client, one Influx POST ───────


def test_lib_extract_otp() -> None:
    bc = _butler_common()
    assert bc.extract_otp("Your code is 482913") == "482913"
    assert bc.extract_otp("12345") is None
    assert bc.extract_otp("no digits") is None


def test_lib_post_line_protocol_sends_octet_stream(monkeypatch: pytest.MonkeyPatch) -> None:
    # Catches: a writer that drops the line protocol's Content-Type, which InfluxDB
    # rejects as an unparseable body.
    bc = _butler_common()
    seen: list[_Request] = []
    monkeypatch.setattr(bc, "urllib", _fake_urllib(status=204, requests=seen))
    assert bc.post_line_protocol("http://x/write?db=d", "m f=1 1") == 204
    assert seen and seen[0].headers["Content-Type"] == "application/octet-stream"
    assert seen[0].data == b"m f=1 1"


def test_lib_graph_get_raises_on_http_error(monkeypatch: pytest.MonkeyPatch) -> None:
    # Catches: a Graph client that turns an HTTP error into a None/empty read, so a
    # failed fetch looks like an empty mailbox.
    bc = _butler_common()
    monkeypatch.setattr(bc, "urllib", _fake_urllib(http_error=(401, b'{"error":"unauthorized"}')))
    with pytest.raises(RuntimeError, match="Graph GET .* HTTP 401"):
        bc.graph_get("https://graph.microsoft.com/v1.0/me/messages", "tok")


# ── glowmarkt: ok must come from the write, not a hardcoded True ──────────────


def _glowmarkt(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> Any:
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
    mod = _glowmarkt(monkeypatch, tmp_path)
    _stub_glowmarkt(monkeypatch, mod, tmp_path, write_result=204,
                    data=[[1_700_000_000, 1.5]])
    result = mod.collect_once()
    assert result["ok"] is True
    assert result["influx"]["status"] == 204


def test_glowmarkt_ok_when_there_is_nothing_to_write(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    mod = _glowmarkt(monkeypatch, tmp_path)
    _stub_glowmarkt(monkeypatch, mod, tmp_path, write_result=None, data=[])
    assert mod.collect_once()["ok"] is True


# ── nas_health: the Influx write reports its failure ──────────────────────────


def test_nas_health_influx_write_returns_false_and_names_the_failure(
    monkeypatch: pytest.MonkeyPatch, capsys: Any
) -> None:
    mod = _load("nas_health", "nas_health_collector.py")
    bc = _butler_common()
    ns = _fake_urllib(fail=True)
    monkeypatch.setattr(bc, "urllib", ns)
    monkeypatch.setattr(mod, "urllib", ns)
    assert mod.influx_write(["m f=1 1"]) is False
    assert "InfluxDB write failed" in capsys.readouterr().err


def test_nas_health_influx_write_true_on_204(monkeypatch: pytest.MonkeyPatch) -> None:
    mod = _load("nas_health", "nas_health_collector.py")
    monkeypatch.setattr(_butler_common(), "urllib", _fake_urllib(status=204))
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
    monkeypatch.setattr(_butler_common(), "urllib", _fake_urllib(fail=True))
    with caplog.at_level(logging.WARNING, logger="nas_mi_scale"):
        mod.write_influx({"mac": "x"}, {"weight_kg": 70.0}, 1)
    assert any("influx write failed" in r.getMessage() for r in caplog.records)


def test_mi_scale_write_influx_warns_on_a_non_204(
    monkeypatch: pytest.MonkeyPatch, caplog: Any
) -> None:
    # Catches: `if r.status != 204: pass` — a rejected write looked like a stored one.
    mod = _mi_scale(monkeypatch)
    monkeypatch.setattr(_butler_common(), "urllib", _fake_urllib(status=500))
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
    monkeypatch.setattr(mod, "urllib", _fake_urllib(status=200, body=payload))
    monkeypatch.setattr(_butler_common(), "urllib", _fake_urllib(fail=True))
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


def test_read_myair_uses_the_shared_extractor() -> None:
    # The IMAP reader now imports extract_otp from lib.butler_common (one extractor),
    # so this asserts the shared symbol, not a private copy.
    mod = _load("nas_myair2", "read-myair-otp-imap.py")
    assert mod.extract_otp is _butler_common().extract_otp
    assert mod.extract_otp("Your one-time code is 482913") == "482913"
    assert mod.extract_otp("no code here") is None


# ── smoke: every migrated importer still loads (lib.butler_common resolves) ───

_IMPORT_SAFE = [
    ("nas_smoke_imap", "read-myair-otp-imap.py"),
    ("nas_smoke_graph", "nas-graph-otp.py"),
    ("nas_smoke_unified", "nas-cpap-unified.py"),
    ("nas_smoke_health", "nas_health_collector.py"),
    ("nas_smoke_air", "air-monitor-influx-collector.py"),
    ("nas_smoke_scale2", "mi-scale-2-collector.py"),
    ("nas_smoke_oauth", "read-myair-otp-graph-oauth.py"),
]


@pytest.mark.parametrize("module_name,filename", _IMPORT_SAFE)
def test_migrated_module_imports(module_name: str, filename: str) -> None:
    # Catches: `from lib.butler_common import ...` failing to resolve once the
    # script's own directory is no longer sys.path[0].  it500 and the two
    # path-mkdir-at-import collectors are covered by the sandboxed case below.
    assert _load(module_name, filename) is not None


def test_migrated_modules_with_paths_sandboxed(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    monkeypatch.setenv("GLOWMARKT_DATA_DIR", str(tmp_path))
    monkeypatch.setenv("GLOWMARKT_TOKEN_FILE", str(tmp_path / "t.json"))
    monkeypatch.setenv("CPAP_DATA_DIR", str(tmp_path / "cpap"))
    assert _load("nas_smoke_glow", "glowmarkt-collector.py") is not None
    assert _load("nas_smoke_cpap", "cpap-myair-collector.py") is not None


# ── acceptance: no bare `except: pass` in the five card-2 files ───────────────

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


# ── acceptance: the collectors import the ONE shared lib ─────────────────────

_MIGRATED = [
    "read-myair-otp-imap.py",
    "nas-graph-otp.py",
    "nas-cpap-unified.py",
    "glowmarkt-collector.py",
    "nas_health_collector.py",
    "mi-scale-subscriber.py",
    "mi-scale-2-collector.py",
    "air-monitor-influx-collector.py",
    "it500-influx-collector.py",
    "cpap-myair-collector.py",
]


@pytest.mark.parametrize("filename", _MIGRATED)
def test_collector_imports_the_shared_lib(filename: str) -> None:
    # The card's acceptance: one OTP extractor / Graph client / Influx writer,
    # imported by the collectors.  Catches a copy that drifts back to a private
    # implementation (the lib is the deliberate mirroring exception).
    source = (NAS / filename).read_text()
    assert re.search(r"^from lib\.butler_common import ", source, flags=re.M), \
        f"{filename} does not import lib.butler_common"
