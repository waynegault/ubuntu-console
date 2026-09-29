#!/usr/bin/env bats
# ==============================================================================
# Unit — tools/check-contracts.sh: the falsification battery
# ==============================================================================
# Card SPEC-VV-CONSOLE-002.  The claim it enforces: the check is worthless if it
# cannot fail — a green result is only evidence when the check could have been red.
# REF: "Towards Spec-Driven Test Automation: Part 1" (Gal Arav, TDS, 2026-09-24) — https://towardsdatascience.com/towards-spec-driven-test-automation-part-1/
#
# WHY THIS SUITE IS SEPARATE from 22-contracts-state.bats and 24-contracts-guards.bats:
# those two prove individual rules as they were written, mixed in with cases that
# assert other behaviour (counts, dispatch, --version).  This is the falsification
# battery proper, in the shape of the investigator repo's
# tests/scripts/test_gate_falsification.py + docs/audit/gate-falsification.md: for
# EVERY subcommand, one deliberately-broken fixture that must be caught — and the
# failure NAMED, not merely a non-zero exit, because exit 2 ("cannot run") is also
# non-zero and would otherwise pass for a catch — beside a clean control that must
# pass.  A gate that fails everything is not a gate, so the control is the
# false-positive half of the measurement.
#
# THE FIXTURES ARE WRONG ON PURPOSE.  Each seeded-fault case breaks exactly one
# rule, and its comment names the checker arm it pins.  The criterion is the
# numbered ENFORCED list in the tools/check-contracts.sh header and the exit-code
# contract at its foot (0 clean / 1 drift / 2 cannot run) — NOT whatever the code
# happens to print today; the message fragments asserted here are the documented
# findings, and a wording change must be a deliberate edit to this file.  Never
# "fix" a fixture to make a case pass: a fixture that stops being wrong turns its
# case into a control and leaves the arm unproven.
#
# Hermetic, like 22 and 24: each case builds a throwaway tree under
# $BATS_TEST_TMPDIR and points the checker at it with --repo, so the shared real
# repo and its baselines are never touched.
#
# CHECKER is taken from the environment when already set, so this battery can be run
# against a copy of the checker with one arm mutated:
#   CHECKER=/tmp/mutant/tools/check-contracts.sh bats tests/unit/34-contracts-falsification.bats
# That is how the "this battery can go red" half is demonstrated — the BATS analogue
# of test_gate_falsification.py patching a gate's root module-locally.  The default is
# this repo's checker.
# ==============================================================================

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    export CHECKER="${CHECKER:-$REPO_ROOT/tools/check-contracts.sh}"
    export FIXTURE="$BATS_TEST_TMPDIR/fixture"
    mkdir -p "$FIXTURE/scripts" "$FIXTURE/docs/contracts" \
             "$FIXTURE/skills/tactical-console" "$FIXTURE/.agents/decisions"
    _write_tree
}

# _write_tree — the CLEAN control tree: two modules in a correct load order, one
# exported command each, one authored table row, one contract entry, one decision
# record, and a two-entry state contract (a variable and a cache) whose producer,
# consumer and invalidator all exist and match.  It passes all five subcommands, so
# the bare-run control below means "every subcommand ran and passed", not "four
# checks refused".
_write_tree() {
    _write_list 01-alpha 02-beta
    _write_alpha 'none (standalone fixture)' 'alpha-cmd, ALPHA_STATE'
    _write_beta 'alpha' 'beta-cmd'
    # Not module-shaped (no NN- name), so the module check does not read it as a
    # module-shaped file that no loader loads.
    cat > "$FIXTURE/scripts/fixture-invalidator.sh" <<'SH'
# Fixture invalidator: clears the fixture cache.
rm -f "$FIXTURE_CACHE"
SH
    _write_skill
    _write_contracts
    _write_decision
    _write_state_contract
}

# _write_list <names...> — the fixture load list, read through its own function.
# Written with %s so the backslash continuation and the `\n` inside the printf
# format survive verbatim.
_write_list() {
    {
        printf '%s\n' '#!/usr/bin/env bash'
        printf '%s\n' '# Fixture load list.'
        printf '%s\n' 'function __tac_module_list() {'
        printf '%s\n' "    printf '%s\\n' \\"
        local name
        for name in "$@"; do
            printf '%s\n' "        $name \\"
        done
        printf '%s\n' '}'
    } > "$FIXTURE/scripts/_module-list.sh"
}

