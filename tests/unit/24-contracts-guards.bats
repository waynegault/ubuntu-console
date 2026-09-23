#!/usr/bin/env bats
# ==============================================================================
# Unit — tools/check-contracts.sh (modules, derived, continuity, swallows)
# ==============================================================================
# The four checkers that joined the dispatcher on 2026-09-23, each owned by a card:
#   modules     GEG-006 — the @depends/@exports headers were parsed nowhere, so a
#               declaration could disagree with the real load order with no failure
#               (measured at HEAD: 12 forward edges, 1 SCC, and docs/inspection.md
#               §9.4.1's "no circular dependencies" claim is false there).
#   derived     DYNSKILL-011 — SKILL.md's tac-exec table is a snapshot of the CLI
#               with no invalidation protocol.
#   continuity  INTENT-CONT-007 — an edited command contract left no record of what
#               it replaced, could not be scoped to one loader, and nothing under
#               .agents/ persisted a decision across sessions.
#   swallows    CLAIMED-SUCCESS-WITNESS-001 (tooling half) — an unclassified
#               `|| true` / `2>/dev/null` is a silent failure by construction.
#
# Hermetic, like 22-contracts-state.bats: every case builds a throwaway fixture tree
# under $BATS_TEST_TMPDIR and points the checker at it with --repo, so the shared
# real repo and its baselines are never touched.  Every hard rule below has a case
# that makes it go red, because a gate that cannot fail is not evidence.
# ==============================================================================

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    export CHECKER="$REPO_ROOT/tools/check-contracts.sh"
    export FIXTURE="$BATS_TEST_TMPDIR/fixture"
    mkdir -p "$FIXTURE/scripts" "$FIXTURE/docs/contracts" \
             "$FIXTURE/skills/tactical-console" "$FIXTURE/.agents/decisions"
    _write_tree
}

# _write_tree — a tiny tree that passes every subcommand: two modules in a correct
# load order, one exported command each, one authored table row, one contract entry,
# one decision record, and a one-entry state contract so the bare run is green too.
_write_tree() {
    _write_list 01-alpha 02-beta
    _write_alpha 'none (standalone fixture)' 'alpha-cmd, ALPHA_STATE'
    _write_beta 'alpha' 'beta-cmd'
    cat > "$FIXTURE/skills/tactical-console/SKILL.md" <<'MD'
---
name: tactical-console
---

# Fixture skill

| Command | Description | Example |
|---------|-------------|---------|
| `tac-exec beta-cmd` | Run beta | Check beta |
MD
    _write_contracts
    _write_decision 'commands: [beta-cmd]'
    cat > "$FIXTURE/docs/contracts/state-contracts.yaml" <<'YAML'
version: 2
variables:
  - name: ALPHA_STATE
    producer: scripts/01-alpha.sh
    consumers:
      - unenforced: true
        reader: a human reading the fixture
        why: fixture only — this file asserts the dispatcher wiring, not state edges
    type: string
    semantics: fixture state
YAML
}

# _write_list <names...> — the fixture load list, read through its own function.
# Each line is written with %s so the backslash continuation and the `\n` inside the
# printf format survive verbatim (a load list that lost either would be a fixture
# bug that looks like a checker bug).
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

# _write_alpha <depends> <exports>
_write_alpha() {
    cat > "$FIXTURE/scripts/01-alpha.sh" <<SH
# shellcheck shell=bash
# Module Version: 1
# @modular-section: alpha
# @depends: $1
# @exports: $2

alpha-cmd() { printf '%s\n' alpha; }
ALPHA_STATE="ready"
SH
}

# _write_beta <depends> <exports>
_write_beta() {
    cat > "$FIXTURE/scripts/02-beta.sh" <<SH
# shellcheck shell=bash
# Module Version: 1
# @modular-section: beta
# @depends: $1
# @exports: $2

beta-cmd() { alpha-cmd; }
SH
}

