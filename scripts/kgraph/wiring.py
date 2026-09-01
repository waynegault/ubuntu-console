"""Source-tree wiring analysis using stdlib ``ast``.

Detects wiring anomalies in a Python codebase without tree-sitter:
orphan modules, broken internal imports, test-only (weak) wiring,
unused package facades, and cross-file call gaps.  This is the
"precise" counterpart to the AST graph extractor: it reasons about
real imports and definitions rather than name-shaped call nodes.

CLI:
    kgraph --wiring --repo /path/to/repo
"""

from __future__ import annotations

import ast
import re
import sys
from collections import defaultdict
from pathlib import Path
from typing import Any

# ── defaults ───────────────────────────────────────────────────────────

DEFAULT_SKIP_DIRS: frozenset[str] = frozenset({
    ".git", ".venv", "venv", "node_modules", "__pycache__", ".mypy_cache",
    ".ruff_cache", ".pytest_cache", ".hypothesis", ".qwen", ".tox", "dist",
    "build", "site-packages", ".direnv",
})

# Modules that are expected to have no importers.
ENTRY_NAME_HINTS = ("__main__", "cli", "conftest", "setup", "main")
ENTRY_SUFFIXES = ("/__main__.py", "/cli.py", "/conftest.py", "/main.py", "/setup.py")

_DOTTED_RE = re.compile(r"[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)*")


def _module_name(rel_parts: tuple[str, ...]) -> str | None:
    """Map a file's relative path parts to a dotted module name."""
    parts = list(rel_parts)
    if not parts:
        return None
    if parts[-1] == "__init__.py":
        parts = parts[:-1]
    else:
        parts[-1] = parts[-1].removesuffix(".py")
    return ".".join(parts) if parts else None


def _package_of(rel_parts: tuple[str, ...]) -> str:
    return ".".join(rel_parts[:-1])


def _resolve_relative(level: int, mod: str, pkg: str) -> str | None:
    pkg_parts = pkg.split(".") if pkg else []
    if level > len(pkg_parts):
        return None
    base = pkg_parts[: len(pkg_parts) - (level - 1)]
    parts = base + ([mod] if mod else [])
    return ".".join(parts) if parts else None


def _line_count(path: Path) -> int:
    """Count lines in a file, closing the handle (0 on read errors)."""
    try:
        with path.open(encoding="utf-8") as f:
            return sum(1 for _ in f)
    except (OSError, UnicodeDecodeError):
        return 0


def _is_entry(rel: str, rel_parts: tuple[str, ...]) -> bool:
    """True for files pytest/interpreter auto-discover (never "orphans").

    Covers ``conftest.py`` at ANY depth (pytest imports it via discovery,
    not via ``import``), plus the classic entry names — the stem check
    handles a root-level ``conftest.py`` that the ``/conftest.py`` suffix
    form misses.
    """
    last = rel_parts[-1]
    stem = last[:-3] if last.endswith(".py") else last
    if stem in ENTRY_NAME_HINTS:
        return True
    if last == "__init__.py":
        return True
    return rel.endswith(ENTRY_SUFFIXES)


def _has_main_guard(tree: ast.AST) -> bool:
    """True when the module has an ``if __name__ == "__main__":`` guard.

    Such modules are interpreter-launched entry points (``python -m mod``
    or ``python path/mod.py``) — by design they have no importers, so they
    must not be reported as orphans or test-only weak wiring.
    """
    for node in ast.walk(tree):
        if isinstance(node, ast.If):
            test = node.test
            if (
                isinstance(test, ast.Compare)
                and isinstance(test.left, ast.Name)
                and test.left.id == "__name__"
                and len(test.ops) == 1
                and isinstance(test.ops[0], (ast.Eq, ast.Is))
                and len(test.comparators) == 1
                and isinstance(test.comparators[0], ast.Constant)
                and test.comparators[0].value == "__main__"
            ):
                return True
    return False


def _is_subprocess_consumed(rel_path: str, sources: dict[str, str]) -> bool:
    """True when another file references *rel_path* as a string.

    Covers scripts launched via ``subprocess.run([... "path/to/mod.py"])``
    or path-constructed references (``Path(...) / "mod.py"``) — the static
    import graph cannot see subprocess wiring, so a string reference to the
    module's relative path elsewhere in the tree counts as a consumer.
    """
    needle = rel_path.as_posix()
    return any(needle in text for path, text in sources.items() if path != rel_path)


# ── analysis ───────────────────────────────────────────────────────────


