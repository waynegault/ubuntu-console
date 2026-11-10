"""Mock hardware emulators for Asus RTX Spark (128GB unified) and Dell XPS 15 (4GB discrete).

Provides:
- Complete authoritative profile definitions matching PROJECT.md interface contracts
- Environment variable injection
- Virtual procfs integration (/proc/cpuinfo, /proc/meminfo)
- Mock subprocess execution for nvidia-smi, lscpu
"""

from __future__ import annotations

import os
import subprocess
from contextlib import contextmanager
from typing import Any, Generator
from tests.e2e.helpers.mock_procfs import VirtualProcfs

ASUS_SPARK_PROFILE: dict[str, Any] = {
    "profile_id": "asus-n1n-rtx-spark",
    "description": "Asus RTX Spark N1X with 128GB Unified Memory under WSL2",
    "arch": "aarch64",
    "cpu_model": "ARM Cortex-X925",
    "has_cuda": True,
    "has_xe_igpu": False,
    "memory_type": "unified",
    "total_system_memory_mb": 131072,
    "gpu_pool_bytes_fallback": 137438953472,  # 128 GiB
    "model_store_path": "/home/wayne/models",
    "model_store_is_mount": False,
    "serving_policy": {
        "default_ctx_size": 131072,
        "max_ctx_size": 262144,
        "batch_size": 2048,
        "ubatch_size": 512,
        "parallel_slots": 4,
        "cpu_threads_base": 10,
        "thread_cap": 0,  # unconstrained
        "ngl_strategy": "full_only",
        "fit_target_mb": 1024,
        "cache_ram_mb": 0,
        "keep_reserve_mb": 12288,  # 12 GiB host reserve
        "primary_port": 18087,
        "gpu_layers": 999,
    },
    "lanes": [
        {
            "unit_name": "llama-cuda-qwen3coder-30b-chat.service",
            "port": 18087,
            "is_primary": True,
            "is_protected": False,
        },
        {
            "unit_name": "llama-cuda-qwen3embedding-embed.service",
            "port": 18080,
            "is_primary": False,
            "is_protected": True,
        },
    ],
    "env": {
        "TAC_HOST_PROFILE_ID": "asus-n1n-rtx-spark",
        "TAC_HOST_PROFILE_ARCH": "aarch64",
        "TAC_HOST_PROFILE_SHARED_MEMORY": "1",
        "LLAMA_GPU_LAYERS": "999",
        "LLAMA_THREAD_CAP": "0",
        "LLM_SERVICE_PORT": "18087",
        "LLAMA_FIT_KEEP_RESERVE_MB": "12288",
        "TAC_HOST_PRIMARY_LANE": "llama-cuda-qwen3coder-30b-chat.service",
        "LLM_HOST_PROFILE": "asus-n1n-rtx-spark",
    },
    "cpuinfo": (
        "processor\t: 0\n"
        "model name\t: ARM Cortex-X925\n"
        "BogoMIPS\t: 200.00\n"
        "Features\t: fp asimd evtstrm aes pmull sha1 sha2 crc32 atomics\n"
        "CPU architecture: 8\n"
        "CPU variant\t: 0x0\n"
        "CPU part\t: 0xd4f\n"
        "CPU revision\t: 0\n"
    ),
    "meminfo_kb": {
        "total": 131072000,
        "available": 120000000,
        "free": 115000000,
    },
    "nvidia_smi_output": (
        "Sat Nov 10 12:00:00 2026\n"
        "+-----------------------------------------------------------------------------------------+\n"
        "| NVIDIA-SMI 570.86.15              Driver Version: 570.86.15      CUDA Version: 12.8     |\n"
        "|-----------------------------------------+------------------------+----------------------+\n"
        "| GPU  Name                 Persistence-M | Bus-Id          Disp.A | Volatile Uncorr. ECC |\n"
        "| Fan  Temp   Perf          Pwr:Usage/Cap |           Memory-Usage | GPU-Util  Compute M. |\n"
        "|                                         |                        |               MIG M. |\n"
        "|=========================================+========================+======================|\n"
        "|   0  NVIDIA RTX Spark N1X           On  |   00000000:01:00.0 Off |                  N/A |\n"
        "| N/A   45C    P0             25W /  120W |    4096MiB / 131072MiB |      5%      Default |\n"
        "+-----------------------------------------+------------------------+----------------------+\n"
    ),
}

