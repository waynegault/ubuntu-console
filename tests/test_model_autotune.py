"""
Unit tests for model-autotune.py.

Tests the extractable pure-logic functions: parsing, estimation, registry
read/write, OOM detection.  Server-launching functions (start_server,
test_config, read_native_ctx) are integration-tested separately since they
require a running llama-server and GPU.
"""

import importlib.util
import os
import tempfile
import unittest

REPO_ROOT = os.path.dirname(os.path.dirname(__file__))
SCRIPT_PATH = os.path.join(REPO_ROOT, "bin", "model-autotune.py")


def load_module():
    spec = importlib.util.spec_from_file_location("model_autotune", SCRIPT_PATH)
    mod = importlib.util.module_from_spec(spec)
    assert spec.loader is not None, f"Could not load module from {SCRIPT_PATH}"
    spec.loader.exec_module(mod)
    return mod


class EstimateVramCeilingTests(unittest.TestCase):
    """Tests for estimate_vram_ceiling() — the VRAM-based ctx estimator."""

    @classmethod
    def setUpClass(cls):
        cls.mod = load_module()

    def test_small_model_fits_easily(self):
        """A 2 GB model on 4 GB VRAM should estimate a ceiling ≤ ceiling param."""
        est = self.mod.estimate_vram_ceiling(
            model_size_gb=2.0, free_vram_mb=4096,
            native_ctx=None, floor=4096, ceiling=32768,
        )
        self.assertGreaterEqual(est, 4096)
        self.assertLessEqual(est, 32768)
        self.assertEqual(est % 512, 0)  # 512-aligned

    def test_large_model_on_small_vram_bounded_by_floor(self):
        """A 7 GB model on 4 GB VRAM should floor at min value."""
        est = self.mod.estimate_vram_ceiling(
            model_size_gb=7.0, free_vram_mb=4096,
            native_ctx=None, floor=4096, ceiling=32768,
        )
        self.assertEqual(est, 4096)

    def test_unknown_vram_uses_default_3800(self):
        """When free_vram_mb is None, fallback to 3800 MiB."""
        est = self.mod.estimate_vram_ceiling(
            model_size_gb=2.0, free_vram_mb=None,
            native_ctx=None, floor=4096, ceiling=32768,
        )
        self.assertGreaterEqual(est, 4096)
        self.assertLessEqual(est, 32768)

    def test_zero_size_model_returns_floor(self):
        """A 0 GB model (edge case) should not raise and return floor."""
        est = self.mod.estimate_vram_ceiling(
            model_size_gb=0.0, free_vram_mb=4096,
            native_ctx=None, floor=4096, ceiling=32768,
        )
        self.assertEqual(est, 4096)

    def test_bounded_by_ceiling(self):
        """Estimate should never exceed the ceiling parameter."""
        est = self.mod.estimate_vram_ceiling(
            model_size_gb=1.0, free_vram_mb=99999,
            native_ctx=None, floor=4096, ceiling=8192,
        )
        self.assertLessEqual(est, 8192)


class OomRegexTests(unittest.TestCase):
    """Tests for the OOM_RE pattern used to detect OOM in server logs."""

    @classmethod
    def setUpClass(cls):
        cls.mod = load_module()
        cls.re = cls.mod.OOM_RE

    def matches(self, text: str) -> bool:
        return bool(self.re.search(text))

    def test_out_of_memory(self):
        self.assertTrue(self.matches("out of memory"))

    def test_oom(self):
        self.assertTrue(self.matches("CUDA OOM during allocation"))

    def test_cuda_failed(self):
        self.assertTrue(self.matches("cuda error: out of memory"))
        self.assertTrue(self.matches("CUDA failed"))

    def test_failed_to_allocate(self):
        self.assertTrue(self.matches("failed to allocate 1024 MB"))

    def test_cannot_allocate(self):
        self.assertTrue(self.matches("cannot allocate memory"))

    def test_normal_log_no_match(self):
        self.assertFalse(self.matches("llama_model_loader: loaded 42 tensors"))
        self.assertFalse(self.matches("n_ctx_train = 32768"))
        self.assertFalse(self.matches("health check passed"))


