# Serving a trained artifact — the path, the provenance, and the prompt contract

*Card UBC-GRPO-004. Companion to `grpo-training-env.md` (the isolated training environment,
UBC-GRPO-005) and `grpo-vram-budget.md` (the measured training budget, UBC-GRPO-003). The
investigator half — which artifact, which hardware route — is GRPO-L4-008.*

REF: "How GRPO Trains Small Language Models with Verifiable Rewards" (Benjamin Nweke, TDS,
2026-09-23) — <https://towardsdatascience.com/how-grpo-trains-small-language-models-with-verifiable-rewards/>
The rule this document exists for is §4 of that audit: **a reward win measured under a prompt
template that then moves is not a win.**

## The decision

A trained artifact is served **through the ordinary registry row**, not through a side channel.

That is deliberate: every consumer — `bin/llama-{cpu,cuda,xe}-server`, `scripts/11c-llm-server.sh`,
`scripts/11e-llm-model.sh`, the autotuner and the `systemd/llama-*.service` templates — reads the
same 37-field row in `~/.llm/models.conf`. A trained model that needed its own launch path would
drift from the runtime the moment either side changed, and the drift would be invisible until a
serving failure. So a trained model is *just a row*, and everything that makes it a trained model
is carried **beside** the row instead of inside it.

## The path

```bash
# 1. Convert the trained checkpoint to GGUF (this repo IS the llama.cpp tree).
python3 convert_hf_to_gguf.py <trained-checkpoint-dir> --outfile <name>.f16.gguf
# 2. Quantize to what the card being served can hold (llama-quantize is built here).
./build/bin/llama-quantize <name>.f16.gguf <name>.Q4_K_M.gguf Q4_K_M
# 3. Put it where served models live, and let the registry see it.
cp <name>.Q4_K_M.gguf "$LLAMA_MODEL_DIR/"
oc model scan
# 4. Register it with its provenance — this is the step that cannot be skipped.
oc model register-trained <name>.Q4_K_M.gguf \
    --benchmark <bench id> --held-out <held-out set id> [--prompt-set <set>] [--notes '…']
```

Step 4 refuses unless `--benchmark` **and** `--held-out` are given, refuses a file that is not a
GGUF, and refuses a file with no registry row. Each refusal names what is missing. That is the
whole enforcement: a trained artifact whose provenance is unknown is the hand-placed file this
card exists to stop, and registration is the cheapest moment to say so.

`--prompt-set` names a set from `scripts/prompt-sets.sh` (`all`, `physics`/`chat`, `legal`,
`agentic`); it defaults to `all`.

## Provenance: what a row cannot say

A row records what the runtime needs — file, quant, arch, context, throughput. It cannot record
*why the artifact exists*. That lives in `~/.llm/provenance/<model-file>.json`, written by
`model register-trained`:

```json
{
  "model_file": "<name>.Q4_K_M.gguf",
  "sha256": "<the artifact's own hash>",
  "benchmark": "<which benchmark scored it>",
  "held_out": "<which held-out set it was measured on>",
  "prompt_set": "legal@ab12cd34ef56",
  "registered_at": "2026-09-27T15:41:02+01:00",
  "notes": "..."
}
```

Two properties matter:

- **Keyed by the model FILE name**, the registry's own identity rule (`tests/unit/14-registry-identity.bats`).
  A `model scan` that renumbers rows cannot move provenance onto a different model, and a row
  number captured before a scan is never the thing stored.
- **`sha256` ties the record to the bytes.** A re-quantized or re-converted file is a different
  artifact, so the hash is what makes "this row is that trained model" checkable rather than
  asserted.

## The prompt contract

`scripts/prompt-sets.sh` **is** the served prompt contract; `__prompt_set_revision <set>` is its
content address (`legal@ab12cd34ef56` — sha256 over the set's display names and prompt bodies).

A revision is recorded with every trained artifact, so the template it was trained under is a
fact that can be re-checked rather than assumed. Re-run the revision before trusting an older
reward number:

```bash
oc llm register-trained … --prompt-set legal      # records legal@<rev>
# …later, before comparing a reward…
source scripts/prompt-sets.sh && __prompt_set_revision legal   # a different revision ⇒ the
                                                              # comparison is not apples-to-apples
```

Pin the prompt set for the whole training run: changing a prompt body mid-run means the later
reward and the earlier reward were measured under different contracts, and the run's own numbers
will not show it.

## Verified, and not verified (2026-09-27)

- **Verified:** the revision is a content address (same content ⇒ same revision; a changed prompt
  body moves it; an unknown set is refused); the sidecar is keyed by file name and survives a
  renumber; `register-trained` refuses without `--benchmark`/`--held-out`, refuses a non-GGUF and
  a file with no row, and records the artifact's hash plus the contract revision; the library it
  needs is loaded on demand and a library it **cannot** load is refused rather than skipped.
  All pinned in `tests/unit/14-registry-identity.bats` (7 cases).
- **Not verified, because no trained artifact exists yet:** the convert and quantize steps were
  **not** executed here — the commands above are the path this repo already carries
  (`convert_hf_to_gguf.py`, `build/bin/llama-quantize`), but their exact invocation against a
  real GRPO checkpoint is untested until GRPO-L4-008 produces one. Until then, treat step 1–2 as
  the documented path, not as a measured one.
- **Out of scope here:** which artifact and which hardware route (GRPO-L4-008), and the
  environment the training itself runs in (`grpo-training-env.md`).
