#!/usr/bin/env bats
# ==============================================================================
# AUTOTUNE-001: workload-selectable scoring payload for the autotune TPS floor.
#
# autotune-model.sh certifies the ctx/batch/TPS winner against a
# workload-selectable scoring payload: --workload chat|legal|agentic|mix
# (env LLM_AUTOTUNE_WORKLOAD), reusing the SPEC-DEC-006 legal/agentic prompt
# sets from scripts/prompt-sets.sh (the single shared source with
# spec-decode-bench.sh), and records the workload used in the registry row
# (schema v6, column 33).
# ==============================================================================

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
TMPDIR_BATS="$(mktemp -d)"

setup() {
    source "$REPO_ROOT/scripts/01-constants.sh"
    source "$REPO_ROOT/scripts/11d-llm-gpu.sh"
    # 11b resolves the model reference to a FILE name through the registry helpers in 11a
    # (the row identity is the file, not the number), so 11a must be loaded first.
    source "$REPO_ROOT/scripts/11a-llm-registry.sh"
    source "$REPO_ROOT/scripts/11b-llm-autotune.sh"
    source "$REPO_ROOT/scripts/prompt-sets.sh"
    export LLM_REGISTRY="$TMPDIR_BATS/models.conf"
}

teardown() {
    rm -rf "$TMPDIR_BATS"
}

@test "autotune-001: prompt sets resolve per workload (shared with spec-decode-bench)" {
    __resolve_prompt_set legal
    [[ "${#PROMPTS[@]}" -eq 5 ]]
    [[ "${PROMPTS[0]}" == *"mediation"* ]]
    __resolve_prompt_set agentic
    [[ "${#PROMPTS[@]}" -eq 5 ]]
    [[ "${PROMPTS[0]}" == *"search_corpus"* ]]
    __resolve_prompt_set mix
    [[ "${#PROMPTS[@]}" -eq 11 ]]
    __resolve_prompt_set chat
    [[ "${#PROMPTS[@]}" -eq 1 ]]
    __resolve_prompt_set physics
    [[ "${#PROMPTS[@]}" -eq 1 ]]
    # Unknown sets are rejected without clobbering the globals.
    local before_names=("${PROMPT_NAMES[@]}")
    if __resolve_prompt_set bogus; then
        echo "bogus set must fail" >&2
        return 1
    fi
    [[ "${PROMPT_NAMES[*]}" == "${before_names[*]}" ]]
}

@test "autotune-001: profile-save records the workload (col 33, v6 schema)" {
    cat > "$LLM_REGISTRY" <<'EOF'
#|name|file|size_gb|quant_cache|arch|gpu_layers|ctx|threads|batch|ubatch|parallel|fit_target_mb|backend|mmap_mode|flash_attn|tps|autotuned|is_default|in_vram|prefill_tps|p2_ctx|p2_batch|p2_ubatch|p2_tps|p2_prefill
1|Model One|model-one.gguf|1.0G|Q4_K_M/q8_0|qwen2|24|4096|6|1024|256|1|1024|llama_server|auto|on|0|no|no|no
EOF
    __llm_autotune_profile_save "1" "native" "4608" "1024" "256" "1" "256" "12.3" \
        "" "" "" "" "" "" "" "Q4_K_M/q8_0/q8_0" "24" \
        "" "" "" "" "" "" "legal"
    local row
    row=$(grep "^1|" "$LLM_REGISTRY")
    # DERIVED: the row must agree with the header the same writer emitted, not with a
    # number that goes stale the next time the schema grows.  The col-33 check below
    # pins the content.
    [[ "$(echo "$row" | awk -F'|' '{print NF}')" == "$(awk -F'|' 'NR==1{print NF}' "$LLM_REGISTRY")" ]]
    [[ "$(echo "$row" | cut -d'|' -f33)" == "legal" ]]
    local header
    header=$(head -1 "$LLM_REGISTRY")
    # The header is the schema: pin its TAIL BY NAME, not its field count.
    [[ "$header" == *"|bench_avg_prompt_tokens|repeat_penalty|repeat_last_n|meas_load|meas_n|meas_spread_pct|meas_drift_pct|meas_state" ]]
}

@test "autotune-001: autotune-model.sh accepts --workload and env default chat" {
    local src
    src=$(< "$REPO_ROOT/scripts/autotune-model.sh")
    [[ "$src" == *"--workload"* ]]
    [[ "$src" == *"LLM_AUTOTUNE_WORKLOAD"* ]]
    [[ "$src" == *"WORKLOAD=\"\${LLM_AUTOTUNE_WORKLOAD:-chat}\""* ]]
    # Scoring payload + fill payload are workload-driven (prompt sets shared).
    [[ "$src" == *"__workload_payload_json"* ]]
    [[ "$src" == *"PROMPTS_LEGAL[0]"* ]]
    [[ "$src" == *"PROMPTS_AGENTIC[0]"* ]]
    # Workload is recorded in the registry row on save.
    [[ "$src" == *'"$WORKLOAD"'* ]]
    [[ "$src" == *"workload=%s"* ]]
}

@test "autotune-003: profile-save records ttft_ms (col 34, v6 schema)" {
    cat > "$LLM_REGISTRY" <<'EOF'
#|name|file|size_gb|quant_cache|arch|gpu_layers|ctx|threads|batch|ubatch|parallel|fit_target_mb|backend|mmap_mode|flash_attn|tps|autotuned|is_default|in_vram
1|Model One|model-one.gguf|1.0G|Q4_K_M/q8_0|qwen2|24|4096|6|1024|256|1|1024|llama_server|auto|on|0|no|no|no
EOF
    __llm_autotune_profile_save "1" "native" "4608" "1024" "256" "1" "256" "12.3" \
        "" "" "" "" "" "" "" "Q4_K_M/q8_0/q8_0" "24" \
        "" "" "" "" "" "" "legal" "145.5"
    local row
    row=$(grep "^1|" "$LLM_REGISTRY")
    [[ "$(echo "$row" | cut -d'|' -f34)" == "145.5" ]]
    # DERIVED, as above: agreement with the header, not a frozen width.
    [[ "$(echo "$row" | awk -F'|' '{print NF}')" == "$(awk -F'|' 'NR==1{print NF}' "$LLM_REGISTRY")" ]]
}

