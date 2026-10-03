"""Shared loader for the hyphenated ``scripts/*.py`` probes.

Three test modules (test_grpo_vram_probe, test_kv_recall_probe,
test_oc_restart_check) each carried an identical ``spec_from_file_location``
block. The block is one thing — import a file whose name is not a module name —
so it lives here once; a fix here reaches all three.

Registered in ``sys.modules`` BEFORE execution on purpose: ``@dataclass``
resolves the defining module's namespace through ``sys.modules``, and on
Python 3.14 a module that was only ``module_from_spec``-ed makes that lookup
return None — the class creation then fails with an AttributeError that points at
the dataclass, not at the loader.
"""

from __future__ import annotations

import importlib.util
import sys
from pathlib import Path
from typing import Any

from _paths import REPO_ROOT


def load_probe(module_name: str, script_filename: str) -> Any:
    """Import ``scripts/<script_filename>`` by path and return the module.

    *module_name* is the name registered in ``sys.modules`` (the file's stem with
    dashes replaced by underscores); *script_filename* is the file under
    ``scripts/``. On failure the ``sys.modules`` entry is removed so a later
    import of the same name re-reads the file rather than reusing a half-loaded
    module.
    """
    spec = importlib.util.spec_from_file_location(
        module_name, Path(REPO_ROOT) / "scripts" / script_filename
    )
    assert spec is not None and spec.loader is not None, f"cannot load {script_filename}"
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    try:
        spec.loader.exec_module(module)
    except BaseException:
        del sys.modules[spec.name]
        raise
    return module

# end of file
