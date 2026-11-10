#!/usr/bin/env bats
# ==============================================================================
# Unit — model use: a live sweep/bench ownership mark is checked BEFORE any lane stops
# ==============================================================================
# WHY THIS EXISTS (measured 2026-11-07T12:18:47Z, closed 2026-11-08): the coder lane
# llama-cuda-qwen3coder-30b-chat.service was stopped (status=9/KILL, 14.1G memory peak)
# by a `model use` that arrived while another run held the card.  The ordering was the
# defect, not the message:
#
#   __model_use_claim_cuda_card:
#     step 1  foreign GPU lock ............ refuse
#     step 2  STOP THE CUDA LANES ......... runs regardless
#     step 3  _tac_suspend_acquire ........ fails -> Warning -> return 0
#
# So the lane was already down by the time anything looked at the marker, and the
# command reported success afterwards.  A marker reader existed; it was simply on the
# wrong side of the destructive step.  This is the green-because-out-of-scope shape
# applied to ordering: "the marker is honoured" was true of step 3 and false of the
# function.
#
# WHAT THESE CASES ASSERT: the PROPERTY — when the marker is held by a live pid, no
# lane-stop command is issued and model use returns non-zero.  The stop call is a
# recording stub, so the assertion is "nothing was stopped", not "a line was printed".
#
# FALSIFICATION: with step 1b removed, the first case fails twice over — the stub
# records a stop and `model use` exits 0.  Verified against the pre-change file.
#
# HERMETIC: HOME, registry and model dir are sandboxed; systemctl, the launcher and the
# download are stubbed.  Nothing touches the card, no server starts.  The box-wide
# heavy-job lock is sandboxed too: __model_bench takes it before its bench mutex, and a
# case that contended for the REAL one queued behind whatever else held the box — with
# no bound, because LLM_BENCH_HEAVY_LOCK_WAIT_SECONDS is unset by default.  Measured
# 2026-11-19: the VS Code BATS runner wedged 10+ minutes in `flock -x` on
# /tmp/heavy-job.lock while an unrelated pytest session held it.  Same seam as
# tests/integration/02-model-lifecycle.bats and tests/unit/38-heavy-job.bats.
# ==============================================================================

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    export REPO_ROOT
    SANDBOX="$(mktemp -d)"
    export SANDBOX
    export HOME="$SANDBOX/home"
    export TAC_TEST_TMPDIR="$SANDBOX/tac"
    export TAC_CACHE_DIR="$SANDBOX/cache"
    export HEAVY_JOB_LOCK="$SANDBOX/heavy-job.lock"
    mkdir -p "$HOME" "$TAC_TEST_TMPDIR" "$TAC_CACHE_DIR"

    # shellcheck source=env.sh
    source "$REPO_ROOT/env.sh"

    __tac_line() { printf 'LINE %s\n' "$*"; }
    __tac_info() { printf 'INFO %s\n' "$*"; }

    export LLM_REGISTRY="$SANDBOX/models.conf"
    export LLAMA_MODEL_DIR="$SANDBOX/models"
    mkdir -p "$LLAMA_MODEL_DIR"
    # A healthy row: ctx present, autotuned=yes — so nothing else can refuse this run.
    cat > "$LLM_REGISTRY" <<'EOF'
#|name|file|size_gb|quant_cache|arch|gpu_layers|ctx|threads|batch|ubatch|parallel|fit_target_mb|backend|mmap_mode|flash_attn|tps|autotuned|is_default|in_vram
1|Ready|ready.gguf|1.0G|Q4_K_M/q8_0|qwen2|24|8192|6|1024|256|1|256|llama_server|auto|on|11.0|yes|no|no
EOF

    LAUNCH_MARKER="$SANDBOX/launched"
    STOP_LOG="$SANDBOX/stopped"
    export LAUNCH_MARKER STOP_LOG
    : > "$STOP_LOG"

    # The suspend marker this test controls.
    export LLAMA_WATCHDOG_CUDA_SUSPEND_FILE="$SANDBOX/suspend"

    # systemctl is the lane-stop path; record every stop instead of performing it.
    systemctl() {
        if [[ "${1:-}" == "--user" && "${2:-}" == "stop" ]]; then
            printf '%s\n' "${3:-}" >> "$STOP_LOG"
            return 0
        fi
        return 1
    }
    export -f systemctl

    # Every step that touches the box, minus the one under test.
    __model_use_ensure_downloaded() { return 0; }
    __model_use_select_backend() { return 0; }
    __model_use_configure_params() { return 0; }
    __model_use_build_command() { return 0; }
    __model_use_launch_server() { : > "$LAUNCH_MARKER"; return 0; }
    __model_use_wait_healthy() { return 0; }

    unset TAC_CTX_SIZE ctx threads
}

