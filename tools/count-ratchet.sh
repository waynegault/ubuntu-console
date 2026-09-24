#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
# count-ratchet.sh — fail when a docs/inspection.md §18.3 count RISES.
# ═══════════════════════════════════════════════════════════════════════════════
# §18.3 is a table of ~27 stylistic migration items that a correctness pass counted
# but deliberately did not fix.  Its own closing note says where they belong:
#
#   "This belongs in a ratchet — a guard that fails when the count RISES — not in a
#    per-pass to-do list.  A number with no owner and no enforcement only grows."
#
# This is that guard: a baseline of the current counts, and a non-zero exit when any
# of them grows.  Lowering a number is free (and reported, so the baseline can follow);
# raising one is a deliberate act that has to be re-baselined on purpose.
#
# WHAT THIS IS NOT: a semantic measurement of code quality.  Each counter is a
# deliberately simple, stable pattern over the tracked shell corpus — the point is
# comparability across revisions, not precision.  Re-deriving an item's *true*
# population is a separate exercise (three of §18.3's figures moved when it was done
# on 2026-09-21: 9→10, 10→19, 41→112).  When a counter is re-derived, lower its
# baseline in the same change and say so in the commit.
#
# THREE ITEMS ARE DELIBERATELY NOT RATCHETED: 4.2.1 (`&&` with `||`), 4.2.5 (`if …;
# then` on one line) and 8.2.2 (`readonly` not ALL_CAPS).  Their populations ARE the
# house style — the safe braced `X && { a || b; }` form, §18.3's own 634 sites it calls
# "idiomatic, not a defect", and the documented `C_*` design-token API — so a ratchet on
# them would fail on ordinary new code instead of on drift worth stopping.  This guard's
# first CI run proved the point: the tool file itself carries four of these patterns, so
# adding it raised four counts at once.
#
# THE BASELINE IS CORPUS-RELATIVE, so a NEW shell file raises several counts by itself
# (`git ls-files` lists only tracked files — baseline after committing, and expect one
# deliberate re-baseline when a file is added).
#
# Usage:
#   tools/count-ratchet.sh              # check against tools/ratchet-baseline.tsv
#   tools/count-ratchet.sh --list       # print every counter with its numbers
#   tools/count-ratchet.sh --update     # re-baseline (deliberate; review the diff)
#   tools/count-ratchet.sh --selftest   # prove every counter against a fixture
#   tools/count-ratchet.sh -h
#
# Exit 0 = no count rose · 1 = a count rose · 2 = bad invocation.
#
# The corpus is the tracked shell set: *.sh, *.bashrc and bin/* (git ls-files), with
# comment-only lines excluded.  It is deliberately the same scope §18.3 measured.
#
# --selftest exists because a counter nobody can make go red is not evidence (§3.1):
# every counter is exercised against a fixture whose expected value is written down,
# and the run fails if any counter disagrees.
# ═══════════════════════════════════════════════════════════════════════════════
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BASELINE="$REPO_ROOT/tools/ratchet-baseline.tsv"

mode="check"
case "${1:-}" in
    ""|--check)  mode="check" ;;
    --list)      mode="list" ;;
    --update)    mode="update" ;;
    --selftest)  mode="selftest" ;;
    -h|--help)
        sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
        exit 0
        ;;
    *)
        echo "usage: count-ratchet.sh [--check|--list|--update|--selftest]" >&2
        exit 2
        ;;
esac

if ! command -v python3 >/dev/null 2>&1; then
    echo "ERROR: python3 is required (the counters parse shell, and are not line greps)." >&2
    exit 2
fi

exec python3 - "$REPO_ROOT" "$BASELINE" "$mode" <<'PYEOF'
"""The counters and the ratchet check.

Every counter is a pure function of one file's text, so --selftest can exercise it on
a fixture instead of on the repo.  The corpus-wide number is their sum.
"""
import os
import re
import subprocess
import sys

REPO, BASELINE, MODE = sys.argv[1], sys.argv[2], sys.argv[3]

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
    return [l for l in _lines(text) if not COMMENT.match(l)]


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
    return sum(1 for l in _code_lines(text) if re.search(r"\bfor\b.*\bdo\b.*\bdone\b", l))


def c_single_bracket(text):
    """6.7 — `[ … ]` where `[[ … ]]` is the house style."""
    n = 0
    for l in _code_lines(text):
        if "[[" in l:
            continue
        if re.search(r"(^|\s)\[\s", l) and re.search(r"\s\]", l):
            n += 1
    return n


def c_long_lines(text):
    """8.1.8 — non-comment lines longer than 120 characters."""
    return sum(1 for l in _code_lines(text) if len(l) > LONG_LINE)


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
    return sum(1 for l in _code_lines(text) if STDERR_REDIR.search(l))


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
        if len([l for l in lines[start:end] if not COMMENT.match(l)]) > FUNC_LONG_LINES:
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


def write_baseline(path, counts):
    with open(path, "w", encoding="utf-8") as fh:
        fh.write("# docs/inspection.md §18.3 count ratchet — see tools/count-ratchet.sh\n")
        fh.write("# id<TAB>count.  A count may FALL freely; raising one is a deliberate act.\n")
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
PYEOF

# end of file
