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
3. **Numbered modules** - Logic split into `scripts/[01-15]-*.sh` files loaded in numeric order
4. **Explicit dependencies** - Each module declares `@depends` and `@exports` annotations
5. **Version tracking** - Each module has `# Module Version: N` for change tracking

Module loading order:
```
01-constants.sh       → All paths, ports, env vars (single truth)
02-error-handling.sh  → Bash ERR trap
03-design-tokens.sh   → ANSI color constants
04-aliases.sh         → Short commands, VS Code wrappers
05-ui-engine.sh       → Box-drawing primitives
06-hooks.sh           → cd override, prompt (PS1), port test
07-telemetry.sh       → CPU, GPU, battery, git, disk, tokens
08-maintenance.sh     → get-ip, up, cl, sysinfo, logtrim
09-openclaw.sh        → Gateway, backup, cron, skills
10-deployment.sh      → mkproj scaffold, git commit+push
11-llm-manager.sh     → model mgmt, chat, burn, explain
12-dashboard-help.sh  → Tactical Dashboard and Help
13-init.sh            → mkdir, completions, WSL loopback fix
14-wsl-extras.sh      → WSL/X11 startup helpers
15-model-recommender.sh → AI model recommendations
```

## Consequences

### Positive
- **Easier navigation** - Each module has a single responsibility
- **Reduced conflicts** - Contributors edit different modules
- **Faster iteration** - Can reload individual modules during development
- **Clear dependencies** - Module order enforces dependency chain
- **Version tracking** - `TACTICAL_PROFILE_VERSION` auto-computed from module versions

### Negative
- **Slightly slower startup** - Multiple `source` calls add ~50-100ms overhead
- **More files to manage** - 15 files instead of 1 monolith
- **Learning curve** - New contributors must understand module system

### Risks Mitigated
- **Circular dependencies** - Prevented by numeric ordering
- **Missing dependencies** - Modules fail loudly if required vars not set
- **Version drift** - Auto-computed version catches module mismatches

## References
- Module annotations: `tactical-console.bashrc` Architecture Map section
- Version computation: `tactical-console.bashrc` SOURCE MODULES section
