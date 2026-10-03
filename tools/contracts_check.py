"""Enforce the console's contracts. See the script header for scope per subcommand."""
import os
import json
import re
import subprocess
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
    import yaml
except ImportError:
    sys.stderr.write(
        "check-contracts: PyYAML is required to parse the contract, and is not importable.\n"
        "  Install it (pip install pyyaml) or run with the repo's .venv python.\n"
        "  Refusing to fall back to a weaker parse — a partial contract check is a silent pass.\n"
    )
    sys.exit(EXIT_CANNOT_RUN)

# The tree to check.  The wrapper ALWAYS passes it as the first argument and
# main() reads it from there; this module-level value is the import-safe default
# for a caller that imports the checkers (a test), and it is this module's own
# repository — the only sensible tree to default to.  It is not a fallback for a
# caller that forgot the argument: running the program without it still raises.
REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
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

# Options that change WHAT is printed rather than what is checked.  A dict rather
# than a longer parse_args() tuple: every subcommand already takes the repo, and
# threading a fifth positional through run_selected() to one arm reads worse than
# reading a named flag here.
OPTIONS = {"print_baseline": False, "dump_sites": False}

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


# ── file resolution ─────────────────────────────────────────────────────────
def resolve_ref(repo, ref):
    """Return (files, missing) for one producer/consumer/invalidator reference.

    A thin loader (one calling __tac_source_submodules) resolves to itself plus
    the scripts/<name>.sh files it names, which is how a contract can say
    "scripts/11-llm-manager.sh" and mean the whole §11 module.  A named
    sub-module that does not exist is reported, not ignored.
    """
    files = [ref]
    missing = []
    path = os.path.join(repo, ref)
    if not os.path.isfile(path):
        return files, [ref]
    try:
        with open(path, encoding="utf-8", errors="replace") as handle:
            text = handle.read()
    except OSError as exc:
        sys.stderr.write(f"check-contracts: cannot read {ref}: {exc}\n")
        return files, [ref]
    lines = text.splitlines()
    seen = {ref}
    for index, line in enumerate(lines):
        if not SUBMODULE_CALL.search(line):
            continue
        chunk = line
        cursor = index
        while chunk.rstrip().endswith("\\") and cursor + 1 < len(lines):
            cursor += 1
            chunk += " " + lines[cursor]
        for name in SUBMODULE_ARG.findall(chunk):
            sub = f"scripts/{name}.sh"
            if sub in seen:
                # The loader names itself as the first argument to
                # __tac_source_submodules; it is already in the set.
                continue
            seen.add(sub)
            files.append(sub)
            if not os.path.isfile(os.path.join(repo, sub)):
                missing.append(sub)
    return files, missing


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


def is_write(line, kind, symbol, tokens):
    """Is this line an assignment or a write of this entry's symbol/path?

    Two shapes, and the difference is deliberate:

    * a VARIABLE entry is produced by an assignment of that name — `NAME=...`,
      including the guarded form `... && NAME=$(< cache)` — so the check is on the
      left-hand side.  A line that merely reads `$NAME` does not match, which is
      what makes a producer that stopped assigning fail;
    * a FILE entry is produced by a BINDING (`local cache=<path-token>`) or by a
      redirect/mutating command whose target mentions a path token.  A binding must
      contain no command substitution: `NAME="$DIR/tac_hostmetrics"` declares the
      path, while `tps=$(cat "$LLM_TPS_CACHE")` READS it, and only the former may
      satisfy a producer edge.
    """
    if kind == "variables":
        pattern = (r"(?:^|[\s;&|(])(?:export\s+|local\s+|declare\s+|readonly\s+|"
                   r"typeset\s+)?" + re.escape(symbol) + r"=")
        return re.search(pattern, line) is not None
    assignment = ASSIGN.search(line)
    if assignment:
        rhs = assignment.group(1)
        if "$(" not in rhs and "`" not in rhs and any(token in rhs for token in tokens):
            return True
    for token in tokens:
        for match in REDIRECT.finditer(line):
            if token in match.group(1):
                return True
        for match in MUTATE.finditer(line):
            if token in match.group(0):
                return True
    return False


def is_delete(line, tokens):
    """Is this line a delete of one of the tokens (an invalidator's job)?"""
    for token in tokens:
        for match in DELETE.finditer(line):
            if token in match.group(0):
                return True
    return False


def first_reference(repo, rel, tokens):
    """Line number of the first non-comment reference to a token, else None."""
    text = read_lines(repo, rel)
    if text is None:
        return None
    for number, line in enumerate(text.splitlines(), 1):
        if COMMENT.match(line):
            continue
        if any(token in line for token in tokens):
            return number
    return None


# ── entry model ─────────────────────────────────────────────────────────────
def entry_symbol(kind, entry):
    """The symbol an entry declares: the variable name, or the path's basename."""
    if kind == "variables":
        return entry.get("name")
    return os.path.basename(entry.get("path", ""))


def entry_tokens(kind, entry):
    """Every token a producer/consumer of this entry may reference it by."""
    if kind == "variables":
        tokens = [entry.get("name", "")]
    else:
        tokens = [os.path.basename(entry.get("path", ""))]
        if entry.get("token"):
            tokens.append(entry["token"])
    tokens.extend(entry.get("bindings") or [])
    return [token for token in tokens if token]


def as_list(value):
    """Normalise a YAML scalar-or-list field to a list of strings."""
    if value is None:
        return []
    if isinstance(value, str):
        return [value]
    return [str(item) for item in value]


# ── checks ──────────────────────────────────────────────────────────────────
def check_structure(kind, entry, problems):
    """Report an entry whose shape cannot be checked, and say what is missing."""
    symbol = entry_symbol(kind, entry) or f"<{kind} entry with no name/path>"
    if not entry_symbol(kind, entry):
        fail(problems, symbol, "entry declares neither name nor path")
        return False
    ok = True
    if not as_list(entry.get("producer")):
        fail(problems, symbol, "entry declares no producer")
        ok = False
    consumers = entry.get("consumers")
    if not isinstance(consumers, list) or not consumers:
        fail(problems, symbol, "entry declares no consumers")
        ok = False
    return ok


def check_consumers(kind, entry, consumers, repo, problems, counts: _StateCounts):
    """Enforce one consumer edge per declared file; count unenforced edges."""
    symbol = entry_symbol(kind, entry)
    base_tokens = entry_tokens(kind, entry)
    for edge in consumers:
        if not isinstance(edge, dict):
            fail(problems, symbol, f"consumer edge is not a mapping: {edge!r}")
            continue
        if edge.get("unenforced"):
            if not edge.get("why"):
                fail(problems, symbol,
                     f"unenforced edge {edge.get('reader', '')!r} declares no `why:`")
                continue
            counts["unenforced"] += 1
            counts["unenforced_lines"].append(
                f"NOT ENFORCED  {symbol} <- {edge.get('reader', '')} — {edge['why']}")
            continue
        ref = edge.get("file")
        if not ref:
            fail(problems, symbol, f"consumer edge has neither file nor unenforced: {edge!r}")
            continue
        tokens = base_tokens + as_list(edge.get("via"))
        files, missing = resolve_ref(repo, ref)
        counts["consumer"] += 1
        for miss in missing:
            fail(problems, symbol, f"consumer '{ref}' names missing file '{miss}'")
        hit = None
        for candidate in files:
            where = first_reference(repo, candidate, tokens)
            if where is not None:
                hit = (candidate, where)
                break
        if hit is None and not missing:
            fail(problems, symbol,
                 f"consumer '{ref}' no longer references {'/'.join(tokens)} "
                 f"(searched {', '.join(files)})")


def check_producers(kind, entry, repo, problems, counts: _StateCounts):
    """Enforce that a declared producer still writes the symbol."""
    symbol = entry_symbol(kind, entry)
    tokens = entry_tokens(kind, entry)
    for ref in as_list(entry.get("producer")):
        files, missing = resolve_ref(repo, ref)
        counts["producer"] += 1
        for miss in missing:
            fail(problems, symbol, f"producer '{ref}' names missing file '{miss}'")
        found = None
        for candidate in files:
            text = read_lines(repo, candidate)
            if text is None:
                continue
            for number, line in enumerate(text.splitlines(), 1):
                if COMMENT.match(line):
                    continue
                if is_write(line, kind, symbol, tokens):
                    found = (candidate, number)
                    break
            if found:
                break
        if found is None:
            fail(problems, symbol,
                 f"no assignment or write of {'/'.join(tokens)} in producer '{ref}' "
                 f"(searched {', '.join(files)})")


def check_path_identity(kind, entry, repo, problems):
    """A FILE entry's declared path must still be bound in its producer set.

    Without this, every other check can pass on a cache that was RENAMED: the
    consumers read through the variable (`$ACTIVE_LLM_FILE`), and a producer edge
    is satisfied by a mention of the binding name, so `/dev/shm/active_llm`
    becoming `/dev/shm/active_model` leaves the contract naming a path nothing
    writes — silently.  Measured 2026-09-22 on a fixture: the producer/consumer
    checks alone passed after exactly that rename.

    The literal is bound by an assignment whose right-hand side holds the path
    (`export ACTIVE_LLM_FILE="/dev/shm/active_llm"`) or by a write whose target
    does (`> "${ACTIVE_LLM_FILE}.tmp"`).  A rename that merely keeps the declared
    token as a PREFIX (`tac_hostmetrics` -> `tac_hostmetrics2`) is not caught:
    the tokens are substring matches.
    """
    if kind != "files":
        return
    literal = entry.get("token") or os.path.basename(entry.get("path", ""))
    if not literal:
        return
    searched = []
    for ref in as_list(entry.get("producer")):
        files, _missing = resolve_ref(repo, ref)
        for candidate in files:
            if candidate in searched:
                continue
            searched.append(candidate)
            text = read_lines(repo, candidate)
            if text is None:
                continue
            for line in text.splitlines():
                if COMMENT.match(line):
                    continue
                if is_write(line, "files", literal, [literal]):
                    return
    fail(problems, entry_symbol(kind, entry),
         f"the declared path literal '{literal}' is not bound or written in any "
         f"producer file (searched {', '.join(searched) or 'nothing'}) — rename the "
         "cache in the contract too, or the contract names a path nothing produces")


def check_invalidators(kind, entry, repo, problems, counts: _StateCounts):
    """Enforce that a declared invalidator still deletes the symbol."""
    symbol = entry_symbol(kind, entry)
    tokens = entry_tokens(kind, entry)
    for ref in as_list(entry.get("invalidators")):
        files, missing = resolve_ref(repo, ref)
        counts["invalidator"] += 1
        for miss in missing:
            fail(problems, symbol, f"invalidator '{ref}' names missing file '{miss}'")
        found = None
        for candidate in files:
            text = read_lines(repo, candidate)
            if text is None:
                continue
            for number, line in enumerate(text.splitlines(), 1):
                if COMMENT.match(line):
                    continue
                if is_delete(line, tokens):
                    found = (candidate, number)
                    break
            if found:
                break
        if found is None:
            fail(problems, symbol,
                 f"no delete of {'/'.join(tokens)} in invalidator '{ref}' "
                 f"(searched {', '.join(files)})")


def compute_counts(kind_entries, text, problems):
    """Check that the parser saw every entry the file declares, then count them."""
    declared = len(ENTRY_LINE.findall(text))
    seen = sum(len(entries) for _kind, entries in kind_entries)
    if declared != seen:
        problems.append(
            f"  FAIL  <contract>: {declared} entry declaration(s) in the file but "
            f"{seen} parsed — a schema change is hiding entries from this check")
    return seen, declared


# ── driver ──────────────────────────────────────────────────────────────────
def index_contract_lines(text, kind_entries):
    """Map every declared symbol to the line of its contract entry.

    Built from the file TEXT rather than from the parsed objects, because the
    line number is the one thing PyYAML does not keep — and it is the number a
    reader needs.  YAML allows a quoted or unquoted scalar here, so both are
    accepted; a value that still fails to match simply yields no line, which is
    why `fail()` treats a missing line as optional rather than printing a wrong
    one.
    """
    lines: dict[str, int] = {}
    for match in ENTRY_LINE.finditer(text):
        start = text.rfind("\n", 0, match.start()) + 1
        end = text.find("\n", match.end())
        line_text = text[start:end if end != -1 else len(text)]
        value = line_text.split(":", 1)[1].strip().strip("'\"")
        lines.setdefault(value, text.count("\n", 0, match.start()) + 1)
    for kind, entries in kind_entries:
        for entry in entries:
            if isinstance(entry, dict):
                key = entry.get("name") if kind == "variables" else entry.get("path")
                symbol = entry_symbol(kind, entry)
                if key in lines and symbol:
                    ENTITY_LINES[symbol] = lines[key]


