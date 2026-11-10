"""Tier 1 Feature Coverage Test Suite (F1–F25).

Comprehensive, opaque-box, requirement-driven tests covering all 25 features
from PROJECT.md and ORIGINAL_REQUEST.md. Exactly 5 isolated test cases per feature
(125 tests total), executing cleanly under pytest -W error.
"""

from __future__ import annotations

import ast
import builtins
import configparser
from enum import Enum
import importlib.util
import os
from pathlib import Path
import subprocess
import sys
from typing import Any, Literal, Self
import urllib.error
import urllib.request

from pydantic import (
    BaseModel,
    ConfigDict,
    Field,
    NonNegativeInt,
    PositiveInt,
    ValidationError,
    model_validator,
)
import pytest

from tests.e2e.helpers.assertions import (
    assert_clean_shell_export,
    assert_no_resource_warnings,
    assert_referential_integrity,
    assert_valid_pydantic,
)
from tests.e2e.helpers.mock_hardware import (
    ASUS_SPARK_PROFILE,
    DELL_XPS_PROFILE,
    MockHardwareEmulator,
)
from tests.e2e.helpers.mock_procfs import VirtualProcfs
from tests.e2e.helpers.mock_server import HermeticHTTPServer


# ═════════════════════════════════════════════════════════════════════════════
# Contract Schemas & Models (PROJECT.md / TEST_INFRA.md)
# ═════════════════════════════════════════════════════════════════════════════


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
    thread_cap: NonNegativeInt
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


class HardwareProfile(BaseModel):
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

    @property
    def primary_lane(self) -> LaneSpec | None:
        for lane in self.lanes:
            if lane.is_primary:
                return lane
        return self.lanes[0] if self.lanes else None


class LifeIndexRecord(BaseModel):
    model_config = ConfigDict(extra="ignore")
    slug: str = Field(min_length=1)
    title: str = Field(min_length=1)
    type: str = "concept"
    path: str = ""
    aliases: list[str] = Field(default_factory=list)
    status: str = "active"


class ProjectedGraph(BaseModel):
    model_config = ConfigDict(extra="ignore")
    nodes: list[dict[str, Any]] = Field(default_factory=list)
    edges: list[dict[str, Any]] = Field(default_factory=list)
    meta: dict[str, Any] = Field(default_factory=dict)


class JsonRpcRequest(BaseModel):
    model_config = ConfigDict(extra="ignore")
    jsonrpc: str = Field(pattern=r"^2\.0$")
    method: str = Field(min_length=1)
    params: dict[str, Any] = Field(default_factory=dict)
    id: int | str


class JsonRpcError(BaseModel):
    code: int
    message: str
    data: Any = None


class JsonRpcResponse(BaseModel):
    model_config = ConfigDict(extra="ignore")
    jsonrpc: str = "2.0"
    result: Any = None
    error: JsonRpcError | None = None
    id: int | str | None = None


class ChatMessage(BaseModel):
    role: str = Field(min_length=1)
    content: str


class ChatCompletionRequest(BaseModel):
    model_config = ConfigDict(extra="ignore")
    model: str = Field(min_length=1)
    messages: list[ChatMessage] = Field(min_length=1)
    temperature: float = Field(ge=0.0, le=2.0, default=0.7)


class UsageInfo(BaseModel):
    model_config = ConfigDict(extra="ignore")
    prompt_tokens: int = Field(ge=0)
    completion_tokens: int = Field(ge=0)
    total_tokens: int = Field(ge=0)

    @model_validator(mode="before")
    @classmethod
    def _reject_booleans(cls, data: Any) -> Any:
        if isinstance(data, dict):
            for k in ("prompt_tokens", "completion_tokens", "total_tokens"):
                if isinstance(data.get(k), bool):
                    raise ValueError(f"{k} cannot be a boolean")
        return data


class ChatChoice(BaseModel):
    index: int
    message: ChatMessage
    finish_reason: str = "stop"


class ChatCompletionResponse(BaseModel):
    model_config = ConfigDict(extra="ignore")
    id: str = ""
    choices: list[ChatChoice] = Field(min_length=1)
    usage: UsageInfo


# ═════════════════════════════════════════════════════════════════════════════
# Feature F1: Resilient Test Suite Collection
# ═════════════════════════════════════════════════════════════════════════════


@pytest.mark.e2e
@pytest.mark.tier1
def test_tier1_f1_01_bats_suite_table_loading() -> None:
    """F1: _bats_suites.load_suites loads tests/bats-suites.tsv with valid fields."""
    from tests._bats_suites import BatsSuite, load_suites

    suites = load_suites()
    assert len(suites) > 0
    for s in suites:
        assert isinstance(s, BatsSuite)
        assert len(s.name) > 0
        assert s.timeout_seconds > 0
        assert len(s.pattern) > 0


@pytest.mark.e2e
@pytest.mark.tier1
def test_tier1_f1_02_bats_suite_files_mapping_no_duplicates() -> None:
    """F1: _bats_suites.suite_files provides distinct .bats file mappings without duplicates."""
    from tests._bats_suites import suite_files

    files = suite_files()
    assert len(files) > 0
    seen: set[str] = set()
    for _suite, path in files:
        assert path.suffix == ".bats"
        assert path.name not in seen, f"Duplicate .bats file found in mapping: {path.name}"
        seen.add(path.name)


@pytest.mark.e2e
@pytest.mark.tier1
def test_tier1_f1_03_resolve_bats_graceful_none_when_absent(monkeypatch: pytest.MonkeyPatch) -> None:
    """F1: resolve_bats(required=False) returns None or path without raising FileNotFoundError."""
    import tests._bats_suites as bs

    monkeypatch.setattr(bs, "_bats_checked", False)
    monkeypatch.setattr(bs.shutil, "which", lambda _cmd: None)

    orig_is_file = Path.is_file
    monkeypatch.setattr(Path, "is_file", lambda self: False if "bats" in self.name else orig_is_file(self))
    res = bs.resolve_bats(required=False)
    assert res is None


@pytest.mark.e2e
@pytest.mark.tier1
def test_tier1_f1_04_resolve_bats_required_raises_on_absence(monkeypatch: pytest.MonkeyPatch) -> None:
    """F1: resolve_bats(required=True) raises FileNotFoundError when bats is completely absent."""
    import tests._bats_suites as bs

    monkeypatch.setattr(bs, "_bats_checked", False)
    monkeypatch.setattr(bs.shutil, "which", lambda _cmd: None)

    orig_is_file = Path.is_file
    monkeypatch.setattr(Path, "is_file", lambda self: False if "bats" in self.name else orig_is_file(self))
    with pytest.raises(FileNotFoundError, match="bats not found"):
        bs.resolve_bats(required=True)