# _write_contracts [EXTRA-ENTRY...] — one entry, plus any extra YAML lines.
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
    contract:
      side_effects: []
      output_shape:
        - one line
      exit_code: 0
YAML
}

# _write_decision <commands-line>
_write_decision() {
    cat > "$FIXTURE/.agents/decisions/fixture-decision.md" <<MD
---
name: fixture-decision
date: 2026-09-23
status: active
scope: both
$1
---

**Decision:** fixture decision, parsed by the continuity check.
MD
}

# ── modules ────────────────────────────────────────────────────────────────
@test "modules: a consistent fixture passes and prints its counts" {
    run "$CHECKER" modules --repo "$FIXTURE"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"check-contracts[modules]: OK"* ]]
    [[ "$output" == *"2 load position(s)"* ]]
    [[ "$output" == *"2 module(s) with a parsed @depends"* ]]
    [[ "$output" == *"disagreements: 0 recorded, 0 new"* ]]
}

@test "modules: a module depending on a later-loaded module fails, naming both" {
    # The card's core case: the declaration and the order disagree, and before this
    # checker nothing failed.
    _write_alpha 'beta' 'alpha-cmd, ALPHA_STATE'
    _write_beta 'none' 'beta-cmd'
    run "$CHECKER" modules --repo "$FIXTURE"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"FAIL  order  01-alpha"* ]]
    [[ "$output" == *"depends on 02-beta, which loads AFTER it"* ]]
    [[ "$output" == *"position 1 > 0"* ]]
    # Nothing in the tree is a cycle here, so the failure is the edge alone.
    [[ "$output" != *"cycle: "* ]]
}

@test "modules: a cycle fails and prints the concrete cycle path" {
    _write_alpha 'beta' 'alpha-cmd, ALPHA_STATE'
    run "$CHECKER" modules --repo "$FIXTURE"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"cycle: 01-alpha -> 02-beta -> 01-alpha"* ]]
    [[ "$output" == *"CYCLE     01-alpha -> 02-beta -> 01-alpha"* ]]
}

@test "modules: an @depends naming a module that does not exist fails" {
    _write_alpha 'gamma' 'alpha-cmd, ALPHA_STATE'
    run "$CHECKER" modules --repo "$FIXTURE"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"FAIL  unknown-depends  01-alpha"* ]]
    [[ "$output" == *"@depends names 'gamma' (unknown), which is not a module"* ]]
}

@test "modules: the literal 'none' with a parenthetical means no dependencies" {
    # tools/lint.sh carries exactly this form, and a parser that read it as a module
    # named 'none (standalone CI helper)' would fail the real tree.
    grep -q '^# @depends: none (standalone fixture)$' "$FIXTURE/scripts/01-alpha.sh"
    run "$CHECKER" modules --repo "$FIXTURE"
    [[ "$status" -eq 0 ]]
}

@test "modules: a thin loader is expanded to its sub-modules" {
    # 09-loader names 09a-sub by argument, and 02-beta depends on that sub-module:
    # only an expansion of the loader knows where it loads.
    _write_list 01-alpha 09-loader 02-beta
    _write_beta 'sub' 'beta-cmd'
    cat > "$FIXTURE/scripts/09-loader.sh" <<'SH'
# shellcheck shell=bash
# Module Version: 1
# @modular-section: loader
# @depends: none
# @exports: (none — loader only)

__tac_source_submodules "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" "09-loader" \
    09a-sub
SH
    cat > "$FIXTURE/scripts/09a-sub.sh" <<'SH'
# shellcheck shell=bash
# Module Version: 1
# @modular-section: loader-sub
# @depends: alpha
# @exports: sub-cmd

sub-cmd() { printf '%s\n' sub; }
SH
    run "$CHECKER" modules --repo "$FIXTURE"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"4 load position(s) (1 thin loader(s) expanded)"* ]]

    # ...and the expansion is real: point the declaration at a sub-module no loader
    # names, and the same edge is not a load-order edge at all.  (09a-sub.sh stays on
    # disk, so the checker also reports it as a module-shaped file nothing loads —
    # that is the same rule, and the assertion below is the one under test.)
    sed -i 's/^    09a-sub$/    09z-other/' "$FIXTURE/scripts/09-loader.sh"
    cat > "$FIXTURE/scripts/09z-other.sh" <<'SH'