def run_state(repo):
    """Enforce the state contract; return the process exit code."""
    contract_rel = "docs/contracts/state-contracts.yaml"
    contract_path = os.path.join(repo, contract_rel)
    if not os.path.isfile(contract_path):
        sys.stderr.write(f"check-contracts: contract not found: {contract_path}\n")
        return EXIT_CANNOT_RUN
    try:
        with open(contract_path, encoding="utf-8") as handle:
            text = handle.read()
    except OSError as exc:
        sys.stderr.write(f"check-contracts: cannot read {contract_rel}: {exc}\n")
        return EXIT_CANNOT_RUN
    try:
        data = yaml.safe_load(text)
    except yaml.YAMLError as exc:
        sys.stderr.write(f"check-contracts: cannot parse {contract_rel}: {exc}\n")
        return EXIT_CANNOT_RUN
    if not isinstance(data, dict):
        sys.stderr.write(f"check-contracts: {contract_rel} is not a mapping\n")
        return EXIT_CANNOT_RUN

    print(f"=== Contract drift check ({contract_rel}) ===")
    problems: list[str] = []
    symbols: dict[str, str] = {}
    counts: _StateCounts = {"producer": 0, "consumer": 0, "invalidator": 0, "unenforced": 0,
                            "unenforced_lines": []}
    kind_entries = []
    for kind in ("variables", "files"):
        entries = data.get(kind) or []
        if not isinstance(entries, list):
            sys.stderr.write(f"check-contracts: '{kind}' is not a list in {contract_rel}\n")
            return EXIT_CANNOT_RUN
        kind_entries.append((kind, entries))
    index_contract_lines(text, kind_entries)

    for kind, entries in kind_entries:
        for entry in entries:
            if not isinstance(entry, dict):
                fail(problems, f"<{kind}>", f"entry is not a mapping: {entry!r}")
                continue
            symbol = entry_symbol(kind, entry)
            if symbol and symbol in symbols:
                fail(problems, symbol, f"declared twice ({symbols[symbol]} and {kind})")
            symbols[symbol] = kind
            if not check_structure(kind, entry, problems):
                continue
            check_producers(kind, entry, repo, problems, counts)
            check_path_identity(kind, entry, repo, problems)
            check_invalidators(kind, entry, repo, problems, counts)
            check_consumers(kind, entry, entry.get("consumers"), repo, problems, counts)

    entries_seen, declared = compute_counts(kind_entries, text, problems)

    # Read-back witnesses (card CLAIMED-SUCCESS-WITNESS-001, authored half).  A
    # line item inside `state` rather than a sixth subcommand: the claim being
    # checked ("this command queried the state before it printed success") is a
    # state claim, and the dispatcher stays at five subcommands.
    witnesses: _WitnessCounts = {"verified": 0, "exempt": 0, "checked": True, "lines": [],
                                 "mutating": []}
    check_read_backs(repo, problems, witnesses)

    for line in counts["unenforced_lines"]:
        print(f"  {line}")
    for line in witnesses["lines"]:
        print(f"  {line}")
    for problem in problems:
        print(problem)
    # The mutating surface, named rather than only counted (card RAGACT-006 item 3):
    # this is the console's half of the retrieval/action seam, so a caller can see
    # which commands change state without parsing the YAML.  Printed on both paths —
    # the inventory is a fact about the contract, not a verdict on the check.
    mutating = witnesses.get("mutating") or []
    if mutating:
        print(f"  MUTATING surface ({len(mutating)} entries): {', '.join(mutating)}")
    if witnesses["checked"]:
        witness_summary = (f"read-back witnesses: {witnesses['verified']} verified, "
                           f"{witnesses['exempt']} not witnessed (printed above)")
    else:
        witness_summary = "read-back witnesses: NOT CHECKED (printed above)"
    summary = (f"{entries_seen} entries ({declared} declared) | enforced edges: "
               f"{counts['producer']} producer, {counts['consumer']} consumer, "
               f"{counts['invalidator']} invalidator | declared-unenforced edges: "
               f"{counts['unenforced']} (printed above) | {witness_summary}")
    if problems:
        print(f"check-contracts[state]: FAIL — {len(problems)} finding(s). {summary}")
        print("  Fix the contract or the code (both are wrong if they disagree); an edge that")
        print("  cannot be checked must be declared `unenforced: true` with a `why:`, and a")
        print("  read-back that is not written yet must be declared `read_back_exempt: <why>`.")
        return EXIT_DRIFT
    print(f"check-contracts[state]: OK — {summary}")
    print("  Coverage limits, not enforced by construction: a file that reads a declared")
    print("  symbol without being declared is invisible here; the type/format/semantics/")
    print("  notes/translation_rules prose fields are not machine-checked.")
    return 0


# ── read-back witnesses (card CLAIMED-SUCCESS-WITNESS-001) ─────────────────
# The tooling half of this card (`swallows`) records silent failures; this half
# checks the OTHER end — that a command which reports success actually queried the
# state it claims to have changed.  The claim is AUTHORED in
# docs/contracts/command-contracts.yaml (a `read_back:` list or a
# `read_back_exempt: <why>`), because the contract is where a command's side
# effects are already stated and a witness that is not next to the effect it
# witnesses is a second list that drifts (DYNSKILL-011 owns the derived surface).
#
# WHAT IS ENFORCED, per declared witness:
#   1. `witness:` and `file:` are both present;
#   2. `asserts:` is present and long enough to be weighable (the same 8-character
#      floor the swallow markers use — a marker with no reason is a marker no
#      reviewer can weigh);
#   3. the named FILE exists and DEFINES the symbol as a function;
#   4. the symbol is CALLED in the module that `@exports` the command — a
#      non-comment reference, using the same first_reference() the state edges use.
#      Without (4) a witness can be defined and never consulted, which is the
#      decorative version of exactly what this card is about.
# And, per ACTIVE entry:
#   5. an entry whose `contract.side_effects` is non-empty must declare a
#      `read_back:` list or a `read_back_exempt:` reason — otherwise nothing
#      records whether the effect was ever verified, which is the hole this card
#      opened on.  An exemption is printed as NOT WITNESSED and counted, so it is
#      a declared gap rather than a silent one;
#   6. an entry with NO side effects must not declare a witness (there would be
#      nothing for it to have read back).
#
# NOT ENFORCED (stated, never silently skipped — the counts are printed):
#   * whether the witness is CALLED ON THE SUCCESS PATH, or before the success
#     line.  A source check can see the call, not the control flow; the BATS suite
#     (tests/unit/25-claimed-success-witness.bats) drives the injected-failure
#     cases for that, and it is what makes the ordering a fact rather than a claim.
#   * a command whose implementation lives outside the module that exports it.
READ_BACK_REASON_MIN = 8

#: The effect classes an ACTIVE entry may declare (card RAGACT-006).  `read` gathers
#: knowledge; `mutate` changes state.  The distinction is the console's half of the
#: article's retrieval/action seam, and it is what lets a caller gate on it at all.
CONTRACT_EFFECTS = ("read", "mutate")


def command_impl_files(repo, module):
    """The files a command's witness call site may live in: the exporting GROUP.

    A thin loader exports what its sub-modules define — `model` is defined in
    scripts/11e-llm-model.sh and reached through scripts/11-llm-manager.sh — so the
    call site is anywhere in the loader's group.  Searching only the loader's own
    file reports a false "never called" finding for every command in this repo's
    §09/§11 groups (measured: all three witnesses above were reported that way
    before this expansion).
    """
    files = [f"scripts/{module}.sh"]
    submodules = loader_submodules(repo, module) or []
    files.extend(f"scripts/{sub}.sh" for sub in submodules)
    return [rel for rel in files if os.path.isfile(os.path.join(repo, rel))]


def first_call(repo, rel, symbol):
    """Line number of the first non-comment CALL of symbol in rel, else None.

    Deliberately not first_reference(): the DEFINITION line (`symbol() { ... }`,
    with or without `function`) also contains the symbol, so a plain reference
    search reports every witness as called — measured on a fixture, where a witness
    that was defined and never consulted passed the check that exists to catch
    exactly that.  Comments are skipped for the same reason the state edges skip
    them: a mention is not a call.
    """
    text = read_lines(repo, rel)
    if text is None:
        return None
    definition = re.compile(r"^\s*(?:function\s+)?" + re.escape(symbol) + r"\s*\(\s*\)")
    for number, line in enumerate(text.splitlines(), 1):
        if COMMENT.match(line) or symbol not in line or definition.match(line):
            continue
        return number
    return None


def check_read_backs(repo, problems, counts: _WitnessCounts):
    """Verify the read-back witnesses declared in command-contracts.yaml."""
    data, _text, error = command_contracts_file(repo)
    if error:
        counts["checked"] = False
        counts["lines"].append(f"NOT CHECKED  read-back witnesses — {error}; continuity owns "
                               f"that file's existence, so a missing contract is its finding")
        return
    entries = data.get("commands")
    if not isinstance(entries, list) or not entries:
        counts["checked"] = False
        counts["lines"].append("NOT CHECKED  read-back witnesses — the contract declares no "
                               "commands to witness")
        return
    if not os.path.isfile(os.path.join(repo, "scripts/_module-list.sh")):
        counts["checked"] = False
        counts["lines"].append("NOT CHECKED  read-back witnesses — resolving a command to the "
                               "module that exports it needs scripts/_module-list.sh")
        return
    order = module_list_names(repo) or []
    positions, group_of, _findings, _groups = module_graph(repo, order)
    surface = command_surface(repo, sorted(positions, key=positions.get), positions, group_of)

    for entry in entries:
        if not isinstance(entry, dict):
            continue
        name = (entry.get("name") or "").strip()
        if not name or entry.get("status") != "active":
            continue
        contract = entry.get("contract")
        effects = as_list(contract.get("side_effects")) if isinstance(contract, dict) else []
        declared = entry.get("read_back")
        exempt = entry.get("read_back_exempt")

        # The effect class (card RAGACT-006).  Every ACTIVE entry declares one, and the
        # two rules are a pair: an entry that changes state must say how the change was
        # read back, so `mutate` and `read_back_exempt` cannot both be true — the
        # exemption claims there is nothing to observe.
        effect = str(entry.get("effect") or "").strip()
        if effect not in CONTRACT_EFFECTS:
            fail(problems, name, f"declares effect '{effect or '(none)'}' — every active entry "
                                 f"must declare one of {'/'.join(CONTRACT_EFFECTS)}")
        elif effect == "mutate":
            counts["mutating"].append(name)
            if exempt is not None:
                fail(problems, name, "is `mutate` but declares `read_back_exempt:` — a state "
                                     "change must say how it was read back, or be reclassified "
                                     "as `read`")
        if not effects:
            if declared:
                fail(problems, name, "declares a `read_back:` witness but its contract lists no "
                                     "side_effects — there is no effect to read back")
            continue
        if exempt is not None:
            reason = str(exempt).strip()
            if len(reason) < READ_BACK_REASON_MIN:
                fail(problems, name, f"`read_back_exempt:` needs a reason, not '{reason}' — a "
                                     f"missing witness with no reason cannot be weighed")
            else:
                counts["exempt"] += 1
                counts["lines"].append(f"NOT WITNESSED  {name} — {reason}")
            continue
        if not isinstance(declared, list) or not declared:
            fail(problems, name, f"declares {len(effects)} side effect(s) but neither a "
                                 f"`read_back:` witness nor a `read_back_exempt:` reason — "
                                 f"nothing records whether the effect was verified before the "
                                 f"command reported success")
            continue
        command = contract_command_name(entry)
        module = surface.get(command)
        impl_files = command_impl_files(repo, module) if module else []
        if not impl_files:
            fail(problems, name, f"cannot resolve the files that export '{command}', so the "
                                 f"witness call site cannot be checked")
            continue
        for index, witness in enumerate(declared, 1):
            where = f"{name} read_back[{index}]"
            if not isinstance(witness, dict):
                fail(problems, where, f"witness is not a mapping: {witness!r}")
                continue
            symbol = str(witness.get("witness") or "").strip()
            rel = str(witness.get("file") or "").strip()
            claim = str(witness.get("asserts") or "").strip()
            if not symbol or not rel:
                fail(problems, where, "needs both a `witness:` symbol and the `file:` that "
                                      "defines it")
                continue
            if len(claim) < READ_BACK_REASON_MIN:
                fail(problems, where, f"`asserts:` must say what the witness reads back, not "
                                      f"'{claim}'")
            text = read_lines(repo, rel)
            if text is None:
                fail(problems, where, f"names missing file '{rel}'")
                continue
            if defined_names(text).get(symbol) != "function":
                fail(problems, where, f"'{symbol}' is not a function defined in {rel}")
                continue
            if not any(first_call(repo, impl, symbol) is not None
                       for impl in impl_files):
                fail(problems, where, f"'{symbol}' is defined in {rel} but never called in "
                                      f"{' or '.join(impl_files)}, which export the command — a "
                                      f"witness nothing calls verifies nothing")
                continue
            counts["verified"] += 1


