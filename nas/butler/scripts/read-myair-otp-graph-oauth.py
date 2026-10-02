#!/usr/bin/env python3
# Version: 1.1.0
# AI INSTRUCTION: After any code change, increment the Version value in this file.

"""Microsoft Graph OAuth OTP reader for ResMed myAir MFA emails.

This is NAS-friendly (stdlib only):
- One-time auth bootstrap with device code flow
- Persistent refresh token cache
- Inbox scanning and post-read deletion of the matched OTP email via Microsoft Graph
"""

from __future__ import annotations

import argparse
import json
import os
import re
import ssl
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

TOKEN_URL_TMPL = "https://login.microsoftonline.com/{tenant}/oauth2/v2.0/token"
DEVICE_CODE_URL_TMPL = "https://login.microsoftonline.com/{tenant}/oauth2/v2.0/devicecode"
# Folders searched for a code mail, by Graph WELL-KNOWN name (not display name: this
# mailbox's folders are "MSN Inbox" / "MSN Junk Email"). The Inbox alone was measured
# insufficient on 2026-10-02 -- the Junk folder here holds live mail and is the classic
# destination for automated MFA mail, so a code sitting there was invisible to this reader.
# Archive is included because a code mail can be filed away by a swipe or a server rule.
# Neither choice widens WHICH mail is accepted: CPAP_MYAIR_OTP_SENDER_REGEX and
# CPAP_MYAIR_OTP_SUBJECT_REGEX still gate every candidate.
GRAPH_OTP_FOLDERS = ("Inbox", "JunkEmail", "Archive")

DEFAULT_SCOPES = "offline_access Mail.Read User.Read"


def _ssl_context() -> ssl.SSLContext:
    ca_file = _env("CPAP_MYAIR_GRAPH_CA_CERT_FILE")
    allow_insecure = _env("CPAP_MYAIR_GRAPH_INSECURE_TLS", "0") == "1"

    if ca_file:
        return ssl.create_default_context(cafile=ca_file)
    if allow_insecure:
        return ssl._create_unverified_context()
    return ssl.create_default_context()


def _env(name: str, default: str = "") -> str:
    return os.getenv(name, default).strip()


def _token_file() -> Path:
    p = _env("CPAP_MYAIR_GRAPH_TOKEN_FILE", "/mnt/HD/HD_a2/butler/cron/myair-graph-token.json")
    return Path(p)


def _token_state() -> dict:
    p = _token_file()
    if not p.exists():
        return {}
    try:
        return json.loads(p.read_text(encoding="utf-8"))
    except Exception:
        return {}


def _save_token_state(state: dict) -> None:
    p = _token_file()
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(json.dumps(state, indent=2) + "\n", encoding="utf-8")
    try:
        os.chmod(p, 0o600)
    except Exception:
        pass


def _post_form(url: str, form: dict[str, str]) -> dict:
    data = urllib.parse.urlencode(form).encode("utf-8")
    req = urllib.request.Request(url, data=data, method="POST")
    req.add_header("Content-Type", "application/x-www-form-urlencoded")
    req.add_header("Accept", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=30, context=_ssl_context()) as resp:
            return json.loads(resp.read().decode("utf-8", errors="replace"))
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", errors="replace")
        payload: dict[str, object]
        try:
            payload = json.loads(body)
        except Exception:
            payload = {"error": "http_error", "error_description": body}
        payload["_http_status"] = int(exc.code)
        return payload


def _graph_get(url: str, access_token: str) -> dict:
    req = urllib.request.Request(url, method="GET")
    req.add_header("Authorization", f"Bearer {access_token}")
    req.add_header("Accept", "application/json")
    req.add_header("Prefer", 'outlook.body-content-type="text"')
    try:
        with urllib.request.urlopen(req, timeout=30, context=_ssl_context()) as resp:
            return json.loads(resp.read().decode("utf-8", errors="replace"))
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", errors="replace")
        payload: dict[str, object]
        try:
            payload = json.loads(body)
        except Exception:
            payload = {"error": {"message": body}}
        payload["_http_status"] = int(exc.code)
        return payload


