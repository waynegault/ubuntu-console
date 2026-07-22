---
title: llama.cpp CUDA Build Guide
description: Definitive guide to building a custom-tuned llama.cpp from source with CUDA acceleration for the Tactical Console's RTX 3050 Ti 4GB system.
---

# llama.cpp CUDA Build Guide

## Purpose

The Tactical Console uses a **custom-tuned** `llama-server` binary built from
source at [`github.com/ggml-org/llama.cpp`](https://github.com/ggml-org/llama.cpp)
with CUDA acceleration. Building from source rather than using a generic prebuilt
release gives the best performance for this specific hardware:

- **CPU-specific optimisations** — CMake with `-DGGML_NATIVE=ON` detects the
  exact CPU (i9-12900HK Alder Lake) and enables AVX2, FMA, BMI2, and other
  instruction sets that a generic binary cannot assume.
- **CUDA architecture targeting** — `-DCMAKE_CUDA_ARCHITECTURES=86` targets
  the RTX 3050 Ti's Ampere SM directly, avoiding fallback to generic CUDA
  kernels.
- **Shared library split** — `-DBUILD_SHARED_LIBS=ON` compiles GPU backends
  (`libggml-cuda.so`) as separate loadable modules so `llama-server` stays
  small and the GPU backend can be updated independently.

---

## Hardware

```text
CPU:  12th Gen Intel Core i9-12900HK (16 cores, Alder Lake)
GPU:  NVIDIA GeForce RTX 3050 Ti Laptop GPU  (4 GB VRAM, Compute Capability 8.6)
RAM:  45 GB
Disk: SSD (WSL2 on NTFS via drvfs)
```

> **Why SM 86?** The RTX 3050 Ti is an Ampere GA107 chip with compute capability
> 8.6 (not 8.0 like A100 or 8.9 like Ada). Setting `CMAKE_CUDA_ARCHITECTURES=86`
> ensures CUDA kernels are compiled for this exact SM rather than falling back to
> a generic PTX path that runs slower.

---

## Prerequisites

| Package | Purpose | Verification |
|---|---|---|
| CUDA Toolkit ≥ 13.1 | nvcc, cuBLAS, cuSOLVER | `ls /usr/local/cuda/bin/nvcc` |
| NVIDIA driver ≥ 596 | Runtime CUDA support | `nvidia-smi` |
| CMake ≥ 3.28 | Build system | `cmake --version` |
| GCC ≥ 13 | C++17 host compiler | `gcc --version` |
| ccache | Accelerate rebuilds | `which ccache` |
| curl | HTTP health checks in autotune | `which curl` |
| OpenSSL dev | TLS for llama-server | `dpkg -l \| grep libssl` |

On Ubuntu 24.04 (WSL2):

```bash
# CUDA Toolkit is typically installed at /usr/local/cuda by the NVIDIA
# WSL2 driver package.  Verify it:
ls /usr/local/cuda/bin/nvcc
# GCC and build tools:
sudo apt install build-essential cmake ccache libssl-dev
```

---

## Build Procedure

### 1. Clone

```bash
git clone https://github.com/ggml-org/llama.cpp.git ~/llama.cpp
cd ~/llama.cpp
```

### 2. Configure with CMake

```bash
cmake -B build \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_CUDA_ARCHITECTURES=86 \
  -DGGML_CUDA=ON \
  -DGGML_CUDA_FA=ON \
  -DGGML_CUDA_FA_ALL_QUANTS=ON \
  -DGGML_CUDA_GRAPHS=ON \
  -DGGML_CUDA_NCCL=ON \
  -DGGML_CUDA_FORCE_MMQ=OFF \
  -DGGML_CUDA_COMPRESSION_MODE=size \
  -DGGML_NATIVE=ON \
  -DGGML_OPENMP=ON \
  -DGGML_CCACHE=ON \
  -DBUILD_SHARED_LIBS=ON \
  -DLLAMA_BUILD_SERVER=ON \
  -DLLAMA_BUILD_EXAMPLES=ON \
  -DLLAMA_BUILD_TESTS=ON
```

**Flag reference:**

| Flag | Value | Effect |
|---|---|---|
| `CMAKE_BUILD_TYPE` | `Release` | `-O3 -DNDEBUG` — full optimisation, no debug asserts |
| `CMAKE_CUDA_ARCHITECTURES` | `86` | Compile CUDA kernels for Ampere GA107 (RTX 3050 Ti) |
| `GGML_CUDA` | `ON` | Enable NVIDIA CUDA GPU backend (the key flag) |
| `GGML_CUDA_FA` | `ON` | Flash Attention v2 CUDA kernels — ~2× prompt processing speedup. Reduces memory bandwidth usage for the attention mechanism. |
| `GGML_CUDA_FA_ALL_QUANTS` | `ON` | Apply flash attention to all quantisation types, not just high-bit ones |
| `GGML_CUDA_GRAPHS` | `ON` | CUDA Graph capture — launches repeated inference patterns as a single graph kernel, reducing kernel launch overhead for batched/continuous batching |
| `GGML_CUDA_NCCL` | `ON` | NCCL multi-GPU support (harmless when only one GPU is present) |
| `GGML_CUDA_FORCE_MMQ` | `OFF` | Keep the default cuBLAS matmul path (MMQ is slower on Ampere) |
| `GGML_CUDA_COMPRESSION_MODE` | `size` | Compress CUDA model weights in VRAM to save memory. Trade-off: slightly higher TPS cost, significantly more VRAM headroom for larger context. |
| `GGML_NATIVE` | `ON` | Detect host CPU and enable all available instruction sets (AVX2, FMA, BMI2 on i9-12900HK). Without this flag, only a portable baseline is used. |
| `GGML_OPENMP` | `ON` | OpenMP parallelisation for CPU fallback layers. Essential when VRAM is tight and some layers land on CPU. |
| `GGML_CCACHE` | `ON` | Cache compiled object files. On a 16-core machine this is marginal for clean builds but **significantly** speeds up incremental rebuilds after `git pull`. |
| `BUILD_SHARED_LIBS` | `ON` | Build GPU backends as shared libraries (`libggml-cuda.so`). Keeps `llama-server` small and allows updating the CUDA backend independently. The generic prebuilt release also uses this layout. |
| `LLAMA_BUILD_SERVER` | `ON` | Build `llama-server` (the HTTP API binary used by the Tactical Console) |
| `LLAMA_BUILD_EXAMPLES` | `ON` | Build `llama-cli`, `llama-bench`, and other utility tools |
| `LLAMA_BUILD_TESTS` | `ON` | Build test binaries for validation |

> **Other backends:** The configuration above leaves GPU backends like Vulkan,
> HIP (AMD), Metal (Apple), SYCL (Intel), and OpenCL disabled because this
> machine uses NVIDIA CUDA. They can be enabled by adding their `-DGGML_*=ON`
> flags if needed, but they increase build time and binary size.

### 3. Build

```bash
cmake --build build --target llama-server -j$(nproc)
```

Build time on the i9-12900HK with 16 threads and ccache:

| Scenario | Time |
|---|---|
| Clean build (first time) | ~30–45 min (CUDA kernel compilation is the bottleneck) |
| Incremental rebuild (small change) | ~1–5 min |
| Rebuild after `git pull` (few changed files) | ~5–15 min |

To build all targets (for benchmarking and testing):

```bash
cmake --build build -j$(nproc)
```

### 4. Verify

```bash
# 4a. Check the binary exists and is executable
ls -lh build/bin/llama-server

# 4b. Verify CUDA support is compiled in
build/bin/llama-cli --help 2>&1 | grep -i cuda
# Expected: "CUDA support: YES" or similar

# 4c. Quick inference smoke test (will fail without a model file — that's OK)
build/bin/llama-server --version 2>&1 || true

# 4d. Check that the shared CUDA library was built
ls -lh build/libggml-cuda.so
# Expected: libggml-cuda.so (tens of MB)
```

---

## Installing the Built Binary

The Tactical Console's `LLAMA_SERVER_BIN` points to
`~/llama.cpp/build/bin/llama-server` by default (set in
`scripts/01-constants.sh`). No installation step is needed — the binary is used
directly from the build directory.

A convenience symlink is also maintained:

```bash
# ~/.local/bin/llama-server-cuda -> ~/llama.cpp/build/bin/llama-server
ln -sf ~/llama.cpp/build/bin/llama-server ~/.local/bin/llama-server-cuda
```

This is the **custom-tuned** binary. The generic prebuilt release lives at
`~/.local/bin/llama-server` → `~/.local/opt/llama.cpp/b<N>/llama-server`.

---

## Updating

```bash
cd ~/llama.cpp

# 1. Pull latest upstream changes
git pull --ff-only

# 2. Rebuild (CMake re-configures automatically if CMakeLists.txt changed)
cmake --build build --target llama-server -j$(nproc)

# 3. Verify
ls -lh build/bin/llama-server
build/bin/llama-cli --help 2>&1 | grep -i cuda

# 4. Update the convenience symlink
ln -sf ~/llama.cpp/build/bin/llama-server ~/.local/bin/llama-server-cuda
```

> **Why `--ff-only`?** The llama.cpp project moves fast and occasionally
> force-pushes to `master`. `git pull --ff-only` will refuse to pull if a
> force-push requires a rebase, alerting you to check the upstream before
> proceeding.

---

## Optimisation Notes for 4 GB VRAM

The RTX 3050 Ti's 4 GB VRAM is the primary constraint. The build flags above
are chosen to squeeze every token out of this limited budget:

**`-DGGML_CUDA_COMPRESSION_MODE=size`**
Compresses model weights in VRAM at a small TPS cost. On a 4 GB card this can
be the difference between fitting a 3B model at 8K context vs 4K context.

**`-DGGML_CUDA_FA=ON` (Flash Attention)**
Flash Attention reduces the memory footprint of the KV cache's attention
computation from O(n²) to O(n) in a way that's particularly impactful at
context sizes >4K. On a 4 GB card this directly translates to more usable
context.

**`-DLLAMA_BUILD_SERVER=ON` only**
Building only `llama-server` (not all examples) saves ~5 minutes of build time.
The full `cmake --build build -j$(nproc)` builds all tools including
`llama-bench` (useful for regression testing) and `llama-cli` (useful for
quick tests), but they are not needed for normal operation.

**Offloading strategy (`--n-gpu-layers`)**
The Tactical Console's `__calc_gpu_layers` function dynamically determines how
many layers to offload based on model size vs free VRAM. For a typical 3B
model at Q4_K_M (~2 GB GGUF), all layers fit on GPU. For larger models,
partial offload keeps context size high at the cost of some CPU fallback
layers — the function finds this balance automatically.

**`--fit off` in autotune**
llama.cpp build b8210 has a projection bug when `--fit on` is combined with
explicit `--ctx-size`, `--batch-size`, and `--ubatch-size` flags. The autotune
script always passes `--fit off` to avoid OOM projection errors.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `nvcc` not found | CUDA Toolkit not on PATH | `export PATH=/usr/local/cuda/bin:$PATH` or install the CUDA toolkit via the NVIDIA WSL2 driver package |
| `fatal error: cuda_runtime.h` | CUDA include paths not configured | CMake should auto-detect. If not: `cmake -B build -DCUDAToolkit_ROOT=/usr/local/cuda ...` |
| Build fails with `cc1plus: out of memory` | Parallel compilation of large CUDA files | Reduce parallelism: `cmake --build build --target llama-server -j4` |
| `libggml-cuda.so` not found at runtime | `LD_LIBRARY_PATH` doesn't include build dir | `export LD_LIBRARY_PATH=$HOME/llama.cpp/build:$LD_LIBRARY_PATH` |
| `CUDA error: out of memory` during inference | Model + KV cache exceeds 4 GB VRAM | Use a smaller quant (Q3_K_M instead of Q4_K_M), reduce `--ctx-size`, or reduce `--n-gpu-layers` |
| `GGML_ASSERT` failure at startup | Corrupted or incompatible GGUF file | Re-download the model or check it with `llama.cpp/build/bin/llama-cli --model <file> --check-tensors` |
| Server binds but `/health` never returns OK | Port conflict (watchdog on 8081) | The Tactical Console uses `AUTOTUNE_PORT` (18081) for autotune and `LLM_PORT` (8081) for the watchdog. The `model use` command manages port allocation automatically. |
| Performance regression after update | New commit changed default behaviour | Check `git log --oneline HEAD..HEAD@{1}` to see what changed. Common culprits: flash-attn defaults, batch size heuristics, GPU layer count algorithms. |
| Generic symlink broken after update | The `~/.local/bin/llama-server` symlink points to a stale release dir | Re-run `bats tests/unit/04-llama-cpp-inventory.bats --filter "update generic"` (with network) to auto-download the latest release, or manually: `ln -sf ~/.local/opt/llama.cpp/b<N>/llama-server ~/.local/bin/llama-server` |

---

## Related

- [LLM System Overview](llm.md) — model registry, lifecycle commands, chat
- [Autotune Specification](autotune_spec.md) — how model parameters are discovered
- [Architecture Guide](architecture.md) — project module layout
- Upstream: [github.com/ggml-org/llama.cpp](https://github.com/ggml-org/llama.cpp)
- Prebuilt releases: [github.com/ggml-org/llama.cpp/releases](https://github.com/ggml-org/llama.cpp/releases)
- Tactical Console inventory test: `tests/unit/04-llama-cpp-inventory.bats`