# ── shared: module annotations and the real load order ──────────────────────
# Card GEG-006.  Every module declares its edges in its own header (@depends,
# @exports) and the two loaders source the modules in the order
# scripts/_module-list.sh gives ("never a glob").  Nothing parsed either, so the
# declarations could drift from the load order with no failure — the article's
# "sequence mistaken for a dependency".  This block is the ONE parser for both
# the `modules` and the `derived` subcommand (two parsers that disagree would be
# worse than none).
#
# REF: "Graph Engineering for AI Agents: From Prompts and Loops to Workflows"
#      (TDS, 2026-09-14) —
#      https://towardsdatascience.com/graph-engineering-for-ai-agents-from-prompts-and-loops-to-workflows/
MODULE_NAME = re.compile(r"^\d\d[a-z]?-[a-z0-9][a-z0-9-]*$")
SECTION_FIELD = re.compile(r"^#\s*@modular-section:")
ANNOTATION_FIELD = re.compile(r"^#\s*@([a-z][a-z-]*):(.*)$")
FUNC_DEF = re.compile(r"^\s*(?:function\s+)?([A-Za-z_][A-Za-z0-9_.-]*)\s*\(\s*\)")
ALIAS_DEF = re.compile(r"^\s*alias\s+([A-Za-z_][A-Za-z0-9_.-]*)=")
ASSIGN_DEF = re.compile(
    r"^\s*(?:export\s+|readonly\s+|declare\s+(?:-[a-zA-Z]+\s+)*|typeset\s+)?"
    r"([A-Za-z_][A-Za-z0-9_]*)=")


def annotation_fields(text):
    """The @-annotation block of a module, or None when the module has none.

    The block is anchored at `# @modular-section:` and runs to the end of the
    comment run that contains it — deliberately NOT "the comments from line 1":
    scripts/01-constants.sh carries a user-configurable-paths section with real
    code above its block, so a top-of-file reader finds no @depends there at all
    (measured 2026-09-23 against a prototype that did exactly that).

    A field value continues on the following comment lines while the line ends
    with a comma; the leading `#` of a continuation is stripped.  Continuation is
    how every @exports list in this repo is written, so a parser without it sees
    one name per module and silently under-reports.
    """
    lines = text.splitlines()
    start = None
    for index, line in enumerate(lines):
        if SECTION_FIELD.match(line.strip()):
            start = index
            break
    if start is None:
        return None
    fields = {}
    index = start
    while index < len(lines) and lines[index].strip().startswith("#"):
        match = ANNOTATION_FIELD.match(lines[index].strip())
        if match:
            name, value = match.group(1), match.group(2).strip()
            parts = [value]
            while lines[index].rstrip().endswith(",") and index + 1 < len(lines):
                index += 1
                nxt = lines[index].strip()
                if nxt.startswith("#"):
                    nxt = nxt[1:].strip()
                parts.append(nxt)
            if name not in fields:
                fields[name] = " ".join(parts).rstrip(",").strip()
        index += 1
    return fields


def csv_tokens(value):
    """Tokens of an @depends/@exports value; None when the field is absent.

    A parenthetical is prose, not part of a name: `(none — sets ERR trap only)`
    tokenises to nothing, `cd (override)` to `cd`, and
    `__tac_install_shim, __tac_install_pwsh_shims (internal helpers — ...)` to the
    two names.  The literal `none` is the documented "no dependencies" form
    (tools/lint.sh carries `@depends: none (standalone CI helper)`); the callers
    treat it as an empty list rather than as a module called `none`.
    """
    if value is None:
        return None
    cleaned = re.sub(r"\([^)]*\)", "", value)
    return [token.strip() for token in cleaned.split(",") if token.strip()]


def module_list_names(repo):
    """The module names __tac_module_list prints, in load order, or None.

    Read from the function's own body: never a glob of scripts/ (which would
    include entry points and fragments) and never by executing it (the thin
    loaders have source-time side effects).  The printf argument list is joined
    across its `\\` continuations — a line-oriented reader finds only the LAST
    entry, because every other line ends with a backslash (measured against the
    prototype).  Comment lines inside the body are skipped.
    """
    text = read_lines(repo, "scripts/_module-list.sh")
    if text is None:
        return None
    lines = text.splitlines()
    start = None
    for index, line in enumerate(lines):
        if "__tac_module_list" in line and re.search(r"\{|\(\s*\)", line):
            start = index
            break
    if start is None:
        return None
    body = []
    for line in lines[start + 1:]:
        if line.strip() == "}":
            break
        if line.strip().startswith("#"):
            continue
        body.append(line)
    joined = " ".join(part.rstrip("\\").strip() for part in body)
    return re.findall(r"\b(\d\d[a-z]?-[a-z0-9][a-z0-9-]*)\b", joined)


def loader_submodules(repo, loader):
    """The sub-modules a thin loader names by argument, or None when it names none.

    The names are literal arguments to __tac_source_submodules on continued
    lines, so they are invisible to a `source` scan — the same expansion this file
    already does for the state contract in resolve_ref.  A loader names ITSELF as
    the first argument; it is not one of its own sub-modules.
    """
    text = read_lines(repo, f"scripts/{loader}.sh")
    if text is None:
        return None
    lines = text.splitlines()
    subs = []
    found = False
    for index, line in enumerate(lines):
        if not SUBMODULE_CALL.search(line):
            continue
        found = True
        chunk = line
        cursor = index
        while chunk.rstrip().endswith("\\") and cursor + 1 < len(lines):
            cursor += 1
            chunk += " " + lines[cursor]
        for name in SUBMODULE_ARG.findall(chunk):
            if name != loader and name not in subs:
                subs.append(name)
    return subs if found else None


def module_graph(repo, order):
    """(positions, group_of, findings, groups) for the real load order.

    A thin loader and its sub-modules load as one unit at the loader's position,
    so a dependency inside that unit is satisfied by the unit being reached at
    all; `group_of` records which unit each module belongs to.
    """
    positions: dict[str, int] = {}
    groups: dict[str, list[str]] = {}
    findings: list[str] = []
    group_of: dict[str, list[str]] = {}
    for loader in order:
        subs = loader_submodules(repo, loader)
        members = [loader]
        if subs:
            groups[loader] = subs
            for sub in subs:
                if not os.path.isfile(os.path.join(repo, f"scripts/{sub}.sh")):
                    findings.append(f"{loader} names sub-module '{sub}', which does not exist")
                members.append(sub)
        for member in members:
            positions[member] = len(positions)
            group_of[member] = members
    return positions, group_of, findings, groups


def resolve_module(token, positions):
    """The single loaded module a @depends token names: (name, problem).

    A declaration may name a full module (`llm-manager`) or the short form this
    repo uses in most headers (`constants`, `llm-registry`, `oc-gateway`), which
    is the module whose name ends with `-<token>`.  Two matches is ambiguous and
    is reported rather than guessed: guessing would make the check depend on
    dictionary order.
    """
    if token in positions:
        return token, None
    hits = sorted(name for name in positions if name.endswith("-" + token))
    if len(hits) == 1:
        return hits[0], None
    if not hits:
        return None, "unknown"
    return None, "ambiguous"


def module_group_text(repo, group_of, module):
    """The source text of a module and every module in its load unit."""
    chunks = []
    for name in group_of.get(module, [module]):
        text = read_lines(repo, f"scripts/{name}.sh")
        if text is not None:
            chunks.append(text)
    return "\n".join(chunks)


def defined_names(text):
    """{name: kind} for every definition site in a module group's text.

    kind is "function", "alias" or "variable"; the distinction is what makes the
    derived command surface decidable (a command is a name defined as a function
    or an alias, so an exported CONSTANT is not mistaken for one).  A name
    defined more than once keeps the first kind seen.
    """
    names = {}
    for line in text.splitlines():
        if line.lstrip().startswith("#"):
            continue
        for kind, pattern in (("function", FUNC_DEF), ("alias", ALIAS_DEF),
                              ("variable", ASSIGN_DEF)):
            match = pattern.match(line)
            if match and match.group(1) not in names:
                names[match.group(1)] = kind
    return names


def command_surface(repo, order, positions, group_of):
    """{command: exporting module} — the machine-checkable command surface.

    Card DYNSKILL-011 decided this: there is no command registry in this repo and
    none is invented.  The surface is DERIVED from the @exports headers the
    modules already carry, restricted to names a module defines as a function or
    an alias (a variable export is a value, not a command: 01-constants exports
    TACTICAL_REPO_ROOT and LLM_PORT, which are not commands).
    """
    surface = {}
    for module in order:
        fields = annotation_fields(module_group_text(repo, group_of, module))
        if not fields:
            continue
        defined = defined_names(module_group_text(repo, group_of, module))
        for token in csv_tokens(fields.get("exports")) or []:
            if defined.get(token) in ("function", "alias") and token not in surface:
                surface[token] = module
    return surface


def declared_depends(repo, module):
    """(tokens, raw, problem) for one module's @depends declaration.

    raw is the declared text, which the prose forms are reported verbatim from.
    """
    text = read_lines(repo, f"scripts/{module}.sh")
    if text is None:
        return None, None, "module file is missing"
    fields = annotation_fields(text)
    if fields is None:
        return None, None, "no @modular-section annotation block"
    raw = fields.get("depends")
    if raw is None:
        return None, None, "annotation block carries no @depends field"
    if raw.lower().startswith("none"):
        return [], raw, None
    return csv_tokens(raw), raw, None


def declared_uses(repo, module):
    """(tokens, raw, problem) for one module's @uses declaration.

    `@uses` is OPTIONAL, unlike `@depends`: a module with no run-time collaborators
    simply omits the field, and unlike a missing @depends that is not a defect.
    The literal `none` is accepted for a module that wants to say so explicitly.
    """
    text = read_lines(repo, f"scripts/{module}.sh")
    if text is None:
        return None, None, "module file is missing"
    fields = annotation_fields(text)
    if fields is None:
        return None, None, "no @modular-section annotation block"
    raw = fields.get("uses")
    if raw is None:
        return [], None, None
    if raw.lower().startswith("none"):
        return [], raw, None
    return csv_tokens(raw), raw, None


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


def path_between(edges, start, goal):
    """Shortest node path start -> goal (inclusive), or None when unreachable."""
    if start == goal:
        return [start]
    queue = [[start]]
    seen = {start}
    while queue:
        path = queue.pop(0)
        for nxt in edges.get(path[-1], []):
            if nxt in seen:
                continue
            if nxt == goal:
                return path + [nxt]
            seen.add(nxt)
            queue.append(path + [nxt])
    return None


def strongly_connected(edges, nodes):
    """The SCCs of the declaration graph, each as a sorted member list."""
    order = []
    seen = set()

    def visit(node, stack):
        # Iterative DFS: a recursive one would be shorter but the module graph is
        # data, and a deep/looped graph must not be able to raise RecursionError
        # out of a checker whose whole job is to report graph problems.
        stack.append((node, iter(edges.get(node, []))))
        seen.add(node)
        while stack:
            current, children = stack[-1]
            advanced = False
            for child in children:
                if child not in seen:
                    seen.add(child)
                    stack.append((child, iter(edges.get(child, []))))
                    advanced = True
                    break
            if not advanced:
                stack.pop()
                order.append(current)

    for node in nodes:
        if node not in seen:
            visit(node, [])
    reverse: dict[str, list[str]] = {node: [] for node in nodes}
    for node in nodes:
        for nxt in edges.get(node, []):
            reverse.setdefault(nxt, []).append(node)
    assigned = set()
    groups = []
    for node in reversed(order):
        if node in assigned:
            continue
        stack = [node]
        assigned.add(node)
        group = []
        while stack:
            current = stack.pop()
            group.append(current)
            for prv in reverse.get(current, []):
                if prv not in assigned:
                    assigned.add(prv)
                    stack.append(prv)
        groups.append(sorted(group))
    return groups


