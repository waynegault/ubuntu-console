#!/usr/bin/env bash
# shellcheck shell=bash
# ==============================================================================
# host-profile.sh — WHICH BOX this repo is running on, resolved once.
# ==============================================================================
# This repo serves more than one machine.  Architecture alone is not enough to
# decide how to behave: an x86_64 box with an Intel Xe iGPU and a 4 GB CUDA card
# and an arm64 box with one large CUDA card share a repo but not a single tuning
# default, lane set, model store or label.  Those differences live in
# `config/hosts.d/<id>.conf`, and this file is the one place that picks one.
#
# Resolution order (first wins):
#   1. LLM_HOST_PROFILE           — an explicit environment override
#   2. ~/.llm/host-profile        — the box's own recorded choice (one id per line,
#                                   `#` comments allowed).  Machine-local state, so
#                                   it is never committed and never shared between
#                                   boxes.
#   3. detection                  — arch + CUDA + render node matched against the
#                                   profiles' declared TAC_HOST_PROFILE_* metadata.
#
# No guess is ever made: no match, two matches, or an unknown override is REFUSED
# with the machine's own facts and the list of profiles, because a silently
# chosen neighbour profile is how a 4 GB box gets a 128 GB box's defaults (or the
# reverse) and nothing fails until a model does not fit.
#
# Source it; it defines functions only (no side effects, no forks at source time):
#   source tools/host-profile.sh
#   tac_host_profile_apply
# ==============================================================================
# AI INSTRUCTION: Increment version on significant changes.
# Module Version: 11
#   v11 (2026-11-05): LLAMA_LANE_KEEP_UNITS joins the clear/export set — it was omitted when
#   the always-on lane was introduced (01-constants v50), so a parent shell's copy survived the
#   `:=` and the lane table refreshed AROUND a stale guard.  Measured 17:20: a shell still held
#   llama-cuda-embeddinggemma-embed.service after the lane was renamed, `model use 1` matched no
#   keep entry and stopped the embedding lane, and the only report of it was the post-load
#   confirmation.  A guard that cannot match is worse than none: the operator believes memory
#   search is protected.
# Module Version: 10
#   v10 (2026-11-05): three profile facts join the clear/export set.  LLAMA_THREAD_CAP is
#   the per-host compute-thread ceiling (6 on the i9's six P-cores, 0 = no ceiling on a
#   homogeneous box); without it in the export set a child shell kept the default 6.  The
#   two census knobs (LLM_AUTOTUNE_CENSUS / ..._MAX_MIB) are the declared VRAM tenants a
#   measurement may share the card with; clearing them stops a parent shell's census from
#   describing a different box.
# Module Version: 9
#   v9 (2026-11-04): detection no longer NEEDS the GPU.  A profile may declare
#   TAC_HOST_PROFILE_CPU and is then matched on the CPU model (readable via lscpu with
#   no device access), outranking the arch/CUDA/render facts.  Measured on the arm64
#   runner, which reads cuda=0 in a bare environment and so matched no profile at all —
#   three BATS cases failed because install.sh refused.  An unreadable CPU refuses
#   rather than falling back to a device fact that may describe another box.
# Module Version: 8
#   v8 (2026-11-03): TAC_HOST_GPU_POOL_BYTES — the GPU-addressable pool, MEASURED once
#   per boot and exported. 11d used to clamp the card's figure to MemTotal on a
#   unified host; two boots hours apart showed why that is wrong (card 81920 MiB with
#   Windows at 46.5 GB, then 98304 MiB with Windows at 30.5 GB — the split MOVES), and
#   torch reported 110.5 GiB on the second, above the card, so the card is the
#   conservative bound. The value is cached per boot_id so only the first shell of a
#   boot pays for the probe; an unreadable card returns 1 and 11d keeps its own
#   fallback rather than inventing a number.
# Module Version: 7
#   v7 (2026-11-02): HF_HUB_CACHE joins HF_HOME in the cleared and exported profile-owned
#   facts. Pinning only HF_HOME would leave a second cache path in play, because the hub
#   cache follows HF_HUB_CACHE whenever it is set; both now name the box's model store, so
#   a download and the GGUF it becomes share one directory.
# Module Version: 6
#   v6 (2026-11-02): HF_HOME joins the cleared profile-owned facts and the exported set.
#   The arm64 box's profile now puts HuggingFace's cache inside its model store
#   ($HOME/models/active, Wayne), which makes HF_HOME a fact about the machine like
#   LLAMA_MODEL_DIR — but the global default in 01-constants.sh:526 uses `:-`, so a
#   parent console's exported ~/hf_cache would win forever in every child and the
#   per-box value would never apply. Measured before the clear: `HF_HOME=<parent value>`
#   survived `source env.sh`; after it, the profile's path wins and a box whose profile
#   declares none still falls through to ~/hf_cache unchanged.
# Module Version: 5
#   v5 (2026-11-01): LLM_REGISTRY / LLM_DEFAULT_FILE / LLM_STATE_DIR join the
#   cleared profile-owned facts.  The registry and tool-state home are per-box, so a
#   console-started window that exported the OLD box's ~/.llm values must not leak
#   them into a shell whose profile now points beside the store (measured 2026-11-01:
#   the agent's shell carried LLM_REGISTRY=~/.llm/models.conf after the move).
#   v4 (2026-11-01): four more profile-owned facts join the clear/export set —
#   LLAMA_CUDA_LANE_UNIT, LLAMA_GPU_FREE_THRESHOLD_MIB, LLM_AUTOTUNE_BASELINE_GAP_MAX and
#   LLAMA_CUDA_SERVER_BIN — so the heavy-job re-exec no longer drops them.
#   v3 (2026-10-30): the model store's shape and the memory model are profile facts —
#   TAC_HOST_PROFILE_MODEL_STORE_IS_MOUNT (a bind mount vs a plain directory) and
#   TAC_HOST_PROFILE_SHARED_MEMORY (the card's memory is the system pool).  Both are
#   cleared with the other profile-owned facts and exported with them.
#   v2 (2026-10-30): PROFILE-OWNED FACTS are cleared before the profile is sourced.
#   A console-started window exports its profile into every child, so the arm64
#   profile could not take effect in a shell that inherited the intel five-lane
#   table, sizing fallback and labels.  The documented operator knobs still win.
#   v1 (2026-10-29): first cut — host profile selection so one repo serves the
#   Intel x86_64 box and the ASUS arm64 box without sharing tuning, lanes,
#   model-store paths or labels between them.
# ==============================================================================

