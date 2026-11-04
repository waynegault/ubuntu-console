#!/usr/bin/env python3
"""Stop the VS Code BATS test-runner killing every suite at ten seconds.

WHY A PATCH AT ALL.  `kherring.bats-test-runner` spawns one `bats` per suite file with

    spawn(cmd, args, {shell: "bash", timeout: 1e4, ...})

so *Node* kills the child after 10 000 ms — 93 suites in one sweep, launched together, on
a box whose load average was 46 that day.  The kill lands on `bash -c "bats ..."`, which
bash has exec'd into `bats` itself, so bats's own EXIT trap runs `rm -rf "$BATS_RUN_TMPDIR"`
while its `bats-exec-*` children keep going.  Those children recreate the run directory
with `mkdir -p` (mode 755, where `mktemp -d` gave 700), `touch` an empty `bats.<pid>.out`,
and never rewrite the `bats.<pid>.src` — so every remaining case fails at
`source "$BATS_TEST_SOURCE"`:

    preprocessing.bash: line 22: /tmp/bats-run-XXXXXX/bats.<pid>.src: No such file or directory

and the panel reports those cases as FAILING TESTS.  Measured 2026-11-04 16:05 GMT in
ubuntu-console: 54 such directories, empty `.out` files, no `.src` in any of them, and
`executeTest error: Error: failed with code null` in the extension's own log for every
suite that overran the 10 s.  Two suites the panel started at 16:00 were still running at
16:40, because the extension wires no cancellation at all (`signal:`/`onCancellationRequested`
are absent from the bundle) — the 10 s spawn timeout is the only thing that ever stops a run.

THE PATCH is one literal, `1e4` -> `36e5` (one hour), plus a marker comment saying why.
36e5 is chosen against `tests/bats-suites.tsv`, whose largest whole-file budget is 2700 s;
this suite asserts the value stays above it.

An extension update replaces `dist/extension.js` and silently reverts this, so:

    vscode-bats-timeout-patch.py --check    # exit 1 when an installed copy is unpatched
    vscode-bats-timeout-patch.py --apply    # replace (idempotent), syntax-check, verify
    vscode-bats-timeout-patch.py --revert   # restore the pristine file from the backup

`--check` exit codes, because a caller keys on them:
    0  every installed copy is patched
    1  at least one installed copy is unpatched (an extension update reverted it)
    2  no kherring.bats-test-runner extension copy found (nothing to patch — not a fault)
    3  an installed copy is not a shape this tool recognises, so NO write was made
"""

from __future__ import annotations

import argparse
import hashlib
import shutil
import subprocess
import sys
from pathlib import Path

MARK = "LOCALLY PATCHED (ubuntu-console tools/vscode-bats-timeout)"
TARGET_GLOBS = (
    "~/.vscode-server/extensions/kherring.bats-test-runner-*/dist/extension.js",
    "~/.vscode/extensions/kherring.bats-test-runner-*/dist/extension.js",
)
BACKUP_DIR = Path("~/.local/lib/vscode-bats-timeout/backups").expanduser()

# The anchor is the two lines that identify the ONE spawn site's timeout, not the bare
# number: `1e4` may legitimately appear elsewhere in a future bundle, and replacing the
# wrong one would be silent.  A file with two `shell,`+`timeout: 1e4,` pairs is refused.
UNPATCHED = "    shell,\n    timeout: 1e4,\n"
PATCHED = (
    "    shell,\n"
    f"    // {MARK}: Node kills a spawn at `timeout` ms.  1e4 killed every suite that\n"
    "    // overran 10 s, and bats's exit trap then deleted its run dir under live children,\n"
    "    // turning their remaining cases into bogus failures.  36e5 = 1 hour.  Re-apply\n"
    "    // after an extension update with vscode-bats-timeout-patch.py --apply.\n"
    "    timeout: 36e5,\n"
)


def targets() -> list[Path]:
    """Every installed copy of the bundle, de-duplicated and ordered."""
    found: list[Path] = []
    home = Path("~").expanduser()
    for pattern in TARGET_GLOBS:
        # Patterns are written "~/..." for legibility; glob from $HOME, not from "/"
        # (a literal "~" directory does not exist).
        for path in sorted(home.glob(pattern[2:] if pattern.startswith("~/") else pattern)):
            if path not in found:
                found.append(path)
    return found


