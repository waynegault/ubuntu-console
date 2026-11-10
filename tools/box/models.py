"""Pydantic v2 domain models for box profiles and hardware awareness.

Module Version: 1 (2026-11-10)
Provides typed, validated, and immutable schemas for hardware architectures,
memory models, serving parameters, quantization policies, and lane port allocations.
"""

from __future__ import annotations

from enum import Enum
from typing import Literal

from pydantic import (
    BaseModel,
    ConfigDict,
    Field,
    NonNegativeInt,
    PositiveInt,
    model_validator,
)


class MemoryArchitecture(str, Enum):
    """Memory architecture classification."""

    UNIFIED = "unified"
    DISCRETE = "discrete"


class Architecture(str, Enum):
    """Host CPU architecture."""

    X86_64 = "x86_64"
    AARCH64 = "aarch64"


class QuantRating(str, Enum):
    """Quantization recommendation rating."""

    RECOMMENDED = "recommended"
    ACCEPTABLE = "acceptable"
    DISCOURAGED = "discouraged"


class QuantRule(BaseModel):
    """Rule defining a quantization pattern and its suitability."""

    model_config = ConfigDict(frozen=True, extra="forbid")

    pattern: str = Field(min_length=1, description="Quantization filename pattern (e.g. Q4_K_M)")
    rating: QuantRating = Field(description="Suitability rating for this hardware profile")
    description: str = Field(default="", description="Operator guidance notes")


class QuantPolicy(BaseModel):
    """Host quantization policy and evaluation rules."""

    model_config = ConfigDict(frozen=True, extra="forbid")

    guide_rel_path: str = Field(default="", description="Relative path to host quant guide conf file")
    recommended: list[str] = Field(default_factory=list, description="Recommended quantization tags")
    acceptable: list[str] = Field(default_factory=list, description="Acceptable quantization tags")
    discouraged: list[str] = Field(default_factory=list, description="Discouraged quantization tags")
    rules: list[QuantRule] = Field(default_factory=list, description="Explicit quant rules")

    def evaluate_quant(self, quant_name: str) -> QuantRating:
        """Evaluate a quantization name or filename against policy rules."""
        q_upper = quant_name.upper()
        for rule in self.rules:
            if rule.pattern.upper() in q_upper:
                return rule.rating
        for r in self.recommended:
            if r.upper() in q_upper:
                return QuantRating.RECOMMENDED
        for a in self.acceptable:
            if a.upper() in q_upper:
                return QuantRating.ACCEPTABLE
        for d in self.discouraged:
            if d.upper() in q_upper:
                return QuantRating.DISCOURAGED
        return QuantRating.ACCEPTABLE

    def is_recommended(self, quant_name: str) -> bool:
        return self.evaluate_quant(quant_name) == QuantRating.RECOMMENDED

    def is_discouraged(self, quant_name: str) -> bool:
        return self.evaluate_quant(quant_name) == QuantRating.DISCOURAGED


class ServingParameters(BaseModel):
    """Inference and serving execution parameters."""

    model_config = ConfigDict(frozen=True, extra="forbid")

    gpu_layers: NonNegativeInt = Field(description="Number of layers to offload to GPU (999 for full offload)")
    context_window: PositiveInt = Field(description="Default context window in tokens")
    max_context_window: PositiveInt = Field(description="Maximum context window in tokens")
    parallel_slots: PositiveInt = Field(default=1, ge=1, le=16, description="Number of parallel request slots")
    batch_size: PositiveInt = Field(description="Prompt processing batch size")
    ubatch_size: PositiveInt = Field(description="Micro-batch size for generation")
    thread_cap: NonNegativeInt = Field(
        default=0,
        description="Ceiling on compute threads (0 = unconstrained; 6 on hybrid Intel P-cores)",
    )
    threads_base: PositiveInt = Field(description="Base CPU threads to allocate for compute/inference")
    primary_port: PositiveInt = Field(ge=1, le=65535, description="Primary serving port for default chat lane")
    min_host_reserve_mb: NonNegativeInt = Field(
        default=1024,
        description="Minimum host RAM to reserve to prevent WSL/OS crashes",
    )
    fit_target_mb: NonNegativeInt = Field(
        default=1024, description="Target headroom to preserve during model fit sizing"
    )
    cache_ram_mb: NonNegativeInt = Field(default=0, description="Host-RAM prompt cache budget (0 = disabled)")
    ngl_strategy: Literal["full_only", "ladder", "binary"] = Field(
        default="full_only",
        description="Layer stepping strategy ('full_only' on unified memory to prevent OOM)",
    )

    @property
    def default_ctx_size(self) -> int:
        return self.context_window

    @property
    def max_ctx_size(self) -> int:
        return self.max_context_window

    @property
    def cpu_threads_base(self) -> int:
        return self.threads_base

    @property
    def keep_reserve_mb(self) -> int:
        return self.min_host_reserve_mb

    @model_validator(mode="after")
    def validate_invariants(self) -> ServingParameters:
        if self.batch_size < self.ubatch_size:
            raise ValueError(f"batch_size ({self.batch_size}) must be >= ubatch_size ({self.ubatch_size})")
        if self.max_context_window < self.context_window:
            raise ValueError(
                f"max_context_window ({self.max_context_window}) must be >= context_window ({self.context_window})"
            )
        return self


