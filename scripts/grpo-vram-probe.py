#!/usr/bin/env python3
"""Measure a GRPO/QLoRA training VRAM budget on this card (card UBC-GRPO-003).

WHY THIS IS A MEASUREMENT AND NOT AN ESTIMATE.  The audit doc this card came from
(REF below, §11.3) is explicit that parameter count is not a fit verdict: a 4-bit
Qwen2.5-1.5B is ~1 GB of weights, and the run that OOMs this 4 GB card does so because
of what sits BESIDE the weights.  So each component is measured, in the same idiom
``scripts/11b-llm-autotune.sh`` already uses for inference: probe the live free VRAM,
subtract what the model actually occupies, and hold a reserve.

Components measured, per model, on this box's 4 GB RTX 3050 Ti:

  baseline          what the process/context already holds before any model loads
  weights           4-bit NF4 load (double quant, bf16 compute) - the "model_mb"
  adapters          LoRA r/alpha on q,k,v,o,gate,up,down at the given rank
  optimizer         AdamW state, read AFTER one step (the state is created lazily)
  activations       one forward+backward at the given ctx, gradient checkpointing ON
  rollouts          one `generate` of --rollouts sequences at --gen-tokens (the
                    per-prompt G samples), from a COMPACT prompt

NAMED ASSUMPTIONS, because an omitted one would be an unmade decision:

  * The reference model costs NOTHING extra here.  Verified in trl's source, not
    assumed: ``grpo_trainer.py`` sets ``self.ref_model = None`` when the policy is a
    PEFT model ("the adapter can be disabled to revert to the initial model").  That is
    the whole reason a 1.5B QLoRA run is even arguable on a 4 GB card.
  * The rollouts are measured through HF ``generate``.  A production GRPO run may roll
    out through vLLM instead (that lives in its own environment, see
    docs/grpo-training-env.md), whose KV accounting differs - the figure here is the HF
    path's, and it is labelled as such rather than presented as universal.
  * The prompt tokens are SYNTHETIC (random ids of the requested length).  This
    measures memory, not quality; the card's own guidance is that prompts must stay
    compact (retrieved clause + question), which is why --ctx is a knob and not a
    document length.
  * Only the CUDA card is measured.  The Xe card and the CPU tier are different
    hardware and nothing here says anything about them.

Usage:
    .venvs path: ~/.venvs/grpo-train/bin/python scripts/grpo-vram-probe.py MODEL [options]
    --ctx N --lora-r N --rollouts N --gen-tokens N --json --dry-run

Exit: 0 measured, 2 usage/dry-run, 3 a component failed to measure.

REF: "How GRPO Trains Small Language Models with Verifiable Rewards" (Benjamin Nweke,
     TDS, 2026-09-23) and the audit doc's §11.3 —
     /home/wayne/investigator/docs/tds/tds-grpo-small-models-verifiable-rewards.md
"""

from __future__ import annotations

import argparse
import json
import logging
import subprocess
import sys
from dataclasses import dataclass, field

logger = logging.getLogger("grpo-vram-probe")

TOTAL_VRAM_MB = 4096
#: The reserve the autotune idiom holds back: 20 % of the free VRAM it found.
RESERVE_FRACTION = 0.20


def gpu_used_mb() -> int | None:
    """VRAM in use, from nvidia-smi, or None when it cannot be read.

    The true footprint, which is what the box enforces: ``torch.cuda.memory_allocated``
    counts only this process's allocator, so the two disagree by exactly the amount that
    makes a "fits" claim wrong.
    """
    try:
        proc = subprocess.run(
            ["nvidia-smi", "--query-gpu=memory.used", "--format=csv,noheader,nounits"],
            capture_output=True,
            text=True,
            check=False,
            timeout=30,
        )
    except (OSError, subprocess.SubprocessError):
        logger.debug("nvidia-smi unavailable", exc_info=True)
        return None
    text = (proc.stdout or "").strip().splitlines()
    if proc.returncode != 0 or not text:
        logger.debug("nvidia-smi rc=%s out=%r", proc.returncode, proc.stdout)
        return None
    value = text[0].strip()
    return int(value) if value.isdigit() else None


