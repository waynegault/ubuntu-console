"""Hardware prober and WSL2 process discovery for box awareness.

Module Version: 1 (2026-11-10)
Provides dynamic detection of host CPU architecture, unified vs discrete memory pools,
effective VRAM headroom calculations, and WSL2-compatible `/proc/*/exe` scanning.
"""

from __future__ import annotations

import os
import platform
import subprocess
from typing import Any

from tools.box.models import Architecture, HardwareProfile
from tools.box.profiles import (
    ASUS_RTX_SPARK_PROFILE,
    DELL_XPS_PROFILE,
    PROFILES,
    get_profile_by_id,
    resolve_profile_override,
)


def probe_arch() -> Architecture:
    """Detect current host CPU architecture."""
    facts = os.getenv("TAC_HOST_FACTS_OVERRIDE", "").strip()
    if facts:
        first = facts.split()[0].lower()
        if first in ("aarch64", "arm64"):
            return Architecture.AARCH64
        if first in ("x86_64", "amd64", "x64"):
            return Architecture.X86_64

    hosttype = os.getenv("HOSTTYPE", "").strip().lower()
    if hosttype in ("aarch64", "arm64"):
        return Architecture.AARCH64
    if hosttype in ("x86_64", "amd64", "x64"):
        return Architecture.X86_64

    machine = platform.machine().lower()
    if machine in ("aarch64", "arm64"):
        return Architecture.AARCH64
    return Architecture.X86_64


def probe_cpu_model() -> str:
    """Detect CPU model string from override, /proc/cpuinfo, or lscpu."""
    override = os.getenv("TAC_HOST_CPU_OVERRIDE", "").strip()
    if override:
        return override

    try:
        with open("/proc/cpuinfo", encoding="utf-8", errors="replace") as fh:
            for line in fh:
                lower = line.lower()
                if lower.startswith("model name") or lower.startswith("hardware"):
                    _, _, val = line.partition(":")
                    cleaned = val.strip()
                    if cleaned:
                        return cleaned
    except OSError:
        pass

    try:
        res = subprocess.run(
            ["lscpu"],
            capture_output=True,
            text=True,
            timeout=3,
            check=False,
        )
        if res.returncode == 0 and res.stdout:
            for line in res.stdout.splitlines():
                if line.lower().startswith("model name:"):
                    return line.partition(":")[2].strip()
    except OSError, subprocess.SubprocessError:
        pass

    return ""


def probe_meminfo() -> dict[str, int]:
    """Read MemTotal and MemAvailable from /proc/meminfo in MiB."""
    out: dict[str, int] = {}
    try:
        with open("/proc/meminfo", encoding="utf-8", errors="replace") as fh:
            for line in fh:
                if line.startswith("MemTotal:"):
                    parts = line.split()
                    if len(parts) >= 2 and parts[1].isdigit():
                        out["total_mb"] = int(parts[1]) // 1024
                elif line.startswith("MemAvailable:"):
                    parts = line.split()
                    if len(parts) >= 2 and parts[1].isdigit():
                        out["available_mb"] = int(parts[1]) // 1024
    except OSError:
        pass
    return out


def probe_gpu_memory_mb() -> tuple[int | None, int | None, int | None]:
    """Query GPU memory (total_mb, used_mb, free_mb) via nvidia-smi."""
    try:
        proc = subprocess.run(
            [
                "nvidia-smi",
                "--query-gpu=memory.total,memory.used,memory.free",
                "--format=csv,noheader,nounits",
            ],
            capture_output=True,
            text=True,
            timeout=5,
            check=False,
        )
        if proc.returncode == 0 and proc.stdout:
            first_line = proc.stdout.strip().splitlines()[0]
            parts = [p.strip() for p in first_line.split(",")]
            if len(parts) >= 3 and all(p.isdigit() for p in parts[:3]):
                return int(parts[0]), int(parts[1]), int(parts[2])
            if len(parts) == 1 and parts[0].isdigit():
                return int(parts[0]), None, None
    except OSError, subprocess.SubprocessError:
        pass
    return None, None, None


def detect_hardware_profile() -> HardwareProfile:
    """Auto-detect the active machine's HardwareProfile."""
    cpu = probe_cpu_model().lower()
    if "cortex-x925" in cpu:
        return ASUS_RTX_SPARK_PROFILE
    if "i9-12900hk" in cpu:
        return DELL_XPS_PROFILE

    arch = probe_arch()
    if arch == Architecture.AARCH64:
        return ASUS_RTX_SPARK_PROFILE
    return DELL_XPS_PROFILE


