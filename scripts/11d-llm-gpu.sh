# shellcheck shell=bash
# --- Module: 11d-llm-gpu ---
# AI INSTRUCTION: On ANY change to this file, increment the Module Version below.
# Module Version: 54
#   v54 (2026-11-12): wake() reports unified-memory Model Memory budget (MemTotal -
#     LLAMA_FIT_KEEP_RESERVE_MB) alongside GPU Carve (NVML) when
#     TAC_HOST_PROFILE_SHARED_MEMORY=1 so `model bench` shows the true model pool.
#   v53 (2026-11-11): one canonical version line; the historical entries below
#     are changelog only, so the loader sums this file once (inspection 13.4.3).
#   v52 (2026-11-10): exclude CPU heartbeat servers (build-cpu) from CUDA process discovery
#     and reap, matching _tac_cuda_server_pids.
#   v51 (2026-11-10): __calc_ctx_size respects shared-memory host context ceiling
#     (LLAMA_MAX_CTX_SIZE / 262144 on unified-memory boxes) instead of hardcoding 65536.
#   v50 (2026-11-10): on a SHARED-MEMORY host, __calc_gpu_layers judges a dense model against
#     the GUEST (MemTotal minus LLAMA_FIT_KEEP_RESERVE_MB), not the card's carve.  The pool
#     there is a reservation backed by the guest's RAM, so the carve is not the allocation
#     bound: a 50.9 GiB model served with -ngl 999 on a 32,768 MiB pool, yet every scan
#     re-marked it CPU-only and undid the launch.  MemTotal rather than MemAvailable, because
#     a scan can run while the model is resident.  The launch-time preflight still guards the
#     live allocation.
#   v49 (2026-11-10): a registry row's draft model now RESOLVES against the store.  The row
#     names its file relative to $LLAMA_MODEL_DIR, but this builder passed the column
#     through verbatim, so the launch carried `--spec-draft-model mtp-....gguf` while the
#     server's cwd is the repo — a draft that cannot be found.  Measured on row 4; the
#     absolute path, or a relative one that is not in the store, is left untouched.
#   v48 (2026-11-10): __llm_cuda_server_pids delegates its /proc walk to the shared
#     _tac_cuda_server_pids; the lanes-stopped declaration moved above the function's
#     doc block so §18.3 9.5's comment is directly above __llm_stand_down_cuda_lanes.
#   v47 (2026-11-10): __llm_restore_stopped_lanes — the run that stands a lane down puts it
#     back itself.  The watchdog's recover() DEFERS while a heavy job holds the box
#     (LLAMA-LANE-CONTENTION-001) and a `model autotune` run IS that heavy job, so when such
#     a run ended nothing restarted the lane until the next tick — up to five minutes — and
#     a stop that escalated to SIGKILL left the unit `failed` on top of that.  Measured
#     09:16 today: the chat lane sat `failed`, /health dead, from 09:16:17 until a hand
#     start, while the watchdog's 09:19 tick logged `suspend: NOT HELD` and finished without
#     touching it.  The stand-down now records what it stopped, and the restore clears
#     `failed` before starting.
#   v46 (2026-11-10): __llm_cuda_server_pids delegates its /proc walk to the shared
#     _tac_cuda_server_pids (bin/_tac-bin-lib.sh) now that the two copies agree on
#     the build-opencl exclusion; the local walk stays as a fallback for callers
#     that source this module without the bin library.
#   v45 (2026-11-10): removed __llm_train_lane_busy — the predicate form had no
#     caller (every consumer calls __llm_train_lane_holder directly).
#   v44 (2026-11-10): the stale-lock reaper reads model-shell PID files from
#     LLM_MODELSHELL_PID_DIR (one constant) instead of the hardcoded /tmp literal.
#   v43 (2026-11-09): __spec_launch_flags reports an unknown draft type through this
#   file's `warn` helper.  v42 wrote it with a hand-written `>&2`, which is exactly the
#   pattern §18.3 10.7 counts — tools/count-ratchet.sh read 245 -> 246 on the commit that
#   carried it, so the tip could not be pushed.  The file already had the helper, with a
#   comment saying it exists to keep new lines off that count; the flag stream on stdout
#   is still the reason the note cannot be a normal tac_info line.
#   v42 (2026-11-09): __spec_launch_flags NAMES a model-based draft type.  It emitted
#   --spec-type only for `ngram`, so a registry row carrying spec_type=draft-dflash
#   (or mtp/simple/eagle3/dspark) with a draft file launched that file with no type and
#   llama-server fell back to its own default — the row's value, read and dropped.  The
#   adopted Qwen3.8-27B DFlash configuration ran with the type named, so the row must
#   reproduce it; backend sampling ships with it and LLM_SPEC_DRAFT_BACKEND_SAMPLING=0
#   turns that off.  An unrecognised type now says so on stderr instead of vanishing.
#   v41 (2026-11-08): __llm_stand_down_cuda_lanes asks the SHARED collector which lanes
#   hold CUDA memory, and refuses to run under AUTOTUNE_SELFTEST=1.  It keyed that
#   decision on nvidia-smi's compute-apps list alone, which answers rc=0 with NO rows on
#   this host — so the deliberate stand-down was a silent no-op: measured 2026-11-08
#   23:54, `model autotune 1` was refused with "Unlisted holders (declared tenants:
#   …embed.service)" naming llama-cuda-qwen3coder-30b-chat.service, a lane the profile
#   says IS stood down for an autotune, while that list reported nothing at 32,331 MiB
#   used.  __llm_cuda_server_pids (v37) is the attribution that works here; the selftest
#   guard is required BECAUSE of it, or a canned run would stop the live lane.
#   v40 (2026-11-06): __calc_gpu_layers' MoE branch no longer CLAIMS the experts are on
#   the CPU.  `-ngl` moves whole layers, expert tensors included; they leave VRAM only
#   with --cpu-moe.  The returned layer count is unchanged, and the launcher now decides
#   placement in 11e (__model_use_fit_preflight) — the sentence this corrects is how a
#   73.3 GB MoE came to be asked for a 24 GiB card and died with CUDA OOM at load.
#   v39 (2026-11-06): the stale-CUDA python sweep is scoped before it kills.  It used to
#   TERM any python process in the compute-apps list that was not llama-server, with no
#   ownership or age test — and at 00:55 on 2026-11-06 it killed one while another agent's
#   pipeline ran inside the transient unit vexed-uphold-full.service.  __gpu_stale_context_verdict
#   now refuses a process inside ANY named .service and one younger than
#   LLM_GPU_STALE_MIN_AGE_S (600 s), so only an unowned leftover can be reaped.
#   v38 (2026-11-06): wake reads persistence mode before it touches sudo.  It used to
#   call `sudo -n nvidia-smi -pm 1` unconditionally, so `model bench` on a box without
#   passwordless sudo printed "GPU Persistence [FAILED - passwordless sudo required for
#   nvidia-smi]" for a card whose mode already read Enabled — a sudo requirement invented
#   by the probe.  Only a Disabled reading is escalated now, and that failure names the
#   `sudo nvidia-smi -pm 1` command; an unreadable/N/A mode is reported as not exposed.
#   Same run: __llm_vram_holder_report printed an EMPTY "Held by:" block under a refusal
#   whose census named its holder, because it read compute-apps — empty on this host.  Its
#   holder list now comes from __llm_cuda_server_pids (compute-apps, else /proc/PID/exe).
#   v37 (2026-11-05): __llm_cuda_server_pids gives the CUDA reap an attribution that
#   works on WSL2.  nvidia-smi's compute-app list is EMPTY here even at 73 GiB used, so
#   __llm_kill_cuda_llama_servers killed nothing and a non-systemd `model use` server
#   survived to make the VRAM census refuse every run as an unlisted holder.  The
#   collector asks nvidia-smi first and falls back to /proc/PID/exe (same build-opencl
#   exclusion), and the reaper now REFUSES to run under AUTOTUNE_SELFTEST=1 — without
#   that guard a selftest would reap the live lanes the fallback just made visible.
#   v36 (2026-11-05): __llm_thread_cap takes the ceiling from the HOST PROFILE
#   (LLAMA_THREAD_CAP), not a repo constant.  It returned 6 on every box, so a 20-core
#   arm64 host launched every model — and measured all 30 autotune rows — at 6 threads
#   while its profile asked for 10.  Intel declares 6 (its 6 P-cores); a homogeneous
#   box declares 0 = no ceiling; an unrecognised value still falls back to 6.  The
#   holder report also names the LEAF unit (the old head -1 printed user@1000.service).
#   v33 (2026-11-02): the lane's new stderr writes go through one `warn` helper and one status
#   line is wrapped — the §18.3 10.7 and 8.1.8 shapes its commits added, fixed at source rather
#   than re-baselined.
#   v32 (2026-11-02): the KEEP-lane note was factually wrong, and it is why the baseline
#   refusal looked like a sweep bug.  It justified sparing the embedding lane with
#   "evicting it to free ~0.5 GB" while that lane holds 4094 MiB, and claimed the baseline
#   tolerance "already absorbs" it while the host profile tolerates 3500.  The arithmetic
#   is now recorded next to the code that depends on it, and the unresolved trade-off
#   (tolerate a contended baseline, or stand the lane down and risk leaving memory search
#   dark) is named on card AUTOTUNE-BASELINE-002.  No behaviour change.
#   v31 (2026-11-02): __llm_stand_down_cuda_lanes — the PROTECTED declared lanes made the
#   autotune VRAM baseline unreachable on a box whose lane holds the CUDA card.  Measured
#   `model autotune 2`: "28099 MiB still held", because llama-cuda-qwen3coder-30b-chat.service
#   was serving at :18087 with -ngl 99 and __llm_kill_cuda_llama_servers spares every declared
#   lane by design.  The retune wrapper has stood its lane down since 2026-09-15; the direct
#   entry point never did, so it could only ever refuse.  The sweep keeps sparing lanes —
#   this helper stops them deliberately, and only when they actually hold CUDA memory.
#   v30 (2026-11-01): bench_*.tsv discovery reads $LLM_STATE_DIR (the tool-state home).
#   v29 (2026-10-30): on a UNIFIED-MEMORY host the sizing ceiling is physical RAM, not
#   the card's reported figure (81920 MiB reported against 39 GiB of RAM, measured on
#   the arm64 box) — the profile declares TAC_HOST_PROFILE_SHARED_MEMORY and the
#   helper clamps to /proc/meminfo MemTotal, measured rather than invented.
#   v28 (2026-10-29): the CUDA cleanup protects every lane the HOST PROFILE
#   declares instead of three unit names written here, so a lane added to this box
#   (or named differently on another) is still never evicted by a bench cleanup.
#   v27 (2026-10-28): model sizing asks the CARD for its VRAM total
#   (__tac_vram_total_bytes, cached per shell) instead of trusting the 4 GiB
#   constant.  On a larger card — including an arm64 CUDA box — every model that
#   actually fits was recorded CPU-only, and the launch hint was wrong.  The
#   constant remains the stated fallback when the driver cannot be read.
#   v26 (2026-10-16): __llm_train_lane_holder requires the runner to be the SCRIPT the
#   interpreter was GIVEN — the argv element immediately after an interpreter — instead of
#   any element that merely names the path.  Measured 2026-10-16: a CI lint job's file list
#   (`bash tools/lint.sh --files … bin/train-timeout-runner.sh …`) arrives as SEPARATE argv
#   elements, so the any-element scan read that job as a training tenant and halted a
#   10-row autotune after 9 s, on a card reading 0 MiB.  bin/gpu-busy.sh's
#   _process_executes carries the same rule.
#   v25 (2026-10-02): adds __llm_train_lane_holder / __llm_train_lane_busy — the
#   console-side read of a supervised GPU TRAINING run (card UBC-GRPO-002). The
#   runner claims the card exactly as a bench does, but the lock file cannot say
#   WHICH lane holds it; `oc health` and the autotune batch both need the name so a
#   training run is visible and is not mistaken for a stuck lane.
# ==============================================================================
# 11d-llm-gpu — GPU status, GGUF metadata, calculations
# ==============================================================================
# @modular-section: llm-manager
# @depends: constants, design-tokens, ui-engine, hooks, telemetry, llm-server
# @exports: wake, gpu-status, gpu-check, __gguf_metadata, __calc_gpu_layers,
#   __gpu_layers_fit, __calc_ctx_size, __calc_threads, __quant_label, __tac_cleanup_stale_locks,
#   __gpu_clear_stale_processes, __llm_kill_cuda_llama_servers,
#   __llm_stand_down_cuda_lanes, __llm_vram_holder_report,
#   __llm_gpu_lock_path, __llm_gpu_lock_holder, __llm_gpu_foreign_owner,
#   __llm_train_lane_holder

# Idempotent include guard: sub-modules are sourced both by their thin
# loader and directly by the profile/env loaders, so run the body once.
[[ -n "${__TAC_MOD_11D_LLM_GPU_LOADED:-}" ]] && return 0
__TAC_MOD_11D_LLM_GPU_LOADED=1

