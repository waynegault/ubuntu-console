#!/usr/bin/env bash
# AI INSTRUCTION: On ANY change to this file, increment the Module Version below.
# Module Version: 139
#   v139 (2026-11-12): scale AT_WINDOW_S for large multi-shard models (>40 GiB) when not
#     explicitly set; emit window_timeout instead of load_fail on readiness expiry so descent
#     reports "readiness timeout" rather than "unsupported model".
#   v138 (2026-11-12): fix multi-part format in adapter_degraded failure label to emit one line.
#   v137 (2026-11-12): classify non-generative / decision models as unsupported_arch and abort
#     preflight immediately; carry window_timeout class on readiness expiry; assign typed
#     adapter_degraded classification to preflight GPU guards instead of unclassified.
#   v136 (2026-11-12): clarify autotune progress lines (human-friendly layer offload
#     and KV cache eligibility notices).
#   v135 (2026-11-12): consolidate and shorten verbose header and inline comments.
#   v134 (2026-11-12): _cuda_guard_or_exit passes explicit detail strings to _preflight_refuse.
#   v133 (2026-11-12): default ALLOW_CONTENDED=${TAC_CONTENDED:-1}; --refuse-contended opts out.
#
# autotune-model.sh — Sweep ctx, batch/ubatch, ngl, kv-quant, and spec-decode for a GGUF.
# Usage: autotune-model.sh <model.gguf> [--workload chat|legal|agentic|mix] [--allow-contended|--refuse-contended]

set -uo pipefail

# ── Box-wide heavy-job serialisation (bin/heavy-job) ─────────────────────────
_AUTOTUNE_ORIG_ARGS=("$@")

# The model may be given as a registry row NUMBER or as a model FILE name.  Both are
MODEL_REF="${1:?Usage: autotune-model.sh MODEL_NUM|MODEL_FILE [--workload chat|legal|agentic|mix] [--allow-contended]}"

# AUTOTUNE-001: workload-selectable scoring payload.  The ctx/batch/TPS
WORKLOAD="${LLM_AUTOTUNE_WORKLOAD:-chat}"
# 3c: contended runs persist stamped meas_state=indicative (retuning advised on a
ALLOW_CONTENDED="${TAC_CONTENDED:-1}"
shift  # drop MODEL_NUM
while [[ $# -gt 0 ]]; do
    case "$1" in
        --workload) WORKLOAD="${2:-}"; shift 2 ;;
        --allow-contended) ALLOW_CONTENDED=1; shift ;;
        --refuse-contended) ALLOW_CONTENDED=0; shift ;;
        *) echo "Unknown arg: $1 (usage: autotune-model.sh MODEL_NUM [--workload chat|legal|agentic|mix] [--allow-contended|--refuse-contended])" >&2; exit 2 ;;
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
if [[ "${TAC_LOAD_DEGRADED:-0}" == "1" ]]; then
    echo "Error: the console loaded degraded (sub-modules failed to load) — refusing to autotune." >&2
    echo "       Run 'source env.sh' in a shell to see which; nothing was benchmarked."
    exit 1
fi
# These are (re)loaded through the shared helper, which REPORTS a missing or failing
__tac_source_submodules "$PWD/scripts" "autotune-model" 01-constants 11-llm-manager prompt-sets

# Source the tactical console for shared functions (__gguf_metadata, __kv_mb_per_1k,

# Resolve the model reference to a FILE NAME — the row's definitive identity — now that
MODEL=""
MODEL_FILE=""
# Startup-validation messages go to STDERR: they report a refusal to start, which is an
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

# ── Box-wide heavy-job serialisation (bin/heavy-job) ─────────────────────────
if [[ -z "${HEAVY_JOB_HELD:-}" ]]; then
    exec "$(cd "$_SELF_DIR/.." && pwd)/bin/heavy-job" \
        "${BASH:-bash}" "$_SELF_DIR/$(basename "${BASH_SOURCE[0]}")" \
        "${_AUTOTUNE_ORIG_ARGS[@]}"
fi

# The ctx this row currently has recorded, captured before anything can mutate it.  The
PREV_CERT_CTX="${_ctx:-0}"

SIZE_INT=${size%G}; SIZE_INT=${SIZE_INT%.*}; SIZE_INT=${SIZE_INT:-1}
[[ "$SIZE_INT" =~ ^[0-9]+$ ]] || SIZE_INT=1

CPU_COUNT=$(nproc 2>/dev/null || echo 6)
# SPEC-DEC-002: the thread count is hard-capped at the i9-12900HK P-core
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
_AUTOTUNE_BOOT_ID="$(tr -d '-' < /proc/sys/kernel/random/boot_id 2>/dev/null | cut -c1-12)"
_CUDA_CYCLE_FILE="${CUDA_CYCLE_FILE:-/dev/shm/autotune-cuda-cycles-${_AUTOTUNE_BOOT_ID:-unknown}}"
_CUDA_STALL_FILE="${CUDA_STALL_FILE:-/dev/shm/autotune-degrade-stalls-${_AUTOTUNE_BOOT_ID:-unknown}}"
_VRAM_BOOT_BASELINE_FILE="${TAC_VRAM_BASELINE_FILE:-/dev/shm/autotune-vram-baseline-${_AUTOTUNE_BOOT_ID:-unknown}}"
export CUDA_CYCLE_FILE
# Halting budget, same default and same counter file as run-autotune-batch.sh:
CUDA_CYCLE_BUDGET="${CUDA_CYCLE_BUDGET:-60}"
# Maximum allowed cumulative VRAM baseline drift (MiB) before halting due to VA fragmentation.
LLM_AUTOTUNE_MAX_DRIFT_MIB="${LLM_AUTOTUNE_MAX_DRIFT_MIB:-1536}"
# Consecutive launches that stall (health never ready, process still alive, no
CUDA_DEGRADE_CONSECUTIVE_STALLS="${CUDA_DEGRADE_CONSECUTIVE_STALLS:-2}"

# _fail — the one refusal path for a pre-measurement check.  It routes through the repo's
_AT_WINDOW_USER_SET="${AT_WINDOW_S:-}"
AT_WINDOW_S="${AT_WINDOW_S:-300}"

# _fail — refuse before any launch: print the reason, then exit 1 with the class recorded.
_fail() {
    if declare -f __tac_info >/dev/null; then
        __tac_info "Autotune" "[ERROR: $*]" "${C_Error:-}"
    else
        echo "ERROR: $*"
    fi
    # DEF-024: every _fail site is a pre-measurement refusal, so the result file must
    _PREFLIGHT_CLASS="${_FAIL_CLASS:-unclassified}"
    exit 1
}

# DEF-024 — the run's verdict, and the refusal that never launched a server.

# __autotune_failure_label <token> — the operator-facing name of a classification.
__autotune_failure_label() {
    case "${1:-}" in
        resource_exhausted) printf 'resource exhaustion (OOM / failed allocation)' ;;
        unsupported_arch)   printf 'unsupported architecture / non-generative model' ;;
        launch_error)       printf "launch or flag error, or a model the server could not load \
(the server rejected its invocation)" ;;
        loader_vintage)     printf "the FILE and the LOADER disagree about a required GGUF key \
or tensor (a key is absent or mistyped, or a tensor the loader names is absent; the weights are \
not at fault).  Which side is stale is not knowable from the message — check whether the \
installed build knows the name (strings <libllama.so> | grep <name>): if it does, the file is \
incomplete or misnamed (re-convert or obtain a matching GGUF); if it does not, rebuild llama.cpp" ;;
        insufficient_host_staging) printf "the largest shard cannot be staged in host memory \
(split GGUFs stage one shard; guest RAM is the wall, not VRAM)" ;;
        insufficient_host_ram) printf "the row's HOST footprint (weights not offloaded at this \
ngl, plus any staged shard) exceeds MemAvailable — guest RAM is the wall, not the GPU pool" ;;
        loader_crash_unknown) printf "the launch died with no OOM witness and no load signature \
(unexplained — stopped without a descent, so nothing was measured)" ;;
        window_timeout)     printf "the readiness window expired with no error signature \
(a slow load or a degraded adapter, NOT an OOM)" ;;
        adapter_degraded)   printf '%s%s\n' "WSL2 GPU adapter degraded (CUDA cycle budget, " \
            "stalls, or kernel dxgkrnl errors; restart WSL)" ;;
        missing_dependency) printf "missing required autotune components or shell functions" ;;
        certified)          printf 'certified' ;;
        *)                  printf 'unclassified (the launch output matched no known signature)' ;;
    esac
}

# warn — one stderr channel for this file's operator messages. §18.3 10.7 counts a
warn() { printf '%s\n' "$*" >&2; }

# _preflight_refuse <classification> <exit-rc> [detail] — end a run that never launched a
_preflight_refuse() {
    _PREFLIGHT_CLASS="${1:-unclassified}"
    _PREFLIGHT_RC="${2:-1}"
    _PREFLIGHT_DETAIL="${3:-}"
    exit "$_PREFLIGHT_RC"
}

# __autotune_write_result <rc> — the run's machine-readable verdict, written on EVERY
__autotune_write_result() {
    local _rc="${1:-0}" _out="${LLM_AUTOTUNE_RESULT_FILE:-}"
    local _stage="unknown" _cls="unclassified" _outcome="not_certified"
    local _line=""
    [[ -n "$_out" ]] || return 0
    if (( _rc == 0 )); then
        _outcome="certified"; _stage="certified"; _cls="certified"
    elif [[ -n "${_PREFLIGHT_CLASS:-}" ]]; then
        _stage="preflight"; _cls="$_PREFLIGHT_CLASS"
    elif [[ -r "/tmp/at-fail-$$" ]]; then
        _stage="launch"
        _cls=$(sed -n 's/^classification=//p' "/tmp/at-fail-$$" | head -1)
        [[ -n "$_cls" ]] || _cls="unclassified"
    fi
    {
        printf 'outcome=%s\n' "$_outcome"
        printf 'stage=%s\n' "$_stage"
        printf 'classification=%s\n' "$_cls"
        printf 'reason=%s\n' "$(__autotune_failure_label "$_cls")"
        if [[ -n "${_PREFLIGHT_DETAIL:-}" ]]; then
            printf 'detail=%s\n' "$_PREFLIGHT_DETAIL"
        fi
        printf 'exit_rc=%s\n' "$_rc"
        printf 'model=%s\n' "${MODEL_FILE:-}"
        printf 'row=%s\n' "${MODEL:-}"
        # The baseline provenance.  A census pass means the card was NOT empty: the
        if [[ -n "${_BASELINE_MODE:-}" ]]; then
            printf 'baseline=%s\n' "$_BASELINE_MODE"
            printf 'baseline_as_of=%s\n' "${_BASELINE_AS_OF:-}"
            if [[ "$_BASELINE_MODE" == "census" ]]; then
                printf 'baseline_held_mib=%s\n' "${_BASELINE_HELD:-}"
                printf 'baseline_cap_mib=%s\n' "${_BASELINE_CAP:-}"
                printf 'baseline_tenants=%s\n' "${_BASELINE_TENANTS:-}"
                printf 'baseline_tenant_count=%s\n' "${_BASELINE_TENANT_COUNT:-}"
            fi
        fi
        if [[ "$_stage" == "certified" ]]; then
            printf 'config=ctx=%s batch=%s ubatch=%s tps=%s\n' \
                "${BEST_CTX:-0}" "${BEST_B:-}" "${BEST_U:-}" "${BEST_TPS:-}"
            printf 'state=%s\n' "${_meas_state:-}"
        elif [[ "$_stage" == "launch" ]]; then
            sed -n 's/^config=//p' "/tmp/at-fail-$$" | head -1 | sed 's/^/config=/'
            sed -n 's/^log=//p' "/tmp/at-fail-$$" | head -1 | sed 's/^/log=/'
            while IFS= read -r _line; do
                [[ -n "$_line" ]] || continue
                printf 'tail=%s\n' "$_line"
            done < <(sed -n 's/^tail=//p' "/tmp/at-fail-$$")
        fi
        if [[ -n "${_FINAL_REGISTRY_STATE:-}" ]]; then
            printf 'registry_state=%s\n' "$_FINAL_REGISTRY_STATE"
        fi
    } > "$_out"
    return 0
}

