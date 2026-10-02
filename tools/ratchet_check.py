"""The counters and the ratchet check.

Every counter is a pure function of one file's text, so --selftest can exercise it on
a fixture instead of on the repo.  The corpus-wide number is their sum.
"""
import os
import re
import subprocess
import sys

# The invocation values.  The wrapper ALWAYS passes them and main() reads them
# from there; these module-level values are the import-safe defaults for a caller
# that imports the counters (a test) — this module's own repo, its baseline and the
# check mode.  They are not a fallback for a caller that forgot an argument:
# running the program with too few arguments still raises.
REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BASELINE = os.path.join(REPO, "tools", "ratchet-baseline.tsv")
MODE = "check"

CORPUS = re.compile(r"\.(sh|bashrc)$|^bin/")
COMMENT = re.compile(r"^\s*#")
LONG_LINE = 120
FUNC_LONG_LINES = 100

FUNC_DEF = re.compile(
    r"^\s*(?:function\s+([A-Za-z_][A-Za-z0-9_]*)|([A-Za-z_][A-Za-z0-9_]*)\s*\(\s*\)\s*\{?)"
)
CASE_START = re.compile(r"case\b.*\bin\b")
STDERR_REDIR = re.compile(r"(?:echo|printf)\b[^\n]*>&2")


def _lines(text):
    return text.splitlines()


def _code_lines(text):
    return [line for line in _lines(text) if not COMMENT.match(line)]


def _declares_default(stripped):
    """True when this case arm's pattern list contains a bare `*` (`*)`, `(*))`, `x|*)`)."""
    m = re.match(r"^\s*\(?([^)]*)\)", stripped)
    if not m:
        return False
    return any(tok.strip() == "*" for tok in m.group(1).split("|"))


def _func_defs(text):
    """(line_index, name) for every function definition."""
    out = []
    for i, line in enumerate(_lines(text)):
        if COMMENT.match(line):
            continue
        m = FUNC_DEF.match(line)
        if m:
            name = m.group(1) or m.group(2)
            if name:
                out.append((i, name))
    return out


def c_case_no_default(text):
    """4.2.4 — case blocks with neither a *) arm nor an explanatory comment."""
    n = depth = 0
    has_default = has_comment = False
    for line in _lines(text):
        stripped = line.strip()
        if depth and stripped.startswith("#"):
            has_comment = True
            continue
        if stripped.startswith("#"):
            continue
        if depth == 0 and CASE_START.search(stripped):
            depth, has_default, has_comment = 1, False, False
            continue
        if depth:
            if re.search(r"\besac\b", stripped):
                depth -= 1
                if depth == 0 and not has_default and not has_comment:
                    n += 1
                continue
            if CASE_START.search(stripped):
                depth += 1
            elif _declares_default(stripped):
                has_default = True
    return n


def c_for_oneline(text):
    """4.2.6 — a whole `for … do … done` loop on one line."""
    return sum(1 for line in _code_lines(text) if re.search(r"\bfor\b.*\bdo\b.*\bdone\b", line))


def c_single_bracket(text):
    """6.7 — `[ … ]` where `[[ … ]]` is the house style."""
    n = 0
    for line in _code_lines(text):
        if "[[" in line:
            continue
        if re.search(r"(^|\s)\[\s", line) and re.search(r"\s\]", line):
            n += 1
    return n


def c_long_lines(text):
    """8.1.8 — non-comment lines longer than 120 characters."""
    return sum(1 for line in _code_lines(text) if len(line) > LONG_LINE)


def c_funcs_without_comment(text):
    """9.5 — function definitions with no comment line directly above them."""
    lines = _lines(text)
    n = 0
    for i, _name in _func_defs(text):
        if i == 0 or not COMMENT.match(lines[i - 1]):
            n += 1
    return n


def c_adhoc_stderr(text):
    """10.7 — `echo`/`printf` writing to stderr by hand instead of via a helper."""
    return sum(1 for line in _code_lines(text) if STDERR_REDIR.search(line))


def c_funcs_over_100(text):
    """10.4 — functions longer than 100 lines (bounded by the next definition).

    COMMENT-ONLY LINES DO NOT COUNT (2026-09-24).  They did, and that made this counter
    fight the swallow guard: `# swallow-ok: <reason>` is a comment the guard REQUIRES, so
    recording a decision lengthened a measured function and re-baselining 10.4 became the
    price of classifying a site — measured three times in one session.  A counter that
    punishes documentation measures the wrong thing.  Blank lines are still counted, so
    padding a function out is still a rise.
    """
    defs = _func_defs(text)
    lines = _lines(text)
    total = len(lines)
    n = 0
    for k, (start, _name) in enumerate(defs):
        end = defs[k + 1][0] if k + 1 < len(defs) else total
        if len([line for line in lines[start:end] if not COMMENT.match(line)]) > FUNC_LONG_LINES:
            n += 1
    return n


