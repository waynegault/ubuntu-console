#!/usr/bin/env bats
# Unit test for oc-refresh-keys using mocks

function __mock_command_local() {
    local cmd="$1"
    local behavior="$2"
    cat > "$MOCK_BIN_DIR/$cmd" << MOCK_EOF
#!/usr/bin/env bash
$behavior
MOCK_EOF
    chmod +x "$MOCK_BIN_DIR/$cmd"
}

setup() {
    export REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    export TAC_TEST_TMPDIR="$(mktemp -d)"
    export TAC_CACHE_DIR="$TAC_TEST_TMPDIR/cache"
    export MOCK_BIN_DIR="$TAC_TEST_TMPDIR/mocks"
    mkdir -p "$TAC_CACHE_DIR"
    mkdir -p "$MOCK_BIN_DIR"
    export PATH="$MOCK_BIN_DIR:$PATH"

    # Clear any stale pwsh bridge warning so the mock is actually tried
    # (sandboxed under TAC_CACHE_DIR — never the real /dev/shm flag).
    rm -f "$TAC_CACHE_DIR/tac_pwsh_bridge_warned"

    # Mock openclaw so SecretRef sync & gateway restart never touch the real config.
    # Capture the `config patch --stdin` payload so tests can assert SecretRefs
    # without invoking the real CLI (refs are batched into one patch call).
    export OC_MOCK_LOG="$TAC_TEST_TMPDIR/openclaw_calls.log"
    export OC_MOCK_PATCH_FILE="$TAC_TEST_TMPDIR/openclaw_patch_stdin.json"
    __mock_command_local openclaw "if [ \"\$*\" = 'config patch --stdin' ]; then cat > \"$OC_MOCK_PATCH_FILE\"; fi; echo \"OPENCLAW_CALL: \$*\" >> \"$OC_MOCK_LOG\"; exit 0"

    # Mock systemctl so we don't touch the real systemd.
    export SYSTEMCTL_LOG="$TAC_TEST_TMPDIR/systemctl_calls.log"
    __mock_command_local systemctl "echo \"SYSTEMCTL_CALL: \$*\" >> \"$SYSTEMCTL_LOG\"; case \"\$*\" in *is-active*) echo active;; esac; exit 0"

    # Mock systemd-run so the deferred gateway restart (step 7) actually runs its
    # payload here.  The real command needs a LIVE user systemd session: without
    # XDG_RUNTIME_DIR + DBUS_SESSION_BUS_ADDRESS it fails with "Failed to connect to
    # bus: No medium found", the restart body never runs, and the mocked openclaw is
    # never invoked — so this file's restart assertions passed only on a machine with
    # a session bus and failed on the CI runner, whose .env sets only LANG.  Same mock
    # as tests/integration/05-refresh-keys.bats.
    __mock_command_local systemd-run 'while [[ "${1:-}" == --* ]]; do shift; done; exec "$@"'

    # Source only required modules for oc-refresh-keys to keep the harness stable.
    # shellcheck source=scripts/01-constants.sh
    source "$REPO_ROOT/scripts/01-constants.sh"
    # shellcheck source=scripts/02-error-handling.sh
    source "$REPO_ROOT/scripts/02-error-handling.sh"
    # shellcheck source=scripts/03-design-tokens.sh
    source "$REPO_ROOT/scripts/03-design-tokens.sh"
    # shellcheck source=scripts/05-ui-engine.sh
    source "$REPO_ROOT/scripts/05-ui-engine.sh"
    # shellcheck source=scripts/_startup-env.sh
    source "$REPO_ROOT/scripts/_startup-env.sh"   # provides __tac_source_submodules
    # shellcheck source=scripts/09-openclaw.sh
    source "$REPO_ROOT/scripts/09-openclaw.sh"

    # Isolate OC_ROOT so tests never touch the real ~/.openclaw.
    export OC_ROOT="$TAC_TEST_TMPDIR/.openclaw"
    mkdir -p "$OC_ROOT"

    # Re-assert sandboxed paths AFTER sourcing: 01-constants.sh unconditionally
    # exports TAC_CACHE_DIR=/dev/shm and derives OC_AGENTS/ErrorLogPath from the
    # real $HOME, so without this the tests would read/write the live bridge
    # cache in /dev/shm and the real error log.
    export TAC_CACHE_DIR="$TAC_TEST_TMPDIR/cache"
    export OC_AGENTS="$OC_ROOT/agents"
    export OC_LOGS="$OC_ROOT/logs"
    export ErrorLogPath="$OC_LOGS/bash-errors.log"
    mkdir -p "$TAC_CACHE_DIR"

    # Keep the harness hermetic: drop anything inherited from the real shell
    # that oc-refresh-keys would act on (NAS mirror preflight, Linux-side merge
    # vars) so the tests never reach the network or depend on host env.
    unset OC_NAS_KEY_PATH OC_NAS_USER OC_NAS_HOST SSH_PASSWORD
    unset CONTEXT7_API_KEY DEVIN_API_KEY OPENCLAW_GATEWAY_TOKEN
    unset QWEN_TOKEN_PLAN_API_KEY

    # OpenClaw-as-authored unit fixture. The refresh must never rewrite it:
    # OpenClaw fingerprints its own unit before a repair and aborts
    # maintenance if the bytes changed.
    mkdir -p "$TAC_TEST_TMPDIR/.config/systemd/user"
    cat > "$TAC_TEST_TMPDIR/.config/systemd/user/openclaw-gateway.service" << 'UNIT'
[Service]
Environment=OPENCLAW_SERVICE_MANAGED_ENV_KEYS=GEMINI_API_KEY
UNIT
    # Override HOME so the unit file path resolves inside the test sandbox.
    export HOME="$TAC_TEST_TMPDIR"
}

