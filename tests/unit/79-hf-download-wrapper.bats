#!/usr/bin/env bats
# ==============================================================================
# Unit — the console's `hf` wrapper (scripts/04-aliases.sh)
# ==============================================================================
# Requirement (Wayne, 2026-11-05): a new LLM model must land in the active model
# store whether it is pulled with `hf` or with `model download`, so a serving lane
# can be pointed at it.  The expected destination comes from docs/llm.md "Where a
# download lands" — $LLAMA_MODEL_DIR, flat — not from the wrapper's own output.
#
# Each case catches one concrete wrong outcome:
#   - a single-file download left nested in the hub cache (the pre-wrapper behaviour)
#   - an --include download bypassing llm-pull's stage-and-move
#   - a bare repo download silently filling the store with models--* trees
#   - a caller's explicit --local-dir being rewritten (llm-pull's own staged pull)
#   - a non-GGUF or non-model download being dragged into the model store
#
# Hermetic: `hf` and `llm-pull` are stubs that only record their argv; nothing
# contacts Hugging Face and no real binary is executed.
# ==============================================================================

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    export HOME="$BATS_TEST_TMPDIR/home"
    export TAC_CACHE_DIR="$BATS_TEST_TMPDIR/cache"
    mkdir -p "$HOME" "$TAC_CACHE_DIR"

    # shellcheck source=env.sh
    source "$REPO_ROOT/env.sh"

    # The host profile names the real store; pin it into the sandbox so the case
    # asserts the path the wrapper actually uses, not this box's ~/models/active.
    MODEL_DIR="$BATS_TEST_TMPDIR/models-active"
    mkdir -p "$MODEL_DIR"
    export LLAMA_MODEL_DIR="$MODEL_DIR"
    export HF_HUB_CACHE="$MODEL_DIR"

    STUB_DIR="$BATS_TEST_TMPDIR/stubs"
    mkdir -p "$STUB_DIR"
    export HF_CALL_LOG="$BATS_TEST_TMPDIR/hf-calls"
    export PULL_CALL_LOG="$BATS_TEST_TMPDIR/pull-calls"
    : > "$HF_CALL_LOG"
    : > "$PULL_CALL_LOG"

    cat > "$STUB_DIR/hf" <<'STUB'
#!/usr/bin/env bash
{ printf 'hf:'; printf ' %s' "$@"; printf '\n'; } >> "$HF_CALL_LOG"
STUB
    cat > "$STUB_DIR/llm-pull" <<'STUB'
#!/usr/bin/env bash
{ printf 'dir=%s' "${LLM_MODELS_DIR:-}"; printf ' %s' "$@"; printf '\n'; } >> "$PULL_CALL_LOG"
STUB
    chmod +x "$STUB_DIR/hf" "$STUB_DIR/llm-pull"
    export PATH="$STUB_DIR:$PATH"
}

@test "hf download <repo> <file.gguf> lands flat in the model store" {
    run hf download Qwen/Qwen3-8B-GGUF Qwen3-8B-Q4_K_M.gguf
    [ "$status" -eq 0 ]

    run grep -qF -- "--local-dir $MODEL_DIR" "$HF_CALL_LOG"
    [ "$status" -eq 0 ]
}

@test "hf download --include is routed through llm-pull, flat into the store" {
    run hf download unsloth/GLM-4.5-Air-GGUF \
        --include '*UD-Q4_K_XL-0000*-of-00002.gguf' --revision main
    [ "$status" -eq 0 ]

    run grep -qF -- "dir=$MODEL_DIR unsloth/GLM-4.5-Air-GGUF *UD-Q4_K_XL-0000*-of-00002.gguf --revision main" \
        "$PULL_CALL_LOG"
    [ "$status" -eq 0 ]

    # The real hf must not run for this shape, or the store gains a nested copy too.
    [ ! -s "$HF_CALL_LOG" ]
}

@test "a bare repo download warns that it nests and adds no --local-dir" {
    run hf download Qwen/Qwen3-8B-GGUF
    [ "$status" -eq 0 ]
    [[ "$output" == *"NESTED under $MODEL_DIR"* ]]

    run grep -qF -- "--local-dir" "$HF_CALL_LOG"
    [ "$status" -ne 0 ]
}

@test "two --include flags are not flattened through llm-pull" {
    run hf download owner/repo --include '*.gguf' --include '*.json'
    [ "$status" -eq 0 ]

    # llm-pull takes one glob; delegating would silently drop the first.
    [ ! -s "$PULL_CALL_LOG" ]
    run grep -qF -- "--include" "$HF_CALL_LOG"
    [ "$status" -eq 0 ]
}

@test "an explicit --local-dir is passed through untouched" {
    run hf download owner/repo model.gguf --local-dir /tmp/elsewhere
    [ "$status" -eq 0 ]

    run grep -qxF -- "hf: download owner/repo model.gguf --local-dir /tmp/elsewhere" \
        "$HF_CALL_LOG"
    [ "$status" -eq 0 ]
}

@test "a non-GGUF file is not dragged into the model store" {
    run hf download owner/repo config.json
    [ "$status" -eq 0 ]

    run grep -qF -- "--local-dir" "$HF_CALL_LOG"
    [ "$status" -ne 0 ]
}

@test "a dataset download is left to hf" {
    run hf download owner/data --repo-type dataset
    [ "$status" -eq 0 ]

    run grep -qF -- "--local-dir" "$HF_CALL_LOG"
    [ "$status" -ne 0 ]
}

@test "other hf subcommands are not parsed" {
    run hf auth whoami
    [ "$status" -eq 0 ]

    run grep -qxF -- "hf: auth whoami" "$HF_CALL_LOG"
    [ "$status" -eq 0 ]
}
