---
title: PowerShell Translation Prep
description: Non-invasive artifacts and workflow for behavior-first translation from Bash to PowerShell.
---

# PowerShell Translation Prep

This document defines a low-risk process for translating tactical-console from
Bash to PowerShell without changing current runtime behavior.

## Goals

- Preserve user-visible behavior and command contracts.
- Separate platform-specific adapters from business logic.
- Validate parity with golden fixtures, not implementation details.
- Keep Bash code untouched while preparing translation inputs.

## What Was Added

- `docs/contracts/command-contracts.yaml`
- `docs/contracts/state-contracts.yaml`
- `tools/capture-golden-fixtures.sh`
- `tests/fixtures/golden/README.md`

These additions are documentation and tooling only. They do not affect profile
startup, command behavior, or module load order.

## Translation Workflow

1. Freeze contracts.
2. Capture golden fixtures in a representative environment.
3. Translate one command family at a time (maintenance, OpenClaw, LLM, UI).
4. Re-run fixture capture against PowerShell commands.
5. Compare normalized outputs and resolve parity gaps.

## Suggested AI Prompt Skeleton

Use this skeleton when asking an AI to perform the PowerShell translation:

```text
Translate tactical-console Bash behaviors to PowerShell 7+.

Hard requirements:
1) Use docs/contracts/command-contracts.yaml as source of truth for command semantics.
2) Preserve state/file contracts in docs/contracts/state-contracts.yaml.
3) Match outputs represented in tests/fixtures/golden.
4) Keep non-interactive entrypoint behavior equivalent to env.sh + bin/tac-exec.
5) Implement platform adapters for external commands (ss/stat/journalctl/typeperf, etc.)
   instead of inlining shell-specific calls.
6) Do not infer behavior that is not in contracts/fixtures/docs; mark unknowns explicitly.

Deliverables:
- PowerShell module layout
- Command implementations
- Pester tests aligned to fixture contracts
- Parity report listing exact deltas
```

## Adapter Design Guidance

Prefer thin wrappers for external dependencies. Examples:

- Port checks: `ss` in Bash -> dedicated PowerShell function with same boolean contract.
- Cache freshness: GNU `stat -c %Y` -> PowerShell `Get-Item` timestamp wrapper.
- Journals/logs: `journalctl` calls -> PowerShell log reader abstraction.
- WSL/Windows bridge calls (`typeperf.exe`, `powershell.exe`) -> explicit interop adapter.

Keep these adapters isolated so translation is mechanical and testable.

## Non-Interactive Contract

Treat this behavior as mandatory:

- Interactive profile loading remains separate from automation loading.
- Automation path must expose full command library without interactive side effects.
- Bash reference implementation is `env.sh` and `bin/tac-exec`.

## Review Checklist

- All translated commands map to an entry in command contracts.
- All shared state files/variables map to state contracts.
- No hidden side effects were introduced.
- Output and exit-code parity validated for high-value commands.
- Error-path behavior is documented where not yet parity-complete.