# Design-token colours, assigned by 03-design-tokens.sh at source time (as
# `readonly`).  Naming them here replaces the file-wide `disable=SC2154` this
# module used to carry: shellcheck lints each module in isolation and cannot see
# an assignment made by a sibling, so the module declares what it consumes
# (docs/inspection.md 17.1 — remove the disable and fix the cause).
# `:=` assigns ONLY when the variable is unset, so this is a runtime no-op, and
# it is safe against the `readonly` in 03 — a plain C_Dim="$C_Dim" would abort.
: "${C_Text:=}"
: "${C_Reset:=}"
: "${C_Dim:=}"
: "${C_Warning:=}"
: "${C_Error:=}"
: "${C_Success:=}"
: "${C_Highlight:=}"

function __tac_cleanup_stale_locks() {
    local _c_lock _c_pid _c_kf _c_sp _c_my_pid _c_ppid _c_cmd _c_owner
    local _c_fd_path _c_keeper_dir
    local -a _c_live_model_shells=()

    # /proc/PID/cwd is ALREADY canonical (no trailing slash, symlinks resolved),
    # so comparing it to a raw LLM_KEEPER_DIR that has a trailing slash or is a
    # symlinked path would never match, and the keeper guards below would
    # silently reap nothing. Normalise the comparison target once.
    _c_keeper_dir=$(realpath -m -- "${LLM_KEEPER_DIR:-/tmp}" 2>/dev/null || printf '%s' "${LLM_KEEPER_DIR:-/tmp}")

    # Track currently live model-shell wrappers so we do not kill keepers that
    # still belong to an active model session.
    local _c_ms_kf _c_ms_pid
    for _c_ms_kf in "${LLM_MODELSHELL_PID_DIR:-/tmp}"/llm-modelshell.*.pid \
                    "${LLM_MODELSHELL_PID_DIR:-/tmp}"/llm-modelshell.pid
    do
        [[ -f "$_c_ms_kf" ]] || continue
        _c_ms_pid=$(cat "$_c_ms_kf" 2>/dev/null || true)
        if [[ "$_c_ms_pid" =~ ^[0-9]+$ ]] && kill -0 "$_c_ms_pid" 2>/dev/null
        then
            _c_live_model_shells+=("$_c_ms_pid")
        fi
    done

    # bench lock + pid — also check custom paths used by non-default configs
    local _c_lock_candidates
    _c_lock_candidates=(
        "${LLM_BENCH_LOCK_FILE:-/tmp/llm-bench.lock}"
        "${LLM_AUTOTUNE_LOCK_FILE:-/tmp/llm-autotune.lock}"
    )
    for _c_lock in "${_c_lock_candidates[@]}"
    do
        [[ -f "$_c_lock" ]] || continue
        # The flock lives on the never-unlinked <lock>.mutex; the lock path is
        # the PID marker.  Probe the MUTEX first: a live holder must keep its
        # marker even though nobody has the marker file open (the old lsof test
        # assumed the marker was the flocked file and would delete a live one).
        local _c_lock_fd="" _c_lock_held=0
        if command -v flock >/dev/null 2>&1
        then
            # swallow-ok: an unopenable mutex is not an error; the PID fallback below decides
            if exec {_c_lock_fd}>"${_c_lock}.mutex" 2>/dev/null
            then
                # swallow-ok: a failed non-blocking probe IS the "held" answer read on the next line
                if ! flock -n "$_c_lock_fd" 2>/dev/null
                then
                    _c_lock_held=1
                fi
                exec {_c_lock_fd}>&-
            fi
        fi
        (( _c_lock_held )) && continue
        # cat, not the $(<file) builtin: the `2>/dev/null || true` tail turns
        # a bare redirection into a command-less one (SC2188), and the
        # failure path is wanted. The rest of this module already reads this
        # way.
        _c_pid=$(cat "$_c_lock" 2>/dev/null || true)
        if [[ -z "$_c_pid" ]] || ! kill -0 "$_c_pid" 2>/dev/null
        then
            rm -f "$_c_lock"
        fi
    done

    # bench PID file — check custom path too
    local _c_pid_file="${LLM_BENCH_PID_FILE:-/tmp/llm-bench.pid}"
    local _c_bench_active=0
    if [[ -f "$_c_pid_file" ]]
    then
        _c_pid=$(cat "$_c_pid_file" 2>/dev/null || true)
        if [[ -z "$_c_pid" ]] || ! kill -0 "$_c_pid" 2>/dev/null
        then
            rm -f "$_c_pid_file"
        else
            _c_bench_active=1
        fi
    fi

    # Bench lock ownership is cooperative: the lock file stores owner PID.
    # Treat bench as active only when that owner PID is alive. An orphaned
    # child can keep the lock file open without owning a valid bench session.
    local _c_bench_lock="${LLM_BENCH_LOCK_FILE:-/tmp/llm-bench.lock}"
    if [[ -f "$_c_bench_lock" ]]
    then
        local _c_lock_owner
        _c_lock_owner=$(cat "$_c_bench_lock" 2>/dev/null || true)
        if [[ "$_c_lock_owner" =~ ^[0-9]+$ ]] && kill -0 "$_c_lock_owner" 2>/dev/null
        then
            _c_bench_active=1
        fi
    fi

    # orphaned stdin keepers: only processes actually holding a /tmp/llm-stdin.*
    # FIFO open (fd-based). `find -lname` resolves the fd symlinks in C — a
    # per-fd bash readlink loop over /proc is ~400x slower on WSL. A shell that
    # merely MENTIONS "llm-stdin" on its command line is never a target, and a
    # live session's server/keeper is spared by the parent-ownership guard. self
    # is skipped.
    _c_my_pid=$$
    while IFS= read -r _c_fd_path
    do
        [[ -n "$_c_fd_path" ]] || continue
        _c_sp="${_c_fd_path#/proc/}"
        _c_sp="${_c_sp%%/*}"
        [[ "$_c_sp" =~ ^[0-9]+$ ]] || continue
        [[ "$_c_sp" == "$_c_my_pid" ]] && continue
        # Only kill true orphans: a live keeper/server has a live model-shell
        # parent, so it belongs to an active model run in some other shell.
        _c_ppid=$(ps -o ppid= -p "$_c_sp" 2>/dev/null | tr -d '[:space:]')
        if [[ -n "$_c_ppid" && "$_c_ppid" != "1" ]] \
           && [[ " ${_c_live_model_shells[*]:-} " == *" $_c_ppid "* ]]
        then
            continue
        fi
        kill -TERM "$_c_sp" 2>/dev/null || true
    done < <(find /proc/[0-9]*/fd -lname '*llm-stdin*' 2>/dev/null || true)

    # orphaned bench timeout wrappers (left behind after interrupted runs)
    # Only reap when no active bench owner exists.
    local _c_bp _c_bppid _c_bcmd
    if (( _c_bench_active == 0 ))
    then
        for _c_bp in $(pgrep -af '__BENCH_MODE=1' 2>/dev/null | awk '{print $1}' || true)
        do
            [[ "$_c_bp" =~ ^[0-9]+$ ]] || continue
            _c_bppid=$(ps -o ppid= -p "$_c_bp" 2>/dev/null | tr -d '[:space:]')
            _c_bcmd=$(ps -o args= -p "$_c_bp" 2>/dev/null || true)
            if [[ "$_c_bcmd" == *"__BENCH_MODE=1"* ]] && [[ "$_c_bppid" != "$$" ]]
            then
                kill -TERM "$_c_bp" 2>/dev/null || true
                sleep 1
                kill -KILL "$_c_bp" 2>/dev/null || true
            fi
        done
    fi

    # orphaned keeper PID files. The directory is env-overridable so tests can
    # sandbox it; the default keeps production on /tmp.
    #
    # The PID file holds the keeper SUBSHELL (`{ sleep 3600; } &`), whose argv is
    # inherited from the model shell — so it never reads "sleep 3600". Identify
    # it by its cwd (the keeper `cd`s to LLM_KEEPER_DIR) and decide ownership
    # from its PARENT, which is the model-shell wrapper for a live session.
    for _c_kf in "${LLM_KEEPER_DIR:-/tmp}"/llm-keeper.*.pid
    do
        [[ -f "$_c_kf" ]] || continue
        local _c_remove_kf=1
        _c_pid=$(cat "$_c_kf" 2>/dev/null || true)
        if [[ "$_c_pid" =~ ^[0-9]+$ ]] && kill -0 "$_c_pid" 2>/dev/null
        then
            # Identity guard against PID reuse: only a keeper has this cwd.
            if [[ "$(readlink "/proc/$_c_pid/cwd" 2>/dev/null || true)" == "$_c_keeper_dir" ]]
            then
                _c_ppid=$(ps -o ppid= -p "$_c_pid" 2>/dev/null | tr -d '[:space:]')
                if [[ -n "$_c_ppid" && "$_c_ppid" != "1" ]] \
                   && [[ " ${_c_live_model_shells[*]:-} " == *" $_c_ppid "* ]]
                then
                    # Live non-orphan keeper: keep its PID file so active
                    # model-stop flows still have the right target.
                    _c_remove_kf=0
                else
                    kill -TERM "$_c_pid" 2>/dev/null || true
                fi
            fi
        fi
        (( _c_remove_kf == 1 )) && rm -f "$_c_kf"
    done

    # Fallback: if a keeper lost its PID file, reap any remaining sleep-loop
    # helpers that are no longer attached to a live model shell. Scoped to THIS
    # directory via /proc/PID/cwd, so an unrelated `sleep 3600` is never killed.
    #
    # The matched process is the keeper's `sleep 3600`, whose parent is the
    # keeper subshell and whose GRANDparent is the model-shell wrapper — the
    # only PID the live list contains. Compare the grandparent, not the parent.
    while IFS= read -r _c_line
    do
        [[ -n "$_c_line" ]] || continue
        _c_sp=${_c_line%% *}
        _c_cmd=${_c_line#* }
        [[ "$_c_sp" =~ ^[0-9]+$ ]] || continue
        [[ "$_c_cmd" == *"sleep 3600"* ]] || continue
        [[ "$(readlink "/proc/$_c_sp/cwd" 2>/dev/null || true)" == "$_c_keeper_dir" ]] || continue
        _c_ppid=$(ps -o ppid= -p "$_c_sp" 2>/dev/null | tr -d '[:space:]')
        if [[ -n "$_c_ppid" && "$_c_ppid" != "1" ]]
        then
            _c_owner=$(ps -o ppid= -p "$_c_ppid" 2>/dev/null | tr -d '[:space:]')
        else
            _c_owner=""
        fi
        if [[ -z "$_c_owner" ]] || [[ "$_c_owner" == "1" ]] \
           || ! [[ " ${_c_live_model_shells[*]:-} " == *" $_c_owner "* ]]
        then
            kill -TERM "$_c_sp" 2>/dev/null || true
        fi
    done < <(pgrep -af 'sleep 3600' 2>/dev/null || true)

    return 0
}

# ---------------------------------------------------------------------------
# __llm_json_escape — Escape a string for safe inline JSON output.
# @returns 0 always.

# ---------------------------------------------------------------------------
# __gpu_stale_context_verdict <comm> <leaf_unit> <age_s> — may this pid be killed?
#
# A python process holding a CUDA context is "stale" only when nothing owns it:
#   * not a llama-server — the lanes and servers are reaped by their own helpers,
#     never by this name sweep;
#   * in NO named .service.  A unit owns its processes: a lane, a CI job, an
#     agent's transient run, a foreign pipeline.  Measured 2026-11-06: another
#     agent's work lived in the transient unit vexed-uphold-full.service, and an
#     ownership-blind kill took one of its python CUDA processes mid-run;
#   * older than LLM_GPU_STALE_MIN_AGE_S (default 600).  A live run's helper is
#     young, so the age bound keeps the cleanup for what it names: leftovers.
#
# Pure by design — the caller reads comm/unit/age, so every arm is exercised
# without a card, a kill or a systemd unit.
# @returns 0 when the pid may be reaped, 1 when it must be left alone.
# ---------------------------------------------------------------------------
function __gpu_stale_context_verdict() {
    local _comm="${1:-}" _unit="${2:-}" _age="${3:-}"
    local _min_age="${LLM_GPU_STALE_MIN_AGE_S:-600}"
    [[ "$_comm" == *llama* ]] && return 1
    [[ "$_comm" == python* ]] || return 1
    [[ -z "$_unit" ]] || return 1
    [[ "$_age" =~ ^[0-9]+$ ]] || return 1
    (( _age >= _min_age )) || return 1
    return 0
}

# ---------------------------------------------------------------------------
# __gpu_clear_stale_processes — Kill stale Python/CUDA processes holding VRAM.
# Bench/autotune call __model_stop which only kills llama-server. Python
# processes holding CUDA contexts are not cleared, silently consuming VRAM.
# Each candidate is filtered by __gpu_stale_context_verdict before it is killed,
# so a process inside a unit — or one a live run just started — is never a target.
# REF: G-5 audit — VRAM clearing gap
# ---------------------------------------------------------------------------
function __gpu_clear_stale_processes() {
    # Never clear VRAM by killing another run's processes.  This function targets
    # python processes holding a CUDA context, and a foreign owner (the
    # investigator's flock) runs its bench as exactly that: their own
    # _is_own_process docstring says the bench and the assess processes it spawns
    # hold CUDA contexts.  It skips comm matching *llama*, so it was never a
    # candidate for killing their server — but it could kill their bench process
    # mid-run.  Skipping is right here, unlike a lane start, which refuses: this
    # is a cleanup helper, and the caller's VRAM baseline then fails closed.
    if __llm_gpu_foreign_owner
    then
        warn "[gpu-clear] CUDA card owned by another run (pid $(__llm_gpu_lock_holder)) — skipping the stale-process clear"
        return 0
    fi
    local _gpu_pid _keep_pid _keep_pids _stale_wait count=0
    local _gpu_comm _gpu_unit _gpu_age
    _keep_pid="$$"
    _keep_pids=" $PPID $_keep_pid "
    while IFS= read -r _gpu_pid; do
        [[ "$_gpu_pid" =~ ^[0-9]+$ ]] || continue
        [[ "$_keep_pids" == *" $_gpu_pid "* ]] && continue
        _gpu_comm=$(ps -o comm= -p "$_gpu_pid" 2>/dev/null | tr -d '[:space:]')
        [[ -z "$_gpu_comm" ]] && continue
        # swallow-ok: a process that exited since the compute-apps read has no cgroup; the empty unit reads as unowned
        _gpu_unit=$(ps -o cgroup= -p "$_gpu_pid" 2>/dev/null | grep -o '[^/]*\.service' | tail -n 1 || true)
        # swallow-ok: the same exit leaves no age; a non-numeric age is refused by the verdict
        _gpu_age=$(ps -o etimes= -p "$_gpu_pid" 2>/dev/null | tr -d '[:space:]')
        if __gpu_stale_context_verdict "$_gpu_comm" "$_gpu_unit" "$_gpu_age"
        then
            kill -TERM "$_gpu_pid" 2>/dev/null || true
            # Graceful wait (WSL2 dxgkrnl): SIGKILL orphans the process's CUDA
            # handles; poll up to 15s for a clean exit before escalating.
            _stale_wait=0
            while kill -0 "$_gpu_pid" 2>/dev/null && (( _stale_wait < 15 )); do
                sleep 1; _stale_wait=$((_stale_wait + 1))
            done
            if kill -0 "$_gpu_pid" 2>/dev/null; then
                kill -KILL "$_gpu_pid" 2>/dev/null || true
            fi
            count=$((count + 1))
        fi
    done < <(nvidia-smi --query-compute-apps=pid --format=csv,noheader 2>/dev/null || true)
    if (( count > 0 )); then
        __tac_info "VRAM" "killed ${count} stale GPU process(es)" "$C_Warning"
    fi
}

# ---------------------------------------------------------------------------
# __llm_gpu_lock_path / __llm_gpu_lock_holder / __llm_gpu_foreign_owner
#
# The investigator pipeline holds a cross-process GPU flock for the whole
# duration of a local-model run (pipeline/gpu/_lock.py, claimed by
# pipeline/gpu/_exclusive.py) and stops the watchdog + CUDA lanes while it
# holds it.  Nothing on the console side honoured that lock, so this module's
# cleanup evicted another agent's in-flight run whenever the two overlapped
# (BENCH-GPU-EXCLUSIVITY-001 — the exclusivity-bridge gap).
#
# Path precedence mirrors config/paths.gpu_lock_path() exactly, including its
# env overrides, so the console and the investigator always agree on the file:
#   $INVESTIGATOR_GPU_LOCK, else
#   $INVESTIGATOR_PRODUCTION_OUTPUT/runtime/gpu.lock, else
#   $HOME/investigator/production/runtime/gpu.lock
#
# The probe is EXISTENCE-GATED deliberately: `flock -n` also fails when the
# path does not exist, so reading a failed probe as "held" would refuse every
# run on a box where the investigator has never taken the lock.  A lock file
# that exists but cannot be probed fails closed (see the caller's log line).
# ---------------------------------------------------------------------------
function __llm_gpu_lock_path() {
    printf '%s\n' \
        "${INVESTIGATOR_GPU_LOCK:-${INVESTIGATOR_PRODUCTION_OUTPUT:-$HOME/investigator/production}/runtime/gpu.lock}"
}

function __llm_gpu_lock_holder() {
    local _lock_path
    _lock_path=$(__llm_gpu_lock_path)
    [[ -r "$_lock_path" ]] || return 0
    tr -dc '0-9' < "$_lock_path" 2>/dev/null || true
}

# Returns 0 when a FOREIGN process holds the GPU lock, 1 when the card is free.
function __llm_gpu_foreign_owner() {
    local _lock_path
    _lock_path=$(__llm_gpu_lock_path)
    [[ -e "$_lock_path" ]] || return 1
    if flock -n "$_lock_path" -c true 2>/dev/null
    then
        return 1   # we took it, so nobody else holds it
    fi
    return 0
}

# ---------------------------------------------------------------------------
# __llm_train_lane_holder / __llm_train_lane_busy
#
# A supervised GPU TRAINING run (card UBC-GRPO-002) claims the CUDA card exactly
# as a bench does — bin/train-timeout-runner.sh takes the bench lock
# ($LLM_BENCH_LOCK_FILE) for the whole run — but the lock file alone cannot say
# WHICH lane holds it.  The console needs that name for the two things the card's
# console-side acceptance asks for: a training run must be visible in the health
# view (`oc health`), and a second heavy job must be able to refuse up front with
# a reason instead of waiting out the bench-lock timeout and failing a row after
# a wasted spawn.
#
# The identity is the EXECUTING artefact, never a word: some process must be
# RUNNING bin/train-timeout-runner.sh itself.  A shell that merely MENTIONS the
# name — a `grep`, an editor, a `cat` of this file — is not a tenant.  That is the
# false-BUSY defect bin/gpu-busy.sh records three times over, and here a false
# BUSY would refuse a bench run on a free card.  bin/gpu-busy.sh carries the same
# rule for the watchdog path; the two copies are pinned together by a drift test
# in tests/unit/12-gpu-exclusivity.bats, because this module is sourced by the
# console while gpu-busy.sh is a standalone script that must not depend on this
# tree (the duplication is deliberate, as the investigator-lock path already is).
# ---------------------------------------------------------------------------
function __llm_train_lane_holder() {
    local _pid _exe_base _elem _prev _is_interp _i
    local -a _argv=()
    # pgrep only SELECTS candidates by command line; each is then proved to be
    # EXECUTING the runner.  A bash child of a runner still matches, and that is
    # correct: it is part of the same tenant.
    while IFS= read -r _pid; do
        [[ "$_pid" =~ ^[0-9]+$ ]] || continue
        # swallow-ok: a process gone between pgrep and here has no exe; the checks below decide
        _exe_base=$(readlink -f "/proc/$_pid/exe" 2>/dev/null || true)
        _exe_base="${_exe_base##*/}"
        if [[ "$_exe_base" == "train-timeout-runner.sh" ]]; then
            printf '%s\n' "$_pid"
            return 0
        fi
        # Only an INTERPRETER carries the script path in argv (how every console
        # script is invoked: `bash bin/train-timeout-runner.sh …`).  For any other
        # exe an argv element that merely NAMES the runner is a reader — a
        # `tail -f`, a `grep` — not a tenant.  bin/gpu-busy.sh gates argv behind
        # the same interpreter list; the drift test pins the two together.
        _is_interp=0
        case "$_exe_base" in
            bash|sh|dash|zsh|ksh|ash|busybox) _is_interp=1 ;;
            python|python[0-9]*|perl|perl5*|ruby) _is_interp=1 ;;
            sudo|doas|su|env|runuser|systemd-run) _is_interp=1 ;;
            *) _is_interp=0 ;;
        esac
        (( _is_interp )) || continue
        # swallow-ok: a vanished process has no cmdline, and its absence is the answer checked
        mapfile -d '' -t _argv < "/proc/$_pid/cmdline" 2>/dev/null || true
        # The runner must be the SCRIPT the interpreter was GIVEN — the argv element
        # that immediately FOLLOWS an interpreter — not any slot that merely NAMES the
        # path.  Measured 2026-10-16: a CI lint job runs
        # `bash tools/lint.sh --files … bin/autotune-rows.sh … bin/train-timeout-runner.sh …`,
        # and its file list arrives as SEPARATE argv elements, so it names the runner
        # without executing it — yet the any-element scan below read that job as a
        # training tenant and halted a 10-row autotune after 9 s on a card reading
        # 0 MiB.  Requiring the element after an interpreter keeps the real invocation
        # (`bash bin/train-timeout-runner.sh …`, and through `sudo`/`env` wrappers,
        # where the element after the wrapper IS the script) and drops the reader.
        for (( _i = 1; _i < ${#_argv[@]}; _i++ )); do
            _elem="${_argv[_i]}"
            [[ "$_elem" == *[[:space:]]* ]] && continue
            [[ "${_elem##*/}" == "train-timeout-runner.sh" ]] || continue
            _prev="${_argv[_i-1]}"
            # The interpreter list is the whole of what can EXECUTE a script, so the
            # match arm is the only one carrying an action; anything else is not a tenant.
            case "${_prev##*/}" in
                bash|sh|dash|zsh|ksh|ash|busybox|python|python[0-9]*|perl|perl5*|ruby|\
                sudo|doas|su|env|runuser|systemd-run)
                    printf '%s\n' "$_pid"
                    return 0 ;;
                *) ;;
            esac
        done
    # swallow-ok: pgrep's non-zero exit means no candidate matched — the "no tenant" answer
    done < <(pgrep -f '/train-timeout-runner\.sh' 2>/dev/null)
    return 1
}

