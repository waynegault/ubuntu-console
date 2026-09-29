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
# Case-name prefixes, which are also the file's index (the `meta:` case below greps
# for them): `seed:` = a deliberately-broken fixture that must be caught,
# `control:` = a clean fixture that must pass, `report:` = a case whose criterion is
# a REPORTED count rather than a verdict, and `real:` = the shipped repo's own
# artifact, asserted where a fixture cannot stand in for it.
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

# ── verified_by: the contract-to-test traceability (SPEC-VV-CONSOLE-003) ────
# The criterion is the checker header: a `verified_by:` node must exist as written
# in a BATS file under tests/ (FAIL otherwise), while an ACTIVE entry that declares
# none is REPORTED and counted, never a failure — the posture `state` takes for its
# NOT ENFORCED edges.  Three cases, one per direction: a dangling pointer, an
# absent map, and a correct declaration that must be accepted and counted.
@test "seed: continuity — a dangling verified_by is caught, naming the entry and the node" {
    mkdir -p "$FIXTURE/tests/unit"
    printf '@test "fixture case" {\n    true\n}\n' > "$FIXTURE/tests/unit/99-fixture.bats"

    # (a) the file exists but the node does not: the test was renamed or deleted, so
    # the entry cites something that is no longer there — a stale claim of coverage.
    sed -i 's|^    scope: both$|    scope: both\n    verified_by:\n      - "tests/unit/99-fixture.bats::a case that was renamed away"|' \
        "$FIXTURE/docs/contracts/command-contracts.yaml"
    run "$CHECKER" continuity --repo "$FIXTURE"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"FAIL  docs/contracts/command-contracts.yaml:beta-cmd"* ]]
    [[ "$output" == *"names 'tests/unit/99-fixture.bats::a case that was renamed away'"* ]]
    [[ "$output" == *"which is not a @test in tests/unit/99-fixture.bats"* ]]

    # (b) the path is not a BATS file under tests/ at all.  A Python test cannot be
    # named (the oracle is the @test parser), so naming one is a failure rather than
    # a silently ignored pointer.
    cat > "$FIXTURE/docs/contracts/command-contracts.yaml" <<'YAML'
version: 2
commands:
  - name: beta-cmd
    family: fixture
    summary: Run the fixture beta command
    version: 1
    updated: 2026-09-23
    status: active
    scope: both
    effect: read
    verified_by:
      - "tests/test_fixture.py::test_beta_cmd"
    contract:
      side_effects: []
YAML
    run "$CHECKER" continuity --repo "$FIXTURE"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"but 'tests/test_fixture.py' is not a BATS file under tests/"* ]]
    [[ "$output" == *"a Python test cannot be named here"* ]]
}

@test "seed: continuity — a malformed verified_by is caught, empty or not a node" {
    # The declaration's own shape: a present-but-empty list says nothing, and an item
    # without the `::` separator is not a node at all.  Both are FAILs rather than
    # silent no-ops, because a field that reads as declared coverage while naming
    # nothing is the failure mode this card is about.
    cat > "$FIXTURE/docs/contracts/command-contracts.yaml" <<'YAML'
version: 2
commands:
  - name: beta-cmd
    family: fixture
    summary: Run the fixture beta command
    version: 1
    updated: 2026-09-23
    status: active
    scope: both
    effect: read
    verified_by: []
    contract:
      side_effects: []
YAML
    run "$CHECKER" continuity --repo "$FIXTURE"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"declares an empty \`verified_by:\`"* ]]

    sed -i 's|^    verified_by: \[\]$|    verified_by:\n      - "not-a-node"|' \
        "$FIXTURE/docs/contracts/command-contracts.yaml"
    run "$CHECKER" continuity --repo "$FIXTURE"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"item 'not-a-node' is not of the form"* ]]
}

@test "report: continuity — an active entry with no verified_by is counted, not fatal" {
    # The posture half: a missing test is a fact about the suite, so it is reported
    # and counted (mirroring `state`'s NOT WITNESSED) rather than failing the check.
    # The fixture has no tests/ at all, which is also how the empty ORACLE stays
    # visible: a zero-node index is printed, not mistaken for a clean tree.
    run "$CHECKER" continuity --repo "$FIXTURE"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"NOT VERIFIED  beta-cmd"* ]]
    [[ "$output" == *"verified_by: 0 node(s) verified, 1 active entr(ies) unverified"* ]]
    [[ "$output" == *"@test oracle: 0 node(s) in 0 BATS file(s)"* ]]
}