# Parameter expansion, not `dirname`: this file is sourced on EVERY shell start, and
# a subshell here would be a fork per shell.  arch.sh defines tac_host_arch.
# shellcheck source=/dev/null
source "${BASH_SOURCE[0]%/*}/arch.sh"

# tac_host_profile_root — the profile directory (overridable for tests and for a
# checkout kept outside REPO).  The absolute path is resolved once and cached: the
# resolver asks for it several times per shell.
tac_host_profile_root() {
    if [[ -n "${TAC_HOST_PROFILE_DIR:-}" ]]
    then
        printf '%s\n' "$TAC_HOST_PROFILE_DIR"
        return 0
    fi
    if [[ -z "${__TAC_HOST_PROFILE_ROOT_CACHE:-}" ]]
    then
        __TAC_HOST_PROFILE_ROOT_CACHE="$(cd "${BASH_SOURCE[0]%/*}/../config/hosts.d" && pwd)"
    fi
    printf '%s\n' "$__TAC_HOST_PROFILE_ROOT_CACHE"
}

# tac_host_profile_ids — every declared profile id, sorted, one per line.
tac_host_profile_ids() {
    local _root _f
    _root="$(tac_host_profile_root)" || return 2   # 2 = profile directory unreadable
    for _f in "$_root"/*.conf
    do
        [[ -f "$_f" ]] || continue
        _f="${_f##*/}"
        printf '%s\n' "${_f%.conf}"
    done | sort
}

