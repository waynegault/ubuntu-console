# Codebase audit findings

Audit started 2026-10-15 in the `\\wsl.localhost\Ubuntu-24.04\home\wayne\ubuntu-console`
checkout. This is a prioritized, evidence-based working record, not a claim that all
technical debt has been removed.

## Closed

| ID | Finding | Resolution |
|---|---|---|
| AUD-001 | Bats tests prepended mock commands before sourcing modules, but `01-constants.sh` could prepend Linuxbrew and make the real `openclaw` win. This broke hermeticity and could reach a real command. | Reassert mock `PATH` after sourcing in the affected unit and integration tests. Commit `c0f102c0`. |
| AUD-002 | `nas-cpap-unified.py` printed the first 50 characters of its bearer token to stderr. | Removed the unused credential log. Commit `47dd8c85`. |
| AUD-003 | The Graph OAuth cache treated every read/JSON error as an empty cache and silently ignored failure to set mode `0600`; writes were non-atomic. | Missing cache alone means empty state; malformed/non-object content fails visibly. Save through a mode-`0600` temporary file and atomic replacement; permission failures propagate. Regression tests cover corruption, mode, atomic result and failed permission setup. |
| AUD-004 | `kgraph.validate` recorded excessive depth but continued into recursive XSS/schema validation. A 500-level nested value under a node reproduced `RecursionError` instead of a validation result. Deep JSON decoder recursion also lacked an explicit error response. | Reject over-depth graphs before recursive checks and return a clear error for parser recursion. Tests cover deeply nested dict, JSON payload/file, and decoder recursion. |
| AUD-005 | Chunk concept links repeated the same node-collection and chunk/file edge construction for actors, topics, and themes, making lineage and file-link behavior prone to drift. | Consolidated the shared operation in `_link_chunk_concept`; kept the existing no-file-link behavior for semantic entities. Existing mixed fixture tests assert the produced nodes, edges, and lineage. |
| AUD-006 | Graph models used Pydantic's lax default coercion (`line="8"`, `degree=True`, and string counts were accepted), and model validators silently discarded removed `weight`, internal `_strength`, and renamed `async` fields. Assignment could also bypass field validation. | Enabled strict validation and assignment validation. Kept only evidenced integer-ID normalization and the confidence enum's explicit producer-string conversion; reject booleans/other ID types and obsolete/unknown fields. Added regression coverage for construction, assignment, metadata, and removed fields. |
| AUD-007 | `tests/unit/20-up-npm-safety.bats` installed `npm`/`systemctl` stubs before sourcing `env.sh`, whose constants module prepended host paths; two failure-recovery cases reached host commands and failed. | Reasserted stub precedence after sourcing. All three BATS cases pass through the `.venv` pytest bridge. Commit `729776bb`. |
| AUD-008 | Five repository shell entrypoints launched inline Python through bare `python3`, bypassing the repository venv and risking missing or mismatched dependencies; interpreter selection was duplicated in the Windows environment importer. | Added `tools/python-runtime.sh` as the shared venv-first resolver (then validated `TAC_PYTHON`, then PATH `python3`) and routed all five callers plus the importer through it. Regression cases cover both venv executable names, explicit override, invalid override, PATH fallback, and caller wiring. The deployment script's system-Python venv bootstrap remains an intentional exception. |
| AUD-009 | `tests/unit/04-llama-cpp-inventory.bats` mixed inventory assertions with live release downloads and an install that could replace `~/.local/bin/llama-server`; warning-only checks could appear successful without asserting a result. | Replaced it with an executable read-only inventory and explicit `--update` command. New BATS tests sandbox `HOME`, use a local ZIP fixture and stubbed `curl`, assert install/backup behavior, no-op idempotency, and API/archive failure cleanup and preservation. Registered the suite in CI and the pytest bridge; removed obsolete exclusions and documented the opt-in update. |
| AUD-010 | Several BATS setups sourced `env.sh` before sandboxing `HOME`, or ignored source errors with `|| true`. Source-time probes in `09-openclaw.sh` and `09b-gog.sh` write capability results through `__tac_probe_ok`; `01-constants.sh` forced that cache into shared `/dev/shm`, bypassing test-provided temp paths. | Set test `HOME` and cache directories before loading modules, made source failures fatal (including explicit sentinel checks in nested E2E shells), and let `TAC_CACHE_DIR` honor an explicit path while retaining `/dev/shm` as the default. Added regression assertions that both startup-probe cache files land in the sandbox. |
| AUD-011 | The main `tests/tactical-console.bats` profile loader suppressed all source output and used `|| true`, then marked the profile as loaded. A failed/partial source could therefore leave many tests operating on incomplete functions; one cooldown case only searched output for `1`, which could match command-not-found status `127`. | Propagate profile-source failure with stderr visible, set the loaded flag only after success, and make subprocess profile/env loads exit with a sentinel on source failure. Focused regressions cover cooldown, model recommendation, restore, and env bootstrap/module loading. |
| AUD-012 | `commit_auto` suppressed curl and jq errors, then returned success when no commit message was produced. It also staged the real index before confirmation and reset it on cancellation/failure, discarding pre-existing staged state. | Use curl's fail/show-error flags, keep jq diagnostics visible, and return non-zero for transport or malformed/empty responses. Build the proposed diff and commit with a temporary index seeded from the current index; leave the real index untouched until acceptance, and refuse to overwrite it if it changed during confirmation. Synchronize it to the new `HEAD` after commit. Hermetic tests cover preserved staged state on failures/cancellation and a confirmed local-bare commit/push. |
| AUD-013 | `_MemoryStoreIngest.ingest_chunks` mixed chunk setup, file/actor references, topic/theme extraction, semantic summaries, and embedding collection in one orchestration loop; it also scanned headings twice. | Extract file/actor/reference links, concepts, and semantic-summary construction into focused helpers. Keep `ingest_chunks` as the row/embedding orchestrator and evaluate each chunk's headings once. Existing end-to-end graph and phase tests characterize node, edge, lineage, and embedding output. |
| AUD-014 | README test totals drifted from the test tree after four BATS cases were added: the unit count was 717 instead of 721, which also made the overall and CI-unit counts stale. `tools/docs-sync-check.sh` correctly failed the bridged regression. | Recomputed every README unit/total/CI-unit figure from the checker: 721 unit BATS tests, 2,017 total tests, and 614 unit tests in CI. The docs-sync checker and its BATS bridge case now pass. |
| AUD-015 | The repository had autotune and TSV re-benchmark flows but no standalone, versioned performance artifact binding request samples to model/runtime/hardware/workload identity; prompt data could not be safely shared in reports, and cross-run comparisons had no compatibility gate. | Added opt-in `tools/llm_benchmark.py` with strict JSONL input, loopback-only streaming requests, warmups/repeats/concurrency, per-request and group metrics, SHA-256 model/prompt provenance, environment/device manifest, atomic no-overwrite output, explicit failed samples, and manifest-gated baseline comparison. Added fake-loopback tests and a usage/metric-contract guide in `docs/llm.md`. Error artifacts omit server-provided body text to prevent echoed prompt leakage. No live hardware benchmark or baseline was run. |
| AUD-016 | `_MemoryStoreIngest._ingest_chunk_concepts` combined six extraction strategies and repeated theme creation/linking, making strategy order and the distinct entity/file-link policy difficult to test independently; it also accepted an unused preview argument. | Extracted heading topics, heading themes, explicit themes, line themes, activation authorship, and named-entity passes into focused methods. Consolidated typed-theme creation/linking, removed the unused argument, and preserved the original pass order, line-pattern stop behavior, and no-file-link behavior for named entities. Added a direct phase test asserting emitted concept order and edge policy. |
| AUD-017 | `tools/contracts_check.py` retained `--print-baseline` / `--dump-sites` options and state-contract line indexes in module globals across repeated in-process calls. An imported caller could therefore have a later invocation inherit an earlier output mode or stale contract line number. | Reset parser options at the start of each parse and clear the state-contract line index before each state check. Extended the tool-module test to exercise option reset across multiple argument sets and stale-index cleanup. |

