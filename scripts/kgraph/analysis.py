"""Per-call code-health analyses — the capability ported from investigator's graphify suite.

WHY THIS MODULE EXISTS (Wayne, 2026-11-26).  investigator's `graphify_analysis/`
carries four analyses kgraph did not: `isolated_nodes`, `unused_call_edges`,
`call_frequency` and `test_coverage`.  Porting them here is what "kgraph can do at
least what graphify does" means in practice.  The SEMANTICS follow graphify's
scripts (read, not assumed); the MECHANISM does not, because kgraph's graph is
typed and already carries caller identity — graphify reconstructs a Claude-shaped
graph from JSON, kgraph reads its own.

WHAT IS PORTED.  All four: `isolated_symbols`, `unresolved_calls`, `test_coverage`
and `call_frequency`.  The first three read the graph.  `call_frequency` cannot —
kgraph emits ONE edge per (caller, callee) on purpose, so a traversal is not
inflated, and the count is therefore an overlay computed from source, exactly as
graphify's own `call_frequency` does it.  It needs the source root and is the only
function here that touches files.

THE HONESTY CONSTRAINT (sharpened by three failed text oracles the same day): these
functions never decide that code is DEAD.  They report measurements a human reads — a
symbol with almost no wiring, a call whose target never resolved, a function no test
reaches, and how often a caller calls a callee.  `isolated_symbols` in particular is a
WIRING GAP signal: an entry point (`main`, a systemd `ExecStart` target, a bash
function a user types) legitimately has degree ≤ 1, so a non-empty list is expected
and is not a defect list.  The dead-code BAR lives in tools/kgraph_deadcode_audit.py
and is unmet.
"""

from __future__ import annotations

import ast
from collections import Counter, defaultdict
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from .models import Graph

# Node types that describe a DOCUMENT or a CONCEPT rather than a callable symbol.
# graphify excluded these from its isolated-symbol count for the same reason: a file
# node's degree says nothing about whether a function is wired.
_NON_SYMBOL_TYPES = frozenset({"file", "module", "concept", "rationale", "chunk", "cluster", "memory", "life_index"})


def _index(graph: Graph) -> tuple[dict[str, Any], dict[str, list[Any]], dict[str, list[Any]]]:
    """(nodes_by_id, outgoing edges by source, incoming edges by target)."""
    nodes = {n.id: n for n in graph.nodes}
    out: dict[str, list[Any]] = defaultdict(list)
    inc: dict[str, list[Any]] = defaultdict(list)
    for edge in graph.edges:
        out[edge.source].append(edge)
        inc[edge.target].append(edge)
    return nodes, out, inc


def _is_code_node(node: Any) -> bool:
    """True for a node the AST extractor produced.

    The store holds TWO graphs — the code graph (`ast_*`) and the memory graph
    (claims, syntheses, entities).  A memory claim has no callers by construction, so
    counting it as an "isolated symbol" floods the report: the first run showed 983
    rows, most of them claims.  Analyses of code wiring must read code nodes only.
    """
    return str(getattr(node, "id", "")).startswith("ast_")


def _is_test_path(path: str) -> bool:
    """A source path that ships with the test suite rather than the product."""
    lowered = path.replace("\\", "/").lower()
    return "/tests/" in f"/{lowered}" or lowered.startswith("tests/")


@dataclass(frozen=True)
class IsolatedSymbol:
    """A callable-ish node with almost no wiring.  A GAP SIGNAL, not a verdict."""

    node_id: str
    label: str
    node_type: str
    file: str
    degree: int
    # degree 1 is usually a lone `defines` edge: defined, never referenced.  It is a
    # weaker signal than degree 0 (no edge at all) and the report keeps them apart,
    # because collapsing them is how "973 isolated symbols" becomes meaningless.
    defined_only: bool = False


@dataclass(frozen=True)
class UnresolvedCall:
    """A call site whose target is not a function this graph knows."""

    node_id: str
    label: str
    referenced_by: tuple[str, ...]
    in_tests: bool
    external: bool = False


@dataclass(frozen=True)
class CoverageReport:
    """Which functions a test file reaches, by call edge."""

    covered: tuple[str, ...] = ()
    uncovered: tuple[str, ...] = ()
    total: int = 0

    @property
    def ratio(self) -> float:
        return (len(self.covered) / self.total) if self.total else 0.0


@dataclass(frozen=True)
class CallFrequency:
    """Call sites counted per (caller, callee), sorted by count then name."""

    pairs: tuple[tuple[str, str, int], ...] = ()
    total_calls: int = 0


