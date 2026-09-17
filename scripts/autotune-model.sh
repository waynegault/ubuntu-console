#!/usr/bin/env bash
# AI INSTRUCTION: On ANY change to this file, increment the Module Version below.
# Module Version: 60
#===============================================================================
# autotune-model.sh — Find optimal ctx/batch/ubatch for one GGUF model.
#
# Phase 1: step down from start until a ctx works.
# Phase 2: step up 50% from working ctx until OOM, then binary probe
#          between the last working ctx and OOM point.
# Search : beam search over batch/ubatch at the winning ctx; in the "almost
#          fits" band, sweep n_gpu_layers and KV-cache quantization (both can
#          free VRAM for a higher ctx than the registry's 999-or-0 binary).
# Phase 4: TPS floor recovery at a *filled* KV cache — the scoring bench
#          pre-fills the context (LLM_AUTOTUNE_FILL_RATIO x ctx, capped) so
#          the floor certifies sustained throughput at the ctx being recorded,
#          not a burst on an empty cache. Prefill tok/s is captured from the
#          server timings and persisted alongside decode.
# Profiles: profile 1 = max ctx sustaining the floor (existing registry
#          columns); profile 2 = max decode TPS config for interactive flows
#          (registry fields 22-26). Winner recorded even when below floor
#          (best-effort honest capability).
# Score  : highest ctx that meets the TPS floor (best-effort max TPS otherwise).
#
# Sources tactical-console functions for VRAM budget, stale process cleanup,
# GGUF metadata, and profile saving — no duplicates.
#===============================================================================

set -uo pipefail

# The model may be given as a registry row NUMBER or as a model FILE name.  Both are
# accepted; the FILE name is the authoritative identity, and a number is resolved to one
# ONCE (see the resolution below, which must run AFTER the console's registry helpers are
# sourced — the reason it is not here).
MODEL_REF="${1:?Usage: autotune-model.sh MODEL_NUM|MODEL_FILE [--workload chat|legal|agentic|mix]}"

# AUTOTUNE-001: workload-selectable scoring payload.  The ctx/batch/TPS
# winner is certified against the workload that matters — legal-RAG for the
# investigator (long, structured, tool-call-shaped prompts), agentic loops,
# the classic chat/physics burn (default), or a mix (interpolation across
# sets).  The workload used is recorded in the registry row so a later
# consumer knows which distribution scored the winner.
# Env: LLM_AUTOTUNE_WORKLOAD (default chat) — the batch runner / investigator
# profile sets it to "legal".
WORKLOAD="${LLM_AUTOTUNE_WORKLOAD:-chat}"
shift  # drop MODEL_NUM
while [[ $# -gt 0 ]]; do
    case "$1" in
        --workload) WORKLOAD="${2:-}"; shift 2 ;;
        *) echo "Unknown arg: $1 (usage: autotune-model.sh MODEL_NUM [--workload chat|legal|agentic|mix])" >&2; exit 2 ;;
    esac
done
case "$WORKLOAD" in
    chat|legal|agentic|mix) ;;
    *) echo "Error: --workload must be one of chat|legal|agentic|mix (got '$WORKLOAD')" >&2; exit 1 ;;
esac

_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$_SELF_DIR/.." || exit 1
source env.sh 2>/dev/null || { echo "Failed to source env.sh"; exit 1; }
# env.sh's degraded-load report goes to stderr, which the line above discards —
# so the exported sentinel is the reliable signal here.  Refuse before any GPU
# work rather than spending a whole bench on a console whose helpers are
# missing (2026-09-13: a sweep "certified" ten rows this way, changing nothing).
if [[ "${TAC_LOAD_DEGRADED:-0}" == "1" ]]; then
    echo "Error: the console loaded degraded (sub-modules failed to load) — refusing to autotune." >&2
    echo "       Run 'source env.sh' in a shell to see which; nothing was benchmarked."
    exit 1
fi
source scripts/01-constants.sh 2>/dev/null || true
source scripts/11-llm-manager.sh 2>/dev/null || true
# AUTOTUNE-001: the SPEC-DEC-006 legal/agentic prompt sets (shared with
# spec-decode-bench.sh) — the scoring payload is built from the workload's
# prompts, so the TPS floor is certified on the real input distribution.
source scripts/prompt-sets.sh 2>/dev/null || true

# Source the tactical console for shared functions (__gguf_metadata, __kv_mb_per_1k,
# __gpu_clear_stale_processes, __llm_autotune_profile_save)
# Falls back to standalone mode if sourcing fails.

# Resolve the model reference to a FILE NAME — the row's definitive identity — now that
# the registry helpers are loaded.  Every idempotent use below (the row lookup, the save,
# the temp-file names) hangs off this, so a `model scan` mid-run cannot make this run's
# numbers land on a different model.  MODEL is then taken from the row itself, so the
# display number is always the current one.
MODEL=""
MODEL_FILE=""
# Startup-validation messages go to STDERR: they report a refusal to start, which is an
# error by the repo's own convention (style checklist 5.4).  Wayne's ruling, 2026-09-17.
# They previously went to stdout to match this script's sibling messages; that is the
# wrong standard for an error path, and the sibling messages are moving with them.
if [[ "$MODEL_REF" =~ ^[0-9]+$ ]]; then
    MODEL_FILE="$(__llm_registry_file_for_row "$MODEL_REF" 2>/dev/null || true)"
    [[ -n "$MODEL_FILE" ]] || { echo "Error: registry row $MODEL_REF does not exist" >&2; exit 1; }
else
    MODEL_FILE="$MODEL_REF"
fi

ENTRY=$(awk -F'|' -v f="$MODEL_FILE" '$3 == f {print; exit}' "$LLM_REGISTRY" 2>/dev/null) || true
[[ -n "$ENTRY" ]] || {
    echo "Error: '$MODEL_REF' is not a model file in the registry — pass a row number or the .gguf file name" >&2
    exit 1; }

IFS='|' read -r _num name file size _qc _arch gpu_layers _ctx _thr _ba _ub _pa _fi _be _mm _fa _tps _autotuned _isdef _vram _prefill _p2ctx _p2b _p2u _p2tps _p2pf _stype _sdmodel _snmax _sngl _sdevice _sacceptlen <<< "$ENTRY"
MODEL="$_num"
[[ -n "$MODEL" ]] || { echo "Error: registry row for '$MODEL_FILE' has no number" >&2; exit 1; }

MODEL_PATH="$LLAMA_MODEL_DIR/$file"
[[ -f "$MODEL_PATH" ]] || { echo "Error: File not found: $MODEL_PATH" >&2; exit 1; }

# The ctx this row currently has recorded, captured before anything can mutate it.  The
# phase-4 descent adds it as a candidate, so a run cannot certify a DIFFERENT window from the
# one the registry holds without having MEASURED the held value — the x3/4 ladder steps over
# values (row 12, 2026-09-17: ... 12288 -> 9216 -> 6656 skipped the recorded 8,192).
PREV_CERT_CTX="${_ctx:-0}"

SIZE_INT=${size%G}; SIZE_INT=${SIZE_INT%.*}; SIZE_INT=${SIZE_INT:-1}
[[ "$SIZE_INT" =~ ^[0-9]+$ ]] || SIZE_INT=1

CPU_COUNT=$(nproc 2>/dev/null || echo 6)
# SPEC-DEC-002: the thread count is hard-capped at the i9-12900HK P-core
# count (6).  nproc inside WSL2 returns 12 (processors=12 in .wslconfig);
# using it uncapped spills decode onto the E-cores and slows generation
# (DFlash article hardware pitfall).  The cap is applied to registry reads
# AND fallbacks so the registry can never hold a >6 value from here.
# REF: "Speculative Decoding on CPUs — Nearly 4x Faster Token Generation
# with DFlash" (Intel, TDS 2026)
# https://towardsdatascience.com/speculative-decoding-on-cpus-nearly-4x-faster-token-generation-with-dflash/
if ! declare -f __llm_thread_cap &>/dev/null; then
    # Standalone fallback (11d-llm-gpu.sh not sourced): same P-core clamp.
    __llm_thread_cap() {
        local _raw="${1:-6}"
        [[ "$_raw" =~ ^[0-9]+$ ]] || _raw=6
        (( _raw > 6 )) && _raw=6
        echo "$_raw"
    }
fi
if [[ "$_thr" =~ ^[0-9]+$ ]] && [[ $_thr -gt 0 ]] && [[ $_thr -le $CPU_COUNT ]]; then
    TUNE_THREADS=$(__llm_thread_cap "$_thr")
else
    TUNE_THREADS=$(__llm_thread_cap "$CPU_COUNT")
fi
BENCH_NGL="${gpu_layers:-999}"
[[ ${gpu_layers:-999} -eq 0 ]] && TUNE_THREADS=$(__llm_thread_cap "$CPU_COUNT")

echo "[${MODEL}] ${name} (${size}, ${gpu_layers:-0} gpu layers)"
echo "  Bench NGL: ${BENCH_NGL}  — max envelope: 999"
echo ""

MIN_CTX=4096
# Uniform minimum acceptable generation speed. Sourced from env.sh (default 10).
MIN_TPS=${LLM_MIN_TPS:-10}

# ── Autotune v4 knobs (documented in env.sh) ────────────────────────────────
FILL_RATIO=${LLM_AUTOTUNE_FILL_RATIO:-0.75}
FILL_MAX_TOKENS=${LLM_AUTOTUNE_FILL_MAX_TOKENS:-16384}
FILL_MIN_TOKENS=${LLM_AUTOTUNE_FILL_MIN_TOKENS:-2048}
MIN_PREFILL_TPS=${LLM_MIN_PREFILL_TPS:-50}
BEAM_WIDTH=${LLM_AUTOTUNE_BEAM_WIDTH:-2}
BEAM_ROUNDS=${LLM_AUTOTUNE_BEAM_ROUNDS:-2}
NGL_BAND_FRAC=${LLM_AUTOTUNE_NGL_BAND_FRAC:-0.55}
BENCH_TIMEOUT=${LLM_AUTOTUNE_BENCH_TIMEOUT:-300}
KV_QUANTS=${LLM_AUTOTUNE_KV_QUANTS:-"q8_0/q8_0 q4_0/q4_0"}

# Sanitize the numeric knobs so a bad env value can't produce garbage math.
[[ "$FILL_RATIO" =~ ^0(\.[0-9]+)?$|^1(\.0+)?$ ]] || FILL_RATIO=0.75
[[ "$FILL_MAX_TOKENS" =~ ^[0-9]+$ ]] && [[ $FILL_MAX_TOKENS -gt 0 ]] || FILL_MAX_TOKENS=16384
[[ "$FILL_MIN_TOKENS" =~ ^[0-9]+$ ]] && [[ $FILL_MIN_TOKENS -gt 0 ]] || FILL_MIN_TOKENS=2048
[[ "$MIN_PREFILL_TPS" =~ ^[0-9]+(\.[0-9]+)?$ ]] || MIN_PREFILL_TPS=0
[[ "$BEAM_WIDTH" =~ ^[0-9]+$ ]] && [[ $BEAM_WIDTH -ge 1 ]] || BEAM_WIDTH=2
[[ "$BEAM_ROUNDS" =~ ^[0-9]+$ ]] && [[ $BEAM_ROUNDS -ge 0 ]] || BEAM_ROUNDS=2
[[ "$NGL_BAND_FRAC" =~ ^0(\.[0-9]+)?$|^1(\.0+)?$ ]] || NGL_BAND_FRAC=0.55
[[ "$BENCH_TIMEOUT" =~ ^[0-9]+$ ]] && [[ $BENCH_TIMEOUT -gt 0 ]] || BENCH_TIMEOUT=300
[[ $FILL_MAX_TOKENS -lt $FILL_MIN_TOKENS ]] && FILL_MAX_TOKENS=$FILL_MIN_TOKENS

# --- WSL2 dxgkrnl leak accounting (CUDA context-cycle ledger) ---
# dxgkrnl leaks GPU VA on every CUDA context create/destroy, and a fresh
# llama-server per bench is one create/destroy: probe + beam + sweeps + Phase 4
# are ~10-20 cycles per row, so a 10-row sweep is ~150-200 in one WSL session.
# Leaking enough VA hangs the VM, and only `wsl --shutdown` clears it — so the
# ledger is ENFORCED here, not merely counted (it used to be written and never
# read, while the batch runner's own guard went unapplied whenever a row was
# driven directly, as the 2026-09-13 sweep's ad-hoc driver did).
#
# Defined ahead of the pre-flight VRAM-baseline guard below (which calls
# _cuda_guard_or_exit before any spawn) — bash resolves function calls at
# runtime, not at parse time, so calling it before this block executes is a
# "command not found" (2026-09-14: `autotune-model.sh` line 208 called the
# guard while its definition sat ~250 lines further down, unreached).
#
# /dev/shm, not /tmp: this is the leak's ledger, and /tmp is cleaned aggressively
# on this box — a mid-boot clean would silently reset the budget while the leak
# persists (observed 2026-09-14). Namespaced by boot ID because a WSL restart is
# the only leak reset. Exported so rows, batches and children share one ledger.
_AUTOTUNE_BOOT_ID="$(tr -d '-' < /proc/sys/kernel/random/boot_id 2>/dev/null | cut -c1-12)"
_CUDA_CYCLE_FILE="${CUDA_CYCLE_FILE:-/dev/shm/autotune-cuda-cycles-${_AUTOTUNE_BOOT_ID:-unknown}}"
_CUDA_STALL_FILE="${CUDA_STALL_FILE:-/dev/shm/autotune-degrade-stalls-${_AUTOTUNE_BOOT_ID:-unknown}}"
export CUDA_CYCLE_FILE
# Halting budget, same default and same counter file as run-autotune-batch.sh:
# the batch runner derived 60 from the measured knee (~26 launch/kill cycles at
# 109K ctx collapsed tps ~16 -> ~3.8, 2026-09-05); the probe is now capped near
# 54K so each cycle leaks less, and 60 sits below the ~70-100 threshold there.
CUDA_CYCLE_BUDGET="${CUDA_CYCLE_BUDGET:-60}"
# Consecutive launches that stall (health never ready, process still alive, no
# architecture error) — the dxgkrnl degradation signature — before halting.
# 0 disables. Two matches the standing bench rule: 2 consecutive failures and
# stop for diagnosis. A legitimately over-large start ctx has the same shape,
# which is why it takes two rather than one.
CUDA_DEGRADE_CONSECUTIVE_STALLS="${CUDA_DEGRADE_CONSECUTIVE_STALLS:-2}"

_cuda_cycles() {
    local n=0
    [[ -f "$_CUDA_CYCLE_FILE" ]] && n=$(cat "$_CUDA_CYCLE_FILE" 2>/dev/null || echo 0)
    [[ "$n" =~ ^[0-9]+$ ]] || n=0
    printf '%s\n' "$n"
}

_cuda_stalls() {
    local n=0
    [[ -f "$_CUDA_STALL_FILE" ]] && n=$(cat "$_CUDA_STALL_FILE" 2>/dev/null || echo 0)
    [[ "$n" =~ ^[0-9]+$ ]] || n=0
    printf '%s\n' "$n"
}

_cuda_stall_bump() { printf '%s\n' "$(( $(_cuda_stalls) + 1 ))" > "$_CUDA_STALL_FILE" 2>/dev/null; }
_cuda_stall_reset() { : > "$_CUDA_STALL_FILE" 2>/dev/null; }

_bump_cuda_cycle() {
    printf '%s\n' "$(( $(_cuda_cycles) + 1 ))" > "$_CUDA_CYCLE_FILE" 2>/dev/null
    return 0
}

# _cuda_guard_or_exit — halt BEFORE the next spawn when the ledger says the
# adapter is at risk. Called at top level (the pre-flight and ahead of every
# phase), so a refusal stops the run instead of degrading into "one more failed
# bench", and the overshoot is bounded by a single phase — well inside the
# budget's margin. exit 3 is distinct so a driver can halt its whole sweep.
_cuda_guard_or_exit() {
    local c s
    c=$(_cuda_cycles)
    if (( c >= CUDA_CYCLE_BUDGET )); then
        echo "ERROR: CUDA context-cycle budget reached (${c} >= ${CUDA_CYCLE_BUDGET}) — WSL2 dxgkrnl leaks GPU VA on every llama-server spawn and an exhausted adapter hangs the VM." >&2
        echo "       Restart WSL from Windows ('wsl --shutdown') to reset the ledger; nothing was certified this run." >&2
        exit 3
    fi
    if (( CUDA_DEGRADE_CONSECUTIVE_STALLS > 0 )); then
        s=$(_cuda_stalls)
        if (( s >= CUDA_DEGRADE_CONSECUTIVE_STALLS )); then
            echo "ERROR: ${s} consecutive launches stalled (health never ready while the process stayed alive) — the dxgkrnl degradation signature, at ${c}/${CUDA_CYCLE_BUDGET} cycles." >&2
            echo "       Restart WSL from Windows ('wsl --shutdown'); nothing was certified this run." >&2
            exit 3
        fi
    fi
    return 0
}

# ---------------------------------------------------------------------------
# VRAM-baseline guarantee: the KV-math START_CTX below is only trustworthy
# if FREE_VRAM reflects a CLEARED GPU.  A concurrent llama-server or stale
# CUDA process silently shrinks BUDGET and collapses START_CTX to MIN_CTX
# (2026-08-27: Llama-3.2-3B certified 4096 while a parallel run held the
# card — the machine had headroom for far more once VRAM was fully cleared).
# Kill CUDA-held llama.cpp servers (the Xe fleet and the persistent llama
# systemd units are structurally spared — they hold no CUDA VRAM) + stale
# GPU processes + WSL2 ghost-VRAM double-kill BEFORE the baseline read, then
# verify free VRAM against the card total.
# ---------------------------------------------------------------------------
if declare -f __llm_kill_cuda_llama_servers &>/dev/null; then
    __llm_kill_cuda_llama_servers || true
