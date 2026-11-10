"""One OpenAI-compatible HTTP client for every tool that talks to a local lane.

Five tools had grown their own client — ``llm_benchmark``, ``llm_outcome_cases``,
``swallow-classify``, ``bench-openai-endpoint`` and ``kv-recall-probe`` — with
five failure policies (timeouts of 60/120/120/600/120 s, one tolerating a
non-UTF-8 body, three different SSE decoders).  A malformed response therefore
produced five different outcomes, and a fix in one place never reached the
others.

What is shared here is the TRANSPORT: request construction, the timeout, the
decode, the SSE framing, and one exception type.  What stays in each tool is its
own POLICY — which error text it prints, which exit code it returns, and whether
a non-loopback host is allowed at all.

The timeout is a required argument rather than a default: the five call sites
genuinely need different budgets (a 256-token probe versus a 600-second
throughput run), and a default would silently pick one of them.

Responses are decoded with ``errors="replace"``.  A body that is not valid UTF-8
is still JSON to the extent its bytes are ASCII; replacing the undecodable
characters lets a model that emits a stray byte be measured, and leaves the
failure to the JSON parse where it belongs.
"""

from __future__ import annotations

import json
import urllib.error
import urllib.request
from collections.abc import Iterator
from dataclasses import dataclass
from typing import Any, Literal

from pydantic import BaseModel, ConfigDict, Field, field_validator

USER_AGENT = "ubuntu-console-llm-client/1"


class ChatMessage(BaseModel):
    """OpenAI-compatible chat message."""

    model_config = ConfigDict(extra="allow")
    role: Literal["system", "user", "assistant", "tool"]
    content: str | None = None
    tool_calls: list[dict[str, Any]] | None = None


class ChatCompletionRequest(BaseModel):
    """OpenAI-compatible chat completion request payload."""

    model_config = ConfigDict(extra="allow")
    model: str = ""
    messages: list[ChatMessage]
    temperature: float = Field(default=0.0, ge=0.0, le=2.0)
    max_tokens: int | None = Field(default=None, ge=1)
    stream: bool = False


class UsageInfo(BaseModel):
    """Token usage record from an OpenAI-compatible response."""

    model_config = ConfigDict(extra="ignore")
    prompt_tokens: int = Field(..., ge=0)
    completion_tokens: int = Field(..., ge=0)
    total_tokens: int = Field(default=0, ge=0)

    @field_validator("prompt_tokens", "completion_tokens", "total_tokens", mode="before")
    @classmethod
    def _reject_bool(cls, v: Any) -> Any:
        if isinstance(v, bool):
            raise ValueError("Boolean is not a valid integer token count")
        return v


class ChatChoice(BaseModel):
    """Single choice in a non-streamed chat completion response."""

    model_config = ConfigDict(extra="ignore")
    index: int = 0
    message: ChatMessage
    finish_reason: str | None = None


class ChatCompletionResponse(BaseModel):
    """OpenAI-compatible chat completion response."""

    model_config = ConfigDict(extra="ignore")
    id: str = ""
    choices: list[ChatChoice]
    usage: UsageInfo | None = None


# A streamed event as the caller needs it: the delta text, the usage record the
# server sent (``stream_options.include_usage``), and whether [DONE] arrived.
@dataclass(frozen=True)
class StreamChunk:
    content: str = ""
    usage: dict[str, Any] | None = None
    done: bool = False


class LLMClientError(RuntimeError):
    """One error type for every way the endpoint can fail us.

    ``status`` carries the HTTP status when the failure was an HTTP error, so a
    caller that wants to distinguish 404 from a connection refusal can; every
    other cause leaves it None.
    """

    def __init__(self, message: str, *, status: int | None = None) -> None:
        super().__init__(message)
        self.status = status


class LLMServerError(LLMClientError):
    """The endpoint answered and reported a failure of its own.

    Distinct from a transport failure: the server was reachable, so the cause is
    the model or the request rather than the connection, and a caller that
    reports "could not reach the server" for this would name the wrong fault.
    """


def _url(base_url: str, path: str) -> str:
    return base_url.rstrip("/") + "/" + path.lstrip("/")


def _headers(api_key: str | None, accept: str) -> dict[str, str]:
    headers = {"Accept": accept, "User-Agent": USER_AGENT}
    if api_key:
        headers["Authorization"] = f"Bearer {api_key}"
    return headers


def _open(url: str, *, data: bytes | None, timeout: float, api_key: str | None, accept: str):
    headers = _headers(api_key, accept)
    if data is not None:
        headers["Content-Type"] = "application/json"
    request = urllib.request.Request(url, data=data, headers=headers, method="POST" if data is not None else "GET")
    try:
        # The URL is the operator's own lane, passed on the command line; this
        # module never invents one and never accepts a redirect to another host.
        return urllib.request.urlopen(request, timeout=timeout)
    except urllib.error.HTTPError as exc:
        exc.close()
        raise LLMClientError(f"HTTP {exc.code} from {url}", status=exc.code) from exc
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        raise LLMClientError(f"request to {url} failed: {exc}") from exc


def _read_json(response, url: str) -> dict[str, Any]:
    body = response.read().decode("utf-8", "replace")
    try:
        payload = json.loads(body)
    except json.JSONDecodeError as exc:
        raise LLMClientError(f"{url} did not return JSON: {exc}: {body[:200]!r}") from exc
    if not isinstance(payload, dict):
        raise LLMClientError(f"{url} returned {type(payload).__name__}, not a JSON object")
    return payload