# tac_host_profile_file <id> — print the profile's path, or rc 1.
tac_host_profile_file() {
    local _id="${1:-}" _root _f
    _root="$(tac_host_profile_root)" || return 2   # 2 = profile directory unreadable
    [[ "$_id" =~ ^[a-z0-9][a-z0-9-]*$ ]] || return 1
    _f="$_root/$_id.conf"
    [[ -f "$_f" ]] || return 1
    printf '%s\n' "$_f"
}

# tac_host_profile_meta <file> <KEY> — one declared metadata value, quotes stripped.
# A read loop rather than sed/grep: this runs at shell start on every new shell.
tac_host_profile_meta() {
    local _file="${1:-}" _key="${2:-}" _line _value
    [[ -f "$_file" && -n "$_key" ]] || return 2   # 2 = no such profile file / no key
    while IFS= read -r _line || [[ -n "$_line" ]]
    do
        case "$_line" in
            "$_key"=*)
                _value="${_line#*=}"
                _value="${_value%\"}"
                _value="${_value#\"}"
                printf '%s\n' "$_value"
                return 0
                ;;
            *) ;;   # every other line (comment, blank, another key) is not this key
        esac
    done < "$_file"
    return 1
}

# tac_host_cpu — this machine's CPU model, a DEVICE-INDEPENDENT identity.
#
# `arch + cuda + render` reads the GPU, and a CI runner in a bare environment cannot
# always see the card.  Measured 2026-11-04 on the arm64 runner: detection read
# `arch=aarch64 cuda=0 render=1`, matched no profile, and install.sh refused — three
# BATS cases failed — while the SAME box in an interactive shell read cuda=1 and matched.
# A box's CPU model is readable through /proc and lscpu with no device access, so a
# profile that declares TAC_HOST_PROFILE_CPU is matched on that identity and the GPU
# facts are not consulted at all.
#
# TAC_HOST_CPU_OVERRIDE states it directly — the suite's seam, and the escape for a box
# whose CPU string cannot be read.
tac_host_cpu() {
    if [[ -n "${TAC_HOST_CPU_OVERRIDE:-}" ]]
    then
        printf '%s\n' "$TAC_HOST_CPU_OVERRIDE"
        return 0
    fi
    local _cpu=""
    if command -v lscpu >/dev/null 2>&1
    then
        # swallow-ok: a best-effort probe guarded by `command -v`; an unreadable lscpu leaves _cpu empty, and every caller treats an empty id as "cannot identify this box" and refuses
        _cpu="$(lscpu 2>/dev/null | sed -n 's/^Model name: *//p' | head -n 1)"
    fi
    if [[ -z "$_cpu" && -r /proc/cpuinfo ]]
    then
        _cpu="$(sed -n 's/^model name[[:space:]]*: //p' /proc/cpuinfo | head -n 1)"
        [[ -n "$_cpu" ]] || _cpu="$(sed -n 's/^Hardware[[:space:]]*: //p' /proc/cpuinfo | head -n 1)"
    fi
    printf '%s\n' "$_cpu"
}

