#!/usr/bin/env python3
"""autotune-resume-quiet-gate.py — do not arm a restart while an agent turn is RUNNING.

Wayne's 2026-10-19 decision: the autotune restart loop must require a QUIET FLEET (no live agent
turns) in addition to a clear CI queue.

VERSIONED HERE 2026-10-19 (Wayne: "version the quiet-gate into ubuntu-console with a test"). It was
written as machine-local code at ~/.openclaw/bin/autotune-resume-quiet-gate.py, where nothing could
test it; that path is now a symlink to this file so no caller changes meaning.

SOURCE OF TRUTH: `session_windows.status` in each agent's `openclaw-agent.sqlite` — the scheduler's
own window state, not an activity heuristic. An earlier version inferred a live turn from `ageMs` in
`openclaw sessions list --json`; that projection has no status field (measured 2026-10-19), so a
session idle for 30 s read as quiet while a turn was still running.

STALENESS, not activity. `status='running'` alone is not enough: a turn that dies before the
scheduler closes its row leaves it `running` for ever. Measured 2026-10-19 — the hal agent carried
three such rows (all `Automation:` cron sessions) whose `updated_at` was 2026-09-01, 2026-09-04 and
2026-09-10, i.e. 39-48 days old, and this gate held the autotune campaign in front of a fleet that
had been quiet for six weeks. Reading status alone, it could never clear. So a row whose last write
is older than FLEET_STALE_AFTER_S (6 h — no agent turn here runs for hours, let alone a day) is
IGNORED and NAMED on stderr: an orphaned row is a scheduler defect worth seeing, not noise to hide.

A probe that cannot answer (no agent DBs, unreadable DB, missing table) REFUSES to arm — fail closed.
"Could not ask" is never read as "quiet".

Modes: (default) wait until quiet, then exec the real resume script; --check one probe only
(0 quiet, 1 busy, 2 probe failure).

Seams (pinned by tests/unit/66-autotune-quiet-gate.bats):
    FLEET_AGENT_DB_GLOB   which agent databases to read
    FLEET_STALE_AFTER_S   the staleness bound, in seconds
    FLEET_POLL_SECONDS    the wait interval in the default mode
    AUTOTUNE_RESUME_SCRIPT  what this execs once the fleet is quiet
"""
from __future__ import annotations

import glob
import os
import sqlite3
import sys
import time

REAL = os.environ.get("AUTOTUNE_RESUME_SCRIPT", os.path.expanduser("~/.local/bin/autotune-resume.sh"))
POLL_SECONDS = int(os.environ.get("FLEET_POLL_SECONDS", "60"))
STALE_AFTER_S = int(os.environ.get("FLEET_STALE_AFTER_S", str(6 * 3600)))
AGENT_DB_GLOB = os.environ.get(
    "FLEET_AGENT_DB_GLOB",
    os.path.expanduser("~/.openclaw/agents/*/agent/openclaw-agent.sqlite"),
)


def _agent_name(db_path: str) -> str:
    parts = db_path.split(os.sep)
    try:
        return parts[parts.index("agents") + 1]
    except (ValueError, IndexError):
        return "?"


def probe() -> tuple[int, list[str]]:
    """Return (verdict, busy_keys): 0 quiet, 1 busy, 2 probe failure."""
    dbs = sorted(glob.glob(AGENT_DB_GLOB))
    if not dbs:
        print(f"[quiet-gate] no agent DBs match {AGENT_DB_GLOB}", file=sys.stderr)
        return 2, []  # "could not ask" is a refusal to arm, never "quiet"

    now_ms = time.time() * 1000.0
    busy: list[str] = []
    stale: list[str] = []
    for db in dbs:
        try:
            con = sqlite3.connect(f"file:{db}?mode=ro", uri=True, timeout=5)
            try:
                rows = con.execute(
                    "select session_key, updated_at, created_at from session_windows"
                    " where status='running'"
                ).fetchall()
            finally:
                con.close()
        except sqlite3.Error as exc:
            print(f"[quiet-gate] cannot read {db}: {exc}", file=sys.stderr)
            return 2, []  # unreadable DB is a refusal to arm, never "quiet"
        for key, updated_at, created_at in rows:
            last = updated_at or created_at or 0
            age_s = (now_ms - last) / 1000.0 if last else float("inf")
            name = f"{_agent_name(db)}:{key}"
            if age_s > STALE_AFTER_S:
                stale.append(f"{name} ({(age_s / 86400):.0f}d)")
            else:
                busy.append(name)

    if stale:
        # Named, not silently dropped: an orphaned row is a scheduler defect worth seeing.
        print(
            f"[quiet-gate] IGNORING {len(stale)} STALE window(s) — status=running but last"
            f" update > {STALE_AFTER_S // 3600}h: {', '.join(stale[:6])}",
            file=sys.stderr,
        )

    return (1 if busy else 0), busy


def main() -> int:
    check_only = "--check" in sys.argv
    args = [a for a in sys.argv[1:] if a != "--check"]

    while True:
        verdict, busy = probe()
        if verdict == 0:
            print("[quiet-gate] fleet is quiet (no session_windows.status='running')", file=sys.stderr)
            if check_only:
                return 0
            # execv replaces this process: the resume script inherits the unit's journal stream.
            os.execv(REAL, [REAL, *args])
        if verdict == 2:
            print("[quiet-gate] REFUSING to arm: the fleet probe could not answer", file=sys.stderr)
            return 2  # exit 2 is the probe-failure contract (see module docstring)
        print(
            f"[quiet-gate] {len(busy)} running turn(s): {', '.join(busy[:6])}; waiting {POLL_SECONDS}s",
            file=sys.stderr,
        )
        if check_only:
            return 1
        time.sleep(POLL_SECONDS)


if __name__ == "__main__":
    sys.exit(main())
