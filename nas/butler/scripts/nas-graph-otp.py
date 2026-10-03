#!/usr/bin/env python3
"""Pure stdlib Graph API OTP fetcher for NAS."""

import json
import pathlib
import urllib.parse
import sys

from lib.butler_common import extract_otp, graph_delete, graph_get

TOKEN_CACHE = "/mnt/HD/HD_a2/butler/cron/outlook-mcp-token-cache"
GRAPH_API = "https://graph.microsoft.com/v1.0"

def _get_access_token() -> str:
    cache_path = pathlib.Path(TOKEN_CACHE)
    if not cache_path.exists():
        raise RuntimeError(f"Token cache not found: {TOKEN_CACHE}")
    cache = json.loads(cache_path.read_text())
    for key, token in cache.get("AccessToken", {}).items():
        if "graph.microsoft.com" in key:
            return token["secret"]
    raise RuntimeError("No Graph API access token found in cache")

def _looks_like_myair(sender: str, subject: str) -> bool:
    s = sender.lower()
    subj = subject.lower()
    return (
        "resmed" in s
        or "myair" in s
        or "resmed" in subj
        or "myair" in subj
        or "verification code" in subj
        or "one-time" in subj
        or ("noreply" in s and "resmed" in s)
    )

def main() -> int:
    try:
        token = _get_access_token()
        
        # Build URL with encoded query params
        base_url = f"{GRAPH_API}/me/messages"
        params = urllib.parse.urlencode({
            "$top": "30",
            "$select": "id,subject,sender,bodyPreview,receivedDateTime",
            "$orderby": "receivedDateTime desc",
        })
        url = f"{base_url}?{params}"
        
        data = graph_get(url, token)
        messages = data.get("value", [])
        
        for msg in messages:
            sender = msg.get("sender", {}).get("emailAddress", {}).get("address", "")
            subject = msg.get("subject", "")
            body = msg.get("bodyPreview", "")
            
            if not _looks_like_myair(sender, subject):
                continue
            
            otp = extract_otp(f"{subject}\n{body}")
            if otp:
                msg_id = msg["id"]
                delete_url = f"{GRAPH_API}/me/messages/{msg_id}"
                graph_delete(delete_url, token)
                print(otp)
                return 0
        
        print("No myAir OTP found in recent messages", file=sys.stderr)
        return 1
        
    except Exception as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 2

if __name__ == "__main__":
    raise SystemExit(main())