@test "control: continuity — a verified_by naming a real test node passes and is counted" {
    # The false-positive half of this rule: the same declaration that must fail when
    # the node is missing must PASS, and be counted, when the node is there.
    mkdir -p "$FIXTURE/tests/unit"
    printf '@test "fixture case exercises beta-cmd" {\n    true\n}\n' \
        > "$FIXTURE/tests/unit/99-fixture.bats"
    sed -i 's|^    scope: both$|    scope: both\n    verified_by:\n      - "tests/unit/99-fixture.bats::fixture case exercises beta-cmd"|' \
        "$FIXTURE/docs/contracts/command-contracts.yaml"
    run "$CHECKER" continuity --repo "$FIXTURE"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"VERIFIED      beta-cmd -> tests/unit/99-fixture.bats::fixture case exercises beta-cmd"* ]]
    [[ "$output" == *"verified_by: 1 node(s) verified, 0 active entr(ies) unverified"* ]]
    [[ "$output" == *"@test oracle: 1 node(s) in 1 BATS file(s)"* ]]
}

@test "real: the shipped contract's verified_by nodes resolve and its counts cross-check" {
    # The real-tree half of the card: the shipped map parses, every declared node
    # exists (a dangling one is a FAIL above, so exit 0 is the assertion), and the
    # reported counts are cross-checked against the FILE ITSELF rather than a pinned
    # number — the count of declared nodes, and the count of entries with no map,
    # both come from the contract's own text.
    run "$CHECKER" continuity --repo "$REPO_ROOT"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"15 contract entr(ies) (15 active, 0 superseded)"* ]]

    local _declared _reported _entries _with_map _unverified
    # Counted with awk, not `grep -c`: grep exits 1 on zero matches, and under this
    # suite's errexit that would abort the case with a bogus failure the first time a
    # count legitimately reaches zero (measured here: 0 consequences).
    _declared=$(awk '/^      - "tests\//{n++} END{print n+0}' \
        "$REPO_ROOT/docs/contracts/command-contracts.yaml")
    _reported=$(printf '%s\n' "$output" \
        | sed -n 's/.*verified_by: \([0-9]*\) node(s) verified.*/\1/p')
    [[ -n "$_reported" ]] || { echo "the summary carries no verified_by count"; return 1; }
    [[ "$_reported" == "$_declared" ]] || {
        echo "$_declared node(s) declared in the contract, $_reported reported verified"
        return 1
    }
    (( _declared > 0 )) || { echo "the shipped map declares no test node at all"; return 1; }

    _entries=$(awk '/^  - name: /{n++} END{print n+0}' \
        "$REPO_ROOT/docs/contracts/command-contracts.yaml")
    _with_map=$(awk '/^    verified_by:$/{n++} END{print n+0}' \
        "$REPO_ROOT/docs/contracts/command-contracts.yaml")
    _unverified=$(printf '%s\n' "$output" \
        | sed -n 's/.*, \([0-9]*\) active entr(ies) unverified.*/\1/p')
    [[ "$_unverified" == "$((_entries - _with_map))" ]] || {
        echo "$((_entries - _with_map)) entr(ies) declare no verified_by, $_unverified reported"
        return 1
    }
    # ...and the one entry without a BATS test is the recorded gap, reported by name:
    # oc-restart-check's coverage is tests/test_oc_restart_check.py, which the
    # BATS-only oracle cannot name.  If a BATS case for it lands, this assertion is
    # the deliberate edit that adds the mapping.
    [[ "$output" == *"NOT VERIFIED  oc-restart-check"* ]]

    # The same cross-check for the triage: the reported split must equal the
    # `disposition:` lines the contract actually carries, and every other ACTIVE entry
    # must be counted as unclassified — a half-populated map cannot pass.
    local _decisions _consequences _unclassified_entries
    _decisions=$(awk '/^    disposition: decision$/{n++} END{print n+0}' \
        "$REPO_ROOT/docs/contracts/command-contracts.yaml")
    _consequences=$(awk '/^    disposition: consequence$/{n++} END{print n+0}' \
        "$REPO_ROOT/docs/contracts/command-contracts.yaml")
    [[ "$output" == *"disposition: ${_decisions} decision(s), ${_consequences} consequence(s)"* ]] || {
        echo "the summary's triage split disagrees with the contract's disposition lines"
        return 1
    }
    _unclassified_entries=$(printf '%s\n' "$output" \
        | sed -n 's/.*disposition: [0-9]* decision(s), [0-9]* consequence(s), \([0-9]*\) active entr(ies) unclassified.*/\1/p')
    [[ -n "$_unclassified_entries" ]] || { echo "the summary carries no unclassified count"; return 1; }
    [[ "$_unclassified_entries" == "$((_entries - _decisions - _consequences))" ]] || {
        echo "$((_entries - _decisions - _consequences)) entr(ies) are unclassified, $_unclassified_entries reported"
        return 1
    }
    # ...and the two classified entries are named while the half-stated one is not:
    # oc-restart-check states a closed three-way enumeration, while m's exit_code
    # ("0 unless internal render failure") names no failing set — the article's
    # "up to 250 m" shape, left for the owner rather than guessed at.
    [[ "$output" == *"DISPOSITION   oc-restart-check -> decision"* ]]
    [[ "$output" == *"UNCLASSIFIED  m —"* ]]
}