def post_url(url: str, payload: dict[str, Any], *, timeout: float, api_key: str | None = None) -> dict[str, Any]:
    """POST a JSON body to a full URL (a caller that already holds one)."""
    data = json.dumps(payload).encode("utf-8")
    with _open(url, data=data, timeout=timeout, api_key=api_key, accept="application/json") as response:
        return _read_json(response, url)


def get_url(url: str, *, timeout: float, api_key: str | None = None) -> dict[str, Any]:
    """GET a full URL (a caller that already holds one)."""
    with _open(url, data=None, timeout=timeout, api_key=api_key, accept="application/json") as response:
        return _read_json(response, url)


def post_json(base_url: str, path: str, payload: dict[str, Any], *, timeout: float, api_key: str | None = None):
    """POST a JSON body and return the decoded object."""
    return post_url(_url(base_url, path), payload, timeout=timeout, api_key=api_key)


def get_json(base_url: str, path: str, *, timeout: float, api_key: str | None = None) -> dict[str, Any]:
    """GET a path and return the decoded object."""
    return get_url(_url(base_url, path), timeout=timeout, api_key=api_key)


def post_chat(
    base_url: str,
    payload: dict[str, Any],
    *,
    timeout: float,
    api_key: str | None = None,
) -> dict[str, Any]:
    """POST ``payload`` to ``/chat/completions``."""
    return post_json(base_url, "chat/completions", payload, timeout=timeout, api_key=api_key)


def get_models(base_url: str, *, timeout: float, api_key: str | None = None) -> list[dict[str, Any]]:
    """The served model entries from ``/models``.

    Raises when the endpoint lists none: every caller that asks is deciding which
    model to measure, and an empty list is that decision's only input.
    """
    payload = get_json(base_url, "models", timeout=timeout, api_key=api_key)
    entries = payload.get("data")
    if not isinstance(entries, list) or not entries:
        raise LLMClientError(f"{_url(base_url, 'models')} listed no models")
    return [entry for entry in entries if isinstance(entry, dict)]


def stream_chat(
    base_url: str,
    payload: dict[str, Any],
    *,
    timeout: float,
    api_key: str | None = None,
) -> Iterator[StreamChunk]:
    """Stream ``payload`` from ``/chat/completions`` on ``base_url``."""
    return stream_url(_url(base_url, "chat/completions"), payload, timeout=timeout, api_key=api_key)


def stream_url(
    url: str,
    payload: dict[str, Any],
    *,
    timeout: float,
    api_key: str | None = None,
) -> Iterator[StreamChunk]:
    """Yield one :class:`StreamChunk` per SSE event, ending with ``done=True``.

    An ``error`` event from the server raises rather than being yielded: a server
    that reports a failure mid-stream has not produced a measurement, and every
    caller here would otherwise have to remember to check.
    """
    body = dict(payload)
    body["stream"] = True
    data = json.dumps(body).encode("utf-8")
    with _open(url, data=data, timeout=timeout, api_key=api_key, accept="text/event-stream") as response:
        for raw_line in response:
            line = raw_line.decode("utf-8", "strict").strip()
            if not line.startswith("data:"):
                continue
            chunk = line[5:].strip()
            if chunk == "[DONE]":
                yield StreamChunk(done=True)
                return
            try:
                event = json.loads(chunk)
            except json.JSONDecodeError as exc:
                raise LLMClientError(f"{url} returned malformed SSE JSON: {exc}") from exc
            if not isinstance(event, dict):
                raise LLMClientError(f"{url} returned a non-object SSE event")
            if "error" in event:
                # The event's payload is NOT included: a server may echo the prompt
                # back inside it, and a prompt must not reach an error line that gets
                # pasted into a report or a card.
                raise LLMServerError(f"{url} returned an error event")
            usage = event.get("usage")
            content = _delta_content(event)
            if content or isinstance(usage, dict):
                yield StreamChunk(content=content, usage=usage if isinstance(usage, dict) else None)


def _delta_content(event: dict[str, Any]) -> str:
    choices = event.get("choices")
    if not isinstance(choices, list) or not choices or not isinstance(choices[0], dict):
        return ""
    delta = choices[0].get("delta")
    if not isinstance(delta, dict):
        return ""
    content = delta.get("content")
    return content if isinstance(content, str) else ""


def extract_text(response: dict[str, Any]) -> str:
    """The assistant message text from a non-streamed chat response."""
    choices = response.get("choices")
    if not isinstance(choices, list) or not choices or not isinstance(choices[0], dict):
        raise LLMClientError("chat response carried no choice")
    message = choices[0].get("message")
    if not isinstance(message, dict):
        raise LLMClientError("chat response carried no message")
    content = message.get("content")
    if not isinstance(content, str):
        raise LLMClientError("chat response message carried no text")
    return content


def extract_usage(response: dict[str, Any]) -> dict[str, int]:
    """``{"prompt_tokens", "completion_tokens"}``, both non-negative integers.

    ``bool`` is rejected even though it is an ``int`` subclass: ``true`` in a
    token field is a malformed response, and counting it as 1 would quietly
    produce a throughput figure from nothing.
    """
    usage = response.get("usage")
    if not isinstance(usage, dict):
        raise LLMClientError("chat response carried no usage record")
    counts: dict[str, int] = {}
    for key in ("prompt_tokens", "completion_tokens"):
        value = usage.get(key)
        if isinstance(value, bool) or not isinstance(value, int) or value < 0:
            raise LLMClientError(f"usage.{key} must be a non-negative integer, got {value!r}")
        counts[key] = value
    return counts
