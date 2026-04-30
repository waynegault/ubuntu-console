---
title: PowerShell Tactical Console — AI Build Prompt
description: >
  Complete, self-contained prompt for an AI agent to build the Windows PowerShell
  equivalent of the Bash Tactical Console profile.
---

# PowerShell Tactical Console — AI Build Prompt

Copy the block below in full when starting a new AI session to build the profile.
Do not abbreviate it; every requirement here was included deliberately.

---

## Prompt

```
TASK
====
Rebuild my PowerShell 7+ profile as a full, production-quality equivalent of my
Bash Tactical Console, which runs inside WSL2 Ubuntu 24.04. The Windows PowerShell
profile lives at:

  C:\Users\wayne\OneDrive\Documents\PowerShell\profile.ps1

which is symlinked from WSL at:

  ~/.config/powershell/microsoft.powershell_profile.ps1

The Bash source is at (WSL path):

  \\wsl.localhost\Ubuntu-24.04\home\wayne\ubuntu-console
  (or from WSL:  /home/wayne/ubuntu-console)


GUIDING DOCUMENTS — READ THESE FIRST
=====================================
Before writing any code, read and internalise the following files from the repo.
They are the source of truth; do not infer behavior that contradicts them.

1. README.md                               — project overview, feature list, design principles
2. docs/pwsh-translation-prep.md          — translation strategy and non-negotiable constraints
3. docs/contracts/command-contracts.yaml  — every user-facing command and its behavioral contract
4. docs/contracts/state-contracts.yaml    — all shared variables and /dev/shm cache files
5. tests/fixtures/golden/README.md        — fixture format and normalization guidance
6. tests/fixtures/golden/*.txt            — captured Bash output baselines (parity targets)
7. tests/fixtures/golden/*.norm           — normalized baselines (use for automated diff)
8. inspection.md                          — audit checklist; derive the PowerShell equivalent


ARCHITECTURE REQUIREMENTS
=========================
1. THIN LOADER ONLY
   profile.ps1 must be a thin loader — nothing more. All logic lives in numbered
   module files, loaded in dependency order, exactly mirroring the Bash structure:

     01-constants.ps1    (constants, design tokens)
     02-error-handling.ps1
     03-design-tokens.ps1
     04-aliases.ps1
     05-ui-engine.ps1
     06-hooks.ps1
     07-telemetry.ps1
     08-maintenance.ps1
     09-openclaw.ps1
     09b-gog.ps1
     10-deployment.ps1
     11-llm-manager.ps1
     12-dashboard-help.ps1
     13-init.ps1         (interactive-only; skipped in library mode)
     14-wsl-extras.ps1
     15-model-recommender.ps1

   The loader must:
   - Dot-source each module in order
   - Skip 13-init.ps1 when $env:TAC_LIBRARY_MODE is set
   - Expose a non-interactive entry point equivalent to bin/tac-exec

2. MODULE LOCATION
   Modules live in a scripts/ subfolder beside profile.ps1:
   e.g. C:\Users\wayne\OneDrive\Documents\PowerShell\scripts\01-constants.ps1

3. NON-INTERACTIVE / AUTOMATION PATH
   Provide a tac-exec.ps1 (or tac-exec.cmd wrapper) that:
   - Sets $env:TAC_LIBRARY_MODE=1
   - Dot-sources the loader (skipping 13-init.ps1)
   - Executes the function/command passed as arguments
   - Preserves exit code
   This is how MCP tools, agents, and automation reach the function library.

4. INSTALLATION SCRIPT
   Provide an install.ps1 that:
   - Writes or updates profile.ps1 (thin loader only, never overwrites user content)
   - Symlinks or copies modules to the scripts/ subfolder
   - Is idempotent (safe to re-run)
   - Sets profile.ps1 to read-only after writing (equivalent to chmod 444)


FEATURE TRANSLATION REQUIREMENTS
=================================
Translate every item listed in docs/contracts/command-contracts.yaml.
Where a Bash command has no clean Windows equivalent, provide the best
PowerShell-native substitute AND add an explicit comment explaining the gap.

Key translations (not exhaustive — the contracts file is canonical):

  Dashboard (m / tactical_dashboard)
  - Render a box-drawn dashboard in the terminal
  - Data sources: CPU %, iGPU %, CUDA %, RAM, disk C:, WSL disk
  - GPU: RTX 3050 Ti via nvidia-smi; iGPU via WMI or Get-Counter
  - Battery: Get-WmiObject Win32_Battery
  - LLM status: read $env:TEMP\tac\active_llm (Windows equivalent of /dev/shm)
  - OpenClaw status: TCP port probe (equivalent to ss -lnt grep)
  - Dashboard width: 78 columns exactly; box-drawing chars preserved
  - Output must normalize to match tests/fixtures/golden/dashboard_m.norm

  Help panel (h / tactical_help)
  - Grouped command sections
  - Output must normalize to match tests/fixtures/golden/help_h.norm

  Model management (model list / model use / model stop / model status)
  - LLM registry: \\wsl.localhost\Ubuntu-24.04\mnt\m\.llm\models.conf
    (pipe-delimited 11-field format: num|name|file|size|arch|quant|layers|gpu_layers|ctx|threads|tps)
  - Read the registry from Windows via the WSL UNC path
  - model status --plain output must match tests/fixtures/golden/model_status_plain.norm

  OpenClaw (so / xo / oc-health)
  - OpenClaw runs inside WSL; health checks call its HTTP API on localhost:18789
  - Use Invoke-WebRequest or Test-NetConnection for port/health checks
  - oc-health --plain output must match tests/fixtures/golden/oc_health_plain.norm

  Maintenance (up)
  - 13-step pipeline with per-step 24h cooldowns
  - Cooldown state stored in $env:USERPROFILE\.openclaw\maintenance_cooldowns.txt
    (equivalent to ~/.openclaw/maintenance_cooldowns.txt)
  - Use file locking (mutex or file-based) equivalent to flock

  Deployment (commit / g)
  - Git operations via standard git.exe
  - Optional LLM commit message via llama-server API (localhost:8081)

  Telemetry cache
  - Bash uses /dev/shm; Windows equivalent is $env:TEMP\tac\ (or a RAM disk if available)
  - Cache files must use the same names: active_llm, last_tps, tac_hostmetrics, etc.
  - Writes must be atomic (write to .tmp then rename, same as Bash)
  - Stale threshold: same as Bash (configurable via constants module)


PLATFORM ADAPTER REQUIREMENTS
==============================
Do NOT inline platform-specific calls. Wrap each external dependency in a
named adapter function in a dedicated adapters/ subfolder or within the
relevant module. Required adapters:

  Invoke-TacPortCheck    — replaces `ss -lnt | awk`; takes port number, returns bool
  Get-TacCacheAge        — replaces `stat -c %Y`; returns seconds since last write
  Get-TacGpuMetrics      — replaces `nvidia-smi --query`; returns hashtable
  Get-TacCpuPercent      — replaces `typeperf.exe`; returns float
  Get-TacIGpuPercent     — replaces iGPU typeperf call
  Get-TacMemoryGb        — returns used/total in GB
  Get-TacDiskFree        — returns free GB for C: and WSL mount
  Invoke-TacWslCommand   — runs a command inside WSL and captures output/exit code
  Get-TacBatteryStatus   — wraps Win32_Battery; returns AC/percentage string

Each adapter must have a matching Pester test.


STATE CONTRACTS
===============
Implement every entry in docs/contracts/state-contracts.yaml.
- Bash variables become PowerShell script-scope variables ($script:TAC_*) inside modules.
- /dev/shm files become $env:TEMP\tac\<same-filename> on Windows.
- Preserve all semantics: format, producer/consumer relationships, stale thresholds.


INSPECTION DOCUMENT
===================
Create docs/pwsh-inspection.md as the PowerShell equivalent of inspection.md.
It must cover the same audit categories adapted for PowerShell:

  Pre-Flight                — execution policy, PS version, module load order
  Security — Critical       — secret handling, API key cache permissions, injection risk
  Safety — Critical         — atomic writes, lock files, idempotency
  Correctness               — output format parity, exit code parity
  Robustness                — error handling, missing-dependency behavior
  Efficiency                — cache usage, background jobs vs runspaces
  Portability               — Works on pwsh 7.4+ Windows; no .NET Framework specifics
  Style                     — Verb-Noun naming, approved verbs, comment-based help
  Documentation             — every public function has comment-based help
  Testing & CI              — Pester test coverage map
  Platform Adapters         — each adapter listed, test status
  Cross-Module Consistency  — shared state usage audit

Each item must include: rationale, test command, expected outcome.


TESTING REQUIREMENTS
====================
Provide a full Pester 5 test suite under tests/:

  tests/
    unit/
      01-constants.Tests.ps1
      05-ui-engine.Tests.ps1
      07-telemetry.Tests.ps1
      ... (one file per module)
    integration/
      01-dashboard.Tests.ps1    (output normalized, diffed against .norm fixture)
      02-model-lifecycle.Tests.ps1
      03-maintenance.Tests.ps1
      04-openclaw.Tests.ps1
      05-llm-manager.Tests.ps1
    adapters/
      adapters.Tests.ps1        (all platform adapters)
    fixtures/                   (same golden fixtures as Bash, shared via WSL UNC)

Test requirements:
- Use BeforeAll/AfterAll for setup/teardown; no test isolation leaks
- Mock all external commands (nvidia-smi, git, wsl.exe, web requests) in unit tests
- Integration tests may call real commands but must be skippable via -Tag 'Slow'
- Fixture parity tests: call Get-TacNormalizedOutput, diff against .norm file,
  assert zero diff
- Test file must have equivalent coverage to tests/tactical-console.bats
  (~489 assertions); aim for parity of intent, not line-for-line duplication
- Include a run-tests.ps1 equivalent to tools/run-tests.sh with colored output


PARITY VALIDATION
=================
For every command listed in docs/contracts/command-contracts.yaml:

1. Run the PowerShell command via tac-exec.ps1
2. Strip ANSI, timestamps, dynamic values using the same rules as
   tools/normalize-fixture.sh (port that logic to a PS function)
3. Diff the normalized output against tests/fixtures/golden/<name>.norm
4. Report exact differences; do not silently swallow gaps

Provide a script tools/parity-report.ps1 that:
- Runs all fixture-producing commands
- Normalizes outputs
- Generates a parity-report.md listing PASS / FAIL / SKIP per command
- Exits non-zero if any FAIL


HARD CONSTRAINTS
================
1. profile.ps1 must be ONLY a thin loader. If the AI writes any logic into it,
   reject and refactor.
2. Do not inline platform-specific calls. Use named adapters.
3. Do not infer behavior that is not documented in contracts or fixtures.
   If a command's behavior is ambiguous, add a # TODO(parity): comment and
   document the gap in parity-report.md.
4. All state files use atomic writes (temp-file-then-rename).
5. The non-interactive path must not emit any interactive side effects
   (no welcome banner, no prompt modification, no window title changes).
6. Do not use Windows PowerShell 5.x constructs; target pwsh 7.4+.
7. Never store secrets in files without restricted ACLs. API key caches must
   use Set-TacSecureFile (implement this) equivalent to Bash chmod 600.
8. Error handling follows the same philosophy as the Bash modules:
   non-fatal warnings do not abort the pipeline; hard failures set exit code.


DELIVERABLES
============
Produce all of the following, in order:

1. docs/pwsh-inspection.md            — audit checklist (see above)
2. profile.ps1                        — thin loader only
3. scripts/01-constants.ps1           through scripts/15-model-recommender.ps1
4. scripts/09b-gog.ps1
5. bin/tac-exec.ps1                   — non-interactive entry point
6. install.ps1                        — idempotent installer
7. tests/unit/*.Tests.ps1             — unit tests, all modules
8. tests/integration/*.Tests.ps1      — integration tests, all command families
9. tests/adapters/adapters.Tests.ps1  — platform adapter tests
10. tools/run-tests.ps1               — colored test runner
11. tools/parity-report.ps1           — parity validation script
12. tools/normalize-fixture.ps1       — port of tools/normalize-fixture.sh

If any deliverable cannot be completed due to missing information,
produce a placeholder file with a clearly marked # INCOMPLETE: <reason> comment
at the top, and include the gap in parity-report.md.


THINGS THAT DO NOT TRANSLATE CLEANLY — HANDLE EXPLICITLY
=========================================================
These are known gaps. Handle each one explicitly rather than silently skipping:

- /dev/shm      → $env:TEMP\tac\ (no RAM-backed FS on Windows without a RAM disk;
                  note this in inspection.md and implement a RAM-disk detection helper)
- flock         → [System.Threading.Mutex] or a .lock file with exclusive open
- journalctl    → Get-WinEvent / Get-Content on WSL log paths via UNC
- systemctl     → wsl.exe -e systemctl (via Invoke-TacWslCommand) or Windows services
- ss/netstat    → Test-NetConnection or Get-NetTCPConnection
- stat -c %Y    → (Get-Item <path>).LastWriteTime
- GNU awk/sed   → native PS string/regex operations
- typeperf.exe  → Get-Counter (available natively in pwsh)
- nvidia-smi    → nvidia-smi.exe in PATH (same binary works from Windows)
- WSL ↔ Windows path translation → wsl.exe --exec wslpath or [System.IO.Path]
```

