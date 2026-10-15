import os
import re
import sys

import yaml

from .core import EXIT_CANNOT_RUN, EXIT_CLEAN, EXIT_DRIFT, read_lines
from .modules import command_surface, module_graph, module_list_names

# ── subcommand: derived ─────────────────────────────────────────────────────
def command_contracts_file(repo) -> tuple[dict, str | None, str | None]:
    """(data, text, error) for docs/contracts/command-contracts.yaml.

    `data` is ALWAYS a mapping — empty on every error path — so a caller that has checked
    `error` can use it without also having to prove it exists.  `error` is the one value
    that says whether the read was usable.  A three-tuple cannot express that invariant, so
    it is kept by construction instead: returning `None` made all four callers index a
    value no checker could tell was present.
    """
    rel = "docs/contracts/command-contracts.yaml"
    path = os.path.join(repo, rel)
    if not os.path.isfile(path):
        return {}, None, f"{rel} not found"
    text = read_lines(repo, rel)
    if text is None:
        return {}, None, f"{rel} cannot be read"
    try:
        data = yaml.safe_load(text)
    except yaml.YAMLError as exc:
        return {}, None, f"{rel} does not parse: {exc}"
    if not isinstance(data, dict):
        return {}, None, f"{rel} is not a mapping"
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
    surface = command_surface(repo, sorted(positions, key=lambda name: positions[name]), positions, group_of)
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