def cycle_through(edges, start, members):
    """One concrete cycle inside an SCC, starting and ending at `start`."""
    inside = set(members)
    sub = {node: [nxt for nxt in edges.get(node, []) if nxt in inside] for node in members}
    best = None
    for nxt in sub.get(start, []):
        if nxt == start:
            return [start, start]
        rest = path_between(sub, nxt, start)
        if rest and (best is None or len(rest) + 1 < len(best)):
            best = [start] + rest
    return best


# ── subcommand: modules ─────────────────────────────────────────────────────
def run_modules(repo):
    """Enforce the @depends/@exports headers against the real load order."""
    print("=== Module graph check (scripts/_module-list.sh) ===")
    if not os.path.isfile(os.path.join(repo, "scripts/_module-list.sh")):
        sys.stderr.write(
            "check-contracts: scripts/_module-list.sh not found — the load order is the\n"
            "  input to this check, so there is nothing to verify. Refusing to pass.\n")
        return EXIT_CANNOT_RUN
    order = module_list_names(repo)
    if not order:
        sys.stderr.write(
            "check-contracts: __tac_module_list yielded no module names — refusing to pass\n"
            "  on an empty load order (a parse that finds nothing is not a clean tree).\n")
        return EXIT_CANNOT_RUN
    positions, group_of, findings, groups = module_graph(repo, order)
    problems = []
    for finding in findings:
        # A finding the loader produced is a FAILURE, not a note: printing it without
        # adding it to `problems` would exit 0 over a broken load order.
        problems.append(f"  FAIL  <load order>: {finding}")
    violations = []          # (kind, key, message) — recorded-or-new disagreements
    edges = {}
    use_edges = []           # (module, module) — run-time collaborators, order-free
    uses_declaring = 0
    for module in sorted(positions, key=positions.get):
        if not os.path.isfile(os.path.join(repo, f"scripts/{module}.sh")):
            problems.append(f"  FAIL  {module}: listed in scripts/_module-list.sh but no "
                            f"such file exists")
            continue
        tokens, raw, problem = declared_depends(repo, module)
        if problem:
            problems.append(f"  FAIL  {module}: {problem} "
                            f"(scripts/{module}.sh)")
            continue
        fields = annotation_fields(read_lines(repo, f"scripts/{module}.sh")) or {}
        exports = csv_tokens(fields.get("exports"))
        if fields.get("exports") is None:
            problems.append(f"  FAIL  {module}: annotation block carries no @exports field "
                            f"(scripts/{module}.sh)")
        else:
            defined = defined_names(module_group_text(repo, group_of, module))
            for token in exports:
                if token not in defined:
                    problems.append(
                        f"  FAIL  {module}: @exports names '{token}', which is not defined\n"
                        f"        as a function, alias or variable in scripts/{module}.sh "
                        f"or its load unit")
        resolved = []
        for token in tokens:
            name, reason = resolve_module(token, positions)
            if name is None:
                violations.append(("unknown-depends", f"{module}->{token}",
                                   f"@depends names '{token}' ({reason}), which is not a "
                                   f"module: declared as '{raw}'"))
                continue
            if name == module:
                problems.append(f"  FAIL  {module}: @depends names itself")
                continue
            resolved.append(name)
            if positions[name] > positions[module]:
                violations.append((
                    "order", f"{module}->{name}",
                    f"depends on {name}, which loads AFTER it "
                    f"(position {positions[name]} > {positions[module]})"))
        edges[module] = resolved

        # @uses: RUN-TIME collaborators.  This field exists because @depends was
        # carrying two different relationships at once — "must be sourced first" and
        # "this module calls that one" — and only the first is a load-order claim.
        # Measured 2026-09-23: sourcing the library loader in a scrubbed `env -i`
        # gives rc=0 with zero `command not found` and zero `unbound variable`, so
        # none of the declared forward edges is used AT SOURCE TIME.  Hence there is
        # deliberately NO order requirement here and a cycle among @uses edges is
        # legitimate and is NOT reported as one; the §11 group is mutually recursive
        # by design.  What IS an error: naming a module that does not load, naming
        # yourself, or declaring one target in BOTH fields — the two fields
        # partition the edges, and an edge in both would make the load-order claim
        # ambiguous again.
        use_tokens, use_raw, use_problem = declared_uses(repo, module)
        if use_problem:
            problems.append(f"  FAIL  {module}: {use_problem} (scripts/{module}.sh)")
            continue
        if use_tokens:
            uses_declaring += 1
        for token in use_tokens:
            name, reason = resolve_module(token, positions)
            if name is None:
                problems.append(
                    f"  FAIL  {module}: @uses names '{token}' ({reason}), which is not a "
                    f"module: declared as '{use_raw}'")
                continue
            if name == module:
                problems.append(f"  FAIL  {module}: @uses names itself")
                continue
            if name in resolved:
                problems.append(
                    f"  FAIL  {module}: '{name}' is declared in BOTH @depends and @uses — "
                    f"the fields partition the edges (load order vs run time)")
                continue
            use_edges.append((module, name))

    # Coverage the other way: a module-shaped file that no loader loads is a
    # module nothing can call, and the load list is exactly what a new module
    # forgets to touch.  A shebang'd file is an entry point (scripts/18-lint.sh,
    # scripts/autotune-model.sh) and is deliberately not a profile module.
    for entry in sorted(os.listdir(os.path.join(repo, "scripts"))):
        if not entry.endswith(".sh") or not MODULE_NAME.match(entry[:-3]):
            continue
        if entry[:-3] in positions:
            continue
        text = read_lines(repo, f"scripts/{entry}")
        if text is None or text.startswith("#!"):
            continue
        problems.append(f"  FAIL  scripts/{entry}: a module-shaped file that neither "
                        f"scripts/_module-list.sh nor a thin loader names — no pass loads it")

    recorded = read_baseline(repo, "tools/contracts-modules-baseline.tsv")
    if OPTIONS["print_baseline"]:
        print("# paste-ready rows for tools/contracts-modules-baseline.tsv, newest "
              "population:")
        for kind, key, message in sorted(violations):
            print(f"{kind}\t{key}\t{message}")
        return EXIT_CLEAN
    new_violations = []
    seen_keys = set()
    for kind, key, message in violations:
        lookup = kind + "\t" + key
        if lookup in recorded:
            seen_keys.add(lookup)
            dependent, _, _dependency = key.partition("->")
            print(f"  RECORDED  {kind:<15} {dependent}: {message}")
        else:
            new_violations.append((kind, key, message))

    cycles = []
    for members in strongly_connected(edges, sorted(positions, key=positions.get)):
        if len(members) < 2:
            continue
        cycle = cycle_through(edges, members[0], members)
        if cycle:
            cycles.append(cycle)
    for kind, key, message in new_violations:
        dependent, _, dependency = key.partition("->")
        path = path_between(edges, dependency, dependent) if kind == "order" else None
        detail = f"  FAIL  {kind}  {dependent}: {message}"
        if path:
            detail += f"\n        cycle: {' -> '.join([dependent] + path)}"
        problems.append(detail)

    stale = [key for key in recorded if key not in seen_keys]
    for cycle in cycles:
        print(f"  CYCLE     {' -> '.join(cycle)}")
    for key in stale:
        print(f"  STALE     {key.replace(chr(9), ' ')} — no longer a disagreement; "
              f"delete this row from tools/contracts-modules-baseline.tsv")

    edge_count = sum(len(targets) for targets in edges.values())
    for problem in problems:
        print(problem)
    new_count = len(violations) - len(seen_keys)
    summary = (f"{len(positions)} load position(s) ({len(groups)} thin loader(s) expanded) | "
               f"{len(edges)} module(s) with a parsed @depends | {edge_count} declared edge(s) | "
               f"{len(use_edges)} @uses edge(s) across {uses_declaring} module(s) | "
               f"disagreements: {len(seen_keys)} recorded, {new_count} new | "
               f"{len(cycles)} cycle(s) reported (one per strongly-connected component)")
    if problems:
        print(f"check-contracts[modules]: FAIL — {len(problems)} finding(s). {summary}")
        print("  Fix the DECLARATION when it disagrees with the load order (never reorder the")
        print("  numeric load list to satisfy this check). A disagreement that is knowingly")
        print("  accepted goes in tools/contracts-modules-baseline.tsv as a row with a reason.")
        print("  NOTE: that file does not exist at present (deleted in 66f17e5e), so nothing is")
        print("  accepted today and every disagreement fails.")
        return EXIT_DRIFT
    print(f"check-contracts[modules]: OK — {summary}")
    print("  Enforced: every @depends target resolves to a real loaded module (or is the")
    print("  literal `none`), no module depends on itself, every @exports name is defined in")
    print("  its load unit, every module-shaped file is loaded by some loader, and no NEW")
    print("  edge violates the load order or closes a cycle.  @uses is held to the other")
    print("  half: every target must resolve to a loaded module, may not be the module")
    print("  itself, and may not also appear in @depends (the fields partition the edges).")
    print("  No order requirement applies to @uses and a @uses cycle is legitimate — the")
    print("  §11 group is mutually recursive by design — so cycles are reported over the")
    print("  @depends edges only.  No baseline file exists (deleted in 66f17e5e), so nothing")
    print("  is grandfathered — every disagreement fails.  Reported, not enforced: whether a")
    print("  forward edge is reached at run time (the BATS suites cover behaviour).")
    return EXIT_CLEAN


# ── subcommand: derived ─────────────────────────────────────────────────────
def command_contracts_file(repo):
    """(data, text, error) for docs/contracts/command-contracts.yaml."""
    rel = "docs/contracts/command-contracts.yaml"
    path = os.path.join(repo, rel)
    if not os.path.isfile(path):
        return None, None, f"{rel} not found"
    text = read_lines(repo, rel)
    if text is None:
        return None, None, f"{rel} cannot be read"
    try:
        data = yaml.safe_load(text)
    except yaml.YAMLError as exc:
        return None, None, f"{rel} does not parse: {exc}"
    if not isinstance(data, dict):
        return None, None, f"{rel} is not a mapping"
    return data, text, None


def skill_table_commands(repo):
    """[(command, row text, line)] from SKILL.md's tac-exec table.

    The table is the authored snapshot this card gates.  A row is a markdown
    table line naming `tac-exec <something>`; the command is the FIRST token of
    the invocation, because every contract and every export in this repo is
    keyed on the command word (`model use` is the `model` command).
    """
    rel = "skills/tactical-console/SKILL.md"
    text = read_lines(repo, rel)
    if text is None:
        return None
    rows = []
    for number, line in enumerate(text.splitlines(), 1):
        stripped = line.strip()
        if not stripped.startswith("|"):
            continue
        match = re.search(r"`tac-exec\s+([^`]+)`", stripped)
        if not match:
            continue
        tokens = match.group(1).split()
        if tokens:
            rows.append((tokens[0], stripped, number))
    return rows


def contract_command_name(entry):
    """The command word an entry declares: the first token of its `name`."""
    name = (entry.get("name") or "").strip()
    return name.split()[0] if name else ""