# shellcheck shell=bash
# Module Version: 1
# @modular-section: loader-other
# @depends: none
# @exports: other-cmd

other-cmd() { printf '%s\n' other; }
SH
    run "$CHECKER" modules --repo "$FIXTURE"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"FAIL  unknown-depends  02-beta"* ]]
}

@test "modules: a loader naming a sub-module that does not exist fails" {
    _write_list 01-alpha 09-loader 02-beta
    cat > "$FIXTURE/scripts/09-loader.sh" <<'SH'
# shellcheck shell=bash
# Module Version: 1
# @modular-section: loader
# @depends: none
# @exports: (none — loader only)

__tac_source_submodules "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" "09-loader" \
    09a-absent
SH
    run "$CHECKER" modules --repo "$FIXTURE"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"names sub-module '09a-absent', which does not exist"* ]]
}

@test "modules: an @exports name that is not defined in the module fails" {
    cat > "$FIXTURE/scripts/01-alpha.sh" <<'SH'
# shellcheck shell=bash
# Module Version: 1
# @modular-section: alpha
# @depends: none
# @exports: alpha-cmd, ALPHA_STATE

renamed_cmd() { printf '%s\n' alpha; }
SH
    run "$CHECKER" modules --repo "$FIXTURE"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"@exports names 'alpha-cmd', which is not defined"* ]]
    [[ "$output" == *"@exports names 'ALPHA_STATE', which is not defined"* ]]
}

@test "modules: a module-shaped file no loader loads fails; a shebang'd entry point does not" {
    cat > "$FIXTURE/scripts/03-orphan.sh" <<'SH'
# shellcheck shell=bash
# Module Version: 1
# @modular-section: orphan
# @depends: none
# @exports: orphan-cmd

orphan-cmd() { printf '%s\n' orphan; }
SH
    run "$CHECKER" modules --repo "$FIXTURE"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"scripts/03-orphan.sh: a module-shaped file that neither"* ]]

    # A shebang makes it a standalone entry point (scripts/18-lint.sh), which is
    # deliberately not a profile module.
    sed -i '1i #!/usr/bin/env bash' "$FIXTURE/scripts/03-orphan.sh"
    run "$CHECKER" modules --repo "$FIXTURE"
    [[ "$status" -eq 0 ]]
}

@test "modules: a module with no annotation block fails" {
    cat > "$FIXTURE/scripts/02-beta.sh" <<'SH'
# shellcheck shell=bash
# Module Version: 1
beta-cmd() { printf '%s\n' beta; }
SH
    run "$CHECKER" modules --repo "$FIXTURE"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"no @modular-section annotation block"* ]]
}

@test "modules: an annotation block below executable code is still found" {
    # 01-constants.sh in the real tree has a user-configurable-paths section with real
    # code above its block; a "comments from line 1" reader finds no @depends there.
    cat > "$FIXTURE/scripts/01-alpha.sh" <<'SH'
# shellcheck shell=bash
# Module Version: 1

ALPHA_ROOT="${ALPHA_ROOT:-/tmp}"
# @modular-section: alpha
# @depends: none
# @exports: alpha-cmd, ALPHA_STATE

alpha-cmd() { printf '%s\n' alpha; }
ALPHA_STATE="ready"
SH
    run "$CHECKER" modules --repo "$FIXTURE"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"2 module(s) with a parsed @depends"* ]]
}