teardown() {
    rm -rf "$TAC_TEST_TMPDIR"
}

@test "oc-refresh-keys caches matching Windows vars, syncs gateway env, and calls ssh" {
    local pwsh_log="$TAC_TEST_TMPDIR/pwsh_calls.log"
    __mock_command_local pwsh.exe "echo \"PWSH_CALL: \$*\" >> \"$pwsh_log\"; printf '%s\\n' 'WIN_API_KEY=winsecret' 'WIN_TOKEN=tok123'"

    local nas_key="$TAC_TEST_TMPDIR/nas_key"
    mkdir -p "$(dirname "$nas_key")"
    touch "$nas_key" && chmod 600 "$nas_key"
    export OC_NAS_KEY_PATH="$nas_key"
    export OC_NAS_USER="testuser"
    export OC_NAS_HOST="nas.example"

    local ssh_log="$TAC_TEST_TMPDIR/ssh_calls.log"
    __mock_command_local ssh "echo \"SSH_CALL: \$*\" >> \"$ssh_log\"; exit 0"

    run oc-refresh-keys
    [ "$status" -eq 0 ]

    # Cache is populated.
    [ -f "$TAC_CACHE_DIR/tac_win_api_keys" ]
    run grep -E '^export WIN_API_KEY=' "$TAC_CACHE_DIR/tac_win_api_keys"
    [ "$status" -eq 0 ]
    run grep -E '^export WIN_TOKEN=' "$TAC_CACHE_DIR/tac_win_api_keys"
    [ "$status" -eq 0 ]

    # PowerShell was called with the expected pattern.
    run grep -E 'TOKEN\|API\(_\|-\)\?KEY' "$pwsh_log"
    [ "$status" -eq 0 ]

    # Bridge also matches PASSWORD anywhere in the variable name.
    run grep -F 'PASSWORD' "$pwsh_log"
    [ "$status" -eq 0 ]

    # Bridged vars were pushed to the systemd user manager env — the gateway's
    # secrets channel (the plaintext gateway.systemd.env file is no longer used).
    run grep -F "set-environment WIN_API_KEY=winsecret" "$SYSTEMCTL_LOG"
    [ "$status" -eq 0 ]
    run grep -F "set-environment WIN_TOKEN=tok123" "$SYSTEMCTL_LOG"
    [ "$status" -eq 0 ]

    # The unit is left exactly as OpenClaw authored it (no rewrite, no
    # daemon-reload): bridged values reach the gateway via the manager env
    # asserted above, so the managed-key list never gains WIN_API_KEY/WIN_TOKEN.
    local unit="$HOME/.config/systemd/user/openclaw-gateway.service"
    run grep 'OPENCLAW_SERVICE_MANAGED_ENV_KEYS=' "$unit"
    [ "$status" -eq 0 ]
    [[ "$output" == *GEMINI_API_KEY* ]]
    [[ "$output" != *WIN_API_KEY* ]]
    [[ "$output" != *WIN_TOKEN* ]]
    run grep -F "daemon-reload" "$SYSTEMCTL_LOG"
    [ "$status" -ne 0 ]

    # Gateway restart was triggered (mock systemctl is-active returns 0).
    run grep -F "gateway restart" "$OC_MOCK_LOG"
    [ "$status" -eq 0 ]

    run grep -c '^SSH_CALL:' "$ssh_log"
    [ "$status" -eq 0 ]
    [ "$output" -ge 1 ]
}

