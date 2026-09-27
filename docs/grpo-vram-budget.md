# GRPO training VRAM budget on the 4 GB card (card UBC-GRPO-003)

Measured, not estimated: the audit doc this card came from is explicit that a parameter
count is not a fit verdict (a 4-bit Qwen2.5-1.5B is ~1 GB of weights, and the run that OOMs
this card does so because of what sits BESIDE the weights — REF below, §11.3). Everything
in the tables is a reading of this box's RTX 3050 Ti, taken with
`scripts/grpo-vram-probe.py`.

## How the measurement was taken

The probe ran under `bin/train-timeout-runner.sh`, which holds the bench lock — the same
tenancy path a real training run uses, so `bin/gpu-busy.sh` reported the card busy and
`llama-watchdog` stood the CUDA lane down by its own rule rather than being raced for the
card. The lane was stopped explicitly (the documented bench/autotune behaviour, which is
why the suspend file was **not** used: a stale one would hold the lane down indefinitely)
and the measurement refused to start until VRAM read 0 MiB.

Settings measured — the card's own edge case: `ctx=2048`, LoRA `r=16` (alpha 32) on
q,k,v,o,gate,up,down, G=4 rollouts of 256 tokens, gradient checkpointing on, batch 1.

## Measured budget

`Qwen/Qwen2.5-0.5B-Instruct`

| component | MiB |
|---|---|
| 4-bit weights (nf4, double quant, bf16 compute) | 554 |
| high-precision (fp32 non-quantized parts, incl. the fp32 `lm_head`) | 520 |
| LoRA adapters (8,798,208 trainable params) | 34 |
| AdamW state (analytic: 2 × fp32 × trainable) | 67 |
| activations, one fwd+bwd at ctx 2048 (checkpointing on) | 2776 |
| G=4 rollouts (256 tokens each) | 0 (no peak above the step) |
| **peak used** | **3951 of 4096** |
| headroom / reserve (20 % of free) | 145 / 819 |
| verdict | **edge** |

`Qwen/Qwen2.5-1.5B-Instruct`

| component | MiB |
|---|---|
| 4-bit weights | 1240 |
| high-precision (fp32 non-quantized parts) | 892 |
| LoRA adapters (18,464,768 trainable params) | 72 |
| AdamW state (analytic) | 140 |
| activations, one fwd+bwd at ctx 2048 | 1608 |
| G=4 rollouts (256 tokens each) | 0 (no peak above the step) |
| **peak used** | **3952 of 4096** |
| headroom / reserve | 144 / 819 |
| verdict | **edge** |

## What the numbers say

- **The activations term dominates, and it is the vocabulary, not the model, that sets
  it.** A 2048-token step produces `lm_head` logits of shape (1, 2048, 151936): ~622 MB in
  bf16, plus their gradients, plus the fp32 cross-entropy. That is why a 0.5B model costs
  ~2.8 GB to take a step on, and why the 1.5B's extra ~1.1 GB of weights is partly offset
  by its lower step peak. The article's own framing, in this card's numbers.
- **Neither model is "comfortable" at ctx 2048.** Both land within ~145 MiB of the card's
  limit, so any longer prompt, larger G, or a second copy of anything OOMs them. The card's
  premise that 0.5B is comfortable is therefore **not** supported at its own edge settings;
  what the measurements support is that **0.5B is comfortable only with a shorter context**
  — the logits term scales linearly with `ctx`, so ~512 tokens should put it near ~0.7 GB
  of activations instead of ~2.8 GB. That figure is an inference from the measured linear
  term and is NOT measured here; the probe takes `--ctx`, so it is one run away.
- **The fp32 high-precision parts are a real, previously invisible component**: peft's
  `prepare_model_for_kbit_training` upcasts the non-quantized parts, and on a 152k vocabulary
  the fp32 `lm_head` alone is ~520 MiB (0.5B) / ~892 MiB (1.5B). Any budget that counts only
  "4-bit weights + optimiser" misses a third of a gigabyte.
- **Read both peaks as "at the ceiling", not as a comfortable fit.** They sit within ~145 MiB
  of the card's limit, and a REPEAT run of the 0.5B had not finished its training step after
  ~6 minutes (the first run reported one), so the step cost rises sharply once the card is
  full. Whether the card paged host-side — WSL's shared GPU memory can page instead of
  OOMing — or the step is simply that heavy at the limit is **not** established here; what is
  established is that these figures bound what fits rather than describing a configuration
  with room in it. The repeat was stopped rather than left to grind, and the card was
  restored (lane active, `/health` 200) before this was written.
- **The reference model costs nothing extra**, which is what makes a 1.5B QLoRA run arguable
  at all: verified in trl's source rather than assumed — `grpo_trainer.py` sets
  `self.ref_model = None` when the policy is a PEFT model ("the adapter can be disabled to
  revert to the initial model").
- **The rollouts did not move the peak.** G=4 × 256 tokens of KV is small next to a
  2048-token step over a 152k vocabulary. That is a measurement of the HF path; a production
  run may roll out through vLLM instead (its own environment, see
  `docs/grpo-training-env.md`), whose accounting differs.

## Consistency with `config/quant-guide.conf`

That guide rates **inference GGUF** quants for llama.cpp (Q4_K_M "recommended", Q2/Q3
"acceptable", F16 "discouraged" on this card). This budget is about **training** with
bitsandbytes nf4 — a different axis, and the two must not be read as one number. What they
do agree on is the conclusion: on 4 GB the budget is tight, the quantisation choice matters,
and a configuration that looks small by parameter count can still not fit.

## What this budget does NOT cover

A real dataset and reward, checkpointing to disk, CPU offload, a second card, the Xe and CPU
tiers (different hardware — nothing here says anything about them), and vLLM rollouts. Each
is named so the boundary is visible rather than implied by a tidy table.

## Reproduce

```bash
# take the card as the training path does, then measure (0 MiB of VRAM before starting)
~/.venvs/grpo-train/bin/python scripts/grpo-vram-probe.py Qwen/Qwen2.5-0.5B-Instruct
~/.venvs/grpo-train/bin/python scripts/grpo-vram-probe.py Qwen/Qwen2.5-1.5B-Instruct
```

`scripts/grpo-vram-probe.py --dry-run` prints the exact 4-bit and LoRA configs without
touching the GPU, and `tests/test_grpo_vram_probe.py` pins the arithmetic (the component sum,
the 20 %-of-free reserve, and the verdict rule).

REF: "How GRPO Trains Small Language Models with Verifiable Rewards" (Benjamin Nweke, TDS,
2026-09-23), and the audit doc's §11.3 —
`/home/wayne/investigator/docs/tds/tds-grpo-small-models-verifiable-rewards.md`.
