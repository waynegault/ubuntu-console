---
name: autotune-operator
description: >-
  Runbook and procedures for LLM autotuning on Ubuntu Console, covering clean-room tenant
  handling, baseline VRAM census, quiet-fleet gates, dual-budget sizing, and profile certification.
---

# LLM Autotune Operator Runbook

This skill guides the preparation, execution, monitoring, and verification of LLM autotune sweeps across Ubuntu Console hardware profiles.

## Core Architecture & Safety Invariants

1. **Clean-Room Isolation (`AUTOTUNE_CLEAN_ROOM=1`)**:
   - `bin/autotune-rows.sh` takes the heavy-job lock (`/dev/shm/heavy-job.lock`) and CUDA suspend hold (`/dev/shm/llama-watchdog-cuda.suspend`).
   - Clean-room automatically holds `llama-watchdog.timer`, `llama-watchdog-guard.timer`, stops declared tenants (`llama-cuda-qwen3embedding-embed.service`), and holds GitHub Actions runner services (`actions.runner.*`).
   - On completion or signal exit (via `trap`), clean-room restores all stopped runners, tenants, and watchdogs.

2. **Dual-Budget Sizing (`__autotune_host_budget_verdict`)**:
   - Compares model weight footprint + KV cache against host `MemAvailable` and GPU pool size.
   - On `asus-n1n-rtx-spark` (128 GB unified LPDDR5X, 32 GB GPU carve), models up to 32 GB offload fully to GPU; larger models (e.g. 52 GB BF16 shards) partially offload to host RAM.
   - On `intel-xe-cuda` (4 GB discrete RTX 3050 Ti), models fit up to 24 layers on GPU; larger models offload to CPU with a P-core ceiling (`LLAMA_THREAD_CAP=6`).

3. **Quiet-Box Certification Gate**:
   - Autotune verifies box quietness before certifying:
     - CI runner worker count (`pgrep -fc 'Runner\.Worker'`) must be 0.
     - System load and CPU PSI pressure (`/proc/pressure/cpu`) must be within quiet thresholds.
   - If contention is detected at certification time, the run prints `REFUSING to write` and marks measurements as indicative rather than certified.

## 4-Phase Tuning Cycle

- **Phase 1 (Start Context Probe)**:
  Spawns `llama-server` on ephemeral port `18082` with initial batch `1024/256` and starting context (e.g., 4096 or 13312). Measures decode throughput against `MIN_TPS` (default 10 tps).
- **Phase 2 (Context Climb)**:
  Steps context upward (+50% step-up / binary probe) until reaching capacity or floor boundary.
- **Phase 3 (Beam Search & Sweeps)**:
  Explores batch/ubatch combinations (`512/128`, `1024/256`, `1024/512`, `2048/512`, `512/512`, `512/256`, `2048/256`, `1024/128`), sweeps `n-gpu-layers` (NGL), and tests KV cache quantization (`q8_0` vs `f16`).
- **Phase 4 (Sustained Scoring & Certification)**:
  Executes filled-cache TPS recovery, runs ngram speculative decode sweep (`[4 8 16 32]`), probes TTFT (time-to-first-token), and executes deterministic task-contract probes before persisting to `/home/wayne/models/active/models.conf`.

## Execution Runbook

### 1. Launching Autotune
Always invoke autotune through the wrapper `bin/autotune-rows.sh` (never bare `scripts/run-autotune-batch.sh`):

```bash
# Tune all models in models.conf that are not yet marked as 'yes' or 'slow'
bin/autotune-rows.sh --all-but-done

# Tune specific models or row numbers
bin/autotune-rows.sh NVIDIA-Nemotron-3.5-Bolt-74B-A9B-UD-Q2_K_XL.gguf
bin/autotune-rows.sh 1 5 7 10
```

### 2. Monitoring Progress
Active autotune runs write logs to `/home/wayne/models/.llm/autotune-logs/`:

```bash
# Check the most recent autotune log
tail -f $(ls -td /home/wayne/models/.llm/autotune-logs/autotune-*.log | head -n 1)

# Check active ephemeral llama-server process
ps aux | grep llama-server | grep -v grep
```

### 3. Verification After Run
Check `/home/wayne/models/active/models.conf`:
- Usable models meeting floor (`tps >= 10`) are marked with `autotuned=yes`.
- Heavy offloaded models below floor (`tps < 10`) are marked with `autotuned=slow` so future sweeps treat them as done.
- Verify primary CUDA chat lane and embeddings are restored:
  `systemctl --user status llama-cuda-qwen3coder-30b-chat.service llama-cuda-qwen3embedding-embed.service`
