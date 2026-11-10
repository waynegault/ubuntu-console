"""Adversarial stress testing suite for HermeticHTTPServer under high socket churn and client disconnects.

Guarantees validated:
- Zero socket leaks under pytest -W error
- Clean file descriptor release across rapid sequential requests (100+)
- Concurrent multi-threaded request handling without corruption or leak
- Graceful recovery from abrupt client resets (TCP RST) during upload and download
- Reliable server restart loops and fixed-port rebinding without EADDRINUSE
- Strict Connection: close enforcement despite keep-alive request headers
- Resilient teardown when idle client connections exist
- Robustness against malformed HTTP protocol payloads
"""

from __future__ import annotations

import contextlib
import gc
import io
import json
import os
import socket
import struct
import sys
import threading
import time
import urllib.error
import urllib.request
from typing import Generator

import pytest

from tests.e2e.helpers.assertions import assert_no_resource_warnings
from tests.e2e.helpers.mock_server import HermeticHTTPServer

pytestmark = pytest.mark.e2e


def _get_open_fd_count() -> int:
    """Return count of open file descriptors in current process after GC."""
    gc.collect()
    return len(os.listdir("/proc/self/fd"))


@contextlib.contextmanager
def _suppress_stderr() -> Generator[io.StringIO, None, None]:
    """Temporarily capture stderr to suppress expected server-side disconnect tracebacks."""
    buf = io.StringIO()
    old_stderr = sys.stderr
    sys.stderr = buf
    try:
        yield buf
    finally:
        sys.stderr = old_stderr


# --- Test Cases ---


def test_server_sequential_churn_120_requests() -> None:
    """Empirically challenge server with 120 rapid sequential requests under zero warning enforcement."""
    initial_fds = _get_open_fd_count()

    server = HermeticHTTPServer()
    server.start()
    base_url = server.url

    with assert_no_resource_warnings():
        for i in range(120):
            if i % 3 == 0:
                # GET /health
                req = urllib.request.Request(f"{base_url}/health")
                with urllib.request.urlopen(req, timeout=5) as resp:
                    assert resp.status == 200
                    data = json.loads(resp.read().decode("utf-8"))
                    assert data["status"] == "ok"
            elif i % 3 == 1:
                # GET /v1/models
                req = urllib.request.Request(f"{base_url}/v1/models")
                with urllib.request.urlopen(req, timeout=5) as resp:
                    assert resp.status == 200
                    data = json.loads(resp.read().decode("utf-8"))
                    assert len(data["data"]) >= 1
            else:
                # POST /v1/chat/completions
                body = json.dumps({"model": "mock-qwen-30b", "index": i}).encode("utf-8")
                req = urllib.request.Request(
                    f"{base_url}/v1/chat/completions",
                    data=body,
                    headers={"Content-Type": "application/json"},
                )
                with urllib.request.urlopen(req, timeout=5) as resp:
                    assert resp.status == 200
                    data = json.loads(resp.read().decode("utf-8"))
                    assert "choices" in data

    assert len(server.requests) == 120

    server.stop()
    final_fds = _get_open_fd_count()
    assert final_fds == initial_fds, f"FD leak detected: started with {initial_fds}, ended with {final_fds}"


def test_server_concurrent_churn_100_requests() -> None:
    """Empirically challenge server with 100 concurrent requests across 20 parallel threads."""
    initial_fds = _get_open_fd_count()

    server = HermeticHTTPServer()
    server.start()
    base_url = server.url

    errors: list[Exception] = []

    def _worker(worker_id: int) -> None:
        try:
            for j in range(5):
                path = "/health" if j % 2 == 0 else "/v1/models"
                req = urllib.request.Request(f"{base_url}{path}")
                with urllib.request.urlopen(req, timeout=5) as resp:
                    assert resp.status == 200
                    _ = resp.read()
        except Exception as exc:
            errors.append(exc)

    with assert_no_resource_warnings():
        threads = [threading.Thread(target=_worker, args=(i,)) for i in range(20)]
        for t in threads:
            t.start()
        for t in threads:
            t.join(timeout=10.0)

    assert not errors, f"Concurrent workers encountered errors: {errors}"
    assert len(server.requests) == 100

    server.stop()
    final_fds = _get_open_fd_count()
    assert final_fds == initial_fds, f"FD leak detected: started with {initial_fds}, ended with {final_fds}"


