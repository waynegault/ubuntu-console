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
@test "gpu-exclusivity: every CUDA reap path consults the guard before killing" {
    # Module: both killers short-circuit when a foreign owner holds the lock —
    # __llm_kill_cuda_llama_servers (llama servers by exe) and
    # __gpu_clear_stale_processes (python CUDA holders, which is what the
    # investigator's bench runs as).
    awk '/^function __llm_kill_cuda_llama_servers/,/^}/' "$MODULE" \
        | grep -q '__llm_gpu_foreign_owner'
    awk '/^function __gpu_clear_stale_processes/,/^}/' "$MODULE" \
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
    [[ "$_claim" == *"llama-cuda-llama32-3b-chat.service"* ]]
    [[ "$_claim" == *"llama-cuda-qwen35-4b-pipeline.service"* ]]
    # ...and never the Xe card's units.
    [[ "$_claim" != *"llama-xe-minicpm5-1b-chat.service"* ]]
    [[ "$_claim" != *"llama-xe-embeddinggemma-embed.service"* ]]
}

# The watchdog can only stand down for another run if gpu-busy.sh knows about it,
# and its foreign-app signal CANNOT tell the two apart (same binary name).  The
# ownership signal is evaluated in isolation here — gpu-busy.sh itself runs its
# whole main flow at the bottom, so it cannot be sourced for this.
@test "gpu-exclusivity: gpu-busy's card-ownership signal fires only when the lock is held" {
    command -v flock >/dev/null || skip "flock unavailable"
    printf 'REASONS=()\n' > "$TAC_TEST_TMPDIR/owner.sh"
    awk '/^cuda_owner_busy\(\)/,/^}/' "$REPO_ROOT/bin/gpu-busy.sh" >> "$TAC_TEST_TMPDIR/owner.sh"
    grep -q 'cuda_owner_busy' "$TAC_TEST_TMPDIR/owner.sh"

    cat > "$TAC_TEST_TMPDIR/owner-probe.sh" <<'EOS'
set -uo pipefail
source "$1"
if cuda_owner_busy; then echo "BUSY ${REASONS[*]}"; else echo FREE; fi
EOS

    # No lock file at all: free (existence-gated — a missing path is not "held").
    run bash "$TAC_TEST_TMPDIR/owner-probe.sh" "$TAC_TEST_TMPDIR/owner.sh"
    [[ "$output" == "FREE" ]]

    # Lock held by another process: busy, with the card named in the reason.
    _hold_lock
    run bash "$TAC_TEST_TMPDIR/owner-probe.sh" "$TAC_TEST_TMPDIR/owner.sh"
    [[ "$output" == BUSY*cuda-owned-by-another-run* ]]

    # And the signal is actually part of the busy chain, not dead code.
    grep -q 'lock_busy || cuda_owner_busy' "$REPO_ROOT/bin/gpu-busy.sh"
}

# The launchers repeat the build path as a LITERAL (they are standalone — a lane
# start cannot assume a sourced shell), while 01-constants derives it from
# LLAMA_ROOT.  Nothing made the two agree until now, and a one-sided repoint is
# the BENCH-ENGINE-ID-001 hazard (docs/llama-cpp-runtime-audit.md) seen from this
# side: the lane and the bench would measure different builds and nothing would say
# so.
@test "gpu-exclusivity: each launcher's build default agrees with 01-constants' LLAMA_ROOT" {
    # 01-constants: AI_STORAGE_ROOT=$HOME, LLAMA_ROOT=$AI_STORAGE_ROOT/llama.cpp,
    # LLAMA_CUDA_SERVER_BIN=$LLAMA_SERVER_BIN ($LLAMA_ROOT/build/bin/llama-server),
    # LLAMA_XE_SERVER_BIN=$LLAMA_ROOT/build-opencl/bin/llama-server.
    local cuda_default xe_default
    cuda_default=$(sed -nE 's/.*LLAMA_CUDA_SERVER_BIN:-([^}]*)\}.*/\1/p' "$REPO_ROOT/bin/llama-cuda-server")
    xe_default=$(sed -nE 's/.*LLAMA_XE_SERVER_BIN:-([^}]*)\}.*/\1/p' "$REPO_ROOT/bin/llama-xe-server")

    [[ -n "$cuda_default" && -n "$xe_default" ]] \
        || { echo "FAIL: could not read a build default from a launcher"; return 1; }
    [[ "$cuda_default" == "$HOME/llama.cpp/build/bin/llama-server" ]] \
        || { echo "CUDA launcher default '$cuda_default' != 01-constants' LLAMA_CUDA_SERVER_BIN"; return 1; }
    [[ "$xe_default" == "$HOME/llama.cpp/build-opencl/bin/llama-server" ]] \
        || { echo "Xe launcher default '$xe_default' != 01-constants' LLAMA_XE_SERVER_BIN"; return 1; }
}

