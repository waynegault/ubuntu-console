---
name: depends-order-baseline
date: 2026-09-23
status: active
scope: both
commands: []
---

**Decision:** the 13 `@depends`/load-order disagreements measured on 2026-09-23 are
RECORDED in `tools/contracts-modules-baseline.tsv` rather than fatal, and
`tools/check-contracts.sh modules` fails only on a NEW one.

**Why:** the declarations and the real load order genuinely disagree today, so a hard
rule would have landed a red gate. Measured: 12 `@depends` edges name a module that
loads AFTER the dependent (09a/09c/09e point at §11, which loads later; 11a→11b/11c,
11b→11e/11f, 11e→11f inside the §11 loader), one strongly-connected component
(11a/11b/11c/11d/11e/11f), and one prose form (`13-init`: `@depends: all sections
above`). docs/inspection.md §9.4.1 claims "Every module's @depends lists only modules
with a lower numeric prefix. No circular dependencies." — that claim is false at HEAD,
which is exactly the drift the check exists to make visible.

**How to apply:** do not reorder `scripts/_module-list.sh` to satisfy the checker, and
do not re-baseline to make a new violation pass. Repair the DECLARATION instead —
a runtime collaborator (09a calling `model`/`serve`) is not a load-order edge, and the
§11 group is mutually recursive by design, so the repair needs an agreed field for a
run-time reference (the headers already carry `@state-in`/`@state-out` for a related
purpose). Four of those files (11b/11c/11d/11e) were reserved by a concurrent session
during the pass that added the checker, which is why the repair is a follow-up.