def test_server_abrupt_client_disconnect_during_payload_upload() -> None:
    """Empirically test client abruptly disconnecting (TCP RST) midway through request payload upload."""
    initial_fds = _get_open_fd_count()

    server = HermeticHTTPServer()
    server.start()
    port = server.port

    with assert_no_resource_warnings():
        with _suppress_stderr():
            for _ in range(20):
                s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
                s.connect(("127.0.0.1", port))
                headers = (
                    f"POST /v1/chat/completions HTTP/1.1\r\n"
                    f"Host: 127.0.0.1:{port}\r\n"
                    f"Content-Length: 50000\r\n"
                    f"Content-Type: application/json\r\n\r\n"
                ).encode("utf-8")
                # Send headers and partial body
                s.sendall(headers + b'{"partial": true')
                # Enforce immediate TCP RST on close
                s.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
                s.close()

        # Allow worker threads brief window to exit
        time.sleep(0.1)

        # Server should still be responsive to legitimate requests
        req = urllib.request.Request(f"{server.url}/health")
        with urllib.request.urlopen(req, timeout=5) as resp:
            assert resp.status == 200

    server.stop()
    final_fds = _get_open_fd_count()
    assert final_fds == initial_fds, f"FD leak detected: started with {initial_fds}, ended with {final_fds}"


def test_server_abrupt_client_disconnect_during_response_download() -> None:
    """Empirically test client abruptly disconnecting (TCP RST) while server is writing large response."""
    initial_fds = _get_open_fd_count()

    server = HermeticHTTPServer()
    # Add large payload route (500KB)
    big_payload = b"X" * 500000
    server.add_route("/large_stream", lambda _req: (200, {"Content-Type": "application/octet-stream"}, big_payload))
    server.start()
    port = server.port

    with assert_no_resource_warnings():
        with _suppress_stderr():
            for _ in range(20):
                s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
                s.connect(("127.0.0.1", port))
                s.sendall(f"GET /large_stream HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\n\r\n".encode("utf-8"))
                # Read only first 64 bytes of response, then reset socket
                _ = s.recv(64)
                s.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
                s.close()

        time.sleep(0.1)

        # Verify server remains healthy
        req = urllib.request.Request(f"{server.url}/health")
        with urllib.request.urlopen(req, timeout=5) as resp:
            assert resp.status == 200

    server.stop()
    final_fds = _get_open_fd_count()
    assert final_fds == initial_fds, f"FD leak detected: started with {initial_fds}, ended with {final_fds}"


def test_server_connect_immediate_rst_churn() -> None:
    """Empirically test connection established and immediately reset without transmitting data."""
    initial_fds = _get_open_fd_count()

    server = HermeticHTTPServer()
    server.start()
    port = server.port

    with assert_no_resource_warnings():
        with _suppress_stderr():
            for _ in range(40):
                s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
                s.connect(("127.0.0.1", port))
                s.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
                s.close()

        time.sleep(0.1)

        # Verify normal request succeeds
        req = urllib.request.Request(f"{server.url}/health")
        with urllib.request.urlopen(req, timeout=5) as resp:
            assert resp.status == 200

    server.stop()
    final_fds = _get_open_fd_count()
    assert final_fds == initial_fds, f"FD leak detected: started with {initial_fds}, ended with {final_fds}"


def test_server_rapid_restart_lifecycle_loops() -> None:
    """Empirically challenge server with 25 rapid start-stop cycles to verify thread & socket cleanup."""
    initial_fds = _get_open_fd_count()

    with assert_no_resource_warnings():
        for i in range(25):
            server = HermeticHTTPServer()
            server.start()
            assert server._is_running is True
            assert server._thread is not None and server._thread.is_alive()

            req = urllib.request.Request(f"{server.url}/health")
            with urllib.request.urlopen(req, timeout=5) as resp:
                assert resp.status == 200

            server.stop()
            assert server._is_running is False
            assert server._server is None
            assert server._thread is None

    final_fds = _get_open_fd_count()
    assert final_fds == initial_fds, f"FD leak across restart cycles: initial {initial_fds}, final {final_fds}"


