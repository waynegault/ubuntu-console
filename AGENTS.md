# Ubuntu Console — Agent Architecture & Quality Rules

These workspace rules govern all AI agent contributions across `/home/wayne/github-wsl/ubuntu-console`. Every change must preserve hardware box-awareness, strict `.venv` execution, Pydantic v2 validation, hermetic testing, and zero technical debt.

---

## 1. Box-Awareness & Hardware Profile Optimization

This repository runs in production across two distinct hardware boxes and must never hardcode one machine's assumptions into shared code:

1. **Asus ProArt P16 / RTX Spark N1X (`asus-n1n-rtx-spark`)**:
   - **Architecture**: `aarch64` (`10x Cortex-X925 + 10x Cortex-A725`, 20 logical CPUs), NVIDIA Blackwell GB10 / RTX Spark N1X (`sm_121a`, `LLAMA_CUDA_ARCH="121a-real"`, `LLAMA_CUDA_FA_QUANTS="all"`).
   - **Memory Model**: 128 GB unified LPDDR5X (`TAC_HOST_PROFILE_SHARED_MEMORY=1`). Sizes against the guest/pool with a `12288 MiB` host reserve (`LLAMA_FIT_KEEP_RESERVE_MB=12288`), full offload (`LLAMA_GPU_LAYERS=999`, `ngl_strategy="full_only"`), `parallel_slots=4`, `threads_base=10`, `thread_cap=0`.
   - **Primary Serving Lane**: `llama-cuda-qwen3coder-30b-chat.service` on port `18087` (`LLM_SERVICE_PORT=18087`), protected embedding lane `llama-cuda-qwen3embedding-embed.service` on port `18080`.
   - **WSL2 Unified Memory Quirks**: `nvidia-smi --query-compute-apps=pid` returns empty on unified memory; process discovery (`scripts/oc-restart-check.py`, `tools/box/prober.py`) must fall back to scanning `/proc/[0-9]*/exe` and `/proc/[0-9]*/cmdline` for `llama-server` (excluding `build-opencl`), and treat `/proc/1/comm` values `("systemd", "exe", "init")` as valid PID 1 supervisors.

2. **Dell XPS 15 (`intel-xe-cuda`)**:
   - **Architecture**: `x86_64` (`i9-12900HK` hybrid P/E cores), NVIDIA RTX 3050 Ti (`sm_86`) + Intel Iris Xe iGPU (`TAC_HOST_PROFILE_XE=1`).
   - **Memory Model**: 4 GB discrete CUDA VRAM (`TAC_HOST_PROFILE_SHARED_MEMORY=0`, `4096 MiB`). Uses `LLAMA_GPU_LAYERS=24`, `parallel_slots=1`, `threads_base=6`, and hybrid P-core ceiling `LLAMA_THREAD_CAP=6` so decode threads never spill onto E-cores.
   - **Primary Serving Lane**: `llama-xe-minicpm5-1b-chat.service` on port `18081` (`LLM_SERVICE_PORT=18081`).

3. **Single Source of Truth**:
   - Python tools resolve hardware profiles, VRAM headroom, and serving parameters through `tools.box` (`tools/box/models.py`, `tools/box/profiles.py`, `tools/box/prober.py`, `tools/box/cli.py`).
   - Shell scripts resolve host profiles through `tools/host-profile.sh` and `config/hosts.d/*.conf` (or `.venv/bin/python3 -m tools.box`).

---

## 2. Strict `.venv` Python Execution & Import Hygiene

- **Always Use `.venv/bin/python3`**: Every Python execution in shell scripts, hooks, linters, and test runners must resolve `.venv/bin/python3` via `tools/python-runtime.sh` (`_tac_python_path "$REPO_ROOT"`) or `TAC_PYTHON` in `scripts/01-constants.sh`. Never invoke bare system `/usr/bin/python3` when `.venv` is expected.
- **No `sys.path.insert` Hacks**: Do not add `sys.path.insert(0, ...)` to scripts or tests. `pytest.ini` configures `pythonpath = . scripts tools nas/butler/scripts`.
- **CLI Entrypoint Discipline**: Executable scripts in `bin/` and `scripts/` must handle `--help` / `-h` cleanly (exit `0`) before performing hardware probes or side effects.

