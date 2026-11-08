#!/usr/bin/env bats
# ==============================================================================
# Unit — the split-GGUF staging gate is a RUNTIME comparison, not a box property
# ==============================================================================
# WHY THIS EXISTS (2026-11-08).  Two tombstone rows in autotune-retired.rows asserted
# their hold-out against a fixed host size ("against host avail 7,922 MiB on a 29.8
# GiB-RAM box"), and both premises died with the 2026-11-08 reboot: VRAM fell 8 GiB
# while RAM total did not move at all.  The gate itself was always correct — it takes
# MemAvailable as an ARGUMENT — so what needed pinning is the property that makes the
# sentence wrong when the box changes: the same shard passes or fails purely as a
# function of the available figure handed in, with no stored size anywhere.
#
# MEASURED PROOF on today's box (2026-11-08T12:5xZ, host avail 58,225 MiB):
#   Qwen3.8-Flash-Next-GSQ-RCO-IQ1_M largest shard 28,236 MiB -> FITS
#   Ripple-65B-Preview-Q5_K_M        largest shard 38,139 MiB -> FITS
# Both were REFUSED on 2026-11-07 with 7,922 MiB and 5,686 MiB available.  Same files,
# same predicate, opposite verdicts — the pool moved, not the model.
#
# FALSIFICATION: if the predicate ever caches or embeds a host size, the two "same
# shard, two readings" cases diverge and this fails.
# ==============================================================================

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    export REPO_ROOT
    # Only the two predicates: 11b is a large module and this test needs no GPU.
    eval "$(sed -n '/^function __autotune_staging_fits/,/^}/p' \
                 "$REPO_ROOT/scripts/11b-llm-autotune.sh")"
    eval "$(sed -n '/^function __autotune_staged_shard_bytes/,/^}/p' \
                 "$REPO_ROOT/scripts/11b-llm-autotune.sh")"
    SANDBOX="$(mktemp -d)"
    export SANDBOX
    MIB=$(( 1024 * 1024 ))
}

teardown() {
    cd /
    rm -rf "$SANDBOX"
}

@test "the predicates loaded (a silent eval failure would pass every case below)" {
    declare -f __autotune_staging_fits >/dev/null
    declare -f __autotune_staged_shard_bytes >/dev/null
}

@test "the real 28,236 MiB shard: refused at 2026-11-07's 7,922 MiB, fits at today's 58,225 MiB" {
    local shard=$(( 28236 * MIB ))
    ! __autotune_staging_fits "$shard" $(( 7922 * MIB )) $(( 4096 * MIB ))
    __autotune_staging_fits "$shard" $(( 58225 * MIB )) $(( 4096 * MIB ))
}

@test "the real 38,139 MiB shard: refused at 5,686 MiB, fits at 58,225 MiB" {
    local shard=$(( 38139 * MIB ))
    ! __autotune_staging_fits "$shard" $(( 5686 * MIB )) $(( 4096 * MIB ))
    __autotune_staging_fits "$shard" $(( 58225 * MIB )) $(( 4096 * MIB ))
}

@test "the margin is applied, not decorative: the same shard flips when only the margin grows" {
    # Exactly on the boundary: 10,000 + 4,096 == 14,096 fits, one more MiB of margin does not.
    local shard=$(( 10000 * MIB )) avail=$(( 14096 * MIB ))
    __autotune_staging_fits "$shard" "$avail" $(( 4096 * MIB ))
    ! __autotune_staging_fits "$shard" "$avail" $(( 4097 * MIB ))
}

@test "an explicit single file stages nothing, so it is never refused however small the host" {
    local f="$SANDBOX/single.gguf"
    head -c 2048 /dev/zero > "$f"
    [ "$(__autotune_staged_shard_bytes "$f")" = "0" ]
}

@test "a split set reports its LARGEST shard, not the named one" {
    local stem="$SANDBOX/model-0000"
    head -c 1000 /dev/zero > "${stem}1-of-00002.gguf"
    head -c 5000 /dev/zero > "${stem}2-of-00002.gguf"
    [ "$(__autotune_staged_shard_bytes "${stem}1-of-00002.gguf")" = "5000" ]
}

# end of file
