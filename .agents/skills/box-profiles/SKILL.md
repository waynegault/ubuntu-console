---
name: box-profiles
description: >-
  Hardware profile definitions, VRAM limits, and serving configuration across Asus ProArt P16
  (RTX Spark N1X GB10) and Dell XPS 15 (RTX 3050 Ti + Intel Iris Xe). Use when querying,
  testing, or configuring box-specific LLM serving parameters.
---

# Box Profiles & Hardware Sizing Reference

Ubuntu Console operates across two distinct hardware targets. Code, configuration, and tools must resolve box identity dynamically via `tools.box` or `tools/host-profile.sh` and never assume one machine's constraints.

## Target Profiles

### 1. Asus ProArt P16 / RTX Spark N1X (`asus-n1n-rtx-spark`)
- **Host Architecture**: `aarch64` (10x Cortex-X925 + 10x Cortex-A725, 20 logical cores).
- **GPU Architecture**: NVIDIA Blackwell GB10 / RTX Spark N1X (`sm_121a`, `LLAMA_CUDA_ARCH="121a-real"`).
- **Memory Model**: 128 GB unified LPDDR5X (`TAC_HOST_PROFILE_SHARED_MEMORY=1`). Sized with a 12,288 MiB host reserve (`LLAMA_FIT_KEEP_RESERVE_MB=12288`), active 32,768 MiB (32 GB) GPU carve.
- **Offload Strategy**: Full offload (`LLAMA_GPU_LAYERS=999`, `ngl_strategy="full_only"`), `parallel_slots=4`, `threads_base=10`, `thread_cap=0`.
- **Primary Serving Services**:
  - Chat: `llama-cuda-qwen3coder-30b-chat.service` on port `18087`.
  - Embeddings: `llama-cuda-qwen3embedding-embed.service` on port `18080`.
- **WSL2 Discovery Quirk**: `nvidia-smi --query-compute-apps=pid` returns empty on unified memory under WSL2. Process discovery must inspect `/proc/[0-9]*/cmdline` for `llama-server` (excluding `build-opencl` and `build-cpu`), and recognize `/proc/1/comm` values `("systemd", "exe", "init")` as valid PID 1 supervisors.

### 2. Dell XPS 15 (`intel-xe-cuda`)
- **Host Architecture**: `x86_64` (Intel Core i9-12900HK hybrid 6P + 8E cores).
- **GPU Architecture**: NVIDIA GeForce RTX 3050 Ti Laptop (`sm_86`) + Intel Iris Xe iGPU (`TAC_HOST_PROFILE_XE=1`).
- **Memory Model**: 4,096 MiB (4 GB) discrete CUDA VRAM (`TAC_HOST_PROFILE_SHARED_MEMORY=0`).
- **Offload Strategy**: Partial offload (`LLAMA_GPU_LAYERS=24`), `parallel_slots=1`, `threads_base=6`, with hybrid P-core ceiling `LLAMA_THREAD_CAP=6` to prevent decode threads from spilling onto slower E-cores.
- **Primary Serving Service**: `llama-xe-minicpm5-1b-chat.service` on port `18081`.

## Querying Box Identity & Headroom

Always query profiles dynamically using `.venv/bin/python3 -m tools.box.cli`:

```bash
# Query active box profile and hardware metrics as JSON
.venv/bin/python3 -m tools.box.cli --json

# Human-readable summary
.venv/bin/python3 -m tools.box.cli

# In shell scripts:
source tools/host-profile.sh
# Provides: TAC_HOST_PROFILE_NAME, TAC_HOST_PROFILE_SHARED_MEMORY, LLM_SERVICE_PORT, etc.
```

## Hardware Rules & Constraints
1. **Never Hardcode VRAM Sizes**: Always query via `tools.box.prober.Prober.probe_gpu_memory()` or `_tac_gpu_used_mib`.
2. **Never Hardcode Thread Counts**: Threads must respect `LLAMA_THREAD_CAP` (capped at 6 on hybrid Intel x86_64; base 10 on ARM64 Cortex-X925).
3. **Respect Watchdog Locks**: Check `/dev/shm/llama-watchdog-cuda.suspend` before touching active CUDA serving lanes.
