"""Tests for the GRPO VRAM probe's budget arithmetic (card UBC-GRPO-003).

The probe's GPU measurement cannot be unit-tested here - it needs the 4 GB card, and it
was verified by running it.  Its ARITHMETIC can be, and that is where a wrong published
budget would come from: the components are summed, the reserve is taken from the free VRAM
found at baseline, and the verdict is the reserve rule.

The module is a hyphenated script (this repo's ``scripts/*.py`` convention), so it is
loaded by path rather than imported by name.
"""

from __future__ import annotations

import argparse
import contextlib
import sys
import types
from typing import Any

import pytest

from _probe_paths import load_probe

probe = load_probe("grpo_vram_probe", "grpo-vram-probe.py")
_BF16_SENTINEL = object()


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


# --- gpu_used_mb: the measured free-VRAM source -----------------------------
# Criterion: the module docstring says the figure comes from nvidia-smi and the probe
# must return None when it "cannot be read" rather than guessing.  The expected values
# below come from that contract, not from the probe's parsing code.


class _FakeProc:
    def __init__(self, returncode: int, stdout: str) -> None:
        self.returncode = returncode
        self.stdout = stdout
        self.stderr = ""


def _fake_subprocess(returncode: int = 0, stdout: str = "1234\n", raise_exc: Exception | None = None) -> Any:
    module: Any = types.ModuleType("subprocess")

    class SubprocessError(Exception):
        pass

    module.SubprocessError = SubprocessError

    def run(*args: Any, **kwargs: Any) -> Any:
        if raise_exc is not None:
            raise raise_exc
        return _FakeProc(returncode, stdout)

    module.run = run
    return module


