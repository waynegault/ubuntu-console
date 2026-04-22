# ADR-001: Modular Bash Architecture

**Date:** 2026-03-10  
**Status:** Accepted  
**Author:** Wayne

## Context

The Tactical Console profile started as a monolithic `~/.bashrc` file that grew to over 3,000 lines. This created several problems:

1. **Difficult to navigate** - Finding specific functions required scrolling through thousands of lines
2. **Merge conflicts** - Multiple contributors editing the same file caused frequent conflicts
3. **Slow iteration** - Testing changes required reloading the entire profile
4. **No clear dependencies** - Functions depended on each other with no explicit ordering

## Decision

Adopt a modular architecture where:

1. **Thin loader** - `~/.bashrc` contains only a loader that sources the canonical profile
2. **Canonical profile** - `~/ubuntu-console/tactical-console.bashrc` is the thin loader's source
3. **Numbered modules** - Logic split into `scripts/[01-15,09b]-*.sh` profile modules loaded in numeric order; utility scripts (`16-20`) are present in `scripts/` but are **not** sourced by the loader
4. **Explicit dependencies** - Each module declares `@depends` and `@exports` annotations
5. **Array-based loader** - `tactical-console.bashrc` uses `_tac_expected_modules` (an explicit array) rather than a glob to source exactly the 16 named profile modules — utility scripts are skipped
6. **Version tracking** - Each module has `# Module Version: N` for change tracking

Module loading order (16 profile modules):
```
01-constants.sh         → All paths, ports, env vars (single truth)
02-error-handling.sh    → Bash ERR trap (exit ≥ 2 logged)
03-design-tokens.sh     → ANSI color constants (readonly)
04-aliases.sh           → Short commands, VS Code wrappers
05-ui-engine.sh         → Box-drawing primitives
06-hooks.sh             → cd override, prompt (PS1), port test
07-telemetry.sh         → CPU, GPU, battery, git, disk, tokens
08-maintenance.sh       → get-ip, up (13 steps), cl, sysinfo, logtrim, docs-sync
09-openclaw.sh          → Gateway, backup, bridge, oc-failover, wacli, kgraph
09b-gog.sh              → Google CLI (gog) detection and helpers
10-deployment.sh        → mkproj scaffold, git commit+push, deploy
11-llm-manager.sh       → model mgmt, chat, burn, bench, explain
12-dashboard-help.sh    → Tactical Dashboard and Help, bashrc_diagnose
13-init.sh              → mkdir, completions, WSL loopback fix (LAST — runs side-effects)
14-wsl-extras.sh        → WSL/X11 startup helpers, completions, vault env
15-model-recommender.sh → AI model recommendations by use case
```

Utility scripts in `scripts/` (not sourced; run standalone or in CI):
```
16-check-oc-agent-use.sh               → Agent usage regression checker
17-import-windows-user-env.sh          → Import Windows user env vars
18-lint.sh                             → bash -n + shellcheck + Unicode safety
19-mirror-gigabrain-vault-to-windows.sh → Sync Obsidian vault to Windows
20-run-tests.sh                        → BATS test runner
```

## Consequences

### Positive
- **Easier navigation** - Each module has a single responsibility
- **Reduced conflicts** - Contributors edit different modules
- **Faster iteration** - Can reload individual modules during development
- **Clear dependencies** - Module order enforces dependency chain
- **Version tracking** - `TACTICAL_PROFILE_VERSION` auto-computed from module versions

### Negative
- **Slightly slower startup** - Multiple `source` calls add ~10ms overhead (measured on this hardware)
- **More files to manage** - 16 profile modules + 5 utility scripts instead of 1 monolith
- **Learning curve** - New contributors must understand module system

### Risks Mitigated
- **Circular dependencies** - Prevented by numeric ordering
- **Missing dependencies** - Modules fail loudly if required vars not set
- **Version drift** - Auto-computed version catches module mismatches

## References
- Module annotations: `tactical-console.bashrc` Architecture Map section
- Version computation: `tactical-console.bashrc` SOURCE MODULES section
