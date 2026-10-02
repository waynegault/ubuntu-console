#!/usr/bin/env python3
"""Stdlib-only CPAP MyAir fetch adapter for NAS use.

Supports EU region using Okta + GraphQL without aiohttp/myair_py.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import re
import secrets
import shlex
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone
from http.cookiejar import CookieJar
from typing import Any

EU_GRAPHQL_URL = "https://graphql.hyperdrive.resmed.eu/graphql"
EU_OKTA_AUTHN_URL = "https://id.resmed.eu/api/v1/authn"
EU_OKTA_AUTHORIZE_URL = "https://id.resmed.eu/oauth2/aus2uznux2sYKTsEg417/v1/authorize"
EU_OKTA_TOKEN_URL = "https://id.resmed.eu/oauth2/aus2uznux2sYKTsEg417/v1/token"
EU_ORIGIN = "https://myair.resmed.eu"
EU_REDIRECT_URI = "https://myair.resmed.eu"
EU_DASHBOARD_URL = "https://myair.resmed.eu/dashboard"
EU_CLIENT_ID = "0oa2uz04d2Pks2NgR417"
EU_API_KEY = os.getenv("CPAP_MYAIR_API_KEY", "")
EU_PRODUCT = "myAir EU"
EU_APP_VERSION = "2.0.0"
EU_PLATFORM = "Web"
EU_MODEL = "MS-Edge-Chromium"

EU_SLEEP_QUERY = """
query GetPatientSleepRecords($startMonth: AWSDate!, $endMonth: AWSDate!) {
  getPatientWrapper {
    patient { id firstName timezoneId }
    masks { maskCode }
    fgDevices { deviceSeries deviceFamily lastSleepDataReportTime }
    sleepRecords(startMonth: $startMonth, endMonth: $endMonth) {
      items {
        startDate totalUsage sleepScore usageScore ahiScore maskScore leakScore
        ahi maskPairCount leakPercentile sleepRecordPatientId
      }
    }
  }
}
""".strip()


class MyAirFetchError(RuntimeError):
    pass


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def _env(name: str, default: str = "") -> str:
    return os.getenv(name, default).strip()


def _resolve_myair_password() -> str:
    """The MyAir account password, resolved by CANONICAL name first.

    RESMED_PASSWORD is the canonical name: it is the Windows user-environment name
    (Wayne's ruling 2026-10-01 -- Windows is the source of record) and the name the
    NAS's openclaw-collectors.env publishes, so this host receives it through the
    export channel rather than a hand-copied value. CPAP_MYAIR_PASSWORD is the local
    alias (same bytes today), kept as an explicit FALLBACK so the pipeline keeps
    working if the alias is what an environment carries. One resolution point, so no
    caller has to know the order. Added 2026-10-02 with the workspace-jarvis copies.
    """
    return _env("RESMED_PASSWORD") or _env("CPAP_MYAIR_PASSWORD")


def _pkce_pair() -> tuple[str, str]:
    verifier = base64.urlsafe_b64encode(secrets.token_bytes(48)).decode("ascii").rstrip("=")
    challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode("utf-8")).digest()).decode("ascii").rstrip("=")
    return verifier, challenge


def _okta_headers(accept: str, content_type: str) -> dict[str, str]:
    return {
        "Accept": accept,
        "Content-Type": content_type,
        "Origin": EU_ORIGIN,
        "Referer": EU_ORIGIN + "/",
        "User-Agent": "Mozilla/5.0",
    }


def _graphql_headers(token: str, api_key: str) -> dict[str, str]:
    """Headers the myAir EU backend requires for GetPatientSleepRecords.

    A request carrying only authorization + x-api-key gets an `internalServerError`
    from the backend: it also needs the app-family `rmd*` headers and a dashboard
    referer. Measured 2026-10-02 -- the NAS request without these returned
    `myAir:result internalServerError` while the workspace-jarvis request (which
    sends this exact set) succeeds -- so the set is ported verbatim from there,
    values env-overridable exactly as that file has them.
    """
    return {
        "accept": "application/json, text/plain, */*",
        "authorization": f"Bearer {token}",
        "content-type": "application/json",
        "origin": EU_ORIGIN,
        "referer": _env("CPAP_MYAIR_DASHBOARD_URL", EU_DASHBOARD_URL),
        "rmdappversion": _env("CPAP_MYAIR_APP_VERSION", EU_APP_VERSION),
        "rmdcountry": _env("CPAP_MYAIR_COUNTRY", "GB"),
        "rmdhandsetid": _env("CPAP_MYAIR_HANDSET_ID", "c4671203-7e59-43a8-9bff-9b859265bc36"),
        "rmdhandsetmodel": _env("CPAP_MYAIR_MODEL", EU_MODEL),
        "rmdhandsetosversion": _env("CPAP_MYAIR_HANDSET_OS_VERSION", "146.0.0.0"),
        "rmdhandsetplatform": _env("CPAP_MYAIR_PLATFORM", EU_PLATFORM),
        "rmdlanguage": _env("CPAP_MYAIR_LANGUAGE", "en-GB"),
        "rmdproduct": _env("CPAP_MYAIR_PRODUCT", EU_PRODUCT),
        "user-agent": _env(
            "CPAP_MYAIR_USER_AGENT",
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/146.0.0.0 Safari/537.36 Edg/146.0.0.0",
        ),
        "x-api-key": api_key,
    }


def _graphql_request(payload: dict[str, Any], token: str, api_key: str) -> urllib.request.Request:
    """Build the GraphQL POST, preserving the header names' case.

    urllib.request.Request.add_header() rewrites names with key.capitalize(), which
    would turn "rmdhandsetosversion" into "Rmdhandsetosversion". The proven-working
    workspace-jarvis request sends them lowercase, so the dict is assigned to
    req.headers directly to reproduce that exactly.
    """
    req = urllib.request.Request(EU_GRAPHQL_URL, data=json.dumps(payload).encode("utf-8"), method="POST")
    req.headers = _graphql_headers(token, api_key)
    return req


def _request_text(opener: urllib.request.OpenerDirector, req: urllib.request.Request, timeout: int = 30) -> tuple[int, str, dict[str, str]]:
    # Header names are lowercased: HTTP header names are case-insensitive and Okta's
    # redirect sends "location" in lowercase, so the previous exact-case lookups
    # ("Location") missed it. Measured 2026-10-02: the 302 carried a lowercase
    # "location" header, which made the authorize step fail with an empty Location.
    try:
        with opener.open(req, timeout=timeout) as response:
            return int(response.status), response.read().decode("utf-8", errors="replace"), {k.lower(): v for k, v in response.headers.items()}
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", errors="replace")
        return int(exc.code), body, {k.lower(): v for k, v in exc.headers.items()}


def _int_env(name: str, default: int, minimum: int = 0) -> int:
    try:
        value = int(_env(name, str(default)) or str(default))
    except ValueError:
        return default
    return max(minimum, value)


def _load_email_otp_once(*, force_refresh: bool) -> tuple[str, str]:
    """Run the configured OTP command once; return (otp, error).

    A non-zero exit is NOT fatal here. The reader exits non-zero when no matching
    message exists yet, which is the expected state between the MFA challenge being
    triggered and the code mail arriving -- the caller polls. Only an expired window
    fails (see _poll_email_otp). The error text of the last failed attempt is returned
    so the expiry message can say why it never matched.
    """
    cmd = _env("CPAP_MYAIR_EMAIL_OTP_COMMAND")
    if not cmd:
        return "", ""
    env = os.environ.copy()
    if force_refresh:
        env["KAI_MYAIR_FORCE_REFRESH"] = "1"
    try:
        proc = subprocess.run(
            shlex.split(cmd),
            capture_output=True,
            text=True,
            timeout=_int_env("CPAP_MYAIR_OTP_COMMAND_TIMEOUT_SECONDS", 75, 1),
            env=env,
        )
    except Exception as exc:
        return "", f"OTP command failed to run: {exc}"
    if proc.returncode != 0:
        return "", f"OTP command returned non-zero ({proc.returncode}): {(proc.stderr or '').strip()}"
    out = (proc.stdout or "").strip()
    if not out:
        return "", "OTP command produced no output"
    match = re.search(r"\b(\d{6,8})\b", out)
    return (match.group(1) if match else out), ""


def _poll_email_otp() -> str:
    """Poll the OTP command across the delivery window; fail only when it expires.

    The width must exceed the mail's delivery latency: a 2026-09-22 run measured the
    MyAir code landing ~5.5 min after the challenge, which a single immediate read can
    never catch. Defaults mirror the workspace-jarvis fetcher (8s + 3x6s); the deployed
    values are set in cron/cpap-collector.env.
    """
    initial_delay = _int_env("CPAP_MYAIR_OTP_INITIAL_DELAY_SECONDS", 8, 0)
    poll_interval = _int_env("CPAP_MYAIR_OTP_POLL_INTERVAL_SECONDS", 6, 1)
    poll_attempts = _int_env("CPAP_MYAIR_OTP_POLL_ATTEMPTS", 3, 1)
    if initial_delay:
        time.sleep(initial_delay)
    last_error = ""
    for attempt in range(poll_attempts):
        otp, last_error = _load_email_otp_once(force_refresh=True)
        if otp:
            return otp
        if attempt + 1 < poll_attempts:
            time.sleep(poll_interval)
    window = initial_delay + poll_interval * (poll_attempts - 1)
    detail = f" Last OTP error: {last_error}" if last_error else ""
    raise MyAirFetchError(
        "EU login requires email MFA; the challenge was triggered but no code mail "
        f"arrived within the {window}s window ({poll_attempts} attempt(s)).{detail}"
    )


def _eu_session_token(opener: urllib.request.OpenerDirector, username: str, password: str) -> str:
    payload = json.dumps(
        {
            "username": username,
            "password": password,
            "options": {"warnBeforePasswordExpired": True, "multiOptionalFactorEnroll": False},
        }
    ).encode("utf-8")
    req = urllib.request.Request(EU_OKTA_AUTHN_URL, data=payload, headers=_okta_headers("application/json", "application/json"), method="POST")
    status, body, _ = _request_text(opener, req)
    if status != 200:
        raise MyAirFetchError(f"EU authn failed ({status}): {body[:300]}")
    data = json.loads(body)

    if data.get("status") == "SUCCESS":
        token = data.get("sessionToken") or ""
        if not token:
            raise MyAirFetchError("EU authn succeeded but sessionToken missing")
        return token

    if data.get("status") != "MFA_REQUIRED":
        raise MyAirFetchError(f"EU authn unsupported status: {data.get('status')}")

    state_token = data.get("stateToken") or ""
    factors = ((data.get("_embedded") or {}).get("factors") or [])
    email_factor = next((f for f in factors if f.get("factorType") == "email"), None)
    verify_url = (((email_factor or {}).get("_links") or {}).get("verify") or {}).get("href") or ""
    if not (state_token and verify_url):
        raise MyAirFetchError("EU authn requires MFA, but email verify factor was not available")

    # Order matters: MyAir only sends the code AFTER the challenge is issued, so the
    # challenge must be triggered BEFORE the code is read. The previous version read
    # first and treated the empty read as fatal, so the challenge POST was never
    # reached, the mailbox was never seeded, and every run failed identically with
    # "No OTP found in matching messages". A pre-supplied CPAP_MYAIR_EMAIL_OTP still
    # pre-empts the challenge and is submitted as-is (unchanged override behaviour).
    otp = _env("CPAP_MYAIR_EMAIL_OTP")
    if not otp:
        begin_payload = json.dumps({"stateToken": state_token}).encode("utf-8")
        begin_req = urllib.request.Request(verify_url, data=begin_payload, headers=_okta_headers("application/json", "application/json"), method="POST")
        begin_status, begin_body, _ = _request_text(opener, begin_req)
        if begin_status == 429:
            raise MyAirFetchError(
                "EU login requires email MFA and challenge is rate-limited (429). "
                "Wait a few seconds before retrying; do not re-request a code already in flight."
            )
        if begin_status != 200:
            raise MyAirFetchError(f"EU MFA challenge request failed ({begin_status}): {begin_body[:300]}")
        otp = _poll_email_otp()

    verify_payload = json.dumps({"stateToken": state_token, "passCode": otp}).encode("utf-8")
    verify_req = urllib.request.Request(verify_url, data=verify_payload, headers=_okta_headers("application/json", "application/json"), method="POST")
    verify_status, verify_body, _ = _request_text(opener, verify_req)
    if verify_status != 200:
        raise MyAirFetchError(f"EU MFA verification failed ({verify_status}): {verify_body[:300]}")
    verify_data = json.loads(verify_body)
    token = verify_data.get("sessionToken") or ""
    if not token:
        raise MyAirFetchError("EU MFA verification response missing sessionToken")
    return token


def _eu_bearer_token(opener: urllib.request.OpenerDirector, username: str, password: str) -> str:
    session_token = _eu_session_token(opener, username, password)
    verifier, challenge = _pkce_pair()
    params = {
        "client_id": _env("CPAP_MYAIR_OKTA_CLIENT_ID", EU_CLIENT_ID),
        "redirect_uri": _env("CPAP_MYAIR_REDIRECT_URI", EU_REDIRECT_URI),
        "response_type": "code",
        "response_mode": "query",
        "scope": "openid profile email",
        "state": secrets.token_urlsafe(16),
        "nonce": secrets.token_urlsafe(16),
        "code_challenge": challenge,
        "code_challenge_method": "S256",
        "prompt": "none",
        "sessionToken": session_token,
    }
    auth_url = f"{EU_OKTA_AUTHORIZE_URL}?{urllib.parse.urlencode(params)}"
    req = urllib.request.Request(auth_url, headers=_okta_headers("text/html,*/*", "application/x-www-form-urlencoded"), method="GET")
    status, _body, headers = _request_text(opener, req)
    location = headers.get("location", "")
    if status not in (302, 303) or not location:
        raise MyAirFetchError(f"EU authorize did not redirect with code (status {status})")
    code = (urllib.parse.parse_qs(urllib.parse.urlparse(location).query).get("code") or [""])[0]
    if not code:
        raise MyAirFetchError("EU authorize redirect missing code")

    form = urllib.parse.urlencode(
        {
            "client_id": _env("CPAP_MYAIR_OKTA_CLIENT_ID", EU_CLIENT_ID),
            "redirect_uri": _env("CPAP_MYAIR_REDIRECT_URI", EU_REDIRECT_URI),
            "grant_type": "authorization_code",
            "code_verifier": verifier,
            "code": code,
        }
    ).encode("utf-8")
    token_req = urllib.request.Request(EU_OKTA_TOKEN_URL, data=form, headers=_okta_headers("application/json", "application/x-www-form-urlencoded"), method="POST")
    token_status, token_body, _ = _request_text(opener, token_req)
    if token_status != 200:
        raise MyAirFetchError(f"EU token exchange failed ({token_status}): {token_body[:300]}")
    token_data = json.loads(token_body)
    access = token_data.get("access_token") or ""
    if not access:
        raise MyAirFetchError("EU token response missing access_token")
    return access


def _fetch_eu(username: str, password: str) -> dict[str, Any]:
    opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(CookieJar()), _NoRedirect())
    token = _env("CPAP_MYAIR_BEARER_TOKEN") or _eu_bearer_token(opener, username, password)
    api_key = _env("CPAP_MYAIR_API_KEY", EU_API_KEY)

    today = datetime.now(timezone.utc).date()
    start = (today - timedelta(days=29)).isoformat()
    end = today.isoformat()
    payload = {
        "operationName": "GetPatientSleepRecords",
        "variables": {"startMonth": start, "endMonth": end},
        "query": EU_SLEEP_QUERY,
    }
    req = _graphql_request(payload, token, api_key)
    status, body, _ = _request_text(opener, req)
    if status != 200:
        raise MyAirFetchError(f"EU GraphQL request failed ({status}): {body[:300]}")
    data = json.loads(body)
    if data.get("errors"):
        raise MyAirFetchError(f"EU GraphQL returned errors: {data['errors']}")

    wrapper = ((data.get("data") or {}).get("getPatientWrapper") or {})
    patient = wrapper.get("patient") or {}
    devices = wrapper.get("fgDevices") or []
    device = devices[0] if devices else {}
    records = (((wrapper.get("sleepRecords") or {}).get("items")) or [])
    normalized_device = {
        "serialNumber": patient.get("id") or username,
        "localizedName": patient.get("firstName") or "ResMed MyAir EU",
        "deviceSeries": device.get("deviceSeries"),
        "deviceFamily": device.get("deviceFamily"),
        "lastSleepDataReportTime": device.get("lastSleepDataReportTime"),
    }
    return {"device": normalized_device, "sleep_records": records}


def main() -> int:
    parser = argparse.ArgumentParser(description="Stdlib MyAir fetch adapter")
    parser.add_argument("--username", help="MyAir username (or CPAP_MYAIR_USERNAME)")
    parser.add_argument("--password", help="MyAir password (or CPAP_MYAIR_PASSWORD)")
    parser.add_argument("--region", default="EU", help="MyAir region (EU supported)")
    args = parser.parse_args()

    username = (args.username or _env("CPAP_MYAIR_USERNAME")).strip()
    password = (args.password or _resolve_myair_password()).strip()
    region = (_env("CPAP_MYAIR_REGION") or _env("CPAP_REGION") or args.region).strip().upper()

    if not username or not password:
        print(json.dumps({"error": "Username and password required"}), file=sys.stderr)
        return 1

    if region != "EU":
        print(json.dumps({"error": f"Region '{region}' not supported by stdlib adapter", "supported": ["EU"]}), file=sys.stderr)
        return 1

    try:
        result = _fetch_eu(username, password)
        json.dump(result, sys.stdout, indent=2)
        sys.stdout.write("\n")
        return 0
    except MyAirFetchError as exc:
        print(json.dumps({"error": str(exc)}), file=sys.stderr)
        return 1
    except Exception as exc:
        print(json.dumps({"error": "Unexpected error", "details": str(exc)}), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
