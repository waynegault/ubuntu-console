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
#
# Tested with a SYNTHETIC token rather than the real patterns: the first version
# of this test asserted `declared_workload_busy` returned FREE, which is simply
# false while a real re-tune runs — it failed during chunk 3 of the 2026-09-15
# sweep, reporting the truth about the box rather than the mechanism.  The
# mechanism is what needs pinning, and it must not depend on a quiet machine.
@test "gpu-exclusivity: the declared-workload check excludes the caller's own chain" {
    printf 'REASONS=()\n' > "$TAC_TEST_TMPDIR/decl.sh"
    awk '/^_self_chain\(\)/,/^}/'            "$REPO_ROOT/bin/gpu-busy.sh" >> "$TAC_TEST_TMPDIR/decl.sh"
    awk '/^_any_foreign_process\(\)/,/^}/'   "$REPO_ROOT/bin/gpu-busy.sh" >> "$TAC_TEST_TMPDIR/decl.sh"
    grep -q '_any_foreign_process' "$TAC_TEST_TMPDIR/decl.sh" || return 1

    cat > "$TAC_TEST_TMPDIR/chain-probe.sh" <<'EOS'
set -uo pipefail
source "$1"
if _any_foreign_process "$2"; then echo FOREIGN; else echo OWN; fi
EOS

    local tok="tac-chain-probe-$RANDOM$RANDOM"

    # A carrier that is genuinely foreign (spawned by this test, outside the
    # probe's ancestry) must be seen.  It is a shell LOOP, not `bash -c 'sleep 30'
    # "$tok"`: bash execs a single-command -c body, so the token — which was only
    # the shell's $0 — would vanish from the cmdline and the pattern would match
    # nothing.  A loop keeps the shell alive with its argv intact.
    bash -c 'while :; do sleep 1; done' "$tok" &
    local _carrier=$!
    sleep 0.3
    run bash "$TAC_TEST_TMPDIR/chain-probe.sh" "$TAC_TEST_TMPDIR/decl.sh" "$tok"
    [[ "$output" == "FOREIGN" ]]
    kill "$_carrier" 2>/dev/null || true
    wait "$_carrier" 2>/dev/null || true

    # ...and when the only carrier is the CALLER's own command line, it must not be.
    run bash -c "bash '$TAC_TEST_TMPDIR/chain-probe.sh' '$TAC_TEST_TMPDIR/decl.sh' '$tok'  # $tok"
    [[ "$output" == "OWN" ]]
}

# The static half of the same contract: the patterns name an artefact.  This is
# what failed on 2026-09-15 — a bare word matches any shell that mentions it.
@test "gpu-exclusivity: the declared-workload patterns name a path, not a bare word" {
    ! grep -q 'pgrep -f "llama-bench|autotune"' "$REPO_ROOT/bin/gpu-busy.sh"
    grep -q "_any_foreign_process '/(autotune-model|run-autotune-batch|retune-band-chunk)" "$REPO_ROOT/bin/gpu-busy.sh"
    grep -q 'pgrep -x llama-bench' "$REPO_ROOT/bin/gpu-busy.sh"
}

