#!/usr/bin/env bash
# gpu-busy.sh — reliable "CUDA card actually in use" detector for local-llm gating.
# Version: 1.13.0 (2026-11-09: the verdict now names WHICH ARM fired and which arms ran
#          before it (card 62fbc8cb, criterion (b) as Wayne ruled). The card asked for
#          "positive evidence of a DECLARED workload before a busy stop", and that cannot
#          be implemented as written: busy() is a short-circuiting OR and
#          declared_workload_busy is arm 5 of 6, so when utilisation_arm is reached "no
#          declared workload" is true BY CONSTRUCTION. Disabling the arm would have been
#          the only literal reading, so the requirement is met by RECORD instead: every
#          verdict carries arm=<the one that answered busy, or none> and
#          checked=<the arms that ran, in order>. Measured 03:23:27 and again 18:01Z: a
#          stop on `util-suppressed:92%>=15%` left a reader unable to tell whether the
#          five prior arms had run at all — the reason named the reading we declined to
#          act on, never that a declared workload had been looked for and not found.
#          Additive: `reasons` keeps its position and shape, so every consumer and every
#          existing test still reads it the same way.
# Version: 1.12.0 (2026-11-08: the serving check asks EVERY CUDA lane on the card, not one
#          port.  Measured 03:23:27 (card 62fbc8cb) — `util=91%>=15%` was the only reason
#          recorded while the CHAT lane was idle and the EMBEDDING lane on the SAME card
#          (:18080) was working, so both suppressions failed, utilisation alone decided, and
#          the watchdog stopped the chat lane mid-call — the Memory Dreaming narrative riding
#          on it died with it.  Arm 2 asked only SANCTIONED_LANE_PORT (:18087).  The ports now
#          come from each RUNNING `llama-cuda-*` unit's own ExecStart, so a lane added or
#          renumbered is covered without editing a list — the listed-scope defect this card
#          names.  Fail-closed direction unchanged: an unreadable unit listing contributes
#          nothing and the configured port is always asked, so the worst case is exactly
#          1.11.0's single-port behaviour.
# Version: 1.11.0 (2026-11-06: the busy line now CARRIES the match, not just its class.
#          `declared:<class>` stays the first token, so every existing consumer and test
#          keeps working; it continues `pid=… rule=exe|argv-after:<interp> argv=<one line>`.
#          Recorded because the 2026-11-04 12:35:56 stop [probe: declared:autotune] was
#          CORRECT and still unattributable afterwards: the class alone cannot separate a real
#          autotune from a test or lint invocation that merely NAMES the script, and the
#          process had exited before anyone looked.  Instrumentation only — WHICH processes
#          answer busy is unchanged (1.10.0's harness suppression still decides that); this
#          records the pid, the rule that matched and the argv it matched on, sanitised and
#          cut to 160 chars + '...' so it stays one journal line.  See _attr_argv.
# Version: 1.10.0 (2026-11-04: a benchmark a TEST HARNESS started is no longer a declared
#          workload. tests/unit/08-autotune-workload.bats executes the repo's own
#          scripts/autotune-model.sh at its real path, so the probe answered correctly and the
#          watchdog stopped the fleet's default CUDA lane to serve a unit test — 14:02:56Z from a
#          local bats loop, 14:09:53Z from a VS Code bats run (bats-exec-suite <- timeout 400 bats
#          <- the qwen-code companion). _under_test_harness walks the declared workload's ancestry
#          and suppresses the match, appending suppressed:test-harness so the suppression is
#          visible rather than reading like a probe that found nothing. The script is real; the
#          intent is a test. Version 1.9.2 (2026-11-02: docs/inspection.md §18.3 9.5 — SANCTIONED_LANE_PORT sat
#          between the doc comment and sanctioned_lane_serving(), so the function counted
#          as "no comment directly above" and raised the ratchet by one. Moved the
#          assignment above the comment block. No behaviour change; measured 9.5 122->121.
# Version: 1.9.1 (2026-11-02: a FREE answer now says WHY it is free. Recorded by Rook
#          from the committed source: every append to REASONS sat on a busy path and
#          emit() prints only REASONS, so the state the 00:13:53 stop was made in —
#          empty residency read, high utilisation, our own lane serving — answered
#          `reasons=none`, byte-identical to an idle card. The safety half of 1.9.0
#          worked; the RECORD could not, and the anomaly that was worth an alarm had no
#          trace at all.
#          Additive, free-path only, and it can never add a stop: utilisation is read
#          (util_peak) but its REASONS entry is appended only after the arm has already
#          answered FREE. Two labels, because they answer different questions:
#            cannot-attribute:residency-empty  — nvidia-smi listed no compute app, so a
#                                                high utilisation cannot be attributed to
#                                                a named resident (the tri-state that
#                                                sanctioned_residents_only still cannot
#                                                express: a bare non-empty test returns 1
#                                                for "empty" and "foreign" alike)
#            lane-serving                      — the lane's own gauge said >=1 request
#          plus util-suppressed=<n>%>=<thr>% naming the reading we chose not to act on.
# Version: 1.9.0 (2026-11-02: an empty residency read plus a SERVING lane is us, not a
#          foreign workload. Measured 00:13:53 — `util=90%>=15%` was the recorded reason,
#          and because busy() is a short-circuiting OR that is proof all five prior signals
#          were false, including both residency probes. The lane was mid-prefill on a 45k
#          prompt, so the utilisation WAS the lane's own work; the watchdog stopped it and
#          the client turns died behind it. sanctioned_residents_only() cannot separate
#          "residents listed, all sanctioned" from "the list is empty / unreadable" — the
#          bare non-empty test returns 1 for both — so the empty arm handed the decision to
#          utilisation. Reversal of the fail-closed direction: stopping is the destructive
#          act and needs positive evidence of a foreign owner, so the last arm now asks the
#          LANE ITSELF. `llamacpp:requests_processing` is a gauge the server publishes
#          (verified live on :18088), so "we are serving" is a statement from the process
#          rather than an inference from device state. Any read failure answers "not
#          serving", which leaves the old fail-closed behaviour intact.
# Version: 1.8.0 (2026-11-01: a resident that cannot be a GPU workload is not a tenant.
#          Measured 19:22:01 — a VS Code pytest run in another workspace
#          (…/investigator/.venv/bin/python … run_pytest_script.py) imported torch, which
#          opens /dev/dxg, so WSL nvidia-smi listed its pid as a compute app with
#          `used_gpu_memory [N/A]` and no device memory. The probe called it foreign-app and
#          llama-watchdog STOPPED llama-cuda-qwen3coder-30b-chat mid-request (task 11693, an
#          81k-token prompt in flight), then SIGKILLed it after a stop-sigterm timeout —
#          Result=timeout, port 18087 dead and the default model lane gone.
#          The class is now stated ONCE, in _is_non_gpu_resident(), and read by BOTH
#          foreign_apps_busy() and sanctioned_residents_only(): exempting it from the foreign
#          probe alone would not have saved the lane, because the same resident also stopped
#          sanctioned_residents_only() from suppressing the utilisation heuristic, and a
#          serving server pins util far past the 15% threshold.
# Version: 1.5.0 (2026-09-21: the declared-workload check proves the artefact is
#          being EXECUTED, not merely NAMED — identity from /proc/PID/exe (or comm
#          when exe is another user's and unreadable), plus an argv element that is
#          a path to the file.  The pattern still selects candidates, so the file
#          name travels with every call.  Before this, `pgrep -f` alone counted a
#          `cat /usr/local/bin/clear_vram.sh` in an operator's own shell as a
#          declared workload and the watchdog stopped a serving CUDA lane on a free
#          card — the third variant of the same command-line-mention defect, after
#          1.4.0 (signal 2) and 1.3.0 (the patterns themselves))
# Version: 1.5.0 (2026-10-23: utilisation no longer counts when EVERY compute-app
#          resident is a sanctioned server binary. A serving llama-server pins the
#          card far past UTIL_THRESHOLD, so the probe answered BUSY about the CUDA
#          lane's OWN generation and the watchdog stopped a healthy lane mid-request
#          (02:34 and 08:18 that day, each time after the lane had just been
#          restarted). Signal order also changed: definitive ownership evidence
#          (training, lock, cuda owner, foreign app, declared workload) is now asked
#          BEFORE the utilisation heuristic, because the OR-chain short-circuits and
#          util-first used to mask the answer that explained the busy correctly)
# Version: 1.4.0 (2026-09-16: signal 2 identifies a resident by its /proc/PID/exe
#          resolved against the sanctioned CUDA/Xe binaries, instead of by the
#          NAME "llama-server" — which any process that merely MENTIONS the string
#          could satisfy, so a stray server from another build path was read as
#          ours and the card looked free)
# Version: 1.3.0 (2026-09-15: the declared-workload patterns name real artefacts
#          instead of bare words, and this probe's own process chain is excluded —
#          a shell that merely mentioned "autotune" was read as a bench and the
#          watchdog took a healthy CUDA lane down)
# Version: 1.6.0 (2026-09-26: a TRAINING tenant is a declared class.  A training run
#          that registers through bin/train-timeout-runner.sh holds the bench lock AND
#          is a CUDA resident, so before this the foreign-app probe named it "an unknown
#          app holds the card" - the distinction card UBC-GRPO-001 exists for.  Matched
#          on the EXECUTING artefact, never on a word like "grpo" or "unsloth": the
#          false-BUSY regressions recorded below are exactly that mistake, and a false
#          BUSY stops a serving lane.)
# Module Version: 22
#   v21 (2026-11-08): the serving check asks every CUDA lane on the card (card 62fbc8cb) —
#     see the 1.12.0 entry at the top of this file.  No other behaviour changes.
#   v20 (2026-11-06): the declared reason is assembled in a variable instead of one
#     123-character array element (18.3 8.1.8).  NOT done by splitting the element across two
#     lines: inside arr=( ... ) a newline SEPARATES words, so that split produced two elements and
#     the reason read "rule=argv-after:bash  argv=" - caught by tests/unit/82 case 1.
# Version: 1.7.1 (2026-11-02: comment-only. The `# swallow-ok:` reason for the ldconfig
#          probe moved from the END of the code line to the line directly above it: the
#          marker is 180 characters of rationale riding on a non-comment line, so §18.3
#          counter 8.1.8 charged it as a line over 120 chars and rose 285 -> 286. The
#          classifier accepts the marker only on its own line or the line DIRECTLY above
#          (a three-line block above does not classify - measured), so it is last.
# Version: 1.7.0 (2026-10-16: `_process_executes` requires the named artefact to be the
#          SCRIPT the interpreter was GIVEN — the argv element immediately after an
#          interpreter — not any element that merely names it.  A CI lint job's file list
#          (`bash tools/lint.sh --files … bin/train-timeout-runner.sh …`) arrives as
#          separate argv elements and was read as a training TENANT, halting an autotune
#          after 9 s on a card reading 0 MiB.  Same rule as 11d-llm-gpu.sh.)
# AI INSTRUCTION: After any code change, increment the Version value in this file.
#
# CARD DISCIPLINE: this script is about the CUDA card only.  The Xe card is a
# different card with its own lanes (xe-llama-server :18081, xe-llama-embed
# :18080) and its own lifecycle.  Nothing here says anything about the Xe card,
# and nothing here should ever gate or stop an Xe lane.
#
# A single nvidia-smi snapshot is NOT reliable (utilization reads 0% between
# tokens; a bench can be idle for seconds between model loads). VRAM footprint
# alone is NOT reliable either (llama-server always holds ~3.8GB of the 4GB
# card). So we combine five signals; ANY true => CUDA card BUSY:
#
#   1. Utilization samples — max over N samples exceeds threshold (actually computing).
#      Asked LAST, and only when the card's compute apps are not exclusively the two
#      sanctioned servers (see sanctioned_residents_only()) AND the CUDA lane itself is
#      not processing a request (see sanctioned_lane_serving()): a serving server pins
#      utilisation far past the threshold, and an empty residency read plus a serving
#      lane is our own work, not a foreign workload.
#   2. Foreign compute-app PIDs — a resident whose /proc/PID/exe is not one of the
#      two sanctioned llama-server binaries holds a CUDA context (someone else is
#      loaded on the GPU).  Both are allowed: the Xe binary is ours, and the Xe
#      lane must go on serving whether or not CUDA is clear.
#   3. Declared GPU workloads — a known GPU-hungry artefact is being EXECUTED
#      (model_selection_bench, autotune, llama-bench, clear_vram, and the TRAINING
#      runner).  Read as "executed", never as "named": the identity is the running
#      executable, so a reader (cat/grep/less/tail) that merely mentions the file
#      does not count.  A false BUSY is not the safe direction here — it stops the
#      lane.  The training class is probed FIRST (see busy()): a registered training
#      run is a CUDA resident too, so the foreign-app probe would otherwise report
#      "an unknown app holds the card" about a tenant that registered as a bench does.
#   4. Lock files — /tmp/llm-bench.lock (bench/autotune convention; watchdog
#      already honours it)
#   5. Another agent's ownership lock (the investigator pipeline's flock).  Signal
#      2 CANNOT see it: their bench server and our own CUDA lane are the SAME
#      binary (llama.cpp/build/bin/llama-server), so a name-based foreign-app
#      check mistakes one for the other.  The flock is the only reliable
#      discriminator, and honouring it is what keeps ONE LLM on the card.
#
# Exit: 0 = GPU FREE (safe to run local LLM), 1 = GPU BUSY.
# --json : print {"busy":true,"reasons":[...]} (exit code still set).
# --wait SECONDS : poll until free or timeout; exit 0 free, 1 still busy, 2 error.
# Env: GPU_BUSY_UTIL_THRESHOLD (default 15 %), GPU_BUSY_SAMPLES (default 5),
#      GPU_BUSY_SAMPLE_INTERVAL (default 0.5 s), GPU_BUSY_LOG (default none)
set -u