DELL_XPS_PROFILE: dict[str, Any] = {
    "profile_id": "intel-xe-cuda",
    "description": "Dell XPS 15 9520 (Intel i9-12900HK + RTX 3050 Ti 4GB Discrete CUDA)",
    "arch": "x86_64",
    "cpu_model": "Intel(R) Core(TM) i9-12900HK",
    "has_cuda": True,
    "has_xe_igpu": True,
    "memory_type": "discrete",
    "total_system_memory_mb": 4096,  # 4 GB VRAM ceiling
    "gpu_pool_bytes_fallback": 4294967296,  # 4 GiB
    "model_store_path": "/mnt/m",
    "model_store_is_mount": True,
    "serving_policy": {
        "default_ctx_size": 16384,
        "max_ctx_size": 21504,
        "batch_size": 512,
        "ubatch_size": 256,
        "parallel_slots": 1,
        "cpu_threads_base": 6,
        "thread_cap": 6,  # P-core ceiling
        "ngl_strategy": "binary",
        "fit_target_mb": 1024,
        "cache_ram_mb": 0,
        "keep_reserve_mb": 1024,
        "primary_port": 18081,
        "gpu_layers": 24,
    },
    "lanes": [
        {
            "unit_name": "llama-xe-minicpm5-1b-chat.service",
            "port": 18081,
            "is_primary": True,
            "is_protected": False,
        },
        {
            "unit_name": "llama-xe-embeddinggemma-embed.service",
            "port": 18080,
            "is_primary": False,
            "is_protected": True,
        },
        {
            "unit_name": "llama-xe-llama32-3b-chat.service",
            "port": 18085,
            "is_primary": False,
            "is_protected": False,
        },
        {
            "unit_name": "llama-cuda-llama32-3b-chat.service",
            "port": 18083,
            "is_primary": False,
            "is_protected": False,
        },
        {
            "unit_name": "llama-cpu-qwen25-3b-chat.service",
            "port": 18084,
            "is_primary": False,
            "is_protected": False,
        },
    ],
    "env": {
        "TAC_HOST_PROFILE_ID": "intel-xe-cuda",
        "TAC_HOST_PROFILE_ARCH": "x86_64",
        "TAC_HOST_PROFILE_SHARED_MEMORY": "0",
        "LLAMA_GPU_LAYERS": "24",
        "LLAMA_THREAD_CAP": "6",
        "LLM_SERVICE_PORT": "18081",
        "LLAMA_FIT_KEEP_RESERVE_MB": "1024",
        "TAC_HOST_PRIMARY_LANE": "llama-xe-minicpm5-1b-chat.service",
        "LLM_HOST_PROFILE": "intel-xe-cuda",
    },
    "cpuinfo": (
        "processor\t: 0\n"
        "vendor_id\t: GenuineIntel\n"
        "cpu family\t: 6\n"
        "model\t\t: 154\n"
        "model name\t: 12th Gen Intel(R) Core(TM) i9-12900HK\n"
        "stepping\t: 3\n"
        "cpu MHz\t\t: 2500.000\n"
        "cache size\t: 24576 KB\n"
    ),
    "meminfo_kb": {
        "total": 32768000,
        "available": 20000000,
        "free": 18000000,
    },
    "nvidia_smi_output": (
        "Sat Nov 10 12:00:00 2026\n"
        "+-----------------------------------------------------------------------------------------+\n"
        "| NVIDIA-SMI 555.42.02              Driver Version: 555.42.02      CUDA Version: 12.5     |\n"
        "|-----------------------------------------+------------------------+----------------------+\n"
        "| GPU  Name                 Persistence-M | Bus-Id          Disp.A | Volatile Uncorr. ECC |\n"
        "| Fan  Temp   Perf          Pwr:Usage/Cap |           Memory-Usage | GPU-Util  Compute M. |\n"
        "|                                         |                        |               MIG M. |\n"
        "|=========================================+========================+======================|\n"
        "|   0  NVIDIA GeForce RTX 3050 Ti ... On  |   00000000:01:00.0 Off |                  N/A |\n"
        "| N/A   52C    P0             18W /   45W |     512MiB /  4096MiB |      0%      Default |\n"
        "+-----------------------------------------+------------------------+----------------------+\n"
    ),
}