---

## How to Use This Prompt

1. Open a new AI chat session with a model capable of long-context file generation
   (Claude 3.5+, GPT-4o, or similar).
2. Paste the entire block above.
3. Attach or paste the contents of the six guiding documents listed at the top.
4. Request delivery in stages if the context window is a concern:
   - Stage 1: inspection.md + profile.ps1 + 01-constants through 04-aliases
   - Stage 2: 05-ui-engine through 09b-gog (telemetry, maintenance, OpenClaw, GOG)
   - Stage 3: 10-deployment through 15-model-recommender
   - Stage 4: tac-exec.ps1 + install.ps1
   - Stage 5: Full test suite + parity tools
5. After each stage, run the delivered modules through `pwsh -NoProfile -File <module>`
   to catch syntax errors before proceeding.
6. Run `tools/parity-report.ps1` after Stage 5 to identify remaining gaps.

## Notes for the Human Reviewer

- The "thin loader" constraint is enforced architecturally: if the AI puts logic
  into profile.ps1, it violates requirement #1 — push back.
- Golden fixtures were captured on 2026-04-30 with model #3 active and both
  LLM and OpenClaw offline. The .norm files are the parity targets, not .txt.
- The WSL bridge (`Invoke-TacWslCommand`) is needed for any command that must
  interact with WSL services (OpenClaw, llama-server). It is NOT a general-purpose
  WSL shell; it runs exactly one command and returns stdout/stderr/exitcode.
- inspect.md items marked 🔧 in the Bash version have equivalent enforcement
  requirements in pwsh-inspection.md.