# __autotune_exit_trap — one EXIT path for the lane hold AND the result file.  It
__autotune_exit_trap() {
    local _rc=$?
    if [[ -n "${_TAC_SUSPEND_HELD:-}" ]] && declare -f _tac_suspend_release &>/dev/null; then
        # swallow-ok: release is owner-checked and idempotent; a failed release leaves a marker the reader treats as NOT HELD
        _tac_suspend_release "${_LANE_SUSPEND:-}" 2>/dev/null || true
    fi
    # Put back the lanes this run stood down (v127).  The watchdog is not a substitute: its
    if declare -f __llm_restore_stopped_lanes &>/dev/null; then
        __llm_restore_stopped_lanes
    fi
    # swallow-ok: the result file is a report; a run that cannot write it has already reported on stderr
    __autotune_write_result "$_rc" 2>/dev/null || true
    exit "$_rc"
}

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
_cuda_guard_or_exit() {
    local c s
    c=$(_cuda_cycles)
    if (( c >= CUDA_CYCLE_BUDGET )); then
        echo "ERROR: CUDA context-cycle budget reached (${c} >= ${CUDA_CYCLE_BUDGET}) — WSL2 dxgkrnl leaks GPU VA on every llama-server spawn and an exhausted adapter hangs the VM." >&2
        echo "       Restart WSL from Windows ('wsl --shutdown') to reset the ledger; nothing was certified this run." >&2
        # DEF-024: a refused pre-flight is not a failed configuration list.  The class is
        _preflight_refuse adapter_degraded 3 \
            "CUDA context-cycle budget reached (${c} >= ${CUDA_CYCLE_BUDGET}); restart WSL"
    fi
    if (( CUDA_DEGRADE_CONSECUTIVE_STALLS > 0 )); then
        s=$(_cuda_stalls)
        if (( s >= CUDA_DEGRADE_CONSECUTIVE_STALLS )); then
            echo "ERROR: ${s} consecutive launches stalled (health never ready while the process stayed alive) — the dxgkrnl degradation signature, at ${c}/${CUDA_CYCLE_BUDGET} cycles." >&2
            echo "       Restart WSL from Windows ('wsl --shutdown'); nothing was certified this run." >&2
            _preflight_refuse adapter_degraded 3 \
                "${s} consecutive launches stalled (dxgkrnl degradation); restart WSL"
        fi
    fi
    if declare -f _tac_dxg_health_check >/dev/null 2>&1; then
        local _dxg_err
        if ! _dxg_err=$(_tac_dxg_health_check); then
            warn "ERROR: WSL2 dxgkrnl reported critical kernel GPU errors (-12/-75/wait timeout):"
            while IFS= read -r _l; do warn "  $_l"; done <<< "$_dxg_err"
            warn "       Restart WSL from Windows ('wsl --shutdown') to clear adapter state."
            _preflight_refuse adapter_degraded 3 \
                "WSL2 dxgkrnl kernel GPU errors in dmesg (-12/-75/wait timeout); restart WSL"
        fi
    fi
    if [[ -f "$_VRAM_BOOT_BASELINE_FILE" ]]; then
        local _init_free _curr_free _vram_drift
        # swallow-ok: baseline file read failure skips drift check
        _init_free=$(cat "$_VRAM_BOOT_BASELINE_FILE" 2>/dev/null || echo "")
        if [[ "$_init_free" =~ ^[0-9]+$ ]] && declare -f _tac_gpu_free_mib >/dev/null 2>&1; then
            # swallow-ok: gpu read failure is handled downstream by preflight vram check
            _curr_free=$(_tac_gpu_free_mib 2>/dev/null || echo "")
            if [[ "$_curr_free" =~ ^[0-9]+$ ]] && (( _init_free > _curr_free )); then
                _vram_drift=$(( _init_free - _curr_free ))
                if (( _vram_drift >= LLM_AUTOTUNE_MAX_DRIFT_MIB )); then
                    warn "ERROR: Cumulative post-boot VRAM drift (${_vram_drift} MiB" \
                         ">= ${LLM_AUTOTUNE_MAX_DRIFT_MIB} MiB)."
                    warn "       WSL2 dxgkrnl GPU VA fragmentation limit reached. Restart WSL ('wsl --shutdown')."
                    _preflight_refuse adapter_degraded 3 \
                        "cumulative post-boot VRAM drift ${_vram_drift} MiB >= ${LLM_AUTOTUNE_MAX_DRIFT_MIB} MiB; restart WSL"
                fi
            fi
        fi
    fi
    return 0
}

# VRAM-baseline guarantee: the KV-math START_CTX below is only trustworthy
if declare -f __llm_kill_cuda_llama_servers &>/dev/null; then
    __llm_kill_cuda_llama_servers || true
else
    echo "WARN: __llm_kill_cuda_llama_servers not loaded — skipping llama cleanup (a name-based pkill would evict the Xe fleet)" >&2
fi

# The sweep above SPARES every declared lane — right for a sweep, fatal for a baseline on
if declare -f __llm_stand_down_cuda_lanes &>/dev/null; then
    __llm_stand_down_cuda_lanes || true
fi

# Keep the lane down for the WHOLE run.  The stop above only wins until the watchdog's
if [[ "${AUTOTUNE_SELFTEST:-0}" == "1" && -z "${LLAMA_WATCHDOG_CUDA_SUSPEND_FILE:-}" ]]; then
    # Stubs cannot reach this: the hold is a file, not a command.  Under selftest the hold goes to
    LLAMA_WATCHDOG_CUDA_SUSPEND_FILE="${TMPDIR:-/tmp}/autotune-selftest-$$.suspend"
    echo "selftest: suspend hold redirected to $LLAMA_WATCHDOG_CUDA_SUSPEND_FILE (never the real one)"
fi
_LANE_SUSPEND="${LLAMA_WATCHDOG_CUDA_SUSPEND_FILE:-/dev/shm/llama-watchdog-cuda.suspend}"
# The suspend helpers live in bin/_tac-bin-lib.sh — the ONE reviewed implementation of
# shellcheck source=../bin/_tac-bin-lib.sh
# swallow-ok: the library is optional for a standalone copy; absence is reported by the declare -f guard below
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../bin/_tac-bin-lib.sh" 2>/dev/null || true
if [[ -z "${_TAC_SUSPEND_HELD:-}" ]] && declare -f _tac_suspend_acquire &>/dev/null; then
    if _tac_suspend_acquire "$_LANE_SUSPEND"; then
        _TAC_SUSPEND_HELD=1
    elif declare -f _tac_suspend_owner_is_ancestor &>/dev/null &&
         _tac_suspend_owner_is_ancestor "$_LANE_SUSPEND"; then
        # The holder is an ANCESTOR - bin/autotune-rows.sh, which took the hold for the whole
        echo "suspend: already held by ancestor pid $(_tac_suspend_pid "$_LANE_SUSPEND") - this row runs under that hold"
    else
        warn "WARN: $_LANE_SUSPEND is held by another run " \
             "(pid $(_tac_suspend_pid "$_LANE_SUSPEND")) — the watchdog may restart the CUDA lane mid-run"
    fi
fi
# ONE exit handler, installed on every path: it releases the lane hold when this run
trap '__autotune_exit_trap' EXIT
# The OpenClaw gateway's local embedding workers each hold ~430 MiB VRAM
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
timeout -k 2 "${TAC_SMI_TIMEOUT:-10}" \
    nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits >/dev/null 2>&1 || true
pkill -9 -u "$(id -un)" -x nvidia-smi 2>/dev/null || true
sleep 1
# BOUNDED RETRY (2026-10-24): the run above forces kills and a cache drop, and a
for _vram_attempt in 1 2 3; do
    VRAM_TOTAL=$(timeout -k 2 "${TAC_SMI_TIMEOUT:-10}" \
        nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ')
    FREE_VRAM=$(timeout -k 2 "${TAC_SMI_TIMEOUT:-10}" \
        nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ')
    [[ "$VRAM_TOTAL" =~ ^[0-9]+$ && "$FREE_VRAM" =~ ^[0-9]+$ ]] && break
    if (( _vram_attempt < 3 )); then sleep 1; fi
done
unset _vram_attempt
# FAIL CLOSED (v85): these used to default to 4096/3965, so an unreadable card produced a
if ! [[ "$VRAM_TOTAL" =~ ^[0-9]+$ ]] || ! [[ "$FREE_VRAM" =~ ^[0-9]+$ ]]; then
    _fail "cannot read VRAM (total='${VRAM_TOTAL}' free='${FREE_VRAM}') - refusing to autotune."
fi
if [[ ! -f "$_VRAM_BOOT_BASELINE_FILE" && "$FREE_VRAM" =~ ^[0-9]+$ ]]; then
    # swallow-ok: recording initial post-boot VRAM baseline is best-effort
    printf '%s\n' "$FREE_VRAM" > "$_VRAM_BOOT_BASELINE_FILE" 2>/dev/null || true
fi
# Trust check: after clearing, free VRAM must sit ~at the card total.  A
BASELINE_GAP_MAX=${LLM_AUTOTUNE_BASELINE_GAP_MAX:-800}
BASELINE_GAP=$(( VRAM_TOTAL - FREE_VRAM ))
# CENSUS MODE (owner decision, 2026-11-05; card AUTOTUNE-BASELINE-002 v92).
_VRAM_VERDICT=""
_vram_rc=0
if [[ "${AUTOTUNE_SELFTEST:-0}" == "1" ]]; then
    # A selftest replaces the engine with canned curves and NEVER launches a server, so
    _VRAM_VERDICT=$'mode=selftest\nverdict=pass'
elif declare -f _tac_vram_baseline_verdict &>/dev/null; then
    _VRAM_VERDICT=$(_tac_vram_baseline_verdict "$FREE_VRAM" "$VRAM_TOTAL")
    _vram_rc=$?
else
    # bin/_tac-bin-lib.sh is mandatory for this script; a partial tree keeps the old
    if (( BASELINE_GAP > BASELINE_GAP_MAX )); then
        _VRAM_VERDICT=$'mode=exclusive\nverdict=refuse\nreason=gap-exceeds-bound'
        _vram_rc=1
    else
        _VRAM_VERDICT=$'mode=exclusive\nverdict=pass'
    fi
fi
_BASELINE_MODE=$(sed -n 's/^mode=//p' <<< "$_VRAM_VERDICT" | head -1)
_BASELINE_HELD=$(sed -n 's/^held_mib=//p' <<< "$_VRAM_VERDICT" | head -1)
_BASELINE_CAP=$(sed -n 's/^held_cap_mib=//p' <<< "$_VRAM_VERDICT" | head -1)
_BASELINE_TENANTS=$(sed -n 's/^tenants=//p' <<< "$_VRAM_VERDICT" | head -1)
_BASELINE_TENANT_COUNT=$(sed -n 's/^tenant_count=//p' <<< "$_VRAM_VERDICT" | head -1)
_BASELINE_AS_OF=$(date -u +%Y-%m-%dT%H:%M:%SZ)
if (( _vram_rc != 0 )); then
    _BASELINE_REASON=$(sed -n 's/^reason=//p' <<< "$_VRAM_VERDICT" | head -1)
    if [[ "$_BASELINE_REASON" == "census-unbounded" ]]; then
        _fail "LLM_AUTOTUNE_CENSUS names tenants but LLM_AUTOTUNE_CENSUS_MAX_MIB is not" \
              "a positive integer (${LLM_AUTOTUNE_CENSUS_MAX_MIB:-unset}) — a census with no bound is not a gate."
    fi
    echo "ERROR: VRAM baseline not cleared — ${FREE_VRAM} MiB free of ${VRAM_TOTAL} MiB" \
         "(${BASELINE_GAP} MiB still held; ${_BASELINE_REASON})." \
         "Refusing to autotune against an untrustworthy baseline." >&2
    # Name the holder.  Without this the operator has to go and run nvidia-smi to learn
    if declare -f __llm_vram_holder_report &>/dev/null; then
        warn "Held by:"
        __llm_vram_holder_report >&2 || true
    elif declare -f _tac_vram_holder_identities &>/dev/null; then
        warn "Held by:"
        # swallow-ok: the holder list is a diagnostic; a failed scan must not replace the refusal with a shell error
        _tac_vram_holder_identities >&2 || true
    fi
    if [[ "$_BASELINE_REASON" == "unlisted-holder" ]]; then
        # "Outside the declared census <tenants>:" read as if the DECLARED tenant were the
        warn "Unlisted holders (declared tenants: ${_BASELINE_TENANTS:-<unset>}):"
        sed -n 's/^unlisted=//p' <<< "$_VRAM_VERDICT" | head -1 | tr ' ' '\n' | sed 's/^/  /' >&2
    fi
    warn "Remedy: stop the holding lane (model stop, or systemctl --user stop <unit>) and re-run; " \
         "a foreign run's GPU lock is never evicted by this check."
    # DEF-024: the card is held by someone else.  That is resource exhaustion from THIS
    _preflight_refuse resource_exhausted 1 \
        "VRAM baseline not cleared — ${BASELINE_GAP} MiB still held by another process (${_BASELINE_REASON})"
fi
if [[ "$_BASELINE_MODE" == "census" ]]; then
    # A CENSUS does not mean CONTENDED.  Measured 2026-11-06 14:22: the clean-room had just
    if [[ "${_BASELINE_TENANT_COUNT:-0}" == "0" ]]; then
        warn "baseline: CENSUS — no declared tenant resident (${_BASELINE_TENANTS}); readings are single-tenant"
    else
        warn "baseline: CENSUS — declared tenants resident: ${_BASELINE_TENANTS}"
        warn "baseline: TPS from this run are CONTENDED, not clean-room."
    fi
    warn "baseline: ${_BASELINE_HELD} MiB held of ${_BASELINE_CAP} allowed (${_BASELINE_AS_OF})"
fi

# Refuse before the first spawn if the dxgkrnl ledger is already exhausted.
_cuda_guard_or_exit
# The row names one file; llama.cpp loads the whole shard SET. Summing the set is what
if declare -f __autotune_model_bytes &>/dev/null; then
    MODEL_BYTES=$(__autotune_model_bytes "$MODEL_PATH")
else
    # 11b is mandatory for this script, so reaching here means a partial tree: keep the
    warn "  __autotune_model_bytes is not loaded — sizing on the named file alone (split GGUFs under-count)"
    MODEL_BYTES=$(stat --format=%s "$MODEL_PATH" 2>/dev/null || echo 0)
fi
[[ "$MODEL_BYTES" =~ ^[0-9]+$ ]] || MODEL_BYTES=0
MODEL_MB=$(( MODEL_BYTES / 1048576 ))

# Scale readiness window for large multi-shard models (>40 GiB) when AT_WINDOW_S wasn't pinned.
if [[ -z "${_AT_WINDOW_USER_SET:-}" ]] && (( MODEL_MB >= 40960 )); then
    _scaled_window=$(( 300 + ((MODEL_MB - 40960) / 1024) * 8 ))
    (( _scaled_window > 900 )) && _scaled_window=900
    (( _scaled_window > AT_WINDOW_S )) && AT_WINDOW_S="$_scaled_window"
fi

# Combos — selected by GGUF file size to avoid guaranteed-OOM combos on large models
if [[ $MODEL_MB -lt 1000 ]]; then
    COMBOS=("1024:256" "2048:512" "4096:1024")
elif [[ $MODEL_MB -lt 2000 ]]; then
    COMBOS=("1024:256" "2048:512")
else
    COMBOS=("1024:256")
fi

BUDGET=$(( FREE_VRAM - MODEL_MB - 200 ))

# NAME BOTH POOLS (2026-11-03).  This script sizes against FREE_VRAM, which is the GPU
if [[ "${TAC_HOST_RAM_AVAIL_BYTES:-}" =~ ^[0-9]+$ ]] && (( TAC_HOST_RAM_AVAIL_BYTES > 0 ))
then
    _HOST_AVAIL_MB=$(( TAC_HOST_RAM_AVAIL_BYTES / 1048576 ))
else
    # swallow-ok: an unreadable /proc/meminfo is reported by the UNREADABLE branch below
    _HOST_AVAIL_MB=$(awk '/^MemAvailable:/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null)
fi
if [[ "$_HOST_AVAIL_MB" =~ ^[0-9]+$ ]]
then
    echo "  pools: gpu ${VRAM_TOTAL} MiB (free ${FREE_VRAM}) | host avail ${_HOST_AVAIL_MB} MiB | model ${MODEL_MB} MiB"
else
    warn "  pools: gpu ${VRAM_TOTAL} MiB (free ${FREE_VRAM}) | host avail UNREADABLE | model ${MODEL_MB} MiB"
fi

# SPLIT-GGUF STAGING PREFLIGHT (2026-11-04).  A split model is loaded by staging one
if declare -f __autotune_staged_shard_bytes &>/dev/null \
   && declare -f __autotune_staging_fits &>/dev/null; then
    _staged_bytes=$(__autotune_staged_shard_bytes "$MODEL_PATH")
    [[ "$_staged_bytes" =~ ^[0-9]+$ ]] || _staged_bytes=0
    _staged_mb=$(( _staged_bytes / 1048576 ))
    _staging_margin_mb="${LLM_AUTOTUNE_STAGING_MARGIN_MB:-4096}"
    [[ "$_staging_margin_mb" =~ ^[0-9]+$ ]] || _staging_margin_mb=4096
    if (( _staged_mb > 0 )); then
        echo "  staging: largest shard ${_staged_mb} MiB + ${_staging_margin_mb} MiB margin, host avail ${_HOST_AVAIL_MB:-0} MiB"
        if [[ "$_HOST_AVAIL_MB" =~ ^[0-9]+$ ]] \
           && ! __autotune_staging_fits "$_staged_bytes" \
                "$(( _HOST_AVAIL_MB * 1048576 ))" "$(( _staging_margin_mb * 1048576 ))"; then
            _preflight_refuse insufficient_host_staging 1 \
                "largest shard ${_staged_mb} MiB cannot be staged: MemAvailable ${_HOST_AVAIL_MB} MiB less the ${_staging_margin_mb} MiB margin"
        fi
    fi
fi

if declare -f __kv_mb_per_1k &>/dev/null && declare -f __gguf_metadata &>/dev/null; then
    # Shared function path — architecture-aware estimate
    _meta=$(__gguf_metadata "$MODEL_PATH" 2>/dev/null || true)
    if [[ -n "$_meta" ]]; then
        _n_layers=$(cut -d'|' -f3 <<< "$_meta")
        _native_ctx=$(cut -d'|' -f4 <<< "$_meta")
        # KV geometry (11d v35 fields 6 and 7) — see __kv_mb_per_1k.  Passing it means
        _kv_heads=$(cut -d'|' -f6 <<< "$_meta")
        _kv_dim=$(cut -d'|' -f7 <<< "$_meta")
        _kv_mb=$(__kv_mb_per_1k "${_n_layers:-0}" "${_kv_heads:-0}" "${_kv_dim:-0}")
        echo "  kv geometry: layers=${_n_layers:-0} kv_heads=${_kv_heads:-0} head_dim=${_kv_dim:-0} -> ${_kv_mb} MiB/1k"
        # BOTH DIRECTIONS OF THE FALLBACK, SAID.  A header without the two keys still gets the
        if declare -f __kv_geometry_known &>/dev/null \
           && ! __kv_geometry_known "${_kv_heads:-0}" "${_kv_dim:-0}"; then
            warn "  kv geometry: absent from the GGUF header — falling back to the shape-agnostic" \
                 "${_kv_mb} MiB/1k constant (KV heads and head dim are unknown for this file)"
        fi
        # THE SECOND BUDGET (card bf92711c).  Everything above prices the probe against the GPU
        if declare -f __autotune_host_weight_bytes &>/dev/null \
           && declare -f __autotune_host_budget_verdict &>/dev/null; then
            _host_weights_bytes=$(__autotune_host_weight_bytes "$MODEL_BYTES" "${_n_layers:-0}" "${BENCH_NGL:-999}")
            [[ "$_host_weights_bytes" =~ ^[0-9]+$ ]] || _host_weights_bytes=0
            _host_need_bytes=$(( _host_weights_bytes + ${_staged_bytes:-0} ))
            _host_need_mb=$(( _host_need_bytes / 1048576 ))
            _host_weights_mb=$(( _host_weights_bytes / 1048576 ))
            _host_factor="${LLM_AUTOTUNE_HOST_FACTOR_PCT:-100}"
            _host_tight="${LLM_AUTOTUNE_HOST_TIGHT_PCT:-75}"
            _host_verdict=$(__autotune_host_budget_verdict "$_host_need_bytes" \
                "$(( ${_HOST_AVAIL_MB:-0} * 1048576 ))" "$_host_factor" "$_host_tight")
            _staging_mb=$(( ${_staged_bytes:-0} / 1048576 ))
            _host_detail="host footprint ${_host_need_mb} MiB (weights ${_host_weights_mb} MiB"
            _host_detail+=" not offloaded at ngl=${BENCH_NGL:-999} + staging ${_staging_mb} MiB)"
            _host_detail+=" exceeds MemAvailable ${_HOST_AVAIL_MB} MiB at the stated factor ${_host_factor}%"
            case "$_host_verdict" in
                refuse)
                    _preflight_refuse insufficient_host_ram 1 "$_host_detail"
                    ;;
                clamp)
                    # Above the tight band but inside the bound: go ahead, ask for the least the
                    _HOST_CTX_CLAMP=1
                    warn "  host budget: footprint ${_host_need_mb} MiB (weights" \
                         "${_host_weights_mb} MiB at ngl=${BENCH_NGL:-999} + staging ${_staging_mb} MiB)" \
                         "is above ${_host_tight}% of MemAvailable ${_HOST_AVAIL_MB} MiB — probing at" \
                         "MIN_CTX; the HOST, not the card, is the binding pool"
                    ;;
                unknown)
                    warn "  host budget: MemAvailable UNREADABLE — no host-side verdict this run" \
                         "(the GPU pool was still measured)"
                    ;;
                *)
                    echo "  host budget: footprint ${_host_need_mb} MiB vs MemAvailable" \
                         "${_HOST_AVAIL_MB} MiB (factor ${_host_factor}%) — fits"
                    ;;
            esac
        fi
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
if ! declare -f __autotune_ctx_bounds &>/dev/null || ! declare -f __autotune_descent_candidates &>/dev/null; then
    echo "ERROR: __autotune_ctx_bounds / __autotune_descent_candidates are not loaded (scripts/11b-llm-autotune.sh missing?) — refusing to autotune without tested ctx bounds." >&2
    _preflight_refuse missing_dependency 1