@test "modules: a multi-line @exports list is parsed in full" {
    # Every @exports list in the repo continues across ",", so a parser without
    # continuation support sees one name per module and silently under-reports.
    cat > "$FIXTURE/scripts/01-alpha.sh" <<'SH'
# shellcheck shell=bash
# Module Version: 1
# @modular-section: alpha
# @depends: none
# @exports: alpha-cmd,
#   alpha-helper,
#   ALPHA_STATE

alpha-cmd() { printf '%s\n' alpha; }
alpha-helper() { printf '%s\n' helper; }
ALPHA_STATE="ready"
SH
    run "$CHECKER" modules --repo "$FIXTURE"
    [[ "$status" -eq 0 ]]
    run "$CHECKER" derived --repo "$FIXTURE"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"3 command(s) derived from @exports"* ]]
}

@test "modules: a recorded disagreement passes, and deleting the baseline makes it fail" {
    # The ratchet shape the tool uses for the 13 disagreements that already exist in
    # the real tree: recording is a deliberate act, fixing is free, and the baseline
    # file is what makes the difference between "reported" and "fatal".
    _write_alpha 'beta' 'alpha-cmd, ALPHA_STATE'
    _write_beta 'none' 'beta-cmd'
    run "$CHECKER" modules --repo "$FIXTURE"
    [[ "$status" -eq 1 ]]

    mkdir -p "$FIXTURE/tools"
    cat > "$FIXTURE/tools/contracts-modules-baseline.tsv" <<'TSV'
# fixture baseline
order	01-alpha->02-beta	recorded for this test
TSV
    run "$CHECKER" modules --repo "$FIXTURE"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"RECORDED  order           01-alpha"* ]]
    [[ "$output" == *"disagreements: 1 recorded, 0 new"* ]]

    # Delete the record and the same tree is fatal again: the baseline is a debt
    # list, not an exemption.
    rm "$FIXTURE/tools/contracts-modules-baseline.tsv"
    run "$CHECKER" modules --repo "$FIXTURE"
    [[ "$status" -eq 1 ]]
}

@test "modules: a stale baseline row is reported, not fatal" {
    mkdir -p "$FIXTURE/tools"
    printf 'order\t01-alpha->02-beta\tno longer a disagreement\n' \
        > "$FIXTURE/tools/contracts-modules-baseline.tsv"
    run "$CHECKER" modules --repo "$FIXTURE"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"STALE"* ]]
    [[ "$output" == *"no longer a disagreement"* ]]
}

@test "modules: --print-baseline prints paste-ready rows and writes nothing" {
    _write_alpha 'beta' 'alpha-cmd, ALPHA_STATE'
    run "$CHECKER" modules --repo "$FIXTURE" --print-baseline
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"paste-ready rows for tools/contracts-modules-baseline.tsv"* ]]
    [[ "$output" == *"order	01-alpha->02-beta"* ]]
    [[ ! -f "$FIXTURE/tools/contracts-modules-baseline.tsv" ]]
}

@test "modules: a missing or empty load list refuses with exit 2 instead of passing" {
    rm "$FIXTURE/scripts/_module-list.sh"
    run "$CHECKER" modules --repo "$FIXTURE"
    [[ "$status" -eq 2 ]]
    [[ "$output" == *"_module-list.sh not found"* ]]

    # ...and an empty list is the same refusal, not a clean pass over nothing.
    printf 'function __tac_module_list() {\n    printf "%%s\\n"\n}\n' \
        > "$FIXTURE/scripts/_module-list.sh"
    run "$CHECKER" modules --repo "$FIXTURE"
    [[ "$status" -eq 2 ]]
    [[ "$output" == *"yielded no module names"* ]]
}

# ── derived ────────────────────────────────────────────────────────────────
@test "derived: the fixture passes and reports coverage as a number" {
    run "$CHECKER" derived --repo "$FIXTURE"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"check-contracts[derived]: OK"* ]]
    [[ "$output" == *"2 command(s) derived from @exports"* ]]
    [[ "$output" == *"SKILL.md table: 1 row(s) naming 1 distinct command(s), 1/1 resolvable"* ]]
    # Coverage is reported, never enforced: the table is a curated subset.
    [[ "$output" == *"Reported, never enforced: COVERAGE"* ]]
}