# tac_host_facts — this machine as `arch cuda render` (each 0/1 except arch).
# CUDA is a driver/tool test, not a model list: nvidia-smi on PATH or a device
# node.  A render node is the directory pyopencl/Xe enumerate from.
# TAC_HOST_FACTS_OVERRIDE ("arch cuda render") states the facts directly — the seam
# the suite uses, and the escape for a box whose detection is wrong.
tac_host_facts() {
    local _arch="" _cuda=0 _render=0
    if [[ -n "${TAC_HOST_FACTS_OVERRIDE:-}" ]]
    then
        printf '%s\n' "$TAC_HOST_FACTS_OVERRIDE"
        return 0
    fi
    case "${HOSTTYPE:-}" in
        x86_64|amd64|x64) _arch="x86_64" ;;
        aarch64|arm64)    _arch="aarch64" ;;
        *) ;;   # empty or exotic HOSTTYPE: fall back to uname below
    esac
    if [[ -z "$_arch" ]]
    then
        _arch="$(tac_host_arch)" || return 2   # 2 = unsupported architecture
    fi
    if command -v nvidia-smi >/dev/null 2>&1 \
       || [[ -e /dev/nvidiactl || -e /dev/nvidia0 ]]
    then
        _cuda=1
    fi
    if [[ -d /dev/dri ]]
    then
        _render=1
    fi
    printf '%s %s %s\n' "$_arch" "$_cuda" "$_render"
}

# tac_host_profile_match <id> <arch> <cuda> <render> — rc 0 when the profile
# describes this machine.  An unset CUDA/RENDER line means "this profile does not
# care", which is how a profile stays matchable on a box whose iGPU presence is
# not known yet.
tac_host_profile_match() {
    local _id="${1:-}" _arch="${2:-}" _cuda="${3:-}" _render="${4:-}"
    local _file _parch _pcuda _prender
    _file="$(tac_host_profile_file "$_id")" || return 2   # 2 = no such profile
    _parch="$(tac_host_profile_meta "$_file" TAC_HOST_PROFILE_ARCH)" || return 2   # 2 = profile declares no arch
    # A DECLARED CPU IDENTITY outranks the GPU facts, because the GPU is exactly what a
    # runner may not be able to see (measured 2026-11-04: cuda=0 on the arm64 runner, so
    # no profile matched and install.sh refused).  A profile without this key keeps the
    # arch/CUDA/render match unchanged.
    local _pcpu _cpu_lc _pcpu_lc
    if _pcpu="$(tac_host_profile_meta "$_file" TAC_HOST_PROFILE_CPU)"
    then
        [[ "$_parch" == "$_arch" ]] || return 1
        _cpu_lc="$(tac_host_cpu | tr '[:upper:]' '[:lower:]')"
        _pcpu_lc="$(printf '%s' "$_pcpu" | tr '[:upper:]' '[:lower:]')"
        # An unreadable CPU refuses rather than falling back to the device facts: a
        # wrong profile silently applies another box's lanes and tuning.
        [[ -n "$_cpu_lc" ]] || return 1
        [[ "$_cpu_lc" == *"$_pcpu_lc"* ]] || return 1
        return 0
    fi
    _pcuda="$(tac_host_profile_meta "$_file" TAC_HOST_PROFILE_CUDA)" || _pcuda="any"
    _prender="$(tac_host_profile_meta "$_file" TAC_HOST_PROFILE_RENDER)" || _prender="any"
    [[ "$_parch" == "$_arch" ]] || return 1
    [[ "$_pcuda" == "any" || "$_pcuda" == "$_cuda" ]] || return 1
    [[ "$_prender" == "any" || "$_prender" == "$_render" ]] || return 1
    return 0
}

# tac_host_profile_detect — the profile this machine's facts select.
# rc 2 = none (the facts are printed on stderr), rc 3 = more than one (every
# candidate is named).  Both refuse rather than pick.
tac_host_profile_detect() {
    local _facts _arch _cuda _render _id _matches=()
    _facts="$(tac_host_facts)" || return 2   # 2 = this machine's facts are unreadable
    read -r _arch _cuda _render <<< "$_facts"
    while IFS= read -r _id
    do
        [[ -n "$_id" ]] || continue
        if tac_host_profile_match "$_id" "$_arch" "$_cuda" "$_render"
        then
            _matches+=("$_id")
        fi
    done < <(tac_host_profile_ids)

    case "${#_matches[@]}" in
        0)
            printf 'host-profile: no profile matches this host (arch=%s cuda=%s render=%s)\n' \
                "$_arch" "$_cuda" "$_render" >&2
            printf 'host-profile: add config/hosts.d/<id>.conf, or record the id in ~/.llm/host-profile\n' >&2
            return 2   # 2 = no profile matches this machine
            ;;
        1)
            printf '%s\n' "${_matches[0]}"
            return 0
            ;;
        *)
            printf 'host-profile: %s profiles match this host: %s\n' \
                "${#_matches[@]}" "${_matches[*]}" >&2
            printf 'host-profile: refusing to guess — set LLM_HOST_PROFILE or ~/.llm/host-profile\n' >&2
            return 3   # 3 = ambiguous: more than one profile matches
            ;;
    esac
}

