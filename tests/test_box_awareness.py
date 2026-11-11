"""Unit tests for the unified box awareness package (tools.box)."""

from __future__ import annotations

import json
from pathlib import Path

import pytest
from pydantic import ValidationError

from tools.box import (
    ASUS_RTX_SPARK_PROFILE,
    DELL_XPS_PROFILE,
    PROFILES,
    LaneSpec,
    MemoryArchitecture,
    PortAllocation,
    QuantPolicy,
    QuantRating,
    QuantRule,
    ServingParameters,
    compute_effective_vram_mb,
    detect_hardware_profile,
    get_hardware_profile,
)
from tools.box.cli import main


def test_hardware_profiles_registry_contains_target_boxes() -> None:
    assert "asus-n1n-rtx-spark" in PROFILES
    assert "intel-xe-cuda" in PROFILES
    assert ASUS_RTX_SPARK_PROFILE.memory_arch == MemoryArchitecture.UNIFIED
    assert ASUS_RTX_SPARK_PROFILE.total_memory_mb == 131072
    assert ASUS_RTX_SPARK_PROFILE.serving.gpu_layers == 999
    assert ASUS_RTX_SPARK_PROFILE.serving.parallel_slots == 4
    assert ASUS_RTX_SPARK_PROFILE.serving.primary_port == 18087
    assert DELL_XPS_PROFILE.memory_arch == MemoryArchitecture.DISCRETE
    assert DELL_XPS_PROFILE.total_memory_mb == 4096
    assert DELL_XPS_PROFILE.serving.gpu_layers == 24
    assert DELL_XPS_PROFILE.serving.thread_cap == 6
    assert DELL_XPS_PROFILE.serving.primary_port == 18081


def test_hardware_profile_is_frozen_and_validates_strictly() -> None:
    with pytest.raises(ValidationError):
        # The ignore below is the point of this case: the assignment is illegal at
        # run time (frozen model), and it must be attempted to prove that it is.
        ASUS_RTX_SPARK_PROFILE.id = "mutated"  # type: ignore[misc]

    with pytest.raises(ValidationError):
        PortAllocation(
            primary_port=18087,
            lanes=[
                LaneSpec(unit_name="a.service", port=18087, is_primary=True),
                LaneSpec(unit_name="b.service", port=18087),
            ],
        )

    with pytest.raises(ValidationError):
        ServingParameters(
            gpu_layers=24,
            context_window=32768,
            max_context_window=16384,
            parallel_slots=1,
            batch_size=512,
            ubatch_size=256,
            threads_base=6,
            thread_cap=6,
            primary_port=18081,
            min_host_reserve_mb=1024,
        )


def test_quant_policy_evaluates_filename_patterns() -> None:
    policy = ASUS_RTX_SPARK_PROFILE.quant_policy
    assert policy.evaluate_quant("Qwen3-30B-A3B-Q8_0.gguf") == QuantRating.RECOMMENDED
    assert policy.evaluate_quant("Qwen2.5-Coder-32B-Q4_K_M.gguf") == QuantRating.ACCEPTABLE
    assert policy.evaluate_quant("TinyModel-Q2_K.gguf") == QuantRating.DISCOURAGED


def test_asus_quant_guide_conf_exists_and_matches_rules() -> None:
    repo_root = Path(__file__).resolve().parent.parent
    conf_path = repo_root / ASUS_RTX_SPARK_PROFILE.quant_policy.guide_rel_path
    assert conf_path.is_file()
    rules: list[QuantRule] = []
    for raw in conf_path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        rating, pattern, description = line.split("|", 2)
        rules.append(QuantRule(rating=QuantRating(rating), pattern=pattern, description=description))
    assert len(rules) >= 5
    dynamic_policy = QuantPolicy(guide_rel_path=str(conf_path), rules=rules)
    assert dynamic_policy.evaluate_quant("model-Q8_0.gguf") == QuantRating.RECOMMENDED
    assert dynamic_policy.evaluate_quant("model-Q2_K.gguf") == QuantRating.DISCOURAGED


def test_detect_hardware_profile_respects_overrides_and_cpu_markers(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv("LLM_HOST_PROFILE", "intel-xe-cuda")
    assert get_hardware_profile().id == "intel-xe-cuda"

    monkeypatch.delenv("LLM_HOST_PROFILE", raising=False)
    monkeypatch.setenv("TAC_HOST_PROFILE_ID", "asus-n1n-rtx-spark")
    assert get_hardware_profile().id == "asus-n1n-rtx-spark"

    monkeypatch.delenv("TAC_HOST_PROFILE_ID", raising=False)
    monkeypatch.setenv("TAC_HOST_CPU_OVERRIDE", "ARM Cortex-X925")
    assert detect_hardware_profile().id == "asus-n1n-rtx-spark"

    monkeypatch.setenv("TAC_HOST_CPU_OVERRIDE", "12th Gen Intel(R) Core(TM) i9-12900HK")
    assert detect_hardware_profile().id == "intel-xe-cuda"


def test_compute_effective_vram_mb_for_unified_and_discrete(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.delenv("TAC_HOST_GPU_POOL_BYTES", raising=False)
    avail_spark = compute_effective_vram_mb(ASUS_RTX_SPARK_PROFILE)
    assert avail_spark >= ASUS_RTX_SPARK_PROFILE.total_memory_mb

    monkeypatch.setenv("TAC_HOST_GPU_POOL_BYTES", str(4096 * 1024 * 1024))
    avail_xps = compute_effective_vram_mb(DELL_XPS_PROFILE)
    assert avail_xps == 4096


def test_cli_export_query_and_detect(capsys: pytest.CaptureFixture[str]) -> None:
    assert main(["--profile", "asus-n1n-rtx-spark", "export-env"]) == 0
    out = capsys.readouterr().out
    assert 'export TAC_HOST_PROFILE_ID="asus-n1n-rtx-spark"' in out
    assert 'export LLM_SERVICE_PORT="18087"' in out

    assert main(["--profile", "intel-xe-cuda", "query", "serving.primary_port"]) == 0
    assert capsys.readouterr().out.strip() == "18081"

    assert main(["--profile", "asus-n1n-rtx-spark", "detect", "--json"]) == 0
    payload = json.loads(capsys.readouterr().out)
    assert payload["id"] == "asus-n1n-rtx-spark"
