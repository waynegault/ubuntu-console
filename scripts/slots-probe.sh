#!/usr/bin/env bash
# AI INSTRUCTION: On ANY change to this file, increment the Module Version below.
# Module Version: 10
#   v10 (2026-11-14): the load term reads through `_load1`, so a case can state the box it is
#     describing.  `_quiet_verdict` read /proc/loadavg inline, which carries the RUNNER's load:
#     tests/unit/88's warm-clock arm pinned pressure, pgrep and the clock, then refused with
#     "load 20.06 on 20 cores" on a busy runner (CI case 1185) — the host deciding an assertion
#     about a fixture.  Same shape as `_cpu_pressure_pct` and `_gpu_clock_mhz`, which were
#     already overridable for exactly this reason.  No behaviour change on a real box.
# Module Version: 9
#   v9 (2026-11-11): one canonical version line; the historical entries below
#     are changelog only, so the loader sums this file once (inspection 13.4.3).
#   v8 (2026-11-09): the cold-card refusal reads as one sentence.  v7 wrapped the gate's reason in
#       brackets of its own, so the live message nested them — "the card is cold (SM clock 650 MHz
#       of 3003 (below 60% ...))", which is what the 17:58 run actually printed.  The reason is now
#       spliced after a dash.  No behaviour changes: the same terms, the same refusals.
#   v7 (2026-11-09): the clock term gets a WARM-UP, because on its own it deadlocks.  Measured
#       17:31: the card sat at 650 of 3,003 MHz with nothing using it, so the gate refused every
#       attempt and the sweep could never run on the quiet box it requires.  _warm_clock now sends
#       three short completions through the lane that is ALREADY serving (before the probe stops
#       it) and polls the clock to the floor, bounded at 90 s; the gate then judges a warm card.
#       Best-effort by design: a lane that is down, or a card that stays cold, still reaches the
#       gate, which refuses with its own reason rather than measuring a cold card.
#   v6 (2026-11-09): the quiet gate gains a CLOCK term.  The 15:14 run was clean on every other
#       term — load 1.90, no CI worker, not a byte of foreign CPU pressure — and still measured
#       28.44 tok/s at four slots where the same arm read 119.12 on a warm card: the SM clock was
#       at 656 of 3,003 MHz and the card drew 1.7 W.  A load average cannot see that, so the gate
#       now refuses below LLM_SLOTS_PROBE_CLOCK_MIN_PCT (default 60%) of this boot's max and
#       quotes both readings; an UNREADABLE clock stays no-evidence, like the PSI term.
#   v5 (2026-11-09): the probe refuses to measure a box that is not quiet, and voids an arm
#       whose numbers cannot be true.  Measured on the second real run (load 6.80 at start):
#       arm 4 reported aggregate 2.43 against per-stream 4.72 — impossible — because its
#       groups read [5.52, 1.96, 2.43] while the 20 s windows were short of a contender that
#       ended inside them.  _quiet_verdict now gates the run on load-vs-cores, CPU pressure
#       (the same /proc/pressure/cpu reading autotune-model.sh uses) and an active CI runner
#       worker, naming the term that refused; _summarise prints VOID instead of a rate when
#       aggregate < per-stream or the group spread exceeds 50 %, and the JSON carries suspect=.
#   v4 (2026-11-09): the summary stopped printing a figure that was wrong twice.  `ctx / slots /
#       1024` was labelled "MiB" — it is K TOKENS — and every arm passes --kv-unified, so the
#       window is SHARED and a per-slot division describes a configuration this lane never runs.
#       The table now names the ctx in tokens and says the window is shared; the JSON drops
#       kv_mib_per_slot.  Found by reading the first real run's own output, not by a test: the
#       case that existed asserted the wrong label, which is why the new assertion checks that
#       "MiB" is absent.
#   v3 (2026-11-09): the restore waits for the PORT, not just for the process.  Measured on the
#       first real run: the last arm's server was killed, the trap started the lane while 18087
#       was still bound, llama-server died with "couldn't bind HTTP server socket" six times and
#       systemd rate-limited the unit into `failed` — the run ended with the fleet's primary lane
#       DOWN and needed reset-failed by hand.  _wait_listen_free (ss, not a connect probe) now
#       gates both the per-arm teardown and the restore, and the restore clears a rate limit
#       before starting.
#   v2 (2026-11-09): §18.3 debt the first cut carried — eight bare `exit 2` sites became one
#       `die_usage` helper holding the status (9.7 79 -> 79, and no line pushed past 120
#       chars doing it, 8.1.8), and the signal trap names its code.  No behaviour change:
#       the same text reaches stderr and the same status leaves the process.
#   v1 (2026-11-09): first cut.  The lane serves --parallel 4 because Wayne asked for at
#       least four slots (2026-11-07), and nothing has ever measured whether 8 or 16 earns
#       its KV.  A vLLM recipe on the same silicon (devjeonghwan/vllm-for-rtx-spark) runs
#       max-num-seqs 16 and reports 65.75 -> 233.63 tok/s from concurrency 1 to 16, so the
#       slot count is a throughput lever, not a comfort setting.  This probe restarts ONE
#       lane at each slot count and measures AGGREGATE throughput at that concurrency with
#       tools/llm_benchmark.py — the load generator this repo already owns and tests.
#
# slots-probe.sh — how many slots should this lane serve?
#
# Usage: slots-probe.sh [--unit U] [--values 4,8,16] [--concurrency N]
#                       [--prompt-tokens N] [--max-tokens N] [--repetitions N]
#                       [--out DIR] [--dry-run]
#
# WHAT IT MEASURES, AND WHAT IT DOES NOT
#   Per slot count: aggregate decode tok/s with N concurrent streams (the number that
#   decides a slot count), plus the per-stream rate and the KV each slot costs
#   (ctx / parallel).  It does NOT re-tune ctx, batch or quantisation — those stay as the
#   lane serves them, so the arms differ in ONE variable.
#
# WHY A RESTART PER ARM
#   --parallel is fixed at process start, so a slot count cannot be changed on a live
#   server.  The probe therefore stops the lane, starts the SAME argv with only --parallel
#   replaced, measures, and restores the lane on exit (trap), including on a signal.
#
# WHY IT IS NOT PART OF cache-ram-probe.sh
#   That probe's measurement is a single-stream BABA prompt sequence: it answers "what does
#   a returning conversation cost", and slots do not help one stream — they divide its ctx.
#   Measuring slots needs a CONCURRENT load generator, which is tools/llm_benchmark.py.
#   The unit-argv parsing below is the same method as cache-ram-probe.sh's __base_from_unit
#   (that script runs its own main, so it cannot be sourced for the helper).
#
# Exit: 0 measured, 1 refused or a failed arm, 2 usage.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BENCH="$REPO_ROOT/tools/llm_benchmark.py"
TAC_PYTHON="${TAC_PYTHON:-$REPO_ROOT/.venv/bin/python3}"
# swallow-ok: a missing python3 is reported by the -x check in parse_args, which refuses
[[ -x "$TAC_PYTHON" ]] || TAC_PYTHON="$(command -v python3 || true)"

