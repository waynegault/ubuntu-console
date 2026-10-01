#!/usr/bin/env bash
# AI INSTRUCTION: On ANY change to this file, increment the Module Version below.
# Module Version: 2
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
#   1. A LIVE SESSION IS NEVER TOUCHED, whatever its age.  Liveness is the registry's own
#      identity test: the entry's procStart is "<bootid>:<ticks>", compared against
#      /proc/<pid>/stat field 22 (starttime, clock ticks since boot) AND
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
#   3. AGE is the criterion: a unit is eligible when its newest mtime is STRICTLY older
#      than the cutoff.  The default is 60 days -- Wayne's decision of 2026-10-01, and
#      stated here rather than implied -- and --max-age-days overrides it.  Ages are
#      printed, because a count alone cannot be checked against the store.
#   4. SCOPE is ONE project's store, default -home-wayne--openclaw.  Another project must be
#      named with --project; there is deliberately no "all projects" mode.
#   5. READ-ONLY BY CONSTRUCTION: the dry run is the default.  It prints exactly what it
#      would remove, deletes nothing, and exits 0.  Nothing is removed unless --delete is
#      passed, and even then only the paths it listed.
#   6. IN-FLIGHT IS NEVER ELIGIBLE: a unit whose newest mtime falls inside GRACE_HOURS
#      (24 h) is excluded whatever the cutoff.  MEASURED 2026-10-01: appending to a
#      transcript refreshes its mtime, and a running subagent call keeps writing its
#      .stream, so a unit's newest mtime is fresh for as long as it is being written.  This
#      rule -- not the cutoff -- is what protects a write in progress, which is why it is
#      separate from it and still holds at --max-age-days 0.
#
# TWO STORES, ONE POLICY (--store chats|subagents)
#   chats      <project>/chats/<sessionId>.jsonl
#              one file per unit; the file name carries the sessionId, so rules 1-2 key on
#              it directly.
#   subagents  <project>/subagents/<parentSessionId>/<agent>-<callid>.{jsonl,meta.json,stream}
#              one CALL per unit, keyed by the PARENT SESSION -- the directory the files sit
#              in.  A subagent file is named after the agent kind and a call id and NEVER
#              after a session, so without that directory there is no link to a session at
#              all.  A unit is its transcript, its .meta.json sidecar and its .stream
#              partial together: written as one call, aged by the NEWEST of the three (so a
#              live .stream pins the whole call fresh), and removed as one unit -- deleting
#              a transcript while leaving its sidecar would leave the store inconsistent.
#   RULE 2 IS NEARLY VACUOUS FOR subagents -- stated, not hidden.  MEASURED 2026-10-01: the
#   registry holds LIVE sessions only (6 entries, all live), so a subagent directory whose
#   session is registered is registered-AND-LIVE, i.e. rule 2 excludes it only where rule 1
#   already does.  A finished session's entry is gone, and there is nothing else of that
#   session to match, so for subagents rule 2 excludes nothing on its own.
#   WHAT ACTUALLY PROTECTS A RUNNING SESSION'S SUBAGENTS, therefore, is rule 1 while its
#   registry entry exists, and RULE 6 (the in-flight window) as the independent backstop.
#   That is measured, not assumed -- appending to a subagent file refreshes its mtime, and
#   tests/unit/37-transcript-retention.bats pins both paths.
#
# EXIT CODES
#   0  the scan ran (dry run, or --delete completed)
#   1  --delete could not remove at least one file it listed
#   2  cannot run: bad invocation, or the chat store / registry is not readable
#
# USAGE
#   qwen-transcript-retention.sh                     # dry run: print the plan, delete nothing
#   qwen-transcript-retention.sh --delete            # remove exactly the listed set
#   qwen-transcript-retention.sh --max-age-days 14   # override the 60-day cutoff
#   qwen-transcript-retention.sh --store subagents   # the subagent store instead of chats
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
# "--max-age-days" with no value is a usage error rather than a silent default (python owns
# the default; this file does not restate it).
qr_delete="0"
qr_max_age_days=""
qr_max_age_given="0"
qr_store=""
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
        --store)
            qr_store="${2:-}"
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
export QR_STORE="$qr_store"
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

# Documented default cutoff, in days.  Wayne's decision, 2026-10-01: 60, over the 30-day
# floor this tool first shipped with.  Used when --max-age-days is not given.
DEFAULT_MAX_AGE_DAYS = 60.0

# The in-flight guard, in hours: a unit whose newest mtime is inside this window is NEVER
# eligible, whatever the cutoff.  MEASURED 2026-10-01: appending to a transcript refreshes
# its mtime, and a running subagent call keeps writing its .stream, so a write in progress
# cannot be swept.  It is a separate rule from the cutoff on purpose -- it still holds at
# --max-age-days 0 -- and it is what makes it safe to age .stream partials out at all.
GRACE_HOURS = 24.0

