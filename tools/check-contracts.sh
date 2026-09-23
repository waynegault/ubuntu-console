#!/usr/bin/env bash
# shellcheck shell=bash
# ==============================================================================
# check-contracts.sh — Contract-drift guard for the ubuntu-console repo.
# ==============================================================================
# Card STATE-CONTRACT-VALIDATION-001.  One home for the console's drift checkers:
# this file is a SUBCOMMAND DISPATCHER, and each subcommand owns one class of
# drift.  The board decision of 2026-09-21 put all five proposed top-level
# checkers here rather than in five new tools/ scripts.
#
#   state       IMPLEMENTED.  Enforces docs/contracts/state-contracts.yaml — the
#               cross-handler state contract (who produces each variable and
#               /dev/shm cache, who consumes it, who invalidates it).
#   modules     RESERVED — not implemented here.  Owned by its own board card.
#   continuity  RESERVED — not implemented here.  Owned by its own board card.
#   derived     RESERVED — not implemented here.  Owned by its own board card.
#   swallows    RESERVED — not implemented here.  Owned by its own board card.
#
# A reserved name exits 2 with a message saying so.  A bare `check-contracts.sh`
# runs every IMPLEMENTED subcommand (today: `state`), so the no-argument
# invocation stays meaningful as subcommands are added.  A subcommand is added by
# adding its name to SUBCOMMANDS and giving it an arm in run_selected() (plus a
# matching run_<name>() checker) — nothing else in this file needs to know.
#
# WHY `state` EXISTS — the failure it catches:
# The article this card cites names the "cross-handler state disconnect": handler
# A clears or changes state that handler B still reads; neither references the
# other, so each looks fine alone.  2026-09-22: renaming /dev/shm/active_llm, or
# deleting the write in scripts/11e-llm-model.sh, degrades the dashboard with NO
# error anywhere — the cache read just returns empty and the row falls back to a
# default.  Before this checker, docs/contracts/state-contracts.yaml was prose:
# nothing parsed it, so every declared edge was unverified documentation.
#
# ENFORCED, per entry (fails name the symbol, the file, and a line when there is
# one to name):
#   1. the contract parses, and every entry is structurally complete (a name or
#      path, a producer, at least one consumer edge, and a `why:` on every edge
#      marked `unenforced: true`);
#   2. no two entries declare the same symbol;
#   3. every declared producer file exists, and the producer set contains a
#      WRITE of the entry:
#        variable -> an assignment of that name, including the guarded form
#                    `... && NAME=$(< cache)`, but never a bare read of it;
#        file     -> a binding whose right-hand side is the path
#                    (`local cache="$TAC_CACHE_DIR/tac_hostmetrics"`) or a
#                    redirect/mutating command whose TARGET holds it
#                    (`> "${ACTIVE_LLM_FILE}.tmp"`).  A command substitution on
#                    the right (`tps=$(cat "$LLM_TPS_CACHE")`) is a READ and does
#                    not count.  A DELETE (`rm -f "$CACHE"`) never satisfies a
#                    producer edge — that is what `invalidators:` is for; with
#                    `rm` counted as a write, `rm -f "$ACTIVE_LLM_FILE"` passed as
#                    the producer of /dev/shm/active_llm and the real write could
#                    be deleted unnoticed (measured 2026-09-22);
#   4. the declared PATH of a file entry is still bound somewhere in its producer
#      set.  Without this, a renamed cache hides behind the variable name: every
#      consumer reads `$ACTIVE_LLM_FILE`, so the entry survived renaming the path
#      to /dev/shm/active_model.  Measured on a fixture;
#   5. every declared consumer file exists, and references the entry (the symbol,
#      the path, any declared binding, or an edge-level `via:`);
#   6. every declared invalidator file exists, and deletes the entry;
#   7. the number of entries parsed equals the number of `- name:`/`- path:`
#      entries in the file, so a schema change cannot silently stop an entry
#      from being checked;
#   8. a producer/consumer that is a thin loader (`__tac_source_submodules`) is
#      expanded to itself plus its named sub-modules — and a sub-module the
#      loader names but that does not exist is a failure.
#
# NOT ENFORCED (stated, never silently skipped — the summary prints both counts):
#   * a file that references a declared symbol WITHOUT being declared as an edge
#     is invisible: the check is over declared edges.  Re-deriving "every file that
#     touches this symbol" is a separate exercise — the 2026-09-22 revision did it
#     by hand and found several undeclared references, each now declared (VSCODE_BIN
#     read by §11f, TACTICAL_PROFILE_VERSION read by §9e, the 0-placeholder
#     assignments of __TAC_OPENCLAW_OK / LAST_TPS in §1, and bash-errors.log
#     written by §13 and by scripts/_startup-env.sh).
#   * `type`, `format`, `semantics`, `translation_rules` and `notes` are prose.
#   * an edge the contract marks `unenforced: true` (with a required `why:`).
#   * tokens are SUBSTRING matches, so a rename that keeps the declared token as a
#     prefix (`tac_hostmetrics` -> `tac_hostmetrics2`) is not caught, and a
#     producer edge proves a write-shaped declaration still exists in the file —
#     not that its target is still reached at run time (the BATS suites cover the
#     behaviour).
#   * the check reads SOURCE, so an edge that only exists at run time (a variable
#     passed through the environment, a file written by an external tool) can only
#     be declared, not verified.
#
# Usage:
#   tools/check-contracts.sh                  # every implemented subcommand
#   tools/check-contracts.sh state            # just the state contract
#   tools/check-contracts.sh state --repo DIR # check another checkout (tests)
#   tools/check-contracts.sh --version
#
# Exit 0 = every enforced edge holds.
# Exit 1 = contract drift (a producer stopped producing, a consumer stopped
#          reading, a file disappeared, or the contract itself is incomplete).
# Exit 2 = bad invocation, or the check cannot run (no python3, no PyYAML,
#          contract file absent or unparseable).  Never a weaker parse.
#
# REF: "Coding Agents Keep Shipping Silent Failures — Here Is How to Catch Them"
#      (TDS, 2026-09-18) —
#      https://towardsdatascience.com/coding-agents-keep-shipping-silent-failures-here-is-how-to-catch-them/
# ==============================================================================
# AI INSTRUCTION: Increment version on significant changes.
# Module Version: 1
# @modular-section: contracts
# @depends: none (standalone CI helper; needs python3 with PyYAML)
# @exports: (none — standalone script, not sourced)
VERSION="1"
set -euo pipefail

