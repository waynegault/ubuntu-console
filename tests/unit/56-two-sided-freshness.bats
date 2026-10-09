#!/usr/bin/env bats
# ==============================================================================
# 56-two-sided-freshness.bats — a cache mtime in the FUTURE must not read as fresh
# ==============================================================================
# Criterion (peer commit 4717b4be, completed here): an age computed as `now - mtime`
# against a ONE-sided bound lets a future mtime — a clock step, or an explicit
# backdate — make the age NEGATIVE and trip the bound the WRONG way, so a stale cache
# is served as fresh. Every freshness bound must be two-sided.
#
# These cases drive the REAL helpers with a file whose mtime is in the future and
# assert the verdict flips.  Each case states the wrong outcome it catches; the
# control case in each pair proves the same helper STILL honours a genuinely young
# cache, so a helper that simply always said "stale" would fail them.
#
# COVERED: __cache_fresh (07), __tac_probe_ok (01), __cache_age_suffix (07) and
# __oc_nas_resolve_host (09d).  NOT covered here, and driven by no suite: the inline
# guard in scripts/08-maintenance.sh:1373, scripts/09a-oc-gateway.sh:95,
# scripts/09e-oc-health.sh and scripts/12-dashboard-help.sh:237 — each needs its own
# command harness; their sites received the same two-sided fix by hand.
# ==============================================================================

setup_file() {
    export REPO_ROOT
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
}

setup() {
    export REPO_ROOT
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    export TAC_CACHE_DIR="$BATS_TEST_TMPDIR/cache"
    mkdir -p "$TAC_CACHE_DIR"
    export __TAC_INITIALIZED=1
    # shellcheck source=env.sh
    source "$REPO_ROOT/env.sh" >/dev/null 2>&1 || true
}

# ── __cache_fresh (07-telemetry) — the shared helper behind six call sites ────

@test "freshness: __cache_fresh rejects a cache dated in the FUTURE" {
    # Wrong outcome caught: a future mtime makes the age negative, and a one-sided
    # `(( _now - _ts < _ttl ))` then reads it as FRESH.
    local c="$TAC_CACHE_DIR/future"
    : > "$c"
    touch -d '+1 hour' "$c"
    run __cache_fresh "$c" 3600
    [ "$status" -eq 1 ]
}

@test "freshness: control — __cache_fresh still honours a young cache" {
    local c="$TAC_CACHE_DIR/young"
    : > "$c"
    run __cache_fresh "$c" 3600
    [ "$status" -eq 0 ]
}

# ── __tac_probe_ok (01-constants) — a cached probe result ────────────────────

@test "freshness: __tac_probe_ok re-probes when its cache is dated in the FUTURE" {
    # Wrong outcome caught: the cached "1" is honoured and the (failing) probe is
    # never run, so a future-dated cache reports success.
    printf '1\n' > "$TAC_CACHE_DIR/probe"
    touch -d '+1 hour' "$TAC_CACHE_DIR/probe"
    run __tac_probe_ok probe 3600 false
    [ "$status" -eq 1 ]
}

@test "freshness: control — __tac_probe_ok honours a young cached value" {
    printf '1\n' > "$TAC_CACHE_DIR/probe2"
    run __tac_probe_ok probe2 3600 false
    [ "$status" -eq 0 ]
}

# ── __cache_age_suffix (07-telemetry) — the rendered staleness marker ─────────

@test "freshness: __cache_age_suffix marks a FUTURE mtime as STALE" {
    # Wrong outcome caught: the value renders with NO marker, so a cache dated in
    # the future is displayed as current.
    local c="$BATS_TEST_TMPDIR/age-future"
    : > "$c"
    touch -d '+1 hour' "$c"
    run __cache_age_suffix "$c" 60
    [ "$status" -eq 0 ]
    [[ "$output" == *STALE* ]]
}

@test "freshness: control — __cache_age_suffix leaves a young cache unmarked" {
    local c="$BATS_TEST_TMPDIR/age-young"
    : > "$c"
    run __cache_age_suffix "$c" 60
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

# ── __oc_nas_resolve_host (09d) — the run-time NAS route ─────────────────────

@test "nas route: __oc_nas_resolve_host defaults to the LAN address without OC_NAS_HOST" {
    unset OC_NAS_HOST
    run __oc_nas_resolve_host /nonexistent-key u 1
    [ "$status" -eq 0 ]
    [ "$output" = "192.168.33.20" ]
}

@test "nas route: __oc_nas_resolve_host lets OC_NAS_HOST win" {
    export OC_NAS_HOST=nas.example
    run __oc_nas_resolve_host /nonexistent-key u 1
    [ "$status" -eq 0 ]
    [ "$output" = "nas.example" ]
    unset OC_NAS_HOST
}