@test "oc-refresh-keys syncs OpenClaw SecretRefs and gateway env only for present credentials" {
    # Bridge returns WIN_API_KEY + GEMINI_API_KEY (simulating Windows env).
    # GEMINI_API_KEY is also exported as a shell var to match reality where
    # __bridge_windows_api_keys sources the cache into the shell.
    __mock_command_local pwsh.exe "printf '%s\\n' 'WIN_API_KEY=winsecret' 'GEMINI_API_KEY=test-gemini-key'"
    rm -f "$OC_MOCK_LOG"

    export GEMINI_API_KEY="test-gemini-key"
    unset QWEN_TOKEN_PLAN_API_KEY

    run oc-refresh-keys
    [ "$status" -eq 0 ]

    # Present mapped credential -> one batched `openclaw config patch --stdin`
    # carries the env-backed SecretRef (payload is nested JSON, not dotted paths).
    run grep -F "OPENCLAW_CALL: config patch --stdin" "$OC_MOCK_LOG"
    [ "$status" -eq 0 ]
    run grep -F '"google": {"config": {"webSearch": {"apiKey": {"source": "env", "provider": "default", "id": "GEMINI_API_KEY"' "$OC_MOCK_PATCH_FILE"
    [ "$status" -eq 0 ]

    # Absent (no longer mapped) credential -> no ref written for that path.
    run grep -F 'qwen-token-plan' "$OC_MOCK_LOG" "$OC_MOCK_PATCH_FILE"
    [ "$status" -ne 0 ]

    # Bridged vars were pushed to the systemd user manager env.
    run grep -F "set-environment WIN_API_KEY=winsecret" "$SYSTEMCTL_LOG"
    [ "$status" -eq 0 ]
    run grep -F "set-environment GEMINI_API_KEY=test-gemini-key" "$SYSTEMCTL_LOG"
    [ "$status" -eq 0 ]

    # The unit is never rewritten, so its managed-key list keeps OpenClaw's
    # own value and gains neither the bridged nor the unset var.
    local unit="$HOME/.config/systemd/user/openclaw-gateway.service"
    run grep 'OPENCLAW_SERVICE_MANAGED_ENV_KEYS=' "$unit"
    [ "$status" -eq 0 ]
    [[ "$output" != *WIN_API_KEY* ]]
    [[ "$output" == *GEMINI_API_KEY* ]]
    [[ "$output" != *QWEN_TOKEN_PLAN_API_KEY* ]]
}