# ---------------------------------------------------------------------------
# __llm_cuda_server_pids — candidate CUDA llama-server PIDs, one per line.
#
# nvidia-smi's compute-app list is the precise source and is used whenever it
# answers.  It is EMPTY on this WSL2 box even at 73 GiB used (measured 2026-11-05),
# so a cleanup that trusted it alone killed nothing, and a non-systemd server (a
# `model use` on :8081) survived to make the VRAM census refuse every measurement
# with an unlisted holder.  When nvidia-smi EXISTS but lists nothing, attribute
# from the PROCESS TABLE by /proc/PID/exe — the same test, so the Xe fleet
# (build-opencl) stays out of scope.  A box with NO nvidia-smi still returns
# nothing: no attribution is better than a name sweep.
# ---------------------------------------------------------------------------
function __llm_cuda_server_pids() {
    local _smi _pid _d _exe
    local -a _listed=()
    # swallow-ok: a missing nvidia-smi selects the /proc fallback below, which is the intended answer
    _smi=$(command -v nvidia-smi 2>/dev/null || true)
    if [[ -n "$_smi" ]]
    then
        while read -r _pid
        do
            [[ "$_pid" =~ ^[0-9]+$ ]] && _listed+=("$_pid")
        # swallow-ok: an unreadable compute-app list leaves _listed empty, which selects the /proc fallback below
        done < <("$_smi" --query-compute-apps=pid --format=csv,noheader,nounits 2>/dev/null || true)
        if (( ${#_listed[@]} > 0 ))
        then
            printf '%s\n' "${_listed[@]}"
            return 0
        fi
    fi
    # The /proc walk is the SHARED helper (bin/_tac-bin-lib.sh, sourced by the
    # bin/ scripts): two copies of this rule had already drifted, and the Xe
    # exclusion must be the same everywhere.
    if declare -f _tac_cuda_server_pids >/dev/null 2>&1
    then
        _tac_cuda_server_pids
        return 0
    fi
    for _d in /proc/[0-9]*
    do
        # swallow-ok: a process that exits mid-scan has no exe link; it is not a candidate
        _exe="$(readlink -f "$_d/exe" 2>/dev/null)" || continue
        case "$_exe" in
            */llama.cpp/build-opencl*/bin/llama-server|*/build-cpu*/bin/llama-server) continue ;;
            */llama.cpp/build*/bin/llama-server) printf '%s\n' "${_d#/proc/}" ;;
            *) ;;   # any other executable: not a candidate
        esac
    done
}