teardown() {
    cd /
    rm -rf "$SANDBOX"
}

# A pid that is certainly alive and is not this shell: "1" would be init. Use the
# test shell's own parent, which exists for the life of the run.
_live_pid() { printf '%s\n' "$PPID"; }

@test "a marker held by a LIVE pid: no lane is stopped and model use refuses" {
    _live_pid > "$LLAMA_WATCHDOG_CUDA_SUSPEND_FILE"

    run __model_use_claim_cuda_card

    [ "$status" -ne 0 ]
    [[ "$output" == *"held by a live sweep/bench"* ]]
    # THE PROPERTY: the destructive step never ran.
    [ ! -s "$STOP_LOG" ]
}

@test "a marker held by a live pid: model use as a whole refuses and does not launch" {
    _live_pid > "$LLAMA_WATCHDOG_CUDA_SUSPEND_FILE"

    run model use 1

    [ "$status" -ne 0 ]
    [ ! -s "$STOP_LOG" ]
    [ ! -e "$LAUNCH_MARKER" ]
}

@test "a marker whose owner pid is DEAD reads as not held: the claim proceeds" {
    # A killed holder cannot release its own hold; it must never wedge the command.
    printf '999999\n' > "$LLAMA_WATCHDOG_CUDA_SUSPEND_FILE"

    run __model_use_claim_cuda_card

    [ "$status" -eq 0 ]
    # And it now owns the mark itself.
    [ "$(cat "$LLAMA_WATCHDOG_CUDA_SUSPEND_FILE")" = "$$" ]
}

@test "no marker at all: the claim proceeds" {
    rm -f "$LLAMA_WATCHDOG_CUDA_SUSPEND_FILE"

    run __model_use_claim_cuda_card

    [ "$status" -eq 0 ]
    [ -e "$LLAMA_WATCHDOG_CUDA_SUSPEND_FILE" ]
}

@test "__BENCH_MODE=1 honors an ancestor hold without refusing or overwriting the parent pid" {
    local parent_pid
    parent_pid=$(_live_pid)
    printf '%s\n' "$parent_pid" > "$LLAMA_WATCHDOG_CUDA_SUSPEND_FILE"

    run bash -c '
        export HOME="$1" TAC_TEST_TMPDIR="$2" TAC_CACHE_DIR="$3"
        export LLAMA_WATCHDOG_CUDA_SUSPEND_FILE="$4" __BENCH_MODE=1
        source "$5/env.sh"
        __tac_info() { printf "INFO %s\n" "$*"; }
        systemctl() { return 1; }
        export -f systemctl
        __model_use_claim_cuda_card
    ' _ "$HOME" "$TAC_TEST_TMPDIR" "$TAC_CACHE_DIR" "$LLAMA_WATCHDOG_CUDA_SUSPEND_FILE" "$REPO_ROOT"

    [ "$status" -eq 0 ]
    [ "$(cat "$LLAMA_WATCHDOG_CUDA_SUSPEND_FILE")" = "$parent_pid" ]
}

@test "__BENCH_MODE=1 still refuses a hold owned by an unrelated live pid" {
    sleep 30 &
    local stranger_pid=$!
    printf '%s\n' "$stranger_pid" > "$LLAMA_WATCHDOG_CUDA_SUSPEND_FILE"

    __BENCH_MODE=1 run __model_use_claim_cuda_card
    local rc=$status

    kill "$stranger_pid" 2>/dev/null || true
    wait "$stranger_pid" 2>/dev/null || true

    [ "$rc" -ne 0 ]
    [[ "$output" == *"held by a live sweep/bench"* ]]
    [ ! -s "$STOP_LOG" ]
}