def analyze_wiring(repo_root: str, *, skip_dirs: set[str] | None = None,
                   entry_dirs: tuple[str, ...] = ("scripts",)) -> dict[str, Any]:
    """Analyze a Python source tree for wiring anomalies.

    Args:
        repo_root: Filesystem path to the repository root.
        skip_dirs: Additional directory names to skip (defaults merged).
        entry_dirs: Top-level directories whose modules are entry points
            (expected to have no importers), e.g. ``("scripts",)``.

    Returns:
        A structured report dict with per-category findings.
    """
    root = Path(repo_root).resolve()
    skip = DEFAULT_SKIP_DIRS | set(skip_dirs or ())

    files = [p for p in root.rglob("*.py") if not any(
        part in skip or part.startswith(".") for part in p.relative_to(root).parts)]

    module_to_path: dict[str, Path] = {}
    path_to_module: dict[Path, str] = {}
    for p in files:
        m = _module_name(p.relative_to(root).parts)
        if m:
            module_to_path[m] = p
            path_to_module[p] = m

    import_deps: dict[str, set[str]] = defaultdict(set)
    symbol_deps: dict[str, set[str]] = defaultdict(set)
    dynamic: dict[str, list[str]] = defaultdict(list)
    parse_failures: list[str] = []
    #: rel_path -> source text (for subprocess-consumed string references).
    source_texts: dict[Path, str] = {}
    #: modules with an ``if __name__ == "__main__":`` guard (entry points).
    main_guard_modules: set[str] = set()

    for p in files:
        m = path_to_module.get(p)
        if not m:
            continue
        try:
            text = p.read_text(encoding="utf-8")
            tree = ast.parse(text)
        except (OSError, SyntaxError, UnicodeDecodeError) as exc:
            parse_failures.append(f"{p.relative_to(root)}: {exc}")
            continue
        source_texts[p] = text
        if _has_main_guard(tree):
            main_guard_modules.add(m)
        pkg = _package_of(p.relative_to(root).parts)
        for node in ast.walk(tree):
            if isinstance(node, ast.Import):
                for a in node.names:
                    import_deps[m].add(a.name)
            elif isinstance(node, ast.ImportFrom):
                if node.module:
                    target: str | None = node.module
                    if node.level:
                        target = _resolve_relative(node.level, target or "", pkg)
                    if target:
                        import_deps[m].add(target)
                        for a in node.names:
                            if a.name != "*":
                                symbol_deps[m].add(f"{target}.{a.name}")
                elif node.level:
                    target = _resolve_relative(node.level, "", pkg)
                    if target:
                        import_deps[m].add(target)
                        for a in node.names:
                            if a.name != "*":
                                symbol_deps[m].add(f"{target}.{a.name}")
            elif isinstance(node, ast.Call):
                f = node.func
                if isinstance(f, ast.Name) and f.id == "__import__":
                    dynamic[m].append(_arg_string(node) or "")
                elif isinstance(f, ast.Attribute) and isinstance(f.value, ast.Name) \
                        and f.value.id in ("importlib", "pkgutil"):
                    dynamic[m].append(f"{f.value.id}.{f.attr}")

    # Every dotted prefix of a local module is an importable package
    # (covers namespace packages — directories without __init__.py).
    package_names: set[str] = set()
    for mod in module_to_path:
        parts = mod.split(".")
        for i in range(1, len(parts) + 1):
            package_names.add(".".join(parts[:i]))
    top_packages = {m.split(".")[0] for m in package_names}

    # Modules under an entry dir (e.g. scripts/) are importable by their
    # name relative to that dir — "kgraph", not "scripts.kgraph" — because
    # the entry dir sits on sys.path.  Map entry-relative names back to the
    # path-based module names so imports resolve against the real namespace.
    entry_relative: dict[str, str] = {}
    for mod in module_to_path:
        first, _sep, rest = mod.partition(".")
        if first in entry_dirs and rest:
            entry_relative[rest] = mod

    def _resolve_local(mod: str) -> str | None:
        """Resolve a module name to the longest local module/package prefix.

        Consults both the path-based namespace (``scripts.kgraph``) and the
        entry-relative namespace (``kgraph``) so ``from kgraph.query import
        query_nodes`` resolves to ``scripts.kgraph.query``.
        """
        if mod in module_to_path or mod in package_names:
            return mod
        if mod in entry_relative:
            return entry_relative[mod]
        prefix = mod
        while "." in prefix:
            prefix = prefix.rsplit(".", 1)[0]
            if prefix in module_to_path or prefix in package_names:
                return prefix
            if prefix in entry_relative:
                return entry_relative[prefix]
        return None

    # Real import targets must exist exactly (as a module or namespace
    # package); a missing module under a local top-level package is a
    # broken import.  Prefix resolution only applies to symbol deps below.
    local_dep: dict[str, set[str]] = defaultdict(set)
    broken: dict[str, set[str]] = defaultdict(set)
    for m, mods in import_deps.items():
        for mod in mods:
            if mod in module_to_path or mod in package_names:
                local_dep[m].add(mod)
            elif mod in entry_relative:
                local_dep[m].add(entry_relative[mod])
            elif mod.split(".")[0] in top_packages:
                broken[m].add(mod)

    # Symbol expansions (``from X import Y``) resolve via longest prefix;
    # they are not module targets, so a missing symbol is never "broken"
    # at the import level (could be an attribute import).
    for m, mods in symbol_deps.items():
        for mod in mods:
            resolved = _resolve_local(mod)
            if resolved is not None:
                local_dep[m].add(resolved)

    importers: dict[str, set[str]] = defaultdict(set)
    for m, mods in local_dep.items():
        for d in mods:
            importers[d].add(m)
            # Importing ``pkg.sub`` executes ``pkg/__init__.py`` too —
            # record every ancestor package as imported so package facades
            # with live submodule importers are not flagged as unused.
            # Never add the importer to its OWN ancestor chain: a package
            # importing its own submodule is a self-reference, not an
            # external consumer.
            prefix = d
            while "." in prefix:
                prefix = prefix.rsplit(".", 1)[0]
                if prefix == m:
                    break
                if prefix in module_to_path or prefix in package_names:
                    importers[prefix].add(m)

    def _reachable(start: str) -> set[str]:
        seen: set[str] = set()
        stack = [start]
        while stack and len(seen) < 5000:
            cur = stack.pop()
            if cur in seen:
                continue
            seen.add(cur)
            for dep in local_dep.get(cur, ()):
                if dep not in seen:
                    stack.append(dep)
        return seen

    def _is_interpreter_entry(m: str) -> bool:
        """True when *m* is launched by the interpreter, not imported.

        A ``__main__`` guard (``python -m mod`` / ``python path/mod.py``)
        or a string reference to its file path from another module
        (subprocess execution) means the module is deliberately wired
        outside the import graph.
        """
        if m in main_guard_modules:
            return True
        p = module_to_path[m]
        return _is_subprocess_consumed(p.relative_to(root), source_texts)

    # 1. orphan source modules
    orphans: list[dict[str, Any]] = []
    for m in sorted(module_to_path):
        if m in importers or m.startswith("tests."):
            continue
        if _is_interpreter_entry(m):
            continue
        p = module_to_path[m]
        rel = p.relative_to(root)
        if _is_entry(rel.as_posix(), rel.parts):
            continue
        if rel.parts and rel.parts[0] in entry_dirs:
            continue
        orphans.append({"module": m, "path": rel.as_posix(), "lines": _line_count(p)})
    orphans.sort(key=lambda d: (-d["lines"], d["module"]))

    # 2. broken internal imports
    broken_list: list[dict[str, Any]] = []
    for m in sorted(broken):
        for b in sorted(broken[m]):
            broken_list.append({"module": m, "import": b})
    broken_list.sort(key=lambda d: (d["module"], d["import"]))

    # 3. weak wiring — source modules imported only from tests/
    weak: list[dict[str, Any]] = []
    for m in sorted(module_to_path):
        if m.startswith(("tests.", "scripts.", "config.")):
            continue
        if m in main_guard_modules:
            # interpreter-launched entry point (python -m), not weak wiring
            continue
        imp = importers.get(m, set())
        if imp and all(i.startswith("tests.") for i in imp):
            p = module_to_path[m]
            weak.append({"module": m, "path": p.relative_to(root).as_posix(),
                         "lines": _line_count(p), "importers": sorted(imp)})
    weak.sort(key=lambda d: (-d["lines"], d["module"]))

    # 4. unused package facades — package __init__ never imported directly
    facades: list[dict[str, Any]] = []
    for m in sorted(module_to_path):
        p = module_to_path[m]
        if p.name != "__init__.py":
            continue
        if m in importers:
            continue
        submodules = {k for k, v in module_to_path.items()
                      if k.startswith(m + ".") and v.name != "__init__.py"}
        facades.append({"package": m, "path": p.relative_to(root).as_posix(),
                        "lines": _line_count(p), "submodules": len(submodules)})
    facades.sort(key=lambda d: (-d["lines"], d["package"]))

    # 5. cross-file call gaps — call to a name defined elsewhere with no
    #    (transitive) import path from the caller to the definer.
    defined_in: dict[str, set[str]] = defaultdict(set)
    for p in files:
        m = path_to_module.get(p)
        if not m:
            continue
        try:
            tree = ast.parse(p.read_text(encoding="utf-8"))
        except (OSError, SyntaxError, UnicodeDecodeError):
            continue
        for node in ast.walk(tree):
            if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
                defined_in[m].add(node.name)

    calls_from: dict[str, set[str]] = defaultdict(set)
    for p in files:
        m = path_to_module.get(p)
        if not m:
            continue
        try:
            tree = ast.parse(p.read_text(encoding="utf-8"))
        except (OSError, SyntaxError, UnicodeDecodeError):
            continue
        for node in ast.walk(tree):
            if isinstance(node, ast.Call) and isinstance(node.func, ast.Name):
                calls_from[node.func.id].add(m)

    cross_gaps: list[dict[str, Any]] = []
    for name, definers in sorted(defined_in.items()):
        callers = calls_from.get(name, set())
        if not callers:
            continue
        for definer in sorted(definers):
            reach = _reachable(definer)
            for caller in sorted(callers):
                if caller == definer or caller in reach:
                    continue
                cross_gaps.append({"name": name, "definer": definer, "caller": caller})
    cross_gaps.sort(key=lambda d: (d["name"], d["definer"], d["caller"]))

    return {
        "repo": str(root),
        "modules": len(module_to_path),
        "files": len(files),
        "parse_failures": parse_failures,
        "orphan_modules": orphans,
        "broken_imports": broken_list,
        "weak_wiring": weak,
        "unused_facades": facades,
        "cross_file_call_gaps": cross_gaps,
        "dynamic_import_sites": {m: sorted(v) for m, v in sorted(dynamic.items()) if v},
    }


