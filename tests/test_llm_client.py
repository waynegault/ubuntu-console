"""Tests for tools/llm_client — the shared transport every lane tool now uses.

Each case names the wrong outcome it catches.  The client's job is to make one
malformed response produce one typed error, and to keep a prompt out of an error
line, so the assertions are about those two things rather than about bytes on the
wire.
"""

from __future__ import annotations

import io
import json
import threading
from unittest import mock

import pytest

from tools import llm_client


class _FakeResponse(io.BytesIO):
    """A urlopen() result: iterable by line for SSE, readable for a body."""

    def __enter__(self):
        return self

    def __exit__(self, *_exc):
        return False


def _sse(*events: str) -> _FakeResponse:
    return _FakeResponse("".join(f"data: {event}\n\n" for event in events).encode())


def test_usage_rejects_a_boolean_token_count():
    """Catches `True` being counted as one token, which yields a throughput figure from nothing."""
    with pytest.raises(llm_client.LLMClientError, match="prompt_tokens"):
        llm_client.extract_usage({"usage": {"prompt_tokens": True, "completion_tokens": 5}})


def test_usage_rejects_a_missing_count():
    """Catches a partial usage record being read as zero completion tokens."""
    with pytest.raises(llm_client.LLMClientError, match="completion_tokens"):
        llm_client.extract_usage({"usage": {"prompt_tokens": 3}})


def test_an_error_event_is_a_server_error_and_does_not_echo_the_prompt():
    """Catches a server failure reported as a transport failure, and a prompt leaking into the message."""
    prompt = "SECRET-PROMPT-TEXT"
    response = _sse(json.dumps({"error": {"message": prompt}}))
    with mock.patch.object(llm_client, "_open", return_value=response):
        with pytest.raises(llm_client.LLMServerError) as exc_info:
            list(llm_client.stream_url("http://127.0.0.1:1/v1/chat/completions", {"messages": []}, timeout=1))
    assert prompt not in str(exc_info.value)


def test_a_malformed_sse_event_is_not_silently_skipped():
    """Catches a broken stream being read as an empty-but-successful reply."""
    response = _sse("{not json")
    with mock.patch.object(llm_client, "_open", return_value=response):
        with pytest.raises(llm_client.LLMClientError, match="malformed SSE"):
            list(llm_client.stream_url("http://127.0.0.1:1/v1/chat/completions", {}, timeout=1))


def test_the_stream_ends_on_done_and_carries_usage():
    """Catches [DONE] being ignored, and a usage-only final event being dropped."""
    response = _sse(
        json.dumps({"choices": [{"delta": {"content": "hi"}}]}),
        json.dumps({"choices": [], "usage": {"prompt_tokens": 2, "completion_tokens": 1}}),
        "[DONE]",
        json.dumps({"choices": [{"delta": {"content": "after-done"}}]}),
    )
    with mock.patch.object(llm_client, "_open", return_value=response):
        chunks = list(llm_client.stream_url("http://127.0.0.1:1/v1/chat/completions", {}, timeout=1))
    assert [chunk.content for chunk in chunks] == ["hi", "", ""]
    assert chunks[-1].done is True
    assert chunks[1].usage == {"prompt_tokens": 2, "completion_tokens": 1}
    assert all("after-done" != chunk.content for chunk in chunks)


def test_get_models_refuses_an_empty_list():
    """Catches a model-less endpoint being read as "use whatever", which files a score under no name."""
    response = _FakeResponse(b'{"data": []}')
    with mock.patch.object(llm_client, "_open", return_value=response):
        with pytest.raises(llm_client.LLMClientError, match="listed no models"):
            llm_client.get_models("http://127.0.0.1:1/v1", timeout=1)


def test_an_http_error_carries_its_status():
    """Catches a 404 being reported as a connection failure, which sends the reader to the wrong fault.

    A real loopback server, not a patched urlopen: the mapping under test lives in
    the code that calls urlopen, so replacing urlopen would test the double.
    """
    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

    class _NotFound(BaseHTTPRequestHandler):
        def do_GET(self):
            self.send_response(404)
            self.end_headers()

        def log_message(self, _format, *_args):
            return

    server = ThreadingHTTPServer(("127.0.0.1", 0), _NotFound)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        with pytest.raises(llm_client.LLMClientError) as exc_info:
            llm_client.get_models(f"http://127.0.0.1:{server.server_port}/v1", timeout=5)
        assert exc_info.value.status == 404
    finally:
        server.shutdown()
        thread.join(timeout=3)
        server.server_close()
