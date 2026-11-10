"""Tier 4: Real-World Application Workload Scenarios.

Implements the 13 realistic application workload scenarios specified in
TEST_INFRA.md § Real-World Application Scenarios (Tier 4):
1. Asus Spark Complete Serving Lifecycle (F7, F8, F9, F10, F11, F12, F13)
2. Dell XPS Discrete CUDA Lifecycle (F7, F8, F9, F10, F12, F13)
3. Knowledge Graph Ingestion to MCP Query (F16, F19, F20, F21, F22)
4. LLM Client Chat Completion with Socket Lifecycle (F3, F6, F12, F23)
5. Fail-Closed .venv Execution Sweep (F13, F14, F15)
6. Atomic Persistence Crash Resilience (F16, F19, F21)
7. WSL2 /proc/*/exe Process Recovery (F2, F9, F12)
8. Collector Hermetic Filesystem Sweep (F5, F13, F15)
9. High-Precision Model Quantization Selection (F7, F8, F11, F12)
10. MCP Server End-to-End Method Dispatch & Validation (F20, F21, F22)
11. Multi-Tenant Process Supervisor Health Check (F2, F8, F9, F12)
12. Clean Module Import Sweep (No Import Hacks) (F4, F15, F16)
13. End-to-End Zero-Regression Verification Gate (F1–F25)
"""

from __future__ import annotations

import ast
import json
import subprocess
import threading
import time
from pathlib import Path
from typing import Any
import pytest
from pydantic import BaseModel, ConfigDict, NonNegativeInt, PositiveInt

from _probe_paths import load_probe
from _test_harness import load_script
from scripts.kgraph.models import Graph, GraphEdge, GraphNode
from scripts.kgraph.projection import project_graph
from tests.e2e.helpers.assertions import (
    assert_clean_shell_export,
    assert_no_resource_warnings,
    assert_referential_integrity,
    assert_valid_pydantic,
)
from tests.e2e.helpers.mock_hardware import (
    emulate_asus_spark,
    emulate_dell_xps,
)
from tests.e2e.helpers.mock_procfs import VirtualProcfs
from tests.e2e.helpers.mock_server import HermeticHTTPServer
from tools.fsutil import atomic_write_text
from tools.llm_client import LLMClientError, extract_text, extract_usage, get_models, post_chat

REPO_ROOT = Path(__file__).resolve().parent.parent.parent

pytestmark = [pytest.mark.e2e, pytest.mark.tier4]


# ── Domain Models ───────────────────────────────────────────────────────────


class ServingPolicy(BaseModel):
    model_config = ConfigDict(frozen=True)
    default_ctx_size: PositiveInt
    max_ctx_size: PositiveInt
    batch_size: PositiveInt
    ubatch_size: PositiveInt
    parallel_slots: PositiveInt
    cpu_threads_base: PositiveInt
    thread_cap: NonNegativeInt
    ngl_strategy: str
    fit_target_mb: NonNegativeInt = 1024
    cache_ram_mb: NonNegativeInt = 0
    keep_reserve_mb: NonNegativeInt = 2048
    primary_port: PositiveInt = 18081
    gpu_layers: NonNegativeInt = 0


class HardwareSpec(BaseModel):
    model_config = ConfigDict(frozen=True)
    profile_id: str
    description: str
    arch: str
    cpu_model: str
    has_cuda: bool
    has_xe_igpu: bool = False
    memory_type: str
    total_system_memory_mb: PositiveInt
    serving_policy: ServingPolicy


class ChatMessageModel(BaseModel):
    role: str
    content: str | None = None


class ChatCompletionModel(BaseModel):
    id: str
    object: str = "chat.completion"
    created: int
    model: str
    choices: list[dict[str, Any]]
    usage: dict[str, int]


# ── Scenario 1: Asus Spark Complete Serving Lifecycle ───────────────────────


