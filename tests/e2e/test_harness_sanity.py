"""Sanity test suite verifying hermetic E2E test harness & infrastructure under pytest -W error."""

from __future__ import annotations

import gc
import json
import os
import subprocess
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any
import pytest
from pydantic import BaseModel, Field

from tests.e2e.helpers.assertions import (
    assert_clean_shell_export,
    assert_no_resource_warnings,
    assert_referential_integrity,
    assert_valid_pydantic,
    assert_validation_error,
)
from tests.e2e.helpers.mock_procfs import VirtualProcfs
from tests.e2e.runner import build_pytest_args


# --- Hermetic Sandbox Tests ---


def test_hermetic_sandbox_redirects_all_state_paths(hermetic_sandbox: Path, tmp_path: Path) -> None:
    """Verifies that all state and data paths are isolated inside tmp_path."""
    home_dir = Path(os.environ["HOME"])
    openclaw_dir = Path(os.environ["OPENCLAW_ROOT"])
    state_dir = Path(os.environ["TAC_STATE_DIR"])
    models_dir = Path(os.environ["LLAMA_MODEL_DIR"])

    assert home_dir.is_relative_to(tmp_path)
    assert openclaw_dir.is_relative_to(tmp_path)
    assert state_dir.is_relative_to(tmp_path)
    assert models_dir.is_relative_to(tmp_path)

    # Mutation test: creating files inside sandbox does not affect host
    test_file = home_dir / "canary.txt"
    test_file.write_text("hermetic canary", encoding="utf-8")
    assert test_file.exists()
    assert not Path("/home/wayne/canary.txt").exists()


# --- VirtualProcfs Tests ---


def test_virtual_procfs_pid1_comm_default(virtual_procfs: VirtualProcfs) -> None:
    """Verifies that /proc/1/comm defaults to 'systemd\n'."""
    with open("/proc/1/comm", encoding="utf-8") as fh:
        comm = fh.read()
    assert comm.strip() == "systemd"


def test_virtual_procfs_pid1_comm_customization(virtual_procfs: VirtualProcfs) -> None:
    """Verifies that /proc/1/comm can be dynamically customized to 'init' or 'exe'."""
    virtual_procfs.set_pid_1_comm("init")
    with open("/proc/1/comm", encoding="utf-8") as fh:
        assert fh.read().strip() == "init"

    virtual_procfs.set_pid_1_comm("exe")
    with open("/proc/1/comm", encoding="utf-8") as fh:
        assert fh.read().strip() == "exe"


def test_virtual_procfs_process_cmdline_and_status(virtual_procfs: VirtualProcfs) -> None:
    """Verifies that simulated processes expose null-delimited cmdline and PPid status."""
    virtual_procfs.add_process(
        pid=5555,
        comm="llama-server",
        cmdline=["llama-server", "-m", "qwen.gguf", "--port", "18087"],
        ppid=1,
    )

    # Verify cmdline (binary null-delimited)
    with open("/proc/5555/cmdline", "rb") as fh:
        raw_cmdline = fh.read()
    args = [a for a in raw_cmdline.decode("utf-8").split("\0") if a]
    assert args == ["llama-server", "-m", "qwen.gguf", "--port", "18087"]

    # Verify status (PPid header)
    ppid_found = False
    with open("/proc/5555/status", encoding="utf-8") as fh:
        for line in fh:
            if line.startswith("PPid:"):
                assert int(line.split()[1]) == 1
                ppid_found = True
    assert ppid_found is True


def test_virtual_procfs_readlink_exe_and_cwd(virtual_procfs: VirtualProcfs) -> None:
    """Verifies that os.readlink works for /proc/{pid}/exe and /proc/{pid}/cwd."""
    virtual_procfs.add_process(
        pid=6666,
        exe="/opt/llama/bin/llama-server",
        cwd="/var/run/llama",
    )
    assert os.readlink("/proc/6666/exe") == "/opt/llama/bin/llama-server"
    assert os.readlink("/proc/6666/cwd") == "/var/run/llama"


def test_virtual_procfs_readlink_permission_error_simulation(
    virtual_procfs: VirtualProcfs,
) -> None:
    """Simulates WSL2 user-manager /proc/PID/exe EACCES permission denied."""
    virtual_procfs.add_process(
        pid=568,
        comm="systemd",
        exe_error=PermissionError(13, "Permission denied"),
    )
    with pytest.raises(PermissionError) as exc_info:
        os.readlink("/proc/568/exe")
    assert exc_info.value.errno == 13

    # Fallback: comm is still readable
    with open("/proc/568/comm", encoding="utf-8") as fh:
        assert fh.read().strip() == "systemd"


