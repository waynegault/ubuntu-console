#!/usr/bin/env python3
"""Unified CPAP fetcher for NAS: triggers MFA, extracts OTP via Graph API, fetches data."""

import json
import pathlib
import re
import urllib.request
import urllib.parse
import urllib.error
import time
import sys
import os

TOKEN_CACHE = "/mnt/HD/HD_a2/butler/cron/outlook-mcp-token-cache"
GRAPH_API = "https://graph.microsoft.com/v1.0"

EU_OKTA_AUTHN_URL = "https://id.resmed.eu/api/v1/authn"
EU_OKTA_AUTHORIZE_URL = "https://id.resmed.eu/oauth2/aus2uznux2sYKTsEg417/v1/authorize"
EU_OKTA_TOKEN_URL = "https://id.resmed.eu/oauth2/aus2uznux2sYKTsEg417/v1/token"
EU_CLIENT_ID = "0oa2uznuih7PcVgF7417"
EU_REDIRECT_URI = "https://myair.resmed.eu/authentication/callback"

USERNAME = os.environ.get("CPAP_MYAIR_USERNAME", "")
PASSWORD = os.environ.get("CPAP_MYAIR_PASSWORD", "")

class NoRedirect(urllib.request.HTTPRedirectHandler):
    def http_error_302(self, req, fp, code, msg, headers):
        return fp
    http_error_301 = http_error_303 = http_error_307 = http_error_302

def _get_graph_token() -> str:
    cache = json.loads(pathlib.Path(TOKEN_CACHE).read_text())
    for key, token in cache.get("AccessToken", {}).items():
        if "graph.microsoft.com" in key:
            return token["secret"]
    raise RuntimeError("No Graph token")

def _graph_get(url: str) -> dict:
    token = _get_graph_token()
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}", "Accept": "application/json"})
    with urllib.request.urlopen(req, timeout=20) as resp:
        return json.loads(resp.read().decode())

def _graph_delete(url: str) -> int:
    token = _get_graph_token()
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}", "Accept": "application/json"}, method="DELETE")
    with urllib.request.urlopen(req, timeout=20) as resp:
        return int(resp.status)

def _extract_otp(text: str) -> str | None:
    match = re.search(r"\b(\d{6,8})\b", text)
    return match.group(1) if match else None

def _get_fresh_otp() -> str:
    """Trigger MFA, poll for email, extract OTP."""
    # Step 1: Trigger MFA
    payload = json.dumps({
        "username": USERNAME,
        "password": PASSWORD,
        "options": {"warnBeforePasswordExpired": True, "multiOptionalFactorEnroll": False}
    }).encode("utf-8")
    req = urllib.request.Request(EU_OKTA_AUTHN_URL, data=payload, headers={"Content-Type": "application/json", "Accept": "application/json"}, method="POST")
    with urllib.request.urlopen(req, timeout=30) as resp:
        data = json.loads(resp.read().decode())
        if data.get("status") != "MFA_REQUIRED":
            raise RuntimeError(f"Unexpected auth status: {data.get('status')}")
    
    print("MFA triggered, waiting for email...", file=sys.stderr)
    
    # Step 2: Poll Graph API for new email (max 30 seconds)
    for attempt in range(10):
        time.sleep(3)
        
        base_url = f"{GRAPH_API}/me/messages"
        params = urllib.parse.urlencode({
            "$top": "5",
            "$select": "id,subject,sender,bodyPreview,receivedDateTime",
            "$orderby": "receivedDateTime desc",
        })
        url = f"{base_url}?{params}"
        
        try:
            data = _graph_get(url)
            messages = data.get("value", [])
            
            for msg in messages:
                sender = msg.get("sender", {}).get("emailAddress", {}).get("address", "")
                if "resmed" not in sender.lower():
                    continue
                
                subject = msg.get("subject", "")
                body = msg.get("bodyPreview", "")
                otp = _extract_otp(f"{subject}\n{body}")
                
                if otp:
                    # Delete the email
                    msg_id = msg["id"]
                    _graph_delete(f"{GRAPH_API}/me/messages/{msg_id}")
                    print(f"OTP extracted: {otp}", file=sys.stderr)
                    return otp
        except Exception as e:
            print(f"Poll error: {e}", file=sys.stderr)
    
    raise RuntimeError("No OTP found after polling")

