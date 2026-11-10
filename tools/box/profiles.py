"""Target hardware profile definitions for the repository.

Module Version: 1 (2026-11-10)
Declares static profile definitions for:
- Asus ProArt P16 / RTX Spark N1X (128GB unified memory)
- Dell XPS 15 (Intel i9 / 4GB discrete CUDA)
"""

from __future__ import annotations

import os
from pathlib import Path

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

# ── Asus ProArt P16 / RTX Spark N1X Profile (128GB Unified) ───────────────────
ASUS_RTX_SPARK_PROFILE = HardwareProfile(
    id="asus-n1n-rtx-spark",
    description="ASUS ProArt P16 arm64 / RTX Spark N1X (Blackwell, compute 12.1), CUDA (WSL2 aarch64)",
    arch=Architecture.AARCH64,
    cpu_model_pattern="Cortex-X925",
    has_cuda=True,
    has_xe_igpu=False,
    memory_arch=MemoryArchitecture.UNIFIED,
    total_memory_mb=131072,  # 128 GB Unified LPDDR5X
    gpu_pool_bytes_fallback=0,  # Never guess: query card or keep 0
    model_store_path="$HOME/models",
    model_store_is_mount=False,
    serving=ServingParameters(
        gpu_layers=999,
        context_window=131072,
        max_context_window=262144,
        parallel_slots=4,
        batch_size=2048,
        ubatch_size=512,
        thread_cap=0,  # Homogeneous ARM cores; no ceiling
        threads_base=10,  # Matches the 10 Cortex-X925 performance cores
        primary_port=18087,
        min_host_reserve_mb=12288,  # 12 GB reserve to protect WSL VM stability
        fit_target_mb=1024,
        cache_ram_mb=0,
        ngl_strategy="full_only",
    ),
    quant_policy=QuantPolicy(
        guide_rel_path="config/hosts.d/asus-rtx-spark-quant-guide.conf",
        recommended=["Q8_0", "Q6_K", "Q5_K_M", "F16"],
        acceptable=[
            "Q4_K_M",
            "Q4_K_S",
            "Q3_K_M",
            "Q3_K_L",
            "IQ3_M",
            "IQ3_XXS",
        ],
        discouraged=["Q2_K", "Q3_K_S", "F32", "BF16"],
        rules=[
            QuantRule(
                pattern="Q8_0",
                rating=QuantRating.RECOMMENDED,
                description="8-bit: Near-lossless quality with high throughput on unified memory",
            ),
            QuantRule(
                pattern="Q6_K",
                rating=QuantRating.RECOMMENDED,
                description="6-bit K-quant: Optimal quality/size trade-off for 30B-70B models",
            ),
            QuantRule(
                pattern="Q5_K_M",
                rating=QuantRating.RECOMMENDED,
                description="5-bit K-quant: Fast execution with negligible degradation",
            ),
            QuantRule(
                pattern="F16",
                rating=QuantRating.RECOMMENDED,
                description="Full half-precision: Ideal for embeddings and <14B models",
            ),
            QuantRule(
                pattern="Q4_K_M",
                rating=QuantRating.ACCEPTABLE,
                description="4-bit: Usable when conserving memory for massive contexts or 70B+ models",
            ),
            QuantRule(
                pattern="Q2_K",
                rating=QuantRating.DISCOURAGED,
                description="2-bit: Unnecessary quality degradation on 128GB unified memory",
            ),
            QuantRule(
                pattern="Q3_K_S",
                rating=QuantRating.DISCOURAGED,
                description="Low quality 3-bit quantization unnecessary on 128GB unified memory",
            ),
            QuantRule(
                pattern="F32",
                rating=QuantRating.DISCOURAGED,
                description="Double memory usage with zero inference benefit",
            ),
            QuantRule(
                pattern="BF16",
                rating=QuantRating.DISCOURAGED,
                description="Inefficient quantization representation for ggml",
            ),
        ],
    ),
    ports=PortAllocation(
        primary_port=18087,
        lanes=[
            LaneSpec(
                unit_name="llama-cuda-qwen3coder-30b-chat.service",
                port=18087,
                is_primary=True,
                is_protected=False,
                is_gated=True,
                description="Primary chat lane (Qwen3-Coder-30B)",
            ),
            LaneSpec(
                unit_name="llama-cuda-qwen3embedding-embed.service",
                port=18080,
                is_primary=False,
                is_protected=True,
                is_gated=False,
                description="Always-on embeddings lane (Qwen3-Embedding-0.6B)",
            ),
        ],
    ),
    gpu_label="RTX Spark N1X",
    igpu_label=None,
    cuda_arch="121a-real",
    cuda_fa_quants="all",
    build_dir="$HOME/llama.cpp/build-cuda",
    server_bin="$HOME/llama.cpp/build-cuda/bin/llama-server",
    autotune_census="llama-cuda-qwen3embedding-embed.service",
    autotune_census_max_mib=6144,
    autotune_baseline_gap_max=3500,
    gpu_free_threshold_mib=3500,
    model_dir="$HOME/models/active",
    archive_dir="$HOME/models/archived",
    hf_home="$HOME/models/active",
    hf_hub_cache="$HOME/models/active",
    registry_path="$HOME/models/active/models.conf",
    state_dir="$HOME/models/.llm",
)


