# Model Autotune — Functional Specification v3

### Purpose
For each untuned GGUF model on this machine (RTX 3050 4GB, WSL2 Ubuntu, NTFS mount), discover the model's capabilities on our hardware: the **highest context size that sustains the minimum acceptable TPS** (`LLM_MIN_TPS`, default **10**, uniform for every model), plus the best batch configuration. Discovery is done through real testing — no VRAM estimates, no hardcoded ceilings, no assumptions about what should or shouldn't fit.

The goal is honest capability profiling. A model that sustains the floor gets its maximum usable ctx recorded. A model that cannot reach the floor even at the smallest ctx is recorded as **too slow for our purposes** — its fastest (best-effort) config and true TPS are still saved so the registry reflects what the hardware can actually deliver.

---

### Inputs
- **Model number** (1-39), resolved through the registry at `~/.llm/models.conf`
- **Registry schema** (pipe-delimited, 20 fields):
  ```
  num|name|file|size_gb|quant_cache|arch|gpu_layers|ctx|threads|batch|ubatch|parallel|fit_target_mb|backend|mmap_mode|flash_attn|tps|autotuned|is_default|in_vram
  ```
- **`LLM_MIN_TPS`** env var (default **10**, uniform for every model) — minimum acceptable tokens/second, exported in `env.sh`. This is the single source of truth shared by `scripts/autotune-model.sh` (the live mechanism) and `bin/model-autotune.py`. Autotune seeks the highest ctx that sustains this TPS; a ctx that generates below it is treated as swapping/too-slow and autotune downshifts to a smaller ctx to recover TPS (see Phase 4).

  **Why 10:** TPS is a speed metric and does not change a model's accuracy directly — accuracy is governed by the model, quant, and whether ctx is large enough for the flow. The floor only affects accuracy *indirectly*, by capping ctx (a higher floor forces a smaller ctx). 10 TPS is fast enough for agentic/interactive flows (~faster than reading speed) yet low enough that the 3–4B models — the sweet spot on a 4 GB GPU — keep ample ctx for context-heavy flows. A 20 TPS floor would starve ctx on those models (accuracy cost); 5 TPS is fine for batch flows but sluggish interactively. The autotuned profiles feed a separate quality benchmark (in the investigator repo) that picks the best model per flow, so each model is profiled at its maximum usable ctx for a fair accuracy comparison.

---

### Outputs
- Winning config (ctx, batch, ubatch) + measured TPS written back to the registry via `__llm_autotune_profile_save`
- Registry fields updated:
  - Field 8 (ctx) → winning context size (the highest that sustains `LLM_MIN_TPS`, or the fastest best-effort ctx if the floor is unreachable)
  - Field 10 (batch) → winning batch size
  - Field 11 (ubatch) → winning ubatch size
  - Field 17 (tps) → measured tokens/second (the honest usability signal)
  - Field 18 (autotuned) → `yes` (means "this model has been profiled")

**Reading the result:** `autotuned=yes` means the model was measured, not that it is fast. Compare field 17 (tps) against `LLM_MIN_TPS`:
- `tps >= LLM_MIN_TPS` → usable; field 8 is the maximum ctx that sustains the floor.
- `tps <  LLM_MIN_TPS` → too slow for our purposes even at min ctx; field 8/17 are the fastest config the hardware can deliver. Such models are not re-tuned by `model autotune all` (they are already profiled); reset field 18 to `no` to force a re-tune.

---

### Benchmark Payload
Pure text generation. **No `response_format` constraint** — `json_object` forces grammar-constrained generation that artificially limits throughput on non-JSON-trained models. This was the root cause of the "0 tokens" / low-TPS failures in batch-2.

```
{
  "messages": [{
    "role": "user",
    "content": "Explain special relativity: time dilation, length contraction, mass-energy equivalence."
  }],
  "max_tokens": 256,
  "temperature": 0
}
```

---

### Probe Algorithm