EXIT_LITERAL = re.compile(r"\b(?:exit|return)\s+([2-9]|[1-9][0-9]+)\b")
LOCAL_DECL = re.compile(r"^\s*(?:local|declare)\s+([A-Za-z_][A-Za-z0-9_]*)")
MIXED_CASE = re.compile(r"^[a-z][A-Za-z0-9_]*[A-Z]")


def c_unexplained_exit_codes(text):
    """9.7 — a literal exit/return code other than 0/1 with no comment on or above it.

    An exit code is part of a function's interface, so an unexplained non-0/1 code is the
    one item in the style set that a reader actually needs; the repo's own style is a
    comment on the line or directly above it.
    """
    lines = _lines(text)
    n = 0
    for i, line in enumerate(lines):
        if COMMENT.match(line) or not EXIT_LITERAL.search(line):
            continue
        if "#" in line:
            continue
        if i and COMMENT.match(lines[i - 1]):
            continue
        n += 1
    return n


def c_mixedcase_locals(text):
    """4.3.6 — a `local`/`declare` name in mixedCase rather than snake_case.

    ALL_CAPS locals are not counted: those are constants-as-locals, which the item is not
    about (it asks for lower_snake_case for ordinary locals).
    """
    n = 0
    for line in _code_lines(text):
        m = LOCAL_DECL.match(line)
        if m and MIXED_CASE.match(m.group(1)):
            n += 1
    return n


COUNTERS = [
    ("4.2.4", "case blocks with neither a *) arm nor an explanatory comment", c_case_no_default),
    ("4.2.6", "whole `for … do … done` loop on one line", c_for_oneline),
    ("4.3.6", "`local`/`declare` names in mixedCase", c_mixedcase_locals),
    ("6.7", "`[ … ]` instead of `[[ … ]]`", c_single_bracket),
    ("8.1.8", "non-comment lines over 120 characters", c_long_lines),
    ("9.5", "function definitions with no comment directly above", c_funcs_without_comment),
    ("9.7", "literal exit/return codes other than 0/1 with no comment", c_unexplained_exit_codes),
    ("10.4", "functions longer than 100 lines", c_funcs_over_100),
    ("10.7", "hand-written `>&2` on echo/printf instead of a helper", c_adhoc_stderr),
]

FIXTURES = {
    "4.2.4": ("case $x in\na) : ;;\nesac\n", 1),
    "4.2.6": ("for i in 1 2; do echo $i; done\n", 1),
    "4.3.6": ("f() {\n    local camelCase=1\n    local snake_case=2\n    local UPPER=3\n}\n", 1),
    "6.7": ("[ -f x ] && echo y\n[[ -f x ]] && echo y\n", 1),
    "8.1.8": ("x=" + "a" * 130 + "\n" + "y=short\n", 1),
    "9.5": ("# noted\nnoted() { :; }\nbare() { :; }\n", 1),
    "9.7": ("exit 0\nreturn 1\nexit 3\n# justified above\nreturn 4\nexit 5 # inline\n", 1),
    "10.4": [("f() {\n" + "\n".join(["  :"] * 105) + "\n}\n", 1),
             # ...and the exemption that keeps this counter compatible with the swallow
             # guard: 60 code lines + 60 comment lines is 60, not 120.
             ("g() {\n" + "\n".join(["  :", "  # why"] * 60) + "\n}\n", 0)],
    "10.7": ("echo bad >&2\nhelper warn\n", 1),
}


def selftest():
    failures = 0
    for cid, _desc, fn in COUNTERS:
        if cid not in FIXTURES:
            print(f"  control {cid:<7} MISSING FIXTURE (a counter with no control is not evidence)")
            failures += 1
            continue
        entry = FIXTURES[cid]
        # A counter may need more than one control — 10.4 does: one proving a long
        # function IS counted, one proving a function long only in COMMENTS is not.
        pairs = entry if isinstance(entry[0], (list, tuple)) else [entry]
        for text, expected in pairs:
            got = fn(text)
            ok = got == expected
            if not ok:
                failures += 1
            print(f"  control {cid:<7} expected {expected}  got {got}  {'OK' if ok else 'MISMATCH'}")
    # A control must also prove the *other* direction: the pristine text scores 0.
    clean = (
        "#!/usr/bin/env bash\n"
        "# a comment\n"
        "f() {\n"
        "    local x=1\n"
        "    [[ $x == 1 ]] && echo ok\n"
        "}\n"
    )
    for cid, _desc, fn in COUNTERS:
        if cid == "9.5":
            continue  # `f()` here is deliberately uncommented; covered above
        got = fn(clean)
        if got != 0:
            failures += 1
            print(f"  control {cid:<7} pristine text scored {got} (expected 0)  MISMATCH")
    if failures:
        print(f"count-ratchet: {failures} control(s) failed — counters are not trustworthy")
        return 1
    print(f"count-ratchet: {len(COUNTERS)} counters, all controls pass")
    return 0