def _arg_string(node: ast.Call) -> str | None:
    if node.args and isinstance(node.args[0], ast.Constant) and isinstance(node.args[0].value, str):
        return node.args[0].value
    for kw in node.keywords:
        if kw.arg == "name" and isinstance(kw.value, ast.Constant) and isinstance(kw.value.value, str):
            return kw.value.value
    return None


# ── reporting ──────────────────────────────────────────────────────────


def format_wiring_report(report: dict[str, Any], *, show_all: bool = False) -> str:
    """Render a wiring-analysis report as human-readable text."""
    lines: list[str] = []
    lines.append(f"Wiring analysis: {report['repo']}")
    lines.append(f"  modules={report['modules']} files={report['files']}")

    if report["parse_failures"]:
        lines.append(f"\nPARSE FAILURES ({len(report['parse_failures'])}):")
        for f in report["parse_failures"]:
            lines.append(f"  {f}")

    orphans = report["orphan_modules"]
    lines.append(f"\n1. ORPHAN MODULES ({len(orphans)}):")
    for o in orphans[:20 if not show_all else None] or []:
        lines.append(f"  {o['lines']:5d}  {o['path']}")
    if len(orphans) > 20 and not show_all:
        lines.append(f"  … and {len(orphans) - 20} more (--wiring-all for full list)")

    broken = report["broken_imports"]
    lines.append(f"\n2. BROKEN INTERNAL IMPORTS ({len(broken)}):")
    for b in broken:
        lines.append(f"  {b['module']}  ->  {b['import']}")

    weak = report["weak_wiring"]
    lines.append(f"\n3. WEAK WIRING — source modules imported only from tests/ ({len(weak)}):")
    for w in weak[:20 if not show_all else None] or []:
        lines.append(f"  {w['lines']:5d}  {w['path']}  <- {w['importers'][:3]}")
    if len(weak) > 20 and not show_all:
        lines.append(f"  … and {len(weak) - 20} more (--wiring-all for full list)")

    facades = report["unused_facades"]
    lines.append(f"\n4. UNUSED PACKAGE FACADES ({len(facades)}):")
    for f_ in facades:
        lines.append(f"  {f_['lines']:5d}  {f_['path']}  ({f_['submodules']} submodules)")

    gaps = report["cross_file_call_gaps"]
    lines.append(f"\n5. CROSS-FILE CALL GAPS ({len(gaps)}):")
    for g in gaps[:20 if not show_all else None] or []:
        lines.append(f"  {g['name']}  defined in {g['definer']}  called from {g['caller']}")
    if len(gaps) > 20 and not show_all:
        lines.append(f"  … and {len(gaps) - 20} more (--wiring-all for full list)")

    return "\n".join(lines)


def wiring_summary(report: dict[str, Any]) -> dict[str, int]:
    """Return a compact count summary of the wiring report."""
    return {
        "modules": report["modules"],
        "files": report["files"],
        "orphans": len(report["orphan_modules"]),
        "broken_imports": len(report["broken_imports"]),
        "weak_wiring": len(report["weak_wiring"]),
        "unused_facades": len(report["unused_facades"]),
        "cross_file_call_gaps": len(report["cross_file_call_gaps"]),
    }


# ── CLI ────────────────────────────────────────────────────────────────


def main() -> None:
    """CLI entry point: python -m kgraph.wiring <repo> [--all]"""
    args = [a for a in sys.argv[1:] if a != "--all"]
    show_all = "--all" in sys.argv[1:]
    if not args:
        print("Usage: python -m kgraph.wiring <repo-root> [--all]")
        sys.exit(1)
    report = analyze_wiring(args[0])
    print(format_wiring_report(report, show_all=show_all))
    summary = wiring_summary(report)
    print(f"\nSUMMARY: {summary}")


if __name__ == "__main__":
    main()
