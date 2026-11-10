# E2E Test Infra: Box Awareness, Architectural Audit & Production Refactoring

## Test Philosophy
- **Opaque-Box & Requirement-Driven**: Tests are derived strictly from `ORIGINAL_REQUEST.md` and `PROJECT.md § Interface Contracts`, treating implementation modules as black boxes accessed via documented public APIs, CLI flags, and standard streams.
- **Hermetic & Isolated**: Test execution strictly redirects mutable filesystem state to isolated temporary environments, preventing any modification or contamination of production directories (`/mnt/HD/HD_a2/`, `~/.openclaw/`).
- **Zero-Warning Clean Execution**: The entire test suite must execute under `pytest -W error` without unhandled warnings, resource leaks, or unclosed socket connections.
- **Methodology**: Systematic 4-tier testing integrating Category-Partition, Boundary Value Analysis (BVA), Pairwise Combinatorial Interaction Testing, and Real-World Workload Scenarios.

---

## Feature Inventory & Test Mapping

| # | Feature | Category | Source (Requirement) | Tier 1 (Coverage) | Tier 2 (Boundary) | Tier 3 (Pairwise) | Tier 4 (Workloads) |
|---|---------|----------|----------------------|:-----------------:|:-----------------:|:-----------------:|:------------------:|
| F1 | Resilient Test Suite Collection | Test Infra | R4 (Pytest Suite Stability) | 5 tests | 5 tests | ✓ | ✓ |
| F2 | Hermetic Systemd Test Mocking | Test Infra | R4 (Pytest Suite Stability) | 5 tests | 5 tests | ✓ | ✓ |
| F3 | Clean Socket & Resource Cleanup | Test Infra | R4 (Zero Warnings / Resource Leaks) | 5 tests | 5 tests | ✓ | ✓ |
| F4 | Standardized Pytest Configuration | Test Infra | R4 (Pytest Execution) | 5 tests | 5 tests | ✓ | ✓ |
| F5 | Production Filesystem Isolation | Isolation | R4 (Data Contamination Avoidance) | 5 tests | 5 tests | ✓ | ✓ |
| F6 | Test Harness Consolidation | Test Infra | R2 (Duplicated Logic Removal) | 5 tests | 5 tests | ✓ | ✓ |
| F7 | Box Profile Domain Models | Box Awareness | R1 (Box Awareness Models) | 5 tests | 5 tests | ✓ | ✓ |
| F8 | Target Profiles Definition | Box Awareness | R1 (Asus Spark vs Dell XPS) | 5 tests | 5 tests | ✓ | ✓ |
| F9 | Hardware Prober & WSL2 Process Discovery | Box Awareness | R1 (Unified Memory / WSL2 Discovery) | 5 tests | 5 tests | ✓ | ✓ |
| F10 | Shell CLI Bridge (`export-env`) | Box Awareness | R1 (Shell & CLI Integration) | 5 tests | 5 tests | ✓ | ✓ |
| F11 | Asus RTX Spark Quantization Guide | Box Awareness | R1 (Quant Policy for Unified RAM) | 5 tests | 5 tests | ✓ | ✓ |
| F12 | Script Adaptation for Box Awareness | Box Awareness | R1 (Dynamic Workload Sizing) | 5 tests | 5 tests | ✓ | ✓ |
| F13 | Strict `.venv` Python Enforcement | Runtime | R3 (Strict .venv Invocation) | 5 tests | 5 tests | ✓ | ✓ |
| F14 | Shebang & Execution Standardization | Runtime | R3 (Strict .venv Invocation) | 5 tests | 5 tests | ✓ | ✓ |
| F15 | Import Hack Elimination | Code Quality | R2, R3 (Import Standardization) | 5 tests | 5 tests | ✓ | ✓ |
| F16 | Atomic File Write Consolidation | Code Quality | R2, R3 (Shared Atomic Utilities) | 5 tests | 5 tests | ✓ | ✓ |
| F17 | Legacy Backward Compatibility Cleanup | Code Quality | R2, R3 (Dead Code Removal) | 5 tests | 5 tests | ✓ | ✓ |
| F18 | Dead Code & Stub Removal | Code Quality | R2, R3 (Dead Code Removal) | 5 tests | 5 tests | ✓ | ✓ |
| F19 | Graph Referential Integrity Validation | Data Integrity | R2, R3 (Pydantic Integrity) | 5 tests | 5 tests | ✓ | ✓ |
| F20 | Identifier Length Enforcement | Data Integrity | R2, R3 (Pydantic Integrity) | 5 tests | 5 tests | ✓ | ✓ |
| F21 | Strict Projection & Life Index Typing | Data Integrity | R2, R3 (Pydantic Integrity) | 5 tests | 5 tests | ✓ | ✓ |
| F22 | MCP Server Pydantic Validation | Data Integrity | R2, R3 (Pydantic Integrity) | 5 tests | 5 tests | ✓ | ✓ |
| F23 | LLM Client Schema Validation | Data Integrity | R2, R3 (Pydantic Integrity) | 5 tests | 5 tests | ✓ | ✓ |
| F24 | E2E Test Suite (Tiers 1–4) | E2E Testing | R4 (Suite Architecture) | 5 tests | 5 tests | ✓ | ✓ |
| F25 | Adversarial Coverage Hardening | E2E Testing | R4 (Robustness Hardening) | 5 tests | 5 tests | ✓ | ✓ |
| **Total** | | | | **125** | **125** | **25** | **13** |

