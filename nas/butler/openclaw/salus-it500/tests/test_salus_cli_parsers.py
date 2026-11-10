import importlib.util
import unittest
from pathlib import Path

# The file this repo ships, resolved from the test's own location.  It used to be
# the absolute path of the INSTALLED skill (~/.openclaw/skills/salus-it500), which
# is a different file: the suite then passed or failed on whatever the host happened
# to have installed, and could not run at all on a machine without that skill.
MODULE_PATH = Path(__file__).resolve().parent.parent / "salus.py"
if not MODULE_PATH.is_file():
    raise RuntimeError(f"mirrored salus.py missing from the repo: {MODULE_PATH}")


def _load_module():
    spec = importlib.util.spec_from_file_location("salus_cli", MODULE_PATH)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class TestSalusCliParsers(unittest.TestCase):
    def setUp(self):
        self.mod = _load_module()

    def test_parse_temperature_valid(self):
        self.assertEqual(self.mod._parse_temperature("20.5"), 20.5)

    def test_parse_temperature_out_of_range(self):
        with self.assertRaises(SystemExit):
            self.mod._parse_temperature("50")

    def test_parse_delta_valid(self):
        self.assertEqual(self.mod._parse_delta("-1.5"), -1.5)

    def test_parse_delta_zero_rejected(self):
        with self.assertRaises(SystemExit):
            self.mod._parse_delta("0")

    def test_parse_minutes_valid(self):
        self.assertEqual(self.mod._parse_minutes("15", "duration minutes"), 15)

    def test_parse_minutes_invalid(self):
        with self.assertRaises(SystemExit):
            self.mod._parse_minutes("0", "duration minutes")


if __name__ == "__main__":
    unittest.main()
