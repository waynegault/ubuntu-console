#!/usr/bin/env python3
"""Wire the vscode-pytest-log recorder into the VS Code Python extension's pytest wrapper.

Why a patch at all: the extension runs `python_files/vscode_pytest/run_pytest_script.py`
for EVERY Testing run in EVERY workspace, so one insertion covers all repos — and the
extension *sets* PYTHONPATH for that process, so a plugin delivered purely by environment
cannot be relied on (measured 2026-09-30: the child sees PYTHONPATH pointing at the
extension's own python_files, and a venv ignores the user site, so there is no dependable
import path for a global plugin).

The insertion is additive and guarded: it only wraps `pytest.main`, and if the recorder
cannot be imported it reports that (stdout + ~/.cache/vscode-pytest/ERRORS.txt) and pytest
runs unchanged.  Nothing else in the file is rewritten.

Extension updates replace the file and silently revert this, exactly as the 0.24.6 Qwen
update reverted the shell-guard patch, so:

    vscode-pytest-log-patch.py --check    # exit 1 when an installed copy is unpatched
    vscode-pytest-log-patch.py --apply    # insert (idempotent), syntax-check, verify
    vscode-pytest-log-patch.py --revert   # restore the pristine file from the backup

Recorder: ~/.local/lib/vscode-pytest-log/vscode_pytest_log.py
Results:  ~/.cache/vscode-pytest/<repo>-<hash8>/{latest.json,<utc>.json}

`--check` exit codes, because oc health reports the state from them:
    0  every installed copy is patched
    1  at least one installed copy is unpatched (an extension update reverted it)
    2  no ms-python.python extension copy found (nothing to patch — not a fault)
    3  the recorder is missing from LIB_DIR (the patch would load nothing)
"""

from __future__ import annotations

import argparse
import hashlib
import py_compile
import shutil
import sys
from pathlib import Path

MARK_BEGIN = "# >>> vscode-pytest-log >>>"
MARK_END = "# <<< vscode-pytest-log <<<"
ANCHOR = 'if __name__ == "__main__":'
LIB_DIR = Path("~/.local/lib/vscode-pytest-log").expanduser()
BACKUP_DIR = LIB_DIR / "backups"
TARGET_GLOBS = (
    "~/.vscode-server/extensions/ms-python.python-*/python_files/vscode_pytest/run_pytest_script.py",
    "~/.vscode/extensions/ms-python.python-*/python_files/vscode_pytest/run_pytest_script.py",
)

BLOCK = f'''{MARK_BEGIN}
# LOCAL ADDITION (not Microsoft's): record this run to a JSON results file, so a Testing
# run is readable from outside VS Code and one in progress can be observed.  It only
# wraps pytest.main; if the recorder cannot be imported, it says so and pytest runs
# unchanged.  Re-apply after an extension update with:
#     vscode-pytest-log-patch.py --apply      (check with --check)
try:
    import sys as _vpl_sys
    import pathlib as _vpl_pathlib

    _vpl_sys.path.insert(
        0, os.fspath(_vpl_pathlib.Path("~/.local/lib/vscode-pytest-log").expanduser())
    )
    import vscode_pytest_log as _vpl_recorder
except Exception as _vpl_exc:
    _vpl_recorder = None
    _vpl_msg = f"recorder not loaded ({{_vpl_exc!r}}) - this run will NOT be logged"
    print(f"Error[vscode-pytest-log]: {{_vpl_msg}}")
    try:
        _vpl_err = _vpl_pathlib.Path("~/.cache/vscode-pytest").expanduser()
        _vpl_err.mkdir(parents=True, exist_ok=True)
        with (_vpl_err / "ERRORS.txt").open("a", encoding="utf-8") as _vpl_h:
            _vpl_h.write(_vpl_msg + "\\n")
    except Exception as _vpl_inner:
        print(f"Error[vscode-pytest-log]: cannot record that either: {{_vpl_inner!r}}")

if _vpl_recorder is not None:
    _vpl_original_main = pytest.main

    def _vpl_main(args=None, plugins=None, **kwargs):
        return _vpl_original_main(
            args=args, plugins=[*(plugins or []), _vpl_recorder], **kwargs
        )

    pytest.main = _vpl_main
{MARK_END}
'''