def run_derived(repo):
    """Gate the AUTHORED command enumerations against the DERIVED surface."""
    print("=== Derived command surface check (@exports vs authored enumerations) ===")
    order = module_list_names(repo) if os.path.isfile(
        os.path.join(repo, "scripts/_module-list.sh")) else None
    if not order:
        sys.stderr.write(
            "check-contracts: the load order (scripts/_module-list.sh) is the input to the\n"
            "  derived command surface; without it there is nothing to derive. Refusing.\n")
        return EXIT_CANNOT_RUN
    positions, group_of, _findings, _groups = module_graph(repo, order)
    surface = command_surface(repo, sorted(positions, key=positions.get), positions, group_of)
    if not surface:
        sys.stderr.write(
            "check-contracts: no command-shaped name was derived from any @exports header —\n"
            "  refusing to pass, because a gate over an empty surface asserts nothing.\n")
        return EXIT_CANNOT_RUN

    rows = skill_table_commands(repo)
    if rows is None:
        sys.stderr.write("check-contracts: skills/tactical-console/SKILL.md not found — the\n"
                         "  authored table this check gates is missing. Refusing to pass.\n")
        return EXIT_CANNOT_RUN
    data, _text, error = command_contracts_file(repo)
    if error:
        sys.stderr.write(f"check-contracts: {error}\n")
        return EXIT_CANNOT_RUN
    entries = data.get("commands")
    if not isinstance(entries, list) or not entries:
        sys.stderr.write("check-contracts: docs/contracts/command-contracts.yaml declares no "
                         "commands — refusing to pass on an empty enumeration.\n")
        return EXIT_CANNOT_RUN

    problems = []
    if not rows:
        problems.append("  FAIL  skills/tactical-console/SKILL.md: no `tac-exec` table row "
                        "was found — the table is what this check gates, and a parse that")
        problems.append("        finds no row would otherwise report a clean pass")
    named = [row[0] for row in rows]
    for command, _row, number in rows:
        if command not in surface:
            problems.append(f"  FAIL  SKILL.md:{number}: the table names 'tac-exec "
                            f"{command}', which no loaded module @exports")
    contract_names = []
    for entry in entries:
        if not isinstance(entry, dict):
            problems.append(f"  FAIL  command-contracts.yaml: entry is not a mapping: {entry!r}")
            continue
        command = contract_command_name(entry)
        contract_names.append(command)
        if not command:
            problems.append("  FAIL  command-contracts.yaml: an entry declares no `name:`")
        elif command not in surface:
            problems.append(f"  FAIL  command-contracts.yaml: entry '{entry.get('name')}' names "
                            f"'{command}', which no loaded module @exports")

    for problem in problems:
        print(problem)
    covered = [c for c in named if c in surface]
    contracted = [c for c in contract_names if c in surface]
    summary = (f"{len(surface)} command(s) derived from @exports | SKILL.md table: {len(rows)} "
               f"row(s) naming {len(set(named))} distinct command(s), {len(covered)}/"
               f"{len(named)} resolvable | command-contracts.yaml: {len(entries)} entry/entries "
               f"naming {len(set(contract_names))} distinct command(s), {len(contracted)}/"
               f"{len(contract_names)} resolvable")
    if problems:
        print(f"check-contracts[derived]: FAIL — {len(problems)} finding(s). {summary}")
        print("  A table that names a command no loaded module exports is a cache with no")
        print("  invalidation: the command was renamed or removed and the table kept the old")
        print("  name. Fix the authored enumeration, or the @exports header if it is the one")
        print("  that is stale.")
        return EXIT_DRIFT
    print(f"check-contracts[derived]: OK — {summary}")
    print("  Enforced: every command NAMED by SKILL.md's tac-exec table or by a")
    print("  command-contracts.yaml entry is exported (as a function or alias) by a loaded")
    print("  module, and both authored enumerations parse to at least one row/entry.")
    print("  Reported, never enforced: COVERAGE. The SKILL.md table is a curated subset (a")
    print("  human decides the scope of what to consult), so requiring completeness would be")
    print("  wrong; the counts above are the number, not a gate. Also not checked: `tac-exec`")
    print(f"  mentions outside the table, and the {len(surface) - len(set(named + contract_names))} "
          "derived command(s) no authored list names.")
    return EXIT_CLEAN


# ── subcommand: continuity ──────────────────────────────────────────────────
# REF: "Coding Agents Don't Need Longer History — They Need Intent Continuity"
#      (TDS, 2026-09-11) —
#      https://towardsdatascience.com/coding-agents-dont-need-longer-history-they-need-intent-continuity/
CONTRACT_SCOPES = ("interactive", "library", "both")
CONTRACT_STATUSES = ("active", "superseded", "retired")
DECISION_DIR = ".agents/decisions"
ISO_DATE = re.compile(r"^\d{4}-\d\d-\d\d$")

# ── continuity's `verified_by:` (card SPEC-VV-CONSOLE-003) ──────────────────
# A contract entry says what a command does; nothing said which test holds it to
# that word, so a CONTRACT-TO-TEST traceability gap was invisible: an entry could
# be reworded, or its behaviour deleted, with every gate still green.
# REF: "Towards Spec-Driven Test Automation: Part 1" (Gal Arav, TDS, 2026-09-24) — https://towardsdatascience.com/towards-spec-driven-test-automation-part-1/
#
# The oracle for "does that node exist" is the @test DECLARATION parser for
# tests/**/*.bats.  The regex is deliberately the same one the pytest bridge uses
# (tests/test_bats_bridge.py, _parse_bats_tests: anchored to the line, opening `{`
# REQUIRED, single or double quoted name), so a node this check accepts is a node
# the bridge collects; two parsers that disagree would make the map mean two
# different things.  The anchoring is load-bearing there and here: an unanchored
# match also reads @test TEXT out of a comment or a printf fixture, which the
# bridge recorded as fabricating cases that never existed.
BATS_TEST_DECL = re.compile(r'^[ \t]*@test[ \t]+(["\'])(.*?)\1[ \t]*\{', re.MULTILINE)


def bats_test_nodes(repo):
    """(nodes_by_file, n_files) — every BATS @test name under tests/.

    Returns {repo-relative .bats path: [exact @test names]} plus the number of
    .bats files read, so the caller can report how big the oracle was rather than
    implying it looked everywhere.  A file that cannot be read is written to
    stderr and skipped: the node it holds then reads as not-found, which fails a
    verified_by that names it instead of passing on a partial index.
    """
    root = os.path.join(repo, "tests")
    nodes: dict[str, list[str]] = {}
    n_files = 0
    if not os.path.isdir(root):
        return nodes, n_files
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames.sort()
        for filename in sorted(filenames):
            if not filename.endswith(".bats"):
                continue
            path = os.path.join(dirpath, filename)
            try:
                with open(path, encoding="utf-8", errors="replace") as fh:
                    text = fh.read()
            except OSError as exc:
                sys.stderr.write(f"check-contracts: cannot read {path}: {exc}\n")
                continue
            n_files += 1
            rel = os.path.relpath(path, repo)
            nodes[rel] = [m.group(2) for m in BATS_TEST_DECL.finditer(text)]
    return nodes, n_files


def check_verified_by(entry, where, status, name, nodes, problems, report):
    """Validate one entry's `verified_by:` and record its coverage.

    `report` collects the NOT VERIFIED lines (the posture `state` takes for an
    unenforced edge: counted and printed, never a failure).  A DECLARED node that
    cannot be resolved IS a failure, naming the entry and the node — that is the
    half this card exists for, because a stale pointer is a claim of coverage that
    is no longer true.
    """
    declared = entry.get("verified_by")
    if declared is None:
        if status == "active":
            report.append(f"NOT VERIFIED  {name} — no `verified_by:` names the test that "
                          f"holds this entry to its word")
        return
    if not isinstance(declared, list) or not declared:
        problems.append(f"  FAIL  {where}: declares an empty `verified_by:` — name at least "
                        f"one '<path>::<exact @test name>' node, or omit the field so the "
                        f"entry is counted as unverified")
        return
    for item in declared:
        if not isinstance(item, str) or "::" not in item:
            problems.append(f"  FAIL  {where}: `verified_by:` item {item!r} is not of the form "
                            f"'<repo-relative .bats path>::<exact @test name>'")
            continue
        path, _sep, node = item.partition("::")
        path = path.strip()
        node = node.strip()
        if not path or not node:
            problems.append(f"  FAIL  {where}: `verified_by:` item '{item}' has an empty path or "
                            f"test name")
            continue
        if path not in nodes:
            problems.append(f"  FAIL  {where}: `verified_by:` names '{item}', but '{path}' is not "
                            f"a BATS file under tests/ — a Python test cannot be named here")
            continue
        if node not in nodes[path]:
            problems.append(f"  FAIL  {where}: `verified_by:` names '{item}', which is not a "
                            f"@test in {path} — the node was renamed or deleted, so the entry "
                            f"claims a test that does not exist")
            continue
        report.append(f"VERIFIED      {name} -> {item}")


# ── continuity's `disposition:` (card SPEC-VV-CONSOLE-004) ──────────────────
# The article's triage question is: "given only the requirements, could two
# competent developers legitimately disagree about this line?"  YES -> the line is
# a DECISION: an owner made a call, so it belongs in the contract as a closed,
# stated value (`disposition: decision` + `bound:`).  NO -> a CONSEQUENCE: derived
# from the producer, free to change when the producer changes, so a hard-coded
# value in the entry goes stale silently.
# REF: "Towards Spec-Driven Test Automation: Part 1" (Gal Arav, TDS, 2026-09-24) — https://towardsdatascience.com/towards-spec-driven-automation-part-1/
#
# The field is OPTIONAL and the classification is AUTHORED, which is the honest
# limit of this check: it REFUSES an incoherent pair (a decision with no bound, a
# consequence that carries one) and REPORTS the active entries nobody classified —
# it cannot tell whether a given line was triaged correctly.  A guessed
# classification is a silently-failed requirement, so an entry whose own text does
# not settle the question stays unclassified and is counted, not filled in.
DISPOSITIONS = ("decision", "consequence")


def check_disposition(entry, where, status, name, problems, report):
    """Validate one entry's `disposition:`/`bound:` pair and record its coverage.

    Rules, each naming the entry and the reason: a `decision` with no weighable
    `bound:` fails; a `consequence` carrying a `bound:` fails (that IS the
    hard-coded value a consequence must not have); any other value fails naming
    the allowed two.  A `bound:` with no `disposition:` is also a failure — the
    bound belongs to a decision, and without the field nothing says whether the
    value is stated or derived.  An ACTIVE entry with no `disposition:` at all is
    REPORTED and counted, never a failure (the field is optional by the card).
    """
    disposition = entry.get("disposition")
    bound = entry.get("bound")
    bound_text = bound.strip() if isinstance(bound, str) else ""
    if disposition is None:
        if bound is not None:
            problems.append(f"  FAIL  {where}: declares a `bound:` with no `disposition:` — the "
                            f"bound belongs to a `disposition: decision`, and without the "
                            f"disposition nothing says whether the value is stated or derived")
        elif status == "active":
            report.append(f"UNCLASSIFIED  {name} — no `disposition:` says whether this entry "
                          f"states a decision (closed bound) or records a consequence")
        return
    if not isinstance(disposition, str) or disposition.strip() not in DISPOSITIONS:
        problems.append(f"  FAIL  {where}: `disposition:` must be one of "
                        f"{'/'.join(DISPOSITIONS)} (got {disposition!r})")
        return
    disposition = disposition.strip()
    if disposition == "decision":
        if not bound_text:
            problems.append(f"  FAIL  {where}: `disposition: decision` with no `bound:` — a "
                            f"decision is a closed stated value, and a decision without its "
                            f"bound is the half-stated line this rule exists to refuse")
            return
        if len(bound_text) < READ_BACK_REASON_MIN:
            problems.append(f"  FAIL  {where}: `bound:` says nothing weighable ({bound_text!r}) — "
                            f"state the closed value the decision fixes")
            return
    elif bound is not None:
        problems.append(f"  FAIL  {where}: `disposition: consequence` carries a `bound:` — a "
                        f"consequence is derived from its producer, so a hard-coded value here "
                        f"goes stale the moment the producer changes; drop the bound, or state "
                        f"the entry as a decision with the bound it really has")
        return
    report.append(f"DISPOSITION   {name} -> {disposition}"
                  + (f" ({bound_text})" if bound_text else ""))