@test "__model_bench holds suspend under its live pid, derives large-model timeout, and releases before restore" {
    touch "$LLAMA_MODEL_DIR/ready.gguf" "$LLAMA_MODEL_DIR/huge.gguf"
    cat > "$LLM_REGISTRY" <<'EOF'
#|name|file|size_gb|quant_cache|arch|gpu_layers|ctx|threads|batch|ubatch|parallel|fit_target_mb|backend|mmap_mode|flash_attn|tps|autotuned|is_default|in_vram
1|Ready|ready.gguf|1.0G|Q4_K_M/q8_0|qwen2|24|8192|6|1024|256|1|256|llama_server|auto|on|11.0|yes|no|no
2|Huge|huge.gguf|73.3G|NVFP4/q8_0|nemotron|89|40960|10|1024|512|1|256|llama_server|auto|on|12.0|yes|no|no
EOF
    export ACTIVE_LLM_FILE="$SANDBOX/active_llm"
    printf '%s\n' "ready.gguf" > "$ACTIVE_LLM_FILE"
    local timeout_log="$SANDBOX/timeouts.log"
    local suspend_seen_log="$SANDBOX/suspend_seen.log"
    local restore_log="$SANDBOX/restore.log"

    run bash -c '
        export HOME="$1" TAC_TEST_TMPDIR="$2" TAC_CACHE_DIR="$3"
        export LLAMA_WATCHDOG_CUDA_SUSPEND_FILE="$6"
        export LLM_BENCH_LOCK_FILE="$8/bench.lock"
        export LLM_BENCH_PID_FILE="$8/bench.pid"
        export LLM_BENCH_WATCHDOG_TIMER="nonexistent-bench-test.timer"
        export LLM_BENCH_COOLDOWN_SEC=0
        export TIMEOUT_LOG="$8/timeouts.log"
        export SUSPEND_SEEN_LOG="$8/suspend_seen.log"
        export RESTORE_LOG="$8/restore.log"
        unset LLM_BENCH_MODEL_TIMEOUT
        source "$9/env.sh" >/dev/null || exit 90
        export LLM_REGISTRY="$4" LLAMA_MODEL_DIR="$5" ACTIVE_LLM_FILE="$7"
        export LLM_STATE_DIR="$8/state" LLM_TPS_CACHE="$8/tps"
        export LLM_WINDOW_MISMATCH_CACHE="$8/win_mismatch"
        mkdir -p "$LLM_STATE_DIR"
        __tac_header() { :; }
        __tac_footer() { :; }
        __tac_info() { printf "INFO %s\n" "$*"; }
        __tac_cleanup_stale_locks() { :; }
        __llm_bench_perf_prep() { :; }
        __llm_autotune_done_for_model() { return 0; }
        __model_stop() { :; }
        __gpu_clear_stale_processes() { :; }
        __resolve_smi() { return 1; }
        _tac_gpu_used_mib() { return 0; }
        # The adapter pre-check reads the REAL dmesg, so on a box with dxgkrnl errors
        # __model_bench refuses before the subject of the case is reached (measured
        # 2026-11-15, ubuntu-console CI red on main, cases 1169/1170). It is a box
        # fact, not the property under test, and it has its own coverage in
        # tests/test_dxg_health.py, so it is stubbed like every other box-touching
        # step in this file. (No apostrophes below: this block is inside a
        # single-quoted bash -c string, where a stray one would close it.)
        _tac_adapter_health_check() { return 0; }
        wake() { :; }
        sudo() { return 0; }
        systemctl() { return 1; }
        __bench_run_with_timeout() {
            printf "%s\n" "$1" >> "$TIMEOUT_LOG"
            shift
            "$@"
        }
        __model_use() {
            if [[ -n "${__BENCH_MODE:-}" ]]; then
                cat "$LLAMA_WATCHDOG_CUDA_SUSPEND_FILE" >> "$SUSPEND_SEEN_LOG"
            else
                if [[ -e "$LLAMA_WATCHDOG_CUDA_SUSPEND_FILE" ]]; then
                    echo "STILL_HELD" >> "$RESTORE_LOG"
                else
                    echo "RELEASED" >> "$RESTORE_LOG"
                fi
            fi
            return 0
        }
        burn() {
            printf "42.0 tps\n" > "$LLM_TPS_CACHE"
            return 0
        }
        __model_bench
    ' _ "$HOME" "$TAC_TEST_TMPDIR" "$TAC_CACHE_DIR" "$LLM_REGISTRY" "$LLAMA_MODEL_DIR" \
        "$LLAMA_WATCHDOG_CUDA_SUSPEND_FILE" "$ACTIVE_LLM_FILE" "$SANDBOX" "$REPO_ROOT"

    [ "$status" -eq 0 ] || { echo "status=$status output=$output"; return 1; }
    # Suspend marker was held under the bench shell pid during the loop and released before restore.
    [ ! -e "$LLAMA_WATCHDOG_CUDA_SUSPEND_FILE" ]
    [ "$(grep -c . "$suspend_seen_log")" -eq 2 ]
    [ "$(cat "$restore_log")" = "RELEASED" ]
    # Model 1 (1.0G) gets health(120) + burn(600) = 720s; Model 2 (73.3G) scales to 876 + 900 = 1776s.
    [ "$(sed -n '1p' "$timeout_log")" -ge 600 ]
    [ "$(sed -n '2p' "$timeout_log")" -gt "$(sed -n '1p' "$timeout_log")" ]
    [ "$(sed -n '2p' "$timeout_log")" -ge 1500 ]
}