def targets() -> list[Path]:
    """Every installed copy of the wrapper, de-duplicated and ordered."""
    found: list[Path] = []
    home = Path("~").expanduser()
    for pattern in TARGET_GLOBS:
        # Patterns are written "~/..." for legibility; glob from $HOME, not from "/"
        # (a literal "~" directory does not exist — measured 2026-09-30, that bug made
        # this tool report "no copy found" while the copy sat right there).
        for path in sorted(home.glob(pattern[2:] if pattern.startswith("~/") else pattern)):
            if path not in found:
                found.append(path)
    return found


def check(path: Path) -> bool:
    return MARK_BEGIN in path.read_text(encoding="utf-8")


def apply(path: Path) -> str:
    text = path.read_text(encoding="utf-8")
    if MARK_BEGIN in text:
        return "already patched"
    if text.count(ANCHOR) != 1:
        return f"REFUSED: {text.count(ANCHOR)} anchors, expected exactly one"
    BACKUP_DIR.mkdir(parents=True, exist_ok=True)
    digest = hashlib.sha256(str(path).encode()).hexdigest()[:8]
    backup = BACKUP_DIR / f"{path.name}.{digest}.orig"
    if not backup.exists():
        shutil.copy2(path, backup)
    patched = text.replace(ANCHOR, BLOCK + ANCHOR, 1)
    if patched.count(MARK_BEGIN) != 1 or patched.count(MARK_END) != 1:
        return "REFUSED: the insertion did not land exactly once"
    path.write_text(patched, encoding="utf-8")
    # Verify by the tool's own parser, then read the file back.
    try:
        py_compile.compile(str(path), doraise=True, cfile="/tmp/.vpl-compile.pyc")
    except py_compile.PyCompileError as exc:
        shutil.copy2(backup, path)
        return f"REFUSED and reverted: does not compile ({exc})"
    if not check(path):
        return "REFUSED: marker missing after the write"
    return f"patched (backup {backup})"


def revert(path: Path) -> str:
    digest = hashlib.sha256(str(path).encode()).hexdigest()[:8]
    backup = BACKUP_DIR / f"{path.name}.{digest}.orig"
    if not backup.exists():
        return f"no backup for {path}"
    shutil.copy2(backup, path)
    return "reverted" if not check(path) else "REVERT FAILED: marker still present"


def main(argv: list[str] | None = None) -> int:
    # `__doc__` is typed `str | None` even for a module that plainly has one, so the
    # summary line is read through a guard rather than asserted away — and a docstring-less
    # copy then prints no description instead of raising IndexError.
    doc_lines = (__doc__ or "").splitlines()
    parser = argparse.ArgumentParser(description=doc_lines[0] if doc_lines else None)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--check", action="store_true", help="report state; exit 1 if any copy is unpatched")
    group.add_argument("--apply", action="store_true", help="insert the block (idempotent)")
    group.add_argument("--revert", action="store_true", help="restore the pristine file")
    args = parser.parse_args(argv)

    found = targets()
    if not found:
        print("no ms-python.python extension copy found — nothing to patch")
        return 2
    if not (LIB_DIR / "vscode_pytest_log.py").exists():
        print(f"REFUSED: the recorder is missing from {LIB_DIR}")
        return 3

    unpatched = 0
    for path in found:
        if args.check:
            state = "PATCHED" if check(path) else "UNPATCHED"
            if state == "UNPATCHED":
                unpatched += 1
            print(f"  {state}  {path}")
        elif args.apply:
            print(f"  {path}: {apply(path)}")
        else:
            print(f"  {path}: {revert(path)}")
    if args.check:
        print(
            "all installed copies are patched"
            if unpatched == 0
            else f"{unpatched} copy(ies) unpatched — an extension update reverted this; run --apply"
        )
        return 0 if unpatched == 0 else 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
