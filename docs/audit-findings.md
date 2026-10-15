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

## Confirmed debt / follow-up

| Priority | Finding | Evidence and disposition |
|---|---|---|
| P2 | Chunk import remains a large orchestration method. | `scripts/kgraph/memory_import.py::_MemoryStoreIngest.ingest_chunks` combines row decoding, embeddings, references, theme extraction and summary construction. AUD-005 removes repeated link plumbing, but a full phase extraction should follow only with characterization tests for every emitted node/edge and lineage rule. |
| P2 | Contract-checker surface is large and multi-purpose. | `tools/contracts_check.py` is 2,465 lines; `run_continuity` is 243 lines. Its checks are an enforcement surface, so splitting it is deferred until CLI/output contracts have focused tests and module boundaries are clear. |
| P2 | Salus scheduler orchestration is large. | `nas/butler/openclaw/salus-it500/salus.py::_run` is 266 lines. The NAS skill copy has deployment/mirror constraints; no refactor was attempted without a verified source-of-truth and deploy path. |
| P2 | CPAP fetch is deliberately unimplemented. | `nas/butler/scripts/nas-cpap-unified.py::_fetch_cpap_data` raises `NotImplementedError` rather than returning fake success; its consumer is not enabled as a cron collector. Implementing it requires the real API contract, not a placeholder. |
| P2 | Some graph model internals remain intentionally broad. | `GraphNode`, `GraphEdge`, `GraphMeta`, and `Graph` forbid unknown top-level fields; graph loading uses Pydantic `model_validate`. `metadata`, `typed_summary`, and community summaries still contain `Any`/generic dictionaries, and IDs/endpoints deliberately normalize numeric values. Constraining these further needs persisted-data and producer-shape evidence. |
| P3 | LLM measurement logic is well tested synthetically, but live performance was not measured in this audit. | Existing coverage includes 33 autotune-workload tests, 29 bench/autotune integration tests, and prompt-cache argv parity cases; the tests exercise sample medians, workload selection, TTFT/profile-2 values, contention and drift. They use controlled fixtures and do not certify current hardware performance. No missing code-path benchmark was confirmed from this pass. |

## Audit checks recorded

- A static import graph over the 23 `scripts/kgraph` modules found no import cycle.
- Searches found no `model_construct`, `strict=False`, global ignored-warning filter, or
  `parse_obj` use in the audited Python trees. The community warning capture explicitly
  enables warnings rather than suppressing them.
- The existing `GraphEdge` `from`/`to` normalization and `set_hot_water` helper are still
  used by current producers/callers; neither was removed as dead compatibility code.
- NAS entrypoints use the NAS runtime, not necessarily this repository's `.venv`; changing
  their interpreter resolution without verifying deployment would break the supported
  runtime. Repository-owned Python checks and tests in this audit use `.venv/bin/python`.

## Verification

Commands, results, commit hashes, and any final-suite limitations are recorded in the
audit task handoff. Run the repository's `.venv/bin/python -m pytest` and relevant bats
suites before treating the current findings as closed.