@test "derived: a SKILL.md row naming a command nothing exports fails" {
    sed -i 's/tac-exec beta-cmd/tac-exec gamma-cmd/' \
        "$FIXTURE/skills/tactical-console/SKILL.md"
    run "$CHECKER" derived --repo "$FIXTURE"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"FAIL  SKILL.md:"* ]]
    [[ "$output" == *"the table names 'tac-exec gamma-cmd', which no loaded module"* ]]
}

@test "derived: a contract entry naming a command nothing exports fails" {
    sed -i 's/^  - name: beta-cmd$/  - name: gamma-cmd/' \
        "$FIXTURE/docs/contracts/command-contracts.yaml"
    run "$CHECKER" derived --repo "$FIXTURE"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"entry 'gamma-cmd' names 'gamma-cmd', which no loaded module"* ]]
}

@test "derived: an alias export counts as a command, a variable export does not" {
    # ALPHA_STATE is an exported variable and must NOT be part of the command
    # surface, or the derived list would be full of constants.
    run "$CHECKER" derived --repo "$FIXTURE"
    [[ "$status" -eq 0 ]]
    [[ "$output" != *"ALPHA_STATE"* ]]

    # An alias IS a command: the real tree's m and h are aliases.
    cat > "$FIXTURE/scripts/01-alpha.sh" <<'SH'
# shellcheck shell=bash
# Module Version: 1
# @modular-section: alpha
# @depends: none
# @exports: alpha-cmd, ALPHA_STATE, alpha-alias

alpha-cmd() { printf '%s\n' alpha; }
alias alpha-alias='alpha-cmd'
ALPHA_STATE="ready"
SH
    run "$CHECKER" derived --repo "$FIXTURE"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"3 command(s) derived from @exports"* ]]
}

@test "derived: a missing SKILL.md or an empty enumeration refuses with exit 2" {
    rm "$FIXTURE/skills/tactical-console/SKILL.md"
    run "$CHECKER" derived --repo "$FIXTURE"
    [[ "$status" -eq 2 ]]
    [[ "$output" == *"SKILL.md not found"* ]]

    _write_tree
    printf 'version: 2\ncommands: []\n' > "$FIXTURE/docs/contracts/command-contracts.yaml"
    run "$CHECKER" derived --repo "$FIXTURE"
    [[ "$status" -eq 2 ]]
    [[ "$output" == *"declares no commands"* ]]
}

@test "derived: an authored table reduced to zero rows fails rather than passing silently" {
    cat > "$FIXTURE/skills/tactical-console/SKILL.md" <<'MD'
---
name: tactical-console
---

# Fixture skill

The table was deleted.
MD
    run "$CHECKER" derived --repo "$FIXTURE"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"no \`tac-exec\` table row was found"* ]]
}

# ── continuity ─────────────────────────────────────────────────────────────
@test "continuity: the fixture passes and the register is reported" {
    run "$CHECKER" continuity --repo "$FIXTURE"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"check-contracts[continuity]: OK"* ]]
    [[ "$output" == *"1 contract entr(ies) (1 active, 0 superseded)"* ]]
    [[ "$output" == *"1 decision record(s) in .agents/decisions/"* ]]
}

@test "continuity: an entry without version/updated/status/scope fails on each field" {
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
    contract:
      side_effects: []
YAML
    run "$CHECKER" continuity --repo "$FIXTURE"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"version:\` must be a positive integer"* ]]
    [[ "$output" == *"updated:\` must be an ISO date"* ]]
    [[ "$output" == *"status:\` must be one of active/superseded/retired"* ]]
    [[ "$output" == *"scope:\` must be one of interactive/library/both"* ]]
}

