#!/usr/bin/env python3
"""Read MyAir OTP from Outlook IMAP with OAuth2/Modern Auth.

Extracts 6-8 digit OTP from ResMed myAir emails and deletes the email after extraction.
"""

from __future__ import annotations

import datetime
import imaplib
import logging
import os
import re
import ssl
import sys
from datetime import timezone

logger = logging.getLogger(__name__)


def _env(key: str, default: str = "") -> str:
    return os.environ.get(key, default)


def _extract_otp(text: str) -> str | None:
    match = re.search(r"\b(\d{6,8})\b", text)
    return match.group(1) if match else None


def _iter_message_text(msg) -> str:
    parts = []
    if msg.is_multipart():
        for part in msg.walk():
            content_type = part.get_content_type()
            if content_type == "text/plain" or content_type == "text/html":
                try:
                    payload = part.get_payload(decode=True)
                    if payload:
                        parts.append(payload.decode("utf-8", errors="replace"))
                except Exception:
                    # One undecodable MIME part is skipped; the message may still
                    # carry the OTP in another part.  Name it so a failure to find
                    # the code can be diagnosed against the raw message.
                    logger.debug("skipping an undecodable MIME part (%s)", content_type, exc_info=True)
    else:
        try:
            payload = msg.get_payload(decode=True)
            if payload:
                parts.append(payload.decode("utf-8", errors="replace"))
        except Exception:
            # Same: a single-part message that will not decode yields no text, and
            # the caller reports "No OTP found" rather than crashing.
            logger.debug("single-part message body could not be decoded", exc_info=True)
    return "\n".join(parts)


def _search_criteria() -> str:
    sender = _env("CPAP_MYAIR_OTP_IMAP_FROM", "")
    subject = _env("CPAP_MYAIR_OTP_IMAP_SUBJECT", "One-time verification code")
    unseen = _env("CPAP_MYAIR_OTP_IMAP_UNSEEN_ONLY", "1") == "1"

    terms: list[str] = []
    if unseen:
        terms.append("UNSEEN")
    if sender:
        terms.extend(["FROM", f'"{sender}"'])
    if subject:
        terms.extend(["SUBJECT", f'"{subject}"'])

    if not terms:
        return "ALL"
    return " ".join(terms)


def main() -> int:
    host = _env("CPAP_MYAIR_OTP_IMAP_HOST", "outlook.office365.com")
    port = int(_env("CPAP_MYAIR_OTP_IMAP_PORT", "993"))
    user = _env("CPAP_MYAIR_OTP_IMAP_USER", "")
    password = _env("CPAP_MYAIR_OTP_IMAP_PASSWORD", "")
    mailbox = _env("CPAP_MYAIR_OTP_IMAP_MAILBOX", "INBOX")
    sender_pattern = _env("CPAP_MYAIR_OTP_IMAP_FROM", "")
    subject_pattern = _env("CPAP_MYAIR_OTP_IMAP_SUBJECT", "One-time verification code")

    if not user or not password:
        print("IMAP credentials not configured", file=sys.stderr)
        return 1

    try:
        ctx = ssl.create_default_context()
        with imaplib.IMAP4_SSL(host, port, ssl_context=ctx) as conn:
            conn.login(user, password)
            status, _ = conn.select(mailbox)
            if status != "OK":
                print(f"Failed to open mailbox {mailbox}", file=sys.stderr)
                return 2

            criteria = _search_criteria()
            status, data = conn.search(None, criteria)
            if status != "OK" or not data or not data[0]:
                print("No OTP email match found", file=sys.stderr)
                return 3

            ids = data[0].split()
            for msg_id in reversed(ids):
                status, msg_data = conn.fetch(msg_id, "(RFC822)")
                if status != "OK" or not msg_data:
                    continue

                for part in msg_data:
                    if not isinstance(part, tuple) or len(part) < 2:
                        continue
                    import email
                    msg = email.message_from_bytes(part[1])
                    subj_hdr = msg.get("Subject", "")
                    from_hdr = msg.get("From", "")

                    if sender_pattern and not re.search(sender_pattern, from_hdr, flags=re.IGNORECASE):
                        continue
                    if subject_pattern and not re.search(subject_pattern, subj_hdr, flags=re.IGNORECASE):
                        continue

                    body = _iter_message_text(msg)
                    otp = _extract_otp(f"{subj_hdr}\n{body}")
                    if otp:
                        conn.store(msg_id, "+FLAGS", "\\Deleted")
                        conn.expunge()
                        print(otp)
                        return 0

            print("No OTP found in matching emails", file=sys.stderr)
            return 4

    except imaplib.IMAP4.error as exc:
        print(f"IMAP error: {exc}", file=sys.stderr)
        return 5
    except Exception as exc:
        now = datetime.datetime.now(timezone.utc).isoformat()
        print(f"Unexpected error at {now}: {exc}", file=sys.stderr)
        return 6


if __name__ == "__main__":
    raise SystemExit(main())