# tac_host_profile_override — the id an operator recorded for this box, if any.
tac_host_profile_override() {
    local _file="${TAC_HOST_PROFILE_FILE:-$HOME/.llm/host-profile}" _line
    if [[ -n "${LLM_HOST_PROFILE:-}" ]]
    then
        printf '%s\n' "$LLM_HOST_PROFILE"
        return 0
    fi
    [[ -f "$_file" ]] || return 1
    while IFS= read -r _line || [[ -n "$_line" ]]
    do
        _line="${_line%%#*}"
        _line="${_line//[[:space:]]/}"
        [[ -n "$_line" ]] || continue
        printf '%s\n' "$_line"
        return 0
    done < "$_file"
    return 1
}

# tac_host_profile_selected — override first, detection second.  An override that
# names no profile is REFUSED here: a typo must not silently fall back to
# detection and run the wrong box's tuning.
tac_host_profile_selected() {
    local _id
    if _id="$(tac_host_profile_override)"
    then
        if ! tac_host_profile_file "$_id" >/dev/null
        then
            printf 'host-profile: unknown profile "%s" (available: %s)\n' \
                "$_id" "$(tac_host_profile_ids | tr '\n' ' ')" >&2
            return 2   # 2 = unknown profile id (a typo never falls back to detection)
        fi
        printf '%s\n' "$_id"
        return 0
    fi
    tac_host_profile_detect
}