UNIT="${LLAMA_CUDA_LANE_UNIT:-}"
VALUES="4,8,16"
CONCURRENCY=""
PROMPT_TOKENS=1800
MAX_TOKENS=256
REPETITIONS=3
OUT_DIR=""
DRY_RUN=0
HEALTH_TIMEOUT=180

# Named exit codes (§18.3 9.7).  The header documents 0/1/2, and a bare `exit 2` at eight
# call sites is exactly the shape that item counts: an exit code is part of a function's
# interface, so it gets a name here rather than a comment repeated eight times.
readonly EXIT_USAGE=2
readonly EXIT_INTERRUPTED=130

# warn — this tool's ONE stderr path, so every refusal has the same shape (10.7).
warn() { printf 'slots-probe: %s\n' "$*" >&2; }

# die_usage — refuse a bad invocation.  One place holds the usage status, so the eight
# argument checks below name their reason and nothing else (9.7), and each stays inside
# the line budget (8.1.8) instead of repeating `exit "$EXIT_USAGE"` on a long line.
die_usage() { warn "FATAL: $*"; exit "$EXIT_USAGE"; }

# usage — the CLI synopsis; stdout on --help, stderr on a bad flag.
usage() {
    printf '%s\n' \
        "usage: slots-probe.sh [--unit U] [--values 4,8,16] [--concurrency N]" \
        "                     [--prompt-tokens N] [--max-tokens N] [--repetitions N]" \
        "                     [--out DIR] [--dry-run]"
}