def decision_records(repo):
    """[(name, fields, problems)] for .agents/decisions/*.md."""
    directory = os.path.join(repo, DECISION_DIR)
    records: list[tuple[str, dict[str, str], str]] = []
    problems = []
    if not os.path.isdir(directory):
        return records, [f"{DECISION_DIR}/ does not exist — no register, so no decision "
                         f"survives a session (the card's hole (c))"]
    for entry in sorted(os.listdir(directory)):
        if not entry.endswith(".md"):
            continue
        rel = f"{DECISION_DIR}/{entry}"
        text = read_lines(repo, rel)
        if text is None:
            problems.append(f"  FAIL  {rel}: cannot be read")
            continue
        lines = text.splitlines()
        if not lines or lines[0].strip() != "---":
            problems.append(f"  FAIL  {rel}: no frontmatter block (a record that cannot be "
                            f"parsed cannot be surfaced)")
            continue
        fields = {}
        closed = False
        for line in lines[1:]:
            if line.strip() == "---":
                closed = True
                break
            match = re.match(r"^([a-z][a-z-]*):\s*(.*)$", line.strip())
            if match:
                fields[match.group(1)] = match.group(2).strip()
        if not closed:
            problems.append(f"  FAIL  {rel}: frontmatter block is not closed")
            continue
        name = fields.get("name", "")
        if name != entry[:-3]:
            problems.append(f"  FAIL  {rel}: frontmatter name '{name}' does not match the "
                            f"file name '{entry[:-3]}'")
        if not ISO_DATE.match(fields.get("date", "")):
            problems.append(f"  FAIL  {rel}: `date:` must be an ISO date "
                            f"(got '{fields.get('date', '')}')")
        if fields.get("status") not in CONTRACT_STATUSES:
            problems.append(f"  FAIL  {rel}: `status:` must be one of "
                            f"{'/'.join(CONTRACT_STATUSES)} (got '{fields.get('status', '')}')")
        records.append((name or entry[:-3], fields, rel))
    return records, problems


def decision_commands(fields):
    """The command names a decision record governs (a `commands:` list)."""
    raw = fields.get("commands", "")
    return [token.strip() for token in raw.strip("[]").split(",") if token.strip()]


def run_continuity(repo, names):
    """Validate per-entry versioning/scope, and surface what still applies."""
    rel = "docs/contracts/command-contracts.yaml"
    print(f"=== Command-contract continuity ({rel} + {DECISION_DIR}/) ===")
    data, text, error = command_contracts_file(repo)
    if error:
        sys.stderr.write(f"check-contracts: {error}\n")
        return EXIT_CANNOT_RUN
    entries = data.get("commands")
    if not isinstance(entries, list) or not entries:
        sys.stderr.write("check-contracts: command-contracts.yaml declares no commands — "
                         "refusing to pass on an empty contract set.\n")
        return EXIT_CANNOT_RUN

    problems = []
    by_name: dict[str, list[dict]] = {}
    active_pairs = {}
    # The traceability oracle (card SPEC-VV-CONSOLE-003): the @test names the pytest
    # bridge would collect, plus how many files they were read from — the second
    # figure is printed so an empty index is visible rather than reading as "clean".
    test_nodes, n_bats = bats_test_nodes(repo)
    trace_lines: list[str] = []
    for entry in entries:
        if not isinstance(entry, dict):
            problems.append(f"  FAIL  {rel}: entry is not a mapping: {entry!r}")
            continue
        name = (entry.get("name") or "").strip()
        where = f"{rel}:{name}" if name else f"{rel}:<unnamed>"
        if not name:
            problems.append(f"  FAIL  {rel}: an entry declares no `name:`")
            continue
        by_name.setdefault(name, []).append(entry)
        version = entry.get("version")
        if not isinstance(version, int) or version < 1:
            problems.append(f"  FAIL  {where}: `version:` must be a positive integer "
                            f"(got {version!r}) — an edited contract is a NEW version, and the")
            problems.append("        old one is marked superseded, never deleted")
        if not ISO_DATE.match(str(entry.get("updated", ""))):
            problems.append(f"  FAIL  {where}: `updated:` must be an ISO date "
                            f"(got {entry.get('updated', '')!r})")
        scope = entry.get("scope")
        if scope not in CONTRACT_SCOPES:
            problems.append(f"  FAIL  {where}: `scope:` must be one of "
                            f"{'/'.join(CONTRACT_SCOPES)} (got {scope!r}) — scope is what lets")
            problems.append("        the interactive loader and tac-exec library mode carry "
                            "different contracts for the same command")
        status = entry.get("status")
        if status not in CONTRACT_STATUSES:
            problems.append(f"  FAIL  {where}: `status:` must be one of "
                            f"{'/'.join(CONTRACT_STATUSES)} (got {status!r})")
        target = entry.get("superseded_by")
        if status == "superseded":
            if not target:
                problems.append(f"  FAIL  {where}: status is superseded but there is no "
                                f"`superseded_by:` pointer — nothing records what replaced it")
            if not ISO_DATE.match(str(entry.get("superseded", ""))):
                problems.append(f"  FAIL  {where}: status is superseded but `superseded:` is "
                                f"not an ISO date (got {entry.get('superseded', '')!r})")
            if not entry.get("contract"):
                problems.append(f"  FAIL  {where}: a superseded entry must keep its `contract:` "
                                f"block — the old rule is the record being superseded")
        elif target:
            problems.append(f"  FAIL  {where}: declares `superseded_by:` but status is "
                            f"'{status}' — an active contract that points at its replacement "
                            f"is two live rules for one command")
        if status == "active" and scope:
            key = (name, scope)
            if key in active_pairs:
                problems.append(f"  FAIL  {where}: two ACTIVE contracts for '{name}' in the "
                                f"same scope '{scope}' — different scopes may coexist, the "
                                f"same scope may not")
            active_pairs[key] = True
        check_verified_by(entry, where, status, name, test_nodes, problems, trace_lines)
        check_disposition(entry, where, status, name, problems, trace_lines)

    for name, group in sorted(by_name.items()):
        for entry in group:
            target = entry.get("superseded_by")
            if not target:
                continue
            # The chain is walked by NAME, and a replacement may legitimately carry
            # the superseded entry's own name (v1 superseded by v2 of the same
            # command, which is the shape this file uses) — so a repeated name is a
            # loop only when it is not the same-name replacement being resolved.
            chain = [name]
            cursor = name
            for _step in range(len(by_name) + 1):
                targets = sorted({str(other.get("superseded_by")).strip()
                                  for other in by_name.get(cursor, [])
                                  if other.get("superseded_by")})
                if not targets:
                    break
                if len(targets) > 1:
                    problems.append(f"  FAIL  {rel}:{name}: two entries for '{cursor}' name "
                                    f"different replacements ({', '.join(targets)}) — which one "
                                    f"supersedes the other is not decidable from the file")
                    break
                nxt = targets[0]
                if nxt not in by_name:
                    problems.append(f"  FAIL  {rel}:{name}: superseded_by names '{nxt}', which "
                                    f"is not an entry in this file")
                    break
                active = [other for other in by_name[nxt] if other.get("status") == "active"]
                if not active:
                    problems.append(f"  FAIL  {rel}:{name}: the superseded_by chain ends at "
                                    f"'{nxt}', which is not active ({' -> '.join(chain + [nxt])})")
                    break
                if nxt == cursor:
                    break
                if nxt in chain:
                    problems.append(f"  FAIL  {rel}:{name}: the superseded_by chain loops back "
                                    f"to '{nxt}' ({' -> '.join(chain + [nxt])})")
                    break
                chain.append(nxt)
                cursor = nxt

    records, register_problems = decision_records(repo)
    problems.extend(register_problems)

    positions = {}
    surface = {}
    if os.path.isfile(os.path.join(repo, "scripts/_module-list.sh")):
        order = module_list_names(repo) or []
        positions, group_of, _f, _g = module_graph(repo, order)
        surface = command_surface(repo, sorted(positions, key=positions.get), positions, group_of)
    else:
        print("  NOT CHECKED  the decisions' `commands:` values resolve against the @exports "
              "surface only\n               when scripts/_module-list.sh is present")
    for name, fields, where in records:
        for command in decision_commands(fields):
            if surface and command not in surface:
                problems.append(f"  FAIL  {where}: decision `commands:` names '{command}', "
                                f"which no loaded module @exports")
        if fields.get("scope") not in CONTRACT_SCOPES:
            problems.append(f"  FAIL  {where}: `scope:` must be one of "
                            f"{'/'.join(CONTRACT_SCOPES)} (got {fields.get('scope', '')})")
    if not records:
        problems.append(f"  FAIL  {DECISION_DIR}/ holds no decision record — the register this")
        problems.append("        check surfaces is empty, so nothing persists an agent's")
        problems.append("        decision across sessions")

    if names:
        wanted = [" ".join(names)]
        print(f"  --- continuity for: {', '.join(wanted)} ---")
        for query in wanted:
            command = query.split()[0]
            matches = [entry for entry in entries
                       if isinstance(entry, dict)
                       and (entry.get("name") or "").strip() == query]
            if not matches:
                matches = [entry for entry in entries
                           if isinstance(entry, dict)
                           and contract_command_name(entry) == command]
            if not matches:
                print(f"  NONE     '{query}' has no contract entry — a new command with no "
                      f"recorded rule is not continuity-checked at all")
            for entry in matches:
                print(f"  ENTRY    {entry.get('name')} v{entry.get('version')} "
                      f"status={entry.get('status')} scope={entry.get('scope')} "
                      f"updated={entry.get('updated')} family={entry.get('family')}")
                if entry.get("superseded_by"):
                    print(f"           superseded {entry.get('superseded')} by "
                          f"'{entry.get('superseded_by')}'")
                if entry.get("verified_by"):
                    print("           verified_by: "
                          f"{', '.join(str(node) for node in entry['verified_by'])}")
                if entry.get("disposition"):
                    print(f"           disposition: {entry.get('disposition')}"
                          + (f" — bound: {str(entry.get('bound')).strip()}"
                             if entry.get("bound") else ""))
            family = {entry.get("family") for entry in matches if isinstance(entry, dict)}
            siblings = sorted(str(name) for name in {
                entry.get("name") for entry in entries
                if isinstance(entry, dict)
                and entry.get("family") in family
                and entry.get("name") not in {m.get("name") for m in matches}})
            if siblings:
                print(f"  FAMILY   still applies from the same family: {', '.join(siblings)}")
            related = [name for name, fields, _where in records
                       if command in decision_commands(fields)]
            if related:
                print(f"  DECISION {', '.join(related)}")

    changed_note = print_changed_entries(repo, rel)

    # The traceability report, printed before the findings like `state` prints its
    # NOT ENFORCED / NOT WITNESSED lines: an unverified entry is a stated gap, not a
    # verdict, and the count in the summary says "(printed above)" so it cannot read
    # as a number with nothing behind it.
    verified_lines = [line for line in trace_lines if line.startswith("VERIFIED")]
    unverified_lines = [line for line in trace_lines if line.startswith("NOT VERIFIED")]
    classified_lines = [line for line in trace_lines if line.startswith("DISPOSITION")]
    unclassified_lines = [line for line in trace_lines if line.startswith("UNCLASSIFIED")]
    for line in trace_lines:
        print(f"  {line}")
    for problem in problems:
        print(problem)
    n_active = sum(1 for entry in entries
                   if isinstance(entry, dict) and entry.get("status") == "active")
    superseded = sum(1 for entry in entries
                     if isinstance(entry, dict) and entry.get("status") == "superseded")
    decisions = sum(1 for line in classified_lines if "-> decision" in line)
    consequences = sum(1 for line in classified_lines if "-> consequence" in line)
    summary = (f"{len(entries)} contract entr(ies) ({n_active} active, {superseded} superseded) | "
               f"{len(records)} decision record(s) in {DECISION_DIR}/ | "
               f"verified_by: {len(verified_lines)} node(s) verified, "
               f"{len(unverified_lines)} active entr(ies) unverified (printed above) | "
               f"@test oracle: {sum(len(v) for v in test_nodes.values())} node(s) "
               f"in {n_bats} BATS file(s) | disposition: {decisions} decision(s), "
               f"{consequences} consequence(s), "
               f"{len(unclassified_lines)} active entr(ies) unclassified (printed above)")
    if problems:
        print(f"check-contracts[continuity]: FAIL — {len(problems)} finding(s). {summary}")
        print("  An edited contract is a NEW version with its predecessor marked superseded —")
        print("  never deleted — so what a rule replaced stays readable.")
        return EXIT_DRIFT
    print(f"check-contracts[continuity]: OK — {summary}")
    if changed_note:
        print("  Continuity surface: the entries listed as CHANGED above were resolved against")
        print("  the older entries that still apply, so a new or edited rule cannot land")
        print("  without the entries it supersedes in view.")
    print("  Enforced: every entry carries a positive version, an ISO updated date, a scope in")
    print("  interactive/library/both and a status in active/superseded/retired; two ACTIVE")
    print("  entries may share a name only in different scopes; a superseded entry keeps its")
    print("  contract, names its replacement and dates the supersession; every superseded_by")
    print("  chain ends at an active entry. Enforced for the register too: at least one record,")
    print("  a parseable frontmatter, a name that matches the file, an ISO date, a known status")
    print("  and scope, and `commands:` values that resolve to an exported command. Enforced")
    print("  for `verified_by:`: every declared test node exists as written, in a BATS file")
    print("  under tests/ (the same @test parser the pytest bridge uses). Enforced for")
    print("  `disposition:`: a `decision` carries a weighable `bound:` (a closed stated value), a")
    print("  `consequence` carries none (it is derived, so a hard-coded value would go stale),")
    print("  the value must be one of the two names, and a `bound:` with no `disposition:` is")
    print("  refused because nothing then says whether the value is stated or derived.")
    print("  NOT enforced here: what the contracts SAY (side_effects/output_shape/exit_code are")
    print("  prose; `state` and `swallows` enforce their own halves), and COVERAGE — an ACTIVE")
    print("  entry with no `verified_by:` is counted and printed as NOT VERIFIED, never a")
    print("  failure, because a missing test is a statement about the suite, not about the")
    print("  contract. The check proves a node EXISTS, not that the test exercises the command.")
    print("  The same posture applies to `disposition:`: an unclassified entry is counted and")
    print("  printed as UNCLASSIFIED, never a failure — the triage of a borderline line is the")
    print("  owner's call, and the check refuses an incoherent pair rather than guessing one.")
    return EXIT_CLEAN