# ── Dell XPS 15 Profile (Intel i9 / 4GB CUDA) ─────────────────────────────────
DELL_XPS_PROFILE = HardwareProfile(
    id="intel-xe-cuda",
    description="Intel i9 / Iris Xe iGPU / RTX 3050 Ti 4 GB (WSL2 x86_64)",
    arch=Architecture.X86_64,
    cpu_model_pattern="i9-12900HK",
    has_cuda=True,
    has_xe_igpu=True,
    memory_arch=MemoryArchitecture.DISCRETE,
    total_memory_mb=4096,  # 4 GB Discrete VRAM
    gpu_pool_bytes_fallback=4294967296,
    model_store_path="/mnt/m",
    model_store_is_mount=True,
    serving=ServingParameters(
        gpu_layers=24,
        context_window=20480,
        max_context_window=21504,
        parallel_slots=1,
        batch_size=512,
        ubatch_size=256,
        thread_cap=6,  # Hybrid core ceiling: stops spillover onto E-cores
        threads_base=6,  # 6 Intel P-cores
        primary_port=18081,
        min_host_reserve_mb=1024,
        fit_target_mb=1024,
        cache_ram_mb=0,
        ngl_strategy="ladder",
    ),
    quant_policy=QuantPolicy(
        guide_rel_path="config/quant-guide.conf",
        recommended=["Q4_K_M", "Q4_K_S"],
        acceptable=[
            "Q3_K_M",
            "Q3_K_L",
            "Q3_K_S",
            "Q5_K_M",
            "Q5_K_S",
            "Q2_K",
            "IQ3_M",
            "IQ3_XXS",
            "IQ2_XS",
            "IQ2_XXS",
            "Q8_0",
            "F16",
        ],
        discouraged=["Q6_K", "F32", "BF16"],
        rules=[
            QuantRule(
                pattern="Q4_K_M",
                rating=QuantRating.RECOMMENDED,
                description="Best all-round: quality + speed + GPU fit for 4GB VRAM",
            ),
            QuantRule(
                pattern="Q4_K_S",
                rating=QuantRating.RECOMMENDED,
                description="Slightly smaller Q4, good alternative",
            ),
            QuantRule(
                pattern="Q6_K",
                rating=QuantRating.DISCOURAGED,
                description="Too large for 4GB: forces heavy CPU fallback and slow inference",
            ),
            QuantRule(
                pattern="F32",
                rating=QuantRating.DISCOURAGED,
                description="Double precision: 28GB+, never useful for inference",
            ),
            QuantRule(
                pattern="BF16",
                rating=QuantRating.DISCOURAGED,
                description="Brain float 16: CPU-only on this card",
            ),
        ],
    ),
    ports=PortAllocation(
        primary_port=18081,
        lanes=[
            LaneSpec(
                unit_name="llama-xe-minicpm5-1b-chat.service",
                port=18081,
                is_primary=True,
                is_protected=False,
                is_gated=False,
                description="Xe MiniCPM production chat lane",
            ),
            LaneSpec(
                unit_name="llama-xe-embeddinggemma-embed.service",
                port=18080,
                is_primary=False,
                is_protected=False,
                is_gated=False,
                description="Xe embedding lane",
            ),
            LaneSpec(
                unit_name="llama-xe-llama32-3b-chat.service",
                port=18085,
                is_primary=False,
                is_protected=False,
                is_gated=False,
                description="Xe Llama 3.2 3B chat lane",
            ),
            LaneSpec(
                unit_name="llama-cuda-llama32-3b-chat.service",
                port=18083,
                is_primary=False,
                is_protected=False,
                is_gated=True,
                description="CUDA Llama 3.2 3B chat lane (gated/suspendable)",
            ),
            LaneSpec(
                unit_name="llama-cpu-qwen25-3b-chat.service",
                port=18084,
                is_primary=False,
                is_protected=False,
                is_gated=False,
                description="CPU Qwen 2.5 3B chat lane",
            ),
        ],
    ),
    gpu_label="RTX 3050 Ti",
    igpu_label="Intel Xe",
    cuda_arch="86",
    autotune_baseline_gap_max=3500,
)

