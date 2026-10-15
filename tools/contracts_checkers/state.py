import os
import re
import sys

import yaml

from .core import (
    ASSIGN, COMMENT, DELETE, ENTRY_LINE, ENTITY_LINES, EXIT_CANNOT_RUN, EXIT_DRIFT,
    MUTATE, READ_BACK_REASON_MIN, REDIRECT, SUBMODULE_ARG, SUBMODULE_CALL,
    _StateCounts, _WitnessCounts, fail, read_lines,
)
from .derived import command_contracts_file, contract_command_name
from .modules import (
    command_surface, defined_names, loader_submodules, module_graph, module_list_names,
)

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
def entry_symbol(kind: str, entry: dict) -> str | None:
    """The symbol an entry declares: the variable name, or the path's basename.

    `None` — not a coerced ``""`` — when the entry declares no name at all, so the caller
    can tell "no symbol" from "a symbol that happens to be empty".  The registry that
    receives this is typed ``dict[str, str]``, and a ``None`` key could never be looked up
    anyway: the only read is guarded by the symbol being truthy.
    """
    if kind == "variables":
        name = entry.get("name")
        return str(name) if name is not None else None
    path = entry.get("path")
    return os.path.basename(str(path)) if path is not None else None


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
    ENTITY_LINES.clear()
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
            if symbol is not None:
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
    surface = command_surface(repo, sorted(positions, key=lambda name: positions[name]), positions, group_of)

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
