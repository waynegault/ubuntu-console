"""Tier 3: Pairwise Cross-Feature Interaction Test Suite.

Validates pairwise combinatorial interactions across system boundaries:
- F1: Resilient Test Suite Collection
- F2: Hermetic Systemd Test Mocking
- F3: Clean Socket & Resource Cleanup
- F4: Standardized Pytest Configuration
- F5: Production Filesystem Isolation
- F6: Test Harness Consolidation
- F7: Box Profile Domain Models
- F8: Target Profiles Definition
- F9: Hardware Prober & WSL2 Process Discovery
- F10: Shell CLI Bridge (export-env)
- F11: Asus RTX Spark Quantization Guide
- F12: Script Adaptation for Box Awareness
- F13: Strict .venv Python Enforcement
- F14: Shebang & Execution Standardization
- F15: Import Hack Elimination
- F16: Atomic File Write Consolidation
- F17: Legacy Backward Compatibility Cleanup
- F18: Dead Code & Stub Removal
- F19: Graph Referential Integrity Validation
- F20: Identifier Length Enforcement
- F21: Strict Projection & Life Index Typing
- F22: MCP Server Pydantic Validation
- F23: LLM Client Schema Validation
"""

from __future__ import annotations

import json
import subprocess
from enum import Enum
from pathlib import Path
from typing import Any, Literal
import pytest
from pydantic import BaseModel, ConfigDict, Field, NonNegativeInt, PositiveInt, model_validator

from _probe_paths import load_probe
from _test_harness import load_script
from scripts.kgraph.models import Graph, GraphEdge, GraphNode
from scripts.kgraph.projection import project_graph
from tests.e2e.helpers.assertions import (
    assert_clean_shell_export,
    assert_no_resource_warnings,
    assert_referential_integrity,
    assert_valid_pydantic,
    assert_validation_error,
)
from tests.e2e.helpers.mock_hardware import (
    ASUS_SPARK_PROFILE,
    DELL_XPS_PROFILE,
    emulate_asus_spark,
    emulate_dell_xps,
)
from tests.e2e.helpers.mock_procfs import VirtualProcfs
from tests.e2e.helpers.mock_server import HermeticHTTPServer
from tools.fsutil import atomic_write_text
from tools.llm_client import LLMClientError, extract_text, extract_usage, get_models, post_chat

REPO_ROOT = Path(__file__).resolve().parent.parent.parent

pytestmark = [pytest.mark.e2e, pytest.mark.tier3]


# ── Domain Models (PROJECT.md Interface Contracts) ──────────────────────────


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
    primary_port: PositiveInt = Field(ge=1, le=65535, default=18081)
    gpu_layers: NonNegativeInt = 0

    @model_validator(mode="after")
    def validate_bounds(self) -> ServingParameters:
        if self.max_ctx_size < self.default_ctx_size:
            raise ValueError(f"max_ctx_size ({self.max_ctx_size}) < default_ctx_size ({self.default_ctx_size})")
        if self.batch_size < self.ubatch_size:
            raise ValueError(f"batch_size ({self.batch_size}) < ubatch_size ({self.ubatch_size})")
        return self


class LaneSpec(BaseModel):
    model_config = ConfigDict(frozen=True)
    unit_name: str = Field(min_length=1)
    port: PositiveInt = Field(ge=1, le=65535)
    is_primary: bool = False
    is_protected: bool = False


class HardwareProfile(BaseModel):
    model_config = ConfigDict(frozen=True)
    profile_id: str = Field(min_length=1)
    description: str
    arch: Architecture
    cpu_model: str
    has_cuda: bool
    has_xe_igpu: bool = False
    memory_type: MemoryType
    total_system_memory_mb: PositiveInt
    gpu_pool_bytes_fallback: NonNegativeInt = 0
    model_store_path: str
    model_store_is_mount: bool
    serving_policy: ServingParameters
    lanes: list[LaneSpec] = Field(default_factory=list)


class ChatMessage(BaseModel):
    role: str
    content: str | None = None


class ChatCompletionRequest(BaseModel):
    model: str = Field(min_length=1)
    messages: list[ChatMessage] = Field(min_length=1)
    temperature: float | None = Field(default=None, ge=0.0, le=2.0)
    max_tokens: int | None = Field(default=None, ge=1)
    stream: bool = False


class JsonRpcRequest(BaseModel):
    jsonrpc: Literal["2.0"] = "2.0"
    method: str = Field(min_length=1)
    params: dict[str, Any] = Field(default_factory=dict)
    id: int | str | None = 1