# Registry of all shipped profiles keyed by profile id
PROFILES: dict[str, HardwareProfile] = {
    ASUS_RTX_SPARK_PROFILE.id: ASUS_RTX_SPARK_PROFILE,
    DELL_XPS_PROFILE.id: DELL_XPS_PROFILE,
}


def get_profile_by_id(profile_id: str) -> HardwareProfile | None:
    """Look up a hardware profile by identifier."""
    return PROFILES.get(profile_id)


def list_profiles() -> list[HardwareProfile]:
    """Return all declared hardware profiles."""
    return list(PROFILES.values())


def resolve_profile_override(override_id: str | None = None) -> str | None:
    """Resolve explicit profile override according to priority rules:

    1. Explicit function argument
    2. LLM_HOST_PROFILE or TAC_HOST_PROFILE_ID or TAC_HOST_PROFILE environment variable
    3. TAC_HOST_PROFILE_FILE or ~/.llm/host-profile configuration file
    """
    if override_id and override_id.strip():
        return override_id.strip()

    for env_key in ("LLM_HOST_PROFILE", "TAC_HOST_PROFILE_ID", "TAC_HOST_PROFILE"):
        env_val = os.getenv(env_key)
        if env_val and env_val.strip() and env_val.strip() != "generic":
            return env_val.strip()

    profile_file_env = os.getenv("TAC_HOST_PROFILE_FILE")
    config_path = Path(profile_file_env) if profile_file_env else (Path.home() / ".llm" / "host-profile")
    if config_path.is_file():
        try:
            for line in config_path.read_text(encoding="utf-8").splitlines():
                line = line.split("#")[0].strip()
                if line:
                    return line
        except OSError:
            pass

    return None


def resolve_profile(override_id: str | None = None) -> HardwareProfile:
    """Resolve hardware profile via override or raise ValueError if unknown."""
    target_id = resolve_profile_override(override_id)
    if target_id:
        profile = get_profile_by_id(target_id)
        if profile is None:
            available = ", ".join(sorted(PROFILES.keys()))
            raise ValueError(f"Unknown profile '{target_id}' (available: {available})")
        return profile

    return ASUS_RTX_SPARK_PROFILE