## Confirmed debt / follow-up

| Priority | Finding | Evidence and disposition |
|---|---|---|
| P2 | Contract-checker surface is large and multi-purpose. | `tools/contracts_check.py` is 2,465 lines; `run_continuity` is 243 lines. Its checks are an enforcement surface, so splitting it is deferred until CLI/output contracts have focused tests and module boundaries are clear. |
| P2 | Salus scheduler orchestration is large. | `nas/butler/openclaw/salus-it500/salus.py::_run` is 266 lines. The NAS skill copy has deployment/mirror constraints; no refactor was attempted without a verified source-of-truth and deploy path. |
| P2 | CPAP fetch is deliberately unimplemented. | `nas/butler/scripts/nas-cpap-unified.py::_fetch_cpap_data` raises `NotImplementedError` rather than returning fake success; its consumer is not enabled as a cron collector. Implementing it requires the real API contract, not a placeholder. |
| P2 | Some nested graph payloads remain intentionally broad. | `metadata`, `typed_summary`, `communities`, and cluster suggestions contain `Any`/generic dictionaries, so strict scalar validation cannot define their internal schemas. `value_score`, `source_strength`, and line-range annotations explicitly allow strings because persisted registry rows can carry them. Constraining these further needs persisted-data and producer-shape evidence. |
| P3 | A representative live-hardware LLM performance baseline has not yet been measured. | Synthetic autotune coverage remains; AUD-015 adds a reproducible opt-in local runner and compatible artifact comparison, but this audit did not spend GPU cycles or establish a reviewed baseline. Baseline collection must use the intended model/runtime/hardware after the operator selects representative prompts and a quiet GPU window. |

