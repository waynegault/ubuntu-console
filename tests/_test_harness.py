"""Unified test harness: dynamic script loading, ephemeral HTTP servers, and HTTP stubs."""

from __future__ import annotations

import contextlib
import importlib.util
import shutil
import subprocess
import sys
import threading
from collections.abc import Generator
from http.server import BaseHTTPRequestHandler, HTTPServer, ThreadingHTTPServer
from pathlib import Path
from typing import Any

from _paths import REPO_ROOT


# ── Interpreter selection ────────────────────────────────────────────────────


def pytest_interpreter() -> str:
    """An interpreter that can import pytest AND its dependencies.

    Candidates are ASKED, not assumed: sys.executable first (the suite's own), then
    the PATH names.  A setup-python job can leave `sys.executable` pointing at an
    installation whose pytest is missing pluggy, while the job's own `python` — the
    one that runs this suite — has it (measured 2026-11-11: ModuleNotFoundError:
    pluggy from sys.executable, green from `python`).
    """
    candidates: list[str] = [sys.executable]
    for name in ("python3", "python"):
        found = shutil.which(name)
        if found and found not in candidates:
            candidates.append(found)
    for candidate in candidates:
        probe = subprocess.run(
            [candidate, "-c", "import pytest, pluggy"],
            capture_output=True,
            timeout=30,
            check=False,
        )
        if probe.returncode == 0:
            return candidate
    raise RuntimeError("no interpreter can import pytest and pluggy")


# ── Dynamic Script Loader ─────────────────────────────────────────────────────


def load_script(path: str | Path, module_name: str | None = None) -> Any:
    """Import a script by path (supporting hyphenated filenames) into sys.modules.

    Parameters:
    - path: Path to the .py script (absolute or relative to REPO_ROOT).
    - module_name: Optional name for sys.modules. Defaults to path.stem with '-'
      replaced by '_'.

    Ensures registration in sys.modules prior to execution (critical for dataclasses
    under Python 3.14). If execution fails, the sys.modules entry is cleaned up.
    """
    target = Path(path)
    if not target.is_absolute():
        target = Path(REPO_ROOT) / target
    if module_name is None:
        module_name = target.stem.replace("-", "_")

    spec = importlib.util.spec_from_file_location(module_name, target)
    if spec is None or spec.loader is None:
        raise ImportError(f"Cannot load script from {target}")

    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    try:
        spec.loader.exec_module(module)
    except BaseException:
        sys.modules.pop(spec.name, None)
        raise
    return module


def load_probe(module_name: str, script_filename: str) -> Any:
    """Backward-compatible loader for scripts in REPO_ROOT/scripts."""
    return load_script(Path(REPO_ROOT) / "scripts" / script_filename, module_name)


# ── Ephemeral HTTP Server Infrastructure ─────────────────────────────────────


@contextlib.contextmanager
def ephemeral_http_server(
    handler_cls: type[BaseHTTPRequestHandler],
    server_cls: type[HTTPServer] = ThreadingHTTPServer,
    host: str = "127.0.0.1",
) -> Generator[tuple[HTTPServer, str], None, None]:
    """Start an ephemeral HTTP server on loopback, yielding (server, base_url).

    Guarantees clean shutdown, thread join, and socket closure upon exit.
    """
    server = server_cls((host, 0), handler_cls)
    port = server.server_address[1]
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield server, f"http://{host}:{port}"
    finally:
        server.shutdown()
        thread.join(timeout=3)
        server.server_close()


class FakeHTTPServer:
    """Captures the handler class passed to HTTPServer without listening.

    Used when testing CLI/server entry points that block in serve_forever.
    """

    captured: dict[str, Any] = {}

    def __init__(self, addr: tuple[str, int], handler: Any):
        FakeHTTPServer.captured["handler"] = handler
        self.server_address = (addr[0], addr[1] or 1)

    def serve_forever(self) -> None:
        pass

    def shutdown(self) -> None:
        pass


class SilentHTTPHandler(BaseHTTPRequestHandler):
    """BaseHTTPRequestHandler subclass that suppresses stderr logging in tests."""

    def log_message(self, format: str, *args: Any) -> None:
        return