def read_baseline(path):
    base = {}
    if not os.path.exists(path):
        return base
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            line = line.rstrip("\n")
            if not line or line.startswith("#"):
                continue
            parts = line.split("\t")
            if len(parts) >= 2 and parts[1].strip().isdigit():
                base[parts[0]] = int(parts[1])
    return base


_BASELINE_HEADER = (
    "# docs/inspection.md §18.3 count ratchet — see tools/count-ratchet.sh",
    "# id<TAB>count.  A count may FALL freely; raising one is a deliberate act.",
)


def _preserved_comments(path):
    """Existing `#` comment lines that are NOT the generated header.

    `read_baseline` has always ignored comments, so the file legitimately carries
    hand-written provenance (WHY a count was re-baselined).  `--update` used to open
    the file with mode "w" and write only the header + rows, deleting them — the file's
    own notes recorded the loss and were "restored by hand" more than once.  Carry them
    through the rewrite instead (card fc4d3e29).
    """
    if not os.path.exists(path):
        return []
    kept = []
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            line = line.rstrip("\n")
            if line.startswith("#") and line not in _BASELINE_HEADER:
                kept.append(line)
    return kept


def write_baseline(path, counts):
    preserved = _preserved_comments(path)
    with open(path, "w", encoding="utf-8") as fh:
        for line in _BASELINE_HEADER:
            fh.write(line + "\n")
        # ...then any hand-added provenance, so a re-baseline no longer destroys it.
        for line in preserved:
            fh.write(line + "\n")
        for cid, _desc, _fn in COUNTERS:
            fh.write(f"{cid}\t{counts[cid]}\n")


def corpus_counts():
    files = subprocess.run(["git", "ls-files"], cwd=REPO, capture_output=True,
                           text=True, check=True).stdout.split()
    files = [f for f in files if CORPUS.search(f)]
    counts = {}
    for cid, _desc, fn in COUNTERS:
        total = 0
        for rel in files:
            try:
                with open(os.path.join(REPO, rel), encoding="utf-8", errors="replace") as fh:
                    total += fn(fh.read())
            except OSError as exc:
                print(f"count-ratchet: cannot read {rel}: {exc}", file=sys.stderr)
                return None
        counts[cid] = total
    return counts, len(files)




def main(argv=None):
    """Run the ratchet.  *argv* defaults to sys.argv[1:] — repo, baseline, mode."""
    global REPO, BASELINE, MODE
    args = list(sys.argv[1:] if argv is None else argv)
    REPO, BASELINE, MODE = args[0], args[1], args[2]

    if MODE == "selftest":
        sys.exit(selftest())

    result = corpus_counts()
    if result is None:
        sys.exit(1)
    counts, nfiles = result

    if MODE == "update":
        write_baseline(BASELINE, counts)
        print(f"count-ratchet: baseline written from {nfiles} files -> {BASELINE}")
        for cid, desc, _fn in COUNTERS:
            print(f"  {cid:<7} {counts[cid]:>5}  {desc}")
        sys.exit(0)

    baseline = read_baseline(BASELINE)

    if MODE == "list":
        print(f"{'id':<8}{'count':>6}{'base':>7}  item")
        for cid, desc, _fn in COUNTERS:
            base = baseline.get(cid)
            print(f"{cid:<8}{counts[cid]:>6}{(str(base) if base is not None else '-'):>7}  {desc}")
        sys.exit(0)

    if not baseline:
        print(f"count-ratchet: no baseline at {BASELINE} — run with --update to create it", file=sys.stderr)
        sys.exit(2)

    risen, fell = [], []
    for cid, desc, _fn in COUNTERS:
        base = baseline.get(cid)
        if base is None:
            risen.append((cid, desc, "missing from the baseline"))
        elif counts[cid] > base:
            risen.append((cid, desc, f"{base} -> {counts[cid]}"))
        elif counts[cid] < base:
            fell.append((cid, desc, f"{base} -> {counts[cid]}"))

    print(f"=== §18.3 count ratchet ({nfiles} files) ===")
    if risen:
        for cid, desc, detail in risen:
            print(f"  RISEN  {cid:<7} {detail:<14} {desc}")
    if fell:
        for cid, desc, detail in fell:
            print(f"  fell   {cid:<7} {detail:<14} {desc}  (re-baseline with --update)")
    if not risen and not fell:
        print(f"  PASS  {len(COUNTERS)} counters, none risen")

    if risen:
        print("")
        print("A §18.3 count rose.  Either the new code is what this item asks you not to add")
        print("(fix the code), or the rise is deliberate — in which case re-baseline on purpose")
        print("with tools/count-ratchet.sh --update and say why in the commit message.")
        print("")
        print("If the rise equals the patterns in ONE newly added shell file, that is the corpus")
        print("growing rather than drift: re-baseline and name the file in the commit.")
        sys.exit(1)
    sys.exit(0)


if __name__ == "__main__":
    main()
