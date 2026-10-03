"""Tests for the GRPO VRAM probe's budget arithmetic (card UBC-GRPO-003).

The probe's GPU measurement cannot be unit-tested here - it needs the 4 GB card, and it
was verified by running it.  Its ARITHMETIC can be, and that is where a wrong published
budget would come from: the components are summed, the reserve is taken from the free VRAM
found at baseline, and the verdict is the reserve rule.

The module is a hyphenated script (this repo's ``scripts/*.py`` convention), so it is
loaded by path rather than imported by name.
"""

from __future__ import annotations

from typing import Any

from _probe_paths import load_probe

probe = load_probe("grpo_vram_probe", "grpo-vram-probe.py")


def _budget(**kw: Any) -> Any:
    """A Budget with the measured shapes, overridable per test."""
    defaults: dict[str, Any] = {
        "model": "probe",
        "ctx": 2048,
        "lora_r": 16,
        "rollouts": 4,
        "gen_tokens": 256,
        "weights_mb": 554,
        "hiprec_mb": 520,
        "adapters_mb": 34,
        "optimizer_mb": 67,
        "activations_mb": 2776,
        "rollouts_mb": 0,
        "peak_used_mb": 3951,
    }
    defaults.update(kw)
    return probe.Budget(**defaults)


def test_trainable_sums_every_component() -> None:
    """A component left out of the sum is a budget that under-reports the card."""
    budget = _budget()
    assert budget.trainable_mb == 554 + 520 + 34 + 67 + 2776 + 0


def test_reserve_is_twenty_percent_of_the_free_vram_at_baseline() -> None:
    """The autotune idiom's reserve: 20 % of the free VRAM, not 20 % of the card."""
    budget = _budget(baseline_mb=496)
    assert budget.reserve_mb == 720
    assert budget.reserve_mb == int((4096 - 496) * 0.20)


def test_verdict_is_comfortable_only_with_the_reserve_left_over() -> None:
    assert _budget(peak_used_mb=3000).verdict == "comfortable"
    # 3300 + 819 > 4096: it fits, but not with the reserve intact - which is "edge".
    assert _budget(peak_used_mb=3300).verdict == "edge"
    assert _budget(peak_used_mb=4200).verdict == "does-not-fit"


def test_headroom_is_measured_against_the_card_not_the_reserve() -> None:
    """Two different questions, two different numbers - do not conflate them."""
    budget = _budget(peak_used_mb=3951)
    assert budget.headroom_mb == 145
    assert budget.verdict == "edge"
