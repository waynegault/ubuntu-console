---
name: depends-uses-split
date: 2026-09-23
status: active
scope: both
commands: []
---

**Decision:** `# @depends:` means LOAD ORDER ONLY — the module must be sourced first.
Run-time collaborators move to a new `# @uses:` field. Twelve edges were relabelled
across six modules (09a, 09c, 09e, 11a, 11b, 11e), `13-init`'s prose
`@depends: all sections above` became `constants, design-tokens, openclaw`, and
`tools/contracts-modules-baseline.tsv` was deleted so a disagreement now fails
immediately.

**Why a relabel and not a reorder.** The 12 forward edges were never load-order bugs:
they were *calls* (`09a`'s `so` calls `model`/`serve`; the §11 group calls across
itself). One field was carrying two relationships, and only one of them is about load
order, so the load-order claim could not be checked honestly while both were in it.
Three independent measurements say no forward edge is used AT SOURCE TIME, which is
what makes `@uses` the truthful classification:

1. sourcing the library loader in a scrubbed environment
   (`env -i HOME=… PATH=… bash --noprofile --norc`) gives rc=0 with **zero**
   `command not found` and **zero** `unbound variable` — an undefined function called
   at source time would have printed the first;
2. no module in the six references any §11 variable on a top-level line;
3. the `: "${VAR:=}"` source-time declaration idiom in those modules names only
   `C_*` (`03-design-tokens`) and `UIWidth` (`01-constants`), both of which load
   EARLIER and are already in `@depends`.

**Evidence that behaviour is unchanged:** the scrubbed-source probe above returns
rc=0, **302** functions defined, and empty stderr both before and after the relabel.
Only comments changed; no module moved in `scripts/_module-list.sh` and no code was
edited.

**How to apply:** when a module calls another at run time, declare it in `@uses`, not
`@depends`. A `@uses` target must resolve to a loaded module, may not be the module
itself, and may not also appear in `@depends` — the fields partition the edges. NO
order requirement applies to `@uses` and a `@uses` cycle is legitimate (the §11 group
is mutually recursive by design), so cycles are computed over `@depends` edges only.
Do not reorder the numeric load list to satisfy the checker: if a declaration
disagrees with the order, the declaration is what gets fixed.