fi
read -r START_CTX MAX_CTX MIN_CTX < <(__autotune_ctx_bounds \
    "$START_CTX" "${_native_ctx:-}" "${LLM_AUTOTUNE_VRAM_CAP_MULT:-2}" "$MIN_CTX")

# The host verdict's clamp lands here, after the bounds: both the start AND the ceiling drop to
if [[ "${_HOST_CTX_CLAMP:-0}" == "1" ]]; then
    START_CTX=$MIN_CTX
    MAX_CTX=$MIN_CTX
fi

# Comma-format numbers (standalone helpers — no outer-scope capture)
fmt() { printf "%'d" "$1"; }
# fmts — comma-format each "batch:ubatch" combo passed as args.
fmts() { local _c _out=""; for _c in "$@"; do _out+="$(printf "%'d:%'d " "${_c%%:*}" "${_c##*:}")"; done; printf '%s' "${_out% }"; }

# ── 3c: the certification's write gate ──────────────────────────────────────
__autotune_measurement_verdict() {
    local load="${1:-}" cores="${2:-}" allow="${3:-0}" force="${4:-0}"
    local psi="${5:-}" ci="${6:-}"
    # The reason travels with the verdict: a CI or pressure refusal happens on a box whose
    __AUTOTUNE_VERDICT=""
    __AUTOTUNE_VERDICT_REASON=""
    # A FORCED run cannot certify at all.  `--allow-contended` on its own only widens the
    if [[ "$force" == "1" && "$allow" == "1" ]]; then
        __AUTOTUNE_VERDICT=indicative
        echo "$__AUTOTUNE_VERDICT"
        return 0
    fi
    # THE LOAD TERM IS NECESSARY, NOT SUFFICIENT (2026-11-08).  load<=cores certified two
    local contended=""
    # TERM 1 — CI, and only CI.  v85 of 11e-llm-model.sh already treats a runner worker as
    if [[ "$ci" =~ ^[0-9]+$ ]] && (( ci > 0 )); then
        contended="${ci} CI runner worker(s) active"
    fi
    # TERM 2 — CPU pressure at the START of the run.  Deliberately NOT the window average:
    if [[ "$psi" =~ ^[0-9]+([.][0-9]+)?$ ]] \
       && awk -v p="$psi" -v m="${LLM_AUTOTUNE_PSI_MAX_PCT:-10}" 'BEGIN{exit !(p > m)}'; then
        contended="cpu pressure ${psi}% (some avg10, threshold ${LLM_AUTOTUNE_PSI_MAX_PCT:-10}%)"
    fi
    if [[ -n "$contended" ]]; then
        __AUTOTUNE_VERDICT_REASON="$contended"
        if [[ "$allow" == "1" ]]; then __AUTOTUNE_VERDICT=indicative; else __AUTOTUNE_VERDICT=refuse; fi
        echo "$__AUTOTUNE_VERDICT"
        return 0
    fi
    if [[ "$load" =~ ^[0-9]+([.][0-9]+)?$ && "$cores" =~ ^[0-9]+$ ]]; then
        if awk -v l="$load" -v c="$cores" 'BEGIN{exit !(l > c)}'; then
            __AUTOTUNE_VERDICT_REASON="load ${load} on ${cores} cores"
            if [[ "$allow" == "1" ]]; then __AUTOTUNE_VERDICT=indicative; else __AUTOTUNE_VERDICT=refuse; fi
        else
            __AUTOTUNE_VERDICT=certified
        fi
        echo "$__AUTOTUNE_VERDICT"
        return 0
    fi
    __AUTOTUNE_VERDICT_REASON="load unreadable (\"${load}\")"
    if [[ "$allow" == "1" ]]; then __AUTOTUNE_VERDICT=indicative; else __AUTOTUNE_VERDICT=refuse; fi
    echo "$__AUTOTUNE_VERDICT"
    return 0
}

# __autotune_cpu_pressure_pct - `some avg10` from /proc/pressure/cpu, or EMPTY.
__autotune_cpu_pressure_pct() {
    local line=""
    # swallow-ok: a kernel without CONFIG_PSI yields nothing, and the caller reads empty as no evidence
    line=$(</proc/pressure/cpu 2>/dev/null) || return 0
    # A line without some/avg10 yields EMPTY — "no instrument", the same reading as an
    [[ "$line" =~ some[[:space:]]+avg10=([0-9]+([.][0-9]+)?) ]] || return 0
    printf '%s' "${BASH_REMATCH[1]}"
}

# __autotune_collapse_verdict <recorded> <measured> — the tps-collapse guard's predicate,
__autotune_collapse_verdict() {
    local recorded="${1:-}" measured="${2:-}"
    [[ "$recorded" =~ ^[0-9]+([.][0-9]+)?$ && "$measured" =~ ^[0-9]+([.][0-9]+)?$ ]] || return 1
    awk -v r="$recorded" -v m="$measured" 'BEGIN{exit !(r > 0 && r < 1000 && r >= 2*m)}'
}

# ── 1a: the position term ────────────────────────────────────────────────────
AUTOTUNE_DRIFT_WARN_PCT=25

# __autotune_position_drift <p1> <p2> — the probe's OWN formula (cache-ram-probe.sh:512,
__autotune_position_drift() {
    local p1="${1:-}" p2="${2:-}"
    if [[ "$p1" =~ ^[0-9]+([.][0-9]+)?$ && "$p2" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        awk -v a="$p1" -v b="$p2" 'BEGIN{
            if (a > 0 && b > 0) { m = (a > b) ? a : b; printf "%.2f", (m - ((a < b) ? a : b)) / m * 100 }
        }'
    fi
    return 0
}

echo "============================================="
echo ""
echo "  threads=$(fmt "$TUNE_THREADS")  cpu=$(fmt "$CPU_COUNT")"
echo "  combos: $(fmts "${COMBOS[@]}")"
echo "  probe:  start=$(fmt "$START_CTX") min_tps=${MIN_TPS}  workload=${WORKLOAD}"
START_TS=$(date '+%H:%M:%S')
echo "  start:  ${START_TS}"
echo ""
START_EPOCH=$(date +%s)
# FOREIGN CPU pressure, read NOW — before any server this run launches exists.  The
START_PSI_PCT=$(__autotune_cpu_pressure_pct)
if [[ "$START_PSI_PCT" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    echo "  psi:    cpu some avg10=${START_PSI_PCT}% before launch (foreign load only)"
fi

LLAMA_BIN="${LLAMA_CUDA_SERVER_BIN:-$HOME/llama.cpp/build-cuda/bin/llama-server}"

# BUILD IDENTITY (card 8d144104, Wayne 2026-11-04: "Bench rows should carry build identity").
LLAMA_BUILD_ID=""
if declare -F __llm_llama_build_id >/dev/null 2>&1; then
    LLAMA_BUILD_ID="$(__llm_llama_build_id "$LLAMA_BIN")"
fi

# ── Workload scoring payload (AUTOTUNE-001) ─────────────────────────────────
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

# Helpers

# Shared cleanup — kills llama-server, stale processes, and forces WSL2
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
        pkill -9 -u "$(id -un)" -x nvidia-smi 2>/dev/null || true
        sleep 1
        sync 2>/dev/null || true
        if [[ -w /proc/sys/vm/drop_caches ]]; then
            echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
        fi
        timeout -k 2 "${TAC_SMI_TIMEOUT:-10}" \
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

# _bench_stop <pid> — graceful llama-server shutdown (WSL2 dxgkrnl leak fix).
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

# _bench_stop_unknown — the stop action for a death with NEITHER an OOM witness NOR a load
_bench_stop_unknown() {
    warn "  no OOM evidence and no load-failure signature — stopping this row (no descent, no FA retry)"
    _bench_stop "${_BENCH_PID:-}"
    _bench_record_failure "$c" "$b" "$u" "$effective_ngl" "$kv_k/$kv_v" "loader_crash_unknown"
    echo "0|0|loader_crash_unknown" > "/tmp/at-metrics-$$"
    _BENCH_FAIL_TYPE="loader_crash_unknown"
}

# _bench_spawn — launch llama-server once (flash-attn retry), pre-flight, and
_sampler_args() {
    local _f="${1##*/}" _rp="" _rln=""
    # The model is an ARGUMENT, not a caller-scope global.  It used to read
    if [[ -z "${1:-}" ]]; then
        __tac_info "Sampler" "[needs the model path - refusing to guess]" "${C_Warning:-}"
        return 1
    fi
    _rp=$(__llm_registry_field "$_f" repeat_penalty)
    _rln=$(__llm_registry_field "$_f" repeat_last_n)
    if [[ -n "$_rp" ]]
    then
        printf '%s\n' "--repeat-penalty" "$_rp"
    fi
    if [[ -n "$_rln" ]]
    then
        printf '%s\n' "--repeat-last-n" "$_rln"
    fi
    return 0
}

# DEF-024 — the witness a failed run used to throw away.

# _bench_log_tail <log> [lines] — the last N non-blank lines of a server log.
_bench_log_tail() {
    local _log="${1:-}" _n="${2:-20}" _tail=""
    [[ -n "$_log" && -r "$_log" ]] || return 1
    # swallow-ok: an unreadable/blank log yields an empty tail, which the caller reports as "no witness captured"
    _tail=$(grep -v '^[[:space:]]*$' "$_log" 2>/dev/null | tail -n "$_n") || _tail=""
    [[ -n "$_tail" ]] || return 1
    printf '%s\n' "$_tail"
}

# __autotune_classify_failure <log> — classify a failed launch FROM ITS OWN OUTPUT.
__autotune_classify_failure() {
    local _log="${1:-}" _text=""
    [[ -n "$_log" && -r "$_log" ]] || { printf 'unclassified'; return 0; }
    _text=$(<"$_log")
    local _re_resource='out of memory|out-of-memory|cuda error: out of memory|cudamalloc|cudaerror(memoryallocation)?|'
    _re_resource+='failed to allocate|unable to allocate|not enough (vram|memory|gpu memory)|insufficient (vram|'
    _re_resource+='memory|gpu memory)|alloc_buffer: allocating|ggml_backend_(cuda|vulkan|metal)_buffer_type_alloc_buffer'
    local _re_unsupported='unknown model architecture|unsupported model|unsupported architecture|architectures? (is|'
    _re_unsupported+='are) not supported|is not supported by this|not supported by this (build|backend)|no (matching|'
    _re_unsupported+='suitable|supported) backend|failed to find (a |the )?(matching |suitable )?backend|'
    _re_unsupported+='requires ctx_other to be set|support for .* was not (built|compiled)|'
    _re_unsupported+='model architecture .* (not supported|unknown)|'
    _re_unsupported+='without text generation|decision model|classifier model|use /v1/systemone'
    # A model the server could NOT LOAD was a shape this classifier was blind to.  _startup_fail_type
    local _re_vintage='key not found in model:|has wrong type .* but expected type|'
    _re_vintage+='error loading model hyperparameters|gguf version .* (not supported|unsupported)|'
    _re_vintage+='unsupported gguf version|unknown gguf (key|value type)|'
    # A TENSOR the loader names and the file lacks is the same disagreement one level deeper, and
    _re_vintage+='tensor .* not found|check_tensor_dims|wrong shape'
    local _re_load='failed to load model|error loading model|failed to open|cannot open model file|'
    _re_load+='no such file'
    local _re_launch='invalid argument|unknown argument|unrecognized (option|argument)|unexpected argument|'
    _re_launch+='error while handling argument|invalid value for|failed to parse|usage: |address already in use|cannot open model'
    if grep -qiE "$_re_vintage" <<< "$_text"; then
        printf 'loader_vintage'
    elif grep -qiE "$_re_resource" <<< "$_text"; then
        printf 'resource_exhausted'
    elif grep -qiE "$_re_unsupported" <<< "$_text"; then
        printf 'unsupported_arch'
    elif grep -qiE "$_re_load" <<< "$_text"; then
        printf 'launch_error'
    elif grep -qiE "$_re_launch" <<< "$_text"; then
        printf 'launch_error'
    else
        printf 'unclassified'
    fi
    return 0
}

# _bench_class_from_startup <startup-type> — carry a DETECTED cause to the writer, or nothing.
_bench_class_from_startup() {
    case "${1:-}" in
        oom) printf 'resource_exhausted' ;;
        # Carried through under its own name: this is not an OOM, and filing it as one is the defect
        loader_crash_unknown) printf 'loader_crash_unknown' ;;
        *)   printf '' ;;
    esac
}

# _bench_record_failure <ctx> <batch> <ubatch> <ngl> <cache> [class] — keep the LAST failed
_bench_record_failure() {
    local _c="${1:-0}" _b="${2:-}" _u="${3:-}" _ngl="${4:-}" _kv="${5:-}"
    local _carried="${6:-}"
    local _log="${_BENCH_LOG:-}" _cls="" _tail="" _line=""
    _cls=$(__autotune_classify_failure "$_log")
    # The LOG is the arbiter and keeps winning whenever it names something - it can see a
    if [[ -z "$_cls" || "$_cls" == "unclassified" ]] && [[ -n "$_carried" ]]; then
        _cls="$_carried"
    fi
    [[ -n "$_cls" ]] || _cls="unclassified"
    _tail=$(_bench_log_tail "$_log" 20) || _tail=""
    {
        printf 'classification=%s\n' "$_cls"
        printf 'config=ctx=%s batch=%s ubatch=%s ngl=%s cache=%s\n' "$_c" "$_b" "$_u" "$_ngl" "$_kv"
        printf 'log=%s\n' "$_log"
        while IFS= read -r _line; do
            [[ -n "$_line" ]] || continue
            printf 'tail=%s\n' "$_line"
        done <<< "$_tail"
    } > "/tmp/at-fail-$$"
}


# sampler flags sit next to the launch sites that use them.
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
    local flash_attn="on"
    local hw=0
    _launch_server() {
        local -a fa_args=()
        [[ $flash_attn == "on" ]] && fa_args=(--flash-attn on) || fa_args=(--flash-attn off)
        # The sampler fragment is built in BOTH launch helpers (the bench spawn and the
        local -a sampler_args=()
        mapfile -t sampler_args < <(_sampler_args "$MODEL_PATH")
        # SPEC-DEC-004: the block-size sweep drives spec-decode via these
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
            "${spec_args[@]}" "${sampler_args[@]}" \
            > "$_BENCH_LOG" 2>&1 &
        _BENCH_PID=$!
        _bump_cuda_cycle
        hw=0
        while [[ $hw -lt "$AT_WINDOW_S" ]]; do
            sleep 1; hw=$((hw + 1))
            kill -0 "$_BENCH_PID" 2>/dev/null || return 1
            curl -sS --max-time 2 "$health_url/health" 2>/dev/null | grep -q '"status":"ok"' && return 0
        done
        return 1
    }
    # _startup_witness <pattern> — print the log line that produced a load_fail verdict.  The server
    _startup_witness() {
        local _w
        _w=$(grep -iE "$1" "$_BENCH_LOG" 2>/dev/null | tail -1)
        echo "  server log said: $_w" >&2
    }
    # _startup_load_fail <quiet|anything> — 0 when the server log names a load failure.  Holds the
    _startup_load_fail() {
        local _pat='unknown model architecture|failed to load model|error loading model|'
        _pat+='unsupported (model|architecture)|failed to open|no such file|'
        _pat+='requires ctx_other to be set'
        grep -qiE "$_pat" "$_BENCH_LOG" 2>/dev/null || return 1
        [[ "${1:-}" == "quiet" ]] || _startup_witness "$_pat"
        return 0
    }
    # _oom_witness_present — the 11b evidence test, guarded for a partial tree (no 11b, no claim).
    _oom_witness_present() {
        declare -f __autotune_oom_evidence &>/dev/null \
            && __autotune_oom_evidence "$_BENCH_LOG" "${_BENCH_PID:-}"
    }
    # _startup_fail_type <quiet> — load_fail | oom | loader_crash_unknown, from the log and the kernel.
    _startup_fail_type() {
        if _startup_load_fail "${1:-}"; then
            printf 'load_fail'
        elif _oom_witness_present; then
            printf 'oom'
        else
            printf 'loader_crash_unknown'
        fi
    }
    # Every path that used to `return` out of _bench_spawn lives here instead, so the 100-line
    _launch_or_record_failure() {
    _launch_server || {
        # Hand live AT_WINDOW_S expiry to the window_timeout path below, not loader_crash_unknown.
        (( hw >= AT_WINDOW_S )) && kill -0 "${_BENCH_PID:-}" 2>/dev/null \
            && ! _startup_load_fail quiet && return 0
        # The REASON must be READ, never assumed: labelling every launch failure
        local _fa_cause _fa_act
        _fa_cause=$(_startup_fail_type quiet)
        if declare -f __autotune_fa_retry >/dev/null 2>&1
        then
            _fa_act=$(__autotune_fa_retry "$_fa_cause" "$flash_attn" "$kv_v")
        else
            # Standalone run with no 11b on disk — this script already refuses to run
            _fa_act="retry"
        fi
        case "$_fa_act" in
            retry)
                local _fa_label="launch failed (no load-failure signature)"
                [[ "$_fa_cause" == "load_fail" ]] && _fa_label="model load failure"
                echo "  ${_fa_label} — retrying once with --flash-attn off" >&2
                _bench_stop "$_BENCH_PID"
                flash_attn="off"
                _launch_server || true
                ;;
            descend)
                warn "  OOM at this ctx — NOT retrying with --flash-attn off (that needs more memory); descending"
                _bench_stop "$_BENCH_PID"
                ;;
            fa_required)
                # llama.cpp refuses a quantised V cache with flash attention off, so the
                warn "  ${_fa_cause} with cache-type-v ${kv_v}: a quantised V needs flash-attn; not retrying"
                _bench_stop "$_BENCH_PID"
                _bench_record_failure "$c" "$b" "$u" "$effective_ngl" "$kv_k/$kv_v"
                echo "0|0|load_fail" > "/tmp/at-metrics-$$"; _BENCH_FAIL_TYPE="load_fail"
                return 1
                ;;
            stop) _bench_stop_unknown; return 1 ;;
            *)
                # Unreachable through __autotune_fa_retry, but a silent fall-through
                warn "  unrecognised fa-retry decision '${_fa_act}' — leaving flash attention as it is"
                _bench_stop "$_BENCH_PID"
                ;;
        esac
        }
    }
    # The helper returns 1 on exactly the paths that used to `return` straight out of
    _launch_or_record_failure || return 1
    if [[ $hw -ge "$AT_WINDOW_S" ]]; then
        # Tell a *stall* apart from a real load failure: the process is still
        local _sft; _sft=$(_startup_fail_type)
        # NO ERROR SIGNATURE IS NOT AN OOM (Wayne, 2026-11-04, option 1A). Reaching this line MEANS
        case "$_sft" in
            oom|loader_crash_unknown) _sft=window_timeout ;;
            *) ;;
        esac
        if kill -0 "$_BENCH_PID" 2>/dev/null && [[ "$_sft" != "load_fail" ]]; then
            _cuda_stall_bump
            # Say it out loud.  The metrics field below keeps writing load_fail
            local _stall_msg="  the readiness window (${AT_WINDOW_S}s) expired with no error signature"
            _stall_msg+=" in the server log and the process stayed alive — dxgkrnl degradation"
            _stall_msg+=" or a model that simply needs longer, NOT an OOM and NOT an unsupported model"
            echo "$_stall_msg" >&2
        else
            _cuda_stall_reset
        fi
        _bench_stop "$_BENCH_PID"
        _bench_record_failure "$c" "$b" "$u" "$effective_ngl" "$kv_k/$kv_v" "$_sft"
        echo "0|0|$_sft" > "/tmp/at-metrics-$$"; _BENCH_FAIL_TYPE="$_sft"; return 1
    fi

    # _bench_preflight_ready — verify slot serves /v1/chat/completions before benchmarking.
    _bench_preflight_ready() {
        local _pf_w=0
        while [[ $_pf_w -lt 60 ]]; do
            local _pf_resp=""
            # swallow-ok: probe failures are expected until the slot is ready; non-zero curl is handled below
            _pf_resp=$(curl -sS --max-time 5 "$health_url/v1/chat/completions" \
                -H "Content-Type: application/json" \
                -d '{"messages":[{"role":"user","content":"hi"}],"max_tokens":1,"temperature":0}' \
                2>/dev/null) || _pf_resp=""
            local _py_tok="import sys,json; d=json.load(sys.stdin); print(d.get('usage',{}).get('completion_tokens',0))"
            if printf '%s' "$_pf_resp" | "$TAC_PYTHON" -c "$_py_tok" 2>/dev/null | grep -q '[1-9]'; then
                return 0
            fi
            # Check if the server explicitly rejected the endpoint as non-generative / unsupported
            local _has_decision_err=0
            if grep -qiE 'without text generation|decision model|use /v1/systemone' <<< "$_pf_resp"; then
                _has_decision_err=1
            elif [[ -r "$_BENCH_LOG" ]] \
                && grep -qiE 'without text generation|decision model|use /v1/systemone' "$_BENCH_LOG"; then
                _has_decision_err=1
            fi
            if (( _has_decision_err == 1 )); then
                # Server rejected chat completions: non-generative/decision model cannot serve text
                return 1
            fi
            kill -0 "$_BENCH_PID" 2>/dev/null || {
                local _sft; _sft=$(_startup_fail_type)
                # _sft is derived HERE from the log, so it is always set (no -u risk) and it is
                _bench_record_failure "$c" "$b" "$u" "$effective_ngl" "$kv_k/$kv_v" \
                    "$(_bench_class_from_startup "$_sft")"
                echo "0|0|$_sft" > "/tmp/at-metrics-$$"
                _BENCH_FAIL_TYPE="$_sft"
                return 1
            }
            sleep 1; _pf_w=$((_pf_w + 1))
        done
        return 1
    }

    local _pf_rc=0
    _bench_preflight_ready || _pf_rc=$?
    if (( _pf_rc != 0 )); then
        _bench_stop "$_BENCH_PID"
        local _pf_fail_cls
        _pf_fail_cls=$(__autotune_classify_failure "$_BENCH_LOG")
        [[ "$_pf_fail_cls" == "unclassified" ]] && _pf_fail_cls="resource_exhausted"
        _bench_record_failure "$c" "$b" "$u" "$effective_ngl" "$kv_k/$kv_v" "$_pf_fail_cls"
        if [[ "$_pf_fail_cls" == "unsupported_arch" || "$_pf_fail_cls" == "launch_error" ]]; then
            echo "0|0|load_fail" > "/tmp/at-metrics-$$"; _BENCH_FAIL_TYPE="load_fail"; return 1
        else
            echo "0|0|oom" > "/tmp/at-metrics-$$"; _BENCH_FAIL_TYPE="oom"; return 1
        fi
    fi

    # GPU warmup: wake clocks from power-save (P5/P8 → P0).
    local warmup_tokens=8
    local _pstate; _pstate=$(timeout -k 2 "${TAC_SMI_TIMEOUT:-10}" \
        nvidia-smi --query-gpu=pstate --format=csv,noheader 2>/dev/null | head -1 | tr -d ' ')
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

