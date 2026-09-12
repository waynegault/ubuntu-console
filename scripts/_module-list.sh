#!/usr/bin/env bash
# shellcheck shell=bash
# ==============================================================================
# _module-list.sh — Canonical module load order (single source of truth).
# ==============================================================================
# AI INSTRUCTION: On ANY change to this file, increment the Module Version below.
# Module Version: 1
#
# Sourced by BOTH loaders so their module sets can never drift:
#   - tactical-console.bashrc (interactive profile)
#   - env.sh (non-interactive library loader)
#
# The thin loaders (09-openclaw, 11-llm-manager) are listed INSTEAD of their
# sub-modules: they source 09a/09c-09f and 11a-11f in dependency order and also
# carry load-time logic (the OpenClaw availability probe, the
# __LLAMA_DRIVE_MOUNTED fallback), so listing them avoids double-sourcing and
# keeps that logic on both paths. 09b-gog is listed separately because
# 09-openclaw does not source it. 13-init is listed for the interactive loader;
# env.sh skips it (its side-effects are interactive-only).
#
# Underscore prefix: NOT a numbered module. Not matched by the module globs
# ([0-9][0-9]-*.sh / [0-9][0-9][a-z]-*.sh), so it is only ever sourced
# explicitly by the two loaders above.
# ==============================================================================

# __tac_module_list — Print the canonical module names, in load order, one per
# line. Loaders read it with: mapfile -t arr < <(__tac_module_list)
function __tac_module_list() {
    printf '%s\n' \
        01-constants \
        02-error-handling \
        03-design-tokens \
        04-aliases \
        05-ui-engine \
        06-hooks \
        07-telemetry \
        08-maintenance \
        09-openclaw \
        09b-gog \
        10-deployment \
        11-llm-manager \
        12-dashboard-help \
        13-init \
        14-wsl-extras \
        15-model-recommender
}

# end of file