@test "autotune-003: autotune-model.sh measures TTFT via a streaming probe" {
    local src
    src=$(< "$REPO_ROOT/scripts/autotune-model.sh")
    [[ "$src" == *"ttft_probe"* ]]
    [[ "$src" == *'"stream": True'* ]]
    [[ "$src" == *"time_starttransfer"* ]] || [[ "$src" == *"delta.get(\"content\")"* ]]
    [[ "$src" == *"TTFT_MS"* ]]
    [[ "$src" == *"ttft_ms=%s"* ]]
}

@test "autotune-004: profile-save records the parallel envelope (field 12)" {
    cat > "$LLM_REGISTRY" <<'EOF'
#|name|file|size_gb|quant_cache|arch|gpu_layers|ctx|threads|batch|ubatch|parallel|fit_target_mb|backend|mmap_mode|flash_attn|tps|autotuned|is_default|in_vram
1|Model One|model-one.gguf|1.0G|Q4_K_M/q8_0|qwen2|24|4096|6|1024|256|1|1024|llama_server|auto|on|0|no|no|no
EOF
    __llm_autotune_profile_save "1" "native" "4608" "1024" "256" "2" "256" "12.3" \
        "" "" "" "" "" "" "" "Q4_K_M/q8_0/q8_0" "24" \
        "" "" "" "" "" "" "legal"
    local row
    row=$(grep "^1|" "$LLM_REGISTRY")
    # parallel column (field 12 incl. model number) = the measured envelope.
    [[ "$(echo "$row" | cut -d'|' -f12)" == "2" ]]
}

@test "autotune-004: --parallel is pinned to 1 and the window invariant is asserted" {
    # Retired 2026-09-14.  The old sweep recorded the largest N that "served",
    # but kv_unified defaults to false, so --parallel N DIVIDES the served
    # window by N — which is why it recorded the MAXIMUM (16) in 34 of 35 rows:
    # under the premise it assumed, 16 x ~1.2 GB of KV cannot fit a 4 GB card,
    # so its own result falsified its premise.
    local src
    src=$(< "$REPO_ROOT/scripts/autotune-model.sh")
    [[ "$src" == *"WIN_PARALLEL=1"* ]]
    [[ "$src" != *"for _pp in 2 4 8 16"* ]]

    local e11
    e11=$(< "$REPO_ROOT/scripts/11e-llm-model.sh")
    [[ "$e11" == *"AUTOTUNE-004"* ]]
    [[ "$e11" == *"parallel_slots=1"* ]]
    [[ "$e11" != *"row_parallel_envelope"* ]]
    # ...and the invariant that actually protects the window:
    # advertised ctx == n_ctx_slot from /props.
    [[ "$e11" == *"/props"* ]]
    [[ "$e11" == *".default_generation_settings.n_ctx"* ]]
    [[ "$e11" == *"window mismatch"* ]]
}

@test "autotune-samples: certified numbers are medians of >=3 samples, never one" {
    # 2026-09-14: the same binary, prompt and n_predict spans ~45-67 tps on this
    # box (+/-15%), so a single sample is not evidence.  bench_once_multi spawns
    # ONE server and issues N requests against it, so extra samples cost no
    # extra CUDA contexts - the spawn-churn reasoning that justified samples=1
    # for profile 2 did not apply.  Pin the floors: lowering either is a
    # deliberate edit, not a tidy-up.
    local src
    src=$(< "$REPO_ROOT/scripts/autotune-model.sh")
    # winner certification: 5 samples, filled cache
    [[ "$src" == *'"$BEST_U" 5 "$EFFECTIVE_MMAP"'* ]]
    # profile 2: 3 samples, filled cache
    [[ "$src" == *'"$P2_U" 3 "$EFFECTIVE_MMAP"'* ]]
    # and the two PERSISTED numbers must not come from a single sample.
    # Deliberately scoped: Phase 4's descent probes (autotune-model.sh:1556,
    # :1573) and the spec-decode block sweep (:1733) still run one sample each
    # because they SELECT a candidate and do not persist a number — raising
    # those multiplies the descend loop and is a separate decision.
    if echo "$src" | grep -E '^[[:space:]]*_(cert|p2t)=\$\(' | grep -q '" 1 '; then
        echo "FAIL: a persisted TPS is certified from a single sample"
        return 1
    fi
}

@test "autotune: a missing profile-save helper fails loudly, never as a no-op" {
    # Regression (2026-09-13): the completion block ran the save only inside
    # `elif declare -f __llm_autotune_profile_save` with NO else.  When the
    # console's llm-manager sub-modules failed to load, neither branch ran and
    # the unchanged `saved:` line was still printed from the registry — a whole
    # sweep "completed" while certifying nothing.  The else must exist and must
    # exit non-zero so the caller marks the row failed.
    local src
    src=$(< "$REPO_ROOT/scripts/autotune-model.sh")
    [[ "$src" == *"the winner was NOT saved"* ]]

    run grep -A2 'the winner was NOT saved' "$REPO_ROOT/scripts/autotune-model.sh"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"exit 1"* ]]
}