# _bench_resolve_payload — echo "payload_file|bench_timeout" for a bench at
_bench_resolve_payload() {
    local c="$1" mode="$2"
    local payload_file="$PAYLOAD_FILE" bench_timeout="$BENCH_TIMEOUT"
    if [[ $mode == filled ]]; then
        if [[ "${_FAST_REJECT:-0}" == "1" ]]; then
            payload_file="/tmp/at-fast-${MODEL}-${c}.json"
            [[ -f $payload_file ]] || gen_fast_fill_payload "$payload_file"
            # Fast-reject (Phase-4 descent): a 2K fill + 32-token decode is
            [[ $bench_timeout -lt 180 ]] && bench_timeout=180
        else
            payload_file="/tmp/at-fill-${MODEL}-${c}.json"
            [[ -f $payload_file ]] || gen_fill_payload "$c" "$payload_file"
            # Filled prefill can be slow: with the KV cache spilling into host RAM
            [[ $bench_timeout -lt 1200 ]] && bench_timeout=1200
        fi
    fi
    echo "${payload_file}|${bench_timeout}"
}

# _bench_request_once — one completion request against the spawned server.
_bench_request_once() {
    local mode="$1" payload_file="$2" bench_timeout="$3"
    local health_url="${_BENCH_HEALTH_URL:-http://127.0.0.1:${AUTOTUNE_PORT:-18082}}"
    local start_ns; start_ns=$(date +%s%N)
    local resp; resp=$(curl -sS --max-time "$bench_timeout" "$health_url/v1/chat/completions" \
        -H "Content-Type: application/json" -d @"$payload_file" 2>/dev/null) || true
    local end_ns; end_ns=$(date +%s%N)

    local elapsed_ms=$(( (end_ns - start_ns) / 1000000 ))

    # Parse usage + server timings in one pass. llama-server includes a
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
    local _req_max
    _req_max=$(grep -oE '"max_tokens"[[:space:]]*:[[:space:]]*[0-9]+' "$payload_file" 2>/dev/null | head -1 | grep -oE '[0-9]+$')
    [[ "$_req_max" =~ ^[0-9]+$ ]] || _req_max=0
    local delivered_tokens="$tokens"
    if (( _req_max > 0 && delivered_tokens > _req_max )); then
        delivered_tokens="$_req_max"
    fi

    # SPEC-DEC-003: parse acceptance length + rate from this bench's server
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
    local _served_ctx=""
    _served_ctx=$(curl -s --max-time 5 "http://127.0.0.1:${AUTOTUNE_PORT:-18082}/props" 2>/dev/null \
        | jq -r '.default_generation_settings.n_ctx // empty' 2>/dev/null || true)
    [[ "$_served_ctx" =~ ^[0-9]+$ ]] || _served_ctx=""
    echo "${decode_tps:-0}|${prefill_tps:-0}||${_acc_len}|${_acc_rate}|${_spec_block}|${_served_ctx}" > "/tmp/at-metrics-$$"
    # ...and to its OWN file, on a successful read only.  Every failure path below
    [[ -n "$_served_ctx" ]] && echo "$_served_ctx" > "/tmp/at-served-ctx-$$"

    # TPS sentinel guard: llama.cpp clamps t_gen_us to a 1 us floor, so a
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

# __autotune_task_quality_check — run one deterministic task-contract probe per
__autotune_quality_error() {
    __tac_info "Autotune" "[ERROR: $1]" "${C_Error:-}"
}

# Validate the selected workload contract once at the final tuned configuration.
__autotune_task_quality_check() {
    local -a probe_workloads=()
    case "$WORKLOAD" in
        legal) probe_workloads=(legal) ;;
        agentic) probe_workloads=(agentic) ;;
        mix) probe_workloads=(legal agentic) ;;
        chat) return 0 ;;
        *) __autotune_quality_error "no task-quality contract for workload $WORKLOAD"; return 1 ;;
    esac

    local _quality_checker="$_SELF_DIR/../tools/llm_task_quality.py"
    if [[ ! -f "$_quality_checker" ]]; then
        __autotune_quality_error "task-quality checker is missing: $_quality_checker"
        return 1
    fi
    cleanup_gpu >&2 || { __autotune_quality_error "could not clear the GPU for task-quality checks"; return 1; }

    local _saved_spec_type="${BENCH_SPEC_TYPE:-off}"
    local _saved_spec_n_max="${BENCH_SPEC_N_MAX:-}"
    local _saved_draft_model="${BENCH_SPEC_DRAFT_MODEL:-}"
    BENCH_SPEC_TYPE="${WIN_SPEC_TYPE:-off}"
    BENCH_SPEC_N_MAX="${WIN_SPEC_N_MAX:-}"
    BENCH_SPEC_DRAFT_MODEL="${WIN_SPEC_DRAFT_MODEL:-}"
    if ! _bench_spawn "$BEST_CTX" "$BEST_B" "$BEST_U" "$EFFECTIVE_MMAP" \
        "$WIN_NGL" "$WIN_KVK" "$WIN_KVV"; then
        _bench_stop "$_BENCH_PID"
        BENCH_SPEC_TYPE="$_saved_spec_type"
        BENCH_SPEC_N_MAX="$_saved_spec_n_max"
        BENCH_SPEC_DRAFT_MODEL="$_saved_draft_model"
        __autotune_quality_error "task-quality probe could not start the winner configuration"
        return 1
    fi

    local _qworkload _qprompt _qpayload _quality_failed=0 _qresp="" _qout=""
    for _qworkload in "${probe_workloads[@]}"; do
        case "$_qworkload" in
            legal) _qprompt="${PROMPTS_LEGAL[1]}" ;;
            agentic) _qprompt="${PROMPTS_AGENTIC[0]}" ;;
            *) __autotune_quality_error "unknown task-quality probe workload: $_qworkload"; _quality_failed=1; break ;;
        esac
        _qpayload=$("$TAC_PYTHON" - "$_qprompt" <<'PYEOF'
import json, sys
print(json.dumps({
    "messages": [{"role": "user", "content": sys.argv[1]}],
    "max_tokens": 256,
    "temperature": 0,
}))
PYEOF
        ) || { __autotune_quality_error "could not build $_qworkload task-quality request"; _quality_failed=1; break; }
        # The checker's exit status is the verdict; its output carries a TYPED
        _qresp=$(curl -fsS --max-time "$BENCH_TIMEOUT" \
            "$_BENCH_HEALTH_URL/v1/chat/completions" \
            -H "Content-Type: application/json" -d "$_qpayload") || _qresp=""
        if [[ -z "$_qresp" ]]; then
            __autotune_quality_error \
                "$_qworkload task-contract probe returned no response; refusing to save this profile"
            _quality_failed=1
            break
        fi
        if ! _qout=$(printf '%s' "$_qresp" \
            | "$TAC_PYTHON" "$_quality_checker" --workload "$_qworkload" 2>&1); then
            __autotune_quality_error \
                "$_qworkload task-contract probe failed: ${_qout:-no diagnostic}"
            __autotune_quality_error \
                "$_qworkload refuses to save (ONE probe per workload: a smoke test, not a rate)"
            _quality_failed=1
            break
        fi
        echo "  $_qout"
    done

    _bench_stop "$_BENCH_PID"
    BENCH_SPEC_TYPE="$_saved_spec_type"
    BENCH_SPEC_N_MAX="$_saved_spec_n_max"
    BENCH_SPEC_DRAFT_MODEL="$_saved_draft_model"
    return "$(( _quality_failed == 0 ? 0 : 1 ))"
}

