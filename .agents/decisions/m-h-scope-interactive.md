---
name: m-h-scope-interactive
date: 2026-09-23
status: active
scope: interactive
commands: [m, h]
---

**Decision:** the `m` and `h` contracts are `scope: interactive`. They are not
contracts that hold in `tac-exec` library mode.

**Why:** `m` and `h` are ALIASES (`scripts/04-aliases.sh`: `alias m='tactical_dashboard'`,
`alias h='tactical_help'`), and a bash alias name is only resolved as a command when
alias expansion is on. Measured 2026-09-23: `shopt expand_aliases` is `off` in a
non-interactive shell and nothing in this repo turns it on — `bash -c 'alias foo="echo
expanded"; foo hello'` exits 127 with "command not found", while interactive use is
unaffected. `bin/tac-exec` ends in `"$@"`, so `tac-exec m` looks for a command named
`m` and finds none. The wrapped functions (`tactical_dashboard` in
`scripts/12-dashboard-help.sh`, `tactical_help`) load in both loaders, so
`tac-exec tactical_dashboard` works and only the shorthand is interactive.

**How to apply:** treat a row that names `tac-exec m` or `tac-exec h` as documentation
for the interactive shell, not a working library-mode invocation. If either shorthand
is promised for library mode, the fix is a wrapper function or a `bin/` shim, not a
contract edit — and `tools/check-contracts.sh derived` will keep accepting the name
either way, because the name IS exported (as an alias); scope is what carries the
difference.
