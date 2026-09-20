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
    # v6 schema: 37 fields.
    [[ "$(echo "$row" | awk -F'|' '{print NF}')" == "37" ]]
    [[ "$(echo "$row" | cut -d'|' -f33)" == "legal" ]]
    local header
    header=$(head -1 "$LLM_REGISTRY")
    [[ "$(echo "$header" | awk -F'|' '{print NF}')" == "37" ]]
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
    [[ "$(echo "$row" | awk -F'|' '{print NF}')" == "37" ]]
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
    env -u VIRTUAL_ENV HOME="$sandbox/home" LLAMA_DRIVE_ROOT="$sandbox/drive" \
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