# parse_args — the CLI.  Refuses an unknown flag rather than silently ignoring it.
parse_args() {
    while (( $# > 0 )); do
        case "$1" in
            --unit) UNIT="${2:?--unit needs a unit name}"; shift 2 ;;
            --values) VALUES="${2:?--values needs a comma list}"; shift 2 ;;
            --concurrency) CONCURRENCY="${2:?--concurrency needs a number}"; shift 2 ;;
            --prompt-tokens) PROMPT_TOKENS="${2:?--prompt-tokens needs a number}"; shift 2 ;;
            --max-tokens) MAX_TOKENS="${2:?--max-tokens needs a number}"; shift 2 ;;
            --repetitions) REPETITIONS="${2:?--repetitions needs a number}"; shift 2 ;;
            --out) OUT_DIR="${2:?--out needs a directory}"; shift 2 ;;
            --dry-run) DRY_RUN=1; shift ;;
            -h|--help) usage; exit 0 ;;
            *) usage >&2; die_usage "unknown argument $1" ;;
        esac
    done
    [[ -n "$UNIT" ]] || { usage >&2; die_usage "--unit is required (or set LLAMA_CUDA_LANE_UNIT)"; }
    [[ "$PROMPT_TOKENS" =~ ^[1-9][0-9]*$ ]] || die_usage "--prompt-tokens must be a positive integer"
    [[ "$MAX_TOKENS" =~ ^[1-9][0-9]*$ ]] || die_usage "--max-tokens must be a positive integer"
    [[ "$REPETITIONS" =~ ^[1-9][0-9]*$ ]] || die_usage "--repetitions must be a positive integer"
    [[ -z "$CONCURRENCY" || "$CONCURRENCY" =~ ^[1-9][0-9]*$ ]] \
        || die_usage "--concurrency must be a positive integer"
    # Validate the slot list HERE, not only where it is emitted: a bad entry inside a
    # process substitution cannot set this script's exit status, so a dry run would print
    # a plan and exit 0 (measured 2026-11-09 by this suite's own case).
    local _v
    local -a _vals=()
    IFS=',' read -ra _vals <<< "$VALUES"
    for _v in "${_vals[@]}"; do
        [[ "$_v" =~ ^[1-9][0-9]*$ ]] || die_usage "--values entry '$_v' is not a positive integer"
    done
    [[ -x "$TAC_PYTHON" ]] || { warn "FATAL: no python3 (set TAC_PYTHON)"; exit 1; }
    [[ -f "$BENCH" ]] || { warn "FATAL: $BENCH is missing"; exit 1; }
}

# _slot_values — the requested slot counts, one per line, refusing anything unusable.
# A zero or a non-number is a refusal, not a skipped arm: an arm that silently vanishes
# reads as "measured and equal" in the summary.
_slot_values() {
    local _v
    local -a _parts=()
    IFS=',' read -ra _parts <<< "$VALUES"
    for _v in "${_parts[@]}"; do
        [[ "$_v" =~ ^[1-9][0-9]*$ ]] || { warn "FATAL: --values entry '$_v' is not a positive integer"; return 1; }
        printf '%s\n' "$_v"
    done
}

# _unit_argv — the lane's own argv, with --parallel removed so the arm's value is the only
# one present (a duplicate would be the malformed-arm shape cache-ram-probe.sh records).
# Sets BASE (array), PORT, MODEL_PATH, MODEL_ID, CTX.
_unit_argv() {
    local _line _argv _i
    _line=$(systemctl --user show "$UNIT" -p ExecStart --value) \
        || { warn "FATAL: no ExecStart for $UNIT"; return 1; }
    _argv="${_line#*argv[]=}"
    _argv="${_argv%% ;*}"
    if [[ -z "$_argv" || "$_argv" == "$_line" ]]; then
        warn "FATAL: could not parse argv from $UNIT"
        return 1
    fi
    local -a _words=() _out=()
    read -ra _words <<< "$_argv"
    for (( _i=0; _i<${#_words[@]}; _i++ )); do
        case "${_words[_i]}" in
            --parallel) _i=$(( _i + 1 )); continue ;;
            # Valued-less: every arm adds it, so a copy in the base would be a duplicate.
            --kv-unified) continue ;;
            --port) PORT="${_words[_i+1]:-$PORT}" ;;
            --ctx-size) CTX="${_words[_i+1]:-$CTX}" ;;
            --alias) MODEL_ID="${_words[_i+1]:-$MODEL_ID}" ;;
            -m|--model) MODEL_PATH="${_words[_i+1]:-}" ;;
        esac
        _out+=("${_words[_i]}")
    done
    BASE=("${_out[@]}")
    [[ -n "$MODEL_PATH" ]] || { warn "FATAL: $UNIT names no model"; return 1; }
    [[ -n "$MODEL_ID" ]] || MODEL_ID="${MODEL_PATH##*/}"
    return 0
}