def test_virtual_procfs_meminfo(virtual_procfs: VirtualProcfs) -> None:
    """Verifies that /proc/meminfo reflects configured memory values."""
    virtual_procfs.set_meminfo(total_kb=131072000, available_kb=120000000)
    totals: dict[str, int] = {}
    with open("/proc/meminfo", encoding="utf-8") as fh:
        for line in fh:
            parts = line.split(":")
            if len(parts) == 2:
                key = parts[0].strip()
                val = int(parts[1].strip().split()[0])
                totals[key] = val

    assert totals["MemTotal"] == 131072000
    assert totals["MemAvailable"] == 120000000


def test_virtual_procfs_cpuinfo(virtual_procfs: VirtualProcfs) -> None:
    """Verifies that /proc/cpuinfo reflects configured CPU model."""
    virtual_procfs.set_cpuinfo("processor\t: 0\nmodel name\t: ARM Cortex-X925\n")
    with open("/proc/cpuinfo", encoding="utf-8") as fh:
        content = fh.read()
    assert "ARM Cortex-X925" in content


def test_virtual_procfs_listdir_proc(virtual_procfs: VirtualProcfs) -> None:
    """Verifies that os.listdir('/proc') includes simulated process IDs."""
    virtual_procfs.add_process(pid=8888)
    entries = os.listdir("/proc")
    assert "8888" in entries
    assert "meminfo" in entries


# --- Mock Hardware Tests ---


def test_profile_spark_emulation(profile_spark: dict[str, Any]) -> None:
    """Verifies Asus RTX Spark hardware emulation facts and environment."""
    assert os.environ["TAC_HOST_PROFILE_ID"] == "asus-n1n-rtx-spark"
    assert os.environ["TAC_HOST_PROFILE_ARCH"] == "aarch64"
    assert os.environ["TAC_HOST_PROFILE_SHARED_MEMORY"] == "1"
    assert os.environ["LLAMA_GPU_LAYERS"] == "999"
    assert os.environ["LLAMA_THREAD_CAP"] == "0"
    assert os.environ["LLM_SERVICE_PORT"] == "18087"

    # Verify subprocess mocking for nvidia-smi
    res = subprocess.run(["nvidia-smi"], capture_output=True, text=True)
    assert res.returncode == 0
    assert "NVIDIA RTX Spark N1X" in res.stdout
    assert "131072MiB" in res.stdout


def test_profile_xps_emulation(profile_xps: dict[str, Any]) -> None:
    """Verifies Dell XPS 15 hardware emulation facts and environment."""
    assert os.environ["TAC_HOST_PROFILE_ID"] == "intel-xe-cuda"
    assert os.environ["TAC_HOST_PROFILE_ARCH"] == "x86_64"
    assert os.environ["TAC_HOST_PROFILE_SHARED_MEMORY"] == "0"
    assert os.environ["LLAMA_GPU_LAYERS"] == "24"
    assert os.environ["LLAMA_THREAD_CAP"] == "6"
    assert os.environ["LLM_SERVICE_PORT"] == "18081"

    # Verify subprocess mocking for nvidia-smi
    res = subprocess.run(["nvidia-smi"], capture_output=True, text=True)
    assert res.returncode == 0
    assert "RTX 3050 Ti" in res.stdout
    assert "4096MiB" in res.stdout


# --- Mock Server & Socket Leak Tests ---


def test_mock_server_lifecycle_and_endpoints(mock_llm_service: Any) -> None:
    """Verifies mock HTTP server serves requests and records history cleanly."""
    base_url = mock_llm_service.url

    # 1. GET /health
    req = urllib.request.Request(f"{base_url}/health")
    with urllib.request.urlopen(req, timeout=5) as resp:
        assert resp.status == 200
        data = json.loads(resp.read().decode("utf-8"))
        assert data["status"] == "ok"

    # 2. GET /v1/models
    req = urllib.request.Request(f"{base_url}/v1/models")
    with urllib.request.urlopen(req, timeout=5) as resp:
        assert resp.status == 200
        data = json.loads(resp.read().decode("utf-8"))
        assert len(data["data"]) >= 1

    # 3. POST /v1/chat/completions
    post_data = json.dumps({"model": "mock-qwen-30b", "messages": [{"role": "user", "content": "hello"}]}).encode(
        "utf-8"
    )
    req = urllib.request.Request(
        f"{base_url}/v1/chat/completions", data=post_data, headers={"Content-Type": "application/json"}
    )
    with urllib.request.urlopen(req, timeout=5) as resp:
        assert resp.status == 200
        data = json.loads(resp.read().decode("utf-8"))
        assert data["choices"][0]["message"]["content"] == "Hermetic mock response for E2E testing."
        assert data["usage"]["total_tokens"] == 20

    assert len(mock_llm_service.requests) == 3


