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
# Module Version: 2
#   v2 (2026-11-19): every refusal is return 1 through _tac_sandbox_refuse, one stderr
#   path, and the absolute-path case states why it has no `*)` arm — three count
#   ratchets (9.7, 10.7, 4.2.4) caught the first cut's shape.
#   v1 (2026-11-19): first cut, after the 2026-11-19 contamination census.

# _tac_sandbox_refuse <reason> — the ONE stderr path, so every refusal has one shape.
_tac_sandbox_refuse() {
    printf '%s\n' "tac_test_state_sandbox: $1" >&2
}

# tac_test_state_sandbox <root> — export a throwaway LLM store under <root>.
# Returns 0 on success and 1 on any refusal — the caller's only decision is "may a
# suite run", and a distinct code per refusal would be a vocabulary nothing reads.
# Every refusal is NAMED; a silent 1 would be indistinguishable from a typo.
tac_test_state_sandbox() {
    local root="${1:-}"
    if [[ -z "$root" ]]; then
        _tac_sandbox_refuse "a sandbox root is required"
        return 1
    fi
    # Absolute: a suite that `cd`s must not be able to drag the sandbox into the repo
    # or, worse, into the live store.  No `*)` arm on purpose — an absolute path is the
    # ONLY shape accepted, so a wildcard here would be the bug rather than the default.
    case "$root" in
        /*) ;;
        *)
            _tac_sandbox_refuse "root must be absolute: $root"
            return 1
            ;;
    esac
    # Refuse the live store by name rather than sanding it.  A caller that passes
    # ~/models would otherwise believe it had sandboxed while writing production.
    case "$root" in
        "$HOME/models"|"$HOME/models/"*)
            _tac_sandbox_refuse "refusing a sandbox inside the live model store: $root"
            return 1
            ;;
    esac
    export LLM_STATE_DIR="$root/.llm"
    export LLM_REGISTRY="$root/models.conf"
    export LLM_DEFAULT_FILE="$root/default_model.conf"
    export LLAMA_MODEL_DIR="$root/active"
    export TAC_STATE_DIR="$root/tac-state"
    mkdir -p "$LLM_STATE_DIR" "$LLAMA_MODEL_DIR" "$TAC_STATE_DIR" || return 1
    return 0
}

# end of file
