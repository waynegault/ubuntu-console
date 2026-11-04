#!/usr/bin/env python3
"""Stop the VS Code BATS test-runner killing every suite at ten seconds, and make its
``--filter`` a shell-safe argument.

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

THE SECOND DEFECT (2026-11-04 22:2x GMT) is the same spawn's `--filter`:

    args.push("--filter", "'" + item.label + "'");

`shell: true` means Node joins the arguments into ONE command string, so that single quote
is real shell syntax — and a `@test` name containing an apostrophe closes it early.  Two
observed outcomes, both bogus: an odd number of apostrophes gives
`bash: -c: line 1: unexpected EOF while looking for matching '` and bats then reads the rest
of the name as a FILE (`ERROR: Test file ".../lane" does not exist`), while an even number
silently MANGLES the filter instead, so it matches nothing.  The fix escapes the apostrophe
as `'\''`, the one form a single-quoted string cannot express.

THE PATCHES are two literal replacements, applied independently:

* `timeout: 1e4` -> `timeout: 36e5` (one hour).  36e5 is chosen against
  `tests/bats-suites.tsv`, whose largest whole-file budget is 2700 s; this suite asserts
  the value stays above it.
* the `--filter` quoting above, which must keep the label byte-identical through bash.

An extension update replaces `dist/extension.js` and silently reverts both, so:

    vscode-bats-timeout-patch.py --check    # exit 1 when an installed copy is unpatched
    vscode-bats-timeout-patch.py --apply    # replace (idempotent), syntax-check, verify
    vscode-bats-timeout-patch.py --revert   # restore the pristine file from the backup

A REPAIRED FILE IS NOT A RUNNING PATCH.  The extension host evaluates this bundle once,
at activation, so a --apply against a running window changes nothing until the window is
reloaded: measured 2026-11-04, the patch landed at 17:13 while the host had been activated
at 16:30, and the next sweep reproduced every bogus failure.  `--apply` therefore prints
the reload step whenever it writes a copy.  (The self-heal tick re-applies after an update
but cannot reload a window, so that step stays the operator's.)

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
from dataclasses import dataclass
from pathlib import Path

MARK = "LOCALLY PATCHED (ubuntu-console tools/vscode-bats-timeout)"
TARGET_GLOBS = (
    "~/.vscode-server/extensions/kherring.bats-test-runner-*/dist/extension.js",
    "~/.vscode/extensions/kherring.bats-test-runner-*/dist/extension.js",
)
BACKUP_DIR = Path("~/.local/lib/vscode-bats-timeout/backups").expanduser()


@dataclass(frozen=True)
class Patch:
    """One literal replacement, with the text that proves it landed.

    The anchors are not bare numbers or bare quotes: `1e4` and `--filter`, `'` may
    legitimately appear elsewhere in a future bundle, and replacing the wrong one would be
    silent.  A file carrying an anchor twice is refused rather than guessed between.
    """

    name: str
    unpatched: str
    patched: str


TIMEOUT_PATCH = Patch(
    name="spawn timeout",
    unpatched="    shell,\n    timeout: 1e4,\n",
    patched=(
        "    shell,\n"
        f"    // {MARK}: Node kills a spawn at `timeout` ms.  1e4 killed every suite that\n"
        "    // overran 10 s, and bats's exit trap then deleted its run dir under live children,\n"
        "    // turning their remaining cases into bogus failures.  36e5 = 1 hour.  Re-apply\n"
        "    // after an extension update with vscode-bats-timeout-patch.py --apply.\n"
        "    timeout: 36e5,\n"
    ),
)

FILTER_PATCH = Patch(
    name="filter quoting",
    unpatched=r"""    args.push("--filter", "'" + item.label + "'");""" + "\n",
    patched=(
        f"    // {MARK}: a single-quoted label is NOT shell-safe.  `shell: true` joins the\n"
        "    // arguments into one command string, so a @test name with an apostrophe closed\n"
        "    // the quote: bash died with \"unexpected EOF while looking for matching `''\",\n"
        "    // and an even count silently mangled the filter instead.  '\\'' is the one form\n"
        "    // a single-quoted string cannot express.\n"
        r"""    args.push("--filter", "'" + item.label.replace(/'/g, "'\\''") + "'");""" + "\n"
    ),
)

