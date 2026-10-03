"""Tests for kgraph.wiring — source-tree wiring analysis.

Uses a synthetic fixture repo (tmp) to exercise the anomaly detector:
orphan modules, broken internal imports, weak wiring, and unused
package facades.
"""

import ast
import os
import sys
import tempfile
import unittest
from pathlib import Path

import pytest

from _paths import SCRIPT_DIR

from kgraph import wiring
from kgraph.wiring import (
    analyze_wiring,
    format_wiring_report,
    wiring_summary,
)

# Guard: the _paths bootstrap must have made scripts/ importable.
if not os.path.isdir(SCRIPT_DIR):
    raise RuntimeError(f"kgraph scripts/ dir not found: {SCRIPT_DIR}")

FIXTURE_FILES = {
    'pkg/__init__.py': '"""pkg package."""\n',
    'pkg/mod_a.py': '"""mod_a."""\ndef hello() -> str:\n    return "hello"\n',
    'pkg/mod_b.py': (
        '"""mod_b — imports a missing sibling."""\n'
        'def run() -> None:\n'
        '    from pkg.missing import nope  # broken import\n'
    ),
    'pkg/mod_c.py': '"""mod_c — only imported by tests."""\ndef helper() -> int:\n    return 1\n',
    'pkg/mod_d.py': '"""mod_d — imports a sibling properly."""\nfrom pkg.mod_a import hello\n',
    'scripts/entry.py': '"""Entry script — expected orphan."""\nfrom pkg.mod_a import hello\nfrom pkg.mod_d import hello as _h2\n',
    'tests/test_weak.py': '"""Weak wiring."""\nfrom pkg import mod_c\n',
    'tests/test_d.py': '"""Imports mod_d."""\nfrom pkg.mod_d import hello\n',
}


def build_fixture(root: str) -> None:
    for rel, content in FIXTURE_FILES.items():
        path = os.path.join(root, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, 'w', encoding='utf-8') as f:
            f.write(content)