# --version is pure bash: a version query must not depend on the YAML engine.
if [[ "${1:-}" == "--version" || "${1:-}" == "-V" ]]; then
    echo "check-contracts $VERSION"
    exit 0
fi

# Default to the repository this script lives in (the tools/ convention),
# overridable with --repo so a throwaway fixture tree can be checked.
_repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# The repo's python (see the project rules: system python lacks the deps in some
# environments); fall back to PATH so a fixture tree with no venv still works.
_python="python3"
if [[ -x "$_repo_root/.venv/bin/python3" ]]; then
    _python="$_repo_root/.venv/bin/python3"
fi
if ! command -v "$_python" >/dev/null 2>&1; then
    printf '%s\n' "check-contracts: python3 not found (needed to parse the contract YAML)" >&2
    exit 2  # cannot run the check
fi

# One program, all arguments: parsing --repo / the subcommand / usage errors in
# one place keeps the dispatch table and the error text together.
exec "$_python" - "$_repo_root" "$@" <<'PYEOF'
"""Enforce docs/contracts/state-contracts.yaml. See the script header for scope."""
import os
import re
import sys

try:
    import yaml
except ImportError:
    sys.stderr.write(
        "check-contracts: PyYAML is required to parse the contract, and is not importable.\n"
        "  Install it (pip install pyyaml) or run with the repo's .venv python.\n"
        "  Refusing to fall back to a weaker parse — a partial contract check is a silent pass.\n"
    )
    sys.exit(EXIT_CANNOT_RUN)

REPO_ROOT = sys.argv[1]
ARGV = sys.argv[2:]
SUBCOMMANDS = ("state",)
RESERVED = {"modules": "module-graph / module-list drift",
            "continuity": "cross-handler state continuity",
            "derived": "derived and computed value drift",
            "swallows": "silently swallowed errors"}

# Exit codes, the same three the header documents.  Named rather than repeated as
# bare digits so each `return` site says what it means.
EXIT_CLEAN = 0
EXIT_DRIFT = 1
EXIT_CANNOT_RUN = 2

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

usage: check-contracts.sh [SUBCOMMAND] [--repo DIR]

  (no SUBCOMMAND)  run every implemented subcommand
  state            docs/contracts/state-contracts.yaml — cross-handler state
  --version, -V    print the tool version and exit

