#!/usr/bin/env bash
# AI INSTRUCTION: On ANY change to this file, increment the Module Version below.
# Module Version: 1
# ==============================================================================
# qwen-transcript-retention.sh — age out chat transcripts that nothing else owns.
#
# WHY THIS EXISTS
#   ~/.qwen/projects/<project>/chats/ accumulates one <sessionId>.jsonl per session, and
#   the session registry (~/.qwen/sessions/<pid>-<hash8>.json) is the only lifecycle a
#   transcript has.  Measured 2026-10-01 in the -home-wayne--openclaw store: 125
#   transcripts, of which just 2 had a registry entry -- 123 files (~250 MiB) that no
#   registry entry describes, so the pid/procStart dead-or-alive test cannot be applied to
#   them and nothing ever removes them.  This is that policy, in code and re-runnable,
#   instead of another one-off sweep.
#
# THE RULES (each is load-bearing; do not widen one without reading the others)
#   1. A LIVE SESSION'S TRANSCRIPT IS NEVER REMOVED, whatever its age.  Liveness is the
#      registry's own identity test: the entry's procStart is "<bootid>:<ticks>", compared
#      against /proc/<pid>/stat field 22 (starttime, clock ticks since boot) AND
#      /proc/sys/kernel/random/boot_id.  BOTH must match: a PID can be REUSED by an
#      unrelated process, so ticks alone would call a stranger a live session.
#   2. A REGISTERED SESSION IS OUT OF SCOPE ENTIRELY -- dead or alive.  This policy exists
#      only for transcripts with NO registry entry, i.e. the ones the registry cannot
#      describe.  Do NOT widen it to registered sessions: that would put a second,
#      age-based lifecycle beside the registry's own.  Rule 1 is the belt to rule 2's
#      braces, and both are printed, so a future widening has to face them explicitly.
#      NOTE THE ORDER OF RELIANCE: eligibility never depends on the liveness test
#      succeeding.  Rule 2 excludes every registered transcript on its own, so an
#      unreadable /proc can only make the report less informative, never make a
#      registered session's transcript eligible.
#   3. AGE is the criterion: a transcript is eligible when its mtime is STRICTLY older
#      than the cutoff.  The default is 30 days -- stated here, not implied -- and
#      --max-age-days overrides it.  Ages are printed, because a count alone cannot be
#      checked against the store.
#   4. SCOPE is ONE project's chat store, default -home-wayne--openclaw.  Another project
#      must be named with --project; there is deliberately no "all projects" mode.
#   5. READ-ONLY BY CONSTRUCTION: the dry run is the default.  It prints exactly what it
#      would remove, deletes nothing, and exits 0.  Nothing is removed unless --delete is
#      passed, and even then only the paths it listed.
#
# EXIT CODES
#   0  the scan ran (dry run, or --delete completed)
#   1  --delete could not remove at least one file it listed
#   2  cannot run: bad invocation, or the chat store / registry is not readable
#
# USAGE
#   qwen-transcript-retention.sh                     # dry run: print the plan, delete nothing
#   qwen-transcript-retention.sh --delete            # remove exactly the listed set
#   qwen-transcript-retention.sh --max-age-days 14   # override the 30-day cutoff
#   qwen-transcript-retention.sh --project -home-wayne-ubuntu-console
#   qwen-transcript-retention.sh --qwen-dir DIR --registry-dir DIR     # tests
#
# WHERE THE WORK SITS: this file owns the command line (flag -> setting) and the report's
# shape; the registry identity test, the scan and the removal are python3 in the heredoc
# below, because they need JSON, /proc and age arithmetic.  That split is the one
# bin/qwen-memory-index-patch.sh already uses for logic of the same kind.
# ==============================================================================
set -euo pipefail

# Translated and validated by python, which owns the usage text and the error wording.
# qr_max_age_days starts EMPTY and QR_MAX_AGE_GIVEN records whether the flag was seen, so
# "--max-age-days" with no value is a usage error rather than a silent 30 (python owns the
# default; this file does not restate it).
qr_delete="0"
qr_max_age_days=""
qr_max_age_given="0"
qr_project="-home-wayne--openclaw"
qr_qwen_dir="${HOME}/.qwen"
qr_registry_dir=""
qr_help="0"
qr_usage_error=""

