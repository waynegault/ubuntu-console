---
name: separation-of-duties
date: 2026-09-29
status: active
scope: both
---

**Decision:** ubuntu-console ADOPTS the spec-driven separation of duties in a NARROW,
stated form.  Card SPEC-VV-CONSOLE-001 asked for this decision to be made explicitly
rather than left implicit; this record is that decision.  Concretely: the two roles are
not separate agents and no role-scoped viewer is built — the repo has no coder-agent
dispatch loop to attach one to, and step 3 of the card forbids rebuilding what already
works.  The separation that IS adopted is the one the repo already carries in a stronger
form than a prose split: the CONTRACT is the independently authored specification.

**The withheld half is the acceptance criteria**, not the requirements.  For any
command, the implementer is given the requirements — the entry's `summary`, `args` and
`contract.side_effects` in `docs/contracts/command-contracts.yaml`.  The verifier is
given, in addition, the acceptance criteria: `contract.output_shape`, `contract.exit_code`,
the `read_back:` witness claim, and the fault-naming rules `tools/check-contracts.sh`
documents for its subcommands.  A verifying test's expected value must come from those
criteria and from the checker's documented behaviour.  It must NOT be read off the
implementation's current output: written that way it asserts consistency, which — as the
card's source puts it — "was never in doubt".

**Why:** SPEC-VV-CONSOLE-001 and its audit
(`docs/tds/tds-spec-driven-test-automation.md` in the investigator repo; source
"Towards Spec-Driven Test Automation: Part 1", Gal Arav, TDS, 2026-09-24,
<https://towardsdatascience.com/towards-spec-driven-test-automation-part-1/>).  The
failure the article names is that one reader resolves every ambiguity of an ambiguous
sentence one way and then writes both the code and its tests from that single reading,
so the suite cannot disagree with the code.  The console already holds the article's
load-bearing half — a machine-checked, hand-authored contract
(`docs/contracts/*.yaml`) verified by `tools/check-contracts.sh`, plus the read-back
witnesses — so the remaining gap is a discipline about WHERE a test's expected value
comes from, not a new subsystem.

**How to apply:** when writing a test for a contracted command (a BATS suite under
`tests/unit/`, or a fixture in the contracts falsification battery), state in the test
which contract entry and which checker rule it is asserting, and derive the expected
value from that text.  Do not pin the implementation's current message unless the
contract declares that message.  `tools/check-contracts.sh continuity <command>` prints
the entry a verifier should read; the falsification battery added by
SPEC-VV-CONSOLE-002 (`tests/unit/34-contracts-falsification.bats`) is the enforcement —
each seeded fault is chosen from the checker's documented rule, so the battery is red
when the rule stops being enforced.  This decision does not add a mechanism and must not
be cited to justify one: the contract, the checker and the read-back witnesses stay the
single source, and a test that would need a new tool to be independent is a signal that
its criterion is not stated in the contract yet.
