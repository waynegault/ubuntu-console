#!/usr/bin/env bats
# ==============================================================================
# Unit Tests — the autotune VRAM-baseline tolerance covers the lane it spares
# ==============================================================================
# `scripts/autotune-model.sh` refuses to autotune when total-free VRAM exceeds
# LLM_AUTOTUNE_BASELINE_GAP_MAX.  The host profile sizes that tolerance for the
# DRIVER's reservation alone (~2.9 GiB on this Blackwell box, "no process attached").
#
# But the guard runs AFTER `__llm_stand_down_cuda_lanes`, which deliberately SPARES
# the lanes named in LLAMA_LANE_KEEP_UNITS — on this host the embedding lane.  So the
# tolerated gap must cover the driver PLUS that spared lane's footprint.  It did not:
#
#   measured 2026-11-02, only `llama-cuda-qwen3embedding-embed.service` holding:
#     total 81920 MiB, free 77826 MiB -> gap 4094 MiB
#   tolerance in the host profile: 3500 MiB
#   -> refused by 594 MiB, and the refusal names no remedy that can help, because the
#      holder is the lane the same script is told to keep.
#
# The existing suite could not catch this: `08-autotune-workload.bats` sets
# LLM_AUTOTUNE_BASELINE_GAP_MAX=999999 to bypass the guard, so every case in it runs
# with the guard switched OFF.  An allow arm is not a test of the bound.  This file is
# the refusal-side arm: it pins the shipped value against the measured footprint.
# ==============================================================================

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
PROFILE="$REPO_ROOT/config/hosts.d/asus-n1n-rtx-spark.conf"

# The measured gap on this box with the spared embedding lane the only holder.
# A pin, not a derivation: nvidia-smi reports used_gpu_memory as [N/A] per PID on
# WSL2 dxgkrnl, so the lane's own footprint cannot be read individually — it can
# only be observed as the whole-card delta while it is alone.
SPARED_LANE_FOOTPRINT_MIB=4094

@test "the host profile records the conflict instead of numbing the guard" {
    [ -f "$PROFILE" ]
    run bash -c "source '$PROFILE' >/dev/null 2>&1; printf '%s' \"\${LLM_AUTOTUNE_BASELINE_GAP_MAX:-}\""
    [ "$status" -eq 0 ]
    local tol="$output"
    [ -n "$tol" ]
    # NOT an assertion that the tolerance covers the lane.  Covering it would accept
    # contended measurements, which is the defect the guard exists to prevent.  This
    # pins the OPEN state so nobody quietly raises the number to make a batch pass
    # without recording why: if the value moves above the measured footprint, the
    # unresolved-trade-off note must have moved with it.
    if [ "$tol" -ge "$SPARED_LANE_FOOTPRINT_MIB" ]; then
        run grep -c "KNOWN CONFLICT, 2026-11-02" "$PROFILE"
        [ "$output" -ge 1 ]
    fi
}

@test "the tolerance is still a bound, not a bypass" {
    # A concurrent serving lane holds multiples of the spared lane, and that is what
    # the bound exists to catch.  This control must pass before and after any fix.
    run bash -c "source '$PROFILE' >/dev/null 2>&1; printf '%s' \"\${LLM_AUTOTUNE_BASELINE_GAP_MAX:-}\""
    local tol="$output"
    if [ "$tol" -gt 16384 ]; then
        printf 'LLM_AUTOTUNE_BASELINE_GAP_MAX=%s no longer distinguishes a spared lane from a full card\n' "$tol" >&2
        return 1
    fi
}

@test "the guard's own default is documented as the driver bound, not a lane bound" {
    # scripts/autotune-model.sh defaults to 800 for boxes with no CUDA lane at all.
    # The comment there used to justify it with a "~430 MiB memory-core embedding
    # worker" — a Node worker this box does not run and which the guard's pkill
    # already removes.  The real holder is a CUDA llama-server 5x the tolerance.
    #
    # The assertion is POSITIVE: name the measurement that sized the profile value.
    # An absence check (grep -c "430 MiB" == 0) would also fail on a comment that
    # QUOTES the old figure to explain why it was wrong — which is what the fix does.
    # A test that forbids a string forbids the correction that mentions it.
    #
    # It is searched across the files that can carry it, not one: the guard's rationale
    # moved from scripts/autotune-model.sh into _tac_vram_baseline_verdict
    # (bin/_tac-bin-lib.sh) when the verdict became a shared predicate, and pinning the
    # old file turned a correct relocation into a red case (measured 2026-11-14: the
    # figure is still documented, in the library and in 11d/autotune-rows).
    run grep -rl "4094 MiB" "$REPO_ROOT/scripts/autotune-model.sh" \
        "$REPO_ROOT/bin/_tac-bin-lib.sh" "$REPO_ROOT/scripts/11d-llm-gpu.sh" \
        "$REPO_ROOT/bin/autotune-rows.sh"
    [ "$status" -eq 0 ] || { echo "FAIL: no file documents the 4094 MiB driver+lane measurement"; return 1; }
    [ -n "$output" ]
}

