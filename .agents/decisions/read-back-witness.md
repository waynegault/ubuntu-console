---
name: read-back-witness
date: 2026-09-23
status: active
scope: both
commands: [model, so, xo, up, burn, cl, logtrim]
---

**Decision:** an ACTIVE entry in `docs/contracts/command-contracts.yaml` whose
`contract:` lists side effects must declare how that effect was READ BACK before the
command printed success — either `read_back:` (a list of witnesses: the function that
performs the query, the file that defines it, and the claim it asserts) or
`read_back_exempt: <reason>` saying the witness is not declared yet.  `model use` and
`model stop` carry witnesses; `up`, `so`, `xo`, `burn`, `cl` and `logtrim` carry
reasons.  `tools/check-contracts.sh state` enforces it (inside an existing
subcommand, deliberately not a sixth top-level checker).

**Why:** the command contract stated a command's side effects but nothing said the
command had CHECKED that they happened, and the code reflected that: `model use`
printed "ONLINE [Port N]" after a pointer write that only warned when it failed, and
`model stop` printed "[STOPPED]" without re-querying anything — a success line for
state that could be untrue (card CLAIMED-SUCCESS-WITNESS-001; the card's own words:
"no test verifies a command actually performed its declared side effect before
printing success").  Both were real: every consumer resolves the active model through
that pointer, and a stop that did not stop leaves the card and the port held.

**How to apply:** a new state-mutating command needs a witness before it can report
success — a re-query of the state (health endpoint, pointer file, port, registry) that
fails LOUDLY, and a contract entry naming it.  The witness is verified mechanically:
the file must exist, the symbol must be a function DEFINED there, and it must be
CALLED (a non-comment reference) in the module that `@exports` the command — a
defined-but-uncalled witness is the decorative version of this.  Do not add
`read_back_exempt` to silence a witness you could write; use it when the read-back
genuinely does not exist yet, and say what it would be.  The three edited entries
outside this card's LLM scope carry that form on purpose, so the gap is printed as
`NOT WITNESSED` on every run instead of being invisible.

Also decided here, because `continuity`'s versioning rule needed an answer: an
ADDITIVE field is a new `version` with NO superseded predecessor (the v1 rule still
holds verbatim), while a REPLACED rule keeps its predecessor as `status: superseded`
with a `superseded_by:` pointer.  That reading is what the eight v2 entries above
follow.