# _write_alpha <depends> <exports> — the producer of both state-contract entries.
_write_alpha() {
    cat > "$FIXTURE/scripts/01-alpha.sh" <<SH
# shellcheck shell=bash
# Module Version: 1
# @modular-section: alpha
# @depends: $1
# @exports: $2

alpha-cmd() { printf '%s\n' alpha; }
ALPHA_STATE="ready"
FIXTURE_CACHE="/dev/shm/fixture_cache"
SH
}

# _write_beta <depends> <exports> — the consumer, reading both entries (the variable
# directly, the cache through its declared binding).
_write_beta() {
    cat > "$FIXTURE/scripts/02-beta.sh" <<SH
# shellcheck shell=bash
# Module Version: 1
# @modular-section: beta
# @depends: $1
# @exports: $2

beta-cmd() { printf '%s\n' "\$ALPHA_STATE"; }
cat "\$FIXTURE_CACHE"
SH
}

_write_skill() {
    cat > "$FIXTURE/skills/tactical-console/SKILL.md" <<'MD'
---
name: tactical-console
---

# Fixture skill

| Command | Description | Example |
|---------|-------------|---------|
| `tac-exec beta-cmd` | Run beta | Check beta |
MD
}

_write_contracts() {
    cat > "$FIXTURE/docs/contracts/command-contracts.yaml" <<'YAML'
version: 2
updated: 2026-09-23
commands:
  - name: beta-cmd
    family: fixture
    summary: Run the fixture beta command
    version: 1
    updated: 2026-09-23
    status: active
    scope: both
    effect: read
    contract:
      side_effects: []
      output_shape:
        - one line
      exit_code: 0
YAML
}

_write_decision() {
    cat > "$FIXTURE/.agents/decisions/fixture-decision.md" <<'MD'
---
name: fixture-decision
date: 2026-09-23
status: active
scope: both
commands: [beta-cmd]
---

**Decision:** fixture decision, parsed by the continuity check.
MD
}

_write_state_contract() {
    cat > "$FIXTURE/docs/contracts/state-contracts.yaml" <<'YAML'
version: 2
variables:
  - name: ALPHA_STATE
    producer: scripts/01-alpha.sh
    consumers:
      - file: scripts/02-beta.sh
    type: string
    semantics: fixture state
files:
  - path: /dev/shm/fixture_cache
    bindings: [FIXTURE_CACHE]
    producer: scripts/01-alpha.sh
    consumers:
      - file: scripts/02-beta.sh
        via: [FIXTURE_CACHE]
    invalidators:
      - scripts/fixture-invalidator.sh
    format: plain text
    semantics: fixture cache
YAML
}

# ── clean controls ─────────────────────────────────────────────────────────
# The false-positive half: for each subcommand the SAME tree an arm's seed is
# built on must pass untouched, or a "caught it" verdict below proves only that
# the checker fails everything.
@test "control: state — the clean fixture passes and reports its edges" {
    run "$CHECKER" state --repo "$FIXTURE"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"check-contracts[state]: OK"* ]]
    [[ "$output" == *"2 entries (2 declared)"* ]]
    [[ "$output" == *"1 invalidator"* ]]
}

@test "control: modules — the clean fixture passes and reports its counts" {
    run "$CHECKER" modules --repo "$FIXTURE"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"check-contracts[modules]: OK"* ]]
    [[ "$output" == *"2 module(s) with a parsed @depends"* ]]
    [[ "$output" == *"disagreements: 0 recorded, 0 new"* ]]
}

@test "control: derived — the clean fixture passes and every authored row resolves" {
    run "$CHECKER" derived --repo "$FIXTURE"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"check-contracts[derived]: OK"* ]]
    [[ "$output" == *"2 command(s) derived from @exports"* ]]
    [[ "$output" == *"1/1 resolvable"* ]]
}

@test "control: continuity — the clean fixture passes and the register is read" {
    run "$CHECKER" continuity --repo "$FIXTURE"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"check-contracts[continuity]: OK"* ]]
    [[ "$output" == *"1 contract entr(ies) (1 active, 0 superseded)"* ]]
    [[ "$output" == *"1 decision record(s)"* ]]
}