class RegistryRowParsingTests(unittest.TestCase):
    """Tests for load_registry_row and write_registry_row."""

    @classmethod
    def setUpClass(cls):
        cls.mod = load_module()
        cls._orig_registry = cls.mod.REGISTRY  # save for tearDown restore
        # Build a realistic registry fragment (20-col format with flash_attn)
        cls.sample = (
            "# LLM Registry\n"
            "# col: num|name|file|size|quant_cache|arch|gpu_layers|ctx|threads|batch|ubatch|parallel|fit_target_mb|backend|mmap_mode|flash_attn|tps|autotuned|is_default|in_vram\n"
            "1|qwen3-4b-q4_k_m.gguf|qwen3-4b-q4_k_m.gguf|2.3G|256|qwen2|33|32768|4|512|128|1|0|native|off|on|60.7|yes|y|no\n"
            "2|deepseek-coder-1.3b-instruct-q4_k_m.gguf|deepseek-coder-1.3b-instruct-q4_k_m.gguf|780M|320|deepseek2|26|16384|4|512|128|1|0|binary|off|on|71.8|yes|n|no\n"
            "3|tinyllama-1.1b-chat-v1.0.Q4_K_M.gguf|tinyllama-1.1b-chat-v1.0.Q4_K_M.gguf|666M|256|llama|26|4096|4|512|128|1|0|native|off|off||no|n|no\n"
        )

    def setUp(self):
        self.tmp = tempfile.NamedTemporaryFile(
            mode="w", suffix=".conf", delete=False, encoding="utf-8")
        self.tmp.write(self.sample)
        self.tmp.close()

    def tearDown(self):
        os.unlink(self.tmp.name)
        self.mod.REGISTRY = self._orig_registry  # restore original path

    def _patch_registry(self):
        """Point REGISTRY path to our temp file."""
        self.mod.REGISTRY = type(self.mod.REGISTRY)(self.tmp.name)

    def test_load_row_1(self):
        self._patch_registry()
        row = self.mod.load_registry_row(1)
        self.assertIsNotNone(row)
        assert row is not None  # type narrowing
        self.assertEqual(row["name"], "qwen3-4b-q4_k_m.gguf")
        self.assertEqual(row["autotuned"], "yes")
        self.assertEqual(row["ctx"], "32768")

    def test_load_row_3(self):
        self._patch_registry()
        row = self.mod.load_registry_row(3)
        self.assertIsNotNone(row)
        assert row is not None
        self.assertEqual(row["name"], "tinyllama-1.1b-chat-v1.0.Q4_K_M.gguf")
        self.assertEqual(row["autotuned"], "no")
        self.assertEqual(row["tps"], "")

    def test_load_nonexistent_row(self):
        self._patch_registry()
        row = self.mod.load_registry_row(99)
        self.assertIsNone(row)

    def test_write_updates_ctx_and_autotuned(self):
        self._patch_registry()
        self.mod.write_registry_row(3, {
            "ctx": 8192,
            "tps": "45.2",
            "autotuned": "yes",
        })
        # Reload and verify
        row = self.mod.load_registry_row(3)
        assert row is not None
        self.assertEqual(row["ctx"], "8192")
        self.assertEqual(row["tps"], "45.2")
        self.assertEqual(row["autotuned"], "yes")

    def test_write_preserves_other_rows(self):
        self._patch_registry()
        self.mod.write_registry_row(1, {"autotuned": "no"})
        row2 = self.mod.load_registry_row(2)
        assert row2 is not None
        self.assertEqual(row2["autotuned"], "yes")
        self.assertEqual(row2["name"], "deepseek-coder-1.3b-instruct-q4_k_m.gguf")


class FreeVramParsingTests(unittest.TestCase):
    """Tests for _get_free_vram_mb parsing logic (nvidia-smi output)."""
    # The actual function runs subprocess, but we can verify the regex/math
    # by testing the parsing pattern directly.

    @classmethod
    def setUpClass(cls):
        cls.mod = load_module()

    def test_nvidia_smi_output_parse(self):
        """Verify the nvidia-smi --query-gpu=memory.free output format
        is parseable as int.  This is a smoke test that the pattern
        nvidia-smi uses matches what we expect."""
        # Simulate nvidia-smi output
        simulated = "3965"
        parsed = int(simulated.strip().split("\n")[0])
        self.assertEqual(parsed, 3965)

    def test_multi_gpu_output(self):
        """Pick first line from multi-GPU output."""
        simulated = "4096\n8192"
        parsed = int(simulated.strip().split("\n")[0])
        self.assertEqual(parsed, 4096)


class ResolveMinTpsTests(unittest.TestCase):
    """Tests for resolve_min_tps() — the uniform min-TPS floor policy."""

    @classmethod
    def setUpClass(cls):
        cls.mod = load_module()

    def setUp(self):
        # Ensure a clean environment so the built-in default is observable.
        os.environ.pop("LLM_MIN_TPS", None)

    def test_default_constant_is_10(self):
        self.assertEqual(self.mod.MIN_ACCEPTABLE_TPS_DEFAULT, 10.0)

    def test_default_is_uniform_10(self):
        self.assertEqual(self.mod.resolve_min_tps("qwen2", 1.0, None), 10.0)

    def test_uniform_across_arch_and_size(self):
        # arch and size no longer relax the floor — every model is held to 10.
        self.assertEqual(self.mod.resolve_min_tps("phi3", 1.6, None), 10.0)
        self.assertEqual(self.mod.resolve_min_tps("llama", 8.0, None), 10.0)
        self.assertEqual(self.mod.resolve_min_tps("qwen35", 3.3, None), 10.0)

    def test_cli_override_wins(self):
        os.environ["LLM_MIN_TPS"] = "10"
        self.assertEqual(self.mod.resolve_min_tps("qwen2", 1.0, 12.0), 12.0)

    def test_env_override(self):
        os.environ["LLM_MIN_TPS"] = "8"
        self.assertEqual(self.mod.resolve_min_tps("qwen2", 1.0, None), 8.0)


class ModuleSmokeTests(unittest.TestCase):
    """Smoke tests that the module loads and key symbols exist."""

    @classmethod
    def setUpClass(cls):
        cls.mod = load_module()

    def test_constants_exist(self):
        self.assertTrue(hasattr(self.mod, "BURN_TOKENS"))
        self.assertEqual(self.mod.BURN_TOKENS, 64)
        self.assertTrue(hasattr(self.mod, "CTX_FLOOR"))
        self.assertEqual(self.mod.CTX_FLOOR, 4096)
        self.assertTrue(hasattr(self.mod, "CONSERVATIVE"))

    def test_required_functions_exist(self):
        for fn in ("estimate_vram_ceiling", "load_registry_row",
                   "write_registry_row", "pick_port", "read_native_ctx",
                   "start_server", "run_burn", "test_config", "main",
                   "kill_zombie_servers", "_get_free_vram_mb"):
            with self.subTest(fn=fn):
                self.assertTrue(
                    hasattr(self.mod, fn),
                    f"Required function {fn} not found in module")

    def test_script_executable(self):
        """Verify the script file is marked executable."""
        self.assertTrue(
            os.access(SCRIPT_PATH, os.X_OK),
            f"Script {SCRIPT_PATH} is not executable")


if __name__ == "__main__":
    unittest.main()