@dataclass(frozen=True)
class DeadcodeReport:
    isolated: tuple[IsolatedSymbol, ...] = ()
    unresolved: tuple[UnresolvedCall, ...] = ()
    coverage: CoverageReport = field(default_factory=CoverageReport)
    by_language: dict[str, int] = field(default_factory=dict)
    frequency: CallFrequency = field(default_factory=CallFrequency)


def isolated_symbols(graph: Graph) -> tuple[IsolatedSymbol, ...]:
    """Symbols whose total degree is ≤ 1, excluding files and concepts.

    Ported from graphify's `isolated_nodes` (degree ≤ 1, no file node, no bare
    `name()` stub, no concept).  A `.name()` label is a method stub in graphify's
    graph; kgraph does not emit that shape, so the check is kept only for labels
    that literally look like it, to stay faithful if such a node ever appears.
    """
    nodes, out, inc = _index(graph)
    found: list[IsolatedSymbol] = []
    for node_id, node in nodes.items():
        # A call SITE is not a symbol: graphify models calls as edges, so its
        # isolated set holds functions and classes only.  Counting call nodes put
        # /usr/bin/smbd and `bats` in the list on the first run.
        if node.type in _NON_SYMBOL_TYPES or node.type == "call" or not _is_code_node(node):
            continue
        label = node.label or ""
        if not label or label.startswith(".") and label.endswith("()"):
            continue
        degree = len(out.get(node_id, ())) + len(inc.get(node_id, ()))
        if degree <= 1:
            found.append(
                IsolatedSymbol(
                    node_id=node_id,
                    label=label,
                    node_type=node.type,
                    file=node.file,
                    degree=degree,
                    defined_only=degree == 1,
                )
            )
    return tuple(sorted(found, key=lambda s: (s.file, s.label)))


# A call whose NAME is a path or a well-known external program is not a missing
# function definition — it is a command the graph was never going to resolve.
_EXTERNAL_BUILTINS = frozenset(
    {
        "bats",
        "cat",
        "cd",
        "chmod",
        "cp",
        "curl",
        "cut",
        "date",
        "df",
        "dirname",
        "du",
        "echo",
        "find",
        "git",
        "grep",
        "gzip",
        "head",
        "hostname",
        "jq",
        "kill",
        "ln",
        "ls",
        "mkdir",
        "mktemp",
        "mv",
        "nvidia-smi",
        "pgrep",
        "pkill",
        "printf",
        "ps",
        "python3",
        "read",
        "realpath",
        "rm",
        "sed",
        "seq",
        "sha256sum",
        "sleep",
        "sort",
        "sqlite3",
        "stat",
        "systemctl",
        "tail",
        "tar",
        "tee",
        "test",
        "timeout",
        "touch",
        "tr",
        "truncate",
        "uniq",
        "unzip",
        "wc",
        "which",
        "xargs",
        "zcat",
    }
)


def _looks_external(name: str) -> bool:
    return name.startswith("/") or name.startswith(".") or name.split(" ")[0] in _EXTERNAL_BUILTINS


def unresolved_calls(graph: Graph) -> tuple[UnresolvedCall, ...]:
    """Call sites with no edge to a function definition.

    Ported from graphify's `classify_unused_call_edges`, reduced to the part kgraph
    can state truthfully: a call node that no `calls` edge reaches a FUNCTION is
    unresolved — typically a builtin, an external command, or dynamic dispatch.  The
    test/production split is reported so the reader can ignore the first, which is
    how graphify's report buckets them.
    """
    nodes, out, inc = _index(graph)
    unresolved: list[UnresolvedCall] = []
    for node_id, node in nodes.items():
        if node.type != "call" or not _is_code_node(node):
            continue
        resolved = any(
            edge.label == "calls" and (target := nodes.get(edge.target)) and target.type == "function"
            for edge in out.get(node_id, ())
        )
        if resolved:
            continue
        referencing_files = tuple(
            sorted(
                nodes.get(edge.source).file or edge.source
                for edge in inc.get(node_id, ())
                if (nodes.get(edge.source) is not None)
            )
        )
        unresolved.append(
            UnresolvedCall(
                node_id=node_id,
                label=node.label or "",
                referenced_by=referencing_files,
                in_tests=bool(referencing_files) and all(_is_test_path(p) for p in referencing_files),
                external=_looks_external(node.label or ""),
            )
        )
    return tuple(sorted(unresolved, key=lambda u: u.label))