@test "autotune: refuses to run against a degraded console (load sentinel)" {
    # Regression (2026-09-13): a console whose sub-modules failed to load still
    # reached the certification phase.  The guard is three-part and all three
    # must stay wired together: the loader counts the failures, env.sh exports a
    # sentinel, and autotune refuses before touching the GPU.  (autotune's own
    # `source env.sh 2>/dev/null` discards the human-readable report, so the
    # sentinel is the only signal that survives.)
    local loader envsrc auto
    loader=$(< "$REPO_ROOT/scripts/_startup-env.sh")
    envsrc=$(< "$REPO_ROOT/env.sh")
    auto=$(< "$REPO_ROOT/scripts/autotune-model.sh")
    [[ "$loader" == *"__TAC_SUBMODULE_FAILURES"* ]]
    [[ "$envsrc" == *"TAC_LOAD_DEGRADED"* ]]
    [[ "$auto" == *"TAC_LOAD_DEGRADED"* ]]
    [[ "$auto" == *"refusing to autotune"* ]]
}

# ── AUTOTUNE decision-logic regression harness ───────────────────────────────
# AUTOTUNE_SELFTEST replaces bench_ctx/ttft_probe/cleanup_gpu with canned curves
# and skips persistence, so the probe -> descent -> certification path runs
# server-free in seconds.  Isolation notes:
#   * 01-constants assigns LLM_REGISTRY="$HOME/.llm/models.conf" and
#     LLAMA_MODEL_DIR="$LLAMA_DRIVE_ROOT/active" UNCONDITIONALLY, so exporting
#     those directly is ignored — HOME and LLAMA_DRIVE_ROOT are the levers.
#   * the documented LLM_AUTOTUNE_BASELINE_GAP_MAX knob tolerates the CUDA lane
#     holding the card, which would otherwise refuse the run before any logic.
_selftest_run() {
    local sandbox="$1"; shift
    mkdir -p "$sandbox/home/.llm" "$sandbox/drive/active"
    # _SELFTEST_FIXTURE=<case> plants a REAL metadata fixture (make-gguf-fixture.py) instead
    # of the unparseable stub.  The capacity ctx comes from the GGUF's <arch>.context_length,
    # so a test that needs a ceiling ABOVE MIN_CTX must use one: 'plain-ctx' declares
    # qwen2/32768 with 28 blocks, which the ctx bounds clamp to 32768.
    local _fixture=""
    local _a
    for _a in "$@"; do
        [[ "$_a" == _SELFTEST_FIXTURE=* ]] && _fixture="${_a#*=}"
    done
    if [[ -n "$_fixture" ]]; then
        "$TAC_PYTHON" "$REPO_ROOT/tests/helpers/make-gguf-fixture.py" \
            "$_fixture" "$sandbox/drive/active/stub.gguf" >/dev/null
    else
        printf 'not-a-real-gguf' > "$sandbox/drive/active/stub.gguf"
    fi
    {
        printf '%s\n' '#|name|file|size_gb|quant_cache|arch|gpu_layers|ctx|threads|batch|ubatch|parallel|fit_target_mb|backend|mmap_mode|flash_attn|tps|autotuned|is_default|in_vram'
        printf '%s\n' '1|Stub Model|stub.gguf|0.1G|Q4_K_M/q8_0|llama|0|4096|4|1024|256|1|256|native|auto|on|0|no|no|no'
    } > "$sandbox/home/.llm/models.conf"
    # LLM_AUTOTUNE_VRAM_CAP_MULT is pinned so the probe ceiling is the fixture's
    # DECLARED ctx and not host-dependent.  The real ceiling is min(native, start x mult),
    # and `start` comes from live free-VRAM heuristics; on a box with less free VRAM the
    # cap lands BELOW the fixture's window (observed: 12,288 vs the 32,768 this file's
    # _SELFTEST_CERT_GAP_* case is written against), so the canned curve never fires and
    # the case silently asserts nothing.  Lifting the multiplier off the native window
    # makes the ceiling the model's own context_length on every host.
    # HEAVY_JOB_LOCK is sandboxed to this case: autotune-model.sh re-execs through
    # bin/heavy-job, which takes an exclusive flock on ${HEAVY_JOB_LOCK:-/tmp/heavy-job.lock}.
    # With the default lock a unit test blocks indefinitely while ANY other heavy job on the
    # box (another repo's pytest, an autotune batch) holds it — measured 2026-10-02, a
    # 45+ min investigator pytest held it and this filtered case hung with no output. A
    # test-private lock makes the suite independent of the shared box-wide lock while still
    # exercising the real heavy-job serialisation path (card 34c28be3).
    env -u VIRTUAL_ENV HOME="$sandbox/home" LLAMA_DRIVE_ROOT="$sandbox/drive" \
        HEAVY_JOB_LOCK="$sandbox/heavy-job.lock" \
        CUDA_CYCLE_FILE="$sandbox/cycles" CUDA_STALL_FILE="$sandbox/stalls" \
        LLM_AUTOTUNE_BASELINE_GAP_MAX=999999 AUTOTUNE_SELFTEST=1 \
        LLM_AUTOTUNE_VRAM_CAP_MULT=4194304 "$@" \
        bash "$REPO_ROOT/scripts/autotune-model.sh" 1 --workload chat 2>&1
}

@test "autotune-selftest: a below-floor model descends and records best-effort" {
    # TPS-first policy (2026-08-29): below the floor at capacity -> descend to
    # MIN_CTX, then record the best-effort config.  This is the case the stale
    # 2026-08-27 note insisted had to certify capacity instead.
    run _selftest_run "$BATS_TEST_TMPDIR/below"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"recording best-effort config"* ]]
    [[ "$output" == *"8.5 tps"* ]]
}