@test "__model_bench enters clean-room (stops census tenants, watchdogs, runners, lane) and restores on exit" {
    touch "$LLAMA_MODEL_DIR/ready.gguf"
    cat > "$LLM_REGISTRY" <<'EOF'
#|name|file|size_gb|quant_cache|arch|gpu_layers|ctx|threads|batch|ubatch|parallel|fit_target_mb|backend|mmap_mode|flash_attn|tps|autotuned|is_default|in_vram
1|Ready|ready.gguf|1.0G|Q4_K_M/q8_0|qwen2|24|8192|6|1024|256|1|256|llama_server|auto|on|11.0|yes|no|no
EOF
    export ACTIVE_LLM_FILE="$SANDBOX/active_llm"
    printf '%s\n' "ready.gguf" > "$ACTIVE_LLM_FILE"
    local sys_log="$SANDBOX/systemctl.log"

    run bash -c '
        export HOME="$1" TAC_TEST_TMPDIR="$2" TAC_CACHE_DIR="$3"
        export LLAMA_WATCHDOG_CUDA_SUSPEND_FILE="$6"
        export LLM_BENCH_LOCK_FILE="$8/bench.lock"
        export LLM_BENCH_PID_FILE="$8/bench.pid"
        export LLM_BENCH_WATCHDOG_TIMER="nonexistent-bench-test.timer"
        export LLM_BENCH_COOLDOWN_SEC=0
        # NOT exported before env.sh sources the host profile: tac_host_profile_apply
        # unsets LLM_AUTOTUNE_CENSUS and LLAMA_CUDA_LANE_UNIT and re-reads them from the
        # profile, so a value set here is discarded.  This case used to assert the embed
        # lane, which was in the census until 2026-11-15T11:01Z corrected it -- naming the
        # KEEP lane there made the clean-room stand down the lane LLAMA_LANE_KEEP_UNITS
        # says must survive.  The census is now {chat, measure} and this case follows it.
        export LLM_AUTOTUNE_VRAM_HOLDERS_FILE="/dev/null"
        export SYS_LOG="$8/systemctl.log"
        # The clean-room refuses every stop under TAC_TEST_TMPDIR (v27, 2026-11-14: a test
        # took the CUDA tier down three times).  This case is the ONLY coverage of the
        # stop ORDER, so it opens the seam -- and the seam is safe here for a reason the
        # guard checks rather than trusts: systemctl is a shell function below, and
        # `declare -F systemctl` is what the guard requires before it will stop anything.
        export TAC_CLEANROOM_ALLOW_STOPS=1
        source "$9/env.sh" >/dev/null || exit 90
        export LLM_REGISTRY="$4" LLAMA_MODEL_DIR="$5" ACTIVE_LLM_FILE="$7"
        export LLM_STATE_DIR="$8/state" LLM_TPS_CACHE="$8/tps"
        export LLM_WINDOW_MISMATCH_CACHE="$8/win_mismatch"
        mkdir -p "$LLM_STATE_DIR"
        __tac_header() { :; }
        __tac_footer() { :; }
        __tac_info() { :; }
        __tac_cleanup_stale_locks() { :; }
        __llm_bench_perf_prep() { :; }
        __llm_autotune_done_for_model() { return 0; }
        __model_stop() { :; }
        __gpu_clear_stale_processes() { :; }
        __resolve_smi() { return 1; }
        _tac_gpu_used_mib() { return 0; }
        # See the note in the case above: the adapter pre-check reads the real dmesg
        # and would refuse before the clean-room ordering is exercised.
        _tac_adapter_health_check() { return 0; }
        wake() { :; }
        sudo() { return 0; }
        systemctl() {
            if [[ "$1" == "--user" && "$2" == "list-unit-files" ]]; then
                printf "actions.runner.test.service enabled\n"
                return 0
            fi
            if [[ "$1" == "--user" && "$2" == "is-active" ]]; then
                return 0
            fi
            printf "%s\n" "$*" >> "$SYS_LOG"
            return 0
        }
        __bench_run_with_timeout() { shift; "$@"; }
        __model_use() { return 0; }
        burn() {
            printf "BURN_MARKER\n" >> "$SYS_LOG"
            printf "42.0 tps\n" > "$LLM_TPS_CACHE"
            return 0
        }
        __model_bench
    ' _ "$HOME" "$TAC_TEST_TMPDIR" "$TAC_CACHE_DIR" "$LLM_REGISTRY" "$LLAMA_MODEL_DIR" \
        "$LLAMA_WATCHDOG_CUDA_SUSPEND_FILE" "$ACTIVE_LLM_FILE" "$SANDBOX" "$REPO_ROOT"

    [ "$status" -eq 0 ] || { echo "status=$status output=$output"; return 1; }
    # Tenant, watchdogs, runner, and primary lane stopped BEFORE burn; restored AFTER burn.
    # The expected set is read from the HOST PROFILE, not named here.  This case used to
    # hardcode the arm64 box's {chat, measure}, which made it pass only where
    # LLM_AUTOTUNE_CENSUS names those units — measured 2026-11-16 on intel-xe-cuda, whose
    # census is empty and whose lane is llama-cuda-llama32-3b-chat.  What this case proves
    # is the ORDER and that nothing undeclared is stopped; census membership is pinned
    # independently by tests/unit/74-host-profiles.bats case 29.
    local burn_line _unit _line
    burn_line=$(grep -n "^BURN_MARKER$" "$sys_log" | cut -d: -f1)
    [ -n "$burn_line" ]

    for _unit in ${LLM_AUTOTUNE_CENSUS:-}; do
        head -n "$burn_line" "$sys_log" | grep -q "stop $_unit" \
            || { echo "census tenant $_unit NOT stopped before burn"; return 1; }
        tail -n +"$burn_line" "$sys_log" | grep -q "start $_unit" \
            || { echo "census tenant $_unit NOT restored after burn"; return 1; }
    done

    head -n "$burn_line" "$sys_log" | grep -q "stop llama-watchdog-guard.timer"
    head -n "$burn_line" "$sys_log" | grep -q "stop actions.runner.test.service"
    head -n "$burn_line" "$sys_log" | grep -q "stop $LLAMA_CUDA_LANE_UNIT"
    tail -n +"$burn_line" "$sys_log" | grep -q "start llama-watchdog-guard.timer"
    tail -n +"$burn_line" "$sys_log" | grep -q "start actions.runner.test.service"

    # Nothing outside the declared sets may be stopped.  This is what keeps a KEEP lane —
    # and any undeclared neighbour — safe, and it stays a real assertion on a box whose
    # census is empty, unlike a check written as "this ASUS lane was not stopped".
    local _allowed=" ${LLM_AUTOTUNE_CENSUS:-} $LLAMA_CUDA_LANE_UNIT"
    _allowed+=" llama-watchdog.timer llama-watchdog-guard.timer llama-watchdog.service"
    # This case's own bench watchdog timer (LLM_BENCH_WATCHDOG_TIMER above, deliberately a
    # unit that does not exist) is stopped by the bench teardown.  It is a declared stop,
    # not a lane — the first run of this check caught it, which is why it is named here.
    _allowed+=" nonexistent-bench-test.timer actions.runner.test.service "
    while IFS= read -r _line; do
        _unit="${_line##* }"
        case "$_allowed" in
            *" $_unit "*) ;;
            *) echo "unexpected stop recorded: $_line"; return 1 ;;
        esac
    done < <(grep " stop " "$sys_log")
}

