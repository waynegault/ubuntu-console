import os
import re
import sys

from .core import (
    EXIT_CANNOT_RUN, EXIT_CLEAN, EXIT_DRIFT, SUBMODULE_ARG, SUBMODULE_CALL,
    _CheckerOptions, read_baseline, read_lines,
)

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
def run_modules(repo, options: _CheckerOptions):
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
    for module in sorted(positions, key=lambda name: positions[name]):
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
            # `csv_tokens` answers None only for an ABSENT @exports field, which the branch
            # above has already reported and this `else` excludes — two facts that live in
            # different expressions, so the empty fallback is spelled out rather than
            # assumed by the checker.
            for token in exports or []:
                if token not in defined:
                    problems.append(
                        f"  FAIL  {module}: @exports names '{token}', which is not defined\n"
                        f"        as a function, alias or variable in scripts/{module}.sh "
                        f"or its load unit")
        resolved = []
        # `declared_depends` answers None only alongside a `problem`, which the guard above
        # has already consumed, so there is nothing to iterate when it fires.
        for token in tokens or []:
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
        # Same contract as `declared_depends`: None comes only with the `problem` above.
        for token in use_tokens or []:
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
    if options["print_baseline"]:
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
    for members in strongly_connected(edges, sorted(positions, key=lambda name: positions[name])):
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