UTIL_THRESHOLD="${GPU_BUSY_UTIL_THRESHOLD:-15}"
SAMPLES="${GPU_BUSY_SAMPLES:-2}"
SAMPLE_INTERVAL="${GPU_BUSY_SAMPLE_INTERVAL:-1.5}"
BENCH_LOCK="${LLM_BENCH_LOCK_FILE:-/tmp/llm-bench.lock}"
LOG_FILE="${GPU_BUSY_LOG:-}"

# log lives in the shared bin library (one definition, every bin/ caller).  This
# script appends to $LOG_FILE (and emits nothing while it is empty) with the
# gpu-busy tag and ISO-8601 seconds — all stated here so the output stays
# byte-identical.  Sourced by realpath so the ~/.local/bin shim that execs this
# file and the repo path both resolve.
TAC_LOG_TAG="gpu-busy"
export TAC_LOG_TAG
TAC_LOG_DATE="-Iseconds"
export TAC_LOG_DATE
TAC_LOG_TO_FILE=1
export TAC_LOG_TO_FILE
TAC_LOG_FILE="$LOG_FILE"
export TAC_LOG_FILE
# shellcheck source=_tac-bin-lib.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/_tac-bin-lib.sh"

REASONS=()

# libcuda resolution (v1.9.2).  nvidia-smi has NO link-time libcuda dependency -- it
# dlopens it at runtime -- so it obeys ldconfig order.  A native libnvidia-compute-595
# package (landed 2026-11-02 11:39 with nvidia-cuda-toolkit) put
# /usr/lib/aarch64-linux-gnu/libcuda.so.1 FIRST and the WSL copy second, so EVERY
# nvidia-smi answered rc=9 "couldn't communicate with the NVIDIA driver" while the
# same card was prefilling a 76,235-token request on :18087.  Measured in the same
# minute: bare -> rc=9; LD_LIBRARY_PATH=/usr/lib/wsl/lib -> "GPU 0: NVIDIA RTX Spark
# N1X".  The card never stopped working; the probe resolved the wrong libcuda, and a
# broken probe that reports "GPU unavailable" is indistinguishable from a dead GPU.
#
# Prepending the WSL driver dir restores the resolution the launcher already relies on
# (llama-server is started with LD_LIBRARY_PATH=/usr/lib/wsl/lib for the same reason).
# This is deliberately a PATH preference and not a package removal: the native
# libnvidia-compute-* packages belong to whoever installed the toolkit, and removing
# them is their decision.  Any existing LD_LIBRARY_PATH is kept, so a caller that has
# already chosen a driver still wins over this default.
WSL_CUDA_LIB_DIR="/usr/lib/wsl/lib"
if [[ -e "$WSL_CUDA_LIB_DIR/libcuda.so.1" ]]; then
    export LD_LIBRARY_PATH="${WSL_CUDA_LIB_DIR}${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