STORE_CHATS = "chats"
STORE_SUBAGENTS = "subagents"
STORES = (STORE_CHATS, STORE_SUBAGENTS)
# The three shapes a subagent unit is made of.  A unit is ONE call: its .jsonl transcript,
# the .meta.json sidecar written beside it, and its in-flight .stream partial (if any).
SUBAGENT_SUFFIXES = (".jsonl", ".meta.json", ".stream")

BOOT_ID_PATH = "/proc/sys/kernel/random/boot_id"

USAGE = """usage: qwen-transcript-retention.sh [--delete] [--max-age-days N]
                                     [--store chats|subagents] [--project NAME]
                                     [--qwen-dir DIR] [--registry-dir DIR]

  --delete            remove exactly the transcripts the dry run listed
  --max-age-days N    cutoff in days; a unit is eligible when its newest mtime is STRICTLY
                      older than N days (default 60)
  --store KIND        chats (default) or subagents -- see the header for how they differ
  --project NAME      store under <qwen-dir>/projects/<NAME> (default -home-wayne--openclaw)
  --qwen-dir DIR      Qwen store root (default ~/.qwen)
  --registry-dir DIR  session registry (default <qwen-dir>/sessions)

A unit is eligible only when its session has NO registry entry (rule 2), its newest mtime is
older than the cutoff (rule 3), and that mtime is outside the in-flight window (rule 6).  A
live registered session is excluded whatever its age (rule 1).  Without --delete nothing is
removed (rule 5)."""


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
    """The sessionId a chat transcript belongs to: the name before the first dot."""
    return os.path.basename(path).split(".", 1)[0]


def subagent_stem_of(name):
    """The call-stem of a subagent file: strip .stream, then .meta.json or .jsonl.

    The order matters: `<stem>.jsonl.stream` and `<stem>.jsonl` are the SAME call, so an
    in-flight partial must not become a unit of its own -- if it did, a stream being written
    right now would be aged out on its own (old) stub's mtime.
    """
    if name.endswith(".stream"):
        name = name[: -len(".stream")]
    for suffix in (".meta.json", ".jsonl"):
        if name.endswith(suffix):
            return name[: -len(suffix)]
    return name