@test "continuity: two ACTIVE contracts may share a name only in different scopes" {
    cat >> "$FIXTURE/docs/contracts/command-contracts.yaml" <<'YAML'
  - name: beta-cmd
    family: fixture
    summary: Run beta in library mode
    version: 1
    updated: 2026-09-23
    status: active
    scope: library
    contract:
      side_effects: []
YAML
    run "$CHECKER" continuity --repo "$FIXTURE"
    [[ "$status" -eq 0 ]]

    # The same scope is the failure the field exists to prevent.
    sed -i '0,/^    scope: both$/s//    scope: library/' \
        "$FIXTURE/docs/contracts/command-contracts.yaml"
    run "$CHECKER" continuity --repo "$FIXTURE"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"two ACTIVE contracts for 'beta-cmd' in the same scope 'library'"* ]]
}

@test "continuity: a superseded entry must keep its contract and name its replacement" {
    cat > "$FIXTURE/docs/contracts/command-contracts.yaml" <<'YAML'
version: 2
commands:
  - name: beta-cmd
    family: fixture
    summary: The superseded rule
    version: 1
    updated: 2026-09-22
    status: superseded
    scope: both
    contract:
      side_effects: []
  - name: beta-cmd
    family: fixture
    summary: The replacement rule
    version: 2
    updated: 2026-09-23
    status: active
    scope: both
    contract:
      side_effects: []
YAML
    run "$CHECKER" continuity --repo "$FIXTURE"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"status is superseded but there is no \`superseded_by:\` pointer"* ]]
    [[ "$output" == *"status is superseded but \`superseded:\` is not an ISO date"* ]]

    # A dangling pointer is the other half: mark it superseded and point at a name
    # that does not exist.
    sed -i 's/^    status: superseded$/    status: superseded\n    superseded: 2026-09-23\n    superseded_by: gamma-cmd/' \
        "$FIXTURE/docs/contracts/command-contracts.yaml"
    run "$CHECKER" continuity --repo "$FIXTURE"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"superseded_by names 'gamma-cmd', which is not an entry in this file"* ]]
}

@test "continuity: the valid superseded shape passes" {
    cat > "$FIXTURE/docs/contracts/command-contracts.yaml" <<'YAML'
version: 2
commands:
  - name: beta-cmd
    family: fixture
    summary: The superseded rule
    version: 1
    updated: 2026-09-22
    status: superseded
    superseded: 2026-09-23
    superseded_by: beta-cmd
    scope: both
    contract:
      side_effects:
        - the old behaviour, kept as the record of what was superseded
  - name: beta-cmd
    family: fixture
    summary: The replacement rule
    version: 2
    updated: 2026-09-23
    status: active
    scope: both
    contract:
      side_effects: []
YAML
    run "$CHECKER" continuity --repo "$FIXTURE"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"1 active, 1 superseded"* ]]
}

@test "continuity: a superseded_by chain that loops or ends at a dead end fails" {
    cat > "$FIXTURE/docs/contracts/command-contracts.yaml" <<'YAML'
version: 2
commands:
  - name: beta-cmd
    family: fixture
    summary: First rule
    version: 1
    updated: 2026-09-21
    status: superseded
    superseded: 2026-09-22
    superseded_by: beta-cmd
    scope: both
    contract:
      side_effects: []
YAML
    run "$CHECKER" continuity --repo "$FIXTURE"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"the superseded_by chain"* ]]
}

@test "continuity: an empty decision register fails, and a record naming an unexported command fails" {
    rm "$FIXTURE/.agents/decisions/fixture-decision.md"
    run "$CHECKER" continuity --repo "$FIXTURE"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"holds no decision record"* ]]

    _write_decision 'commands: [gamma-cmd]'
    run "$CHECKER" continuity --repo "$FIXTURE"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"decision \`commands:\` names 'gamma-cmd', which no loaded module"* ]]

    # A record whose frontmatter name does not match its file is not a record the
    # check can surface, so it fails rather than being skipped.
    _write_decision 'commands: []'
    sed -i 's/^name: fixture-decision$/name: other-name/' \
        "$FIXTURE/.agents/decisions/fixture-decision.md"
    run "$CHECKER" continuity --repo "$FIXTURE"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"does not match the file name"* ]]
}