PATCHES = (TIMEOUT_PATCH, FILTER_PATCH)


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


def _patch_state(text: str, patch: Patch) -> str:
    """'patched', 'missing', or 'unrecognised' for ONE replacement.

    'missing' requires exactly one anchor: zero means the shape moved (the tool must not
    invent a site), and two mean it cannot tell which one is the spawn's.
    """
    if patch.patched in text:
        return "patched"
    if text.count(patch.unpatched) == 1:
        return "missing"
    return "unrecognised"


def state(path: Path) -> str:
    """'patched', 'unpatched', or 'unrecognised' — never a guess dressed as a verdict.

    'unpatched' includes a HALF-patched copy (one replacement landed, the other did not),
    because each missing one is still addressable: apply() fills in exactly the anchors
    that are absent and leaves the applied text alone.
    """
    text = path.read_text(encoding="utf-8")
    states = [_patch_state(text, patch) for patch in PATCHES]
    if all(value == "patched" for value in states):
        return "patched"
    if any(value == "unrecognised" for value in states):
        return "unrecognised"
    return "unpatched"


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
            "REFUSED: this copy does not carry exactly one anchor for every patch — "
            "upstream may have changed shape; nothing was written"
        )
    backup = _backup_path(path)
    BACKUP_DIR.mkdir(parents=True, exist_ok=True)
    if not backup.exists():
        shutil.copy2(path, backup)
    text = path.read_text(encoding="utf-8")
    patched = text
    for patch in PATCHES:
        # A half-patched copy keeps what has already landed, so a second --apply cannot
        # duplicate the comment block or lose a previous run's work.
        if _patch_state(text, patch) == "patched":
            continue
        patched = patched.replace(patch.unpatched, patch.patched, 1)
    landed = {patch.name: _patch_state(patched, patch) for patch in PATCHES}
    if any(value != "patched" for value in landed.values()):
        return f"REFUSED: a replacement did not land exactly once ({landed})"
    path.write_text(patched, encoding="utf-8")
    ok, note = _syntax_ok(path)
    if not ok:
        shutil.copy2(backup, path)
        return f"REFUSED and reverted: {note}"
    if state(path) != "patched":
        shutil.copy2(backup, path)
        return "REFUSED and reverted: a marker is missing after the write"
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
    group.add_argument("--apply", action="store_true", help="apply every literal (idempotent)")
    group.add_argument("--revert", action="store_true", help="restore the pristine file")
    args = parser.parse_args(argv)

    found = targets()
    if not found:
        print("no kherring.bats-test-runner extension copy found — nothing to patch")
        return 2

    worst = 0
    patched_any = False
    missing_names: set[str] = set()
    for path in found:
        if args.check:
            current = state(path)
            print(f"  {current.upper()}  {path}")
            if current == "unpatched":
                text = path.read_text(encoding="utf-8")
                missing_names.update(p.name for p in PATCHES if _patch_state(text, p) == "missing")
                worst = max(worst, 1)
            elif current == "unrecognised":
                worst = max(worst, 3)
        elif args.apply:
            note = apply(path)
            print(f"  {path}: {note}")
            if note.startswith("REFUSED"):
                worst = max(worst, 3)
            elif note.startswith("patched") or note == "already patched":
                patched_any = True
        else:
            note = revert(path)
            print(f"  {path}: {note}")
            if not note.startswith("reverted"):
                worst = max(worst, 1)

    # A write is not an effect: the extension host loaded its bundle at activation and
    # keeps it in memory, so even a file that already reads "patched" may not be running.
    # Say so at the moment the operator believes the run is fixed.
    if patched_any:
        print(
            "NOTE: a running VS Code extension host keeps the OLD bundle in memory — "
            "reload the window (Developer: Reload Window) or every run is still killed at 10 s."
        )

    if args.check:
        if worst == 0:
            print("all installed copies are patched")
        elif worst == 3:
            print("a copy is an unrecognised shape — inspect it; do not assume the revert")
        else:
            missing = f" (missing: {', '.join(sorted(missing_names))})" if missing_names else ""
            print(f"a copy is unpatched{missing} — run --apply")
    return worst


if __name__ == "__main__":
    sys.exit(main())