def get_hardware_profile(override_id: str | None = None) -> HardwareProfile:
    """Resolve the active HardwareProfile via override or hardware auto-detection."""
    target_id = resolve_profile_override(override_id)
    if target_id:
        profile = get_profile_by_id(target_id)
        if profile is None:
            available = ", ".join(sorted(PROFILES.keys()))
            raise ValueError(f"Unknown profile '{target_id}' (available: {available})")
        return profile
    return detect_hardware_profile()


def compute_effective_vram_mb(profile: HardwareProfile | None = None) -> int:
    """Compute effective VRAM ceiling in MiB for the active box profile."""
    prof = profile or get_hardware_profile()
    pool_env = os.getenv("TAC_HOST_GPU_POOL_BYTES", "").strip()
    if pool_env.isdigit() and int(pool_env) > 0:
        return int(pool_env) // (1024 * 1024)

    if prof.is_unified:
        mem = probe_meminfo()
        total_mb = mem.get("total_mb", prof.total_memory_mb)
        # If guest MemTotal reflects unified pool, return profile's total pool or probed ceiling
        return max(total_mb, prof.total_memory_mb)

    gpu_total, _, _ = probe_gpu_memory_mb()
    if gpu_total is not None and gpu_total > 0:
        return gpu_total
    return prof.total_memory_mb


def _read_proc_cmdline(pid: int) -> list[str]:
    try:
        with open(f"/proc/{pid}/cmdline", "rb") as fh:
            raw = fh.read()
        return [arg for arg in raw.decode("utf-8", errors="replace").split("\0") if arg]
    except OSError:
        return []


def _read_proc_comm(pid: int) -> str:
    try:
        with open(f"/proc/{pid}/comm", encoding="utf-8", errors="replace") as fh:
            return fh.read().strip()
    except OSError:
        return ""


def _read_proc_ppid(pid: int) -> int:
    try:
        with open(f"/proc/{pid}/status", encoding="utf-8", errors="replace") as fh:
            for line in fh:
                if line.startswith("PPid:"):
                    parts = line.split()
                    if len(parts) >= 2 and parts[1].isdigit():
                        return int(parts[1])
    except OSError:
        pass
    return 0


def is_pid_systemd_managed(pid: int) -> bool:
    """Determine if a process is managed by systemd or WSL2 init (PID 1)."""
    ppid = _read_proc_ppid(pid)
    if ppid <= 0:
        return False
    try:
        exe = os.readlink(f"/proc/{ppid}/exe")
    except OSError:
        exe = ""
    if os.path.basename(exe) == "systemd":
        return True
    comm = _read_proc_comm(ppid)
    if ppid == 1 and comm in ("systemd", "exe", "init"):
        return True
    return comm == "systemd"


def discover_wsl2_gpu_processes(executable_filter: str = "llama-server") -> list[dict[str, Any]]:
    """Discover GPU compute processes with `/proc/*/exe` fallback for WSL2 unified memory."""
    discovered: list[dict[str, Any]] = []
    seen_pids: set[int] = set()

    # 1. Try nvidia-smi compute apps first
    try:
        proc = subprocess.run(
            ["nvidia-smi", "--query-compute-apps=pid", "--format=csv,noheader"],
            capture_output=True,
            text=True,
            timeout=5,
            check=False,
        )
        if proc.returncode == 0 and proc.stdout:
            for line in proc.stdout.splitlines():
                text = line.strip()
                if text.isdigit():
                    pid = int(text)
                    seen_pids.add(pid)
    except OSError, subprocess.SubprocessError:
        pass

    # 2. Walk /proc/[0-9]*/exe and cmdline (critical on WSL2 unified memory where nvidia-smi returns 0 rows)
    try:
        proc_entries = [int(name) for name in os.listdir("/proc") if name.isdigit()]
    except OSError:
        proc_entries = []

    for pid in sorted(proc_entries):
        if pid in seen_pids:
            continue
        exe = ""
        try:
            exe = os.readlink(f"/proc/{pid}/exe")
        except OSError:
            pass
        if "build-opencl" in exe:
            continue
        comm = _read_proc_comm(pid)
        argv = _read_proc_cmdline(pid)
        matched = False
        if executable_filter:
            if executable_filter in os.path.basename(exe) or executable_filter == comm:
                matched = True
            elif argv and executable_filter in os.path.basename(argv[0]):
                matched = True
        if matched:
            seen_pids.add(pid)

    for pid in sorted(seen_pids):
        exe = ""
        try:
            exe = os.readlink(f"/proc/{pid}/exe")
        except OSError:
            pass
        argv = _read_proc_cmdline(pid)
        comm = _read_proc_comm(pid)
        discovered.append(
            {
                "pid": pid,
                "exe": exe,
                "comm": comm,
                "argv": argv,
                "ppid": _read_proc_ppid(pid),
                "is_systemd_managed": is_pid_systemd_managed(pid),
            }
        )

    return discovered