@test "autotune-selftest: a capacity that meets the floor is certified at capacity" {
    run _selftest_run "$BATS_TEST_TMPDIR/floor" _SELFTEST_FLOOR_ABOVE=32768
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"12.0 tps"* ]]
    [[ "$output" != *"recording best-effort config"* ]]
}

@test "autotune-selftest: a certification below the floor descends at the certification's sample count" {
    # The 2026-09-17 defect: Phase 4's floor gate judges each rung from ONE sample, so a
    # config can PASS it and then certify far below the floor with the 5-sample median —
    # and pre-fix the run recorded that ctx anyway (rows 13/14 advertised 131,072 at ~3 tps
    # while their own Phase-4 rungs read ~14, reproduced across a cold boot, with the ttft
    # probe agreeing with the certification).  Here the capacity ctx is 32768: one sample
    # reads 12.0 (gate passes) and five read 3.0 (= 12 / FACTOR 4, gate would fail), so the
    # run must descend and adopt a smaller window that holds the floor under the SAME
    # measurement — and must NOT be written off as too slow.
    run _selftest_run "$BATS_TEST_TMPDIR/certgap" \
        _SELFTEST_FIXTURE=plain-ctx \
        _SELFTEST_FLOOR_ABOVE=32768 \
        _SELFTEST_CERT_GAP_ABOVE=32768 \
        _SELFTEST_CERT_GAP_FACTOR=4
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"descending at the certification's sample count"* ]]
    [[ "$output" == *"floor met at ctx"* ]]
    [[ "$output" != *"recording best-effort config"* ]]
}

@test "autotune-selftest: a ceiling above the probed capacity forces the filled-load descent" {
    run _selftest_run "$BATS_TEST_TMPDIR/oom" _SELFTEST_OOM_ABOVE=8192
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"descending to the highest ctx that sustains"* ]]
    [[ "$output" == *"recording best-effort config"* ]]
}

@test "autotune-selftest: a model that cannot load at any ctx exits non-zero" {
    run _selftest_run "$BATS_TEST_TMPDIR/unloadable" _SELFTEST_OOM_ABOVE=2048
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"cannot be loaded"* || "$output" == *"unsupported"* ]]
}

# ── WSL2 dxgkrnl leak ledger (2026-09-14) ────────────────────────────────────
# Every bench spawns a llama-server, which is one CUDA context create/destroy;
# dxgkrnl leaks GPU VA per cycle until the VM hangs.  The ledger is a FILE, so
# the guard is testable without a GPU — which is the point: the bug was that the
# counter was written and never read.

@test "autotune-dxg: an exhausted cycle ledger refuses before any spawn" {
    local sb="$BATS_TEST_TMPDIR/exhausted"
    mkdir -p "$sb"
    printf '60\n' > "$sb/cycles"
    : > "$sb/stalls"
    run _selftest_run "$sb" CUDA_CYCLE_FILE="$sb/cycles" CUDA_STALL_FILE="$sb/stalls"
    [[ "$status" -eq 3 ]]
    [[ "$output" == *"CUDA context-cycle budget reached"* ]]
    [[ "$output" == *"wsl --shutdown"* ]]
}

@test "autotune-dxg: consecutive launch stalls halt as the degradation signature" {
    local sb="$BATS_TEST_TMPDIR/stalled"
    mkdir -p "$sb"
    printf '12\n' > "$sb/cycles"
    printf '2\n' > "$sb/stalls"
    run _selftest_run "$sb" CUDA_CYCLE_FILE="$sb/cycles" CUDA_STALL_FILE="$sb/stalls"
    [[ "$status" -eq 3 ]]
    [[ "$output" == *"consecutive launches stalled"* ]]
}

@test "autotune-dxg: a clean ledger still certifies (the guard is not a blanket halt)" {
    local sb="$BATS_TEST_TMPDIR/clean"
    mkdir -p "$sb"
    printf '3\n' > "$sb/cycles"
    : > "$sb/stalls"
    run _selftest_run "$sb" CUDA_CYCLE_FILE="$sb/cycles" CUDA_STALL_FILE="$sb/stalls"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"winner:"* ]]
}

@test "autotune-dxg: AUTOTUNE_SPEC_SWEEP=0 skips the 4-launch sweep without losing the cert" {
    run _selftest_run "$BATS_TEST_TMPDIR/nospec" AUTOTUNE_SPEC_SWEEP=0
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"skipping the sweep to conserve CUDA cycles"* ]]
    [[ "$output" == *"winner:"* ]]
}

# The (p2_ctx, p2_tps) pair written to the registry must describe ONE real
# measurement. Applying the ctx clamp after the certification rewrote P2_CTX
# while leaving P2_TPS measured at the un-clamped ctx, so a row could carry a
# p2_tps several times below a tps taken at the very same config (7.7x,
# 2026-09-15) and no consumer could tell that from a genuine regression.
# Clamp first, then certify — this pins the order.
@test "autotune-p2: the ctx clamp runs BEFORE the profile-2 certification" {
    local clamp_line cert_line
    clamp_line=$(grep -nF 'P2_CTX=$BEST_CTX' "$REPO_ROOT/scripts/autotune-model.sh" | head -1 | cut -d: -f1)
    cert_line=$(grep -nF '_p2t=$(bench_ctx' "$REPO_ROOT/scripts/autotune-model.sh" | head -1 | cut -d: -f1)
    # Both constructs must exist, or this test is silently asserting nothing.
    [[ -n "$clamp_line" ]]
    [[ -n "$cert_line" ]]
    (( clamp_line < cert_line ))
}

# ── SAMPLER-ARGS: the audit path that did not exist on 2026-09-29 ───────────
# _sampler_args is the only way to answer "what decode policy did this row run
# under?" — the question that could not be answered when row 26's certification was
# audited.  It used to read a CALLER-scope MODEL_PATH, so a direct call printed
# NOTHING and looked like dead wiring; three probes concluded wrongly.  The model is
# an argument now, and the run records its own policy.