## Audit checks recorded

- A static import graph over the 23 `scripts/kgraph` modules found no import cycle.
- Searches found no `model_construct`, `strict=False`, global ignored-warning filter, or
  `parse_obj` use in the audited Python trees. The graph boundary now uses strict scalar
  validation and assignment validation; opaque nested dictionaries remain a limitation.
  The community warning capture explicitly enables warnings rather than suppressing them.
- The existing `GraphEdge` `from`/`to` normalization and `set_hot_water` helper are still
  used by current producers/callers; neither was removed as dead compatibility code.
- NAS entrypoints use the NAS runtime, not necessarily this repository's `.venv`; changing
  their interpreter resolution without verifying deployment would break the supported
  runtime. Repository-owned Python checks and tests in this audit use `.venv/bin/python`.

## Verification

- `.venv/bin/python -m pytest -q -p no:cacheprovider --ignore=tests/test_bats_bridge.py`:
  749 passed, 15 subtests passed after strict model validation.
- `.venv/bin/python -m pytest -q -p no:cacheprovider tests/test_models.py tests/test_kgraph.py`:
  236 passed after strict model validation.
- `.venv/bin/python -m pytest -q -p no:cacheprovider tests/test_bats_bridge.py -k
  "50_python_interpreter_resolution"`: 8 passed for the shared interpreter resolver and caller wiring.
- `.venv/bin/python -m pytest -q -p no:cacheprovider tests/test_bats_bridge.py -k
  "04_llama_cpp_tools"`: 7 passed for the sandboxed inventory/updater suite.
- `.venv/bin/python -m pytest -q -p no:cacheprovider tests/test_bats_unittest.py -k
  "04_llama_cpp_tools"`: 1 passed; the unittest bridge includes the replacement suite.
- `.venv/bin/python -m pytest -q -p no:cacheprovider tests/test_bats_bridge.py -k
  "every_runnable_test_suite"`: 1 passed; every runnable BATS suite is referenced by a workflow.
- `bash -n` and ShellCheck (`-x -P bin`) passed for `tools/llama-cpp-inventory.sh`.
- `.venv/bin/python -m pytest -q -p no:cacheprovider tests/test_bats_bridge.py -k
  "refresh_keys or two_sided_freshness or model_lifecycle or backup_restore or
  e2e_bench_autotune or function_availability"`: 143 passed and 1 initially failed because
  the E2E suite had not created its newly isolated cache directory; after adding that setup,
  rerunning `-k "e2e_bench_autotune"` passed all 29 cases.
