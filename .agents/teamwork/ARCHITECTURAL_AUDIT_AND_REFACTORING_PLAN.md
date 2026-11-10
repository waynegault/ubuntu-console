# Comprehensive Architectural Audit & Refactoring Plan

**Target Repositories & Execution Context**: `/home/wayne/github-wsl/ubuntu-console`
**Date**: 2026-11-10
**Architect**: Teamwork Orchestrator
**Status**: Ready for Execution

---

## Executive Summary

An exhaustive empirical survey was executed across the repository by three specialized exploration agents examining (1) Repository Architecture & Technical Debt, (2) Box Awareness & Hardware Profiling, and (3) Test Suite Quality & Pydantic Validation.

The investigation verified that while the repository possesses a solid foundation (919 passing unit tests in ~35s, strict type checking with mypy and pyright), it suffers from five critical architectural flaws:
1. **Total Absence of Python Box Awareness**: While bash has emerging host profiles (`tools/host-profile.sh`), the Python codebase has zero native hardware awareness, hardcoding 4096MB VRAM and port 18081, while driver differences under WSL2 on the Asus RTX Spark cause silent process detection failures and risk host memory exhaustion.
2. **Virtual Environment & Execution Fragmentation**: Python execution fallbacks across shell scripts and wrappers invoke `/usr/bin/python3`, which fails under Debian/Ubuntu PEP 668 restrictions due to missing dependencies (`pydantic`, `pytest`, `yaml`).
3. **Pydantic Validation Gaps & Bypasses**: Pydantic models are confined to `scripts/kgraph/models.py` and are downgraded to raw `dict`s in projection and MCP servers. Critical validations (e.g. referential integrity for dangling edges, non-empty identifiers) are missing.
4. **Isolated & Duplicated Utilities with Import Hacks**: Lack of a root package forces `sys.path.insert(0, str(REPO_DIR))` and dynamic `importlib` calls across 11 files; atomic write logic and test harnesses are duplicated across modules.
5. **Test Suite Hygiene & Production Data Isolation Violations**: Pytest collection crashes when `bats` is not installed on PATH due to an eager top-level call in `tests/test_bats_bridge.py`; unclosed HTTP sockets trigger `ResourceWarning` under strict warnings; and collectors mutate `/mnt/HD/HD_a2/` and `~/.openclaw/` at module import time.

---

## 1. Architectural Audit

### 1.1 Box Awareness & Hardware Profile Gaps (R1)
- **Hardcoded 4GB VRAM & Port Assumptions**:
  - `scripts/grpo-vram-probe.py`: `TOTAL_VRAM_MB = 4096` hardcoded.
  - `scripts/oc-health-check.py`: `LLM_SERVICE_PORT = 18081` hardcoded fallback (Dell XPS Xe lane), whereas Asus RTX Spark serves primary chat on port `18087`.
  - `scripts/11d-llm-gpu.sh`: Hardcoded 64K context ceiling and 4GB card rules.
  - `scripts/11e-llm-model.sh`: Parallel execution hardcoded to 1 (`--parallel 1`) for all machines.
- **WSL2 Driver Divergence on Asus RTX Spark**:
  - `scripts/oc-restart-check.py`: Relies on `nvidia-smi --query-compute-apps=pid`. Under WSL2 on unified memory, this returns 0 processes even with >36GB VRAM in use. Process discovery requires `/proc/*/exe` or `pgrep` scanning.
  - `scripts/oc-restart-check.py`: Assumes `/proc/1/comm == "systemd"`, failing under WSL2 where PID 1 is `"exe"` or `"init"`.
- **Unified Memory vs Discrete VRAM Architecture**:
  - *Asus RTX Spark*: 128GB unified memory (ARM64 Cortex-X925, Blackwell RTX Spark N1X). Needs full offload (`-ngl 999` — stepping down offload layers paradoxically spills weights to guest RAM, causing kernel OOM panics), parallel lanes (`--parallel 4`), large batches (`2048/512`), unconstrained threads, and a minimum 12GB host reserve to protect the Windows WSL2 relay.
  - *Dell XPS*: 4GB discrete VRAM (x86_64 i9-12900HK hybrid, RTX 3050 Ti + Intel Xe). Needs strict 4GB budget, `--parallel 1`, thread cap at 6 (P-core protection), smaller batches (`512/256`), and quant filtering.