# __llm_proc_is_server replaced `pgrep -f "$LLM_SERVER_PROC_PATTERN"` for every
# "is a llama backend running / is this pid one of ours?" check in the console.
# Real processes, real /proc: the matcher must accept a backend whatever it was
# invoked as, accept the python backend whose exe is the INTERPRETER, and reject
# a process that merely mentions the names in its arguments (that last one is the
# shape that stopped a serving CUDA lane on 2026-09-15).
@test "gpu-exclusivity: a llama backend is identified by exe, not by its command line" {
    awk '/^function __llm_proc_exe/,/^}/'        "$REPO_ROOT/scripts/11c-llm-server.sh" >  "$TAC_TEST_TMPDIR/proc.sh"
    awk '/^function __llm_proc_is_server/,/^}/'  "$REPO_ROOT/scripts/11c-llm-server.sh" >> "$TAC_TEST_TMPDIR/proc.sh"
    grep -q '__llm_proc_is_server' "$TAC_TEST_TMPDIR/proc.sh" || return 1

    cat > "$TAC_TEST_TMPDIR/is-server.sh" <<'EOS'
set -uo pipefail
source "$1"
if __llm_proc_is_server "$2"; then echo LLAMA; else echo NOT; fi
EOS

    # A compiled llama.cpp binary, invoked under its own name.
    cp "$(command -v sleep)" "$TAC_TEST_TMPDIR/llama-server" || skip "cannot copy a binary here"
    "$TAC_TEST_TMPDIR/llama-server" 60 &
    local _backend=$!
    # A backend started through a differently-named LAUNCHER (the legacy symlink
    # shape): exe resolves to the real artefact, so it is still identified.
    ln -s "$TAC_TEST_TMPDIR/llama-server" "$TAC_TEST_TMPDIR/cuda-llama-server"
    "$TAC_TEST_TMPDIR/cuda-llama-server" 60 &
    local _launcher=$!
    python3 -c 'import time; time.sleep(60)' llama_cpp.server &
    local _pybackend=$!
    # Neither of these is a backend: a plain process, and a shell whose ARGUMENTS
    # name the binaries the old command-line pattern matched on.
    sleep 60 &
    local _plain=$!
    bash -c 'sleep 60' llama-server llama-bench cuda-llama-bench &
    local _mentioner=$!

    run bash "$TAC_TEST_TMPDIR/is-server.sh" "$TAC_TEST_TMPDIR/proc.sh" "$_backend"
    [[ "$output" == "LLAMA" ]]
    run bash "$TAC_TEST_TMPDIR/is-server.sh" "$TAC_TEST_TMPDIR/proc.sh" "$_launcher"
    [[ "$output" == "LLAMA" ]]
    run bash "$TAC_TEST_TMPDIR/is-server.sh" "$TAC_TEST_TMPDIR/proc.sh" "$_pybackend"
    [[ "$output" == "LLAMA" ]]
    run bash "$TAC_TEST_TMPDIR/is-server.sh" "$TAC_TEST_TMPDIR/proc.sh" "$_plain"
    [[ "$output" == "NOT" ]]
    run bash "$TAC_TEST_TMPDIR/is-server.sh" "$TAC_TEST_TMPDIR/proc.sh" "$_mentioner"
    [[ "$output" == "NOT" ]]

    kill "$_backend" "$_launcher" "$_pybackend" "$_plain" "$_mentioner" 2>/dev/null || true
}

# retune-band-chunk.sh stops the CUDA lane itself before handing the card to the
# bench (the suspension file alone leaves it up until the watchdog's next 300s
# tick, and the batch's drain never evicts a systemd unit's server — chunk 2 of
# the 2026-09-15 re-tune burned two rows on exactly that).  It therefore names the
# lane a second time, and the two names must be the one unit.
@test "gpu-exclusivity: the re-tune wrapper and the watchdog name the same CUDA lane" {
    local from_wrapper from_watchdog
    from_wrapper=$(sed -nE 's/.*LLAMA_CUDA_LANE_UNIT:-([^}]*)\}.*/\1/p' "$REPO_ROOT/scripts/retune-band-chunk.sh")
    from_watchdog=$(sed -nE 's/^CUDA_UNIT="([^"]*)".*/\1/p' "$REPO_ROOT/bin/llama-watchdog.sh")
    [[ -n "$from_wrapper" && -n "$from_watchdog" ]] \
        || { echo "FAIL: could not read a lane name (wrapper='$from_wrapper' watchdog='$from_watchdog')"; return 1; }
    [[ "${from_wrapper%.service}" == "$from_watchdog" ]] \
        || { echo "drifted: wrapper '${from_wrapper%.service}' vs watchdog '$from_watchdog'"; return 1; }
}

# run-autotune-batch.sh's footer is where a failed row used to disappear: it sliced
# the remaining list from COUNT, so rows that FAILED were dropped from the resume
# line (chunk 2 of the 2026-09-15 re-tune printed "remaining models: 18 27" while 5
# and 7 had failed and still needed doing), and the batch exited 0 on a 2-of-2
# failure, which read as progress.  The footer reads global state, not arguments, so
# its contract can be exercised without a GPU.
@test "gpu-exclusivity: a failed row stays in the resume list, and certifying nothing is not exit 0" {
    awk '/^__rab_footer\(\)/,/^}/' "$REPO_ROOT/scripts/run-autotune-batch.sh" > "$TAC_TEST_TMPDIR/footer.sh"
    grep -q '__rab_footer' "$TAC_TEST_TMPDIR/footer.sh" || return 1

    cat > "$TAC_TEST_TMPDIR/footer-probe.sh" <<'EOS'
set -uo pipefail
source "$1"
case "$2" in
    failures) MODEL_ARRAY=(5 7 18 27); COUNT=2; TOTAL=4; TUNED_COUNT=0; FAILED_ROWS=(5 7) ;;
    clean)    MODEL_ARRAY=(1 5);       COUNT=1; TOTAL=2; TUNED_COUNT=1; FAILED_ROWS=() ;;
    allfail)  MODEL_ARRAY=(5 7);       COUNT=2; TOTAL=2; TUNED_COUNT=0; FAILED_ROWS=(5 7) ;;
    budget)   MODEL_ARRAY=(5 7);       COUNT=1; TOTAL=2; TUNED_COUNT=0; FAILED_ROWS=(5); HALT_EXIT=3 ;;