@dataclass
class Budget:
    """One model's measured budget, in MiB."""

    model: str
    ctx: int
    lora_r: int
    rollouts: int
    gen_tokens: int
    baseline_mb: int = 0
    weights_mb: int = 0
    hiprec_mb: int = 0
    adapters_mb: int = 0
    optimizer_mb: int = 0
    activations_mb: int = 0
    rollouts_mb: int = 0
    peak_used_mb: int = 0
    notes: list[str] = field(default_factory=list)

    @property
    def trainable_mb(self) -> int:
        """Everything the run holds at its peak, excluding the baseline."""
        return (
            self.weights_mb
            + self.hiprec_mb
            + self.adapters_mb
            + self.optimizer_mb
            + self.activations_mb
            + self.rollouts_mb
        )

    @property
    def reserve_mb(self) -> int:
        """20 % of the free VRAM at baseline, as the autotune idiom holds it back."""
        free = max(TOTAL_VRAM_MB - self.baseline_mb, 0)
        return int(free * RESERVE_FRACTION)

    @property
    def headroom_mb(self) -> int:
        """Free VRAM left at the measured peak, against the 4 GB card."""
        return TOTAL_VRAM_MB - self.peak_used_mb

    @property
    def verdict(self) -> str:
        """comfortable / edge / does-not-fit, against the reserve rule."""
        if self.peak_used_mb + self.reserve_mb <= TOTAL_VRAM_MB:
            return "comfortable"
        if self.peak_used_mb <= TOTAL_VRAM_MB:
            return "edge"
        return "does-not-fit"


def build_configs(model_id: str, lora_r: int) -> tuple[object, object]:
    """The 4-bit and LoRA configs this measurement uses.

    Kept in one place so ``--dry-run`` can print exactly what a real run would use.
    """
    import torch
    # peft lives ONLY in the isolated training env (docs/grpo-training-env.md), never in
    # this repo's .venv by design - so both checkers are told so, with the reason.
    from peft import LoraConfig  # type: ignore[import-not-found]  # pyright: ignore[reportMissingImports]
    from transformers import BitsAndBytesConfig

    quant = BitsAndBytesConfig(
        load_in_4bit=True,
        bnb_4bit_quant_type="nf4",
        bnb_4bit_use_double_quant=True,
        bnb_4bit_compute_dtype=torch.bfloat16,
    )
    lora = LoraConfig(
        r=lora_r,
        lora_alpha=2 * lora_r,
        lora_dropout=0.0,
        bias="none",
        task_type="CAUSAL_LM",
        target_modules=[
            "q_proj",
            "k_proj",
            "v_proj",
            "o_proj",
            "gate_proj",
            "up_proj",
            "down_proj",
        ],
    )
    logger.debug("configs for %s: lora_r=%d", model_id, lora_r)
    return quant, lora


def measure(model_id: str, args: argparse.Namespace) -> Budget:
    """Load, adapt, step and generate once, recording each phase's cost."""
    import torch
    # Same reason as in build_configs: peft is in the training env, not this repo's .venv.
    from peft import get_peft_model, prepare_model_for_kbit_training  # type: ignore[import-not-found]  # pyright: ignore[reportMissingImports]
    from transformers import AutoModelForCausalLM, AutoTokenizer

    budget = Budget(
        model=model_id,
        ctx=args.ctx,
        lora_r=args.lora_r,
        rollouts=args.rollouts,
        gen_tokens=args.gen_tokens,
    )
    quant, lora = build_configs(model_id, args.lora_r)

    before = gpu_used_mb()
    if before is None:
        raise RuntimeError("nvidia-smi cannot report VRAM - refusing to measure blind")
    budget.baseline_mb = before

    tokenizer = AutoTokenizer.from_pretrained(model_id)
    model = AutoModelForCausalLM.from_pretrained(
        model_id, quantization_config=quant, device_map={"": 0}
    )
    after_load = gpu_used_mb()
    if after_load is None:
        raise RuntimeError("nvidia-smi cannot report VRAM after the load")
    budget.weights_mb = max(after_load - before, 0)

    # prepare_model_for_kbit_training enables gradient checkpointing and, per the
    # article's own component list, upcasts the HIGH-PRECISION parts - it is what makes
    # the fp32 lm_head appear (measured: a large share of this delta for a 152k vocab).
    # Kept as its own component rather than folded into the 4-bit weights.
    model = prepare_model_for_kbit_training(model, use_gradient_checkpointing=True)
    after_prep = gpu_used_mb()
    if after_prep is None:
        raise RuntimeError("nvidia-smi cannot report VRAM after prepare_model_for_kbit_training")
    budget.hiprec_mb = max(after_prep - after_load, 0)
    budget.notes.append(
        "high-precision components (peft upcasts the non-quantized parts, fp32 lm_head): "
        f"+{budget.hiprec_mb} MiB, gradient checkpointing enabled"
    )

    model = get_peft_model(model, lora)
    model.print_trainable_parameters()
    after_lora = gpu_used_mb()
    if after_lora is None:
        raise RuntimeError("nvidia-smi cannot report VRAM after the LoRA attach")
    budget.adapters_mb = max(after_lora - after_prep, 0)

    optim = torch.optim.AdamW(
        [p for p in model.parameters() if p.requires_grad], lr=1e-4
    )

    # One training step at the requested ctx.  The AdamW state appears only after the
    # first step, and it is reported ANALYTICALLY (2 fp32 moments per trainable
    # parameter) because nvidia-smi cannot separate it from the activation peak in the
    # same instant - saying which of the two figures is measured and which is computed
    # is the point; mixing them would make both uncheckable.
    n_trainable = sum(p.numel() for p in model.parameters() if p.requires_grad)
    budget.optimizer_mb = (2 * 4 * n_trainable) // (1024 * 1024)
    budget.notes.append(
        f"optimizer state is analytic: 2 x fp32 x {n_trainable} trainable params"
    )

    torch.cuda.reset_peak_memory_stats()
    ids = torch.randint(0, 1000, (1, args.ctx), device="cuda")
    model.train()
    out = model(input_ids=ids, attention_mask=torch.ones_like(ids), labels=ids)
    out.loss.backward()
    optim.step()
    optim.zero_grad(set_to_none=True)
    torch.cuda.synchronize()
    step_peak = gpu_used_mb()
    if step_peak is None:
        raise RuntimeError("nvidia-smi cannot report VRAM after the step")
    budget.activations_mb = max(step_peak - after_lora - budget.optimizer_mb, 0)
    budget.notes.append(
        f"one fwd+bwd at ctx={args.ctx} (gradient checkpointing on): "
        f"peak {step_peak} MiB used"
    )

    # The rollouts: G sampled completions from ONE compact prompt.
    torch.cuda.reset_peak_memory_stats()
    prompt = torch.randint(0, 1000, (1, min(64, args.ctx)), device="cuda")
    model.eval()
    with torch.no_grad():
        model.generate(
            input_ids=prompt,
            attention_mask=torch.ones_like(prompt),
            max_new_tokens=args.gen_tokens,
            num_return_sequences=args.rollouts,
            do_sample=True,
            temperature=0.7,
            pad_token_id=tokenizer.eos_token_id,
        )
    torch.cuda.synchronize()
    rollout_peak = gpu_used_mb()
    if rollout_peak is None:
        raise RuntimeError("nvidia-smi cannot report VRAM after the rollouts")
    budget.rollouts_mb = max(rollout_peak - step_peak, 0)
    budget.peak_used_mb = max(step_peak, rollout_peak)
    return budget