@test "continuity: naming a command surfaces its entry, its family and its decisions" {
    cat >> "$FIXTURE/docs/contracts/command-contracts.yaml" <<'YAML'
  - name: alpha-cmd
    family: fixture
    summary: The sibling command
    version: 1
    updated: 2026-09-23
    status: active
    scope: both
    contract:
      side_effects: []
YAML
    run "$CHECKER" continuity beta-cmd --repo "$FIXTURE"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"--- continuity for: beta-cmd ---"* ]]
    [[ "$output" == *"ENTRY    beta-cmd v1 status=active scope=both"* ]]
    [[ "$output" == *"FAMILY   still applies from the same family: alpha-cmd"* ]]
    [[ "$output" == *"DECISION fixture-decision"* ]]

    # A command with no recorded rule says so: silence would read as "checked".
    run "$CHECKER" continuity gamma-cmd --repo "$FIXTURE"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"NONE     'gamma-cmd' has no contract entry"* ]]
}

@test "continuity: a malformed contract file fails cleanly with exit 2" {
    printf 'version: [1, 2\n' > "$FIXTURE/docs/contracts/command-contracts.yaml"
    run "$CHECKER" continuity --repo "$FIXTURE"
    [[ "$status" -eq 2 ]]
    [[ "$output" == *"does not parse"* ]]
    [[ "$output" != *"Traceback"* ]]
}

# ── swallows ───────────────────────────────────────────────────────────────
@test "swallows: a fixture with no swallow sites passes with a zero population" {
    run "$CHECKER" swallows --repo "$FIXTURE"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"check-contracts[swallows]: OK"* ]]
    # Three files: the two modules and the load list itself.
    [[ "$output" == *"0 site(s) in 3 file(s) | 0 classified | 0 unclassified"* ]]
}

@test "swallows: a NEW unclassified swallow fails; marking it with a reason passes" {
    cat >> "$FIXTURE/scripts/01-alpha.sh" <<'SH'

# Capability probe: the tool may be absent.
probe_tool() { command -v some-tool 2>/dev/null >/dev/null || true; }
SH
    run "$CHECKER" swallows --repo "$FIXTURE"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"scripts/01-alpha.sh: 2 unclassified swallow(s) and no baseline row"* ]]
    [[ "$output" == *"one-line reason"* ]]

    # The documented convention: one comment line, on the site or directly above it.
    sed -i 's/^probe_tool() .*$/probe_tool() { :; }/' "$FIXTURE/scripts/01-alpha.sh"
    cat >> "$FIXTURE/scripts/01-alpha.sh" <<'SH'
# The tool is optional by design; absence is the state the caller checks for.
# swallow-ok: an absent optional tool is an expected state, not a failed operation.
probe_tool() { command -v some-tool 2>/dev/null >/dev/null || true; }
SH
    run "$CHECKER" swallows --repo "$FIXTURE"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"2 classified"* ]]
}

@test "swallows: a marker two lines above the site does not classify it" {
    # Deliberate: a wrapped marker (or a stale explanation) must not silence a site
    # by accident, because that is the failure class this check exists to catch.
    cat >> "$FIXTURE/scripts/01-alpha.sh" <<'SH'
# swallow-ok: this marker is not adjacent, so it must classify nothing at all.
# (and here is a second comment line in the same block)
probe_far() { command -v far 2>/dev/null || true; }
SH
    run "$CHECKER" swallows --repo "$FIXTURE"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"2 unclassified swallow(s)"* ]]
}