# ── The census (owner decision 2026-11-05, card AUTOTUNE-BASELINE-002) ─────────
# The gate cannot use nvidia-smi for identity on this box: `--query-compute-apps`
# answers "No running processes found" even at 36 GiB used (measured 2026-11-05).
# Identity is therefore the process table, and every arm is driven through the
# injection seam so no case depends on what happens to be resident.
BINLIB="$REPO_ROOT/bin/_tac-bin-lib.sh"

@test "census: the LEAF unit is named, never the user manager" {
    # Catches: `grep -o ... | head -1`, which answered user@1000.service for every
    # user unit — measured in a real refusal ("pid 242004 user@1000.service").
    run bash -c 'source "$1"; _tac_cgroup_unit "0::/user.slice/user-1000.slice/user@1000.service/app.slice/llama-x.service"' _ "$BINLIB"
    [ "$status" -eq 0 ]
    [ "$output" = "llama-x.service" ]
}

@test "census: a declared tenant resident is a CONTENDED pass" {
    # Catches: a census that refuses the very lane its own profile says to keep.
    printf '4242|llama-cuda-qwen3embedding-embed.service|llama-server\n' > "$BATS_TEST_TMPDIR/holders"
    run env LLM_AUTOTUNE_VRAM_HOLDERS_FILE="$BATS_TEST_TMPDIR/holders" \
        LLM_AUTOTUNE_CENSUS=llama-cuda-qwen3embedding-embed.service \
        LLM_AUTOTUNE_CENSUS_MAX_MIB=6144 \
        bash -c 'source "$1"; _tac_vram_baseline_verdict 77826 81920' _ "$BINLIB"
    [ "$status" -eq 0 ]
    [[ "$output" == *"mode=census"* ]]
    [[ "$output" == *"verdict=pass"* ]]
    [[ "$output" == *"tenant_count=1"* ]]
}

@test "census: an UNLISTED holder refuses, and the refusal names it" {
    # Catches: a byte-only cap silently admitting a foreign server.  The name must
    # reach the operator — the first cut printed nothing because of "\$_VRAM_VERDICT".
    printf '4242|llama-other.service|llama-server\n' > "$BATS_TEST_TMPDIR/holders"
    run env LLM_AUTOTUNE_VRAM_HOLDERS_FILE="$BATS_TEST_TMPDIR/holders" \
        LLM_AUTOTUNE_CENSUS=llama-cuda-qwen3embedding-embed.service \
        LLM_AUTOTUNE_CENSUS_MAX_MIB=6144 \
        bash -c 'source "$1"; _tac_vram_baseline_verdict 77826 81920' _ "$BINLIB"
    [ "$status" -eq 1 ]
    [[ "$output" == *"reason=unlisted-holder"* ]]
    [[ "$output" == *"4242:llama-other.service:llama-server"* ]]
}

@test "census: a hold above the declared cap refuses even with no holder derived" {
    # Measures the cap as the real bound: with both lanes resident the gap was
    # 36,147 MiB, so a cap of 6144 must refuse — this is the serving-chat-lane case.
    : > "$BATS_TEST_TMPDIR/holders"
    run env LLM_AUTOTUNE_VRAM_HOLDERS_FILE="$BATS_TEST_TMPDIR/holders" \
        LLM_AUTOTUNE_CENSUS=llama-cuda-qwen3embedding-embed.service \
        LLM_AUTOTUNE_CENSUS_MAX_MIB=6144 \
        bash -c 'source "$1"; _tac_vram_baseline_verdict 37581 73728' _ "$BINLIB"
    [ "$status" -eq 1 ]
    [[ "$output" == *"reason=held-exceeds-census-cap"* ]]
}

@test "census: a census with no bound is rc 2, never a pass" {
    # Catches: LLM_AUTOTUNE_CENSUS set without a cap becoming an unbounded allow.
    run env LLM_AUTOTUNE_CENSUS=llama-cuda-qwen3embedding-embed.service \
        bash -c 'source "$1"; unset LLM_AUTOTUNE_CENSUS_MAX_MIB; _tac_vram_baseline_verdict 77826 81920' _ "$BINLIB"
    [ "$status" -eq 2 ]
    [[ "$output" == *"reason=census-unbounded"* ]]
}