def print_changed_entries(repo, rel):
    """Print the contract entries added or edited against HEAD; return True if any.

    The card's failure mode is that new work never triggers a check of whether an
    older decision still applies.  Reading the previous revision of the contract
    is how "newly added or edited" becomes mechanical: the diff names the
    entries, and their family and scope say which older entries to re-read.  A
    checkout with no git (a fixture) or no HEAD revision PRINTS that it could not
    run — a silent skip would look identical to "nothing changed".
    """
    try:
        shown = subprocess.run(["git", "-C", repo, "show", f"HEAD:{rel}"],
                               capture_output=True, text=True, check=False)
    except OSError as exc:
        print(f"  NOT CHECKED  changed-entry pass: git is unavailable ({exc})")
        return False
    if shown.returncode != 0:
        print(f"  NOT CHECKED  changed-entry pass: `git show HEAD:{rel}` failed "
              f"(no HEAD revision or not a git tree)")
        return False
    try:
        before = yaml.safe_load(shown.stdout) or {}
    except yaml.YAMLError as exc:
        print(f"  NOT CHECKED  changed-entry pass: the HEAD revision does not parse ({exc})")
        return False
    old = {}
    for entry in before.get("commands") or []:
        if isinstance(entry, dict) and entry.get("name"):
            old[str(entry["name"]).strip()] = entry
    changed = False
    data, _text, error = command_contracts_file(repo)
    if error:
        return False
    for entry in data.get("commands") or []:
        if not isinstance(entry, dict) or not entry.get("name"):
            continue
        name = str(entry["name"]).strip()
        was = old.get(name)
        applies = ", ".join(entry_family_siblings(data, name)) or "(none)"
        if was is None:
            changed = True
            print(f"  CHANGED  '{name}' is NEW in the working tree (v{entry.get('version')}) — "
                  f"older entries that still apply: {applies}")
            continue
        # A rule change is what needs a superseded predecessor: summary and the
        # contract block.  Adding the v2 metadata (version/updated/status/scope)
        # is bookkeeping, not a new rule, so it is deliberately NOT reported as a
        # change — otherwise a schema addition would drown the pass in noise and
        # the one real edit would be invisible among 14 bookkeeping lines.
        rule_before = (was.get("summary"), was.get("contract"))
        rule_now = (entry.get("summary"), entry.get("contract"))
        if rule_before != rule_now:
            changed = True
            print(f"  CHANGED  '{name}': the rule changed "
                  f"(v{was.get('version', '?')} -> v{entry.get('version')}). The previous")
            print(f"           revision must be kept as a superseded entry. Older entries that "
                  f"still apply: {applies}")
    if not changed:
        print("  (no contract entry was added, and no entry's summary or contract block "
              "changed, against HEAD)")
    return changed


def entry_family_siblings(data, name):
    """Names of the other entries in the same family as `name`."""
    for entry in data.get("commands") or []:
        if isinstance(entry, dict) and str(entry.get("name", "")).strip() == name:
            family = entry.get("family")
            return sorted({str(e.get("name")).strip() for e in data.get("commands") or []
                           if isinstance(e, dict) and e.get("family") == family
                           and str(e.get("name", "")).strip() != name})
    return []


# ── subcommand: swallows ────────────────────────────────────────────────────
# REF: "Coding Agents Keep Shipping Silent Failures — Here Is How to Catch Them"
#      (TDS, 2026-09-18) —
#      https://towardsdatascience.com/coding-agents-keep-shipping-silent-failures-here-is-how-to-catch-them/
#
# TOOLING HALF ONLY (card item 2).  Silent swallows are unclassified and heavy in
# the mutating modules.  Reclassifying the existing corpus is a separate pass that
# collides with files another session owns, so this subcommand does the
# count-ratchet job the repo already uses for exactly this situation
# (tools/count-ratchet.sh): the existing population is RECORDED, a NEW unclassified
# swallow is a FAILURE, and the baseline shrinks as sites are classified.
#
# DEFERRED, not attempted here (each lives in a reserved file or a later pass):
# card item 1 (read-back assertions before a success echo on model start/stop/
# switch, vault load, orphan clean, gog auth), item 3 (stale-telemetry badges in
# the dashboard render) and item 4 (injected-failure BATS cases for them).
SWALLOWS_MARKER = re.compile(r"#\s*swallow-ok:\s*(\S.*)$")
SWALLOW_PATTERNS = (("|| true", re.compile(r"\|\|\s*true\b")),
                    ("2>/dev/null", re.compile(r"2>\s*/dev/null")))
SWALLOWS_SCOPE = "scripts/*.sh, bin/*, tools/*.sh, tools/hooks/*, tools/qwen-hooks/*, nas/**/*.sh"
# Files another session owns during the tooling pass: reported with their counts,
# never edited here, so the second pass has a starting point.
SWALLOWS_RESERVED = {
    "scripts/11e-llm-model.sh": "start/stop read-backs landed (tests/unit/25-*.bats); its sites stay unclassified, which the baseline permits",
    "scripts/09d-oc-agents.sh": "reported only this pass",
    "scripts/08-maintenance.sh": "reported only: 5 pre-existing sites, untouched by the docker-prune fix (commit 39f2fb08)",
    "scripts/11d-llm-gpu.sh": "reported only this pass",
}


def swallow_sites(text):
    """[(line number, pattern name)] for every swallow site in a file's text.

    Comment-only lines are excluded; a site inside a TRAILING comment on a code
    line still counts (a deliberate over-count that keeps the counter simple and
    stable, which is what a ratchet needs).  A marker reason must therefore not
    spell a pattern itself.
    """
    sites = []
    for number, line in enumerate(text.splitlines(), 1):
        if line.lstrip().startswith("#"):
            continue
        for name, pattern in SWALLOW_PATTERNS:
            sites.extend([(number, name)] * len(pattern.findall(line)))
    return sites


def swallow_markers(text):
    """{line number: reason} for every `# swallow-ok: <reason>` marker.

    The marker is ONE comment line, and it classifies a site on its own line or on
    the line DIRECTLY below it.  Deliberately not "somewhere in the comment block
    above": a stale explanation three lines up would then silence a new swallow
    silently, which is the whole failure class this check exists to catch.  A
    wrapped marker therefore does not count — put the reason on one line and keep
    any longer explanation in the comment lines above it.
    """
    markers = {}
    for number, line in enumerate(text.splitlines(), 1):
        match = SWALLOWS_MARKER.search(line)
        if match:
            markers[number] = match.group(1).strip()
    return markers


def swallow_corpus(repo):
    """[(rel, abs)] for every shell file the swallow check scans.

    WIDENED 2026-09-24, from `scripts/*.sh` alone.  bin/ and tools/ are shell too, and
    excluding them made the reported population a PARTIAL figure — this check's own
    output said so ("the same counts outside scripts/*.sh are not scanned") — and a
    partial count cannot be ratcheted against honestly.  tools/hooks/* is in for the
    same reason: those files ARE shell, so an unscanned hook is an unmeasured decision.

    WIDENED AGAIN 2026-10-02: `nas/**/*.sh`.  The NAS (butler) tooling is mirrored into this
    repo at nas/butler/ and is shell, so leaving it out was the same unmeasured decision.  It
    is the ONE group that needs a RECURSIVE walk — its files sit two levels down (nas/butler/
    scripts/…), which a single listdir of `nas/` can never reach.  Every site in that tree was
    classified BEFORE this landed, so the baseline gains no row.

    WIDENED AGAIN 2026-10-02 (card b55c77f5): `tools/qwen-hooks/*`.  The Qwen hook set lives
    under tools/ but one listdir of `tools/` never reaches a subdirectory, so — with `tools`
    non-recursive — those files were scanned by neither this gate nor tools/lint.sh's
    whole-tree loops.  Every site was classified before this landed, so the baseline gains no
    row.

    Returns `(corpus, missing)` where `missing` is the (sub, base) of every CONFIGURED group
    whose directory is absent (card 74051862).  A missing group used to be skipped silently,
    so its baseline rows read STALE (non-fatal) and a whole vanished group passed as a fix.
    """
    groups = (("scripts", True, False), ("bin", False, False), ("tools", True, False),
              ("tools/hooks", False, False), ("tools/qwen-hooks", False, False),
              ("nas", True, True))
    corpus = []
    missing = []
    for sub, only_sh, recursive in groups:
        base = os.path.join(repo, sub)
        if not os.path.isdir(base):
            missing.append((sub, base))
            continue
        if recursive:
            for dirpath, dirnames, filenames in os.walk(base):
                dirnames[:] = sorted(d for d in dirnames if not d.startswith("."))
                for entry in sorted(filenames):
                    if entry.startswith("."):
                        continue
                    if only_sh and not entry.endswith(".sh"):
                        continue
                    full = os.path.join(dirpath, entry)
                    corpus.append((os.path.relpath(full, repo), full))
            continue
        for entry in sorted(os.listdir(base)):
            if entry.startswith("."):
                continue
            path = os.path.join(base, entry)
            if not os.path.isfile(path):
                continue
            if only_sh and not entry.endswith(".sh"):
                continue
            corpus.append((f"{sub}/{entry}", path))
    return corpus, missing


