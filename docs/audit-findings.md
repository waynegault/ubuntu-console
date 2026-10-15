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

## Confirmed debt / follow-up

| Priority | Finding | Evidence and disposition |
|---|---|---|
| P2 | Chunk import remains a large orchestration method. | `scripts/kgraph/memory_import.py::_MemoryStoreIngest.ingest_chunks` combines row decoding, embeddings, references, theme extraction and summary construction. AUD-005 removes repeated link plumbing, but a full phase extraction should follow only with characterization tests for every emitted node/edge and lineage rule. |
| P2 | Contract-checker surface is large and multi-purpose. | `tools/contracts_check.py` is 2,465 lines; `run_continuity` is 243 lines. Its checks are an enforcement surface, so splitting it is deferred until CLI/output contracts have focused tests and module boundaries are clear. |
| P2 | Salus scheduler orchestration is large. | `nas/butler/openclaw/salus-it500/salus.py::_run` is 266 lines. The NAS skill copy has deployment/mirror constraints; no refactor was attempted without a verified source-of-truth and deploy path. |
| P2 | CPAP fetch is deliberately unimplemented. | `nas/butler/scripts/nas-cpap-unified.py::_fetch_cpap_data` raises `NotImplementedError` rather than returning fake success; its consumer is not enabled as a cron collector. Implementing it requires the real API contract, not a placeholder. |
| P2 | Some nested graph payloads remain intentionally broad. | `metadata`, `typed_summary`, `communities`, and cluster suggestions contain `Any`/generic dictionaries, so strict scalar validation cannot define their internal schemas. `value_score`, `source_strength`, and line-range annotations explicitly allow strings because persisted registry rows can carry them. Constraining these further needs persisted-data and producer-shape evidence. |
| P3 | LLM measurement logic is well tested synthetically, but live performance was not measured in this audit. | Existing coverage includes 33 autotune-workload tests, 29 bench/autotune integration tests, and prompt-cache argv parity cases; the tests exercise sample medians, workload selection, TTFT/profile-2 values, contention and drift. They use controlled fixtures and do not certify current hardware performance. No missing code-path benchmark was confirmed from this pass. |

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
- `bash -n` and ShellCheck (`-x -P bin`) passed for the seven modified shell scripts.
- `.venv/bin/python -m ruff check scripts tools tests nas/butler` and
  `.venv/bin/python -m mypy`: passed after strict model validation.
- The full suite before the latest fixes reported 2,056 passed, 15 subtests passed, and
  two failures in `20-up-npm-safety`; after reasserting mock `PATH`, all three cases pass
  (`tests/test_bats_bridge.py -k test_20_up_npm_safety`: 3 passed). The full 20-minute
  bridge suite has not been repeated after this isolated fix.