@test "exclusive: with no census the byte bound is unchanged" {
    # The control: a box that declares no tenant keeps the old behaviour exactly.
    run env -u LLM_AUTOTUNE_CENSUS LLM_AUTOTUNE_BASELINE_GAP_MAX=800 \
        bash -c 'source "$1"; _tac_vram_baseline_verdict 81120 81920; echo "---"; _tac_vram_baseline_verdict 81119 81920' _ "$BINLIB"
    [ "$status" -eq 1 ]
    [[ "$output" == *"mode=exclusive"* ]]
    [[ "$output" == *"held_mib=800"* ]]
    [[ "$output" == *"reason=gap-exceeds-bound"* ]]
}

@test "tombstone: a listed row is retired, and comments/blank lines are ignored" {
    # Catches: run-autotune-batch.sh / --all-but-done re-selecting an archived row.
    printf '# retired\n\na.gguf|wrong artefact\n\nb.gguf|too slow\n' > "$BATS_TEST_TMPDIR/retired"
    run env TAC_RESUME_RETIRED="$BATS_TEST_TMPDIR/retired" \
        bash -c 'source "$1"; _tac_is_retired a.gguf && ! _tac_is_retired c.gguf' _ "$BINLIB"
    [ "$status" -eq 0 ]
}

@test "tombstone: an absent tombstone retires nothing" {
    run env TAC_RESUME_RETIRED="$BATS_TEST_TMPDIR/absent.rows" \
        bash -c 'source "$1"; _tac_is_retired a.gguf' _ "$BINLIB"
    [ "$status" -eq 1 ]
}


@test "tombstone: an explicit override can read WHY the row was retired" {
    # Measured 2026-11-10 00:53 — the registry was renumbered at 00:11, so `autotune-rows.sh 5`
    # named a DIFFERENT model than the plan meant and staged Qwen3.8-Flash-Next-Coder-cut240,
    # retired as "qwen4exp.expert_count is an array, the loader reads u32 — re-convert".  The
    # run said nothing.  Naming a row is a deliberate override and stays honoured; what it must
    # no longer do is stay silent about the retirement.
    printf '# c\n\na.gguf|wrong artefact — re-convert\nb.gguf|no reason given\n' > "$BATS_TEST_TMPDIR/ret2"
    run env TAC_RESUME_RETIRED="$BATS_TEST_TMPDIR/ret2" \
        bash -c 'source "$1"; _tac_retired_reason a.gguf' _ "$BINLIB"
    [ "$status" -eq 0 ]
    [ "$output" = "wrong artefact — re-convert" ]
    # An unlisted file answers nothing and says so through its status, so a caller cannot
    # mistake "no reason recorded" for "not retired".
    run env TAC_RESUME_RETIRED="$BATS_TEST_TMPDIR/ret2" \
        bash -c 'source "$1"; _tac_retired_reason c.gguf; echo "rc=$?"' _ "$BINLIB"
    [ "$output" = "rc=1" ]
}

@test "tombstone: the caller WARNS on an explicitly named retired row" {
    # The call-site half. The helper above cannot see whether autotune-rows asks it, so this
    # pins the caller: the warning must name the row and carry the recorded reason, and it must
    # be emitted BEFORE the lock is taken.
    local src="$REPO_ROOT/bin/autotune-rows.sh"
    grep -q '_tac_retired_reason "\$_rfile"' "$src" \
        || { echo "autotune-rows no longer asks for the retirement reason"; return 1; }
    grep -q "row '\$_r' is RETIRED" "$src" \
        || { echo "the explicit-override warning is gone"; return 1; }
    # ...and it sits above the quiet gate, which is where the run stops mattering.
    local warn_n gate_n
    warn_n=$(grep -n "row '\$_r' is RETIRED" "$src" | head -1 | cut -d: -f1)
    gate_n=$(grep -n 'AUTOTUNE_QUIET_GATE:-' "$src" | head -1 | cut -d: -f1)
    [ -n "$warn_n" ] && [ -n "$gate_n" ] && [ "$warn_n" -lt "$gate_n" ] \
        || { echo "the warning must precede the quiet gate ($warn_n vs $gate_n)"; return 1; }
}

# ── The CUDA reap's attribution, and its selftest guard ───────────────────────
# nvidia-smi lists NO compute app on this box even at 73 GiB used, so the reaper
# killed nothing and a non-systemd server survived to refuse the census.  The
# collector falls back to /proc/PID/exe; the reaper itself must never run under a
# selftest, whose cases execute on a box whose real lanes are serving.