# ---------------------------------------------------------------------------
# __llm_kill_cuda_llama_servers — Kill ONLY CUDA-held llama.cpp processes.
#
# Two-card machine: the Xe fleet server (llama-xe-minicpm5-1b-chat.service, :18081) and
# the embed server (llama-xe-embeddinggemma-embed.service, :18080) run the SAME
# llama-server binary on the Intel Xe via OpenCL as every CUDA server.  A
# name-based pkill (pkill -x/-f llama-server) therefore collateral-kills the
# Xe fleet even though it holds NO CUDA VRAM.  This helper kills only
# llama.cpp processes that hold a CUDA compute context
# (nvidia-smi --query-compute-apps) and, as a second guard, excludes the
# MainPIDs of the persistent llama systemd units (a live NVIDIA unit must
# never be evicted by an autotune/bench cleanup either).
#
# Prints nothing on stdout (bench harnesses parse it); warnings go to stderr.
# ---------------------------------------------------------------------------
function __llm_kill_cuda_llama_servers() {
    local _unit _svc_pid _pid _exe _smi _skip _p _llm_wait _alive
    local -a _protected=() _cuda_pids=() _kill_pids=()

    # A SELFTEST must not touch live state.  Its canned engine never launches a
    # server and its cases run on a box whose real lanes ARE serving; with the /proc
    # fallback below, an unguarded selftest would reap the live embedding lane and
    # the operator's model (measured 2026-11-05).  The suite's own kill path is
    # exercised through __llm_cuda_server_pids, never through this reaper.
    if [[ "${AUTOTUNE_SELFTEST:-0}" == "1" ]]
    then
        warn "[llm-kill] selftest — not touching live CUDA servers"
        return 0
    fi

    # Never evict another agent's in-flight run.  When the investigator holds
    # the GPU lock the card belongs to that run and its llama-server is not
    # ours to reap; the autotune VRAM gate then refuses the row, so a batch
    # fails closed instead of stealing the card out from under a bench.
    if __llm_gpu_foreign_owner
    then
        warn "[llm-kill] GPU lock held by another agent's run (pid $(__llm_gpu_lock_holder)) — skipping CUDA llama cleanup"
        return 0
    fi

    # Protected: MainPIDs of the persistent llama systemd units — every lane the
    # HOST PROFILE declares, because a lane list written here would protect no lane
    # on a box whose lanes are named differently.
    while IFS='|' read -r _unit _port
    do
        [[ -n "$_unit" ]] || continue
        _svc_pid=$(systemctl --user show -p MainPID --value "$_unit" 2>/dev/null | tr -d ' \n' || true)
        if [[ "$_svc_pid" =~ ^[0-9]+$ ]] && (( _svc_pid > 0 ))
        then
            _protected+=("$_svc_pid")
        fi
    done <<< "${LLAMA_LANE_SPECS:-}"

    # CUDA attribution: the shared collector asks nvidia-smi first and falls back to
    # /proc/PID/exe when it lists nothing (WSL2 dxgkrnl — measured 2026-11-05).  A box
    # with NO nvidia-smi still kills nothing: no attribution beats a name sweep, which
    # would reintroduce the Xe collateral this helper exists to prevent.
    _smi=$(command -v nvidia-smi 2>/dev/null || true)
    if [[ -z "$_smi" ]]
    then
        echo "[llm-kill] nvidia-smi unavailable — skipping llama cleanup (no CUDA attribution)" >&2
        return 0
    fi
    while read -r _pid
    do
        [[ "$_pid" =~ ^[0-9]+$ ]] || continue
        # Scope by the EXECUTABLE, never by comm (corrected 2026-09-14).
        # /proc/PID/comm is the INVOKED name, truncated to 15 bytes: the CUDA
        # lane (a symlink launcher) reads "cuda-llama-serv", while the Xe fleet
        # reads "xe-llama-server" and "xe-llama-embed" — all three contain
        # "llama", so ANY comm substring match evicts the Xe fleet this helper
        # exists to leave alone.  The executable distinguishes the builds
        # instead: the CUDA trees vs build-opencl.
        _exe=$(readlink -f "/proc/$_pid/exe" 2>/dev/null || echo "")
        case "$_exe" in
            */llama.cpp/build-opencl*/bin/llama-server|*/build-cpu*/bin/llama-server)
                continue ;;   # the Xe / CPU fleet — never touched
            */llama.cpp/build*/bin/llama-server)
                _cuda_pids+=("$_pid") ;;
            *)
                continue ;;
        esac
    done < <(__llm_cuda_server_pids)

    if [[ ${#_cuda_pids[@]} -eq 0 ]]
    then
        return 0
    fi

    for _pid in "${_cuda_pids[@]}"
    do
        _skip=0
        for _p in "${_protected[@]:-}"
        do
            [[ "$_pid" == "$_p" ]] && { _skip=1; break; }
        done
        (( _skip == 0 )) && _kill_pids+=("$_pid")
    done

    if [[ ${#_kill_pids[@]} -gt 0 ]]
    then
        echo "[llm-kill] killing CUDA llama-server PIDs: ${_kill_pids[*]}" >&2
        kill -TERM "${_kill_pids[@]}" 2>/dev/null || true
        # Graceful wait (WSL2 dxgkrnl): SIGKILL orphans the servers' CUDA
        # handles; poll up to 15s for a clean exit before escalating.
        _llm_wait=0
        while (( _llm_wait < 15 )); do
            _alive=0
            for _pid in "${_kill_pids[@]}"; do
                if kill -0 "$_pid" 2>/dev/null; then _alive=1; break; fi
            done
            (( _alive == 0 )) && break
            sleep 1; _llm_wait=$((_llm_wait + 1))
        done
        for _pid in "${_kill_pids[@]}"
        do
            if kill -0 "$_pid" 2>/dev/null
            then
                kill -KILL "$_pid" 2>/dev/null || true
            fi
        done
    fi
}

# ---------------------------------------------------------------------------
# __llm_vram_holder_report — name what is holding the card, one line per CUDA process.
#
# The autotune's refusal said only "28099 MiB still held".  An operator reading that has
# to go and run nvidia-smi to learn which unit — and the answer, on this box, is a unit
# the sweep deliberately spared, so the refusal's own cause is invisible from the message.
#
# The LIST comes from __llm_cuda_server_pids (compute-apps when it answers, the process
# table by /proc/PID/exe when it does not), NOT from compute-apps alone.  Measured
# 2026-11-06: a refusal that named its unlisted holder through the census printed an
# empty "Held by:" block, because this function read the one source this host leaves
# empty — the same blindness v37 fixed in the reaper and the census already worked
# around.  nvidia-smi still supplies the per-process MiB when it can attribute one.
# Prints to stdout for the caller to embed; empty when nothing holds the card.
# ---------------------------------------------------------------------------
function __llm_vram_holder_report() {
    local _smi _pid _mib _unit _exe _pairs=" "
    # swallow-ok: a missing nvidia-smi only removes the per-process MiB figures; the holder list comes from the process scan below
    _smi=$(command -v nvidia-smi 2>/dev/null || true)
    if [[ -n "$_smi" ]]
    then
        while IFS=',' read -r _pid _mib
        do
            _pid=$(printf '%s' "${_pid:-}" | tr -d ' ')
            _mib=$(printf '%s' "${_mib:-}" | tr -d ' ')
            [[ "$_pid" =~ ^[0-9]+$ ]] || continue
            # This host reports [N/A] for per-process memory (WSL2 dxgkrnl); carry the
            # figure only when it is a number, so a line never shows a placeholder.
            case "$_mib" in ''|*[!0-9]*) continue ;; esac
            _pairs+="$_pid:$_mib "
        # swallow-ok: an unreadable compute-apps list only costs the MiB figure; the scan below still names every holder
        done < <("$_smi" --query-compute-apps=pid,used_gpu_memory --format=csv,noheader,nounits 2>/dev/null || true)
    fi
    while IFS= read -r _pid
    do
        [[ "$_pid" =~ ^[0-9]+$ ]] || continue
        _mib=""
        case "$_pairs" in
            *" $_pid:"*) _mib="${_pairs##* "$_pid:"}"; _mib="${_mib%% *}" ;;
            *) ;;
        esac
        # The LEAF .service: the first match is the user manager
        # (user@1000.service), measured 2026-11-05 in a real refusal.
        # swallow-ok: a process that exited since the scan has no cgroup to name
        _unit=$(ps -o cgroup= -p "$_pid" 2>/dev/null | grep -o '[^/]*\.service' | tail -n 1 || true)
        # swallow-ok: the same exit leaves no exe to name
        _exe=$(readlink -f "/proc/$_pid/exe" 2>/dev/null || true)
        printf '  pid %s  %s%s  %s\n' \
            "$_pid" "${_mib:+${_mib} MiB  }" "${_unit:-no-unit}" "${_exe:-unknown-exe}"
    done < <(__llm_cuda_server_pids)
}

# ---------------------------------------------------------------------------
# __llm_stand_down_cuda_lanes — stop the host profile's OWN declared lanes when they
# hold CUDA memory, so an autotune/bench can take the whole card.
#
# Why this is not part of __llm_kill_cuda_llama_servers: that sweep must never reap a
# systemd-managed unit (a restart storm, and a lane may be serving a user), so it SPARES
# every lane in LLAMA_LANE_SPECS.  The sparing is right and it also makes the VRAM
# baseline unreachable whenever a declared lane is a CUDA lane — measured 2026-11-02,
# `model autotune 2` refused with 28099 MiB still held while
# llama-cuda-qwen3coder-30b-chat.service served :18087 with -ngl 99.  Standing a lane
# down for a benchmark is a DELIBERATE act and belongs at the caller, with its own
# message.  A foreign owner's run is never touched: the lock check comes first.
#
# warn — one stderr channel for this file's operator messages. §18.3 10.7 counts a
# hand-written `>&2` per site; a helper keeps new lines off that count and gives the
# messages one shape.
warn() { printf '%s\n' "$*" >&2; }

# The lanes THIS run stood down, so __llm_restore_stopped_lanes can put them back.  Declared
# here rather than inside the function: both the recorder and the restorer are file-scope.
__LLM_LANES_STOPPED=()

# Prints one line per lane stopped.  Always returns 0 — the caller's VRAM baseline gate is
# the thing that decides whether the card is clear, and it fails closed.
# ---------------------------------------------------------------------------
function __llm_stand_down_cuda_lanes() {
    if __llm_gpu_foreign_owner
    then
        warn "[lanes] card owned by another run (pid $(__llm_gpu_lock_holder)) — leaving the lanes alone"
        return 0
    fi
    # A SELFTEST must not touch live state — the rule v37 gave the reaper, for the same
    # reason: the /proc fallback below makes the live lanes VISIBLE, and standing one
    # down to satisfy a canned run is how v103 stopped the production lane twice.
    if [[ "${AUTOTUNE_SELFTEST:-0}" == "1" ]]
    then
        warn "[lanes] selftest — not standing any lane down"
        return 0
    fi
    local _unit _port _pid _waited _smi _mib _keep _cpid
    local -a _cuda_pids=()
    # WHICH LANES HOLD CUDA comes from the shared collector: compute-apps when it
    # answers, the process table by /proc/PID/exe when it does not.  Keyed on
    # compute-apps alone this helper was a SILENT no-op — measured 2026-11-08 23:54 at a
    # 32 GiB carve, that list answered rc=0 with NO rows while the chat lane held
    # 32,331 MiB, so nothing was stood down and the row was refused with
    # "Unlisted holders (declared tenants: …embed.service)" naming a lane whose own
    # profile says it IS stood down for an autotune.
    while IFS= read -r _cpid
    do
        [[ "$_cpid" =~ ^[0-9]+$ ]] || continue
        _cuda_pids+=("$_cpid")
    done < <(__llm_cuda_server_pids)
    # nvidia-smi is still asked for the per-process MiB, which is a message
    # embellishment only (this host answers [N/A]); the attribution is already decided.
    # swallow-ok: a missing nvidia-smi costs the figure, never the attribution above
    _smi=$(command -v nvidia-smi 2>/dev/null || true)
    while IFS='|' read -r _unit _port
    do
        [[ -n "$_unit" ]] || continue
        # A lane the host profile marks as always-on is never stood down: the embedding
        # lane backs memory search, and evicting it would break a different subsystem.
        # The baseline tolerance therefore has to ABSORB it, and did not: measured
        # 2026-11-02, that lane alone holds 4094 MiB on this box (the driver's ~2.9 GiB
        # reservation included), while the profile tolerated 3500 — so every autotune
        # refused by 594 MiB, and the refusal's remedy could not help, because the
        # holder was the lane the same run is told to keep.  Tolerating it by raising the
        # bound is not free either: the same guard exists to refuse a baseline whose TPS
        # would be untrustworthy.  That trade-off is recorded, unresolved, on card
        # AUTOTUNE-BASELINE-002; this comment exists so the next reader does not
        # re-derive it as a bug in the sweep.
        for _keep in ${LLAMA_LANE_KEEP_UNITS:-}
        do
            [[ "$_unit" == "$_keep" ]] && continue 2
        done
        # swallow-ok: is-active exits non-zero for inactive OR unknown; both mean "not ours to stop here"
        systemctl --user is-active --quiet "$_unit" 2>/dev/null || continue
        # swallow-ok: a unit with no MainPID has nothing to stand down
        _pid=$(systemctl --user show -p MainPID --value "$_unit" 2>/dev/null | tr -d ' \n' || true)
        [[ "$_pid" =~ ^[0-9]+$ ]] && (( _pid > 0 )) || continue
        # PRESENCE in the resident CUDA set decides, never a memory figure: on this box
        # (WSL2 dxgkrnl) nvidia-smi reports used_gpu_memory as [N/A] for every PID, and
        # the compute-apps list itself comes back empty.  An Xe/OpenCL lane in the
        # declared list is absent from the set (the collector excludes build-opencl), and
        # a lane whose server is not resident is absent too, so both stay serving.
        case " ${_cuda_pids[*]-} " in
            *" $_pid "*) ;;
            *) continue ;;
        esac
        _mib=""
        if [[ -n "$_smi" ]]
        then
            # swallow-ok: the figure is optional; the decision above is already made
            _mib=$("$_smi" --query-compute-apps=pid,used_gpu_memory --format=csv,noheader,nounits 2>/dev/null \
                | awk -F',' -v p="$_pid" '{gsub(/ /,"",$1); gsub(/ /,"",$2); if ($1+0 == p+0) {print $2; exit}}')
            case "$_mib" in ''|*[!0-9]*) _mib="" ;; esac
        fi
        __tac_info "Lanes" \
            "stopping $_unit (pid $_pid${_mib:+, ${_mib} MiB CUDA}) to clear the VRAM baseline" \
            "$C_Warning"
        # REMEMBER what this run stands down, so it can put it back itself.  Measured
        # 2026-11-10 09:16: the stop escalated to SIGKILL (a request was in flight, so the
        # server outran its stop budget), systemd recorded `failed`, and the watchdog —
        # the only other restorer — DEFERS while a heavy job holds the box, which this run
        # does.  The chat lane therefore stayed down from 09:16:17 until someone looked,
        # with the next watchdog tick up to five minutes away.
        __LLM_LANES_STOPPED+=("$_unit")
        # swallow-ok: a stop that fails is reported by the bounded is-active poll below, which refuses the baseline
        systemctl --user stop "$_unit" 2>/dev/null || true
        _waited=0
        while (( _waited < 60 ))
        do
            # swallow-ok: is-active exits non-zero for inactive OR unknown; both mean "not ours to stop here"
            systemctl --user is-active --quiet "$_unit" 2>/dev/null || break
            sleep 5
            _waited=$((_waited + 5))
        done
        # swallow-ok: is-active exits non-zero for inactive OR unknown; both mean "not ours to stop here"
        if systemctl --user is-active --quiet "$_unit" 2>/dev/null
        then
            warn "[lanes] WARN: $_unit still active after ${_waited}s — the baseline gate will refuse"
        else
            echo "[lanes] stopped $_unit after ${_waited}s${_mib:+ (${_mib} MiB released)}"
        fi
    done <<< "${LLAMA_LANE_SPECS:-}"
    return 0
}