class MockHardwareEmulator:
    """Emulates Asus RTX Spark or Dell XPS 15 hardware facts."""

    def __init__(
        self,
        profile: dict[str, Any],
        procfs: VirtualProcfs | None = None,
        monkeypatch: Any | None = None,
    ) -> None:
        self.profile = profile
        self.procfs = procfs
        self.monkeypatch = monkeypatch
        self._saved_env: dict[str, str | None] = {}
        self._orig_subprocess_run = subprocess.run

    def start(self) -> MockHardwareEmulator:
        # 1. Inject environment variables
        for k, v in self.profile["env"].items():
            self._saved_env[k] = os.environ.get(k)
            os.environ[k] = str(v)

        # 2. Update VirtualProcfs if provided
        if self.procfs is not None:
            self.procfs.set_cpuinfo(self.profile["cpuinfo"])
            mem = self.profile["meminfo_kb"]
            self.procfs.set_meminfo(
                total_kb=mem["total"],
                available_kb=mem["available"],
                free_kb=mem["free"],
            )

        # 3. Intercept subprocess calls for nvidia-smi / lscpu
        smi_out = self.profile["nvidia_smi_output"]
        arch = self.profile["arch"]
        cpu_model = self.profile["cpu_model"]

        def _mock_run(args: Any, **kwargs: Any) -> subprocess.CompletedProcess[Any]:
            cmd_str = " ".join(str(a) for a in args) if isinstance(args, (list, tuple)) else str(args)

            if "nvidia-smi" in cmd_str:
                return subprocess.CompletedProcess(
                    args=args,
                    returncode=0,
                    stdout=smi_out if kwargs.get("text") else smi_out.encode("utf-8"),
                    stderr="" if kwargs.get("text") else b"",
                )

            if "lscpu" in cmd_str:
                out = f"Architecture:\t{arch}\nModel name:\t{cpu_model}\n"
                return subprocess.CompletedProcess(
                    args=args,
                    returncode=0,
                    stdout=out if kwargs.get("text") else out.encode("utf-8"),
                    stderr="" if kwargs.get("text") else b"",
                )

            return self._orig_subprocess_run(args, **kwargs)

        if self.monkeypatch is not None:
            self.monkeypatch.setattr(subprocess, "run", _mock_run)
        else:
            subprocess.run = _mock_run  # type: ignore

        return self

    def stop(self) -> None:
        # Restore environment
        for k, v in self._saved_env.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
        self._saved_env.clear()

        # Restore subprocess.run
        if self.monkeypatch is None:
            subprocess.run = self._orig_subprocess_run  # type: ignore

    def __enter__(self) -> MockHardwareEmulator:
        return self.start()

    def __exit__(self, exc_type: Any, exc_val: Any, exc_tb: Any) -> None:
        self.stop()


@contextmanager
def emulate_asus_spark(
    procfs: VirtualProcfs | None = None,
    monkeypatch: Any | None = None,
) -> Generator[dict[str, Any], None, None]:
    """Context manager emulating Asus RTX Spark (128GB unified)."""
    emulator = MockHardwareEmulator(ASUS_SPARK_PROFILE, procfs=procfs, monkeypatch=monkeypatch)
    with emulator:
        yield ASUS_SPARK_PROFILE


@contextmanager
def emulate_dell_xps(
    procfs: VirtualProcfs | None = None,
    monkeypatch: Any | None = None,
) -> Generator[dict[str, Any], None, None]:
    """Context manager emulating Dell XPS 15 (4GB discrete VRAM)."""
    emulator = MockHardwareEmulator(DELL_XPS_PROFILE, procfs=procfs, monkeypatch=monkeypatch)
    with emulator:
        yield DELL_XPS_PROFILE
