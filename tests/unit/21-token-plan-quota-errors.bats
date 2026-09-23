#!/usr/bin/env bats
# ==============================================================================
# Unit — tpq must say WHY, not just "unexpected response"
# ==============================================================================
# Why: the probe handled 429/200/401/000 and threw the response BODY away for
# anything else, so an entire entitlement state read as an unnamed glitch.
# Measured 2026-09-22: every Token Plan model returned `403
# AccessDenied.Unpurchased` — the key authenticated (`GET /models` was 200) but no
# plan was active for it, which a status code alone cannot distinguish from a
# transient fault.
#
# Hermetic: a stub `curl` prints a canned body + status code, and HOME /
# TAC_CACHE_DIR are temp, so nothing here reaches the network or the real cache.
# ==============================================================================

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    TAC_TEST_TMPDIR="$(mktemp -d)"
    export TAC_TEST_TMPDIR
    export HOME="$TAC_TEST_TMPDIR/home"
    export TAC_CACHE_DIR="$TAC_TEST_TMPDIR/cache"
    mkdir -p "$HOME" "$TAC_CACHE_DIR"

    export CURL_STUB_DIR="$TAC_TEST_TMPDIR/stub"
    mkdir -p "$CURL_STUB_DIR"
    cat > "$CURL_STUB_DIR/curl" <<'STUB'
#!/usr/bin/env bash
# Stub curl. Like `-w '\n%{http_code}'`: the body, then the status on its own
# final line. The probe's own arguments are irrelevant to the stub.
printf '%s\n%s\n' "$STUB_BODY" "$STUB_CODE"
STUB
    chmod 755 "$CURL_STUB_DIR/curl"
    export PATH="$CURL_STUB_DIR:$PATH"
    export BAILIAN_TOKEN_PLAN_API_KEY="sk-sp-test"

    # shellcheck source=env.sh
    source "$REPO_ROOT/env.sh"

    # Bypass the probe's TTL cache. §1 sets TAC_CACHE_DIR unconditionally to /dev/shm
    # (an exported override is ignored), and `jq empty` ACCEPTS the probe's
    # "body\n<status>" output as a two-value JSON stream — so the result really is
    # cached, in a location every concurrent suite shares, and the second case would
    # read the first case's body. The classification is what this file tests, so run
    # the command directly.
    __os_fetch_cached() { shift 2; "$@"; }
}

teardown() {
    rm -rf "${TAC_TEST_TMPDIR:-/tmp/bats-noop}"
}

@test "tpq: 403 AccessDenied.Unpurchased is reported as not entitled" {
    export STUB_CODE=403
    export STUB_BODY='{"error":{"message":"Access to model denied. Please make sure you are eligible for using the model.","type":"AccessDenied.Unpurchased","code":"AccessDenied.Unpurchased"}}'

    run __model_token_plan_quota

    [[ "$output" == *"Not entitled"* ]]
    [[ "$output" == *"AccessDenied.Unpurchased"* ]]
    [[ "$output" != *"unexpected response"* ]]
}

@test "tpq: any other error status surfaces the provider's code and message" {
    export STUB_CODE=500
    export STUB_BODY='{"error":{"code":"InternalError","message":"upstream boom"}}'

    run __model_token_plan_quota

    [[ "$output" == *"HTTP 500"* ]]
    [[ "$output" == *"InternalError"* ]]
    [[ "$output" == *"upstream boom"* ]]
}

@test "tpq: a 403 that is not an entitlement state is NOT called 'not entitled'" {
    export STUB_CODE=403
    export STUB_BODY='{"error":{"code":"SomethingElse","message":"blocked by policy"}}'

    run __model_token_plan_quota

    [[ "$output" == *"HTTP 403"* ]]
    [[ "$output" == *"blocked by policy"* ]]
    [[ "$output" != *"Not entitled"* ]]
}

# end of file
