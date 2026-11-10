"""Hermetic self-closing loopback HTTP server fixture.

Guarantees:
- Zero socket leaks under pytest -W error
- Explicit server.shutdown(), server.server_close(), thread.join()
- Ephemeral port binding (127.0.0.1:0)
- Connection: close enforcement
- Request recording and customizable route handlers
"""

from __future__ import annotations

import json
import threading
import time
from dataclasses import dataclass, field
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any, Callable


@dataclass
class RecordedRequest:
    """Captured incoming HTTP request metadata."""

    method: str
    path: str
    headers: dict[str, str]
    body: bytes
    timestamp: float = field(default_factory=time.time)

    def json(self) -> Any:
        return json.loads(self.body.decode("utf-8"))


class HermeticHTTPServer:
    """Ephemeral HTTP test server with guaranteed resource cleanup."""

    def __init__(self, host: str = "127.0.0.1", port: int = 0) -> None:
        self.host = host
        self.requested_port = port
        self.routes: dict[tuple[str, str], Callable[[RecordedRequest], tuple[int, dict[str, str], bytes]]] = {}
        self.requests: list[RecordedRequest] = []
        self._server: ThreadingHTTPServer | None = None
        self._thread: threading.Thread | None = None
        self._is_running = False

        # Register default LLM & health endpoints
        self._register_default_routes()

    def _register_default_routes(self) -> None:
        """Register default endpoints for LLM service compatibility."""
        # /health
        self.add_json_route("/health", {"status": "ok", "service": "hermetic-mock"})
        self.add_json_route("/v1/health", {"status": "ok", "service": "hermetic-mock"})

        # /v1/models and /models
        models_payload = {
            "object": "list",
            "data": [
                {
                    "id": "mock-qwen-30b",
                    "object": "model",
                    "created": 1700000000,
                    "owned_by": "tactical-console",
                },
                {
                    "id": "mock-minicpm-1b",
                    "object": "model",
                    "created": 1700000000,
                    "owned_by": "tactical-console",
                },
            ],
        }
        self.add_json_route("/v1/models", models_payload)
        self.add_json_route("/models", models_payload)

        # /v1/chat/completions and /chat/completions
        chat_payload = {
            "id": "chatcmpl-mock-123",
            "object": "chat.completion",
            "created": 1700000000,
            "model": "mock-qwen-30b",
            "choices": [
                {
                    "index": 0,
                    "message": {
                        "role": "assistant",
                        "content": "Hermetic mock response for E2E testing.",
                    },
                    "finish_reason": "stop",
                }
            ],
            "usage": {
                "prompt_tokens": 12,
                "completion_tokens": 8,
                "total_tokens": 20,
            },
        }
        self.add_json_route("/v1/chat/completions", chat_payload, methods=["POST"])
        self.add_json_route("/chat/completions", chat_payload, methods=["POST"])

    def add_route(
        self,
        path: str,
        handler: Callable[[RecordedRequest], tuple[int, dict[str, str], bytes]],
        methods: list[str] | None = None,
    ) -> HermeticHTTPServer:
        """Add custom route handler."""
        if methods is None:
            methods = ["GET"]
        for m in methods:
            self.routes[(m.upper(), path)] = handler
        return self

    def add_json_route(
        self,
        path: str,
        data: Any,
        status: int = 200,
        methods: list[str] | None = None,
    ) -> HermeticHTTPServer:
        """Helper to register a JSON response route."""
        body = json.dumps(data).encode("utf-8")
        headers = {
            "Content-Type": "application/json; charset=utf-8",
            "Content-Length": str(len(body)),
        }

        def handler(_req: RecordedRequest) -> tuple[int, dict[str, str], bytes]:
            return status, headers, body

        return self.add_route(path, handler, methods=methods)

    def add_error_route(
        self,
        path: str,
        status: int = 500,
        message: str = "Internal Server Error",
        methods: list[str] | None = None,
    ) -> HermeticHTTPServer:
        """Helper to register an error response route."""
        if methods is None:
            methods = ["GET", "POST", "PUT", "DELETE"]
        return self.add_json_route(
            path,
            {"error": {"code": status, "message": message}},
            status=status,
            methods=methods,
        )

    @property
    def is_running(self) -> bool:
        return self._is_running

    @property
    def port(self) -> int:
        if self._server is None:
            raise RuntimeError("Server is not running")
        return self._server.server_port

    @property
    def url(self) -> str:
        return f"http://{self.host}:{self.port}"

    def start(self) -> HermeticHTTPServer:
        """Start the HTTP server on a background daemon thread."""
        if self._is_running:
            return self

        outer = self

        class _Handler(BaseHTTPRequestHandler):
            server_version = "HermeticMock/1.0"
            protocol_version = "HTTP/1.1"

            def log_message(self, format: str, *args: Any) -> None:
                # Suppress noisy standard server logging
                return

            def _handle_request(self) -> None:
                content_len = int(self.headers.get("Content-Length", 0))
                body = self.rfile.read(content_len) if content_len > 0 else b""

                req = RecordedRequest(
                    method=self.command,
                    path=self.path.split("?")[0],
                    headers=dict(self.headers),
                    body=body,
                )
                outer.requests.append(req)

                route_key = (req.method, req.path)
                if route_key in outer.routes:
                    status, headers, resp_body = outer.routes[route_key](req)
                else:
                    status = 404
                    resp_body = json.dumps({"error": f"Path not found: {req.path}"}).encode("utf-8")
                    headers = {
                        "Content-Type": "application/json",
                        "Content-Length": str(len(resp_body)),
                    }

                # Always enforce Connection: close to eliminate dangling socket leaks
                headers["Connection"] = "close"

                self.send_response(status)
                for k, v in headers.items():
                    self.send_header(k, v)
                self.end_headers()
                self.wfile.write(resp_body)
                self.close_connection = True

            def do_GET(self) -> None:
                self._handle_request()

            def do_POST(self) -> None:
                self._handle_request()

            def do_PUT(self) -> None:
                self._handle_request()

            def do_DELETE(self) -> None:
                self._handle_request()

        ThreadingHTTPServer.allow_reuse_address = True
        self._server = ThreadingHTTPServer((self.host, self.requested_port), _Handler)
        self._thread = threading.Thread(target=self._server.serve_forever, daemon=True)
        self._thread.start()
        self._is_running = True
        return self

    def stop(self) -> None:
        """Guaranteed teardown sequence: shutdown, close socket, join thread."""
        if not self._is_running:
            return

        self._is_running = False

        if self._server is not None:
            self._server.shutdown()
            self._server.server_close()
            self._server = None

        if self._thread is not None:
            self._thread.join(timeout=3.0)
            self._thread = None

    def __enter__(self) -> HermeticHTTPServer:
        return self.start()

    def __exit__(self, exc_type: Any, exc_val: Any, exc_tb: Any) -> None:
        self.stop()