@test "__bench_heavy_lock_acquire binds the fd in the CALLER, so release frees the box lock" {
    # Criterion: bin/heavy-job's header — the box-wide lock is held for the job and
    # released when the job ends, so the next heavy job gets the box.
    # Wrong outcome detected: the bench returns while the lock is STILL held.  Bash's
    # `exec {var}>file` assigns `var` in the function that runs it, so a helper that
    # opens the lock without a caller-scoped name leaves __model_bench's own
    # _bench_heavy_fd empty; its release gate then never fires and the lock is shipped
    # to the parent.  Measured 2026-11-19: fd 11 stayed flocked in the VS Code extension
    # host, every later `heavy-job` invocation queued forever, and this suite wedged
    # 10+ minutes in `flock -x` on the real lock.
    local _lock="$SANDBOX/heavy-job.lock"
    run bash -c '
        export HEAVY_JOB_LOCK="$1"
        unset HEAVY_JOB_HELD
        source "$2/env.sh" >/dev/null
        _bench_heavy_fd=""
        _bench_acquired_heavy=0
        __bench_heavy_lock_acquire _bench_heavy_fd || { echo "acquire failed"; exit 1; }
        [[ -n "$_bench_heavy_fd" ]] || { echo "fd not bound in the caller"; exit 2; }
        __bench_heavy_lock_release
        if flock -n "$HEAVY_JOB_LOCK" -c true; then echo RELEASED; else echo STILL_HELD; fi
    ' _ "$_lock" "$REPO_ROOT"

    [ "$status" -eq 0 ]
    [ "$output" = "RELEASED" ]
}