class WiringAnalysisTests(unittest.TestCase):
    def test_orphan_module_detection(self):
        with tempfile.TemporaryDirectory() as td:
            build_fixture(td)
            report = analyze_wiring(td)
            orphans = {o['path'] for o in report['orphan_modules']}
            # pkg.mod_b is orphaned (nothing imports it); entry.py is an
            # entry point and is exempt.
            self.assertIn('pkg/mod_b.py', orphans)
            self.assertNotIn('scripts/entry.py', orphans)
            self.assertNotIn('pkg/mod_a.py', orphans)

    def test_broken_import_detection(self):
        with tempfile.TemporaryDirectory() as td:
            build_fixture(td)
            report = analyze_wiring(td)
            broken = {(b['module'], b['import']) for b in report['broken_imports']}
            self.assertIn(('pkg.mod_b', 'pkg.missing'), broken)
            # healthy sibling import is not flagged
            self.assertNotIn(('pkg.mod_d', 'pkg.mod_a'), broken)

    def test_weak_wiring_detection(self):
        with tempfile.TemporaryDirectory() as td:
            build_fixture(td)
            report = analyze_wiring(td)
            weak = {w['module'] for w in report['weak_wiring']}
            self.assertIn('pkg.mod_c', weak)
            self.assertNotIn('pkg.mod_d', weak)

    def test_unused_facade_detection(self):
        with tempfile.TemporaryDirectory() as td:
            build_fixture(td)
            # add a facade package nobody imports
            os.makedirs(os.path.join(td, 'facade'))
            with open(os.path.join(td, 'facade', '__init__.py'), 'w', encoding='utf-8') as f:
                f.write('"""facade package."""\nfrom facade._impl import f as f\n')
            with open(os.path.join(td, 'facade', '_impl.py'), 'w', encoding='utf-8') as f:
                f.write('"""impl."""\ndef f() -> None:\n    pass\n')
            report = analyze_wiring(td)
            facades = {f_['path'] for f_ in report['unused_facades']}
            self.assertIn('facade/__init__.py', facades)

    def test_root_conftest_not_orphaned(self):
        """A root-level conftest.py is pytest infra, never an orphan."""
        with tempfile.TemporaryDirectory() as td:
            build_fixture(td)
            with open(os.path.join(td, 'conftest.py'), 'w', encoding='utf-8') as f:
                f.write('"""pytest fixtures."""\n')
            report = analyze_wiring(td)
            orphans = {o['path'] for o in report['orphan_modules']}
            self.assertNotIn('conftest.py', orphans)

    def test_main_guard_module_not_orphan_or_weak(self):
        """An ``if __name__ == "__main__":`` module is an entry point."""
        with tempfile.TemporaryDirectory() as td:
            build_fixture(td)
            with open(os.path.join(td, 'pkg', 'cli_tool.py'), 'w', encoding='utf-8') as f:
                f.write(
                    '"""Interpreter-launched tool, not imported by prod."""\n'
                    'def main() -> None:\n    pass\n'
                    'if __name__ == "__main__":\n    main()\n'
                )
            report = analyze_wiring(td)
            orphans = {o['path'] for o in report['orphan_modules']}
            weak = {w['module'] for w in report['weak_wiring']}
            self.assertNotIn('pkg/cli_tool.py', orphans)
            self.assertNotIn('pkg.cli_tool', weak)

    def test_subprocess_consumed_module_not_orphaned(self):
        """A module launched via a subprocess path string is not an orphan."""
        with tempfile.TemporaryDirectory() as td:
            build_fixture(td)
            os.makedirs(os.path.join(td, 'taxonomy'))
            with open(os.path.join(td, 'taxonomy', 'rebuild.py'), 'w', encoding='utf-8') as f:
                f.write('"""Rebuild helper, run via subprocess."""\n')
            with open(os.path.join(td, 'pkg', 'runner.py'), 'w', encoding='utf-8') as f:
                f.write(
                    '"""Launches rebuild.py as a subprocess."""\n'
                    'import subprocess\n'
                    'subprocess.run(["python", "taxonomy/rebuild.py"])\n'
                )
            report = analyze_wiring(td)
            orphans = {o['path'] for o in report['orphan_modules']}
            self.assertNotIn('taxonomy/rebuild.py', orphans)

    def test_facade_with_external_submodule_importer_is_used(self):
        """A facade whose submodule is imported elsewhere is NOT unused.

        Importing ``pkg.sub`` executes ``pkg/__init__.py`` — a package with
        a live submodule importer must not be flagged as an unused facade.
        """
        with tempfile.TemporaryDirectory() as td:
            build_fixture(td)
            os.makedirs(os.path.join(td, 'lib'))
            with open(os.path.join(td, 'lib', '__init__.py'), 'w', encoding='utf-8') as f:
                f.write('"""lib facade."""\n')
            with open(os.path.join(td, 'lib', '_impl.py'), 'w', encoding='utf-8') as f:
                f.write('"""impl."""\ndef f() -> None:\n    pass\n')
            with open(os.path.join(td, 'pkg', 'consumer.py'), 'w', encoding='utf-8') as f:
                f.write('"""consumes lib._impl."""\nfrom lib._impl import f\n')
            report = analyze_wiring(td)
            facades = {f_['path'] for f_ in report['unused_facades']}
            self.assertNotIn('lib/__init__.py', facades)

    def test_facade_self_import_not_counted_as_consumer(self):
        """A package importing its OWN submodule is not a consumer."""
        with tempfile.TemporaryDirectory() as td:
            build_fixture(td)
            os.makedirs(os.path.join(td, 'facade'))
            with open(os.path.join(td, 'facade', '__init__.py'), 'w', encoding='utf-8') as f:
                f.write('"""facade package."""\nfrom facade._impl import f as f\n')
            with open(os.path.join(td, 'facade', '_impl.py'), 'w', encoding='utf-8') as f:
                f.write('"""impl."""\ndef f() -> None:\n    pass\n')
            report = analyze_wiring(td)
            facades = {f_['path'] for f_ in report['unused_facades']}
            self.assertIn('facade/__init__.py', facades)

    def test_entry_dir_facade_imported_by_relative_name_not_flagged(self):
        """A package under an entry dir imported via its sys.path name is used."""
        with tempfile.TemporaryDirectory() as td:
            build_fixture(td)
            os.makedirs(os.path.join(td, 'scripts', 'pkg2'))
            with open(os.path.join(td, 'scripts', 'pkg2', '__init__.py'), 'w', encoding='utf-8') as f:
                f.write('"""pkg2 facade."""\n')
            with open(os.path.join(td, 'scripts', 'pkg2', 'mod.py'), 'w', encoding='utf-8') as f:
                f.write('"""mod."""\n')
            with open(os.path.join(td, 'tests', 'test_pkg2.py'), 'w', encoding='utf-8') as f:
                f.write('"""imports the facade by its entry-relative name."""\nimport pkg2\n')
            report = analyze_wiring(td)
            facades = {f_['path'] for f_ in report['unused_facades']}
            self.assertNotIn('scripts/pkg2/__init__.py', facades)

    def test_entry_dir_submodule_and_symbol_imports_resolve(self):
        """``from pkg2.mod import helper`` resolves via the entry-relative namespace."""
        with tempfile.TemporaryDirectory() as td:
            build_fixture(td)
            os.makedirs(os.path.join(td, 'scripts', 'pkg2'))
            with open(os.path.join(td, 'scripts', 'pkg2', '__init__.py'), 'w', encoding='utf-8') as f:
                f.write('"""pkg2 facade."""\n')
            with open(os.path.join(td, 'scripts', 'pkg2', 'mod.py'), 'w', encoding='utf-8') as f:
                f.write('"""mod."""\ndef helper() -> int:\n    return 1\n')
            with open(os.path.join(td, 'scripts', 'consumer.py'), 'w', encoding='utf-8') as f:
                f.write('"""consumes pkg2 via entry-relative imports."""\n'
                        'from pkg2 import helper\n'
                        'from pkg2.mod import helper as h2\n')
            report = analyze_wiring(td)
            facades = {f_['path'] for f_ in report['unused_facades']}
            self.assertNotIn('scripts/pkg2/__init__.py', facades)
            # both entry-relative imports resolved locally (no broken entries
            # involving pkg2; the fixture's own pkg.missing stays broken)
            self.assertFalse(
                any('pkg2' in b['module'] or 'pkg2' in b['import']
                    for b in report['broken_imports']),
                f'pkg2 imports wrongly flagged broken: {report["broken_imports"]}',
            )

    def test_summary_counts(self):
        with tempfile.TemporaryDirectory() as td:
            build_fixture(td)
            report = analyze_wiring(td)
            summary = wiring_summary(report)
            self.assertGreaterEqual(summary['orphans'], 1)
            self.assertGreaterEqual(summary['broken_imports'], 1)
            self.assertGreaterEqual(summary['weak_wiring'], 1)
            self.assertEqual(summary['modules'], 8)

    def test_report_format_contains_sections(self):
        with tempfile.TemporaryDirectory() as td:
            build_fixture(td)
            text = format_wiring_report(analyze_wiring(td))
            self.assertIn('ORPHAN MODULES', text)
            self.assertIn('BROKEN INTERNAL IMPORTS', text)
            self.assertIn('WEAK WIRING', text)
            self.assertIn('UNUSED PACKAGE FACADES', text)