def test_mock_server_zero_socket_leak_under_w_error(mock_llm_service: Any) -> None:
    """Verifies that rapid requests produce zero ResourceWarning under -W error."""
    base_url = mock_llm_service.url

    with assert_no_resource_warnings():
        for _ in range(10):
            req = urllib.request.Request(f"{base_url}/health")
            with urllib.request.urlopen(req, timeout=5) as resp:
                _ = resp.read()
        gc.collect()


def test_mock_server_custom_error_route(mock_llm_service: Any) -> None:
    """Verifies mock HTTP server custom error routes and clean socket handling."""
    mock_llm_service.add_error_route("/v1/simulate-500", status=500, message="Simulated failure")

    req = urllib.request.Request(f"{mock_llm_service.url}/v1/simulate-500")
    with pytest.raises(urllib.error.HTTPError) as exc_info:
        urllib.request.urlopen(req, timeout=5)

    assert exc_info.value.code == 500
    # Explicitly close the HTTPError response to avoid warning
    exc_info.value.close()


# --- Assertion Helpers Tests ---


class _SampleModel(BaseModel):
    id: str = Field(min_length=1)
    port: int = Field(ge=1, le=65535)


def test_assertions_assert_valid_pydantic() -> None:
    """Verifies assert_valid_pydantic validates compliant payloads."""
    inst = assert_valid_pydantic(_SampleModel, {"id": "test-service", "port": 18087})
    assert inst.id == "test-service"
    assert inst.port == 18087


def test_assertions_assert_validation_error() -> None:
    """Verifies assert_validation_error detects schema violations on targeted fields."""
    exc = assert_validation_error(_SampleModel, {"id": "", "port": 18087}, field_name="id")
    assert exc is not None

    exc_port = assert_validation_error(_SampleModel, {"id": "ok", "port": 0}, field_name="port")
    assert exc_port is not None


def test_assertions_assert_referential_integrity() -> None:
    """Verifies assert_referential_integrity checks graph node existence."""
    valid_graph = {
        "nodes": [{"id": "n1"}, {"id": "n2"}],
        "edges": [{"source": "n1", "target": "n2"}],
    }
    assert_referential_integrity(valid_graph)

    invalid_graph = {
        "nodes": [{"id": "n1"}],
        "edges": [{"source": "n1", "target": "n_missing"}],
    }
    with pytest.raises(AssertionError, match="Referential integrity violation"):
        assert_referential_integrity(invalid_graph)


def test_assertions_assert_clean_shell_export() -> None:
    """Verifies assert_clean_shell_export parses valid shell exports and rejects invalid syntax."""
    valid_shell = (
        'export TAC_HOST_PROFILE_ID="asus-n1n-rtx-spark"\n'
        "export LLAMA_GPU_LAYERS=999\n"
        'export LLM_SERVICE_PORT="18087"\n'
    )
    env = assert_clean_shell_export(valid_shell)
    assert env["TAC_HOST_PROFILE_ID"] == "asus-n1n-rtx-spark"
    assert env["LLAMA_GPU_LAYERS"] == "999"
    assert env["LLM_SERVICE_PORT"] == "18087"

    with pytest.raises(AssertionError, match="does not start with 'export '"):
        assert_clean_shell_export("INVALID_ASSIGNMENT=123")


# --- Runner Argument Tests ---


def test_runner_build_pytest_args() -> None:
    """Verifies runner argument builder produces compliant pytest options."""
    args_all = build_pytest_args(tier="all", feature="F7", verbose=True)
    assert "-W" in args_all and "error" in args_all
    assert "-v" in args_all
    assert "-k" in args_all
    assert "f7 or F7" in args_all

    args_tier1 = build_pytest_args(tier="1", durations=5)
    assert "--durations=5" in args_tier1


# --- Additional Fixture Sanity Tests ---


def test_isolated_graph_db_fixture(isolated_graph_db: Path) -> None:
    """Verifies isolated_graph_db fixture provides a clean temporary JSON file."""
    assert isolated_graph_db.exists()
    content = json.loads(isolated_graph_db.read_text(encoding="utf-8"))
    assert content == {"nodes": [], "edges": [], "meta": {}}


def test_mock_venv_tree_fixture(mock_venv_tree: Path) -> None:
    """Verifies mock_venv_tree fixture provides executable python3 binary."""
    python_bin = mock_venv_tree / "bin" / "python3"
    assert python_bin.exists()
    assert os.access(str(python_bin), os.X_OK)
    res = subprocess.run([str(python_bin)], capture_output=True)
    assert res.returncode == 0