@test "oc-refresh-keys skips gateway restart and NAS export when nothing changed" {
    __mock_command_local pwsh.exe "printf '%s\\n' 'WIN_API_KEY=winsecret' 'GEMINI_API_KEY=test-gemini-key'"
    export GEMINI_API_KEY="test-gemini-key"

    local nas_key="$TAC_TEST_TMPDIR/nas_key"
    touch "$nas_key" && chmod 600 "$nas_key"
    export OC_NAS_KEY_PATH="$nas_key"
    export OC_NAS_USER="testuser"
    export OC_NAS_HOST="nas.example"

    local ssh_log="$TAC_TEST_TMPDIR/ssh_calls.log"
    __mock_command_local ssh "echo \"SSH_CALL: \$*\" >> \"$ssh_log\"; exit 0"

    # First refresh: env push + gateway restart + NAS upload + nas hash marker.
    run oc-refresh-keys
    [ "$status" -eq 0 ]
    run grep -F "gateway restart" "$OC_MOCK_LOG"
    [ "$status" -eq 0 ]
    run grep -c '^SSH_CALL:' "$ssh_log"
    [ "$status" -eq 0 ]
    [ "$output" -ge 1 ]
    [ -f "$TAC_CACHE_DIR/tac_win_api_keys.nas_hash" ]

    # Second refresh with identical bridge output: zero side effects — no env
    # push, no restart, no NAS upload.
    : > "$OC_MOCK_LOG"
    : > "$SYSTEMCTL_LOG"
    : > "$ssh_log"
    run oc-refresh-keys
    [ "$status" -eq 0 ]
    run grep -F "gateway restart" "$OC_MOCK_LOG"
    [ "$status" -ne 0 ]
    run grep -F "set-environment" "$SYSTEMCTL_LOG"
    [ "$status" -ne 0 ]
    [ ! -s "$ssh_log" ]
}

@test "oc-refresh-keys retries NAS export after a failed upload" {
    __mock_command_local pwsh.exe "printf '%s\\n' 'WIN_API_KEY=winsecret' 'GEMINI_API_KEY=test-gemini-key'"
    export GEMINI_API_KEY="test-gemini-key"

    local nas_key="$TAC_TEST_TMPDIR/nas_key"
    touch "$nas_key" && chmod 600 "$nas_key"
    export OC_NAS_KEY_PATH="$nas_key"
    export OC_NAS_USER="testuser"
    export OC_NAS_HOST="nas.example"

    local ssh_log="$TAC_TEST_TMPDIR/ssh_calls.log"
    __mock_command_local ssh "echo \"SSH_CALL: \$*\" >> \"$ssh_log\"; exit 1"

    # NAS unreachable: no marker persisted, refresh still exits 0.
    run oc-refresh-keys
    [ "$status" -eq 0 ]
    [ ! -f "$TAC_CACHE_DIR/tac_win_api_keys.nas_hash" ]

    # NAS back: the failed upload is retried and the marker is persisted.
    __mock_command_local ssh "echo \"SSH_CALL: \$*\" >> \"$ssh_log\"; exit 0"
    run oc-refresh-keys
    [ "$status" -eq 0 ]
    [ -f "$TAC_CACHE_DIR/tac_win_api_keys.nas_hash" ]
    run grep -c '^SSH_CALL:' "$ssh_log"
    [ "$status" -eq 0 ]
    [ "$output" -ge 1 ]
}

@test "oc-refresh-keys reports a readiness timeout (not recovery) when restart fails but the unit is active" {
    __mock_command_local pwsh.exe "printf '%s\\n' 'WIN_API_KEY=winsecret'"

    # openclaw: config patch succeeds, but `gateway restart` exits non-zero —
    # simulating the 45s /healthz+/readyz readiness probe timing out on a slow
    # cold start. The unit stays active (systemctl mock returns 0 for is-active).
    __mock_command_local openclaw "if [ \"\$*\" = 'config patch --stdin' ]; then cat > \"$OC_MOCK_PATCH_FILE\"; fi; echo \"OPENCLAW_CALL: \$*\" >> \"$OC_MOCK_LOG\"; case \"\$1 \$2\" in 'gateway restart') exit 1 ;; esac; exit 0"

    run oc-refresh-keys
    [ "$status" -eq 0 ]
    local refresh_out="$output"

    # The restart was attempted...
    run grep -F "OPENCLAW_CALL: gateway restart" "$OC_MOCK_LOG"
    [ "$status" -eq 0 ]

    # ...and because the unit is still active, the message must name the
    # readiness-probe timeout rather than claim a recovery.
    [[ "$refresh_out" == *"readiness probe timed out"* ]]

    # No redundant reset-failed+start was stacked on an already-active unit.
    run grep -F "reset-failed" "$SYSTEMCTL_LOG"
    [ "$status" -ne 0 ]
}