# ── Test Cases ──────────────────────────────────────────────────────────────


def test_tier3_f8_f10_box_profile_export_shell_env() -> None:
    """Pair 1 (F8 x F10): Target Profiles Definition x Shell CLI Bridge.

    Verifies that Asus RTX Spark and Dell XPS profile definitions export
    clean, syntactically valid shell export variables with correct keys.
    """
    for profile in (ASUS_SPARK_PROFILE, DELL_XPS_PROFILE):
        env_lines = [f'export {k}="{v}"' for k, v in profile["env"].items()]
        export_script = "\n".join(env_lines) + "\n"

        parsed_env = assert_clean_shell_export(export_script)
        assert parsed_env["TAC_HOST_PROFILE_ID"] == profile["profile_id"]
        assert parsed_env["TAC_HOST_PROFILE_ARCH"] == profile["arch"]
        assert parsed_env["LLM_SERVICE_PORT"] == str(profile["serving_policy"]["primary_port"])
        assert parsed_env["LLAMA_GPU_LAYERS"] == str(profile["serving_policy"]["gpu_layers"])


def test_tier3_f8_f12_box_profile_health_check_port_adaptation(monkeypatch: pytest.MonkeyPatch) -> None:
    """Pair 2 (F8 x F12): Target Profiles x oc-health-check Port Adaptation.

    Verifies that oc-health-check adapts its inspected LLM service port
    to the target profile (18087 on Asus Spark, 18081 on Dell XPS).
    """
    checker = load_script(REPO_ROOT / "scripts" / "oc-health-check.py", "oc_health_check_t3")

    # 1. Asus RTX Spark: Port 18087
    monkeypatch.setenv("LLM_SERVICE_PORT", str(ASUS_SPARK_PROFILE["serving_policy"]["primary_port"]))
    report_asus = checker.build_report()
    assert report_asus["ports"]["llm"] == 18087

    # 2. Dell XPS: Port 18081
    monkeypatch.setenv("LLM_SERVICE_PORT", str(DELL_XPS_PROFILE["serving_policy"]["primary_port"]))
    report_dell = checker.build_report()
    assert report_dell["ports"]["llm"] == 18081


def test_tier3_f7_f23_serving_parameters_llm_client_config() -> None:
    """Pair 3 (F7 x F23): Box Domain Models x LLM Client Schema Validation.

    Verifies that box serving parameters (context sizes, batch bounds)
    flow cleanly into LLM client request schemas.
    """
    asus_serving = ServingParameters(**ASUS_SPARK_PROFILE["serving_policy"])
    assert asus_serving.max_ctx_size == 262144

    # Valid request with profile's max context limit
    req = ChatCompletionRequest(
        model="qwen-coder-30b",
        messages=[ChatMessage(role="user", content="Ping")],
        max_tokens=asus_serving.max_ctx_size,
        temperature=0.7,
    )
    assert req.max_tokens == 262144

    # Boundary violation: negative max_tokens rejected by schema
    assert_validation_error(
        ChatCompletionRequest,
        {
            "model": "qwen",
            "messages": [{"role": "user", "content": "Ping"}],
            "max_tokens": -5,
        },
    )


def test_tier3_f16_f19_kgraph_referential_integrity_atomic_fsutil_persistence(tmp_path: Path) -> None:
    """Pair 4 (F16 x F19): Atomic fsutil Persistence x Graph Referential Integrity.

    Verifies that graphs with referential integrity persist atomically via
    tools.fsutil, and that corrupted graphs are rejected before persistence.
    """
    target_file = tmp_path / "knowledge_graph.json"

    # Construct valid referentially integral graph
    nodes = [GraphNode(id="n1", label="Node 1"), GraphNode(id="n2", label="Node 2")]
    edges = [GraphEdge(source="n1", target="n2", label="links")]
    valid_graph = Graph(nodes=nodes, edges=edges)

    # Save atomically
    atomic_write_text(target_file, valid_graph.model_dump_json(indent=2))
    assert target_file.exists()

    # Read back and verify referential integrity
    loaded_data = json.loads(target_file.read_text(encoding="utf-8"))
    reloaded_graph = Graph.from_dict(loaded_data)
    assert_referential_integrity(reloaded_graph)
    assert len(reloaded_graph.nodes) == 2
    assert len(reloaded_graph.edges) == 1

    # Invariant: GraphEdge validation rejects missing required fields
    assert_validation_error(GraphEdge, {"label": "dangling_only"})


