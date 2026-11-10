# Project: Box Awareness, Architectural Audit & Production Refactoring

## Architecture
The repository is refactored into clean, typed, modular boundaries:
1. **Core Box Awareness Subsystem (`tools/box/`)**:
   - Single source of truth for hardware profiling, resource limits, and serving configurations.
   - Pydantic v2 domain models (`HardwareProfile`, `MemoryArchitecture`, `ServingParameters`, `QuantPolicy`).
   - Dual interface: Native Python API for scripts and CLI bridge (`export-env`) for shell environments.
2. **Standardized Python Runtime & Execution Layer**:
   - Strict enforcement of the local virtual environment (`.venv/bin/python3`). Fail-closed behavior on missing `.venv`.
   - Clean module imports without runtime `sys.path.insert` or dynamic `importlib` workarounds.
   - Unified shared utilities (atomic filesystem operations in `tools/fsutil.py`).
3. **Strict Pydantic Validation & Domain Integrity (`scripts/kgraph/`)**:
   - Complete referential integrity verification (no dangling edges, non-empty identifiers).
   - Fully validated models across projection flows, JSON-RPC MCP server interfaces, and life index ingestion.
4. **Hermetic Test Infrastructure & E2E Validation**:
   - Resilient pytest test suite with graceful fallback when optional external tools (like `bats`) are absent.
   - Complete isolation from production filesystem mutations (`/mnt/HD/HD_a2/` and `~/.openclaw/`).
   - Clean execution under `-W error` with zero resource leaks or unclosed sockets.

---

## Feature Inventory
| # | Feature | Description | Milestone | Source |
|---|---------|-------------|-----------|--------|
| F1 | Resilient Test Suite Collection | Fix eager `resolve_bats()` in `tests/_bats_suites.py` to prevent pytest collection crashes when bats is absent | M1 | Survey (Explorer 3) |
| F2 | Hermetic Systemd Test Mocking | Mock `/proc/1/comm` in `tests/test_oc_restart_check.py` to decouple test assertions from host PID 1 identity | M1 | Survey (Explorer 1 & 3) |
| F3 | Clean Socket & Resource Cleanup | Ensure `exc.close()` is called in `tools/llm_client.py` to eliminate `ResourceWarning` and socket leaks under `-W error` | M1 | Survey (Explorer 3) |
| F4 | Standardized Pytest Configuration | Add `pythonpath = . scripts tools nas/butler/scripts` to `pytest.ini` for standalone test execution | M1 | Survey (Explorer 3) |
| F5 | Production Filesystem Isolation | Remove top-level `mkdir` calls in `it500-influx-collector.py` and `glowmarkt-collector.py` to prevent real data contamination | M1 | Survey (Explorer 3) |
| F6 | Test Harness Consolidation | Consolidate duplicate dynamic module loaders and HTTP server test fixtures in `tests/` | M1 | Survey (Explorer 3) |
| F7 | Box Profile Domain Models | Implement Pydantic v2 models for `HardwareProfile`, `MemoryArchitecture`, `ServingParameters`, `PortAllocation` in `tools/box/models.py` | M2 | Survey (Explorer 2) |
| F8 | Target Profiles Definition | Define explicit configurations for Asus RTX Spark (128GB unified) and Dell XPS (4GB CUDA) in `tools/box/profiles.py` | M2 | Survey (Explorer 2) |
| F9 | Hardware Prober & WSL2 Process Discovery | Implement hardware prober with unified memory detection and `/proc/*/exe` process scanning fallback in `tools/box/prober.py` | M2 | Survey (Explorer 2) |
| F10 | Shell CLI Bridge (`export-env`) | Provide CLI commands (`python -m tools.box export-env` and `query`) for seamless bash profile integration | M2 | Survey (Explorer 2) |
| F11 | Asus RTX Spark Quantization Guide | Create `config/hosts.d/asus-rtx-spark-quant-guide.conf` supporting high-precision quants (Q8_0, Q6_K, F16) | M2 | Survey (Explorer 2) |
| F12 | Script Adaptation for Box Awareness | Refactor `grpo-vram-probe.py`, `oc-health-check.py`, `oc-restart-check.py`, `llm_benchmark.py`, and `11d-llm-gpu.sh` to use Box API | M2 | Survey (Explorer 1 & 2) |
| F13 | Strict `.venv` Python Enforcement | Remove global `python3` fallbacks in `tools/python-runtime.sh`, `scripts/01-constants.sh`, `tools/lint.sh`, `tools/count-ratchet.sh` — fail closed if `.venv` is missing | M3 | Survey (Explorer 1) |
| F14 | Shebang & Execution Standardization | Standardize Python tool shebangs and invocation wrappers to target the `.venv` interpreter | M3 | Survey (Explorer 1) |
| F15 | Import Hack Elimination | Remove `sys.path.insert(0, str(REPO_DIR))` and dynamic `importlib.import_module("tools.fsutil")` across the 11 identified files | M3 | Survey (Explorer 1) |
| F16 | Atomic File Write Consolidation | Consolidate duplicate atomic file write implementations into `tools/fsutil.py` | M3 | Survey (Explorer 1) |
| F17 | Legacy Backward Compatibility Cleanup | Eliminate legacy 20/26/32/37-column row padding in model registry scripts and remove deprecated shell aliases (`egrep`, `fgrep`, `ocstat`) | M4 | Survey (Explorer 1) |
| F18 | Dead Code & Stub Removal | Remove or finalize dead stubs (`nas-cpap-unified.py::_fetch_cpap_data`) and legacy edge translations | M4 | Survey (Explorer 1) |
| F19 | Graph Referential Integrity Validation | Enforce dangling edge rejection (source and target nodes must exist) in `scripts/kgraph/models.py` and `validate.py` | M4 | Survey (Explorer 3) |
| F20 | Identifier Length Enforcement | Enforce `min_length=1` on `GraphNode.id`, `GraphEdge.source`, and `GraphEdge.target` in `scripts/kgraph/models.py` | M4 | Survey (Explorer 3) |
| F21 | Strict Projection & Life Index Typing | Add Pydantic schemas for `scripts/kgraph/projection.py` output and `scripts/kgraph/life_index.py` records | M4 | Survey (Explorer 3) |
| F22 | MCP Server Pydantic Validation | Enforce typed Pydantic models for JSON-RPC 2.0 requests, responses, and method parameters in `scripts/kgraph/mcp_server.py` | M4 | Survey (Explorer 3) |
| F23 | LLM Client Schema Validation | Introduce typed Pydantic models for HTTP request payloads and responses in `tools/llm_client.py` | M4 | Survey (Explorer 3) |
| F24 | E2E Test Suite (Tiers 1–4) | Implement opaque-box E2E test suite covering all features across unit, boundary, combinatorial, and workload tiers | M5 | Project Requirement R4 |
| F25 | Adversarial Coverage Hardening (Tier 5) | White-box adversarial testing by Challenger agents to expose corner cases and eliminate regression vulnerabilities | M5 | Project Requirement R4 |