#### START_CTX
Take `_ctx` from the registry and multiply by a **size-aware multiplier**:
- Models under 2GB GGUF (high VRAM headroom) → **4×**
- Models 2GB and over (limited VRAM headroom) → **2×**

This puts START_CTX close to the VRAM ceiling. Round down to nearest 1024. Floor at 4096. Phase 1 steps down if the multiplier is too aggressive.

Rationale: the registry ctx is the model's trained maximum (from GGUF metadata), which is almost always below the VRAM OOM ceiling on this GPU. Small models have 3+ GB of free VRAM after loading, so they can handle 4× their trained ctx. Large models have <1 GB headroom, so 2× is safer.

#### Cross-combo ctx carry-over

After combo 1 finds BEST_CTX, subsequent combos use that value as their START_CTX instead of the registry-derived value. This avoids re-climbing from a low starting point for each combo.

#### Phase 1 — Find a working ctx (step down, single-sample)

Phase 1 is coarse exploration — find any working ctx. Single sample per test is sufficient.

```
c = START_CTX
while c >= 4096:
    tps = bench(c)                  // single run
    if SUCCESS and tps >= MIN_TPS:
        record_best(c, tps)         // track by the success metric (see Scoring)
        → Phase 2
    else:
        if FAIL_LOAD:               // server PID died before health check
            _ALL_LOAD_FAIL = true   // model GGUF cannot be loaded at any ctx
        c = c / 2
        continue

// Early abort: if every ctx size in this combo failed with FAIL_LOAD,
// skip remaining combos and go straight to the --no-mmap fallback.
// If --no-mmap also fails with FAIL_LOAD at every ctx, the model is
// unsupported on this hardware and autotune exits with:
//   "failed: unsupported model — model could not be loaded at any ctx"
```

### Phase 2 — Probe the ceiling (refinement zone uses double-sample)

Phase 2 applies a **stepped convergence** approach. During the climbing phase (increment = working_ctx), a single sample per ctx is sufficient. Once OOM is hit and the increment begins halving (the refinement zone), each ctx is sampled **twice** and the median TPS reported. This smooths out GPU clock variance and thermal throttling that caused 15% TPS variation between adjacent ctx values.

If it OOMs at the same ctx **twice in a row** (confirming a fuzzy OOM boundary), the increment is halved and it retries from the last confirmed working point. Single OOMs are retried — the boundary is probabilistic on this GPU. The probe stops when either:

1. The increment drops below 512
2. The ctx×tps score hasn't improved by more than 5% over the last 3 tests

```
working = ctx found in Phase 1
scores = []                        // rolling window of last 3 scores
samples = 1                        // single sample for climbing phase

for increment in [working, working/2, working/4, ...] while increment >= 512:
    c = working + increment
    oom_count = 0

    while c > working and oom_count < 2:
        tps = bench(c) if samples == 1 else median(bench(c) × 2)

        if OOM:
            oom_count += 1
            if oom_count == 2:
                samples = 2                    // enter refinement zone
                increment = increment / 2
                c = working + increment
                oom_count = 0
        elif tps < MIN_TPS:
            oom_count += 1
            if oom_count == 2:
                samples = 2
                increment = increment / 2
                c = working + increment
                oom_count = 0
        else:
            oom_count = 0
            working = c
            score = c × tps
            record if best
            scores.append(score)
            if len(scores) > 3: scores.pop(0)
            if len(scores) == 3 and both adjacent improvements < 5%:
                stop                          // plateaued
            c = c + increment
```

### Phase 4 — TPS floor recovery (downshift ctx to recover TPS)

Phases 1–2 maximise ctx, which on a 4 GB card can leave a model swapping at large
context: high ctx, low TPS. Phase 4 enforces the floor. If the best config from
Phases 1–2 is below `LLM_MIN_TPS`, ctx is stepped **down** (a smaller KV cache
raises TPS) until the floor is met or the minimum ctx (4096) is reached:

```
if best_tps < MIN_TPS:
    cursor = best_ctx
    while best_tps < MIN_TPS and cursor > 4096:
        cursor = max(4096, floor_to_512(cursor * 0.75))
        tps = bench(cursor)
        if tps valid: best_ctx, best_tps = cursor, tps
```

