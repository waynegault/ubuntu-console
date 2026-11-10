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

from _test_harness import load_probe, load_script

__all__ = ["load_probe", "load_script"]