def test_coverage(graph: Graph) -> CoverageReport:
    """Functions a test file reaches through a call edge.

    Ported from graphify's `test_coverage`, which asks whether a test reaches a
    module.  kgraph answers at FUNCTION granularity because it now has caller
    identity: a function is covered when a call node its callers include is
    referenced by a file under tests/.  Module-level coverage is the union of its
    functions, so this is strictly finer.
    """
    nodes, out, inc = _index(graph)
    covered: set[str] = set()
    functions = {nid for nid, n in nodes.items() if n.type == "function"}
    for call_id, edges in inc.items():
        call_node = nodes.get(call_id)
        if call_node is None or call_node.type != "call":
            continue
        # A call node is test-reachable when any file that references it is a test.
        test_reachable = any(
            _is_test_path(nodes.get(e.source).file or "")
            for e in edges
            if nodes.get(e.source) is not None and nodes.get(e.source).type == "file"
        )
        if not test_reachable:
            continue
        for edge in out.get(call_id, ()):
            if edge.label == "calls" and edge.target in functions:
                covered.add(edge.target)
    uncovered = functions - covered
    return CoverageReport(
        covered=tuple(sorted(covered)),
        uncovered=tuple(sorted(uncovered)),
        total=len(functions),
    )


def build_report(graph: Graph, source_root: Path | None = None) -> DeadcodeReport:
    """Every analysis; call frequency only when a source root is supplied."""
    isolated = isolated_symbols(graph)
    by_language: Counter[str] = Counter()
    nodes, _, _ = _index(graph)
    for symbol in isolated:
        node = nodes.get(symbol.node_id)
        by_language[node.language or "?"] += 1
    return DeadcodeReport(
        isolated=isolated,
        unresolved=unresolved_calls(graph),
        coverage=test_coverage(graph),
        by_language=dict(sorted(by_language.items())),
        frequency=call_frequency(graph, source_root) if source_root else CallFrequency(),
    )


def format_report(report: DeadcodeReport, *, show_all: bool = False, limit: int = 20) -> str:
    """Render the report.  Every section states what it does NOT mean."""
    lines: list[str] = []
    isolated = report.isolated
    unwired = [s for s in isolated if not s.defined_only]
    defined_only = [s for s in isolated if s.defined_only]
    lines.append(f"ISOLATED SYMBOLS  ({len(unwired)} with no edge, {len(defined_only)} defined but never referenced)")
    lines.append("  a WIRING GAP signal, not dead code: entry points (main, a systemd")
    lines.append("  ExecStart target, a function a user types) legitimately have degree <= 1")
    if report.by_language:
        lines.append("  by language: " + ", ".join(f"{k}={v}" for k, v in report.by_language.items()))
    for symbol in isolated if show_all else unwired[:limit]:
        lines.append(f"    {symbol.label}  [{symbol.node_type}] {symbol.file}")
    if not show_all and len(unwired) > limit:
        lines.append(f"    ... {len(unwired) - limit} more with no edge (--deadcode-all)")

    unresolved = report.unresolved
    external = [u for u in unresolved if u.external]
    prod = [u for u in unresolved if not u.in_tests and not u.external]
    lines.append("")
    lines.append(
        f"UNRESOLVED CALL SITES  ({len(unresolved)}: {len(external)} external command, "
        f"{len(prod)} code call with no known target)"
    )
    lines.append("  a call whose target is not a known function: builtin, external")
    lines.append("  command, or dynamic dispatch. NOT a dead-code claim about the callee")
    for call in prod if show_all else prod[:limit]:
        lines.append(f"    {call.label}")

    if not show_all and len(prod) > limit:
        lines.append(f"    ... {len(prod) - limit} more (--deadcode-all)")

    coverage = report.coverage
    lines.append("")
    lines.append(
        f"TEST COVERAGE  {len(coverage.covered)}/{coverage.total} functions reachable "
        f"from a test file ({coverage.ratio * 100:.1f}%)"
    )
    lines.append("  reachability by call edge, not execution: a function called only")
    lines.append("  from untested code counts as uncovered even if it runs in production")
    uncovered = coverage.uncovered
    for name in uncovered if show_all else uncovered[:limit]:
        lines.append(f"    uncovered: {name}")
    if not show_all and len(uncovered) > limit:
        lines.append(f"    ... {len(uncovered) - limit} more (--deadcode-all)")

    frequency = report.frequency
    lines.append("")
    lines.append(
        f"CALL FREQUENCY  ({frequency.total_calls} call sites, {len(frequency.pairs)} distinct caller->callee pairs)"
    )
    lines.append("  counted from SOURCE, not from the graph: kgraph emits one edge per")
    lines.append("  pair, so the graph cannot say how often a callee is called")
    if frequency.pairs:
        for caller, callee, count in frequency.pairs if show_all else frequency.pairs[:limit]:
            lines.append(f"    {caller} -> {callee}  x{count}")
    else:
        lines.append("    (no source root given: pass --repo to count frequency)")
    return "\n".join(lines)