fi

# libcuda_shadowed -- echo the path of a native libcuda.so.1 that ldconfig resolves
# BEFORE the WSL one, or nothing.  Read-only, and used only to explain a failed probe:
# it answers "is the driver actually broken, or is the resolver pointing elsewhere?".
libcuda_shadowed() {
    local line
    # An unreadable ldconfig cache returns empty, which reads "nothing shadows WSL"
    # -- the conservative direction, since the probe itself already prefers the WSL dir.
    # swallow-ok: an unreadable cache reads "nothing shadows WSL", the conservative direction
    line=$(ldconfig -p 2>/dev/null | awk '/libcuda\.so\.1 /{print $NF; exit}')
    [[ -z "$line" ]] && return 0
    [[ "$line" == "$WSL_CUDA_LIB_DIR"/* ]] && return 0
    printf '%s' "$line"
}

# Free-path record (v1.9.1). Set by the probes that can answer "not attributable" and
# read only by utilisation_arm() AFTER it has decided the card is free, so neither can
# ever contribute to a stop.
RESIDENCY_EMPTY=0   # nvidia-smi listed no compute app at all
LANE_SERVING=0      # some sanctioned lane on this card answered >=1 processing request
LANE_SERVING_PORT=""  # WHICH lane answered — the audit line names it, not just "a lane"
# Which arm answered BUSY, and which arms ran before it. Empty ARM on the free path, by
# design: "no arm fired" is a reading, and an empty string says so without inventing one.
ARM=""
ARMS_RUN=()
SANCTIONED_LANE_PORT="${LLAMA_CUDA_LANE_PORT:-18087}"

# _sanctioned_lane_ports -- echo the port of every RUNNING CUDA lane on this card,
# derived from the units rather than listed here.
#
# One port was not enough (2026-11-08 03:23:27, card 62fbc8cb).  The serving check
# asked :18087 only, the CHAT lane; it was idle while the EMBEDDING lane on the same
# card (:18080) was working, so the arm answered "not serving", utilisation alone
# decided BUSY, and the watchdog stopped a lane that was not the one using the card —
# taking the narrative call riding on it with it.  A hand-written port list would
# repeat that defect the first time a lane is added or renumbered, so each unit's own
# ExecStart is the source.  `llama-cuda-*` is scoped to THIS card: the CPU and Xe
# tiers are different devices, and asking their ports could suppress a stop for a
# foreign tenant of this one.
#
# Always prints the configured port first, so an unreadable unit listing (no systemd
# user manager, a stub in a test, a lane not yet installed) degrades to exactly the
# single-port behaviour this replaces — the fail-closed direction is unchanged.
_sanctioned_lane_ports() {
    local _u _p _units
    printf '%s\n' "$SANCTIONED_LANE_PORT"
    # swallow-ok: no user manager -> no derived ports, never an abort
    _units=$(systemctl --user list-units --type=service --state=running 'llama-cuda-*' \
                 --no-legend 2>/dev/null | awk '{print $1}')
    while IFS= read -r _u; do
        [[ -n "$_u" ]] || continue
        # swallow-ok: an unreadable unit yields no port, and the configured port is still asked
        _p=$(systemctl --user show -p ExecStart --value "$_u" 2>/dev/null \
             | sed -n 's/.*--port[= ]\([0-9]\{1,5\}\).*/\1/p' | head -1)
        [[ "$_p" =~ ^[0-9]+$ ]] && printf '%s\n' "$_p"
    done <<< "$_units"
}

# sanctioned_lane_serving -- 0 when ANY sanctioned CUDA lane on this card is processing
# a request right now.  Asked only from the utilisation arm, where the residency read
# already failed to name a resident: without this, a serving lane's own prefill is the
# evidence used to stop it (2026-11-02 00:13:53).
#
# The signal is read from the SERVER, not from the device: llama-server publishes
# `llamacpp:requests_processing` when started with --metrics (verified live on the
# CPU lane :18088 on 2026-11-02, gauge present at 0 while idle).  A server that is
# mid-prefill reports >=1 for the whole request, which is exactly the window the
# 00:13:53 stop landed in.
#
# Every lane is asked, not just the one this probe grew up around: the card is shared,
# so "the chat lane is idle" says nothing about whether OUR work is what the card is
# busy with.  The set comes from _sanctioned_lane_ports(), never from a list here.
#
# Fail-closed is preserved in the direction that matters: an unreachable or
# unparseable metric answers "not serving" for that lane, so utilisation still decides
# BUSY the way it always did.  This function can only ever REMOVE a stop, never add one.
sanctioned_lane_serving() {
    local out n port
    LANE_SERVING=0
    LANE_SERVING_PORT=""
    while IFS= read -r port; do
        [[ "$port" =~ ^[0-9]+$ ]] || continue
        # swallow-ok: an unreachable lane is "not serving", which leaves utilisation deciding
        out=$(curl -s --max-time 2 "http://127.0.0.1:${port}/metrics" 2>/dev/null) || continue
        [[ -n "$out" ]] || continue
        n=$(awk '$1 == "llamacpp:requests_processing" {print $2; exit}' <<<"$out")
        [[ "$n" =~ ^[0-9]+$ ]] || continue
        (( n > 0 )) || continue
        # Recorded for the free-path audit line only; the return value alone decides.
        LANE_SERVING=1
        LANE_SERVING_PORT="$port"
        return 0
    done < <(_sanctioned_lane_ports)
    return 1
}

# util_peak — echo the highest utilisation reading, 1 when the probe failed.
# Deliberately records NOTHING: the caller decides whether a reading becomes a reason.
# Splitting it out is what lets the suppression path PRINT a reading it declined to
# act on, without a second sampling loop and without the risk of a read that appends
# to REASONS by itself.
util_peak() {
    local max_util=0 s out rc
    for _ in $(seq 1 "$SAMPLES"); do
        out=$(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>/dev/null); rc=$?
        # While the driver is unavailable every sample is a *crashing* nvidia-smi, and
        # each crash makes WSL capture a core dump (kernel-log noise + jitter). One
        # failed probe is enough proof they will all fail: stop sampling and let
        # foreign_apps_busy() fail closed with reason nvidia-smi-unavailable.
        (( rc != 0 )) && return 1
        s=$(tr -dc '0-9' <<<"$out")
        [[ -z "$s" ]] && s=0
        (( s > max_util )) && max_util=$s
        # Above the threshold the exact peak no longer matters: every caller compares
        # against the threshold, so returning here keeps the probe as fast as before.
        (( s >= UTIL_THRESHOLD )) && { printf '%s\n' "$s"; return 0; }
        sleep "$SAMPLE_INTERVAL"
    done
    printf '%s\n' "$max_util"
    return 0
}

util_busy() {
    local m
    m=$(util_peak) || return 1
    [[ "$m" =~ ^[0-9]+$ ]] || return 1
    (( m >= UTIL_THRESHOLD )) || return 1
    REASONS+=("util=${m}%>=${UTIL_THRESHOLD}%")
    ARM="utilisation"
    return 0
}

# The last arm of busy(), and the only one that can answer FREE while the card is
# busy. Two suppressions, both of which MUST be recorded on the free path (v1.9.1):
#   * every compute-app resident is a sanctioned server, so the utilisation is our own
#     lane's work; or
#   * a sanctioned lane on this card reports a request in flight, so the utilisation is
#     our own work — WHICH lane is named, since "some lane was serving" was not enough
#     to read the 2026-11-08 03:23:27 stop afterwards (v1.12.0).
# A quiet card records nothing: with utilisation below the threshold there is nothing
# to attribute and an annotation would be noise on every idle poll.
utilisation_arm() {
    ARMS_RUN+=("utilisation")
    local m
    if sanctioned_residents_only; then
        :
    elif sanctioned_lane_serving; then
        :
    else
        util_busy
        return
    fi
    # Suppressed: read the utilisation we are declining to act on. A failed probe here
    # is not a reason to stop either — this arm can only ever answer FREE.
    m=$(util_peak) || return 1
    [[ "$m" =~ ^[0-9]+$ ]] || return 1
    (( m >= UTIL_THRESHOLD )) || return 1
    (( RESIDENCY_EMPTY )) && REASONS+=("cannot-attribute:residency-empty")
    (( LANE_SERVING )) && REASONS+=("lane-serving:${LANE_SERVING_PORT}")
    REASONS+=("util-suppressed:${m}%>=${UTIL_THRESHOLD}%")
    return 1
}

# The sanctioned server binaries, resolved to real paths.  One definition for the
# foreign-app probe and the utilisation gate, so the two can never disagree about
# which residents are OURS.
_sanctioned_exes() {
    local _a _cuda
    # Name the CUDA tree that EXISTS, not the one this probe was written against.
    # Measured 2026-11-02 12:55Z: the serving lane runs
    # /home/wayne/llama.cpp/build-cuda/bin/llama-server while this default still said
    # build/bin, so the lane's OWN resident failed _is_sanctioned_exe and the probe
    # answered BUSY "foreign-app exe=…/build-cuda/bin/llama-server" about the server it
    # was protecting.  A false BUSY is the dangerous direction here — it takes the lane
    # down — and this file states that two hundred lines further up.
    #
    # scripts/01-constants.sh already resolved this on 2026-11-01 (build/ held nothing
    # while build-cuda/ served the card).  This probe is standalone by design and
    # therefore carries a copy; the copy had drifted from the decision.  Preferring the
    # existing tree keeps the copy honest without importing the console.
    _cuda="${LLAMA_CUDA_SERVER_BIN:-}"
    if [[ -z "$_cuda" ]]; then
        _cuda="$HOME/llama.cpp/build-cuda/bin/llama-server"
        [[ -x "$_cuda" ]] || _cuda="$HOME/llama.cpp/build/bin/llama-server"
    fi
    for _a in "$_cuda" \
              "${LLAMA_XE_SERVER_BIN:-$HOME/llama.cpp/build-opencl/bin/llama-server}"
    do
        # An absent build (the Xe tree is not on every host) must yield an empty
        # entry, not abort the probe.
        readlink -f "$_a" 2>/dev/null || true  # swallow-ok: absent build -> empty
    done
}

# 0 (TRUE) when this resolved exe is one of the sanctioned server binaries.
_is_sanctioned_exe() {
    local _exe="$1" _a
    [[ -n "$_exe" ]] || return 1
    while IFS= read -r _a; do
        [[ -n "$_a" && "$_exe" == "$_a" ]] && return 0
    done < <(_sanctioned_exes)
    return 1
}

# 0 (TRUE) when this resident CANNOT be a GPU workload, whatever nvidia-smi says about
# it. Two members of the class, both identified by the command line that launched them
# (their /proc/PID/exe is an interpreter, so the exe cannot tell them apart):
#
#   * an OpenClaw embedding worker (node/python) — a declared consumer, not a tenant;
#   * a TEST RUNNER. Importing torch opens /dev/dxg and makes the kernel list the
#     process as a CUDA compute app with used_gpu_memory [N/A] on this WSL host, at
#     0 MiB of device memory. Measured 2026-11-01: a VS Code pytest run was read as
#     "a foreign app holds the card" while our own lane served an 81k-token prompt, and
#     the watchdog stopped that lane. A process holding no device memory is not the
#     tenant the watchdog frees VRAM for.
#
# Read by foreign_apps_busy() AND sanctioned_residents_only(). Skipping it in the
# foreign probe alone leaves the lane condemned by the utilisation heuristic, which is
# only suppressed when EVERY remaining resident is a sanctioned server.
_is_non_gpu_resident() {
    local _pid="$1" _cmdline
    _cmdline=$(tr '\0' ' ' < "/proc/$_pid/cmdline" 2>/dev/null || true)  # swallow-ok: a resident that exited mid-probe has no cmdline, and an absent one must read "not exempt", never abort the probe
    case "$_cmdline" in
        *memory-core-local-embedding-worker*) return 0 ;;
        *run_pytest_script.py*|*" -m pytest"*|*"/pytest "*) return 0 ;;
    esac
    return 1
}

