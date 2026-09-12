"""Shared sys.path bootstrap for the test modules.

Importing this module inserts the repo's ``scripts/`` directory on
``sys.path`` so ``import kgraph`` works both under pytest and in a standalone
``python tests/test_<name>.py`` run. Keeping the insert here means the test
modules can import everything at the top of the file, with no E402
suppressions.
"""

import os
import sys

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPT_DIR = os.path.join(REPO_ROOT, "scripts")

if SCRIPT_DIR not in sys.path:
    sys.path.insert(0, SCRIPT_DIR)

# end of file