Because the descent runs top-down, the **first** ctx that meets the floor is the
highest ctx that sustains it — exactly the capability we record. A model still
below the floor at 4096 cannot reach it on this hardware; its fastest
(best-effort) config and true TPS are saved and it is reported as too slow.

### Success metric — lexicographic capability

The objective is **not** `ctx × tps`. That product treats speed and context as
interchangeable on a multiplicative scale, which does not match how the hardware
is actually used: once generation speed clears the usability floor, extra speed
has diminishing returns, while extra context keeps paying off (longer
conversations and documents). Maximising the product can therefore pick a
needlessly slow high-ctx config, or a fast tiny-ctx one, in ways that misrepresent
what a model can do for us.

Instead the winner is chosen by a strict lexicographic order:

1. **Feasibility gate** — a config that sustains `LLM_MIN_TPS` always beats one
   that does not.
2. **Maximise context** subject to that gate — the highest ctx that sustains the
   floor; tiebreak by higher TPS (a snappier config at the same ctx).
3. **Best-effort fallback** — if no config meets the floor (model is too slow on
   this hardware), the highest-TPS config wins (fastest available; tiebreak by
   higher ctx) so the registry still records the model's true capability.

In the refinement zone, TPS is the median of 2 benchmark runs per ctx value to
smooth out GPU clock variance. Comparisons use the full precision TPS value, not
the rounded display value.

The rolling improvement check prevents the probe from spending 20+ iterations refining ctx values that all give similar scores. If the last 3 tests all scored within 5% of each other, further refinement is pointless.

---

### Per-Combo Testing

Different batch/ubatch sizes affect throughput and VRAM usage. Combos are selected by GGUF file size:

| Model size | Combos tested |
|---|---|
| <1 GB | 1024:256, 2048:512, 4096:1024 |
| 1-2 GB | 1024:256, 2048:512 |
| ≥2 GB | 1024:256 |

Each combo runs a full independent Phase 1 + Phase 2 probe. The global best across all combos wins by the success metric above (highest ctx sustaining the floor; best-effort max TPS otherwise).

---

### Server Configuration (llama-server)

```
--model {GGUF file}
--port ${AUTOTUNE_PORT:-18081} --host 127.0.0.1   # Uses AUTOTUNE_PORT to avoid conflict with watchdog (8081)
--ctx-size {ctx}
--batch-size {batch} --ubatch-size {ubatch}
--threads {nproc or registry threads}
--n-gpu-layers {from registry}
--parallel 1
--fit off                       # projection bug in this build — explicit params only
--flash-attn on
--kv-offload
--cache-type-k q8_0
--no-mmap
```

---

### VRAM Management

**Between tests within a model:**
1. `pkill -9 -x llama-server` (ignore if no process found)
2. Poll `nvidia-smi --query-gpu=memory.used` every 1s until it drops to ≤ pre-kill baseline (max 15s)
3. Poll `ss -ltn` until port 8081 is not LISTENing (max 10s)
4. If either times out, report FAIL-port-busy and skip this test

**Between models (batch runner):**
Same drain procedure. Executed before the first model and between every model in the batch.

---

### Health Check

Start server in background. Poll `http://127.0.0.1:8081/health` every 1s up to 90s. Success when the response body contains `"ok"` (the server returns `{"status":"ok"}` when ready). Two exit paths:

- **Server dies during check** (`kill -0` fails): `tail -3` the server log to extract the failure reason, report FAIL-crash
- **90s timeout reached**: kill server, report FAIL-timeout

---

### Error Classification

