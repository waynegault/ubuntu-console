#!/usr/bin/env bats
# ==============================================================================
# Unit — tools/check-contracts.sh (state-contract drift guard)
# ==============================================================================
# Card STATE-CONTRACT-VALIDATION-001.  The guard exists because
# docs/contracts/state-contracts.yaml was prose: nothing parsed it, so renaming
# /dev/shm/active_llm — or deleting the write in scripts/11e-llm-model.sh —
# degraded the dashboard with no error anywhere.
#
# Hermetic: every case builds a throwaway fixture tree under $BATS_TEST_TMPDIR and
# points the checker at it with --repo, so the shared real repo/index is never
# touched.  The fixture is deliberately tiny (two symbols, three modules) so a
# failing assertion names a fixture file, not a 300-line real one.
# ==============================================================================

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    export CHECKER="$REPO_ROOT/tools/check-contracts.sh"
    export FIXTURE="$BATS_TEST_TMPDIR/fixture"
    mkdir -p "$FIXTURE/docs/contracts" "$FIXTURE/scripts"
    _write_contract
    _write_tree
}

# _write_contract — the minimal contract every case starts from: one variable
# (FIXTURE_STATE) and one cache file (with a binding, a consumer via the binding,
# and an invalidator), which together exercise every edge kind.
_write_contract() {
    cat > "$FIXTURE/docs/contracts/state-contracts.yaml" <<'YAML'
version: 2
notes:
  - Fixture contract for tests/unit/22-contracts-state.bats.
variables:
  - name: FIXTURE_STATE
    producer: scripts/01-constants.sh
    consumers:
      - file: scripts/12-consumer.sh
    type: string
    semantics: fixture state
files:
  - path: /dev/shm/fixture_cache
    bindings: [FIXTURE_CACHE]
    producer: scripts/01-constants.sh
    consumers:
      - file: scripts/12-consumer.sh
        via: [FIXTURE_CACHE]
    invalidators:
      - scripts/07-invalidator.sh
    format: plain text
    semantics: fixture cache
YAML
}

# _write_tree — the producer, consumer and invalidator the fixture contract names.
_write_tree() {
    cat > "$FIXTURE/scripts/01-constants.sh" <<'SH'
#!/usr/bin/env bash
# Fixture producer: binds both fixture symbols.
export FIXTURE_STATE="ready"
export FIXTURE_CACHE="/dev/shm/fixture_cache"
SH
    cat > "$FIXTURE/scripts/12-consumer.sh" <<'SH'
#!/usr/bin/env bash
# Fixture consumer: reads the state and the cache.
echo "$FIXTURE_STATE"
[[ -f "$FIXTURE_CACHE" ]] && cat "$FIXTURE_CACHE"
SH
    cat > "$FIXTURE/scripts/07-invalidator.sh" <<'SH'
#!/usr/bin/env bash
# Fixture invalidator: clears the cache.
rm -f "$FIXTURE_CACHE"
SH
}

@test "contracts: a clean fixture passes and prints the enforced/unenforced counts" {
    run "$CHECKER" state --repo "$FIXTURE"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"check-contracts[state]: OK"* ]]
    [[ "$output" == *"2 entries (2 declared)"* ]]
    [[ "$output" == *"2 producer"* ]]
    [[ "$output" == *"2 consumer"* ]]
    [[ "$output" == *"1 invalidator"* ]]
    [[ "$output" == *"declared-unenforced edges: 0"* ]]
    # The coverage limits are printed, so "not enforced" is visible, not implied.
    [[ "$output" == *"Coverage limits, not enforced by construction"* ]]
}

@test "contracts: a producer that no longer assigns the symbol fails and names it" {
    sed -i 's/FIXTURE_STATE="ready"/FIXTURE_STATE_NEW="ready"/' \
        "$FIXTURE/scripts/01-constants.sh"
    run "$CHECKER" state --repo "$FIXTURE"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"FAIL  FIXTURE_STATE:"* ]]
    [[ "$output" == *"scripts/01-constants.sh"* ]]
    [[ "$output" == *"no assignment or write"* ]]
    # The finding names the contract line that made the claim, so a reader knows
    # which entry to fix as well as which file stopped matching.
    [[ "$output" == *"[contract line "* ]]
}

