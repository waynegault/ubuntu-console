#!/usr/bin/env bash
# shellcheck shell=bash
# ==============================================================================
# test-state-sandbox.sh — point every LLM path a test can write at a throwaway root.
# ==============================================================================
# THE DEFECT (measured 2026-11-19).  The operator's shell exports the live paths
# (env.sh: LLM_STATE_DIR=/home/wayne/models/.llm, LLM_REGISTRY=.../models.conf,
# LLAMA_MODEL_DIR=.../active), and the test runner inherited them.  A suite that did
# not pin all of them wrote the box's own store:
#   * 631 of 782 files in ~/models/.llm/backups were Alpha/Beta/Gamma scan fixtures
#     (scripts/11e-llm-model.sh's _scan_backup_dir follows LLM_STATE_DIR);
#   * 286 rows-999 logs sat in ~/models/.llm/autotune-logs;
#   * autotune-failures.tsv carried stub.gguf failure tallies;
#   * a 0-byte ~/models/active/beta.gguf appeared in the model store.
#
# AGENTS.md §4 bans production writes from tests.  Pinning one suite works only until
# the next suite is written, so the chokepoint is the RUNNER: it hands every suite a
# sandbox, and a suite that genuinely needs the live paths must export them itself.
# The suites proven to write (14, 92, 08, 68) also pin their own, so a direct
# `bats tests/unit/<suite>.bats` is safe without the runner.
#
# NOT a general-purpose tool: <root> must be an absolute temp dir.  A root inside the
# live model store is REFUSED, because a "sandbox" there is still the production tree.
# ==============================================================================
# Module Version: 1
#   v1 (2026-11-19): first cut, after the 2026-11-19 contamination census.

# tac_test_state_sandbox <root> — export a throwaway LLM store under <root>.
# Returns 0 on success, 2 when <root> is missing, relative, or inside the live store.
tac_test_state_sandbox() {
    local root="${1:-}"
    if [[ -z "$root" ]]; then
        printf '%s\n' "tac_test_state_sandbox: a sandbox root is required" >&2
        return 2
    fi
    # Absolute: a suite that `cd`s must not be able to drag the sandbox into the repo
    # or, worse, into the live store.
    case "$root" in
        /*) ;;
        *)
            printf '%s\n' "tac_test_state_sandbox: root must be absolute: $root" >&2
            return 2
            ;;
    esac
    # Refuse the live store by name rather than sanding it.  A caller that passes
    # ~/models would otherwise believe it had sandboxed while writing production.
    case "$root" in
        "$HOME/models"|"$HOME/models/"*)
            printf '%s\n' "tac_test_state_sandbox: refusing a sandbox inside the live model store: $root" >&2
            return 2
            ;;
    esac
    export LLM_STATE_DIR="$root/.llm"
    export LLM_REGISTRY="$root/models.conf"
    export LLM_DEFAULT_FILE="$root/default_model.conf"
    export LLAMA_MODEL_DIR="$root/active"
    export TAC_STATE_DIR="$root/tac-state"
    mkdir -p "$LLM_STATE_DIR" "$LLAMA_MODEL_DIR" "$TAC_STATE_DIR" || return 2
    return 0
}

# end of file
