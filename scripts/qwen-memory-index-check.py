#!/usr/bin/env python3
"""qwen-memory-index-check — is every managed-memory index entry still usable?

WHY THIS EXISTS (2026-10-01)
----------------------------
The Qwen CLI builds each `MEMORY.md` managed-memory index line as
`- [title](relative/path.md) — description`, then truncated the WHOLE line at 150
characters.  The cut lands inside the `](path)` link, chopping the target and leaving
a dangling ellipsis, so every index in every store read broken.  A local patch to the
bundled indexer (`bin/qwen-memory-index-patch.sh`, hunks 1-3) stops the cut — but that
patch is against a FOREIGN bundle, so any CLI or companion update reverts it, and a
fix nobody can re-run is a fix nobody can trust.  This is the re-runnable witness: it
reads every index in the box and reports, per file, how many entries it holds and how
many are BROKEN.

WHAT COUNTS AS BROKEN (one `- [` entry line)
--------------------------------------------
  * no link at all, or an empty/unclosed `](...)` target;
  * a link whose target does not exist RELATIVE TO THE INDEX FILE's own directory.
One line is counted ONCE however many of those it trips, so `bad=` is a line count,
not a reason count: `entries=3 bad=2` means one good entry and two bad ones.

A TRAILING ELLIPSIS IS NOT A DEFECT ON ITS OWN (changed 2026-10-06).  A line ending in
`…` used to mean the stock truncator had cut through the `](path)` target and left a
dangling marker — but the CLI's 0.25.0 builder keeps the link intact and marks only a
SHORTENED DESCRIPTION with `…` (measured 2026-10-06: calling the shipped
`truncateIndexField` appends `…`, and every one of the 133 flagged store lines across the
root/investigator/ubuntu-console stores had a link that resolved, `missing_target=0`).
Flagging those fired the guard on upstream's deliberate, harmless behaviour.  The ellipsis
is therefore named only as CONTEXT for an entry that is already broken; the link checks
above carry the detection, because a cut-through link has no closing `)` and is caught as
"no link".

A LINE LONGER THAN THE WRITER'S CAP IS ITS OWN FINDING (added 2026-10-11).  The indexer's
line builder budgets the description AROUND the link but never the TITLE, so a long note name
beside a long relative path produced a line of up to ~189 characters while the writer's own
`MAX_INDEX_LINE_CHARS = 150` went unenforced.  Such a line is NOT "broken" — its link still
resolves — so it is counted separately as `over=` and reported; it is checked here because a
resolving link is not the only way an index line can be wrong.  Fixed at the mechanism by
`bin/qwen-memory-index-patch.sh` hunk 4 and reported upstream as QwenLM/qwen-code#13910.  The
`MAX_INDEX_LINE_CHARS` below MIRRORS the writer's constant, and this file's own suite pins the
150 boundary, so a drift in either direction shows up as a failure.

WHICH INDEXES (the store set is DISCOVERED, never listed)
---------------------------------------------------------
With no arguments it checks the ROOT store (`<qwen-dir>/memories/MEMORY.md`) and every
PROJECT store (`<qwen-dir>/projects/*/memory/MEMORY.md`).  The two locations are stated
once here; the stores themselves are globbed, so a project store added later is checked
without an edit — a hard-coded list would silently miss the one that is broken.

EXIT CODES
  0  every index read cleanly, no entry is broken and no line exceeds the cap
  1  at least one broken entry — this is the gate (a broken link outranks a long line)
  2  the check could not run: a named index is missing, or no index was found at all
     (an empty scan is not a clean tree)
  3  no broken entry, but at least one line is longer than MAX_INDEX_LINE_CHARS

USAGE
  qwen-memory-index-check.py                    # every store under ~/.qwen
  qwen-memory-index-check.py PATH [PATH ...]    # only these index files
  qwen-memory-index-check.py --qwen-dir DIR     # a different store root (tests)

READ-ONLY: indexes are opened for reading and nothing is ever written.
"""

from __future__ import annotations

import argparse
import glob
import os
import re
import sys

EXIT_CLEAN = 0
EXIT_BROKEN = 1
EXIT_CANNOT_RUN = 2
EXIT_OVER_LONG = 3

# Mirrors the CLI indexer's MAX_INDEX_LINE_CHARS, which its own line builder has not always
# enforced on the title (see the docstring).  Named here so the boundary this check gates on
# is one identifiable number, pinned by tests/unit/36-memory-index-check.bats.
MAX_INDEX_LINE_CHARS = 150