# 0 (TRUE) when nvidia-smi lists at least one compute app and EVERY one of them is a
# sanctioned server binary; 1 otherwise (an unsanctioned resident, an unreadable
# /proc, or no listing at all).
#
# This is the gate that keeps utilisation from accusing the lane of being foreign to
# itself.  A llama-server generating tokens sits at 80-100% util against a 15%
# threshold, so util said BUSY about our own lane's work and the watchdog stopped it
# mid-request — twice, on 2026-10-23.  Anything we cannot prove is ours leaves this
# false, so utilisation still counts: the fail-closed direction is preserved.
sanctioned_residents_only() {
    local smi_out pid exe seen=0
    RESIDENCY_EMPTY=0
    # stderr is dropped because a driver fault is answered by the explicit
    # "|| return 1" (not-busy-only), never by reading the error text as a pid.
    smi_out=$(nvidia-smi --query-compute-apps=pid --format=csv,noheader 2>/dev/null)  # swallow-ok: see above
    if [[ -z "$smi_out" ]]; then
        # No listing at all. This is the state that cannot be told apart from "a
        # foreign resident is listed" by the return value (both answer 1), so it is
        # recorded here and read only by utilisation_arm()'s free-path audit line.
        RESIDENCY_EMPTY=1
        return 1
    fi
    while IFS= read -r pid; do
        pid="${pid%$'\r'}"
        [[ "$pid" =~ ^[0-9]+$ ]] || continue
        seen=1
        # A resident that exits mid-probe leaves an unreadable exe; empty is "not
        # proven ours", which this caller treats as foreign (fail-closed).
        exe=$(readlink -f "/proc/$pid/exe" 2>/dev/null || true)  # swallow-ok: race -> foreign
        _is_non_gpu_resident "$pid" && continue
        _is_sanctioned_exe "$exe" || return 1
    done <<< "${smi_out:-}"
    (( seen ))
}

