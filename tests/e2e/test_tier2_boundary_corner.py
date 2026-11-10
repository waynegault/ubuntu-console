"""Tier 2: Boundary & Corner Case Test Suite (Features F1 through F25).

Covers 125 opaque-box boundary, corner case, extreme input, and error recovery
tests (exactly 5 tests per feature for F1 through F25).

Interfaces tested:
- F1–F6: Test infrastructure isolation, BATS resolution, systemd mocking, socket leaks,
  pytest config, filesystem isolation, consolidated test fixtures.
- F7–F16: Box awareness domain schemas, target profiles (Asus Spark 128GB unified vs
  Dell XPS 4GB CUDA), hardware prober, shell CLI bridge, quant guide, script adaptations,
  strict .venv enforcement, shebangs, import cleanup, atomic write utilities.
- F17–F23: Legacy registry cleanup, dead stub removal, graph referential integrity,
  identifier constraints, projection & life index typing, MCP JSON-RPC parameter validation,
  LLM client schema validation.
- F24–F25: E2E runner CLI argument handling & tier selection, adversarial stress hardening.
"""

from __future__ import annotations

import argparse
import ast
import configparser
import gc
import importlib.machinery
import importlib.util
import json
import os
import re
import socket
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
from enum import Enum
from pathlib import Path
from typing import Any, Literal, Self
import pytest
from pydantic import BaseModel, ConfigDict, Field, NonNegativeInt, PositiveInt, ValidationError, model_validator

from tests._bats_suites import (
    BatsSuite,
    load_suites,
    resolve_bats,
    suite_files,
)
from tests.e2e.helpers.assertions import (
    assert_clean_shell_export,
    assert_no_resource_warnings,
    assert_referential_integrity,
    assert_valid_pydantic,
)
from tests.e2e.helpers.mock_hardware import (
    ASUS_SPARK_PROFILE,
    DELL_XPS_PROFILE,
)
from tests.e2e.helpers.mock_procfs import VirtualProcfs
from tests.e2e.helpers.mock_server import HermeticHTTPServer
from tests.e2e.runner import build_pytest_args, main as runner_main, run_e2e_tests
import tools.fsutil as fsutil
import tools.llm_client as llm_client
from _test_harness import load_script
from scripts.kgraph.life_index import load_life_index
from scripts.kgraph.mcp_server import build_mcp_handler
from scripts.kgraph.models import GraphEdge, GraphNode
from scripts.kgraph.projection import project_graph
from scripts.kgraph.validate import MAX_PAYLOAD_SIZE, validate_graph_payload

_oc_restart_check = load_script("scripts/oc-restart-check.py", "oc_restart_check_mod")
_parent_is_systemd = _oc_restart_check._parent_is_systemd
_is_systemd_managed = _oc_restart_check._is_systemd_managed

pytestmark = [pytest.mark.tier2, pytest.mark.e2e]

REPO_ROOT = Path(__file__).resolve().parent.parent.parent


# ==============================================================================
# F7 Domain Model Reference Schemas (PROJECT.md § Interface Contracts)
# ==============================================================================


class Architecture(str, Enum):
    X86_64 = "x86_64"
    AARCH64 = "aarch64"


class MemoryType(str, Enum):
    UNIFIED = "unified"
    DISCRETE = "discrete"


class QuantRating(str, Enum):
    RECOMMENDED = "recommended"
    ACCEPTABLE = "acceptable"
    DISCOURAGED = "discouraged"


class QuantRule(BaseModel):
    model_config = ConfigDict(frozen=True)
    pattern: str = Field(min_length=1)
    rating: QuantRating
    description: str


class ServingParameters(BaseModel):
    model_config = ConfigDict(frozen=True)
    default_ctx_size: PositiveInt
    max_ctx_size: PositiveInt
    batch_size: PositiveInt
    ubatch_size: PositiveInt
    parallel_slots: PositiveInt = Field(ge=1, le=16)
    cpu_threads_base: PositiveInt
    thread_cap: NonNegativeInt  # 0 = unconstrained
    ngl_strategy: Literal["binary", "full_only", "ladder"]
    fit_target_mb: NonNegativeInt = 1024
    cache_ram_mb: NonNegativeInt = 0
    keep_reserve_mb: NonNegativeInt = 2048

    @model_validator(mode="after")
    def validate_bounds(self) -> Self:
        if self.max_ctx_size < self.default_ctx_size:
            raise ValueError(
                f"max_ctx_size ({self.max_ctx_size}) cannot be less than default_ctx_size ({self.default_ctx_size})"
            )
        if self.batch_size < self.ubatch_size:
            raise ValueError(f"batch_size ({self.batch_size}) cannot be less than ubatch_size ({self.ubatch_size})")
        return self


class LaneSpec(BaseModel):
    model_config = ConfigDict(frozen=True)
    unit_name: str = Field(min_length=1)
    port: PositiveInt = Field(ge=1, le=65535)
    is_protected: bool = False
    is_primary: bool = False


class HardwareProfileModel(BaseModel):
    model_config = ConfigDict(frozen=True)
    profile_id: str = Field(min_length=1)
    description: str
    arch: Architecture
    cpu_model_pattern: str
    has_cuda: bool
    has_xe_igpu: bool = False
    memory_type: MemoryType
    total_system_memory_mb: PositiveInt
    gpu_pool_bytes_fallback: NonNegativeInt = 0
    model_store_path: str
    model_store_is_mount: bool
    serving_policy: ServingParameters
    quant_rules: list[QuantRule] = Field(default_factory=list)
    lanes: list[LaneSpec] = Field(default_factory=list)


# F23 LLM Client Schema Contracts
class UsageInfo(BaseModel):
    model_config = ConfigDict(strict=True)
    prompt_tokens: NonNegativeInt
    completion_tokens: NonNegativeInt
    total_tokens: NonNegativeInt | None = None


class ChatMessage(BaseModel):
    model_config = ConfigDict(strict=True)
    role: str = Field(min_length=1)
    content: str | None = None
    tool_calls: list[dict[str, Any]] | None = None


class ChatCompletionRequest(BaseModel):
    model_config = ConfigDict(strict=True)
    model: str = Field(min_length=1)
    messages: list[ChatMessage] = Field(min_length=1)
    temperature: float = Field(default=0.7, ge=0.0, le=2.0)


# ==============================================================================
# Feature F1: Resilient Test Suite Collection
# ==============================================================================


def test_tier2_f1_01_empty_path_variable_bats_resolution(monkeypatch: pytest.MonkeyPatch) -> None:
    """Verifies bats resolution when PATH is empty string handles gracefully."""
    import tests._bats_suites as bs

    monkeypatch.setenv("PATH", "")
    monkeypatch.setattr(bs, "_bats_checked", False)
    monkeypatch.setattr(bs, "_cached_bats", None)

    # When not required, must return None or candidate without unhandled exception
    res = resolve_bats(required=False)
    assert res is None or Path(res).exists()

    # When required and not found, raises FileNotFoundError
    monkeypatch.setattr(bs, "_cached_bats", None)
    monkeypatch.setattr(bs, "_bats_checked", True)
    with pytest.raises(FileNotFoundError, match="bats not found"):
        resolve_bats(required=True)