class LaneSpec(BaseModel):
    """Specification of a resident systemd service lane."""

    model_config = ConfigDict(frozen=True, extra="forbid")

    unit_name: str = Field(min_length=1, description="systemd unit name")
    port: PositiveInt = Field(ge=1, le=65535, description="Listening TCP port")
    is_primary: bool = Field(default=False, description="Whether this is the primary production lane")
    is_protected: bool = Field(default=False, description="Whether this lane is protected from VRAM drain eviction")
    is_gated: bool = Field(default=False, description="Whether this lane is the suspendable CUDA lane")
    description: str = Field(default="", description="Descriptive label for the lane")


class PortAllocation(BaseModel):
    """TCP port allocation and lane topologies."""

    model_config = ConfigDict(frozen=True, extra="forbid")

    primary_port: PositiveInt = Field(ge=1, le=65535, description="Primary HTTP serving port")
    lanes: list[LaneSpec] = Field(default_factory=list, description="All declared resident lanes")

    @property
    def primary_lane(self) -> LaneSpec | None:
        """Resolve the primary production lane."""
        for lane in self.lanes:
            if lane.is_primary or lane.port == self.primary_port:
                return lane
        return self.lanes[0] if self.lanes else None

    @property
    def protected_lanes(self) -> list[LaneSpec]:
        """Lanes that must not be stood down during autotune/benchmark sweeps."""
        return [lane for lane in self.lanes if lane.is_protected]

    @property
    def gated_lane(self) -> LaneSpec | None:
        """The GPU lane suspended during benchmarking and autotuning."""
        for lane in self.lanes:
            if lane.is_gated:
                return lane
        return None

    def format_lane_specs(self) -> str:
        """Format as newline-delimited unit_name|port strings for bash export."""
        return "\n".join(f"{lane.unit_name}|{lane.port}" for lane in self.lanes)