foreign_apps_busy() {
    ARMS_RUN+=("foreign-app")
    local pid comm exe smi_out smi_rc _a
    # When the driver/NVML blocks GPU access, nvidia-smi exits non-zero AND prints
    # its error text on STDOUT. Without this guard that text was read as a pid,
    # yielding the nonsense reason "foreign-app pid=Failed to initialize NVML...".
    # We cannot prove the GPU is free, so FAIL CLOSED with a truthful reason.
    smi_out=$(nvidia-smi --query-compute-apps=pid --format=csv,noheader 2>/dev/null)
    smi_rc=$?
    if (( smi_rc != 0 )) || grep -qvE '^[0-9]*$' <<< "${smi_out:-0}"; then
        REASONS+=("nvidia-smi-unavailable")
        ARM="nvidia-smi-unavailable"
        return 0
    fi
    # The residents this probe must not report as foreign, resolved to their real
    # paths. Matched on /proc/PID/exe — never on comm or cmdline: a NAME matches
    # any process that merely MENTIONS the string (a `tail -f llama-server.log`, a
    # shell running `grep llama-server`), and the Xe build carries the same binary
    # NAME as the CUDA one, so a name cannot tell the two cards' servers apart
    # either. These defaults mirror 01-constants.sh (LLAMA_CUDA_SERVER_BIN /
    # LLAMA_XE_SERVER_BIN); this probe is standalone and does not source the
    # console, so they are repeated here rather than imported.
    local -a _allowed=()
    mapfile -t _allowed < <(_sanctioned_exes)
    while IFS= read -r pid; do
        pid="${pid%$'\r'}"
        [[ -z "$pid" ]] && continue
        [[ "$pid" =~ ^[0-9]+$ ]] || continue
        [[ "$pid" == "$$" ]] && continue
        comm=$(cat "/proc/$pid/comm" 2>/dev/null || echo "")
        # A sanctioned server holding the card is expected: skip only if the
        # RESOLVED binary is one of the two above, so a same-named server from any
        # other build path stays foreign and still reports busy.
        exe=$(readlink -f "/proc/$pid/exe" 2>/dev/null || true)
        _is_sanctioned_exe "$exe" && continue
        # Interpreter-based residents that cannot be a GPU workload (an embedding
        # worker, a test runner) are identified by the command line that launched
        # them — their exe is the interpreter, which says nothing about the role.
        _is_non_gpu_resident "$pid" && continue
        REASONS+=("foreign-app pid=$pid $comm exe=${exe:-unreadable}")
        ARM="foreign-app"
        return 0
    done <<< "$smi_out"
    return 1
}