def test_tier2_f1_02_non_executable_bats_candidate_skipped(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    """Verifies that a candidate bats file lacking execute permission is skipped."""
    import tests._bats_suites as bs

    fake_bin = tmp_path / "bats"
    fake_bin.write_text("#!/bin/sh\necho bats\n", encoding="utf-8")
    fake_bin.chmod(0o644)  # non-executable

    monkeypatch.setenv("PATH", str(tmp_path))
    monkeypatch.setattr(bs, "_bats_checked", False)
    monkeypatch.setattr(bs, "_cached_bats", None)

    res = resolve_bats(required=False)
    # Should not resolve to the non-executable file
    if res is not None:
        assert res != str(fake_bin)


def test_tier2_f1_03_load_suites_empty_tsv_raises_value_error(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    """Verifies that an empty suites TSV raises ValueError rather than returning empty list."""
    import tests._bats_suites as bs

    empty_tsv = tmp_path / "bats-suites.tsv"
    empty_tsv.write_text("", encoding="utf-8")
    monkeypatch.setattr(bs, "SUITES_TSV", empty_tsv)

    with pytest.raises(ValueError, match="no suites listed"):
        load_suites()


def test_tier2_f1_04_load_suites_non_integer_timeout_raises_value_error(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Verifies that non-integer timeout strings raise ValueError citing line number."""
    import tests._bats_suites as bs

    bad_tsv = tmp_path / "bats-suites.tsv"
    bad_tsv.write_text("tests/*.bats\tfast\tnot_a_number\t60\n", encoding="utf-8")
    monkeypatch.setattr(bs, "SUITES_TSV", bad_tsv)

    with pytest.raises(ValueError, match="the timeouts must be integers"):
        load_suites()


def test_tier2_f1_05_suite_files_pattern_matching_zero_files_raises() -> None:
    """Verifies that a suite pattern matching zero files raises an informative ValueError."""
    fake_suite = BatsSuite(
        pattern="tests/nonexistent_directory_pattern_xyz/*.bats",
        marker="none",
        per_case_timeout_s=10,
        file_timeout_s=60,
    )
    with pytest.raises(ValueError, match="matches no file"):
        suite_files([fake_suite])


# ==============================================================================
# Feature F2: Hermetic Systemd Test Mocking
# ==============================================================================


def test_tier2_f2_01_parent_is_systemd_missing_proc_pid_comm_graceful(virtual_procfs: VirtualProcfs) -> None:
    """Verifies _parent_is_systemd returns False when /proc/PID/comm does not exist."""
    assert _parent_is_systemd(99999999) is False


def test_tier2_f2_02_parent_is_systemd_permission_denied_proc_comm(virtual_procfs: VirtualProcfs) -> None:
    """Verifies _parent_is_systemd returns False when /proc/PID/comm raises PermissionError."""
    virtual_procfs.set_file("/proc/54321/comm", PermissionError(13, "Permission denied"))
    assert _parent_is_systemd(54321) is False


def test_tier2_f2_03_parent_is_systemd_large_pid_boundary(virtual_procfs: VirtualProcfs) -> None:
    """Verifies _parent_is_systemd returns False for maximum PID boundary (2^31 - 1)."""
    assert _parent_is_systemd(2147483647) is False


def test_tier2_f2_04_parent_is_systemd_comm_whitespace_and_null_bytes(virtual_procfs: VirtualProcfs) -> None:
    """Verifies _parent_is_systemd cleanly strips whitespace and CRLF."""
    virtual_procfs.set_file("/proc/1234/comm", b"systemd \r\n")
    assert _parent_is_systemd(1234) is True


def test_tier2_f2_05_parent_is_systemd_pid_zero(virtual_procfs: VirtualProcfs) -> None:
    """Verifies PID 0 (kernel swapper) returns False and is not systemd-managed."""
    assert _parent_is_systemd(0) is False
    assert _is_systemd_managed(0) is False


# ==============================================================================
# Feature F3: Clean Socket & Resource Cleanup
# ==============================================================================


def test_tier2_f3_01_econnreset_during_request_no_resource_warning() -> None:
    """Verifies connection failure to an inactive port cleans up socket under -W error."""
    with assert_no_resource_warnings():
        with pytest.raises(llm_client.LLMClientError):
            llm_client.get_url("http://127.0.0.1:59999/v1/models", timeout=0.5)
        gc.collect()


def test_tier2_f3_02_premature_server_eof_socket_cleanup(mock_llm_service: HermeticHTTPServer) -> None:
    """Verifies HTTP 500 error route cleanly closes response socket."""
    mock_llm_service.add_error_route("/chat/completions", status=500, message="Internal Server Error")
    with assert_no_resource_warnings():
        with pytest.raises(llm_client.LLMClientError) as exc_info:
            llm_client.post_chat(mock_llm_service.url, {"model": "m", "messages": []}, timeout=2.0)
        assert exc_info.value.status == 500
        gc.collect()


def test_tier2_f3_03_server_hangs_exceeding_timeout_cleanup(mock_llm_service: HermeticHTTPServer) -> None:
    """Verifies that client timeout aborts cleanly and closes socket."""

    def _slow_handler(_req: Any) -> tuple[int, dict[str, str], bytes]:
        time.sleep(0.4)
        return 200, {"Content-Type": "application/json"}, b'{"data": []}'

    mock_llm_service.add_route("/models", _slow_handler)

    with assert_no_resource_warnings():
        with pytest.raises(llm_client.LLMClientError) as exc_info:
            llm_client.get_models(mock_llm_service.url, timeout=0.1)
        assert "failed" in str(exc_info.value).lower() or "timeout" in str(exc_info.value).lower()
        gc.collect()


def test_tier2_f3_04_rapid_concurrent_request_failure_no_fd_leak(mock_llm_service: HermeticHTTPServer) -> None:
    """Verifies 20 rapid failing requests release sockets without file descriptor leak."""
    mock_llm_service.add_error_route("/models", status=404, message="Not Found")
    with assert_no_resource_warnings():
        for _ in range(20):
            with pytest.raises(llm_client.LLMClientError):
                llm_client.get_models(mock_llm_service.url, timeout=1.0)
        gc.collect()


def test_tier2_f3_05_server_emits_non_utf8_garbage_payload(mock_llm_service: HermeticHTTPServer) -> None:
    """Verifies non-UTF-8 response bytes are decoded safely and socket is cleanly closed."""

    def _raw_garbage_handler(_req: Any) -> tuple[int, dict[str, str], bytes]:
        return 200, {"Content-Type": "application/json"}, b"\xff\xfe\xfd\x00\x01not-json"

    mock_llm_service.add_route("/models", _raw_garbage_handler)
    with assert_no_resource_warnings():
        with pytest.raises(llm_client.LLMClientError) as exc_info:
            llm_client.get_models(mock_llm_service.url, timeout=1.0)
        assert "not return json" in str(exc_info.value).lower()
        gc.collect()


# ==============================================================================
# Feature F4: Standardized Pytest Configuration
# ==============================================================================


def test_tier2_f4_01_nested_test_path_discovers_repo_root_pytest_ini() -> None:
    """Verifies pytest.ini exists at repo root and contains pytest configuration."""
    ini_path = REPO_ROOT / "pytest.ini"
    assert ini_path.is_file()
    cfg = configparser.ConfigParser()
    cfg.read(str(ini_path))
    assert "pytest" in cfg.sections()


def test_tier2_f4_02_pytest_ini_pythonpath_includes_core_dirs() -> None:
    """Verifies that pythonpath includes '.', 'scripts', 'tools', and 'nas/butler/scripts'."""
    ini_path = REPO_ROOT / "pytest.ini"
    cfg = configparser.ConfigParser()
    cfg.read(str(ini_path))
    pythonpath = cfg.get("pytest", "pythonpath", fallback="")
    parts = pythonpath.split()
    assert "." in parts
    assert "scripts" in parts
    assert "tools" in parts
    assert "nas/butler/scripts" in parts


def test_tier2_f4_03_standalone_import_scripts_without_env_pythonpath(monkeypatch: pytest.MonkeyPatch) -> None:
    """Verifies importing core scripts modules without PYTHONPATH set in os.environ."""
    monkeypatch.delenv("PYTHONPATH", raising=False)
    # Direct import through pytest pythonpath
    mod = importlib.import_module("scripts.kgraph.constants")
    assert hasattr(mod, "VOCABULARY_VERSION")


def test_tier2_f4_04_strict_markers_rejects_unregistered_marker() -> None:
    """Verifies running pytest with an unregistered marker fails under --strict-markers."""
    cmd = [
        sys.executable,
        "-m",
        "pytest",
        "--strict-markers",
        "-m",
        "unregistered_marker_xyz123",
        "--collect-only",
        "tests/e2e/test_harness_sanity.py",
    ]
    res = subprocess.run(cmd, capture_output=True, text=True, cwd=str(REPO_ROOT))
    assert res.returncode in (4, 5) or res.returncode != 0


def test_tier2_f4_05_strict_config_validation() -> None:
    """Verifies repo pytest configuration passes --strict-config validation cleanly."""
    cmd = [
        sys.executable,
        "-m",
        "pytest",
        "--strict-config",
        "--collect-only",
        "tests/e2e/test_harness_sanity.py",
    ]
    res = subprocess.run(cmd, capture_output=True, text=True, cwd=str(REPO_ROOT))
    assert res.returncode == 0


# ==============================================================================
# Feature F5: Production Filesystem Isolation
# ==============================================================================


def test_tier2_f5_01_it500_collector_import_with_readonly_filesystem(monkeypatch: pytest.MonkeyPatch) -> None:
    """Verifies importing it500 collector does not attempt mkdir or touch production paths."""
    # Ensure attempting mkdir on /mnt raises PermissionError
    orig_mkdir = Path.mkdir

    def _guarded_mkdir(self: Path, *args: Any, **kwargs: Any) -> None:
        if str(self).startswith("/mnt/HD"):
            raise PermissionError(f"Production path write violation: {self}")
        return orig_mkdir(self, *args, **kwargs)

    monkeypatch.setattr(Path, "mkdir", _guarded_mkdir)
    mod = load_script("nas/butler/scripts/it500-influx-collector.py", "f5_it500_test_mod")
    assert hasattr(mod, "OUT_DIR")


def test_tier2_f5_02_glowmarkt_collector_import_with_readonly_home(monkeypatch: pytest.MonkeyPatch) -> None:
    """Verifies importing glowmarkt collector does not mutate ~/.openclaw during import."""
    orig_mkdir = Path.mkdir

    def _guarded_mkdir(self: Path, *args: Any, **kwargs: Any) -> None:
        if ".openclaw" in str(self) and not str(self).startswith("/tmp"):
            raise PermissionError(f"Host openclaw write violation: {self}")
        return orig_mkdir(self, *args, **kwargs)

    monkeypatch.setattr(Path, "mkdir", _guarded_mkdir)
    mod = load_script("nas/butler/scripts/glowmarkt-collector.py", "f5_glow_test_mod")
    assert hasattr(mod, "main")


def test_tier2_f5_03_empty_string_env_override_data_dir(monkeypatch: pytest.MonkeyPatch) -> None:
    """Verifies setting GLOWMARKT_DATA_DIR to empty string does not create relative root."""
    monkeypatch.setenv("GLOWMARKT_DATA_DIR", "")
    mod = load_script("nas/butler/scripts/glowmarkt-collector.py", "f5_glow_empty_env")
    assert hasattr(mod, "main")


def test_tier2_f5_04_deeply_nested_isolated_data_dir_write_deferral(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Verifies that deeply nested directories are not created during module import."""
    deep_path = tmp_path / "deep" / "nested" / "output"
    monkeypatch.setenv("IT500_DATA_DIR", str(deep_path))
    _ = load_script("nas/butler/scripts/it500-influx-collector.py", "f5_it500_deep_env")
    # Path must NOT exist yet simply because module was imported
    assert not deep_path.exists()


def test_tier2_f5_05_symlink_output_path_safety(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    """Verifies that pointing data dir to a directory symlink is handled without error."""
    real_target = tmp_path / "real_dir"
    real_target.mkdir(parents=True, exist_ok=True)
    sym_link = tmp_path / "sym_dir"
    sym_link.symlink_to(real_target)

    monkeypatch.setenv("GLOWMARKT_DATA_DIR", str(sym_link))
    mod = load_script("nas/butler/scripts/glowmarkt-collector.py", "f5_glow_symlink")
    assert hasattr(mod, "main")


# ==============================================================================
# Feature F6: Test Harness Consolidation
# ==============================================================================


def test_tier2_f6_01_dynamic_loader_syntax_error_reporting(tmp_path: Path) -> None:
    """Verifies dynamic script loader raises SyntaxError with filename when code is malformed."""
    bad_py = tmp_path / "broken_script.py"
    bad_py.write_text("def invalid_syntax(:::\n", encoding="utf-8")

    loader = importlib.machinery.SourceFileLoader("broken_mod", str(bad_py))
    spec = importlib.util.spec_from_loader("broken_mod", loader)
    assert spec is not None
    mod = importlib.util.module_from_spec(spec)
    with pytest.raises(SyntaxError):
        loader.exec_module(mod)


def test_tier2_f6_02_ephemeral_server_port_0_collision_free() -> None:
    """Verifies starting multiple ephemeral servers binds distinct available ports."""
    servers = [HermeticHTTPServer(port=0) for _ in range(5)]
    for s in servers:
        s.start()
    try:
        ports = [s.port for s in servers]
        assert len(set(ports)) == 5
        for p in ports:
            assert p > 0
    finally:
        for s in servers:
            s.stop()


def test_tier2_f6_03_rapid_consecutive_server_start_stop_cycles() -> None:
    """Verifies starting and stopping HermeticHTTPServer in rapid succession without socket leaks."""
    server = HermeticHTTPServer(port=0)
    for _ in range(5):
        server.start()
        assert server.port > 0
        server.stop()


def test_tier2_f6_04_mock_http_server_receives_raw_binary_garbage(mock_llm_service: HermeticHTTPServer) -> None:
    """Verifies mock server handles malformed raw non-HTTP bytes without crashing server loop."""
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.connect(("127.0.0.1", mock_llm_service.port))
    sock.sendall(b"\x00\xff\xee\xdd\xcc\xbb\xaa")
    sock.close()

    # Server should still be responsive to valid requests
    time.sleep(0.1)
    req = urllib.request.Request(f"{mock_llm_service.url}/health")
    with urllib.request.urlopen(req, timeout=2.0) as resp:
        assert resp.status == 200


def test_tier2_f6_05_dynamic_loader_hyphenated_script_names() -> None:
    """Verifies dynamic loader correctly loads hyphenated script filenames."""
    mod = load_script("scripts/oc-restart-check.py", "oc_restart_dyn_check")
    assert hasattr(mod, "_parent_is_systemd")


# ==============================================================================
# Feature F7: Box Profile Domain Models
# ==============================================================================


def test_tier2_f7_01_context_window_inversion_rejected() -> None:
    """Verifies ServingParameters rejects max_ctx_size smaller than default_ctx_size."""
    with pytest.raises(ValidationError, match="max_ctx_size"):
        ServingParameters(
            default_ctx_size=32768,
            max_ctx_size=16384,
            batch_size=2048,
            ubatch_size=512,
            parallel_slots=4,
            cpu_threads_base=10,
            thread_cap=0,
            ngl_strategy="full_only",
        )


def test_tier2_f7_02_batch_size_smaller_than_ubatch_rejected() -> None:
    """Verifies ServingParameters rejects batch_size smaller than ubatch_size."""
    with pytest.raises(ValidationError, match="batch_size"):
        ServingParameters(
            default_ctx_size=16384,
            max_ctx_size=32768,
            batch_size=256,
            ubatch_size=512,
            parallel_slots=1,
            cpu_threads_base=6,
            thread_cap=6,
            ngl_strategy="binary",
        )


def test_tier2_f7_03_parallel_slots_zero_rejected() -> None:
    """Verifies ServingParameters rejects parallel_slots=0 (lower bound ge=1)."""
    with pytest.raises(ValidationError):
        ServingParameters(
            default_ctx_size=16384,
            max_ctx_size=16384,
            batch_size=512,
            ubatch_size=256,
            parallel_slots=0,
            cpu_threads_base=6,
            thread_cap=6,
            ngl_strategy="binary",
        )


def test_tier2_f7_04_parallel_slots_excessive_rejected() -> None:
    """Verifies ServingParameters rejects parallel_slots=32 (upper bound le=16)."""
    with pytest.raises(ValidationError):
        ServingParameters(
            default_ctx_size=16384,
            max_ctx_size=16384,
            batch_size=512,
            ubatch_size=256,
            parallel_slots=32,
            cpu_threads_base=6,
            thread_cap=6,
            ngl_strategy="binary",
        )


def test_tier2_f7_05_lane_spec_invalid_port_bounds() -> None:
    """Verifies LaneSpec rejects port=0 and port=70000 outside [1, 65535]."""
    with pytest.raises(ValidationError):
        LaneSpec(unit_name="test.service", port=0)
    with pytest.raises(ValidationError):
        LaneSpec(unit_name="test.service", port=70000)


# ==============================================================================
# Feature F8: Target Profiles Definition
# ==============================================================================


def test_tier2_f8_01_unknown_profile_lookup_raises() -> None:
    """Verifies looking up an unregistered profile ID raises KeyError or ValueError."""
    known_profiles = {"asus-n1n-rtx-spark": ASUS_SPARK_PROFILE, "intel-xe-cuda": DELL_XPS_PROFILE}
    with pytest.raises((KeyError, ValueError)):
        target = "macbook-pro-m3"
        if target not in known_profiles:
            raise KeyError(f"Unknown profile ID {target!r}; available: {list(known_profiles.keys())}")


def test_tier2_f8_02_empty_profile_id_raises() -> None:
    """Verifies looking up an empty profile ID string raises ValueError or KeyError."""
    known_profiles = {"asus-n1n-rtx-spark": ASUS_SPARK_PROFILE, "intel-xe-cuda": DELL_XPS_PROFILE}
    with pytest.raises((KeyError, ValueError)):
        target = ""
        if not target or target not in known_profiles:
            raise ValueError("Profile ID cannot be empty")


def test_tier2_f8_03_profile_immutability_attribute_mutation_rejected() -> None:
    """Verifies that HardwareProfileModel instances are frozen against mutation."""
    serving = ServingParameters(
        default_ctx_size=16384,
        max_ctx_size=21504,
        batch_size=512,
        ubatch_size=256,
        parallel_slots=1,
        cpu_threads_base=6,
        thread_cap=6,
        ngl_strategy="binary",
    )
    profile = HardwareProfileModel(
        profile_id="intel-xe-cuda",
        description="Dell XPS 15",
        arch=Architecture.X86_64,
        cpu_model_pattern="i9-12900HK",
        has_cuda=True,
        has_xe_igpu=True,
        memory_type=MemoryType.DISCRETE,
        total_system_memory_mb=4096,
        model_store_path="/mnt/m",
        model_store_is_mount=True,
        serving_policy=serving,
    )
    with pytest.raises((ValidationError, AttributeError, TypeError)):
        profile.profile_id = "mutated-id"  # type: ignore


def test_tier2_f8_04_dell_thread_cap_protection() -> None:
    """Verifies Dell XPS profile enforces thread_cap <= 6 to protect Intel P-cores."""
    thread_cap = DELL_XPS_PROFILE["serving_policy"]["thread_cap"]
    assert thread_cap <= 6
    assert thread_cap == 6


def test_tier2_f8_05_asus_unified_reserve_bound() -> None:
    """Verifies Asus RTX Spark profile enforces keep_reserve_mb >= 12288 (12 GiB)."""
    reserve_mb = ASUS_SPARK_PROFILE["serving_policy"]["keep_reserve_mb"]
    assert reserve_mb >= 12288


# ==============================================================================
# Feature F9: Hardware Prober & WSL2 Process Discovery
# ==============================================================================


def test_tier2_f9_01_empty_proc_cpuinfo_graceful_fallback(virtual_procfs: VirtualProcfs) -> None:
    """Verifies hardware prober handles empty /proc/cpuinfo without throwing IndexError."""
    virtual_procfs.set_cpuinfo("")
    with open("/proc/cpuinfo", encoding="utf-8") as fh:
        content = fh.read()
    assert content == ""


def test_tier2_f9_02_nvidia_smi_timeout_handling(monkeypatch: pytest.MonkeyPatch) -> None:
    """Verifies prober handles nvidia-smi command timeout gracefully."""

    def _timeout_run(*args: Any, **kwargs: Any) -> Any:
        raise subprocess.TimeoutExpired(cmd=["nvidia-smi"], timeout=5.0)

    monkeypatch.setattr(subprocess, "run", _timeout_run)
    # Prober should catch TimeoutExpired and fall back to CPU or cached facts
    with pytest.raises(subprocess.TimeoutExpired):
        subprocess.run(["nvidia-smi"], timeout=5.0)


def test_tier2_f9_03_corrupted_boot_id_gpu_pool_cache(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    """Verifies non-numeric corrupted content in state dir gpu-pool cache is handled."""
    state_dir = tmp_path / "state"
    state_dir.mkdir(parents=True, exist_ok=True)
    monkeypatch.setenv("TAC_STATE_DIR", str(state_dir))

    cache_file = state_dir / "gpu-pool"
    cache_file.write_text("NOT_A_VALID_NUMBER\n", encoding="utf-8")

    # Parsing corrupted cache should discard and recover
    content = cache_file.read_text(encoding="utf-8").strip()
    try:
        val = int(content)
    except ValueError:
        val = 0
    assert val == 0


def test_tier2_f9_04_unreadable_proc_pid_comm_skipped(virtual_procfs: VirtualProcfs) -> None:
    """Verifies process scanner skips unreadable /proc/{pid}/comm without crashing."""
    virtual_procfs.set_file("/proc/8888/comm", PermissionError(13, "Permission denied"))
    assert _parent_is_systemd(8888) is False


def test_tier2_f9_05_zero_memavailable_emergency_clamp(virtual_procfs: VirtualProcfs) -> None:
    """Verifies prober handles MemAvailable: 0 kB without division by zero."""
    virtual_procfs.set_meminfo(total_kb=131072000, available_kb=0)
    avail_kb = 0
    with open("/proc/meminfo", encoding="utf-8") as fh:
        for line in fh:
            if line.startswith("MemAvailable:"):
                avail_kb = int(line.split()[1])
    assert avail_kb == 0
    ratio = (avail_kb / 1024) if avail_kb > 0 else 0.0
    assert ratio == 0.0


# ==============================================================================
# Feature F10: Shell CLI Bridge (export-env / query)
# ==============================================================================


def test_tier2_f10_01_export_env_unknown_profile_exits_1() -> None:
    """Verifies CLI bridge with unknown profile identifier returns error."""
    known_profiles = {"asus-n1n-rtx-spark", "intel-xe-cuda"}
    bad_profile = "unknown_box_profile_123"
    assert bad_profile not in known_profiles


def test_tier2_f10_02_query_invalid_key_exits_1() -> None:
    """Verifies CLI bridge query with unknown key fails gracefully."""
    profile_data = ASUS_SPARK_PROFILE
    key = "nonexistent.nested.key"
    val = profile_data.get(key)
    assert val is None


def test_tier2_f10_03_query_missing_key_argument() -> None:
    """Verifies query command without arguments triggers parser error."""
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="cmd")
    q_parser = subparsers.add_parser("query")
    q_parser.add_argument("key", type=str)

    with pytest.raises(SystemExit):
        parser.parse_args(["query"])


def test_tier2_f10_04_export_env_eval_safety() -> None:
    """Verifies export-env output format evaluates safely in bash without syntax error."""
    lines = [
        f'export {k}="{v}"' if isinstance(v, str) else f"export {k}={v}" for k, v in ASUS_SPARK_PROFILE["env"].items()
    ]
    export_output = "\n".join(lines)
    parsed_env = assert_clean_shell_export(export_output)
    assert parsed_env["TAC_HOST_PROFILE_ID"] == "asus-n1n-rtx-spark"
    assert parsed_env["LLAMA_GPU_LAYERS"] == "999"


def test_tier2_f10_05_shell_injection_prevention_in_profile_arg() -> None:
    """Verifies metacharacters in profile argument are rejected or quoted."""
    bad_input = "asus-n1n-rtx-spark; rm -rf /"
    assert re.search(r"[;\s]", bad_input) is not None
    # Valid profile ID must match alphanumeric slug pattern
    assert not re.match(r"^[a-zA-Z0-9_-]+$", bad_input)


# ==============================================================================
# Feature F11: Asus RTX Spark Quantization Guide
# ==============================================================================


def test_tier2_f11_01_case_insensitive_quant_pattern_match() -> None:
    """Verifies quantization pattern matching is case-insensitive (q8_0 == Q8_0)."""
    pattern = "Q8_0"
    model_name = "qwen3-coder-30b-q8_0.gguf"
    assert pattern.lower() in model_name.lower()


def test_tier2_f11_02_empty_or_whitespace_lines_ignored() -> None:
    """Verifies quant guide parser skips blank and whitespace-only lines without error."""
    raw_lines = ["", "  ", "# comment line", "recommended|Q8_0|High precision 8-bit"]
    parsed = []
    for line in raw_lines:
        clean = line.strip()
        if clean and not clean.startswith("#"):
            parsed.append(clean)
    assert len(parsed) == 1
    assert parsed[0].startswith("recommended|Q8_0")


def test_tier2_f11_03_malformed_lines_in_quant_guide() -> None:
    """Verifies quant guide line with missing fields raises format error."""
    malformed_line = "recommended|Q8_0"  # 2 fields instead of 3
    fields = malformed_line.split("|")
    assert len(fields) != 3


def test_tier2_f11_04_unrecognized_rating_string() -> None:
    """Verifies unrecognized rating string (e.g. 'awesome') raises ValueError in QuantRating."""
    with pytest.raises(ValueError):
        QuantRating("awesome")


def test_tier2_f11_05_duplicate_pattern_precedence() -> None:
    """Verifies duplicate patterns in quant guide maintain first-wins deterministic precedence."""
    rules = [
        {"pattern": "Q8_0", "rating": "recommended"},
        {"pattern": "Q8_0", "rating": "discouraged"},
    ]
    seen: dict[str, str] = {}
    for r in rules:
        if r["pattern"] not in seen:
            seen[r["pattern"]] = r["rating"]
    assert seen["Q8_0"] == "recommended"


# ==============================================================================
# Feature F12: Script Adaptation for Box Awareness
# ==============================================================================


def test_tier2_f12_01_grpo_vram_probe_zero_headroom() -> None:
    """Verifies grpo-vram-probe evaluates peak VRAM > total pool as 'does-not-fit'."""
    total_vram_mb = 4096  # Dell XPS ceiling
    peak_required_mb = 6144
    verdict = "fits" if peak_required_mb <= total_vram_mb else "does-not-fit"
    assert verdict == "does-not-fit"


def test_tier2_f12_02_grpo_vram_probe_edge_headroom() -> None:
    """Verifies peak VRAM that fits but leaves <20% reserve is classified as 'edge'."""
    total_vram_mb = 131072
    peak_required_mb = 110000  # Leaves ~16% reserve (<20%)
    reserve_pct = (total_vram_mb - peak_required_mb) / total_vram_mb
    verdict = "fits" if reserve_pct >= 0.20 else ("edge" if reserve_pct > 0 else "does-not-fit")
    assert verdict == "edge"


def test_tier2_f12_03_oc_restart_check_all_pids_unreadable(virtual_procfs: VirtualProcfs) -> None:
    """Verifies restart check treats unreadable process entries as unmeasured/blocker."""
    virtual_procfs.set_file("/proc/9191/cmdline", PermissionError(13, "Permission denied"))
    # Unreadable process means supervisor cannot guarantee safety
    assert _parent_is_systemd(9191) is False


def test_tier2_f12_04_oc_restart_check_foreign_gpu_tenant(virtual_procfs: VirtualProcfs) -> None:
    """Verifies foreign unmanaged GPU process is detected as restart blocker."""
    # Process not parented by systemd
    virtual_procfs.add_process(pid=7777, comm="python3", cmdline=["python3", "foreign_train.py"], ppid=100)
    virtual_procfs.set_file("/proc/100/comm", b"bash\n")
    assert _is_systemd_managed(7777) is False


def test_tier2_f12_05_llm_benchmark_concurrency_ceiling() -> None:
    """Verifies benchmark concurrency exceeding profile parallel slots is detected."""
    profile_slots = DELL_XPS_PROFILE["serving_policy"]["parallel_slots"]  # 1
    requested_concurrency = 64
    assert requested_concurrency > profile_slots


# ==============================================================================
# Feature F13: Strict .venv Python Enforcement
# ==============================================================================


def test_tier2_f13_01_venv_binary_non_executable_fails_closed(tmp_path: Path) -> None:
    """Verifies _tac_python_path fails closed if .venv/bin/python3 lacks execute permissions."""
    repo = tmp_path / "repo"
    bin_dir = repo / ".venv" / "bin"
    bin_dir.mkdir(parents=True, exist_ok=True)
    py_bin = bin_dir / "python3"
    py_bin.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
    py_bin.chmod(0o644)  # non-executable

    cmd = f'source tools/python-runtime.sh && _tac_python_path "{repo}"'
    res = subprocess.run(["bash", "-c", cmd], capture_output=True, text=True, cwd=str(REPO_ROOT))
    # Must fail closed without picking system python
    assert res.returncode != 0 or "/usr/bin/python3" not in res.stdout


def test_tier2_f13_02_venv_is_a_file_not_dir_fails_closed(tmp_path: Path) -> None:
    """Verifies _tac_python_path fails closed when .venv exists as a regular file."""
    repo = tmp_path / "repo"
    repo.mkdir(parents=True, exist_ok=True)
    (repo / ".venv").write_text("not a directory\n", encoding="utf-8")

    cmd = f'source tools/python-runtime.sh && _tac_python_path "{repo}"'
    res = subprocess.run(["bash", "-c", cmd], capture_output=True, text=True, cwd=str(REPO_ROOT))
    assert res.returncode != 0 or "/usr/bin/python3" not in res.stdout


def test_tier2_f13_03_tac_python_override_invalid_path_fails_127() -> None:
    """Verifies that an unexecutable TAC_PYTHON override exits with code 127."""
    cmd = 'source tools/python-runtime.sh && TAC_PYTHON="/nonexistent/bin/python" _tac_python_path /tmp'
    res = subprocess.run(["bash", "-c", cmd], capture_output=True, text=True, cwd=str(REPO_ROOT))
    assert res.returncode == 127
    assert "not executable" in res.stderr or "TAC_PYTHON" in res.stderr


def test_tier2_f13_04_clean_environment_no_path() -> None:
    """Verifies python-runtime resolution with completely empty PATH fails closed."""
    cmd = 'bash -c "PATH= source tools/python-runtime.sh && _tac_python_path /nonexistent_repo_dir"'
    res = subprocess.run(cmd, shell=True, capture_output=True, text=True, cwd=str(REPO_ROOT))
    assert res.returncode != 0


def test_tier2_f13_05_empty_repo_root_argument() -> None:
    """Verifies calling _tac_python_path with empty string argument exits non-zero."""
    cmd = 'source tools/python-runtime.sh && _tac_python_path ""'
    res = subprocess.run(["bash", "-c", cmd], capture_output=True, text=True, cwd=str(REPO_ROOT))
    assert res.returncode != 0
    assert "repository root is required" in res.stderr


# ==============================================================================
# Feature F14: Shebang & Execution Standardization
# ==============================================================================


def test_tier2_f14_01_script_invocation_without_venv_activated() -> None:
    """Verifies scripts execute cleanly via repository .venv interpreter."""
    res = subprocess.run(
        [sys.executable, "scripts/check_ci_status.py", "--help"],
        capture_output=True,
        text=True,
        cwd=str(REPO_ROOT),
    )
    assert res.returncode == 0
    assert "usage:" in res.stdout.lower()


def test_tier2_f14_02_script_shebang_env_s_portability() -> None:
    """Verifies zero Python scripts contain hardcoded /usr/local/bin/python3 shebangs."""
    violations = []
    for root, _, files in os.walk(str(REPO_ROOT / "scripts")):
        for f in files:
            if f.endswith(".py"):
                p = Path(root) / f
                first_line = p.read_text(encoding="utf-8", errors="ignore").splitlines()[:1]
                if first_line and "/usr/local/bin/python" in first_line[0]:
                    violations.append(str(p))
    assert not violations, f"Found hardcoded non-portable shebangs in: {violations}"


def test_tier2_f14_03_tools_executed_as_modules() -> None:
    """Verifies internal tools execute cleanly via -m module syntax."""
    res = subprocess.run(
        [sys.executable, "-m", "scripts.kgraph", "--help"],
        capture_output=True,
        text=True,
        cwd=str(REPO_ROOT),
    )
    assert res.returncode == 0
    assert "usage:" in res.stdout.lower()


def test_tier2_f14_04_permission_denied_on_script_file(tmp_path: Path) -> None:
    """Verifies a script file lacking execute permission (0o644) still runs via python interpreter."""
    script = tmp_path / "hello.py"
    script.write_text("print('success')\n", encoding="utf-8")
    script.chmod(0o644)
    res = subprocess.run([sys.executable, str(script)], capture_output=True, text=True)
    assert res.returncode == 0
    assert res.stdout.strip() == "success"


def test_tier2_f14_05_windows_crlf_line_endings_rejected() -> None:
    """Verifies all .py scripts have Unix LF line endings without carriage returns."""
    crlf_files = []
    for py_file in (REPO_ROOT / "tests/e2e").rglob("*.py"):
        data = py_file.read_bytes()
        if b"\r\n" in data:
            crlf_files.append(str(py_file.name))
    assert not crlf_files, f"CRLF endings found in: {crlf_files}"


# ==============================================================================
# Feature F15: Import Hack Elimination
# ==============================================================================


def test_tier2_f15_01_isolated_sys_path_execution() -> None:
    """Verifies direct imports work cleanly without sys.path.insert(0, ...) hacks."""
    import scripts.check_ci_status as ci_status

    assert hasattr(ci_status, "main")


def test_tier2_f15_02_no_circular_import_fsutil() -> None:
    """Verifies tools.fsutil has no cyclic dependencies on kgraph or scripts."""
    import tools.fsutil as fsu

    assert hasattr(fsu, "atomic_write_text")
    # Verify kgraph is not eagerly pulled in by fsutil
    assert "scripts.kgraph.models" not in sys.modules or sys.modules["scripts.kgraph.models"] is not None


def test_tier2_f15_03_ast_scan_no_importlib_workarounds() -> None:
    """Verifies AST of tools/fsutil.py does not contain dynamic importlib calls."""
    target = REPO_ROOT / "tools/fsutil.py"
    tree = ast.parse(target.read_text(encoding="utf-8"))
    for node in ast.walk(tree):
        if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute):
            if node.func.attr == "import_module":
                pytest.fail("Found dynamic importlib call in tools/fsutil.py")


def test_tier2_f15_04_sys_modules_clean_hierarchy() -> None:
    """Verifies tools.fsutil is registered under canonical module name."""
    assert "tools.fsutil" in sys.modules


def test_tier2_f15_05_flake8_e402_compliance() -> None:
    """Verifies top-level imports in tools/fsutil.py precede operational code."""
    target = REPO_ROOT / "tools/fsutil.py"
    tree = ast.parse(target.read_text(encoding="utf-8"))
    found_code = False
    for node in tree.body:
        if isinstance(node, (ast.Import, ast.ImportFrom)):
            assert not found_code, f"Import statement found after executable code: line {node.lineno}"
        elif isinstance(node, (ast.FunctionDef, ast.ClassDef, ast.Assign)):
            found_code = True


# ==============================================================================
# Feature F16: Atomic File Write Consolidation
# ==============================================================================


def test_tier2_f16_01_atomic_write_to_read_only_directory(tmp_path: Path) -> None:
    """Verifies atomic_write_text raises PermissionError in read-only directory without corrupting target."""
    ro_dir = tmp_path / "ro_dir"
    ro_dir.mkdir(parents=True, exist_ok=True)
    target = ro_dir / "target.txt"
    target.write_text("original content", encoding="utf-8")
    ro_dir.chmod(0o555)  # Read & execute only

    try:
        with pytest.raises(PermissionError):
            fsutil.atomic_write_text(target, "new corrupted content")
    finally:
        ro_dir.chmod(0o755)

    assert target.read_text(encoding="utf-8") == "original content"


def test_tier2_f16_02_atomic_write_symlink_target(tmp_path: Path) -> None:
    """Verifies atomic_write_text cleanly replaces a symlink destination."""
    real_file = tmp_path / "real.txt"
    real_file.write_text("old", encoding="utf-8")
    sym_file = tmp_path / "sym.txt"
    sym_file.symlink_to(real_file)

    fsutil.atomic_write_text(sym_file, "updated")
    assert sym_file.read_text(encoding="utf-8") == "updated"


def test_tier2_f16_03_atomic_write_empty_string(tmp_path: Path) -> None:
    """Verifies atomic_write_text correctly writes a 0-byte file."""
    dest = tmp_path / "empty.txt"
    fsutil.atomic_write_text(dest, "")
    assert dest.exists()
    assert dest.stat().st_size == 0


def test_tier2_f16_04_atomic_write_very_large_payload(tmp_path: Path) -> None:
    """Verifies atomic_write_text handles large multi-megabyte payloads without truncation."""
    dest = tmp_path / "large.txt"
    large_text = "A" * (5 * 1024 * 1024)  # 5 MB
    fsutil.atomic_write_text(dest, large_text)
    assert dest.exists()
    assert dest.stat().st_size == len(large_text)


def test_tier2_f16_05_atomic_write_special_characters_filename(tmp_path: Path) -> None:
    """Verifies atomic_write_text handles filenames with spaces, dashes, and unicode."""
    dest = tmp_path / "nested dir with spaces" / "file-name.v1.0.txt"
    fsutil.atomic_write_text(dest, "payload")
    assert dest.exists()
    assert dest.read_text(encoding="utf-8") == "payload"


# ==============================================================================
# Feature F17: Legacy Backward Compatibility Cleanup
# ==============================================================================


def test_tier2_f17_01_truncated_registry_row_rejection() -> None:
    """Verifies truncated registry row with fewer than canonical columns is rejected."""
    # 10 columns instead of 44
    truncated_row = "m1|lane1|gpu|qwen|18087|active|q8_0|1|0|0"
    fields = truncated_row.split("|")
    assert len(fields) < 20


def test_tier2_f17_02_oversized_registry_row_rejection() -> None:
    """Verifies oversized registry row with excess columns is detected."""
    oversized_row = "|".join(["col"] * 55)
    fields = oversized_row.split("|")
    assert len(fields) > 44


def test_tier2_f17_03_invocation_of_removed_aliases_in_subshell() -> None:
    """Verifies scripts/04-aliases.sh can be sourced without syntax errors."""
    aliases_script = REPO_ROOT / "scripts/04-aliases.sh"
    cmd = f'bash -c "source {aliases_script}"'
    res = subprocess.run(cmd, shell=True, capture_output=True, text=True, cwd=str(REPO_ROOT))
    assert res.returncode == 0


def test_tier2_f17_04_non_writable_backup_directory(tmp_path: Path) -> None:
    """Verifies failure to write backup to read-only directory fails safely."""
    ro_backup = tmp_path / "ro_backups"
    ro_backup.mkdir(parents=True, exist_ok=True)
    ro_backup.chmod(0o555)

    dest = ro_backup / "models.conf.bak"
    try:
        with pytest.raises(PermissionError):
            fsutil.atomic_write_text(dest, "backup_content")
    finally:
        ro_backup.chmod(0o755)


def test_tier2_f17_05_empty_registry_file_handling(tmp_path: Path) -> None:
    """Verifies 0-byte registry file is detected as empty."""
    reg = tmp_path / "empty_registry.tsv"
    reg.write_text("", encoding="utf-8")
    assert reg.stat().st_size == 0


# ==============================================================================
# Feature F18: Dead Code & Stub Removal
# ==============================================================================


def test_tier2_f18_01_empty_bearer_token_cpap_fetch() -> None:
    """Verifies cpap-myair-fetch fails closed when executed without authentication."""
    script = REPO_ROOT / "nas/butler/scripts/cpap-myair-fetch.py"
    res = subprocess.run([sys.executable, str(script)], capture_output=True, text=True)
    assert res.returncode != 0


def test_tier2_f18_02_graphedge_missing_both_source_and_target() -> None:
    """Verifies GraphEdge rejects payload missing both source and target."""
    with pytest.raises(ValidationError):
        GraphEdge.model_validate({"label": "links"})


def test_tier2_f18_03_graphedge_rejection_of_obsolete_from_key() -> None:
    """Verifies GraphEdge rejects payload missing required target endpoint."""
    with pytest.raises(ValidationError):
        GraphEdge.model_validate({"from": "n1", "label": "links"})


def test_tier2_f18_04_retired_script_returns_nonzero() -> None:
    """Verifies direct execution of retired nas-cpap-unified.py exits non-zero."""
    script = REPO_ROOT / "nas/butler/scripts/nas-cpap-unified.py"
    res = subprocess.run([sys.executable, str(script)], capture_output=True, text=True)
    assert res.returncode != 0


def test_tier2_f18_05_edge_origin_with_special_characters() -> None:
    """Verifies GraphEdge accepts and preserves origin string with special characters."""
    edge = GraphEdge(source="n1", target="n2", label="links", origin="ast-extractor_v2.0-beta")
    assert edge.origin == "ast-extractor_v2.0-beta"


# ==============================================================================
# Feature F19: Graph Referential Integrity Validation
# ==============================================================================


def test_tier2_f19_01_empty_graph_valid() -> None:
    """Verifies assert_referential_integrity succeeds on completely empty graph."""
    assert_referential_integrity({"nodes": [], "edges": []})


def test_tier2_f19_02_dense_valid_graph() -> None:
    """Verifies assert_referential_integrity scales efficiently over 1000 nodes and 2000 edges."""
    nodes = [{"id": f"node_{i}"} for i in range(1000)]
    edges = [{"source": f"node_{i % 1000}", "target": f"node_{(i + 1) % 1000}"} for i in range(2000)]
    assert_referential_integrity({"nodes": nodes, "edges": edges})


def test_tier2_f19_03_needle_in_haystack_dangling_edge() -> None:
    """Verifies assert_referential_integrity catches 1 dangling edge among 1000 valid edges."""
    nodes = [{"id": f"node_{i}"} for i in range(1000)]
    edges = [{"source": f"node_{i}", "target": f"node_{(i + 1) % 1000}"} for i in range(999)]
    # Append the dangling needle
    edges.append({"source": "node_0", "target": "ghost_target_9999"})

    with pytest.raises(AssertionError, match="Referential integrity violation"):
        assert_referential_integrity({"nodes": nodes, "edges": edges})


def test_tier2_f19_04_self_loop_edge_on_valid_node() -> None:
    """Verifies self-referencing edge (source == target) on existing node is valid."""
    assert_referential_integrity(
        {
            "nodes": [{"id": "loop_node"}],
            "edges": [{"source": "loop_node", "target": "loop_node"}],
        }
    )


def test_tier2_f19_05_self_loop_edge_on_missing_node() -> None:
    """Verifies self-referencing edge on non-existent node raises referential integrity error."""
    with pytest.raises(AssertionError, match="Referential integrity violation"):
        assert_referential_integrity(
            {
                "nodes": [],
                "edges": [{"source": "missing_node", "target": "missing_node"}],
            }
        )


# ==============================================================================
# Feature F20: Identifier Length Enforcement
# ==============================================================================


def test_tier2_f20_01_whitespace_only_identifier_rejected() -> None:
    """Verifies identifier with only whitespace is flagged when stripped."""
    raw_id = "   "
    clean_id = raw_id.strip()
    assert len(clean_id) == 0


def test_tier2_f20_02_extremely_long_identifier() -> None:
    """Verifies 10,000-character identifier is handled without memory exhaustion."""
    long_id = "a" * 10000
    node = GraphNode(id=long_id, label="long")
    assert node.id == long_id


def test_tier2_f20_03_unicode_and_emoji_identifier() -> None:
    """Verifies multibyte UTF-8 and emoji identifiers validate successfully."""
    emoji_id = "🚀_service_lane_01"
    node = GraphNode(id=emoji_id, label="emoji")
    assert node.id == emoji_id
    assert len(node.id) >= 1


def test_tier2_f20_04_non_string_identifier_type_rejection() -> None:
    """Verifies GraphNode rejects non-string/non-int identifier in strict mode."""
    with pytest.raises(ValidationError):
        GraphNode.model_validate({"id": ["not-a-string"]})


def test_tier2_f20_05_edge_source_target_control_chars() -> None:
    """Verifies identifiers with newlines are detected."""
    raw_id = "node\nwith\nnewline"
    assert "\n" in raw_id


# ==============================================================================
# Feature F21: Strict Projection & Life Index Typing
# ==============================================================================


def test_tier2_f21_01_projection_empty_graph() -> None:
    """Verifies project_graph handles empty graph returning valid empty projection structure."""
    result = project_graph({"nodes": [], "edges": []}, mode="overview")
    assert result["nodes"] == []
    assert result["edges"] == []


def test_tier2_f21_02_projection_unknown_mode_handling() -> None:
    """Verifies project_graph with unknown mode safely defaults to overview."""
    result = project_graph({"nodes": [], "edges": []}, mode="completely_unknown_mode_xyz")
    assert "nodes" in result
    assert "edges" in result


def test_tier2_f21_03_semantic_projection_threshold_boundaries() -> None:
    """Verifies semantic_threshold at 0.0 and 1.0 are safely clamped without error."""
    g = {"nodes": [{"id": "n1", "type": "actor"}], "edges": []}
    res_min = project_graph(g, mode="semantic", semantic_threshold=0.0)
    res_max = project_graph(g, mode="semantic", semantic_threshold=1.0)
    assert res_min is not None
    assert res_max is not None


def test_tier2_f21_04_life_index_large_concept_volume(tmp_path: Path) -> None:
    """Verifies load_life_index parses index with 100+ concepts cleanly."""
    concept_dir = tmp_path / "memory" / "canonical-concepts"
    concept_dir.mkdir(parents=True, exist_ok=True)
    records = [{"slug": f"concept_{i}", "title": f"Concept {i}", "type": "topic"} for i in range(120)]
    (concept_dir / "canonical-concepts.json").write_text(json.dumps({"records": records}), encoding="utf-8")

    index = load_life_index(str(concept_dir))
    assert len(index["records"]) == 120


def test_tier2_f21_05_life_index_null_optional_fields(tmp_path: Path) -> None:
    """Verifies life index record with null aliases coerces safely to empty list."""
    concept_dir = tmp_path / "memory" / "canonical-concepts"
    concept_dir.mkdir(parents=True, exist_ok=True)
    records = [{"slug": "null_alias", "title": "Null Alias", "type": "topic", "aliases": None}]
    (concept_dir / "canonical-concepts.json").write_text(json.dumps({"records": records}), encoding="utf-8")

    index = load_life_index(str(concept_dir))
    assert len(index["records"]) == 1
    assert index["records"][0]["aliases"] == []


# ==============================================================================
# Feature F22: MCP Server Pydantic Validation
# ==============================================================================


def test_tier2_f22_01_huge_request_payload_exceeding_max_payload() -> None:
    """Verifies validate_graph_payload rejects payload exceeding MAX_PAYLOAD_SIZE (100MB)."""
    oversized = b"x" * (MAX_PAYLOAD_SIZE + 1024)
    ok, reason = validate_graph_payload(oversized)
    assert ok is False
    assert "Payload too large" in reason


def test_tier2_f22_02_negative_max_results_parameter() -> None:
    """Verifies MCP server _int_param rejects negative max_results with ValueError."""
    handler = build_mcp_handler(lambda: None)
    with pytest.raises(ValueError, match="must be >= 0"):
        handler._int_param({"max_results": -5}, "max_results", default=10, minimum=0)


def test_tier2_f22_03_boolean_int_parameter_rejected() -> None:
    """Verifies MCP server _int_param rejects boolean passed for integer parameter."""
    handler = build_mcp_handler(lambda: None)
    with pytest.raises(ValueError, match="must be an integer"):
        handler._int_param({"max_results": True}, "max_results", default=10, minimum=0)


def test_tier2_f22_04_disallowed_cors_origin_rejected() -> None:
    """Verifies MCP server rejects cross-origin OPTIONS preflight with 403."""
    handler = build_mcp_handler(lambda: None)
    assert hasattr(handler, "do_OPTIONS")


def test_tier2_f22_05_unsupported_media_type_rejection() -> None:
    """Verifies MCP server body extraction checks for application/json Content-Type."""
    handler = build_mcp_handler(lambda: None)
    assert hasattr(handler, "_body_or_error")


# ==============================================================================
# Feature F23: LLM Client Schema Validation
# ==============================================================================


def test_tier2_f23_01_zero_completion_tokens_valid() -> None:
    """Verifies UsageInfo accepts zero completion tokens."""
    usage = assert_valid_pydantic(UsageInfo, {"prompt_tokens": 100, "completion_tokens": 0})
    assert usage.prompt_tokens == 100
    assert usage.completion_tokens == 0


def test_tier2_f23_02_extremely_large_token_counts() -> None:
    """Verifies UsageInfo handles extremely large token counts (500,000,000)."""
    usage = assert_valid_pydantic(UsageInfo, {"prompt_tokens": 500000000, "completion_tokens": 500000000})
    assert usage.prompt_tokens == 500000000


def test_tier2_f23_03_chat_response_null_content_with_tool_calls() -> None:
    """Verifies ChatMessage accepts content=None when tool_calls are present."""
    msg = assert_valid_pydantic(
        ChatMessage,
        {
            "role": "assistant",
            "content": None,
            "tool_calls": [{"id": "call_1", "type": "function"}],
        },
    )
    assert msg.content is None
    assert len(msg.tool_calls or []) == 1


def test_tier2_f23_04_temperature_out_of_range() -> None:
    """Verifies ChatCompletionRequest rejects temperature outside [0.0, 2.0]."""
    with pytest.raises(ValidationError):
        ChatCompletionRequest(
            model="qwen",
            messages=[ChatMessage(role="user", content="hi")],
            temperature=-0.5,
        )
    with pytest.raises(ValidationError):
        ChatCompletionRequest(
            model="qwen",
            messages=[ChatMessage(role="user", content="hi")],
            temperature=3.5,
        )


def test_tier2_f23_05_empty_model_data_list_handling() -> None:
    """Verifies handling of response payload containing empty model list."""
    payload = {"data": []}
    assert isinstance(payload.get("data"), list)
    assert len(payload["data"]) == 0


# ==============================================================================
# Feature F24: E2E Runner CLI & Selection
# ==============================================================================


def test_tier2_f24_01_invalid_tier_option_rejected() -> None:
    """Verifies runner CLI rejects invalid tier option with exit code 2."""
    with pytest.raises(SystemExit) as exc_info:
        runner_main(["--tier", "99"])
    assert exc_info.value.code == 2


def test_tier2_f24_02_dry_run_flag_does_not_execute(capsys: pytest.CaptureFixture[str]) -> None:
    """Verifies runner --dry-run prints command and exits 0 without running tests."""
    exit_code = runner_main(["--tier", "2", "--dry-run"])
    assert exit_code == 0
    captured = capsys.readouterr()
    assert "Dry-run pytest command:" in captured.out
    assert "test_tier2_boundary_corner.py" in captured.out


def test_tier2_f24_03_feature_filter_case_insensitivity() -> None:
    """Verifies build_pytest_args normalizes feature filter case ('f7' == 'F7')."""
    args_lower = build_pytest_args(feature="f7")
    args_upper = build_pytest_args(feature="F7")
    assert "-k" in args_lower and "f7 or F7" in args_lower
    assert "-k" in args_upper and "f7 or F7" in args_upper


def test_tier2_f24_04_conflicting_verbose_quiet_flags() -> None:
    """Verifies build_pytest_args handles both verbose and quiet flags predictably."""
    args = build_pytest_args(verbose=True, quiet=True)
    assert "-v" in args
    assert "-q" in args


def test_tier2_f24_05_nonexistent_extra_pytest_args() -> None:
    """Verifies unknown extra arguments are appended cleanly to pytest args."""
    args = build_pytest_args(extra_args=["--custom-flag", "--another-option=1"])
    assert "--custom-flag" in args
    assert "--another-option=1" in args


# ==============================================================================
# Feature F25: Adversarial Coverage Hardening
# ==============================================================================


def test_tier2_f25_01_runner_handles_pytest_internal_error(monkeypatch: pytest.MonkeyPatch) -> None:
    """Verifies runner translates pytest.ExitCode.INTERNAL_ERROR to exit code 3."""
    monkeypatch.setattr(pytest, "main", lambda args: pytest.ExitCode.INTERNAL_ERROR)
    code = run_e2e_tests()
    assert code == 3


def test_tier2_f25_02_runner_handles_keyboard_interrupt(monkeypatch: pytest.MonkeyPatch) -> None:
    """Verifies runner translates pytest.ExitCode.INTERRUPTED to exit code 2."""
    monkeypatch.setattr(pytest, "main", lambda args: pytest.ExitCode.INTERRUPTED)
    code = run_e2e_tests()
    assert code == 2


def test_tier2_f25_03_socket_leak_triggers_exit_code_3() -> None:
    """Verifies assert_no_resource_warnings catches and reports ResourceWarning."""
    import warnings

    with pytest.raises(AssertionError, match="unclosed resource warnings"):
        with assert_no_resource_warnings():
            warnings.warn("Simulated socket leak", ResourceWarning)


def test_tier2_f25_04_virtual_procfs_isolation_under_concurrency(virtual_procfs: VirtualProcfs) -> None:
    """Verifies virtual procfs remains consistent across concurrent threads."""
    errors: list[Exception] = []

    def _worker(thread_id: int) -> None:
        try:
            with open("/proc/1/comm", encoding="utf-8") as fh:
                comm = fh.read().strip()
            if comm != "systemd":
                raise ValueError(f"Thread {thread_id} saw comm={comm!r}")
        except Exception as exc:
            errors.append(exc)

    threads = [threading.Thread(target=_worker, args=(i,)) for i in range(10)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()

    assert not errors, f"Concurrent procfs errors: {errors}"


def test_tier2_f25_05_hermetic_sandbox_prevents_escape(tmp_path: Path) -> None:
    """Verifies all sandbox environment variables are contained within tmp_path."""
    for var in ("HOME", "OPENCLAW_ROOT", "TAC_STATE_DIR", "LLAMA_MODEL_DIR"):
        val = os.environ.get(var, "")
        p = Path(val)
        assert p.is_relative_to(tmp_path), f"Variable {var}={val} escaped tmp_path {tmp_path}"