# ── disposition/bound: the decision/consequence triage (SPEC-VV-CONSOLE-004) ──
# The criterion is the checker header: `disposition: decision` needs a weighable
# `bound:` (the closed stated value an owner fixed), `disposition: consequence` must
# carry none (it is derived from its producer, so a hard-coded value goes stale), any
# other value is refused naming the two, and an ACTIVE entry that declares no
# `disposition:` at all is REPORTED and counted, never a failure.
@test "seed: continuity — a decision with no bound is caught" {
    # The rule the card names first: a decision is a CLOSED stated value, so an entry
    # marked `decision` without one is the article's half-stated line ("up to 250 m",
    # lower bound undefined) — a bound nobody can check, which is what this refuses.
    sed -i 's|^    scope: both$|    scope: both\n    disposition: decision|' \
        "$FIXTURE/docs/contracts/command-contracts.yaml"
    run "$CHECKER" continuity --repo "$FIXTURE"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"FAIL  docs/contracts/command-contracts.yaml:beta-cmd"* ]]
    [[ "$output" == *"\`disposition: decision\` with no \`bound:\`"* ]]

    # A `bound:` that says nothing is the same finding, not a pass: the floor is the
    # one the read_back exemption already uses, so a value a reviewer cannot weigh is
    # refused rather than counted as a stated bound.
    sed -i 's|^    disposition: decision$|    disposition: decision\n    bound: "x"|' \
        "$FIXTURE/docs/contracts/command-contracts.yaml"
    run "$CHECKER" continuity --repo "$FIXTURE"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"\`bound:\` says nothing weighable"* ]]
}

@test "seed: continuity — a consequence carrying a bound is caught" {
    # The second rule: a consequence is DERIVED from its producer, so a hard-coded
    # value in the entry goes stale silently the moment the producer changes — the
    # failure the pair of rules exists to separate.
    sed -i 's|^    scope: both$|    scope: both\n    disposition: consequence\n    bound: "exit_code: 0"|' \
        "$FIXTURE/docs/contracts/command-contracts.yaml"
    run "$CHECKER" continuity --repo "$FIXTURE"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"\`disposition: consequence\` carries a \`bound:\`"* ]]

    # ...and the mirror: a `bound:` with no `disposition:` is refused too, because
    # nothing then says whether the value is stated or derived.
    sed -i '/^    disposition: consequence$/d' "$FIXTURE/docs/contracts/command-contracts.yaml"
    run "$CHECKER" continuity --repo "$FIXTURE"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"declares a \`bound:\` with no \`disposition:\`"* ]]
}

@test "seed: continuity — an unknown disposition is caught, naming the allowed two" {
    sed -i 's|^    scope: both$|    scope: both\n    disposition: derived-ish|' \
        "$FIXTURE/docs/contracts/command-contracts.yaml"
    run "$CHECKER" continuity --repo "$FIXTURE"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"\`disposition:\` must be one of decision/consequence (got 'derived-ish')"* ]]
}