# ── resolution + scanning branches (card 7577436f) ─────────────────────────
# These cover the arms the anomaly detector's whole point rides on: relative and
# dynamic imports, unparseable files, and the cross-file call gap.  Expected values
# come from Python's import semantics and the module's own documented report shape,
# never from the detector's current output.


def _write_files(root: str, files: dict[str, str]) -> None:
    for rel, content in files.items():
        path = os.path.join(root, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, 'w', encoding='utf-8') as f:
            f.write(content)


def test_module_name_and_relative_resolution_follow_import_semantics() -> None:
    # Catches: a wrong module name for a package __init__/leaf, or a mis-resolved
    # relative level, either of which fabricates or hides a broken-import finding.
    assert wiring._module_name(()) is None
    assert wiring._module_name(('pkg', '__init__.py')) == 'pkg'
    assert wiring._module_name(('pkg', 'mod.py')) == 'pkg.mod'
    # `from .x import ...` inside package `a` resolves to a.x.
    assert wiring._resolve_relative(1, 'x', 'a') == 'a.x'
    # `from ..x import ...` inside package a.b resolves to a.x.
    assert wiring._resolve_relative(2, 'x', 'a.b') == 'a.x'
    # `from .. import x` inside a.b resolves to the parent package a.
    assert wiring._resolve_relative(2, '', 'a.b') == 'a'
    # A level that climbs above the package root cannot resolve.
    assert wiring._resolve_relative(3, 'x', 'a') is None