- **Missing Quantization Guide**:
  - `config/quant-guide.conf` only targets 4GB cards (deprecating Q6_K, Q8_0). `config/hosts.d/asus-n1n-rtx-spark.conf` sets `LLAMA_QUANT_GUIDE_REL:=""` with no quant guide defined.

### 1.2 Virtual Environment & Invocation Fragmentation (R3)
- `tools/python-runtime.sh`, `scripts/01-constants.sh`, `tools/lint.sh`, `tools/count-ratchet.sh`, and `bin/vscode-state-compact.sh` include fallback branches to system `python3` or `command -v python3`.
- Under Debian PEP 668, `/usr/bin/python3` cannot run repository tooling because dependencies (`pydantic`, `pytest`, `yaml`) are installed solely in `.venv`.
- Standalone Python scripts under `bin/`, `scripts/`, and `tools/` use `#!/usr/bin/env python3` which resolves to global python if PATH has not activated `.venv`.

### 1.3 Structural Debt, Monster Files & Import Hacks (R2, R3)
- **Import Hacks**: 11 files inject `sys.path.insert(0, str(REPO_DIR))` and import via `importlib.import_module("tools.fsutil")` to bypass lint/import restrictions.
- **Monster Files**:
  - `scripts/11e-llm-model.sh`: 5,809 lines.
  - `scripts/autotune-model.sh`: 4,099 lines.
  - `scripts/09d-oc-agents.sh`: 3,067 lines.
  - `scripts/kgraph/memory_import.py`: 2,419 lines.
- **Legacy Backward Compatibility Shims**:
  - Padding legacy 20/26/32/37-column model registry rows to 39 columns (`scripts/11a-llm-registry.sh`, `scripts/11b-llm-autotune.sh`).
  - Obsolete shell aliases (`egrep`, `fgrep`, `ocstat`).
  - Legacy `from`/`to` mapping in `scripts/kgraph/models.py`.
- **Dead Code & Unfinalized Stubs**:
  - `nas/butler/scripts/nas-cpap-unified.py:176`: `_fetch_cpap_data` raises `NotImplementedError` as an unfinalized stub.
- **Duplicated Utilities**:
  - Atomic file write logic duplicated across `tools/fsutil.py`, `tools/llm_benchmark.py`, and `tools/vscode-pytest-log/vscode_pytest_log.py`.
  - Duplicate dynamic module loading and test web server harnesses across test suites.

### 1.4 Pydantic Validation Bypasses (R2, R3)
- **Referential Integrity**: `Graph` in `scripts/kgraph/models.py` accepts dangling edges (source/target node IDs that do not exist in the node set) with zero validation errors.
- **Empty String Identifiers**: `GraphNode.id`, `GraphEdge.source`, and `GraphEdge.target` allow empty strings `""`.
- **Data Flow Downgrades**:
  - `scripts/kgraph/projection.py`: Downgrades `Graph` to raw `dict` for projection and returns unvalidated dict.
  - `scripts/kgraph/mcp_server.py`: Converts `Graph` to raw `dict` and processes JSON-RPC parameters using hand-rolled dict parsing.
  - `scripts/kgraph/life_index.py`: Directly ingests JSON files into raw dicts without Pydantic schemas.
  - `tools/llm_client.py`: Uses untyped dicts for request/response payloads.

