#!/usr/bin/env bash
# shellcheck shell=bash
# ==============================================================================
# check-contracts.sh — Contract-drift guard for the ubuntu-console repo.
# ==============================================================================
# Card STATE-CONTRACT-VALIDATION-001 opened this file.  One home for the console's
# drift checkers: this file is a SUBCOMMAND DISPATCHER, and each subcommand owns one
# class of drift.  The board decision of 2026-09-21 put all five proposed top-level
# checkers here rather than in five new tools/ scripts; the other four landed
# 2026-09-23 and each cites its own card below.
#
#   state       docs/contracts/state-contracts.yaml — the cross-handler state
#               contract (who produces each variable and /dev/shm cache, who
#               consumes it, who invalidates it).
#   modules     the @depends/@exports headers against the REAL load order read from
#               scripts/_module-list.sh, with thin loaders expanded.
#   derived     the DERIVED command surface (from @exports) against the AUTHORED
#               enumerations that snapshot it (skills/tactical-console/SKILL.md's
#               tac-exec table and docs/contracts/command-contracts.yaml).
#   continuity  per-entry version/status/scope/superseded_by, the per-entry
#               `verified_by:` test nodes and the `disposition:`/`bound:` triage in
#               docs/contracts/command-contracts.yaml, plus the decision register
#               under .agents/decisions/.
#   swallows    unclassified `|| true` and `2>/dev/null` sites in the shell corpus
#               (scripts/*.sh, bin/*, tools/*.sh, tools/hooks/*, tools/qwen-hooks/*,
#               nas/**/*.sh).
#
# A bare `check-contracts.sh` runs EVERY subcommand, so the no-argument invocation
# stays meaningful.  A subcommand is added by adding its name to SUBCOMMANDS and
# giving it an arm in run_selected() (plus a matching run_<name>() checker) —
# nothing else in this file needs to know.  A name in RESERVED exits 2 with a
# message naming its owner instead of silently doing nothing.
#
# WHY `state` EXISTS — the failure it catches:
# The article this card cites names the "cross-handler state disconnect": handler
# A clears or changes state that handler B still reads; neither references the
# other, so each looks fine alone.  2026-09-22: renaming /dev/shm/active_llm, or
# deleting the write in scripts/11e-llm-model.sh, degrades the dashboard with NO
# error anywhere — the cache read just returns empty and the row falls back to a
# default.  Before this checker, docs/contracts/state-contracts.yaml was prose:
# nothing parsed it, so every declared edge was unverified documentation.
#
# `state` ALSO VERIFIES THE READ-BACK WITNESSES (card CLAIMED-SUCCESS-WITNESS-001,
# authored half — see check_read_backs below): every ACTIVE command entry in
# docs/contracts/command-contracts.yaml whose contract lists side effects must
# declare how the effect was read back before success was printed (`read_back:`),
# or declare `read_back_exempt: <why>`; every declared witness must name a file
# that exists, a symbol that is a FUNCTION defined there, and a call site in the
# module that exports the command.  It lives inside `state` rather than as a sixth
# subcommand: the claim is a state claim, and the dispatcher stays at five.
#
# ENFORCED, per entry (fails name the symbol, the file, and a line when there is
# one to name):
#   1. the contract parses, and every entry is structurally complete (a name or
#      path, a producer, at least one consumer edge, and a `why:` on every edge
#      marked `unenforced: true`);
#   2. no two entries declare the same symbol;
#   3. every declared producer file exists, and the producer set contains a
#      WRITE of the entry:
#        variable -> an assignment of that name, including the guarded form
#                    `... && NAME=$(< cache)`, but never a bare read of it;
#        file     -> a binding whose right-hand side is the path
#                    (`local cache="$TAC_CACHE_DIR/tac_hostmetrics"`) or a
#                    redirect/mutating command whose TARGET holds it
#                    (`> "${ACTIVE_LLM_FILE}.tmp"`).  A command substitution on
#                    the right (`tps=$(cat "$LLM_TPS_CACHE")`) is a READ and does
#                    not count.  A DELETE (`rm -f "$CACHE"`) never satisfies a
#                    producer edge — that is what `invalidators:` is for; with
#                    `rm` counted as a write, `rm -f "$ACTIVE_LLM_FILE"` passed as
#                    the producer of /dev/shm/active_llm and the real write could
#                    be deleted unnoticed (measured 2026-09-22);
#   4. the declared PATH of a file entry is still bound somewhere in its producer
#      set.  Without this, a renamed cache hides behind the variable name: every
#      consumer reads `$ACTIVE_LLM_FILE`, so the entry survived renaming the path
#      to /dev/shm/active_model.  Measured on a fixture;
#   5. every declared consumer file exists, and references the entry (the symbol,
#      the path, any declared binding, or an edge-level `via:`);
#   6. every declared invalidator file exists, and deletes the entry;
#   7. the number of entries parsed equals the number of `- name:`/`- path:`
#      entries in the file, so a schema change cannot silently stop an entry
#      from being checked;
#   8. a producer/consumer that is a thin loader (`__tac_source_submodules`) is
#      expanded to itself plus its named sub-modules — and a sub-module the
#      loader names but that does not exist is a failure.
#
# NOT ENFORCED (stated, never silently skipped — the summary prints both counts):
#   * a file that references a declared symbol WITHOUT being declared as an edge
#     is invisible: the check is over declared edges.  Re-deriving "every file that
#     touches this symbol" is a separate exercise — the 2026-09-22 revision did it
#     by hand and found several undeclared references, each now declared (VSCODE_BIN
#     read by §11f, TACTICAL_PROFILE_VERSION read by §9e, the 0-placeholder
#     assignments of __TAC_OPENCLAW_OK / LAST_TPS in §1, and bash-errors.log
#     written by §13 and by scripts/_startup-env.sh).
#   * `type`, `format`, `semantics`, `translation_rules` and `notes` are prose.
#   * an edge the contract marks `unenforced: true` (with a required `why:`).
#   * tokens are SUBSTRING matches, so a rename that keeps the declared token as a
#     prefix (`tac_hostmetrics` -> `tac_hostmetrics2`) is not caught, and a
#     producer edge proves a write-shaped declaration still exists in the file —
#     not that its target is still reached at run time (the BATS suites cover the
#     behaviour).
#   * the check reads SOURCE, so an edge that only exists at run time (a variable
#     passed through the environment, a file written by an external tool) can only
#     be declared, not verified.
#
# WHY `modules` EXISTS — the failure it catches:
# The console already does the hard half of "draw dependencies, not sequences":
# every module header declares its edges (`# @depends:`, `# @exports:`) and both
# loaders source the modules in the order scripts/_module-list.sh gives ("never a
# glob").  But those declarations were parsed NOWHERE — no cycle check, no order
# check, no check that a name is declared by a module loaded EARLIER — so the
# declarations could drift from the load order with no failure.  Measured
# 2026-09-23 (the pass that added the check): 12 declared edges name a module that
# loads AFTER the dependent, 1 strongly-connected component (11a-11f), and
# docs/inspection.md §9.4.1's "no circular dependencies" claim is false at HEAD.
#
# SPLIT 2026-09-23 (card MOD-GRAPH-DECLARATION-001).  Those disagreements were NOT
# load-order bugs: `@depends` was carrying two relationships at once — "must be
# sourced first" and "this module calls that one" — and only the first is a
# load-order claim.  Measured evidence for that: sourcing the library loader in a
# scrubbed `env -i` gives rc=0 with zero `command not found` and zero `unbound
# variable`, so none of the twelve forward edges is used AT SOURCE TIME.  The
# run-time references moved to a new `@uses:` field, tools/contracts-modules-
# baseline.tsv was deleted, and the load-order claim became both checkable and true.
# `@depends` now means LOAD ORDER ONLY; `@uses` means "calls at run time".
#
# ENFORCED by `modules`:
#   1. every module in the load order exists, and carries a `# @modular-section:`
#      annotation block with an `@depends:` field; the block is read from its own
#      anchor, not from the top of the file (01-constants.sh has code above its
#      block), and a value continues across the `,`-terminated comment lines the
#      repo writes every @exports list on;
#   2. every `@depends` target resolves to exactly one loaded module — the literal
#      `none` (with or without a parenthetical) means "no dependencies", and a
#      parenthetical is prose (`cd (override)` -> `cd`);
#   3. no module declares a dependency on itself;
#   4. every `@exports` name is DEFINED in the module or its load unit (a function,
#      an alias, or a variable assignment) — an export that names nothing is drift;
#   5. a module-shaped file (`NN-*.sh` / `NNx-*.sh`) that no loader loads and that
#      is not a shebang'd entry point is a failure: no pass would analyse it;
#   6. a thin loader that names a sub-module which does not exist is a failure;
#   7. no NEW edge violates the load order, and no NEW declaration names a
#      non-module.  A cycle is printed with its concrete path; every cycle
#      necessarily contains a forward edge, so a new cycle can never be silent.
#   8. `@uses` is OPTIONAL (a module with no run-time collaborators omits it, which
#      unlike a missing `@depends` is not a defect).  Where present, every target
#      must resolve to a loaded module, may not be the module itself, and may not
#      also appear in `@depends` — the fields partition the edges.  It carries NO
#      order requirement and a `@uses` cycle is legitimate (§11 is mutually
#      recursive by design), so cycles are computed over `@depends` edges only.
# REPORTED, never enforced by `modules`: whether a forward edge is actually
# reached at run time (the BATS suites cover behaviour).
#
# NO BASELINE FILE EXISTS.  tools/contracts-modules-baseline.tsv was DELETED in
# 66f17e5e, so nothing is grandfathered: every load-order disagreement is reported
# as NEW and FAILS this check.  The reader and the RECORDED/STALE paths below are
# kept for a future baseline — re-add the file and its rows print in full, each with
# the module pair and a cycle path when the edge closes one, and a row that is no
# longer a disagreement prints as STALE (a free fix: remove the row).
#
# WHY `derived` EXISTS — the failure it catches:
# A static skill is a cache with no invalidation protocol: SKILL.md's tac-exec table
# is a snapshot of the CLI and drifts when a command is renamed.  There is no
# command registry in this repo and none is invented — the machine-checkable
# surface is DERIVED from the `@exports` headers the modules already carry.
#
# ENFORCED by `derived`:
#   1. every command NAMED by a SKILL.md tac-exec table row, or by a
#      `docs/contracts/command-contracts.yaml` entry, is exported as a function or
#      an alias by a loaded module (a variable export is a value, not a command);
#   2. both authored enumerations parse to at least one row/entry, and the derived
#      surface is non-empty — a parse that finds nothing must not read as clean.
# REPORTED, never enforced by `derived`: COVERAGE.  The table is a curated subset
# (a human owns the scope of what to consult), so requiring completeness would be
# wrong; the summary prints how many derived commands each authored list names,
# and how many derived commands nothing names.
#
# WHY `continuity` EXISTS — the failure it catches:
# New work never triggers a check of whether an older decision still applies.  The
# natural home for stated-once rules, docs/contracts/command-contracts.yaml, was
# read by no script or test: an edited rule left no record of what it replaced, a
# rule could not be scoped to the interactive loader or to library mode, and
# nothing under .agents/ persisted an agent's decision across sessions.
#
# ENFORCED by `continuity` (per command-contract entry): a positive integer
# `version:`, an ISO `updated:`, a `status:` in active/superseded/retired, a
# `scope:` in interactive/library/both; two ACTIVE entries may share a name only in
# DIFFERENT scopes; a superseded entry keeps its `contract:` block and carries both
# `superseded:` and `superseded_by:`, and every superseded_by chain ends at an
# active entry (a dangling pointer or a chain to a dead end is a failure).  For the
# register: .agents/decisions/ must hold at least one record, whose frontmatter
# parses, whose `name:` matches its file name, whose `date:` is ISO, whose
# `status:`/`scope:` are known values, and whose `commands:` values resolve to an
# exported command.
#   `verified_by:` (card SPEC-VV-CONSOLE-003) is an OPTIONAL entry-level list, a
#   sibling of `read_back:`, whose items are test nodes written
#   `<repo-relative path>::<exact @test name>`.  The oracle is the @test NAME PARSER
#   for tests/**/*.bats (the same declaration regex the pytest bridge uses), so a
#   node this check accepts is a node the bridge collects.  A declared node that does
#   not exist is a FAIL, naming the entry and the node; the field is validated on
#   every entry, superseded ones included, because a dangling pointer is dangling
#   wherever it sits.
#   `disposition:` (card SPEC-VV-CONSOLE-004) is an OPTIONAL entry-level field, the
#   article's triage: `decision` for a line two competent developers could disagree
#   about (it needs a `bound:` stating the closed value an owner chose) and
#   `consequence` for a line derived from its producer (it must carry no `bound:`, or
#   the value goes stale silently).  A decision with no weighable bound FAILS, a
#   consequence with a bound FAILS, any other value FAILS naming the two, and a
#   `bound:` with no `disposition:` FAILS.  The classification itself is AUTHORED and
#   cannot be checked here — the check refuses an incoherent pair, and an entry whose
#   own text does not settle the question is left UNCLASSIFIED and counted rather than
#   guessed at.
# REPORTED, never enforced by `continuity`: what the contracts SAY (`side_effects`,
# `output_shape`, `exit_code` are prose — `state` and `swallows` enforce their own
# halves); the ACTIVE entries that declare no `verified_by:` or no `disposition:` at
# all (the same posture `state` takes for its NOT ENFORCED edges and NOT WITNESSED
# entries — the gap is COUNTED and printed, never silent, and an unverified or
# unclassified entry is not a failure); and the changed-entry pass, which prints (or
# prints that it could not run) the entries added against HEAD and the older
# same-family entries that still apply.
#
# NOT COVERED by `verified_by` (stated rather than implied): a Python test cannot be
# named — the index is BATS only — and the check proves a node EXISTS, not that the
# test genuinely exercises the command.  The map is authored, so it can be wrong in
# the direction of naming a weaker test; that is a review question, not a checkable
# one.  Likewise `disposition:` is authored: the check proves a `decision` states a
# bound and a `consequence` does not, never that the line was TRIAGED correctly, so a
# mis-triaged line stays a review question (which is why the unclassified count is
# printed — the entries nobody has judged are the ones that need the owner).
#
# WHY `swallows` EXISTS — the failure it catches:
# An unclassified `|| true` or `2>/dev/null` is a silent failure: the code runs,
# returns something plausible, and the mistake stays invisible.  Reclassifying the
# whole corpus is a separate pass, so this subcommand does the count-ratchet job
# tools/count-ratchet.sh already uses for exactly this situation.
#
# ENFORCED by `swallows`: no NEW unclassified swallow site anywhere in the shell corpus
# (a count that RISES above tools/contracts-swallows-baseline.tsv, or a file that is not in
# it and carries one, is a failure), and every `# swallow-ok:` marker carries a
# reason of its own (8+ characters).  The marker is ONE comment line and it
# classifies a site on its own line or on the line directly below it — deliberately
# not "somewhere in the comment block above", because a stale explanation would then
# silence a new swallow silently.
# REPORTED, never enforced by `swallows`: the recorded unclassified population (its
# size, the heaviest files, and the `grep -c`-style line counts beside the site
# counts), and the same counts in bin/ and tools/, which are outside this pass's
# scope.  `--dump-sites` is the machine-readable form of the same population (one
# JSON object per site: file, line, pattern, matched text, classified, reason,
# reason source and whether the reason is weighable) for a consumer such as
# tools/swallow-classify.py — so the site SCANNER lives here once and a consumer
# never re-greps the corpus with a second scanner that could disagree (card
# SPLIT-CONTRACT-TRIAGE-001).  It is read-only, prints the human summary to stderr,
# and exits 0 even when sites are unclassified: a dump is not a verdict.
#
# DEFERRED from the card that owns this check: read-back assertions before a
# success echo (model start/stop/switch, vault load, orphan clean, gog auth) — those
# live in files a concurrent session owns — stale-telemetry badges in the dashboard
# render, and injected-failure BATS cases for both.
#
# Usage:
#   tools/check-contracts.sh                     # every subcommand
#   tools/check-contracts.sh state               # just the state contract
#   tools/check-contracts.sh modules --repo DIR  # check another checkout (tests)
#   tools/check-contracts.sh continuity model use # what still applies to a command
#   tools/check-contracts.sh swallows --print-baseline  # read-only: paste-ready rows
#   tools/check-contracts.sh --version
#
# Exit 0 = every enforced rule holds.
# Exit 1 = drift (a producer stopped producing, a declaration disagrees with the
#          load order, an authored list names a command nothing exports, a contract
#          entry is unversioned/unscoped, or a NEW swallow is unclassified).
# Exit 2 = bad invocation, or the check cannot run (no python3, no PyYAML, the
#          artifact it checks is absent or unparseable).  Never a weaker parse.
#
# REF: "Coding Agents Keep Shipping Silent Failures — Here Is How to Catch Them"
#      (TDS, 2026-09-18) — swallows —
#      https://towardsdatascience.com/coding-agents-keep-shipping-silent-failures-here-is-how-to-catch-them/
# REF: "Graph Engineering for AI Agents: From Prompts and Loops to Workflows"
#      (TDS, 2026-09-14) — modules —
#      https://towardsdatascience.com/graph-engineering-for-ai-agents-from-prompts-and-loops-to-workflows/
# REF: "From Static to Dynamic Skills: A Different Model for Agent Knowledge"
#      (TDS, 2026-09-14) — derived —
#      https://towardsdatascience.com/from-static-to-dynamic-skills-a-different-model-for-agent-knowledge/
# REF: "Coding Agents Don't Need Longer History — They Need Intent Continuity"
#      (TDS, 2026-09-11) — continuity —
#      https://towardsdatascience.com/coding-agents-dont-need-longer-history-they-need-intent-continuity/
# REF: "Towards Spec-Driven Test Automation: Part 1" (Gal Arav, TDS, 2026-09-24) — https://towardsdatascience.com/towards-spec-driven-test-automation-part-1/
#      — continuity's `verified_by:` (a contract entry must say which test holds it
#      to its word, and a named node must exist) and `disposition:` (the
#      decision/consequence triage: a decision needs its closed bound, a consequence
#      must not carry one).
# ==============================================================================
# AI INSTRUCTION: Increment version on significant changes.
# Module Version: 15
#   v15 (2026-10-02, card dd96b63f): the 2365-line embedded Python program moved out of the
#   heredoc into tools/contracts_check.py; this file is now a 391-line wrapper that selects
#   the interpreter and execs the module with the SAME argv (`python3 -` and `python3 <file>`
#   both expose the arguments at sys.argv[1:]).  No behaviour change: the heredoc body was
#   moved byte-for-byte (verified with diff against HEAD) and the CLI/subcommand interface is
#   untouched.  The point is gate visibility — the program was invisible to ruff/mypy/pyright,
#   which are scoped to .py files.  The tool VERSION does not move (no new mode or rule).
#   v14 (2026-10-02, card b55c77f5): `swallows` corpus widened to `tools/qwen-hooks/*` — the Qwen
#   hook set (post-edit-check.sh, memory-markdownlint.sh, guard-patch-check.sh, shell-command-scan.py)
#   sits under tools/ but a listdir of tools/ never reaches a subdirectory, so neither this gate nor
#   tools/lint.sh's whole-tree loops saw it.  Its six unclassified sites were marked with a reason
#   BEFORE the widening landed, so the baseline gains no row; measured
#   `OK — 1184 site(s) in 112 file(s)` against 1178/108 before.  The tool VERSION does not move (no
#   new mode or enforced rule), so the BATS version pins stay put.
#   v13 (2026-10-02): `swallows` corpus widened to nas/**/*.sh — the NAS (butler) tooling,
#   mirrored into this repo at nas/butler/, is shell, and leaving it unscanned was the same
#   unmeasured decision the 2026-09-24 widening fixed for bin/ and tools/.  It is the one group
#   that needs a RECURSIVE walk (its files sit two levels down).  Every site in that tree was
#   classified before the widening landed, so the baseline gains no row; measured
#   `OK — 1180 site(s) in 105 file(s)` against 89 before.
#   v12 (2026-09-29): `swallows` gained `--dump-sites` (card SPLIT-CONTRACT-TRIAGE-001) —
#   a read-only JSONL dump of every site (file, line, pattern, matched text,
#   classified, reason, reason source, weighable) so tools/swallow-classify.py reads
#   the SAME population this check counts instead of re-grepping with a second
#   scanner.  Stdout is pure JSONL and the summary goes to stderr; the mode narrows a
#   bare invocation to `swallows`, refuses the `--print-baseline` combination, and
#   exits 0 even with unclassified sites (a dump, not a verdict).  The tool `VERSION`
#   moves to 8, so the BATS version pins move with it (tests/unit/22 and 24).
#   v11 (2026-09-29): `continuity` gained `disposition:`/`bound:` (card
#   SPEC-VV-CONSOLE-004) — the decision/consequence triage from the article.  A
#   `decision` needs a weighable `bound:` (the closed stated value), a `consequence`
#   must carry none (it is derived, so a hard-coded value goes stale), any other value
#   fails naming the two, and a `bound:` with no `disposition:` fails.  ACTIVE entries
#   that declare no `disposition:` are COUNTED and printed as UNCLASSIFIED, never a
#   failure — the triage of a borderline line is the owner's call.  The tool
#   `VERSION` moves to 7, so the BATS version pins move with it (tests/unit/22 and 24).
#   v10 (2026-09-29): `continuity` gained `verified_by:` (card SPEC-VV-CONSOLE-003) —
#   an optional per-entry list of `<repo-relative path>::<exact @test name>` nodes,
#   validated against the @test declaration parser for tests/**/*.bats (a declared
#   node that does not exist FAILS, naming the entry and the node), with the ACTIVE
#   entries that declare none COUNTED and printed as NOT VERIFIED rather than failing
#   — the posture `state` already takes for its NOT ENFORCED edges.  The tool
#   `VERSION` moves to 6 for the new enforced rule, so the BATS version pins move with
#   it (tests/unit/22 and 24).
#   v9 (2026-09-28): state validates each ACTIVE entry's `effect: read|mutate` and
#   forbids `mutate` + `read_back_exempt`, and names the mutating surface (RAGACT-006).
#   v8 (2026-09-24): two corrections to v7, both found by running the thing rather
#   than reading it.  The swallows footer still claimed "bin/ and tools/ are not
#   scanned" — false the moment the corpus widened — and tests/unit/24 pinned that
#   old scope, so the widen shipped with a red CI on three pushes.  The case now
#   pins the widened scope; the footer names what is still outside it.
#   v7 (2026-09-24): `swallows` scans the WHOLE shell corpus, not scripts/*.sh alone —
#   bin/, tools/*.sh and tools/hooks/* are shell too, and leaving them out made the
#   reported population a partial figure the ratchet could not be honest about.  The
#   baseline is re-derived in the same change, because a wider corpus necessarily
#   raises the recorded counts; that is a corpus change, not drift.
#   v6 (2026-09-24): prose only — `modules` no longer describes
#   tools/contracts-modules-baseline.tsv as a live baseline whose rows print every
#   run.  That file was DELETED in 66f17e5e, so nothing is grandfathered and every
#   load-order disagreement already fails; the reader and the RECORDED/STALE paths
#   stay for a future baseline.  The tool `VERSION` does not move for a comment.
#   v5 (2026-09-23): prose only — SWALLOWS_RESERVED's entry for 08-maintenance.sh no
#   longer claims it is "another session's in-flight file": that change is committed
#   (39f2fb08), so the note now says what it is (5 pre-existing sites, untouched by it).
#   The tool `VERSION` does not move for a comment, so the BATS version pins stay put.
#   v4 (2026-09-23): `modules` gained the @uses field — run-time collaborators,
#   order-free and cycle-legal — and the load-order baseline was deleted after the
#   13 recorded disagreements were relabelled rather than "fixed" (card
#   MOD-GRAPH-DECLARATION-001).  No behaviour changed: see the measured
#   clean-source evidence in the modules doc block above.
# @modular-section: contracts
# @depends: none (standalone CI helper; needs python3 with PyYAML)
# @exports: (none — standalone script, not sourced)
VERSION="8"
set -euo pipefail