---

## Milestones
| # | Name | Scope | Dependencies | Status |
|---|------|-------|-------------|--------|
| M1 | Test Suite Stabilization & Isolation Fixes | F1, F2, F3, F4, F5, F6 | None | DONE (969 passed, 0 failures, verified clean) |
| M2 | Unified Box Awareness Subsystem | F7, F8, F9, F10, F11, F12 | M1 | IN_PROGRESS (sub_orch: bb0ac127) |
| M3 | Python Invocation Strictness & Shared Package Architecture | F13, F14, F15, F16 | M1 | IN_PROGRESS (sub_orch: 599fb7aa) |
| M4 | Codebase Consolidation, Legacy Cleanup & Pydantic Enforcement | F17, F18, F19, F20, F21, F22, F23 | M2, M3 | PLANNED |
| M5 | E2E Test Suite Validation & Zero-Regression Hardening | F24, F25 (100% E2E test pass + adversarial coverage) | M4 | PLANNED |
| E2E | Dual Track E2E Test Suite Development | Tiers 1-4 Test Infra, Cases & Runner | None (Parallel) | IN_PROGRESS (sub_orch: 72f3cf33; E1 passed) |

---

## Interface Contracts

### Box Awareness Subsystem (`tools.box`) ↔ Python Scripts / Shell
- **Python API**:
  ```python
  from tools.box import get_hardware_profile, detect_hardware_profile, HardwareProfile

  profile: HardwareProfile = get_hardware_profile(override_id: str | None = None)
  # Attributes:
  # profile.id: "asus-n1n-rtx-spark" | "intel-xe-cuda"
  # profile.memory_arch: "unified" | "discrete"
  # profile.total_memory_mb: int
  # profile.serving.gpu_layers: int (e.g. 999 for unified, 24 for discrete)
  # profile.serving.context_window: int (e.g. 131072 for unified, 20480 for discrete)
  # profile.serving.parallel_slots: int (e.g. 4 for unified, 1 for discrete)
  # profile.serving.batch_size: int (e.g. 2048 for unified, 512 for discrete)
  # profile.serving.ubatch_size: int (e.g. 512 for unified, 256 for discrete)
  # profile.serving.thread_cap: int (e.g. 0 for unified, 6 for discrete)
  # profile.serving.primary_port: int (e.g. 18087 for unified, 18081 for discrete)
  # profile.serving.min_host_reserve_mb: int (e.g. 12288 for unified, 1024 for discrete)
  ```