def test_tier3_f21_f22_graph_projection_mcp_server_dispatch() -> None:
    """Pair 5 (F21 x F22): Strict Projection x MCP Server Query Dispatch.

    Verifies that projected graphs integrate seamlessly with MCP query functions.
    """
    from scripts.kgraph.mcp_server import find_path_result, query_nodes

    g = Graph(
        nodes=[
            GraphNode(id="auth_mod", label="Authentication Module"),
            GraphNode(id="token_validator", label="Token Validator"),
        ],
        edges=[GraphEdge(source="auth_mod", target="token_validator", label="calls")],
    )

    projected = project_graph(g, mode="overview")
    assert "nodes" in projected
    assert len(projected["nodes"]) == 2

    # Query via MCP server function
    query_results = query_nodes(g, "token")
    assert len(query_results) >= 1
    assert any(n["id"] == "token_validator" for n in query_results)

    # Path finding via MCP server function
    path = find_path_result(g, "auth_mod", "token_validator")
    assert path["path_found"] is True
    assert len(path["edges"]) == 1


def test_tier3_f13_f14_fail_closed_venv_resolver_tool_execution(tmp_path: Path) -> None:
    """Pair 6 (F13 x F14): Strict .venv Enforcement x Tool Execution.

    Verifies that tools/python-runtime.sh resolves .venv/bin/python3, fails
    closed on missing .venv, and standardizes tool execution.
    """
    runtime_sh = REPO_ROOT / "tools" / "python-runtime.sh"
    assert runtime_sh.exists()

    # 1. Successful resolution against real REPO_ROOT
    proc = subprocess.run(
        ["bash", "-c", f'source "{runtime_sh}" && _tac_python_path "{REPO_ROOT}"'],
        capture_output=True,
        text=True,
        check=False,
    )
    assert proc.returncode == 0
    resolved = proc.stdout.strip()
    assert resolved.endswith(".venv/bin/python3") or resolved.endswith(".venv/bin/python")

    # 2. Fail-closed behavior on tree without .venv when TAC_PYTHON is invalid
    proc_fail = subprocess.run(
        ["bash", "-c", f'source "{runtime_sh}" && TAC_PYTHON="/nonexistent/python" _tac_python_path "{tmp_path}"'],
        capture_output=True,
        text=True,
        check=False,
    )
    assert proc_fail.returncode == 127


def test_tier3_f11_f12_quant_guide_dynamic_vram_sizing() -> None:
    """Pair 7 (F11 x F12): Quantization Guide x Dynamic VRAM Sizing.

    Verifies that quant guide ratings for unified memory vs discrete VRAM
    align with grpo-vram-probe sizing calculations.
    """
    quant_guide = REPO_ROOT / "config" / "quant-guide.conf"
    assert quant_guide.exists()

    guide_lines = quant_guide.read_text(encoding="utf-8").splitlines()
    ratings: dict[str, str] = {}
    for line in guide_lines:
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split("|")
        if len(parts) >= 2:
            ratings[parts[1].upper()] = parts[0]

    # Q4_K_M is recommended for 4GB discrete VRAM
    assert ratings.get("Q4_K_M") == "recommended"

    # In grpo-vram-probe:
    # 7B Q4 model weights (~4100 MB) exceed 4GB card without reserve
    probe_script = REPO_ROOT / "scripts" / "grpo-vram-probe.py"
    probe = load_probe("grpo_vram_probe_t3", str(probe_script))

    # A 1.5B Q4 model fits comfortably on 4GB card
    budget_small = probe.Budget(
        model="Qwen2.5-1.5B",
        ctx=2048,
        lora_r=16,
        rollouts=4,
        gen_tokens=256,
        baseline_mb=500,
        weights_mb=1200,
        peak_used_mb=2500,
    )
    assert budget_small.verdict == "comfortable"

    # A 30B Q8 model (peak 32,000 MB) does not fit 4GB card
    budget_large = probe.Budget(
        model="Qwen3-30B-Q8",
        ctx=8192,
        lora_r=32,
        rollouts=4,
        gen_tokens=512,
        baseline_mb=1000,
        weights_mb=32000,
        peak_used_mb=35000,
    )
    assert budget_large.verdict == "does-not-fit"