# tac_host_profile_apply — source the selected profile and export what the rest of
# the console reads.  When no profile applies it says so ONCE, sets
# TAC_HOST_PROFILE=generic and TAC_HOST_PROFILE_MATCHED=0, and returns 0: a shell
# must not fail to open because a box is unrecognised (its generic defaults below
# still work), and callers that need strictness — the installer — ask
# tac_host_profile_selected instead.  TAC_HOST_PROFILE_MATCHED is the signal.
#
# Profile files use `: "${VAR:=value}"` so an explicit environment value still
# wins, and the applier marks each export as set by the profile only when the
# profile actually declared it.
#
# PROFILE-OWNED FACTS are cleared before the profile is sourced.  They are not
# user knobs: they describe a machine.  An exported value inherited from a parent
# shell is a SNAPSHOT of whichever profile that shell resolved, so letting it win
# hands this process a foreign box's lanes, labels or sizing fallback — measured
# 2026-10-30, when a console-started window exported the intel profile's five-lane
# table into every child and the arm64 profile could no longer take effect.  The
# documented knobs (LLAMA_DRIVE_ROOT, LLAMA_GPU_LAYERS, LLAMA_CPU_THREADS,
# LLAMA_FIT_TARGET_MB, LLAMA_CACHE_RAM_MB) are deliberately NOT cleared: those are
# the values an operator is told to export.
# tac_host_gpu_pool_bytes — the GPU-addressable pool for THIS boot, in bytes; 1 when
# the card cannot be read.  Measured, never assumed: the OS/GPU split is made at boot
# and it moves (81920 MiB with Windows at 46.5 GB on the 2026-11-02 boot; 98304 MiB
# with Windows at 30.5 GB on 2026-11-03), so a constant would be stale after one
# restart.  Cached per boot_id, so only the first shell of a boot pays for the
# nvidia-smi call; an unwritable cache costs one re-probe per shell and nothing else,
# which is why that write is not fatal — but an unreadable CARD is reported as a
# failure so the caller keeps its own fallback instead of sizing against a guess.
tac_host_gpu_pool_bytes() {
    local _cache _boot _mb _cb _cv
    _cache="${TAC_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/tactical-console}/gpu-pool"
    # No boot_id only costs the cache: the probe below still answers and the write is
    # skipped, so the worst case is one nvidia-smi call per shell.
    # swallow-ok: boot_id is optional — the probe is the answer, the file is only speed
    _boot="$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)" || _boot=""
    if [[ -n "$_boot" && -r "$_cache" ]]
    then
        # A short or unreadable cache line is a MISS, decided by the two checks below;
        # this file is not under `set -e`, so a non-zero read needs no `|| true`.
        read -r _cb _cv < "$_cache"
        if [[ "$_cb" == "$_boot" && "${_cv:-}" =~ ^[0-9]+$ ]]
        then
            printf '%s\n' "$_cv"
            return 0
        fi
    fi
    # An unreadable card returns 1 on the next line, so the caller keeps its own fallback.
    # swallow-ok: an nvidia-smi failure is reported by the `return 1` on the line below
    _mb="$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ')"
    [[ "$_mb" =~ ^[0-9]+$ ]] || return 1
    if [[ -n "$_boot" ]]
    then
        # Failures here are NOT suppressed: an unwritable state dir costs a re-probe per
        # shell and nothing else, but it usually means something larger is broken (the
        # same directory holds LLM_STATE_DIR), so bash's own message is worth seeing.
        mkdir -p "${_cache%/*}"
        printf '%s %s\n' "$_boot" "$(( _mb * 1048576 ))" > "$_cache"
    fi
    printf '%s\n' "$(( _mb * 1048576 ))"
}