# ── call frequency: the one analysis that needs SOURCE, not the graph ──────────
def _python_pairs(path: Path) -> Counter[tuple[str, str]]:
    """(caller, callee) counts for one Python file, by real call occurrences."""
    try:
        tree = ast.parse(path.read_text(encoding="utf-8", errors="replace"))
    except SyntaxError, OSError:
        return Counter()

    pairs: Counter[tuple[str, str]] = Counter()
    stack: list[str] = ["<module>"]

    class Visitor(ast.NodeVisitor):
        def _func(self, node: ast.FunctionDef | ast.AsyncFunctionDef) -> None:
            stack.append(node.name)
            try:
                self.generic_visit(node)
            finally:
                stack.pop()

        visit_FunctionDef = _func
        visit_AsyncFunctionDef = _func

        def visit_Call(self, node: ast.Call) -> None:
            func = node.func
            name = func.id if isinstance(func, ast.Name) else func.attr if isinstance(func, ast.Attribute) else ""
            if name:
                pairs[(stack[-1], name)] += 1
            self.generic_visit(node)

    Visitor().visit(tree)
    return pairs


def _bash_pairs(path: Path) -> Counter[tuple[str, str]]:
    """(caller, callee) counts for one shell file.

    Reuses the extractor's own node helpers rather than re-deriving them: the same
    `_enclosing_function` that names a caller for the graph names it here, so the
    overlay and the graph cannot disagree about who the caller is.
    """
    try:
        import tree_sitter_bash
        from tree_sitter import Language, Parser
    except ImportError as exc:  # pragma: no cover - optional dependency
        # A missing grammar is reported, not silently treated as "no calls".
        import logging

        logging.getLogger(__name__).debug("tree-sitter-bash unavailable: %s", exc, exc_info=True)
        return Counter()

    from .ast_extractor import _enclosing_function, _node_text

    source = path.read_bytes()
    parser = Parser(Language(tree_sitter_bash.language()))
    pairs: Counter[tuple[str, str]] = Counter()

    def walk(node) -> None:
        if node.type == "command":
            name_node = next((c for c in node.children if c.type == "command_name"), None)
            if name_node is not None:
                callee = _node_text(name_node, source).strip().strip("'\"")
                # Require a bare name: `/usr/bin/x` and `$(cmd)` are not a caller/callee
                # pair inside this codebase, and counting them would inflate the table
                # with commands no source file defines.
                if callee and all(ch.isalnum() or ch in "_-." for ch in callee):
                    caller = _enclosing_function(node, source) or "<module>"
                    pairs[(caller, callee)] += 1
        for child in node.children:
            walk(child)

    walk(parser.parse(source).root_node)
    return pairs


def call_frequency(graph: Graph, source_root: Path) -> CallFrequency:
    """Count calls per (caller, callee) across the graph's own source files.

    The file set comes from the GRAPH (function nodes carry `file`), so the overlay
    covers exactly the tree the graph describes — not whatever happens to be on disk.
    """
    files: set[Path] = set()
    for node in graph.nodes:
        if node.type in _NON_SYMBOL_TYPES or not _is_code_node(node) or not node.file:
            continue
        candidate = source_root / node.file
        if candidate.is_file():
            files.add(candidate)
    # Only pairs whose CALLEE is a function the graph knows: graphify's overlay
    # weights existing edges, and a command like `grep` has no node to weight. The
    # first run listed `grep x63` and `printf x65`, which no analysis can act on.
    known = {n.label for n in graph.nodes if n.type == "function"}
    totals: Counter[tuple[str, str]] = Counter()
    for path in sorted(files):
        counted = _bash_pairs(path) if path.suffix in (".sh", ".bash") else _python_pairs(path)
        totals.update({pair: n for pair, n in counted.items() if pair[1] in known})
    ordered = tuple(
        (caller, callee, count) for (caller, callee), count in sorted(totals.items(), key=lambda kv: (-kv[1], kv[0]))
    )
    return CallFrequency(pairs=ordered, total_calls=sum(totals.values()))
