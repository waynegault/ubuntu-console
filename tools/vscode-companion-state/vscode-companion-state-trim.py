#!/usr/bin/env python3
"""Bound the Qwen companion's conversation blob inside VS Code's extension state.

WHY THIS EXISTS
    The companion persists its ENTIRE WebView conversation history in ONE
    `globalState` value — key `qwenlm.qwen-code-vscode-ide-companion` — inside the
    profile's state DB.  On this box that value reached 75,342,349 bytes (1006
    conversations, 12,095 messages) and VS Code logged its own warning:

        large extension state detected (extensionId: qwenlm.qwen-code-vscode-ide-companion,
        global: true): 73577.216796875kb.  Consider to use 'storageUri' or
        'globalStorageUri' to store this data on disk instead.

    VS Code serialises extension state wholesale on write and loads that DB at window
    start, so the blob is a per-write and per-startup cost, not just disk.  The durable
    fix is the extension moving the store to disk (QwenLM/qwen-code#14262); until that
    lands, this tool bounds the local copy.  It is the same shape as the transcript
    retention policy, because it is the same problem one store over.

CONTRACT
    no arguments    DRY RUN: print exactly what would be removed, change NOTHING.
    --apply         the ONLY path that writes.  Takes a timestamped backup FIRST, then
                    rewrites the value; re-reads and re-reports afterwards.
    --keep-days N   keep conversations that HAVE MESSAGES and were updated within N days
                    (default 90).  Conversations with no messages are always dropped —
                    measured 2026-10-15: 641 of 1006 held nothing at all.
    --state-dir D   override the auto-detected VS Code user-data dir.
    --backup-dir D  override the backup home (default ~/.llm/backups).
    -h / --help     this text.

PRECONDITION — READ IT
    VS Code must be CLOSED.  The running app caches extension state in memory and
    flushes it, so a write made under a live window can be silently overwritten.  This
    tool cannot see the Windows-side app from inside WSL, so it states the precondition
    and requires --apply rather than pretending it can check.
"""

from __future__ import annotations

import argparse
import gzip
import json
import os
import sqlite3
import sys
import time
from pathlib import Path

KEY = "qwenlm.qwen-code-vscode-ide-companion"
DEFAULT_KEEP_DAYS = 90


def candidate_user_dirs(explicit: str | None = None) -> list[Path]:
    """The VS Code user-data dir(s) to search, most specific first."""
    if explicit:
        return [Path(explicit)]
    dirs = []
    env = os.environ.get("VSCODE_USER_DIR")
    if env:
        dirs.append(Path(env))
    # The Windows app's user dir is where this window's profile actually lives
    # (measured: profileAssociations bind the WSL workspace to a Windows profile).
    for p in (
        Path("/mnt/c/Users/wayne/AppData/Roaming/Code/User"),
        Path("/mnt/c/Users/wayne/AppData/Roaming/Code - Insiders/User"),
        Path.home() / ".vscode-server/data/User",
    ):
        if p.is_dir():
            dirs.append(p)
    return dirs


def state_dbs(user_dir: Path) -> list[Path]:
    """Every state.vscdb under a user dir, profile ones included."""
    found = []
    top = user_dir / "globalStorage/state.vscdb"
    if top.is_file():
        found.append(top)
    profiles = user_dir / "profiles"
    if profiles.is_dir():
        found.extend(sorted(profiles.glob("*/globalStorage/state.vscdb")))
    return found


def read_blob(db: Path) -> bytes | None:
    """The raw value, or None when this DB cannot hold the key at all."""
    conn = sqlite3.connect(f"file:{db}?mode=ro", uri=True, timeout=10)
    try:
        have = conn.execute(
            "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'ItemTable'"
        ).fetchone()
        if have is None:
            # e.g. the remote server's state.vscdb can exist at 0 bytes with no tables;
            # a DB without ItemTable holds no extension state, which is not an error.
            return None
        row = conn.execute("SELECT value FROM ItemTable WHERE key = ?", (KEY,)).fetchone()
    finally:
        conn.close()
    if row is None:
        return None
    value = row[0]
    return value if isinstance(value, (bytes, bytearray)) else str(value).encode()