# bench_once — start server, run one benchmark, return decode TPS on stdout.
bench_once() {
    local c="$1" b="$2" u="$3" mmap_mode="${4:-auto}" override_ngl="${5:-}"
    local mode="${6:-quick}" kv_k="${7:-q8_0}" kv_v="${8:-q8_0}"
    local tag="/tmp/at-vram-${MODEL}-${c}"

    _BENCH_FAIL_TYPE=""  # global: "load_fail" or "oom"; reset before each bench
    cleanup_gpu >&2 || { echo "0|0|oom" > "/tmp/at-metrics-$$"; echo ""; return 1; }

    if [[ ! -f $tag ]]; then
        local g; g=$(timeout -k 2 "${TAC_SMI_TIMEOUT:-10}" \
            nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ')
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

# bench_once_multi — single-server multi-sample bench (WSL2 dxgkrnl fix).
bench_once_multi() {
    local samples="$1" c="$2" b="$3" u="$4" mmap_mode="${5:-auto}" override_ngl="${6:-}"
    local mode="${7:-quick}" kv_k="${8:-q8_0}" kv_v="${9:-q8_0}"
    local tag="/tmp/at-vram-${MODEL}-${c}"

    _BENCH_FAIL_TYPE=""
    cleanup_gpu >&2 || { echo "0|0|oom" > "/tmp/at-metrics-$$"; echo ""; return 1; }

    if [[ ! -f $tag ]]; then
        local g; g=$(timeout -k 2 "${TAC_SMI_TIMEOUT:-10}" \
            nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ')
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
    # Expose how many samples the figure really rests on (v85): the save used to stamp a
    printf '%s\n' "${#vals[@]}" > "/tmp/at-samples-$$"
    _spread=$(printf '%s\n' "${vals[@]}" | LC_ALL=C sort -n \
        | awk 'NR==1{min=$1} {max=$1} END{if (max>0) printf "%.2f", (max-min)*100/max}')
    printf '%s\n' "$_spread" > "/tmp/at-spread-$$"
    echo "$tps"
    return 0
}

# bench_ctx — returns decode TPS on stdout, empty on failure. RC 0/1.
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
        echo "$tps"
        return 0
    fi

    # Multi-sample (samples >= 2): spawn ONE server and issue N requests
    local tps; tps=$(bench_once_multi "$samples" "$c" "$b" "$u" "$mmap_mode" "$override_ngl" "$mode" "$kv_k" "$kv_v") || { echo ""; return 1; }
    # Refinement: only check for actual OOM (0 tokens). TPS floor is applied
    echo "$tps"
    return 0
}

# --- AUTOTUNE_SELFTEST: canned bench_ctx for decision-logic regression ---
if [[ "${AUTOTUNE_SELFTEST:-0}" == "1" ]]; then
    bench_ctx() {
        local c="$1" b="$2" u="$3" samples="${4:-1}" mmap_mode="${5:-auto}" override_ngl="${6:-}"
        local mode="${7:-quick}"
        _BENCH_FAIL_TYPE=""
        # Optional OOM ceiling: _SELFTEST_OOM_ABOVE makes ctx beyond the
        if [[ -n "${_SELFTEST_OOM_ABOVE:-}" ]] && [[ $c -gt ${_SELFTEST_OOM_ABOVE} ]]; then
            echo ""; return 1
        fi
        # Optional hard-load-failure mode: _SELFTEST_LOAD_FAIL makes every bench
        if [[ -n "${_SELFTEST_LOAD_FAIL:-}" ]]; then
            echo "0|0|load_fail" > "/tmp/at-metrics-$$"
            echo ""; return 1
        fi
        # Optional LAUNCH-failure mode (DEF-024): _SELFTEST_LAUNCH_FAIL=<oom|unsupported|
        if [[ -n "${_SELFTEST_LAUNCH_FAIL:-}" ]]; then
            _BENCH_LOG="/tmp/at-${MODEL}-c${c}-b${b}.log"
            case "$_SELFTEST_LAUNCH_FAIL" in
                oom)
                    cat > "$_BENCH_LOG" <<'EOF'
llama_model_load: loading model from '/models/stub.gguf'
ggml_backend_cuda_buffer_type_alloc_buffer: allocating 61440.00 MiB on device 0: cudaMalloc failed: out of memory
llama_model_load: error loading model: unable to allocate CUDA0 buffer
CUDA error: out of memory
EOF
                    printf '0|0|oom\n' > "/tmp/at-metrics-$$" ;;
                unsupported)
                    cat > "$_BENCH_LOG" <<'EOF'
llama_model_load: loading model from '/models/stub.gguf'
llama_model_load: error loading model: unknown model architecture: 'gpt-oss'
llama_load_model_from_file: failed to load model
EOF
                    printf '0|0|load_fail\n' > "/tmp/at-metrics-$$" ;;
                launch)
                    cat > "$_BENCH_LOG" <<'EOF'