@test "sampler-args: the model is an argument, and a bare call refuses loudly" {
    # Catches: the hidden-global shape answering "no flags" for a model that HAS them —
    # a false negative that reads as "the autotune does not apply the sampler".
    local src
    src=$(< "$REPO_ROOT/scripts/autotune-model.sh")
    [[ "$src" != *'local _f="${MODEL_PATH##*/}"'* ]] || {
        echo "the model must not come from a caller-scope MODEL_PATH"
        return 1
    }
    [[ "$src" == *'local _f="${1##*/}"'* ]]
    # ...and both spawn sites pass it explicitly, so neither can silently emit nothing.
    local _sites
    _sites=$(grep -c 'mapfile -t sampler_args < <(_sampler_args "$MODEL_PATH")' \
        "$REPO_ROOT/scripts/autotune-model.sh")
    [[ "$_sites" -eq 2 ]]

    eval "$(sed -n '/^_sampler_args()/,/^}/p' "$REPO_ROOT/scripts/autotune-model.sh")"
    # The refusal goes through the UI helper (ratchet 10.7 forbids a hand-written >&2),
    # so the helper has to be loaded here — the shipped script sources it.
    source "$REPO_ROOT/scripts/05-ui-engine.sh"
    run _sampler_args
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"needs the model path"* ]]
}

@test "sampler-args: flags come from the registry columns, and a blank column emits nothing" {
    # Catches: the spawn flags drifting from the registry column (the drift the function
    # exists to prevent), and a blank column emitting a flag with NO value — which would
    # hand llama-server a bare `--repeat-penalty`.
    eval "$(sed -n '/^_sampler_args()/,/^}/p' "$REPO_ROOT/scripts/autotune-model.sh")"

    cat > "$LLM_REGISTRY" <<'EOF'
#|name|file|repeat_penalty|repeat_last_n
1|Spark|spark.gguf|1.1|256
2|Plain|plain.gguf||
EOF

    run _sampler_args spark.gguf
    [[ "$status" -eq 0 ]]
    # One argv word per line (the __spec_launch_flags idiom), so the flag and its value
    # are separate lines — asserting "--repeat-penalty 1.1" would never match.
    [[ "$output" == *"--repeat-penalty"* ]]
    [[ "$output" == *"1.1"* ]]
    [[ "$output" == *"--repeat-last-n"* ]]
    [[ "$output" == *"256"* ]]

    run _sampler_args plain.gguf
    [[ "$status" -eq 0 ]]
    [[ -z "$output" ]]
}

@test "cuda-suspend: live owner refuses, stale is taken over, release is owner-checked" {
    # Card 7d3e7b95: /dev/shm/llama-watchdog-cuda.suspend used to be touch/rm with
    # NO ownership, so a run could release another run's hold (lane back up
    # mid-sweep) and an abort left the hold behind (lane down until someone
    # noticed).  bin/_tac-bin-lib.sh now records the setter's pid; this exercises
    # all three branches against a temp path (never the real /dev/shm file).
    source "$REPO_ROOT/bin/_tac-bin-lib.sh"
    local f; f="$TMPDIR_BATS/thread.suspend"

    # (1) fresh: this shell owns it, and release removes it.
    _tac_suspend_acquire "$f"
    [[ "$(_tac_suspend_pid "$f")" == "$$" ]]
    _tac_suspend_release "$f"
    [[ ! -e "$f" ]]

    # (2) a LIVE owner: acquire refuses, and a non-owner release leaves it.
    sleep 30 &
    local _live=$!
    printf '%s\n' "$_live" > "$f"
    local rc=0; _tac_suspend_acquire "$f" || rc=$?
    [[ "$rc" -eq 1 ]]
    [[ -e "$f" ]]
    rc=0; _tac_suspend_release "$f" || rc=$?
    [[ "$rc" -eq 1 ]]
    [[ -e "$f" ]]

    # (3) STALE owner (killed and reaped): taken over by this shell, then released.
    kill "$_live" 2>/dev/null || true
    wait "$_live" 2>/dev/null || true
    _tac_suspend_acquire "$f"
    [[ "$(_tac_suspend_pid "$f")" == "$$" ]]
    _tac_suspend_release "$f"
    [[ ! -e "$f" ]]
}

# ── _tac_suspend_held: the ONE rule readers and acquirers share (v5) ──────────
#
# The defect these pin (measured 2026-10-11): the marker's holder was recorded in a
# companion file, and every reader tested only that the MARKER EXISTED — so a holder
# killed with SIGKILL, whose `trap … EXIT` never ran, kept the CUDA lane down.  The
# marker now carries the pid and liveness decides.  Each case below is a shape that
# must NOT be read as held, except the live-owner one.

@test "suspend held: a MISSING marker is NOT held" {
    # Catches: treating "no marker" as held (which would wedge the lane down with
    # nothing on disk to explain it).
    source "$REPO_ROOT/bin/_tac-bin-lib.sh"
    local f="$TMPDIR_BATS/held-missing.suspend"
    rm -f "$f"
    ! _tac_suspend_held "$f"
}

@test "suspend held: an EMPTY marker is NOT held (the legacy shape)" {
    # Catches: the LIVE defect — the file on disk today is 0 bytes, and the old
    # existence test read it as held.  An empty marker must let the lane come back.
    source "$REPO_ROOT/bin/_tac-bin-lib.sh"
    local f="$TMPDIR_BATS/held-empty.suspend"
    : > "$f"
    ! _tac_suspend_held "$f"
}