# __llm_restore_stopped_lanes — put back the lanes THIS run stood down.
#
# The stand-down's own caller is the only restorer that can act promptly: the watchdog's
# recover() DEFERS while a heavy job holds the box (LLAMA-LANE-CONTENTION-001), and a
# `model autotune` run IS that heavy job.  So when such a run ends, nothing restarts the
# lane until the next watchdog tick — up to five minutes — and if the stop escalated to
# SIGKILL the unit reads `failed` on top of that.  Measured 2026-11-10 09:16: the chat lane
# sat `failed` from 09:16:17 with /health dead until a hand start, while the watchdog's
# 09:19 tick logged `suspend: NOT HELD` and finished without touching it.
#
# reset-failed FIRST: a SIGKILLed lane is `failed`, and that is exactly the state the
# stop left behind when a request was in flight and the server outran its stop budget.
function __llm_restore_stopped_lanes() {
    local _unit
    (( ${#__LLM_LANES_STOPPED[@]} > 0 )) || return 0
    for _unit in "${__LLM_LANES_STOPPED[@]}"
    do
        # swallow-ok: reset-failed exits non-zero for a unit that is not failed, which is the good case
        systemctl --user reset-failed "$_unit" >/dev/null 2>&1 || true
        if systemctl --user start "$_unit" >/dev/null 2>&1
        then
            warn "[lanes] restored $_unit"
        else
            warn "[lanes] FAILED to restart $_unit — start it by hand: systemctl --user start $_unit"
        fi
    done
    __LLM_LANES_STOPPED=()
    return 0
}

# ---------------------------------------------------------------------------
# wake — lock GPU persistence mode where that is possible, then show the card.
#
# Reading the mode needs no privilege, so it is read FIRST: in the steady state
# it already reads Enabled and the mode never has to be changed.  This used to
# call `sudo -n nvidia-smi -pm 1` unconditionally, so a box without passwordless
# sudo reported `GPU Persistence [FAILED - passwordless sudo required for
# nvidia-smi]` on `model bench` (2026-11-06, this box) for a setting that was
# already on — a sudo requirement invented by the probe, not by the driver.
#
# Only a Disabled reading is escalated, and only that failure is worth a warning:
# it names the one command that fixes it.  An unreadable/N/A mode means the
# driver exposes no persistence switch (a PV guest), so there is nothing to lock
# and the return is 0 — the GPU serves either way.
#
# @returns 0 when persistence is Enabled or not exposed by the driver; 1 when it
#          is Off and could not be turned on.  Every caller treats this as
#          best-effort.
# ---------------------------------------------------------------------------
function wake() {
    local smi_cmd
    smi_cmd=$(__resolve_smi) || {
        __tac_info "GPU" "[nvidia-smi not found]" "$C_Error"
        return 1
    }

    local _pm_mode
    # swallow-ok: an unreadable mode leaves _pm_mode empty, which the case below reports as not-exposed
    _pm_mode=$("$smi_cmd" --query-gpu=persistence_mode --format=csv,noheader 2>/dev/null | head -1 | tr -d ' ')

    case "$_pm_mode" in
        Enabled)
            __tac_info "GPU Persistence" "[ENABLED]" "$C_Success"
            ;;
        Disabled)
            # Try to enable persistence mode; capture output for NVML error detection
            local _pm_output
            _pm_output=$(sudo -n "$smi_cmd" -pm 1 2>&1)
            local _pm_status=$?

            # Check for any NVML initialization failure (common in WSL2 with various driver states)
            if [[ "$_pm_output" == *"Failed to initialize NVML"* ]]
            then
                # NVML unavailable (WSL2/driver limitation) — GPU still works for inference
                return 0
            fi

            # Check for actual failure (sudo denied or other error)
            if (( _pm_status != 0 ))
            then
                if [[ "$_pm_output" == *"password"* || "$_pm_output" == *"sudo"* || "$_pm_output" == *"authentication"* ]]
                then
                    # The setting is Off and only root can change it — name the command
                    # rather than a sudo policy this shell cannot obtain.
                    __tac_info "GPU Persistence" \
                        "[OFF - needs root: sudo $smi_cmd -pm 1]" "$C_Warning"
                else
                    __tac_info "GPU Persistence" "[FAILED - nvidia-smi error: $_pm_output]" "$C_Warning"
                fi
                return 1
            fi

            __tac_info "GPU Persistence" "[ENABLED]" "$C_Success"
            ;;
        *)
            __tac_info "GPU Persistence" \
                "[${_pm_mode:-unreadable} - no persistence switch on this driver]" "$C_Dim"
            ;;
    esac

    local gpu_stat
    gpu_stat=$("$smi_cmd" \
        --query-gpu=utilization.gpu,memory.used,memory.total,temperature.gpu \
        --format=csv,noheader,nounits 2>/dev/null)
    if [[ -n "$gpu_stat" ]]
    then
        local g_util g_used g_total g_temp
        IFS=',' read -r g_util g_used g_total g_temp <<< "$gpu_stat"
        g_util="${g_util// /}"; g_used="${g_used// /}"; g_total="${g_total// /}"; g_temp="${g_temp// /}"
        __tac_info "GPU Util" "${g_util}%" "$C_Text"
        if [[ "${TAC_HOST_PROFILE_SHARED_MEMORY:-0}" == "1" ]]
        then
            local _mem_total_mb=0 _mem_avail_mb=0 _reserve_mb="${LLAMA_FIT_KEEP_RESERVE_MB:-12288}"
            [[ "$_reserve_mb" =~ ^[0-9]+$ ]] || _reserve_mb=12288
            # swallow-ok: unreadable /proc/meminfo falls back to 0 and skips unified budget line
            _mem_total_mb=$(awk '/^MemTotal:/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null) || _mem_total_mb=0
            # swallow-ok: unreadable /proc/meminfo falls back to 0 and skips unified budget line
            _mem_avail_mb=$(awk '/^MemAvailable:/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null) || _mem_avail_mb=0
            __tac_info "GPU Carve" "${g_used} MiB / ${g_total} MiB (NVML)" "$C_Text"
            if (( _mem_total_mb > _reserve_mb ))
            then
                local _budget_mb=$(( _mem_total_mb - _reserve_mb ))
                local _model_avail_mb=$(( _mem_avail_mb > _reserve_mb ? _mem_avail_mb - _reserve_mb : 0 ))
                local _budget_gib _avail_gib
                _budget_gib=$(awk -v m="$_budget_mb" 'BEGIN{printf "%.1f", m/1024}')
                _avail_gib=$(awk -v m="$_model_avail_mb" 'BEGIN{printf "%.1f", m/1024}')
                __tac_info "Model Memory" \
                    "${_avail_gib} GiB free / ${_budget_gib} GiB budget (${_budget_mb} MiB)" "$C_Text"
            fi
        else
            __tac_info "GPU VRAM" "${g_used} MiB / ${g_total} MiB" "$C_Text"
        fi
        __tac_info "Temp" "${g_temp}${DEGREE}C" "$C_Text"
    fi
}

# ---------------------------------------------------------------------------
# gpu-status — Detailed NVIDIA GPU status (replaces standalone oc-gpu-status).
# Shows utilisation, VRAM, temperature, power draw, persistence mode.
# ---------------------------------------------------------------------------
function gpu-status() {
    local smi
    smi=$(__resolve_smi) || {
        __tac_info "GPU" "[nvidia-smi not found]" "$C_Error"
        return 1
    }

    __tac_header "GPU STATUS" "open"

    while IFS=, read -r gname gutil gmused gmtotal gmfree gtemp gpwr gplim
    do
        gutil="${gutil// /}"; gmused="${gmused// /}"; gmtotal="${gmtotal// /}"
        gmfree="${gmfree// /}"; gtemp="${gtemp// /}"; gpwr="${gpwr// /}"; gplim="${gplim// /}"

        local util_n="${gutil%\%}"
        if ! [[ "$util_n" =~ ^[0-9]+$ ]]
        then
            util_n=0
        fi
        local color
        color=$(__threshold_color "$util_n")

        __tac_info "GPU" "${gname}" "$C_Highlight"
        __tac_info "Util" "${color}${gutil}${C_Reset}" "$color"
        __tac_info "VRAM" "${gmused} / ${gmtotal} (${gmfree} free)" "$C_Text"
        __tac_info "Temp" "${gtemp} C" "$C_Text"
        __tac_info "Power" "${gpwr} / ${gplim}" "$C_Text"
    done < <("$smi" \
        --query-gpu=name,utilization.gpu,memory.used,memory.total,memory.free,temperature.gpu,power.draw,power.limit \
        --format=csv,noheader 2>/dev/null)

    local pm
    pm=$("$smi" --query-gpu=persistence_mode --format=csv,noheader 2>/dev/null | head -1 | tr -d ' ')
    if [[ "$pm" == "Enabled" ]]
    then
        __tac_info "Persist" "ON" "$C_Success"
    else
        __tac_info "Persist" "OFF (run 'wake' to enable)" "$C_Warning"
    fi
    __tac_footer
}

# ---------------------------------------------------------------------------
# gpu-check — Quick 5-second CUDA verification.
# Confirms nvidia-smi is reachable, the GPU is visible, and (if a model is
# running) that llama-server is actually offloading layers to the GPU.
# ---------------------------------------------------------------------------
function gpu-check() {
    local smi
    smi=$(__resolve_smi 2>/dev/null) || true

    __tac_header "CUDA / GPU CHECK" "open"

    # 1. nvidia-smi reachable?
    if [[ -z "$smi" ]]
    then
        __tac_info "nvidia-smi" "NOT FOUND - GPU passthrough broken" "$C_Error"
        __tac_info "Tip" "In WSL run: nvidia-smi  (if this fails, CUDA is unavailable)" "$C_Dim"
        __tac_footer; return 1
    fi
    __tac_info "nvidia-smi" "OK" "$C_Success"

    # 2. CUDA device visible?
    local gpu_name
    gpu_name=$("$smi" --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)
    if [[ -z "$gpu_name" ]]
    then
        __tac_info "CUDA Device" "NONE DETECTED" "$C_Error"
        __tac_footer; return 1
    fi
    __tac_info "CUDA Device" "$gpu_name" "$C_Success"

    # 3. VRAM status
    local vram
    vram=$("$smi" --query-gpu=memory.used,memory.total --format=csv,noheader,nounits 2>/dev/null | head -1)
    if [[ -n "$vram" ]]
    then
        local used total
        IFS=',' read -r used total <<< "$vram"
        used="${used// /}"; total="${total// /}"
        __tac_info "VRAM" "${used} MiB / ${total} MiB" "$C_Text"
    fi

    # 4. llama-server CUDA offload (check the runtime log)
    if __llm_server_running && [[ -f "$LLM_LOG_FILE" ]]
    then
        local offload_line
        offload_line=$(grep -i \
            'offload.*layers to GPU\|offloading.*layers to GPU' \
            "$LLM_LOG_FILE" 2>/dev/null | tail -1)
        local cuda_line
        cuda_line=$(grep -i 'ggml_cuda.*found.*CUDA' "$LLM_LOG_FILE" 2>/dev/null | tail -1)

        if [[ -n "$cuda_line" ]]
        then
            __tac_info "CUDA Init" "${cuda_line##*: }" "$C_Success"
        fi
        if [[ -n "$offload_line" ]]
        then
            __tac_info "Offload" "${offload_line##*: }" "$C_Success"
        elif [[ -n "$cuda_line" ]]
        then
            __tac_info "Offload" "No offload line found (check -ngl setting)" "$C_Warning"
        else
            __tac_info "Offload" "No CUDA references in log - may be CPU-only build" "$C_Error"
        fi
    else
        __tac_info "Server" "Not running - start a model to verify offloading" "$C_Dim"
    fi

    __tac_footer
}

# ---------------------------------------------------------------------------
# model — Unified LLM model manager (v3 — auto-scan, numbered selection).
# Subcommands: scan, list, default, use, stop, status, doctor, recommend,
#   info, bench, bench-diff, bench-compare, bench-latest, bench-history,
#   delete, archive, download
# Registry: models.conf — auto-generated by 'model scan', do not hand-edit.
# Format: #|name|file|size_gb|quant_cache|arch|gpu_layers|ctx|threads|batch|ubatch|parallel|fit_target_mb|backend|mmap_mode|flash_attn|tps|autotuned|is_default|in_vram|prefill_tps|p2_ctx|p2_batch|p2_ubatch|p2_tps|p2_prefill
# Active model tracked in: $ACTIVE_LLM_FILE (the model FILE name — the registry row
# identity, not the row number, which `model scan` reassigns)
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# __gguf_metadata — Extract key metadata from a GGUF file header.
# Outputs: name|architecture|block_count|context_length|file_type
# Uses dd+awk to parse GGUF binary format (pure bash, no python dependency).
# Reads first 256KB — sufficient for all KV metadata in any GGUF file.
# ---------------------------------------------------------------------------
function __gguf_metadata() {
    local fpath="$1" fname
    fname=$(basename "$fpath" .gguf)
    dd if="$fpath" bs=262144 count=1 2>/dev/null | od -A n -t u1 -v | \
    awk -v fname="$fname" '
    #-------------------------------------------------------------------
    # GGUF binary parser (pure awk).
    # Input: unsigned byte stream from od -t u1.
    # GGUF layout: 4-byte magic "GGUF" (71,71,85,70), version (u32),
    #   tensor_count (u64), metadata_kv_count (u64), then KV pairs.
    # Each KV: key_len (u64), key (utf8), value_type (u32), value.
    # We extract 5 fields: name, architecture, block_count, ctx, ftype.
    #-------------------------------------------------------------------

    # Helper: read a little-endian u32 from byte array at offset p.
    function u32(p) {
        return b[p] + b[p+1]*256 + b[p+2]*65536 + b[p+3]*16777216
    }

    # Phase 1: Load all bytes into array b[0..n-1].
    { for (i = 1; i <= NF; i++) b[n++] = $i + 0 }

    END {
        # --- Validate GGUF magic bytes ---
        if (n < 24 || b[0] != 71 || b[1] != 71 || b[2] != 85 || b[3] != 70) {
            print fname "|unknown|0|4096|0"
            exit
        }

        # --- Read metadata KV count (u64, but only lower 32 bits matter) ---
        nkv = u32(16)

        # Sanity check: no valid GGUF has more than 10000 metadata keys.
        # Corrupted/truncated files could have garbage nkv causing out-of-bounds reads.
        if (nkv > 10000 || nkv < 0) {
            print fname "|unknown|0|4096|0"
            exit
        }

        # --- Defaults (overwritten if keys are found) ---
        name   = fname
        arch   = "unknown"
        blocks = 0
        ctx    = 4096
        ftype  = 0
        # KV GEOMETRY (fields 6 and 7, added 2026-11-03).  0 = not present in the header,
        # which is the signal for __kv_mb_per_1k to fall back to its old shape-agnostic
        # constant rather than compute from a half-read geometry.
        kvh    = 0
        kdim   = 0
        found  = 0

        # --- Walk KV pairs ---
        # Offset starts after the 24-byte header (magic + version + counts).
        off = 24
        for (kv = 0; kv < nkv && off < n - 8; kv++) {

            # -- Read key: length (u64, lower 32) then UTF-8 bytes --
            klen = u32(off); off += 8
            if (klen < 0 || klen > 1000 || off + klen > n) break
            key = ""
            for (i = 0; i < klen; i++)
                key = key sprintf("%c", b[off + i])
            off += klen

            # -- Read value type (u32) --
            if (off + 4 > n) break
            vt = u32(off); off += 4

            # -- Type 8: STRING (u64 length + UTF-8 bytes) --
            if (vt == 8) {
                if (off + 8 > n) break
                vlen = u32(off); off += 8
                if (off + vlen > n) break
                val = ""
                for (i = 0; i < vlen; i++)
                    val = val sprintf("%c", b[off + i])
                off += vlen
                if (key == "general.architecture") { arch = val; found++ }
                if (key == "general.name")         { name = val; found++ }
            }
            # -- Types 4,5: UINT32, INT32 (4 bytes) --
            else if (vt == 4 || vt == 5) {
                if (off + 4 > n) break
                val = u32(off); off += 4
                if (key == "general.file_type")  { ftype  = val; found++ }
                if (key ~ /block_count/)         { blocks = val; found++ }
                # Anchored, because unanchored this also matched
                # phi3.rope.scaling.original_context_length (the LongRoPE original
                # window, 4096) and — that key being written AFTER
                # <arch>.context_length, with a last-wins assignment — overwrote
                # the real 131072 with 4096 for the whole phi3 family (found
                # 2026-09-16: those rows reported a 4096 window, so their ctx
                # estimates and KV-math ceilings were capped at 4096 too).
                if (key ~ /^[A-Za-z0-9_-]+\.context_length$/ || key == "general.context_length") { ctx = val; found++ }
                # KV GEOMETRY — scalar form (many archs write these as one u32).
                if (key ~ /head_count_kv$/) kvh = val; if (key ~ /key_length$/) kdim = val
            }
            # -- Types 10,11,12: UINT64, INT64, FLOAT64 (8 bytes) --
            else if (vt == 10 || vt == 11 || vt == 12) {
                if (off + 8 > n) break
                val = u32(off); off += 8
                if (key == "general.file_type")  { ftype  = val; found++ }
                if (key ~ /block_count/)         { blocks = val; found++ }
                if (key ~ /^[A-Za-z0-9_-]+\.context_length$/ || key == "general.context_length") { ctx = val; found++ }
                if (key ~ /head_count_kv$/) kvh = val; if (key ~ /key_length$/) kdim = val
            }
            # -- Type 6: FLOAT32 (4 bytes) --
            else if (vt == 6) { off += 4 }
            # -- Types 0,1,7: UINT8, INT8, BOOL (1 byte) --
            else if (vt == 0 || vt == 1 || vt == 7) { off += 1 }
            # -- Types 2,3: UINT16, INT16 (2 bytes) --
            else if (vt == 2 || vt == 3) { off += 2 }
            # -- Type 9: ARRAY (element_type u32, count u64, then elements) --
            else if (vt == 9) {
                if (off + 12 > n) break
                at = u32(off); off += 4              # element type
                al = u32(off); off += 8              # array length (lower 32)
                # KV GEOMETRY — ARRAY form.  MoE archs commonly write head_count_kv as a
                # per-layer array, which the skip below would step over without reading,
                # so the geometry would read as "absent" on exactly the models whose KV
                # cost is largest.  Read element 0 here; the values are uniform in every
                # GGUF seen on this box, and a per-layer divergence only moves the
                # estimate, never a correctness decision.
                if (al > 0 && (at == 4 || at == 5 || at == 10 || at == 11)) {
                    if (key ~ /\.attention\.head_count_kv$/) kvh  = u32(off)
                    if (key ~ /\.attention\.key_length$/)    kdim = u32(off)
                }
                # Skip array contents based on element type
                if      (at == 0 || at == 1 || at == 7)          off += al
                else if (at == 2 || at == 3)                     off += al * 2
                else if (at == 4 || at == 5 || at == 6)          off += al * 4
                else if (at == 10 || at == 11 || at == 12)       off += al * 8
                else if (at == 8) {
                    # Array of strings: each has u64 len + bytes
                    for (a = 0; a < al && off < n; a++) {
                        sl = u32(off)
                        off += 8 + sl
                    }
                }
                else break  # unknown element type - bail
            }
            else break  # unknown value type - bail

            # Early exit once all 5 target keys are found AND the KV geometry was seen —
            # the geometry can appear after any of them, and a model whose header omits
            # it simply walks the remaining keys (bounded by nkv).
            if (found >= 5 && kvh > 0 && kdim > 0) break
        }

        print name "|" arch "|" blocks "|" ctx "|" ftype "|" kvh "|" kdim
    }'
}

# __tac_ram_total_bytes — physical RAM total, cached per shell.
# The seam TAC_HOST_RAM_TOTAL_BYTES exists so a test can state the figure; otherwise
# it is read from /proc/meminfo with bash builtins (no fork per call).
function __tac_ram_total_bytes() {
    if [[ -n "${__TAC_RAM_TOTAL_BYTES_CACHE:-}" ]]
    then
        printf '%d\n' "$__TAC_RAM_TOTAL_BYTES_CACHE"
        return
    fi
    local _kb="" _line _key _val
    if [[ "${TAC_HOST_RAM_TOTAL_BYTES:-}" =~ ^[0-9]+$ ]] && (( TAC_HOST_RAM_TOTAL_BYTES > 0 ))
    then
        __TAC_RAM_TOTAL_BYTES_CACHE="$TAC_HOST_RAM_TOTAL_BYTES"
    elif [[ -r /proc/meminfo ]]
    then
        while IFS= read -r _line
        do
            _key="${_line%%:*}" _val="${_line#*:}"
            if [[ "$_key" == "MemTotal" ]]
            then
                _val="${_val//[[:space:]]/}"
                _kb="${_val%kB}"
                break
            fi
        done < /proc/meminfo
        if [[ "$_kb" =~ ^[0-9]+$ ]]
        then
            __TAC_RAM_TOTAL_BYTES_CACHE=$(( _kb * 1024 ))
        fi
    fi
    printf '%d\n' "${__TAC_RAM_TOTAL_BYTES_CACHE:-0}"
}

# __tac_vram_total_bytes — the card's own VRAM total, or the profile's fallback.
# The card is asked first: sizing every model against a constant marks a model that
# fits a larger card (24 GB, or an arm64 CUDA box) as CPU-only.  When the card
# cannot be read the HOST PROFILE's fallback is used, and 0 there means "this host
# has no honest constant" — callers then size conservatively (CPU-only) instead of
# borrowing another card's number.  Cached per shell: a card's total does not change
# under a session.
function __tac_vram_total_bytes() {
    if [[ -n "${__TAC_VRAM_TOTAL_BYTES_CACHE:-}" ]]
    then
        printf '%d\n' "$__TAC_VRAM_TOTAL_BYTES_CACHE"
        return
    fi
    # THE POOL IS MEASURED PER BOOT AND NEVER CLAMPED TO RAM (2026-11-03).
    # This used to clamp the card's figure to MemTotal on a unified host, on the reading
    # that the card reports memory the machine cannot back.  Two boots measured hours
    # apart refute that: 2026-11-02 23:43 gave card 81920 MiB against Windows 46.5 GB, and
    # 2026-11-03 01:50 gave card 98304 MiB against Windows 30.5 GB — the OS/GPU split is
    # made at boot and it MOVES by ~16 GiB between boots.  On the second of those,
    # torch.cuda.get_device_properties(0).total_memory read 110.5 GiB, i.e. ABOVE the
    # card's own figure, so the card's number is the conservative bound of the two and
    # min(card, torch) reduces to the card — one cheap read rather than a torch import
    # in this path.  What the clamp actually did was hide ~66 GiB behind a guest MemTotal
    # that was itself only a .wslconfig value (29.8 GiB).
    #
    # Precedence: the profile's measured pool, then the card, then the declared fallback.
    # TAC_HOST_GPU_POOL_BYTES is what tools/host-profile.sh exports, once per boot.
    if [[ "${TAC_HOST_GPU_POOL_BYTES:-}" =~ ^[0-9]+$ ]] && (( TAC_HOST_GPU_POOL_BYTES > 0 ))
    then
        __TAC_VRAM_TOTAL_BYTES_CACHE="$TAC_HOST_GPU_POOL_BYTES"
        printf '%d\n' "$__TAC_VRAM_TOTAL_BYTES_CACHE"
        return
    fi
    local _total_mb=""
    if command -v nvidia-smi >/dev/null 2>&1
    then
        # swallow-ok: an unreadable card falls back to VRAM_TOTAL_BYTES below, which is the named fallback
        _total_mb=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null)
        _total_mb="${_total_mb%%$'\n'*}"
        _total_mb="${_total_mb// /}"
    fi
    if [[ "$_total_mb" =~ ^[0-9]+$ ]]
    then
        __TAC_VRAM_TOTAL_BYTES_CACHE=$(( _total_mb * 1048576 ))
    else
        __TAC_VRAM_TOTAL_BYTES_CACHE="${VRAM_TOTAL_BYTES:-0}"
    fi
    printf '%d\n' "$__TAC_VRAM_TOTAL_BYTES_CACHE"
}

# __calc_gpu_layers — Calculate optimal GPU layer count for available VRAM.
# Strategy: use -ngl 999 at launch to let llama.cpp offload the maximum
# layers that fit in VRAM. This scan-time function determines the launch
# MODE (gpu vs cpu-only) and stores a hint for display/logging. The actual
# offload count is decided by the runtime, not by this calculation.
#
# Decision logic (binary, not partial offload):
#   - If model fits entirely in VRAM: return 999 (offload all layers)
#   - If model exceeds VRAM: return 0 (CPU-only mode is faster than partial)
#   - For MoE models: return total_layers — the count is right only because the
#     LAUNCHER pairs it with --cpu-moe when the weights exceed the card
#     (__model_use_fit_preflight, 11e).  `-ngl` moves whole layers, expert tensors
#     included; experts stay in RAM only with --cpu-moe/--n-cpu-moe.  The old note
#     here said they "stay on CPU anyway", which was untrue of llama.cpp and is how
#     a 73.3 GB MoE was asked for a 24 GiB card (2026-11-06, CUDA OOM at load).
#
# Rationale: Partial offload (some layers on GPU, rest in system RAM) causes
# PCIe bandwidth bottlenecks. Pure CPU inference with --mlock is faster than
# the hybrid path when the model doesn't fit in VRAM.
# Args: file_size_bytes total_layers [arch]
# Returns: 999 (max offload), total_layers (MoE), or 0 (CPU-only)
function __calc_gpu_layers() {
    local _mem_total
    # swallow-ok: /proc/meminfo may be absent in a minimal test environment; empty falls back to usable_vram
    _mem_total="$(awk '/^MemTotal:/{printf "%.0f", $2*1024}' /proc/meminfo 2>/dev/null)"
    __gpu_layers_fit "$1" "$2" "${3:-}" \
        "$(__tac_vram_total_bytes)" \
        "$_mem_total" \
        "${TAC_HOST_PROFILE_SHARED_MEMORY:-0}"
}

# __gpu_layers_fit — the placement decision with every number PASSED IN (pure).
# Split out of __calc_gpu_layers so a test can pin the card and the guest separately;
# it reads no file, no card and no environment except the reserve knob.
# Args: file_bytes total_layers arch vram_total_bytes mem_total_bytes shared(0|1)
function __gpu_layers_fit() {
    local _file_bytes=$1 _total_layers=$2 _arch="${3:-}"
    local _vram_total=$4 _mem_total=$5 _shared=$6
    local usable_vram=$(( ${_vram_total:-0} * VRAM_USABLE_PCT / 100 ))

    # MoE: the layer count is returned WITHOUT a VRAM comparison (the caller decides
    # placement — see __model_use_fit_preflight in 11e, which adds --cpu-moe when the
    # weights do not fit the card).  It is not a claim that experts are on the CPU.
    if [[ "${_arch,,}" == *moe* ]]
    then
        echo "${_total_layers:-0}"
        return
    fi

    # Full offload when the model fits in usable VRAM, otherwise CPU-only.
    #
    # A SHARED-MEMORY host is judged against the GUEST, not the card: there the pool is a
    # reservation backed by the guest's own RAM, so the card's figure is not the allocation
    # bound.  Measured 2026-11-10 on the RTX Spark box: a 50.9 GiB dense model loaded and
    # served with `-ngl 999` on a 32,768 MiB pool.  Judging it against the card here marks
    # the row CPU-only, and the next `model scan` then silently undoes a launch that works
    # (it did, twice).  MemTOTAL, not MemAvailable: a scan can run while the model is
    # resident, and a load-dependent reading would flip the row back.  The launch-time
    # `__model_use_fit_preflight` still guards the live allocation with the same reserve.
    if [[ "$_shared" == "1" ]]
    then
        local _reserve_mb _budget
        _reserve_mb="${LLAMA_FIT_KEEP_RESERVE_MB:-12288}"
        [[ "$_reserve_mb" =~ ^[0-9]+$ ]] || _reserve_mb=12288
        if [[ "$_mem_total" =~ ^[0-9]+$ ]] && (( _mem_total > 0 ))
        then
            _budget=$(( _mem_total - _reserve_mb * 1048576 ))
            if (( _budget > 0 && _file_bytes <= _budget ))
            then
                echo 999
            else
                echo 0
            fi
            return
        fi
    fi

    if (( _file_bytes <= usable_vram ))
    then
        echo 999
    else
        echo 0
    fi
}

# __calc_ctx_size — Pick a practical context size.
# Must account for KV cache VRAM: larger ctx = more VRAM consumed beyond model weights.
# CPU-only models (>4GB) have no VRAM constraint so can use larger ctx.
# For GPU-capable models, estimates ctx from VRAM budget so first registration
# is realistic instead of storing the GGUF metadata value (which can be 1M+).
function __calc_ctx_size() {
    local _file_bytes=$1 _native_ctx=$2 _arch="${3:-}"
    local _vram_total
    _vram_total="$(__tac_vram_total_bytes)"
    # MoE models use a stable conservative context regardless of size.
    if [[ "${_arch,,}" == *moe* ]]
    then
        echo "$MOE_DEFAULT_CTX"
        return
    fi

    # CPU-only mode (model exceeds VRAM threshold): cap to MOE_DEFAULT_CTX.
    if (( _file_bytes > _vram_total * VRAM_THRESHOLD_PCT / 100 ))
    then
        echo "$MOE_DEFAULT_CTX"
        return
    fi

    # GPU-capable: estimate realistic ctx from VRAM budget.
    # KV cache overhead: ~0.5 MB per layer per 1K tokens (q8_0 K + f16 V).
    # We budget remaining VRAM after model weights for ~20K context as a
    # practical starting point, capped by the model's native max.
    local _model_mb=$(( _file_bytes / 1048576 ))
    local _vram_free_mb
    if command -v nvidia-smi &>/dev/null; then
        _vram_free_mb=$(nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ')
    fi
    [[ "$_vram_free_mb" =~ ^[0-9]+$ ]] || _vram_free_mb=""
    local _vram_total_mb=$(( _vram_total / 1048576 ))  # 4096 on the RTX 3050 Ti
    [[ -n "$_vram_free_mb" && "$_vram_free_mb" -gt "$_vram_total_mb" ]] && _vram_free_mb=$_vram_total_mb
    local _vram_avail_mb=$(( _vram_total_mb - _model_mb - 200 ))  # minus weights + 200MB OS
    [[ -n "$_vram_free_mb" && "$_vram_free_mb" -lt "$_vram_avail_mb" ]] && _vram_avail_mb=$_vram_free_mb

    # Estimate KV cache MB per 1K tokens from model size (proxy for layer count).
    # Typical: <1GB ~16 layers (0.5 MB/layer => 8 MB/1K), 1-2GB ~24 layers (12 MB/1K),
    # 2-3GB ~28 layers (14 MB/1K), 3-4GB ~32 layers (16 MB/1K)
    local _kv_mb_per_1k=12.0
    if (( _model_mb >= 3500 )); then
        _kv_mb_per_1k=16.0
    elif (( _model_mb >= 2000 )); then
        _kv_mb_per_1k=14.0
    elif (( _model_mb >= 1000 )); then
        _kv_mb_per_1k=12.0
    elif (( _model_mb >= 500 )); then
        _kv_mb_per_1k=10.0
    else
        _kv_mb_per_1k=8.0
    fi

    if (( _vram_avail_mb > 0 )); then
        # Estimate ctx from available VRAM: ctx = trunc(vram_avail / kv_mb_per_1k * 1000 / 1024) * 1024
        local _est_ctx
        _est_ctx=$(awk -v v="$_vram_avail_mb" -v k="$_kv_mb_per_1k" 'BEGIN{c=int(v/k*1000/1024)*1024; print c<4096?4096:c}')
        # Cap at native model context limit
        if (( _native_ctx > 0 && _native_ctx < _est_ctx )); then
            _est_ctx=$_native_ctx
        fi
        # Absolute ceiling: 64K for initial registration on a 4GB GPU, or LLAMA_MAX_CTX_SIZE
        # (256K default) on a shared-memory unified host.
        # Autotune will find the real optimum; this is just a realistic first guess.
        local _max_ctx=65536
        [[ "${TAC_HOST_PROFILE_SHARED_MEMORY:-0}" == "1" ]] && _max_ctx="${LLAMA_MAX_CTX_SIZE:-262144}"
        (( _est_ctx > _max_ctx )) && _est_ctx=$_max_ctx
        echo "$_est_ctx"
    else
        # No VRAM available before freeing model weights, use a conservative fallback
        if (( _native_ctx > 0 )); then
            # Cap native ctx to a value proportional to model size vs VRAM
            local _ratio=$(( _model_mb * 100 / _vram_total_mb ))
            if (( _ratio >= 100 )); then
                echo "$MOE_DEFAULT_CTX"
            elif (( _ratio >= 75 )); then
                local _cap=$(( _native_ctx < 16384 ? _native_ctx : 16384 ))
                echo "$_cap"
            else
                local _cap=$(( _native_ctx < 32768 ? _native_ctx : 32768 ))
                echo "$_cap"
            fi
        else
            echo "$MOE_DEFAULT_CTX"
        fi
    fi
}

# ---------------------------------------------------------------------------
# __bench_resolve_files — Resolve old/new benchmark TSV paths.
# Usage:
#   __bench_resolve_files                   -> latest two bench TSVs
#   __bench_resolve_files old.tsv new.tsv   -> explicit files
# Outputs: old_path|new_path
# ---------------------------------------------------------------------------
function __bench_resolve_files() {
    if (( $# == 2 ))
    then
        printf '%s|%s\n' "$1" "$2"
        return 0
    fi
    if (( $# != 0 ))
    then
        return 1
    fi

    local latest_files=()
    while IFS= read -r bench_file
    do
        latest_files+=("$bench_file")
    done < <(find "$LLM_STATE_DIR" -maxdepth 1 -name 'bench_*.tsv' -type f \
        -printf '%T@ %p\n' 2>/dev/null | sort -n -r | head -2 | cut -d' ' -f2-)

    if (( ${#latest_files[@]} < 2 ))
    then
        return 1
    fi

    # newest first from ls -t; diff should read old -> new
    printf '%s|%s\n' "${latest_files[1]}" "${latest_files[0]}"
}

# ---------------------------------------------------------------------------
# __bench_latest_file — Return newest benchmark TSV path.
# Returns 1 if no bench TSV exists.
# ---------------------------------------------------------------------------
function __bench_latest_file() {
    find "$LLM_STATE_DIR" -maxdepth 1 -name 'bench_*.tsv' -type f \
        -printf '%T@ %p\n' 2>/dev/null | sort -n -r | head -1 | cut -d' ' -f2-
}

# ---------------------------------------------------------------------------
# __llm_thread_cap — Clamp a compute-thread count to the HOST's declared ceiling.
# Usage: __llm_thread_cap <threads>  ->  min(threads, LLAMA_THREAD_CAP)
#
# The ceiling is a per-machine fact, not a repo constant.  On the i9-12900HK
# (6 P-cores / 8 E-cores) any count above 6 spills decode onto the efficiency
# cores and SLOWS generation via sync latency — the DFlash article's
# hybrid-architecture pitfall — so the Intel profile declares 6.  A homogeneous
# arm64 box has no E-core split: its profile declares 0, meaning NO ceiling, and
# the caller's nproc-derived count stands.  Measured 2026-11-05: this function
# returned 6 unconditionally on a 20-core box, so every launch and all 30 autotune
# rows measured at 6 threads while the profile's 10 was silently discarded.
# An unrecognised value falls back to 6, the conservative hybrid default.
#
# REF: "Speculative Decoding on CPUs — Nearly 4x Faster Token Generation
# with DFlash" (Intel, TDS 2026)
# https://towardsdatascience.com/speculative-decoding-on-cpus-nearly-4x-faster-token-generation-with-dflash/
function __llm_thread_cap() {
    local _raw="${1:-6}" _cap="${LLAMA_THREAD_CAP:-6}"
    [[ "$_raw" =~ ^[0-9]+$ ]] || _raw=6
    [[ "$_cap" =~ ^[0-9]+$ ]] || _cap=6
    if (( _cap == 0 )) || (( _raw <= _cap )); then
        echo "$_raw"
    else
        echo "$_cap"
    fi
}

# ---------------------------------------------------------------------------
# __spec_decode_stats — Parse llama-server speculative-decode stats from a log.
# Usage: __spec_decode_stats <logfile>
# Output: rate|accepted|generated|mean_len|present
#   rate      acceptance ratio (accepted/generated draft tokens)
#   accepted  draft tokens accepted by the target model
#   generated draft tokens proposed
#   mean_len  mean acceptance LENGTH = accepted-per-round + 1 (the article's
#             tuning metric — do NOT compare runs on rate alone)
#   present   "yes" when a stats line was found, "no" otherwise
# The server emits one "draft acceptance = ..." line per completed request
# (tools/server/server-context.cpp @1692f9e50); the LAST line is the most
# recent request.  SPEC-DEC-003: counter inflation — usage.completion_tokens
# can count accepted final-block tokens discarded at max_tokens, so TPS must
# be recomputed from delivered tokens when spec-decode is on.
#
# REF: "Speculative Decoding on CPUs — Nearly 4x Faster Token Generation
# with DFlash" (Intel, TDS 2026)
# https://towardsdatascience.com/speculative-decoding-on-cpus-nearly-4x-faster-token-generation-with-dflash/
function __spec_decode_stats() {
    local _log="${1:-}"
    [[ -f "$_log" ]] || { echo "0|0|0|0|no"; return 1; }
    local _line
    _line=$(grep -oE 'draft acceptance = [0-9.]+ \( *[0-9]+ accepted / *[0-9]+ generated\), mean len = *[0-9.]+' \
        "$_log" 2>/dev/null | tail -1)
    [[ -n "$_line" ]] || { echo "0|0|0|0|no"; return 1; }

    local _clean
    _clean=$(echo "$_line" | sed -E \
        -e 's/draft acceptance = //' \
        -e 's/ *\( *([0-9]+) accepted \/ *([0-9]+) generated\), mean len = */|\1|\2|/')
    local _rate _accepted _generated _mean_len
    IFS='|' read -r _rate _accepted _generated _mean_len <<< "$_clean"
    [[ "$_rate" =~ ^[0-9.]+$ ]] || _rate=0
    [[ "$_accepted" =~ ^[0-9]+$ ]] || _accepted=0
    [[ "$_generated" =~ ^[0-9]+$ ]] || _generated=0
    [[ "$_mean_len" =~ ^[0-9.]+$ ]] || _mean_len=0
    echo "${_rate}|${_accepted}|${_generated}|${_mean_len}|yes"
}

# ---------------------------------------------------------------------------
# __spec_block_size — Resolve the active speculative-decode block size.
# Priority: LLM_SPEC_DRAFT_N_MAX env > LLM_SPECULATIVE_NGRAM env > the active
# model's registry spec_draft_n_max (field 29, written by SPEC-DEC-004
# autotune) > 16 (the llama.cpp --spec-draft-n-max default).  Prints int.
function __spec_block_size() {
    local _n_max="${LLM_SPEC_DRAFT_N_MAX:-}"
    [[ "$_n_max" =~ ^[0-9]+$ ]] && [[ $_n_max -gt 0 ]] && { echo "$_n_max"; return 0; }
    local _ngram="${LLM_SPECULATIVE_NGRAM:-}"
    [[ "$_ngram" =~ ^[0-9]+$ ]] && [[ $_ngram -gt 0 ]] && { echo "$_ngram"; return 0; }
    if [[ -f "${ACTIVE_LLM_FILE:-}" && -f "$LLM_REGISTRY" ]]; then
        local _act_file _act_row _reg_n_max
        # The pointer holds the model FILE name (the row's identity); resolving it by
        # number would read a DIFFERENT model's spec block after any rescan.
        _act_file=$(cat "$ACTIVE_LLM_FILE" 2>/dev/null || true)
        if [[ -n "$_act_file" ]]; then
            _act_row=$(__llm_registry_entry_by_file "$_act_file" 2>/dev/null || true)
            _reg_n_max=$(cut -d'|' -f29 <<< "$_act_row")
            [[ "$_reg_n_max" =~ ^[0-9]+$ ]] && [[ $_reg_n_max -gt 0 ]] && { echo "$_reg_n_max"; return 0; }
        fi
    fi
    echo "16"
}

# ---------------------------------------------------------------------------
# __spec_launch_flags — Emit speculative-decoding launch flags (VERIFIED
# llama.cpp @1692f9e50 names — the removed --draft-model / --speculative-ngram
# crash llama-server at launch, common/arg.cpp:825).
#
# Resolution priority: LLM_SPEC_* env overrides > registry row_spec_* fields
# (dynamic scope) > defaults.  Reads: LLM_SPEC_DRAFT_ENABLED, LLM_SPEC_TYPE,
# LLM_SPEC_DRAFT_MODEL, LLM_SPEC_DRAFT_N_MAX, LLM_SPEC_DRAFT_NGL,
# LLM_SPEC_DRAFT_DEVICE, LLM_SPECULATIVE_NGRAM and the row_spec_* variables.
#
# 4 GB VRAM rule: a draft model must NEVER steal VRAM from the target, so the
# default draft placement is CPU-only (--spec-draft-device none) unless the
# user explicitly sets LLM_SPEC_DRAFT_NGL>0 or LLM_SPEC_DRAFT_DEVICE.
#
# Speculative decoding is LOSSLESS (rejection sampling recovers the target
# distribution exactly) — preferred over lossy quantization for
# quality-critical paths (legal evidence); ngram spec-decode needs no extra
# model and is the natural first step on a 4 GB card.
#
# Output: one flag per line on stdout (paths may contain spaces); empty when
# spec-decode is disabled or nothing is configured.
#
# REF: "Speculative Decoding on CPUs — Nearly 4x Faster Token Generation
# with DFlash" (Intel, TDS 2026)
# https://towardsdatascience.com/speculative-decoding-on-cpus-nearly-4x-faster-token-generation-with-dflash/
function __spec_launch_flags() {
    # SPEC-DEC-005 knob: disable draft decoding under load (per-server).
    case "${LLM_SPEC_DRAFT_ENABLED:-1}" in
        0|false|FALSE|no|NO|off|OFF) return 0 ;;
    esac

    local _type="${LLM_SPEC_TYPE:-${row_spec_type:-}}"
    local _draft="${LLM_SPEC_DRAFT_MODEL:-${row_spec_draft_model:-}}"
    # A registry row names its file RELATIVE to the model store — that is the convention
    # the row's own `file` column follows, and every consumer joins it to
    # $LLAMA_MODEL_DIR.  The draft column was passed through verbatim, so the server (whose
    # cwd is the repo, not the store) received `--spec-draft-model mtp-...gguf` and could
    # not find it.  Measured 2026-11-10 on row 4.  Only a relative path that EXISTS under
    # the store is rewritten: an absolute path, or one meant for another cwd, is untouched.
    if [[ -n "$_draft" && "$_draft" != /* && -n "${LLAMA_MODEL_DIR:-}" && -e "$LLAMA_MODEL_DIR/$_draft" ]]
    then
        _draft="$LLAMA_MODEL_DIR/$_draft"
    fi
    local _n_max="${LLM_SPEC_DRAFT_N_MAX:-${row_spec_n_max:-0}}"
    [[ "$_n_max" =~ ^[0-9]+$ ]] || _n_max=0
    local _ngl="${LLM_SPEC_DRAFT_NGL:-${row_spec_ngl:-0}}"
    [[ "$_ngl" =~ ^[0-9]+$ ]] || _ngl=0
    local _device="${LLM_SPEC_DRAFT_DEVICE:-${row_spec_device:-}}"
    local _ngram="${LLM_SPECULATIVE_NGRAM:-0}"
    [[ "$_ngram" =~ ^[0-9]+$ ]] || _ngram=0

    [[ -n "$_draft" || "$_type" == "ngram" || $_ngram -gt 0 ]] || return 0

    if [[ -n "$_draft" ]]
    then
        printf '%s\n' "--spec-draft-model" "$_draft"
        if [[ -n "$_device" ]]
        then
            printf '%s\n' "--spec-draft-device" "$_device"
        elif (( _ngl > 0 ))
        then
            printf '%s\n' "--spec-draft-ngl" "$_ngl"
        else
            # CPU-only draft: never steal VRAM from the target on 4 GB.
            printf '%s\n' "--spec-draft-device" "none"
        fi
    fi

    if [[ "$_type" == "ngram" || $_ngram -gt 0 ]]
    then
        local _block="$_n_max"
        (( _block > 0 )) || _block="$_ngram"
        (( _block > 0 )) || _block=16
        # n_min pinned to the block so a small block is actually drafted
        # (the ngram-mod default n_min=48 would swallow smaller blocks).
        printf '%s\n' "--spec-type" "ngram-mod" \
            "--spec-ngram-mod-n-max" "$_block" \
            "--spec-ngram-mod-n-min" "$_block"
    elif (( _n_max > 0 ))
    then
        printf '%s\n' "--spec-draft-n-max" "$_n_max"
    fi

    # v42: a MODEL-BASED draft type must be NAMED.  Only `ngram` emitted --spec-type
    # before, so a row carrying spec_type=draft-dflash (etc.) launched the draft file
    # with no type at all and llama-server fell back to its own default — the row's
    # value was read and then silently dropped.  Measured 2026-11-09: the adopted
    # Qwen3.8-27B DFlash arm named the type explicitly, so the row must reproduce it.
    case "$_type" in
        '' | ngram) ;;
        draft-simple | draft-eagle3 | draft-mtp | draft-dflash | draft-dspark)
            printf '%s\n' "--spec-type" "$_type"
            # Backend sampling is what the measured DFlash arm ran and what a
            # model-based drafter expects; LLM_SPEC_DRAFT_BACKEND_SAMPLING=0 disables
            # it.  ngram drafting has no sampler of its own, so it is not emitted there.
            case "${LLM_SPEC_DRAFT_BACKEND_SAMPLING:-1}" in
                0 | false | FALSE | no | NO | off | OFF) ;;
                *) printf '%s\n' "--spec-draft-backend-sampling" ;;
            esac
            ;;
        *)
            # stdout is the flag stream (mapfile at the caller), so the note goes through
            # this file's warn helper; a hand-written >&2 here raises §18.3 10.7.
            warn "spec-decode: unknown spec_type $_type ignored"
            ;;
    esac
}

# __calc_threads — CPU threads based on how much spills to CPU.
# Uses nproc to detect available threads, then scales:
#   CPU-only  → 80% (all layers on CPU, maximise parallelism)
#   Partial   → 70% (CPU handles remaining layers + KV-cache)
#   Full GPU  → 50% (CPU only does prompt processing + sampling)
# Result is clamped to the host's LLAMA_THREAD_CAP: 6 on the i9-12900HK hybrid
# (more than 6 compute threads spill onto E-cores and slow generation,
# SPEC-DEC-002), 0 = no ceiling on a homogeneous box.
function __calc_threads() {
    local _gpu_layers=$1 _total_layers=$2
    local ncpu pct
    ncpu=$(nproc 2>/dev/null || echo 16)

    if (( _gpu_layers <= 0 ))
    then
        pct=80
    elif (( _total_layers > 0 && _gpu_layers >= _total_layers ))
    then
        pct=50
    else
        pct=70
    fi

    local threads=$(( ncpu * pct / 100 ))
    (( threads < 1 )) && threads=1
    __llm_thread_cap "$threads"
}

# __quant_label — Map GGUF file_type int to human-readable quant label.
# Values sourced from llama.cpp's ggml.h GGML_FTYPE enum.
# Falls back to extracting quant from filename if file_type is 0/unknown.
function __quant_label() {
    local ftype=$1 fname=$2
    local label=""
    case "$ftype" in
        1) label="F16";;   2) label="Q4_0";;  3) label="Q4_1";;
        7) label="Q8_0";;  8) label="Q5_0";;  9) label="Q5_1";;  10) label="Q2_K";;
        11) label="Q3_K_S";; 12) label="Q3_K_M";; 13) label="Q3_K_L";;
        14) label="Q4_K_S";; 15) label="Q4_K_M";; 16) label="Q5_K_S";;
        17) label="Q5_K_M";; 18) label="Q6_K";;  19) label="IQ2_XXS";;
        20) label="IQ2_XS";; 21) label="IQ3_XXS";; 26) label="IQ3_M";;
        28) label="Q4_0_4_4";; 29) label="Q4_0_4_8";; 30) label="Q4_0_8_8";;
        *) ;;
    esac
    # Regex matches GGUF quantization naming patterns:
    #   IQ variants (IQ2_XXS, IQ3_M, etc.), standard K-quants (Q4_K_S, Q5_K_M),
    #   base quants (Q4_0, Q8_0), split formats (Q4_0_4_4), and float types (F16, BF16).
    if [[ -z "$label" || "$ftype" == "0" ]] && [[ -n "$fname" ]]
    then
        local quant_pat='(IQ[0-9]_[A-Z]+|Q[0-9]+_K_[SML]'
        quant_pat+='|Q[0-9]+_K|Q[0-9]+_[0-9]+|Q[0-9]+|F16|F32|BF16)'
        local extracted
        extracted=$(echo "$fname" \
            | grep -oiE "$quant_pat" | head -1 \
            | tr '[:lower:]' '[:upper:]')
        [[ -n "$extracted" ]] && label="$extracted"
    fi
    echo "${label:-unknown}"
}

# ---------------------------------------------------------------------------
# __renumber_registry lives in 11a-llm-registry.sh, which the 11-llm-manager thin
# loader sources before this module. It used to be duplicated here verbatim — 36
# identical lines under the same name — so an edit to one copy silently diverged
# from the other (docs/inspection.md 10.1). Do not re-add it.
#
# The `__model_scan` doc block that used to sit here was orphaned: that function
# is defined in 11e-llm-model.sh.
# ---------------------------------------------------------------------------

# end of file