# A lane that named a historical forwarding shim (or the other card's launcher)
# would still start, and the card map would then describe something other than what
# runs — which is how "which build serves this card?" became unanswerable before.
@test "gpu-exclusivity: every lane unit runs its own card's canonical launcher" {
    local -a lanes=(
        llama-xe-minicpm5-1b-chat.service
        llama-xe-embeddinggemma-embed.service
        llama-cuda-llama32-3b-chat.service
        llama-cuda-qwen35-4b-pipeline.service
    )
    local u launcher

    for u in "${lanes[@]}"; do
        launcher=$(sed -nE 's/^ExecStart=([^ ]+).*/\1/p' "$REPO_ROOT/systemd/$u")
        case "$u" in
            llama-xe-*)   [[ "$launcher" == */llama-xe-server ]] \
                              || { echo "FAIL: $u runs '${launcher:-<none>}'"; return 1; } ;;
            llama-cuda-*) [[ "$launcher" == */llama-cuda-server ]] \
                              || { echo "FAIL: $u runs '${launcher:-<none>}'"; return 1; } ;;
        esac
    done

    # ...and no OTHER llama unit serves a port, so a new lane cannot be added
    # without landing in the list above.
    local listed
    for u in "$REPO_ROOT"/systemd/llama-*.service; do
        listed=""
        for launcher in "${lanes[@]}"; do
            [[ "${u##*/}" == "$launcher" ]] && listed=1
        done
        [[ -n "$listed" ]] && continue
        grep -q -- '--port' "$u" \
            && { echo "FAIL: ${u##*/} serves a port but is not in the lane list"; return 1; }
    done
    return 0
}

# The launchers are invoked by systemd as ExecStart and by the installed shims as a
# target, so a missing exec bit breaks a LANE START, far from here — the same
# failure the installer's fail-closed check exists to catch.  git records the bit,
# so this is cheap to hold.
@test "gpu-exclusivity: every bin/* entry is executable" {
    local f
    for f in "$REPO_ROOT"/bin/*
    do
        [[ -f "$f" ]] || continue
        [[ -x "$f" ]] || { echo "FAIL: bin/${f##*/} is not executable"; return 1; }
    done
}

# The 2026-09-15 regression: the declared-workload check ran
# `pgrep -f "llama-bench|autotune"`, which matched the CALLER's own command line,
# so the probe answered BUSY and the watchdog took a healthy, serving CUDA lane
# down on a free card.  A false BUSY is not the safe direction — it stops a lane —
# so the patterns must name a real artefact and the probe's own chain is excluded.
@test "gpu-exclusivity: a shell that merely mentions autotune is not a declared workload" {
    printf 'REASONS=()\n' > "$TAC_TEST_TMPDIR/decl.sh"
    awk '/^_self_chain\(\)/,/^}/'          "$REPO_ROOT/bin/gpu-busy.sh" >> "$TAC_TEST_TMPDIR/decl.sh"
    awk '/^_any_foreign_process\(\)/,/^}/' "$REPO_ROOT/bin/gpu-busy.sh" >> "$TAC_TEST_TMPDIR/decl.sh"
    awk '/^declared_workload_busy\(\)/,/^}/' "$REPO_ROOT/bin/gpu-busy.sh" >> "$TAC_TEST_TMPDIR/decl.sh"
    grep -q 'declared_workload_busy' "$TAC_TEST_TMPDIR/decl.sh" || return 1

    cat > "$TAC_TEST_TMPDIR/decl-probe.sh" <<'EOS'
set -uo pipefail
source "$1"
if declared_workload_busy; then echo "BUSY ${REASONS[*]}"; else echo FREE; fi
EOS

    # The calling shell's command line names the bare words the old pattern used.
    run bash -c "bash '$TAC_TEST_TMPDIR/decl-probe.sh' '$TAC_TEST_TMPDIR/decl.sh'  # llama-bench autotune"
    [[ "$output" == "FREE" ]]
}