@test "suspend held: a DEAD owner pid is NOT held" {
    # Catches: the SIGKILL asymmetry — a holder that never ran its EXIT trap.  Its
    # pid is recorded but gone, so the hold must be treated as released.
    source "$REPO_ROOT/bin/_tac-bin-lib.sh"
    local f="$TMPDIR_BATS/held-dead.suspend"
    local dead
    sleep 30 & dead=$!
    kill "$dead" 2>/dev/null || true
    wait "$dead" 2>/dev/null || true
    printf '%s\n' "$dead" > "$f"
    ! _tac_suspend_held "$f"
}

@test "suspend held: a LIVE owner pid IS held" {
    # The control: without it, a predicate that always answered "not held" would
    # pass every case above — and would let the watchdog restart a lane a bench is
    # holding down.
    source "$REPO_ROOT/bin/_tac-bin-lib.sh"
    local f="$TMPDIR_BATS/held-live.suspend"
    printf '%s\n' "$$" > "$f"
    _tac_suspend_held "$f"
    # ...and it stops being held once that owner is gone (the transition, in place).
    printf '%s\n' "999999" > "$f"
    ! _tac_suspend_held "$f"
}

# ── the SHARED GPU-availability gate (bin/_tac-bin-lib.sh v6) ────────────────
#
# The same GPU gate was hand-rolled inline THREE times in one day and each copy was
# wrong differently (a fall-through on exhaustion; an unsatisfiable "<1500 MiB BEFORE
# suspending our own lane" precondition that polled 5.6 h; a multi-line reading that
# never matched on a multi-GPU box).  These cases drive the ONE reviewed mechanism.
# Each states the wrong outcome it catches; the A/B for cases (a) and (c) runs the
# hand-rolled predecessors against the same assertions.

# _gpu_stubs <busy-rc> [used-mib...] — sandbox BOTH inputs: a stub bin/gpu-busy.sh
# whose EXIT CODE is the foreign-holder contract, and a stub nvidia-smi whose readings
# come from a queue (one per call, the last repeating), so "a foreign holder is here,
# then our lane is suspended" is expressible in one case.
_gpu_stubs() {
    local busy_rc="$1"; shift
    local busy_bool="true"
    (( busy_rc == 0 )) && busy_bool="false"
    GPUBIN="$TMPDIR_BATS/gpubin"
    mkdir -p "$GPUBIN"
    cat > "$GPUBIN/gpu-busy.sh" <<STUB
#!/usr/bin/env bash
printf '{"busy":${busy_bool},"reasons":["stub"]}\n'
exit ${busy_rc}
STUB
    chmod +x "$GPUBIN/gpu-busy.sh"
    local v seq=""
    for v in "$@"; do seq+="$v"$'\n'; done
    export GPU_SEQ_FILE="$TMPDIR_BATS/gpu-seq"
    printf '%s' "$seq" > "$GPU_SEQ_FILE"
    cat > "$GPUBIN/nvidia-smi" <<'STUB'
#!/usr/bin/env bash
# While OUR OWN lane is up (the suspend marker is absent) the card reads the held
# value; the queue is consulted only once the lane has been suspended.  That is what
# makes the deadlock expressible: a gate that demands a free card BEFORE suspending
# can never see the drop.  Unset GPU_SUSPEND_MARKER = always read the queue.
if [[ -n "${GPU_SUSPEND_MARKER:-}" && ! -e "$GPU_SUSPEND_MARKER" ]]; then
    printf '%s\n' "${GPU_HELD_MIB:-3376}"
    exit 0
fi
# One reading per call from the queue; the LAST value repeats once it is exhausted.
_n=$(wc -l < "$GPU_SEQ_FILE")
if (( _n > 1 )); then
    head -1 "$GPU_SEQ_FILE"
    sed -i '1d' "$GPU_SEQ_FILE"
else
    cat "$GPU_SEQ_FILE"
fi
STUB
    chmod +x "$GPUBIN/nvidia-smi"
    export TAC_GPU_BUSY_SH="$GPUBIN/gpu-busy.sh"
    export PATH="$GPUBIN:$PATH"
}

@test "gpu gate: our OWN lane holding the card is NOT a foreign holder (the 5.6h deadlock)" {
    # Catches the UNSATISFIABLE precondition: gpu-busy.sh excludes our own fleet's
    # servers, so a card pinned at our lane's ~3376 MiB must read FREE — the foreign
    # test must PASS and the run must proceed to the suspend, where 3376 -> 120 is
    # satisfiable.  The hand-rolled predecessor waited for <1500 MiB BEFORE suspending
    # and polled 5.6 h having launched nothing.
    #
    # The fixture models the ORDER: the card reads 3376 while our lane is up and 120
    # only once the suspend marker is held, so a threshold-before-suspend gate can
    # never see the drop.
    source "$REPO_ROOT/bin/_tac-bin-lib.sh"
    _gpu_stubs 0 120
    export GPU_SUSPEND_MARKER="$TMPDIR_BATS/lane.suspend"
    rm -f "$GPU_SUSPEND_MARKER"
    run _tac_gpu_wait_foreign_clear 10 0
    [[ "$status" -eq 0 ]] || { echo "a card held only by OUR lane was treated as foreign"; return 1; }
    _tac_suspend_acquire "$GPU_SUSPEND_MARKER" || { echo "the suspend could not be taken"; return 1; }
    run _tac_gpu_wait_used_below 800 10 1
    [[ "$status" -eq 0 ]] || { echo "the card never freed after our own lane was suspended"; return 1; }
    _tac_suspend_release "$GPU_SUSPEND_MARKER"
}