def split(state: dict, keep_days: int, now_ms: float) -> tuple[list, list]:
    """(keep, drop) under the stated rule.  Pure — the selftest drives this."""
    cutoff = now_ms - keep_days * 86_400_000
    keep, drop = [], []
    for conv in state.get("conversations", []) or []:
        has_messages = bool(conv.get("messages"))
        recent = float(conv.get("updatedAt") or 0) >= cutoff
        (keep if (has_messages and recent) else drop).append(conv)
    return keep, drop


def projected(state: dict, keep: list) -> bytes:
    """Exactly what --apply would store: the state with `conversations` replaced."""
    out = dict(state)
    out["conversations"] = keep
    return json.dumps(out, separators=(",", ":")).encode()


def describe(state: dict, keep: list, drop: list, before: int) -> str:
    after = len(projected(state, keep))
    lines = [
        f"  conversations: {len(keep) + len(drop)} -> {len(keep)}  (dropping {len(drop)})",
        f"  bytes:         {before:,} -> {after:,}  (reclaiming {before - after:,})",
        "  by rule:       kept = has messages AND updated within the window;",
        f"                 dropped = empty or older ({len(drop)} here)",
    ]
    return "\n".join(lines)


def apply_trim(db: Path, state: dict, keep: list, backup_dir: Path) -> dict:
    """Back up, rewrite the value, then re-read.  Returns a result summary."""
    backup_dir.mkdir(parents=True, exist_ok=True)
    stamp = time.strftime("%Y%m%d-%H%M%S")
    backup = backup_dir / f"companion-conversations-{stamp}.json.gz"
    with gzip.open(backup, "wb") as fh:
        fh.write(json.dumps(state, separators=(",", ":")).encode())
    payload = projected(state, keep)
    conn = sqlite3.connect(db, timeout=20)
    try:
        conn.execute("UPDATE ItemTable SET value = ? WHERE key = ?", (payload, KEY))
        conn.commit()
    finally:
        conn.close()
    fresh = read_blob(db)
    after = json.loads(fresh) if fresh else {}
    return {
        "backup": backup,
        "wrote": len(payload),
        "after_bytes": len(fresh or b""),
        "after_conversations": len(after.get("conversations", []) or []),
    }


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(
        prog="vscode-companion-state-trim.py",
        description="Bound the companion's conversation blob in VS Code extension state.",
    )
    ap.add_argument("--apply", action="store_true", help="write the trim (backup taken first)")
    ap.add_argument("--keep-days", type=int, default=DEFAULT_KEEP_DAYS,
                    help=f"keep conversations with messages updated within N days (default {DEFAULT_KEEP_DAYS})")
    ap.add_argument("--state-dir", default=None, help="VS Code user-data dir")
    ap.add_argument("--backup-dir", default=os.path.expanduser("~/.llm/backups"))
    args = ap.parse_args(argv)

    user_dirs = candidate_user_dirs(args.state_dir)
    targets = [(d, db) for d in user_dirs for db in state_dbs(d)]
    if not targets:
        print("no state.vscdb found; searched:", ", ".join(str(d) for d in user_dirs), file=sys.stderr)
        return 2

    now_ms = time.time() * 1000
    print(f"mode: {'APPLY' if args.apply else 'DRY RUN (nothing will be written)'}")
    print(f"rule: keep conversations with messages updated within {args.keep_days} days; drop empty ones")
    if args.apply:
        print("PRECONDITION: VS Code must be CLOSED — a live window can overwrite this write.")
    print()

    rc = 0
    for _user_dir, db in targets:
        blob = read_blob(db)
        if blob is None:
            print(f"{db}\n  (no ItemTable or no such key — nothing to do)")
            print()
            continue
        state = json.loads(blob)
        keep, drop = split(state, args.keep_days, now_ms)
        print(f"{db}")
        print(describe(state, keep, drop, len(blob)))
        if not drop:
            print("  nothing to do — already within the rule")
            print()
            continue
        if args.apply:
            res = apply_trim(db, state, keep, Path(args.backup_dir))
            print(f"  backup:        {res['backup']} "
                  f"({res['backup'].stat().st_size:,} bytes gz)")
            print(f"  after re-read: {res['after_bytes']:,} bytes, "
                  f"{res['after_conversations']} conversations")
            if res["after_conversations"] != len(keep):
                print("  MISMATCH: the re-read disagrees with the write — investigate", file=sys.stderr)
                rc = 1
        else:
            print("  (dry run — pass --apply with VS Code closed to write this)")
        print()
    return rc


if __name__ == "__main__":
    sys.exit(main())
