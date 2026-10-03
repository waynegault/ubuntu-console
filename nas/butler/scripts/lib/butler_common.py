"""Shared primitives for the NAS butler collectors (card 974f99ff).

This module is the ONE deliberate exception to byte-identical mirroring in
``nas/butler``: the collectors import these primitives instead of each carrying a
private copy of the OTP extractor, the Microsoft Graph GET/DELETE client and the
InfluxDB line-protocol POST.  It deploys alongside the scripts (as
``lib/butler_common.py``); a script run as ``python /path/to/foo.py`` has its own
directory on ``sys.path``, so ``from lib.butler_common import ...`` resolves.
"""

from __future__ import annotations

import json
import re
import urllib.error
import urllib.request
from typing import Any

OTP_RE = re.compile(r"\b(\d{6,8})\b")


def extract_otp(text: str) -> str | None:
    """The 6-8 digit one-time code in *text*, or None when there is none.

    One extractor, so a myAir/ResMed email cannot be parsed one way by the IMAP
    reader and another way by the Graph readers.
    """
    match = OTP_RE.search(text)
    return match.group(1) if match else None


def graph_get(url: str, access_token: str, *, prefer_text: bool = False,
              timeout: int = 20) -> dict[str, Any]:
    """Authenticated Microsoft Graph GET; raises RuntimeError on an HTTP error.

    ``prefer_text`` adds the ``Prefer: outlook.body-content-type="text"`` header
    the OAuth reader needs; it is off by default so the plain ``bodyPreview``
    callers get an unchanged request.
    """
    req = urllib.request.Request(url, method="GET")
    req.add_header("Authorization", f"Bearer {access_token}")
    req.add_header("Accept", "application/json")
    if prefer_text:
        req.add_header("Prefer", 'outlook.body-content-type="text"')
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return json.loads(resp.read().decode("utf-8", errors="replace"))
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"Graph GET {url} HTTP {exc.code}: {body}") from exc


def graph_delete(url: str, access_token: str, *, timeout: int = 20) -> int:
    """Authenticated Microsoft Graph DELETE; returns the HTTP status."""
    req = urllib.request.Request(url, method="DELETE")
    req.add_header("Authorization", f"Bearer {access_token}")
    req.add_header("Accept", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return int(resp.status)
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"Graph DELETE {url} HTTP {exc.code}: {body}") from exc


def post_line_protocol(url: str, body: str, *, timeout: int = 8) -> int:
    """POST InfluxDB line protocol; returns the HTTP status (raises on failure).

    Callers keep their own URL and their own error handling; only the request /
    Content-Type boilerplate lives here.
    """
    req = urllib.request.Request(url, data=body.encode("utf-8"), method="POST")
    req.add_header("Content-Type", "application/octet-stream")
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return int(resp.status)
