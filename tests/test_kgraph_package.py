"""Tests for the kgraph package boundaries — the `python -m kgraph` entry point and the library-must-not-print invariant."""

import os
import subprocess
import sys
import unittest

from _paths import REPO_ROOT


class TestKgrapModuleEntryPoint(unittest.TestCase):
    """`python -m kgraph` — the __main__.py shim into cli.main()."""

    def test_module_entry_point_prints_usage(self):
        # __main__.py is only reachable in a subprocess, so coverage cannot
        # attribute it in-process; this proves the entry point at least works.
        env = dict(os.environ, PYTHONPATH=os.path.join(REPO_ROOT, "scripts"))
        proc = subprocess.run([sys.executable, "-m", "kgraph", "--help"],
                              capture_output=True, text=True, env=env, cwd=REPO_ROOT)
        self.assertEqual(proc.returncode, 0)
        self.assertIn("usage: kgraph", proc.stdout)


class TestKgrapLibraryDoesNotPrint(unittest.TestCase):
    """Only cli.py — the CLI boundary — prints; library modules return data.

    Catches: a print() creeping back into a library module (report, update,
    benchmark, mcp_server, pr_dashboard, server, wiring, validate, …), which
    would emit output a library caller and the MCP server never asked for.
    A print inside a module's top-level `if __name__ == "__main__":` block is
    allowed — that block IS a CLI boundary for `python -m kgraph.<module>`.
    """

    def test_library_modules_do_not_call_print(self):
        import ast
        import pathlib

        def main_block_lines(tree):
            lines = set()
            for node in tree.body:
                if not isinstance(node, ast.If):
                    continue
                test = node.test
                if not (isinstance(test, ast.Compare) and isinstance(test.left, ast.Name)
                        and test.left.id == "__name__" and len(test.comparators) == 1):
                    continue
                comp = test.comparators[0]
                if not (isinstance(comp, ast.Constant) and comp.value == "__main__"):
                    continue
                for stmt in node.body:
                    for ln in range(stmt.lineno, (stmt.end_lineno or stmt.lineno) + 1):
                        lines.add(ln)
            return lines

        pkg = pathlib.Path(REPO_ROOT) / "scripts" / "kgraph"
        offenders: list[str] = []
        for path in sorted(pkg.glob("*.py")):
            if path.name == "cli.py":
                continue
            tree = ast.parse(path.read_text(encoding="utf-8"))
            allowed = main_block_lines(tree)
            for node in ast.walk(tree):
                if (isinstance(node, ast.Call) and isinstance(node.func, ast.Name)
                        and node.func.id == "print" and node.lineno not in allowed):
                    offenders.append(f"{path.name}:{node.lineno}")
        self.assertEqual(offenders, [],
                         "library modules must return data, not print: " + ", ".join(offenders))


if __name__ == "__main__":
    unittest.main()