def _graph_delete(url: str, access_token: str) -> None:
    req = urllib.request.Request(url, method="DELETE")
    req.add_header("Authorization", f"Bearer {access_token}")
    try:
        with urllib.request.urlopen(req, timeout=30, context=_ssl_context()) as resp:
            status = int(resp.status)
            if status not in {200, 202, 204}:
                raise RuntimeError(f"Graph delete returned HTTP {status}")
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"Graph delete failed ({exc.code}): {body[:300]}") from exc


def _client_id() -> str:
    return _env("CPAP_MYAIR_GRAPH_CLIENT_ID")


def _tenant() -> str:
    return _env("CPAP_MYAIR_GRAPH_TENANT_ID", "consumers")


def _scopes() -> str:
    return _env("CPAP_MYAIR_GRAPH_SCOPES", DEFAULT_SCOPES)


def _now() -> int:
    return int(time.time())


def _is_token_valid(state: dict) -> bool:
    exp = int(state.get("expires_at", 0) or 0)
    return bool(state.get("access_token")) and exp > (_now() + 60)


def _refresh_access_token(state: dict) -> dict:
    refresh_token = (state.get("refresh_token") or "").strip()
    if not refresh_token:
        return {"error": "missing_refresh_token", "error_description": "No refresh token cached. Run --auth-init first."}

    token_url = TOKEN_URL_TMPL.format(tenant=_tenant())
    payload = _post_form(
        token_url,
        {
            "client_id": _client_id(),
            "grant_type": "refresh_token",
            "refresh_token": refresh_token,
            "scope": _scopes(),
        },
    )
    if payload.get("access_token"):
        expires_in = int(payload.get("expires_in", 3600) or 3600)
        new_state = {
            "access_token": payload.get("access_token"),
            "refresh_token": payload.get("refresh_token") or refresh_token,
            "expires_at": _now() + expires_in,
            "token_type": payload.get("token_type", "Bearer"),
            "scope": payload.get("scope", _scopes()),
            "updated_at": datetime.now(timezone.utc).isoformat(),
        }
        _save_token_state(new_state)
        return new_state
    return payload


def _ensure_access_token() -> str:
    cid = _client_id()
    if not cid:
        raise RuntimeError("Missing CPAP_MYAIR_GRAPH_CLIENT_ID")

    state = _token_state()
    if _is_token_valid(state):
        return str(state["access_token"])

    refreshed = _refresh_access_token(state)
    if refreshed.get("access_token"):
        return str(refreshed["access_token"])

    err = refreshed.get("error_description") or refreshed.get("error") or "unknown auth error"
    raise RuntimeError(f"OAuth token unavailable: {err}")


def _extract_otp(text: str) -> str:
    match = re.search(r"\b([0-9]{6,8})\b", text)
    return match.group(1) if match else ""


def _message_matches(msg: dict) -> bool:
    sender_re = _env("CPAP_MYAIR_OTP_SENDER_REGEX", "resmed|myair")
    subject_re = _env("CPAP_MYAIR_OTP_SUBJECT_REGEX", "verification|code|myair")

    sender = (((msg.get("from") or {}).get("emailAddress") or {}).get("address") or "")
    subject = msg.get("subject") or ""

    if sender_re and not re.search(sender_re, sender, flags=re.IGNORECASE):
        return False
    if subject_re and not re.search(subject_re, subject, flags=re.IGNORECASE):
        return False
    return True


def _otp_folders() -> tuple[str, ...]:
    """The folders to search, overridable without an edit."""
    raw = _env("CPAP_MYAIR_OTP_GRAPH_FOLDERS", ",".join(GRAPH_OTP_FOLDERS))
    folders = tuple(f.strip() for f in raw.split(",") if f.strip())
    return folders or GRAPH_OTP_FOLDERS


