# shellcheck shell=bash
# shellcheck disable=SC1090,SC1091,SC2015,SC2016,SC2034,SC2059,SC2086,SC2154,SC2317
# ─── Module: 09-openclaw ───────────────────────────────────────────────────────
# AI INSTRUCTION: On ANY change to this file, increment the Module Version below.
# TACTICAL_PROFILE_VERSION auto-computes from the sum of all module versions.
# Module Version: 22
# ==============================================================================
# 9. OPENCLAW MANAGER (THIN LOADER)
# ==============================================================================
# This module has been split into sub-modules for maintainability.
# The thin loader sources each sub-module in dependency order.
#
# @modular-section: openclaw
# @depends: constants, design-tokens, ui-engine, hooks
# @exports: so, xo, oc, oc-restart, ocstart, ocstop, oc-purge,
#   ockeys, ocdoc-fix, oc-refresh-keys, oc-backup, oc-restore,
#   oc-agent-use, oc-health, oc-diag, oc-doctor-local, oc-failover,
#   wacli, oc-kgraph, owk, ologs, ocroot, lc, oc-update,
#   oc-cron, oc-skills, oc-plugins, oc-plugin-update, oc-tail,
#   oc-channels, oc-sec, oc-stinger, oc-tui, oc-config, oc-docs,
#   oc-usage, oc-local-llm, oc-sync-models, ocms, oc-browser,
#   oc-nodes, oc-sandbox, oc-env, oc-cache-clear, oc-trust-sync,
#   mem-index, oc-memory-search
# ---------------------------------------------------------------------------

# ── Source sub-modules in dependency order ──────────────────────────────
_MOD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

for _09_mod in \
    09a-oc-gateway \
    09c-oc-core \
    09d-oc-agents \
    09e-oc-health \
    09f-oc-misc
do
    _09_f="$_MOD_DIR/${_09_mod}.sh"
    if [[ -f "$_09_f" ]]; then
        # shellcheck disable=SC1090
        source "$_09_f"
    fi
done
unset _MOD_DIR _09_mod _09_f