esac
__rab_footer "halt" 0
echo "RC=$?"
echo "REMAINING=${REMAINING[*]:-}"
EOS

    # Both failed rows are owed a run, and they must come back in the resume list.
    run bash "$TAC_TEST_TMPDIR/footer-probe.sh" "$TAC_TEST_TMPDIR/footer.sh" failures
    [[ "$output" == *"REMAINING=5 7 18 27"* ]]
    [[ "$output" == *"RC=1"* ]]

    # A chunk-cap halt after one good row is a clean exit.
    run bash "$TAC_TEST_TMPDIR/footer-probe.sh" "$TAC_TEST_TMPDIR/footer.sh" clean
    [[ "$output" == *"REMAINING=5"* ]]
    [[ "$output" == *"RC=0"* ]]

    # Every row failed: non-zero, and nothing is dropped from the resume list.
    run bash "$TAC_TEST_TMPDIR/footer-probe.sh" "$TAC_TEST_TMPDIR/footer.sh" allfail
    [[ "$output" == *"REMAINING=5 7"* ]]
    [[ "$output" == *"RC=1"* ]]

    # Stopped for the ADAPTER: exit 3, which outranks the failed row beside it.
    # docs/llm.md states this as a contract shared with autotune-model.sh, and the
    # batch used to have no exit 3 at all.
    run bash "$TAC_TEST_TMPDIR/footer-probe.sh" "$TAC_TEST_TMPDIR/footer.sh" budget
    [[ "$output" == *"RC=3"* ]]
    [[ "$output" == *"REMAINING=5 7"* ]]
}

# The dxgkrnl EOVERFLOW count WARNS, it does not halt (Wayne, 2026-09-15).  It
# tracks host state rather than this batch's activity — 22 events at 18 cycles on
# one boot, 4 events at 20 cycles on the next — so gating on it halted a chunk
# while measuring nothing, at the cost of a WSL restart per row.  The batch's own
# corroboration is MAX_CONSECUTIVE_FAILURES.  Pinned statically because the
# behaviour is "do not halt", which no output assertion can capture directly.
@test "autotune: the dxg health count warns, it does not halt the batch" {
    ! grep -q 'check_wsl_gpu_health' "$REPO_ROOT/scripts/run-autotune-batch.sh"
    grep -q 'wsl_gpu_health_suspect' "$REPO_ROOT/scripts/run-autotune-batch.sh"
    # ...and it must not be a halt reason any more.
    ! grep -qE 'HALT_REASON=.*(degrad|paravirtuali)' "$REPO_ROOT/scripts/run-autotune-batch.sh"
    # The hard stops that remain:
    grep -q 'CONSECUTIVE_FAILURES >= MAX_CONSECUTIVE_FAILURES' "$REPO_ROOT/scripts/run-autotune-batch.sh"
    grep -q 'CUDA_CYCLE_BUDGET' "$REPO_ROOT/scripts/run-autotune-batch.sh"
}

# Signal 2 of gpu-busy.sh identified a resident by the NAME "llama-server" — via
# comm or cmdline — so a process that merely MENTIONED the string was treated as
# ours, and so was a real server from any other build path.  gpu-busy.sh is the
# CUDA lane's start gate, so reading a foreign resident as "ours" reads the card as
# FREE and the watchdog may then put a second server on it — the exact failure the
# card-discipline section exists to prevent.  It now keys on /proc/PID/exe resolved
# against the two sanctioned binaries, the same discriminator the repo settled on
# for the `so` probe.
#
# These drive the extracted foreign_apps_busy() with a stub nvidia-smi, so nothing
# touches the GPU and the "server" is a copy of sleep carrying the right name.
_foreign_apps_fixture() {
    mkdir -p "$TAC_TEST_TMPDIR/bin" "$TAC_TEST_TMPDIR/allowed" "$TAC_TEST_TMPDIR/other"
    # Stand-ins for the two builds: the same binary NAME at different paths — the
    # case a name-based match cannot separate.
    cp "$(command -v sleep)" "$TAC_TEST_TMPDIR/allowed/llama-server"
    cp "$(command -v sleep)" "$TAC_TEST_TMPDIR/other/llama-server"

    cat > "$TAC_TEST_TMPDIR/bin/nvidia-smi" <<'EOS'
#!/usr/bin/env bash
case "$*" in
    *--query-compute-apps*) printf '%s\n' "${STUB_SMI_PIDS:-}" ;;
    *) printf '0\n' ;;