def collect_units(store, store_dir):
    """(key, [paths], newest_mtime, total_size, label) for every unit in one store.

    chats:      one file per unit, keyed by the sessionId in its name.
    subagents:  one CALL per unit, keyed by the PARENT session -- the directory it sits in.
                A subagent file is named after the agent kind and a call id, never after a
                session, so the parent directory is the only link to a session (see the
                header).  A unit's mtime is the NEWEST of its files, so an in-flight
                .stream pins the whole call -- transcript and sidecar included -- fresh.
    """
    units = []
    if store == STORE_CHATS:
        for path in sorted(glob.glob(os.path.join(store_dir, "*"))):
            if not os.path.isfile(path):
                continue
            stat = os.stat(path)
            units.append(
                (session_id_of(path), [path], stat.st_mtime, stat.st_size, os.path.basename(path))
            )
        return units

    for parent_dir in sorted(glob.glob(os.path.join(store_dir, "*"))):
        if not os.path.isdir(parent_dir):
            continue
        parent = os.path.basename(parent_dir)
        stems = {}
        for path in sorted(glob.glob(os.path.join(parent_dir, "*"))):
            if not os.path.isfile(path):
                continue
            stems.setdefault(subagent_stem_of(os.path.basename(path)), []).append(path)
        for stem, paths in sorted(stems.items()):
            stats = [os.stat(path) for path in paths]
            units.append(
                (parent, paths, max(stat.st_mtime for stat in stats),
                 sum(stat.st_size for stat in stats), f"{parent}/{stem}")
            )
    return units


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
    store = os.environ.get("QR_STORE", "").strip() or STORE_CHATS
    registry_dir = os.environ.get("QR_REGISTRY_DIR", "").strip() or os.path.join(qwen_dir, "sessions")
    if not qwen_dir:
        fail("no --qwen-dir given")
    if not project:
        fail("no --project given")
    if store not in STORES:
        fail(f"--store must be one of {', '.join(STORES)}: {store!r}")
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

    store_dir = os.path.join(qwen_dir, "projects", project, store)
    if not os.path.isdir(store_dir):
        fail(f"no {store} store at {store_dir} -- an empty scan is not a clean tree")
    if not os.path.isdir(registry_dir):
        fail(f"no session registry at {registry_dir} -- liveness cannot be bounded")

    delete_mode = os.environ.get("QR_DELETE") == "1"
    boot_id = read_boot_id()
    registry = read_registry(registry_dir)
    now = time.time()
    cutoff = now - max_age_days * 86400.0
    inflight = now - GRACE_HOURS * 3600.0

    units = collect_units(store, store_dir)
    excluded_live = []
    excluded_registered = []
    kept_young = []
    kept_inflight = []
    eligible = []
    for key, paths, newest, size, label in units:
        age_days = (now - newest) / 86400.0
        if key in registry:
            is_live, why = liveness(registry[key], boot_id)
            row = (label, size, newest, age_days, why, len(paths))
            if is_live:
                excluded_live.append(row)
            else:
                excluded_registered.append(row)
            continue
        if newest >= cutoff:
            kept_young.append((label, size, newest, age_days, "", len(paths)))
        elif newest >= inflight:
            # Rule 6: written recently enough that a call may still be appending to it.
            kept_inflight.append((label, size, newest, age_days, "", len(paths)))
        else:
            eligible.append((label, paths, size, newest, age_days))

    explicit = time.strftime("%Y-%m-%d %H:%M:%S %Z", time.localtime(cutoff))
    entries_word = "entry" if len(registry) == 1 else "entries"
    if store == STORE_CHATS:
        unit_word = "1 file per unit, keyed by sessionId"
    else:
        unit_word = "1 unit per call, keyed by the PARENT session directory"
    print(f"qwen-transcript-retention: {store_dir}")
    print(f"  store         {store} ({unit_word})")
    print(f"  registry      {registry_dir} ({len(registry)} {entries_word})")
    print(f"  cutoff        newest mtime strictly older than {max_age_days:g} days (before {explicit})")
    print(f"  in-flight     newest mtime inside {GRACE_HOURS:g} h -- never eligible, whatever the cutoff")
    print(f"  units         {len(units)} in scope")
    print(f"  excluded      registered (rule 2): {len(excluded_registered) + len(excluded_live)}")
    print(f"  excluded      of those LIVE (rule 1, never touched): {len(excluded_live)}")
    for label, size, mtime, age_days, why, nfiles in excluded_live + excluded_registered:
        stamp = time.strftime("%Y-%m-%d %H:%M:%S %Z", time.localtime(mtime))
        files_word = "" if nfiles == 1 else f", {nfiles} files"
        print(f"    {label}  {size} bytes{files_word}  mtime={stamp}  age={age_days:.1f}d")
        print(f"      excluded: {why}; registered, so out of scope whatever its age")
    print(f"  unregistered  {len(kept_young) + len(kept_inflight) + len(eligible)}")
    print(f"  kept          younger than the cutoff: {len(kept_young)}")
    print(f"  kept          inside the in-flight window: {len(kept_inflight)}")

    total_bytes = sum(row[2] for row in eligible)
    total_files = sum(len(row[1]) for row in eligible)
    units_word = "unit" if len(eligible) == 1 else "units"
    files_word = "file" if total_files == 1 else "files"
    print(f"  TO REMOVE     {len(eligible)} {units_word}, {total_files} {files_word} "
          f"({total_bytes} bytes, {total_bytes / 1048576:.1f} MiB)")
    for label, paths, size, newest, age_days in eligible:
        stamp = time.strftime("%Y-%m-%d %H:%M:%S %Z", time.localtime(newest))
        files_word = "" if len(paths) == 1 else f", {len(paths)} files"
        print(f"    {os.path.join(store_dir, label)}  {size} bytes{files_word}  "
              f"mtime={stamp}  age={age_days:.1f} days")
    if eligible:
        oldest = min(eligible, key=lambda row: row[3])
        newest = max(eligible, key=lambda row: row[3])
        print(f"  oldest        {oldest[0]}  age={(now - oldest[3]) / 86400.0:.1f} days")
        print(f"  newest        {newest[0]}  age={(now - newest[3]) / 86400.0:.1f} days")

    if not delete_mode:
        print(f"  DRY RUN       nothing deleted; re-run with --delete to remove these "
              f"{len(eligible)} {units_word}")
        return EXIT_OK

    failures = []
    removed_bytes = 0
    removed_files = 0
    for label, paths, _size, _newest, _age in eligible:
        for path in paths:
            try:
                bytes_here = os.stat(path).st_size
                os.remove(path)
                removed_bytes += bytes_here
                removed_files += 1
            except OSError as error:
                failures.append(f"{path}: {error}")
    print(f"  DELETED       {removed_files} files, {removed_bytes} bytes freed")
    for label, paths, _size, _newest, _age in eligible:
        for path in paths:
            if os.path.exists(path):
                print(f"  REMAINS       {path}", file=sys.stderr)
    if failures:
        for line in failures:
            print(f"qwen-transcript-retention: could not remove {line}", file=sys.stderr)
        return EXIT_DELETE_FAILED
    print("  verified      every removed path is gone; every other unit was left alone")
    return EXIT_OK


if __name__ == "__main__":
    sys.exit(main())
PY