# tac_host_profile_apply — clear the profile-owned facts, select a profile, source it and
# export what the rest of the console reads.  Called once per shell.
tac_host_profile_apply() {
    local _id _file _facts _arch _cuda _render _pool
    unset LLAMA_LANE_SPECS LLAMA_LANE_KEEP_UNITS LLAMA_CUDA_LANE_UNIT LLAMA_GPU_FREE_THRESHOLD_MIB \
          LLM_AUTOTUNE_BASELINE_GAP_MAX LLM_AUTOTUNE_CENSUS LLM_AUTOTUNE_CENSUS_MAX_MIB \
          LLAMA_THREAD_CAP LLAMA_CUDA_SERVER_BIN LLM_SERVICE_PORT TAC_HOST_PRIMARY_LANE \
          VRAM_TOTAL_BYTES_FALLBACK TAC_HOST_GPU_LABEL TAC_HOST_IGPU_LABEL \
          TAC_HOST_PROFILE_XE TAC_HOST_PROFILE_DESCRIPTION \
          TAC_HOST_PROFILE_SHARED_MEMORY TAC_HOST_PROFILE_MODEL_STORE_IS_MOUNT \
          LLAMA_MODEL_DIR LLAMA_ARCHIVE_DIR \
          LLM_REGISTRY LLM_DEFAULT_FILE LLM_STATE_DIR \
          HF_HOME HF_HUB_CACHE \
          LLAMA_QUANT_GUIDE_REL QUANT_GUIDE
    # Measured per boot.  DELIBERATELY NOT in the clear list above: those clear because a
    # profile constant describes a machine identity, so a parent's value is a foreign
    # box's fact.  This is a per-boot MEASUREMENT, and no shell can outlive the boot it
    # was started in, so inheritance within a boot is the same number — while clearing it
    # would discard a caller's explicit value (a fallback path, a test, an operator).
    if _pool="$(tac_host_gpu_pool_bytes)"
    then
        : "${TAC_HOST_GPU_POOL_BYTES:=$_pool}"
        export TAC_HOST_GPU_POOL_BYTES
    fi
    _facts="$(tac_host_facts)" || _facts=""
    if [[ -n "$_facts" ]]
    then
        read -r _arch _cuda _render <<< "$_facts"
        TAC_HOST_ARCH="$_arch"; export TAC_HOST_ARCH
        TAC_HOST_CUDA="$_cuda"; export TAC_HOST_CUDA
        TAC_HOST_RENDER_NODE="$_render"; export TAC_HOST_RENDER_NODE
    fi

    if ! _id="$(tac_host_profile_selected)"
    then
        TAC_HOST_PROFILE="generic"
        TAC_HOST_PROFILE_MATCHED=0
        export TAC_HOST_PROFILE TAC_HOST_PROFILE_MATCHED
        if [[ -z "${__TAC_HOST_PROFILE_WARNED:-}" ]]
        then
            printf '[tac] host profile: none selected — generic defaults in use (see tools/host-profile.sh)\n' >&2
            __TAC_HOST_PROFILE_WARNED=1
        fi
        return 0
    fi

    _file="$(tac_host_profile_file "$_id")" || return 1
    # shellcheck source=/dev/null
    source "$_file"

    TAC_HOST_PROFILE="$_id"
    TAC_HOST_PROFILE_MATCHED=1
    export TAC_HOST_PROFILE TAC_HOST_PROFILE_MATCHED
    export LLAMA_DRIVE_ROOT LLAMA_GPU_LAYERS LLAMA_FIT_TARGET_MB \
           LLAMA_CACHE_RAM_MB LLAMA_LANE_SPECS LLAMA_LANE_KEEP_UNITS LLAMA_CUDA_LANE_UNIT \
           LLAMA_GPU_FREE_THRESHOLD_MIB LLM_AUTOTUNE_BASELINE_GAP_MAX \
           LLM_AUTOTUNE_CENSUS LLM_AUTOTUNE_CENSUS_MAX_MIB LLAMA_THREAD_CAP \
           LLAMA_CUDA_SERVER_BIN LLM_SERVICE_PORT \
           LLAMA_MODEL_DIR LLAMA_ARCHIVE_DIR \
           LLM_REGISTRY LLM_STATE_DIR \
           HF_HOME HF_HUB_CACHE \
           TAC_HOST_PRIMARY_LANE VRAM_TOTAL_BYTES_FALLBACK TAC_HOST_GPU_LABEL \
           TAC_HOST_IGPU_LABEL TAC_HOST_PROFILE_XE TAC_HOST_PROFILE_DESCRIPTION \
           TAC_HOST_PROFILE_SHARED_MEMORY TAC_HOST_PROFILE_MODEL_STORE_IS_MOUNT
    # The quant guide is a PATH, and `""` is meaningful (this host has no guide),
    # so an empty value is exported as empty rather than skipped.
    QUANT_GUIDE=""
    if [[ -n "${LLAMA_QUANT_GUIDE_REL:-}" ]]
    then
        QUANT_GUIDE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/${LLAMA_QUANT_GUIDE_REL}"
    fi
    export QUANT_GUIDE
    return 0
}

# tac_host_unit_profile <unit-file> — the profile a systemd unit belongs to, from
# its `# install-profile: <id>` line.  No line means `any` (shared infrastructure:
# watchdogs, timers, samplers).  install.sh uses this so a box never links a lane
# it cannot serve.
tac_host_unit_profile() {
    local _file="${1:-}" _line
    [[ -f "$_file" ]] || return 2   # 2 = no such unit file
    while IFS= read -r _line || [[ -n "$_line" ]]
    do
        case "$_line" in
            '# install-profile:'*)
                _line="${_line#*:}"
                _line="${_line//[[:space:]]/}"
                printf '%s\n' "${_line:-any}"
                return 0
                ;;
            *) ;;   # not the marker line: keep reading
        esac
    done < "$_file"
    printf 'any\n'
}

# end of file
