import os
import re
import subprocess
import sys

import yaml

from .core import (
    EXIT_CANNOT_RUN, EXIT_CLEAN, EXIT_DRIFT,
    READ_BACK_REASON_MIN, read_lines,
)
from .derived import command_contracts_file, contract_command_name
from .modules import command_surface, module_graph, module_list_names

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


def check_superseded_chains(by_name, rel, problems):
    """Require each superseded-by chain to resolve unambiguously to an active entry."""
    for name, group in sorted(by_name.items()):
        for entry in group:
            target = entry.get("superseded_by")
            if not target:
                continue
            # A same-name replacement is valid (v1 to v2); only a later revisit
            # to an earlier name is a cycle.
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


def validate_contract_entries(entries, rel, test_nodes):
    """Validate each command row and collect names and traceability report lines."""
    problems = []
    by_name: dict[str, list[dict]] = {}
    active_pairs = set()
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
                                "same scope may not")
            active_pairs.add(key)
        check_verified_by(entry, where, status, name, test_nodes, problems, trace_lines)
        check_disposition(entry, where, status, name, problems, trace_lines)
    return by_name, trace_lines, problems


def validate_decision_records(repo, records, problems):
    """Validate decision command references against the loaded module surface."""
    surface = {}
    if os.path.isfile(os.path.join(repo, "scripts/_module-list.sh")):
        order = module_list_names(repo) or []
        positions, group_of, _files, _groups = module_graph(repo, order)
        surface = command_surface(
            repo, sorted(positions, key=lambda name: positions[name]), positions, group_of,
        )
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


def print_continuity_lookup(entries, names, records):
    """Print the named contract, its family siblings, and governing decisions."""
    if not names:
        return
    query = " ".join(names)
    command = query.split()[0]
    print(f"  --- continuity for: {query} ---")
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
    matched_names = {entry.get("name") for entry in matches}
    siblings = sorted(str(name) for name in {
        entry.get("name") for entry in entries
        if isinstance(entry, dict)
        and entry.get("family") in family
        and entry.get("name") not in matched_names})
    if siblings:
        print(f"  FAMILY   still applies from the same family: {', '.join(siblings)}")
    related = [name for name, fields, _where in records
               if command in decision_commands(fields)]
    if related:
        print(f"  DECISION {', '.join(related)}")


def print_continuity_result(entries, records, test_nodes, n_bats, trace_lines, problems,
                            changed_note):
    """Print traceability/finding counts and the final continuity verdict."""
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

    # The traceability oracle (card SPEC-VV-CONSOLE-003): the @test names the pytest
    # bridge would collect, plus how many files they were read from — the second
    # figure is printed so an empty index is visible rather than reading as "clean".
    test_nodes, n_bats = bats_test_nodes(repo)
    by_name, trace_lines, problems = validate_contract_entries(entries, rel, test_nodes)

    check_superseded_chains(by_name, rel, problems)

    records, register_problems = decision_records(repo)
    problems.extend(register_problems)
    validate_decision_records(repo, records, problems)
    print_continuity_lookup(entries, names, records)

    changed_note = print_changed_entries(repo, rel)
    return print_continuity_result(
        entries, records, test_nodes, n_bats, trace_lines, problems, changed_note,
    )


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