def _first_call(src: str) -> ast.Call:
    """The single Call expression in *src*, for the _arg_string cases."""
    stmt = ast.parse(src).body[0]
    assert isinstance(stmt, ast.Expr)
    call = stmt.value
    assert isinstance(call, ast.Call)
    return call


def test_arg_string_reads_a_literal_or_a_name_keyword() -> None:
    # Catches: __import__(name="...") (the keyword form) being recorded as an empty
    # dynamic-import site, which would under-report the tool's dynamic_import_sites.
    assert wiring._arg_string(_first_call('__import__("pkg.mod")')) == 'pkg.mod'
    assert wiring._arg_string(_first_call('__import__(name="pkg.mod")')) == 'pkg.mod'
    assert wiring._arg_string(_first_call('__import__(1)')) is None


def test_line_count_unreadable_path_is_zero(tmp_path: Path) -> None:
    # Catches: an unreadable path raising out of the scan instead of counting as 0
    # lines (a directory is the cheapest stand-in for an unreadable file).
    assert wiring._line_count(tmp_path) == 0


_DYNAMIC_FIXTURE = {
    'pkg/__init__.py': '"""pkg."""\n',
    'pkg/mod.py': '"""mod."""\ndef x() -> int:\n    return 1\n',
    'pkg/dyn.py': (
        '"""dynamic imports."""\n'
        'import importlib\n'
        'import pkgutil\n'
        '__import__("pkg.mod")\n'
        '__import__(name="pkg.mod")\n'
        'importlib.import_module("pkg.mod")\n'
        'pkgutil.import_module("pkg.mod")\n'
    ),
    'pkg/rel.py': (
        '"""relative imports."""\n'
        'from .mod import x\n'
        'from . import mod as m\n'
    ),
    'pkg/ext.py': '"""external symbol import."""\nfrom os import path\n',
    'scripts/gadget/__init__.py': '"""gadget."""\n',
    'scripts/gadget/mod.py': '"""mod."""\n',
    'scripts/gadget_user.py': '"""entry-relative import."""\nfrom gadget import mod as gmod\n',
}


def test_dynamic_relative_and_entry_relative_imports_resolve(tmp_path: Path) -> None:
    # Catches: a dynamic import site dropped from the report, a relative import
    # mis-resolved into a false broken-import, or an entry-relative package facade
    # flagged unused.
    _write_files(str(tmp_path), _DYNAMIC_FIXTURE)
    report = analyze_wiring(str(tmp_path))
    assert report['dynamic_import_sites']['pkg.dyn'] == sorted(
        ['pkg.mod', 'pkg.mod', 'importlib.import_module', 'pkgutil.import_module'])
    broken = {(b['module'], b['import']) for b in report['broken_imports']}
    assert not any(m.startswith('pkg.rel') or m.startswith('pkg.dyn') for m, _ in broken)
    facades = {f_['path'] for f_ in report['unused_facades']}
    assert 'scripts/gadget/__init__.py' not in facades


