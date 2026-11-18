"""Unit tests for the unified box awareness package (tools.box)."""

from __future__ import annotations

import json
from collections.abc import Callable
from pathlib import Path

import pytest
from pydantic import ValidationError

from tools.box import (
    ASUS_RTX_SPARK_PROFILE,
    DELL_XPS_PROFILE,
    PROFILES,
    HardwareProfile,
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
    # Q2_K is ACCEPTABLE on this host by Wayne's ruling of 2026-11-18: the only Q2_K row is
    # the 74B Nemotron, no larger quant fits, and `discouraged` would auto-archive it.
    assert policy.evaluate_quant("TinyModel-Q2_K.gguf") == QuantRating.ACCEPTABLE
    # NVFP4 had no pattern at all, so it rated `unknown` — not a verdict.
    assert policy.evaluate_quant("NVIDIA-Nemotron-3.5-Super-VL-120B-A12B-NVFP4.gguf") == QuantRating.ACCEPTABLE


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
    # The guide is the policy now: Q2_K acceptable (Wayne, 2026-11-18), NVFP4 scored with
    # the 4-bit class, and BF16 discouraged — which only works because BF16 precedes F16
    # in the file (patterns match as substrings in file order).
    assert dynamic_policy.evaluate_quant("model-Q2_K.gguf") == QuantRating.ACCEPTABLE
    assert dynamic_policy.evaluate_quant("model-NVFP4.gguf") == QuantRating.ACCEPTABLE
    assert dynamic_policy.evaluate_quant("model-BF16.gguf") == QuantRating.DISCOURAGED
    assert dynamic_policy.evaluate_quant("model-F16.gguf") == QuantRating.RECOMMENDED


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


# --- the conf and the Python profile must state the SAME facts --------------
# tools/box/profiles.py and config/hosts.d/<id>.conf both describe one machine.  Until
# 2026-11-18 nothing compared them: the ASUS profile's autotune_census and its measure lane
# were re-synced BY HAND in v2, and the shell is what the box actually runs on.  A fact the
# conf declares is the operative one, so Python holding a different value is silent drift —
# the Python layer would size a sweep against a census the launcher does not honour.

CONF_DIR = Path(__file__).resolve().parents[1] / "config" / "hosts.d"


def _conf_facts(conf: Path, keys: tuple[str, ...]) -> dict[str, str]:
    """Source the conf exactly as tools/host-profile.sh does and read the named facts.

    Sourced, not grepped: the confs are declarative shell, and a regex that re-implements
    `${VAR:=value}` would be a second reading of the same file — the drift this guards.
    """
    # A BLOCK per fact: LLAMA_LANE_SPECS is a multi-line value, and a `key=value` line
    # parser silently kept only its first lane (measured 2026-11-18).
    script = 'source "$1" >/dev/null 2>&1; '
    script += "; ".join(f'printf "<<<{k}\\n%s\\n>>>{k}\\n" "${{{k}:-}}"' for k in keys)
    # env -i: the confs use `${VAR:=value}`, so an INHERITED value wins — and a pytest
    # process started from a shell that sourced env.sh carries this box's facts, which made
    # the XPS conf report the ASUS's port and lanes (measured 2026-11-18: intel read 18087).
    import re
    import subprocess

    out = subprocess.run(
        ["env", "-i", f"HOME={Path.home()}", "PATH=/usr/bin:/bin", "bash", "-c", script, "_", str(conf)],
        capture_output=True,
        text=True,
        check=True,
    ).stdout
    facts: dict[str, str] = {}
    for key in keys:
        m = re.search(rf"<<<{re.escape(key)}\n(.*?)\n>>>{re.escape(key)}", out, re.S)
        if m and m.group(1).strip():
            facts[key] = m.group(1)
    return facts


# conf fact -> the Python value it must equal.
SHARED_FACTS: dict[str, Callable[[HardwareProfile], object]] = {
    "LLM_SERVICE_PORT": lambda p: p.serving.primary_port,
    "LLAMA_THREAD_CAP": lambda p: p.serving.thread_cap,
    "LLAMA_GPU_LAYERS": lambda p: p.serving.gpu_layers,
    "LLAMA_FIT_TARGET_MB": lambda p: p.serving.fit_target_mb,
    "LLAMA_CACHE_RAM_MB": lambda p: p.serving.cache_ram_mb,
    "VRAM_TOTAL_BYTES_FALLBACK": lambda p: p.gpu_pool_bytes_fallback,
    "TAC_HOST_GPU_LABEL": lambda p: p.gpu_label,
    "LLAMA_QUANT_GUIDE_REL": lambda p: p.quant_policy.guide_rel_path,
    "TAC_HOST_PRIMARY_LANE": lambda p: p.lanes[0].unit_name,
    "LLM_AUTOTUNE_CENSUS": lambda p: p.autotune_census,
    "LLM_AUTOTUNE_CENSUS_MAX_MIB": lambda p: p.autotune_census_max_mib,
}

# Facts a conf deliberately does not declare.  The XPS derives its store from
# LLAMA_DRIVE_ROOT=/mnt/m and runs no autotune census, so it states none of these.  Every
# OTHER shared fact must be declared: since v3 of profiles.py reads them from the conf, a
# conf that quietly stopped stating one would let the Python fallback literal take over —
# the duplication that version removed.
UNDERIVED: dict[str, set[str]] = {
    "intel-xe-cuda": {
        "LLM_AUTOTUNE_CENSUS",
        "LLM_AUTOTUNE_CENSUS_MAX_MIB",
        "LLM_AUTOTUNE_BASELINE_GAP_MAX",
        "LLAMA_GPU_FREE_THRESHOLD_MIB",
    },
}


@pytest.mark.parametrize("profile_id", sorted(PROFILES))
def test_python_profile_matches_the_conf_it_describes(profile_id: str) -> None:
    """Catches: Python holding a fact the box's own conf contradicts, and a conf that
    stopped declaring a fact the Python layer would then silently default."""
    profile = get_hardware_profile(profile_id)
    facts = _conf_facts(CONF_DIR / f"{profile_id}.conf", tuple(SHARED_FACTS))
    assert facts, f"{profile_id}.conf declared none of the shared facts — wrong path?"
    undeclared = [key for key in SHARED_FACTS if key not in facts and key not in UNDERIVED.get(profile_id, set())]
    assert not undeclared, f"{profile_id}.conf no longer declares: {undeclared}"
    mismatches = []
    for key, getter in SHARED_FACTS.items():
        if key not in facts:
            continue
        expected = str(getter(profile))
        if facts[key].strip() != expected:
            mismatches.append(f"{key}: conf={facts[key].strip()!r} profiles.py={expected!r}")
    assert not mismatches, f"{profile_id}: " + "; ".join(mismatches)


@pytest.mark.parametrize("profile_id", sorted(PROFILES))
def test_lane_sets_match_between_conf_and_python(profile_id: str) -> None:
    """Catches: a lane renamed or renumbered in one layer only — the drift that left the
    ASUS Python profile without its :18089 measure lane."""
    profile = get_hardware_profile(profile_id)
    raw = _conf_facts(CONF_DIR / f"{profile_id}.conf", ("LLAMA_LANE_SPECS",))["LLAMA_LANE_SPECS"]
    from_conf = sorted((line.split("|")[0], int(line.split("|")[1])) for line in raw.splitlines() if "|" in line)
    from_python = sorted((lane.unit_name, lane.port) for lane in profile.lanes)
    assert from_conf == from_python, f"{profile_id}: conf={from_conf} profiles.py={from_python}"