error while handling argument "--spec-ngram-mod-n-max": invalid argument: 16
usage: llama-server [options]
EOF
                    printf '0|0|oom\n' > "/tmp/at-metrics-$$" ;;
                *)
                    cat > "$_BENCH_LOG" <<'EOF'
terminate called after throwing an instance of 'std::runtime_error'
  what():  unexpected internal state
EOF
                    printf '0|0|oom\n' > "/tmp/at-metrics-$$" ;;
            esac
            _bench_record_failure "$c" "$b" "$u" "${override_ngl:-0}" "q8_0/q8_0"
            echo ""; return 1
        fi
        # Optional TPS-floor threshold: _SELFTEST_FLOOR_ABOVE makes ctx above
        local _st_tps="8.5"
        if [[ -n "${_SELFTEST_FLOOR_ABOVE:-}" ]]; then
            if [[ $c -gt ${_SELFTEST_FLOOR_ABOVE} ]]; then
                _st_tps="5.0"
            else
                _st_tps="12.0"
            fi
        fi
        # _SELFTEST_CERT_GAP_ABOVE / _SELFTEST_CERT_GAP_FACTOR model the 2026-09-17 defect:
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
    ttft_probe() {
        echo "250.0|120.0"
        return 0
    }
    # cleanup_gpu stubbed — its ~4s of kill/sleep/drop-cache cycles per call
    cleanup_gpu() {
        return 0
    }
fi

# Probe

BEST_TPS="0"; BEST_COMBO=""; BEST_CTX=0; ANY_OK=false
# Profile 1's prefill tok/s (filled-cache certification) and profile 2.
BEST_PREFILL="0"
# Profile 2 (interactive): config with the highest decode TPS anywhere in the
P2_TPS="0"; P2_CTX=0; P2_B=""; P2_U=""; P2_PREFILL="0"
# Set to 1 when the --load-mode none fallback produced the winner; the beam search,
MMAP_FALLBACK_USED=0

# Writes to BEST_TPS/BEST_COMBO/BEST_CTX/ANY_OK globals.
record_best() {
    local c=$1 tps=$2 b=$3 u=$4

    # Profile 2 (interactive): highest decode TPS across every probed config,
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

# last_fail_type — read the last bench's failure classification from the
last_fail_type() {
    cut -d'|' -f3 "/tmp/at-metrics-$$" 2>/dev/null | head -1
}

# _last_fail_label [fail_type] — map a bench_ctx failure token to its display label.
_last_fail_label() {
    local _t="${1:-$(last_fail_type)}"
    case "$_t" in
        load_fail)            printf '%s\n' "unsupported model" ;;
        window_timeout)       printf '%s\n' "readiness timeout" ;;
        loader_crash_unknown) printf '%s\n' "unclassified crash" ;;
        *)                    printf '%s\n' "OOM" ;;
    esac
}

# --- KV-quant certification gate (KVCACHE-CONSOLE-PROMPT-CACHE-001) ---
KV_CERTIFIED_PAIRS="q8_0/q8_0"

# The REFERENCE dtypes are eligible without a retrieval probe, and that is not a
KV_REFERENCE_TYPES="f16 f32 bf16"

# kv_pair_status <type_k> <type_v> — print "certified" when this pair may be
kv_pair_status() {
    local _pair="$1/$2" _c
    for _c in $KV_CERTIFIED_PAIRS; do
        if [[ "$_c" == "$_pair" ]]; then
            printf '%s\n' "certified"
            return 0
        fi
    done
    if [[ "$1" == "$2" ]] && [[ " $KV_REFERENCE_TYPES " == *" $1 "* ]]; then
        printf '%s\n' "certified"
        return 0
    fi
    printf '%s\n' "not eligible: no long-context retrieval validation (KVCACHE-QUANT-VALIDATE-001)"
}