@test "cuda sweep: an empty nvidia-smi list falls back to /proc by exe, and skips build-opencl" {
    local root="$BATS_TEST_TMPDIR/llama.cpp"
    mkdir -p "$root/build-cuda/bin" "$root/build-opencl/bin" "$BATS_TEST_TMPDIR/bin"
    # A bash COPY, not /bin/sleep: this box's coreutils is uutils, a multicall binary
    # that rejects a renamed copy ("unknown program 'llama-server'").
    cp /bin/bash "$root/build-cuda/bin/llama-server"
    cp /bin/bash "$root/build-opencl/bin/llama-server"
    "$root/build-cuda/bin/llama-server" -c 'while :; do sleep 1; done' &
    local cuda_pid=$!
    "$root/build-opencl/bin/llama-server" -c 'while :; do sleep 1; done' &
    local xe_pid=$!
    # The stub answers the compute-app query with NOTHING — this box's real behaviour.
    printf '#!/usr/bin/env bash\nexit 0\n' > "$BATS_TEST_TMPDIR/bin/nvidia-smi"
    chmod +x "$BATS_TEST_TMPDIR/bin/nvidia-smi"
    sleep 0.2

    run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" bash -c \
        'source "$1"; __llm_cuda_server_pids' _ "$REPO_ROOT/scripts/11d-llm-gpu.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"$cuda_pid"* ]]
    [[ "$output" != *"$xe_pid"* ]]

    kill "$cuda_pid" "$xe_pid" 2>/dev/null || true
    wait "$cuda_pid" "$xe_pid" 2>/dev/null || true
}

@test "cuda sweep: a selftest never runs the reaper against the live card" {
    # Catches: the /proc fallback making a SELFTEST reap the box's real lanes.  The
    # guard must fire before the foreign-owner probe and the scan.
    local root="$BATS_TEST_TMPDIR/llama.cpp"
    mkdir -p "$root/build-cuda/bin"
    cp /bin/bash "$root/build-cuda/bin/llama-server"
    "$root/build-cuda/bin/llama-server" -c 'while :; do sleep 1; done' &
    local pid=$!
    sleep 0.2

    run env AUTOTUNE_SELFTEST=1 bash -c \
        'source "$1"; __llm_kill_cuda_llama_servers' _ "$REPO_ROOT/scripts/11d-llm-gpu.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"selftest"* ]]
    kill -0 "$pid"   # still alive: no reap happened

    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
}

@test "the stale 2026-08-28 sizing note is gone from the guard" {
    run grep -c "on this box, 2026-08-28" "$REPO_ROOT/scripts/autotune-model.sh"
    [ "$output" -eq 0 ]
}

@test "clean-room: only no-unit CUDA holders are named for reaping" {
    # Measured 2026-11-11 09:39: `model autotune 1` refused on pid 278370 (no unit, :8081)
    # beside two unit-owned lanes.  A unit-owned server must never be reaped by pid —
    # systemd would restart it — so only the empty-unit rows may come back.
    local f="$BATS_TEST_TMPDIR/holders"
    printf '%s\n' \
        "2911479|llama-cuda-qwen3embedding-embed.service|llama-server" \
        "278370||llama-server" \
        "2911684|llama-cuda-qwen3coder-30b-chat.service|llama-server" > "$f"
    run env LLM_AUTOTUNE_VRAM_HOLDERS_FILE="$f" bash -c \
        'source "$1"; _tac_unsupervised_cuda_pids' _ "$REPO_ROOT/bin/_tac-bin-lib.sh"
    [ "$status" -eq 0 ]
    [ "$output" = "278370" ]
}

@test "clean-room: model autotune routes through the wrapper with flags as env" {
    # Catches: `model autotune N` calling the inner engine, which never stops a lane and so
    # can only refuse a busy card.  The wrapper is stubbed; the call it receives is the test.
    local stub="$BATS_TEST_TMPDIR/bin"
    mkdir -p "$stub"
    run env STUB_DIR="$stub" bash -c '
        source "$1/scripts/11e-llm-model.sh" >/dev/null 2>&1
        __autotune_script_path() { printf "%s/rows.sh\n" "$STUB_DIR"; }
        printf "#!/usr/bin/env bash\nprintf \"wl=%%s cont=%%s args=%%s\\\\n\" \"\$LLM_AUTOTUNE_WORKLOAD\" \"\$TAC_CONTENDED\" \"\$*\"\n" \
            > "$STUB_DIR/rows.sh"
        __model_autotune_clean_room 3 --workload legal --allow-contended' _ "$REPO_ROOT"
    [ "$status" -eq 0 ]
    [ "$output" = "wl=legal cont=1 args=3" ]
}

@test "clean-room: a bare --workload is refused, not forwarded" {
    run bash -c '
        source "$1/scripts/01-constants.sh" >/dev/null 2>&1 || true
        source "$1/scripts/05-ui-engine.sh" >/dev/null 2>&1 || true
        source "$1/scripts/11e-llm-model.sh" >/dev/null 2>&1
        __model_autotune_clean_room 3 --workload' _ "$REPO_ROOT"
    [ "$status" -eq 2 ]
    [[ "$output" == *"--workload needs a value"* ]]
}
