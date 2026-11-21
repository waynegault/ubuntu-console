"""Target hardware profile definitions for the repository.

Module Version: 5 (2026-11-21)
Declares profile definitions for:
- Asus ProArt P16 / RTX Spark N1X (128GB unified memory)
- Dell XPS 15 (Intel i9 / 4GB discrete CUDA)

v5 (2026-11-21): resolve_profile() delegates to prober.detect_hardware_profile() when no
    override is configured instead of hardcoding ASUS_RTX_SPARK_PROFILE.
v4 (2026-11-18): add IQ4_XS and Q4_0 to ASUS_RTX_SPARK_PROFILE.quant_policy acceptable
    quants (matching config/hosts.d/asus-rtx-spark-quant-guide.conf for NVIDIA RTX Spark
    recipes and sidecar MTP draft models).
v3 (2026-11-18): the facts a box's own conf declares are READ FROM IT, not restated here.
    v2 had to re-sync the ASUS census and its :18089 measure lane BY HAND because this file
    held a second copy, and nothing compared the two.  Every scalar below that the conf
    declares (ports, thread cap, layers, thresholds, census, archive/registry/state paths,
    GPU label, CUDA arch/flavour, baseline model) and the whole lane table now come from
    `tools.box.conf_facts`, which sources `config/hosts.d/<id>.conf` with a clean
    environment.  What stays literal is what a conf does not declare: architecture,
    memory model, context windows, batch sizes, min host reserve and the linguistic
    descriptions of each lane.  `tests/test_box_awareness.py` keeps a parity case so a future
    conf edit that this file cannot follow is a failing test, not silent drift.
v2 (2026-11-18): sync ASUS_RTX_SPARK_PROFILE autotune_census, measure lane (18089),
and baseline_model (both boxes) with config/hosts.d/*.conf.
"""

from __future__ import annotations

import os
from pathlib import Path

from tools.box.conf_facts import facts as _conf_facts
from tools.box.conf_facts import lane_specs as _conf_lane_specs
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

_ASUS = _conf_facts("asus-n1n-rtx-spark")
_XPS = _conf_facts("intel-xe-cuda")


def _num(f: dict[str, str], key: str, default: int) -> int:
    """A declared integer, or `default` when the conf does not state the fact."""
    raw = f.get(key, "").strip()
    return int(raw) if raw.lstrip("-").isdigit() else default


def _txt(f: dict[str, str], key: str, default: str | None = None) -> str | None:
    """A declared string, or `default` (an empty conf value counts as undeclared)."""
    value = f.get(key, "").strip()
    return value or default


# Prose only: a lane's meaning for a reader.  The conf owns the fact (unit, port, whether
# it is primary/gated/protected); this map owns the English.
_LANE_DESCRIPTIONS = {
    "llama-cuda-qwen3coder-30b-chat.service": "Primary chat lane (Qwen3-Coder-30B)",
    "llama-cuda-qwen3embedding-embed.service": "Always-on embeddings lane (Qwen3-Embedding-0.6B)",
    "llama-cuda-qwen25-3b-measure.service": "Measurement lane (Qwen2.5 3B)",
    "llama-xe-minicpm5-1b-chat.service": "Xe MiniCPM production chat lane",
    "llama-xe-embeddinggemma-embed.service": "Xe embedding lane",
    "llama-xe-llama32-3b-chat.service": "Xe Llama 3.2 3B chat lane",
    "llama-cuda-llama32-3b-chat.service": "CUDA Llama 3.2 3B chat lane (gated/suspendable)",
    "llama-cpu-qwen25-3b-chat.service": "CPU Qwen 2.5 3B chat lane",
}