esac
EOS
    chmod +x "$TAC_TEST_TMPDIR/bin/nvidia-smi"

    printf 'REASONS=()\n' > "$TAC_TEST_TMPDIR/fab.sh"
    awk '/^foreign_apps_busy\(\)/,/^}/' "$REPO_ROOT/bin/gpu-busy.sh" >> "$TAC_TEST_TMPDIR/fab.sh"
    grep -q 'foreign_apps_busy' "$TAC_TEST_TMPDIR/fab.sh"

    cat > "$TAC_TEST_TMPDIR/fab-probe.sh" <<'EOS'
set -uo pipefail
source "$1"
if foreign_apps_busy; then echo "BUSY ${REASONS[*]}"; else echo FREE; fi
EOS
}

@test "gpu-exclusivity: a same-named server from another build path is FOREIGN" {
    _foreign_apps_fixture
    "$TAC_TEST_TMPDIR/other/llama-server" 30 &
    local spid=$!
    run env PATH="$TAC_TEST_TMPDIR/bin:$PATH" \
        LLAMA_CUDA_SERVER_BIN="$TAC_TEST_TMPDIR/allowed/llama-server" \
        LLAMA_XE_SERVER_BIN="$TAC_TEST_TMPDIR/absent/llama-server" \
        STUB_SMI_PIDS="$spid" \
        bash "$TAC_TEST_TMPDIR/fab-probe.sh" "$TAC_TEST_TMPDIR/fab.sh"
    kill "$spid" 2>/dev/null || true
    [[ "$output" == BUSY*"foreign-app pid=$spid"* ]] \
        || { echo "expected BUSY for $spid, got: $output"; return 1; }
    [[ "$output" == *"exe=$TAC_TEST_TMPDIR/other/llama-server"* ]] \
        || { echo "reason did not name the exe: $output"; return 1; }
}

@test "gpu-exclusivity: the sanctioned CUDA binary is skipped, not reported" {
    _foreign_apps_fixture
    "$TAC_TEST_TMPDIR/allowed/llama-server" 30 &
    local spid=$!
    run env PATH="$TAC_TEST_TMPDIR/bin:$PATH" \
        LLAMA_CUDA_SERVER_BIN="$TAC_TEST_TMPDIR/allowed/llama-server" \
        LLAMA_XE_SERVER_BIN="$TAC_TEST_TMPDIR/absent/llama-server" \
        STUB_SMI_PIDS="$spid" \
        bash "$TAC_TEST_TMPDIR/fab-probe.sh" "$TAC_TEST_TMPDIR/fab.sh"
    kill "$spid" 2>/dev/null || true
    [[ "$output" == "FREE" ]] || { echo "expected FREE, got: $output"; return 1; }
}

@test "gpu-exclusivity: a mere mention of llama-server in argv is FOREIGN" {
    _foreign_apps_fixture
    # argv[0] is "llama-server" but the executable is sleep. The old comm/cmdline
    # match skipped precisely this, which is how a mention hid a real resident.
    bash -c 'exec -a llama-server sleep 30' &
    local spid=$!
    run env PATH="$TAC_TEST_TMPDIR/bin:$PATH" \
        LLAMA_CUDA_SERVER_BIN="$TAC_TEST_TMPDIR/allowed/llama-server" \
        LLAMA_XE_SERVER_BIN="$TAC_TEST_TMPDIR/absent/llama-server" \
        STUB_SMI_PIDS="$spid" \
        bash "$TAC_TEST_TMPDIR/fab-probe.sh" "$TAC_TEST_TMPDIR/fab.sh"
    kill "$spid" 2>/dev/null || true
    [[ "$output" == BUSY*"foreign-app pid=$spid"* ]] \
        || { echo "a mention must not hide a resident, got: $output"; return 1; }
}

@test "gpu-exclusivity: signal 2 matches on exe, and keeps the embedding-worker exception" {
    ! grep -q '\*llama-server\*) continue' "$REPO_ROOT/bin/gpu-busy.sh"
    grep -q 'readlink -f "/proc/\$pid/exe"' "$REPO_ROOT/bin/gpu-busy.sh"
    grep -q 'LLAMA_CUDA_SERVER_BIN' "$REPO_ROOT/bin/gpu-busy.sh"
    grep -q 'LLAMA_XE_SERVER_BIN' "$REPO_ROOT/bin/gpu-busy.sh"
    grep -q 'memory-core-local-embedding-worker' "$REPO_ROOT/bin/gpu-busy.sh"
}