def run_swallows(repo):
    """Record and ratchet the unclassified silent swallows in the shell corpus."""
    # `--dump-sites` is the machine-readable form of this subcommand's population
    # (card SPLIT-CONTRACT-TRIAGE-001): one JSON object per site, so a consumer —
    # tools/swallow-classify.py — reads the SAME sites this check counts instead of
    # re-grepping the corpus with a second scanner that could disagree.  It is
    # read-only and never a verdict: every line of stdout is JSONL, the human-facing
    # summary goes to stderr, and the exit code is clean even when sites are
    # unclassified (this is a dump, not a check).
    dump = OPTIONS["dump_sites"]
    if dump:
        sys.stderr.write(f"=== Silent-swallow site dump ({SWALLOWS_SCOPE}) ===\n")
    else:
        print(f"=== Silent-swallow check ({SWALLOWS_SCOPE}) ===")
    corpus, missing_groups = swallow_corpus(repo)
    if not corpus:
        sys.stderr.write("check-contracts: no shell files found for the swallow check — nothing "
                         "to scan, and an empty scan is not a clean tree. Refusing to pass.\n")
        return EXIT_CANNOT_RUN
    baseline = read_baseline(repo, "tools/contracts-swallows-baseline.tsv")
    known = {}
    for key, detail in baseline.items():
        if key.startswith("unclassified\t"):
            known[key.split("\t", 1)[1]] = detail

    # A configured group whose directory is absent is a coverage loss, not a clean
    # tree (card 74051862).  Without this it was skipped silently, so its baseline rows
    # read STALE (non-fatal) and a whole vanished group passed as the fix that removed
    # its sites.  A group the baseline knows about is a FAIL (blocking); a group with no
    # baseline rows has nothing to lose and is only a named WARNING, so a partial
    # fixture tree stays usable with --repo.
    group_fail: list[str] = []
    group_warn: list[str] = []
    for sub, base in missing_groups:
        covered = any(rel.startswith(sub + "/") for rel in known)
        line = (f"  {'FAIL' if covered else 'WARNING'}  group '{sub}': configured for the "
                f"swallow corpus but {os.path.relpath(base, repo)}/ is not a directory — a "
                f"whole group was NOT scanned")
        (group_fail if covered else group_warn).append(line)

    problems = []
    rows = []
    site_rows = []
    for rel, _path in corpus:
        text = read_lines(repo, rel)
        if text is None:
            problems.append(f"  FAIL  {rel}: cannot be read")
            continue
        sites = swallow_sites(text)
        markers = swallow_markers(text)
        lines = text.splitlines()
        classified = 0
        occurrence: dict = {}
        for number, pattern_name in sites:
            reason = markers.get(number)
            source = "same-line" if reason is not None else None
            if reason is None and number - 2 >= 0:
                previous = lines[number - 2].strip()
                above = SWALLOWS_MARKER.search(previous) if previous.startswith("#") else None
                if above:
                    reason = above.group(1).strip()
                    source = "line-above"
            if reason is not None and len(reason) < 8:
                problems.append(f"  FAIL  {rel}:{number}: `# swallow-ok:` needs a reason, not "
                                f"'{reason}' — a marker with no reason is a marker no reviewer "
                                f"can weigh")
            if reason:
                classified += 1
            if dump:
                # The matched TEXT, not just the pattern's name: a pattern can match a
                # longer spelling (`||    true`), and the consumer quotes what was
                # matched.  `occurrence` keeps rows distinct when one line carries the
                # same pattern twice, which the site count above also counts twice.
                key = (number, pattern_name)
                occurrence[key] = occurrence.get(key, 0) + 1
                matched = next(p.search(lines[number - 1]) for name, p in SWALLOW_PATTERNS
                               if name == pattern_name)
                site_rows.append({
                    "file": rel,
                    "line": number,
                    "pattern": pattern_name,
                    "match": matched.group(0) if matched else pattern_name,
                    "occurrence": occurrence[key],
                    "text": lines[number - 1].strip(),
                    "classified": bool(reason),
                    "reason": reason,
                    "reason_source": source,
                    "reason_weighable": bool(reason) and len(reason) >= READ_BACK_REASON_MIN,
                })
        unclassified = len(sites) - classified
        rows.append((rel, len(sites), classified, unclassified))

    if dump:
        for site_row in site_rows:
            print(json.dumps(site_row, sort_keys=True))
        # stderr, so the JSONL on stdout stays parseable.
        for line in group_fail + group_warn:
            sys.stderr.write(line.lstrip() + "\n")
        sys.stderr.write(
            f"check-contracts[dump-sites]: {len(site_rows)} site(s) in {len(rows)} file(s) — "
            f"{sum(1 for row in site_rows if row['classified'])} classified, "
            f"{sum(1 for row in site_rows if not row['classified'])} unclassified "
            f"(read-only; the exit code is not a verdict)\n")
        return EXIT_CLEAN

    new_sites = []
    seen = set()
    if OPTIONS["print_baseline"]:
        print("# paste-ready rows for tools/contracts-swallows-baseline.tsv — the measured "
              "population:")
        for rel, _total, _classified, unclassified in rows:
            if unclassified:
                print(f"unclassified\t{rel}\t{unclassified}")
        for line in group_fail + group_warn:
            sys.stderr.write(line.lstrip() + "\n")
        return EXIT_CLEAN
    for rel, total, _classified, unclassified in rows:
        if unclassified == 0:
            continue
        if rel in known:
            seen.add(rel)
            if unclassified > int(known[rel]):
                new_sites.append(f"  FAIL  {rel}: {unclassified} unclassified swallow(s) against "
                                 f"a baseline of {known[rel]} — a NEW swallow needs a reason: "
                                 f"mark it `# swallow-ok: <why>`, or fix the swallow")
        else:
            new_sites.append(f"  FAIL  {rel}: {unclassified} unclassified swallow(s) and no "
                             f"baseline row. Mark each one on its own line or the line")
            new_sites.append("        directly above it (`# swallow-ok: <one-line reason>`), or "
                             "record the count in")
            new_sites.append("        tools/contracts-swallows-baseline.tsv as a deliberate act")
    problems.extend(new_sites)
    problems.extend(group_fail)

    stale = [rel for rel in known
             if rel not in {row[0] for row in rows}
             or next((r[3] for r in rows if r[0] == rel), 0) < int(known[rel])]
    for rel in stale:
        print(f"  STALE     {rel}: fewer unclassified swallow(s) than the baseline "
              f"({known[rel]}) — lower or delete the row in "
              f"tools/contracts-swallows-baseline.tsv")
    for line in group_warn:
        print(line)

    total_sites = sum(row[1] for row in rows)
    total_classified = sum(row[2] for row in rows)
    total_unclassified = sum(row[3] for row in rows)
    heaviest = sorted([row for row in rows if row[3]], key=lambda row: -row[3])[:6]
    print(f"  {len(rows)} file(s) scanned: {total_sites} site(s), {total_classified} classified "
          f"(`# swallow-ok:`), {total_unclassified} unclassified across "
          f"{sum(1 for row in rows if row[3])} file(s)")
    for rel, total, classified, unclassified in heaviest:
        note = SWALLOWS_RESERVED.get(rel)
        suffix = f"   <- {note}" if note else ""
        print(f"  HEAVIEST  {rel}: {total} site(s), {classified} classified, "
              f"{unclassified} unclassified{suffix}")
    per_pattern: dict[str, int] = {}
    for rel, _path in corpus:
        text = read_lines(repo, rel)
        if text is None:
            continue
        for name, pattern in SWALLOW_PATTERNS:
            hits = sum(1 for line in text.splitlines() if not line.lstrip().startswith("#")
                       and pattern.search(line))
            per_pattern[name] = per_pattern.get(name, 0) + hits
    print("  line counts (the card's `grep -c` figures, comments excluded): "
          + ", ".join(f"{name}: {count}" for name, count in sorted(per_pattern.items())))

    for problem in problems:
        print(problem)
    summary = (f"{total_sites} site(s) in {len(rows)} file(s) | {total_classified} classified | "
               f"{total_unclassified} unclassified | {len(known)} baseline row(s)")
    if problems:
        print(f"check-contracts[swallows]: FAIL — {len(problems)} finding(s). {summary}")
        print("  A new `|| true` or `2>/dev/null` is a decision: either the failure is genuinely")
        print("  optional (say why with `# swallow-ok: <reason>` on the site or the line above)")
        print("  or it is a swallow that hides a real failure. The baseline records the")
        print("  population measured on 2026-09-23; it may FALL freely, never rise unnoticed.")
        return EXIT_DRIFT
    print(f"check-contracts[swallows]: OK — {summary}")
    print("  Enforced: no NEW unclassified swallow, and every `# swallow-ok:` marker carries a")
    print("  reason. Reported, not enforced: the existing unclassified population (recorded in")
    print("  tools/contracts-swallows-baseline.tsv, printed above with the heaviest files).")
    print("  Enforced for EVERY file in the corpus above.  Not scanned: tests/ (test")
    print("  fixtures, not shipped code) and the root-level loaders (env.sh,")
    print("  tactical-console.bashrc, install.sh) — adding those is a separate decision.")
    return EXIT_CLEAN


# ── argument parsing ────────────────────────────────────────────────────────
def parse_args(argv):
    """Return (subcommands, repo, positionals) or an exit code when it is bad.

    A positional argument is a command name for `continuity` ("what still applies
    to this command?").  It is only accepted with that subcommand selected, so a
    typo'd subcommand cannot be mistaken for a command name and slip through.
    """
    selected = []
    positionals = []
    repo = REPO_ROOT
    index = 0
    while index < len(argv):
        arg = argv[index]
        if arg == "--repo":
            if index + 1 >= len(argv):
                sys.stderr.write("check-contracts: --repo needs a path\n")
                return EXIT_CANNOT_RUN, None, None, None
            repo = argv[index + 1]
            index += 2
            continue
        if arg == "--print-baseline":
            # Read-only: prints the rows the recorded baseline would need, so the
            # deliberate act of recording is a paste rather than a guess.  It never
            # writes the file.
            OPTIONS["print_baseline"] = True
            index += 1
            continue
        if arg == "--dump-sites":
            # Read-only JSONL dump of the swallow SITES (card SPLIT-CONTRACT-TRIAGE-001):
            # the machine-readable form of the population this subcommand counts, so a
            # consumer never re-greps with a second scanner that could disagree.
            OPTIONS["dump_sites"] = True
            index += 1
            continue
        if arg in ("-h", "--help"):
            print(USAGE)
            return EXIT_CLEAN, None, None, None
        if arg in SUBCOMMANDS:
            selected.append(arg)
            index += 1
            continue
        if arg.startswith("-"):
            sys.stderr.write(f"check-contracts: unknown option '{arg}'\n\n{USAGE}\n")
            return EXIT_CANNOT_RUN, None, None, None
        positionals.append(arg)
        index += 1
    if not selected:
        if positionals:
            # Keep the plain "unknown argument" wording (a typo'd subcommand is the
            # common case) and add the one thing that disambiguates it.
            sys.stderr.write(
                f"check-contracts: unknown argument '{positionals[0]}'\n"
                "  A COMMAND name is only accepted with the `continuity` subcommand, e.g.\n"
                "  `check-contracts.sh continuity model use`.\n\n" + USAGE + "\n")
            return EXIT_CANNOT_RUN, None, None, None
        selected = list(SUBCOMMANDS)
    if positionals and "continuity" not in selected:
        sys.stderr.write(
            f"check-contracts: unexpected argument(s) {' '.join(positionals)} — a COMMAND name\n"
            "  is only meaningful for `continuity`.\n")
        return EXIT_CANNOT_RUN, None, None, None
    if OPTIONS["dump_sites"]:
        # The dump is a machine-readable stream: mixing it with the baseline print or
        # with another subcommand's prose would make the JSONL unparseable, so the
        # combination is refused rather than half-honoured.  A bare invocation narrows
        # to `swallows` for the same reason.
        if OPTIONS["print_baseline"]:
            sys.stderr.write("check-contracts: --dump-sites and --print-baseline are two "
                             "read-only modes for the same population — pass one.\n")
            return EXIT_CANNOT_RUN, None, None, None
        if "swallows" not in selected and selected != list(SUBCOMMANDS):
            sys.stderr.write("check-contracts: --dump-sites is only meaningful with the "
                             "`swallows` subcommand.\n")
            return EXIT_CANNOT_RUN, None, None, None
        selected = ["swallows"]
    return None, selected, repo, positionals


def run_selected(selected, repo, positionals):
    """Dispatch each requested subcommand; return the worst exit code."""
    worst = EXIT_CLEAN
    arms = {
        "state": lambda: run_state(repo),
        "modules": lambda: run_modules(repo),
        "derived": lambda: run_derived(repo),
        "continuity": lambda: run_continuity(repo, positionals),
        "swallows": lambda: run_swallows(repo),
    }
    for name in selected:
        arm = arms.get(name)
        if arm is None:
            sys.stderr.write(f"check-contracts: subcommand '{name}' has no implementation\n")
            worst = max(worst, EXIT_CANNOT_RUN)
            continue
        # The blank separator is for a human reading prose; in `--dump-sites` mode it
        # would be a non-JSON line on stdout and break the stream contract.
        if not OPTIONS["dump_sites"]:
            print("")
        worst = max(worst, arm())
    return worst


# `_run_subcommand` is the single entry point for both paths below: SUBCOMMANDS +
# run_selected() are the extension points named in the header, and a new
# subcommand needs nothing else.
def _run_subcommand(argv):
    """Parse argv and run the selected subcommands."""
    code, selected, repo, positionals = parse_args(argv)
    if code is not None:
        return code
    if repo and not os.path.isdir(repo):
        sys.stderr.write(f"check-contracts: --repo {repo} is not a directory\n")
        return EXIT_CANNOT_RUN
    return run_selected(selected, repo, positionals)


def main(argv=None):
    """Run the selected subcommands and return the process exit code.

    *argv* defaults to this process's arguments after the program name — the repo
    root, then the subcommand options — which is exactly what the wrapper passes.
    """
    global REPO_ROOT
    args = list(sys.argv[1:] if argv is None else argv)
    REPO_ROOT = args[0]
    return _run_subcommand(args[1:])


if __name__ == "__main__":
    sys.exit(main())