declared_workload_busy() {
    ARMS_RUN+=("declared-workload")
    local _why=""
    # Patterns here name a real artefact — a script PATH or an executable — and
    # never a bare word.  A bare word matches any process whose command line
    # merely contains it: on 2026-09-15 `pgrep -f "llama-bench|autotune"` matched
    # a human's interactive `grep -iE 'llama|autotune'`, this probe reported BUSY,
    # and the watchdog STOPPED a healthy, serving CUDA lane on a free card.  A
    # false BUSY is not the safe direction here: it takes the lane down.
    #
    # Naming the artefact was not enough either.  A pattern only SELECTS candidates
    # by command line; _any_executing_process then proves the process is RUNNING the
    # artefact.  On 2026-09-21 a `cat /usr/local/bin/clear_vram.sh` in an operator's
    # shell was selected by the clear_vram pattern, this probe answered BUSY, and the
    # watchdog stopped the CUDA lane on a free card.  So every call below passes the
    # artefact's FILE NAME alongside its pattern.
    if _any_executing_process 'model_selection_bench\.py' model_selection_bench.py; then
        _why="model_selection_bench"
    fi
    # llama.cpp's bench tool, matched on COMM: a mention in someone's command line
    # cannot produce a comm match, so this one cannot self-match at all.
    if [[ -z "$_why" ]] && pgrep -x llama-bench >/dev/null 2>&1; then
        _why="llama-bench"
    fi
    # A console autotune/bench run — by script path, not by the word "autotune".
    if [[ -z "$_why" ]] \
        && _any_executing_process '/(autotune-model|run-autotune-batch|retune-band-chunk)\.sh' \
               autotune-model.sh run-autotune-batch.sh retune-band-chunk.sh; then
        _why="autotune"
    fi
    # The investigator's path-pinned bench wrapper (~/.local/bin/cuda-llama-bench).
    if [[ -z "$_why" ]] && _any_executing_process '/cuda-llama-bench' cuda-llama-bench; then
        _why="cuda-llama-bench"
    fi
    # A VRAM-clearing helper.
    if [[ -z "$_why" ]] && _any_executing_process 'clear_vram\.sh' clear_vram.sh; then
        _why="clear_vram"
    fi
    if [[ -n "$_why" ]]; then
        # Attribution AT THE MATCH: the class, then which process and which rule.
        # Until 1.11.0 this line carried the class alone, so a stop could not be
        # attributed after the fact — the 2026-11-04 12:35:56 [probe: declared:autotune]
        # was correct and unreadable at the same time.
        local _reason="declared:$_why pid=${_MATCH_PID:-unknown} rule=${_MATCH_RULE:-unknown}"
        _reason+=" argv=${_MATCH_ARGV:-unreadable}"
        REASONS+=("$_reason")
        ARM="declared-workload"
        return 0
    fi
    return 1
}

# PIDs of this probe and its ancestry, bounded.  A `pgrep -f` runs against every
# process on the box, including the shell that asked the question, so the probe's
# own chain is excluded from the declared-workload match — otherwise the check can
# answer "busy" because of how the caller happened to be invoked.
_self_chain() {
    local p=$$ n=0
    while [[ "$p" =~ ^[0-9]+$ ]] && (( p > 1 )) && (( n < 8 )); do
        printf '%s\n' "$p"
        p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' \n')
        n=$((n + 1))
    done
}

# 0 when this executable NAME is something that RUNS a script — a shell, an
# interpreter, or a privilege/exec wrapper.  Readers and editors (cat, grep, less,
# tail, head, diff, sed, awk, vim) are deliberately absent: they can only NAME an
# artefact, and reading a name as a run is what took the CUDA lane down.
_is_interpreter() {
    case "$1" in
        bash|sh|dash|zsh|ksh|ash|busybox) return 0 ;;
        python|python[0-9]*|perl|perl5*|ruby) return 0 ;;
        sudo|doas|su|env|runuser|systemd-run) return 0 ;;
    esac
    return 1
}

