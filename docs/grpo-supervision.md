# Supervising a long GPU training run (card UBC-GRPO-002)

A GRPO/QLoRA run is the same shape as a bench run — minutes to hours of exclusive
CUDA-card work — so it is supervised the same way, and the console must be able to
**see** it. This is the companion to `grpo-vram-budget.md` (UBC-GRPO-003, how much
VRAM a run needs), `grpo-training-env.md` (UBC-GRPO-005, the isolated environment)
and `grpo-serving-path.md` (UBC-GRPO-004, what happens to the trained artifact).

REF: "How GRPO Trains Small Language Models with Verifiable Rewards" (Benjamin Nweke, TDS,
2026-09-23) — <https://towardsdatascience.com/how-grpo-trains-small-language-models-with-verifiable-rewards/>

## The runner

`bin/train-timeout-runner.sh` is the sibling of `bin/bench-timeout-runner.sh`
(card `#0967f11c`). It gives a training job a pidfile, a structured start/exit log,
orphan cleanup, and a timeout, and runs the trainer as a foreground child so a
silent exit 1 stops being undebuggable.

Two things make it a **tenant** rather than a second rule:

1. **It claims the card on the bench lock.** It holds `$LLM_BENCH_LOCK_FILE`
   (`flock`, content = holder PID, removed on exit) for the whole run — the same
   path the bench/autotune lane uses. The lock file is removed on exit because
   `bin/gpu-busy.sh`'s signal 4 reads its **existence**; `tools/clean-orphans.sh`
   reaps it after a `SIGKILL`.
2. **It refuses when another agent owns the card.** The bench (`11e-llm-model.sh`)
   and the autotune batch refuse on the investigator's GPU flock, and so does this
   runner (exit 4) — without it a training run could become a second consumer on a
   4 GB card.

The audit doc's own words are *"Training must register as a known tenant, exactly as
a bench does"* (Wayne's call, 2026-09-26, card UBC-GRPO-001).

**A crashed trainer is cleaned fail-closed.** `bin/llama-gpu-clear.sh` runs
**exactly once**, never in a retry loop, and only when this runner actually held the
lock. Every probe of a broken GPU makes WSL capture a core dump
(`Capturing crash … signal: 11`), so a failing cleanup stops and says so instead of
grinding.

## Seeing the run: `oc health`

`oc health` reports the card's **Training lane** (human mode; `09e-oc-health.sh::
__oc_train_lane`, wired into both the enhanced-checker branch and the fallback):

| row | meaning |
|---|---|
| `Training lane: [RUNNING pid=… elapsed=…]` | a training tenant is executing |
| `Training lane: [HELD by another lane (lock: …) — no training tenant]` | the bench lock exists but no training run does — a bench/autotune holder, **or a stale file a `SIGKILL` left behind** (the "stuck lane") |
| `Training lane: [IDLE]` | no training run and no bench lock |

That third distinction is the point: a leftover lock file must not read as a live
training run, and a live run must not be mistaken for a stuck lane.

## The lane identity

Both the health row and the watchdog path agree on **who** a training tenant is:
`__llm_train_lane_holder` (`scripts/11d-llm-gpu.sh`) and `bin/gpu-busy.sh`'s
`training_tenant_busy` both match the **executing** `train-timeout-runner.sh`
artefact — `/proc/PID/exe`, or an argv element for the bash interpreter, with the
argv path gated behind an interpreter check so a `tail -f` of the runner is not read
as a tenant. A shell that merely *names* the runner is never a tenant; that is the
false-BUSY defect `gpu-busy.sh` records three times over.

The two copies are deliberate — `11d` is sourced by the console while `gpu-busy.sh`
is a standalone script that must not depend on that tree — and a **drift test**
pins them together (`tests/unit/12-gpu-exclusivity.bats`, the same idiom already
used for the investigator-lock path).

## The autotune batch

`scripts/run-autotune-batch.sh` is the console's other heavy job on the same card.
It **halts** when a training run holds the card — up front (skipping the drain) and
per row — naming the lane and letting the footer print the real resume command. It
consults the lane read (`__llm_train_lane_holder`), never a bare lock test, so a
stale lock file never refuses a bench run.

## Tests

`tests/unit/12-gpu-exclusivity.bats`: the runner's claim/cleanup/refusal cases, the
lane holder (names a live runner; a mere mention is not a tenant), the console ↔
`gpu-busy` drift pin, the batch halt, and the three `oc health` states.