@test "control: swallows — the clean fixture has a zero population" {
    run "$CHECKER" swallows --repo "$FIXTURE"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"check-contracts[swallows]: OK"* ]]
    # Four files: the load list, the two modules and the invalidator.
    [[ "$output" == *"0 site(s) in 4 file(s) | 0 classified | 0 unclassified"* ]]
}

@test "control: a bare invocation runs all five subcommands and passes" {
    run "$CHECKER" --repo "$FIXTURE"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"check-contracts[state]: OK"* ]]
    [[ "$output" == *"check-contracts[modules]: OK"* ]]
    [[ "$output" == *"check-contracts[derived]: OK"* ]]
    [[ "$output" == *"check-contracts[continuity]: OK"* ]]
    [[ "$output" == *"check-contracts[swallows]: OK"* ]]
}

# ── seeded faults: one per subcommand, each naming its arm ─────────────────
# Every case asserts exit 1 (DRIFT) specifically, never "non-zero": exit 2 is
# CANNOT-RUN, and accepting it would let a checker that refuses to run at all read
# as a catch.  The finding must also NAME the seeded fault.
@test "seed: state — a producer that stopped writing the symbol is caught and named" {
    # ENFORCED 3: every declared producer contains a WRITE of the entry; a bare
    # rename of the assignment is the shape that degraded the dashboard silently.
    sed -i 's/^ALPHA_STATE="ready"$/ALPHA_STATE_NEW="ready"/' "$FIXTURE/scripts/01-alpha.sh"
    run "$CHECKER" state --repo "$FIXTURE"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"FAIL  ALPHA_STATE:"* ]]
    [[ "$output" == *"no assignment or write"* ]]
    [[ "$output" == *"scripts/01-alpha.sh"* ]]
}

@test "seed: state — a consumer that stopped referencing the symbol is caught and named" {
    # ENFORCED 5: every declared consumer file exists and references the entry.
    sed -i 's/^beta-cmd() .*$/beta-cmd() { printf "%s\\n" retired; }/' \
        "$FIXTURE/scripts/02-beta.sh"
    run "$CHECKER" state --repo "$FIXTURE"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"FAIL  ALPHA_STATE:"* ]]
    [[ "$output" == *"no longer references ALPHA_STATE"* ]]
    [[ "$output" == *"scripts/02-beta.sh"* ]]
}

@test "seed: modules — a module depending on a later-loaded module is caught, naming both" {
    # ENFORCED 7: no NEW edge violates the load order.  The declaration and the
    # load list disagree; before this arm existed, nothing failed.
    _write_alpha 'beta' 'alpha-cmd, ALPHA_STATE'
    _write_beta 'none' 'beta-cmd'
    run "$CHECKER" modules --repo "$FIXTURE"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"FAIL  order  01-alpha"* ]]
    [[ "$output" == *"depends on 02-beta, which loads AFTER it"* ]]
}

@test "seed: modules — a cycle is caught and its concrete path is printed" {
    # ENFORCED 7: a cycle is printed with its concrete path.  Honest boundary: the
    # exit code here is carried by the forward edge the cycle contains — the header
    # says so itself ("every cycle necessarily contains a forward edge, so a new
    # cycle can never be silent") — so this case adds the printed PATH to what the
    # forward-edge case already pins; measured, the two go red together when the
    # load-order arm is mutated.
    _write_alpha 'beta' 'alpha-cmd, ALPHA_STATE'
    run "$CHECKER" modules --repo "$FIXTURE"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"cycle: 01-alpha -> 02-beta -> 01-alpha"* ]]
    [[ "$output" == *"CYCLE     01-alpha -> 02-beta -> 01-alpha"* ]]
}

@test "seed: derived — a SKILL.md row naming a command nothing exports is caught" {
    # ENFORCED 1: every command NAMED by a SKILL.md tac-exec row is exported by a
    # loaded module — the renamed-command drift the static table cannot notice.
    sed -i 's/tac-exec beta-cmd/tac-exec gamma-cmd/' \
        "$FIXTURE/skills/tactical-console/SKILL.md"
    run "$CHECKER" derived --repo "$FIXTURE"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"FAIL  SKILL.md:"* ]]
    [[ "$output" == *"the table names 'tac-exec gamma-cmd'"* ]]
    [[ "$output" == *"which no loaded module @exports"* ]]
}