### 1.5 Test Suite Gaps & Isolation Violations (R4)
- **Collection Blocker**: `tests/test_bats_bridge.py:25` executes `_resolve_bats()` at module import time, crashing pytest with `FileNotFoundError` during collection if `bats` is not installed.
- **Unclosed Sockets & Warnings**: `tools/llm_client.py:88-89` does not close `urllib.error.HTTPError`, triggering `ResourceWarning` and unraisable exception warnings under `-W error`.
- **Missing `pythonpath`**: `pytest.ini` omits `pythonpath = .`, causing individual test file runs to fail.
- **Production Filesystem Contamination**: `it500-influx-collector.py` and `glowmarkt-collector.py` call `.mkdir(parents=True, exist_ok=True)` at top-level module scope, writing to `/mnt/HD/HD_a2/...` and `~/.openclaw/...` on import.

---

## 2. Refactoring Plan

The refactoring is partitioned into 5 coherent, sequentially verifiable milestones:

### Milestone 1: Test Suite Stabilization & Isolation Fixes (Prerequisite)
**Scope**:
- Fix `tests/_bats_suites.py`: make `resolve_bats()` non-fatal during collection (return `None` or skip gracefully if `bats` is absent).
- Fix `tests/test_oc_restart_check.py:249`: mock `/proc/1/comm` so tests do not rely on host PID 1 identity.
- Fix `tools/llm_client.py`: call `exc.close()` in HTTP error handling to eliminate `ResourceWarning` and socket leaks under `-W error`.
- Update `pytest.ini`: add `pythonpath = . scripts tools nas/butler/scripts`.
- Fix production path mutation on module load in `it500-influx-collector.py` and `glowmarkt-collector.py` (defer directory creation to main/entry point).
- Consolidate duplicate dynamic module loaders and test server harnesses in `tests/`.

