---
title: llama.cpp Runtime Audit — flags, semantics and traps
description: Audit of the llama.cpp flags and settings the Tactical Console and investigator pass, against the binary actually built (build 10955). Records removed and deprecated flags, semantic traps, unused capabilities, and how to verify each.
---

# llama.cpp Runtime Audit

**Date:** 2026-09-14
**Auditor:** the agent that rebuilt `~/llama.cpp` (with findings contributed by the console,
investigator and OpenClaw agents)
**Artifact audited:** `~/llama.cpp/build/bin/llama-server` —
`0.4.0-dev (build 10955, commit 2f539596c)`, ggml 0.23.0
**Previously deployed:** `build-cuda133/bin/llama-server` —
`0.1.0-dev (build 10432, commit ab5ce4658)`

## Why this audit exists

The checkout advanced across roughly a thousand commits between the previously deployed
binary and the one now built. Flags drift: some are removed outright, some are
renamed, some keep their name and change meaning. Every finding below was measured on
this box, and each one is marked **[measured]** or **[inferred]** so a reader knows which
is which. Nothing here is quoted from upstream documentation without checking it against
the running binary.

**Read this before changing any `llama-server` invocation.**

---

## 1. Removed flags our repos still pass — LAUNCH-BREAKING

`--mmap`, `--no-mmap` and `--mlock` no longer exist. The current binary rejects them:

```
build-cuda133 (build 10432):  W DEPRECATED: --mmap and --no-mmap are deprecated. use --load-mode mmap instead
                              W DEPRECATED: --mlock is deprecated. use --load-mode mlock instead
build        (build 10955):   error: invalid argument: --no-mmap
                              error: invalid argument: --mmap
                              error: invalid argument: --mlock
```

**[measured]** A rejected argument is fatal: `llama-server` exits before loading the
model. This is not a warning to be scrolled past.

**The replacement is `-lm` / `--load-mode MODE`**, with modes:

| mode | meaning |
|---|---|
| `auto` | *(default)* mmap, unless a device does not support it |
| `none` | no special loading mode — the old `--no-mmap` behaviour |
| `mmap` | memory-map the model |
| `mlock` | force the model to stay in RAM |
| `mmap+mlock` | both |
| `dio` | use DirectIO if available |

**Pass `--load-mode` as TWO tokens — `--load-mode none`, never `--load-mode=none`.** The parser
matches whole argv tokens against its option table and only normalises `_` → `-` for `--`
arguments (`common/arg.cpp:813-824`); it never splits on `=`, so the joined form fails with
`error: invalid argument: --load-mode=none`. This is why both launchers build an argv **array**
rather than a string (`11e-llm-model.sh:862`, `autotune-model.sh:574`).

### Call sites — all migrated 2026-09-14

| repo | file:line | was | now |
|---|---|---|---|
| console | `scripts/11e-llm-model.sh:862` | `--no-mmap` | ✅ `--load-mode none` (native branch). `:864` is the *python* backend's `--use_mmap false` — deliberately untouched, see below and §5 |
| console | `scripts/autotune-model.sh:574` | `--no-mmap` | ✅ `--load-mode none` |
| console | `scripts/autotune-model.sh:1779` | `--no-mmap` | ✅ `--load-mode none` (was `:1763` before the pass was extracted into `probe_no_mmap()`) |
| investigator | `pipeline/cli/_app.py:506` | `--no-mmap` | ✅ `--load-mode none` |
| investigator | `pipeline/cli/_app.py:508` | `--mmap` | ✅ `--load-mode mmap` (or omit; `auto` already means mmap) |
| investigator | `pipeline/benchmark/server.py:330` | `--no-mmap` | ✅ `--load-mode none` |
| investigator | `pipeline/benchmark/server.py:332` | `--mlock` | ✅ `--load-mode mlock` |
| investigator | `pipeline/benchmark/_worker_server.py:48` | `--mmap` | ✅ `--load-mode mmap` (or omit) |

Console: `421435909` (autotune) and `43074055` (11e). Investigator: `4abb46497`. Every row
above was re-grepped on 2026-09-14 — no site in either repo passes a removed flag, and the
lines still match. Keep this table as the re-scan baseline for §7 step 2.

