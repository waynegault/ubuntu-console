# ASUS ProArt P16 (H7607BA / RTX Spark N1X 128GB) — Verified Hardware & LLM Optimization Brief

**Author**: Terminal `agy` Session (Collaborating with VS Code `agy` `/teamwork` Swarm)
**Date**: 2026-11-10
**Target Milestone**: Milestone 2 (`Unified Box Awareness Subsystem` — `tools/box/`, `11d-llm-gpu.sh`, `11e-llm-model.sh`, `autotune-model.sh`, `llm_benchmark.py`, `asus-rtx-spark-quant-guide.conf`)

---

## 1. Verified Hardware Topology (ASUS H7607BA / NVIDIA RTX Spark N1X)

| Subsystem | Verified Specification | Source / Evidence |
|---|---|---|
| **SoC** | **NVIDIA RTX Spark N1X** (GB10-class Blackwell + Grace-derived ARMv9-A die-to-die NVLink-C2C) | Windows WMI `Win32_Processor` & `nvidia-smi` |
| **Physical CPU Cores** | **20 cores in 2 clusters: `10× Cortex-X925` (2 MB L2/core, 4.0 GHz) + `10× Cortex-A725` (512 KB L2/core)** | `Win32_Processor.L2CacheSize = 25600 KB` ($10\times2048 + 10\times512\text{ KB}$), `L3CacheSize = 24576 KB`; NVIDIA `dgx-spark-skills` |
| **WSL2 Hyper-V CPU Exposure** | Exposes 20 uniform vCPUs (`MIDR_EL1 = 0x410fd851` = `0xd85` Cortex-X925, 2048 KB L2) in `/proc/cpuinfo` | Windows Thread Director schedules the first 10 active compute threads onto the 10 physical X925 cores; threads 11–20 spill onto the slower A725 cores |
| **GPU Architecture** | **6,144-core Blackwell RTX GPU**, Compute Capability **`12.1` (`sm_121a`)**, Driver `621.01` / CUDA `13.4` | `nvidia-smi --query-gpu=name,compute_cap`; NVCC `/usr/local/cuda-13.4/bin/nvcc` |
| **Unified Memory (UMA)** | **128 GB LPDDR5X-8533** (256-bit, ~273 GB/s bandwidth), shared between Windows host, WSL2 guest (`memory=102GB`), and WDDM GPU carve (`81,920–98,304 MiB`) | `/mnt/c/Users/wayne/.wslconfig` (`memory=102GB`, `kernelCommandLine=sysctl.vm.swappiness=10`) |

---

## 2. Critical Guidance for Milestone 2 (`tools/box/` & LLM Tooling)

### 2.1 CPU Thread Allocation (`cpu_threads_base = 10`, `LLAMA_THREAD_CAP = 0`)
- **Contract invariant**: Keep `LLAMA_THREAD_CAP=0` in `config/hosts.d/asus-n1n-rtx-spark.conf` and `tools/box/profiles.py` (`thread_cap = 0`) because `tests/unit/74-host-profiles.bats` and `tests/e2e/test_harness_sanity.py` pin `LLAMA_THREAD_CAP == "0"`.
- **Operational target**: Always set `cpu_threads_base = 10` (half of 20 vCPUs) so `llama-server`, `autotune-model.sh`, and `llm_benchmark.py` run **10 compute threads** on the 10 physical Cortex-X925 cores and never spill onto the 10 Cortex-A725 cores (where GGML barrier synchronization stalls on the slowest core).

### 2.2 `llm-build` CMake Flags (`scripts/11e-llm-model.sh` v117 & `asus-n1n-rtx-spark.conf`)
- **Completed in `v117`**:
  - `LLAMA_CUDA_ARCH=121a-real`: Targets Blackwell `sm_121a` directly so `nvcc` compiles architecture-specific Tensor Core instructions (`tcgen05` / FP4 / block-scaled MMA) as native SASS without PTX bloat.
  - `LLAMA_CUDA_FA_QUANTS=all`: Uses upstream `llama.cpp`'s `GGML_CUDA_FA_QUANTS=all` (replacing the deprecated `GGML_CUDA_FA_ALL_QUANTS=ON` which emits a CMake warning) so all KV cache quant combinations (`q8_0`, `q4_0`, `q4_1`, `q5_0`, `q5_1`, `f16`, `bf16`) have native CUDA FlashAttention kernels.
  - `/home/wayne/llama.cpp/build-cuda` has already been rebuilt with `121a-real` and `FA_QUANTS=all` at commit `c75fba30c` (build 264).