# end of file

# ==============================================================================
# AUTOTUNE-CARD-ATTR-003 — the lane this function SPARES is on the CUDA card
# ==============================================================================
# The doc block above `__model_use_claim_cuda_card` used to justify sparing the
# embedding lane by saying it was an Xe lane: "Both Xe lanes keep serving
# throughout — llama-xe-minicpm5-1b-chat (:18081) and llama-xe-embeddinggemma-embed
# (:18080)".  On this box :18080 is llama-cuda-qwen3embedding-embed, on the very
# card the incoming model needs, and NO llama-xe unit is installed at all
# (measured 2026-11-10: `systemctl --user list-unit-files | grep -c '^llama-xe'` = 0).
# So the block spared a tenant on the contested card while telling the reader it was
# elsewhere.  The SPARING is still correct — the lane is kept for memory search, and
# its ~1.5 GB is what --fit sizes around — but the reason had to be the true one.
#
# These cases are derived from the host profile, not from a list of unit names: the
# unit that is spared is whatever LLAMA_LANE_KEEP_UNITS names, and the card is read
# from that unit's own `# CARD:` line.

@test "card-attr: the spared lane is a CUDA unit serving :18080 (not an Xe lane)" {
    local unit
    unit=$(bash -c 'source "$1"; tac_host_profile_apply >/dev/null 2>&1; printf "%s" "${LLAMA_LANE_KEEP_UNITS:-}"' \
        _ "$REPO_ROOT/tools/host-profile.sh" 2>/dev/null | tr ' ' '\n' | grep -m1 .)
    # The profile may need its facts stated; fall back to reading the shipped profile.
    if [[ -z "$unit" ]]; then
        unit=$(grep -oE 'LLAMA_LANE_KEEP_UNITS:=[^}]*' "$REPO_ROOT/config/hosts.d/asus-n1n-rtx-spark.conf" \
            | head -1 | sed 's/.*:=//')
    fi
    [[ -n "$unit" ]] || { echo "no keep unit resolved"; return 1; }
    local unit_file="$REPO_ROOT/systemd/$unit"
    [[ -f "$unit_file" ]] || { echo "no unit file at $unit_file"; return 1; }
    grep -q '^# CARD: CUDA' "$unit_file" \
        || { echo "$unit is not declared CUDA: $(grep -m1 '^# CARD:' "$unit_file")"; return 1; }
    grep -q 'port 18080' "$unit_file" \
        || { echo "$unit does not serve :18080: $(grep -m1 '^Description=' "$unit_file")"; return 1; }
}

