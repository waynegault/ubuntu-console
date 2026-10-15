"""Tests for the extracted tool programs (card dd96b63f).

``tools/check-contracts.sh`` and ``tools/count-ratchet.sh`` used to carry their
Python inside shell heredocs, where no Python gate could see it.  The programs now
live in ``tools/contracts_check.py`` and ``tools/ratchet_check.py``; these cases
import them and exercise a pure helper from each, so the modules are covered AS
modules rather than only through a wrapper's subprocess path.

Both programs read their arguments at IMPORT time (``REPO_ROOT = sys.argv[1]``) —
which is exactly what the wrapper passes — so the importer below sets ``sys.argv``
first.  No fallback was added to the programs for a missing argument: a default for
a value the wrapper always supplies is a silent fallback that could only ever mask
a broken caller.
"""

import importlib.util
import io
import os
import sys
from contextlib import redirect_stderr

TOOLS = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "tools")
REPO = os.path.dirname(TOOLS)


def _import_tool(module_name, argv):
    """Import a ``tools/*.py`` program by path, with the argv its wrapper passes."""
    sys.argv = [module_name, *argv]
    spec = importlib.util.spec_from_file_location(module_name, os.path.join(TOOLS, f"{module_name}.py"))
    assert spec is not None and spec.loader is not None, module_name
    module = importlib.util.module_from_spec(spec)
    sys.modules[module_name] = module
    spec.loader.exec_module(module)
    return module


def test_ratchet_counters_are_pure_functions_of_a_files_text():
    """States the wrong outcome: a counter that counts COMMENT lines, or has no
    120-column ceiling, would mis-report the corpus it exists to describe."""
    ratchet = _import_tool("ratchet_check", [REPO, "baseline.tsv", "check"])
    text = "\n".join([
        "# a comment line: not code, whatever it contains",
        "echo hi >&2",
        "x" * 121,
        "y" * 120,
    ])
    assert ratchet._code_lines(text) == ["echo hi >&2", "x" * 121, "y" * 120]
    assert ratchet.c_long_lines(text) == 1  # 121 characters is over, 120 is not
    assert ratchet.c_adhoc_stderr(text) == 1  # the hand-written >&2 on a code line


def test_contract_checker_helpers_and_repeated_runs_are_isolated():
    """States the wrong outcome: a scanner that counted comment lines would read a
    `# swallow-ok:` marker (or a comment merely mentioning a pattern) as a live
    swallow site, and the gate would report drift that does not exist."""
    checker = _import_tool("contracts_check", [REPO, "swallows"])
    text = "\n".join([
        "# a comment that mentions || true and 2>/dev/null",
        "run || true",
        "quiet 2>/dev/null",
    ])
    assert checker.swallow_sites(text) == [(2, "|| true"), (3, "2>/dev/null")]

    code, selected, _, _, baseline_options = checker.parse_args(["--print-baseline", "modules"])
    assert code is None
    assert selected == ["modules"]
    assert baseline_options == {"print_baseline": True, "dump_sites": False}

    code, selected, _, _, dump_options = checker.parse_args(["--dump-sites"])
    assert code is None
    assert selected == ["swallows"]
    assert dump_options == {"print_baseline": False, "dump_sites": True}
    assert baseline_options == {"print_baseline": True, "dump_sites": False}

    code, selected, _, positionals, default_options = checker.parse_args([
        "continuity", "model", "use",
    ])
    assert code is None
    assert selected == ["continuity"]
    assert positionals == ["model", "use"]
    assert default_options == {"print_baseline": False, "dump_sites": False}

    with redirect_stderr(io.StringIO()):
        code, selected, repo, positionals, invalid_options = checker.parse_args(["--repo"])
    assert code == checker.EXIT_CANNOT_RUN
    assert selected is repo is positionals is None
    assert invalid_options == {"print_baseline": False, "dump_sites": False}

    checker.ENTITY_LINES["stale-entry"] = 99
    assert checker.run_state(os.path.join(REPO, "missing-fixture")) == checker.EXIT_CANNOT_RUN
    assert checker.ENTITY_LINES == {}