`--use_mmap false` at `11e-llm-model.sh:864` is deliberately **not** in this table: it belongs
to the *python* backend and is correct there — see §5. It was flagged as a tenth call site on
2026-09-14 after being tested against `llama-server` rather than the server that receives it;
checked and refuted.

**Why this was not caught earlier:** the flag was already deprecated *in the binary we
were running* — the old binary printed the deprecation on every launch that used it. The
warning was visible in server logs and unactioned. That is precisely the class of signal
this project's "never silence a warning" rule exists for.

**Severity:** latent, not yet firing when this was written. The live service units do not pass
these flags, and the selection bench does not either — which is why everything currently works.
The `model use` path (`11e-llm-model.sh:862` after migration, on WSL the flag is appended
unconditionally in `auto` mode) and any `mmap_mode == off` autotune row would have failed on
first use with the new binary. **Migrated the same day — see the table above — before the new
binary took over a serving path (§8).**

---

## 2. Semantic traps — flags whose real meaning inverted our assumption

These keep their names but do not mean what the code around them believes. Each was
measured; the console's own comments describe the opposite in two cases.

### 2.1 `--parallel N` DIVIDES the served window **[measured]**

`kv_unified` defaults to **false** (`common/common.h:573`), so each parallel slot gets
`n_ctx / N` unless `-kvu`/`--kv-unified` is passed.

| flags (ctx 4096) | n_slots | n_ctx_slot | kv_unified |
|---|---|---|---|
| `--parallel 1` | 1 | 4096 | false |
| `--parallel 4` | 4 | **1024** | false |
| `--parallel 4 --kv-unified` | 4 | 4096 | true |
| `--parallel 16` | 16 | **256** | false |

Measured in the server's own startup line: `n_slots = 4, n_ctx_slot = 1024, kv_unified = 'false'`.

**The registry contradicts this.** 34 of 35 rows in `~/.llm/models.conf` carry
`parallel=16` (col 12), written by the AUTOTUNE-004 sweep
(`autotune-model.sh:1966-1984`, persisted at `:2054`). The sweep's own premise
(`:1961-1963` and the `11e-llm-model.sh:739` warning) is unified-KV semantics — "N slots at
the tuned single-slot ctx over-commit VRAM". Under that premise 16 slots at ~1.2 GB of KV
could not fit a 4 GB card, so the sweep recording 16 in 34/35 rows is itself the
falsification of its premise: those rows could only "serve" because each slot silently
received `ctx/16`.

Consequences it had before the fix (the RESOLVED block below removes every one):

- **All five service units pin `--parallel 1`**, so the live lanes are correct. Verified:
  `:18081 /props` reports `n_ctx=65536, total_slots=1`.
- **`model use` of any registry row serves `ctx/16`.** `11e-llm-model.sh:814` passes the
  registry value, and `:994` execs the argv directly (no unit involved). For
  Llama-3.2-3B that is an advertised 21504 and a served **1344 tokens per request**.
- The AUTOTUNE-004 guard cannot fire: `11e-llm-model.sh:493` sets
  `row_parallel_envelope="$parallel_slots"`, so the test at `:738` is `N > N` — always false.
- The investigator's `pipeline/benchmark/_worker_server.py:107` takes `_df["parallel"]`
  directly (overridable only by a runtime object at `:120` or tuned params at `:132`), so
  its worker server inherits the trap. Carded as REGISTRY-PARALLEL-001.

**The assertion that catches this, whichever semantics is chosen:**

```
advertised contextWindow == n_ctx_slot
```

Both quantities are in `/props`. This form is semantics-independent, unlike
`total_slots × n_ctx_slot == ctx`, which breaks under `-kvu` (4 × 4096 ≠ 4096).