# _attr_argv <pid> — the argv a match was made on, as ONE bounded journal-safe line.
#
# Why this exists (2026-11-06): the 2026-11-04 12:35:56 stop read
#   [probe: declared:autotune]
# and the class alone could not be attributed afterwards. It cannot separate a real
# autotune from a test or lint invocation that NAMES the script, and the process had
# exited before anyone looked, so absence at 12:39 said nothing about 12:35:56.
# Instrumentation only: this runs AFTER a match is made and changes nothing about
# which processes match.
#
# The string is embedded in reasons (a quoted JSON array) and in the watchdog's
# [probe: ...] bracket, so the sanitisation is part of the contract: " becomes ',
# \ becomes /, ] becomes ), and control/non-printable bytes become ?. A quote would
# break the reasons JSON, a ']' would end the bracket early, and a newline would
# forge a second journal line. Each is REPLACED rather than dropped, so a reader can
# see that a character was altered instead of a silently cleaned-up argv.
# The joined argv is cut at 160 characters with a trailing '...'.
_attr_argv() {
    local _pid="$1" _s=""
    local -a _a=()
    # swallow-ok: an unreadable cmdline IS the fact being reported; the empty array falls through
    mapfile -d '' -t _a < "/proc/$_pid/cmdline" 2>/dev/null || true
    if (( ${#_a[@]} > 0 )); then
        _s="${_a[*]}"
    else
        # An exited or other-user process has no readable cmdline, and the kernel's comm
        # is the fallback identity; empty must read as unreadable, not as "no match".
        # swallow-ok: absent comm is the identity fallback, not an error; empty prints unreadable
        _s=$(cat "/proc/$_pid/comm" 2>/dev/null || true)
        [[ -n "$_s" ]] && _s="comm=$_s"
    fi
    _s="${_s//$'\n'/ }"
    _s="${_s//$'\r'/ }"
    _s="${_s//$'\t'/ }"
    _s="${_s//\"/\'}"
    _s="${_s//\\//}"
    _s="${_s//\]/)}"
    _s=$(printf '%s' "$_s" | LC_ALL=C tr -c '[:print:]' '?')
    if (( ${#_s} > 160 )); then
        _s="${_s:0:160}..."
    fi
    printf '%s' "${_s:-unreadable}"
}

# 0 when process <pid> is really EXECUTING one of the named artefacts, 1 when it
# merely names one.  Two gates, and neither is a command-line substring:
#
#   (a) the running executable IS the artefact — a compiled bench, or a script the
#       kernel exec'd directly (the kernel then names the process after the script);
#   (b) the running executable is an interpreter/shell/wrapper AND an argv element
#       is a PATH whose file name is the artefact.
#
# Identity comes from /proc/PID/exe, which `exec -a` cannot forge.  For another
# user's process — a root-run clear_vram.sh is the real case — exe is unreadable,
# and the kernel's own /proc/PID/comm is used instead: comm is the executable's
# name, so it keeps the same discipline, and unlike argv a mere mention cannot
# reach it (the comm match is the repo's existing idiom — see pgrep -x llama-bench).
#
# In gate (b) the argv element must be a path, i.e. ONE WORD.  `cat <file>` passed
# to `bash -c` is a single element with a space in it and does not qualify, which is
# exactly the incident this exists for.
_process_executes() {
    local _pid="$1"; shift
    local _name _exe_base _elem _i
    local -a _argv=()
    # Which gate matched, for the busy line's attribution (_attr_argv carries the
    # pid and argv). Reset per call so a previous candidate's rule cannot be read.
    _MATCH_RULE=""
    _exe_base=$(readlink -f "/proc/$_pid/exe" 2>/dev/null || true)
    _exe_base="${_exe_base##*/}"
    if [[ -z "$_exe_base" ]]; then
        IFS= read -r _exe_base < "/proc/$_pid/comm" 2>/dev/null || true
    fi
    for _name in "$@"; do
        if [[ -n "$_exe_base" && "$_exe_base" == "$_name" ]]; then
            _MATCH_RULE="exe"
            return 0
        fi
    done
    _is_interpreter "$_exe_base" || return 1
    mapfile -d '' -t _argv < "/proc/$_pid/cmdline" 2>/dev/null || true
    # The named artefact must be the SCRIPT the interpreter was GIVEN — the argv
    # element that immediately FOLLOWS an interpreter — not any slot that merely
    # NAMES it.  Measured 2026-10-16: a CI lint job's own file list
    # (`bash tools/lint.sh --files … bin/train-timeout-runner.sh …`) arrives as
    # separate argv elements, so it names the runner without executing it, and the
    # any-element scan below read it as a tenant.  scripts/11d-llm-gpu.sh's
    # __llm_train_lane_holder carries the same rule.
    for (( _i = 1; _i < ${#_argv[@]}; _i++ )); do
        _elem="${_argv[_i]}"
        [[ "$_elem" == *[[:space:]]* ]] && continue
        _is_interpreter "${_argv[_i-1]##*/}" || continue
        for _name in "$@"; do
            if [[ "${_elem##*/}" == "$_name" ]]; then
                _MATCH_RULE="argv-after:${_argv[_i-1]##*/}"
                return 0
            fi
        done
    done
    return 1
}

# _under_test_harness <pid> — 0 when the process descends from a test harness.
#
# 2026-11-04: tests/unit/08-autotune-workload.bats runs the REPO's own scripts/autotune-model.sh
# at its real path, so this probe answered correctly -- a real autotune script WAS executing --
# and the watchdog stopped the fleet's default CUDA lane to serve a unit test. Twice: 14:02:56Z
# from a bats loop, 14:09:53Z from a VS Code bats run (bats-exec-suite <- timeout 400 bats <-
# the qwen-code companion extension).
#
# The script is real; the intent is a test. A benchmark a test harness started is not a declared
# workload, and the name must be the executable token: a process whose argv merely contains
# 'bats' does not match.
_under_test_harness() {
    local p="$1" n=0 _comm _args
    local _harness='^(bats|bats-exec-test|bats-exec-file|bats-exec-suite|pytest) ?( |$)'
    while [[ "$p" =~ ^[0-9]+$ ]] && (( p > 1 )) && (( n < 15 )); do
        # swallow-ok: an exited process has no comm; absent must read "not a harness"
        _comm=$(ps -o comm= -p "$p" 2>/dev/null | tr -d ' \n')
        if [[ "$_comm" =~ ^(bats|bats-exec-test|bats-exec-file|bats-exec-suite|pytest)$ ]]; then
            return 0
        fi
        # swallow-ok: no argv is not evidence of a harness
        _args=$(ps -o args= -p "$p" 2>/dev/null)
        if [[ "$_args" =~ (^|/)(bats|bats-exec-test|bats-exec-file|bats-exec-suite|pytest)( |$) ]]; then
            return 0
        fi
        # swallow-ok: the top of the chain has no parent; that ends the walk
        p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' \n')
        n=$((n + 1))
    done
    return 1
}

# _any_executing_process <pgrep -f pattern> <artefact name>... — 0 when a process
# outside this probe's own process chain is EXECUTING one of the artefacts, 1
# otherwise.  The pattern only SELECTS candidates by command line (cheap, and it
# keeps the artefact deliberately named); _process_executes decides.  Without that
# second gate any process that merely NAMED the artefact — a cat, a grep, a tail —
# was counted as a declared workload and stopped a serving lane (2026-09-21).
_any_executing_process() {
    local _pat="$1"; shift
    local _pid _s _is_self
    local -a _self=()
    # Attribution for the caller's busy line: the pid and the argv of the match.
    # _process_executes supplies the rule. Reset here, because a stale pid from an
    # earlier probe would read as evidence about this one.
    _MATCH_PID=""; _MATCH_ARGV=""
    mapfile -t _self < <(_self_chain)
    while read -r _pid; do
        [[ "$_pid" =~ ^[0-9]+$ ]] || continue
        _is_self=0
        for _s in "${_self[@]}"; do
            [[ "$_pid" == "$_s" ]] && _is_self=1
        done
        (( _is_self )) && continue
        _process_executes "$_pid" "$@" || continue
        _MATCH_PID="$_pid"
        _MATCH_ARGV=$(_attr_argv "$_pid")
        if _under_test_harness "$_pid"; then
            # Visible, never silent: a suppression a reader cannot see is indistinguishable from a
            # probe that found nothing, which is the defect class this repo keeps paying for.
            REASONS+=("suppressed:test-harness pid=$_pid rule=$_MATCH_RULE argv=$_MATCH_ARGV")
            continue
        fi
        return 0
    done < <(pgrep -f "$_pat" 2>/dev/null)
    return 1
}

lock_busy() {
    ARMS_RUN+=("bench-lock")
    if [ -f "$BENCH_LOCK" ]; then
        REASONS+=("lock:$BENCH_LOCK")
        ARM="bench-lock"
        return 0
    fi
    return 1
}

cuda_owner_busy() {
    # Signal 5: another agent owns the CUDA card (the investigator pipeline's
    # flock, taken for the whole of a local-model run).  Path precedence mirrors
    # investigator/config/paths.py:gpu_lock_path() EXACTLY, and the probe is
    # existence-gated — `flock -n` also fails on a MISSING path, so reading a
    # failed probe as "held" would report busy forever on a box that never took
    # the lock.
    ARMS_RUN+=("cuda-owner")
    local _lock="${INVESTIGATOR_GPU_LOCK:-${INVESTIGATOR_PRODUCTION_OUTPUT:-$HOME/investigator/production}/runtime/gpu.lock}"
    [[ -e "$_lock" ]] || return 1
    if flock -n "$_lock" -c true 2>/dev/null; then
        return 1   # we took it, so nobody else holds it
    fi
    REASONS+=("cuda-owned-by-another-run pid=$(tr -dc '0-9' < "$_lock" 2>/dev/null || true)")
    ARM="cuda-owner"
    return 0
}

# Signal 3, the TRAINING tenant (card UBC-GRPO-001).  A training run registers by
# running under bin/train-timeout-runner.sh (card UBC-GRPO-002), which holds the SAME
# bench lock this file's signal 4 reads - so the tenancy authority stays single, and the
# holder's CLASS is read from the executing artefact rather than from a second lock file.
#
# First in busy(), deliberately: the trainer is a CUDA resident, so foreign_apps_busy()
# would otherwise answer "foreign-app pid=... exe=.../python3.12" about it, which is what
# made a tenant read as an unknown app.  The match never names a word like "grpo" or
# "unsloth" - the false-BUSY regression in this file's header is that mistake.
#
# The reason carries the card's footprint when nvidia-smi answers, so the watchdog's busy
# line can tell "training holds the card" from an unknown holder without a second probe.
training_tenant_busy() {
    ARMS_RUN+=("training-tenant")
    _any_executing_process '/train-timeout-runner\.sh' train-timeout-runner.sh || return 1
    local _used
    # swallow-ok: a failed probe only drops the footprint figure; the tenant match above already decided BUSY
    _used=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ')
    if [[ "$_used" =~ ^[0-9]+$ ]]; then
        REASONS+=("declared:training vram=${_used}MiB")
    else
        REASONS+=("declared:training")
    fi
    ARM="training-tenant"
    return 0
}

busy() {
    # Per-call reset, so a --wait loop or a second call cannot accumulate another call's
    # arms. REASONS is reset by each caller; these two are reset here, where the chain
    # that appends to them begins.
    ARM=""
    ARMS_RUN=()
    # Order is the fix, not a style choice. This is a short-circuiting OR: whichever
    # signal answers first is the ONLY reason recorded, and the rest never run. Asking
    # utilisation first meant a serving lane always answered "util=95%>=15%" and the
    # lock/owner/foreign answers that would have said "this is the lane's own work"
    # were never consulted.
    #
    #   1. training tenant   — registered, declared, holds the shared bench lock
    #   2. bench lock        — another run has claimed the card
    #   3. cuda owner        — the investigator's flock is held elsewhere
    #   4. foreign app       — an unsanctioned resident holds a CUDA context
    #   5. declared workload — a bench/autotune artefact is EXECUTING
    #   6. utilisation       — heuristic, and only when the residents are not ours.
    #      This arm can also answer FREE while the card is busy (a serving lane's own
    #      prefill), so it records WHY on the free path — see utilisation_arm().
    training_tenant_busy \
        || lock_busy || cuda_owner_busy \
        || foreign_apps_busy || declared_workload_busy \
        || utilisation_arm
}

emit() {
    local state="$1" reasons=""
    # An empty REASONS array expanded to a lone empty string, emitting the invalid
    # reason reasons:[""] on the free path; build the list only when non-empty.
    if (( ${#REASONS[@]} > 0 )); then
        reasons=$(printf '"%s",' "${REASONS[@]}" | sed 's/,$//')
    fi
    # arm/checked are APPENDED, so `reasons` keeps its position and shape: every existing
    # consumer parses that field by prefix, and a stop that is attributable but unreadable
    # by the watchdog would be no improvement at all.
    local _checked=""
    if (( ${#ARMS_RUN[@]} > 0 )); then
        _checked=$(printf '"%s",' "${ARMS_RUN[@]}" | sed 's/,$//')
    fi
    if [ "${JSON_OUT:-0}" = "1" ]; then
        printf '{"busy":%s,"reasons":[%s],"arm":"%s","checked":[%s]}\n' \
            "$state" "$reasons" "${ARM:-none}" "$_checked"
    fi
    log "busy=$state reasons=${REASONS[*]:-none} arm=${ARM:-none} checked=${ARMS_RUN[*]:-none}"
}

JSON_OUT=0
case "${1:-}" in
    --json) JSON_OUT=1 ;;
    --wait)
        JSON_OUT=1
        WAIT_SECS="${2:-300}"
        waited=0
        while [ "$waited" -lt "$WAIT_SECS" ]; do
            REASONS=()
            if ! busy; then emit false; exit 0; fi
            sleep 5
            waited=$((waited + 5))
        done
        emit true
        exit 1
        ;;
esac

REASONS=()
if busy; then
    emit true
    exit 1
fi
emit false
exit 0

# end of file