def _get_bearer_token(otp: str) -> str:
    """Complete OAuth2 flow."""
    import secrets, hashlib, base64
    
    # Authn
    payload = json.dumps({
        "username": USERNAME,
        "password": PASSWORD,
        "options": {"warnBeforePasswordExpired": True, "multiOptionalFactorEnroll": False}
    }).encode("utf-8")
    req = urllib.request.Request(EU_OKTA_AUTHN_URL, data=payload, headers={"Content-Type": "application/json", "Accept": "application/json"}, method="POST")
    with urllib.request.urlopen(req, timeout=30) as resp:
        data = json.loads(resp.read().decode())
        state_token = data.get("stateToken", "")
        factors = data.get("_embedded", {}).get("factors", [])
        email_factor = next((f for f in factors if f.get("factorType") == "email"), None)
        verify_url = (((email_factor or {}).get("_links") or {}).get("verify") or {}).get("href") or ""
    
    # Verify OTP
    verify_payload = json.dumps({"stateToken": state_token, "passCode": otp}).encode("utf-8")
    verify_req = urllib.request.Request(verify_url, data=verify_payload, headers={"Content-Type": "application/json", "Accept": "application/json"}, method="POST")
    with urllib.request.urlopen(verify_req, timeout=30) as resp:
        verify_data = json.loads(resp.read().decode())
        session_token = verify_data.get("sessionToken", "")
    
    # Authorize
    verifier = base64.urlsafe_b64encode(secrets.token_bytes(48)).decode("ascii").rstrip("=")
    challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode("utf-8")).digest()).decode("ascii").rstrip("=")
    params = {
        "client_id": EU_CLIENT_ID,
        "redirect_uri": EU_REDIRECT_URI,
        "response_type": "code",
        "scope": "openid profile offline_access",
        "state": secrets.token_urlsafe(16),
        "nonce": secrets.token_urlsafe(16),
        "code_challenge": challenge,
        "code_challenge_method": "S256",
        "prompt": "none",
        "sessionToken": session_token,
    }
    auth_url = f"{EU_OKTA_AUTHORIZE_URL}?{urllib.parse.urlencode(params)}"
    req = urllib.request.Request(auth_url, headers={"Accept": "text/html,*/*"}, method="GET")
    opener = urllib.request.build_opener(NoRedirect())
    
    try:
        with opener.open(req, timeout=30) as resp:
            status = resp.status
            location = resp.headers.get("Location", "")
    except urllib.error.HTTPError as e:
        status = e.code
        location = e.headers.get("Location", "")
    
    if status not in (302, 303):
        raise RuntimeError(f"Authorize did not redirect (status {status})")
    
    code = urllib.parse.parse_qs(urllib.parse.urlparse(location).query).get("code", [""])[0]
    if not code:
        raise RuntimeError("Authorize redirect missing code")
    
    # Token exchange
    form = urllib.parse.urlencode({
        "client_id": EU_CLIENT_ID,
        "redirect_uri": EU_REDIRECT_URI,
        "grant_type": "authorization_code",
        "code_verifier": verifier,
        "code": code,
    }).encode("utf-8")
    token_req = urllib.request.Request(EU_OKTA_TOKEN_URL, data=form, headers={"Accept": "application/json", "Content-Type": "application/x-www-form-urlencoded"}, method="POST")
    with urllib.request.urlopen(token_req, timeout=30) as resp:
        token_data = json.loads(resp.read().decode())
        return token_data.get("access_token", "")

def _fetch_cpap_data(bearer: str) -> dict:
    """Fetch CPAP data using bearer token."""
    # TODO: Implement GraphQL query to myAir API
    # For now, return mock data structure
    return {"device": {}, "sleep_records": []}

def main() -> int:
    if not USERNAME or not PASSWORD:
        print("CPAP_MYAIR_USERNAME and CPAP_MYAIR_PASSWORD required", file=sys.stderr)
        return 1
    
    try:
        otp = _get_fresh_otp()
        bearer = _get_bearer_token(otp)
        print(f"Bearer token: {bearer[:50]}...", file=sys.stderr)
        
        # TODO: Fetch actual CPAP data
        print(json.dumps({"ok": True, "bearer": bearer[:20] + "..."}))
        return 0
        
    except Exception as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 1

if __name__ == "__main__":
    raise SystemExit(main())
