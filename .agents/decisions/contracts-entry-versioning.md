---
name: contracts-entry-versioning
date: 2026-09-23
status: active
scope: both
commands: []
---

**Decision:** every entry in `docs/contracts/command-contracts.yaml` carries its own
`version`, `updated`, `status` and `scope`, and an edited contract is a NEW version
whose predecessor stays in the file as `status: superseded` with a
`superseded_by:` pointer — never deleted.

**Why:** the file self-described as a "starter contract set" and was read by no
script or test, so an edit to a stated-once rule left no record of what it replaced,
and two contracts for the same command could not both stay active across the
interactive loader and `tac-exec` library mode. Card INTENT-CONT-007
("Coding Agents Don't Need Longer History — They Need Intent Continuity", TDS
2026-09-11): new work never triggers a check of whether an older decision still
applies. The shape is the one investigator already uses for a canonical answer
(`pipeline/canonical_faq.py`, status `active|superseded|retired` plus
`superseded_by`).

**How to apply:** do not delete or rewrite a contract entry's rule — bump `version`,
set `updated`, and if the rule is replaced, add the replacement as a new entry and
mark the old one `status: superseded` + `superseded` + `superseded_by`. Run
`tools/check-contracts.sh continuity <command>` before changing a command: it prints
the active entries, any superseded predecessor and the same-family entries that still
apply.