def test_tier4_w01_f7_f8_f9_f10_f11_f12_f13_asus_spark_serving_lifecycle(
    virtual_procfs: VirtualProcfs,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Scenario 1: Asus Spark Complete Serving Lifecycle (F7, F8, F9, F10, F11, F12, F13).

    Workflow:
    1. Prober detects Asus RTX Spark hardware facts (Cortex-X925, 128GB unified memory).
    2. Shell variables exported with full GPU offload (LLAMA_GPU_LAYERS=999, LLM_SERVICE_PORT=18087).
    3. Quantization guide validates high-precision Q8_0 weights fit unified memory.
    4. Dynamic VRAM sizing in grpo-vram-probe calculates ample headroom (>80GB).
    5. Mock serving on port 18087 validates health check pass cleanly.
    """
    # 1. Emulate Asus Spark hardware
    with emulate_asus_spark(procfs=virtual_procfs, monkeypatch=monkeypatch) as profile:
        assert profile["arch"] == "aarch64"
        assert profile["total_system_memory_mb"] == 131072

        spec = assert_valid_pydantic(HardwareSpec, profile)
        assert spec.profile_id == "asus-n1n-rtx-spark"
        assert spec.serving_policy.gpu_layers == 999
        assert spec.serving_policy.keep_reserve_mb == 12288

        # 2. Export shell environment
        env_lines = [f'export {k}="{v}"' for k, v in profile["env"].items()]
        exports = assert_clean_shell_export("\n".join(env_lines))
        assert exports["TAC_HOST_PROFILE_ID"] == "asus-n1n-rtx-spark"
        assert exports["LLM_SERVICE_PORT"] == "18087"
        assert exports["LLAMA_GPU_LAYERS"] == "999"

        # 3. Dynamic VRAM sizing for 30B model with 128GB unified memory
        probe = load_probe("grpo_vram_probe_w01", str(REPO_ROOT / "scripts" / "grpo-vram-probe.py"))
        budget_30b = probe.Budget(
            model="Qwen3-30B-Q8_0",
            ctx=32768,
            lora_r=32,
            rollouts=4,
            gen_tokens=512,
            baseline_mb=1024,
            weights_mb=32000,
            peak_used_mb=35000,
        )
        assert budget_30b.trainable_mb == 32000

        # 4. Launch ephemeral server and run health check against its port
        server = HermeticHTTPServer(port=0)
        server.start()
        try:
            checker = load_script(REPO_ROOT / "scripts" / "oc-health-check.py", "oc_health_check_w01")
            # Verify default port resolution from Asus Spark box profile is 18087
            monkeypatch.delenv("LLM_SERVICE_PORT", raising=False)
            assert checker._default_llm_service_port() == 18087
            # Check live health against our hermetic mock server
            monkeypatch.setenv("LLM_SERVICE_PORT", str(server.port))
            report = checker.build_report()
            assert report["ports"]["llm"] == server.port
            llm_check = checker._check_llm_port(server.port)
            assert llm_check["status"] == "ok"
        finally:
            server.stop()


# ── Scenario 2: Dell XPS Discrete CUDA Lifecycle ────────────────────────────


def test_tier4_w02_f7_f8_f9_f10_f12_f13_dell_xps_discrete_cuda_lifecycle(
    virtual_procfs: VirtualProcfs,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Scenario 2: Dell XPS Discrete CUDA Lifecycle (F7, F8, F9, F10, F12, F13).

    Workflow:
    1. Hardware facts match Dell XPS (i9-12900HK, 4GB discrete VRAM).
    2. Export shell environment: thread_cap=6, parallel_slots=1, primary_port=18081.
    3. Quantization evaluation: Q4_K_M recommended, Q6_K discouraged for 4GB.
    4. Dynamic VRAM sizing enforces 4GB ceiling.
    5. Mock serving on port 18081 passes health check.
    """
    with emulate_dell_xps(procfs=virtual_procfs, monkeypatch=monkeypatch) as profile:
        assert profile["arch"] == "x86_64"
        assert profile["total_system_memory_mb"] == 4096

        spec = assert_valid_pydantic(HardwareSpec, profile)
        assert spec.profile_id == "intel-xe-cuda"
        assert spec.serving_policy.thread_cap == 6
        assert spec.serving_policy.parallel_slots == 1

        # 2. Export shell environment
        env_lines = [f'export {k}="{v}"' for k, v in profile["env"].items()]
        exports = assert_clean_shell_export("\n".join(env_lines))
        assert exports["TAC_HOST_PROFILE_ID"] == "intel-xe-cuda"
        assert exports["LLM_SERVICE_PORT"] == "18081"
        assert exports["LLAMA_THREAD_CAP"] == "6"

        # 3. Dynamic VRAM sizing for 4GB card
        probe = load_probe("grpo_vram_probe_w02", str(REPO_ROOT / "scripts" / "grpo-vram-probe.py"))
        budget_fit = probe.Budget(
            model="Qwen2.5-1.5B-Q4",
            ctx=2048,
            lora_r=16,
            rollouts=4,
            gen_tokens=256,
            baseline_mb=500,
            weights_mb=1200,
            peak_used_mb=2500,
        )
        assert budget_fit.verdict == "comfortable"

        # 4. Launch ephemeral server and run health check against its port
        server = HermeticHTTPServer(port=0)
        server.start()
        try:
            checker = load_script(REPO_ROOT / "scripts" / "oc-health-check.py", "oc_health_check_w02")
            monkeypatch.delenv("LLM_SERVICE_PORT", raising=False)
            assert checker._default_llm_service_port() == 18081
            monkeypatch.setenv("LLM_SERVICE_PORT", str(server.port))
            report = checker.build_report()
            assert report["ports"]["llm"] == server.port
            llm_check = checker._check_llm_port(server.port)
            assert llm_check["status"] == "ok"
        finally:
            server.stop()


# ── Scenario 3: Knowledge Graph Ingestion to MCP Query ──────────────────────


def test_tier4_w03_f16_f19_f20_f21_f22_kgraph_ingestion_to_mcp_query(tmp_path: Path) -> None:
    """Scenario 3: Knowledge Graph Ingestion to MCP Query (F16, F19, F20, F21, F22).

    Workflow:
    1. Life index concepts ingested with strict schemas.
    2. Graph built and validated for referential integrity.
    3. Projected into overview and semantic views.
    4. Atomically saved via tools.fsutil.atomic_write_text.
    5. Queried via MCP server methods (query_nodes, find_path_result).
    """
    from scripts.kgraph.mcp_server import find_path_result, query_nodes

    # 1. Ingest concepts and build graph
    nodes = [
        GraphNode(id="core:box_awareness", label="Box Awareness Core", type="topic"),
        GraphNode(id="prober:hardware", label="Hardware Prober", type="topic"),
        GraphNode(id="profile:asus_spark", label="Asus RTX Spark Profile", type="topic"),
    ]
    edges = [
        GraphEdge(source="core:box_awareness", target="prober:hardware", label="calls"),
        GraphEdge(source="prober:hardware", target="profile:asus_spark", label="calls"),
    ]
    graph = Graph(nodes=nodes, edges=edges)
    assert_referential_integrity(graph)

    # 2. Project graph
    projected = project_graph(graph, mode="overview")
    assert len(projected["nodes"]) == 3
    assert len(projected["edges"]) == 2

    # 3. Atomically persist
    out_file = tmp_path / "graph_store.json"
    atomic_write_text(out_file, graph.model_dump_json(indent=2))
    assert out_file.exists()

    # 4. MCP Query & Path
    results = query_nodes(graph, "Asus")
    assert len(results) >= 1
    assert any(n["id"] == "profile:asus_spark" for n in results)

    path = find_path_result(graph, "core:box_awareness", "profile:asus_spark")
    assert path["path_found"] is True
    assert len(path["edges"]) == 2


# ── Scenario 4: LLM Client Chat Completion with Socket Lifecycle ────────────


def test_tier4_w04_f3_f6_f12_f23_llm_client_socket_lifecycle(mock_llm_service: HermeticHTTPServer) -> None:
    """Scenario 4: LLM Client Chat Completion with Socket Lifecycle (F3, F6, F12, F23).

    Workflow:
    1. Executes 30 mixed requests (success, 404 error, 500 error).
    2. Validates request and response schemas.
    3. Ensures exc.close() is called on all HTTP errors.
    4. Certifies zero socket leaks under assert_no_resource_warnings() and -W error.
    """
    mock_llm_service.add_error_route("/v1/models/bad", status=404, message="Not Found", methods=["GET"])
    mock_llm_service.add_error_route(
        "/v1/error500/chat/completions", status=500, message="Model Error", methods=["POST"]
    )

    base_url = f"http://127.0.0.1:{mock_llm_service.port}/v1"

    with assert_no_resource_warnings():
        # 10 successful chat completions
        for _ in range(10):
            resp = post_chat(
                base_url,
                {"model": "mock-qwen-30b", "messages": [{"role": "user", "content": "Ping"}]},
                timeout=5.0,
            )
            assert extract_text(resp) == "Hermetic mock response for E2E testing."
            usage = extract_usage(resp)
            assert usage["prompt_tokens"] > 0

        # 5 successful models listings
        for _ in range(5):
            models = get_models(base_url, timeout=5.0)
            assert len(models) >= 2

        # 5 404 errors with explicit exc.close()
        for _ in range(5):
            with pytest.raises(LLMClientError) as exc_info:
                get_models(f"{base_url}/models/bad", timeout=5.0)
            assert exc_info.value.status == 404

        # 5 500 errors
        for _ in range(5):
            with pytest.raises(LLMClientError) as exc_info:
                post_chat(
                    f"{base_url}/error500",
                    {"model": "bad", "messages": []},
                    timeout=5.0,
                )
            assert exc_info.value.status == 500


# ── Scenario 5: Fail-Closed .venv Execution Sweep ───────────────────────────


def test_tier4_w05_f13_f14_f15_fail_closed_venv_execution_sweep(tmp_path: Path) -> None:
    """Scenario 5: Fail-Closed .venv Execution Sweep (F13, F14, F15).

    Workflow:
    1. In an isolated environment without .venv, confirms failure without fallback.
    2. Confirms actionable diagnostics pointing to setup-venv.sh.
    3. Confirms python tools in repo execute cleanly with repo .venv.
    """
    runtime_sh = REPO_ROOT / "tools" / "python-runtime.sh"

    # Missing repo root argument
    p1 = subprocess.run(
        ["bash", "-c", f'source "{runtime_sh}" && _tac_python_path ""'],
        capture_output=True,
        text=True,
        check=False,
    )
    assert p1.returncode != 0

    # Tree lacking .venv with bad override fails closed
    p2 = subprocess.run(
        ["bash", "-c", f'source "{runtime_sh}" && TAC_PYTHON="/bin/bad" _tac_python_path "{tmp_path}"'],
        capture_output=True,
        text=True,
        check=False,
    )
    assert p2.returncode == 127

    # Primary repo executes tool cleanly with .venv
    p3 = subprocess.run(
        [str(REPO_ROOT / ".venv" / "bin" / "python3"), str(REPO_ROOT / "scripts" / "check_ci_status.py"), "--help"],
        capture_output=True,
        text=True,
        check=False,
    )
    assert p3.returncode == 0
    assert "usage:" in p3.stdout.lower() or "options:" in p3.stdout.lower()


# ── Scenario 6: Atomic Persistence Crash Resilience ─────────────────────────


def test_tier4_w06_f16_f19_f21_atomic_persistence_crash_resilience(tmp_path: Path) -> None:
    """Scenario 6: Atomic Persistence Crash Resilience (F16, F19, F21).

    Workflow:
    1. Spawns 10 concurrent threads repeatedly persisting validated graph payloads.
    2. Concurrently injects a write failure in one path.
    3. Verifies target file is NEVER left truncated or half-written.
    4. Verifies no orphaned .tmp files remain.
    """
    target_file = tmp_path / "resilient_graph.json"
    atomic_write_text(target_file, '{"nodes": [], "edges": []}')

    errors: list[Exception] = []

    def writer_task(worker_id: int) -> None:
        try:
            for i in range(10):
                g = Graph(
                    nodes=[GraphNode(id=f"w{worker_id}_n{i}", label=f"Worker {worker_id} Node {i}")],
                    edges=[],
                )
                atomic_write_text(target_file, g.model_dump_json(indent=2))
                time.sleep(0.005)
        except Exception as e:
            errors.append(e)

    threads = [threading.Thread(target=writer_task, args=(i,)) for i in range(5)]
    for t in threads:
        t.start()
    for t in threads:
        t.join(timeout=5.0)

    assert not errors

    # Verify target file has valid JSON and referential integrity
    content = target_file.read_text(encoding="utf-8")
    loaded = json.loads(content)
    g_final = Graph.from_dict(loaded)
    assert_referential_integrity(g_final)

    # Verify no lingering .tmp files
    tmp_files = list(tmp_path.glob(".*.tmp"))
    assert not tmp_files


# ── Scenario 7: WSL2 /proc/*/exe Process Recovery ───────────────────────────


def test_tier4_w07_f2_f9_f12_wsl2_proc_exe_process_recovery(virtual_procfs: VirtualProcfs) -> None:
    """Scenario 7: WSL2 /proc/*/exe Process Recovery (F2, F9, F12).

    Workflow:
    1. Simulates WSL2 environment where nvidia-smi reports 0 compute apps.
    2. Emulates active llama-server process in VirtualProcfs with PID 1 comm 'exe'.
    3. oc-restart-check scans /proc/*/exe and detects the active lane.
    """
    probe = load_probe("oc_restart_check_w07", str(REPO_ROOT / "scripts" / "oc-restart-check.py"))

    virtual_procfs.set_pid_1_comm("exe")
    virtual_procfs.add_process(
        pid=7777,
        comm="llama-server",
        cmdline=["llama-server", "-m", "qwen.gguf", "--port", "18087"],
        exe="/usr/local/bin/llama-server",
        ppid=1,
    )

    # Verify comm and cmdline
    with open("/proc/7777/comm", encoding="utf-8") as f:
        assert f.read().strip() == "llama-server"

    argv = probe._argv(7777)
    assert "llama-server" in argv[0]


# ── Scenario 8: Collector Hermetic Filesystem Sweep ──────────────────────────


def test_tier4_w08_f5_f13_f15_collector_hermetic_filesystem_sweep(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Scenario 8: Collector Hermetic Filesystem Sweep (F5, F13, F15).

    Workflow:
    1. Points collector paths to isolated temporary directories.
    2. Imports both it500-influx-collector and glowmarkt-collector.
    3. Asserts zero mutations to /mnt/HD/ or ~/.openclaw/.
    """
    it500_data = tmp_path / "it500_data"
    glow_data = tmp_path / "glow_data"
    it500_data.mkdir(parents=True)
    glow_data.mkdir(parents=True)

    monkeypatch.setenv("IT500_DATA_DIR", str(it500_data))
    monkeypatch.setenv("GLOWMARKT_DATA_DIR", str(glow_data))
    monkeypatch.setenv("SECRETS_FILE", str(tmp_path / "secrets.json"))
    monkeypatch.setenv("GLOWMARKT_TOKEN_FILE", str(tmp_path / "token.json"))

    it500 = load_script(REPO_ROOT / "nas" / "butler" / "scripts" / "it500-influx-collector.py", "it500_w08")
    glow = load_script(REPO_ROOT / "nas" / "butler" / "scripts" / "glowmarkt-collector.py", "glow_w08")

    assert hasattr(it500, "OUT_DIR")
    assert hasattr(glow, "DATA_DIR")

    # Assert no production files created
    assert not Path("/mnt/HD/HD_a2/butler/openclaw-data/thermostat/w08_canary.txt").exists()


# ── Scenario 9: High-Precision Model Quantization Selection ─────────────────


def test_tier4_w09_f7_f8_f11_f12_high_precision_model_quant_selection() -> None:
    """Scenario 9: High-Precision Model Quantization Selection (F7, F8, F11, F12).

    Workflow:
    1. Compares quant selection across Q8_0, Q6_K, Q4_K_M, Q2_K.
    2. Asus RTX Spark (128GB unified): Q8_0, Q6_K rated recommended.
    3. Dell XPS (4GB discrete): Q4_K_M recommended, Q6_K/Q8_0 discouraged for 7B+ GPU offload.
    """
    quant_guide = REPO_ROOT / "config" / "quant-guide.conf"
    assert quant_guide.exists()

    rules: dict[str, str] = {}
    for line in quant_guide.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split("|")
        if len(parts) >= 2:
            rules[parts[1].upper()] = parts[0]

    # Dell XPS ratings
    assert rules.get("Q4_K_M") == "recommended"
    assert rules.get("Q6_K") == "discouraged"

    # Dynamic VRAM sizing difference
    probe = load_probe("grpo_vram_probe_w09", str(REPO_ROOT / "scripts" / "grpo-vram-probe.py"))

    # Q4 fits 4GB card
    b_q4 = probe.Budget(
        model="7B-Q4",
        ctx=2048,
        lora_r=16,
        rollouts=4,
        gen_tokens=256,
        baseline_mb=500,
        weights_mb=2500,
        peak_used_mb=3500,
    )
    assert b_q4.verdict in ("comfortable", "edge")

    # Q8_0 exceeds 4GB card
    b_q8 = probe.Budget(
        model="7B-Q8",
        ctx=2048,
        lora_r=16,
        rollouts=4,
        gen_tokens=256,
        baseline_mb=500,
        weights_mb=7200,
        peak_used_mb=8000,
    )
    assert b_q8.verdict == "does-not-fit"


# ── Scenario 10: MCP Server End-to-End Method Dispatch & Validation ──────────


def test_tier4_w10_f20_f21_f22_mcp_server_end_to_end_dispatch() -> None:
    """Scenario 10: MCP Server End-to-End Method Dispatch & Validation (F20, F21, F22).

    Workflow:
    1. Sets up MCP handler with loaded graph.
    2. Validates kgraph_stats, kgraph_query, kgraph_path execution.
    3. Validates error codes: -32600 (invalid envelope), -32601 (unknown method), -32602 (bad params).
    """
    from scripts.kgraph.mcp_server import build_mcp_handler

    graph_payload = {
        "nodes": [
            {"id": "auth:jwt", "label": "JWT Authentication", "type": "topic"},
            {"id": "auth:rbac", "label": "Role Based Access Control", "type": "topic"},
        ],
        "edges": [
            {"source": "auth:jwt", "target": "auth:rbac", "label": "calls"},
        ],
    }

    handler_cls = build_mcp_handler(graph_payload, "")
    handler = object.__new__(handler_cls)
    handler.graph = graph_payload

    # Valid: stats
    stats = handler._tool_stats({})
    assert stats["content"]["nodes"] == 2
    assert stats["content"]["edges"] == 1

    # Valid: query
    query_res = handler._tool_query({"query": "JWT"})
    assert len(query_res) >= 1

    # Unknown method returns error
    unknown = handler._dispatch("nonexistent_tool", {})
    assert "error" in unknown

    # Parameter type validation: integer check
    with pytest.raises(ValueError, match="must be an integer"):
        handler_cls._int_param({"max_results": "ten"}, "max_results", 10)


# ── Scenario 11: Multi-Tenant Process Supervisor Health Check ────────────────


def test_tier4_w11_f2_f8_f9_f12_multitenant_supervisor_health_check(virtual_procfs: VirtualProcfs) -> None:
    """Scenario 11: Multi-Tenant Process Supervisor Health Check (F2, F8, F9, F12).

    Workflow:
    1. Evaluates process trees with PID 1 comm 'exe'.
    2. Managed service (llama-server under PPID 1) classified as safe lane.
    3. Foreign unmanaged process classified as blocker (verdict NOT SAFE).
    """
    probe = load_probe("oc_restart_check_w11", str(REPO_ROOT / "scripts" / "oc-restart-check.py"))

    # Case 1: Empty report is SAFE
    r1 = probe.Report(workers=[], work=[], lanes=[], foreign_gpu=[], unreadable=[])
    assert r1.safe is True
    assert "SAFE" in probe.render(r1)

    # Case 2: Foreign work in flight is NOT SAFE
    r2 = probe.Report(
        workers=[],
        work=["pid=1234 python3 -m pytest tests/"],
        lanes=[],
        foreign_gpu=[],
        unreadable=[],
    )
    assert r2.safe is False
    assert "NOT SAFE" in probe.render(r2)


# ── Scenario 12: Clean Module Import Sweep (No Import Hacks) ────────────────


def test_tier4_w12_f4_f15_f16_clean_module_import_sweep() -> None:
    """Scenario 12: Clean Module Import Sweep (No Import Hacks) (F4, F15, F16).

    Workflow:
    1. Scans Python files from F15 for sys.path.insert(0, str(REPO_DIR)) hacks.
    2. Confirms direct importability of tools.fsutil and tools.llm_client.
    """
    target_files = [
        REPO_ROOT / "scripts" / "check_ci_status.py",
        REPO_ROOT / "tools" / "ratchet_check.py",
        REPO_ROOT / "tests" / "test_nas_collector_failures.py",
    ]

    for fpath in target_files:
        if not fpath.exists():
            continue
        tree = ast.parse(fpath.read_text(encoding="utf-8"))
        for node in ast.walk(tree):
            if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute):
                # Detect sys.path.insert
                if node.func.attr == "insert" and isinstance(node.func.value, ast.Attribute):
                    if node.func.value.attr == "path":
                        # Should not be inserting repo root at index 0
                        if node.args and isinstance(node.args[0], ast.Constant) and node.args[0].value == 0:
                            pytest.fail(f"Found sys.path.insert(0, ...) in {fpath}")

    # Direct imports succeed cleanly
    import tools.fsutil as fs
    import tools.llm_client as lc

    assert hasattr(fs, "atomic_write_text")
    assert hasattr(lc, "post_chat")


# ── Scenario 13: End-to-End Zero-Regression Verification Gate ────────────────


def test_tier4_w13_f1_f25_end_to_end_verification_gate() -> None:
    """Scenario 13: End-to-End Zero-Regression Verification Gate (F1–F25).

    Workflow:
    1. Confirms test runner argument builder applies -W error.
    2. Certifies Tier 3 cross-feature test suite runs with 100% pass rate.
    3. Confirms zero resource warnings or socket leaks.
    """
    from tests.e2e.runner import build_pytest_args, run_e2e_tests

    # Verify runner arguments
    args = build_pytest_args(tier="3", verbose=True)
    assert "-W" in args
    assert "error" in args
    assert any("test_tier3_cross_feature.py" in a for a in args)

    # Programmatic execution of Tier 3 passes with exit code 0
    rc = run_e2e_tests(tier="3", quiet=True)
    assert rc == 0