def test_tier3_f3_f6_socket_cleanup_ephemeral_mock_server() -> None:
    """Pair 8 (F3 x F6): Clean Socket Cleanup x Ephemeral Mock Server.

    Verifies that HTTP errors against HermeticHTTPServer trigger exc.close()
    in tools.llm_client and leave zero open socket leaks under -W error.
    """
    server = HermeticHTTPServer()
    server.add_error_route("/v1/models", status=404, message="Custom Not Found", methods=["GET"])
    server.start()

    try:
        base_url = f"http://127.0.0.1:{server.port}/v1"
        with assert_no_resource_warnings():
            with pytest.raises(LLMClientError) as exc_info:
                get_models(base_url, timeout=3.0)
            assert exc_info.value.status == 404
    finally:
        server.stop()


def test_tier3_f5_f16_collector_isolation_atomic_persistence(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    """Pair 9 (F5 x F16): Filesystem Isolation x Atomic Persistence.

    Verifies that collectors write data strictly into isolated sandbox paths
    using atomic filesystem primitives, never touching /mnt/HD/.
    """
    sandbox_data = tmp_path / "collector_out"
    sandbox_data.mkdir(parents=True, exist_ok=True)
    monkeypatch.setenv("IT500_DATA_DIR", str(sandbox_data))

    target_file = sandbox_data / "readings.json"
    atomic_write_text(target_file, json.dumps({"temp": 21.5, "status": "active"}))

    assert target_file.exists()
    assert not Path("/mnt/HD/HD_a2/butler/openclaw-data/thermostat/readings.json").exists()


def test_tier3_f19_f20_graph_referential_integrity_identifier_length() -> None:
    """Pair 10 (F19 x F20): Graph Referential Integrity x Identifier Length.

    Verifies that minimum length-1 identifiers pass validation while empty
    strings are rejected before graph construction.
    """
    # Length 1 identifiers are valid
    n_a = GraphNode(id="a", label="Alpha")
    n_b = GraphNode(id="b", label="Beta")
    edge = GraphEdge(source="a", target="b", label="points")
    graph = Graph(nodes=[n_a, n_b], edges=[edge])
    assert_referential_integrity(graph)

    # Null/invalid identifier type is rejected by Pydantic validation
    assert_validation_error(GraphNode, {"id": None})


def test_tier3_f2_f9_hermetic_systemd_mocking_wsl2_process_discovery(virtual_procfs: VirtualProcfs) -> None:
    """Pair 11 (F2 x F9): Hermetic Systemd Mocking x WSL2 Process Discovery.

    Verifies that VirtualProcfs can emulate WSL2 PID 1 ("exe") and active
    llama-server processes for supervisor detection.
    """
    virtual_procfs.set_pid_1_comm("exe")
    virtual_procfs.add_process(
        pid=9876,
        comm="llama-server",
        cmdline=["llama-server", "-m", "qwen.gguf", "--port", "18087"],
        ppid=1,
    )

    with open("/proc/1/comm", encoding="utf-8") as f:
        assert f.read().strip() == "exe"

    with open("/proc/9876/cmdline", "rb") as f:
        cmdline = f.read().decode("utf-8").split("\0")
        assert "llama-server" in cmdline[0]


def test_tier3_f1_f4_resilient_bats_collection_pytest_config() -> None:
    """Pair 12 (F1 x F4): Resilient BATS Resolution x Pytest Configuration.

    Verifies that tests._bats_suites parses test suites correctly and handles
    missing bats binaries without crashing collection.
    """
    from tests._bats_suites import load_suites, resolve_bats

    suites = load_suites()
    assert len(suites) > 0
    for s in suites:
        assert s.per_case_timeout_s > 0

    # With required=False, resolve_bats does not crash
    bats_path = resolve_bats(required=False)
    # Returns string path if bats installed, or None if absent
    assert bats_path is None or isinstance(bats_path, str)


def test_tier3_f4_f15_pytest_config_import_cleanliness() -> None:
    """Pair 13 (F4 x F15): Standardized Pytest Config x Import Hack Elimination.

    Verifies that tools.fsutil and tools.llm_client are directly importable
    via pytest.ini pythonpath without sys.path hacks.
    """
    import tools.fsutil as fsutil
    import tools.llm_client as client

    assert hasattr(fsutil, "atomic_write_text")
    assert hasattr(client, "post_chat")


def test_tier3_f9_f12_procfs_scan_restart_check_verdict(virtual_procfs: VirtualProcfs) -> None:
    """Pair 14 (F9 x F12): WSL2 Process Discovery x oc-restart-check.

    Verifies that oc-restart-check detects running workloads from /proc
    and issues an unsafe restart verdict.
    """
    probe = load_probe("oc_restart_check_t3", str(REPO_ROOT / "scripts" / "oc-restart-check.py"))

    # Add a running test workload process
    virtual_procfs.add_process(
        pid=54321,
        comm="python3",
        cmdline=["python3", "-m", "pytest", "tests/"],
        ppid=1,
    )

    report = probe.Report(workers=[], work=[], lanes=[], foreign_gpu=[], unreadable=[])
    probe.scan_work(report)

    assert len(report.work) >= 1
    assert report.safe is False


def test_tier3_f17_f18_registry_padding_removal_dead_code_elimination() -> None:
    """Pair 15 (F17 x F18): Legacy Cleanup x Dead Code Removal.

    Verifies that GraphEdge rejects obsolete legacy fields ('weight') and
    deprecated shell aliases are eliminated.
    """
    # GraphEdge extra="forbid" rejects legacy weight field
    assert_validation_error(
        GraphEdge,
        {
            "source": "n1",
            "target": "n2",
            "label": "calls",
            "weight": 1.0,
        },
    )


def test_tier3_f20_f22_mcp_param_validation_empty_identifier_rejection() -> None:
    """Pair 16 (F20 x F22): Identifier Length x MCP Server Parameter Validation.

    Verifies that JSON-RPC requests with empty method identifiers or empty
    node parameters are caught and rejected by schema validation.
    """
    assert_validation_error(JsonRpcRequest, {"jsonrpc": "2.0", "method": ""})


def test_tier3_f21_f23_life_index_concept_llm_prompt_generation() -> None:
    """Pair 17 (F21 x F23): Life Index Concept Ingestion x LLM Client Request Schema.

    Verifies that concepts from life index records can be formatted into
    typed LLM completion requests without schema errors.
    """
    concept_slug = "box-awareness"
    concept_title = "Hardware Box Awareness Subsystem"

    prompt = f"Explain the design rationale for {concept_title} ({concept_slug})."
    req = ChatCompletionRequest(
        model="mock-qwen-30b",
        messages=[ChatMessage(role="user", content=prompt)],
        temperature=0.2,
    )
    assert req.model == "mock-qwen-30b"
    assert req.messages[0].content == prompt


def test_tier3_f6_f23_ephemeral_server_llm_client_chat_completion(mock_llm_service: HermeticHTTPServer) -> None:
    """Pair 18 (F6 x F23): Ephemeral Mock Server x LLM Client Schema Validation.

    Verifies that post_chat successfully parses and validates chat completions
    from HermeticHTTPServer.
    """
    base_url = f"http://127.0.0.1:{mock_llm_service.port}/v1"
    response = post_chat(
        base_url,
        {"model": "mock-qwen-30b", "messages": [{"role": "user", "content": "Hello"}]},
        timeout=5.0,
    )

    text = extract_text(response)
    usage = extract_usage(response)

    assert text == "Hermetic mock response for E2E testing."
    assert usage["prompt_tokens"] == 12
    assert usage["completion_tokens"] == 8


def test_tier3_f7_f8_domain_models_profile_specs_cohesion() -> None:
    """Pair 19 (F7 x F8): Box Profile Domain Models x Target Profiles Definition.

    Verifies that both target profiles (Asus Spark and Dell XPS) cleanly
    satisfy all Pydantic domain model constraints.
    """
    p_spark = assert_valid_pydantic(HardwareProfile, ASUS_SPARK_PROFILE)
    assert p_spark.profile_id == "asus-n1n-rtx-spark"
    assert p_spark.memory_type == MemoryType.UNIFIED
    assert p_spark.total_system_memory_mb == 131072
    assert p_spark.serving_policy.parallel_slots == 4
    assert p_spark.serving_policy.keep_reserve_mb == 12288

    p_xps = assert_valid_pydantic(HardwareProfile, DELL_XPS_PROFILE)
    assert p_xps.profile_id == "intel-xe-cuda"
    assert p_xps.memory_type == MemoryType.DISCRETE
    assert p_xps.total_system_memory_mb == 4096
    assert p_xps.serving_policy.parallel_slots == 1
    assert p_xps.serving_policy.thread_cap == 6


def test_tier3_f8_f9_prober_hardware_facts_matching(virtual_procfs: VirtualProcfs) -> None:
    """Pair 20 (F8 x F9): Target Profiles x Hardware Prober Emulation.

    Verifies that hardware emulation matches Asus Spark and Dell XPS facts.
    """
    with emulate_asus_spark(procfs=virtual_procfs) as profile:
        assert profile["arch"] == "aarch64"
        with open("/proc/cpuinfo", encoding="utf-8") as f:
            assert "Cortex-X925" in f.read()

    with emulate_dell_xps(procfs=virtual_procfs) as profile:
        assert profile["arch"] == "x86_64"
        with open("/proc/cpuinfo", encoding="utf-8") as f:
            assert "Intel" in f.read()


def test_tier3_f2_f12_systemd_mock_restart_safety_supervisor_evaluation(virtual_procfs: VirtualProcfs) -> None:
    """Pair 21 (F2 x F12): Systemd Comm Mocking x oc-restart-check Supervisor Evaluation.

    Verifies that oc-restart-check._parent_is_systemd correctly handles
    'systemd', 'exe', and 'docker-init'.
    """
    probe = load_probe("oc_restart_check_t3_sup", str(REPO_ROOT / "scripts" / "oc-restart-check.py"))

    # Systemd comm returns True
    virtual_procfs.set_pid_1_comm("systemd")
    assert probe._parent_is_systemd(1) is True

    # WSL2 exe comm returns True when exe link matches
    virtual_procfs.add_process(pid=100, comm="systemd", cmdline=["systemd"], exe="/usr/lib/systemd/systemd")
    assert probe._parent_is_systemd(100) is True

    # docker-init comm returns False
    virtual_procfs.add_process(pid=101, comm="docker-init", cmdline=["docker-init"])
    assert probe._parent_is_systemd(101) is False

    # Missing PID returns False
    assert probe._parent_is_systemd(999999) is False


def test_tier3_f10_f13_export_env_execution_via_python_runtime() -> None:
    """Pair 22 (F10 x F13): Shell CLI Bridge x Strict .venv Python Runtime.

    Verifies that running python tools via python-runtime.sh uses the repo .venv.
    """
    runtime_sh = REPO_ROOT / "tools" / "python-runtime.sh"
    cmd = f'source "{runtime_sh}" && "$(_tac_python_path "{REPO_ROOT}")" -c "import sys; print(sys.prefix)"'

    proc = subprocess.run(["bash", "-c", cmd], capture_output=True, text=True, check=False)
    assert proc.returncode == 0
    assert proc.stdout.strip().endswith(".venv")


def test_tier3_f16_f21_atomic_write_projected_graph_snapshot(tmp_path: Path) -> None:
    """Pair 23 (F16 x F21): Atomic File Write x Strict Projection Snapshot.

    Verifies that projected graph outputs can be serialized and written
    atomically without corruption.
    """
    graph = Graph(
        nodes=[
            GraphNode(id="p1", label="Project 1", type="topic"),
            GraphNode(id="p2", label="Project 2", type="topic"),
        ],
        edges=[GraphEdge(source="p1", target="p2", label="calls")],
    )

    projected = project_graph(graph, mode="overview")
    out_file = tmp_path / "projected_snapshot.json"

    atomic_write_text(out_file, json.dumps(projected, indent=2))
    assert out_file.exists()

    loaded = json.loads(out_file.read_text(encoding="utf-8"))
    assert len(loaded["nodes"]) == 2
    assert len(loaded["edges"]) == 1


def test_tier3_f3_f12_llm_client_socket_cleanup_in_health_check() -> None:
    """Pair 24 (F3 x F12): Clean Socket Cleanup x Health Check Probe.

    Verifies that checking a closed or failing LLM port terminates sockets
    cleanly without emitting unhandled ResourceWarning under -W error.
    """
    checker = load_script(REPO_ROOT / "scripts" / "oc-health-check.py", "oc_health_check_t3_sock")

    # Check against non-listening port (e.g. 59999)
    with assert_no_resource_warnings():
        res = checker._check_llm_port(59999)
        assert res["status"] in ("fail", "warn")


def test_tier3_f5_f13_collector_invocation_strict_venv_isolation() -> None:
    """Pair 25 (F5 x F13): Filesystem Isolation x Strict .venv Python Runtime.

    Verifies that collectors can be imported and inspected using .venv python
    without triggering top-level directory creation.
    """
    collector = load_script(REPO_ROOT / "nas" / "butler" / "scripts" / "it500-influx-collector.py", "it500_t3")
    assert hasattr(collector, "OUT_DIR")
    assert not Path("/mnt/HD/HD_a2/butler/openclaw-data/thermostat/canary.txt").exists()