def test_server_fixed_port_rebinding_cycles() -> None:
    """Empirically test that HermeticHTTPServer can bind, release, and rebind to the same fixed port."""
    initial_fds = _get_open_fd_count()
    fixed_port = 19125

    with assert_no_resource_warnings():
        for _ in range(10):
            server = HermeticHTTPServer(port=fixed_port)
            server.start()
            assert server.port == fixed_port

            req = urllib.request.Request(f"http://127.0.0.1:{fixed_port}/health")
            with urllib.request.urlopen(req, timeout=5) as resp:
                assert resp.status == 200

            server.stop()

    final_fds = _get_open_fd_count()
    assert final_fds == initial_fds, f"FD leak across fixed port rebinds: initial {initial_fds}, final {final_fds}"


def test_server_connection_close_enforced_against_keepalive() -> None:
    """Empirically verify server forces Connection: close even when client sends keep-alive."""
    server = HermeticHTTPServer()
    server.start()
    port = server.port

    try:
        with assert_no_resource_warnings():
            s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            s.settimeout(3.0)
            s.connect(("127.0.0.1", port))
            s.sendall(
                f"GET /health HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nConnection: keep-alive\r\n\r\n".encode("utf-8")
            )

            response_data = b""
            while True:
                chunk = s.recv(1024)
                if not chunk:
                    break
                response_data += chunk

            s.close()

            response_text = response_data.decode("utf-8")
            assert "HTTP/1.1 200 OK" in response_text
            assert "Connection: close" in response_text
            assert '{"status": "ok"' in response_text
    finally:
        server.stop()


def test_server_idle_client_teardown_resilience() -> None:
    """Empirically verify server teardown does not hang when an idle client connection is open."""
    server = HermeticHTTPServer()
    server.start()
    port = server.port

    client_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    client_sock.connect(("127.0.0.1", port))
    # Client does not send anything (idle connection)

    t0 = time.time()
    # Server stop should complete cleanly within timeout without blocking
    server.stop()
    teardown_duration = time.time() - t0

    assert teardown_duration < 3.5, f"Server teardown hung for {teardown_duration:.2f}s"
    assert server._is_running is False
    assert server._server is None

    # Close client socket
    client_sock.close()


def test_server_malformed_protocol_resilience() -> None:
    """Empirically test server resilience against malformed HTTP inputs without hanging or leaking."""
    initial_fds = _get_open_fd_count()

    server = HermeticHTTPServer()
    server.start()
    port = server.port

    def _send_raw(payload: bytes) -> bytes:
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(2.0)
        s.connect(("127.0.0.1", port))
        s.sendall(payload)
        try:
            resp = s.recv(4096)
        except Exception:
            resp = b""
        finally:
            s.close()
        return resp

    with assert_no_resource_warnings():
        with _suppress_stderr():
            # 1. Unsupported HTTP method
            resp = _send_raw(b"INVALID_METHOD /health HTTP/1.1\r\nHost: localhost\r\n\r\n")
            assert b"501" in resp

            # 2. HTTP 0.9 simple request
            resp = _send_raw(b"GET /health\r\n")
            assert b"status" in resp

            # 3. Raw binary garbage
            _ = _send_raw(b"\x00\xff\x00\xff\x10\x20\r\n\r\n")

            # 4. Non-numeric Content-Length
            _ = _send_raw(
                f"POST /v1/chat/completions HTTP/1.1\r\n"
                f"Host: 127.0.0.1:{port}\r\n"
                f"Content-Length: not-a-number\r\n\r\n".encode("utf-8")
            )

        # Confirm server remains functional
        req = urllib.request.Request(f"{server.url}/health")
        with urllib.request.urlopen(req, timeout=5) as valid_resp:
            assert valid_resp.status == 200

    server.stop()
    final_fds = _get_open_fd_count()
    assert final_fds == initial_fds, f"FD leak detected: started with {initial_fds}, ended with {final_fds}"