# _quant_from_name — the quantisation token in a GGUF filename, or "unknown".
# The bench artifact records it so two runs are comparable; a guess would be worse than
# the word "unknown", which is what an unrecognised name gets.
_quant_from_name() {
    local _n="${1##*/}"
    if [[ "$_n" =~ (IQ[0-9][A-Z0-9_]*|Q[0-9][A-Z0-9_]*|BF16|F16|F32|FP8) ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
    else
        printf 'unknown\n'
    fi
}

# _workload_jsonl <path> — one fixed prompt, repeated by the bench tool's --repetitions.
# Deterministic text, so two arms see the same tokens; the prompt is not saved by the tool.
_workload_jsonl() {
    "$TAC_PYTHON" - "$1" "$PROMPT_TOKENS" <<'PYEOF'
import json, sys
path, tokens = sys.argv[1], int(sys.argv[2])
seed = "The quick brown fox jumps over the lazy dog. "
content = (seed * ((tokens * 5) // len(seed) + 1))[: tokens * 5]
with open(path, "w", encoding="utf-8") as fh:
    fh.write(json.dumps({"id": "slots", "prompt": content}) + "\n")
PYEOF
}

# _load1 — the 1-minute load average, or EMPTY when there is no instrument.  A function, not
# an inline read, for the same reason `_cpu_pressure_pct` and `_gpu_clock_mhz` are: /proc/loadavg
# carries the RUNNER's load.  Measured 2026-11-14 on CI: the warm-clock arm of tests/unit/88
# stubbed pressure, pgrep and the clock, then refused with "load 20.06 on 20 cores" because the
# runner was busy — an assertion about the fixture that the host was allowed to decide.
_load1() {
    local _one="" rc=0
    read -r _one _ < /proc/loadavg || rc=$?
    (( rc == 0 )) || return 0
    printf '%s' "$_one"
}

# _cpu_pressure_pct — `some avg10` from /proc/pressure/cpu, or EMPTY when there is no
# instrument.  Same reading as scripts/autotune-model.sh uses, so the two tools judge the box
# the same way; empty means "no evidence", never a refusal.
_cpu_pressure_pct() {
    local line="" rc=0
    # swallow-ok: a kernel without CONFIG_PSI yields nothing; the caller reads empty as "no instrument"
    line="$(cat /proc/pressure/cpu 2>/dev/null)" || rc=$?
    (( rc == 0 )) || return 0
    [[ "$line" =~ some[[:space:]]+avg10=([0-9]+([.][0-9]+)?) ]] || return 0
    printf '%s' "${BASH_REMATCH[1]}"
}

# _gpu_clock_mhz — the SM clock and this boot's max, as "sm max", or EMPTY when unreadable.
# Measured 2026-11-09 while the sweep ran: 656 MHz of 3,003 — the IDLE floor — with the card
# drawing 1.7 W.  That sweep produced 28.44 tok/s at four slots against 119.12 from the same
# arm on a warm card, i.e. a clock factor of ~4 that nothing in the result recorded.  The
# clock is the one confounder a load average cannot see at all.
_gpu_clock_mhz() {
    local _line="" _raw=""
    # The pipeline's status is captured rather than forced to 0 with an appended `exit 0`: a
    # missing nvidia-smi must read as UNKNOWN, and that is decided below on _raw, not here.
    _raw="$(timeout -k 2 "${TAC_SMI_TIMEOUT:-10}" nvidia-smi \
        --query-gpu=clocks.sm,clocks.max.sm \
        --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ')" || _raw=""  # swallow-ok: clock UNKNOWN
    _line="$_raw"
    [[ "$_line" =~ ^([0-9]+),([0-9]+)$ ]] || return 0
    printf '%s %s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
}

# _warm_clock [secs] — bring the card up to the clock floor BEFORE the gate judges it.
#
# WHY (measured 2026-11-09 17:31): the clock term alone deadlocks.  An idle card sits at 650 of
# 3,003 MHz, nothing else on this box uses the GPU, and the gate refuses before the probe starts
# — so the sweep could never run on a quiet box, which is the only box it may run on.  The card
# warms when the LANE serves, so the warm-up goes through the lane that is already up, before the
# probe stops it.  Best-effort: a lane that is down, or a card that stays cold, is left to the
# gate, which then refuses with its own reason.
_warm_clock() {
    local _bound="${1:-90}" _floor="${LLM_SLOTS_PROBE_CLOCK_MIN_PCT:-60}"
    local _waited=0 _clk _sm _max _i _served=0
    for _i in 1 2 3; do
        # swallow-ok: a lane that is down cannot be warmed, and _served below decides that
        if curl -fsS --max-time 30 "http://127.0.0.1:${PORT}/v1/chat/completions" \
            -H 'Content-Type: application/json' \
            -d '{"messages":[{"role":"user","content":"warm"}],"max_tokens":32,"temperature":0}' \
            >/dev/null 2>&1; then
            _served=1
        else
            break
        fi
    done
    while (( _waited < _bound )); do
        _clk="$(_gpu_clock_mhz)"
        [[ -n "$_clk" ]] || return 0
        read -r _sm _max <<< "$_clk"
        if (( _max > 0 )) && awk -v s="$_sm" -v m="$_max" -v p="$_floor" \
             'BEGIN{exit !(s * 100 >= m * p)}'; then
            printf 'slots-probe: card warm at %s MHz of %s after %ss\n' "$_sm" "$_max" "$_waited"
            return 0
        fi
        # ONE clock read before giving up on a silent lane: the card may already be warm from a
        # job that just finished, but nothing this probe can do will raise a clock when the lane
        # is not serving — polling for 90 s would only delay the refusal.
        if (( _served == 0 )); then
            warn "no lane answered on port ${PORT} — nothing can warm the card"
            return 1
        fi
        sleep 5
        _waited=$(( _waited + 5 ))
    done
    warn "the card stayed cold for ${_bound}s of warming through the lane"
    return 1
}

# _quiet_verdict — may this run measure?  Prints a reason and returns 1 when the box is not
# quiet; returns 0 with no output when it is.
#
# WHY (measured 2026-11-09): without this the probe measured at load 6.80 and arm 4 read
# 2.43 aggregate against 4.72 per-stream — arithmetically impossible, because during the
# 20 s group window the sweep's own `ss` polling adds load that does not exist while the
# samples are taken.  A sweep that reports a number the box's state invalidated is worse than
# a refused run.  FOUR terms, none ever licensed by a missing instrument:
#   * load1 above the core count (a run-queue average cannot see few saturated threads, so
#     this alone is not enough — it is the cheap first term);
#   * CPU pressure above LLM_AUTOTUNE_PSI_MAX_PCT (default 10%), sampled BEFORE any server
#     launches so the probe's own threads are not mistaken for foreign load;
#   * an active CI runner worker — CI's bats children never take heavy-job, so the lock
#     cannot see them (the same rule autotune-model.sh v85 adopted);
#   * an SM clock below LLM_SLOTS_PROBE_CLOCK_MIN_PCT (default 60%) of this boot's max.  A
#     quiet, IDLE card is the other way this sweep lies: the 2026-11-09 15:14 run was clean
#     on load, 1.90, and still measured at the 656 MHz floor.
_quiet_verdict() {
    local _load _cores _psi _ci _clk _sm _max _term=""
    _load="$(_load1)"
    # swallow-ok: an unreadable core count leaves the load term unavailable, which is not a refusal
    _cores="$(nproc 2>/dev/null)" || _cores=""
    _psi="$(_cpu_pressure_pct)"
    # swallow-ok: no runner process means no CI term; pgrep's own status is not a finding
    _ci="$(pgrep -c -f 'actions-runner.*[R]unner\.Worker' 2>/dev/null || true)"
    _clk="$(_gpu_clock_mhz)"
    if [[ "$_ci" =~ ^[0-9]+$ ]] && (( _ci > 0 )); then
        _term="${_ci} CI runner worker(s) active"
    fi
    if [[ -n "$_clk" ]]; then
        read -r _sm _max <<< "$_clk"
        if (( _max > 0 )) && awk -v s="$_sm" -v m="$_max" \
             -v p="${LLM_SLOTS_PROBE_CLOCK_MIN_PCT:-60}" 'BEGIN{exit !(s * 100 < m * p)}'; then
            # One printf keeps the text on one line without a bare continuation word: adjacent
            # string literals joined by "\" would form the "A"B"C" shape shellcheck warns on.
            _term="${_term:+$_term; }$(printf 'SM clock %s MHz of %s (below %s%% - an idle card measures ~4x low)' \
                "$_sm" "$_max" "${LLM_SLOTS_PROBE_CLOCK_MIN_PCT:-60}")"
        fi
    fi
    if [[ -n "$_psi" ]] && awk -v p="$_psi" -v m="${LLM_AUTOTUNE_PSI_MAX_PCT:-10}" 'BEGIN{exit !(p > m)}'; then
        _term="${_term:+$_term; }cpu pressure ${_psi}% (some avg10, threshold ${LLM_AUTOTUNE_PSI_MAX_PCT:-10}%)"
    fi
    if [[ "$_load" =~ ^[0-9]+([.][0-9]+)?$ && "$_cores" =~ ^[0-9]+$ ]] \
       && awk -v l="$_load" -v c="$_cores" 'BEGIN{exit !(l > c)}'; then
        _term="${_term:+$_term; }load ${_load} on ${_cores} cores"
    fi
    [[ -z "$_term" ]] && return 0
    printf '%s' "$_term"
    return 1
}

# _wait_health — bounded wait for the arm's server to answer /health.
_wait_health() {
    local _waited=0
    while (( _waited < HEALTH_TIMEOUT )); do
        if curl -fsS --max-time 2 "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1; then
            return 0
        fi
        sleep 2
        _waited=$(( _waited + 2 ))
    done
    warn "FATAL: the arm's server did not answer /health within ${HEALTH_TIMEOUT}s"
    return 1
}

# _wait_listen_free [secs] — bounded wait until nothing LISTENs on the arm's port.
# Measured 2026-11-09: killing the last arm's server is not enough.  The restore trap then
# started the lane while 18087 was still bound, llama-server died with "couldn't bind HTTP
# server socket", systemd retried six times and rate-limited the unit into `failed` — so the
# run ended with the fleet's primary lane DOWN.  `ss` is the check that answers the question
# bind() actually asks; a connect probe says "free" for a port in TIME_WAIT.
_wait_listen_free() {
    local _bound="${1:-30}" _waited=0 _listen=""
    while (( _waited < _bound )); do
        # swallow-ok: ss's own diagnostics are not wanted; a FAILED read is decided below, not here
        if ! _listen="$(ss -ltnH "sport = :${PORT}" 2>/dev/null)"; then
            # An unreadable socket table is not "free": say so and let the caller's start decide.
            warn "cannot read the socket table for port ${PORT} — assuming it is free"
            return 1
        fi
        [[ -n "$_listen" ]] || return 0
        sleep 1
        _waited=$(( _waited + 1 ))
    done
    warn "port ${PORT} was still listening after ${_bound}s — the lane's restart may fail"
    return 1
}

# _restore_lane — put the lane back.  Installed as the EXIT trap BEFORE the first stop, so
# a refusal, a failed arm or a signal all leave the box serving what it served before.
_restore_lane() {
    [[ "${LANE_STOPPED:-0}" == "1" ]] || return 0
    # The port must be free BEFORE the start: a bind failure is what rate-limits the unit.
    # swallow-ok: a port that never frees is reported by _wait_listen_free, and the start below still runs
    _wait_listen_free 30 || true
    # A unit that failed during an arm is rate-limited; clearing that is part of a restore.
    # swallow-ok: reset-failed reports non-zero when the unit is not failed, which is the normal case
    systemctl --user reset-failed "$UNIT" >/dev/null 2>&1 || true
    if systemctl --user start "$UNIT" >/dev/null 2>&1; then
        printf 'slots-probe: restored %s\n' "$UNIT"
    else
        warn "FAILED to restart $UNIT — start it by hand"
    fi
    LANE_STOPPED=0
}

# _run_arm <slots> <outdir> — stop the lane, serve at <slots>, measure, stop the arm.
# Returns non-zero when the arm could not be measured; the caller records that as a
# NOT-RUN rather than as a slow slot count.
_run_arm() {
    local _slots="$1" _dir="$2"
    # Two statements, not one: a later word in the same `local` cannot see an earlier one
    # (SC2318), so the log and artifact paths would have been built from empty values.
    local _log="$_dir/arm-${_slots}.log" _art="$_dir/arm-${_slots}.json"
    local _conc="${CONCURRENCY:-$_slots}"
    # A stop that FAILS is not "already down": `systemctl stop` exits 0 for an inactive
    # unit, so a non-zero status means the lane may still hold the port.  Say so — the
    # health wait below then decides, and a held port fails the arm rather than measuring
    # a server this probe did not start.
    if ! systemctl --user stop "$UNIT" >/dev/null 2>&1; then
        warn "could not stop $UNIT — the arm's port may still be held"
    fi
    LANE_STOPPED=1
    "${BASE[@]}" --parallel "$_slots" --kv-unified >"$_log" 2>&1 &
    local _pid=$!
    if ! _wait_health; then
        # swallow-ok: the arm's server may have exited on its own; the health wait already decided
        kill "$_pid" 2>/dev/null || true
        return 1
    fi
    # swallow-ok: same as above — a server that died during load has nothing to kill
    _workload_jsonl "$_dir/workload.jsonl" || { kill "$_pid" 2>/dev/null || true; return 1; }
    "$TAC_PYTHON" "$BENCH" run \
        --endpoint "http://127.0.0.1:${PORT}" \
        --workloads "$_dir/workload.jsonl" \
        --output "$_art" \
        --model-id "$MODEL_ID" \
        --model-file "$MODEL_PATH" \
        --quantization "$(_quant_from_name "$MODEL_PATH")" \
        --runtime-version "${RUNTIME_VERSION:-unknown}" \
        --runtime-build "${RUNTIME_BUILD:-unknown}" \
        --context-size "$CTX" \
        --max-tokens "$MAX_TOKENS" \
        --repetitions "$REPETITIONS" \
        --concurrency "$_conc" \
        --force >>"$_log" 2>&1
    local _rc=$?
    # swallow-ok: the arm's server is expected to be alive here; a kill that finds it gone is the same end state
    kill "$_pid" 2>/dev/null || true
    # swallow-ok: wait's status is the server's, not the measurement's — the bench's rc is returned
    wait "$_pid" 2>/dev/null || true
    # The NEXT arm (and the restore) must find the port free: a bind failure is what rate-limits
    # the unit, and it is the failure this probe caused on its first real run.
    # swallow-ok: a port that never frees is reported by _wait_listen_free; the arm's rc still decides
    _wait_listen_free 30 || true
    return "$_rc"
}

# _summarise <outdir> <ctx> <values-csv> — the table and the JSON, from the arms' artifacts.
# A REQUESTED arm with no artifact is printed as NOT-RUN: an arm that never measured must
# not read as a slot count that measured badly, and must not vanish from the table either.
_summarise() {
    "$TAC_PYTHON" - "$1" "$2" "$3" <<'PYEOF'
import json, pathlib, sys
out = pathlib.Path(sys.argv[1])
ctx = int(sys.argv[2]) if sys.argv[2].isdigit() else 0
requested = [int(v) for v in sys.argv[3].split(",") if v.strip().isdigit()]
rows = []
for slots in sorted(set(requested)):
    art = out / f"arm-{slots}.json"
    agg = per = None
    suspect = ""
    if art.is_file():
        try:
            doc = json.loads(art.read_text(encoding="utf-8"))
            workload = doc["workloads"][0]
            summary = workload["summary"]
            agg = (summary.get("concurrency_group_decode_tokens_per_second") or {}).get("median")
            per = (summary.get("decode_tokens_per_second") or {}).get("median")
            groups = [g.get("decode_tokens_per_second") for g in workload.get("groups", [])
                      if not g.get("warmup")]
            groups = [g for g in groups if isinstance(g, (int, float))]
            if agg is not None and per is not None and agg < per:
                # Impossible, so the ARM is not a measurement.  Measured 2026-11-09: a median of
                # group rates over groups that include a drowned 1.96 settled BELOW one stream's
                # own median.  A rate that cannot exist must not sit in a table looking like data.
                suspect = f"aggregate {agg:.2f} < per-stream {per:.2f} is impossible"
                agg = per = None
            elif len(groups) > 1:
                spread = (max(groups) - min(groups)) / max(groups) if max(groups) > 0 else 1.0
                if spread > 0.5:
                    # The same reading on the first contended run: one group drowned while its
                    # neighbours were healthy — foreign load that ended inside the window.
                    suspect = f"group spread {spread:.0%} (groups {', '.join(f'{g:.1f}' for g in groups)})"
        except (OSError, KeyError, IndexError, ValueError):
            agg = per = None
    rows.append({"slots": slots, "aggregate_tps": agg, "per_stream_tps": per, "suspect": suspect})
# NO per-slot context figure.  An earlier cut printed `ctx / slots / 1024` as "MiB", which was
# wrong twice: it is K TOKENS, not bytes, and every arm passes --kv-unified, so the window is
# SHARED rather than divided — the per-slot arithmetic described a configuration this lane does
# not run.  What actually changes between arms is throughput, and that is what is printed.
if ctx:
    print(f"ctx={ctx} tokens, --kv-unified: the window is shared by all slots, not divided")
print(f"{'slots':>5} {'aggregate tok/s':>16} {'per-stream tok/s':>17}")
for r in rows:
    if r["suspect"]:
        print(f"{r['slots']:>5} {'VOID':>16} {'VOID':>17}   {r['suspect']}")
        continue
    agg = "NOT-RUN" if r["aggregate_tps"] is None else f"{r['aggregate_tps']:.2f}"
    per = "NOT-RUN" if r["per_stream_tps"] is None else f"{r['per_stream_tps']:.2f}"
    print(f"{r['slots']:>5} {agg:>16} {per:>17}")
voided = [r["slots"] for r in rows if r["suspect"]]
if voided:
    print(f"VOID arms: {', '.join(str(v) for v in voided)} — re-run them on a quiet box; "
          f"a void arm is not a slow slot count.")
(out / "summary.json").write_text(json.dumps({"ctx": ctx, "arms": rows}, indent=2) + "\n",
                                  encoding="utf-8")
PYEOF
}

# dry_run — prove the plan and the argv rewrite, start nothing.
dry_run() {
    local _v
    printf 'slots-probe: DRY RUN — nothing is stopped, started or measured\n'
    printf '  unit:   %s\n' "$UNIT"
    printf '  model:  %s\n' "$MODEL_PATH"
    printf '  port:   %s   ctx: %s\n' "$PORT" "$CTX"
    printf '  base:   %s\n' "${BASE[*]}"
    while IFS= read -r _v; do
        printf '  arm %s: %s --parallel %s --kv-unified   (concurrency %s)\n' \
            "$_v" "${BASE[0]}" "$_v" "${CONCURRENCY:-$_v}"
    done < <(_slot_values)
}

# main — parse, prove the plan, then measure each arm and restore the lane.
main() {
    parse_args "$@"
    _unit_argv || exit 1
    if (( DRY_RUN == 1 )); then
        dry_run
        return 0
    fi
    # The box must be quiet BEFORE the first stop: a slot count measured beside foreign load,
    # or whose group windows are shorter than the load that ended before they began, is a
    # number the run's own state invalidated.  Refuse and name the term — never measure anyway
    # and report it as if clean.
    #
    # A COLD CARD is the one refusal this probe can clear itself, so it gets a warm-up rather
    # than a dead end (measured 17:31: 650 of 3,003 MHz with nothing using the card, so every
    # run refused and the sweep could never start).  Only when the clock is the SOLE term:
    # warming beside foreign load, or beside a CI worker, spends 90 s on a run that still
    # refuses.
    local _why=""
    if ! _why="$(_quiet_verdict)"; then
        if [[ "$_why" == "SM clock"* && "$_why" != *"; "* ]]; then
            warn "the card is cold — ${_why}; warming it through the serving lane"
            if _warm_clock 90; then
                # A failing verdict still PRINTS its reason, so _why carries the term either
                # way; an empty _why here means the warm-up cleared the only term that refused.
                _why="$(_quiet_verdict)"
            fi
        fi
    fi
    if [[ -n "$_why" ]]; then
        warn "FATAL: this box is not quiet — ${_why}.  Not measuring."
        warn "  Wait for the job to clear (bin/heavy-job --status) and re-run; a swept row"
        warn "  measured on a busy box is worse than no row."
        exit 1
    fi
    OUT_DIR="${OUT_DIR:-$REPO_ROOT/logs/slots-probe/$(date -u +%Y%m%dT%H%M%SZ)}"
    mkdir -p "$OUT_DIR" || { warn "FATAL: cannot create $OUT_DIR"; exit 1; }
    trap '_restore_lane' EXIT
    trap 'exit "$EXIT_INTERRUPTED"' INT TERM
    local _v _rc=0
    while IFS= read -r _v; do
        printf 'slots-probe: arm %s slots (concurrency %s)\n' "$_v" "${CONCURRENCY:-$_v}"
        if ! _run_arm "$_v" "$OUT_DIR"; then
            warn "arm $_v did not measure — recorded as NOT-RUN"
            _rc=1
        fi
    done < <(_slot_values)
    _summarise "$OUT_DIR" "$CTX" "$VALUES"
    printf 'slots-probe: artifacts in %s\n' "$OUT_DIR"
    return "$_rc"
}

main "$@"
# end of file