def test_gpu_used_mb_parses_nvidia_smi_memory(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(probe, "subprocess", _fake_subprocess(stdout="1234\n"))
    assert probe.gpu_used_mb() == 1234


def test_gpu_used_mb_returns_none_on_subprocess_failure(monkeypatch: pytest.MonkeyPatch) -> None:
    # Catches: a non-zero nvidia-smi read as a real figure, which would silently
    # corrupt every delta the budget is built from.
    monkeypatch.setattr(probe, "subprocess", _fake_subprocess(returncode=9))
    assert probe.gpu_used_mb() is None


def test_gpu_used_mb_returns_none_on_unparseable_output(monkeypatch: pytest.MonkeyPatch) -> None:
    # Catches: "N/A" (nvidia-smi's own answer for an unreadable field) becoming a number.
    monkeypatch.setattr(probe, "subprocess", _fake_subprocess(stdout="N/A\n"))
    assert probe.gpu_used_mb() is None


def test_gpu_used_mb_returns_none_when_nvidia_smi_cannot_run(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(probe, "subprocess", _fake_subprocess(raise_exc=OSError("no nvidia-smi")))
    assert probe.gpu_used_mb() is None


# --- build_configs: the config the budget is measured from -------------------
# Criterion: the module docstring names the components - a 4-bit NF4 load with double
# quantisation and bf16 compute, and LoRA r/alpha on q,k,v,o,gate,up,down.  The expected
# values are read from that document, not from the probe's output.


def _fake_quant_env(monkeypatch: pytest.MonkeyPatch) -> tuple[list[dict], list[dict]]:
    torch = types.ModuleType("torch")
    torch.__dict__["bfloat16"] = _BF16_SENTINEL
    peft = types.ModuleType("peft")
    seen_lora: list[dict] = []

    class LoraConfig:
        def __init__(self, **kw: Any) -> None:
            seen_lora.append(kw)
            self.kw = kw

    peft.LoraConfig = LoraConfig  # type: ignore[attr-defined]
    transformers = types.ModuleType("transformers")
    seen_quant: list[dict] = []

    class BitsAndBytesConfig:
        def __init__(self, **kw: Any) -> None:
            seen_quant.append(kw)
            self.kw = kw

    transformers.BitsAndBytesConfig = BitsAndBytesConfig  # type: ignore[attr-defined]
    monkeypatch.setitem(sys.modules, "torch", torch)
    monkeypatch.setitem(sys.modules, "peft", peft)
    monkeypatch.setitem(sys.modules, "transformers", transformers)
    return seen_quant, seen_lora


def test_build_configs_matches_the_documented_4bit_and_lora_shape(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    seen_quant, seen_lora = _fake_quant_env(monkeypatch)
    quant, lora = probe.build_configs("Qwen/Qwen2.5-1.5B", 8)
    assert seen_quant == [{
        "load_in_4bit": True,
        "bnb_4bit_quant_type": "nf4",
        "bnb_4bit_use_double_quant": True,
        "bnb_4bit_compute_dtype": _BF16_SENTINEL,
    }]
    assert seen_lora[0]["r"] == 8
    # lora_alpha = 2 * r is the docstring's "r/alpha" convention.
    assert seen_lora[0]["lora_alpha"] == 16
    assert seen_lora[0]["task_type"] == "CAUSAL_LM"
    assert seen_lora[0]["target_modules"] == [
        "q_proj", "k_proj", "v_proj", "o_proj", "gate_proj", "up_proj", "down_proj",
    ]
    assert (quant.kw["bnb_4bit_quant_type"], lora.kw["r"]) == ("nf4", 8)


# --- measure: the per-phase deltas ------------------------------------------
# Criterion: the components are the DIFFERENCES nvidia-smi shows between phases
# (baseline/weights/hiprec/adapters/activations/rollouts), and the optimizer is analytic
# (2 fp32 moments per trainable parameter) - both stated in the docstring.  The expected
# numbers below come from those definitions applied to a fixed gpu_used_mb sequence.


class _Param:
    def __init__(self, numel: int) -> None:
        self._numel = numel
        self.requires_grad = True

    def numel(self) -> int:
        return self._numel


class _Log:
    def __init__(self) -> None:
        self.events: list[str] = []


class _Loss:
    def __init__(self, log: _Log) -> None:
        self.log = log

    def backward(self) -> None:
        self.log.events.append("backward")


class _Output:
    def __init__(self, log: _Log) -> None:
        self.loss = _Loss(log)


class _Optim:
    def __init__(self, params: Any, log: _Log) -> None:
        self.params = list(params)
        self.log = log

    def step(self) -> None:
        self.log.events.append("step")

    def zero_grad(self, set_to_none: bool = False) -> None:
        self.log.events.append("zero_grad")


class _Model:
    def __init__(self, log: _Log, params: list[_Param]) -> None:
        self.log = log
        self._params = params

    def parameters(self) -> list[_Param]:
        return self._params

    def print_trainable_parameters(self) -> None:
        self.log.events.append("print_trainable_parameters")

    def train(self) -> None:
        self.log.events.append("train")

    def eval(self) -> None:
        self.log.events.append("eval")

    def __call__(self, **kw: Any) -> Any:
        self.log.events.append("forward")
        return _Output(self.log)

    def generate(self, **kw: Any) -> None:
        self.log.events.append(f"generate:{kw.get('num_return_sequences')}")


def _fake_measure_env(monkeypatch: pytest.MonkeyPatch) -> tuple[_Log, _Model]:
    log = _Log()
    # 8 Mi params => analytic optimizer = 2 * 4 * 8*1024*1024 // 1 Mi = 64 MiB.
    params = [_Param(8 * 1024 * 1024)]
    model = _Model(log, params)

    torch = types.ModuleType("torch")
    torch.__dict__["bfloat16"] = "bf16"
    torch.randint = lambda *a, **k: "ids"  # type: ignore[attr-defined]
    torch.ones_like = lambda x: "ones"  # type: ignore[attr-defined]
    torch.optim = types.SimpleNamespace(AdamW=lambda ps, lr: _Optim(ps, log))  # type: ignore[attr-defined]
    torch.cuda = types.SimpleNamespace(  # type: ignore[attr-defined]
        reset_peak_memory_stats=lambda: log.events.append("reset_peak"),
        synchronize=lambda: log.events.append("sync"),
    )
    torch.no_grad = lambda: contextlib.nullcontext()  # type: ignore[attr-defined]

    peft = types.ModuleType("peft")
    peft.get_peft_model = lambda m, lora: m  # type: ignore[attr-defined]
    peft.prepare_model_for_kbit_training = (  # type: ignore[attr-defined]
        lambda m, use_gradient_checkpointing=True: m)

    class LoraConfig:
        def __init__(self, **kw: Any) -> None:
            self.kw = kw

    peft.LoraConfig = LoraConfig  # type: ignore[attr-defined]

    transformers = types.ModuleType("transformers")

    class BitsAndBytesConfig:
        def __init__(self, **kw: Any) -> None:
            self.kw = kw

    class AutoTokenizer:
        eos_token_id = 2

        @classmethod
        def from_pretrained(cls, mid: str) -> Any:
            return cls()

    class AutoModelForCausalLM:
        @classmethod
        def from_pretrained(cls, mid: str, **kw: Any) -> Any:
            return model

    transformers.BitsAndBytesConfig = BitsAndBytesConfig  # type: ignore[attr-defined]
    transformers.AutoTokenizer = AutoTokenizer  # type: ignore[attr-defined]
    transformers.AutoModelForCausalLM = AutoModelForCausalLM  # type: ignore[attr-defined]

    monkeypatch.setitem(sys.modules, "torch", torch)
    monkeypatch.setitem(sys.modules, "peft", peft)
    monkeypatch.setitem(sys.modules, "transformers", transformers)
    return log, model


def _args(**kw: Any) -> Any:
    return argparse.Namespace(
        model="m", ctx=kw.get("ctx", 2048), lora_r=kw.get("lora_r", 16),
        rollouts=kw.get("rollouts", 4), gen_tokens=kw.get("gen_tokens", 256),
    )


def test_measure_reports_each_component_as_a_phase_delta(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    log, _model = _fake_measure_env(monkeypatch)
    seq = [496, 1050, 1570, 1604, 4400, 4600]
    it = iter(seq)
    monkeypatch.setattr(probe, "gpu_used_mb", lambda: next(it))

    budget = probe.measure("m", _args())

    assert (budget.baseline_mb, budget.weights_mb, budget.hiprec_mb,
            budget.adapters_mb) == (496, 554, 520, 34)
    # Analytic optimizer: 2 fp32 moments per trainable parameter.
    assert budget.optimizer_mb == (2 * 4 * 8 * 1024 * 1024) // (1024 * 1024) == 64
    assert budget.activations_mb == 4400 - 1604 - 64
    assert budget.rollouts_mb == 200
    assert budget.peak_used_mb == 4600
    assert budget.verdict == "does-not-fit"
    # The phases really ran, in order: the model was stepped, then generated from.
    assert log.events.index("backward") < log.events.index("step")
    assert "train" in log.events and "eval" in log.events
    assert "generate:4" in log.events
    assert any("gradient checkpointing" in n for n in budget.notes)
    assert any("2 x fp32" in n for n in budget.notes)


def test_measure_refuses_to_measure_blind_when_nvidia_smi_is_unreadable(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # Criterion: the docstring's measured-not-estimated rule - with no baseline the
    # deltas are meaningless, so this must raise rather than publish a fabricated budget.
    _fake_measure_env(monkeypatch)
    monkeypatch.setattr(probe, "gpu_used_mb", lambda: None)
    with pytest.raises(RuntimeError, match="refusing to measure blind"):
        probe.measure("m", _args())


# --- render / main ----------------------------------------------------------


def test_render_names_every_component_and_the_verdict() -> None:
    # Criterion: the human table is what gets published, so every named component and
    # the verdict line must be present - a component silently dropped from render is a
    # budget nobody can audit.
    text = probe.render(_budget(baseline_mb=496))
    for label in ("baseline", "weights (4-bit)", "high-precision", "adapters",
                  "optimizer", "activations", "rollouts", "trainable", "reserve (20%)",
                  "PEAK used", "headroom", "verdict"):
        assert label in text, label
    assert "edge" in text


def test_main_dry_run_returns_2_and_prints_the_config(
    monkeypatch: pytest.MonkeyPatch, capsys: Any
) -> None:
    _fake_quant_env(monkeypatch)
    rc = probe.main(["Qwen/Qwen2.5-1.5B", "--dry-run", "--lora-r", "4"])
    out = capsys.readouterr().out
    assert rc == 2
    assert "model      : Qwen/Qwen2.5-1.5B" in out
    assert "rollouts   : 4 x 256 tokens" in out


def test_main_returns_3_and_reports_a_failed_measurement(
    monkeypatch: pytest.MonkeyPatch, caplog: Any
) -> None:
    _fake_quant_env(monkeypatch)

    def boom(model: str, args: Any) -> Any:
        raise RuntimeError("card busy")

    monkeypatch.setattr(probe, "measure", boom)
    with caplog.at_level("ERROR", logger="grpo-vram-probe"):
        rc = probe.main(["m"])
    assert rc == 3
    assert any("measurement failed for m" in r.getMessage() for r in caplog.records)


def test_main_prints_render_by_default_and_json_on_request(
    monkeypatch: pytest.MonkeyPatch, capsys: Any
) -> None:
    _fake_quant_env(monkeypatch)
    budget = _budget()
    monkeypatch.setattr(probe, "measure", lambda model, args: budget)
    assert probe.main(["m"]) == 0
    human = capsys.readouterr().out
    assert "verdict" in human
    assert probe.main(["m", "--json"]) == 0
    payload = capsys.readouterr().out
    assert '"model": "probe"' in payload