| Error | Meaning | Handling |
|---|---|---|
| FAIL-crash | Server PID died during health check | OOM on model load, bad params, or port conflict. Phase 1 halves ctx, retries. |
| FAIL-timeout | Health check exceeded 90s | Model load stalled (unlikely on this mount, but possible for very large CPU-only models). Phase 1 halves ctx, retries. |
| FAIL-load | Server PID died before health check returned *any* `ok` response | Model GGUF cannot be loaded on this hardware — unsupported architecture, corrupted file, or incompatible ops. Triggers **early abort**: if this occurs at every ctx size for a combo, remaining combos and the `--no-mmap` fallback are skipped. The script exits with `failed: unsupported model — model could not be loaded at any ctx`. |
| FAIL-0tokens | Server responded but produced 0 completion tokens | Bench curl timed out or empty response. Probably OOM during generation. Treated as failure. |
| FAIL-port-busy | VRAM or port didn't clear after kill | Previous server left state behind. Retry after longer wait. |
| below floor | Server worked but TPS < `LLM_MIN_TPS` | Model is swapping to system RAM. Phase 4 downshifts ctx (smaller KV cache → higher TPS) until the floor is met or min ctx is reached. If still below at min ctx, the best-effort config is saved and the model is reported as too slow. |

FAIL-load is the only error that terminates autotune early. The rest are handled
by stepping down (Phase 1), narrowing the probe (Phase 2), or downshifting
(Phase 4).

---

### Batch Mode

`model autotune all` reads the registry, filters for models where field 18 (`autotuned`) != `yes`, and calls the standalone script for each. VRAM is drained between models. The batch runner prints minimal progress:

```
model autotune all
  models: 35 untuned
  start:  14:45

[1/35] model #1 ... (script output) ... done
[2/35] model #3 ... done
```

The `__llm_autotune_profile_save` function sets `autotuned=yes` in the registry, which excludes the model from subsequent batch runs. If a user wants to re-tune, they can manually set the field back to `no`.

---

### Single Mechanism

`model autotune <N>` and `model autotune all` both route to the same standalone script (`~/ubuntu-console/scripts/autotune-model.sh`). The old `__model_autotune` shell function (which had the `--fit on` bug that caused all the batch-2 failures) is marked deprecated and no longer called. `model bench` also routes to the same script when it needs to autotune an untuned model before benchmarking. There is one live autotune mechanism.

`bin/model-autotune.py` is a parallel implementation kept for experimentation and unit-tested in isolation; it is **not** wired into the CLI. To prevent the two from diverging it shares the same floor policy: it reads the same `LLM_MIN_TPS` env var (default 10, uniform per model) and applies the same downshift-to-recover / honest-profiling semantics described above. If you change the floor policy, change it in `env.sh` (the single source of truth) and both implementations pick it up.

---

### Single-Model Timing Estimates

Measured on RTX 3050 4GB, WSL2, NTFS mount. Cold load from disk dominates per-test time.

| Model size | Load time | Bench time | Per-test total | Phase 1 | Phase 2 | Worst-case total |
|---|---|---|---|---|---|---|
| <1 GB | ~20s | ~2s | ~22s | 1-3 tests | 6-12 tests | ~5 min |
| 1-2 GB | ~45s | ~3s | ~48s | 1-3 tests | 4-8 tests | ~9 min |
| 2-3 GB | ~55s | ~5s | ~60s | 1-3 tests | 3-6 tests | ~9 min |
| 3+ GB (IQ3) | ~60s | ~5s | ~65s | 2-4 tests | 3-5 tests | ~10 min |
| CPU-only (4.2G) | ~80s | ~20s | ~100s | 2-4 tests | 3-5 tests | ~15 min |

35 untuned models: **roughly 4-8 hours** depending on OOM rate and model distribution.

---

### What Went Wrong in batch-2 (Root Cause Analysis)

1. **`--fit on` with explicit args**: llama-server build 8210 has a VRAM projection bug when `--fit on` is combined with explicit `--ctx-size`, `--batch-size`, `--ubatch-size` flags. The projection would OOM models that work perfectly fine with `--fit off`. This caused most of the "server crash" failures.

2. **VRAM tracking was non-functional**: `nvidia-smi --query-compute-apps=pid,used_memory` returns `PID, Used_Memory` with no process name column. The `grep -i 'llama-server'` always failed, so the VRAM drain loop always returned immediately. Next model saw stale VRAM from the previous test's OOM, causing cascade failures.