### 2.3 Unified Memory `mmap` Policy (`scripts/11e-llm-model.sh` v117)
- **Completed in `v117`**:
  - Under `no_mmap_mode=auto`, single-file GPU-offloaded GGUFs on a shared-memory host with a native `ext4` store (`TAC_HOST_PROFILE_SHARED_MEMORY=1`, `TAC_HOST_PROFILE_MODEL_STORE_IS_MOUNT=0`, `moe_offload_flag=""`, non-sharded) now keep `use_no_mmap=0` (`mmap:on`) instead of passing `--load-mode none`.
  - **Why**: Passing `--load-mode none` with `--fit on` forces `llama-server` to `read()` the entire 15–73 GB GGUF into anonymous heap **twice** (once during the `--fit` probe and once during context creation), turning a **6-second** page-cache load into a **55–160 second** load and doubling transient host RAM pressure.

### 2.4 Full GPU Offload (`gpu_layers = 999`) & Quantization Guide (`F11`)
- On unified memory (`asus-n1n-rtx-spark`), both dense and MoE models that fit within `MemTotal - 12288 MiB` (~87.6 GiB on the 102 GB `.wslconfig` allocation) must use `gpu_layers = 999`.
- **Why `-ngl <block_count>` is a bug on MoE**: A model with $N$ transformer blocks has $N+1$ offloadable layers ($N$ blocks + 1 `output.weight` head). Passing `-ngl 48` on a 48-block model offloads `48/49` layers and leaves the final output projection layer on the CPU (`53.7 tok/s` vs `69.5–78.2 tok/s` with `-ngl 999`).
- **Active Registry (`/home/wayne/models/active/models.conf`)**:
  - Updated and verified: rows `#1`, `#2`, `#3`, `#4`, `#5`, `#6`, `#7`, `#8` all use `gpu_layers=999` and `threads=10`.
  - Row `#5` (`Qwen3.8-27B-UD-Q4_K_M.gguf`) is wired with `draft-mtp` (`mtp-Qwen3.8-27B-Q4_0.gguf`, `spec_draft_n_max=3`, `spec_draft_ngl=999`).
- **For `config/hosts.d/asus-rtx-spark-quant-guide.conf` (F11)**:
  - Models $\le 35\text{B}$: recommend `Q8_0`, `Q6_K`, `Q5_K_M`, `Q4_K_M`, `BF16`/`F16`.
  - Models $70\text{B}\text{–}123\text{B}$: recommend `Q4_K_M`, `UD-Q4_K_XL`, `MXFP4_MOE`, `Q5_K_M` (up to ~85 GB GGUF).
  - Deprecate `Q2_K` / `IQ2_*` on 128 GB unified memory (unnecessary quality loss when `Q4_K_M`–`Q8_0` fit entirely in unified memory).

### 2.5 Empirical Test-Launch Results on Row `#5` (`Qwen3.8-27B-UD-Q4_K_M.gguf` + `draft-mtp`)
- **Single-token decode baseline (no draft model, `-ngl 999`, `t=10`)**: `13.9–14.09 tok/s` (~79% of theoretical LPDDR5X peak bandwidth $273\text{ GB/s} / 15.3\text{ GB} \approx 17.8\text{ tok/s}$).
- **With `draft-mtp` (`mtp-Qwen3.8-27B-Q4_0.gguf`, `n_max=3`, `spec_draft_ngl=999`, `--spec-draft-backend-sampling`)**:
  - **Sustained generation speed**: **`19.63 tok/s`** (`22.20 tok/s` 3s peak window) — a **+39.3% throughput gain** breaking past the single-token memory bandwidth wall.
  - **Draft acceptance**: `39.19%` (`107 accepted / 273 generated`), **`mean len = 2.16` tokens/step**.
- **`--fit on` vs `--fit off` on certified Unified Memory rows**:
  - With `--fit off`, `#5` loads and begins generating in **< 8 seconds**.
  - With `--fit on`, `llama_params_fit` performs a dry-run load of both the 15.3 GB target model and the 1.6 GB draft model before loading them a second time (taking ~121s). Already-certified (`autotuned=yes`) rows that pass `__model_use_fit_preflight` on unified memory benefit substantially from `--fit off`.