else
    echo "WARN: __llm_kill_cuda_llama_servers not loaded — skipping llama cleanup (a name-based pkill would evict the Xe fleet)" >&2
fi
# The OpenClaw gateway's local embedding workers each hold ~430 MiB VRAM
# (embeddinggemma-300m on CUDA); the gateway respawns them on demand, so
# killing them here is safe and self-healing. Bracket the pattern so
# pkill -f cannot match this script's own cmdline (2026-08-28).
# Graceful first — SIGKILL orphans the worker's CUDA handles in WSL2's dxgkrnl
# VMBus channel; SIGTERM lets it exit and release them cleanly, escalating to
# SIGKILL only if it does not exit within 10s.
pkill -u "$(id -un)" -f "memory-core-local-embedding-worker[.]js" 2>/dev/null || true
_ew_wait=0
while pgrep -u "$(id -un)" -f "memory-core-local-embedding-worker[.]js" >/dev/null 2>&1 && [[ $_ew_wait -lt 10 ]]; do
    sleep 1; _ew_wait=$((_ew_wait + 1))
done
pkill -9 -u "$(id -un)" -f "memory-core-local-embedding-worker[.]js" 2>/dev/null || true
sleep 1
if declare -f __gpu_clear_stale_processes &>/dev/null; then
    __gpu_clear_stale_processes || true
fi
# WSL2 ghost-VRAM release — same double-kill trick cleanup_gpu uses later.
pkill -9 -u "$(id -un)" -x nvidia-smi 2>/dev/null || true
sleep 1
sync 2>/dev/null || true
if [[ -w /proc/sys/vm/drop_caches ]]; then
    echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
fi
nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits >/dev/null 2>&1 || true
pkill -9 -u "$(id -un)" -x nvidia-smi 2>/dev/null || true
sleep 1
VRAM_TOTAL=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ')
VRAM_TOTAL=${VRAM_TOTAL:-4096}
FREE_VRAM=$(nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ')
FREE_VRAM=${FREE_VRAM:-3965}
# Trust check: after clearing, free VRAM must sit ~at the card total.  A
# large gap means a foreign process still holds the GPU — a certification
# against that baseline would be untrustworthy, so fail loudly instead.
# Tolerance is generous (default 800 MiB) because the guard runs AFTER
# the CUDA-scoped llama cleanup — a surviving hold is either ghost VRAM or a
# stable non-llama service (e.g. the OpenClaw memory embedding worker, ~430 MiB
# on this box, 2026-08-28) that FREE_VRAM reflects deterministically and the
# KV-math BUDGET accounts for.  A concurrent autotune/serving server would
# hold >1 GB, still caught.
BASELINE_GAP_MAX=${LLM_AUTOTUNE_BASELINE_GAP_MAX:-800}
BASELINE_GAP=$(( VRAM_TOTAL - FREE_VRAM ))
if (( BASELINE_GAP > BASELINE_GAP_MAX )); then
    echo "ERROR: VRAM baseline not cleared — ${FREE_VRAM} MiB free of ${VRAM_TOTAL} MiB (${BASELINE_GAP} MiB still held). Refusing to autotune against an untrustworthy baseline." >&2
    exit 1
fi
# Refuse before the first spawn if the dxgkrnl ledger is already exhausted.
_cuda_guard_or_exit
MODEL_BYTES=$(stat --format=%s "$MODEL_PATH" 2>/dev/null || echo 0)
MODEL_MB=$(( MODEL_BYTES / 1048576 ))

# Combos — selected by GGUF file size to avoid guaranteed-OOM combos on large models
if [[ $MODEL_MB -lt 1000 ]]; then
    COMBOS=("1024:256" "2048:512" "4096:1024")
elif [[ $MODEL_MB -lt 2000 ]]; then
    COMBOS=("1024:256" "2048:512")
else
    COMBOS=("1024:256")
fi

BUDGET=$(( FREE_VRAM - MODEL_MB - 200 ))

if declare -f __kv_mb_per_1k &>/dev/null && declare -f __gguf_metadata &>/dev/null; then
    # Shared function path — architecture-aware estimate
    _meta=$(__gguf_metadata "$MODEL_PATH" 2>/dev/null || true)
    if [[ -n "$_meta" ]]; then
        _n_layers=$(echo "$_meta" | cut -d'|' -f3)
        _native_ctx=$(echo "$_meta" | cut -d'|' -f4)
        _kv_mb=$(__kv_mb_per_1k "${_n_layers:-0}")
    else
        _native_ctx=""
        _kv_mb=$(__kv_mb_per_1k "0")
    fi
    if (( BUDGET > 0 )); then
        START_CTX=$(awk -v b="$BUDGET" -v k="$_kv_mb" 'BEGIN{c=int((b/k)*1000); print c<4096?4096:c}')
    else
        START_CTX=$MIN_CTX
    fi
else
    # Standalone fallback: size-class factor heuristic
    _native_ctx=""
    if [[ $MODEL_MB -gt 3000 ]]; then FACTOR=50
    elif [[ $MODEL_MB -gt 2000 ]]; then FACTOR=100
    elif [[ $MODEL_MB -gt 1000 ]]; then FACTOR=500
    else FACTOR=1000; fi
    if [[ $BUDGET -gt 0 ]]; then START_CTX=$(( BUDGET * FACTOR ))
    else START_CTX=$MIN_CTX; fi
fi

START_CTX=$(( (START_CTX / 1024) * 1024 ))
[[ $START_CTX -lt $MIN_CTX ]] && START_CTX=$MIN_CTX
[[ $START_CTX -gt 4194304 ]] && START_CTX=4194304

# Probe bounds — floor AND ceiling — come from __autotune_ctx_bounds in
# scripts/11b-llm-autotune.sh: a pure function, so the arithmetic is unit-tested
# without a GPU (tests/unit/13-gguf-ctx-bounds.bats).  It is REQUIRED, not
# best-effort: the console's modules are already mandatory for this script to record
# anything (see the profile-save guard further down), so a standalone run only ever
# burned card time and then refused to save.  Failing here is the same verdict before
# the cost.  What the bounds encode (all measured 2026-09-16):
#
#   * ceiling = the model NATIVE window.  llama.cpp caps the served window to
#     <arch>.context_length at load ("exceeds the training context of the model
#     (2048) - capping"), so a probe above it measures the SAME window under a bigger
#     label — and everything sized from that label is then rejected mid-request
#     ("exceeds the available context size (4096 tokens)"), a 400 that killed the
#     filled-cache certification and the TTFT probe on every clamped row.
#   * ceiling, second cap = LLM_AUTOTUNE_VRAM_CAP_MULT × the KV-fit estimate (default
#     2).  2× is an estimate of where the filled-cache decode collapses, and for a
#     model whose real window is larger it under-probes BY DESIGN: Phi-3.5-mini
#     (native 131072) serves 32768 FULL in 9 s while a 2× cap stops the probe near
#     15360.  Raising it is not a licence to certify a slow window — Phase 4's
#     TPS-first descent still refuses anything that cannot hold MIN_TPS.
#   * floor = MIN_CTX, but it FOLLOWS THE CEILING DOWN.  A model whose window is below
#     MIN_CTX (legalparam's 2048) must still be searchable; otherwise the phase-1 loop
#     `while [[ $c -ge $MIN_CTX ]]` runs ZERO iterations and the row is aborted as an
#     "unsupported model" having attempted nothing (three runs lost to that on
#     2026-09-16).
if ! declare -f __autotune_ctx_bounds &>/dev/null || ! declare -f __autotune_descent_candidates &>/dev/null; then
    echo "ERROR: __autotune_ctx_bounds / __autotune_descent_candidates are not loaded (scripts/11b-llm-autotune.sh missing?) — refusing to autotune without tested ctx bounds." >&2
    exit 1
fi
read -r START_CTX MAX_CTX MIN_CTX < <(__autotune_ctx_bounds \
    "$START_CTX" "${_native_ctx:-}" "${LLM_AUTOTUNE_VRAM_CAP_MULT:-2}" "$MIN_CTX")

# Comma-format numbers (standalone helpers — no outer-scope capture)
fmt() { printf "%'d" "$1"; }
# fmts — comma-format each "batch:ubatch" combo passed as args.
fmts() { local _c _out=""; for _c in "$@"; do _out+="$(printf "%'d:%'d " "${_c%%:*}" "${_c##*:}")"; done; printf '%s' "${_out% }"; }

echo "============================================="
echo ""
echo "  threads=$(fmt "$TUNE_THREADS")  cpu=$(fmt "$CPU_COUNT")"
echo "  combos: $(fmts "${COMBOS[@]}")"
echo "  probe:  start=$(fmt "$START_CTX") min_tps=${MIN_TPS}  workload=${WORKLOAD}"
START_TS=$(date '+%H:%M:%S')
echo "  start:  ${START_TS}"
echo ""
START_EPOCH=$(date +%s)

LLAMA_BIN="${LLAMA_SERVER_BIN:-$HOME/llama.cpp/build/bin/llama-server}"

# ── Workload scoring payload (AUTOTUNE-001) ─────────────────────────────────
# The scoring payload is built from the selected workload's SPEC-DEC-006
# prompt set so the ctx/batch/TPS winner (and the filled-cache TPS floor) is
# certified against the workload that matters.  chat = the classic physics
# burn (default, unchanged for generic use); legal = the investigator's
# legal-RAG prompts; agentic = tool-call loops; mix = interpolation across
# sets (legal prompt under an agentic tool-call system instruction).
# The workload used is recorded in the registry row.
__workload_payload_json() {
    local _w="$1" _system=""
    case "$_w" in
        legal)
            _prompt="${PROMPTS_LEGAL[0]:-}"
            ;;
        agentic)
            _prompt="${PROMPTS_AGENTIC[0]:-}"
            ;;
        mix)
            _system="You have tools: search_corpus(query), fetch_document(id), summarize(text). Plan and execute the minimal sequence of tool calls, then return a structured verdict."
            _prompt="${PROMPTS_LEGAL[0]:-} ${PROMPTS_AGENTIC[0]:-}"
            ;;
        chat|*)
            _prompt="${PROMPTS_PHYSICS[0]:-Explain special relativity: time dilation, length contraction, mass-energy equivalence.}"
            ;;
    esac
    "$TAC_PYTHON" - "$_system" "$_prompt" << 'PYEOF'
import json, sys
system, prompt = sys.argv[1], sys.argv[2]
messages = []
if system:
    messages.append({"role": "system", "content": system})
messages.append({"role": "user", "content": prompt})
payload = {"messages": messages, "max_tokens": 256, "temperature": 0}
print(json.dumps(payload))
PYEOF
}
# __workload_prompt_text <chat|legal|agentic|mix> — @stdout the plain prompt
# text (without the system wrapper) used to pre-fill the KV cache, so the
# fill distribution matches the scoring distribution.
__workload_prompt_text() {
    case "$1" in
        legal)   printf '%s\n' "${PROMPTS_LEGAL[0]:-}" ;;
        agentic) printf '%s\n' "${PROMPTS_AGENTIC[0]:-}" ;;
        mix)     printf '%s\n' "${PROMPTS_LEGAL[0]:-} ${PROMPTS_AGENTIC[0]:-}" ;;
        chat|*)  printf '%s\n' "${PROMPTS_PHYSICS[0]:-Explain special relativity: time dilation, length contraction, mass-energy equivalence.}" ;;
    esac
}

PAYLOAD_FILE="/tmp/autotune-payload-${MODEL}.json"
__workload_payload_json "$WORKLOAD" > "$PAYLOAD_FILE"

# Filled-cache payload generator — pre-fills the KV cache with a long prompt
# (FILL_RATIO x ctx, capped by LLM_AUTOTUNE_FILL_MAX_TOKENS) so the scoring
# bench measures sustained decode at the ctx being certified instead of a burst
# on an empty cache, and yields a real prefill tok/s measurement. On CPU-only
# models prefill is slow, so the cap is tightened to keep a bench bounded.
# The fill repeats the WORKLOAD prompt (not a generic sentence) so the cache
# pressure matches the workload's token distribution (AUTOTUNE-001).
# args: ctx payload_file
gen_fill_payload() {
    local _ctx="$1" _out="$2"
    local _fill_tokens _source
    _fill_tokens=$(awk -v c="$_ctx" -v r="$FILL_RATIO" 'BEGIN{printf "%d", c*r}')
    [[ $_fill_tokens -gt $FILL_MAX_TOKENS ]] && _fill_tokens=$FILL_MAX_TOKENS
    [[ $_fill_tokens -lt $FILL_MIN_TOKENS ]] && _fill_tokens=$FILL_MIN_TOKENS
    if [[ "${BENCH_NGL:-999}" == "0" ]]; then
        local _cpu_cap=8192
        [[ $_fill_tokens -gt $_cpu_cap ]] && _fill_tokens=$_cpu_cap
    fi
    _source="$(__workload_prompt_text "$WORKLOAD")"
    "$TAC_PYTHON" - "$_fill_tokens" "$_out" "$_source" << 'PYEOF'
import json, sys
tokens = int(sys.argv[1])
out = sys.argv[2]
source = sys.argv[3]
count = tokens * 4 // max(1, len(source)) + 1
content = (source * count)[: tokens * 5]
payload = {
    "messages": [{"role": "user", "content": content}],
    "max_tokens": 256,
    "temperature": 0,
}
with open(out, "w") as f:
    json.dump(payload, f)
PYEOF
}

# Fast-reject payload generator — a SMALL prefill (2048 tokens) + tiny decode
# budget (32 tokens) so the Phase-4 descent can classify a ctx as above/below
# the TPS floor in ~1-2 min instead of the ~30 min a full 16K-token fill costs
# at a spilling ctx. The spill signature (KV cache paging to host RAM) shows
# within the first ~1K prefill tokens and collapses decode, so the small sample
# is a faithful above/below-floor vote. The recorded number still comes from
# the full-fill certification, so this never weakens the final result.
gen_fast_fill_payload() {
    local _out="$1"
    local _source; _source="$(__workload_prompt_text "$WORKLOAD")"
    "$TAC_PYTHON" - "$_out" "$_source" << 'PYEOF'
import json, sys
out = sys.argv[1]
source = sys.argv[2]
tokens = 2048
count = tokens * 4 // max(1, len(source)) + 1
content = (source * count)[: tokens * 5]
payload = {
    "messages": [{"role": "user", "content": content}],
    "max_tokens": 32,
    "temperature": 0,
}
with open(out, "w") as f:
    json.dump(payload, f)
PYEOF
}

#==============================================================================
# Helpers
#==============================================================================

# Shared cleanup — kills llama-server, stale processes, and forces WSL2
# ghost-VRAM release via nvidia-smi query-context reset (double-kill trick).
# This is the fast path (~2 s). The full nvidia-uvm reload (clear_vram.sh)
# runs between models in the bench loop, not between every ctx probe.
# Nested function — captures $MODEL from parent scope for temp-file naming
cleanup_gpu() {
    local max_retries="${1:-1}"
    local attempt=0
    while [[ $attempt -lt $max_retries ]]; do
        # CUDA-scoped llama kill — never the Xe fleet / persistent units.
        if declare -f __llm_kill_cuda_llama_servers &>/dev/null; then
            __llm_kill_cuda_llama_servers || true
        fi
        sleep 1
        if declare -f __gpu_clear_stale_processes &>/dev/null; then
            __gpu_clear_stale_processes
        fi

        # WSL2 ghost-VRAM workaround: kill nvidia-smi to recycle the CUDA
        # query context, then double-kill to trigger dxgkrnl release.
        # Does NOT reload nvidia-uvm (too slow for per-probe use).
        pkill -9 -u "$(id -un)" -x nvidia-smi 2>/dev/null || true
        sleep 1
        sync 2>/dev/null || true
        if [[ -w /proc/sys/vm/drop_caches ]]; then
            echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
        fi
        nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits >/dev/null 2>&1 || true
        pkill -9 -u "$(id -un)" -x nvidia-smi 2>/dev/null || true
        sleep 1

        local waited=0
    local cleanup_port="${AUTOTUNE_PORT:-18082}"
        while [[ $waited -lt 20 ]]; do
            if ! ss -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:)$cleanup_port\$"; then return 0; fi
            sleep 1; waited=$((waited + 1))
        done

        attempt=$((attempt + 1))
        [[ $attempt -lt $max_retries ]] && sleep 2
    done
    echo "ERROR: Port $cleanup_port still occupied after ${max_retries} cleanup attempts" >&2
    return 1
}