@test "gpu gate: a FOREIGN holder makes it WAIT, and our lane's VRAM does not satisfy it" {
    # Catches: reading "something is using 3376 MiB" as permission to launch.  With a
    # foreign holder the wait must TIME OUT (non-zero) even though the VRAM reading on
    # its own would have looked like a busy-but-usable card.
    source "$REPO_ROOT/bin/_tac-bin-lib.sh"
    _gpu_stubs 1 3376 120
    run _tac_gpu_wait_foreign_clear 0 0
    [[ "$status" -ne 0 ]] || { echo "a FOREIGN holder was accepted as free"; return 1; }
}

@test "gpu gate: exhaustion ABORTS non-zero and never falls through" {
    # Catches the fall-through that launched a run onto an occupied card: a card that
    # never frees must return NON-ZERO, so the caller launches nothing.
    source "$REPO_ROOT/bin/_tac-bin-lib.sh"
    _gpu_stubs 0 3376 3376 3376
    run _tac_gpu_wait_used_below 800 0 0
    [[ "$status" -ne 0 ]] || { echo "an exhausted wait returned success (fall-through)"; return 1; }
}

@test "gpu gate: an unreadable nvidia-smi FAILS CLOSED" {
    # Catches: "cannot tell" reading as "free".  An empty reading must never satisfy
    # the used-below test, because the caller has already suspended our lane.
    source "$REPO_ROOT/bin/_tac-bin-lib.sh"
    _gpu_stubs 0 ""
    run _tac_gpu_wait_used_below 800 10 1
    [[ "$status" -ne 0 ]] || { echo "an unreadable card was accepted as free"; return 1; }
}

@test "gpu gate: a MULTI-GPU multi-line reading still OPENS (the v4 property)" {
    # Catches the regression that closed the gate forever on a multi-GPU box: the query
    # prints ONE LINE PER CARD, so a bare numeric test never matches.  Two lines under
    # the bound must yield the MOST-used card and open.
    source "$REPO_ROOT/bin/_tac-bin-lib.sh"
    mkdir -p "$TMPDIR_BATS/multigpu"
    cat > "$TMPDIR_BATS/multigpu/nvidia-smi" <<'STUB'
#!/usr/bin/env bash
printf '100\n50\n'
STUB
    chmod +x "$TMPDIR_BATS/multigpu/nvidia-smi"
    export PATH="$TMPDIR_BATS/multigpu:$PATH"
    run _tac_gpu_used_mib
    [[ "$output" == "100" ]] || { echo "the most-used card was not taken (got '$output')"; return 1; }
    run _tac_gpu_wait_used_below 800 10 1
    [[ "$status" -eq 0 ]] || { echo "a multi-GPU reading never opened the gate"; return 1; }
}

@test "verify-write: a save whose awk matches NO row is REFUSED, not reported as success" {
    # Item 5 (2026-10-12).  A row whose file name carries a BACKSLASH is not matched by the
    # save's `awk -v f=...` (awk expands the escape in a -v assignment), so the rewrite
    # emits the row unchanged and the mv still succeeds.  BEFORE the write-verification
    # this returned 0 — a save that persisted NOTHING and read as success.  It must now
    # fail closed.  The mangling premise, proved once here so the case cannot pass
    # vacuously: printf 'a\b\n' | awk -F'|' -v f='a\b' '{print ($1==f)?"M":"N"}' -> N.
    printf '%s\n' "$LLM_REGISTRY_HEADER" \
        '1|Weird|weird\name.gguf|1.0G|Q4_K_M/q8_0|qwen2|24|4096|6|1024|256|1|1024|llama_server|auto|on|0|no|no|no' \
        > "$LLM_REGISTRY"
    run __llm_autotune_profile_save "1" "native" "4608" "1024" "256" "1" "256" "12.3"
    [[ "$status" -ne 0 ]] || { echo "a save that wrote NOTHING was reported as success"; return 1; }
    # Control: prove the write really did no-op (the case is not green by accident).
    [[ "$(grep '^1|' "$LLM_REGISTRY" | cut -d'|' -f17)" != "12.3" ]] \
        || { echo "premise failed: the write DID land, so this case tested nothing"; return 1; }
}

# ── 3c: the quiet-box write gate (2026-10-13) ────────────────────────────────
# The certification stores a bare tps that reads as certified.  A tps measured on a
# CONTENDED box is indicative, not certified, so 3c makes the run REFUSE to persist
# one by default and permits it only under an explicit --allow-contended, stamped
# meas_state=indicative.  The verdict is a pure function (extracted here, like
# _sampler_args) so the policy matrix is testable without a GPU.

@test "3c: a CONTENDED box refuses to write; --allow-contended stamps indicative" {
    # Catches: the pre-3c behaviour, where a contended box wrote the row anyway and the
    # number read as certified; and a gate that ignores the flag, or refuses a quiet box.
    eval "$(sed -n '/^__autotune_measurement_verdict()/,/^}/p' "$REPO_ROOT/scripts/autotune-model.sh")"
    # Both constructs must exist or this case asserts nothing.
    declare -f __autotune_measurement_verdict >/dev/null

    run __autotune_measurement_verdict "1.77" "16" "0"
    [[ "$output" == "certified" ]] || { echo "a QUIET box (load 1.77/16) must certify (got '$output')"; return 1; }

    run __autotune_measurement_verdict "20.0" "16" "0"
    [[ "$output" == "refuse" ]] || { echo "a CONTENDED box (load 20/16) must REFUSE without the flag (got '$output')"; return 1; }

    run __autotune_measurement_verdict "20.0" "16" "1"
    [[ "$output" == "indicative" ]] || { echo "--allow-contended must record INDICATIVE (got '$output')"; return 1; }

    # An UNREADABLE load is not proven quiet: it fails closed, like the GPU gate.
    run __autotune_measurement_verdict "?" "16" "0"
    [[ "$output" == "refuse" ]] || { echo "an unreadable load must fail closed (got '$output')"; return 1; }

    # ...and --allow-contended still permits the unreadable case, stamped indicative.
    run __autotune_measurement_verdict "?" "16" "1"
    [[ "$output" == "indicative" ]] || { echo "an unreadable load + --allow-contended must be indicative (got '$output')"; return 1; }
}

