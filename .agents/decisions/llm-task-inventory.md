---
name: llm-task-inventory
date: 2026-10-03
status: active
scope: both
---

**Decision (card `9fa9e818`):** every site in the repo that calls an LLM is either
covered by the model registry's benchmark/autotune path, or listed here with a named
reason it is exempt. The audit's concern was that `tools/swallow-classify.py` invokes
an LLM whose model is whatever serves the loopback lane — so its behaviour can change
under it with no bench evidence. That tool now records the resolved endpoint and model
in its report header and marks a model read from `/v1/models` as **UNPINNED** (pass
`--model` to pin it); this record is the inventory the card asked for.

**Enumerated with** `git grep -n 'chat/completions'` (plus `/completion` and
`/v1/models` for the full LLM surface), 2026-10-03.

## Registry-covered (benchmarked / tuned by the model registry)

| Site | What it is |
|------|------------|
| `scripts/autotune-model.sh` (bench + readiness probes) | The autotune path that WRITES the registry rows (`model bench`, `models.conf`). |
| `scripts/spec-decode-bench.sh` | Speculative-decoding bench harness over the active lane. |
| `scripts/spec_dec_crossover.sh` | Spec-dec crossover experiment; its own port. |
| `bin/interview-benchmark.sh` | Interview benchmark; uses llama.cpp `/completion` (the comment at :74 records why). |

These measure the same model the registry names, so a model change is covered by
`model bench` / autotune.

## Exempt — with a named reason

| Site | Reason |
|------|--------|
| `tools/swallow-classify.py:355` | A development/classification tool (proposes `# swallow-ok:` reasons). Not a scored benchmark task; its model is recorded in the report header and marked UNPINNED, with `--model` to pin. |
| `scripts/kv-recall-probe.py:190` | A targeted diagnostic probe with its own oracle; it measures one property of the active model, not a benchmark score. |
| `scripts/10-deployment.sh:433` (`commit_auto`) | Generates a commit message for the user to accept, reject or edit — human-in-the-loop, no rubric or score. The diff is refused to any non-localhost `LOCAL_LLM_URL` by a host check before the call. |
| `scripts/11f-llm-runtime.sh:442` (`burn`) | A synthetic TPS/latency stress test of the active lane — a transport measurement, not a judged task; a model change is caught by `model bench`. |
| `scripts/11e-llm-model.sh:1420,1431` | `model use` launch readiness preflight — a 1-token liveness check, not a task whose output is judged. |
| `scripts/11f-llm-runtime.sh:174,184` | `burn`'s slot-readiness preflight — same liveness-only shape. |
| `scripts/11e-llm-model.sh:4011` | The HOSTED Token Plan endpoint, not a local registry model; out of the local registry's scope by construction. The 1-token probe burns PAID quota, so it is cached 60s (`__os_fetch_cached`). |
| `scripts/11f-llm-runtime.sh:623` interactive chat / `serve` | Human-facing interactive chat; no rubric, no score, unbounded input. |
| `scripts/11c-llm-server.sh:105` | `/v1/models` readiness probe (waits for the served model list) — never sends a completion. |
| `bin/llama-watchdog.sh:230` | `/v1/models` liveness probe only — it never sends a completion. |

**Why:** an LLM-invoking path with no bench evidence can change behaviour silently when
its model changes. Naming each one (registry-covered or exempt-with-reason) is the
mitigation, and the swallow-classify header pin is the live example.

**How to apply:** when adding a new LLM-invoking site, either route it through the
registry's bench/autotune path or add a row here with a reason; do not leave it
implicit.