- `.venv/bin/python -m pytest -q -p no:cacheprovider tests/test_bats_bridge.py -k
  "11_module_versions"`: 7 passed after incrementing `01-constants.sh` to module version 30.
- `.venv/bin/python -m pytest -q -p no:cacheprovider tests/test_bats_bridge.py -k
  "tactical_console and (cooldown_check_cooldown_returns_1_active or
  cooldown_check_cooldown_returns_remaining_time or model_recommend_ranks_on_disk_models
  or restore_recreates_missing_parent_directories or env_sh_library_mode_bootstraps or
  env_sh_loads_09b_gog)"`: 6 passed after making profile loading fail visibly.
- `.venv/bin/python -m pytest -q -p no:cacheprovider tests/test_bats_bridge.py -k
  "42_commit_deploy_push_status"`: 6 passed, including local-bare success and
  `commit_auto` transport/malformed-response/cancellation regressions.
- `.venv/bin/python -m pytest -q -p no:cacheprovider tests/test_bats_bridge.py -k
  "11_module_versions"`: 7 passed after incrementing `10-deployment.sh` for the two
  `commit_auto` batches (module version 9).
- `.venv/bin/python -m pytest -q -p no:cacheprovider tests/test_memory_import.py
  tests/test_kgraph.py`: 188 passed after extracting the memory-store chunk phases.
- `.venv/bin/python -m ruff check scripts/kgraph/memory_import.py
  tests/test_memory_import.py`: passed.
- `tools/docs-sync-check.sh`: passed after updating README test counts.
- `.venv/bin/python -m pytest -q -p no:cacheprovider tests/test_bats_bridge.py -k
  "16_docs_sync"`: 1 passed after correcting the documented counts.
- `.venv/bin/python -m pytest -q -p no:cacheprovider tests/test_llm_benchmark.py`: 8 passed using a fake loopback SSE server; no real model or GPU request was made.
- `.venv/bin/python -m ruff check tools/llm_benchmark.py tests/test_llm_benchmark.py`: passed.
- `.venv/bin/python -m mypy tools/llm_benchmark.py`: passed.
- `tools/docs-sync-check.sh`: passed with the new Python test count and updated README.
- `.venv/bin/python -m pytest -q -p no:cacheprovider tests/test_memory_import.py tests/test_kgraph.py`: 188 passed after extracting concept strategies and adding order/link-policy coverage; the 23 memory-import tests passed again after removing the unused argument.
- `.venv/bin/python -m ruff check scripts/kgraph/memory_import.py tests/test_memory_import.py` and `.venv/bin/python -m mypy scripts/kgraph/memory_import.py`: passed.
- `.venv/bin/python -m pytest -q -p no:cacheprovider tests/test_tool_modules.py`: 2 passed, including repeated contract-checker invocation state.
- `.venv/bin/python -m pytest -q -p no:cacheprovider tests/test_bats_bridge.py -k "22_contracts_state or 24_contracts_guards or 34_contracts_falsification or 25_claimed_success_witness"`: 120 passed, 1,210 deselected.
- `.venv/bin/python -m ruff check tools/contracts_check.py tests/test_tool_modules.py` and `.venv/bin/python -m mypy tools/contracts_check.py`: passed.
- `bash -n` and ShellCheck (`-x -P bin`) passed for the seven modified shell scripts.
- `.venv/bin/python -m ruff check scripts tools tests nas/butler` and
  `.venv/bin/python -m mypy`: passed after strict model validation.
- An earlier full suite reported 2,056 passed, 15 subtests passed, and two failures in
  `20-up-npm-safety`; after reasserting mock `PATH`, all three cases passed
  (`tests/test_bats_bridge.py -k test_20_up_npm_safety`: 3 passed). The 2026-10-15
  fail-fast bridge run passed 223 tests, then caught the README count drift in AUD-014;
  after correction, `-k "16_docs_sync"` and `tools/docs-sync-check.sh` passed. The
  entire bridge was not rerun after correction: the README notes the full suite restarts
  the live gateway, and this host's first BATS case took 291s versus a 0.9s median. No
  full-suite pass is claimed.