@test "3c: the certification parses --allow-contended and refuses BEFORE the save" {
    # Catches the helper-only blind spot: the verdict function existing while the CALL
    # SITE ignores it.  The gate must sit between the load/cores read and the profile
    # save, and the flag must be parsed — a green unit test on the helper proves neither.
    local src
    src=$(< "$REPO_ROOT/scripts/autotune-model.sh")
    [[ "$src" == *'--allow-contended) ALLOW_CONTENDED=1'* ]]
    [[ "$src" == *'__autotune_measurement_verdict "$_row_load" "$_row_cores" "${ALLOW_CONTENDED:-0}"'* ]]

    local refuse_line save_line
    refuse_line=$(grep -nF 'REFUSING to write' "$REPO_ROOT/scripts/autotune-model.sh" | head -1 | cut -d: -f1)
    save_line=$(grep -nF '__llm_autotune_profile_save "$MODEL_FILE"' "$REPO_ROOT/scripts/autotune-model.sh" | head -1 | cut -d: -f1)
    # Both must exist, or this ordering assert is vacuous.
    [[ -n "$refuse_line" ]]
    [[ -n "$save_line" ]]
    (( refuse_line < save_line )) || { echo "the refusal must precede the save (refuse=$refuse_line save=$save_line)"; return 1; }
}

# ── 1a: the position term (2026-10-13) ───────────────────────────────────────
# The winner is a median of 5 samples taken at ONE point in the run, and this box
# drifts with POSITION (45-65% cold-decode drift across the cache-ram probe's own
# positions against ~13% run-to-run spread).  1a re-measures the SAME config at a
# second position and records the drift, stamped indicative above the probe's own
# 25% DRIFT_WARN_PCT bound.

@test "1a: the position-drift formula is the probe's own (max-min)/max" {
    # Catches: a drift DEFINED differently from the probe's, so a figure here and a
    # figure there would not mean the same thing.  The probe computes (max-min)/max*100
    # (scripts/cache-ram-probe.sh:512) against its 25% bound.
    eval "$(sed -n '/^__autotune_position_drift()/,/^}/p' "$REPO_ROOT/scripts/autotune-model.sh")"
    declare -f __autotune_position_drift >/dev/null

    run __autotune_position_drift 22.66 23.77
    [[ "$output" == "4.67" ]] || { echo "22.66 vs 23.77 must drift 4.67% (got '$output')"; return 1; }
    # Order-independent: the same pair read the other way must give the same figure.
    run __autotune_position_drift 23.77 22.66
    [[ "$output" == "4.67" ]] || { echo "the drift must not depend on position ORDER (got '$output')"; return 1; }
    # (max-min)/max: 10 vs 20 over the max 20 = 50%.
    run __autotune_position_drift 10 20
    [[ "$output" == "50.00" ]] || { echo "10 vs 20 must drift 50.00% (got '$output')"; return 1; }
    # A non-positive or unreadable figure yields NO drift, never a fabricated one.
    run __autotune_position_drift 0 20
    [[ -z "$output" ]] || { echo "a zero first position must yield no drift (got '$output')"; return 1; }
    run __autotune_position_drift "" 20
    [[ -z "$output" ]] || { echo "an absent first position must yield no drift (got '$output')"; return 1; }
    run __autotune_position_drift "?" 23
    [[ -z "$output" ]] || { echo "a non-numeric figure must yield no drift (got '$output')"; return 1; }
}

@test "1a: the certification measures a SECOND position and stamps indicative above 25%" {
    # Catches the helper-only blind spot plus both halves of the policy: the verdict that
    # the write branch really RE-MEASURES the winner config (a second bench_ctx, AFTER the
    # refusal gate), that the drift reaches meas_drift_pct (save arg 29), and that exceeding
    # the bound stamps meas_state=indicative.  A test on the helper alone proves none of it.
    local src
    src=$(< "$REPO_ROOT/scripts/autotune-model.sh")
    [[ "$src" == *'AUTOTUNE_DRIFT_WARN_PCT=25'* ]]
    [[ "$src" == *'_meas_pos2=$(bench_ctx "$BEST_CTX" "$BEST_B" "$BEST_U" 5'* ]]
    [[ "$src" == *'_meas_drift_pct=$(__autotune_position_drift "${BEST_TPS:-0}" "$_meas_pos2")'* ]]
    # the figure reaches the save as meas_drift_pct — the FOURTH optional (arg 29)
    [[ "$src" == *'"$_row_load" "5" "" "$_meas_drift_pct" "$_meas_state"'* ]]
    # ...and exceeding the bound stamps the row indicative, as contention does
    [[ "$src" == *'awk -v d="$_meas_drift_pct" -v w="$AUTOTUNE_DRIFT_WARN_PCT"'* ]]
    [[ "$src" == *'_meas_state="indicative"'* ]]
    # A REFUSED row must not spend the second bench: the refusal precedes it.
    local refuse_line pos2_line
    refuse_line=$(grep -nF 'REFUSING to write' "$REPO_ROOT/scripts/autotune-model.sh" | head -1 | cut -d: -f1)
    pos2_line=$(grep -nF '_meas_pos2=$(bench_ctx' "$REPO_ROOT/scripts/autotune-model.sh" | head -1 | cut -d: -f1)
    [[ -n "$refuse_line" ]]
    [[ -n "$pos2_line" ]]
    (( refuse_line < pos2_line )) || { echo "the second bench must follow the refusal (refuse=$refuse_line pos2=$pos2_line)"; return 1; }
}