---

## Test Architecture

### Directory Layout
```
tests/e2e/
├── __init__.py
├── conftest.py                       # Root hermetic fixtures & emulators
├── runner.py                         # Standalone runner CLI & programmatic API
├── test_tier1_feature_coverage.py    # Tier 1: 125 feature tests (F1–F25)
├── test_tier2_boundary_corner.py     # Tier 2: 125 boundary & error recovery tests (F1–F25)
├── test_tier3_cross_feature.py       # Tier 3: 25 pairwise cross-feature tests
├── test_tier4_workloads.py           # Tier 4: 13 full application workload scenarios
└── helpers/
    ├── __init__.py
    ├── assertions.py                 # Pydantic schema, shell env, exit code assertions
    ├── mock_procfs.py                # Virtual procfs builder & monkeypatcher
    ├── mock_hardware.py              # Asus RTX Spark & Dell XPS environment emulators
    └── mock_server.py                # Hermetic self-closing HTTP server fixture
```

### Test Runner Invocation
1. **Pytest Direct Invocation**:
   ```bash
   .venv/bin/python3 -m pytest -W error tests/e2e/
   ```
2. **Targeted Tier Execution**:
   ```bash
   .venv/bin/python3 -m pytest -W error tests/e2e/test_tier1_feature_coverage.py
   .venv/bin/python3 -m pytest -W error tests/e2e/test_tier2_boundary_corner.py
   .venv/bin/python3 -m pytest -W error tests/e2e/test_tier3_cross_feature.py
   .venv/bin/python3 -m pytest -W error tests/e2e/test_tier4_workloads.py
   ```
3. **Standalone Runner CLI**:
   ```bash
   .venv/bin/python3 -m tests.e2e.runner --tier 1
   .venv/bin/python3 -m tests.e2e.runner --tier all -v
   .venv/bin/python3 -m tests.e2e.runner --feature F7
   ```

### Pass / Fail Semantics
- **Exit Code 0**: All executed tests passed cleanly with zero warnings or errors.
- **Exit Code 1**: One or more test assertions failed.
- **Exit Code 2**: CLI invocation or configuration error.
- **Exit Code 3**: Execution aborted due to unhandled `ResourceWarning`, socket leak, or timeout under `-W error`.

---

## Real-World Application Scenarios (Tier 4)

