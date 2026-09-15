#!/usr/bin/env bats
# ==============================================================================
# Unit Tests — GPU exclusivity bridge (BENCH-GPU-EXCLUSIVITY-001)
# ==============================================================================
# The investigator pipeline holds a cross-process GPU flock for the whole
# duration of a local-model run (investigator pipeline/gpu/_lock.py). Nothing on
# the console side honoured it, so its two CUDA-reap paths could destroy another
# agent's run:
#
#   1. scripts/11d-llm-gpu.sh::__llm_kill_cuda_llama_servers (the autotune/bench drain)
#   2. bin/llama-gpu-clear.sh (the CUDA lane's ExecStartPre — evictor #1 in the
#      investigator's own list)
#
# Both now probe the same lock. The path expression is duplicated on purpose:
# the clear script is an ExecStartPre and must not depend on the console's
# module tree, which is why it stands alone at all. The drift tests below pin
# the two copies together so they cannot diverge.
#
# The regression these tests exist for: `flock -n` ALSO fails on a MISSING path,
# so a probe without an existence gate reads "cannot open the file" as "held by
# another owner" — and then refuses every run on a box that never took the lock.
#
# NOTE: these tests probe the guard FUNCTIONS, extracted verbatim from each
# file. They deliberately never execute bin/llama-gpu-clear.sh itself: its reap
# path matches real host llama-server builds by /proc/PID/exe, so running it
# here would kill the very processes the guard exists to protect.
# ==============================================================================

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
MODULE="$REPO_ROOT/scripts/11d-llm-gpu.sh"
CLEAR="$REPO_ROOT/bin/llama-gpu-clear.sh"

setup() {
    TAC_TEST_TMPDIR="$(mktemp -d)"
    export TAC_TEST_TMPDIR
    export INVESTIGATOR_GPU_LOCK="$TAC_TEST_TMPDIR/gpu.lock"
    unset INVESTIGATOR_PRODUCTION_OUTPUT
    LOCK_HOLDER_PID=""

    cat > "$TAC_TEST_TMPDIR/probe.sh" <<'EOS'
set -uo pipefail
source "$1"
_probe_fn="$2"
if "$_probe_fn"; then echo HELD; else echo FREE; fi
EOS

    # Value-returning guards (the holder pid) must not be funnelled through the
    # predicate harness, which would swallow their stdout.
    cat > "$TAC_TEST_TMPDIR/call.sh" <<'EOS'
set -uo pipefail
source "$1"
_call_fn="$2"
"$_call_fn"
EOS
}

teardown() {
    [[ -n "${LOCK_HOLDER_PID:-}" ]] && kill -TERM "$LOCK_HOLDER_PID" 2>/dev/null || true
    rm -rf "$TAC_TEST_TMPDIR" 2>/dev/null || true
}

# The module's three guards, extracted verbatim and evaluated, so this exercises
# the real source text without pulling in the module's dependencies.
_module_guards() {
    sed -n '/^function __llm_gpu_lock_path/,/^}/p' "$MODULE" > "$TAC_TEST_TMPDIR/guards.sh"
    sed -n '/^function __llm_gpu_lock_holder/,/^}/p' "$MODULE" >> "$TAC_TEST_TMPDIR/guards.sh"
    sed -n '/^function __llm_gpu_foreign_owner/,/^}/p' "$MODULE" >> "$TAC_TEST_TMPDIR/guards.sh"
}

_clear_guards() {
    sed -n '/^_inv_gpu_lock_path/,/^}/p' "$CLEAR" > "$TAC_TEST_TMPDIR/guards.sh"
    sed -n '/^_inv_gpu_foreign_owner/,/^}/p' "$CLEAR" >> "$TAC_TEST_TMPDIR/guards.sh"
}

# _hold_lock — take the lock from another process until teardown.
_hold_lock() {
    flock "$INVESTIGATOR_GPU_LOCK" -c "sleep 30" &
    LOCK_HOLDER_PID=$!
    local _i
    for _i in $(seq 1 40); do
        flock -n "$INVESTIGATOR_GPU_LOCK" -c true 2>/dev/null || return 0
        sleep 0.1
    done
    return 1
}

@test "gpu-exclusivity: the module probe reports FREE when the lock file is absent" {
    _module_guards
    [[ ! -e "$INVESTIGATOR_GPU_LOCK" ]]
    run bash "$TAC_TEST_TMPDIR/probe.sh" "$TAC_TEST_TMPDIR/guards.sh" __llm_gpu_foreign_owner
    [[ "$output" == "FREE" ]]
}

@test "gpu-exclusivity: the module probe reports HELD when another process owns the lock" {
    command -v flock >/dev/null || skip "flock unavailable"
    _module_guards
    _hold_lock || skip "could not take the lock in this environment"
    [[ -e "$INVESTIGATOR_GPU_LOCK" ]]
    run bash "$TAC_TEST_TMPDIR/probe.sh" "$TAC_TEST_TMPDIR/guards.sh" __llm_gpu_foreign_owner
    [[ "$output" == "HELD" ]]
}

@test "gpu-exclusivity: the module probe reports FREE when the lock file exists but is unheld" {
    _module_guards
    : > "$INVESTIGATOR_GPU_LOCK"
    run bash "$TAC_TEST_TMPDIR/probe.sh" "$TAC_TEST_TMPDIR/guards.sh" __llm_gpu_foreign_owner
    [[ "$output" == "FREE" ]]
}