3. **`json_object` response format**: Forced grammar-constrained generation. Models would produce 5 tokens at ~15 TPS instead of 256 tokens at ~110 TPS. The "0 tokens" reports were actually the model generating a short JSON response and stopping. This made every model look unusable.

4. **No step-down on OOM**: If START_CTX was too high, there was no Phase 1 to step down to a working ctx. The model was simply marked as failed for that combo.

5. **No step-up ceiling**: Phase 2 (when it existed) had unbounded stepping. Models that could handle 100K+ ctx would be tested at 7M+, wasting hours on tests that would eventually OOM.

6. **Multiple autotune implementations**: The tactical console's built-in `__model_autotune` function and the standalone script diverged. One had bugs fixed, the other didn't. They now route to the same standalone script.

---

## Fixes and edge cases

### AUTOTUNE_PORT isolation (card ca23ec0a)
The watchdog daemon (`bin/llama-watchdog.sh`) binds `LLM_PORT` (default 8081).
Autotune originally also bound port 8081, causing a race condition when both
ran simultaneously. Fixed by introducing `AUTOTUNE_PORT` (default 18081):

- `bin/llama-watchdog.sh` declares `AUTOTUNE_PORT` as a documented env var
- `scripts/autotune-model.sh` uses it for all server, curl, health, and
  cleanup operations — 6 HTTP endpoints, the server bind, and the port
  check in `cleanup_gpu` all route through it.
- The bench (`__bench_run_with_timeout`) continues to use `LLM_PORT` (8081),
  so the benchmark is unaffected.

### Post-autotune VRAM clearing (card 1b from merged b9ba4596)
The autotune **failure** path always called `clear_vram.sh`. The **success**
path jumped straight to the bench, inheriting any VRAM fragmentation from
autotune's 6 OOM tests. Fixed by adding `clear_vram.sh` between autotune
completion and `__bench_run_with_timeout` on the success path.

### Burn auto-recover step-down (card 658c3efe)
`burn()` in `11-llm-manager.sh` auto-recovers from transport failures by
calling `__model_use` with the exact same params that caused the crash.
On repeated failures, this thrash-loops the GPU. Fixed by tracking
`_burn_last_recover_count` and halving ctx (floor 1024) and batch
(floor 128) on each successive recovery attempt. A diagnostic line
is printed showing the step-down attempt number and resulting ctx/batch.

### 0-tps OOM classification (card b564d801)
The binary probe in `bench_ctx` checks `$rc -ne 0` to detect OOM. An edge
case occurred where `bench_ctx` returned exit code 0 but produced literally
zero tokens (`tps=0`) — the server responded with 0 completion tokens.
This was treated as a valid run rather than OOM. Fixed by adding an
explicit `tps == "0" / "0.00" / empty` check alongside the exit code check
in the binary probe loop.

### Duplicate stale-locks call not a bug (card 902f30a7)
`__tac_cleanup_stale_locks` appears twice in `__model_bench`. Investigation
confirmed both calls are purposeful: the first runs at function entry (before
trap restoration from a prior interrupted run), and the second runs after
trap setup (before bench work begins). Different safety domains. No change
needed.

### `__bench_run_with_timeout` refactor deferred (card 0967f11c)
The 40-line heredoc with inline traps and PID tracking was assessed for
standalone script extraction. The subprocess isolation is complex because
shell-scoped variables (`__bench_signal_rc`, `__bench_cleanup`, `run_id`)
are set inside the heredoc and read after it completes. Refactor deemed
complex with no current runtime impact. Deferred.

---

*Spec written 2026-06-06. Updated 2026-07-22 (v3: uniform `LLM_MIN_TPS=10` floor, lexicographic success metric, Phase 4 downshift-to-recover, honest capability profiling, load_fail/unsupported model classification & early abort). Corresponding code in `~/ubuntu-console/scripts/autotune-model.sh` and `~/ubuntu-console/scripts/run-autotune-batch.sh`.*