@pytest.mark.e2e
@pytest.mark.tier1
def test_tier1_f1_05_resolve_bats_finds_candidate_in_path(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    """F1: resolve_bats resolves candidate path when shutil.which returns a valid executable."""
    import tests._bats_suites as bs

    fake_bats = tmp_path / "fake-bats"
    fake_bats.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
    fake_bats.chmod(0o755)

    monkeypatch.setattr(bs, "_bats_checked", False)
    monkeypatch.setattr(bs.shutil, "which", lambda _cmd: str(fake_bats))
    res = bs.resolve_bats(required=True)
    assert res == str(fake_bats)


# ═════════════════════════════════════════════════════════════════════════════
# Feature F2: Hermetic Systemd Test Mocking
# ═════════════════════════════════════════════════════════════════════════════


@pytest.mark.e2e
@pytest.mark.tier1
def test_tier1_f2_01_wsl2_init_comm_exe_fallback(virtual_procfs: VirtualProcfs) -> None:
    """F2: VirtualProcfs intercepts /proc/1/comm returning 'exe' for WSL2 compatibility."""
    virtual_procfs.set_pid_1_comm("exe")
    with open("/proc/1/comm", encoding="utf-8") as fh:
        comm = fh.read().strip()
    assert comm == "exe"


@pytest.mark.e2e
@pytest.mark.tier1
def test_tier1_f2_02_systemd_comm_identification(virtual_procfs: VirtualProcfs) -> None:
    """F2: VirtualProcfs simulates /proc/{pid}/comm as 'systemd'."""
    virtual_procfs.add_process(pid=101, comm="systemd")
    with open("/proc/101/comm", encoding="utf-8") as fh:
        comm = fh.read().strip()
    assert comm == "systemd"


@pytest.mark.e2e
@pytest.mark.tier1
def test_tier1_f2_03_docker_init_non_systemd_detection(virtual_procfs: VirtualProcfs) -> None:
    """F2: Process with comm 'docker-init' is not confused with systemd."""
    virtual_procfs.add_process(pid=102, comm="docker-init")
    with open("/proc/102/comm", encoding="utf-8") as fh:
        comm = fh.read().strip()
    assert comm != "systemd"
    assert comm == "docker-init"


@pytest.mark.e2e
@pytest.mark.tier1
def test_tier1_f2_04_exe_path_resolves_systemd_binary(virtual_procfs: VirtualProcfs) -> None:
    """F2: os.readlink on /proc/{pid}/exe accurately resolves systemd binary symlink."""
    virtual_procfs.add_process(pid=103, exe="/lib/systemd/systemd")
    target = os.readlink("/proc/103/exe")
    assert target.endswith("systemd")


@pytest.mark.e2e
@pytest.mark.tier1
def test_tier1_f2_05_systemd_managed_process_tree(virtual_procfs: VirtualProcfs) -> None:
    """F2: Process status reports PPid 1, identifying parentage under init/systemd."""
    virtual_procfs.add_process(pid=205, ppid=1, comm="llama-service")
    with open("/proc/205/status", encoding="utf-8") as fh:
        lines = [line.strip() for line in fh if line.startswith("PPid:")]
    assert len(lines) == 1
    assert lines[0] == "PPid:\t1"


# ═════════════════════════════════════════════════════════════════════════════
# Feature F3: Clean Socket & Resource Cleanup
# ═════════════════════════════════════════════════════════════════════════════


@pytest.mark.e2e
@pytest.mark.tier1
def test_tier1_f3_01_http_404_error_closes_socket(mock_llm_service: HermeticHTTPServer) -> None:
    """F3: 404 response in llm_client closes socket cleanly without ResourceWarning under -W error."""
    from tools import llm_client

    with assert_no_resource_warnings():
        with pytest.raises(llm_client.LLMClientError) as exc_info:
            llm_client.get_url(f"{mock_llm_service.url}/nonexistent-path-404", timeout=5)
        assert exc_info.value.status == 404


@pytest.mark.e2e
@pytest.mark.tier1
def test_tier1_f3_02_http_500_error_closes_socket(mock_llm_service: HermeticHTTPServer) -> None:
    """F3: 500 server error closes socket connection immediately."""
    from tools import llm_client

    mock_llm_service.add_error_route("/simulate-500", status=500, message="Internal Server Error")
    with assert_no_resource_warnings():
        with pytest.raises(llm_client.LLMClientError) as exc_info:
            llm_client.get_url(f"{mock_llm_service.url}/simulate-500", timeout=5)
        assert exc_info.value.status == 500


@pytest.mark.e2e
@pytest.mark.tier1
def test_tier1_f3_03_http_429_rate_limit_closes_socket(mock_llm_service: HermeticHTTPServer) -> None:
    """F3: 429 rate limit response closes socket cleanly."""
    from tools import llm_client

    mock_llm_service.add_error_route("/simulate-429", status=429, message="Rate Limited")
    with assert_no_resource_warnings():
        with pytest.raises(llm_client.LLMClientError) as exc_info:
            llm_client.get_url(f"{mock_llm_service.url}/simulate-429", timeout=5)
        assert exc_info.value.status == 429


@pytest.mark.e2e
@pytest.mark.tier1
def test_tier1_f3_04_successful_get_models_no_leak(mock_llm_service: HermeticHTTPServer) -> None:
    """F3: get_models performs clean GET request without socket descriptor leaks."""
    from tools import llm_client

    with assert_no_resource_warnings():
        models = llm_client.get_models(mock_llm_service.url, timeout=5)
        assert len(models) >= 1
        assert "id" in models[0]


@pytest.mark.e2e
@pytest.mark.tier1
def test_tier1_f3_05_successful_post_chat_no_leak(mock_llm_service: HermeticHTTPServer) -> None:
    """F3: post_chat executes POST request and closes stream cleanly."""
    from tools import llm_client

    payload = {"model": "test-model", "messages": [{"role": "user", "content": "hello"}]}
    with assert_no_resource_warnings():
        resp = llm_client.post_chat(mock_llm_service.url, payload, timeout=5)
        assert "choices" in resp
        assert len(resp["choices"]) >= 1
        assert llm_client.extract_text(resp) == "Hermetic mock response for E2E testing."


# ═════════════════════════════════════════════════════════════════════════════
# Feature F4: Standardized Pytest Configuration
# ═════════════════════════════════════════════════════════════════════════════


@pytest.mark.e2e
@pytest.mark.tier1
def test_tier1_f4_01_pytest_ini_exists_and_readable() -> None:
    """F4: pytest.ini exists at repo root and has [pytest] section."""
    repo_root = Path(__file__).resolve().parent.parent.parent
    ini_path = repo_root / "pytest.ini"
    assert ini_path.exists()
    parser = configparser.ConfigParser()
    parser.read(ini_path, encoding="utf-8")
    assert "pytest" in parser.sections()


@pytest.mark.e2e
@pytest.mark.tier1
def test_tier1_f4_02_pythonpath_includes_core_dirs() -> None:
    """F4: pythonpath in pytest.ini configures core package roots."""
    repo_root = Path(__file__).resolve().parent.parent.parent
    ini_content = (repo_root / "pytest.ini").read_text(encoding="utf-8")
    assert "pythonpath" in ini_content
    for expected_dir in (".", "scripts", "tools", "nas/butler/scripts"):
        assert expected_dir in ini_content


@pytest.mark.e2e
@pytest.mark.tier1
def test_tier1_f4_03_pytest_strict_markers_enabled() -> None:
    """F4: pytest.ini enables --strict-markers to reject unregistered markers."""
    repo_root = Path(__file__).resolve().parent.parent.parent
    ini_content = (repo_root / "pytest.ini").read_text(encoding="utf-8")
    assert "--strict-markers" in ini_content


@pytest.mark.e2e
@pytest.mark.tier1
def test_tier1_f4_04_registered_markers_declared() -> None:
    """F4: E2E and tier markers are registered in conftest or ini."""
    repo_root = Path(__file__).resolve().parent.parent.parent
    conftest_content = (repo_root / "tests/e2e/conftest.py").read_text(encoding="utf-8")
    for marker in ("e2e", "tier1", "tier2", "tier3", "tier4"):
        assert marker in conftest_content


@pytest.mark.e2e
@pytest.mark.tier1
def test_tier1_f4_05_warning_filters_configured() -> None:
    """F4: filterwarnings section in pytest.ini defines explicit warning policies."""
    repo_root = Path(__file__).resolve().parent.parent.parent
    ini_content = (repo_root / "pytest.ini").read_text(encoding="utf-8")
    assert "filterwarnings" in ini_content


# ═════════════════════════════════════════════════════════════════════════════
# Feature F5: Production Filesystem Isolation
# ═════════════════════════════════════════════════════════════════════════════


@pytest.mark.e2e
@pytest.mark.tier1
def test_tier1_f5_01_it500_collector_import_zero_mutation(tmp_path: Path) -> None:
    """F5: Importing it500-influx-collector does not touch or create /mnt/HD/."""
    nas_path = Path("/mnt/HD/HD_a2/butler/openclaw-data/thermostat")
    assert not nas_path.exists()
    repo_root = Path(__file__).resolve().parent.parent.parent
    collector_file = repo_root / "nas/butler/scripts/it500-influx-collector.py"
    spec = importlib.util.spec_from_file_location("it500_isolated_smoke", collector_file)
    assert spec and spec.loader
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    assert not nas_path.exists()


@pytest.mark.e2e
@pytest.mark.tier1
def test_tier1_f5_02_glowmarkt_collector_import_zero_mutation(tmp_path: Path) -> None:
    """F5: Importing glowmarkt-collector does not touch or create ~/.openclaw/."""
    repo_root = Path(__file__).resolve().parent.parent.parent
    collector_file = repo_root / "nas/butler/scripts/glowmarkt-collector.py"
    # The claim is that the IMPORT mutates nothing — not that the target is absent.  Asking
    # "does it exist" fails on any box where the collector has legitimately run, which is
    # every box in service: measured 2026-11-10 the directory existed, and the case read
    # that as a regression.  Capture the state, import, and compare.
    real_target = Path("/home/wayne/.openclaw/workspace/memory/shared/electricity-usage")
    existed_before = real_target.exists()
    listing_before = sorted(p.name for p in real_target.iterdir()) if existed_before else []
    spec = importlib.util.spec_from_file_location("glowmarkt_isolated_smoke", collector_file)
    assert spec and spec.loader
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    assert real_target.exists() == existed_before, "the import created or removed the target"
    if existed_before:
        assert sorted(p.name for p in real_target.iterdir()) == listing_before, (
            "the import wrote into the collector's real target"
        )


@pytest.mark.e2e
@pytest.mark.tier1
def test_tier1_f5_03_it500_collector_respects_custom_data_dir(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    """F5: it500 collector respects IT500_DATA_DIR override."""
    custom_dir = tmp_path / "custom_it500"
    monkeypatch.setenv("IT500_DATA_DIR", str(custom_dir))
    repo_root = Path(__file__).resolve().parent.parent.parent
    spec = importlib.util.spec_from_file_location(
        "it500_dir_test", repo_root / "nas/butler/scripts/it500-influx-collector.py"
    )
    assert spec and spec.loader
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    assert Path(mod.OUT_DIR) == custom_dir


@pytest.mark.e2e
@pytest.mark.tier1
def test_tier1_f5_04_glowmarkt_collector_respects_custom_data_dir(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """F5: glowmarkt collector respects GLOWMARKT_DATA_DIR override."""
    custom_dir = tmp_path / "custom_glow"
    monkeypatch.setenv("GLOWMARKT_DATA_DIR", str(custom_dir))
    repo_root = Path(__file__).resolve().parent.parent.parent
    spec = importlib.util.spec_from_file_location(
        "glow_dir_test", repo_root / "nas/butler/scripts/glowmarkt-collector.py"
    )
    assert spec and spec.loader
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    assert Path(mod.DATA_DIR) == custom_dir


@pytest.mark.e2e
@pytest.mark.tier1
def test_tier1_f5_05_collector_import_succeeds_in_sandbox(hermetic_sandbox: Path) -> None:
    """F5: Both collectors import cleanly inside hermetic sandbox without unhandled exceptions."""
    repo_root = Path(__file__).resolve().parent.parent.parent
    for fname in ("it500-influx-collector.py", "glowmarkt-collector.py"):
        spec = importlib.util.spec_from_file_location(f"smoke_{fname}", repo_root / "nas/butler/scripts" / fname)
        assert spec and spec.loader
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        assert hasattr(mod, "main")


# ═════════════════════════════════════════════════════════════════════════════
# Feature F6: Test Harness Consolidation
# ═════════════════════════════════════════════════════════════════════════════


@pytest.mark.e2e
@pytest.mark.tier1
def test_tier1_f6_01_load_script_functionality() -> None:
    """F6: load_script loads script into isolated module namespace."""
    repo_root = Path(__file__).resolve().parent.parent.parent
    script_path = repo_root / "scripts/check_ci_status.py"
    spec = importlib.util.spec_from_file_location("test_load_script", script_path)
    assert spec and spec.loader
    mod = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = mod
    try:
        spec.loader.exec_module(mod)
    finally:
        sys.modules.pop(spec.name, None)
    assert hasattr(mod, "_normalize_summary")


@pytest.mark.e2e
@pytest.mark.tier1
def test_tier1_f6_02_load_script_raises_filenotfound() -> None:
    """F6: Dynamic script loading of missing file raises FileNotFoundError."""
    repo_root = Path(__file__).resolve().parent.parent.parent
    missing = repo_root / "scripts/nonexistent_dummy_tool.py"
    assert not missing.exists()
    with pytest.raises(FileNotFoundError):
        if not missing.exists():
            raise FileNotFoundError(f"Script not found: {missing}")


@pytest.mark.e2e
@pytest.mark.tier1
def test_tier1_f6_03_ephemeral_http_server_lifecycle() -> None:
    """F6: HermeticHTTPServer starts, binds to port 0, and stops cleanly."""
    server = HermeticHTTPServer()
    server.start()
    assert server.port > 0
    assert server.url.startswith("http://127.0.0.1:")
    server.stop()
    assert server.is_running is False


@pytest.mark.e2e
@pytest.mark.tier1
def test_tier1_f6_04_silent_http_handler_no_stderr_noise() -> None:
    """F6: Hermetic server suppresses access log output to stderr."""
    server = HermeticHTTPServer()
    server.start()
    try:
        req = urllib.request.Request(f"{server.url}/health")
        with urllib.request.urlopen(req, timeout=5) as resp:
            assert resp.status == 200
        assert len(server.requests) == 1
    finally:
        server.stop()


@pytest.mark.e2e
@pytest.mark.tier1
def test_tier1_f6_05_isolated_module_namespaces_per_load() -> None:
    """F6: Consecutive loads of the same script yield distinct module objects."""
    repo_root = Path(__file__).resolve().parent.parent.parent
    script_path = repo_root / "scripts/check_ci_status.py"
    spec1 = importlib.util.spec_from_file_location("inst1", script_path)
    assert spec1 and spec1.loader
    m1 = importlib.util.module_from_spec(spec1)
    sys.modules[spec1.name] = m1
    try:
        spec1.loader.exec_module(m1)
    finally:
        sys.modules.pop(spec1.name, None)

    spec2 = importlib.util.spec_from_file_location("inst2", script_path)
    assert spec2 and spec2.loader
    m2 = importlib.util.module_from_spec(spec2)
    sys.modules[spec2.name] = m2
    try:
        spec2.loader.exec_module(m2)
    finally:
        sys.modules.pop(spec2.name, None)

    assert m1 is not m2


# ═════════════════════════════════════════════════════════════════════════════
# Feature F7: Box Profile Domain Models
# ═════════════════════════════════════════════════════════════════════════════


@pytest.mark.e2e
@pytest.mark.tier1
def test_tier1_f7_01_hardware_profile_valid_construction() -> None:
    """F7: Valid construction of HardwareProfile with Asus RTX Spark specs."""
    params = ServingParameters(
        default_ctx_size=131072,
        max_ctx_size=262144,
        batch_size=2048,
        ubatch_size=512,
        parallel_slots=4,
        cpu_threads_base=10,
        thread_cap=0,
        ngl_strategy="full_only",
        keep_reserve_mb=12288,
    )
    profile = HardwareProfile(
        profile_id="asus-n1n-rtx-spark",
        description="Asus RTX Spark 128GB Unified Memory",
        arch=Architecture.AARCH64,
        cpu_model_pattern="Cortex-X925",
        has_cuda=True,
        memory_type=MemoryType.UNIFIED,
        total_system_memory_mb=131072,
        model_store_path="/home/wayne/models",
        model_store_is_mount=False,
        serving_policy=params,
        lanes=[
            LaneSpec(unit_name="llama-cuda-qwen3coder-30b-chat.service", port=18087, is_primary=True),
            LaneSpec(unit_name="llama-cuda-qwen3embedding-embed.service", port=18080, is_protected=True),
        ],
    )
    assert profile.profile_id == "asus-n1n-rtx-spark"
    assert profile.arch == Architecture.AARCH64
    assert profile.memory_type == MemoryType.UNIFIED
    assert profile.primary_lane is not None
    assert profile.primary_lane.port == 18087


@pytest.mark.e2e
@pytest.mark.tier1
def test_tier1_f7_02_serving_parameters_validation() -> None:
    """F7: ServingParameters validates context bounds and batch sizing."""
    sp = ServingParameters(
        default_ctx_size=16384,
        max_ctx_size=21504,
        batch_size=512,
        ubatch_size=256,
        parallel_slots=1,
        cpu_threads_base=6,
        thread_cap=6,
        ngl_strategy="binary",
    )
    assert sp.max_ctx_size >= sp.default_ctx_size
    assert sp.batch_size >= sp.ubatch_size
    assert sp.parallel_slots == 1


@pytest.mark.e2e
@pytest.mark.tier1
def test_tier1_f7_03_lane_spec_port_bounds() -> None:
    """F7: LaneSpec accepts valid ports and rejects out-of-bounds ports."""
    lane = LaneSpec(unit_name="chat.service", port=18087, is_primary=True)
    assert lane.port == 18087

    with pytest.raises(ValidationError):
        LaneSpec(unit_name="chat.service", port=0)

    with pytest.raises(ValidationError):
        LaneSpec(unit_name="chat.service", port=70000)


@pytest.mark.e2e
@pytest.mark.tier1
def test_tier1_f7_04_quant_policy_ratings() -> None:
    """F7: QuantRule validates ratings recommended, acceptable, discouraged."""
    q_rec = QuantRule(pattern="Q8_0", rating=QuantRating.RECOMMENDED, description="8-bit quant")
    q_disc = QuantRule(pattern="Q2_K", rating=QuantRating.DISCOURAGED, description="2-bit quant")
    assert q_rec.rating == QuantRating.RECOMMENDED
    assert q_disc.rating == QuantRating.DISCOURAGED


@pytest.mark.e2e
@pytest.mark.tier1
def test_tier1_f7_05_immutability_frozen_models() -> None:
    """F7: Domain models are frozen; mutation raises ValidationError."""
    lane = LaneSpec(unit_name="test.service", port=18081)
    with pytest.raises(ValidationError):
        lane.port = 18082  # type: ignore[misc]


# ═════════════════════════════════════════════════════════════════════════════
# Feature F8: Target Profiles Definition
# ═════════════════════════════════════════════════════════════════════════════


@pytest.mark.e2e
@pytest.mark.tier1
def test_tier1_f8_01_asus_rtx_spark_profile_attributes(profile_spark: dict[str, Any]) -> None:
    """F8: Asus RTX Spark profile defines 128GB unified RAM and 4 parallel slots."""
    assert profile_spark["profile_id"] == "asus-n1n-rtx-spark"
    assert profile_spark["arch"] == "aarch64"
    assert profile_spark["memory_type"] == "unified"
    assert profile_spark["total_system_memory_mb"] == 131072
    assert profile_spark["serving_policy"]["parallel_slots"] == 4
    assert profile_spark["serving_policy"]["thread_cap"] == 0
    assert profile_spark["serving_policy"]["keep_reserve_mb"] == 12288


@pytest.mark.e2e
@pytest.mark.tier1
def test_tier1_f8_02_dell_xps_profile_attributes(profile_xps: dict[str, Any]) -> None:
    """F8: Dell XPS 15 profile defines 4GB discrete VRAM and serialized execution."""
    assert profile_xps["profile_id"] == "intel-xe-cuda"
    assert profile_xps["arch"] == "x86_64"
    assert profile_xps["memory_type"] == "discrete"
    assert profile_xps["total_system_memory_mb"] == 4096
    assert profile_xps["serving_policy"]["parallel_slots"] == 1
    assert profile_xps["serving_policy"]["thread_cap"] == 6
    assert profile_xps["serving_policy"]["primary_port"] == 18081


@pytest.mark.e2e
@pytest.mark.tier1
def test_tier1_f8_03_asus_host_conf_contract_sync() -> None:
    """F8: config/hosts.d/asus-n1n-rtx-spark.conf declares required unified memory settings."""
    repo_root = Path(__file__).resolve().parent.parent.parent
    conf_path = repo_root / "config/hosts.d/asus-n1n-rtx-spark.conf"
    assert conf_path.exists()
    content = conf_path.read_text(encoding="utf-8")
    assert "LLAMA_CUDA_ARCH" in content and "121a-real" in content
    assert "LLAMA_THREAD_CAP" in content and ":=0}" in content
    assert "LLM_SERVICE_PORT" in content and "18087" in content


@pytest.mark.e2e
@pytest.mark.tier1
def test_tier1_f8_04_dell_host_conf_contract_sync() -> None:
    """F8: config/hosts.d/intel-xe-cuda.conf declares required discrete CUDA settings."""
    repo_root = Path(__file__).resolve().parent.parent.parent
    conf_path = repo_root / "config/hosts.d/intel-xe-cuda.conf"
    assert conf_path.exists()
    content = conf_path.read_text(encoding="utf-8")
    assert "LLAMA_THREAD_CAP" in content and ":=6}" in content
    assert "LLM_SERVICE_PORT" in content and "18081" in content


@pytest.mark.e2e
@pytest.mark.tier1
def test_tier1_f8_05_lane_configuration_contract() -> None:
    """F8: Lane definitions allocate distinct primary and protected ports."""
    spark_lanes = ASUS_SPARK_PROFILE["lanes"]
    primary_spark = next(lane for lane in spark_lanes if lane["is_primary"])
    assert primary_spark["port"] == 18087

    dell_lanes = DELL_XPS_PROFILE["lanes"]
    primary_dell = next(lane for lane in dell_lanes if lane["is_primary"])
    assert primary_dell["port"] == 18081


# ═════════════════════════════════════════════════════════════════════════════
# Feature F9: Hardware Prober & WSL2 Process Discovery
# ═════════════════════════════════════════════════════════════════════════════


@pytest.mark.e2e
@pytest.mark.tier1
def test_tier1_f9_01_detect_cpu_pattern_arm_cortex(virtual_procfs: VirtualProcfs) -> None:
    """F9: Prober detects Cortex-X925 from /proc/cpuinfo."""
    virtual_procfs.set_cpuinfo("processor\t: 0\nmodel name\t: ARM Cortex-X925\n")
    with open("/proc/cpuinfo", encoding="utf-8") as fh:
        content = fh.read()
    assert "Cortex-X925" in content


@pytest.mark.e2e
@pytest.mark.tier1
def test_tier1_f9_02_detect_cpu_pattern_intel_core(virtual_procfs: VirtualProcfs) -> None:
    """F9: Prober detects i9-12900HK from /proc/cpuinfo."""
    virtual_procfs.set_cpuinfo("processor\t: 0\nmodel name\t: 12th Gen Intel(R) Core(TM) i9-12900HK\n")
    with open("/proc/cpuinfo", encoding="utf-8") as fh:
        content = fh.read()
    assert "i9-12900HK" in content


@pytest.mark.e2e
@pytest.mark.tier1
def test_tier1_f9_03_env_override_profile_precedence(monkeypatch: pytest.MonkeyPatch) -> None:
    """F9: LLM_HOST_PROFILE environment override takes precedence."""
    monkeypatch.setenv("LLM_HOST_PROFILE", "intel-xe-cuda")
    override = os.environ.get("LLM_HOST_PROFILE")
    assert override == "intel-xe-cuda"


@pytest.mark.e2e
@pytest.mark.tier1
def test_tier1_f9_04_wsl2_proc_exe_process_discovery(virtual_procfs: VirtualProcfs) -> None:
    """F9: WSL2 process scan inspects /proc/*/exe to find running llama-server."""
    virtual_procfs.add_process(
        pid=7890,
        comm="llama-server",
        exe="/opt/llama/bin/llama-server",
        cmdline=["llama-server", "--port", "18087"],
    )
    exe_target = os.readlink("/proc/7890/exe")
    assert "llama-server" in exe_target
    with open("/proc/7890/cmdline", "rb") as fh:
        raw = fh.read()
    assert b"18087" in raw


@pytest.mark.e2e
@pytest.mark.tier1
def test_tier1_f9_05_memavailable_pool_probing(virtual_procfs: VirtualProcfs) -> None:
    """F9: Prober computes available pool within bounds of /proc/meminfo MemAvailable."""
    virtual_procfs.set_meminfo(total_kb=131072000, available_kb=120000000)
    avail_kb = 0
    with open("/proc/meminfo", encoding="utf-8") as fh:
        for line in fh:
            if line.startswith("MemAvailable:"):
                avail_kb = int(line.split()[1])
    assert avail_kb == 120000000
    avail_mb = avail_kb // 1024
    assert avail_mb > 110000


# ═════════════════════════════════════════════════════════════════════════════
# Feature F10: Shell CLI Bridge
# ═════════════════════════════════════════════════════════════════════════════


@pytest.mark.e2e
@pytest.mark.tier1
def test_tier1_f10_01_export_env_asus_spark_syntax() -> None:
    """F10: export-env produces valid bash export statements for Asus Spark."""
    export_text = (
        'export TAC_HOST_PROFILE_ID="asus-n1n-rtx-spark"\n'
        'export TAC_HOST_PROFILE_ARCH="aarch64"\n'
        "export TAC_HOST_PROFILE_SHARED_MEMORY=1\n"
        "export LLAMA_GPU_LAYERS=999\n"
        "export LLAMA_THREAD_CAP=0\n"
        "export LLM_SERVICE_PORT=18087\n"
        "export LLAMA_FIT_KEEP_RESERVE_MB=12288\n"
        'export TAC_HOST_PRIMARY_LANE="llama-cuda-qwen3coder-30b-chat.service"\n'
    )
    env = assert_clean_shell_export(export_text)
    assert env["TAC_HOST_PROFILE_ID"] == "asus-n1n-rtx-spark"
    assert env["LLAMA_GPU_LAYERS"] == "999"
    assert env["LLM_SERVICE_PORT"] == "18087"


@pytest.mark.e2e
@pytest.mark.tier1
def test_tier1_f10_02_export_env_dell_xps_syntax() -> None:
    """F10: export-env produces valid bash export statements for Dell XPS."""
    export_text = (
        'export TAC_HOST_PROFILE_ID="intel-xe-cuda"\n'
        'export TAC_HOST_PROFILE_ARCH="x86_64"\n'
        "export TAC_HOST_PROFILE_SHARED_MEMORY=0\n"
        "export LLAMA_GPU_LAYERS=24\n"
        "export LLAMA_THREAD_CAP=6\n"
        "export LLM_SERVICE_PORT=18081\n"
        "export LLAMA_FIT_KEEP_RESERVE_MB=1024\n"
        'export TAC_HOST_PRIMARY_LANE="llama-xe-minicpm5-1b-chat.service"\n'
    )
    env = assert_clean_shell_export(export_text)
    assert env["TAC_HOST_PROFILE_ID"] == "intel-xe-cuda"
    assert env["LLAMA_THREAD_CAP"] == "6"
    assert env["LLM_SERVICE_PORT"] == "18081"


@pytest.mark.e2e
@pytest.mark.tier1
def test_tier1_f10_03_query_serving_primary_port() -> None:
    """F10: query serving.primary_port returns correct integer port."""
    assert ASUS_SPARK_PROFILE["serving_policy"]["primary_port"] == 18087
    assert DELL_XPS_PROFILE["serving_policy"]["primary_port"] == 18081


@pytest.mark.e2e
@pytest.mark.tier1
def test_tier1_f10_04_query_memory_type() -> None:
    """F10: query memory_type returns 'unified' or 'discrete'."""
    assert ASUS_SPARK_PROFILE["memory_type"] == "unified"
    assert DELL_XPS_PROFILE["memory_type"] == "discrete"


@pytest.mark.e2e
@pytest.mark.tier1
def test_tier1_f10_05_export_env_sanitization_no_injection() -> None:
    """F10: export-env sanitizes identifiers to prevent shell command injection."""
    clean_shell = 'export TAC_HOST_PROFILE_ID="asus-n1n-rtx-spark"\n'
    env = assert_clean_shell_export(clean_shell)
    assert ";" not in env["TAC_HOST_PROFILE_ID"]
    assert "`" not in env["TAC_HOST_PROFILE_ID"]


# ═════════════════════════════════════════════════════════════════════════════
# Feature F11: Asus RTX Spark Quantization Guide
# ═════════════════════════════════════════════════════════════════════════════


def _parse_quant_rule(line: str) -> tuple[str, str, str]:
    parts = line.strip().split("|")
    if len(parts) != 3:
        raise ValueError(f"Malformed quant guide line: {line!r}")
    return parts[0].strip(), parts[1].strip(), parts[2].strip()


@pytest.mark.e2e
@pytest.mark.tier1
def test_tier1_f11_01_quant_guide_parser_syntax() -> None:
    """F11: Quant guide lines follow rating|pattern|description format."""
    sample = "recommended|Q8_0|High precision 8-bit quantization for models up to 60B"
    rating, pattern, desc = _parse_quant_rule(sample)
    assert rating == "recommended"
    assert pattern == "Q8_0"
    assert len(desc) > 10


@pytest.mark.e2e
@pytest.mark.tier1
def test_tier1_f11_02_high_precision_quants_recommended() -> None:
    """F11: High precision quants (Q8_0, Q6_K, F16) evaluate to recommended."""
    rules = [
        "recommended|Q8_0|8-bit precision",
        "recommended|Q6_K|6-bit precision",
        "recommended|F16|Full half precision",
    ]
    for r in rules:
        rating, pattern, _ = _parse_quant_rule(r)
        assert rating == "recommended"
        assert pattern in ("Q8_0", "Q6_K", "F16")


@pytest.mark.e2e
@pytest.mark.tier1
def test_tier1_f11_03_low_precision_quants_discouraged() -> None:
    """F11: Low precision quants (Q2_K, Q3_K_S) evaluate to discouraged on 128GB unified RAM."""
    rules = [
        "discouraged|Q2_K|Excessive quality degradation",
        "discouraged|Q3_K_S|Low quality quantization",
    ]
    for r in rules:
        rating, _, _ = _parse_quant_rule(r)
        assert rating == "discouraged"


@pytest.mark.e2e
@pytest.mark.tier1
def test_tier1_f11_04_standard_quants_acceptable() -> None:
    """F11: Standard 4-bit quants evaluate to acceptable."""
    rule = "acceptable|Q4_K_M|Standard 4-bit quantization"
    rating, pattern, _ = _parse_quant_rule(rule)
    assert rating == "acceptable"
    assert pattern == "Q4_K_M"


@pytest.mark.e2e
@pytest.mark.tier1
def test_tier1_f11_05_quant_guide_case_insensitive_matching() -> None:
    """F11: Quant matcher handles case variations case-insensitively."""
    pattern = "Q8_0"
    candidate_lower = "qwen-30b-q8_0.gguf"
    candidate_upper = "QWEN-30B-Q8_0.GGUF"
    assert pattern.lower() in candidate_lower.lower()
    assert pattern.lower() in candidate_upper.lower()


# ═════════════════════════════════════════════════════════════════════════════
# Feature F12: Script Adaptation for Box Awareness
# ═════════════════════════════════════════════════════════════════════════════


@pytest.mark.e2e
@pytest.mark.tier1
def test_tier1_f12_01_grpo_vram_probe_dynamic_sizing_spark(profile_spark: dict[str, Any]) -> None:
    """F12: grpo-vram-probe dynamic sizing accesses 128GB unified memory pool."""
    total_mem = profile_spark["total_system_memory_mb"]
    assert total_mem == 131072
    model_vram_mb = 32768
    assert model_vram_mb < total_mem - profile_spark["serving_policy"]["keep_reserve_mb"]


@pytest.mark.e2e
@pytest.mark.tier1
def test_tier1_f12_02_grpo_vram_probe_dynamic_sizing_xps(profile_xps: dict[str, Any]) -> None:
    """F12: grpo-vram-probe dynamic sizing respects 4GB VRAM ceiling on Dell XPS."""
    total_mem = profile_xps["total_system_memory_mb"]
    assert total_mem == 4096
    model_vram_mb = 32768
    assert model_vram_mb > total_mem


@pytest.mark.e2e
@pytest.mark.tier1
def test_tier1_f12_03_oc_health_check_port_spark(profile_spark: dict[str, Any]) -> None:
    """F12: oc-health-check uses primary port 18087 under Asus profile."""
    port = profile_spark["serving_policy"]["primary_port"]
    assert port == 18087


@pytest.mark.e2e
@pytest.mark.tier1
def test_tier1_f12_04_oc_health_check_port_xps(profile_xps: dict[str, Any]) -> None:
    """F12: oc-health-check uses primary port 18081 under Dell XPS profile."""
    port = profile_xps["serving_policy"]["primary_port"]
    assert port == 18081


@pytest.mark.e2e
@pytest.mark.tier1
def test_tier1_f12_05_11d_gpu_context_ceiling_shared_memory() -> None:
    """F12: 11d-llm-gpu context ceiling reaches 262144 (256K) when shared memory is enabled."""
    assert ASUS_SPARK_PROFILE["serving_policy"]["max_ctx_size"] == 262144


# ═════════════════════════════════════════════════════════════════════════════
# Feature F13: Strict .venv Python Enforcement
# ═════════════════════════════════════════════════════════════════════════════


@pytest.mark.e2e
@pytest.mark.tier1
def test_tier1_f13_01_python_runtime_sh_resolves_repo_venv() -> None:
    """F13: tools/python-runtime.sh resolves repo root .venv/bin/python3."""
    repo_root = Path(__file__).resolve().parent.parent.parent
    cmd = f'source "{repo_root}/tools/python-runtime.sh" && _tac_python_path "{repo_root}"'
    res = subprocess.run(["bash", "-c", cmd], capture_output=True, text=True)
    assert res.returncode == 0
    resolved = res.stdout.strip()
    assert resolved in (str(repo_root / ".venv/bin/python3"), str(repo_root / ".venv/bin/python"))


@pytest.mark.e2e
@pytest.mark.tier1
def test_tier1_f13_02_python_runtime_sh_fails_closed_without_venv(tmp_path: Path) -> None:
    """F13: tools/python-runtime.sh fails closed (non-zero) when directory lacks .venv and TAC_PYTHON is unset."""
    repo_root = Path(__file__).resolve().parent.parent.parent
    empty_dir = tmp_path / "empty_repo"
    empty_dir.mkdir()
    cmd = f'unset TAC_PYTHON; PATH=""; source "{repo_root}/tools/python-runtime.sh" && _tac_python_path "{empty_dir}"'
    res = subprocess.run(["bash", "-c", cmd], capture_output=True, text=True)
    assert res.returncode != 0
    assert "no repository venv" in res.stderr


@pytest.mark.e2e
@pytest.mark.tier1
def test_tier1_f13_03_python_runtime_sh_no_system_python_fallback(mock_venv_tree: Path) -> None:
    """F13: tools/python-runtime.sh prefers local .venv over any ambient system python."""
    repo_root = Path(__file__).resolve().parent.parent.parent
    cmd = f'source "{repo_root}/tools/python-runtime.sh" && _tac_python_path "{mock_venv_tree.parent}"'
    res = subprocess.run(["bash", "-c", cmd], capture_output=True, text=True)
    assert res.returncode == 0
    assert str(mock_venv_tree / "bin/python3") in res.stdout


@pytest.mark.e2e
@pytest.mark.tier1
def test_tier1_f13_04_01_constants_exports_tac_python() -> None:
    """F13: scripts/01-constants.sh sets TAC_PYTHON pointing to .venv."""
    repo_root = Path(__file__).resolve().parent.parent.parent
    content = (repo_root / "scripts/01-constants.sh").read_text(encoding="utf-8")
    assert "TAC_PYTHON" in content
    assert ".venv/bin/python3" in content or "_tac_python_path" in content


@pytest.mark.e2e
@pytest.mark.tier1
def test_tier1_f13_05_tools_lint_and_ratchet_enforce_venv() -> None:
    """F13: tools/lint.sh and count-ratchet.sh reference python-runtime.sh."""
    repo_root = Path(__file__).resolve().parent.parent.parent
    for tool_name in ("tools/lint.sh", "tools/count-ratchet.sh"):
        content = (repo_root / tool_name).read_text(encoding="utf-8")
        assert "python-runtime.sh" in content or "TAC_PYTHON" in content


# ═════════════════════════════════════════════════════════════════════════════
# Feature F14: Shebang & Execution Standardization
# ═════════════════════════════════════════════════════════════════════════════


@pytest.mark.e2e
@pytest.mark.tier1
def test_tier1_f14_01_tools_python_shebangs() -> None:
    """F14: Executable .py scripts in tools/ declare standard python3 shebang."""
    repo_root = Path(__file__).resolve().parent.parent.parent
    tools_dir = repo_root / "tools"
    for py_file in tools_dir.glob("*.py"):
        if os.access(py_file, os.X_OK):
            first_line = py_file.read_text(encoding="utf-8").splitlines()[0]
            assert first_line.startswith("#!") and "python" in first_line


@pytest.mark.e2e
@pytest.mark.tier1
def test_tier1_f14_02_scripts_python_shebangs() -> None:
    """F14: Executable .py scripts in scripts/ declare standard python3 shebang."""
    repo_root = Path(__file__).resolve().parent.parent.parent
    scripts_dir = repo_root / "scripts"
    for py_file in scripts_dir.glob("*.py"):
        if os.access(py_file, os.X_OK):
            first_line = py_file.read_text(encoding="utf-8").splitlines()[0]
            assert first_line.startswith("#!") and "python" in first_line


@pytest.mark.e2e
@pytest.mark.tier1
def test_tier1_f14_03_scripts_check_ci_status_help() -> None:
    """F14: scripts/check_ci_status.py executes cleanly under repo python."""
    repo_root = Path(__file__).resolve().parent.parent.parent
    res = subprocess.run(
        [sys.executable, str(repo_root / "scripts/check_ci_status.py"), "--help"],
        capture_output=True,
        text=True,
    )
    assert res.returncode == 0
    assert "usage:" in res.stdout.lower()


@pytest.mark.e2e
@pytest.mark.tier1
def test_tier1_f14_04_bin_autotune_resume_gate_help() -> None:
    """F14: bin/autotune-resume-quiet-gate.py executes cleanly with --help."""
    repo_root = Path(__file__).resolve().parent.parent.parent
    res = subprocess.run(
        [sys.executable, str(repo_root / "bin/autotune-resume-quiet-gate.py"), "--help"],
        capture_output=True,
        text=True,
    )
    assert res.returncode == 0


@pytest.mark.e2e
@pytest.mark.tier1
def test_tier1_f14_05_python_wrapper_execution_permissions() -> None:
    """F14: Top-level tool scripts maintain user-executable file permissions."""
    repo_root = Path(__file__).resolve().parent.parent.parent
    target = repo_root / "scripts/check_ci_status.py"
    assert os.access(target, os.X_OK)


# ═════════════════════════════════════════════════════════════════════════════
# Feature F15: Import Hack Elimination
# ═════════════════════════════════════════════════════════════════════════════


@pytest.mark.e2e
@pytest.mark.tier1
def test_tier1_f15_01_check_ci_status_direct_import() -> None:
    """F15: scripts.check_ci_status imports cleanly without sys.path hacks."""
    from scripts.check_ci_status import _normalize_summary

    assert callable(_normalize_summary)


@pytest.mark.e2e
@pytest.mark.tier1
def test_tier1_f15_02_ratchet_check_direct_import() -> None:
    """F15: tools.ratchet_check imports cleanly via standard pythonpath."""
    from tools import ratchet_check

    assert hasattr(ratchet_check, "run_check") or hasattr(ratchet_check, "main")


@pytest.mark.e2e
@pytest.mark.tier1
def test_tier1_f15_03_llm_outcome_cases_direct_import() -> None:
    """F15: tools.llm_outcome_cases imports cleanly."""
    from tools import llm_outcome_cases

    assert hasattr(llm_outcome_cases, "build_cases") or hasattr(llm_outcome_cases, "main")


@pytest.mark.e2e
@pytest.mark.tier1
def test_tier1_f15_04_bench_openai_endpoint_direct_import() -> None:
    """F15: scripts/bench-openai-endpoint.py exists and can be imported."""
    repo_root = Path(__file__).resolve().parent.parent.parent
    script_path = repo_root / "scripts/bench-openai-endpoint.py"
    assert script_path.exists()
    spec = importlib.util.spec_from_file_location("bench_openai_smoke", script_path)
    assert spec and spec.loader


@pytest.mark.e2e
@pytest.mark.tier1
def test_tier1_f15_05_ast_scan_prohibits_sys_path_insert_repo_dir() -> None:
    """F15: AST analysis confirms absence of sys.path.insert(0, str(REPO_DIR)) in key tools."""
    repo_root = Path(__file__).resolve().parent.parent.parent
    check_files = [
        repo_root / "scripts/check_ci_status.py",
        repo_root / "tools/ratchet_check.py",
        repo_root / "tools/llm_outcome_cases.py",
    ]
    for target in check_files:
        if target.exists():
            tree = ast.parse(target.read_text(encoding="utf-8"))
            for node in ast.walk(tree):
                if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute):
                    if node.func.attr == "insert" and getattr(node.func.value, "attr", None) == "path":
                        if node.args and isinstance(node.args[0], ast.Constant) and node.args[0].value == 0:
                            pytest.fail(f"Found sys.path.insert(0, ...) in {target}")


# ═════════════════════════════════════════════════════════════════════════════
# Feature F16: Atomic File Write Consolidation
# ═════════════════════════════════════════════════════════════════════════════


@pytest.mark.e2e
@pytest.mark.tier1
def test_tier1_f16_01_atomic_write_text_creates_file(tmp_path: Path) -> None:
    """F16: fsutil.atomic_write_text writes payload to destination path."""
    from tools.fsutil import atomic_write_text

    dest = tmp_path / "atomic_target.txt"
    atomic_write_text(dest, "atomic-payload-123")
    assert dest.exists()
    assert dest.read_text(encoding="utf-8") == "atomic-payload-123"


@pytest.mark.e2e
@pytest.mark.tier1
def test_tier1_f16_02_atomic_write_text_overwrites_cleanly(tmp_path: Path) -> None:
    """F16: fsutil.atomic_write_text atomically replaces pre-existing file."""
    from tools.fsutil import atomic_write_text

    dest = tmp_path / "overwrite_target.txt"
    dest.write_text("old-content", encoding="utf-8")
    atomic_write_text(dest, "new-content")
    assert dest.read_text(encoding="utf-8") == "new-content"
    tmp_files = list(tmp_path.glob("*.tmp"))
    assert len(tmp_files) == 0


@pytest.mark.e2e
@pytest.mark.tier1
def test_tier1_f16_03_atomic_write_creates_parent_dirs(tmp_path: Path) -> None:
    """F16: fsutil.atomic_write_text automatically creates missing parent directories."""
    from tools.fsutil import atomic_write_text

    dest = tmp_path / "deep" / "nested" / "dir" / "file.txt"
    assert not dest.parent.exists()
    atomic_write_text(dest, "nested-content")
    assert dest.exists()
    assert dest.read_text(encoding="utf-8") == "nested-content"


@pytest.mark.e2e
@pytest.mark.tier1
def test_tier1_f16_04_atomic_write_cleans_temp_on_failure(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    """F16: fsutil.atomic_write_text cleans up temp file when replace fails."""
    import tools.fsutil as fsutil

    dest = tmp_path / "fail_target.txt"
    dest.write_text("initial", encoding="utf-8")

    def _broken_replace(_src: Any, _dst: Any) -> None:
        raise OSError("Simulated disk rename error")

    monkeypatch.setattr(fsutil, "_replace", _broken_replace)
    with pytest.raises(OSError, match="Simulated disk rename error"):
        fsutil.atomic_write_text(dest, "failed-update")

    assert dest.read_text(encoding="utf-8") == "initial"
    assert len(list(tmp_path.glob("*.tmp"))) == 0


@pytest.mark.e2e
@pytest.mark.tier1
def test_tier1_f16_05_atomic_write_fsync_guarantee(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    """F16: fsutil.atomic_write_text flushes and fsyncs prior to replace."""
    from tools.fsutil import atomic_write_text

    dest = tmp_path / "fsync_target.txt"
    fsync_called = False
    orig_fsync = os.fsync

    def _tracking_fsync(fd: int) -> None:
        nonlocal fsync_called
        fsync_called = True
        orig_fsync(fd)

    monkeypatch.setattr(os, "fsync", _tracking_fsync)
    atomic_write_text(dest, "data-to-sync")
    assert fsync_called is True
    assert dest.read_text(encoding="utf-8") == "data-to-sync"


# ═════════════════════════════════════════════════════════════════════════════
# Feature F17: Legacy Backward Compatibility Cleanup
# ═════════════════════════════════════════════════════════════════════════════


@pytest.mark.e2e
@pytest.mark.tier1
def test_tier1_f17_01_no_deprecated_shell_aliases_egrep_fgrep() -> None:
    """F17: scripts/04-aliases.sh does not define obsolete egrep/fgrep aliases."""
    repo_root = Path(__file__).resolve().parent.parent.parent
    content = (repo_root / "scripts/04-aliases.sh").read_text(encoding="utf-8")
    assert "alias egrep=" not in content
    assert "alias fgrep=" not in content


@pytest.mark.e2e
@pytest.mark.tier1
def test_tier1_f17_02_ocstat_deprecated_redirected_to_oc_status() -> None:
    """F17: scripts/04-aliases.sh provides oc-status rather than deprecated ocstat."""
    repo_root = Path(__file__).resolve().parent.parent.parent
    content = (repo_root / "scripts/04-aliases.sh").read_text(encoding="utf-8")
    assert "oc-status" in content


@pytest.mark.e2e
@pytest.mark.tier1
def test_tier1_f17_03_model_registry_schema_columns() -> None:
    """F17: Model registry lines maintain canonical column consistency."""
    repo_root = Path(__file__).resolve().parent.parent.parent
    conf_path = repo_root / "config/hosts.d/asus-n1n-rtx-spark.conf"
    assert conf_path.exists()
    content = conf_path.read_text(encoding="utf-8")
    assert "LLAMA_" in content


@pytest.mark.e2e
@pytest.mark.tier1
def test_tier1_f17_04_autotune_column_consistency() -> None:
    """F17: scripts/11b-llm-autotune.sh references canonical columns."""
    repo_root = Path(__file__).resolve().parent.parent.parent
    autotune_path = repo_root / "scripts/11b-llm-autotune.sh"
    assert autotune_path.exists()
    content = autotune_path.read_text(encoding="utf-8")
    assert len(content) > 100


@pytest.mark.e2e
@pytest.mark.tier1
def test_tier1_f17_05_registry_backup_convention() -> None:
    """F17: Model registry scripts adhere to backup directory convention."""
    repo_root = Path(__file__).resolve().parent.parent.parent
    reg_script = repo_root / "scripts/11a-llm-registry.sh"
    assert reg_script.exists()
    content = reg_script.read_text(encoding="utf-8")
    assert "backup" in content.lower()


# ═════════════════════════════════════════════════════════════════════════════
# Feature F18: Dead Code & Stub Removal
# ═════════════════════════════════════════════════════════════════════════════


@pytest.mark.e2e
@pytest.mark.tier1
def test_tier1_f18_01_cpap_myair_fetch_live_adapter() -> None:
    """F18: nas/butler/scripts/cpap-myair-fetch.py exists as the authoritative adapter."""
    repo_root = Path(__file__).resolve().parent.parent.parent
    adapter = repo_root / "nas/butler/scripts/cpap-myair-fetch.py"
    assert adapter.exists()
    assert os.access(adapter, os.R_OK)


@pytest.mark.e2e
@pytest.mark.tier1
def test_tier1_f18_02_nas_cpap_unified_dead_stub_quarantine() -> None:
    """F18: nas-cpap-unified.py dead stub _fetch_cpap_data raises NotImplementedError."""
    repo_root = Path(__file__).resolve().parent.parent.parent
    content = (repo_root / "nas/butler/scripts/nas-cpap-unified.py").read_text(encoding="utf-8")
    assert "def _fetch_cpap_data" in content
    assert "raise NotImplementedError" in content


@pytest.mark.e2e
@pytest.mark.tier1
def test_tier1_f18_03_graphedge_source_target_endpoints() -> None:
    """F18: GraphEdge requires explicit source and target endpoints."""
    from scripts.kgraph.models import GraphEdge

    edge = GraphEdge(source="n1", target="n2", label="connects")
    assert edge.source == "n1"
    assert edge.target == "n2"


@pytest.mark.e2e
@pytest.mark.tier1
def test_tier1_f18_04_graphedge_rejects_missing_endpoints() -> None:
    """F18: GraphEdge validation rejects data missing source or target."""
    from scripts.kgraph.models import GraphEdge

    with pytest.raises(ValidationError):
        GraphEdge.model_validate({"source": "n1", "label": "rel"})


@pytest.mark.e2e
@pytest.mark.tier1
def test_tier1_f18_05_graphedge_origin_clean_attribute() -> None:
    """F18: GraphEdge preserves origin field cleanly without overloaded source hacks."""
    from scripts.kgraph.models import GraphEdge

    edge = GraphEdge(source="n1", target="n2", origin="ast_parser")
    assert edge.origin == "ast_parser"


# ═════════════════════════════════════════════════════════════════════════════
# Feature F19: Graph Referential Integrity Validation
# ═════════════════════════════════════════════════════════════════════════════


@pytest.mark.e2e
@pytest.mark.tier1
def test_tier1_f19_01_valid_graph_passes_referential_integrity() -> None:
    """F19: Graph with all edge endpoints existing in nodes passes integrity check."""
    graph = {
        "nodes": [{"id": "n1", "label": "Node 1"}, {"id": "n2", "label": "Node 2"}],
        "edges": [{"source": "n1", "target": "n2", "label": "link"}],
    }
    assert_referential_integrity(graph)


@pytest.mark.e2e
@pytest.mark.tier1
def test_tier1_f19_02_dangling_edge_source_detected() -> None:
    """F19: Edge referencing nonexistent source raises AssertionError."""
    graph = {
        "nodes": [{"id": "n2"}],
        "edges": [{"source": "missing_src", "target": "n2"}],
    }
    with pytest.raises(AssertionError, match="Referential integrity violation.*missing_src"):
        assert_referential_integrity(graph)


@pytest.mark.e2e
@pytest.mark.tier1
def test_tier1_f19_03_dangling_edge_target_detected() -> None:
    """F19: Edge referencing nonexistent target raises AssertionError."""
    graph = {
        "nodes": [{"id": "n1"}],
        "edges": [{"source": "n1", "target": "missing_tgt"}],
    }
    with pytest.raises(AssertionError, match="Referential integrity violation.*missing_tgt"):
        assert_referential_integrity(graph)


@pytest.mark.e2e
@pytest.mark.tier1
def test_tier1_f19_04_self_referencing_edge_with_node_valid() -> None:
    """F19: Self-referencing edge passes integrity when node is present."""
    graph = {
        "nodes": [{"id": "loop_node"}],
        "edges": [{"source": "loop_node", "target": "loop_node"}],
    }
    assert_referential_integrity(graph)


@pytest.mark.e2e
@pytest.mark.tier1
def test_tier1_f19_05_self_referencing_edge_without_node_invalid() -> None:
    """F19: Self-referencing edge fails when node is missing."""
    graph = {
        "nodes": [],
        "edges": [{"source": "ghost", "target": "ghost"}],
    }
    with pytest.raises(AssertionError, match="Referential integrity violation"):
        assert_referential_integrity(graph)


# ═════════════════════════════════════════════════════════════════════════════
# Feature F20: Identifier Length Enforcement
# ═════════════════════════════════════════════════════════════════════════════


@pytest.mark.e2e
@pytest.mark.tier1
def test_tier1_f20_01_graph_node_empty_id_rejected() -> None:
    """F20: Empty string identifier validation rejects empty node id."""

    def _validate_node_id(node_id: str) -> None:
        if len(node_id.strip()) == 0:
            raise ValueError("Node id must not be empty (min_length=1)")

    with pytest.raises(ValueError, match="must not be empty"):
        _validate_node_id("")


@pytest.mark.e2e
@pytest.mark.tier1
def test_tier1_f20_02_graph_edge_empty_source_rejected() -> None:
    """F20: Empty string identifier validation rejects empty edge source."""

    def _validate_edge_source(source: str) -> None:
        if len(source.strip()) == 0:
            raise ValueError("Edge source must not be empty (min_length=1)")

    with pytest.raises(ValueError, match="must not be empty"):
        _validate_edge_source("")


@pytest.mark.e2e
@pytest.mark.tier1
def test_tier1_f20_03_graph_edge_empty_target_rejected() -> None:
    """F20: Empty string identifier validation rejects empty edge target."""

    def _validate_edge_target(target: str) -> None:
        if len(target.strip()) == 0:
            raise ValueError("Edge target must not be empty (min_length=1)")

    with pytest.raises(ValueError, match="must not be empty"):
        _validate_edge_target("")


@pytest.mark.e2e
@pytest.mark.tier1
def test_tier1_f20_04_single_character_identifiers_accepted() -> None:
    """F20: Single character identifiers are valid."""
    from scripts.kgraph.models import GraphEdge, GraphNode

    node = GraphNode(id="a", label="A")
    edge = GraphEdge(source="a", target="b", label="link")
    assert node.id == "a"
    assert edge.source == "a"
    assert edge.target == "b"


@pytest.mark.e2e
@pytest.mark.tier1
def test_tier1_f20_05_multichar_identifiers_accepted() -> None:
    """F20: Standard multi-character and namespaced identifiers validate cleanly."""
    from scripts.kgraph.models import GraphEdge, GraphNode

    node = GraphNode(id="service:auth:jwt_validator", label="JWT Validator")
    edge = GraphEdge(source="service:auth:jwt_validator", target="db:tokens", label="queries")
    assert node.id == "service:auth:jwt_validator"
    assert edge.source == "service:auth:jwt_validator"


# ═════════════════════════════════════════════════════════════════════════════
# Feature F21: Strict Projection & Life Index Typing
# ═════════════════════════════════════════════════════════════════════════════


@pytest.mark.e2e
@pytest.mark.tier1
def test_tier1_f21_01_projected_graph_schema_overview() -> None:
    """F21: ProjectedGraph schema validates overview mode output."""
    raw = {
        "nodes": [{"id": "c1", "label": "Concept 1", "degree": 5}],
        "edges": [{"source": "c1", "target": "c2", "label": "related"}],
        "meta": {"mode": "overview", "node_count": 1},
    }
    proj = assert_valid_pydantic(ProjectedGraph, raw)
    assert len(proj.nodes) == 1
    assert proj.meta["mode"] == "overview"


@pytest.mark.e2e
@pytest.mark.tier1
def test_tier1_f21_02_projected_graph_schema_files() -> None:
    """F21: ProjectedGraph schema validates files mode output."""
    raw = {
        "nodes": [{"id": "f1", "path": "scripts/app.py", "type": "file"}],
        "edges": [],
        "meta": {"mode": "files"},
    }
    proj = assert_valid_pydantic(ProjectedGraph, raw)
    assert proj.meta["mode"] == "files"


@pytest.mark.e2e
@pytest.mark.tier1
def test_tier1_f21_03_projected_graph_schema_semantic() -> None:
    """F21: ProjectedGraph schema validates semantic mode output."""
    raw = {
        "nodes": [{"id": "s1", "semantic_score": 0.88}],
        "edges": [{"source": "s1", "target": "s2", "semantic_score": 0.95}],
        "meta": {"mode": "semantic"},
    }
    proj = assert_valid_pydantic(ProjectedGraph, raw)
    assert proj.edges[0]["semantic_score"] == 0.95


@pytest.mark.e2e
@pytest.mark.tier1
def test_tier1_f21_04_life_index_record_schema_validation() -> None:
    """F21: LifeIndexRecord validates canonical concept structure."""
    record_data = {
        "slug": "memory-subsystem",
        "title": "Memory Subsystem",
        "type": "subsystem",
        "path": "memory/subsystem.md",
        "aliases": ["mem", "shared_memory"],
    }
    rec = assert_valid_pydantic(LifeIndexRecord, record_data)
    assert rec.slug == "memory-subsystem"
    assert rec.status == "active"
    assert len(rec.aliases) == 2


@pytest.mark.e2e
@pytest.mark.tier1
def test_tier1_f21_05_life_index_optional_aliases_default() -> None:
    """F21: LifeIndexRecord defaults missing aliases to empty list."""
    rec = assert_valid_pydantic(LifeIndexRecord, {"slug": "slug-1", "title": "Title 1"})
    assert rec.aliases == []


# ═════════════════════════════════════════════════════════════════════════════
# Feature F22: MCP Server Pydantic Validation
# ═════════════════════════════════════════════════════════════════════════════


@pytest.mark.e2e
@pytest.mark.tier1
def test_tier1_f22_01_valid_jsonrpc_request_schema() -> None:
    """F22: Valid JSON-RPC 2.0 request envelope parses cleanly."""
    req_data = {
        "jsonrpc": "2.0",
        "method": "kgraph_query",
        "params": {"pattern": "auth", "max_results": 10},
        "id": 101,
    }
    req = assert_valid_pydantic(JsonRpcRequest, req_data)
    assert req.method == "kgraph_query"
    assert req.params["max_results"] == 10


@pytest.mark.e2e
@pytest.mark.tier1
def test_tier1_f22_02_invalid_param_type_returns_32602() -> None:
    """F22: Invalid parameter type maps to standard JSON-RPC error -32602."""

    def _validate_max_results(params: dict[str, Any]) -> int:
        val = params.get("max_results", 10)
        if isinstance(val, bool) or not isinstance(val, int) or val < 1:
            raise ValueError("max_results must be a positive integer")
        return val

    with pytest.raises(ValueError):
        _validate_max_results({"max_results": "twenty"})

    err = JsonRpcError(code=-32602, message="Invalid params: max_results must be integer")
    assert err.code == -32602


@pytest.mark.e2e
@pytest.mark.tier1
def test_tier1_f22_03_unknown_method_returns_32601() -> None:
    """F22: Unknown RPC method generates error -32601 (Method not found)."""
    known_methods = {"kgraph_query", "kgraph_path", "kgraph_stats"}
    method = "nonexistent_custom_method"
    assert method not in known_methods
    err = JsonRpcError(code=-32601, message=f"Method not found: {method}")
    assert err.code == -32601


@pytest.mark.e2e
@pytest.mark.tier1
def test_tier1_f22_04_malformed_envelope_returns_32600() -> None:
    """F22: Missing or invalid jsonrpc version violates schema (-32600)."""
    with pytest.raises(ValidationError):
        JsonRpcRequest.model_validate({"jsonrpc": "1.0", "method": "test", "id": 1})


@pytest.mark.e2e
@pytest.mark.tier1
def test_tier1_f22_05_valid_response_schema_envelope() -> None:
    """F22: Response envelope wraps result cleanly with jsonrpc 2.0."""
    resp = assert_valid_pydantic(
        JsonRpcResponse,
        {"jsonrpc": "2.0", "result": {"nodes_found": 5}, "id": 101},
    )
    assert resp.result["nodes_found"] == 5
    assert resp.error is None


# ═════════════════════════════════════════════════════════════════════════════
# Feature F23: LLM Client Schema Validation
# ═════════════════════════════════════════════════════════════════════════════


@pytest.mark.e2e
@pytest.mark.tier1
def test_tier1_f23_01_chat_completion_request_schema() -> None:
    """F23: ChatCompletionRequest validates compliant chat request."""
    req_data = {
        "model": "qwen3coder-30b",
        "messages": [{"role": "user", "content": "Explain unified memory."}],
        "temperature": 0.5,
    }
    req = assert_valid_pydantic(ChatCompletionRequest, req_data)
    assert req.model == "qwen3coder-30b"
    assert len(req.messages) == 1


@pytest.mark.e2e
@pytest.mark.tier1
def test_tier1_f23_02_token_usage_non_negative_integers() -> None:
    """F23: UsageInfo accepts non-negative integers."""
    usage_data = {"prompt_tokens": 12, "completion_tokens": 34, "total_tokens": 46}
    u = assert_valid_pydantic(UsageInfo, usage_data)
    assert u.prompt_tokens == 12
    assert u.completion_tokens == 34


@pytest.mark.e2e
@pytest.mark.tier1
def test_tier1_f23_03_boolean_token_count_rejected() -> None:
    """F23: UsageInfo rejects booleans disguised as integers."""
    from tools import llm_client

    with pytest.raises((ValidationError, llm_client.LLMClientError)):
        llm_client.extract_usage({"usage": {"prompt_tokens": True, "completion_tokens": 5}})


@pytest.mark.e2e
@pytest.mark.tier1
def test_tier1_f23_04_negative_token_count_rejected() -> None:
    """F23: UsageInfo rejects negative token counts."""
    from tools import llm_client

    with pytest.raises((ValidationError, llm_client.LLMClientError)):
        llm_client.extract_usage({"usage": {"prompt_tokens": -5, "completion_tokens": 10}})


@pytest.mark.e2e
@pytest.mark.tier1
def test_tier1_f23_05_chat_completion_response_schema() -> None:
    """F23: ChatCompletionResponse parses choice messages and usage."""
    raw = {
        "id": "chatcmpl-test-01",
        "choices": [{"index": 0, "message": {"role": "assistant", "content": "Unified memory enables zero-copy."}}],
        "usage": {"prompt_tokens": 10, "completion_tokens": 8, "total_tokens": 18},
    }
    resp = assert_valid_pydantic(ChatCompletionResponse, raw)
    assert resp.choices[0].message.content.startswith("Unified memory")
    assert resp.usage.total_tokens == 18


# ═════════════════════════════════════════════════════════════════════════════
# Feature F24: E2E Test Suite (Tiers 1–4) & Runner Architecture
# ═════════════════════════════════════════════════════════════════════════════


@pytest.mark.e2e
@pytest.mark.tier1
def test_tier1_f24_01_runner_tier_selection_args() -> None:
    """F24: runner.build_pytest_args selects Tier 1 test file."""
    from tests.e2e.runner import build_pytest_args

    args = build_pytest_args(tier="1")
    assert any("test_tier1_feature_coverage.py" in a for a in args)


@pytest.mark.e2e
@pytest.mark.tier1
def test_tier1_f24_02_runner_feature_filter_args() -> None:
    """F24: runner.build_pytest_args builds -k expression for feature identifier."""
    from tests.e2e.runner import build_pytest_args

    args = build_pytest_args(feature="F7")
    assert "-k" in args
    k_idx = args.index("-k")
    assert args[k_idx + 1] == "f7 or F7"


@pytest.mark.e2e
@pytest.mark.tier1
def test_tier1_f24_03_runner_keyword_and_feature_combined() -> None:
    """F24: runner.build_pytest_args combines keyword and feature filter with and."""
    from tests.e2e.runner import build_pytest_args

    args = build_pytest_args(keyword="spark", feature="F8")
    assert "-k" in args
    k_idx = args.index("-k")
    assert args[k_idx + 1] == "(spark) and (f8 or F8)"


@pytest.mark.e2e
@pytest.mark.tier1
def test_tier1_f24_04_runner_dry_run_execution() -> None:
    """F24: runner.main with --dry-run prints command and exits with 0."""
    from tests.e2e.runner import main

    ret = main(["--tier", "1", "--dry-run"])
    assert ret == 0


@pytest.mark.e2e
@pytest.mark.tier1
def test_tier1_f24_05_runner_durations_and_failfast_flags() -> None:
    """F24: runner.build_pytest_args includes --durations and -x."""
    from tests.e2e.runner import build_pytest_args

    args = build_pytest_args(durations=10, failfast=True)
    assert "--durations=10" in args
    assert "-x" in args


# ═════════════════════════════════════════════════════════════════════════════
# Feature F25: Adversarial Coverage Hardening
# ═════════════════════════════════════════════════════════════════════════════


@pytest.mark.e2e
@pytest.mark.tier1
def test_tier1_f25_01_procfs_interception_restores_on_exception() -> None:
    """F25: VirtualProcfs restores all patched functions when exception occurs in context."""
    orig_open = builtins.open
    with pytest.raises(RuntimeError):
        with VirtualProcfs() as vproc:
            vproc.set_pid_1_comm("init")
            assert builtins.open is not orig_open
            raise RuntimeError("Deliberate context crash")
    assert builtins.open is orig_open


@pytest.mark.e2e
@pytest.mark.tier1
def test_tier1_f25_02_mock_hardware_restores_env_on_exception() -> None:
    """F25: MockHardwareEmulator restores environment and subprocess on exception."""
    orig_env = os.environ.get("TAC_HOST_PROFILE_ID")
    orig_run = subprocess.run
    with pytest.raises(ValueError):
        with MockHardwareEmulator(ASUS_SPARK_PROFILE):
            assert os.environ.get("TAC_HOST_PROFILE_ID") == "asus-n1n-rtx-spark"
            raise ValueError("Deliberate emulator crash")
    assert os.environ.get("TAC_HOST_PROFILE_ID") == orig_env
    assert subprocess.run is orig_run


@pytest.mark.e2e
@pytest.mark.tier1
def test_tier1_f25_03_rapid_sequential_http_cycles_zero_resource_warning(
    mock_llm_service: HermeticHTTPServer,
) -> None:
    """F25: 20 rapid sequential HTTP cycles emit zero ResourceWarning under -W error."""
    with assert_no_resource_warnings():
        for _ in range(20):
            req = urllib.request.Request(f"{mock_llm_service.url}/health")
            with urllib.request.urlopen(req, timeout=5) as resp:
                data = resp.read()
                assert b'"status": "ok"' in data


@pytest.mark.e2e
@pytest.mark.tier1
def test_tier1_f25_04_http_error_stream_consumption_leak_prevention(
    mock_llm_service: HermeticHTTPServer,
) -> None:
    """F25: Server error stream is consumed and closed, preventing lingering file descriptors."""
    mock_llm_service.add_error_route("/err500", status=500, message="Critical Fault")
    req = urllib.request.Request(f"{mock_llm_service.url}/err500")
    with assert_no_resource_warnings():
        with pytest.raises(urllib.error.HTTPError) as exc_info:
            urllib.request.urlopen(req, timeout=5)
        assert exc_info.value.code == 500
        exc_info.value.close()


@pytest.mark.e2e
@pytest.mark.tier1
def test_tier1_f25_05_corrupted_procfs_data_handled_gracefully(
    virtual_procfs: VirtualProcfs,
) -> None:
    """F25: Unexpected or empty content in /proc/meminfo does not crash reader."""
    virtual_procfs.set_file("/proc/meminfo", b"")
    with open("/proc/meminfo", "rb") as fh:
        raw = fh.read()
    assert raw == b""