@test "gpu-exclusivity: the module reports the recorded holder pid" {
    _module_guards
    printf '4242\n' > "$INVESTIGATOR_GPU_LOCK"
    run bash "$TAC_TEST_TMPDIR/call.sh" "$TAC_TEST_TMPDIR/guards.sh" __llm_gpu_lock_holder
    [[ "$output" == "4242" ]]
}

# The false-positive regression: a missing path must NOT read as "held".
@test "gpu-exclusivity: the clear-script probe reports FREE when the lock file is absent" {
    _clear_guards
    [[ ! -e "$INVESTIGATOR_GPU_LOCK" ]]
    run bash "$TAC_TEST_TMPDIR/probe.sh" "$TAC_TEST_TMPDIR/guards.sh" _inv_gpu_foreign_owner
    [[ "$output" == "FREE" ]]
}

@test "gpu-exclusivity: the clear-script probe reports HELD when another process owns the lock" {
    command -v flock >/dev/null || skip "flock unavailable"
    _clear_guards
    _hold_lock || skip "could not take the lock in this environment"
    run bash "$TAC_TEST_TMPDIR/probe.sh" "$TAC_TEST_TMPDIR/guards.sh" _inv_gpu_foreign_owner
    [[ "$output" == "HELD" ]]
}

# --- drift guards: the two copies of the path rule must stay identical -------
@test "gpu-exclusivity: both copies resolve the lock path identically" {
    local _expr='${INVESTIGATOR_GPU_LOCK:-${INVESTIGATOR_PRODUCTION_OUTPUT:-$HOME/investigator/production}/runtime/gpu.lock}'
    grep -qF -- "$_expr" "$MODULE"
    grep -qF -- "$_expr" "$CLEAR"
}

@test "gpu-exclusivity: both copies existence-gate the probe and use flock -n" {
    local _gate='[[ -e "$_lock_path" ]] || return 1'
    grep -qF -- "$_gate" "$MODULE"
    grep -qF -- "$_gate" "$CLEAR"
    # Both must probe with the same primitive: a non-blocking flock.
    [[ "$(grep -cF 'flock -n "$_lock_path" -c true' "$MODULE")" -ge 1 ]]
    [[ "$(grep -cF 'flock -n "$_lock_path" -c true' "$CLEAR")" -ge 1 ]]
}

# A guard that is defined but never consulted protects nothing.
@test "gpu-exclusivity: both reap paths consult the guard before killing" {
    # Module: the killer short-circuits when a foreign owner holds the lock.
    awk '/^function __llm_kill_cuda_llama_servers/,/^}/' "$MODULE" \
        | grep -q '__llm_gpu_foreign_owner'
    # Clear script: the reap is inside the guard's else branch.
    grep -q 'if _inv_gpu_foreign_owner; then' "$CLEAR"
    # Batch: the drain and the per-row gate both consult it.
    grep -q '__llm_gpu_foreign_owner' "$REPO_ROOT/scripts/run-autotune-batch.sh"
}

# ONE LLM ON THE CUDA CARD, EVER.  When another run owns the card the lane must
# not start at all — a second llama-server on a 4 GB card is the failure mode, and
# skipping only the reap was not enough.  Only the REFUSAL path is exercised here:
# with the lock held the script exits before its reap, so this cannot reach a real
# server.  (The free path deliberately is not run — it kills CUDA servers.)
@test "gpu-exclusivity: llama-gpu-clear REFUSES to start the lane when the card is owned" {
    command -v flock >/dev/null || skip "flock unavailable"
    _hold_lock || skip "could not take the lock in this environment"

    run "$REPO_ROOT/bin/llama-gpu-clear.sh"

    [ "$status" -ne 0 ]
    [[ "$output" == *"CUDA card is owned by another run"* ]]
    [[ "$output" == *"NOT starting this lane"* ]]
}

# A claim that is never consulted protects nothing, and a mark that is never
# released leaves the CUDA lane down for good.
@test "gpu-exclusivity: model use claims the CUDA card and model stop releases it" {
    local _claim _use _stop
    _claim=$(awk '/^function __model_use_claim_cuda_card\(\)/,/^}/' "$REPO_ROOT/scripts/11e-llm-model.sh")
    _use=$(awk '/^function __model_use\(\)/,/^}/' "$REPO_ROOT/scripts/11e-llm-model.sh")
    _stop=$(awk '/^function __model_stop\(\)/,/^}/' "$REPO_ROOT/scripts/11e-llm-model.sh")

    # Wired in, and released.
    [[ "$_use" == *"__model_use_claim_cuda_card"* ]]
    [[ "$_stop" == *"card released"* ]]
    # It refuses a foreign owner and displaces our own CUDA lanes...
    [[ "$_claim" == *"__llm_gpu_foreign_owner"* ]]
    [[ "$_claim" == *"llama-server-nvidia.service"* ]]
    [[ "$_claim" == *"llama-server-phi4.service"* ]]
    # ...and never the Xe card's units.
    [[ "$_claim" != *"llama-server.service"* ]]
    [[ "$_claim" != *"llama-embed-server.service"* ]]
}
