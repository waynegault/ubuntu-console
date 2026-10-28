#!/usr/bin/env bash
# shellcheck shell=bash
# ==============================================================================
# arch.sh — this host's architecture, resolved once.
# ==============================================================================
# Every pinned download in this repo names its asset PER ARCHITECTURE
# (shellcheck `linux.x86_64` / `linux.aarch64`, gitleaks `linux_x64` /
# `linux_arm64`, llama.cpp `ubuntu-x64` / `ubuntu-arm64`).  Each installer maps
# its own upstream spelling, but all of them must agree on what the HOST is, so
# the host reading lives here rather than being re-derived with `uname -m` at
# each call site.
#
# Two architectures are supported: x86_64 and aarch64.  Anything else is
# REFUSED (exit 2, reason on stderr), never mapped onto a neighbouring name:
# an installer that guesses installs a binary the CPU cannot execute, and the
# failure surfaces later as "Exec format error" far from the cause.
#
# Source it; it defines functions only and has no side effects:
#   source "$(dirname "$0")/arch.sh"
#   host_arch="$(tac_host_arch)"
# ==============================================================================
# AI INSTRUCTION: Increment version on significant changes.
# Module Version: 1
#   v1 (2026-10-28): first cut — the host architecture in one place, so the
#   installers stop assuming x86_64.
# ==============================================================================

# tac_host_arch — print `x86_64` or `aarch64`.
# The accepted spellings are the ones `uname -m` and the release assets actually
# use: amd64/x86_64/x64 are the same machine, as are arm64/aarch64.  An
# unreadable or unsupported machine prints the reason on stderr and returns 2.
tac_host_arch() {
    local machine
    if ! machine="$(uname -m)"
    then
        printf 'arch: uname -m failed — cannot determine the host architecture\n' >&2
        # 2 = usage: no addressable architecture (callers exit with the same code).
        return 2
    fi
    case "$machine" in
        x86_64|amd64|x64)
            printf '%s\n' x86_64
            ;;
        aarch64|arm64)
            printf '%s\n' aarch64
            ;;
        *)
            printf 'arch: unsupported architecture: %s (supported: x86_64, aarch64)\n' \
                "$machine" >&2
            # 2 = usage: an architecture no pinned asset is named for.
            return 2
            ;;
    esac
}

# end of file