### Milestone 2: Unified Box Awareness Subsystem (`tools/box/` & `tools/hardware/`)
**Reference**: See [`RTX_SPARK_HARDWARE_AND_LLM_FINDINGS.md`](file:///home/wayne/github-wsl/ubuntu-console/.agents/teamwork/RTX_SPARK_HARDWARE_AND_LLM_FINDINGS.md) for verified ASUS H7607BA hardware topology (`10x Cortex-X925 + 10x Cortex-A725`, `cpu_threads_base=10`, `thread_cap=0`, `121a-real`, `FA_QUANTS=all`, unified-memory `mmap` policy, and `gpu_layers=999` for both dense and MoE models).
**Scope**:
- Create unified, Pydantic v2-backed `tools/box/` package:
  - `models.py`: Pydantic models for `HardwareProfile`, `MemoryArchitecture` (UNIFIED vs DISCRETE), `ServingParameters` (context window, batch sizes, parallel slots, thread allocation, GPU layers), `QuantPolicy`, `PortAllocation`.
  - `profiles.py`: Pre-configured profile definitions for:
    1. `Asus RTX Spark`: 128GB unified memory, Cortex-X925, Blackwell RTX Spark N1X, full offload (ngl=999), parallel=4, context=128k-256k, batch=2048/512, thread_cap=0, min host reserve=12GB, primary port=18087.
    2. `Dell XPS`: 4GB discrete CUDA VRAM, i9-12900HK hybrid, RTX 3050 Ti, partial offload (ngl=24), parallel=1, context=16k-21k, batch=512/256, thread_cap=6, primary port=18081.
  - `prober.py`: Dynamic prober detecting current hardware, memory availability, unified memory carve, and `/proc/*/exe` process scanning for WSL2 environments.
  - `cli.py`: CLI bridge (`python -m tools.box export-env` and `python -m tools.box query <key>`) providing zero-overhead shell integration.
- Create `config/hosts.d/asus-rtx-spark-quant-guide.conf` enabling high-precision quants (Q8_0, Q6_K, F16) on Asus RTX Spark.
- Adapt affected scripts (`scripts/grpo-vram-probe.py`, `scripts/oc-health-check.py`, `scripts/oc-restart-check.py`, `tools/llm_benchmark.py`, `scripts/11d-llm-gpu.sh`, `systemd/`) to query the unified Box Profile API.

### Milestone 3: Python Invocation Strictness & Shared Package Architecture
**Scope**:
- Enforce strict `.venv` Python usage across all shell wrappers (`tools/python-runtime.sh`, `scripts/01-constants.sh`, `tools/lint.sh`, `tools/count-ratchet.sh`, `bin/vscode-state-compact.sh`). Remove fallback to system `python3` — fail closed with an informative error if `.venv` is missing.
- Ensure scripts and entry points specify or resolve via the local `.venv/bin/python3`.
- Eliminate `sys.path.insert(0, str(REPO_DIR))` and dynamic `importlib.import_module("tools.fsutil")` workarounds across the 11 identified files.
- Consolidate atomic file write implementations into `tools/fsutil.py`.

### Milestone 4: Codebase Consolidation, Legacy Cleanup & Pydantic Enforcement
**Scope**:
- Eliminate backwards compatibility hacks:
  - Remove legacy 20/26/32/37-column row padding in model registry scripts.
  - Remove obsolete `egrep`, `fgrep`, and `ocstat` aliases.
  - Clean up legacy `from`/`to` edge translation in `scripts/kgraph/models.py`.
- Remove or finalize dead code stubs (e.g. `nas/butler/scripts/nas-cpap-unified.py::_fetch_cpap_data`).
- Enforce strict Pydantic v2 validation:
  - Add referential integrity validation for dangling edges in `scripts/kgraph/models.py::Graph`.
  - Enforce `min_length=1` on `GraphNode.id`, `GraphEdge.source`, and `GraphEdge.target`.
  - Add Pydantic schemas for `scripts/kgraph/projection.py` output and `scripts/kgraph/life_index.py`.
  - Add typed Pydantic models for JSON-RPC payloads in `scripts/kgraph/mcp_server.py`.
  - Add typed Pydantic models for LLM client request/response in `tools/llm_client.py`.

### Milestone 5: E2E Test Suite Validation & Zero-Regression Hardening
**Scope**:
- Dual-track opaque-box E2E testing suite (Tiers 1–4):
  - Tier 1: Feature Coverage (≥5 per feature across box awareness, CLI invocation, Pydantic validation, graph processing).
  - Tier 2: Boundary & Corner Cases (empty graph, dangling edges, maximum context bounds, zero VRAM reserve, extreme profile specs).
  - Tier 3: Cross-Feature Combinations (box profile export into shell scripts, Pydantic validation in MCP server, atomic writes across modules).
  - Tier 4: Real-World Scenarios (complete health check under Asus RTX Spark profile vs Dell XPS profile, model registry tuning).
- Tier 5: Adversarial white-box coverage hardening (Challenger audit).
- Verify 100% test passes cleanly with zero warnings (`-W error`), zero skipped validations, and zero regressions.

---

## 3. Verification & Acceptance Criteria Matrix

| Criterion | Target Behavior | Verification Mechanism |
|-----------|-----------------|------------------------|
| **Box Awareness** | Dynamic detection & adaptation to Asus RTX Spark (128GB unified) and Dell XPS (4GB CUDA) | `python -m tools.box detect`, `pytest tests/test_box_awareness.py`, health check checks matching port/limits |
| **Strict `.venv` Execution** | All scripts strictly execute using `.venv/bin/python3`; no fallback to broken system python | `tools/lint.sh`, `pytest tests/test_python_runtime.sh`, grep audit for untracked python calls |
| **Pydantic Validation** | Strict validation of models, referential integrity (no dangling edges), non-empty IDs, typed MCP/LLM payloads | `pytest tests/test_kgraph_models.py`, `test_validate.py`, `test_mcp_server.py` |
| **Clean Architecture & Cleanup** | Elimination of `sys.path.insert` hacks, legacy row padding, dead code stubs, consolidated atomic writes | Ruff, Mypy, Pyright, repo boundary check |
| **Test Quality & Zero Regressions** | 100% pytest suite passes cleanly with zero errors, zero unclosed socket warnings under `-W error`, and zero data contamination | `pytest -W error`, data isolation fixtures, verified 0 real data path writes |