def render(budget: Budget) -> str:
    """Human table for the measured budget."""
    lines = [
        f"{budget.model}  (ctx={budget.ctx}, lora_r={budget.lora_r}, "
        f"G={budget.rollouts}, gen={budget.gen_tokens})",
        f"  baseline        {budget.baseline_mb:>6} MiB",
        f"  weights (4-bit) {budget.weights_mb:>6} MiB",
        f"  high-precision  {budget.hiprec_mb:>6} MiB   (fp32 non-quantized parts)",
        f"  adapters        {budget.adapters_mb:>6} MiB",
        f"  optimizer       {budget.optimizer_mb:>6} MiB",
        f"  activations     {budget.activations_mb:>6} MiB",
        f"  rollouts        {budget.rollouts_mb:>6} MiB",
        "  -------------------------------",
        f"  trainable       {budget.trainable_mb:>6} MiB   (weights+adapters+optim+acts+G)",
        f"  reserve (20%)   {budget.reserve_mb:>6} MiB",
        f"  PEAK used       {budget.peak_used_mb:>6} MiB of {TOTAL_VRAM_MB}",
        f"  headroom        {budget.headroom_mb:>6} MiB",
        f"  verdict         {budget.verdict}",
    ]
    lines.extend(f"  note: {n}" for n in budget.notes)
    return "\n".join(lines)


def main(argv: list[str] | None = None) -> int:
    """Entry point.  See the module docstring for the measured components."""
    parser = argparse.ArgumentParser(description="Measure a GRPO/QLoRA VRAM budget")
    parser.add_argument("model", help="HF model id, e.g. Qwen/Qwen2.5-0.5B-Instruct")
    parser.add_argument("--ctx", type=int, default=2048)
    parser.add_argument("--lora-r", type=int, default=16)
    parser.add_argument("--rollouts", type=int, default=4)
    parser.add_argument("--gen-tokens", type=int, default=256)
    parser.add_argument("--json", action="store_true")
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="print the configs without loading anything",
    )
    args = parser.parse_args(argv)
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(name)s: %(message)s")

    quant, lora = build_configs(args.model, args.lora_r)
    if args.dry_run:
        print(f"model      : {args.model}")
        print(f"4-bit      : {quant}")
        print(f"lora       : {lora}")
        print(f"ctx        : {args.ctx}")
        print(f"rollouts   : {args.rollouts} x {args.gen_tokens} tokens")
        return 2

    try:
        budget = measure(args.model, args)
    except Exception as exc:  # reported, never hidden
        logger.error("measurement failed for %s: %s", args.model, exc, exc_info=True)
        return 3

    if args.json:
        print(json.dumps(budget.__dict__, indent=2, default=str))
    else:
        print(render(budget))
    return 0


if __name__ == "__main__":
    sys.exit(main())
