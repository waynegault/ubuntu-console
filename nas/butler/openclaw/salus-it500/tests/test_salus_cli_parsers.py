import importlib.util
import unittest
from pathlib import Path

MODULE_PATH = Path("/home/wayne/.openclaw/skills/salus-it500/salus.py")


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