@test "report: continuity — an entry with no disposition is counted, then accepted once stated" {
    # `disposition:` is optional by the card, so an entry nobody triaged is REPORTED
    # and counted (the posture `state` takes for NOT WITNESSED), never a failure.
    run "$CHECKER" continuity --repo "$FIXTURE"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"UNCLASSIFIED  beta-cmd"* ]]
    [[ "$output" == *"disposition: 0 decision(s), 0 consequence(s), 1 active entr(ies) unclassified"* ]]

    # The false-positive half: the SAME entry, once stated, is accepted and counted as
    # a decision — so "reported" is not the only outcome the rule can produce.
    sed -i 's|^    scope: both$|    scope: both\n    disposition: decision\n    bound: "exit_code: 0 — one closed value, stated by this fixture"|' \
        "$FIXTURE/docs/contracts/command-contracts.yaml"
    run "$CHECKER" continuity --repo "$FIXTURE"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"DISPOSITION   beta-cmd -> decision"* ]]
    [[ "$output" == *"disposition: 1 decision(s), 0 consequence(s), 0 active entr(ies) unclassified"* ]]
}

@test "seed: swallows — the site dump reports the seeded site, and refuses to mix modes" {
    # `--dump-sites` is CHANGED SUBCOMMAND BEHAVIOUR (card SPLIT-CONTRACT-TRIAGE-001),
    # so the battery seeds its fault too: the seeded fault is an UNCLASSIFIED swallow,
    # and the dump must report it as unclassified with no reason — then flip to
    # classified, with the reason and its placement, once a human marker lands.  A dump
    # that said "classified" for everything would make every proposal built on it
    # meaningless, and it would still look green.
    cat >> "$FIXTURE/scripts/01-alpha.sh" <<'SH'

probe_dump() { command -v some-tool 2>/dev/null || true; }
SH
    "$CHECKER" swallows --dump-sites --repo "$FIXTURE" > "$BATS_TEST_TMPDIR/dump.jsonl" 2>/dev/null
    run python3 - "$BATS_TEST_TMPDIR/dump.jsonl" <<'PY'
import json
import sys

rows = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8") if line.strip()]
mine = [row for row in rows if row["file"] == "scripts/01-alpha.sh" and "probe_dump" in row["text"]]
assert len(mine) == 2, mine                       # both patterns on the seeded line
assert all(not row["classified"] and row["reason"] is None for row in mine), mine
assert all(row["reason_source"] is None for row in mine), mine
print("seeded dump rows:", len(mine), "unclassified")
PY
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"seeded dump rows: 2 unclassified"* ]]

    # The same site, classified by a marker on the line above: the dump must carry the
    # reason, where it was found, and that it is weighable.
    sed -i 's|^probe_dump() |# swallow-ok: the dump fixture marks this site on the line above.\nprobe_dump() |' \
        "$FIXTURE/scripts/01-alpha.sh"
    "$CHECKER" swallows --dump-sites --repo "$FIXTURE" > "$BATS_TEST_TMPDIR/dump2.jsonl" 2>/dev/null
    run python3 - "$BATS_TEST_TMPDIR/dump2.jsonl" <<'PY'
import json
import sys

rows = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8") if line.strip()]
mine = [row for row in rows if row["file"] == "scripts/01-alpha.sh" and "probe_dump" in row["text"]]
assert len(mine) == 2, mine
assert all(row["classified"] for row in mine), mine
assert all(row["reason"] == "the dump fixture marks this site on the line above."
           for row in mine), mine
assert all(row["reason_source"] == "line-above" and row["reason_weighable"]
           for row in mine), mine
print("classified dump rows:", len(mine))
PY
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"classified dump rows: 2"* ]]

    # The machine-readable mode is `swallows`-only and refuses to mix with the other
    # read-only mode: a half-honoured dump would put non-JSON on the stream.
    run "$CHECKER" state --dump-sites --repo "$FIXTURE"
    [[ "$status" -eq 2 ]]
    [[ "$output" == *"only meaningful with the \`swallows\` subcommand"* ]]
    run "$CHECKER" swallows --dump-sites --print-baseline --repo "$FIXTURE"
    [[ "$status" -eq 2 ]]
    [[ "$output" == *"pass one"* ]]
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
