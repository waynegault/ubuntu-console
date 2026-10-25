# Codebase audit record (retired)

The 2026-10-15 audit's closed findings, evidence and verification are retained in
git history at `2b706d66:docs/audit-findings.md`:

    git show 2b706d66:docs/audit-findings.md

Its closed table is no longer maintained here. The three open follow-ups were moved
to the workboard on 2026-10-25 by this session, each carrying its measurement, both
consequences, the decision still owed as lettered options, and a binary acceptance
line:

| Card | Title |
|---|---|
| `87d3022b` | AUD-FU-001 — Salus scheduler `_run` is 266 lines and cannot be refactored without a verified deploy path |
| `e23aadcd` | AUD-FU-002 — `nas-cpap-unified.py::_fetch_cpap_data` is deliberately unimplemented; decide delete vs implement |
| `5441e1c5` | AUD-FU-003 — Measure a representative live-hardware LLM performance baseline |

This file is a pointer, not a status report. The cards are the live record, and the
closed findings remain readable at the commit named above.