| # | Scenario | Features Exercised | Complexity | Description |
|---|----------|--------------------|------------|-------------|
| 1 | Asus Spark Complete Serving Lifecycle | F7, F8, F9, F10, F11, F12, F13 | High | Hardware prober detects Asus RTX Spark, exports shell variables (`TAC_HOST_PROFILE_ID="asus-n1n-rtx-spark"`, `LLAMA_GPU_LAYERS=999`, `LLM_SERVICE_PORT=18087`), evaluates quantization guide for Q8_0 GGUF, computes dynamic VRAM budget in `grpo-vram-probe.py`, and validates health check. |
| 2 | Dell XPS Discrete CUDA Lifecycle | F7, F8, F9, F10, F12, F13 | High | Prober detects Dell XPS 4GB CUDA, exports shell configuration (`thread_cap=6`, `parallel_slots=1`, `primary_port=18081`), validates VRAM sizing with 4GB ceiling in `grpo-vram-probe.py`, and validates health check against port 18081. |
| 3 | Knowledge Graph Ingestion to MCP Query | F16, F19, F20, F21, F22 | High | Life index records ingested with strict Pydantic schemas, projected into validated Graph with full referential integrity, saved atomically via `tools.fsutil`, and queried over JSON-RPC 2.0 via `mcp_server.py`. |
| 4 | LLM Client Chat Completion with Socket Lifecycle | F3, F6, F12, F23 | Medium | `tools.llm_client.py` performs health check and chat completions against mock LLM server, handles 404/500 errors with explicit `exc.close()`, and verifies zero socket leaks under `-W error`. |
| 5 | Fail-Closed `.venv` Execution Sweep | F13, F14, F15 | Medium | Verifies that all scripts and shell entry points strictly resolve `.venv/bin/python3`, failing closed with exit code 1 and actionable diagnostics when `.venv` is missing, without system python fallback. |
| 6 | Atomic Persistence Crash Resilience | F16, F19, F21 | High | Performs concurrent atomic writes of validated Graph datasets under simulated sudden thread termination and simulated `OSError`, verifying destination files remain intact and temporary `.tmp` files are cleaned up. |
| 7 | WSL2 `/proc/*/exe` Process Recovery | F2, F9, F12 | Medium | Simulates `nvidia-smi` reporting 0 compute applications under WSL2; `tools.box.prober` and `scripts/oc-restart-check.py` successfully scan `/proc/*/exe` and identify active `llama-server` instances. |
| 8 | Collector Hermetic Filesystem Sweep | F5, F13, F15 | Medium | Executes `it500-influx-collector.py` and `glowmarkt-collector.py` in test environment, verifying zero filesystem mutation to `/mnt/HD/HD_a2/` or `~/.openclaw/`. |
| 9 | High-Precision Model Quantization Selection | F7, F8, F11, F12 | Medium | Evaluates model downloads across Q8_0, Q6_K, Q4_K_M, Q2_K under Asus RTX Spark 128GB unified vs Dell XPS 4GB, verifying correct rating assignment and memory fit calculation. |
| 10 | MCP Server End-to-End Method Dispatch & Validation | F20, F21, F22 | High | Dispatches full suite of MCP tools (`graph_stats`, `search_nodes`, `get_node_neighbors`) with valid and malformed JSON-RPC requests, verifying RFC-compliant error codes (`-32600`, `-32602`). |
| 11 | Multi-Tenant Process Supervisor Health Check | F2, F8, F9, F12 | High | `oc-restart-check.py` evaluates complex process trees with PID 1 comm `"exe"`, detecting systemd-managed services vs unmanaged foreign processes and returning appropriate restart safety verdicts. |
| 12 | Clean Module Import Sweep (No Import Hacks) | F4, F15, F16 | Medium | Imports all 11 refactored files directly in an isolated Python environment without `sys.path.insert(0, ...)` or dynamic `importlib`, verifying clean resolution via `pytest.ini:pythonpath`. |
| 13 | End-to-End Zero-Regression Verification Gate | F1–F25 | High | Meta-test executing the full test runner across all tiers, certifying 100% pass rate, zero warnings under `-W error`, and layout conformance. |

---

## Coverage Thresholds
- **Tier 1 (Feature Coverage)**: ≥5 test cases per feature × 25 features = **125 test cases**
- **Tier 2 (Boundary & Corner Cases)**: ≥5 boundary/error test cases per feature × 25 features = **125 test cases**
- **Tier 3 (Cross-Feature Combinations)**: Pairwise combinatorial test cases = **25 test cases**
- **Tier 4 (Real-World Workloads)**: Application-level scenarios = **13 test cases**
- **Total Suite Minimum**: **288 test cases**