def state(path: Path) -> str:
    """'patched', 'unpatched', or 'unrecognised' — never a guess dressed as a verdict."""
    text = path.read_text(encoding="utf-8")
    if MARK in text:
        return "patched"
    if text.count(UNPATCHED) == 1:
        return "unpatched"
    return "unrecognised"


def _backup_path(path: Path) -> Path:
    digest = hashlib.sha256(str(path).encode()).hexdigest()[:8]
    return BACKUP_DIR / f"{path.name}.{digest}.orig"


def _syntax_ok(path: Path) -> tuple[bool, str]:
    """Verify with the extension host's own parser.  A check that cannot run is reported."""
    try:
        proc = subprocess.run(["node", "--check", str(path)], capture_output=True, text=True, check=False)
    except FileNotFoundError:
        return True, "syntax NOT verified: node is not on PATH"
    if proc.returncode == 0:
        return True, "syntax ok (node --check)"
    detail = (proc.stderr or proc.stdout).strip().splitlines()
    return False, f"syntax check FAILED: {detail[0] if detail else 'no output'}"


def apply(path: Path) -> str:
    current = state(path)
    if current == "patched":
        return "already patched"
    if current == "unrecognised":
        return (
            "REFUSED: this copy does not carry exactly one spawn-options timeout — "
            "upstream may have changed shape; nothing was written"
        )
    backup = _backup_path(path)
    BACKUP_DIR.mkdir(parents=True, exist_ok=True)
    if not backup.exists():
        shutil.copy2(path, backup)
    text = path.read_text(encoding="utf-8")
    patched = text.replace(UNPATCHED, PATCHED, 1)
    if patched.count(MARK) != 1 or patched.count(UNPATCHED) != 0:
        return "REFUSED: the replacement did not land exactly once"
    path.write_text(patched, encoding="utf-8")
    ok, note = _syntax_ok(path)
    if not ok:
        shutil.copy2(backup, path)
        return f"REFUSED and reverted: {note}"
    if state(path) != "patched":
        shutil.copy2(backup, path)
        return "REFUSED and reverted: marker missing after the write"
    return f"patched ({note}; backup {backup})"


def revert(path: Path) -> str:
    backup = _backup_path(path)
    if not backup.exists():
        return f"NOT reverted: no backup at {backup}"
    shutil.copy2(backup, path)
    return "reverted" if state(path) != "patched" else "REVERT FAILED: marker still present"


def main(argv: list[str] | None = None) -> int:
    doc_lines = (__doc__ or "").splitlines()
    parser = argparse.ArgumentParser(description=doc_lines[0] if doc_lines else None)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--check", action="store_true", help="report state; exit 1 if any copy is unpatched")
    group.add_argument("--apply", action="store_true", help="replace the timeout (idempotent)")
    group.add_argument("--revert", action="store_true", help="restore the pristine file")
    args = parser.parse_args(argv)

    found = targets()
    if not found:
        print("no kherring.bats-test-runner extension copy found — nothing to patch")
        return 2

    worst = 0
    for path in found:
        if args.check:
            current = state(path)
            print(f"  {current.upper()}  {path}")
            if current == "unpatched":
                worst = max(worst, 1)
            elif current == "unrecognised":
                worst = max(worst, 3)
        elif args.apply:
            note = apply(path)
            print(f"  {path}: {note}")
            if note.startswith("REFUSED"):
                worst = max(worst, 3)
        else:
            note = revert(path)
            print(f"  {path}: {note}")
            if not note.startswith("reverted"):
                worst = max(worst, 1)

    if args.check:
        if worst == 0:
            print("all installed copies are patched")
        elif worst == 3:
            print("a copy is an unrecognised shape — inspect it; do not assume the revert")
        else:
            print("a copy is unpatched — an extension update reverted this; run --apply")
    return worst


if __name__ == "__main__":
    sys.exit(main())
