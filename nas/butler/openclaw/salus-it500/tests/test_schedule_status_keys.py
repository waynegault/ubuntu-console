"""Regression guard for the schedule-status payload keys (card 6082a17d).

WHY THIS EXISTS (2026-10-02): the `_out({...})` literal in salus.py's
`schedule-status` branch carried the key `"command"` TWICE — once as the operation
label ("schedule-status") and once as the scheduled task's own command — so the
second entry silently overwrote the first and the operation label was lost.
ruff's F601 caught it once nas/ came under the gates.

These assertions read the REPO salus.py (a sibling of this file, resolved
relative), not the installed skill copy that test_salus_cli_parsers.py loads.
They assert the two facts are DISTINCT keys and that no key repeats, which is the
property the duplicate silently violated.

FALSIFICATION (2026-10-02): against the pre-fix salus.py both cases fail — the
key list carries "command" twice and there is no "task_command".
"""

import ast
import unittest
from pathlib import Path

SALUS_PY = Path(__file__).resolve().parents[1] / "salus.py"


def _schedule_status_dict(tree: ast.Module) -> ast.Dict:
    """The dict literal whose value is the "schedule-status" operation label."""
    for node in ast.walk(tree):
        if not isinstance(node, ast.Dict):
            continue
        for value in node.values:
            if isinstance(value, ast.Constant) and value.value == "schedule-status":
                return node
    raise AssertionError("no schedule-status dict literal found in salus.py")


def _schedule_status_keys() -> list[str]:
    tree = ast.parse(SALUS_PY.read_text(encoding="utf-8"))
    node = _schedule_status_dict(tree)
    return [
        k.value
        for k in node.keys
        if isinstance(k, ast.Constant) and isinstance(k.value, str)
    ]


class TestScheduleStatusKeys(unittest.TestCase):
    def test_no_duplicate_dict_keys(self):
        # The defect: a repeated literal key drops the first value, so the
        # operation label was overwritten by task.command.
        keys = _schedule_status_keys()
        self.assertEqual(len(keys), len(set(keys)), f"duplicate dict keys: {keys}")

    def test_operation_label_and_task_command_are_distinct(self):
        keys = _schedule_status_keys()
        self.assertIn("command", keys)  # the operation label, "schedule-status"
        self.assertIn("task_command", keys)  # the scheduled task's own command


if __name__ == "__main__":
    unittest.main()