Reserved, NOT implemented here (each exits 2 and names its owner):
  modules, continuity, derived, swallows — see the header of this script.

options:
  --repo DIR       check the checkout at DIR instead of this repository

exit: 0 clean · 1 contract drift · 2 bad invocation / cannot run the check"""


# ── findings ────────────────────────────────────────────────────────────────
# ENTITY_LINES maps a declared symbol to the line of the contract entry that
# declares it.  Every finding names that line, so a failure points at both the
# code that stopped matching AND the contract claim that is now stale.  (A
# missing file or a missing reference has no line of its own to name; the
# declaration line is the one a reader needs to act on.)
ENTITY_LINES = {}


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


def check_consumers(kind, entry, consumers, repo, problems, counts):
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


def check_producers(kind, entry, repo, problems, counts):
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


def check_invalidators(kind, entry, repo, problems, counts):
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
    lines = {}
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
    problems = []
    symbols = {}
    counts = {"producer": 0, "consumer": 0, "invalidator": 0, "unenforced": 0,
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

    for line in counts["unenforced_lines"]:
        print(f"  {line}")
    for problem in problems:
        print(problem)
    edges = counts["producer"] + counts["consumer"] + counts["invalidator"]
    summary = (f"{entries_seen} entries ({declared} declared) | enforced edges: "
               f"{counts['producer']} producer, {counts['consumer']} consumer, "
               f"{counts['invalidator']} invalidator | declared-unenforced edges: "
               f"{counts['unenforced']} (printed above)")
    if problems:
        print(f"check-contracts[state]: FAIL — {len(problems)} finding(s). {summary}")
        print("  Fix the contract or the code (both are wrong if they disagree); an edge that")
        print("  cannot be checked must be declared `unenforced: true` with a `why:`.")
        return EXIT_DRIFT
    print(f"check-contracts[state]: OK — {summary}")
    print("  Coverage limits, not enforced by construction: a file that reads a declared")
    print("  symbol without being declared is invisible here; the type/format/semantics/")
    print("  notes/translation_rules prose fields are not machine-checked.")
    return 0


# ── argument parsing ────────────────────────────────────────────────────────
def parse_args(argv):
    """Return (subcommands, repo) or an exit code when the invocation is bad."""
    selected = []
    repo = REPO_ROOT
    index = 0
    while index < len(argv):
        arg = argv[index]
        if arg == "--repo":
            if index + 1 >= len(argv):
                sys.stderr.write("check-contracts: --repo needs a path\n")
                return EXIT_CANNOT_RUN, None, None
            repo = argv[index + 1]
            index += 2
            continue
        if arg in ("-h", "--help"):
            print(USAGE)
            return EXIT_CLEAN, None, None
        if arg in RESERVED:
            sys.stderr.write(
                f"check-contracts: subcommand '{arg}' is reserved but NOT implemented here.\n"
                f"  It is owned by its own board card ({RESERVED[arg]}) and will land as a\n"
                "  SUBCOMMANDS entry plus a run_<name>() arm in run_selected().\n")
            return EXIT_CANNOT_RUN, None, None
        if arg in SUBCOMMANDS:
            selected.append(arg)
            index += 1
            continue
        sys.stderr.write(f"check-contracts: unknown argument '{arg}'\n\n{USAGE}\n")
        return EXIT_CANNOT_RUN, None, None
    if not selected:
        selected = list(SUBCOMMANDS)
    return None, selected, repo


def run_selected(selected, repo):
    """Dispatch each requested subcommand; return the worst exit code."""
    worst = EXIT_CLEAN
    for name in selected:
        if name == "state":
            code = run_state(repo)
        else:
            sys.stderr.write(f"check-contracts: subcommand '{name}' has no implementation\n")
            code = 2
        worst = max(worst, code)
    return worst


# `_run_subcommand` is the single entry point for both paths below: SUBCOMMANDS +
# run_selected() are the extension points named in the header, and a new
# subcommand needs nothing else.
def _run_subcommand(argv):
    """Parse argv and run the selected subcommands."""
    code, selected, repo = parse_args(argv)
    if code is not None:
        return code
    if repo and not os.path.isdir(repo):
        sys.stderr.write(f"check-contracts: --repo {repo} is not a directory\n")
        return EXIT_CANNOT_RUN
    return run_selected(selected, repo)


sys.exit(_run_subcommand(ARGV))
PYEOF

# end of file