@test "card-attr: the doc block names that unit and drops the false Xe claim" {
    local block
    block=$(sed -n '/^# __model_use_claim_cuda_card/,/^function __model_use_claim_cuda_card/p' \
        "$REPO_ROOT/scripts/11e-llm-model.sh")
    [[ -n "$block" ]] || { echo "the doc block moved; update this locator"; return 1; }
    # It names the lane it actually spares.
    [[ "$block" == *"llama-cuda-qwen3embedding-embed"* ]] \
        || { echo "the block does not name the CUDA embedding lane it spares"; return 1; }
    # REGRESSION PIN on the exact sentence the defect lived in.  A prose claim cannot be
    # tested by parsing, so this pins the false statement itself: "Both Xe lanes keep
    # serving throughout" asserted that the :18080 lane was an Xe lane on THIS box, where
    # it is the CUDA embedding lane.  A revert of the fix restores the sentence and fails
    # here; a future re-wording is free to say the same true thing differently.
    if printf '%s\n' "$block" | grep -qF 'Both Xe lanes keep serving throughout'; then
        echo "the block still claims both :18080 and :18081 are Xe lanes on this box"
        return 1
    fi
    # And every Xe unit it DOES name must exist in the repo — a name nothing ships is the
    # same defect one level down.
    local xe
    for xe in $(printf '%s\n' "$block" | grep -oE 'llama-xe-[a-z0-9-]+' | sort -u); do
        [[ -f "$REPO_ROOT/systemd/$xe.service" ]] \
            || { echo "the block names $xe, which no unit file ships"; return 1; }
    done
}

# ==============================================================================
# AUTOTUNE-CARD-ATTR-003 — the card is DECLARED per unit and ASSERTED at start
# ==============================================================================
# The comment fix above removes the false belief; it cannot stop the next one.  A
# unit name (`llama-cuda-*`) is not evidence of a card, and neither is a comment:
# the only mechanical fact is Environment=LLAMA_GPU=<card> in the unit, checked
# against the build the launcher is about to exec.  bin/llama-card-assert is that
# check; the three launchers call it before exec, and the fleet case below refuses
# a unit whose declaration and executable disagree.
#
# Controls from the card:
#   (b) a unit declaring Xe while running a CUDA binary is refused at start — the
#       second and third cases drive the launcher and the assertion directly.
#   (c) a genuinely foreign, undeclared holder still refuses the run, naming it —
#       pinned by the census case in tests/unit/23-autotune-baseline-tolerance.bats
#       ("an UNLISTED holder refuses, and the refusal names it").
#   (a) a CUDA unit is detected by its RESIDENT PID and stood down, not spared by a
#       name — pinned by tests/unit/12-gpu-exclusivity.bats ("a lane holding CUDA
#       memory is stopped").  The kept embedding lane is spared deliberately, and
#       the first case above pins that it is a CUDA unit on :18080.

# _fake_server <root> <tree> — an executable that prints its arguments, standing in
# for the llama-server in a named build tree.
_fake_server() {
    mkdir -p "$1/$2/bin"
    printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@"\n' > "$1/$2/bin/llama-server"
    chmod +x "$1/$2/bin/llama-server"
}

@test "card-declaration: every lane unit declares its card, and the declaration agrees with what it execs" {
    local u decl launcher want comment
    for u in "$REPO_ROOT"/systemd/llama-*.service; do
        launcher=$(sed -nE 's/^ExecStart=([^ ]+).*/\1/p' "$u")
        case "$launcher" in
            */llama-cuda-server)                          want=cuda ;;
            */llama-xe-server)                            want=xe ;;
            */llama-cpu-server|*/build-cpu/bin/llama-server) want=none ;;
            *) continue ;;   # not a lane (watchdog, guard, cache sampler)
        esac
        decl=$(sed -nE 's/^Environment=LLAMA_GPU=([A-Za-z]+).*/\1/p' "$u" | head -1)
        [[ -n "$decl" ]] || { echo "${u##*/} declares no Environment=LLAMA_GPU"; return 1; }
        [[ "${decl,,}" == "$want" ]] \
            || { echo "${u##*/} declares '${decl}' but execs ${launcher##*/}"; return 1; }
        # The human-readable line must agree too: a comment that names another card
        # is exactly the drift this card was filed for.
        comment=$(sed -nE 's/^# CARD: ([^ (]+).*/\1/p' "$u" | head -1)
        case "$want" in
            cuda) [[ "$comment" == CUDA* ]] \
                      || { echo "${u##*/} runs the CUDA launcher but says '# CARD: ${comment:-<none>}'"; return 1; } ;;
            xe)   [[ "$comment" == Xe* ]] \
                      || { echo "${u##*/} runs the Xe launcher but says '# CARD: ${comment:-<none>}'"; return 1; } ;;
            none) [[ "$comment" == none* ]] \
                      || { echo "${u##*/} runs the CPU launcher but says '# CARD: ${comment:-<none>}'"; return 1; } ;;
        esac
    done
}