@test "swallows: a marker with no reason is not a reason" {
    cat >> "$FIXTURE/scripts/01-alpha.sh" <<'SH'
# swallow-ok: hmm
probe_more() { command -v x 2>/dev/null || true; }
SH
    run "$CHECKER" swallows --repo "$FIXTURE"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"needs a reason"* ]]
}

@test "swallows: a count that rises above the baseline fails; a fall is reported as STALE" {
    mkdir -p "$FIXTURE/tools"
    printf 'unclassified\tscripts/01-alpha.sh\t1\n' \
        > "$FIXTURE/tools/contracts-swallows-baseline.tsv"
    printf 'probe_a() { command -v a || true; }\n' >> "$FIXTURE/scripts/01-alpha.sh"
    run "$CHECKER" swallows --repo "$FIXTURE"
    [[ "$status" -eq 0 ]]

    printf 'probe_b() { command -v b || true; }\n' >> "$FIXTURE/scripts/01-alpha.sh"
    run "$CHECKER" swallows --repo "$FIXTURE"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"2 unclassified swallow(s) against a baseline of 1"* ]]

    # A fall is free, and the row is named so the baseline can follow it down.
    sed -i 's/^probe_a() .*$/probe_a() { :; }/' "$FIXTURE/scripts/01-alpha.sh"
    sed -i 's/^probe_b() .*$/probe_b() { :; }/' "$FIXTURE/scripts/01-alpha.sh"
    run "$CHECKER" swallows --repo "$FIXTURE"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"STALE     scripts/01-alpha.sh"* ]]
}

@test "swallows: the scan is limited to scripts/ and says so" {
    mkdir -p "$FIXTURE/bin"
    cat > "$FIXTURE/bin/helper.sh" <<'SH'
#!/usr/bin/env bash
helper() { command -v x 2>/dev/null || true; }
SH
    run "$CHECKER" swallows --repo "$FIXTURE"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"scripts/*.sh"* ]]
    [[ "$output" == *"bin/ and tools/ are not scanned"* ]]
}

@test "swallows: --print-baseline prints rows and writes nothing" {
    cat >> "$FIXTURE/scripts/01-alpha.sh" <<'SH'
probe_c() { command -v c 2>/dev/null || true; }
SH
    run "$CHECKER" swallows --repo "$FIXTURE" --print-baseline
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"unclassified	scripts/01-alpha.sh	2"* ]]
    [[ ! -f "$FIXTURE/tools/contracts-swallows-baseline.tsv" ]]
}

# ── dispatch ───────────────────────────────────────────────────────────────
@test "dispatch: a bare run executes every subcommand and stays meaningful" {
    run "$CHECKER" --repo "$FIXTURE"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"check-contracts[state]: OK"* ]]
    [[ "$output" == *"check-contracts[modules]: OK"* ]]
    [[ "$output" == *"check-contracts[derived]: OK"* ]]
    [[ "$output" == *"check-contracts[continuity]: OK"* ]]
    [[ "$output" == *"check-contracts[swallows]: OK"* ]]
}

@test "dispatch: a COMMAND name is only accepted for continuity" {
    run "$CHECKER" modules beta-cmd --repo "$FIXTURE"
    [[ "$status" -eq 2 ]]
    [[ "$output" == *"unexpected argument(s) beta-cmd"* ]]

    run "$CHECKER" beta-cmd --repo "$FIXTURE"
    [[ "$status" -eq 2 ]]
    [[ "$output" == *"unknown argument 'beta-cmd'"* ]]
    [[ "$output" == *"only accepted with the \`continuity\` subcommand"* ]]
}

@test "dispatch: an unknown option exits 2; --version prints 2" {
    run "$CHECKER" --bogus
    [[ "$status" -eq 2 ]]
    [[ "$output" == *"unknown option '--bogus'"* ]]
    run "$CHECKER" --version
    [[ "$status" -eq 0 ]]
    [[ "$output" == "check-contracts 2" ]]
}

# end of file