@test "seed: derived — a contract entry naming a command nothing exports is caught" {
    # ENFORCED 1, the other authored enumeration: command-contracts.yaml is the
    # same kind of cache and is held to the same rule.
    sed -i 's/^  - name: beta-cmd$/  - name: gamma-cmd/' \
        "$FIXTURE/docs/contracts/command-contracts.yaml"
    run "$CHECKER" derived --repo "$FIXTURE"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"entry 'gamma-cmd' names 'gamma-cmd'"* ]]
    [[ "$output" == *"which no loaded module @exports"* ]]
}

@test "seed: continuity — an entry with an invalid version/date/status/scope is caught" {
    # ENFORCED by continuity: a positive integer version, an ISO updated date, a
    # status in active/superseded/retired and a scope in interactive/library/both.
    # All four are wrong ON PURPOSE; each must be named, so one field failing
    # cannot stand in for the other three.
    cat > "$FIXTURE/docs/contracts/command-contracts.yaml" <<'YAML'
version: 2
commands:
  - name: beta-cmd
    family: fixture
    summary: Run the fixture beta command
    version: 0
    updated: 30-09-2026
    status: live
    scope: everywhere
    effect: read
    contract:
      side_effects: []
YAML
    run "$CHECKER" continuity --repo "$FIXTURE"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"beta-cmd: \`version:\` must be a positive integer"* ]]
    [[ "$output" == *"beta-cmd: \`updated:\` must be an ISO date"* ]]
    [[ "$output" == *"beta-cmd: \`status:\` must be one of active/superseded/retired"* ]]
    [[ "$output" == *"beta-cmd: \`scope:\` must be one of interactive/library/both"* ]]
}

@test "seed: continuity — a superseded entry with no successor pointer is caught" {
    # ENFORCED by continuity: a superseded entry carries both `superseded:` and
    # `superseded_by:`, so what a rule replaced stays readable.
    sed -i 's/^    status: active$/    status: superseded\n    superseded: 2026-09-23/' \
        "$FIXTURE/docs/contracts/command-contracts.yaml"
    run "$CHECKER" continuity --repo "$FIXTURE"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"status is superseded but there is no \`superseded_by:\` pointer"* ]]
}

@test "seed: swallows — a new unclassified swallow is caught" {
    # ENFORCED by swallows: no NEW unclassified `|| true` / `2>/dev/null` site —
    # the silent-failure class the whole subcommand exists for.
    cat >> "$FIXTURE/scripts/01-alpha.sh" <<'SH'

probe_tool() { command -v some-tool 2>/dev/null >/dev/null || true; }
SH
    run "$CHECKER" swallows --repo "$FIXTURE"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"scripts/01-alpha.sh: 2 unclassified swallow(s)"* ]]
    [[ "$output" == *"# swallow-ok: <one-line reason>"* ]]
}

@test "seed: swallows — a marker with no reason does not classify its site" {
    # ENFORCED by swallows: every `# swallow-ok:` marker carries a reason of its
    # own (8+ characters).  A short marker is a refusal, not a classification —
    # and the neighbouring site must NOT be counted as classified.
    cat >> "$FIXTURE/scripts/01-alpha.sh" <<'SH'

# swallow-ok: hmm
probe_more() { command -v x 2>/dev/null || true; }
SH
    run "$CHECKER" swallows --repo "$FIXTURE"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"needs a reason, not 'hmm'"* ]]
    [[ "$output" == *"0 unclassified"* ]]
}

# ── the battery's own ratchet ──────────────────────────────────────────────
@test "meta: every subcommand has a seeded case and a clean control in this file" {
    # A seeded case that is deleted or renamed leaves the battery green with the
    # arm unproven, which is the failure mode this whole suite exists to prevent.
    # Case names are the index: "seed: <subcommand> …" / "control: <subcommand> …".
    local sub
    for sub in state modules derived continuity swallows; do
        grep -qF "@test \"seed: $sub " "$BATS_TEST_FILENAME" \
            || { echo "no seeded-fault case for '$sub' in $BATS_TEST_FILENAME"; return 1; }
        grep -qF "@test \"control: $sub " "$BATS_TEST_FILENAME" \
            || { echo "no clean control for '$sub' in $BATS_TEST_FILENAME"; return 1; }
    done
}

# end of file
