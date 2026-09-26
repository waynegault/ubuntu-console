# GRPO training environment (card UBC-GRPO-005)

What this records: the isolated training/rollout environments for the GRPO work, the
toolkit and driver compatibility they were verified against, and the pinned versions of
everything installed. Nothing here is used by the served runtime — see *Layout and rule*.

## One environment cannot hold the card's stack — measured 2026-09-26

The card asks for torch + CUDA wheels, unsloth, trl, bitsandbytes and vLLM in one isolated
environment. That combination does not resolve to a working set:

- vLLM 0.30.0 hard-pins `torch==2.13.0` **and** `transformers>=5.10.4`.
- With those two pins in play, the resolver is forced onto the *older* `unsloth 2025.9.5`,
  and that build fails at import:

  ```text
  File ".../unsloth/models/_utils.py", line 448, in <module>
      exec(config, globals())
  NameError: name 'auto_docstring' is not defined
  ```

  `auto_docstring` no longer exists in transformers 5.x. The failure reproduces with
  `import unsloth` **first**, so it is a version clash, not the import-order artefact
  unsloth warns about.
- Without vLLM, the same resolver picks `unsloth 2026.9.11` + `transformers 5.5.0` +
  `torch 2.12.1`, and every package in that set imports cleanly.

So the stack is provisioned as **two environments**, each isolated. That satisfies what the
card actually requires (no interference with the served runtime); it does not satisfy the
card's literal "one environment" phrasing, which the measurement above rules out.

## Declaration: toolkit and driver compatibility

Measured on this box 2026-09-26:

| Item | Value |
|---|---|
| GPU | NVIDIA GeForce RTX 3050 Ti Laptop GPU, 4 GB, compute capability **8.6** (sm_86) |
| Driver (KMD) | **616.92**; NVIDIA-SMI 615.71.08; CUDA UMD version 13.4 |
| System nvcc toolkits | `/usr/local/cuda-12.4`, `cuda-13.1`, `cuda-13.3` (default symlink → 13.3) — **not used** |
| Python | **3.12.3** (`/usr/bin/python3.12`) for both environments |
| torch CUDA runtime | **13.0** (bundled in the wheel: `torch.version.cuda == '13.0'`) |
| CUDA usable | `torch.cuda.is_available() == True`, GPU matmul verified in both environments |

No system nvcc is required or used: every wheel carries its own CUDA runtime, and the
toolchains under `/usr/local/cuda*` are irrelevant to this stack.

**Why Python 3.12.** Wheel availability was the question, and it turned out not to
discriminate: with `--no-build` and a cold cache, **3.11.15, 3.12.3 and 3.14.6 all** resolve
the whole stack from wheels. The pick is therefore on fit — 3.12.3 is the interpreter every
other environment on this box already uses (`/home/wayne/.venv`, `~/venv`, `/opt/jarvis-venv`,
the investigator venv) and the version CI pins, and it is a **different interpreter from the
served runtime's** (`python3` here is linuxbrew 3.14.6), so the training stack can never share
site-packages or a pycache generation with what serves models.

## Layout and rule

| Environment | Purpose | Path |
|---|---|---|
| `grpo-train` | GRPO/QLoRA training: torch, unsloth, trl, bitsandbytes, xformers, transformers, peft, accelerate, datasets | `/home/wayne/.venvs/grpo-train` |
| `grpo-vllm` | vLLM inference / rollout generation (its own pinned torch and transformers) | `/home/wayne/.venvs/grpo-vllm` |

**Rule:** never install the training stack into the repository's `.venv` (the dev venv), into
the interpreter the services use (`python3` → linuxbrew 3.14.6), or into the llama.cpp/ggml
build tree. Nothing in this repository sources or activates these environments; they are
reached only by an explicit absolute path. Disk: 5.3 GB and 4.3 GB respectively.

**Why that rule is not hypothetical (measured 2026-09-26).** The repository's `.venv` is not a
clean dev venv: it already carries a full `torch 2.12.1+cu130` with the `nvidia-*` cu13 runtime
(installed with **pip** — `INSTALLER: pip`, files dated 2026-06-30) plus `transformers` and
`triton` (2026-07-07), and it is 6.1 GB. That is the venv this repo's own tooling runs from
(ruff, mypy, pyright, pytest) and the one the `cd` override activates, so anything added there
sits one `python3` away from the tools. On the serving side the separation is direct: the
`llama-*` systemd units execute the `llama-cuda-server` / `llama-cpu-server` binaries, and no
server path references the repository `.venv` (the python in the launcher path is
`LLM_SERVER_PYTHON_BIN`, default `python3`).

## Reproduce

```bash
uv venv --python /usr/bin/python3.12 /home/wayne/.venvs/grpo-train
uv pip install --no-build --python /home/wayne/.venvs/grpo-train/bin/python \
    torch unsloth trl bitsandbytes xformers

uv venv --python /usr/bin/python3.12 /home/wayne/.venvs/grpo-vllm
uv pip install --no-build --python /home/wayne/.venvs/grpo-vllm/bin/python vllm
```

`--no-build` is deliberate: it forbids source builds, so an install that would need a
compiler fails loudly instead of succeeding slowly and differently.

## Resolved versions

The full pinned sets are the two lock files beside this document, generated with
`uv pip freeze --python <env>/bin/python`:

- `docs/grpo-train.lock.txt` — 101 distributions
- `docs/grpo-vllm.lock.txt` — 198 distributions

The load-bearing pins:

| | `grpo-train` | `grpo-vllm` |
|---|---|---|
| torch | 2.12.1 | 2.13.0 |
| transformers | 5.5.0 | 5.17.0 |
| triton | 3.7.1 | 3.7.1 |
| unsloth | 2026.9.11 | — |
| trl | 0.24.0 | — |
| bitsandbytes | 0.50.2 | — |
| xformers | 0.0.35 | — |
| vllm | — | 0.30.0 |

## Expected warnings (third-party; none of these is an environment defect)

- `unsloth`: `WARNING: Unsloth should be imported before [trl, transformers, peft]` — an
  instruction from the package, satisfied by importing `unsloth` first in training code.
- `unsloth/import_fixes.py:4896`: `FutureWarning: torch._dynamo.config.inline_inbuilt_nn_modules
  is deprecated` — upstream drift between unsloth and torch 2.12.
- `torch/utils/_pytree.py:630`: `Calling register_constant() on Enum subclasses is deprecated`
  — emitted by xformers/torchao registering their enums as constants.

## Importing unsloth writes into the current working directory

`unsloth` compiles trainer sources into a cache directory **in the current working directory**.
An import run from this repository created `unsloth_compiled_cache/` (1.9 MB) at the repo root
on 2026-09-26; it was removed, and it is deliberately not added to `.gitignore`, because the
right fix is not to live with it. The package reads `UNSLOTH_COMPILE_LOCATION`
(`unsloth/models/_utils.py:3885`), so training code must set that to a path outside this
repository — or simply run from a dedicated working directory — otherwise a training run
litters the tree that this repo's own gates read.

## Verified, and not verified

Verified 2026-09-26: both environments import every headline package, and both report
`torch.cuda.is_available() == True` on this GPU; a real 512×512 GPU matmul was executed in
the first environment.

**Not** verified here: that a GRPO run *fits* in 4 GB — that is the measured per-run budget of
card UBC-GRPO-003 — and vLLM was import-verified only, not exercised for serving. Serving a
trained artifact remains card UBC-GRPO-004.