# probe_upward — bounded ctx re-climb for a fixed config (quick benches).
probe_upward() {
    local _pc="$1" _pb="$2" _pu="$3" _pm="${4:-auto}" _pngl="${5:-$BENCH_NGL}"
    local _pkk="${6:-q8_0}" _pkv="${7:-q8_0}"
    local _tps _lo _hi=0 _steps=0 _mid _fail_label

    # Which decode policy is this row being measured under?  Say it ONCE per row, before
    if [[ -z "${_SAMPLER_POLICY_LOGGED:-}" ]]; then
        _SAMPLER_POLICY_LOGGED=1
        local -a _policy_args=()
        mapfile -t _policy_args < <(_sampler_args "$MODEL_PATH")
        if (( ${#_policy_args[@]} > 0 )); then
            echo "  sampler: ${_policy_args[*]}   (registry columns 38/39)"
        else
            echo "  sampler: none configured (registry columns 38/39 blank) — llama.cpp defaults apply"
        fi
    fi

    _tps=$(bench_ctx "$_pc" "$_pb" "$_pu" 1 "$_pm" "$_pngl" "quick" "$_pkk" "$_pkv") || {
        _fail_label=$(_last_fail_label)
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
            _fail_label=$(_last_fail_label)
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
            _fail_label=$(_last_fail_label)
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
            fail_label=$(_last_fail_label)
            echo "  ctx $(fmt "$BEST_CTX") - ${fail_label} with batch $(fmt "$b")/$(fmt "$u")"
        fi
        continue
    fi
    test_num=0; c=$c0; found=false; _ALL_LOAD_FAIL=true; _ABORT_COMBO_WALK=0
    while [[ $c -ge $MIN_CTX ]]; do
        test_num=$((test_num + 1))
        tps=$(bench_ctx "$c" "$b" "$u" 1) || {
            _lft=$(last_fail_type)
            fail_label=$(_last_fail_label "$_lft")
            # STOP, do not halve, on a hard load failure, timeout, or unclassified crash:
            if [[ "$_lft" == "load_fail" ]]; then
                break
            fi
            if [[ "$_lft" == "loader_crash_unknown" || "$_lft" == "window_timeout" ]]; then
                echo "  Test $test_num: ctx $(fmt "$c") - ${fail_label} (stopping descent)"
                _ALL_LOAD_FAIL=false
                _ABORT_COMBO_WALK=1
                break
            fi
            echo "  Test $test_num: ctx $(fmt "$c") - ${fail_label}: dropping to $(fmt $((c/2)))"
            _ALL_LOAD_FAIL=false
            _next_c=$((c/2)); [[ $_next_c -lt $MIN_CTX ]] && break; c=$_next_c; continue
        }
        echo "  Test $test_num: ctx $(fmt "$c") - ${tps} tps"
        found=true; ANY_OK=true; _ALL_LOAD_FAIL=false
        record_best "$c" "$tps" "$b" "$u"

        # Always climb past the first success (fixed 2026-09-14): START_CTX
        lo=$c; hi=0; c=$((c * 3 / 2)); [[ $c -gt $MAX_CTX ]] && c=$MAX_CTX
        while true; do
            [[ $c -eq $lo ]] && break
            test_num=$((test_num + 1))
            bench_ctx "$c" "$b" "$u" 1 > /tmp/at-tps-$$; rc=$?
            tps=$(cat /tmp/at-tps-$$ 2>/dev/null)
            # REF: ubuntu-console card b564d801 — bench_ctx can return rc=0 with tps=0
            if [[ $rc -ne 0 ]] || [[ -z "$tps" || "$tps" == "0" || "$tps" == "0.00" || "$tps" == "0,00" ]]; then
                hi=$c
                fail_label=$(_last_fail_label)
                if [[ -n "$tps" && "$tps" == "0" ]]; then
                    echo "  Test $test_num: ctx $(fmt "$c") - 0 tps (${fail_label}): binary probe $(fmt $(( (lo+hi)/2/512*512 )))"
                else
                    echo "  Test $test_num: ctx $(fmt "$c") - ${fail_label}: binary probe $(fmt $(( (lo+hi)/2/512*512 )))"
                fi
                break
            fi
            lo=$c; record_best "$lo" "$tps" "$b" "$u"
            # Capacity-first (2026-08-27, Wayne): the climb does NOT stop on
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
                fail_label=$(_last_fail_label)
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
        fail_label=$(_last_fail_label)
        [[ $_ALL_LOAD_FAIL == true ]] && fail_label="unsupported model"
        # No attempt at all is NOT a model verdict.  _ALL_LOAD_FAIL is initialised
        if [[ $test_num -eq 0 ]]; then
            fail_label="PROBE BUG (no ctx attempted)"
            echo "  WARNING: START_CTX=$(fmt "$START_CTX") < MIN_CTX=$(fmt "$MIN_CTX") — the probe never ran. This is a probe-bounds bug, NOT an unsupported model." >&2
        fi
        echo "  Test $test_num: ctx $(fmt "$c") - ${fail_label} - model cannot run at any ctx"
        # Early abort: if the model never loaded at any ctx (load_fail at every
        if [[ $_ALL_LOAD_FAIL == true ]]; then
            echo "  (model cannot be loaded — skipping remaining combos)"
            break
        fi
        if [[ "${_ABORT_COMBO_WALK:-0}" == "1" ]]; then
            echo "  (unclassified crash on default load — skipping remaining combos)"
            break
        fi
    fi
done

# --- mmap fallback ---
_probe_no_mmap_climb() {
    local _lo="$1" _b="$2" _u="$3" _c _tps _rc _fl
    _c=$((_lo * 3 / 2)); [[ $_c -gt $MAX_CTX ]] && _c=$MAX_CTX
    while true; do
        [[ $_c -eq $_lo ]] && break
        bench_ctx "$_c" "$_b" "$_u" 1 "off" > /tmp/at-tps-$$; _rc=$?
        # swallow-ok: missing metrics temp file reads empty, which triggers the failure branch below
        _tps=$(cat /tmp/at-tps-$$ 2>/dev/null)
        if [[ $_rc -ne 0 ]]; then
            _fl=$(_last_fail_label)
            echo "  ctx $(fmt "$_c") - ${_fl}"
            break
        fi
        _lo=$_c; record_best "$_lo" "$_tps" "$_b" "$_u"
        echo "  ctx $(fmt "$_c") - ${_tps} tps - climbing to $(fmt $((_c*3/2)))"
        _c=$((_c * 3 / 2)); [[ $_c -gt $MAX_CTX ]] && _c=$MAX_CTX
    done
}

# probe_no_mmap — retry the probe with --load-mode none after default (mmap) loads fail.
probe_no_mmap() {
    echo ""
    echo "  default (mmap) load failed at all ctx — retrying with --load-mode none"
    echo ""
    _ALL_LOAD_FAIL=true
    local _abort_no_mmap=0
    for combo in "${COMBOS[@]}"; do
        IFS=':' read -r b u <<< "$combo"
        echo "  batch $(fmt "$b")/$(fmt "$u")  (--load-mode none)"
        echo "  ---------------------"

        c=$START_CTX; found=false
        while [[ $c -ge $MIN_CTX ]]; do
            tps=$(bench_ctx "$c" "$b" "$u" 1 "off") || {
                local _lft _next_c
                _lft=$(last_fail_type)
                fail_label=$(_last_fail_label "$_lft")
                # Same stop-on-load-fail rule as the mmap walk: an unloadable GGUF
                if [[ "$_lft" == "load_fail" ]]; then
                    break
                fi
                if [[ "$_lft" == "loader_crash_unknown" || "$_lft" == "window_timeout" ]]; then
                    echo "  ctx $(fmt "$c") - ${fail_label} (stopping descent)"
                    _ALL_LOAD_FAIL=false
                    _abort_no_mmap=1
                    break
                fi
                echo "  ctx $(fmt "$c") - ${fail_label}: dropping to $(fmt $((c/2)))"
                _ALL_LOAD_FAIL=false
                _next_c=$((c/2)); [[ $_next_c -lt $MIN_CTX ]] && break; c=$_next_c; continue
            }
            echo "  ctx $(fmt "$c") - ${tps} tps"
            found=true; ANY_OK=true; _ALL_LOAD_FAIL=false; MMAP_FALLBACK_USED=1
            record_best "$c" "$tps" "$b" "$u"
            _probe_no_mmap_climb "$c" "$b" "$u"
            break
        done
        # Likewise early-abort remaining combos in the fallback path
        if [[ $_ALL_LOAD_FAIL == true ]]; then
            echo "  (model cannot be loaded even with --load-mode none — aborting)"
            break
        fi
        if (( _abort_no_mmap == 1 )); then
            echo "  (unclassified crash with --load-mode none — aborting)"
            break
        fi
    done
}

# A model that never loaded at any ctx (a load_fail at every step) is un-runnable
if [[ $ANY_OK == false && ${_ALL_LOAD_FAIL:-true} != true ]]; then
    probe_no_mmap
fi

_cuda_guard_or_exit

# --- Beam search over batch/ubatch at the winning ctx ---
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
            fail_label=$(_last_fail_label)
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
    if [[ -n $BEST_COMBO ]]; then
        IFS=':' read -r BEST_B BEST_U <<< "$BEST_COMBO"
        echo "  re-climbing ctx for combo $(fmt "$BEST_B")/$(fmt "$BEST_U")"
        probe_upward "$BEST_CTX" "$BEST_B" "$BEST_U" "$EFFECTIVE_MMAP"
    fi
fi

_cuda_guard_or_exit

# --- n_gpu_layers / KV-quant sweep (the "almost fits" band) ---
WIN_NGL="$BENCH_NGL"; WIN_KVK="q8_0"; WIN_KVV="q8_0"
BAND_MIN_MB=$(awk -v f="$FREE_VRAM" -v fr="$NGL_BAND_FRAC" 'BEGIN{printf "%d", f*fr}')
if [[ $ANY_OK == true && -n $BEST_COMBO ]] && [[ $MODEL_MB -ge $BAND_MIN_MB ]]; then
    IFS=':' read -r BEST_B BEST_U <<< "$BEST_COMBO"

    # ngl candidates: runtime-max offload (999) plus a short ladder down the
    NGL_CANDIDATES=()
    [[ "$BENCH_NGL" != "999" ]] && NGL_CANDIDATES+=("999")
    # SHARED-MEMORY HOSTS GET NO LADDER (2026-11-03).  The ladder exists for a discrete
    if [[ "${TAC_HOST_PROFILE_SHARED_MEMORY:-0}" == "1" ]]
    then
        echo "  • Layer offload: Keeping full offload (unified memory detected)"
    elif [[ -n "${_n_layers:-}" ]] && [[ "$_n_layers" =~ ^[0-9]+$ ]] && [[ $_n_layers -gt 1 ]]; then
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
    KV_PAIRS=()
    _pair=""
    for _pair in $KV_QUANTS; do
        _kk="${_pair%%/*}"; _kv="${_pair##*/}"
        [[ "$_kk" == "$WIN_KVK" && "$_kv" == "$WIN_KVV" ]] && continue
        _kv_status=$(kv_pair_status "$_kk" "$_kv")
        if [[ "$_kv_status" != "certified" ]]; then
            echo "  • KV Cache ($_kk/$_kv): Skipped (requires retrieval validation test)"
            continue
        fi
        KV_PAIRS+=("$_pair")
    done
    unset _kv_status

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
if [[ $ANY_OK == true && -n $BEST_COMBO ]]; then
    IFS=':' read -r BEST_B BEST_U <<< "$BEST_COMBO"
    echo ""
    echo "  Phase 4: filled-cache TPS floor recovery"
    echo "  ---------------------"
    _dc=$BEST_CTX
    _ft=""
    # TPS-first (2026-08-29, Wayne): the certified ctx is the highest ctx
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
            _flat=0 _prev_tps=$_ft
            # The ladder is computed ONCE, from the ctx that failed, so capture it before the
            _dc_from=$_dc
            while IFS= read -r _dc; do
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
                    if [[ $_dok == 0 ]]; then
                        # swallow-ok: bc's own failure is the "no improvement" answer below, which fails safe (the walk continues)
                        if [[ $(echo "$_ft > $_prev_tps * 1.10" | bc -l 2>/dev/null || echo "0") == 1 ]]
                        then
                            _flat=0
                        else
                            _flat=$((_flat + 1))
                        fi
                        _prev_tps=$_ft
                        if (( _flat >= 2 )); then
                            echo "  tps is flat across ctx (no >10% gain in 2 descents) — stopping the walk early"
                            break
                        fi
                    fi
                fi
            done < <(__autotune_descent_candidates "$_dc_from" "$MIN_CTX" "$PREV_CERT_CTX")
            if [[ $_dok == 0 || $_pok == 0 ]]; then
                if (( _flat >= 2 )); then
                    echo "  ⚠ below floor and flat across ctx — too slow (walk stopped early)"
                    echo "    recording best-effort config (max TPS) for capability profiling"
                else
                    echo "  ⚠ below floor even at min ctx — too slow for our purposes; recording best-effort config"
                fi
            fi
        fi
    else
        _FAST_REJECT=0
        fail_label=$(_last_fail_label)
        echo "  ctx $(fmt "$_dc") - filled ${fail_label} (capacity ctx failed the filled load — descending once)"
        # The capacity ctx failed the FILLED load (memory pressure at fill) — fall back to a
        _dc_from=$_dc
        while IFS= read -r _dc; do
            _ft=$(bench_ctx "$_dc" "$BEST_B" "$BEST_U" 3 "$EFFECTIVE_MMAP" "$WIN_NGL" "filled" "$WIN_KVK" "$WIN_KVV") || _ft=""
            if [[ -n $_ft ]] && [[ $(echo "$_ft > 0" | bc 2>/dev/null || echo "0") == 1 ]]; then
                IFS='|' read -r _fd _fp _ff < "/tmp/at-metrics-$$" 2>/dev/null || true
                echo "  ctx $(fmt "$_dc") - filled ${_ft} tps (prefill ${_fp:-0} tok/s)"
                BEST_CTX=$_dc; BEST_TPS=$_ft; BEST_PREFILL="${_fp:-0}"
                break
            fi
        done < <(__autotune_descent_candidates "$_dc_from" "$MIN_CTX" "$PREV_CERT_CTX")
    fi

    # Final certification: multi-sample (median) at the winner for the
    _FAST_REJECT=0
    : > "/tmp/at-served-ctx-$$" 2>/dev/null || rm -f "/tmp/at-served-ctx-$$" 2>/dev/null || true
    _cert=$(bench_ctx "$BEST_CTX" "$BEST_B" "$BEST_U" 5 "$EFFECTIVE_MMAP" "$WIN_NGL" "filled" "$WIN_KVK" "$WIN_KVV") || _cert=""
    # The ctx the server ACTUALLY served, captured by bench_ctx from its live server.
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
    if [[ $BEST_CTX -gt $MIN_CTX ]] \
        && [[ $(echo "${BEST_TPS:-0} < $MIN_TPS" | bc 2>/dev/null || echo "0") == 1 ]]; then
        echo "  certified ${BEST_TPS} tps is below the floor at ctx $(fmt "$BEST_CTX")" \
            "— descending at the certification's sample count"
        _cert_from=$BEST_CTX
        while IFS= read -r _cert_dc; do
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
        done < <(__autotune_descent_candidates "$_cert_from" "$MIN_CTX" "$PREV_CERT_CTX")
    fi
    # Record GPU thermal/clock state alongside the certified number — heat
    if command -v nvidia-smi >/dev/null 2>&1; then
        _gpu_thermal=$(timeout -k 2 "${TAC_SMI_TIMEOUT:-10}" \
            nvidia-smi --query-gpu=temperature.gpu,clocks.sm --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ')
        echo "  thermal at certification: GPU ${_gpu_thermal:-n/a} (temp °C, SM MHz)"
    fi

    # tps-collapse guard (WSL2 dxgkrnl degradation): the dmesg EOVERFLOW proxy
    if __autotune_collapse_verdict "${_tps:-}" "${BEST_TPS:-0}"; then
        _meas_collapse=1
        echo ""
        echo "  ⚠ WARN: tps collapse — certified ${BEST_TPS} tps vs recorded ${_tps} tps (>=2x drop)."
        echo "           GPU may be degraded (WSL2 dxgkrnl leak); the re-certified numbers are untrustworthy."
        echo "           Restart WSL (wsl --shutdown) before trusting this re-tune."
        echo ""
    fi
fi

_cuda_guard_or_exit

# After a TPS-floor descent, the interactive profile must never exceed the
if [[ $P2_CTX -gt $BEST_CTX ]]; then
    echo "  profile 2 ctx $(fmt "$P2_CTX") clamped to certified $(fmt "$BEST_CTX")"
    P2_CTX=$BEST_CTX
fi

# Profile 2 (interactive) certification: one filled bench at the max-TPS
if [[ $ANY_OK == true && -n $BEST_COMBO ]] && [[ $P2_CTX -gt 0 ]]; then
    if [[ "$P2_CTX|$P2_B:$P2_U" != "$BEST_CTX|$BEST_B:$BEST_U" ]]; then
        echo "  certifying profile 2 (interactive) at ctx=$(fmt "$P2_CTX")  $(fmt "$P2_B")/$(fmt "$P2_U")"
        # 3 samples (2026-09-14, was 1).  The old "one sample keeps churn to a
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
    _sb_list="$SPEC_N_MAX_LIST"
    if [[ "${AUTOTUNE_SPEC_SWEEP:-1}" == "0" ]]; then
        _sb_list=""
        echo "  (AUTOTUNE_SPEC_SWEEP=0 — skipping the sweep to conserve CUDA cycles)"
    fi
    _sb_zero=0
    for _sb_block in $_sb_list
    do
        if [[ ! "$_sb_block" =~ ^[0-9]+$ ]] || (( _sb_block <= 0 )); then
            continue
        fi
        BENCH_SPEC_TYPE="ngram"; BENCH_SPEC_N_MAX="$_sb_block"
        # samples=1 (not 3): the block sweep is a *selection*, not a recorded
        _sb_t=$(bench_ctx "$BEST_CTX" "$_sb_b" "$_sb_u" 1 "$EFFECTIVE_MMAP" "$WIN_NGL" "filled" "$WIN_KVK" "$WIN_KVV") || _sb_t=""
        _sb_t=$(echo "$_sb_t" | bc 2>/dev/null || echo "0"); [ -z "$_sb_t" ] && _sb_t=0
        _sb_al="0"; _sb_ar="0"
        IFS='|' read -r _sb_d _sb_p _sb_f _sb_al _sb_ar _sb_bl < "/tmp/at-metrics-$$" 2>/dev/null || true
        echo "  block ${_sb_block}: ${_sb_t} tps (accept len ${_sb_al:-0}, rate ${_sb_ar:-0})"
        # ECONOMY (2026-11-03): two consecutive blocks that accepted nothing is enough
        if [[ "${_sb_al:-0}" =~ ^[0-9]+$ ]] && (( _sb_al == 0 ))
        then
            _sb_zero=$((_sb_zero + 1))
        else
            _sb_zero=0
        fi
        if __autotune_spec_sweep_stop "$_sb_zero"
        then
            echo "  spec-decode: ${_sb_zero} consecutive blocks accepted nothing — stopping the sweep"
            break
        fi
        if [[ $(echo "$_sb_t > $_sb_best_tps" | bc 2>/dev/null || echo "0") == 1 ]]; then
            # Faster is not enough: the block must actually PLACE draft tokens, or every
            if __autotune_spec_worth_keeping "${_sb_al:-0}" "${_sb_ar:-0}"
            then
                _sb_best_tps="$_sb_t"
                WIN_SPEC_TYPE="ngram"; WIN_SPEC_N_MAX="$_sb_block"; WIN_SPEC_ACCEPT_LEN="$_sb_al"
            else
                echo "  block ${_sb_block}: faster but accepted ${_sb_al:-0} tokens —" \
                     "NOT recorded (a draft that never hits is pure overhead)"
            fi
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


# ttft_probe — time-to-first-token at a config (AUTOTUNE-003).
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
        # The sampler fragment is built in BOTH launch helpers (the bench spawn and the
        local -a sampler_args=()
        mapfile -t sampler_args < <(_sampler_args "$MODEL_PATH")
        "$LLAMA_BIN" --model "$MODEL_PATH" --port "$autotune_port" --host 127.0.0.1 \
            --ctx-size "$c" --batch-size "$b" --ubatch-size "$u" \
            --threads "$TUNE_THREADS" --n-gpu-layers "$effective_ngl" \
            --parallel 1 --fit off "${fa_args[@]}" --kv-offload \
            --cache-type-k "$kv_k" --cache-type-v "$kv_v" "${mmap_flag[@]}" \
            "${sampler_args[@]}" \
            > "/tmp/at-ttft-${MODEL}-c${c}.log" 2>&1 &
        pid=$!
        _bump_cuda_cycle
        hw=0
        while [[ $hw -lt "$AT_WINDOW_S" ]]; do
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
    if [[ $hw -ge "$AT_WINDOW_S" ]]; then
        _bench_stop "$pid"
        echo ""; return 1
    fi

    # Pre-flight: one real completion confirms the slot is actually serving
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
TTFT_MS=0; TTFT_PER_STEP=0
if [[ $ANY_OK == true && -n $BEST_COMBO ]]; then
    IFS=':' read -r BEST_B BEST_U <<< "$BEST_COMBO"
    echo ""
    # 1 sample (not 3): TTFT is a secondary latency metric; a single sample
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
WIN_PARALLEL=1

# REF: ubuntu-console card ca23ec0a — cleanup_gpu uses AUTOTUNE_PORT (18082), not the production port 18081
_autotune_failure_report() {
    local _src="/tmp/at-fail-$$" _cls="unclassified" _config="" _log="" _line=""
    local -a _tail=()
    if [[ -r "$_src" ]]; then
        _cls=$(sed -n 's/^classification=//p' "$_src" | head -1)
        _config=$(sed -n 's/^config=//p' "$_src" | head -1)
        _log=$(sed -n 's/^log=//p' "$_src" | head -1)
        mapfile -t _tail < <(sed -n 's/^tail=//p' "$_src")
    fi
    [[ -n "$_cls" ]] || _cls="unclassified"
    _FINAL_FAIL_CLASS="$_cls"

    # The headline must not outrun the class.  It used to say "the model cannot be loaded at any
    case "$_cls" in
        unsupported_arch)
            echo "  failed: the model cannot be loaded at any ctx — NOT CERTIFIED" ;;
        resource_exhausted)
            echo "  failed: every configuration ran out of memory on this card — not certified on this run" ;;
        launch_error)
            echo "  failed: the server rejected its launch before it could be measured — not certified on this run" ;;
        loader_vintage)
            echo "  failed: the file and the loader disagree about a required GGUF key — NOT CERTIFIED" ;;
        *)
            echo "  failed: no configuration could be measured — not certified on this run" ;;
    esac
    echo "  reason:  $(__autotune_failure_label "$_cls")"
    if [[ -n "$_config" ]]; then
        echo "  last launch attempted: ${_config}"
    fi
    if (( ${#_tail[@]} > 0 )); then
        echo "  server stderr (last ${#_tail[@]} lines${_log:+ of $_log}):"
        for _line in "${_tail[@]}"; do
            printf '    | %s\n' "$_line"
        done
    elif [[ -n "$_log" ]]; then
        echo "  server stderr: the launch wrote nothing to $_log before it exited"
    else
        echo "  server stderr: no launch output was captured for this run"
    fi

    # A DURABLE verdict is one about the model or the build: an architecture the binary
    if [[ "$_cls" == "unsupported_arch" ]]; then
        if [[ "${AUTOTUNE_SELFTEST:-0}" == "1" ]]; then
            echo "  registry: would mark meas_state=unacceptable (selftest — registry untouched)"
            _FINAL_REGISTRY_STATE="unacceptable (selftest, not written)"
        elif declare -f __llm_autotune_mark_state &>/dev/null \
            && __llm_autotune_mark_state "$MODEL_FILE" "unacceptable"; then
            _FINAL_REGISTRY_STATE="unacceptable"
            echo "  registry: row marked meas_state=unacceptable — NOT CERTIFIED; consumers must not select it"
        else
            _FINAL_REGISTRY_STATE="unmarked (write failed)"
            warn "  registry: WARNING — could not mark $MODEL_FILE not-certified; the row still reads as usable"
        fi
    else
        _FINAL_REGISTRY_STATE="unchanged"
        echo "  registry: row left unchanged — this failure is not a verdict on the model; fix it and re-run"
    fi
    # 2026-11-06 (Wayne): record every classified failure durably, and archive the ones
    _arch="$(dirname "$(readlink -f "$0")")/../bin/llm-archive-unusable.sh"
    if [[ -x "$_arch" ]]; then
        # swallow-ok: the recorder must never change this row verdict; its own output is the record
        "$_arch" --record-failure "$MODEL_FILE" --class "$_cls" || true
        # swallow-ok: a failed assess prints nothing, so the too-big test simply does not fire
        if "$_arch" --assess "$MODEL_FILE" 2>/dev/null | grep -qx verdict=too-big; then
            # swallow-ok: archival failure is reported by the tool; the row verdict stands
            "$_arch" --archive "$MODEL_FILE" --reason "capacity: the weight set exceeds this box guest-RAM ceiling" || true
        fi
    else
        echo "  archive: recorder not found at $_arch - failure not recorded" >&2
    fi
    if [[ -n "${LLM_AUTOTUNE_RESULT_FILE:-}" ]]; then
        echo "  result:  ${LLM_AUTOTUNE_RESULT_FILE}"
    fi
}

cleanup_gpu 3 >/dev/null 2>&1 || { echo "ERROR: cleanup_gpu failed after 3 retries — port ${AUTOTUNE_PORT:-18082} still bound" >&2; exit 1; }
echo ""

if [[ $ANY_OK == true && -n $BEST_COMBO ]]; then
    IFS=':' read -r BEST_B BEST_U <<< "$BEST_COMBO"

    # Capability verdict relative to the floor (filled-cache decode TPS). We
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
    if [[ $BEST_CTX -gt 0 ]]
    then
        # AUTOTUNE_SERVED_CTX was captured by bench_ctx from ITS live server, via the
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
    # Measurement context (2b/3c): the box's load is read ONCE, BEFORE the selftest and
    _row_load=$(cut -d' ' -f1 /proc/loadavg 2>/dev/null || echo "?")
    _row_cores=$(nproc 2>/dev/null || echo "?")
    # AUTOTUNE_SELFTEST never persists — the canned curve is a decision-logic
    if [[ "${AUTOTUNE_SELFTEST:-0}" == "1" ]]; then
        echo "  (selftest — registry write skipped)"
    elif declare -f __llm_autotune_profile_save &>/dev/null; then
        # SPEC-DEC-004: record the winning spec block + measured acceptance
        # swallow-ok: pgrep exit 1 means no runners, which is the quiet reading — not an error
        _row_ci=$(pgrep -fc '[R]unner\.Worker' 2>/dev/null) || _row_ci=0
        # NOT in a subshell (v126).  Both the word and the reason are script-scope state, and
        __AUTOTUNE_VERDICT=""
        __autotune_measurement_verdict "$_row_load" "$_row_cores" \
            "${ALLOW_CONTENDED:-0}" "${TAC_CONTENDED:-0}" \
            "${START_PSI_PCT:-}" "$_row_ci" >/dev/null
        _meas_state="$__AUTOTUNE_VERDICT"
        if [[ "$_meas_state" == "refuse" ]]; then
            echo "  REFUSING to write: ${__AUTOTUNE_VERDICT_REASON:-the gate named no term} — the box"
            echo "  was CONTENDED, so this row's tps is indicative, not certified — nothing was written."
            echo "  Re-run on a quiet box, or pass --allow-contended to save it as meas_state=indicative."
            exit 1
        fi
        # The verdict is the WEAKEST of the three terms, not the load alone.  A collapse is a
        if [[ "${_meas_collapse:-0}" == "1" && "$_meas_state" == "certified" ]]; then
            echo "  stamping this row INDICATIVE: the collapse above makes this a re-tune owed, not a certification"
            _meas_state="indicative"
        fi
        # 1a — the POSITION term.  The winner above is a median of 5 taken at ONE point in
        _meas_drift_pct=""
        _meas_pos2=$(bench_ctx "$BEST_CTX" "$BEST_B" "$BEST_U" 5 "$EFFECTIVE_MMAP" \
            "$WIN_NGL" "filled" "$WIN_KVK" "$WIN_KVV") || _meas_pos2=""
        [[ -n "$_meas_pos2" ]] \
            && _meas_drift_pct=$(__autotune_position_drift "${BEST_TPS:-0}" "$_meas_pos2")
        if [[ -z "$_meas_drift_pct" ]]; then
            # FAIL CLOSED (v85): an unmeasurable second position is not evidence of stability.
            echo "  the second-position re-measurement produced no figure — stamping this row INDICATIVE"
            _meas_state="indicative"
        elif awk -v d="$_meas_drift_pct" -v w="$AUTOTUNE_DRIFT_WARN_PCT" 'BEGIN{exit !(d > w)}'; then
            echo "  position drift ${_meas_drift_pct}% (p1=${BEST_TPS} p2=${_meas_pos2}) exceeds" \
                 "the ${AUTOTUNE_DRIFT_WARN_PCT}% hazard bound — stamping this row INDICATIVE"
            _meas_state="indicative"
        else
            echo "  position drift ${_meas_drift_pct}% (p1=${BEST_TPS} p2=${_meas_pos2}) —" \
                 "within the ${AUTOTUNE_DRIFT_WARN_PCT}% hazard bound"
        fi
        # v85: a thermally throttled card is NOT a comparable measurement.  The SW Thermal
        if [[ "${AUTOTUNE_SELFTEST:-0}" != "1" ]]; then
            _throttle=$(timeout -k 2 "${TAC_SMI_TIMEOUT:-10}" nvidia-smi --query-gpu=clocks_throttle_reasons.active \
                --format=csv,noheader 2>/dev/null | head -1 | tr -d ' ')
            if [[ "$_throttle" =~ ^0x[0-9a-fA-F]+$ ]] && (( _throttle & 0x20 )); then
                echo "  SW Thermal Slowdown is ACTIVE at certification — stamping this row INDICATIVE"
                _meas_state="indicative"
            fi
        fi
        if ! __autotune_task_quality_check; then
            __autotune_quality_error "task-quality contract was not verified — the winner was NOT saved"
            exit 1
        fi
        # CTXBUDGET-003: report how the certified window relates to the observed input
        _row_avg_prompt=$(awk -F'|' -v f="$MODEL_FILE" '$3 == f {print $37; exit}' "$LLM_REGISTRY")
        _ctx_policy=$(__autotune_window_policy "$BEST_CTX" "$_row_avg_prompt")
        case "$_ctx_policy" in
            profile-missing)
                echo "  profile-missing (no observed profile; max-ctx certification unchanged)" ;;
            profile-fits:*)
                echo "  ${_ctx_policy}" ;;
            profile-over:*)
                echo "  ${_ctx_policy} (a smaller window would cover the observed profile)" ;;
            profile-under:*)
                echo "  WARNING: ${_ctx_policy} — the observed prompt does not fit this window" ;;
            *)
                echo "  WARNING: window policy returned an unexpected verdict '${_ctx_policy}'" ;;
        esac
        # v85: the REAL sample count and spread written by the last bench_once_multi (the
        _meas_n=5
        [[ -r "/tmp/at-samples-$$" ]] && _meas_n=$(< "/tmp/at-samples-$$")
        [[ "$_meas_n" =~ ^[0-9]+$ ]] || _meas_n=5
        _meas_spread=""
        [[ -r "/tmp/at-spread-$$" ]] && _meas_spread=$(< "/tmp/at-spread-$$")
        # A below-floor verdict is saved as autotuned=slow, not "yes" and not "no":
        # swallow-ok: an unusable bc is the below-floor branch, which records "slow" — the safe side
        if [[ $(echo "$BEST_TPS >= $MIN_TPS" | bc 2>/dev/null || echo "0") == 1 ]]
        then
            AUTOTUNE_SAVE_STATE=yes
        else
            AUTOTUNE_SAVE_STATE=slow
        fi
        export AUTOTUNE_SAVE_STATE
        __llm_autotune_profile_save "$MODEL_FILE" "native" "$BEST_CTX" "$BEST_B" "$BEST_U" "$WIN_PARALLEL" "256" "$BEST_TPS" \
            "" "$BEST_PREFILL" "${_P2ARGS[@]}" "$KV_QUANT_SAVE" "$WIN_NGL" \
            "$WIN_SPEC_TYPE" "" "$WIN_SPEC_N_MAX" "" "" "$WIN_SPEC_ACCEPT_LEN" \
            "$WORKLOAD" "$TTFT_MS" \
            "$_row_load" "$_meas_n" "$_meas_spread" "$_meas_drift_pct" "$_meas_state" "$_ctx_policy" \
            "$LLAMA_BUILD_ID" "$VRAM_TOTAL" \
            || { echo "  ERROR: registry write not verified - the winner was NOT saved"; exit 1; }
    else
        # A missing helper used to take NEITHER branch and then still print the
        echo "  ERROR: __llm_autotune_profile_save is not loaded — the winner was NOT saved." >&2
        echo "         The console's llm-manager helpers failed to load; look for 'missing sub-module' above." >&2
        exit 1
    fi
    awk -F'|' -v f="$MODEL_FILE" '$3 == f {rp=($38==""?"none":$38); rln=($39==""?"none":$39); printf "  saved:   ctx=%s batch=%s/%s parallel=%s tps=%s prefill=%s autotuned=%s spec_type=%s spec_n_max=%s spec_accept_len=%s workload=%s ttft_ms=%s sampler=%s/%s\n", $8, $10, $11, $12, $17, $21, $18, $27, $29, $32, $33, $34, rp, rln}' "$LLM_REGISTRY"

    # Measurement context (2026-09-16).  A certified tps is only comparable to another
    if [[ "$_row_load" =~ ^[0-9.]+$ && "$_row_cores" =~ ^[0-9]+$ ]] \
        && awk -v l="$_row_load" -v c="$_row_cores" 'BEGIN{exit !(l > c)}'
    then
        echo "  WARNING: measured at load ${_row_load} on ${_row_cores} cores — the box was CONTENDED, so this row's tps is indicative, not certified (retuning advised on a quiet box)."
    elif [[ "${_meas_state:-}" == "indicative" ]]; then
        # DEFAULT THE PARAMETER.  `_meas_state` is assigned only inside the save branch, so
        echo "  WARNING: ${__AUTOTUNE_VERDICT_REASON:-an unstated term} — this row's tps is" \
             "INDICATIVE, not certified, even though load ${_row_load} was under" \
             "${_row_cores} cores (retuning advised on a quiet box)."
    else
        echo "  measured at load ${_row_load} on ${_row_cores} cores"
    fi
    echo ""
    echo "============================================="
    echo "  done"
    exit 0
else
    # ── DEF-024: say WHY, and never call an unqualified failure "unsupported" ────
    _autotune_failure_report
    exit 1
fi

# end of file

# end of file marker
