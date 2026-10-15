"""Enforce the console's contracts. See the script header for scope per subcommand."""
import os
import re
import sys
from typing import TypedDict

# Exit codes, the same three the header documents.  Named rather than repeated as
# bare digits so each `return` site says what it means.  Declared BEFORE the
# interpreter-dependency guard below, which exits with EXIT_CANNOT_RUN: with the
# names defined after it, a missing PyYAML raised NameError (exit 1 and a
# traceback) instead of the documented exit 2.  Found by ruff/mypy once the
# program moved out of the shell heredoc into a .py module (card dd96b63f).
EXIT_CLEAN = 0
EXIT_DRIFT = 1
EXIT_CANNOT_RUN = 2

try:
    import yaml  # noqa: F401
except ImportError:
    sys.stderr.write(
        "check-contracts: PyYAML is required to parse the contract, and is not importable.\n"
        "  Install it (pip install pyyaml) or run with the repo's .venv python.\n"
        "  Refusing to fall back to a weaker parse — a partial contract check is a silent pass.\n"
    )
    sys.exit(EXIT_CANNOT_RUN)

SUBCOMMANDS = ("state", "modules", "derived", "continuity", "swallows")
# Every subcommand named above is implemented.  The reservation mechanism stays:
# re-adding a name here is how a sixth checker would land, and a name in RESERVED
# exits 2 with a message naming its owner instead of silently doing nothing.
RESERVED: dict[str, str] = {}


class _StateCounts(TypedDict):
    """The `state` subcommand's heterogeneous edge counters.

    A TypedDict rather than one `dict` of ints plus a parallel list: the values
    are read by name and mutated by name, and the separate list was what made the
    accumulator's type unrepresentable to a checker.
    """

    producer: int
    consumer: int
    invalidator: int
    unenforced: int
    unenforced_lines: list[str]


class _WitnessCounts(TypedDict):
    """The read-back witness tallies, threaded through check_read_backs()."""

    verified: int
    exempt: int
    checked: bool
    lines: list[str]
    mutating: list[str]


class _CheckerOptions(TypedDict):
    """Per-invocation output modes; never shared between checker runs."""

    print_baseline: bool
    dump_sites: bool

COMMENT = re.compile(r"^\s*#")
ENTRY_LINE = re.compile(r"^\s*- (?:name|path):", re.M)
# An assignment must be *of the token*: NAME=<...token...>.  The name may sit
# mid-line, because a real write is often guarded — 11f-llm-runtime.sh:443 is
# `[[ -f "$LLM_TPS_CACHE" ]] && LAST_TPS=$(< "$LLM_TPS_CACHE")`, an assignment
# that an anchored pattern missed (it made the producer check report a false
# "no write" on a healthy file).
ASSIGN = re.compile(
    r"(?:^|[\s;&|(])(?:export\s+|local\s+|declare\s+|readonly\s+|typeset\s+)?"
    r"[A-Za-z_][A-Za-z0-9_]*=(.*)$")
REDIRECT = re.compile(r">>?\s*(\S+)")
# `rm` is deliberately NOT here: a delete must never satisfy a PRODUCER edge —
# that is what `invalidators:` exists for.  Measured 2026-09-22: with `rm` in this
# set, scripts/11a-llm-registry.sh's `rm -f "$ACTIVE_LLM_FILE"` (a cache clear)
# passed as the producer of /dev/shm/active_llm, so removing the real write in
# scripts/11e-llm-model.sh was NOT caught — the exact silent regression this
# checker exists to catch.  DELETE below is the invalidator side.
MUTATE = re.compile(r"\b(?:mv|touch|truncate|tee|cp|dd)\b[^;|&]*")
DELETE = re.compile(r"\b(?:rm|unlink)\b[^;|&]*")
SUBMODULE_CALL = re.compile(r"__tac_source_submodules\b")
SUBMODULE_ARG = re.compile(r"\b(\d\d[a-z]?-[a-z0-9][a-z0-9-]*)\b")

USAGE = """check-contracts — contract-drift guard (subcommand dispatcher)

usage: check-contracts.sh [SUBCOMMAND] [--repo DIR] [COMMAND...]

  (no SUBCOMMAND)  run every subcommand
  state            docs/contracts/state-contracts.yaml — cross-handler state
  modules          @depends/@exports headers vs the real load order
  derived          the derived command surface vs the authored enumerations
  continuity       per-entry version/scope/superseded_by + the decision register
  swallows         unclassified `|| true` / `2>/dev/null` sites in the shell corpus
  --version, -V    print the tool version and exit

  COMMAND...       only with `continuity`: surface the contract entries and
                   recorded decisions that still apply to that command.

options:
  --repo DIR       check the checkout at DIR instead of this repository
  --print-baseline print the paste-ready baseline rows for `modules`/`swallows`
                   (read-only; the baseline file is never written by this tool)
  --dump-sites     print every `swallows` site as one JSON object per line (read-only
                   JSONL on stdout, the summary on stderr, exit 0 — a dump, not a
                   check).  Only with `swallows`; a bare invocation narrows to it.

exit: 0 clean · 1 contract drift · 2 bad invocation / cannot run the check"""


# ── findings ────────────────────────────────────────────────────────────────
# ENTITY_LINES maps a declared symbol to the line of the contract entry that
# declares it.  Every finding names that line, so a failure points at both the
# code that stopped matching AND the contract claim that is now stale.  (A
# missing file or a missing reference has no line of its own to name; the
# declaration line is the one a reader needs to act on.)
ENTITY_LINES: dict[str, int] = {}


def fail(problems, symbol, detail):
    """Record one drift finding against a symbol, naming its contract line."""
    line = ENTITY_LINES.get(symbol)
    where = f"  [contract line {line}]" if line else ""
    problems.append(f"  FAIL  {symbol}: {detail}{where}")


def read_lines(repo, rel):
    """Return the text of one repo file, or None when it cannot be read.

    A file that does not exist is reported by the caller as a drift finding, so
    returning None here is silent for that case; only a file that exists but
    cannot be read is a run problem worth naming on stderr.
    """
    path = os.path.join(repo, rel)
    if not os.path.isfile(path):
        return None
    try:
        with open(path, encoding="utf-8", errors="replace") as handle:
            return handle.read()
    except OSError as exc:
        sys.stderr.write(f"check-contracts: cannot read {rel}: {exc}\n")
        return None


def read_baseline(repo, rel):
    """{key: detail} from a `<kind>\\t<key>\\t<detail>` baseline, or {} when absent.

    The baseline records disagreements that already exist, so that only a NEW one
    fails.  It is data, not a counter: the key names the exact edge, so fixing one
    edge makes exactly one row stale.  An absent file is an empty baseline — that
    is what makes the bare tool fail on a tree that carries no record.
    """
    text = read_lines(repo, rel)
    rows: dict[str, str] = {}
    if text is None:
        return rows
    for line in text.splitlines():
        line = line.rstrip("\n")
        if not line or line.startswith("#"):
            continue
        parts = line.split("\t")
        if len(parts) >= 2:
            rows.setdefault(parts[0] + "\t" + parts[1], parts[2] if len(parts) > 2 else "")
    return rows


READ_BACK_REASON_MIN = 8