def _lanes(profile_id: str, f: dict[str, str]) -> list[LaneSpec]:
    """The conf's lane table, with the three flags derived from the same conf.

    A lane is GATED when it is a CUDA lane that is not protected: the CUDA family is what a
    sweep suspends, and the always-on embedding lane sits in that family but is protected
    from a VRAM drain (measured shape on both boxes, 2026-11-18).
    """
    primary = f.get("TAC_HOST_PRIMARY_LANE", "").strip()
    protected = set(f.get("LLAMA_LANE_KEEP_UNITS", "").split())
    out: list[LaneSpec] = []
    for unit, port in _conf_lane_specs(profile_id):
        out.append(
            LaneSpec(
                unit_name=unit,
                port=port,
                is_primary=unit == primary,
                is_protected=unit in protected,
                is_gated=unit.startswith("llama-cuda-") and unit not in protected,
                description=_LANE_DESCRIPTIONS.get(unit, ""),
            )
        )
    return out


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
        gpu_layers=_num(_ASUS, "LLAMA_GPU_LAYERS", 999),
        context_window=131072,
        max_context_window=262144,
        parallel_slots=4,
        batch_size=2048,
        ubatch_size=512,
        thread_cap=_num(_ASUS, "LLAMA_THREAD_CAP", 0),  # 0 = no ceiling (homogeneous X925)
        threads_base=10,  # Matches the 10 Cortex-X925 performance cores
        primary_port=_num(_ASUS, "LLM_SERVICE_PORT", 18087),
        min_host_reserve_mb=12288,  # 12 GB reserve to protect WSL VM stability
        fit_target_mb=_num(_ASUS, "LLAMA_FIT_TARGET_MB", 1024),
        cache_ram_mb=_num(_ASUS, "LLAMA_CACHE_RAM_MB", 0),
        ngl_strategy="full_only",
    ),
    quant_policy=QuantPolicy(
        guide_rel_path="config/hosts.d/asus-rtx-spark-quant-guide.conf",
        recommended=["Q8_0", "Q6_K", "Q5_K_M", "F16"],
        acceptable=[
            "Q4_K_M",
            "Q4_K_S",
            "IQ4_XS",
            "Q4_0",
            "Q3_K_M",
            "Q3_K_L",
            "IQ3_M",
            "IQ3_XXS",
            "NVFP4",
            "Q2_K",
        ],
        discouraged=["Q3_K_S", "F32", "BF16"],
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
                pattern="IQ4_XS",
                rating=QuantRating.ACCEPTABLE,
                description="iQuant Q4 extra-small: Balanced 4-bit quantization used in NVIDIA RTX Spark recipes",
            ),
            QuantRule(
                pattern="Q4_0",
                rating=QuantRating.ACCEPTABLE,
                description="4-bit legacy: Used for sidecar MTP draft models and fast 4-bit inference",
            ),
            QuantRule(
                pattern="NVFP4",
                rating=QuantRating.ACCEPTABLE,
                description="4-bit float (ModelOpt): 4-bit-class size, scored with the other 4-bit quants",
            ),
            QuantRule(
                pattern="Q2_K",
                rating=QuantRating.ACCEPTABLE,
                description="2-bit: accepted for the 74B row, where no larger quant fits",
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
        primary_port=_num(_ASUS, "LLM_SERVICE_PORT", 18087),
        lanes=_lanes("asus-n1n-rtx-spark", _ASUS),
    ),
    gpu_label=_txt(_ASUS, "TAC_HOST_GPU_LABEL") or "RTX Spark N1X",
    igpu_label=None,
    cuda_arch=_txt(_ASUS, "LLAMA_CUDA_ARCH", "121a-real"),
    cuda_fa_quants=_txt(_ASUS, "LLAMA_CUDA_FA_QUANTS", "all"),
    build_dir=_txt(_ASUS, "LLAMA_BUILD_DIR", "$HOME/llama.cpp/build-cuda"),
    server_bin=_txt(_ASUS, "LLAMA_CUDA_SERVER_BIN", "$HOME/llama.cpp/build-cuda/bin/llama-server"),
    autotune_census=_txt(_ASUS, "LLM_AUTOTUNE_CENSUS", ""),
    autotune_census_max_mib=_num(_ASUS, "LLM_AUTOTUNE_CENSUS_MAX_MIB", 6144),
    autotune_baseline_gap_max=_num(_ASUS, "LLM_AUTOTUNE_BASELINE_GAP_MAX", 3500),
    gpu_free_threshold_mib=_num(_ASUS, "LLAMA_GPU_FREE_THRESHOLD_MIB", 3500),
    model_dir=_txt(_ASUS, "LLAMA_MODEL_DIR", "$HOME/models/active"),
    archive_dir=_txt(_ASUS, "LLAMA_ARCHIVE_DIR", "$HOME/models/archived"),
    hf_home=_txt(_ASUS, "HF_HOME", "$HOME/models/active"),
    hf_hub_cache=_txt(_ASUS, "HF_HUB_CACHE", "$HOME/models/active"),
    registry_path=_txt(_ASUS, "LLM_REGISTRY", "$HOME/models/active/models.conf"),
    state_dir=_txt(_ASUS, "LLM_STATE_DIR", "$HOME/models/.llm"),
    baseline_model=_txt(_ASUS, "TAC_HOST_BASELINE_MODEL", "cuda-qwen3coder-30b/qwen3-coder-30b-gpu"),
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
    gpu_pool_bytes_fallback=_num(_XPS, "VRAM_TOTAL_BYTES_FALLBACK", 4294967296),
    model_store_path="/mnt/m",
    model_store_is_mount=True,
    serving=ServingParameters(
        gpu_layers=_num(_XPS, "LLAMA_GPU_LAYERS", 24),
        context_window=20480,
        max_context_window=21504,
        parallel_slots=1,
        batch_size=512,
        ubatch_size=256,
        thread_cap=_num(_XPS, "LLAMA_THREAD_CAP", 6),  # hybrid ceiling: no spill onto E-cores
        threads_base=_num(_XPS, "LLAMA_CPU_THREADS_BASE", 6),  # 6 Intel P-cores
        primary_port=_num(_XPS, "LLM_SERVICE_PORT", 18081),
        min_host_reserve_mb=1024,
        fit_target_mb=_num(_XPS, "LLAMA_FIT_TARGET_MB", 1024),
        cache_ram_mb=_num(_XPS, "LLAMA_CACHE_RAM_MB", 0),
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
        primary_port=_num(_XPS, "LLM_SERVICE_PORT", 18081),
        lanes=_lanes("intel-xe-cuda", _XPS),
    ),
    gpu_label=_txt(_XPS, "TAC_HOST_GPU_LABEL") or "RTX 3050 Ti",
    igpu_label=_txt(_XPS, "TAC_HOST_IGPU_LABEL", "Intel Xe"),
    cuda_arch=_txt(_XPS, "LLAMA_CUDA_ARCH", "86"),
    autotune_baseline_gap_max=_num(_XPS, "LLM_AUTOTUNE_BASELINE_GAP_MAX", 3500),
    baseline_model=_txt(_XPS, "TAC_HOST_BASELINE_MODEL", "cuda-llama32-3b/llama32"),
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
    """Resolve hardware profile via override or auto-detect active host hardware."""
    target_id = resolve_profile_override(override_id)
    if target_id:
        profile = get_profile_by_id(target_id)
        if profile is None:
            available = ", ".join(sorted(PROFILES.keys()))
            raise ValueError(f"Unknown profile '{target_id}' (available: {available})")
        return profile

    from tools.box.prober import detect_hardware_profile

    return detect_hardware_profile()
