#!/usr/bin/env bats
# llm-archive-unusable.sh - the rule that decides a model is not for this box.
#
# What these pin: a single refusal is NOT a verdict (one strike must not archive),
# a repeated unsupported_arch IS (two strikes archive), a capacity verdict is
# arithmetic against guest RAM, and every shard leaves with its first one.

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    TOOL="$REPO/bin/llm-archive-unusable.sh"
    TMP="$(mktemp -d)"
    mkdir -p "$TMP/active" "$TMP/state"
    export LLAMA_MODEL_DIR="$TMP/active"
    export LLM_ARCHIVE_DIR="$TMP/archived"
    export TAC_STATE_DIR="$TMP/state"
    export LLM_STATE_DIR="$TMP/state/.llm"
    export AUTOTUNE_ARCHIVE_AUTO=1
}

teardown() { rm -rf "$TMP"; }

@test "assess: a small model fits" {
    head -c 3000000 /dev/zero > "$TMP/active/Small.gguf"
    run "$TOOL" --assess "$TMP/active/Small.gguf"
    [ "$status" -eq 0 ]
    [[ "$output" == *"verdict=fits"* ]]
}

@test "assess: a set larger than the guest ceiling is too-big" {
    # Force the ceiling below the file by declaring a tiny reserve-free ceiling.
    head -c 3000000 /dev/zero > "$TMP/active/Big.gguf"
    export AUTOTUNE_ARCHIVE_RESERVE_MIB=999999999
    run "$TOOL" --assess "$TMP/active/Big.gguf"
    [ "$status" -eq 3 ]
    [[ "$output" == *"verdict=too-big"* ]]
}

@test "one unsupported_arch failure does NOT archive" {
    head -c 1000 /dev/zero > "$TMP/active/Bad.gguf"
    run "$TOOL" --record-failure "$TMP/active/Bad.gguf" --class unsupported_arch
    [ "$status" -eq 0 ]
    [[ "$output" == *"archive-eligible=no"* ]]
    [ -f "$TMP/active/Bad.gguf" ]
}

@test "a second unsupported_arch archives and records why" {
    head -c 1000 /dev/zero > "$TMP/active/Bad.gguf"
    run "$TOOL" --record-failure "$TMP/active/Bad.gguf" --class unsupported_arch
    run "$TOOL" --record-failure "$TMP/active/Bad.gguf" --class unsupported_arch
    [ "$status" -eq 0 ]
    [[ "$output" == *"archive-eligible=yes"* ]]
    [ ! -f "$TMP/active/Bad.gguf" ]
    [ -f "$TMP/archived/Bad.gguf" ]
    grep -q 'unsupported_arch x2' "$TMP/state/.llm/autotune-archive.log"
    grep -q 'Bad.gguf|' "$TMP/state/autotune-retired.rows"
}

@test "a resource_exhausted failure never archives, however often it repeats" {
    head -c 1000 /dev/zero > "$TMP/active/Oom.gguf"
    for _ in 1 2 3; do
        run "$TOOL" --record-failure "$TMP/active/Oom.gguf" --class resource_exhausted
        [[ "$output" == *"archive-eligible=no"* ]]
    done
    [ -f "$TMP/active/Oom.gguf" ]
}

@test "every shard of a split model moves with the first" {
    for i in 1 2 3; do head -c 1000 /dev/zero > "$TMP/active/Split-0000$i-of-00003.gguf"; done
    run "$TOOL" --archive "$TMP/active/Split-00001-of-00003.gguf" --reason "test: split set"
    [ "$status" -eq 0 ]
    [ -z "$(ls -A "$TMP/active")" ]
    [ "$(ls "$TMP/archived" | wc -l)" -eq 3 ]
}

@test "archive without --yes is refused when auto is off" {
    head -c 1000 /dev/zero > "$TMP/active/Keep.gguf"
    export AUTOTUNE_ARCHIVE_AUTO=0
    run "$TOOL" --archive "$TMP/active/Keep.gguf" --reason "test"
    [ "$status" -ne 0 ]
    [ -f "$TMP/active/Keep.gguf" ]
}