# ---------------------------------------------------------------------------
# _bench_stop <pid> — graceful llama-server shutdown (WSL2 dxgkrnl leak fix).
#   SIGKILL bypasses llama-server's clean teardown and orphans its CUDA/DirectX
#   handles in the host dxgkrnl VMBus channel; the orphaned contexts accumulate
#   until dxgkio_destroy_allocation fails with -512.  SIGTERM lets llama-server
#   run its destructor (ggml_backend_free → cudaFree) and release the handles
#   cleanly.  Poll up to 15s for a graceful exit, escalating to SIGKILL only if
#   the process is genuinely stuck.  A clean exit normally lands in 1-3s.
# ---------------------------------------------------------------------------
_bench_stop() {
    local _p="$1" _w=0
    [[ "$_p" =~ ^[0-9]+$ ]] || return 0
    kill "$_p" 2>/dev/null || true
    while [[ $_w -lt 15 ]]; do
        kill -0 "$_p" 2>/dev/null || return 0
        sleep 1; _w=$((_w + 1))
    done
    kill -9 "$_p" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# _bench_spawn — launch llama-server once (flash-attn retry), pre-flight, and
#   warm up the GPU.  On success sets the module globals _BENCH_PID,
#   _BENCH_HEALTH_URL and _BENCH_LOG and returns 0; on failure writes the
#   "0|0|<type>" metric line and returns 1.  Split out of bench_once so a
#   multi-sample bench can spawn ONE server and reuse its CUDA context across
#   every sample instead of creating/destroying a context per sample (WSL2
#   dxgkrnl leaks GPU VA on each context create/destroy — see bench_once_multi).
#   args: ctx batch ubatch [mmap_mode] [ngl] [kv_k] [kv_v]
# ---------------------------------------------------------------------------
_bench_spawn() {
    local c="$1" b="$2" u="$3" mmap_mode="${4:-auto}" override_ngl="${5:-}" kv_k="${6:-q8_0}" kv_v="${7:-q8_0}"
    local effective_ngl="${override_ngl:-${BENCH_NGL:-999}}"
    local autotune_port="${AUTOTUNE_PORT:-18082}"
    local health_url="http://127.0.0.1:$autotune_port"
    _BENCH_PID="" _BENCH_HEALTH_URL="$health_url" _BENCH_LOG="/tmp/at-${MODEL}-c${c}-b${b}.log"

    # build 10955 removed --no-mmap; an array (not a string) so the two words
    # stay two argv entries and shellcheck's SC2086 stays quiet.
    local -a mmap_flag=()
    [[ $mmap_mode == off ]] && mmap_flag=(--load-mode none)

    # Flash-attn can hang or crash model load for some architectures (e.g.
    # qwen35 / certain Q8/F16 quants) — retry once with it off before
    # declaring the model unloadable.
    local flash_attn="on"
    local hw=0
    _launch_server() {
        local -a fa_args=()
        [[ $flash_attn == "on" ]] && fa_args=(--flash-attn on) || fa_args=(--flash-attn off)
        # SPEC-DEC-004: the block-size sweep drives spec-decode via these
        # globals (BENCH_SPEC_TYPE / BENCH_SPEC_N_MAX / BENCH_SPEC_DRAFT_MODEL);
        # "off" (the default during the ctx/batch search) passes no flags.
        # Flags use the VERIFIED llama.cpp @1692f9e50 names — the removed
        # --draft-model / --speculative-ngram crash the server.
        # REF: DFlash TDS article (Intel, 2026).
        local -a spec_args=()
        if [[ "${BENCH_SPEC_TYPE:-off}" == "ngram" ]]; then
            local _block="${BENCH_SPEC_N_MAX:-16}"
            spec_args=(--spec-type ngram-mod \
                --spec-ngram-mod-n-max "$_block" \
                --spec-ngram-mod-n-min "$_block")
        elif [[ -n "${BENCH_SPEC_DRAFT_MODEL:-}" ]]; then
            spec_args=(--spec-draft-model "$BENCH_SPEC_DRAFT_MODEL" --spec-draft-device none)
            [[ -n "${BENCH_SPEC_N_MAX:-}" ]] && spec_args+=(--spec-draft-n-max "$BENCH_SPEC_N_MAX")
        fi
        "$LLAMA_BIN" --model "$MODEL_PATH" --port "$autotune_port" --host 127.0.0.1 \
            --ctx-size "$c" --batch-size "$b" --ubatch-size "$u" \
            --threads "$TUNE_THREADS" --n-gpu-layers "$effective_ngl" \
            --parallel "${BENCH_PARALLEL:-1}" --fit off "${fa_args[@]}" --kv-offload \
            --cache-type-k "$kv_k" --cache-type-v "$kv_v" "${mmap_flag[@]}" \
            "${spec_args[@]}" \
            > "$_BENCH_LOG" 2>&1 &
        _BENCH_PID=$!
        _bump_cuda_cycle
        hw=0
        while [[ $hw -lt 90 ]]; do
            sleep 1; hw=$((hw + 1))
            kill -0 "$_BENCH_PID" 2>/dev/null || return 1
            curl -sS --max-time 2 "$health_url/health" 2>/dev/null | grep -q '"status":"ok"' && return 0
        done
        return 1
    }
    # Classify a failed startup from the server log: a hard load failure
    # (unsupported/corrupt GGUF, missing file) must not be mistaken for OOM —
    # OOM descends to a smaller ctx, a load failure aborts the remaining
    # combos. When the process dies, only the log tells the two apart.
    #
    # The matched line goes to stderr as well as the label going to stdout: the
    # server log is deleted when the spawn unwinds, so a bare "unsupported model"
    # left no evidence at all behind it.  Two consecutive row-4 failures on
    # 2026-09-16 (legalparam, which loads fine in 3 s under the same flags) were
    # un-diagnosable for exactly that reason — the one line that named the cause
    # had already been thrown away.  Never discard the only witness.
    _startup_fail_type() {
        local _pat='unknown model architecture|failed to load model|error loading model|unsupported (model|architecture)|failed to open|no such file'
        if grep -qiE "$_pat" "$_BENCH_LOG" 2>/dev/null; then
            echo "  server log said: $(grep -iE "$_pat" "$_BENCH_LOG" 2>/dev/null | tail -1)" >&2
            printf 'load_fail'
        else
            printf 'oom'
        fi
    }
    _launch_server || {
        if [[ $flash_attn == "on" ]]; then
            echo "  flash-attn load failure — retrying with --flash-attn off" >&2
            _bench_stop "$_BENCH_PID"
            flash_attn="off"
            _launch_server || true
        fi
    }
    if [[ $hw -ge 90 ]]; then
        # Tell a *stall* apart from a real load failure: the process is still
        # alive and the log has no architecture/GGUF error, so the server simply
        # never became healthy — the dxgkrnl degradation signature.  (A
        # legitimately over-large start ctx looks the same, hence the
        # consecutive threshold rather than a single trip.)
        local _sft; _sft=$(_startup_fail_type)
        if kill -0 "$_BENCH_PID" 2>/dev/null && [[ "$_sft" != "load_fail" ]]; then
            _cuda_stall_bump
            # Say it out loud.  The metrics field below keeps writing load_fail
            # because that value is what makes the callers ABORT the remaining
            # combos instead of descending — the right response for a stall too —
            # but a stall is not an unsupported model, and the operator reading
            # "unsupported model" is sent to the wrong place entirely.
            echo "  the server never became healthy in 90s while the process stayed alive — dxgkrnl degradation, NOT an unsupported model" >&2
        else
            _cuda_stall_reset
        fi
        _bench_stop "$_BENCH_PID"
        echo "0|0|load_fail" > "/tmp/at-metrics-$$"; _BENCH_FAIL_TYPE="load_fail"; return 1
    fi

    # Pre-flight: confirm model slot is actually ready to serve.
    # /health can return OK before the GGUF memory-map completes, so the
    # first real completion may stall or return 0 tokens (worst on slow
    # mounts); probe one real completion before benchmarking.
    local pf_ok=0 pf_w=0
    while [[ $pf_w -lt 60 ]]; do
        if curl -sS --max-time 5 "$health_url/v1/chat/completions" \
            -H "Content-Type: application/json" \
            -d '{"messages":[{"role":"user","content":"hi"}],"max_tokens":1,"temperature":0}' \
            2>/dev/null | "$TAC_PYTHON" -c "import sys,json; d=json.load(sys.stdin); print(d.get('usage',{}).get('completion_tokens',0))" 2>/dev/null | grep -q '[1-9]'; then
            pf_ok=1; break
        fi
        kill -0 "$_BENCH_PID" 2>/dev/null || { local _sft; _sft=$(_startup_fail_type); echo "0|0|$_sft" > "/tmp/at-metrics-$$"; _BENCH_FAIL_TYPE="$_sft"; return 1; }
        sleep 1; pf_w=$((pf_w + 1))
    done
    if [[ $pf_ok -ne 1 ]]; then
        _bench_stop "$_BENCH_PID"
        echo "0|0|oom" > "/tmp/at-metrics-$$"; _BENCH_FAIL_TYPE="oom"; return 1
    fi

    # GPU warmup: wake clocks from power-save (P5/P8 → P0).
    # Laptop GPUs idle at 1035 MHz (~19 TPS) but can reach 1600+ MHz (60+ TPS).
    # 8 tokens isn't enough compute — use 64 when cold, 8 when already warm.
    local warmup_tokens=8
    local _pstate; _pstate=$(nvidia-smi --query-gpu=pstate --format=csv,noheader 2>/dev/null | head -1 | tr -d ' ')
    if [[ -n "$_pstate" ]] && [[ "$_pstate" != "P0" ]]; then
        warmup_tokens=64
    fi
    curl -sS --max-time 30 "$health_url/v1/chat/completions" \
        -H "Content-Type: application/json" \
        -d "{\"messages\":[{\"role\":\"user\",\"content\":\"Warmup\"}],\"max_tokens\":${warmup_tokens},\"temperature\":0}" \
        > /dev/null 2>&1 || true

    _cuda_stall_reset   # a healthy launch breaks the consecutive-stall chain
    return 0
}

# ---------------------------------------------------------------------------
# _bench_resolve_payload — echo "payload_file|bench_timeout" for a bench at
#   the given ctx + mode (quick / filled / filled fast-reject).  Resolved once
#   so every sample of a multi-sample bench reuses the same payload file.
# ---------------------------------------------------------------------------
_bench_resolve_payload() {
    local c="$1" mode="$2"
    local payload_file="$PAYLOAD_FILE" bench_timeout="$BENCH_TIMEOUT"
    if [[ $mode == filled ]]; then
        if [[ "${_FAST_REJECT:-0}" == "1" ]]; then
            payload_file="/tmp/at-fast-${MODEL}-${c}.json"
            [[ -f $payload_file ]] || gen_fast_fill_payload "$payload_file"
            # Fast-reject (Phase-4 descent): a 2K fill + 32-token decode is
            # enough to vote above/below floor; keep the timeout tight so a
            # hung spill fails fast instead of burning the descent.
            [[ $bench_timeout -lt 180 ]] && bench_timeout=180
        else
            payload_file="/tmp/at-fill-${MODEL}-${c}.json"
            [[ -f $payload_file ]] || gen_fill_payload "$c" "$payload_file"
            # Filled prefill can be slow: with the KV cache spilling into host RAM
            # at huge ctx, prefill can drop below 55 tok/s, and lower still under
            # concurrent load. Give generous headroom so slow-but-real prefills
            # complete and are measured instead of timing out and being
            # misclassified as OOM (which forces unnecessary Phase-4 descents).
            [[ $bench_timeout -lt 1200 ]] && bench_timeout=1200
        fi
    fi
    echo "${payload_file}|${bench_timeout}"
}

# ---------------------------------------------------------------------------
# _bench_request_once — one completion request against the spawned server.
#   args: mode payload_file bench_timeout
#   Returns decode TPS on stdout (empty + rc 1 on OOM/sentinel); writes the
#   metrics file.  Does NOT kill the server — the caller owns the lifecycle so
#   multiple samples can share one CUDA context (see bench_once_multi).
# ---------------------------------------------------------------------------
_bench_request_once() {
    local mode="$1" payload_file="$2" bench_timeout="$3"
    local health_url="${_BENCH_HEALTH_URL:-http://127.0.0.1:${AUTOTUNE_PORT:-18082}}"
    local start_ns; start_ns=$(date +%s%N)
    local resp; resp=$(curl -sS --max-time "$bench_timeout" "$health_url/v1/chat/completions" \
        -H "Content-Type: application/json" -d @"$payload_file" 2>/dev/null) || true
    local end_ns; end_ns=$(date +%s%N)

    local elapsed_ms=$(( (end_ns - start_ns) / 1000000 ))

    # Parse usage + server timings in one pass. llama-server includes a
    # timings block (prompt_per_second / predicted_per_second) in every
    # /v1/chat/completions response; fall back to wall-clock if absent.
    local parsed; parsed=$(echo "$resp" | "$TAC_PYTHON" -c "
import sys, json
try:
    d = json.load(sys.stdin)
except Exception as exc:
    print(f'[tac] warning: could not parse chat response JSON: {exc}', file=sys.stderr)
    print('0|0|0|0|0'); sys.exit(0)
u = d.get('usage', {}) or {}
ct = u.get('completion_tokens', 0) or 0
pt = u.get('prompt_tokens', 0) or 0
t = d.get('timings', {}) or {}
decode = t.get('predicted_per_second', 0) or 0
prefill = t.get('prompt_per_second', 0) or 0
pred_ms = t.get('predicted_ms', 0) or 0
print('%s|%s|%s|%s|%s' % (ct, pt, decode, prefill, pred_ms))
" 2>/dev/null) || parsed="0|0|0|0|0"
    local tokens prompt_tokens decode_tps prefill_tps pred_ms
    IFS='|' read -r tokens prompt_tokens decode_tps prefill_tps pred_ms <<< "$parsed"
    [[ "$tokens" =~ ^[0-9]+$ ]] || tokens=0
    [[ "$prompt_tokens" =~ ^[0-9]+$ ]] || prompt_tokens=0

    # SPEC-DEC-003: counter-inflation guard — usage.completion_tokens can
    # count accepted final-block tokens discarded at max_tokens, so the TPS
    # the floor is judged on uses DELIVERED tokens (capped at the bench's
    # requested output budget).  max_tokens is parsed from the payload file.
    local _req_max
    _req_max=$(grep -oE '"max_tokens"[[:space:]]*:[[:space:]]*[0-9]+' "$payload_file" 2>/dev/null | head -1 | grep -oE '[0-9]+$')
    [[ "$_req_max" =~ ^[0-9]+$ ]] || _req_max=0
    local delivered_tokens="$tokens"
    if (( _req_max > 0 && delivered_tokens > _req_max )); then
        delivered_tokens="$_req_max"
    fi

    # SPEC-DEC-003: parse acceptance length + rate from this bench's server
    # log (one stats line per completed request; the last is this request).
    local _acc_len="0" _acc_rate="0"
    if declare -f __spec_decode_stats &>/dev/null; then
        IFS='|' read -r _acc_rate _acc_n _acc_g _acc_len _acc_present \
            <<< "$(__spec_decode_stats "${_BENCH_LOG}")"
    fi
    local _spec_block="${BENCH_SPEC_N_MAX:-0}"
    [[ "$_spec_block" =~ ^[0-9]+$ ]] || _spec_block=0

    if [[ $tokens -gt 0 ]]; then
        # Prefer the server's own decode timing; fall back to wall-clock.
        if [[ $(echo "${decode_tps:-0} > 0" | bc 2>/dev/null || echo "0") != 1 ]]; then
            if [[ $(echo "${pred_ms:-0} > 0" | bc 2>/dev/null || echo "0") == 1 ]]; then
                decode_tps=$(echo "scale=2; $delivered_tokens * 1000 / $pred_ms" | bc 2>/dev/null || echo "0")
            elif [[ $elapsed_ms -gt 0 ]]; then
                decode_tps=$(echo "scale=2; $delivered_tokens * 1000 / $elapsed_ms" | bc 2>/dev/null || echo "0")
            fi
        fi
        if [[ $(echo "${prefill_tps:-0} > 0" | bc 2>/dev/null || echo "0") != 1 ]] && [[ $prompt_tokens -gt 0 ]]; then
            if [[ $(echo "${pred_ms:-0} > 0" | bc 2>/dev/null || echo "0") == 1 ]] \
                && [[ $(echo "$elapsed_ms > $pred_ms" | bc 2>/dev/null || echo "0") == 1 ]]; then
                prefill_tps=$(echo "scale=2; $prompt_tokens * 1000 / ($elapsed_ms - $pred_ms)" | bc -l 2>/dev/null || echo "0")
            fi
        fi
    fi

    # Persist decode|prefill|failtype|accept_len|accept_rate|block|served_ctx for
    # callers (survives the subshell that bench_ctx runs in — globals do not).  served_ctx
    # is read from THIS function's live server: llama.cpp clamps the window to the model's
    # own <arch>.context_length at load, so the ctx we ASK for is not necessarily the ctx a
    # client receives.  Recording the request made 11 of 26 registry rows advertise a
    # window no server serves (measured 2026-09-16).  The clamp is to the GGUF native
    # window, NOT to what fits in VRAM: measured 2026-09-16 every reduced row served its
    # native value exactly, and the same value came back across ngl 24/999 and --fit on/off.
    local _served_ctx=""
    _served_ctx=$(curl -s --max-time 5 "http://127.0.0.1:${AUTOTUNE_PORT:-18082}/props" 2>/dev/null \
        | jq -r '.default_generation_settings.n_ctx // empty' 2>/dev/null || true)
    [[ "$_served_ctx" =~ ^[0-9]+$ ]] || _served_ctx=""
    echo "${decode_tps:-0}|${prefill_tps:-0}||${_acc_len}|${_acc_rate}|${_spec_block}|${_served_ctx}" > "/tmp/at-metrics-$$"
    # ...and to its OWN file, on a successful read only.  Every failure path below
    # rewrites the metrics line as "0|0|oom", which would erase a served ctx we HAD
    # read: a request rejected mid-prompt (400) is enough to do it, and it cost the
    # certification its served ctx on rows 3 and 4 (2026-09-16) even though earlier
    # samples of the same server had answered.  The save site reads (and clears) this
    # file around the certification, so a failure cannot erase the value and a stale
    # one from an earlier probe cannot leak in.
    [[ -n "$_served_ctx" ]] && echo "$_served_ctx" > "/tmp/at-served-ctx-$$"

    # TPS sentinel guard: llama.cpp clamps t_gen_us to a 1 us floor, so a
    # filled-cache decode that emits EOS in the same microsecond reports a
    # degenerate 1e6 tps (1000000.00), not real throughput. Reject it so the
    # caller keeps the real beam-search tps instead of certifying the sentinel.
    if [[ $mode == filled ]] && [[ $(echo "${decode_tps:-0} >= 1000" | bc 2>/dev/null || echo "0") == 1 ]]; then
        echo "0|0|oom" > "/tmp/at-metrics-$$"; echo ""; _BENCH_FAIL_TYPE="oom"
        return 1
    fi

    if [[ $elapsed_ms -gt 0 && $delivered_tokens -gt 0 ]] && [[ $(echo "${decode_tps:-0} > 0" | bc 2>/dev/null || echo "0") == 1 ]]; then
        echo "scale=2; $decode_tps / 1" | bc 2>/dev/null || echo "0"
        return 0
    fi
    echo "0|0|oom" > "/tmp/at-metrics-$$"; echo ""; _BENCH_FAIL_TYPE="oom"
    return 1
}

# ---------------------------------------------------------------------------
# bench_once — start server, run one benchmark, return decode TPS on stdout.
#   args: ctx batch ubatch [mmap_mode] [ngl] [mode] [kv_k] [kv_v]
#   mmap_mode: "auto" (default: mmap) or "off" (--load-mode none)
#   mode: "quick" (short prompt, discovery) or "filled" (scoring: pre-fills
#         the KV cache with a FILL_RATIO x ctx prompt and measures sustained
#         decode + prefill from the server timings)
#   kv_k/kv_v: cache-type-k / cache-type-v (default q8_0)
#   Writes "decode|prefill" (tok/s) to /tmp/at-metrics-$$ for callers that
#   need the prefill half; stdout stays the decode TPS so existing callers
#   are unchanged. Defaults to mmap (no flag) to avoid CUDA malloc ghost-VRAM
#   OOM on WSL2.
# ---------------------------------------------------------------------------
bench_once() {
    local c="$1" b="$2" u="$3" mmap_mode="${4:-auto}" override_ngl="${5:-}"
    local mode="${6:-quick}" kv_k="${7:-q8_0}" kv_v="${8:-q8_0}"
    local tag="/tmp/at-vram-${MODEL}-${c}"

    _BENCH_FAIL_TYPE=""  # global: "load_fail" or "oom"; reset before each bench
    cleanup_gpu >&2 || { echo "0|0|oom" > "/tmp/at-metrics-$$"; echo ""; return 1; }

    if [[ ! -f $tag ]]; then
        local g; g=$(nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ')
        echo "  VRAM cleared: $(fmt "${g:-?}") MiB free" >&2
        touch "$tag"
    fi

    local pf_info; pf_info=$(_bench_resolve_payload "$c" "$mode")
    local payload_file bench_timeout
    IFS='|' read -r payload_file bench_timeout <<< "$pf_info"

    _bench_spawn "$c" "$b" "$u" "$mmap_mode" "$override_ngl" "$kv_k" "$kv_v" || {
        _bench_stop "$_BENCH_PID"
        echo ""; return 1
    }

    local tps; tps=$(_bench_request_once "$mode" "$payload_file" "$bench_timeout") || tps=""
    _bench_stop "$_BENCH_PID"
    [[ -n "$tps" ]] || { echo ""; return 1; }
    echo "$tps"
    return 0
}

# ---------------------------------------------------------------------------
# bench_once_multi — single-server multi-sample bench (WSL2 dxgkrnl fix).
#   Spawn ONE llama-server and issue N requests against it, returning the
#   median decode TPS.  Every spawn/kill is a CUDA context create/destroy
#   cycle; WSL2's dxgkrnl leaks GPU VA on each one and eventually fails
#   dxgkio_destroy_allocation with -512, deadlocking the adapter until
#   `wsl --shutdown`.  Collapsing N cycles into one directly reduces the
#   degradation the autotune causes (single-process context reuse).
#   args: samples ctx batch ubatch [mmap_mode] [ngl] [mode] [kv_k] [kv_v]
# ---------------------------------------------------------------------------
bench_once_multi() {
    local samples="$1" c="$2" b="$3" u="$4" mmap_mode="${5:-auto}" override_ngl="${6:-}"
    local mode="${7:-quick}" kv_k="${8:-q8_0}" kv_v="${9:-q8_0}"
    local tag="/tmp/at-vram-${MODEL}-${c}"

    _BENCH_FAIL_TYPE=""
    cleanup_gpu >&2 || { echo "0|0|oom" > "/tmp/at-metrics-$$"; echo ""; return 1; }

    if [[ ! -f $tag ]]; then
        local g; g=$(nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ')
        echo "  VRAM cleared: $(fmt "${g:-?}") MiB free" >&2
        touch "$tag"
    fi

    local pf_info; pf_info=$(_bench_resolve_payload "$c" "$mode")
    local payload_file bench_timeout
    IFS='|' read -r payload_file bench_timeout <<< "$pf_info"

    _bench_spawn "$c" "$b" "$u" "$mmap_mode" "$override_ngl" "$kv_k" "$kv_v" || {
        _bench_stop "$_BENCH_PID"
        echo ""; return 1
    }

    local -a vals=()
    local _i _v _cold_metrics=""
    for ((_i = 0; _i < samples; _i++)); do
        _v=$(_bench_request_once "$mode" "$payload_file" "$bench_timeout") || _v=""
        # Sample 1 is the only COLD one.  llama.cpp caches the prompt prefix, so
        # samples 2..N re-send the same filled prompt as a cache hit and their
        # `timings` are not a prefill rate at all — while _bench_request_once
        # overwrites /tmp/at-metrics-$$ on EVERY request, so without this capture
        # the callers downstream record the last sample's cache-hit figure as
        # `prefill_tps`.  Measured 2026-09-17: row 12 persisted prefill 17.87 tok/s
        # where its own 1-sample rungs at the SAME ctx measured 934.73, and 17.87
        # tracked its decode tps (18.45).  Decode still uses the median of ALL
        # samples — prompt caching does not distort generated-token timing.
        if (( _i == 0 )); then
            _cold_metrics="$(cat "/tmp/at-metrics-$$" 2>/dev/null || true)"
        fi
        _v=$(echo "$_v" | bc 2>/dev/null || echo "0")
        if [[ $(echo "$_v > 0" | bc 2>/dev/null || echo "0") == 1 ]]; then
            vals+=("$_v")
        fi
    done
    _bench_stop "$_BENCH_PID"
    # Restore the cold sample's metrics (decode|prefill|accept...) for the callers.
    [[ -n "$_cold_metrics" ]] && printf '%s\n' "$_cold_metrics" > "/tmp/at-metrics-$$"

    if [[ ${#vals[@]} -eq 0 ]]; then echo ""; return 1; fi

    local tps
    if [[ ${#vals[@]} -eq 1 ]]; then
        tps="${vals[0]}"
    elif [[ $samples -eq 2 ]]; then
        tps=$(echo "scale=2; (${vals[0]}+${vals[1]})/${#vals[@]}" | bc -l 2>/dev/null || echo "${vals[0]}")
    else
        # Median of the survivors (LC_ALL=C sort keeps decimals locale-safe).
        tps=$(printf '%s\n' "${vals[@]}" | LC_ALL=C sort -n | awk '{a[NR]=$1} END { if (NR%2) print a[(NR+1)/2]; else printf "%.2f\n", (a[NR/2]+a[NR/2+1])/2 }')
    fi
    tps=$(echo "scale=2; $tps / 1" | bc -l 2>/dev/null || echo "$tps"); [ -z "$tps" ] && tps=0
    echo "$tps"
    return 0
}

# ---------------------------------------------------------------------------
# bench_ctx — returns decode TPS on stdout, empty on failure. RC 0/1.
#   args: ctx batch ubatch [samples] [mmap_mode] [ngl] [mode] [kv_k] [kv_v]
#   Also refreshes /tmp/at-metrics-$$ with "decode|prefill" from the last
#   bench_once run (see bench_once).
# ---------------------------------------------------------------------------
bench_ctx() {
    local c="$1" b="$2" u="$3" samples="${4:-1}" mmap_mode="${5:-auto}" override_ngl="${6:-}"
    local mode="${7:-quick}" kv_k="${8:-q8_0}" kv_v="${9:-q8_0}"
    _BENCH_FAIL_TYPE=""
    echo "" > "/tmp/at-metrics-$$" 2>/dev/null || true

    if [[ $samples -eq 1 ]]; then
        local tps; tps=$(bench_once "$c" "$b" "$u" "$mmap_mode" "$override_ngl" "$mode" "$kv_k" "$kv_v") || { echo ""; return 1; }
        # Pre-check tps=0 edge-cases that bc may miss (locale, trailing whitespace).
        if [[ -z "$tps" || "$tps" == "0" || "$tps" == "0.00" || "$tps" == "0,00" ]]; then
            echo "DEBUG: bench_once raw tps=[$tps] for ctx=$c — classified as OOM" >&2
            echo ""; return 1
        fi
        tps=$(echo "$tps" | bc 2>/dev/null || echo "0"); [ -z "$tps" ] && tps=0
        if [[ $(echo "$tps <= 0" | bc 2>/dev/null || echo "1") == 1 ]]; then
            echo "DEBUG: bc-evaluated tps=[$tps] for ctx=$c — classified as OOM" >&2
            echo ""; return 1
        fi
        # Phase 1: only check for actual OOM (0 tokens). TPS floor is applied
        # at the final check — rejecting slow models mid-probe hides viable ctx.
        echo "$tps"
        return 0
    fi

    # Multi-sample (samples >= 2): spawn ONE server and issue N requests
    # against it, returning the median of surviving samples.  Reusing one CUDA
    # context across samples is the WSL2 dxgkrnl fix — each spawn/kill is a
    # context create/destroy that leaks GPU VA and eventually fails
    # dxgkio_destroy_allocation with -512 (see bench_once_multi).
    local tps; tps=$(bench_once_multi "$samples" "$c" "$b" "$u" "$mmap_mode" "$override_ngl" "$mode" "$kv_k" "$kv_v") || { echo ""; return 1; }
    # Refinement: only check for actual OOM (0 tokens). TPS floor is applied
    # at the final check — rejecting here hides the true ceiling.
    echo "$tps"
    return 0
}

# --- AUTOTUNE_SELFTEST: canned bench_ctx for decision-logic regression ---
# With AUTOTUNE_SELFTEST=1, bench_ctx returns a deterministic curve (8.5 tps at
# every ctx by default), ttft_probe and cleanup_gpu are stubbed, and nothing is
# persisted — so the whole probe -> descent -> certification decision path runs
# SERVER-FREE in seconds.  Optional knobs:
#   _SELFTEST_FLOOR_ABOVE=<ctx>  12.0 tps at/below, 5.0 above (floor descent)
#   _SELFTEST_OOM_ABOVE=<ctx>    load fails above the ceiling (OOM path)
# Exercised by tests/unit/08-autotune-workload.bats.
#
# Policy under test — TPS-FIRST (2026-08-29, Wayne), which SUPERSEDES the
# 2026-08-27 "certify the max probed ctx" decision this comment used to cite: a
# model below the floor at its capacity ctx is NOT certified at capacity; Phase 4
# descends until the floor is met, or to MIN_CTX, and then records the
# best-effort config.  The stale 2026-08-27 note is why this harness was never
# wired to a test: it asserted the opposite of what the code had been changed to
# do.
if [[ "${AUTOTUNE_SELFTEST:-0}" == "1" ]]; then
    bench_ctx() {
        local c="$1" b="$2" u="$3" samples="${4:-1}" mmap_mode="${5:-auto}" override_ngl="${6:-}"
        local mode="${7:-quick}"
        _BENCH_FAIL_TYPE=""
        # Optional OOM ceiling: _SELFTEST_OOM_ABOVE makes ctx beyond the
        # threshold fail (returns OOM), reproducing the real binary-probe /
        # floor-recovery OOM path deterministically (default: no OOM).
        if [[ -n "${_SELFTEST_OOM_ABOVE:-}" ]] && [[ $c -gt ${_SELFTEST_OOM_ABOVE} ]]; then
            echo ""; return 1
        fi
        # Optional TPS-floor threshold: _SELFTEST_FLOOR_ABOVE makes ctx above
        # it return below-floor TPS and ctx at/below it return above-floor
        # TPS — reproducing the TPS-first descent that finds the highest ctx
        # sustaining MIN_TPS (2026-08-29).  Without it the canned curve is
        # below-floor at every ctx (the "too slow for our purposes" path).
        local _st_tps="8.5"
        if [[ -n "${_SELFTEST_FLOOR_ABOVE:-}" ]]; then
            if [[ $c -gt ${_SELFTEST_FLOOR_ABOVE} ]]; then
                _st_tps="5.0"
            else
                _st_tps="12.0"
            fi
        fi
        # _SELFTEST_CERT_GAP_ABOVE / _SELFTEST_CERT_GAP_FACTOR model the 2026-09-17 defect:
        # at large ctx a SINGLE sample overstates the sustained rate, so the 5-sample
        # certification lands FACTOR x lower AT THE SAME ctx.  Measured: rows 13/14 read
        # 13.89 / 14.57 tps on one sample at ctx 131,072 and certified 2.95 / 3.12, while
        # rows 2/12 at 4.6-6.6K agreed within 1.2-1.4x.  Ctx at or below the threshold is
        # unaffected, which is what gives the post-certification descent a window that
        # genuinely holds the floor to adopt.
        if [[ -n "${_SELFTEST_CERT_GAP_ABOVE:-}" ]] \
            && (( c >= _SELFTEST_CERT_GAP_ABOVE )) \
            && (( samples >= 5 )); then
            _st_tps=$(echo "scale=2; $_st_tps / ${_SELFTEST_CERT_GAP_FACTOR:-4}" | bc -l 2>/dev/null || echo "$_st_tps")
        fi
        echo "${_st_tps}|500.0|0" > "/tmp/at-metrics-$$"
        echo "$_st_tps"
        return 0
    }
    # TTFT probe stubbed too — it launches a real server at the certified
    # ctx (multi-minute load at >250K ctx); the selftest must stay a
    # server-free decision-logic regression (2026-08-27).
    ttft_probe() {
        echo "250.0|120.0"
        return 0
    }
    # cleanup_gpu stubbed — its ~4s of kill/sleep/drop-cache cycles per call
    # dominate the selftest runtime (20+ calls through the beam search and
    # sweeps); there is no real server to clean in the selftest.
    cleanup_gpu() {
        return 0
    }
fi

#==============================================================================
# Probe
#==============================================================================

BEST_TPS="0"; BEST_COMBO=""; BEST_CTX=0; ANY_OK=false
# Profile 1's prefill tok/s (filled-cache certification) and profile 2.
BEST_PREFILL="0"
# Profile 2 (interactive): config with the highest decode TPS anywhere in the
# search, tiebreak higher ctx. Certified later with a filled-cache bench.
P2_TPS="0"; P2_CTX=0; P2_B=""; P2_U=""; P2_PREFILL="0"
# Set to 1 when the --load-mode none fallback produced the winner; the beam search,
# sweeps, and Phase 4 must then bench with mmap off too.
MMAP_FALLBACK_USED=0

# Writes to BEST_TPS/BEST_COMBO/BEST_CTX/ANY_OK globals.
#
# Success metric — lexicographic capability (replaces the old ctx×tps product):
#   1. A config that meets the TPS floor always beats one that does not.
#   2. Among configs that meet the floor: highest ctx wins (context is the
#      capability that keeps paying off once speed is acceptable); tiebreak by
#      higher TPS.
#   3. Among configs below the floor (model is too slow): highest TPS wins
#      (fastest best-effort config); tiebreak by higher ctx.
# ctx×tps conflated speed and context as interchangeable; once TPS clears the
# floor, extra speed has diminishing value while extra context does not.
record_best() {
    local c=$1 tps=$2 b=$3 u=$4

    # Profile 2 (interactive): highest decode TPS across every probed config,
    # independent of the floor — it is the "fast" profile for short-context
    # interactive flows. The prefill half is captured at certification time.
    if [[ $(echo "$tps > $P2_TPS" | bc 2>/dev/null || echo "0") == 1 ]] ||
       { [[ $(echo "$tps == $P2_TPS" | bc 2>/dev/null || echo "0") == 1 ]] &&
         [[ $(echo "$c > $P2_CTX" | bc 2>/dev/null || echo "0") == 1 ]]; }; then
        P2_TPS=$tps; P2_CTX=$c; P2_B=$b; P2_U=$u
    fi

    local above; above=$(echo "$tps >= $MIN_TPS" | bc 2>/dev/null || echo "0")
    local best_above; best_above=$(echo "$BEST_TPS >= $MIN_TPS" | bc 2>/dev/null || echo "0")

    # Rule 1: floor-meeting config always wins over a below-floor one.
    if [[ $above == 1 && $best_above == 0 ]]; then
        BEST_TPS=$tps; BEST_COMBO="$b:$u"; BEST_CTX=$c; return
    fi
    if [[ $above == 0 && $best_above == 1 ]]; then
        return  # keep current — it meets the floor, the candidate does not
    fi

    if [[ $above == 1 ]]; then
        # Rule 2: both meet floor → max ctx, tiebreak max TPS.
        if [[ $(echo "$c > $BEST_CTX" | bc 2>/dev/null || echo "0") == 1 ]] ||
           { [[ $(echo "$c == $BEST_CTX" | bc 2>/dev/null || echo "0") == 1 ]] &&
             [[ $(echo "$tps > $BEST_TPS" | bc 2>/dev/null || echo "0") == 1 ]]; }; then
            BEST_TPS=$tps; BEST_COMBO="$b:$u"; BEST_CTX=$c
        fi
    else
        # Rule 3: both below floor (best-effort) → max TPS, tiebreak max ctx.
        if [[ $(echo "$tps > $BEST_TPS" | bc 2>/dev/null || echo "0") == 1 ]] ||
           { [[ $(echo "$tps == $BEST_TPS" | bc 2>/dev/null || echo "0") == 1 ]] &&
             [[ $(echo "$c > $BEST_CTX" | bc 2>/dev/null || echo "0") == 1 ]]; }; then
            BEST_TPS=$tps; BEST_COMBO="$b:$u"; BEST_CTX=$c
        fi
    fi
}

# ---------------------------------------------------------------------------
# last_fail_type — read the last bench's failure classification from the
# metrics file. bench_ctx/bench_once run in command-substitution subshells
# where global assignment does not propagate, so the file is the reliable
# channel (REF: autotune-model.sh v4).
# @stdout "load_fail", "oom", or empty.
# ---------------------------------------------------------------------------
last_fail_type() {
    cut -d'|' -f3 "/tmp/at-metrics-$$" 2>/dev/null | head -1
}

# ---------------------------------------------------------------------------
# probe_upward — bounded ctx re-climb for a fixed config (quick benches).
# Confirms the given ctx, then up to 2 ×1.5 climb steps and one binary probe.
# Every successful test feeds record_best (max-ctx profile + profile-2
# tracking), so the caller's BEST_* may end higher than the starting ctx.
#   args: ctx batch ubatch [mmap] [ngl] [kv_k] [kv_v]
# @returns 0 when the starting ctx confirmed, 1 when it failed.
# ---------------------------------------------------------------------------
probe_upward() {
    local _pc="$1" _pb="$2" _pu="$3" _pm="${4:-auto}" _pngl="${5:-$BENCH_NGL}"
    local _pkk="${6:-q8_0}" _pkv="${7:-q8_0}"
    local _tps _lo _hi=0 _steps=0 _mid _fail_label

    _tps=$(bench_ctx "$_pc" "$_pb" "$_pu" 1 "$_pm" "$_pngl" "quick" "$_pkk" "$_pkv") || {
        _fail_label="OOM"
        [[ $(last_fail_type) == "load_fail" ]] && _fail_label="unsupported model"
        echo "    ctx $(fmt "$_pc") - ${_fail_label}"
        return 1
    }
    echo "    ctx $(fmt "$_pc") - ${_tps} tps"
    record_best "$_pc" "$_tps" "$_pb" "$_pu"
    _lo=$_pc
    while [[ $_steps -lt 2 ]]; do
        _steps=$((_steps + 1))
        _pc=$(( _lo * 3 / 2 )); [[ $_pc -gt $MAX_CTX ]] && _pc=$MAX_CTX
        [[ $_pc -eq $_lo ]] && break
        _tps=$(bench_ctx "$_pc" "$_pb" "$_pu" 1 "$_pm" "$_pngl" "quick" "$_pkk" "$_pkv") || {
            _hi=$_pc
            _fail_label="OOM"
            [[ $(last_fail_type) == "load_fail" ]] && _fail_label="unsupported model"
            echo "    ctx $(fmt "$_pc") - ${_fail_label}: binary probe"
            break
        }
        echo "    ctx $(fmt "$_pc") - ${_tps} tps - climbing"
        _lo=$_pc; record_best "$_lo" "$_tps" "$_pb" "$_pu"
    done
    if [[ $_hi -gt 0 ]] && [[ $(( _hi - _lo )) -ge 512 ]]; then
        _mid=$(( ( _lo + _hi ) / 2 / 512 * 512 ))
        [[ $_mid -eq $_lo ]] && return 0
        _tps=$(bench_ctx "$_mid" "$_pb" "$_pu" 1 "$_pm" "$_pngl" "quick" "$_pkk" "$_pkv") || {
            _fail_label="OOM"
            [[ $(last_fail_type) == "load_fail" ]] && _fail_label="unsupported model"
            echo "    ctx $(fmt "$_mid") - ${_fail_label}"
            return 0
        }
        echo "    ctx $(fmt "$_mid") - ${_tps} tps"
        record_best "$_mid" "$_tps" "$_pb" "$_pu"
    fi
    return 0
}

for combo in "${COMBOS[@]}"; do
    IFS=':' read -r b u <<< "$combo"
    echo ""
    echo "  batch $(fmt "$b")/$(fmt "$u")"
    echo "  ---------------------"

    c0=$START_CTX
    if [[ $BEST_CTX -gt 0 ]]; then
        tps=$(bench_ctx "$BEST_CTX" "$b" "$u" 1) || tps=""
        if [[ -n $tps ]]; then
            echo "  ctx $(fmt "$BEST_CTX") - ${tps} tps"
            ANY_OK=true; record_best "$BEST_CTX" "$tps" "$b" "$u"
        else
            fail_label="OOM"
            [[ $(last_fail_type) == "load_fail" ]] && fail_label="unsupported model"
            echo "  ctx $(fmt "$BEST_CTX") - ${fail_label} with batch $(fmt "$b")/$(fmt "$u")"
        fi
        continue
    fi
    test_num=0; c=$c0; found=false; _ALL_LOAD_FAIL=true
    while [[ $c -ge $MIN_CTX ]]; do
        test_num=$((test_num + 1))
        tps=$(bench_ctx "$c" "$b" "$u" 1) || {
            fail_label="OOM"
            [[ $(last_fail_type) == "load_fail" ]] && fail_label="unsupported model"
            echo "  Test $test_num: ctx $(fmt "$c") - ${fail_label}: dropping to $(fmt $((c/2)))"
            [[ $(last_fail_type) != "load_fail" ]] && _ALL_LOAD_FAIL=false
            c=$((c/2)); [[ $c -lt $MIN_CTX ]] && break; continue
        }
        echo "  Test $test_num: ctx $(fmt "$c") - ${tps} tps"
        found=true; ANY_OK=true; _ALL_LOAD_FAIL=false
        record_best "$c" "$tps" "$b" "$u"

        # Always climb past the first success (fixed 2026-09-14): START_CTX
        # is only an ESTIMATE of the KV-fit ceiling (kv-per-1k model, ignores
        # GQA head-count and runtime KV-quant nuances) — a first-try success
        # does not prove MAX_CTX is unreachable. Skipping the climb here
        # silently capped every model at its KV-math guess instead of the
        # empirically confirmed max, defeating the tool's purpose (find the
        # highest ctx meeting the TPS floor). The climb below is still
        # bounded by MAX_CTX and stops on the first OOM/load-fail.
        # Phase 2: step up 50% — capacity-first (2026-08-27), climbs to
        # MAX_CTX or OOM. The climb is clamped at MAX_CTX — probing past the
        # native-ctx ceiling records RoPE-extended ctx values the machine
        # cannot serve sanely.
        lo=$c; hi=0; c=$((c * 3 / 2)); [[ $c -gt $MAX_CTX ]] && c=$MAX_CTX
        while true; do
            [[ $c -eq $lo ]] && break
            test_num=$((test_num + 1))
            bench_ctx "$c" "$b" "$u" 1 > /tmp/at-tps-$$; rc=$?
            tps=$(cat /tmp/at-tps-$$ 2>/dev/null)
            # REF: ubuntu-console card b564d801 — bench_ctx can return rc=0 with tps=0
            # when the server replies successfully with 0 completion tokens.
            # Catch both non-zero rc AND empty/zero tps as OOM to ensure consistent
            # classification in the binary probe.
            if [[ $rc -ne 0 ]] || [[ -z "$tps" || "$tps" == "0" || "$tps" == "0.00" || "$tps" == "0,00" ]]; then
                hi=$c
                fail_label="OOM"
                [[ $(last_fail_type) == "load_fail" ]] && fail_label="unsupported model"
                if [[ -n "$tps" && "$tps" == "0" ]]; then
                    echo "  Test $test_num: ctx $(fmt "$c") - 0 tps (${fail_label}): binary probe $(fmt $(( (lo+hi)/2/512*512 )))"
                else
                    echo "  Test $test_num: ctx $(fmt "$c") - ${fail_label}: binary probe $(fmt $(( (lo+hi)/2/512*512 )))"
                fi
                break
            fi
            lo=$c; record_best "$lo" "$tps" "$b" "$u"
            # Capacity-first (2026-08-27, Wayne): the climb does NOT stop on
            # "TPS stable" — a slight TPS decline as ctx grows is normal, and
            # the goal is the maximum VRAM-fitting context, not the fastest
            # one. Only OOM/load-fail or the native-ctx cap (MAX_CTX) ends
            # the climb; the filled-cache floor (Phase 4) still filters for
            # sustained throughput afterwards.
            echo "  Test $test_num: ctx $(fmt "$c") - ${tps} tps - climbing to $(fmt $((c*3/2)))"
            c=$((c * 3 / 2)); [[ $c -gt $MAX_CTX ]] && c=$MAX_CTX
        done

        # If first step-up OOM'd and TPS was marginal (< 25), skip binary probe.
        if [[ $hi -gt 0 ]] && [[ $(echo "$BEST_TPS < 25" | bc 2>/dev/null || echo "0") == 1 ]]; then
            echo "  (TPS marginal, no binary probe needed)"
        else
        # Binary probe between lo (working) and hi (OOM) — max 5 steps
        prev_c=-1; probe_count=0
        while [[ $((hi - lo)) -ge 512 ]] && [[ $probe_count -lt 5 ]]; do
            probe_count=$((probe_count + 1))
            nsamples=1
            [[ $probe_count -gt 1 ]] && nsamples=2   # double-sample in refinement zone
            c=$(( (lo + hi) / 2 / 512 * 512 ))
            [[ $c -eq $prev_c ]] && break
            prev_c=$c
            test_num=$((test_num + 1))
            bench_ctx "$c" "$b" "$u" "$nsamples" > /tmp/at-tps-$$; rc=$?
            tps=$(cat /tmp/at-tps-$$ 2>/dev/null)
            if [[ $rc -ne 0 ]]; then
                hi=$c
                fail_label="OOM"
                [[ $(last_fail_type) == "load_fail" ]] && fail_label="unsupported model"
                echo "  Test $test_num: ctx $(fmt "$c") - ${fail_label}"
            else
                lo=$c; record_best "$lo" "$tps" "$b" "$u"
                echo "  Test $test_num: ctx $(fmt "$c") - ${tps} tps"
            fi
        done
        fi
        break
    done
    if [[ $found == false ]]; then
        fail_label="OOM"
        [[ $_ALL_LOAD_FAIL == true ]] && fail_label="unsupported model"
        # No attempt at all is NOT a model verdict.  _ALL_LOAD_FAIL is initialised
        # true and cleared by a non-load failure, so a loop that never ran leaves it
        # true and libels the model as unsupported.  The floor fix above should make
        # this unreachable; if it ever fires again, the bug is in the probe bounds
        # (START_CTX vs MIN_CTX), not in the GGUF — say so instead of accusing it.
        if [[ $test_num -eq 0 ]]; then
            fail_label="PROBE BUG (no ctx attempted)"
            echo "  WARNING: START_CTX=$(fmt "$START_CTX") < MIN_CTX=$(fmt "$MIN_CTX") — the probe never ran. This is a probe-bounds bug, NOT an unsupported model." >&2
        fi
        echo "  Test $test_num: ctx $(fmt "$c") - ${fail_label} - model cannot run at any ctx"
        # Early abort: if the model never loaded at any ctx (load_fail at every
        # step), skip remaining combos — stepping down won't make the GGUF
        # load. Go straight to the --load-mode none fallback.
        if [[ $_ALL_LOAD_FAIL == true ]]; then
            echo "  (model cannot be loaded — skipping remaining combos)"
            break
        fi
    fi
done

# --- mmap fallback ---
# If the default (mmap) load failed at all ctx for all combos, retry with
# --load-mode none.  (build 10955 removed --mmap/--no-mmap/--mlock; the old
# spelling is a fatal "invalid argument", not a deprecation.)
# Some architectures (phi3, gemma3n) need --load-mode none for stable VRAM allocation.
# Extracted from the top-level flow with its body unchanged: a self-contained
# pass that re-runs the probe with mmap off and shares the same globals.  `b`/`u`
# stay global exactly as before, so the move is behaviour-preserving (a later
# step can unify this with probe_upward, whose loop it duplicates).
probe_no_mmap() {
    echo ""
    echo "  default (mmap) load failed at all ctx — retrying with --load-mode none"
    echo ""
    _ALL_LOAD_FAIL=true
    for combo in "${COMBOS[@]}"; do
        IFS=':' read -r b u <<< "$combo"
        echo "  batch $(fmt "$b")/$(fmt "$u")  (--load-mode none)"
        echo "  ---------------------"

        c=$START_CTX; found=false
        while [[ $c -ge $MIN_CTX ]]; do
            tps=$(bench_ctx "$c" "$b" "$u" 1 "off") || {
                fail_label="OOM"
                [[ $(last_fail_type) == "load_fail" ]] && fail_label="unsupported model"
                echo "  ctx $(fmt "$c") - ${fail_label}: dropping to $(fmt $((c/2)))"
                [[ $(last_fail_type) != "load_fail" ]] && _ALL_LOAD_FAIL=false
                c=$((c/2)); [[ $c -lt $MIN_CTX ]] && break; continue
            }
            echo "  ctx $(fmt "$c") - ${tps} tps"
            found=true; ANY_OK=true; _ALL_LOAD_FAIL=false; MMAP_FALLBACK_USED=1
            record_best "$c" "$tps" "$b" "$u"
            # Phase 2: step up, stop at first OOM (fallback path — keep it simple)
            lo=$c; c=$((c * 3 / 2)); [[ $c -gt $MAX_CTX ]] && c=$MAX_CTX
            while true; do
                [[ $c -eq $lo ]] && break
                bench_ctx "$c" "$b" "$u" 1 "off" > /tmp/at-tps-$$; rc=$?
                tps=$(cat /tmp/at-tps-$$ 2>/dev/null)
                if [[ $rc -ne 0 ]]; then
                    fail_label="OOM"
                    [[ $(last_fail_type) == "load_fail" ]] && fail_label="unsupported model"
                    echo "  ctx $(fmt "$c") - ${fail_label}"
                    break
                fi
                lo=$c; record_best "$lo" "$tps" "$b" "$u"
                echo "  ctx $(fmt "$c") - ${tps} tps - climbing to $(fmt $((c*3/2)))"
                c=$((c * 3 / 2)); [[ $c -gt $MAX_CTX ]] && c=$MAX_CTX
            done
            break
        done
        # Likewise early-abort remaining combos in the fallback path
        if [[ $_ALL_LOAD_FAIL == true ]]; then
            echo "  (model cannot be loaded even with --load-mode none — aborting)"
            break
        fi
    done
}

if [[ $ANY_OK == false ]]; then
    probe_no_mmap
fi

_cuda_guard_or_exit

# --- Beam search over batch/ubatch at the winning ctx ---
# Replaces the fixed 128/256/512 ubatch pass. Evaluates a small anchor set,
# then expands neighbors of the top performers (beam search). All evals are
# quick single-sample benches at BEST_CTX; the floor itself is certified
# later with a filled-cache bench.
EFFECTIVE_MMAP="auto"
[[ $MMAP_FALLBACK_USED == 1 ]] && EFFECTIVE_MMAP="off"
if [[ $ANY_OK == true && -n $BEST_COMBO ]] && [[ $BEST_CTX -gt 0 ]]; then
    IFS=':' read -r BEST_B BEST_U <<< "$BEST_COMBO"

    BATCHES=()
    UBATCHES=()
    ANCHORS=()
    if [[ $MODEL_MB -lt 1000 ]]; then
        BATCHES=(1024 2048 4096); UBATCHES=(256 512 1024)
        ANCHORS=(1024:256 2048:512 4096:1024)
    else
        BATCHES=(512 1024 2048); UBATCHES=(128 256 512)
        ANCHORS=(512:128 1024:256 1024:512 2048:512)
    fi

    # Candidate space, gated by ctx (big batches need big compute buffers).
    SPACE=()
    _b=""; _u=""
    for _b in "${BATCHES[@]}"; do
        [[ $BEST_CTX -lt 8192 && $_b -gt 1024 ]] && continue
        [[ $BEST_CTX -lt 16384 && $_b -gt 1536 ]] && continue
        for _u in "${UBATCHES[@]}"; do
            [[ $_u -le $_b ]] || continue
            SPACE+=("${_b}:${_u}")
        done
    done

    declare -A SEEN=()
    declare -A COMBO_TPS=()
    BEAM=()
    FRONTIER=()

    echo ""
    echo "  beam search at ctx=$(fmt "$BEST_CTX")  (batch/ubatch)"
    echo "  ---------------------"

    beam_eval() {
        local key="$1"
        [[ -n "${SEEN[$key]:-}" ]] && return
        SEEN[$key]=1
        local _b2 _u2 tps fail_label
        IFS=':' read -r _b2 _u2 <<< "$key"
        tps=$(bench_ctx "$BEST_CTX" "$_b2" "$_u2" 1) || tps=""
        if [[ -n $tps ]]; then
            echo "  combo $_b2/$_u2 - ${tps} tps"
            COMBO_TPS[$key]="$tps"
            record_best "$BEST_CTX" "$tps" "$_b2" "$_u2"
        else
            fail_label="OOM"
            [[ $(last_fail_type) == "load_fail" ]] && fail_label="unsupported model"
            echo "  combo $_b2/$_u2 - ${fail_label}"
        fi
    }

    beam_top() {
        local k t above
        for k in "${!COMBO_TPS[@]}"; do
            t="${COMBO_TPS[$k]}"
            above=0
            [[ $(echo "$t >= $MIN_TPS" | bc 2>/dev/null || echo "0") == 1 ]] && above=1
            printf '%s|%s|%s\n' "$above" "$t" "$k"
        done | sort -t'|' -k1,1nr -k2,2nr | head -n "$BEAM_WIDTH" | cut -d'|' -f3
    }

    beam_neighbors() {
        local key="$1"
        local _b3 _u3 bi=0 ui=0 _i _nb _nu
        local -a out=()
        IFS=':' read -r _b3 _u3 <<< "$key"
        for _i in "${!BATCHES[@]}"; do [[ "${BATCHES[$_i]}" == "$_b3" ]] && bi=$_i && break; done
        for _i in "${!UBATCHES[@]}"; do [[ "${UBATCHES[$_i]}" == "$_u3" ]] && ui=$_i && break; done
        [[ $bi -gt 0 ]] && out+=("${BATCHES[$((bi-1))]}:$_u3")
        [[ $bi -lt $(( ${#BATCHES[@]} - 1 )) ]] && out+=("${BATCHES[$((bi+1))]}:$_u3")
        [[ $ui -gt 0 ]] && out+=("$_b3:${UBATCHES[$((ui-1))]}")
        [[ $ui -lt $(( ${#UBATCHES[@]} - 1 )) ]] && out+=("$_b3:${UBATCHES[$((ui+1))]}")
        # Diagonal moves jump the grid toward higher-throughput corners.
        [[ $bi -gt 0 && $ui -gt 0 ]] && out+=("${BATCHES[$((bi-1))]}:${UBATCHES[$((ui-1))]}")
        [[ $bi -lt $(( ${#BATCHES[@]} - 1 )) && $ui -lt $(( ${#UBATCHES[@]} - 1 )) ]] \
            && out+=("${BATCHES[$((bi+1))]}:${UBATCHES[$((ui+1))]}")
        printf '%s\n' "${out[@]}"
    }

    # Filter anchors to the ctx-gated space.
    FILTERED_ANCHORS=()
    _a=""; _sk=""
    for _a in "${ANCHORS[@]}"; do
        for _sk in "${SPACE[@]}"; do
            [[ "$_sk" == "$_a" ]] && FILTERED_ANCHORS+=("$_a") && break
        done
    done
    if [[ ${#FILTERED_ANCHORS[@]} -eq 0 ]]; then
        FILTERED_ANCHORS=("${SPACE[@]:0:4}")
    fi
    _a2=""
    for _a2 in "${FILTERED_ANCHORS[@]}"; do beam_eval "$_a2"; done

    mapfile -t BEAM < <(beam_top)
    _round=0
    while [[ $_round -lt $BEAM_ROUNDS ]] && [[ ${#BEAM[@]} -gt 0 ]]; do
        _round=$((_round + 1))
        FRONTIER=()
        _bk=""; _nk=""; _in=0; _dup=0
        for _bk in "${BEAM[@]}"; do
            while IFS= read -r _nk; do
                [[ -n $_nk ]] || continue
                _in=0
                for _sk in "${SPACE[@]}"; do [[ "$_sk" == "$_nk" ]] && _in=1 && break; done
                [[ $_in == 1 ]] || continue
                [[ -n "${SEEN[$_nk]:-}" ]] && continue
                _dup=0
                _fk=""
                for _fk in "${FRONTIER[@]}"; do [[ "$_fk" == "$_nk" ]] && _dup=1 && break; done
                [[ $_dup == 1 ]] && continue
                FRONTIER+=("$_nk")
            done < <(beam_neighbors "$_bk")
        done
        _nk2=""
        for _nk2 in "${FRONTIER[@]}"; do beam_eval "$_nk2"; done
        _nb2=()
        while IFS= read -r _nk3; do _nb2+=("$_nk3"); done < <(beam_top)
        if [[ "${_nb2[*]:-}" == "${BEAM[*]}" ]]; then break; fi
        BEAM=("${_nb2[@]}")
    done

    # The beam winner may enable a higher ctx ceiling (smaller ubatch → less
    # peak VRAM). Re-climb ctx for the winning combo.
    if [[ -n $BEST_COMBO ]]; then
        IFS=':' read -r BEST_B BEST_U <<< "$BEST_COMBO"
        echo "  re-climbing ctx for combo $(fmt "$BEST_B")/$(fmt "$BEST_U")"
        probe_upward "$BEST_CTX" "$BEST_B" "$BEST_U" "$EFFECTIVE_MMAP"
    fi
fi

_cuda_guard_or_exit

# --- n_gpu_layers / KV-quant sweep (the "almost fits" band) ---
# The registry's __calc_gpu_layers is 999-or-0: models slightly too big for
# full offload fall to CPU-only. In the band (model is a meaningful fraction
# of free VRAM) probe alternate offload counts and cache quantizations —
# partial offload or q4_0 KV can beat pure CPU and free VRAM for a higher ctx.
WIN_NGL="$BENCH_NGL"; WIN_KVK="q8_0"; WIN_KVV="q8_0"
BAND_MIN_MB=$(awk -v f="$FREE_VRAM" -v fr="$NGL_BAND_FRAC" 'BEGIN{printf "%d", f*fr}')
if [[ $ANY_OK == true && -n $BEST_COMBO ]] && [[ $MODEL_MB -ge $BAND_MIN_MB ]]; then
    IFS=':' read -r BEST_B BEST_U <<< "$BEST_COMBO"

    # ngl candidates: runtime-max offload (999) plus a short ladder down the
    # GGUF layer count (3/4, 1/4) — on a 4 GB card partial offload can win
    # anywhere in that band, and 999-or-half alone skips it.  The 1/2 midpoint
    # is dropped to cut load/unload cycles: every candidate spawns a fresh CUDA
    # context, which accelerates the WSL2 dxgkrnl degradation; 3/4 and 1/4
    # still bracket the useful partial-offload band. Dedup against the
    # registry's current value and against each other.
    NGL_CANDIDATES=()
    [[ "$BENCH_NGL" != "999" ]] && NGL_CANDIDATES+=("999")
    if [[ -n "${_n_layers:-}" ]] && [[ "$_n_layers" =~ ^[0-9]+$ ]] && [[ $_n_layers -gt 1 ]]; then
        for _frac in 3 1; do
            _ngl_cand=$(( _n_layers * _frac / 4 ))
            [[ $_ngl_cand -lt 1 ]] && _ngl_cand=1
            [[ "$_ngl_cand" != "$BENCH_NGL" ]] || continue
            _dup=0
            for _existing in "${NGL_CANDIDATES[@]:-}"; do
                [[ "$_existing" == "$_ngl_cand" ]] && _dup=1 && break
            done
            (( _dup )) || NGL_CANDIDATES+=("$_ngl_cand")
        done
        unset _frac _ngl_cand _dup _existing
    fi

    if [[ ${#NGL_CANDIDATES[@]} -gt 0 ]]; then
        echo ""
        echo "  n_gpu_layers sweep (band) at ctx=$(fmt "$BEST_CTX")  [${NGL_CANDIDATES[*]}]"
        echo "  ---------------------"
        _ngl=""
        for _ngl in "${NGL_CANDIDATES[@]}"; do
            _before="$BEST_CTX|$BEST_TPS"
            echo "  ngl=$_ngl:"
            probe_upward "$BEST_CTX" "$BEST_B" "$BEST_U" "$EFFECTIVE_MMAP" "$_ngl" "q8_0" "q8_0" || true
            _after="$BEST_CTX|$BEST_TPS"
            [[ "$_after" != "$_before" ]] && WIN_NGL="$_ngl"
        done
    fi

    # KV-quant candidates: e.g. "q8_0/q8_0 q4_0/q4_0" — the default pair was
    # implicitly probed by every bench so far; probe the alternates.
    KV_PAIRS=()
    _pair=""
    for _pair in $KV_QUANTS; do
        _kk="${_pair%%/*}"; _kv="${_pair##*/}"
        [[ "$_kk" == "$WIN_KVK" && "$_kv" == "$WIN_KVV" ]] && continue
        KV_PAIRS+=("$_pair")
    done

    if [[ ${#KV_PAIRS[@]} -gt 0 ]]; then
        echo ""
        echo "  KV-quant sweep (band) at ctx=$(fmt "$BEST_CTX")  [${KV_PAIRS[*]}]"
        echo "  ---------------------"
        _pair=""
        for _pair in "${KV_PAIRS[@]}"; do
            _kk="${_pair%%/*}"; _kv="${_pair##*/}"
            _before="$BEST_CTX|$BEST_TPS"
            echo "  cache k=$_kk v=$_kv:"
            probe_upward "$BEST_CTX" "$BEST_B" "$BEST_U" "$EFFECTIVE_MMAP" "$WIN_NGL" "$_kk" "$_kv" || true
            _after="$BEST_CTX|$BEST_TPS"
            if [[ "$_after" != "$_before" ]]; then WIN_KVK="$_kk"; WIN_KVV="$_kv"; fi
        done
    fi
fi

_cuda_guard_or_exit

# --- Phase 4: filled-cache TPS floor recovery ---
# The probe maximises ctx, which on a 4 GB card can leave a model swapping at
# large context (high ctx, low TPS). The floor is now certified at a FILLED
# KV cache — a long prompt pre-fills the context so decode is measured under
# the cache pressure the recorded ctx actually produces. If the best config is
# below the floor (decode or the optional prefill floor), step ctx DOWN — a
# smaller KV cache raises TPS — until the floor is met or MIN_CTX is reached.
# Descending top-down means the first ctx that meets the floor is the highest
# ctx that sustains it, which is exactly the capability we record.
if [[ $ANY_OK == true && -n $BEST_COMBO ]]; then
    IFS=':' read -r BEST_B BEST_U <<< "$BEST_COMBO"
    echo ""
    echo "  Phase 4: filled-cache TPS floor recovery"
    echo "  ---------------------"
    _dc=$BEST_CTX
    _ft=""
    # TPS-first (2026-08-29, Wayne): the certified ctx is the highest ctx
    # that sustains MIN_TPS at a FILLED cache. A model below the floor at
    # its capacity ctx is NOT certified at capacity — it descends until the
    # floor is met (or MIN_CTX), so the recorded ctx is the usable one.
    _FAST_REJECT=1
    _ft=$(bench_ctx "$_dc" "$BEST_B" "$BEST_U" 1 "$EFFECTIVE_MMAP" "$WIN_NGL" "filled" "$WIN_KVK" "$WIN_KVV") || _ft=""
    if [[ -n $_ft ]] && [[ $(echo "$_ft > 0" | bc 2>/dev/null || echo "0") == 1 ]]; then
        _fp="0"
        IFS='|' read -r _fd _fp _ff < "/tmp/at-metrics-$$" 2>/dev/null || true
        echo "  ctx $(fmt "$_dc") - filled ${_ft} tps (prefill ${_fp:-0} tok/s)"
        BEST_CTX=$_dc; BEST_TPS=$_ft; BEST_PREFILL="${_fp:-0}"
        _dok=0; _pok=0
        [[ $(echo "$_ft >= $MIN_TPS" | bc 2>/dev/null || echo "0") == 1 ]] && _dok=1
        if [[ $MIN_PREFILL_TPS == 0 ]] \
            || [[ $(echo "${_fp:-0} >= $MIN_PREFILL_TPS" | bc 2>/dev/null || echo "0") == 1 ]]; then
            _pok=1
        fi
        if [[ $_dok == 0 || $_pok == 0 ]]; then
            echo "  below TPS floor at capacity ctx $(fmt "$_dc") — descending to the highest ctx that sustains ${MIN_TPS} tps"
            # Candidates are pre-built (descending, and including this row's PREVIOUS
            # certification) so the walk cannot step over a value the row is known to hold —
            # see __autotune_descent_candidates.
            for _dc in $(__autotune_descent_candidates "$_dc" "$MIN_CTX" "$PREV_CERT_CTX"); do
                _ft=$(bench_ctx "$_dc" "$BEST_B" "$BEST_U" 1 "$EFFECTIVE_MMAP" "$WIN_NGL" "filled" "$WIN_KVK" "$WIN_KVV") || _ft=""
                if [[ -n $_ft ]] && [[ $(echo "$_ft > 0" | bc 2>/dev/null || echo "0") == 1 ]]; then
                    IFS='|' read -r _fd _fp _ff < "/tmp/at-metrics-$$" 2>/dev/null || true
                    echo "  ctx $(fmt "$_dc") - filled ${_ft} tps (prefill ${_fp:-0} tok/s)"
                    BEST_CTX=$_dc; BEST_TPS=$_ft; BEST_PREFILL="${_fp:-0}"
                    _dok=0; _pok=0
                    [[ $(echo "$_ft >= $MIN_TPS" | bc 2>/dev/null || echo "0") == 1 ]] && _dok=1
                    if [[ $MIN_PREFILL_TPS == 0 ]] \
                        || [[ $(echo "${_fp:-0} >= $MIN_PREFILL_TPS" | bc 2>/dev/null || echo "0") == 1 ]]; then
                        _pok=1
                    fi
                    if [[ $_dok == 1 && $_pok == 1 ]]; then
                        echo "  ✓ floor met at ctx $(fmt "$_dc") — certifying this as the usable ctx"
                        break
                    fi
                fi
            done
            if [[ $_dok == 0 || $_pok == 0 ]]; then
                echo "  ⚠ below floor even at min ctx — too slow for our purposes; recording best-effort config"
            fi
        fi
    else
        _FAST_REJECT=0
        fail_label="OOM"
        [[ $(last_fail_type) == "load_fail" ]] && fail_label="unsupported model"
        echo "  ctx $(fmt "$_dc") - filled ${fail_label} (capacity ctx failed the filled load — descending once)"
        # The capacity ctx failed the FILLED load (memory pressure at fill) — fall back to a
        # quick descent for a working filled ctx.  Same candidate list, so it also cannot step
        # below a window this row already holds without testing it.
        for _dc in $(__autotune_descent_candidates "$_dc" "$MIN_CTX" "$PREV_CERT_CTX"); do
            _ft=$(bench_ctx "$_dc" "$BEST_B" "$BEST_U" 3 "$EFFECTIVE_MMAP" "$WIN_NGL" "filled" "$WIN_KVK" "$WIN_KVV") || _ft=""
            if [[ -n $_ft ]] && [[ $(echo "$_ft > 0" | bc 2>/dev/null || echo "0") == 1 ]]; then
                IFS='|' read -r _fd _fp _ff < "/tmp/at-metrics-$$" 2>/dev/null || true
                echo "  ctx $(fmt "$_dc") - filled ${_ft} tps (prefill ${_fp:-0} tok/s)"
                BEST_CTX=$_dc; BEST_TPS=$_ft; BEST_PREFILL="${_fp:-0}"
                break
            fi
        done
    fi

    # Final certification: multi-sample (median) at the winner for the
    # recorded number — the persisted TPS is a robust estimate, not a burst.
    # 5 samples (2026-09-14, was 3): this box spans ~45-67 tps on the same
    # binary, prompt and n_predict (±15%), and a median-of-3 of that still
    # carries ~10% standard error — enough to flip a row that sits near a role
    # admission threshold.  bench_once_multi spawns ONE server and issues N
    # requests against it, so the extra samples cost no extra CUDA contexts,
    # only wall-clock.  Median SE falls as 1/sqrt(n): 5 gives ~29% less
    # spread than 3.
    _FAST_REJECT=0
    : > "/tmp/at-served-ctx-$$" 2>/dev/null || rm -f "/tmp/at-served-ctx-$$" 2>/dev/null || true
    _cert=$(bench_ctx "$BEST_CTX" "$BEST_B" "$BEST_U" 5 "$EFFECTIVE_MMAP" "$WIN_NGL" "filled" "$WIN_KVK" "$WIN_KVV") || _cert=""
    # The ctx the server ACTUALLY served, captured by bench_ctx from its live server.
    # Carried to the save site, which has no server of its own to ask.  Read from the
    # dedicated file FIRST: it holds the last successful /props read of this server, so a
    # sample rejected mid-prompt (400) cannot drop it — the metrics line would have been
    # rewritten as "0|0|oom".  Captured whether or not the tps sample survived, because
    # the served window is a fact about the live server, not about the measurement.
    _served_now=$(cat "/tmp/at-served-ctx-$$" 2>/dev/null || true)
    IFS='|' read -r _fd2 _fp2 _ff2 _fa2 _fr2 _fb2 _served2 < "/tmp/at-metrics-$$" 2>/dev/null || true
    [[ -n "${_served_now:-}" ]] && _served2="$_served_now"
    if [[ "${_served2:-}" =~ ^[0-9]+$ ]] && (( _served2 > 0 )); then
        AUTOTUNE_SERVED_CTX=$_served2
    fi
    if [[ -n $_cert ]] && [[ $(echo "$_cert > 0" | bc 2>/dev/null || echo "0") == 1 ]]; then
        BEST_TPS=$_cert
        BEST_PREFILL="${_fp2:-0}"
    fi

    # POST-CERTIFICATION FLOOR DESCENT (2026-09-17).  Phase 4's floor gate judges every rung
    # from ONE sample, and at large ctx a single sample overstates the SUSTAINED rate by
    # 3.6-4.7x.  Rows 13 and 14 passed the gate at ctx 131,072 (13.89 / 14.57 tps on one
    # sample, reproduced on a cold boot) and then certified at 2.95 / 3.12 tps with the
    # 5-sample median, with the ttft probe independently agreeing with the CERTIFICATION
    # (3.28 vs 3.12).  So the gate passed windows the rows cannot hold, the descent never
    # ran, and each was left advertising a ctx it cannot sustain.  It is ctx-dependent —
    # rows 2 and 12 at 4.6-6.6K certify within 1.2-1.4x of their rungs — which is why it
    # went unnoticed: only huge-context fills pay the cache pressure that depresses the
    # later samples.
    #
    # Descending HERE, at the CERTIFICATION'S OWN sample count, makes the gate and the
    # recorded value the same measurement.  The cost falls only on rows that fail the gate,
    # and one bench_ctx call is one CUDA cycle per rung (N requests against one server).
    if [[ $BEST_CTX -gt $MIN_CTX ]] \
        && [[ $(echo "${BEST_TPS:-0} < $MIN_TPS" | bc 2>/dev/null || echo "0") == 1 ]]; then
        echo "  certified ${BEST_TPS} tps is below the floor at ctx $(fmt "$BEST_CTX")" \
            "— descending at the certification's sample count"
        for _cert_dc in $(__autotune_descent_candidates "$BEST_CTX" "$MIN_CTX" "$PREV_CERT_CTX"); do
            : > "/tmp/at-served-ctx-$$" 2>/dev/null || rm -f "/tmp/at-served-ctx-$$" 2>/dev/null || true
            _cert_t=$(bench_ctx "$_cert_dc" "$BEST_B" "$BEST_U" 5 \
                "$EFFECTIVE_MMAP" "$WIN_NGL" "filled" "$WIN_KVK" "$WIN_KVV") || _cert_t=""
            if [[ -z "$_cert_t" ]] || [[ $(echo "${_cert_t:-0} > 0" | bc 2>/dev/null || echo "0") != 1 ]]; then
                echo "  ctx $(fmt "$_cert_dc") — filled load failed, continuing down"
                continue
            fi
            IFS='|' read -r _cert_d _cert_p _cert_f < "/tmp/at-metrics-$$" 2>/dev/null || true
            echo "  ctx $(fmt "$_cert_dc") - filled ${_cert_t} tps (prefill ${_cert_p:-0} tok/s)"
            if [[ $(echo "$_cert_t >= $MIN_TPS" | bc 2>/dev/null || echo "0") == 1 ]]; then
                BEST_CTX=$_cert_dc; BEST_TPS=$_cert_t; BEST_PREFILL="${_cert_p:-0}"
                _cert_served=$(cat "/tmp/at-served-ctx-$$" 2>/dev/null || true)
                if [[ "${_cert_served:-}" =~ ^[0-9]+$ ]] && (( _cert_served > 0 )); then
                    AUTOTUNE_SERVED_CTX=$_cert_served
                fi
                echo "  ✓ floor met at ctx $(fmt "$_cert_dc") — certifying this as the usable ctx"
                break
            fi
        done
    fi
    # Record GPU thermal/clock state alongside the certified number — heat
    # soak on a laptop biases later benches; the temp explains outliers.
    if command -v nvidia-smi >/dev/null 2>&1; then
        _gpu_thermal=$(nvidia-smi --query-gpu=temperature.gpu,clocks.sm --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ')
        echo "  thermal at certification: GPU ${_gpu_thermal:-n/a} (temp °C, SM MHz)"
    fi

    # tps-collapse guard (WSL2 dxgkrnl degradation): the dmesg EOVERFLOW proxy
    # can miss a leak, but the reliable symptom is a model re-certifying at a
    # large factor below its previously-recorded filled-cache tps (registry
    # field 17).  The OpenClaw gateway marks tiny/instant models with a
    # sentinel 1000000, so a recorded value is only compared when it is a
    # plausible measured decode (0 < tps < 1000).  Warn only — a drop can also
    # be a genuine hardware/quant regression, so never abort.
    if [[ "${_tps:-}" =~ ^[0-9]+(\.[0-9]+)?$ ]] \
        && [[ "${BEST_TPS:-0}" =~ ^[0-9]+(\.[0-9]+)?$ ]] \
        && [[ $(echo "${_tps:-0} > 0" | bc 2>/dev/null || echo "0") == 1 ]] \
        && [[ $(echo "${_tps:-0} < 1000" | bc 2>/dev/null || echo "0") == 1 ]] \
        && [[ $(echo "${_tps:-0} >= 2 * ${BEST_TPS:-0}" | bc 2>/dev/null || echo "0") == 1 ]]; then
        echo ""
        echo "  ⚠ WARN: tps collapse — certified ${BEST_TPS} tps vs recorded ${_tps} tps (>=2x drop)."
        echo "           GPU may be degraded (WSL2 dxgkrnl leak); the re-certified numbers are untrustworthy."
        echo "           Restart WSL (wsl --shutdown) before trusting this re-tune."
        echo ""
    fi
fi

_cuda_guard_or_exit

# After a TPS-floor descent, the interactive profile must never exceed the
# certified ctx (a below-floor model's P2 was probed at its old capacity).
#
# Clamped BEFORE the certification below, deliberately — not after it. Applying
# the clamp afterwards rewrote P2_CTX while leaving P2_TPS as measured at the
# un-clamped ctx, so the persisted (p2_ctx, p2_tps) pair described a measurement
# that was never taken at the ctx it names. That is how a row came to carry a
# p2_tps several times BELOW a tps measured at the very same config (7.7x,
# 2026-09-15), which no consumer could distinguish from a real regression.
# Clamping first means the pair written to the registry is always one real
# measurement at the ctx it reports, so nothing needs a "was it clamped?"
# caveat to know whether p2_tps is trustworthy.
if [[ $P2_CTX -gt $BEST_CTX ]]; then
    echo "  profile 2 ctx $(fmt "$P2_CTX") clamped to certified $(fmt "$BEST_CTX")"
    P2_CTX=$BEST_CTX
fi

# Profile 2 (interactive) certification: one filled bench at the max-TPS
# config so the persisted numbers are honest sustained throughput.
if [[ $ANY_OK == true && -n $BEST_COMBO ]] && [[ $P2_CTX -gt 0 ]]; then
    if [[ "$P2_CTX|$P2_B:$P2_U" != "$BEST_CTX|$BEST_B:$BEST_U" ]]; then
        echo "  certifying profile 2 (interactive) at ctx=$(fmt "$P2_CTX")  $(fmt "$P2_B")/$(fmt "$P2_U")"
        # 3 samples (2026-09-14, was 1).  The old "one sample keeps churn to a
        # single launch" reasoning was wrong: N samples reuse ONE spawn
        # (bench_once_multi issues N requests against one server), so more
        # samples cost no extra CUDA contexts — while a single sample of a
        # ±15% measurement is not evidence at all.
        _p2t=$(bench_ctx "$P2_CTX" "$P2_B" "$P2_U" 3 "$EFFECTIVE_MMAP" "$WIN_NGL" "filled" "$WIN_KVK" "$WIN_KVV") || _p2t=""
        if [[ -n $_p2t ]] && [[ $(echo "$_p2t > 0" | bc 2>/dev/null || echo "0") == 1 ]]; then
            P2_TPS=$_p2t
            IFS='|' read -r _pd3 _pp3 _pf3 < "/tmp/at-metrics-$$" 2>/dev/null || true
            P2_PREFILL="${_pp3:-0}"
        fi
    else
        P2_TPS=$BEST_TPS; P2_PREFILL=$BEST_PREFILL
    fi
fi

# ── SPEC-DEC-004: speculative-decoding block-size sweep ─────────────────────
# The article's central tuning rule: optimal block size
# (num_speculative_tokens) depends on hardware + concurrency, so it must be
# tuned empirically per model and the winner recorded.  On the 4 GB card the
# sweep uses VRAM-free ngram spec-decode (no extra model, --spec-type
# ngram-mod) with the verified llama.cpp flags; a CPU-placed draft model
# (BENCH_SPEC_DRAFT_MODEL) is honoured when the user provides one.  The TPS
# comparison uses the de-inflated delivered-token TPS (SPEC-DEC-003) and the
# acceptance LENGTH of the winning block is recorded alongside.
# REF: "Speculative Decoding on CPUs — Nearly 4x Faster Token Generation with
# DFlash" (Intel, TDS 2026)
# https://towardsdatascience.com/speculative-decoding-on-cpus-nearly-4x-faster-token-generation-with-dflash/
WIN_SPEC_TYPE=""; WIN_SPEC_N_MAX=""; WIN_SPEC_ACCEPT_LEN=""
SPEC_N_MAX_LIST=${LLM_AUTOTUNE_SPEC_N_MAX_LIST:-"4 8 16 32"}
if [[ $ANY_OK == true && -n $BEST_COMBO ]]; then
    IFS=':' read -r _sb_b _sb_u <<< "$BEST_COMBO"
    echo ""
    _cuda_guard_or_exit
    echo "  spec-decode block-size sweep (ngram, VRAM-free)  [${SPEC_N_MAX_LIST}]"
    echo "  -------------------------------------"
    _sb_best_tps="0"
    # AUTOTUNE_SPEC_SWEEP=0 skips the sweep: it is FOUR launches per row and its
    # result feeds only the recorded spec block.  Default is ON — for a slow
    # model spec-decode is exactly the lever that raises tps, so this is an
    # opt-out for a run that must conserve CUDA context cycles, not a saving.
    _sb_list="$SPEC_N_MAX_LIST"
    if [[ "${AUTOTUNE_SPEC_SWEEP:-1}" == "0" ]]; then
        _sb_list=""
        echo "  (AUTOTUNE_SPEC_SWEEP=0 — skipping the sweep to conserve CUDA cycles)"
    fi
    for _sb_block in $_sb_list
    do
        if [[ ! "$_sb_block" =~ ^[0-9]+$ ]] || (( _sb_block <= 0 )); then
            continue
        fi
        BENCH_SPEC_TYPE="ngram"; BENCH_SPEC_N_MAX="$_sb_block"
        # samples=1 (not 3): the block sweep is a *selection*, not a recorded
        # number — a single sample per block keeps the CUDA-context churn to
        # 4 launches instead of 12, which matters because WSL2 dxgkrnl leaks
        # GPU VA per launch (~26-cycle knee at huge ctx, measured 2026-09-05).
        _sb_t=$(bench_ctx "$BEST_CTX" "$_sb_b" "$_sb_u" 1 "$EFFECTIVE_MMAP" "$WIN_NGL" "filled" "$WIN_KVK" "$WIN_KVV") || _sb_t=""
        _sb_t=$(echo "$_sb_t" | bc 2>/dev/null || echo "0"); [ -z "$_sb_t" ] && _sb_t=0
        _sb_al="0"; _sb_ar="0"
        IFS='|' read -r _sb_d _sb_p _sb_f _sb_al _sb_ar _sb_bl < "/tmp/at-metrics-$$" 2>/dev/null || true
        echo "  block ${_sb_block}: ${_sb_t} tps (accept len ${_sb_al:-0}, rate ${_sb_ar:-0})"
        if [[ $(echo "$_sb_t > $_sb_best_tps" | bc 2>/dev/null || echo "0") == 1 ]]; then
            _sb_best_tps="$_sb_t"
            WIN_SPEC_TYPE="ngram"; WIN_SPEC_N_MAX="$_sb_block"; WIN_SPEC_ACCEPT_LEN="$_sb_al"
        fi
    done
    BENCH_SPEC_TYPE="off"; BENCH_SPEC_N_MAX=""; BENCH_SPEC_DRAFT_MODEL=""
    if [[ -n "$WIN_SPEC_N_MAX" ]]; then
        echo "  spec-decode winner: block ${WIN_SPEC_N_MAX} (${_sb_best_tps} tps, accept len ${WIN_SPEC_ACCEPT_LEN:-0})"
        echo "  spec-decode is LOSSLESS (rejects preserve the target distribution) — preferred over"
        echo "  lossy quantization for quality-critical paths; ngram needs no extra model on 4 GB."
    else
        echo "  spec-decode: no block beat the no-spec baseline — leaving spec-decode off"
    fi
fi


# ---------------------------------------------------------------------------
# ttft_probe — time-to-first-token at a config (AUTOTUNE-003).
#   args: ctx batch ubatch [mmap] [ngl] [kv_k] [kv_v]
# Launches the server exactly like the scoring bench, then sends a STREAMING
# completion shaped like an agentic step — the WORKLOAD prompt pre-filling the
# KV cache (FILL_RATIO x ctx), a short 64-token budget — and times the first
# content token (the SSE stream delivers the first `delta.content` when the
# first token is generated; TPS-style burst measurements cannot see this).
# Also computes the per-step decode latency (ms/token after the first token).
# Prints "ttft_ms|per_step_ms" on stdout; empty on failure.
# ---------------------------------------------------------------------------
if [[ "${AUTOTUNE_SELFTEST:-0}" != "1" ]]; then
ttft_probe() {
    local c="$1" b="$2" u="$3" mmap_mode="${4:-auto}" override_ngl="${5:-}"
    local kv_k="${6:-q8_0}" kv_v="${7:-q8_0}"
    local effective_ngl="${override_ngl:-${BENCH_NGL:-999}}"
    local autotune_port="${AUTOTUNE_PORT:-18082}"
    local health_url="http://127.0.0.1:$autotune_port"
    local flash_attn="on" pid="" hw=0

    cleanup_gpu >&2 || { echo ""; return 1; }

    # build 10955 removed --no-mmap; an array (not a string) so the two words
    # stay two argv entries and shellcheck's SC2086 stays quiet.
    local -a mmap_flag=()
    [[ $mmap_mode == off ]] && mmap_flag=(--load-mode none)

    _launch_ttft_server() {
        local -a fa_args=()
        [[ $flash_attn == "on" ]] && fa_args=(--flash-attn on) || fa_args=(--flash-attn off)
        "$LLAMA_BIN" --model "$MODEL_PATH" --port "$autotune_port" --host 127.0.0.1 \
            --ctx-size "$c" --batch-size "$b" --ubatch-size "$u" \
            --threads "$TUNE_THREADS" --n-gpu-layers "$effective_ngl" \
            --parallel 1 --fit off "${fa_args[@]}" --kv-offload \
            --cache-type-k "$kv_k" --cache-type-v "$kv_v" "${mmap_flag[@]}" \
            > "/tmp/at-ttft-${MODEL}-c${c}.log" 2>&1 &
        pid=$!
        _bump_cuda_cycle
        hw=0
        while [[ $hw -lt 90 ]]; do
            sleep 1; hw=$((hw + 1))
            kill -0 "$pid" 2>/dev/null || return 1
            curl -sS --max-time 2 "$health_url/health" 2>/dev/null | grep -q '"status":"ok"' && return 0
        done
        return 1
    }
    _launch_ttft_server || {
        if [[ $flash_attn == "on" ]]; then
            _bench_stop "$pid"
            flash_attn="off"
            _launch_ttft_server || true
        fi
    }
    if [[ $hw -ge 90 ]]; then
        _bench_stop "$pid"
        echo ""; return 1
    fi

    # Pre-flight: one real completion confirms the slot is actually serving
    # (the same guard the scoring bench uses).
    local pf_ok=0 pf_w=0
    while [[ $pf_w -lt 60 ]]; do
        if curl -sS --max-time 5 "$health_url/v1/chat/completions" \
            -H "Content-Type: application/json" \
            -d '{"messages":[{"role":"user","content":"hi"}],"max_tokens":1,"temperature":0}' \
            2>/dev/null | "$TAC_PYTHON" -c "import sys,json; d=json.load(sys.stdin); print(d.get('usage',{}).get('completion_tokens',0))" 2>/dev/null | grep -q '[1-9]'; then
            pf_ok=1; break
        fi
        kill -0 "$pid" 2>/dev/null || { echo ""; return 1; }
        sleep 1; pf_w=$((pf_w + 1))
    done
    if [[ $pf_ok -ne 1 ]]; then
        _bench_stop "$pid"
        echo ""; return 1
    fi

    # Streaming payload: the workload prompt fills the cache (same length
    # policy as the scoring fill) with a short 64-token completion budget.
    local ttft_payload="/tmp/at-ttft-${MODEL}-${c}.json"
    local _fill_tokens
    _fill_tokens=$(awk -v cc="$c" -v r="$FILL_RATIO" 'BEGIN{printf "%d", cc*r}')
    [[ $_fill_tokens -gt $FILL_MAX_TOKENS ]] && _fill_tokens=$FILL_MAX_TOKENS
    [[ $_fill_tokens -lt $FILL_MIN_TOKENS ]] && _fill_tokens=$FILL_MIN_TOKENS
    if [[ "${BENCH_NGL:-999}" == "0" ]]; then
        local _cpu_cap=8192
        [[ $_fill_tokens -gt $_cpu_cap ]] && _fill_tokens=$_cpu_cap
    fi
    local _fill_source
    _fill_source="$(__workload_prompt_text "$WORKLOAD")"
    "$TAC_PYTHON" - "$_fill_tokens" "$ttft_payload" "$_fill_source" << 'PYEOF'
import json, sys
tokens = int(sys.argv[1])
out = sys.argv[2]
source = sys.argv[3]
count = tokens * 4 // max(1, len(source)) + 1
content = (source * count)[: tokens * 5]
payload = {
    "messages": [{"role": "user", "content": content}],
    "max_tokens": 64,
    "temperature": 0,
    "stream": True,
}
with open(out, "w") as f:
    json.dump(payload, f)
PYEOF

    local start_ns; start_ns=$(date +%s%N)
    local body="/tmp/at-ttft-body-$$"
    local parsed
    # AUTOTUNE-003: the stream probe must POST to the chat-completions
    # endpoint — the bare server root (health_url without the path) answers
    # with a non-SSE error in milliseconds, so TTFT was always 0 no matter
    # how the SSE body was parsed (2026-08-27: 15/15 rows ttft_ms=0).
    parsed=$("$TAC_PYTHON" - "$health_url/v1/chat/completions" "$ttft_payload" "$start_ns" "$body" << 'PYEOF'
import json, sys, time, urllib.request
url, payload_path, start_ns, body_path = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
with open(payload_path, "rb") as f:
    data = f.read()
req = urllib.request.Request(
    url,
    data=data,
    headers={"Content-Type": "application/json"},
    method="POST",
)
ttft_ms = 0
count = 0
buf = b""
try:
    with urllib.request.urlopen(req, timeout=1200) as resp:
        with open(body_path, "wb") as out:
            for raw in resp:
                out.write(raw)
                # SSE events are newline-delimited, but socket reads are NOT
                # line-aligned: a chunk can hold a partial event, several
                # events, or a split line. Buffer and split on "\n" so the
                # first content delta is actually seen (AUTOTUNE-003: TTFT
                # was always 0 because coalesced/split events never parsed).
                buf += raw
                while b"\n" in buf:
                    line, buf = buf.split(b"\n", 1)
                    line = line.decode("utf-8", errors="replace").strip()
                    if not line.startswith("data: "):
                        continue
                    payload = line[6:]
                    if payload == "[DONE]":
                        break
                    try:
                        obj = json.loads(payload)
                    except Exception as exc:
                        print(f'[autotune] warning: skipping malformed SSE chunk: {exc}', file=sys.stderr)
                        continue
                    delta = (obj.get("choices") or [{}])[0].get("delta") or {}
                    # AUTOTUNE-003: reasoning models (R1 distills,
                    # MiniCPM-thinking) can stream the whole 64-token budget
                    # as reasoning_content with no content delta at all —
                    # the first token of EITHER field marks generation start
                    # (2026-08-27: TTFT stayed 0 for such models).
                    if delta.get("content") or delta.get("reasoning_content"):
                        if ttft_ms == 0:
                            ttft_ms = (time.time_ns() - start_ns) // 1_000_000
                        count += 1
                else:
                    continue
                break
except Exception as exc:
    print(f'[autotune] warning: ttft probe stream failed: {exc}', file=sys.stderr)
    sys.exit(1)
print("%s|%s" % (ttft_ms, count))
PYEOF
    )
    local _tt_rc=$?
    local end_ns; end_ns=$(date +%s%N)
    _bench_stop "$pid"
    if [[ $_tt_rc -ne 0 ]] || [[ -z "$parsed" ]]; then
        # A request/stream failure (HTTP 400, connection reset, etc.) is NOT
        # a 0ms TTFT — the old fallback (`parsed="0|0"`) recorded a failed
        # probe as an instantaneous response, which then persisted a
        # fabricated ttft_ms=0 into the saved profile (2026-09-14). Propagate
        # the failure so the caller reports it as "failed" instead.
        return 1
    fi

    local total_ms=$(( (end_ns - start_ns) / 1000000 ))
    local ttft_ms delivered per_step
    IFS='|' read -r ttft_ms delivered <<< "$parsed"
    [[ "$ttft_ms" =~ ^[0-9]+$ ]] || ttft_ms=0
    [[ "$delivered" =~ ^[0-9]+$ ]] || delivered=0
    if [[ $ttft_ms -gt 0 ]] && [[ $delivered -gt 0 ]] && [[ $total_ms -gt $ttft_ms ]]; then
        per_step=$(awk -v t="$total_ms" -v f="$ttft_ms" -v d="$delivered" 'BEGIN{printf "%.1f", (t-f)/d}')
    else
        per_step=0
    fi
    echo "${ttft_ms}|${per_step}"
}
fi  # AUTOTUNE_SELFTEST guard — the stub defined in the selftest block wins.

# ── AUTOTUNE-003: time-to-first-token at the winning config ─────────────────
# Agentic steps are latency-bound (long prompt, short completion) — TTFT is
# the decisive metric and the burst TPS floor cannot see it.  One streaming
# sample at the winning config; the TTFT is recorded in the registry
# (column 34) and surfaced next to TPS in the summary.
TTFT_MS=0; TTFT_PER_STEP=0
if [[ $ANY_OK == true && -n $BEST_COMBO ]]; then
    IFS=':' read -r BEST_B BEST_U <<< "$BEST_COMBO"
    echo ""
    # 1 sample (not 3): TTFT is a secondary latency metric; a single sample
    # keeps the CUDA-context churn to one launch (WSL2 dxgkrnl VA leak).
    echo "  TTFT probe at ctx=$(fmt "$BEST_CTX")  (workload ${WORKLOAD}, 1 sample)"
    echo "  ---------------------"
    _tt_samples=()
    _ps_samples=()
    _tt=$(ttft_probe "$BEST_CTX" "$BEST_B" "$BEST_U" "$EFFECTIVE_MMAP" "$WIN_NGL" "$WIN_KVK" "$WIN_KVV") || _tt=""
    if [[ -n "$_tt" ]]; then
        IFS='|' read -r _ttv _psv <<< "$_tt"
        echo "  sample 1: ttft ${_ttv:-0} ms (per-step decode ${_psv:-0} ms/token)"
        [[ "$_ttv" =~ ^[0-9]+$ ]] && _tt_samples+=("$_ttv")
        [[ "$_psv" =~ ^[0-9]+(\.[0-9]+)?$ ]] && _ps_samples+=("$_psv")
    else
        echo "  sample 1: failed"
    fi
    if [[ ${#_tt_samples[@]} -ge 1 ]]; then
        TTFT_MS=$(printf '%s\n' "${_tt_samples[@]}" | LC_ALL=C sort -n | awk '{a[NR]=$1} END { if (NR%2) print a[(NR+1)/2]; else printf "%.0f\n", (a[NR/2]+a[NR/2+1])/2 }')
        TTFT_PER_STEP=$(printf '%s\n' "${_ps_samples[@]}" | LC_ALL=C sort -n | awk '{a[NR]=$1} END { if (NR%2) print a[(NR+1)/2]; else printf "%.1f\n", (a[NR/2]+a[NR/2+1])/2 }')
        echo "  ttft: ${TTFT_MS} ms (median)  per-step decode: ${TTFT_PER_STEP} ms/token"
    fi
fi

# ── AUTOTUNE-004 retired (2026-09-14): there is no envelope to measure ──────
# The sweep that lived here tried 2/4/8/16 slots at the winning ctx and
# recorded the largest that "served", on the premise that N slots at the full
# ctx over-commit VRAM (unified-KV semantics).  The launcher never passed
# --kv-unified, so kv_unified stayed false and each slot silently received
# ctx/N — which is exactly why this recorded the MAXIMUM (16) in 34 of 35 rows:
# under the premise it assumed, 16 x ~1.2 GB of KV could not fit a 4 GB card,
# so its own result falsified its premise.  It certified the one property
# nobody doubted (that it loads) and could not see the one that mattered (at
# what window).  --parallel is now pinned to 1 in the launcher, so the column
# records 1.  Retiring the sweep also removes FOUR llama-server launches per
# row from the WSL2 dxgkrnl context-cycle budget.
WIN_PARALLEL=1

# REF: ubuntu-console card ca23ec0a — cleanup_gpu uses AUTOTUNE_PORT (18082), not the production port 18081
cleanup_gpu 3 >/dev/null 2>&1 || { echo "ERROR: cleanup_gpu failed after 3 retries — port ${AUTOTUNE_PORT:-18082} still bound" >&2; exit 1; }
echo ""

if [[ $ANY_OK == true && -n $BEST_COMBO ]]; then
    IFS=':' read -r BEST_B BEST_U <<< "$BEST_COMBO"

    # Capability verdict relative to the floor (filled-cache decode TPS). We
    # always persist the best config we found (autotuned=yes ⇒ "this model has
    # been profiled"), and the recorded TPS is the honest, machine-readable
    # signal of usability:
    #   tps >= floor  → usable; ctx is the maximum that sustains the floor.
    #   tps <  floor  → too slow for our purposes even at min ctx; the saved
    #                   config is the fastest one available (best-effort).
    if [[ $(echo "$BEST_TPS >= $MIN_TPS" | bc 2>/dev/null || echo "0") == 1 ]]; then
        echo "  ✓ meets floor: ${BEST_TPS} tps >= ${MIN_TPS} at ctx $(fmt "$BEST_CTX")"
    else
        echo "  ⚠ below floor: ${BEST_TPS} tps < ${MIN_TPS} even at min ctx — too slow for our purposes"
        echo "    recording best-effort config (max TPS) for capability profiling"
        echo "    NOTE: below-floor can also be WSL2 GPU degradation (dxgkrnl tps collapse,"
        echo "          not just model slowness) — if the tps is implausibly low for this"
        echo "          model, restart WSL (wsl --shutdown) and re-tune to disambiguate."
    fi
    echo "      prefill: ${BEST_PREFILL:-0} tok/s"
    if [[ $MIN_PREFILL_TPS != 0 ]] && [[ $(echo "${BEST_PREFILL:-0} < $MIN_PREFILL_TPS" | bc 2>/dev/null || echo 0) == 1 ]]; then
        echo "  ⚠ prefill ${BEST_PREFILL:-0} tok/s below prefill floor ${MIN_PREFILL_TPS}"
    fi
    if [[ $WIN_NGL != "$BENCH_NGL" ]]; then
        echo "  ✓ ngl swept: ${BENCH_NGL} -> ${WIN_NGL}"
    fi
    if [[ "$WIN_KVK:$WIN_KVV" != "q8_0:q8_0" ]]; then
        echo "  ✓ KV quant swept: cache k=$WIN_KVK v=$WIN_KVV"
    fi
    if [[ $P2_CTX -gt 0 ]]; then
        echo "  profile 2: ctx=$(fmt "$P2_CTX")  batch=$(fmt "$P2_B")/$(fmt "$P2_U")  ${P2_TPS} tps (prefill ${P2_PREFILL:-0})"
    fi

    # Record what the server ACTUALLY served, not what we asked for.  llama.cpp clamps
    # the served window to the model's own <arch>.context_length at load — measured
    # 2026-09-16: requests of 47104, 65536, 100352 and 131072 all served 32768, 147456
    # served 131072, and 476928 and 373248 served 262144, each exactly that model's native
    # window.  It is NOT a VRAM-dependent reduction: the same values came back at ngl 24
    # and ngl 999 and with --fit on and off, while every row asking for LESS than its native
    # window served the full request.  Eleven of 26 rows carried a ctx no client would ever
    # get — the 400-mid-prompt hazard docs/llm.md names, observed live as "ttft probe stream
    # failed: HTTP Error 400" on a row asking 8192 of a 2048-native model — because the
    # winner was recorded from the value the probe ASKED for.  Reading /props is the only
    # honest source; when it cannot be read the run keeps the requested ctx and SAYS SO.
    if [[ $BEST_CTX -gt 0 ]]
    then
        # AUTOTUNE_SERVED_CTX was captured by bench_ctx from ITS live server, via the
        # metrics line (the subshell does not export globals).  This site has no server of
        # its own — the winner is a configuration, not a running process — which is why the
        # first version of this check could only ever warn.
        if [[ "${AUTOTUNE_SERVED_CTX:-}" =~ ^[0-9]+$ ]] && (( AUTOTUNE_SERVED_CTX > 0 ))
        then
            if (( AUTOTUNE_SERVED_CTX != BEST_CTX ))
            then
                echo "  served:  ctx=$(fmt "$AUTOTUNE_SERVED_CTX")  (the server reduced the requested ctx=$(fmt "$BEST_CTX") at load — recording what a client receives)"
            fi
            BEST_CTX=$AUTOTUNE_SERVED_CTX
        else
            echo "  WARNING: the served ctx was never captured from a live server — recording the requested ctx=$(fmt "$BEST_CTX"), which may be larger than this server serves" >&2
        fi
    fi

    END_TS=$(date '+%H:%M:%S')
    DURATION=$(( $(date +%s) - START_EPOCH ))
    printf '  time:    %s \u2192 %s  (%dm %ds)\n' "$START_TS" "$END_TS" $((DURATION/60)) $((DURATION%60))
    echo "  winner:  ctx=$(fmt "$BEST_CTX")  batch=$(fmt "$BEST_B")/$(fmt "$BEST_U")  ${BEST_TPS} tps  (workload ${WORKLOAD})"
    if [[ $TTFT_MS -gt 0 ]]; then
        echo "  ttft:    ${TTFT_MS} ms at ctx=$(fmt "$BEST_CTX")  (per-step decode ${TTFT_PER_STEP} ms/token)"
    fi
    echo "  envelope: ctx=$(fmt "$BEST_CTX") / parallel ${WIN_PARALLEL}"

    # Profile-2 fields only when profile 2 exists (BEST exists ⇒ P2 exists).
    _P2ARGS=("" "" "" "" "")
    [[ $P2_CTX -gt 0 ]] && _P2ARGS=("$P2_CTX" "$P2_B" "$P2_U" "$P2_TPS" "$P2_PREFILL")
    # KV quant save: "QUANT/type-k/type-v" (field 5), preserving the quant part.
    KV_QUANT_SAVE=""
    if [[ -n "${_qc%%/*}" ]]; then
        KV_QUANT_SAVE="${_qc%%/*}/${WIN_KVK}/${WIN_KVV}"
    fi
    # AUTOTUNE_SELFTEST never persists — the canned curve is a decision-logic
    # regression, not a measurement (2026-08-27: a selftest run wrote its
    # 524288/8.5 into registry row 3, polluting the real profile).
    if [[ "${AUTOTUNE_SELFTEST:-0}" == "1" ]]; then
        echo "  (selftest — registry write skipped)"
    elif declare -f __llm_autotune_profile_save &>/dev/null; then
        # SPEC-DEC-004: record the winning spec block + measured acceptance
        # length (registry fields 27/29/32) alongside the ctx/batch winner.
        # AUTOTUNE-001: the scoring workload rides in field 33 so consumers
        # know which prompt distribution certified the winner.
        # AUTOTUNE-003: the median TTFT at the winning ctx rides in field 34.
        # AUTOTUNE-004: the measured (ctx, parallel) envelope rides in the
        # parallel column (field 12) — launches validate --parallel N against
        # it and warn when over-subscribed (11e-llm-model.sh).
        # The FILE name, not the row number: this run tuned MODEL_PATH, so this run's
        # numbers belong to that file whatever the row numbering does meanwhile.
        __llm_autotune_profile_save "$MODEL_FILE" "native" "$BEST_CTX" "$BEST_B" "$BEST_U" "$WIN_PARALLEL" "256" "$BEST_TPS" \
            "" "$BEST_PREFILL" "${_P2ARGS[@]}" "$KV_QUANT_SAVE" "$WIN_NGL" \
            "$WIN_SPEC_TYPE" "" "$WIN_SPEC_N_MAX" "" "" "$WIN_SPEC_ACCEPT_LEN" \
            "$WORKLOAD" "$TTFT_MS" \
            || echo "  warning: profile save failed"
    else
        # A missing helper used to take NEITHER branch and then still print the
        # `saved:` line below straight out of the unchanged registry row — a run
        # that certified nothing while reading as success (2026-09-13: an entire
        # sweep "completed" this way after the console's llm-manager sub-modules
        # failed to load).  Fail loudly and non-zero so the caller marks the row.
        echo "  ERROR: __llm_autotune_profile_save is not loaded — the winner was NOT saved." >&2
        echo "         The console's llm-manager helpers failed to load; look for 'missing sub-module' above." >&2
        exit 1
    fi
    awk -F'|' -v f="$MODEL_FILE" '$3 == f {printf "  saved:   ctx=%s batch=%s/%s parallel=%s tps=%s prefill=%s autotuned=%s spec_type=%s spec_n_max=%s spec_accept_len=%s workload=%s ttft_ms=%s\n", $8, $10, $11, $12, $17, $21, $18, $27, $29, $32, $33, $34}' "$LLM_REGISTRY"

    # Measurement context (2026-09-16).  A certified tps is only comparable to another
    # row if the box was quiet when it was taken.  On 2026-09-16 this sweep ran at load
    # 20-26 on 12 cores and row 2 recorded .96 tps mid-run, with NOTHING in the output
    # saying so — the number reads as a property of the model.  Printing the load beside
    # it is the cheap half of the fix; the warning is for the case where it is not cheap.
    # (Not `local`: this block is script scope, not a function — SC2168.)
    _row_load=$(cut -d' ' -f1 /proc/loadavg 2>/dev/null || echo "?")
    _row_cores=$(nproc 2>/dev/null || echo "?")
    if [[ "$_row_load" =~ ^[0-9.]+$ && "$_row_cores" =~ ^[0-9]+$ ]] \
        && awk -v l="$_row_load" -v c="$_row_cores" 'BEGIN{exit !(l > c)}'
    then
        echo "  WARNING: measured at load ${_row_load} on ${_row_cores} cores — the box was CONTENDED, so this row's tps is indicative, not certified. Re-run it on a quiet box before trusting it."
    else
        echo "  measured at load ${_row_load} on ${_row_cores} cores"
    fi
    echo ""
    echo "============================================="
    echo "  done"
    exit 0
else
    echo "  failed: unsupported model — model could not be loaded at any ctx"
    exit 1
fi

# end of file

# end of file marker