# --version is pure bash: a version query must not depend on the YAML engine.
if [[ "${1:-}" == "--version" || "${1:-}" == "-V" ]]; then
    echo "check-contracts $VERSION"
    exit 0
fi

# Default to the repository this script lives in (the tools/ convention),
# overridable with --repo so a throwaway fixture tree can be checked.
_repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# The repo's python (see the project rules: system python lacks the deps in some
# environments); fall back to PATH so a fixture tree with no venv still works.
_python="python3"
if [[ -x "$_repo_root/.venv/bin/python3" ]]; then
    _python="$_repo_root/.venv/bin/python3"
fi
if ! command -v "$_python" >/dev/null 2>&1; then
    printf '%s\n' "check-contracts: python3 not found (needed to parse the contract YAML)" >&2
    exit 2  # cannot run the check
fi

# One program, all arguments: parsing --repo / the subcommand / usage errors in
# one place keeps the dispatch table and the error text together.
# The program is a real module now (tools/contracts_check.py) so ruff, mypy and
# pyright see it; this wrapper only selects the interpreter and forwards the same
# argv — `python3 -` and `python3 <file>` both expose the arguments at sys.argv[1:].
exec "$_python" "$_repo_root/tools/contracts_check.py" "$_repo_root" "$@"

# end of file