def _received_at(msg: dict) -> float:
    """Received time as a POSIX timestamp; 0.0 when absent or unparsable.

    Deliberately never "now": a message whose date cannot be read must not look fresh, or an
    undated match would be treated as a live code (see _otp_max_age_seconds).
    """
    raw = str(msg.get("receivedDateTime") or "")
    try:
        return datetime.fromisoformat(raw.replace("Z", "+00:00")).timestamp()
    except ValueError:
        return 0.0


def _fetch_messages(token: str) -> list[dict]:
    """Every message in the searched folders, NEWEST FIRST across all of them.

    Newest-first matters: the caller takes the first match, and an arbitrary per-folder order
    could hand back an older code than one sitting in another folder.
    """
    top = int(_env("CPAP_MYAIR_GRAPH_TOP", "25") or "25")
    query = urllib.parse.urlencode(
        {
            "$top": str(top),
            "$orderby": "receivedDateTime desc",
            "$select": "id,subject,from,bodyPreview,body,receivedDateTime,isRead",
        }
    )
    messages: list[dict] = []
    for folder in _otp_folders():
        url = (
            "https://graph.microsoft.com/v1.0/me/mailFolders/"
            f"{urllib.parse.quote(folder)}/messages?{query}"
        )
        data = _graph_get(url, token)
        if data.get("error"):
            message = (data.get("error") or {}).get("message") or str(data.get("error"))
            raise RuntimeError(f"Graph read failed for folder {folder}: {message}")
        messages.extend(data.get("value", []))
    messages.sort(key=_received_at, reverse=True)
    return messages


def _otp_max_age_seconds() -> int:
    """How old a matched code mail may be before it is refused.

    An OTP belongs to the challenge that generated it. Submitting a stale one burns a wrong
    passcode against Okta and risks a lockout, while refusing fails cleanly and visibly — the
    failure mode is already recorded on this estate: a cached code produced E0000068
    "Invalid Passcode/Answer" (read-myair-otp.sh v1.1.0, 2026-09-22, which added the same
    guard on the host side). The knob name and default match that reader deliberately, so one
    number explains both.
    """
    try:
        return max(0, int(_env("CPAP_MYAIR_OTP_CACHE_MAX_AGE_SECONDS", "600") or "600"))
    except ValueError:
        return 600


def _read_otp_from_graph() -> str:
    token = _ensure_access_token()
    messages = _fetch_messages(token)
    max_age = _otp_max_age_seconds()

    for msg in messages:
        if not _message_matches(msg):
            continue
        # messages is newest-first, so the FIRST match is the newest one and every later match
        # is older: if this one is stale there is nothing fresh to submit. An undated match
        # ages as infinitely old (_received_at -> 0.0), i.e. it is refused too.
        age = int(max(0, _now() - _received_at(msg)))
        if age > max_age:
            raise RuntimeError(
                f"No FRESH OTP: the newest matching message is {age}s old "
                f"(max {max_age}s) -- refusing to submit a stale code"
            )
        message_id = str(msg.get("id") or "")
        subject = msg.get("subject") or ""
        preview = msg.get("bodyPreview") or ""
        body = ((msg.get("body") or {}).get("content") or "")
        otp = _extract_otp("\n".join([subject, preview, body]))
        if otp and message_id:
            _graph_delete(
                f"https://graph.microsoft.com/v1.0/me/messages/{urllib.parse.quote(message_id)}",
                token,
            )
            return otp

    raise RuntimeError(
        "No OTP found in matching messages (folders searched: "
        + ", ".join(_otp_folders()) + ")"
    )