**Migration options:** pin `--parallel 1` in the launcher (matches every live unit and this
card's reality), or keep N and set the window explicitly with
`--kv-unified-per-slot <n>` (`common/arg.cpp:1647`, "max context per parallel slot") so it
is **set**, not derived.

**RESOLVED 2026-09-14 — option (a): the launcher pins `--parallel 1`.** [measured]

- `11e-llm-model.sh` no longer reads the registry parallel column for launch and sets
  `parallel_slots=1`. `LLAMA_PARALLEL_SLOTS>1` is now **refused loudly** rather than honoured
  (silently dividing the window is what we are removing); real concurrency must be set
  explicitly with `--kv-unified-per-slot`.
- The vacuous AUTOTUNE-004 guard is gone, replaced by the runtime assertion above: after a
  launch the launcher curls `/props` and warns when
  `default_generation_settings.n_ctx != ` the advertised ctx.
- The envelope sweep in `autotune-model.sh` (2/4/8/16 slots at the winning ctx) is retired;
  the column records `1`. Retiring it also removes **four** llama-server launches per row
  from the WSL2 dxgkrnl context-cycle budget.
- All 35 registry rows migrated: column 12 is now `1` for every row (34 held 16). Verified
  that every *other* field is byte-identical; backup at
  `~/.llm/models.conf.bak-20260914-parallel1`.

Rejected alternative: keeping N and advertising `ctx/N`. It would require re-certifying all
34 rows — their recorded ctx was measured at one slot — and on a 4 GB card a second full
window does not fit beside a 3B model anyway.

### 2.2 `--fit` defaults to ON, and can shrink the window to 4096 **[measured]**

`common/common.h:476 bool fit_params = true` — so a launch that omits `--fit` lets
llama.cpp *adjust unset arguments to fit device memory*, silently reducing the window.
The floor is `common/common.h:478 fit_params_min_ctx = 4096`.

Observed in a launch that passed no `--fit`: `common_init_: fitting params to device memory ...`

**Consequence:** a serving launch that omits `--fit off` can re-derive the very context
window the registry advertises — the same silent-mismatch class as 2.1 and as the
8192-vs-65536 fault fixed on 2026-09-14. All five units pass `--fit off`; the autotune and
crossover paths pass `--fit off`; `model use` passes `--fit on --fit-target`. Anything new
must pass it explicitly.

### 2.3 `OCL_ICD_VENDORS` hid the Xe iGPU **[measured, fixed in `fcdb6537`]**

`01-constants.sh` exported `OCL_ICD_VENDORS=/etc/OpenCL/vendors`, commented as exposing the
iGPU. It did the opposite: **any** value of that variable made the loader enumerate zero
platforms.

| value | result |
|---|---|
| unset | `GPUOpenCL: Intel(R) Graphics [0x46a6] (30197 MiB, ...)` |
| `/etc/OpenCL/vendors` (directory) | `E ggml_opencl: platform IDs not available.` → `(none)` |
| `/etc/OpenCL/vendors/intel.icd` | `(none)` |
| `/etc/OpenCL/vendors/intel64.icd` | `(none)` |
| both, colon-joined | `(none)` |

Both ICD libraries exist, so this was never a missing-library problem. The loader in play is
the **CUDA toolkit stub** `/usr/local/cuda/targets/x86_64-linux/lib/libOpenCL.so.1`, not the
system `ocl-icd` loader — confirmed by `ldd` on `build-opencl/bin/llama-server`.

**Proven consequence, not inferred:** launching the Xe lane from a console-sourced shell
loses the device and **serves from CPU**:

```
E ggml_opencl: platform IDs not available.
warning: no usable GPU found, --gpu-layers option will be ignored
```

It does not fail — it starts, serves, and is orders of magnitude slower. The live Xe lane
was never affected because the systemd units set their own environment and never source
`01-constants.sh`.

### 2.4 `GGML_CUDA_ENABLE_UNIFIED_MEMORY` is inert **[measured]**

Not a CMake option in either the current tree or the tarball tree. The only consumers are
`getenv("GGML_CUDA_ENABLE_UNIFIED_MEMORY")` at `ggml-cuda.cu:143` and `:4989`, and **nothing
on this box sets that variable**. The `UNINITIALIZED` cache type was the tell — an undeclared
variable, not a configured behaviour.

**Consequence:** `build/` and `build-cuda133` never actually differed in memory behaviour.
The rationale in `investigator/docs/gpu-openclaw-coordination.md` for keeping them apart
("unified memory is how the bench fits more than 4 GB of model onto the 4 GB card") does not
describe anything that ever happened.

### 2.5 `GGML_CUDA_COMPRESSION_MODE=size` compresses the binary, not VRAM **[measured]**

It is `nvcc -compress-mode` applied to the linked CUDA library
(`ggml/src/ggml-cuda/CMakeLists.txt:199`). It cannot affect weight residency and buys no
VRAM headroom. (Corrected in the build guide's flag table.)

---

## 3. Capabilities the build has that we do not use

### 3.1 No anti-repetition sampler anywhere — the likely cause of the 0.028 collapse

The build carries the full sampler set, and **neither repo sets any of it**:

`--repeat-last-n`, `--repeat-penalty`, `--dry-multiplier`, `--dry-base`,
`--dry-allowed-length`, `--dry-penalty-last-n`, `--dry-sequence-breaker`,
`--top-nsigma`/`--top-n-sigma`, `--min-p`, `--xtc-probability`, `--xtc-threshold`,
`--typical`/`--typical-p`, `--top-k`, `--top-p`, `--dynatemp-range`
(`common/arg.cpp:2021-2210`).

The assessment path decodes greedily (`--temp 0` / `temperature: 0`) with **no repetition
control**, which is the textbook configuration for a loop. The investigator's sanity gate
rejected `unique_word_ratio = 0.028 < 0.25` on `nexus-legal-q4_k_m.gguf`; I reproduced the
same class of failure independently (`0.0693` on a short prompt) at `temperature 0` with
`top_k 1` and no penalty — **on both binaries**, so it is not the engine.

The investigator already has detection (`~/investigator/docs/design/ANTIDOOM-REPETITION-ANALYSIS.md`
— their repo, not this one — and a `min_repeats=4, max_period=1024` detector) but no prevention at the
sampler.

**This is the highest-value unexplored lever on the degeneracy question.** It is a
configuration change, not a model or binary change, and it is cheap to test:
`--repeat-penalty 1.1 --repeat-last-n 256`, or DRY (`--dry-multiplier 0.8`), against the
same case.

### 3.2 Other unused flags worth knowing

- `-dev` / `--device` (`arg.cpp:2734`) — explicit device selection. Relevant if a single
  build is ever made to serve both GPUs (see §5).
- `--n-cpu-moe` / `--cpu-moe` — MoE-specific CPU offload. The registry contains MoE rows.
- `--no-warmup` — the units currently pay a warmup.
- `/props` exposes `build_info`, `total_slots`, `n_ctx` — the right probes for the
  assertions in §2.1. Note `build_info` is a **placeholder** (`b0-unknown`) on tarball
  builds that cannot embed a version, and `/v1/models` does **not** carry it at all.

---

## 4. The dxgkrnl counter is an odometer, not a leak meter

`docs/llm.md` previously described `dxgkio_reserve_gpu_va: -75` accumulating as GPU VA leaks,
with the boot-scoped `CUDA_CYCLE_BUDGET` halting autotune when it reaches 60. That section was
corrected in the same pass — it now carries the measurement table below. Four measurements say
the counter does not behave that way:

| activity | delta in `dxgkio_reserve_gpu_va: -75` |
|---|---|
| 24 clean `llama-server` spawn/kill cycles, 8-token completions | **0** |
| 2 server sessions doing 512-token generations | **+28** (~14/session) |
| 5× SIGKILLed `nvidia-smi` | **0** |
| 1 bench run of 3 real assess cases (+ lane restarts) | **+14** |

**[measured]** It tracks **inference volume**, not context churn and not process count. A
high since-boot value is therefore expected after a day of heavy work and is not by itself
evidence of degradation. The threshold (20) has no measured baseline behind it, so the
probe currently reports `degraded` on a healthy box.

**Read the count from `journalctl -k -b`, never `dmesg`.** Measured on the same box minutes
apart: `dmesg` said **2**, the journal said **30**. The ring buffer evicts entries.

**Status of the NO_VMM hypothesis: UNPROVEN · MECHANISM-JUSTIFIED · CHEAP.** The
mechanism is real by construction — the VMM pool reserves 32 GiB of VA per process
(`ggml-cuda.cu:537`, `:593`), removed entirely under `#ifndef GGML_USE_VMM`, and confirmed
present at runtime as `NO_VMM = 1`. But the leak was never measured: this counter cannot
arbitrate it (see the table), and 24 cycles is ~5% of the historically recorded
~350-440-cycle cliff. **Do not let this drift into "the leak was never real" — we tested an
instrument that cannot see it.** Genuine evidence would need a per-spawn count of VA
reservations, or a run to the cliff with `wsl --shutdown` in hand.

**Side effect of the rebuild:** `--load-mode` / `--no-mmap` aside, the rebuild was proven
numerically neutral. Three runs × three prompts comparing the old and new binaries produced
**byte-identical** output, and the FA_QUANTS migration (49 kernel pairs → 4) also produced
byte-identical output against the pre-migration build. Decode TPS medians matched
(p1: 59 vs 61; p2: 65 vs 65; p3: 61 vs 65, n=3). Single-sample TPS on this box is
unreliable — the same binary on the same prompt spanned **45–67 tps** across three runs,
≈±15%.

---

## 5. Things that are correct — do not "fix" these

- `CMAKE_CUDA_ARCHITECTURES=86` — the only dGPU is SM 8.6. Confirmed at runtime as `ARCHS = 860`.
- `GGML_CUDA_FA=ON` + `GGML_CUDA_FA_QUANTS` list — covers `q8_0-q8_0` (every registry row)
  and the sweep's `q4_0-q4_0`. Verified neutral against `FA_QUANTS=all`.
- `GGML_NATIVE=ON` — safe on Alder Lake: AVX2/F16C/FMA/BMI2 are common to P and E cores,
  and the runtime CPU list shows no AVX-512.
- `--threads 6` — matches the 6 P-cores; the console caps every `nproc`-derived path at 6
  (`01-constants.sh:289`, `11d-llm-gpu.sh:814`). The *unit files* outside the repo are the
  exception, and it is current, not historical: as of 2026-09-14 the CUDA lane runs
  `--threads 4` and the Xe lane `--threads 8` (the 8081 unit runs `--threads 6`).
- `--reasoning off` — current flag (`arg.cpp:3677`, `[on|off|auto]`, default `auto`).
- `--cache-type-k/v q8_0` — current and appropriate.
- Removed spec-decode flags are already documented and not used.
- **`--use_mmap false` (`11e-llm-model.sh:864`) is correct — do NOT "migrate" it to
  `--load-mode`.** It is passed only on the **python** backend, which builds
  `("$python_bin" "-m" "$LLM_SERVER_MODULE")` (`11e:819`) — i.e. `llama_cpp.server`, not
  `llama-server`. That server *does* accept `--use_mmap USE_MMAP` (default `True`); verified
  against the installed llama-cpp-python 0.3.23. The native branch passes `--load-mode none`
  instead, and the two branches are mutually exclusive, so `llama-server` never receives
  `--use_mmap` (it would reject it: `error: invalid argument`). Rewriting this site to
  `--load-mode` would break the python backend, which has no such flag.
  No registry row selects the python backend today — 34 `native` + 1 `llama_server`, and
  `11e:589-599` maps both to native — so the site is also unexercised.

**Two GPU lanes are on different source revisions** and that is worth knowing before anyone
"unifies" them: `build-opencl` is built from the `~/llama-src/b6b003d2…` tarball (b10944),
while `build` and `build-cuda133` come from the `~/llama.cpp` checkout. A single build *can*
serve both GPUs — each backend is a separate `libggml-*.so` and `ggml_backend_load_all()`
loads every one beside the binary (`ggml-backend-reg.cpp:574`), with `--device` selecting per
process — but doing it would also unify revisions, which is a larger change than it looks.

---

## 6. Verification recipes

```bash
c() { journalctl -k -b --no-pager -q | grep -c "dxgkio_reserve_gpu_va: Ioctl failed: -75"; }

# Does a flag exist in the built binary? (no GPU context is created by --version)
~/llama.cpp/build/bin/llama-server --NAME --model /nonexistent.gguf 2>&1 | grep -i "invalid argument"

# Is the running lane what you think it is? (pgrep -f SELF-MATCHES your own shell)
# Canonical name; the legacy `llama-server-nvidia.service` is a relative alias.
P=$(systemctl --user show llama-cuda-llama32-3b-chat.service -p MainPID --value); readlink -f /proc/$P/exe

# Is the lane really GPU-offloaded, and at what window? (semantics-independent)
curl -s :18083/props | jq '{n_ctx: .default_generation_settings.n_ctx, total_slots, build_info}'

# Offload ratio: cpu/wall ~0.9 = offloaded, ~4-8 = CPU threads.
# NOTE: `--list-devices` is unreliable for OpenCL from a console-sourced shell (§2.3);
# it is reliable for CUDA. Use /health or the ratio for the Xe lane.

# The runtime feature line (needs -lv 4; it is LOG_TRC and is NOT printed at default verbosity)
~/llama.cpp/build/bin/llama-server --host 127.0.0.1 --port 39199 --model M.gguf -lv 4 2>&1 | grep "system_info"
```

**Build hygiene, learned the hard way:** configure a tree under the name it will live under.
`RPATH` is baked at configure time as an absolute path, so a tree configured as `build-fresh`
and renamed to `build` dies with `cannot open shared object file`. And always wipe rather
than reconfigure a tree that came from a different source or flag set — a reused tree
silently absorbed 150 objects from a five-day-old build here, producing an artifact that
looked fine and was half-swapped.

## 7. Upgrading llama.cpp — checklist

A pull is not free. It changes the artifact, invalidates every validation result pinned to the
previous commit, and can silently break invocations. On 2026-09-14 the 13-commit gap between the
deployed binary and upstream contained **zero** changes to `common/arg.cpp` or `common/common.h`
— the flag hazard was absent — and nothing addressing any open finding. **Check that before
pulling, not after.**

### Before pulling — is there a reason?

```bash
cd ~/llama.cpp
git fetch origin
git log --oneline HEAD..origin/master | wc -l                      # how far behind
git diff HEAD..origin/master -- common/arg.cpp common/common.h     # FLAG/DEFAULT CHURN - check first
git log --oneline HEAD..origin/master -- \
    ggml/src/ggml-cuda ggml/src/ggml-cpu ggml/src common src tools/server \
    ggml/CMakeLists.txt CMakeLists.txt                             # what would actually rebuild
git log --oneline HEAD..origin/master | grep -iE \
    "vmm|wsl|dxgk|repet|dry|parallel|mmap|load-mode|fit"            # anything relevant to us
```

If nothing in the gap addresses a problem we actually have, **do not pull.** Staying pinned at a
validated commit is a legitimate steady state, not drift.

### When pulling

1. `git pull --ff-only`.
2. **Re-run the removed-flag scan across both repos** (§1). A removed flag is fatal, and this is
   the failure that has actually happened here. Do it *before* rebuilding so the migration lands
   in the same change.
3. **Rebuild properly**: wipe the tree, do not reconfigure in place, and configure it **as
   `build`** (§6). A version bump changes the `.so` sonames, and a build-system change (e.g.
   removing precompiled headers) invalidates broadly — expect a full rebuild (~40-60 min at
   `-j6`), not the ~10 min a warm incremental one takes.
4. **Verify the artifact, not the cache**: `--version`; the runtime feature line at `-lv 4`
   (`ARCHS`, `NO_VMM`, `FA_QUANTS`, `USE_GRAPHS`); every object dated today.
5. **Re-run the behaviour checks the upgrade invalidated**: the output-identity A/B against the
   previous binary, and TPS **with repeats** — the run-to-run spread on this box is ~±15%, so a
   single sample proves nothing.
6. **Reconcile the version string.** The console reads `LLAMA_BUILD_VERSION` from
   `git -C ~/llama.cpp rev-parse --short HEAD`, so after a pull it advertises the new commit while
   the installed binary is still the old one — until you rebuild. Keep the two in step.

### The trap: a build pulls for you

`11e-llm-model.sh:3120` runs `git pull --ff-only` before configuring, so **any `llm-build` moves
the source to upstream's tip and rebuilds**, not just the target named. To stay pinned at a
known-good commit, use `llm-build --no-pull`, and prefer it during any validation window.

**GUARDED 2026-09-14 [measured].** `llm-build` now prints its plan before changing anything —
source and current commit, `pull: <remote> -> <target> (N commits behind)`, the **flag/default
churn** probe (`common/arg.cpp` + `common/common.h`), the rebuild path, and the **lane impact**
(whether the live CUDA lane serves a binary inside the tree about to be rebuilt) — and then
asks. It **fails closed**: with no terminal to confirm on (a script, an agent) it refuses and
says how to proceed, so a pull cannot arrive through a command that looks like it is just
building. `--yes` gives explicit consent; `--no-pull` skips the pull entirely.

Verified live: `llm-build --quick` with no terminal printed the plan, refused, and left both
`HEAD` and the binary's mtime untouched. The plan in that run reported `origin/master ->
391fac164 (14 commits behind)` with `flags: none` — the reader gets the answer to "is this pull
safe" *before* deciding.

---

## 8. Repoint of the CUDA lane — DONE 2026-09-14 **[measured]**

`~/.local/bin/cuda-llama-server` now points at `build/bin/llama-server` (b10955 /
`2f539596c`), and `llama-server-nvidia.service` was restarted onto it.

| | before | after |
|---|---|---|
| symlink | `build-cuda133/bin/llama-server` | `build/bin/llama-server` |
| running exe | `build-cuda133/bin/llama-server` | `build/bin/llama-server` |
| `/props` `build_info` | `b10432-ab5ce4658` | **`b10955-2f539596c`** |
| `/props` `n_ctx` / `total_slots` | 21504 / 1 | **21504 / 1** (unchanged — the invariant holds) |
| VRAM used / free | 3376 / 590 MiB | **3376 / 590 MiB** (identical) |
| state | — | active, `NRestarts=0`, `/health` ok, served a generation |

The serving regime was the one unverified case (a 3B model at ctx 21504 on a 4 GB card): the
NO_VMM `cudaMalloc` allocator shows **the same VRAM footprint** as the VMM build, so no
fragmentation penalty at this window. Rollback: point the symlink back at
`build-cuda133/bin/llama-server` and restart, per
`~/.local/bin/.cuda-lane-repoint-20260913`.

Note the lane was already **down** when this was done (stopped cleanly at 18:08:39 by the
watchdog's busy-GPU policy, `Result=success`), so the restart also restored service.

**Hazard found while repointing:** `~/.local/bin/llama-gpu-clear.sh:43` selects victims with
`pgrep -f 'llama.cpp/build/bin/llama-server|...'` — a match on the **command line**, so any
shell whose text mentions that path (including an agent's) is killed, with a `kill -KILL`
fallback at `:51`. It killed this session's shell during the restart. Match the executable
(`readlink /proc/<pid>/exe`) instead of the command line to remove the self-match.

---

## Appendix — provenance, and what was removed

Live trees:

```
~/llama.cpp/build/bin/llama-server   0.4.0-dev (build 10955, commit 2f539596c)   NO_VMM=ON, FA_QUANTS=list  [CUDA lane since §8]
~/llama.cpp/build-cuda133/...        0.1.0-dev (build 10432, commit ab5ce4658)   VMM, FA_QUANTS=all  [rollback only — no longer serving]
~/llama.cpp/build-opencl/...         cannot print --version; tarball b6b003d2    [Xe + embed lanes]
~/.local/opt/llama.cpp/b9371/...     0.4.0-dev (build 10216, commit 876a43211)   PATH install, not a lane
```

Convenience links, so nobody assumes a bare `llama-server` is a lane.  As of
2026-09-15 these are one-line forwarding shims to the canonical card launchers
rather than symlinks to a build: `cuda-llama-server` → `llama-cuda-server` → `build`
(repointed in §8; this is the CUDA lane's pointer), `xe-llama-server` and
`xe-llama-embed` → `llama-xe-server` → `build-opencl`, `cuda-llama-bench` →
*(wrapper script)* → `build`.  Removed on 2026-09-15: `llama-server-cuda` (the
pre-repoint target `build-cuda133`, now rollback-only), `cuda-llama-phi4` (the
retired Phi-4-mini lane), and `llama-cli` (the unrecorded `~/.local/opt` build).
A bare `llama-server` is deliberately **not** on PATH: `~/.local/opt/llama.cpp/b9371`
serves an unrecorded card, so it was a coin-flip.

Checked again 2026-09-15, because the repoint marker made this read like a live
divergence: it is **history, not current state**.  The CUDA lane's pointer and the bench
wrapper agree — both `build/bin/llama-server` — the symlink was re-pointed back from
`build-cuda133` on 2026-09-14 18:09, and the running lane's own `/proc/PID/exe` is
`build/bin/llama-server` (the investigator's engine-identity field reports b10955 /
2f539596c for it).

One hazard survives that check: `cuda-llama-bench` is a **path-pinned wrapper** (Hal,
2026-09-11) whose `REAL` is a literal path, so a future repoint of the lane's symlink
would silently leave the bench measuring the old build.  Its only caller is the
investigator's screen, whose rows now record the engine they actually ran
(BENCH-ENGINE-ID-001), so the divergence is observable rather than silent.  A check on
this side that the launcher, the constants' build and the units' `ExecStart` still
agree now exists —
`tests/unit/12-gpu-exclusivity.bats` asserts the two launcher defaults match
`LLAMA_CUDA_SERVER_BIN` / `LLAMA_XE_SERVER_BIN` and that every lane unit's
`ExecStart` names a canonical card launcher (2026-09-15).  The bench wrapper's own
binary resolution stays with the investigator under `WRAPPER-CUDA-BENCH-001`.

Provenance note: `LLAMA-CPP-SOURCE-COMMIT.txt` exists in **`build-opencl/` only** (it records
the tarball sha and the lane). `build/` has no such file — its exact configure line is
recoverable from `build/CMakeCache.txt` (`GGML_CUDA=ON`, `GGML_CUDA_FA_QUANTS` = the four
pinned pairs, `GGML_CUDA_FA_ALL_QUANTS=OFF`, `GGML_CUDA_NO_VMM=ON`, `GGML_NATIVE=ON`,
`GGML_CCACHE=ON`, `BUILD_SHARED_LIBS=ON`, `GGML_OPENCL=OFF`, `CMAKE_BUILD_TYPE=Release`,
`CMAKE_CUDA_ARCHITECTURES=86`).

### Removed 2026-09-14 (~5.7 GB of the ~8.5 GB that had accumulated)

Deleted only after confirming that nothing executed from them, no symlink or systemd unit
referenced them, and no process had their libraries mapped. Recorded here so the identities
are not lost:

| tree | size | what it was |
|---|---|---|
| `build.tarball-b10944-20260914` | 849M | the previous `build/` — codeload tarball of `b6b003d2` (= tag b10944), built 2026-09-13. Was the undo for the current `build/`. |
| `build.rollback-20260913` | 1.4G | CUDA rollback, build 10431 @ `1692f9e50` (2026-08-14); kept by the 2026-09-13 upgrade as its predecessor. |
| `build-opencl.rollback-20260913` | 873M | Xe rollback, build 10431 @ `1692f9e50` (2026-08-29). |
| `build-novmm` | 1.5G | scratch from the 2026-09-06 NO_VMM spike; had absorbed 150 objects from that older build when it was reconfigured in place, so its artifact was mixed and untrustworthy. |
| `build-sycl` | 1.1G | Intel SYCL experiment (2026-08-28), referenced by nothing. |

**The rollback path is now "rebuild", not "restore a directory".** `build/` is reproducible
from the checkout using the configure line recorded in the build guide, cross-checked against
`~/llama.cpp/build/CMakeCache.txt` (there is no `LLAMA-CPP-SOURCE-COMMIT.txt` in `build/` —
that file exists only under `build-opencl/`); the ccache is warm, so a clean rebuild took
under ten minutes when measured. Note also that a build tree cannot simply be renamed into
place — `RPATH` is baked at configure time (§6).