- **CLI Shell Contract**:
  - `python3 -m tools.box export-env`: outputs `export TAC_HOST_PROFILE_ID=...`, `export LLAMA_GPU_LAYERS=...`, `export LLM_SERVICE_PORT=...`.
  - `python3 -m tools.box query <key>`: outputs value to stdout.

### Knowledge Graph Validation (`scripts.kgraph.models`) ↔ Consuming Applications
- **Model Signature**:
  ```python
  class Graph(BaseModel):
      nodes: list[GraphNode]
      edges: list[GraphEdge]
      meta: dict[str, Any] = Field(default_factory=dict)

      @model_validator(mode="after")
      def validate_referential_integrity(self) -> Self:
          # Raises ValueError if any edge.source or edge.target is not present in {n.id for n in self.nodes}
          ...
  ```
- **Identifier Constraints**:
  ```python
  class GraphNode(BaseModel):
      id: Annotated[str, Field(min_length=1)]
      ...

  class GraphEdge(BaseModel):
      source: Annotated[str, Field(min_length=1)]
      target: Annotated[str, Field(min_length=1)]
      ...
  ```

### Python Virtual Environment Invocation Contract
- `_tac_python_path()` in `tools/python-runtime.sh` returns `$REPO_ROOT/.venv/bin/python3` if executable; otherwise exits with code 1 and outputs error message:
  `ERROR: Virtual environment not found at $REPO_ROOT/.venv. Run ./tools/setup-venv.sh first.`
- Global `/usr/bin/python3` fallback is strictly prohibited.

---

## Code Layout
```
ubuntu-console/
├── tools/
│   ├── box/                      # New unified Box Awareness package
│   │   ├── __init__.py           # Exports get_hardware_profile, detect_hardware_profile
│   │   ├── models.py             # Pydantic v2 schemas for profiles & serving specs
│   │   ├── profiles.py           # Explicit specs for Asus RTX Spark & Dell XPS
│   │   ├── prober.py             # Memory, CUDA, WSL2 process probing
│   │   └── cli.py                # Shell integration (export-env, query)
│   ├── fsutil.py                 # Consolidated atomic file write and filesystem utils
│   ├── python-runtime.sh         # Strict .venv resolver
│   └── llm_client.py             # HTTP client with exc.close() and Pydantic schemas
├── scripts/
│   ├── 01-constants.sh           # Strict TAC_PYTHON enforcement
│   ├── grpo-vram-probe.py        # Box-aware dynamic VRAM sizing
│   ├── oc-health-check.py        # Box-aware port & process discovery
│   ├── oc-restart-check.py       # Box-aware WSL2 process scanner (/proc/*/exe)
│   └── kgraph/
│       ├── models.py             # Pydantic models with referential integrity & non-empty IDs
│       ├── validate.py           # Strict validation logic
│       ├── projection.py         # Typed projection flows
│       └── mcp_server.py         # Pydantic JSON-RPC parameter validation
├── config/
│   ├── hosts.d/
│   │   ├── asus-n1n-rtx-spark.conf
│   │   ├── asus-rtx-spark-quant-guide.conf  # New quant guide for unified memory
│   │   └── intel-xe-cuda.conf
├── tests/
│   ├── _bats_suites.py           # Resilient bats resolution (non-crashing collection)
│   ├── _test_harness.py          # Consolidated loaders and ephemeral HTTP server fixtures
│   ├── test_box_awareness.py     # Comprehensive unit tests for tools.box
│   ├── test_e2e_box_workloads.py # E2E tests for hardware profile adaptations
│   └── ...
└── pytest.ini                    # pythonpath configured for clean execution
```