_BAD_FIXTURE = {
    '__init__.py': '"""root package (its module name is undecidable)."""\n',
    'pkg/__init__.py': '"""pkg."""\n',
    'pkg/defs.py': '"""defs."""\ndef shared() -> int:\n    return 1\n',
    'pkg/caller.py': '"""caller."""\ndef go() -> int:\n    return shared()\n',
    'pkg/broken.py': '"""unparseable."""\ndef (\n',
}


def test_parse_failure_and_cross_file_gap_are_reported(tmp_path: Path) -> None:
    # Catches: an unparseable file silently skipped (not even named), and a bare
    # cross-file call with no import path left unreported - both the tool's point.
    _write_files(str(tmp_path), _BAD_FIXTURE)
    report = analyze_wiring(str(tmp_path))
    assert any('pkg/broken.py' in f for f in report['parse_failures'])
    assert 'PARSE FAILURES (1)' in format_wiring_report(report)
    gaps = {(g['name'], g['definer'], g['caller'])
            for g in report['cross_file_call_gaps']}
    assert ('shared', 'pkg.defs', 'pkg.caller') in gaps


def _synthetic_report() -> dict:
    return {
        'repo': '/x', 'modules': 9, 'files': 9,
        'parse_failures': ['b.py: bad syntax'],
        'orphan_modules': [
            {'module': f'm{i}', 'path': f'm{i}.py', 'lines': i} for i in range(25)],
        'broken_imports': [],
        'weak_wiring': [
            {'module': f'w{i}', 'path': f'w{i}.py', 'lines': i,
             'importers': ['tests.t']} for i in range(25)],
        'unused_facades': [
            {'package': 'p', 'path': 'p/__init__.py', 'lines': 3, 'submodules': 2}],
        'cross_file_call_gaps': [
            {'name': f'g{i}', 'definer': 'a', 'caller': 'b'} for i in range(25)],
    }


def test_report_truncates_without_all_and_expands_with_it() -> None:
    # Catches: a report that silently drops rows past the display cap with no
    # ellipsis (looking complete), or --all failing to print the whole list.
    report = _synthetic_report()
    text = format_wiring_report(report)
    assert text.count('… and 5 more') == 3
    assert 'p/__init__.py  (2 submodules)' in text
    assert 'g0  defined in a  called from b' in text
    full = format_wiring_report(report, show_all=True)
    assert '… and' not in full
    assert 'm24' in full and 'w24' in full and 'g24' in full


def test_main_prints_usage_without_a_repo(monkeypatch: pytest.MonkeyPatch) -> None:
    # Catches: the CLI running a scan of sys.argv[0] or exiting 0 with no argument.
    monkeypatch.setattr(sys, 'argv', ['wiring'])
    said: list[str] = []
    with pytest.raises(SystemExit) as exc:
        wiring.main(reporter=said.append)
    assert exc.value.code == 1
    assert any('Usage: python -m kgraph.wiring' in s for s in said)


def test_main_reports_a_scanned_repo(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    # Catches: the CLI printing nothing (or dying) on a real repo argument.
    _write_files(str(tmp_path), {'pkg/__init__.py': '"""pkg."""\n'})
    monkeypatch.setattr(sys, 'argv', ['wiring', str(tmp_path)])
    said: list[str] = []
    wiring.main(reporter=said.append)
    joined = '\n'.join(said)
    assert 'Wiring analysis:' in joined
    assert 'SUMMARY:' in joined


if __name__ == '__main__':
    unittest.main()