@test "contracts: a cache renamed in its producer fails the path-identity check" {
    # The card's exact scenario: the cache moves, the variable name stays.  Every
    # reader still uses $FIXTURE_CACHE, so only the declared PATH can catch it.
    sed -i 's#/dev/shm/fixture_cache#/dev/shm/fixture_store#' \
        "$FIXTURE/scripts/01-constants.sh"
    run "$CHECKER" state --repo "$FIXTURE"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"FAIL  fixture_cache:"* ]]
    [[ "$output" == *"declared path literal 'fixture_cache' is not bound or written"* ]]
}

@test "contracts: a consumer file that disappears fails" {
    rm "$FIXTURE/scripts/12-consumer.sh"
    run "$CHECKER" state --repo "$FIXTURE"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"names missing file 'scripts/12-consumer.sh'"* ]]
}

@test "contracts: a consumer that no longer references the symbol fails" {
    sed -i 's/FIXTURE_STATE/FIXTURE_VALUE/g' "$FIXTURE/scripts/12-consumer.sh"
    run "$CHECKER" state --repo "$FIXTURE"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"FAIL  FIXTURE_STATE:"* ]]
    [[ "$output" == *"no longer references FIXTURE_STATE"* ]]
    [[ "$output" == *"scripts/12-consumer.sh"* ]]
}

@test "contracts: an invalidator that stops deleting the cache fails" {
    cat > "$FIXTURE/scripts/07-invalidator.sh" <<'SH'
#!/usr/bin/env bash
# Fixture invalidator that was quietly changed to a no-op.
echo "nothing cleared"
SH
    run "$CHECKER" state --repo "$FIXTURE"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"no delete of"* ]]
    [[ "$output" == *"scripts/07-invalidator.sh"* ]]
}

@test "contracts: an unenforced edge without a why: fails" {
    cat > "$FIXTURE/docs/contracts/state-contracts.yaml" <<'YAML'
version: 2
variables:
  - name: FIXTURE_STATE
    producer: scripts/01-constants.sh
    consumers:
      - unenforced: true
        reader: "a human reading it"
YAML
    run "$CHECKER" state --repo "$FIXTURE"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"declares no \`why:\`"* ]]
}

@test "contracts: an unenforced edge with a why: is a stated choice, counted and printed" {
    cat > "$FIXTURE/docs/contracts/state-contracts.yaml" <<'YAML'
version: 2
variables:
  - name: FIXTURE_STATE
    producer: scripts/01-constants.sh
    consumers:
      - unenforced: true
        reader: "a human reading it"
        why: "the reader is an operator at a shell, so there is no file to check"
YAML
    run "$CHECKER" state --repo "$FIXTURE"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"NOT ENFORCED  FIXTURE_STATE <- a human reading it"* ]]
    [[ "$output" == *"declared-unenforced edges: 1"* ]]
}

@test "contracts: a symbol declared twice fails" {
    cat > "$FIXTURE/docs/contracts/state-contracts.yaml" <<'YAML'
version: 2
variables:
  - name: FIXTURE_STATE
    producer: scripts/01-constants.sh
    consumers:
      - file: scripts/12-consumer.sh
  - name: FIXTURE_STATE
    producer: scripts/01-constants.sh
    consumers:
      - file: scripts/12-consumer.sh
YAML
    run "$CHECKER" state --repo "$FIXTURE"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"declared twice"* ]]
}

@test "contracts: an entry with no consumers fails" {
    cat > "$FIXTURE/docs/contracts/state-contracts.yaml" <<'YAML'
version: 2
variables:
  - name: FIXTURE_STATE
    producer: scripts/01-constants.sh
YAML
    run "$CHECKER" state --repo "$FIXTURE"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"entry declares no consumers"* ]]
}