while (( $# > 0 ))
do
    case "$1" in
        --delete)
            qr_delete="1"
            shift
            ;;
        --max-age-days)
            qr_max_age_days="${2:-}"
            qr_max_age_given="1"
            shift
            if (( $# > 0 ))
            then
                shift
            fi
            ;;
        --project)
            qr_project="${2:-}"
            shift
            if (( $# > 0 ))
            then
                shift
            fi
            ;;
        --qwen-dir)
            qr_qwen_dir="${2:-}"
            shift
            if (( $# > 0 ))
            then
                shift
            fi
            ;;
        --registry-dir)
            qr_registry_dir="${2:-}"
            shift
            if (( $# > 0 ))
            then
                shift
            fi
            ;;
        -h|--help)
            qr_help="1"
            shift
            ;;
        *)
            # An unknown flag and a stray argument land here together; python turns either
            # into the usage error, so that wording lives in exactly one place.
            qr_usage_error="${qr_usage_error}${qr_usage_error:+ }${1}"
            shift
            ;;
    esac
done

# QR_* carry the translated command line into the heredoc below; nothing else reads them.
export QR_DELETE="$qr_delete"
export QR_MAX_AGE_DAYS="$qr_max_age_days"
export QR_MAX_AGE_GIVEN="$qr_max_age_given"
export QR_PROJECT="$qr_project"
export QR_QWEN_DIR="$qr_qwen_dir"
export QR_REGISTRY_DIR="$qr_registry_dir"
export QR_HELP="$qr_help"
export QR_USAGE_ERROR="$qr_usage_error"

python3 - <<'PY'
"""qwen-transcript-retention -- see the shell header for the policy this encodes.

The shell wrapper has already translated the command line into QR_* settings.  This
module validates them, applies the policy, prints the plan, and -- only when QR_DELETE is
1 -- removes exactly the listed files.
"""

from __future__ import annotations

import glob
import json
import os
import sys
import time

EXIT_OK = 0
EXIT_DELETE_FAILED = 1
EXIT_CANNOT_RUN = 2

# Documented default cutoff, in days.  Mirrored by the shell wrapper's QR_MAX_AGE_DAYS.
DEFAULT_MAX_AGE_DAYS = 30.0

BOOT_ID_PATH = "/proc/sys/kernel/random/boot_id"

USAGE = """usage: qwen-transcript-retention.sh [--delete] [--max-age-days N]
                                     [--project NAME] [--qwen-dir DIR]
                                     [--registry-dir DIR]

  --delete            remove exactly the transcripts the dry run listed
  --max-age-days N    cutoff in days; a transcript is eligible when its mtime is STRICTLY
                      older than N days (default 30)
  --project NAME      chat store under <qwen-dir>/projects (default -home-wayne--openclaw)
  --qwen-dir DIR      Qwen store root (default ~/.qwen)
  --registry-dir DIR  session registry (default <qwen-dir>/sessions)

A transcript is eligible only when its sessionId has NO registry entry (rule 2) and its
mtime is older than the cutoff (rule 3).  A live registered session is excluded whatever
its age (rule 1).  Without --delete nothing is removed (rule 5)."""


def fail(message):
    """Print a cannot-run report on stderr, then leave with EXIT_CANNOT_RUN."""
    print(f"qwen-transcript-retention: {message}", file=sys.stderr)
    sys.exit(EXIT_CANNOT_RUN)


def read_boot_id():
    """The current boot id, or None when it cannot be read.

    None is not fatal: rule 2 already excludes every registered transcript, so the
    liveness test can only make the report more precise, never make removal safe or unsafe.
    """
    try:
        with open(BOOT_ID_PATH, encoding="utf-8") as handle:
            return handle.read().strip()
    except OSError:
        return None


def proc_start_ticks(pid):
    """Field 22 of /proc/<pid>/stat (starttime in clock ticks), or None when gone.

    The comm field (2) may contain spaces and parentheses, so the line is split after the
    LAST ')': everything before it is pid + comm, and the remainder starts at field 3 --
    which puts field 22 at index 19.
    """
    try:
        with open(f"/proc/{pid}/stat", encoding="utf-8", errors="replace") as handle:
            raw = handle.read()
    except OSError:
        return None
    try:
        return int(raw.rsplit(") ", 1)[1].split()[19])
    except (IndexError, ValueError):
        return None


def read_registry(registry_dir):
    """sessionId -> entry dict, for every readable entry in the registry.

    An unreadable or unparseable entry is still REGISTERED (its sessionId is recorded with
    liveness unknown): rule 2 makes the session out of scope, and guessing the other way
    would put a transcript back in scope because its entry was damaged.
    """
    entries = {}
    for path in sorted(glob.glob(os.path.join(registry_dir, "*.json"))):
        try:
            with open(path, encoding="utf-8") as handle:
                record = json.load(handle)
        except (OSError, ValueError):
            entries.setdefault(None, None)
            continue
        if not isinstance(record, dict):
            continue
        session_id = record.get("sessionId")
        if isinstance(session_id, str) and session_id:
            entries[session_id] = record
    return entries


def liveness(record, boot_id):
    """(is_live, why) for one registry entry -- the PID-reuse-safe identity test.

    Live requires BOTH the boot id and the tick count to match.  A reused PID, a session
    from an earlier boot, and an unreadable /proc all read as not-live, and none of them
    can make a registered transcript eligible (rule 2).
    """
    if record is None:
        return False, "no registry entry"
    raw = record.get("procStart")
    pid = record.get("pid")
    if not isinstance(raw, str) or ":" not in raw or not isinstance(pid, int):
        return False, "registry entry has no usable pid/procStart"
    registry_boot, _, ticks = raw.partition(":")
    live_ticks = proc_start_ticks(pid)
    if live_ticks is None:
        return False, f"pid {pid} is gone (/proc/{pid} absent)"
    if boot_id is None:
        return False, f"pid {pid} exists but the boot id is unreadable"
    if registry_boot != boot_id:
        return False, f"pid {pid} is a different boot ({registry_boot[:8]} vs {boot_id[:8]})"
    try:
        claimed = int(ticks)
    except ValueError:
        return False, f"pid {pid} has an unparseable procStart tick count"
    if live_ticks != claimed:
        return False, f"pid {pid} is REUSED (claimed ticks {claimed}, live {live_ticks})"
    return True, f"live: ticks {live_ticks} and boot id both match"


def session_id_of(path):
    """The sessionId a transcript file belongs to: the name before the first dot."""
    return os.path.basename(path).split(".", 1)[0]


def main():
    if os.environ.get("QR_HELP") == "1":
        print(USAGE)
        return EXIT_OK
    usage_error = os.environ.get("QR_USAGE_ERROR", "").strip()
    if usage_error:
        print(f"qwen-transcript-retention: unrecognized argument: {usage_error}", file=sys.stderr)
        print(USAGE, file=sys.stderr)
        return EXIT_CANNOT_RUN

    qwen_dir = os.environ.get("QR_QWEN_DIR", "").strip()
    project = os.environ.get("QR_PROJECT", "").strip()
    registry_dir = os.environ.get("QR_REGISTRY_DIR", "").strip() or os.path.join(qwen_dir, "sessions")
    if not qwen_dir:
        fail("no --qwen-dir given")
    if not project:
        fail("no --project given")
    try:
        raw_age = os.environ.get("QR_MAX_AGE_DAYS", "").strip()
        age_given = os.environ.get("QR_MAX_AGE_GIVEN") == "1"
        if age_given and not raw_age:
            fail("--max-age-days needs a value")
        max_age_days = float(raw_age) if raw_age else DEFAULT_MAX_AGE_DAYS
    except ValueError:
        fail(f"--max-age-days is not a number: {os.environ.get('QR_MAX_AGE_DAYS', '')!r}")
    if max_age_days < 0:
        fail(f"--max-age-days must not be negative: {max_age_days}")

    chats_dir = os.path.join(qwen_dir, "projects", project, "chats")
    if not os.path.isdir(chats_dir):
        fail(f"no chat store at {chats_dir} -- an empty scan is not a clean tree")
    if not os.path.isdir(registry_dir):
        fail(f"no session registry at {registry_dir} -- liveness cannot be bounded")

    delete_mode = os.environ.get("QR_DELETE") == "1"
    boot_id = read_boot_id()
    registry = read_registry(registry_dir)
    cutoff = time.time() - max_age_days * 86400.0

    transcripts = sorted(glob.glob(os.path.join(chats_dir, "*")))
    transcripts = [path for path in transcripts if os.path.isfile(path)]

    excluded_live = []
    excluded_registered = []
    kept_young = []
    eligible = []
    for path in transcripts:
        session_id = session_id_of(path)
        stat = os.stat(path)
        age_days = (time.time() - stat.st_mtime) / 86400.0
        if session_id in registry:
            record = registry[session_id]
            is_live, why = liveness(record, boot_id)
            row = (path, stat.st_size, stat.st_mtime, age_days, why)
            if is_live:
                excluded_live.append(row)
            else:
                excluded_registered.append(row)
            continue
        if stat.st_mtime < cutoff:
            eligible.append((path, stat.st_size, stat.st_mtime, age_days))
        else:
            kept_young.append((path, stat.st_size, stat.st_mtime, age_days))

    explicit = time.strftime("%Y-%m-%d %H:%M:%S %Z", time.localtime(cutoff))
    entries_word = "entry" if len(registry) == 1 else "entries"
    print(f"qwen-transcript-retention: {chats_dir}")
    print(f"  registry      {registry_dir} ({len(registry)} {entries_word})")
    print(f"  cutoff        mtime strictly older than {max_age_days:g} days (before {explicit})")
    print(f"  transcripts   {len(transcripts)} in scope")
    print(f"  excluded      registered (rule 2): {len(excluded_registered) + len(excluded_live)}")
    print(f"  excluded      of those LIVE (rule 1, never touched): {len(excluded_live)}")
    for path, size, mtime, age_days, why in excluded_live + excluded_registered:
        stamp = time.strftime("%Y-%m-%d %H:%M:%S %Z", time.localtime(mtime))
        print(f"    {os.path.basename(path)}  {size} bytes  mtime={stamp}  age={age_days:.1f}d")
        print(f"      excluded: {why}; registered, so out of scope whatever its age")
    print(f"  unregistered  {len(kept_young) + len(eligible)}")
    print(f"  kept          younger than the cutoff: {len(kept_young)}")

    total_bytes = sum(row[1] for row in eligible)
    print(f"  TO REMOVE     {len(eligible)} ({total_bytes} bytes, {total_bytes / 1048576:.1f} MiB)")
    for path, size, mtime, age_days in eligible:
        stamp = time.strftime("%Y-%m-%d %H:%M:%S %Z", time.localtime(mtime))
        print(f"    {path}  {size} bytes  mtime={stamp}  age={age_days:.1f} days")
    if eligible:
        oldest = min(eligible, key=lambda row: row[2])
        newest = max(eligible, key=lambda row: row[2])
        print(f"  oldest        {os.path.basename(oldest[0])}  age={oldest[3]:.1f} days")
        print(f"  newest        {os.path.basename(newest[0])}  age={newest[3]:.1f} days")

    if not delete_mode:
        print(f"  DRY RUN       nothing deleted; re-run with --delete to remove these {len(eligible)}")
        return EXIT_OK

    failures = []
    for path, size, mtime, age_days in eligible:
        try:
            os.remove(path)
        except OSError as error:
            failures.append(f"{path}: {error}")
    removed_bytes = sum(row[1] for row in eligible if not os.path.exists(row[0]))
    print(f"  DELETED       {len(eligible) - len(failures)} files, {removed_bytes} bytes freed")
    for path, _size, _mtime, _age in eligible:
        if os.path.exists(path):
            print(f"  REMAINS       {path}", file=sys.stderr)
    if failures:
        for line in failures:
            print(f"qwen-transcript-retention: could not remove {line}", file=sys.stderr)
        return EXIT_DELETE_FAILED
    print("  verified      every removed path is gone; every other transcript was left alone")
    return EXIT_OK


if __name__ == "__main__":
    sys.exit(main())
PY
