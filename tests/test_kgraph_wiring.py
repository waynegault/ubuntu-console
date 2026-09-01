"""Tests for kgraph.wiring — source-tree wiring analysis.

Uses a synthetic fixture repo (tmp) to exercise the anomaly detector:
orphan modules, broken internal imports, weak wiring, and unused
package facades.
"""

import os
import sys
import tempfile
import unittest

REPO_ROOT = os.path.dirname(os.path.dirname(__file__))
SCRIPT_DIR = os.path.join(REPO_ROOT, 'scripts')
sys.path.insert(0, SCRIPT_DIR)

from kgraph.wiring import (  # noqa: E402  (sys.path hack above)
    analyze_wiring,
    format_wiring_report,
    wiring_summary,
)

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


if __name__ == '__main__':
    unittest.main()
