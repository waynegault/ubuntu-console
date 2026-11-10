"""Unified Box Awareness and Hardware Profiling Subsystem.

Module Version: 1 (2026-11-10)
Provides the single source of truth for hardware profiling, resource limits,
and serving parameters across the repository.
"""

from __future__ import annotations

from tools.box.cli import format_shell_exports, query_profile_value
from tools.box.models import (
    Architecture,
    HardwareProfile,
    LaneSpec,
    MemoryArchitecture,
    PortAllocation,
    QuantPolicy,
    QuantRating,
    QuantRule,
    ServingParameters,
)
from tools.box.prober import (
    compute_effective_vram_mb,
    detect_hardware_profile,
    discover_wsl2_gpu_processes,
    get_hardware_profile,
    is_pid_systemd_managed,
    probe_arch,
    probe_cpu_model,
    probe_gpu_memory_mb,
    probe_meminfo,
)
from tools.box.profiles import (
    ASUS_RTX_SPARK_PROFILE,
    DELL_XPS_PROFILE,
    PROFILES,
    get_profile_by_id,
    list_profiles,
    resolve_profile,
    resolve_profile_override,
)

__all__ = [
    # Models
    "Architecture",
    "HardwareProfile",
    "LaneSpec",
    "MemoryArchitecture",
    "PortAllocation",
    "QuantPolicy",
    "QuantRating",
    "QuantRule",
    "ServingParameters",
    # Profiles & Helpers
    "ASUS_RTX_SPARK_PROFILE",
    "DELL_XPS_PROFILE",
    "PROFILES",
    "get_profile_by_id",
    "list_profiles",
    "resolve_profile",
    "resolve_profile_override",
    # Prober & Detection API
    "compute_effective_vram_mb",
    "detect_hardware_profile",
    "discover_wsl2_gpu_processes",
    "get_hardware_profile",
    "is_pid_systemd_managed",
    "probe_arch",
    "probe_cpu_model",
    "probe_gpu_memory_mb",
    "probe_meminfo",
    # CLI Helpers
    "format_shell_exports",
    "query_profile_value",
]
