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
# Module Version: 1
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
tac_host_profile_apply() {
    local _id _file _facts _arch _cuda _render
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
           LLAMA_CACHE_RAM_MB LLAMA_LANE_SPECS LLM_SERVICE_PORT \
           TAC_HOST_PRIMARY_LANE VRAM_TOTAL_BYTES_FALLBACK TAC_HOST_GPU_LABEL \
           TAC_HOST_IGPU_LABEL TAC_HOST_PROFILE_XE TAC_HOST_PROFILE_DESCRIPTION
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