# One index entry: `- [title](target) — description`.  Group 2 is the link target.
# A line truncated mid-link has no closing `)`, so this does not match it and the
# entry is reported as having no link (the trailing ellipsis is then named as context).
ENTRY_RE = re.compile(r"^- \[(.*?)\]\(([^)]*)\)")

# Per-file detail is capped so one rotten index cannot bury the summary lines.
MAX_DETAIL_LINES = 10


def discover_indexes(qwen_dir):
    """Absolute paths of every managed-memory index under `qwen_dir`.

    The root store and the project stores sit at two different depths, so both are
    named here; the store names are globbed, never enumerated.  Sorted so the report
    does not depend on directory order.
    """
    found = []
    root_index = os.path.join(qwen_dir, "memories", "MEMORY.md")
    if os.path.isfile(root_index):
        found.append(os.path.abspath(root_index))
    project_pattern = os.path.join(qwen_dir, "projects", "*", "memory", "MEMORY.md")
    found.extend(
        sorted(os.path.abspath(path) for path in glob.glob(project_pattern) if os.path.isfile(path))
    )
    return found


def check_index(path):
    """(entry_count, [(lineno, why)], [(lineno, length)]) for one index file.

    The two findings lists are independent — an entry can be broken, over the cap, or both —
    and only the first feeds `bad=` (see the module docstring).  Length is counted on the line
    as stored without its newline, which is the unit the writer's cap is stated in.
    """
    base = os.path.dirname(os.path.abspath(path))
    entries = 0
    broken = []
    too_long = []
    with open(path, encoding="utf-8") as handle:
        for lineno, line in enumerate(handle, 1):
            if not line.startswith("- ["):
                continue
            entries += 1
            stripped = line.rstrip("\n")
            if len(stripped) > MAX_INDEX_LINE_CHARS:
                too_long.append((lineno, len(stripped)))
            reasons = []
            match = ENTRY_RE.match(line)
            if not match or not match.group(2).strip():
                reasons.append("no link (empty or unclosed target)")
            else:
                target = os.path.join(base, match.group(2))
                if not os.path.exists(target):
                    reasons.append(f"missing target: {match.group(2)}")
            # Context only — see the module docstring: from 0.25.0 on, a trailing ellipsis
            # marks a shortened description with an intact link, so it is NOT a defect and
            # is named only beside a link problem.
            if reasons and line.rstrip().endswith(("…", "...")):
                reasons.append("line ends in an ellipsis (truncated)")
            if reasons:
                broken.append((lineno, "; ".join(reasons)))
    return entries, broken, too_long


def main(argv):
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument(
        "indexes",
        nargs="*",
        metavar="INDEX",
        help="index files to check (default: every store under --qwen-dir)",
    )
    parser.add_argument(
        "--qwen-dir",
        default=os.path.join(os.path.expanduser("~"), ".qwen"),
        help="store root holding memories/ and projects/*/memory/ (default: ~/.qwen)",
    )
    args = parser.parse_args(argv)

    if args.indexes:
        targets = [os.path.abspath(path) for path in args.indexes]
        missing = [path for path in targets if not os.path.isfile(path)]
        for path in missing:
            print(
                f"qwen-memory-index-check: {path}: not a readable index file",
                file=sys.stderr,
            )
        if missing:
            return EXIT_CANNOT_RUN
    else:
        targets = discover_indexes(args.qwen_dir)
        if not targets:
            print(
                f"qwen-memory-index-check: no MEMORY.md index found under {args.qwen_dir} — "
                "an empty scan is not a clean tree",
                file=sys.stderr,
            )
            return EXIT_CANNOT_RUN

    any_broken = False
    any_over = False
    for path in targets:
        entries, broken, too_long = check_index(path)
        print(f"{path}: entries={entries} bad={len(broken)} over={len(too_long)}")
        for lineno, why in broken[:MAX_DETAIL_LINES]:
            print(f"    line {lineno}: {why}")
        if len(broken) > MAX_DETAIL_LINES:
            print(f"    ... {len(broken) - MAX_DETAIL_LINES} more")
        for lineno, length in too_long[:MAX_DETAIL_LINES]:
            print(f"    line {lineno}: {length} chars, over the {MAX_INDEX_LINE_CHARS} cap")
        if len(too_long) > MAX_DETAIL_LINES:
            print(f"    ... {len(too_long) - MAX_DETAIL_LINES} more")
        if broken:
            any_broken = True
        if too_long:
            any_over = True

    # A broken link outranks a long line: `bad=` keeps the meaning it has always had, so a
    # caller testing `== 1` still reads "an entry is unusable", while `over=` is its own code.
    if any_broken:
        return EXIT_BROKEN
    if any_over:
        return EXIT_OVER_LONG
    return EXIT_CLEAN


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