---

## 3. Strict Pydantic v2 Validation & Zero Legacy Debt

- **Enforce Pydantic v2 at All Boundaries**:
  - Use `BaseModel` with `ConfigDict(extra="forbid")` (or explicit boundary policies) across `tools/box/`, `scripts/kgraph/` (`GraphNode`, `GraphEdge`, `Graph`, `ProjectedGraph`, `LifeIndexRecord`, `JsonRpcRequest`, `JsonRpcError`, `JsonRpcResponse`), and `tools/llm_client.py` (`ChatMessage`, `ChatCompletionRequest`, `UsageInfo`, `ChatChoice`, `ChatCompletionResponse`).
  - Enforce `min_length=1` and non-whitespace identifiers on graph nodes/edges, validate graph referential integrity (`Graph.validate_referential_integrity()`), and reject `bool` values where `int` is expected.
- **No Backwards-Compatibility Shims or Silent Fallbacks**: Do not keep deprecated aliases (`egrep`, `fgrep`), dead code, or silent catch-all fallbacks that mask upstream failures.
- **Atomic File Persistence**: Always use `tools.fsutil.atomic_write_text` or `tools.fsutil.atomic_write_bytes` (`os.fsync` + `os.replace`) for state and artifact writes.

---

## 4. Hermetic Testing & Resource Cleanup

- **Zero Production Data Contamination**: Never call `.mkdir()` or write to production paths (`/mnt/HD/HD_a2/...`, `~/.openclaw/...`, `~/models/...`) at module import time or during unit/E2E tests.
- **Warning-Free Execution (`-W error`)**: All tests must pass under `.venv/bin/python3 -m pytest -W error` with zero `ResourceWarning` socket leaks. Always close `urllib.error.HTTPError` streams (`exc.close()`) and shut down ephemeral HTTP test servers cleanly.

---

## 5. Mandatory Version Headers & Quality Gates

Before completing any task that modifies repository files:

1. **Increment File Version Headers**: Every file carrying `# Module Version: N` or `# Version: X.Y.Z` must have its version incremented with a dated changelog entry when modified (`tools/check-module-versions.sh`).
2. **Comment Every Shell Function**: Place a descriptive `# comment` directly above every shell function definition (`§18.3` item `9.5` in `tools/count-ratchet.sh`).
3. **Classify Every Error Suppression**: Never add an unexplained `2>/dev/null` or `|| true` in shell scripts. Either handle the error or document why suppression is safe on the line immediately above with `# swallow-ok: <reason>` (`tools/check-contracts.sh swallows`).
4. **Run Verification Gates**:
   - `.venv/bin/python3 -m ruff check tools/ scripts/ bin/ tests/`
   - `.venv/bin/python3 -m mypy tools/box scripts/kgraph tools/fsutil.py tools/llm_client.py`
   - `tools/check-repo-boundaries.sh && tools/check-contracts.sh && tools/count-ratchet.sh && tools/check-module-versions.sh`
   - `.venv/bin/python3 -m pytest -W error -m "not bats" --ignore=tests/e2e -q`
   - `.venv/bin/python3 tests/e2e/runner.py -q`

---

## 6. Standing Engineering Rules

- **Never Silence a Warning**: Do not use blanket `filterwarnings`, `-W ignore`, `# noqa`, or unannotated `# type: ignore`. When `# type: ignore` is unavoidable due to third-party typing limitations, document the exact reason inline.
- **Omitted Arguments are Unmade Decisions**: Explicitly pass critical parameters (`timeout`, `shell=False`, `encoding="utf-8"`, `errors="strict"`) rather than relying on silent defaults.
- **Verify Effects, Not Returns**: Use read-back witnesses and verify persistent state changes rather than relying solely on function return codes.
- **Operational Issues Solved in Code**: Fix root causes in code rather than recording manual operational workarounds.
- **Timezone Discipline**: Human-facing timestamps and diagnostic logs must be formatted in ISO 8601 UTC or `Europe/London` (GMT/BST).