@test "contracts: a malformed contract fails cleanly with exit 2 (no traceback)" {
    printf 'version: [1, 2\n' > "$FIXTURE/docs/contracts/state-contracts.yaml"
    run "$CHECKER" state --repo "$FIXTURE"
    [[ "$status" -eq 2 ]]
    [[ "$output" == *"cannot parse"* ]]
    [[ "$output" != *"Traceback"* ]]
}

@test "contracts: an absent contract fails cleanly with exit 2" {
    rm "$FIXTURE/docs/contracts/state-contracts.yaml"
    run "$CHECKER" state --repo "$FIXTURE"
    [[ "$status" -eq 2 ]]
    [[ "$output" == *"contract not found"* ]]
    [[ "$output" != *"Traceback"* ]]
}

@test "contracts: a thin loader resolves to its sub-modules" {
    rm -f "$FIXTURE/scripts/01-constants.sh"
    cat > "$FIXTURE/scripts/11-loader.sh" <<'SH'
#!/usr/bin/env bash
# Fixture thin loader: sources its sub-modules, as scripts/11-llm-manager.sh does.
__tac_source_submodules "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" "11-loader" \
    11a-sub
SH
    cat > "$FIXTURE/scripts/11a-sub.sh" <<'SH'
#!/usr/bin/env bash
# Fixture sub-module: holds the fixture writes.
export FIXTURE_STATE="ready"
export FIXTURE_CACHE="/dev/shm/fixture_cache"
SH
    sed -i 's#scripts/01-constants.sh#scripts/11-loader.sh#' \
        "$FIXTURE/docs/contracts/state-contracts.yaml"
    run "$CHECKER" state --repo "$FIXTURE"
    [[ "$status" -eq 0 ]]

    # ...and a sub-module that stops producing is still a failure, so the
    # expansion cannot be passing for the wrong reason (e.g. on the loader file).
    sed -i 's/FIXTURE_STATE="ready"/FIXTURE_STATE_NEW="ready"/' "$FIXTURE/scripts/11a-sub.sh"
    run "$CHECKER" state --repo "$FIXTURE"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"FAIL  FIXTURE_STATE:"* ]]
    [[ "$output" == *"scripts/11-loader.sh"* ]]
}

@test "contracts: a loader naming a missing sub-module fails" {
    rm -f "$FIXTURE/scripts/01-constants.sh"
    cat > "$FIXTURE/scripts/11-loader.sh" <<'SH'
#!/usr/bin/env bash
# Fixture thin loader naming a sub-module that does not exist.
__tac_source_submodules "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" "11-loader" \
    11a-absent
SH
    sed -i 's#scripts/01-constants.sh#scripts/11-loader.sh#' \
        "$FIXTURE/docs/contracts/state-contracts.yaml"
    run "$CHECKER" state --repo "$FIXTURE"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"names missing file 'scripts/11a-absent.sh'"* ]]
}

@test "contracts: a bare invocation runs every implemented subcommand" {
    run "$CHECKER" --repo "$FIXTURE"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"=== Contract drift check (docs/contracts/state-contracts.yaml) ==="* ]]
}

@test "contracts: an unknown subcommand exits 2 with usage; a reserved one says so" {
    run "$CHECKER" bogus
    [[ "$status" -eq 2 ]]
    [[ "$output" == *"unknown argument 'bogus'"* ]]
    [[ "$output" == *"usage: check-contracts.sh"* ]]
    # The four reserved names are the other board cards' subcommands: refusing is
    # correct, silently doing nothing would be a fake pass.
    run "$CHECKER" swallows
    [[ "$status" -eq 2 ]]
    [[ "$output" == *"reserved but NOT implemented here"* ]]
}

@test "contracts: --version prints the tool version" {
    run "$CHECKER" --version
    [[ "$status" -eq 0 ]]
    [[ "$output" == "check-contracts 1" ]]
}

# end of file