@test "card-declaration: the CUDA launcher refuses a unit that declares another card" {
    _fake_server "$BATS_TEST_TMPDIR/refuse" build-cuda
    run env LLAMA_GPU=xe \
        LLAMA_CUDA_SERVER_BIN="$BATS_TEST_TMPDIR/refuse/build-cuda/bin/llama-server" \
        bash "$REPO_ROOT/bin/llama-cuda-server" --version
    [ "$status" -ne 0 ]
    [[ "$output" == *"declares LLAMA_GPU=xe"* ]] \
        || { echo "got: $output"; return 1; }
    # ...and it never reached the server: the contradiction is a START refusal.
    [[ "$output" != *"--version"* ]]
}

@test "card-declaration: the CUDA launcher refuses an OpenCL build even when the unit says CUDA" {
    _fake_server "$BATS_TEST_TMPDIR/opencl" build-opencl
    run env LLAMA_GPU=cuda \
        LLAMA_CUDA_SERVER_BIN="$BATS_TEST_TMPDIR/opencl/build-opencl/bin/llama-server" \
        bash "$REPO_ROOT/bin/llama-cuda-server" --version
    [ "$status" -ne 0 ]
    [[ "$output" == *"declares CUDA but execs the OpenCL/Xe build"* ]] \
        || { echo "got: $output"; return 1; }
}

@test "card-declaration: a matching declaration starts the server it names" {
    _fake_server "$BATS_TEST_TMPDIR/match" build-cuda
    run env LLAMA_GPU=cuda \
        LLAMA_CUDA_SERVER_BIN="$BATS_TEST_TMPDIR/match/build-cuda/bin/llama-server" \
        bash "$REPO_ROOT/bin/llama-cuda-server" --version
    [ "$status" -eq 0 ]
    [ "$output" = "--version" ]
}

@test "card-declaration: the assertion refuses the other card's build, and accepts its own" {
    _fake_server "$BATS_TEST_TMPDIR/assert" build-cuda
    _fake_server "$BATS_TEST_TMPDIR/assert" build-opencl
    _fake_server "$BATS_TEST_TMPDIR/assert" build-cpu

    run "$REPO_ROOT/bin/llama-card-assert" xe "$BATS_TEST_TMPDIR/assert/build-cuda/bin/llama-server"
    [ "$status" -eq 1 ]
    [[ "$output" == *"declares Xe but execs"* ]] || { echo "got: $output"; return 1; }

    run "$REPO_ROOT/bin/llama-card-assert" cuda "$BATS_TEST_TMPDIR/assert/build-opencl/bin/llama-server"
    [ "$status" -eq 1 ]
    [[ "$output" == *"declares CUDA but execs the OpenCL/Xe build"* ]] || { echo "got: $output"; return 1; }

    run "$REPO_ROOT/bin/llama-card-assert" none "$BATS_TEST_TMPDIR/assert/build-cuda/bin/llama-server"
    [ "$status" -eq 1 ]
    [[ "$output" == *"declares no card but execs a GPU build"* ]] || { echo "got: $output"; return 1; }

    run "$REPO_ROOT/bin/llama-card-assert" cuda "$BATS_TEST_TMPDIR/assert/build-cuda/bin/llama-server"
    [ "$status" -eq 0 ]
    run "$REPO_ROOT/bin/llama-card-assert" xe "$BATS_TEST_TMPDIR/assert/build-opencl/bin/llama-server"
    [ "$status" -eq 0 ]
    run "$REPO_ROOT/bin/llama-card-assert" none "$BATS_TEST_TMPDIR/assert/build-cpu/bin/llama-server"
    [ "$status" -eq 0 ]
}

@test "card-declaration: an unknown declaration is a usage error, never a pass" {
    run "$REPO_ROOT/bin/llama-card-assert" gpu0 "$BATS_TEST_TMPDIR/assert/build-cuda/bin/llama-server"
    [ "$status" -eq 2 ]
    [[ "$output" == *"unknown declared card"* ]] || { echo "got: $output"; return 1; }
}