def auth_init() -> int:
    cid = _client_id()
    if not cid:
        print("Missing CPAP_MYAIR_GRAPH_CLIENT_ID", file=sys.stderr)
        return 2

    tenant = _tenant()
    scope = _scopes()

    device_url = DEVICE_CODE_URL_TMPL.format(tenant=tenant)
    token_url = TOKEN_URL_TMPL.format(tenant=tenant)

    dc = _post_form(device_url, {"client_id": cid, "scope": scope})
    if dc.get("error"):
        print(f"Device-code init failed: {dc.get('error_description') or dc.get('error')}", file=sys.stderr)
        return 3

    print(dc.get("message") or f"Visit {dc.get('verification_uri')} and enter code {dc.get('user_code')}")

    device_code = dc.get("device_code")
    if not device_code:
        print("Device-code init returned no device_code", file=sys.stderr)
        return 4
    interval = int(dc.get("interval", 5) or 5)
    expires_in = int(dc.get("expires_in", 900) or 900)
    deadline = _now() + expires_in

    while _now() < deadline:
        time.sleep(interval)
        tok = _post_form(
            token_url,
            {
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
                "client_id": cid,
                "device_code": device_code,
            },
        )

        if tok.get("access_token"):
            expires_in_tok = int(tok.get("expires_in", 3600) or 3600)
            state = {
                "access_token": tok.get("access_token"),
                "refresh_token": tok.get("refresh_token", ""),
                "expires_at": _now() + expires_in_tok,
                "token_type": tok.get("token_type", "Bearer"),
                "scope": tok.get("scope", scope),
                "updated_at": datetime.now(timezone.utc).isoformat(),
            }
            _save_token_state(state)
            print("OAuth login successful; token cache saved.")
            return 0

        err = tok.get("error")
        if err == "authorization_pending":
            continue
        if err == "slow_down":
            interval += 2
            continue
        print(f"OAuth login failed: {tok.get('error_description') or err}", file=sys.stderr)
        return 4

    print("OAuth login timed out waiting for user authorization.", file=sys.stderr)
    return 5


def auth_status() -> int:
    state = _token_state()
    if not state:
        print("OAuth token cache not initialized")
        return 1
    exp = int(state.get("expires_at", 0) or 0)
    print(
        json.dumps(
            {
                "has_access_token": bool(state.get("access_token")),
                "has_refresh_token": bool(state.get("refresh_token")),
                "expires_at_unix": exp,
                "expires_in_sec": max(0, exp - _now()),
                "token_file": str(_token_file()),
            },
            indent=2,
        )
    )
    return 0


def _clean_matching() -> int:
    """Delete all messages matching the configured sender/subject regex
    without extracting OTP."""
    token = _ensure_access_token()
    # _fetch_messages returns the message list and RAISES RuntimeError on a Graph
    # error, so the old {"value": ...} wrapper's error branch was unreachable.
    messages = _fetch_messages(token)
    deleted = 0
    for msg in messages:
        if not _message_matches(msg):
            continue
        message_id = str(msg.get("id") or "")
        if not message_id:
            continue
        try:
            _graph_delete(
                f"https://graph.microsoft.com/v1.0/me/messages/{urllib.parse.quote(message_id)}",
                token,
            )
            deleted += 1
        except Exception as e:
            print(f"Delete failed for {msg.get('subject')}: {e}", file=sys.stderr)
    print(f"Deleted {deleted} matching emails.")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="Graph OAuth OTP reader / cleaner")
    parser.add_argument("--auth-init", action="store_true", help="Run one-time OAuth device-code login")
    parser.add_argument("--auth-status", action="store_true", help="Show token cache status")
    parser.add_argument("--clean", action="store_true", help="Delete all matching ResMed OTP emails without extracting OTP")
    args = parser.parse_args()

    if args.auth_init:
        return auth_init()
    if args.auth_status:
        return auth_status()
    if args.clean:
        return _clean_matching()


    try:
        otp = _read_otp_from_graph()
        print(otp)
        return 0
    except Exception as exc:
        print(str(exc), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())

# end of file