@test "oc-refresh-keys escapes NAS env values with %q only (no double-quote wrap)" {
    # A value containing '!' must round-trip: %q alone yields win\!secret, which
    # sources back to win!secret. Wrapping it in double quotes (the old bug)
    # produced "win\!secret" -> a literal backslash, breaking the NAS collector.
    __mock_command_local pwsh.exe "printf '%s\\n' 'WIN_API_KEY=win!secret'"

    local nas_key="$TAC_TEST_TMPDIR/nas_key"
    touch "$nas_key" && chmod 600 "$nas_key"
    export OC_NAS_KEY_PATH="$nas_key"
    export OC_NAS_USER="testuser"
    export OC_NAS_HOST="nas.example"

    # Capture the first ssh call's stdin (the generated env file).
    local cap="$TAC_TEST_TMPDIR/nas_stdin.txt"
    __mock_command_local ssh "if [ -f \"$cap\" ]; then exit 0; fi; cat > \"$cap\"; exit 0"

    run oc-refresh-keys
    [ "$status" -eq 0 ]
    [ -f "$cap" ]

    run grep -F 'export WIN_API_KEY=win\!secret' "$cap"
    [ "$status" -eq 0 ]

    run grep -F '"win\!secret"' "$cap"
    [ "$status" -ne 0 ]
}

@test "oc-refresh-keys pushes ONLY gateway-resolved vars into the manager env (2026-09-13 narrowing)" {
    # Regression test for the narrowing: the manager env used to receive every
    # bridged Windows var, so every user unit inherited ~45 secrets it never
    # reads (readable by any same-user process via /proc/<pid>/environ). It must
    # now receive only the vars the gateway resolves as secret refs.
    mkdir -p "$HOME/.openclaw"
    cat > "$HOME/.openclaw/openclaw.json" << 'CFG'
{
  "plugins": {
    "entries": {
      "google": {
        "config": {
          "webSearch": {
            "apiKey": { "source": "env", "provider": "default", "id": "GEMINI_API_KEY" }
          }
        }
      }
    }
  }
}
CFG

    # Bridge offers one resolved var (GEMINI_API_KEY) and one that nothing
    # resolves (WIN_API_KEY).
    __mock_command_local pwsh.exe "printf '%s\\n' 'WIN_API_KEY=winsecret' 'GEMINI_API_KEY=test-gemini-key'"
    export GEMINI_API_KEY="test-gemini-key"
    rm -f "$SYSTEMCTL_LOG"

    run oc-refresh-keys
    [ "$status" -eq 0 ]

    # The resolved var is pushed...
    run grep -F "set-environment GEMINI_API_KEY=test-gemini-key" "$SYSTEMCTL_LOG"
    [ "$status" -eq 0 ]

    # ...and the unresolved one is NOT.
    run grep -F "set-environment WIN_API_KEY=" "$SYSTEMCTL_LOG"
    [ "$status" -ne 0 ]

    # Nothing else leaked into the manager env either.
    run grep -cE 'set-environment (WIN_TOKEN|SSH_PASSWORD|TAILSCALE_API_KEY)=' "$SYSTEMCTL_LOG"
    [ "$status" -ne 0 ]
}

@test "oc-refresh-keys reports an UNCONFIRMED restart rather than a silent no-op" {
    # The runner's real failure mode (2026-09-21): `systemd-run --user` cannot reach a
    # user bus — "Failed to connect to bus: No medium found" — so the restart body never
    # executes and the gateway is left stale.  The refresh must SAY the restart is
    # unconfirmed rather than report success.  Before setup() mocked systemd-run this
    # path could not be reached from here at all, which is exactly why the file's three
    # restart assertions passed locally and failed on CI: the mock always ran the
    # payload, so the bus-less reality was invisible.
    __mock_command_local pwsh.exe "printf '%s\\n' 'WIN_API_KEY=winsecret' 'GEMINI_API_KEY=test-gemini-key'"
    export GEMINI_API_KEY="test-gemini-key"
    # A systemd-run that accepts the call and runs nothing — what a failed bus
    # connection looks like to the caller.
    __mock_command_local systemd-run 'exit 0'

    run oc-refresh-keys
    [ "$status" -eq 0 ]
    [[ "$output" == *"restart not confirmed"* ]]
}
