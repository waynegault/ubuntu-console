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
# download are stubbed.  Nothing touches the card, no server starts.
# ==============================================================================

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    export REPO_ROOT
    SANDBOX="$(mktemp -d)"
    export SANDBOX
    export HOME="$SANDBOX/home"
    export TAC_TEST_TMPDIR="$SANDBOX/tac"
    export TAC_CACHE_DIR="$SANDBOX/cache"
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
