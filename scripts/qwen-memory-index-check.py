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
  * a link whose target does not exist RELATIVE TO THE INDEX FILE's own directory;
  * a line that ends in an ellipsis (`…` or `...`) — the truncation's own signature,
    and a defect even when the link it cut still happens to resolve.
One line is counted ONCE however many of those it trips, so `bad=` is a line count,
not a reason count: `entries=3 bad=2` means one good entry and two bad ones.

WHICH INDEXES (the store set is DISCOVERED, never listed)
---------------------------------------------------------
With no arguments it checks the ROOT store (`<qwen-dir>/memories/MEMORY.md`) and every
PROJECT store (`<qwen-dir>/projects/*/memory/MEMORY.md`).  The two locations are stated
once here; the stores themselves are globbed, so a project store added later is checked
without an edit — a hard-coded list would silently miss the one that is broken.

EXIT CODES
  0  every index read cleanly and no entry is broken
  1  at least one broken entry — this is the gate
  2  the check could not run: a named index is missing, or no index was found at all
     (an empty scan is not a clean tree)

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

# One index entry: `- [title](target) — description`.  Group 2 is the link target.
# A line truncated mid-link has no closing `)`, so this does not match it and the
# entry is reported as having no link; the ellipsis test below names the real cause.
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
    """(entry_count, [(lineno, why)]) for one index file."""
    base = os.path.dirname(os.path.abspath(path))
    entries = 0
    broken = []
    with open(path, encoding="utf-8") as handle:
        for lineno, line in enumerate(handle, 1):
            if not line.startswith("- ["):
                continue
            entries += 1
            reasons = []
            match = ENTRY_RE.match(line)
            if not match or not match.group(2).strip():
                reasons.append("no link (empty or unclosed target)")
            else:
                target = os.path.join(base, match.group(2))
                if not os.path.exists(target):
                    reasons.append(f"missing target: {match.group(2)}")
            if line.rstrip().endswith(("…", "...")):
                reasons.append("line ends in an ellipsis (truncated)")
            if reasons:
                broken.append((lineno, "; ".join(reasons)))
    return entries, broken


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
    for path in targets:
        entries, broken = check_index(path)
        print(f"{path}: entries={entries} bad={len(broken)}")
        for lineno, why in broken[:MAX_DETAIL_LINES]:
            print(f"    line {lineno}: {why}")
        if len(broken) > MAX_DETAIL_LINES:
            print(f"    ... {len(broken) - MAX_DETAIL_LINES} more")
        if broken:
            any_broken = True

    return EXIT_BROKEN if any_broken else EXIT_CLEAN


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