class HardwareProfile(BaseModel):
    """Single source of truth describing host hardware and serving configuration."""

    model_config = ConfigDict(frozen=True, extra="forbid")

    id: str = Field(min_length=1, description="Unique profile identifier")
    description: str = Field(default="", description="Human-readable description of machine")
    arch: Architecture = Field(description="CPU architecture")
    cpu_model_pattern: str = Field(
        default="", description="Case-insensitive CPU model pattern for device-independent match"
    )
    has_cuda: bool = Field(default=True, description="Whether NVIDIA CUDA is supported")
    has_xe_igpu: bool = Field(default=False, description="Whether Intel Iris Xe iGPU is present")
    memory_arch: MemoryArchitecture = Field(description="Memory architecture (unified vs discrete)")
    total_memory_mb: PositiveInt = Field(description="Total system pool memory (unified) or discrete VRAM in MB")
    gpu_pool_bytes_fallback: NonNegativeInt = Field(default=0, description="Fallback GPU pool in bytes when unreadable")
    model_store_path: str = Field(description="Base path for model storage")
    model_store_is_mount: bool = Field(
        default=False, description="True if model store is a bind mount requiring mount checks"
    )
    serving: ServingParameters = Field(description="Serving and inference parameters")
    quant_policy: QuantPolicy = Field(description="Quantization policies")
    ports: PortAllocation = Field(description="Port allocation and resident lane topology")

    # Environment and build metadata
    gpu_label: str = Field(default="", description="GPU hardware label")
    igpu_label: str | None = Field(default=None, description="iGPU hardware label")
    cuda_arch: str | None = Field(default=None, description="CUDA architecture compilation target")
    cuda_fa_quants: str | None = Field(default=None, description="FlashAttention quant compilation list")
    build_dir: str | None = Field(default=None, description="llama.cpp build directory")
    server_bin: str | None = Field(default=None, description="llama-server binary path")
    autotune_census: str | None = Field(
        default=None, description="Declared tenant service for autotune VRAM contention"
    )
    autotune_census_max_mib: NonNegativeInt = Field(
        default=0, description="Max allowed VRAM hold for declared census tenant"
    )
    autotune_baseline_gap_max: NonNegativeInt = Field(
        default=3500, description="Max baseline VRAM gap allowed before starting autotune"
    )
    gpu_free_threshold_mib: NonNegativeInt = Field(
        default=3500, description="Minimum free VRAM required before launching workloads"
    )
    model_dir: str | None = Field(default=None, description="Active models directory")
    archive_dir: str | None = Field(default=None, description="Archived models directory")
    hf_home: str | None = Field(default=None, description="HuggingFace home cache directory")
    hf_hub_cache: str | None = Field(default=None, description="HuggingFace hub cache directory")
    registry_path: str | None = Field(default=None, description="models.conf registry path")
    state_dir: str | None = Field(default=None, description="Tactical state directory")

    @property
    def profile_id(self) -> str:
        return self.id

    @property
    def memory_type(self) -> MemoryArchitecture:
        return self.memory_arch

    @property
    def total_system_memory_mb(self) -> int:
        return self.total_memory_mb

    @property
    def serving_policy(self) -> ServingParameters:
        return self.serving

    @property
    def is_unified(self) -> bool:
        """True if host has unified CPU/GPU memory architecture."""
        return self.memory_arch == MemoryArchitecture.UNIFIED

    @property
    def is_discrete(self) -> bool:
        """True if host has dedicated discrete GPU VRAM."""
        return self.memory_arch == MemoryArchitecture.DISCRETE

    @property
    def lanes(self) -> list[LaneSpec]:
        """Convenience accessor for declared lanes."""
        return self.ports.lanes

    @property
    def primary_lane(self) -> LaneSpec | None:
        """Convenience accessor for primary lane."""
        return self.ports.primary_lane

    def to_env_dict(self) -> dict[str, str]:
        """Convert profile configuration into bash environment variables."""
        env: dict[str, str] = {
            "TAC_HOST_PROFILE": self.id,
            "TAC_HOST_PROFILE_ID": self.id,
            "TAC_HOST_PROFILE_DESCRIPTION": self.description,
            "TAC_HOST_PROFILE_ARCH": self.arch.value,
            "TAC_HOST_PROFILE_CUDA": "1" if self.has_cuda else "0",
            "TAC_HOST_PROFILE_XE": "1" if self.has_xe_igpu else "0",
            "TAC_HOST_PROFILE_SHARED_MEMORY": "1" if self.is_unified else "0",
            "TAC_HOST_PROFILE_MODEL_STORE_IS_MOUNT": "1" if self.model_store_is_mount else "0",
            "LLAMA_DRIVE_ROOT": self.model_store_path,
            "LLAMA_GPU_LAYERS": str(self.serving.gpu_layers),
            "LLAMA_CPU_THREADS_BASE": str(self.serving.threads_base),
            "LLAMA_THREAD_CAP": str(self.serving.thread_cap),
            "LLAMA_FIT_TARGET_MB": str(self.serving.fit_target_mb),
            "LLAMA_FIT_KEEP_RESERVE_MB": str(self.serving.min_host_reserve_mb),
            "LLAMA_CACHE_RAM_MB": str(self.serving.cache_ram_mb),
            "VRAM_TOTAL_BYTES_FALLBACK": str(self.gpu_pool_bytes_fallback),
            "LLAMA_LANE_SPECS": self.ports.format_lane_specs(),
            "LLM_SERVICE_PORT": str(self.serving.primary_port),
        }
        if self.ports.primary_lane:
            env["TAC_HOST_PRIMARY_LANE"] = self.ports.primary_lane.unit_name
        if self.ports.protected_lanes:
            env["LLAMA_LANE_KEEP_UNITS"] = " ".join(lane.unit_name for lane in self.ports.protected_lanes)
        if self.ports.gated_lane:
            env["LLAMA_CUDA_LANE_UNIT"] = self.ports.gated_lane.unit_name
        if self.quant_policy.guide_rel_path:
            env["LLAMA_QUANT_GUIDE_REL"] = self.quant_policy.guide_rel_path
        if self.gpu_label:
            env["TAC_HOST_GPU_LABEL"] = self.gpu_label
        if self.igpu_label:
            env["TAC_HOST_IGPU_LABEL"] = self.igpu_label
        if self.cuda_arch:
            env["LLAMA_CUDA_ARCH"] = self.cuda_arch
        if self.cuda_fa_quants:
            env["LLAMA_CUDA_FA_QUANTS"] = self.cuda_fa_quants
        if self.build_dir:
            env["LLAMA_BUILD_DIR"] = self.build_dir
        if self.server_bin:
            env["LLAMA_CUDA_SERVER_BIN"] = self.server_bin
        if self.autotune_census:
            env["LLM_AUTOTUNE_CENSUS"] = self.autotune_census
        if self.autotune_census_max_mib:
            env["LLM_AUTOTUNE_CENSUS_MAX_MIB"] = str(self.autotune_census_max_mib)
        if self.autotune_baseline_gap_max:
            env["LLM_AUTOTUNE_BASELINE_GAP_MAX"] = str(self.autotune_baseline_gap_max)
        if self.gpu_free_threshold_mib:
            env["LLAMA_GPU_FREE_THRESHOLD_MIB"] = str(self.gpu_free_threshold_mib)
        if self.model_dir:
            env["LLAMA_MODEL_DIR"] = self.model_dir
        if self.archive_dir:
            env["LLAMA_ARCHIVE_DIR"] = self.archive_dir
        if self.hf_home:
            env["HF_HOME"] = self.hf_home
        if self.hf_hub_cache:
            env["HF_HUB_CACHE"] = self.hf_hub_cache
        if self.registry_path:
            env["LLM_REGISTRY"] = self.registry_path
        if self.state_dir:
            env["LLM_STATE_DIR"] = self.state_dir
        return env
