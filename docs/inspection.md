# Bash Script Inspection, Improvement & Audit Checklist

A comprehensive, repeatable checklist for auditing the Tactical Console Profile
and its modular architecture. Covers the thin loader (tactical-console.bashrc),
16 profile modules under scripts/ (01-constants through 15-model-recommender,
plus 09b-gog), the numbered utility `scripts/18-lint.sh`, standalone scripts in
bin/, and companion files. Derived from real-world production audits.
Each item includes the rationale, a concrete test command, and the expected outcome.

Scope

The following file classes are in-scope for every audit pass:

- `tactical-console.bashrc` — thin loader
- `scripts/[0-9][0-9]-*.sh` — the 15 numbered profile modules (01-constants
  through 15-model-recommender) plus the `18-lint.sh` utility
- `scripts/09b-gog.sh` — the 16th profile module (non-numeric name)
- `tools/*.sh` — 13 utility scripts (capture-golden-fixtures, check-agent-use,
  check-module-versions, check-repo-boundaries, clean-orphans, docs-sync-check,
  import-windows-env, install-shellcheck, lint, mirror-vault, normalize-fixture,
  run-tests, sync-openclaw-completion)
- `tools/hooks/*` — the repo's git hooks. Tracked here, NOT in `.git/hooks/`
  (which holds only git's own samples); activated via `core.hooksPath`
- `bin/*.sh` — standalone helper scripts
- `bin/tac-exec` — non-interactive function runner (symlinked to `~/.local/bin/`)
- `env.sh` — library loader for non-interactive shells
- `install.sh` — installer
- `tools/lint.sh`, `tools/run-tests.sh` — CI helper scripts
- `tests/*.bats` — BATS test files at root level
- `tests/unit/*.bats` — BATS unit test files
- `tests/integration/*.bats` — BATS integration test files
- `tests/test_bats_bridge.py` — Pytest parametrize bridge for BATS suites
- `tests/test_kgraph.py` — Python tests for kgraph package
- `tests/test_models.py` — Pydantic model tests (GraphNode, GraphEdge, Graph, GraphBuilder)
- `tests/test_untested_modules.py` — Tests for call_flow, update, life_index, benchmark, mcp_server, pr_dashboard, validate
- `tests/conftest.py` — Pytest fixtures (BATS serialization via flock)
- `pytest.ini` — Pytest configuration (markers, testpaths)
- `scripts/kgraph/models.py` — Pydantic models (GraphNode, GraphEdge, Graph, GraphBuilder, ConfidenceLevel)
- `scripts/kgraph/templates/kgraph.html` — Cytoscape.js viewer template
- `config/concept-aliases.json` — kgraph concept classification data
- `tools/hooks/pre-commit` — pre-commit hook: runs `tools/lint.sh --staged`
  (bash -n + shellcheck on staged `.sh`) then
  `tools/check-module-versions.sh --staged`. Bypass: `git commit --no-verify`
- `tools/hooks/post-commit`, `tools/hooks/post-merge` — kgraph auto-update
- Activate all three with `git config core.hooksPath <repo>/tools/hooks`;
  `install.sh` does it. The hooks are tracked (reviewable, diffable) precisely
  because `.git/hooks/` is not version-controlled — a hook inlined there drifted
  from `tools/lint.sh` on 2026-09-15 when only one copy of its shellcheck flags
  was updated. Keep persistent checks in `tools/`, never inline in a hook.
- `systemd/*` — systemd unit files

Files excluded by `.gitignore` are out of scope. Companion config files
(`config/quant-guide.conf`, `*.json`) are reviewed for correctness but not subject
to shell-specific checks.

Usage: Work through each section top-to-bottom. Mark items [x] as you
go. Items marked 🔧 require code changes; items marked 🔍 are read-only checks.

How to run a full pass (added 2026-09-16, after the first complete one)

A full pass is 252 items and is not one sitting. What worked:

- Split it by section across parallel auditors, then verify every FAIL yourself
  with the command that produced it. An auditor's report is evidence, not truth:
  the first full pass produced real findings and also two that did not survive
  re-running the command that was supposed to prove them.
- Audit read-only. Fixes land afterwards as their own commits. Editing files while
  the pass is still reading them makes the remaining sections describe a tree that
  no longer exists, and any finding touching an edited file must be re-derived.
- Re-run the pass after fixing. "Fixed" is not "verified fixed".

Four rules the first pass earned:

- **A check whose command cannot run is a FAILURE of the check, not a pass.** Three
  commands in this document had never executed: 5.4's was a BRE in which `|` is
  literal, 6.2's had a literal newline inside a character class, and 6.3's was
  matching 245 arithmetic lines instead of the ~52 subshell openings it aimed at.
  All three were corrected on 2026-09-16. Treat "grep: Invalid regular expression"
  or a conspicuously empty result as the finding.
- **Every clean result needs a control.** Prove the probe CAN fail before believing
  it passed. Worked example: `bash -n` against `/usr/bin/bash` appeared to confirm
  the autotune benches parse under Bash 5.2 — but `/usr/bin/bash` is a symlink to
  the Homebrew bash 5.3.9, so the probe ran the very interpreter it claimed to rule
  out. A green that cannot go red is worth nothing.
- **Re-derive every count from the repo.** A number asserted in two places and
  checked in one drifts in the other — which is why `tools/docs-sync-check.sh`
  exists, and it caught README's test totals going stale by four on 2026-09-16.
- **Measure the artefact, not the label.** `/proc/PID/exe` over `comm`,
  `dpkg --verify` over a version string, `grep -c '^@test'` over a documented
  test count.

**Added 2026-09-18, after a pass that ran against a moving document and found three dead probes.
These are instructions for an agent running this checklist, not historical notes:**

- **Freeze the revision and name it.** Do not edit this file while a pass reads it. On
  2026-09-18 it grew 3019 → 3030 lines mid-pass, so a running auditor's line windows stopped
  matching the section boundaries it was given and its findings required re-derivation. Pass
  the commit hash to every auditor; a pass against a moving target is not a pass.
- **A report with no failing control is not evidence.** Ask any delegated auditor for the
  command that WOULD have failed had the probe been blind. On 2026-09-18 six delegated passes
  returned mostly NOT-RUN, and one PASS was self-flagged as having proved nothing.
- **Date every count, because fixing moves it.** Two of this document's own §17.1 fixes removed
  two of the directives that item counts, so its figure is dated, not eternal.
- **A comment can break a tool two ways.** Never reproduce a directive's literal text in prose —
  it becomes a phantom hit for every grep-based audit, including §17.1's own; and never start a
  prose line with the token the directive parser scans for, because a comment reading
  "shellcheck reports …" failed the entire file with SC1073/SC1072 on 2026-09-18.
- **Suspect the probe before the code, and prove which it is by equivalence.** Three dead probes
  have now been found in this document: §5.4, §6.2 and §6.3 (2026-09-16), then §2.1.3 and §6.1
  (2026-09-18 — §2.1.3 matched nothing anywhere, §6.1 matched every line mentioning `echo`).
  When a probe returns zero or thousands, reduce the pattern and show both forms return the same
  thing; that is what proved §6.1 blind.

Table of Contents

Pre-Flight

Security — Critical

Safety — Critical

Correctness & Clean Code — High

Robustness — High

Efficiency & Native Bash — Medium

Portability — Medium

Style & Formatting — Medium

Documentation & Future-Proofing — Medium

Refactor & Maintainability — Low

Testing & CI — Low

llama.cpp Integration — Medium

Cross-Script Consistency — Medium

AI Agent Access — High

Final Validation

New Insights & Standards (2026-09-12)

Field Notes — the 2026-09-16 pass

1. Pre-Flight

Before making any changes, establish a baseline and ensure foundational rules are met.

#

Check

Command / Action

Expected

1.1

🔍 Record file line count

wc -l <file>

Note baseline

1.2

🔧 Mandatory version variable

Loader: `grep 'TACTICAL_PROFILE_VERSION=' <file>`. Modules: `grep '^# Module Version:' <file>`.

For the loader: `_TAC_LOADER_VERSION="N"` near the top; `TACTICAL_PROFILE_VERSION` auto-computed as `${_TAC_LOADER_VERSION}.${_tac_mod_sum}`. For each module in scripts/: `# Module Version: N` comment in the header block. All modules must have this comment to satisfy the `grep '^# Module Version:'` check used in cross-script tests.

1.3

🔧 Mandatory AI instruction

grep 'AI INSTRUCTION' <file>

For the loader: `# AI INSTRUCTION: Increment version on significant changes.` above the version variable. For each module: an AI instruction block stating that on any change the module's `# Module Version: N` comment must be incremented (`TACTICAL_PROFILE_VERSION` then auto-computes from the sum of all module versions).

1.4

🔍 Ensure clean git state

git status --short

Working tree clean (or stash first)

1.5

🔍 Create a checkpoint

git stash or cp <file> <file>.bak

Backup exists

1.6

🔍 Identify target shell

head -1 <file>

`#!/usr/bin/env bash` or `#!/bin/bash` for standalone scripts. Sourced modules use `# shellcheck shell=bash` instead of a shebang.

1.7

🔍 Record baseline error count

shellcheck -s bash -x --source-path="$PWD" <file> 2>&1 | grep -c 'In '

Note baseline finding count for before/after comparison

1.8

🔍 Verify file is UTF-8 without BOM

file <file>

Reports "UTF-8 Unicode text" or "ASCII text", never "with BOM"

1.9

🔍 Check for carriage returns

grep -Pcn '\r' <file>

Zero matches (no Windows \r\n line endings)

1.10

🔍 Verify file ends with newline

tail -c 1 <file> | xxd | grep -q '0a'

Last byte is 0x0a (newline)

1.11

🔧 Mandatory end-of-file comment

grep -v '^[[:space:]]*$' <file> | tail -1

Last non-blank line must mention `end of file`, AND the file must end with a newline
(`tail -c 1 <file> | xxd -p` prints `0a`). Two accepted forms: the plain
`# end of file`, and the older two-line trailer (`# end of file`, blank,
`# end of file marker`) that 23 files still carry. In the two-line form the last
non-blank line is the `marker` one, which is why the check greps for the phrase
rather than matching the line exactly. Both halves are checked because they rot
independently: `bin/llama-gpu-clear.sh` had the comment but no final newline, and six
files had neither — all fixed 2026-09-16.

COVERAGE GAP worth knowing, because it is how those six drifted unnoticed: the
automated hygiene test (`tests/tactical-console.bats`, "hygiene: all scripts end
with …") globs `scripts/[0-9][0-9]-*.sh`, `bin/*.sh`, `install.sh` and `tools/*.sh`.
That MISSES `scripts/prompt-sets.sh`, `scripts/spec-decode-bench.sh`,
`scripts/spec_dec_crossover.sh` and everything under `tools/hooks/*`. A new script
outside those globs has nothing watching it but this item.

1.12

🔍 Shellcheck directives documented

grep 'shellcheck disable' <file>

Each disabled rule has a rationale comment on the line above or same line.
File-level `# shellcheck disable=...` lists must be MINIMAL: only the codes the
file actually produces. Audit by removing the line and reading what shellcheck
reports, then declaring exactly that set — 2026-09-12 narrowed every module
this way (07-telemetry, 09-openclaw and 11-llm-manager need no file-level
suppression at all). Note `-x`/`external-sources=true` does not help here:
these are structural cross-module findings (a var owned by another module →
SC2034/SC2154) that no source-following can resolve.

1.13

🔍 Host shell integrity

`ls -la /usr/bin/bash /usr/bin/bash.distrib; dpkg-divert --list | grep 'usr/bin/bash'; dpkg --verify bash`

`/usr/bin/bash` must be a KNOWN, DELIBERATE interpreter rather than whatever dpkg
last happened to write. On this box it is a symlink to
`/home/linuxbrew/.linuxbrew/bin/bash` (Homebrew 5.3.9), replacing the packaged
`bash 5.2.21-2ubuntu4`. Because the replacement is deliberate it is registered as a
dpkg diversion, and that is what makes it survive:

    local diversion of /usr/bin/bash to /usr/bin/bash.distrib

so an `apt upgrade bash` writes the new binary to `/usr/bin/bash.distrib` and leaves
the symlink alone. Proven 2026-09-16 by reinstalling the package: the symlink
survived, and `dpkg --verify bash` went from reporting `?M5?????? /usr/bin/bash` to
silent — the substitution stopped being a modified package file. `/bin` is a symlink
to `usr/bin` here, so this one path covers both.

dpkg warns that diverting a file from an Essential package is dangerous, so this
check exists to catch the two ways it can still go wrong:

- `/usr/bin/bash` DANGLING (Homebrew removed) — the system's shell is missing.
- `/usr/bin/bash.distrib` NEWER than the running bash — apt shipped a bash update
    that is installed but NOT in effect, so packaged fixes are sitting unused.

Revert the arrangement entirely with:
`sudo rm -f /usr/bin/bash && sudo dpkg-divert --local --rename --remove /usr/bin/bash`

2. Security — Critical

These issues can lead to arbitrary code execution, data exfiltration, or
privilege escalation. Fix all findings before proceeding.

2.1 Remote Code Execution

#

Check

Command

Expected

2.1.1

🔧 No curl | bash / wget | sh

grep -nE '(curl[^|;\n]*\|[[:space:]]*(bash|sh)|wget[^|;\n]*\|[[:space:]]*(bash|sh))' <file>

Zero matches (comments OK)

2.1.2

🔧 No eval on untrusted input

grep -n '\beval\b' <file>

Zero matches, or each use verified safe

2.1.3

🔧 No source of untrusted paths

`grep -nE '(^|[;&|!]|\bif\b|\belif\b|\bthen\b|\bdo\b)[[:space:]]*(source|\.)[[:space:]]+["$~./]' <file>`

All source targets are trusted/validated. **The command that used to be here could not fail:**
`grep -n '\bsource\b|\. '` is a BRE, so `|` is literal and it matched *nothing* — not even in
`env.sh` (3 real sites) or `tactical-console.bashrc` (6). That is a green that cannot go red, the
same defect class the preamble records as fixed for 5.4, 6.2 and 6.3 (2026-09-16). The replacement
above is anchored at a command position and requires a path-like target; re-verified both ways on
2026-09-18 — it finds `env.sh`'s sites *including* `if ! source "$_tac_lib_f"`, returns 0 on a
prose-only markdown file, and matches a synthetic `if ! source "$x/y"`. Re-derived same day:
**100 sites** across `*.sh`/`*.bashrc`/`*.bats`. A first attempt at the fix (just adding `-E`)
was ALSO wrong, silently matching ordinary prose — `. The`, `. A`, `. This` — which is why the
target must look like a path; anchoring is what makes this discriminate.

2.2 Secrets & Credentials

#

Check

Command

Expected

2.2.1

🔧 No hardcoded passwords/tokens

grep -niE 'password|passwd|secret|token|api.key' <file>

Only pattern-matching or env-var reads

2.2.2

🔧 No API keys in plain text

grep -nE '[A-Za-z0-9]{32,}' <file>

No long random strings that look like keys

2.2.3

🔍 Secrets loaded securely

Inspect all credential reads

From env vars, files with 600 perms, or secret managers

2.2.4

🔧 Prevent log leakage

grep -n 'set -x|set -o xtrace' <file>

set -x is not enabled across blocks processing credentials

2.3 Privilege & Permissions

#

Check

Command

Expected

2.3.1

🔧 No sudo in startup path

grep -n '\bsudo\b' <file>

None in code that runs at source-time; OK in explicit functions

2.3.2

🔧 No chmod 777

grep -n 'chmod 777|chmod a+rwx' <file>

Zero matches

2.3.3

🔧 No chown root without justification

grep -n 'chown root' <file>

Zero or justified

2.3.4

🔍 Temp files use mktemp

`grep -nE '>[[:space:]]*"?[$]?[{]?(TMPDIR|/tmp|/dev/shm)' <file | grep -vE ':[0-9]+:[[:space:]]*#'`

All temp files created via mktemp or atomic .tmp → mv. **The probe that used to be here asked for a
substring rather than for the thing:** `grep -nE 'tmp|temp'` returns **375** lines over the corpus,
25 of them prose ("attempt", "template"), so it could neither find a write to a temp path nor tell
one from a comment about it. The probe above asks the actual question — a redirection *into* a temp
location — and returns **21** sites. They are one design, not 21 oversights: 18 are in
`scripts/autotune-model.sh`, `$$`-suffixed scratch files (`/tmp/at-metrics-$$`, `/tmp/at-tps-$$`,
`/tmp/at-served-ctx-$$`) whose name the reader reconstructs from the same `$$` — a documented
in-process hand-off (the helper's own comment: it writes `decode|prefill` in tok/s to
`/tmp/at-metrics-$$` "for callers that …", `autotune-model.sh:904`) — so `mktemp` would mean
threading a variable to every reader to buy an unpredictability the `$$` already provides per run.
(Those 18 include one name keyed by model rather than PID, `/tmp/at-ttft-${MODEL}-c${c}.log` at
`:1971`.) The other three sites are `/tmp/llm-modelshell.$$.pid`
(`scripts/11e-llm-model.sh:1202`, the documented PID-file protocol),
`/tmp/autotune_verify_use_${model_num}.log` (`scripts/11b-llm-autotune.sh:457`), and
`/tmp/burn_transport_recover_use.log` (`scripts/11f-llm-runtime.sh:302`) — the last carrying no key
at all, and the only one a concurrent run could clobber. All three are on the autotune/bench path,
which the GPU lock serializes, so none has collided. Noted, not changed: this is a read-only check,
and making those names unique is a behaviour change on the bench path rather than a cleanup.

2.3.5

🔧 No world-writable output files

grep -n 'chmod.*o+w|chmod.*666' <file>

Zero matches

2.3.6

🔧 Cache files secured with chmod 600

grep -n 'umask 077\|chmod 600' <file>

All cache files containing credentials or sensitive data use restrictive permissions

2.3.7

🔍 /dev/shm files are user-owned

ls -la /dev/shm/tac_*

All tac_* files owned by the user, mode 600 or 644

2.4 Process, Path & Signal Safety

#

Check

Command

Expected

2.4.1

🔧 No . in PATH

grep -n 'PATH=.*:\.:' <file>

Zero matches

2.4.2

🔧 pkill -x not pkill -f

grep -n 'pkill -f' <file>

Zero matches (use -x for exact match)

2.4.3

🔧 No unquoted command substitution in kill

grep -n 'kill \$(' <file>

All quoted: kill "$pid"

2.4.4

🔧 pkill scoped to current user

grep -n 'pkill' <file>

All pkill calls use -u "$USER" to avoid killing other users' processes

2.4.5

🔧 Killed processes verified before cleanup

Inspect kill/pkill calls

After pkill, sleep before assuming process is dead; verify with pgrep

2.5 Input Handling

#

Check

Command

Expected

2.5.1

🔧 No unquoted $@ or $*

grep -nE '\$@|\$\*' <file> | grep -v '"'

All uses double-quoted: "$@"

2.5.2

🔧 No unquoted variable in [[ ]]

grep -nE '\[\[.*\$[a-zA-Z]' <file>

Variables quoted (except inside (( )))

2.5.3

🔧 No injection via variable in printf format

grep -n 'printf.*\$' <file>

Variables in args, not format string

2.5.4

🔧 No unquoted variable expansion in paths

grep -nE 'rm.*\$|mv.*\$|cp.*\$' <file>

All path variables double-quoted to prevent word splitting on spaces

2.5.5

🔧 read -r always used

grep -n '\bread\b' <file> | grep -v '\-r'

All read calls use -r to prevent backslash interpretation

2.5.6

🔧 IFS-sensitive reads are explicit

grep -n 'IFS=' <file>

IFS changes are local to the read or restored afterward

2.6 Race Conditions & Atomicity

#

Check

Command

Expected

2.6.1

🔍 File writes use atomic pattern

grep -nE '> .*\$|>> ' <file>

All writes to shared state use tmp→mv atomic pattern, not direct overwrite

2.6.2

🔍 Lock files used for concurrent access

Inspect scripts callable from timers/cron

flock or lockfile guards present for scripts executed by systemd timers

2.6.3

🔍 PID file staleness handled

Inspect PID file reads

PID files are validated (process still alive) before trusting content

2.6.4

🔍 No TOCTOU on file checks

Inspect [[ -f ... ]] followed by operations

Check and use are in the same atomic block where possible

3. Safety — Critical

Prevent the script from damaging the host environment.

#

Check

Command

Expected

3.1

🔧 Interactive shell guard

`grep -n "case \$- in" <file>`

Non-interactive shells exit early in profiles — the loader (`tactical-console.bashrc:53`) and
`scripts/14-wsl-extras.sh:72`. Expect **one known false positive**, not zero:
`scripts/12-dashboard-help.sh:412` *echoes* the idiom (`$(case $- in (*i*) …)`) to print the
interactive state, so three hits are two guards. Re-derived 2026-09-18: 2 guards across
`*.sh`/`*.bashrc`. This item is about PROFILES, not every module — a reading that demanded a
guard in each of the 16 numbered modules would report 14 false failures (they define
functions and are sourced by the guarded loader).

3.2

🔧 No background daemons at source-time

grep -nE 'nohup|&$|disown' <file>

bg processes only inside explicit user-invoked functions

3.3

🔍 Strict Mode (scope-dependent)

head -10 <file>

Strict mode requirements vary by file type:

- **Loader + sourced modules** (`tactical-console.bashrc`, `scripts/[0-9][0-9]-*.sh`): MUST NOT use `set -euo pipefail` (breaks interactive shell — see 3.8).
- **`install.sh`**: SHOULD use `set -euo pipefail`.
- **`bin/*.sh`**: MAY use `set -euo pipefail`. The premise that used to be here —
  "sourced into the environment via install.sh symlinks, so MUST NOT use `set -e`" —
  is wrong on both halves: `install.sh` installs them as `exec` shims (`launcher()`)
  or symlinks that are invoked as COMMANDS, never sourced. Two of them,
  `bin/bench-timeout-runner.sh:54` and `bin/tac_hostmetrics.sh:19`, legitimately use
  `set -euo pipefail` (verified 2026-09-16).
- **`tools/lint.sh`, `tools/run-tests.sh`**: document an intentional omission with a
  comment if `set -e` is absent (e.g., bare `(( ))` operators return exit 1 on zero).
  `tools/lint.sh` has `-e`; `tools/run-tests.sh:16` deliberately omits it so that one
  failing suite cannot abort the run before the summary is printed — that reason is
  now stated in the file (2026-09-16) rather than left to be guessed.

3.4

🔍 Subshell error inheritance

grep -n 'set -E' <file>

set -E is used if trapping ERR so subshells trigger traps

3.5

🔍 Trap cleans up on signals

grep -n 'trap' <file>

Traps handle EXIT, INT, TERM, ERR properly

3.6

🔧 No rm -rf with variables

grep -n 'rm -rf.*\$' <file>

Variable is validated non-empty; path is anchored

3.7

🔧 No destructive operations on unvalidated paths

grep -nE 'rm -rf|rm -f' <file>

Every rm target is either a literal path, validated non-empty, or under a known safe directory

3.8

🔧 set -euo pipefail NOT used in sourced profiles

Inspect .bashrc files

Profiles sourced into interactive shells MUST NOT use set -e (breaks interactive use). Standalone scripts SHOULD use it.

3.9

🔍 ERR trap tolerates expected failures

Inspect ERR trap handler

ERR trap filters exit code 1 (normal grep/test/[[ "not found" returns) to avoid log flooding

3.10

🔧 sudo calls are gated with sudo -n

grep -n 'sudo' <file>

All sudo calls in startup paths use sudo -n (non-interactive) to avoid hanging on password prompt

3.11

🔍 Background processes tracked for cleanup

grep -n '&$\|&)' <file>

Background PIDs are captured in an array and killed on EXIT trap

3.12

🔧 No infinite loops without a timeout or break condition

Inspect while/for loops

All loops have a bounded iteration count, timeout, or explicit break condition

3.13

🔧 Network calls in startup path are non-blocking

Inspect code executed at source-time

No curl/wget/nc calls in the startup (source-time) path; all behind functions or lazy caches

3.14

🔍 Startup does not hang if network is down

Inspect __bridge_windows_api_keys and similar

All pwsh.exe / typeperf.exe calls have timeout wrappers

4. Correctness & Clean Code — High

4.1 Syntax & Static Analysis

#

Check

Command

Expected

4.1.1

🔍 bash -n passes

bash -n <file>

Exit code 0, no output

4.1.2

🔍 ShellCheck passes (all severities)

shellcheck -s bash -x --source-path="$PWD" <file> (no `-S` severity filter)

Zero findings at all severity levels (error, warning, info, style). The invocation
above is the canonical one — the same flags `tools/lint.sh` runs, where
`-x --source-path` resolves the source-following SC1090/SC1091 class rather than
hiding it.

Directives: this repo DOES carry `# shellcheck disable=` lines — **25 across 14 files** at the
2026-09-16-era tip (`4381948d`), down from 37 across 25 before the module-graph change in
`tools/lint.sh` (§17.1), and **20 across 13** when re-derived on 2026-09-18 — five were removed by
fixing their cause or proving them redundant, not by adjusting the count (two cause-fixes in
§17.1, `bin/tac-exec`'s and the two in `tactical-console.bashrc` that its file-wide directive at
`:47` already covered). The "22 across 12 files" that used to be here
reproduces under NO scope of the command, at either revision — measured with
`git grep -c 'shellcheck disable=SC' <rev> -- scripts bin tools tests tactical-console.bashrc env.sh`.
The wording before that claimed the repo carried
none, which made this item unpassable and meant the count was never tracked. What the
repo requires is not zero directives but MINIMAL, REASONED ones: narrow where the
cause is local, with a note saying why. (The instruction that `disable=SC2034` /
`SC2154` be removed by "fixing the cause" per file is what led to linting the module
graph instead — a module's interface is only visible alongside its consumers.)

4.1.3

🔧 Fix all ShellCheck errors (SCxxxx)

Address each finding

Severity error = must fix; warning = should fix; info = evaluate

4.1.4

🔍 No syntax errors in embedded awk/sed

Inspect awk/sed snippets

All embedded awk/sed programs are syntactically correct and tested

4.1.5

🔍 No deprecated bash constructs

grep -nE '\$\[|\blet\b' <file>

Use $(( )) instead of deprecated $[ ]. Use (( )) instead of let.

4.2 Control Flow (Longhand Bash Enforced)

#

Check

Command

Expected

4.2.1

🔧 No golfed `&&` / `||` logic for branching

grep -nE '&&.*\|\||.*&&[^&]' <file>

Use explicit if/then/else instead of cmd && success || failure (which is NOT equivalent to if/then/else when success can fail)

4.2.2

🔧 Multi-line statements

Inspect script

Avoid ; to chain commands on one line. Use newlines.

4.2.3

🔍 All case branches end with ;;

shellcheck catches this

No fall-through warnings

4.2.4

🔧 case statements have a default *) branch

grep -A5 'case.*in' <file>

Every case has a *) catch-all for unexpected inputs, or a comment explaining why not

4.2.5

🔧 No compressed if/then on single lines

grep -nE 'if .*;.*then' <file>

Each if, then, else, elif, fi on its own line for readability

4.2.6

🔧 No compressed for/while on single lines

    grep -nE 'for .* do .* done' <file>

Loop body on separate lines; do/done on their own lines

4.2.7

🔧 Consistent return vs exit usage

Inspect functions vs scripts

Functions use return. Only top-level scripts use exit. Never exit from a sourced file.

4.2.8

🔧 No nested functions that capture outer scope unexpectedly

grep -n 'function.*function\|function.*()' <file>

If nested functions are used, comment explains dynamic scoping dependency

4.3 Variable Handling, Types & Dead Code

#

Check

Command

Expected

4.3.1

🔧 Separate declare and assignment

grep -nE 'local \w+=\$\(' <file>

(SC2155) Split: local x; x=$(cmd)

4.3.2

🔧 Lists use Arrays

Inspect assignment of lists

Use arr=(a b c), not str="a b c". Iterate with "${arr[@]}"

4.3.3

🔧 No dead/unused variables

`tools/lint.sh` (which lints the module graph), **not** a per-file shellcheck

All declared variables used. **Use the canonical gate.** A per-file
`shellcheck -s bash -x --source-path="$PWD" <file>` reports ~112 findings on a lone member of
this graph (mostly SC2034/SC2154) because a module's interface only exists alongside its
consumers — those are not dead variables, and chasing them file-by-file is the trap the
module-graph pass exists to remove. Verified 2026-09-17: two SC2034 claimants checked by hand
(`01-constants.sh`'s `VENV_DIR`, `LAST_TPS`) are genuinely used from other modules, so the
graph's clean result is correct rather than a suppression artifact. Item §1.12 and §17.1 carry
the same caveat.

4.3.4

🔧 No dead/unused functions

grep '^function' <file> then search usages

Delete unused functions to reduce bloat

4.3.5

🔍 Local variables declared local

Inspect functions

No accidental globals inside functions

4.3.6

🔧 Consistent variable naming: lowercase for locals, UPPER for exports/globals

Inspect variable declarations

Local vars: snake_case. Exported/global constants: UPPER_SNAKE_CASE. No mixedCase.

4.3.7

🔧 No unnecessary global variables

Inspect top-level assignments outside functions

Variables used only inside one function should be local to that function

4.3.8

🔍 Arithmetic variables (no declare -i requirement)

Inspect arithmetic variables

No requirement here, deliberately — this item was WITHDRAWN rather than met. It used to
ask that counters and numeric accumulators use `declare -i`; the repo uses **zero** of
them (measured 2026-09-16) and writes `local n=0; (( n++ ))` throughout.

That idiom is the better one, which is why the rule went: `declare -i` makes every
assignment to the variable an ARITHMETIC one, so `x=08` becomes an octal error, `x=abc`
silently becomes 0, and `x="1+1"` becomes 2. Assignments stop being assignments, and
that is a subtle trap rather than a safety feature. `(( ))` already gives integer
semantics in the places that need them.

A check that makes code harder to read and harder to reason about is not a standard
worth meeting.

4.3.9

🔧 Readonly variables declared readonly

Inspect constants

Constants that must not change after initialization use readonly

4.3.10

🔧 No shadowed variables

Inspect nested function calls

Inner functions do not re-declare variables that shadow outer scope without explicit intent

4.3.11

🔧 No deprecated OPENCLAW_ROOT usage

grep -n 'OPENCLAW_ROOT' <file>

Migrated to OC_ROOT; OPENCLAW_ROOT only kept as compatibility alias with deprecation comment

5. Robustness — High

Handle failures gracefully.

#

Check

Command

Expected

5.1

🔍 External commands guarded

grep -n 'command -v' <file>

Optional external tools checked before use via command -v

5.2

🔍 Network calls have timeouts

grep -nE 'curl|wget|nc ' <file>

--connect-timeout or --max-time present

5.3

🔍 Fallback values used

Inspect ${var:-default} usage

Critical paths have explicit default values

5.4

🔍 Error messages to stderr

`grep -rnE '(echo|printf)[^;]*(\[FAIL\]|Error:|ERROR:)' <file> | grep -v '>&2'`

Diagnostics in STANDALONE scripts go to stderr. Two deliberate exemptions, both
verified 2026-09-16: this repo's UI engine renders to stdout by design, so the
styled `[FAIL]`/`[WARN]` lines in the sourced modules ARE the interface and moving
them to stderr changes what callers capture; and `install.sh`'s `[WARNING]` lines
are progress output, not errors. Read the hits and judge them — do not expect zero.
The previous command here was a BRE, in which `|` is literal, so it matched nothing
and could never fail.

5.5

🔧 Failing subcommands checked

Inspect command sequences

After apt-get, pip, npm, etc.: check $? or use if/then; do not silently continue

5.6

🔧 Arithmetic errors guarded

Inspect $(( )) expressions

Division by zero is prevented with (( divisor > 0 )) checks; modular arithmetic is safe

5.7

🔧 File existence checked before reading

Inspect $(<file>) and source calls

All file reads preceded by [[ -f "$file" ]] guard

5.8

🔧 cd failures handled

grep -n '\bcd\b' <file>

No `cd` may silently proceed in the wrong directory. `|| return` / `|| exit` is the
usual remedy — but check what follows before applying it: where the continuation is
load-bearing, ending the shell is worse than the wrong cwd. The stdin keeper in
`scripts/11e-llm-model.sh` is the worked example (2026-09-16) — exiting the subshell
closes fd 3 and EOFs llama-server's stdin, so the fix creates the directory and
reports instead. The requirement is that the failure be neither silent nor fatal.

5.9

🔍 Pipe failures detected

grep -n 'pipefail' <file>

Applies to STANDALONE scripts only: `set -o pipefail` must NOT be set in a sourced
module, where it leaks into the user's interactive shell. For modules the
requirement is that the segment whose status matters is captured explicitly —
`${PIPESTATUS[0]}`, with `scripts/04-aliases.sh:212` as the reference. "pipefail
absent" in `scripts/` is therefore correct behaviour, not a finding.

5.10

🔧 curl responses validated

Inspect curl calls

HTTP response body is checked for validity (non-empty, valid JSON) before parsing

5.11

🔧 jq inputs validated

Inspect jq calls

jq calls wrapped with 2>/dev/null and output checked for empty/null before use

5.12

🔧 pwsh.exe/typeperf.exe calls have timeout wrappers

grep -nE 'pwsh|typeperf|powershell' <file>

All WSL interop calls wrapped with timeout to prevent hangs after sleep/hibernate

5.13

🔧 Stale cache data handled

Inspect cache reads

Functions degrade gracefully when cache data is corrupt, truncated, or zero-length

5.14

🔧 mkdir -p used before writing to directories

Inspect file write targets

Directories are created before writing files that depend on them existing

6. Efficiency & Native Bash — Medium

Performance Notes

Subshells: Subshells $(...) incur a fork overhead. In loops, this destroys performance. Use native Bash builtins (e.g., parameter expansion ${var%pattern}) instead of piping to sed, awk, or grep.

I/O Operations: Avoid while read -r line; do ... done < file for processing large files. Use mapfile to load files into memory as an array.

Tooling: Only use Python/Perl/Ruby if doing complex templating or math that Bash cannot natively handle.

#

Check

Command

Expected

6.1

🔧 Remove sed/awk/grep for strings

`grep -nE '\b(sed|awk|grep)\b' <file> | grep -vE ':[0-9]+:[[:space:]]*#'`

Replaced with native Bash ${var//find/replace} or ${var#prefix}. **The probe that used to be here
was non-discriminating:** `grep -nE 'echo.*|.*awk|echo.*|.*sed|echo.*|.*grep'` is equivalent to
`echo|awk|sed|grep` — proved by running both and getting the same 2,201 lines repo-wide — so it
counted every line that merely mentions `echo`. The contrast is stark per file: on
`scripts/11e-llm-model.sh` the old pattern returns 203 lines and the anchored one 18.
Re-derived 2026-09-18 over the tracked shell corpus (`*.sh`, `*.bashrc`, `bin/*`): **228** uses
with comments excluded, **256** with them — so "comments excluded: 256" was quoting the count the
exclusion is meant to remove, which is why re-running this item's own command does not reproduce it.
That is a migration backlog, not a crash — read the hits rather than chasing the number to zero.

**Read on 2026-09-18 at `f7403d24`, and the number is not a worklist.** Parameter expansion replaces
a *simple string* operation; the 228 are three different jobs — sed 34, awk 94, grep 115
(overlapping, since a line can hold more than one):

- **awk (94)** is the tool item 6.5 exists to sanction: "only if doing complex templating or math
  that Bash cannot natively handle". Field extraction and `printf "%.2f"` rounding are that.
- **sed (34)** does per-line and stream work parameter expansion cannot express: `sed 's/^/  /'`
  (indent every line), `sed '$d'`, `sed '/^[[:space:]]*$/d'` (drop blanks), `sed -n 's/^port=//p'`
  (pull one field out of a stream), `sed "$__unit_fix"` (a script held in a variable). `sed -i` — the
  only form that edits a file — is **0** sites.
- **grep (115)** searches files and streams rather than testing a variable. Only a `grep` fed by a
  here-string can become `[[ ]]`, and there are **4**. One of them,
  `grep -qvE '^[0-9]*$' <<< "${smi_out:-0}"` (`bin/gpu-busy.sh:83`), is *not* equivalent — tested,
  `123\n456` gives exit 1 from grep ("every line is numeric") where `[[ ! $x =~ ^[0-9]*$ ]]` is true —
  and `smi_out` is multi-line nvidia-smi output by construction.

Two sites were the real thing and were changed on 2026-09-18 (`scripts/04-aliases.sh:168`,
`bin/llama-watchdog.sh:287`). That is this item's shape: a number in the hundreds, a worklist in the
single digits.

6.2

🔧 No Useless Use of Cat (UUOC)

`grep -nE '\bcat [^|]*\|[[:space:]]*[a-z]' <file>`

No `cmd <file> | cmd` where `<file` or `<<<` would do. Expect **two known false
positives**, not zero: `journalctl --output=cat | grep` (`scripts/09a-oc-gateway.sh:488`,
where `cat` is a flag value) and a usage comment (`scripts/11f-llm-runtime.sh:701` —
re-derived 2026-09-18; this line said `:691`, and the file has moved since the 2026-09-16
audit while the citation did not). The previous command here had a literal newline inside its
character class plus an empty alternative, so grep rejected it rather than reporting anything.

6.3

🔧 No unnecessary subshells

`grep -nE '^\s*\([^(]' <file>`

`{ }` grouping where a subshell is not needed. The `[^(]` is what makes this
discriminating: `^\s*\(` alone also matches every `(( ... ))` arithmetic line — 245
of them at the 2026-09-16 audit, against 52 real subshell openings then. Re-derived
2026-09-18 with this item's command: **53**, i.e. the tree gained one subshell while the
number here stayed put. The arithmetic figure is scope-sensitive and I could not reproduce
245 under my globs (`*.sh` + `*.bashrc`, excluding `.venv`/`examples` → 198), so it is left
attributed to that audit rather than overwritten with a number I cannot defend. Most of the
subshell hits are justified (background groups, `( trap ... EXIT; ... )`,
`( umask 077; ... )`), so read them rather than counting them.

6.4

🔧 Optimize file reading

`grep -nE '^[[:space:]]*while[[:space:]]+(IFS=[^[:space:]]*[[:space:]]+)?read([^[:alnum:]_]|$)' <file | grep -vE ':[0-9]+:[[:space:]]*#'`

`mapfile -t` used for array ingestion instead of while-loops. **The probe that used to be here was
blind in the direction that matters:** `grep -n 'while read'` misses every `while IFS= read` site —
the standard whole-line idiom, and where most of these sites live — while also matching prose,
because `while read` is a substring of "while reading" (`scripts/autotune-model.sh:2284` is a comment
the old probe counted). Measured at `f7403d24` (2026-09-18, comments excluded): the old spelling
returns **7**, the anchored probe **75**. Those 75 are two populations and only one is this item's
business: **46** read a whole line (`while read`, `while IFS= read`) and **29** split fields
(`while IFS='|' read -r a b`), where `mapfile -t` is *not* equivalent and must not be used. Narrow
again to whole-line reads whose matching `done` carries a redirection — `done < file` or
`done < <(cmd)` — and the worklist is **41**. A loop fed by `cmd | while` is not in it: converting
one means moving the command into the process substitution, which is a different change.

**The 41 were then read, on 2026-09-18 at `f7403d24`, and reading them closes the item: not one
ingests a large input.** The item's rationale is "for processing large files", and the measured
sizes are 1–45 lines — `$HOME/.bashrc` 27 (`install.sh:157`), `~/.llm/models.conf` 28
(`scripts/11e-llm-model.sh:309`), `/dev/shm/tac_win_api_keys` 45 (`scripts/09d-oc-agents.sh:849`),
`find /proc/*/fd -lname '*llm-stdin*'` 0 (`tools/clean-orphans.sh:163`, `scripts/11d-llm-gpu.sh:122`),
`pgrep -af 'sleep 3600'` 3 (`clean-orphans:190`, `11d:198`, `11e:1395`),
`nvidia-smi --query-compute-apps` 1 (`11d:375`), and 22 `bench_*.tsv` files. A `while read` over 27
lines is not the cost this item exists to remove, and `mapfile -t` would add an array to save
nothing.

Two of the 41 are streams, where the conversion is not merely pointless but wrong — and both say so
in their own code:

- `tools/run-tests.sh:100` calls `test_line` per TAP line so a 386-test suite is seen to advance.
  Buffering it into an array shows nothing for 5–15 minutes and then everything at once.
- `scripts/11f-llm-runtime.sh:512` reads `curl --no-buffer` SSE chunks, `printf`s each delta as it
  arrives and `break`s on `[DONE]`. `mapfile` would hold a whole generation back until it finished.

The one site in this family worth touching has been touched, and it was a change *away* from the
pattern rather than toward `mapfile`: `scripts/09d-oc-agents.sh:866` read an already-in-memory array
back through `done < <(printf '%s\n' "${_var_names[@]}")`, forking a `printf` and a subshell to hand
`read` one line at a time. It is a plain `for` loop now (2026-09-18, module version 8 → 9). So the
item is satisfied by the tree as it stands, and re-opening it requires a site that actually reads
something large.

6.5

🔧 No external non-bash tooling

grep -nE '\bpython\b|\bperl\b|\bnode\b' <file>

Used strictly for templating/specialized tasks. Core logic stays native.

    awk '
    { if ($0 ~ /^[[:space:]]*#/) next
      if ($0 ~ /(^|[;&|[:space:]])do[[:space:]]*$/) { d++; next }
      if ($0 ~ /(^|[;&|[:space:]])done([^[:alnum:]_]|$)/) { if (d>0) d--; next }
      if (d>0 && $0 ~ /(^|[^[:alnum:]_-])(date|grep|awk|cut|sed|sort|basename|dirname)[[:space:]]/) print FILENAME":"FNR": "$0 }
    ' <file>

Loops that iterate >10× must not call `date`, `grep`, `awk`, `cut` inside the body; hoist or cache
the result beforehand. The old cell said only "Inspect for/while bodies", so every pass invented its
own probe and published its own number. **The tracker above keys on `do`/`done`, not on
`for`/`while`, and that is what makes it discriminating:** a shell script that embeds an AWK program
(`bin/tac_hostmetrics.sh`, `scripts/09d-oc-agents.sh`, `scripts/11d-llm-gpu.sh`) contains AWK
`for (luid in sums) { … }` loops that close with `}`, so keying on the shell keyword counts them as
loop headers and never closes them — a leak across files that inflated a first attempt at this
probe to 383 before it was caught. AWK has no `do…done`, so `do` cannot be an AWK header. Controls:
a `date` call inside a `for …; do` body matches, the same call outside any loop does not.
Re-derived 2026-09-18 at `f7403d24` (comments excluded): **63** calls inside a loop body, headed by
`scripts/11e-llm-model.sh` (10) and `tools/lint.sh` (7). Two limits, stated rather than hidden:
iteration count is not statically knowable, so read the hits and apply the >10× test by eye; and a
`do`/`done` pair inside a heredoc that *generates* a script is counted, so a file's own `do`/`done`
totals can differ by a few — that difference is the probe's uncertainty, not a finding.

**Read on 2026-09-18 at `f7403d24`, and the item's own remedy applies to none of the 63.** Split by
tool: grep 24, awk 15, basename 10, date 8, sed 4, cut 3, dirname 2, sort 0.

- **Nothing is hoistable.** All 8 `date` calls are per-iteration by construction —
  `start_ns=$(date +%s%N)` / `end_ns=$(date +%s%N)` timing a measurement
  (`11f-llm-runtime.sh:205,210`, `spec-decode-bench.sh:114,117`, `tactical-console.bashrc:177,179`),
  a filename stamp (`chat_$(date +%Y%m%d_%H%M%S).json`), and a per-event log timestamp. Hoisting any
  of them breaks the thing it measures. The grep/awk/sed/cut sites are per-iteration by necessity
  too — each filters or parses the item the loop is currently on, so there is no invariant to cache.
- **The 10 `basename` sites were the work**: a fork per iteration with an exact native equivalent,
  converted to `${f##*/}` (module versions 08-maintenance 40→41, 11e-llm-model 40→41,
  docs-sync-check 5→6). Each takes its path from a glob, an array or `find`, so a trailing slash is
  impossible and the two forms agree — that qualifier is load-bearing, since `basename a/b/` is `b`
  where `${a/b/##*/}` is empty.
- **Left alone with reasons**: the 2 `dirname` sites (`09f-oc-misc.sh:575,587`) — `${x%/*}` is *not*
  its equivalent, verified: `dirname c.sh` is `.` where the expansion is `c.sh`, and `dirname a//b`
  is `a` where the expansion is `a/`; and the 3 `cut` sites, where bash has no single-step delimiter
  split.

The item's enumeration says `date, grep, awk, cut`; the probe also matches `sed`, `sort`, `basename`
and `dirname`, and that is what let it find the 10 real sites. Its two apparent misses were checked
rather than assumed: `basename` also appears at `08-maintenance.sh:780` and `11e-llm-model.sh:456`,
but both sit outside any loop (an `if` block and straight-line code), so excluding them was correct
and the 63 stands.

6.7

🔧 String tests prefer [[ ]]

grep -nE '^\s*\[ ' <file>

Use [[ ]] instead of [ ] for string/regex tests — no word-splitting, supports pattern matching

6.8

🔧 Arithmetic tests prefer (( ))

`grep -nE '\[\[.*[[:space:]]-(gt|lt|ge|le|eq|ne)[[:space:]].*\]\]' <file | grep -vE ':[0-9]+:[[:space:]]*#'`

Use `(( n > 5 ))` instead of `[[ $n -gt 5 ]]` for numeric comparisons. The old cell said only
"Inspect numeric comparisons", so three passes produced three numbers for the same tree — 245 at the
2026-09-16 audit, 240 later, and 234 from a loose `\[\[.*-(gt|…)\b` — none of them reproducible from
the item. One way to get this wrong is worth recording, because the first attempt here did: writing
the operand as `[^]]*` ("no `]` before the operator") silently drops every test whose left side is an
array length, since `${#arr[@]}` contains a `]` — 17 sites, which is the whole gap to the loose
pattern. The probe above closes on `]]` without constraining the operand. Controls: `[[ "$n" -gt 5 ]]`
matches, `[[ ${#a[@]} -gt 0 ]]` matches, and `(( n > 5 ))` does not — it cannot report the very form
this item asks for. Re-derived 2026-09-18 at `f7403d24`: **232** comments excluded, 234 raw, and the
loose pattern agrees at 232 once it too excludes comments — that agreement is the cross-check that
the operand class is now right.

**Read on 2026-09-18, and this item saves nothing — it is syntax, not cost.** Unlike 6.1 and 6.6 there
is no fork to remove: `[[ ]]` and `(( ))` are both shell builtins. And the two forms are
behaviourally identical, not merely similar: tested across 11 operand values — `5`, `0`, `-1`, `5.5`,
`abc`, `" 5"`, `0x10`, `1e3`, empty, whitespace, `007` — the comparison status *and* the stderr text
matched every time, including the errors (`5.5` and `1e3` produce the same "invalid arithmetic
operator" / "value too great for base" from both). `[[ x -gt y ]]` evaluates its operands
arithmetically exactly as `(( ))` does, so there is no loud-failure-versus-silent-coercion trade
either — the reason to replace one with the other is spelling alone. The operator split is `-eq` 82,
`-gt` 79, `-lt` 40, `-ge` 23, `-ne` 13, `-le` 2.

Converting 232 sites across 8 files — 100 of them in `scripts/autotune-model.sh` — therefore buys a
shorter spelling and nothing else, at the cost of eight module-version bumps and eight
re-verifications. It is not even uniformly possible: mixed tests such as
`[[ "$_behind" -eq 0 && "$_ahead" -eq 0 ]]` (`08-maintenance.sh:658`) and
`[[ "$RECOVERY" -eq 1 && -z "${STALE:-}" ]]` (`bin/llama-gpu-clear.sh:139`) must stay `[[ ]]` or be
split into two statements, because a string test cannot live inside `(( ))`. Read this item as
guidance for new code whose operand is provably numeric; it is not a migration, and the count should
not be chased.

6.9

🔧 Here-strings over echo | pipe

    awk '
    { s = $0
      gsub(/"[^"]*"/, "Q", s); gsub(/'[^']*'/, "Q", s)
      if (s !~ /(^|[;&({]|do[[:space:]]|then[[:space:]])[[:space:]]*echo([^[:alnum:]_]|$)/) next
      if (s !~ /echo[^|]*\|[^|]/) next
      print FILENAME":"FNR": "$0 }
    ' <file>

Use `<<< "$var"` instead of `echo "$var" | cmd` where possible; avoids a fork. **The item's own
command counts the wrong thing**, in both directions: `grep -nE 'echo.*\|'` asks only that an `echo`
appear somewhere before a `|`, so `echo "0|0|0"`, the `… ; echo true || echo false` form (the `||` of
the `&&`/`||` idiom) and `case` alternations such as `…|echo|enable|…` all count. Re-derived
2026-09-18 at `f7403d24`, comments excluded: the item's command returns **179**, the probe above
**89** — and that 90-line difference decomposes cleanly, which is the check that the probe is right.
56 of the 90 have no `echo` at command position at all (13 of those are `||` or a `case`
alternation), and 34 are command-position echoes with no pipe to feed, most of them the
`[[ … ]] && echo a || echo b` idiom. The probe strips quoted text before testing, so a literal `|`
in the message neither counts nor hides a real pipe behind it, and it requires `echo` to be *at
command position*, so `cmd | echo …` (echo as the consumer) is not a candidate. Controls:
`echo "$x" | wc`, `echo "a|b" | wc`, `x=$(echo "$y" | …)` and `…; then echo q | cat` match;
`echo "0|0|0"`, `foo || echo hi`, `ls | grep "$(echo x)"`, `cmd | echo x` and a `case` alternation
do not.

**The 78 in §18.3 is unattributable**, the same shape as §4.1.2, where no scope of an item's own
command reproduced its stated count. Re-derived at both `4381948d` (the 2026-09-16-era tip) and
`f7403d24`: raw 177 → 179; "a command letter follows the pipe" 106 → 110; "pipe then non-space"
89 → 87; "the argument is a variable" 92 → 96; numbered modules only 89; `scripts/` only 164;
`tools/` + `bin/` only 15. Nothing lands on 78, and the tree did not grow into it — 69 shell files
at both revisions, 35 commits apart.

The concentration is real and worth reading: `scripts/autotune-model.sh` holds 53 of the 89, then
`scripts/08-maintenance.sh` (7) and `scripts/11e-llm-model.sh` (6). For scale, `<<<` is already used
**98** times, so this is a partial migration rather than an untouched one.

6.10

🔧 printf over echo -e

grep -n 'echo -e' <file>

printf is portable and unambiguous; echo -e behavior varies across shells

6.11

🔧 Process substitution over temp files

`grep -nE '\bmktemp\b' <file | grep -vE ':[0-9]+:[[:space:]]*#'`

Use `<(cmd)` or `>(cmd)` instead of writing to temp files when data is consumed once. The old cell
said only "Inspect mktemp usage", so it carried no command and no count at all. Re-derived
2026-09-18 at `f7403d24`: **23** sites, against 27 for the bare `grep -n mktemp` — the four extra are
comments that mention it (`scripts/07-telemetry.sh:31`, `scripts/09f-oc-misc.sh:485` and `:487`,
`scripts/14-wsl-extras.sh:28`). The distribution is concentrated: `scripts/09d-oc-agents.sh` holds
6, then two each in `tools/sync-openclaw-completion.sh`, `tools/normalize-fixture.sh`,
`scripts/11e-llm-model.sh` and `scripts/07-telemetry.sh`. A `mktemp` that a `trap … EXIT` deletes
and several commands write to is legitimate; the item's test is "consumed once", which the probe
cannot see, so read the 23 rather than counting them.

6.12

🔧 Avoid du on drvfs mounts

grep -n '\bdu\b' <file>

du -sb on /mnt/c (drvfs) is extremely slow; use stat --printf='%s' or wc -c instead

6.13

🔧 Cache expensive lookups

    for L in 'command -v' uname lsb_release hostname nproc getconf; do
        for f in <files>; do
            c=$(grep -nE "(^|[^[:alnum:]_])${L// / }([^[:alnum:]_]|$)" "$f" | grep -vcE ':[0-9]+:[[:space:]]*#')
            [ "$c" -gt 1 ] && echo "$L: $f ($c)"
        done
    done

Results of `command -v`, `uname`, `lsb_release`, etc. called once and stored in a variable. The old
cell said only "Inspect repeated calls to same command", so like 6.6 it had no command and no count.
The item's claim is *repetition within one file*, and that has to be the probe or it answers a
different question: word-bounded and comments excluded, this tree holds **100** lookup call sites,
but only **23** (file, lookup) pairs where one lookup appears more than once. The boundaries are a
correctness guard rather than a number-changer here — measured both ways, the bare substring returns
the same 23 — but they are what keeps `my_command -v` and `nproc_file` from counting as lookups. The
distribution is the finding: `scripts/08-maintenance.sh` alone holds **23** `command -v` calls,
then `scripts/09d-oc-agents.sh` (8), `scripts/09f-oc-misc.sh` (7), and `scripts/09a-oc-gateway.sh`
and `scripts/11e-llm-model.sh` (6 each); `nproc` repeats in three files. A lookup whose answer
genuinely varies between calls is not a candidate — read the pairs.

7. Portability — Medium

#

Check

Command

Expected

7.1

🔍 Shebang is correct

    head -1 <file>

    #!/usr/bin/env bash

`#!/usr/bin/env bash` for every executable; a sourced module uses
`# shellcheck shell=bash` and no shebang. A machine-specific absolute interpreter
path — `#!/home/linuxbrew/.linuxbrew/bin/bash` — needs a stated reason in the file
or the commit, and is justified only when the script genuinely needs that
interpreter: check for a version-specific construct before assuming it does. Note
also that a shebang is IGNORED whenever the caller runs `bash <script>`, which is
how every in-repo caller of the autotune benches invokes them (added 2026-09-16).

7.2

🔍 GNU extensions documented

grep -nE 'stat -c|find.*-printf|date \+%s%N|readarray|mapfile' <file>

GNU-ism justified & documented (Standard for Ubuntu/WSL)

7.3

🔍 Bash version minimum documented

Inspect file header

Minimum required Bash version stated (e.g., 5.1+ for ${var@Q}, mapfile -d)

7.4

🔍 WSL-specific paths guarded

grep -rnE '/mnt/[c-z]|wslpath|wsl\.exe|clip\.exe|pwsh\.exe' --include='*.sh' .

Every interop call must fail predictably off-WSL. Two acceptable forms, in this
order of preference: an explicit detection guard (`[[ -n "${WSL_DISTRO_NAME:-}" ]]`,
or `grep -qi microsoft /proc/version` as `scripts/09f-oc-misc.sh:157` does), or an
availability probe on the binary itself (`command -v pwsh.exe`), which is what most
call sites use because it answers the question that matters — can this call work at
all. What is NOT acceptable is an unconditional `/mnt/c` path. Measured 2026-09-16:
one site detects WSL; the rest rely on availability probes.

7.5

🔍 Windows executable calls documented

grep -nE '\.exe\b' <file>

Each .exe call has a comment explaining what it does and why native Linux alternative isn't used

7.6

🔍 /dev/shm availability assumed safely

grep -n '/dev/shm' <file>

All /dev/shm usage preceded by a mount check or documented as WSL/Linux-only requirement

7.7

🔍 drvfs performance caveats documented

Inspect /mnt/ usage

Any heavy I/O on /mnt/c paths has a comment noting drvfs performance penalty

8. Style & Formatting — Medium

Strictly enforce "Classic Longhand Bash" and extreme readability. Do not compress code.

8.1 Spacing & Readability

#

Check

Command

Expected

8.1.1

🔧 Liberal vertical spacing

Inspect script visually

Blank lines exist between logical blocks, variable declarations, and loops.

8.1.2

🔧 Liberal horizontal spacing

Inspect script visually

Spaces around operators (=, ==, +). e.g., [[ $a == $b ]] not [[$a==$b]].

8.1.3

🔧 Consistent indentation

grep -Pc '\t' <file>

Uniform 4 spaces (No tabs).

8.1.4

🔧 No trailing whitespace

grep -Pn ' +$' <file>

Zero matches.

8.1.5

🔧 No compressed if/then on one line

`grep -nE ';.*fi$' <file>`

A whole `if/then/else/fi` compressed onto one line is not allowed; the body goes on
its own line. Measured 2026-09-16: 48 lines. The command that used to be here —
`if .*;.*then|;.*fi$` — ALSO matched 627 ordinary `if [[ … ]]; then` headers, the
idiomatic form with the body on the next line, so its output was never a clean
signal and its count was unusable.

8.1.6

🔧 No compressed for/while/do on one line

`grep -nE ';.*done$' <file>`

A whole `for/do/done` or `while/do/done` compressed onto one line is not allowed.
Measured 2026-09-16: 9 lines. As in 8.1.5, the command that used to be here also
matched normal `for …; do` headers — 144 of them — so it over-reported by ~15x.

8.1.7

🔧 && / || not used as if replacements

grep -nE '&&|\|\|' <file>

Avoid cmd && success || failure pattern; use explicit if/then/else for clarity

8.1.8

🔧 Long lines wrapped

awk 'length > 120' <file>

Lines under 120 characters; long strings broken with backslash continuation. No exemptions — URLs must be extracted to variables; heredoc content must be wrapped or refactored.

8.1.9

🔧 No <<- heredocs (tabs are banned)

`grep -n '<<-' <file>`

Zero, and none is wanted. `<<-` only strips TAB indentation, and 8.1.3 forbids tabs
outright — so the two rules cannot both hold, and this one loses. Heredoc bodies here
are indented with spaces and the delimiter sits at column 0. Measured 2026-09-16: 0
occurrences of `<<-`; 27 real heredocs and 98 `<<<` herestrings.

The command that used to be here, `grep -n '<<[^-]'`, had two faults: it matched
`<<<` herestrings (98 of its 125 hits), so ordinary herestrings were reported as a
heredoc-style violation, and its expectation (`<<-` with tabs) contradicted 8.1.3.

8.2 Declarations

#

Check

Command

Expected

8.2.1

🔍 Functions named consistently

`grep -cE '^function ' <file>` and `grep -cE '^[a-z_][A-Za-z0-9_]*\(\)' <file>`

House style is `function name() {`. Measured 2026-09-16: **298** definitions use the
`function` keyword and **92** use the bare `name()`, and **no file mixes the two** —
each file is internally consistent, which is the property that actually matters. The 92
sit in a handful of files (autotune-model, llama-watchdog, gpu-busy, run-tests, and the
installer/standalone tools).

So the requirement is ONE STYLE PER FILE. The previous wording ("prefer func_name() { }")
implied migrating the 298, and that is not wanted: it is churn that buries findings, and
`function` is the more greppable and unambiguous of the two. Do not unify them, and do
not mix styles inside a file.

8.2.2

🔍 Constants in UPPER_CASE

Inspect constant declarations

Read-only global constants in ALL_CAPS.

8.2.3

🔍 Local variables in lower_case

Inspect function bodies

All function-scoped variables declared with local and named in lower_snake_case

8.2.4

🔍 Section headers use consistent divider style

Inspect section markers

All major sections use identical divider format (e.g., # ═══════════... with §N tag)

8.2.5

🔍 Function opening brace on same line

grep -nE '^\{' <file>

Always func_name() { not func_name()\n{ — K&R style consistently

8.2.6

🔍 Quoting style consistent

Inspect variable references

Double-quote variables ("$var") everywhere unless explicitly splitting; single quotes only for literal strings

9. Documentation & Future-Proofing — Medium

Optimize for Wayne, future maintainers, and AI systems (specifically for future PowerShell conversion).

#

Check

Action

Expected

9.1

🔍 File header present

head -20 <file>

Purpose, author, version, date

9.2

🔧 Liberal inline commenting

Scan script visually

Comments explain why logic exists, not just what it does.

9.3

🔧 AI / PowerShell translation notes

Inspect complex Bashisms

Difficult regex, file-descriptor manipulation, or Bash-specific tricks have comments explaining the intent so an AI can port it to pwsh.

9.4

� Modular Architecture

`ls scripts/[0-9][0-9]-*.sh | grep -v 18-lint.sh; ls scripts/09b-gog.sh`

16 profile module files exist under scripts/ (01-constants through 15-model-recommender + 09b-gog). **Do not count the raw glob:** `ls scripts/[0-9][0-9]-*.sh scripts/09b-gog.sh` returns **17**, because the numbered pattern also matches `scripts/18-lint.sh`, a standalone utility that is not a profile module — so "16 numbered + 09b" double-counts against both the glob (17) and `scripts/_module-list.sh` (16). Correct composition: 15 numbered profile modules + `09b-gog.sh` = 16. 13 utility scripts live in tools/. The loaders (tactical-console.bashrc, env.sh) source the profile modules in the order given by scripts/_module-list.sh. Each module has `@modular-section`, `@depends`, and `@exports` annotations below its header.

9.4.1

🔍 Module load order matches dependencies

Inspect @depends annotations

Every module's @depends lists only modules with a lower numeric prefix. No circular dependencies.

9.4.2

🔧 Module version tracks changes

grep 'Module Version:' scripts/[0-9][0-9]-*.sh

Each module has a `# Module Version: N` comment in its header. When a module is modified, its version number is incremented; `TACTICAL_PROFILE_VERSION` then auto-computes from the sum of all module versions. `_TAC_LOADER_VERSION` in `tactical-console.bashrc` is bumped only when the loader itself changes.

9.4.3

🔍 Loader sources all modules

grep '_module-list' tactical-console.bashrc

Both loaders read the canonical module list from `scripts/_module-list.sh` (via `__tac_module_list`). The loader does NOT glob `scripts/`; adding or removing a module means editing that shared list, which keeps the interactive and library loaders in sync.

9.4.4

🔍 No executable code in loader

Inspect tactical-console.bashrc

The loader contains only: header comments, the interactive guard, sourcing of the
shared fragments (`_startup-env.sh`, `_module-list.sh`), `TACTICAL_PROFILE_VERSION`,
the module loop, `unset` cleanup — PLUS two blocks this item originally omitted: the
`-f`-guarded host-env sources (`~/.openclaw/secrets.env`, wrapped in `set -a`/`set +a`,
and `~/.config/environment.d/90-openclaw.conf`) and the optional display banner
(`__TAC_DISPLAY_BANNER`, which calls `clear_tactical`). All LOGIC lives in modules.
Measured 2026-09-16: those are the loader's only non-comment lines — nothing else.

9.5

🔧 Every function has a purpose comment

Inspect function definitions

A one-line comment above each function stating what it does (not a full docstring — just purpose)

9.6

🔧 Complex regex patterns explained

grep -nE '\[\[.*=~' <file>

Every =~ regex or sed/awk pattern beyond trivial has an inline comment explaining what it matches

9.7

🔧 Non-obvious exit codes documented

Inspect return/exit statements

Any return code other than 0/1 has a comment explaining its meaning

9.8

🔧 Global state mutations documented

Inspect global variable writes in functions

Functions that modify global variables have a comment at top listing which globals they change

9.9

🔧 TODO/FIXME/HACK tags tracked

grep -nEi 'TODO|FIXME|HACK|XXX|TEMP' <file>

Each tag has an owner or date; stale tags (>6 months) flagged for resolution

9.10

🔍 Significant changes are recorded

`git log --oneline`

NO separate CHANGELOG, by design. The commit history IS the changelog here, and unlike a
hand-maintained file it carries the WHY: each commit states what was wrong, what the
evidence was, and what was deliberately left alone. Measured 2026-09-16: no CHANGELOG
file or section exists anywhere in the repo, and `README.md`'s "Version System" section
documents the versioning scheme instead.

A hand-written CHANGELOG would be a SECOND record of the same facts, maintained by hand,
that drifts — the exact failure mode this repo keeps hitting (test counts asserted in
three places, shellcheck flags in three places, ci.yml's copy of the lint flags). If a
user-facing artifact is ever wanted, GENERATE it from git (release notes / `git log`);
never maintain it by hand.

9.11

🔧 Design decisions documented

Inspect §0 or file header

Key architectural choices (modular loader + 16 profile modules, /dev/shm caching, WSL interop strategy, dual-version scheme) documented for future maintainers

10. Refactor & Maintainability — Low

#

Check

Action

Expected

10.1

🔍 Abstract repeated logic

Search for 3+ identical code blocks

Extract to helper functions

10.2

🔍 Magic numbers extracted

grep -nE '[^0-9][0-9]{4,}[^0-9]' <file>

Named constants used instead of hardcoded numbers

10.3

🔧 Diagnostic utilities

Inspect for diagnose/dryrun

Script includes a --dry-run or validation mode

10.4

🔍 Function length reasonable

`grep -cE '^(function )?[A-Za-z_][A-Za-z0-9_]*\(\)' <file>` for the definition count,
then read the long ones — there is NO reliable one-liner for the length itself

Functions under 100 lines; longer ones carry subsection comments or are split
candidates. Measured 2026-09-16, brace-matched parse over 63 files (287 definitions):
**21 functions exceed 100 lines**, longest `ockeys` (`scripts/09d-oc-agents.sh:399`)
at 436.

Two warnings, both measured, because the obvious commands do not work:

- The command that used to be here,
    `awk '/^[a-z_].*\(\)/{name=$1; start=NR} /^}/{…}'`, reports `$1`. For `foo() {`
    that is the name, but for `function foo() {` — the repo's dominant style, 301 of
    385 defs — it prints the literal word `function`, so every hit was
    unattributable. Do not restore it.
- Brace counting is not a safe substitute either: heredocs in this repo contain
    braces, so depth never returns to zero and the span runs away — the candidate
    probe reported one "function" as **16,452 lines**. An over-100-line hit from
    that method is noise, not a finding.

10.5

🔍 Cyclomatic complexity reasonable

Inspect deeply nested if/case blocks

No function exceeds 4 levels of nesting; deeply nested logic refactored to early-return or helper functions

10.6

🔍 Configuration separated from logic

Inspect hardcoded values

Paths, ports, URLs, and thresholds defined as constants at top of file or in config files, not embedded in functions

10.7

🔍 Consistent error reporting pattern

Inspect error output

A single error reporting helper (e.g., __tac_error) used throughout instead of ad-hoc echo/printf to stderr

10.8

🔍 Dead feature flags removed

Inspect ENABLE_* or feature toggle variables

No feature flags that are permanently enabled/disabled; remove the flag and keep the code

10.9

🔍 Startup path is linear and clear

Inspect §13 init sequence

Initialization follows a predictable sequence with clear dependency ordering; no circular calls

11. Testing & CI — Low

#

Check

Action

Expected

11.1

🔧 Lint script exists

`tools/lint.sh` — three modes: whole repo (default), `--staged` (the staged
`.sh` files, used by the pre-commit hook), and `--files F...` (an explicit list,
used by the BATS suites)

bash -n + shellcheck executed automatically, with the flags defined in exactly
one place. shellcheck runs `-x --source-path` so the SC1090/SC1091
source-following class resolves instead of being suppressed; callers must not
re-invoke shellcheck with their own flags.

Measured 2026-09-16: `.github/workflows/ci.yml` was the LAST caller doing exactly
that — `shellcheck -s bash "$f"`, no `-x`, so CI analysed every module STANDALONE and
failed on `01-constants.sh` (SC2034 for `VENV_DIR`, `LAST_TPS` — both used by other
modules) while `tools/lint.sh` passed on the same tree. It had passed only because of
the file-wide disables the module-graph change removed. CI now calls `tools/lint.sh`
and nothing else. Add a future caller as `tools/lint.sh --files`, never as a fresh
shellcheck invocation.

Two facts to preserve. (1) lint.sh's `bash -n` and shellcheck loops cover `env.sh` —
they did NOT until 2026-09-16, while CI's hand-rolled loops did, so removing those
without adding it here would have dropped 218 lines from every check. (2) A sourced
MODULE is only analysed correctly through the graph: a bare
`shellcheck -s bash <module>.sh` reports its interface (SC2034/SC2154 for variables
that other modules use) BY DESIGN, and that is not a finding.

CI YAML is covered by NO check — shellcheck cannot read it and lint.sh never looks at
it. Validate it explicitly after editing:

    .venv/bin/python3 -c "import yaml;yaml.safe_load(open('.github/workflows/ci.yml'))"

A colon+space inside an unquoted step name is a YAML syntax error, and nothing in this
repo will tell you: on 2026-09-16 a step named `Lint & static analysis (canonical:
tools/lint.sh)` broke the whole workflow silently.

⚠ A comment line must never BEGIN with the directive word (the `#` + the tool
name): shellcheck parses any such line as a directive and fails the file with
SC1072/SC1073. A wrapped sentence is enough to trigger it — hit 2026-09-15 by a
comment in `install.sh` whose continuation line started that way. Wrap earlier,
or reword.

11.2

🔍 BATS integration

Check for tests/*.bats

Core logic functions are sourced and tested via BATS-core

11.3

🔍 Smoke test exists

Check for test script

Basic script invocation works without errors

11.4

🔧 Lint covers all file types

Inspect lint.sh scope

lint.sh runs on .sh files AND .bashrc files; not just scripts in bin/

11.5

🔧 ShellCheck directives are minimal and justified

grep -c 'shellcheck disable' <file>

Each disable has an inline comment explaining why; no blanket disables at file level covering unrelated issues

11.6

🔧 CI runs on commit

`tools/hooks/pre-commit` — tracked, and activated by `core.hooksPath` (which
`install.sh` sets) — plus `.github/workflows/`

Linting and bash -n run automatically before commits land. The hook must CALL the
tracked tools (`tools/lint.sh --staged`, `tools/check-module-versions.sh --staged`)
rather than inlining them: an inlined copy drifted from `tools/lint.sh` on
2026-09-15 because `.git/hooks/` is not version-controlled, so one of the two
copies of the shellcheck flags was never updated. Hooks live in `tools/hooks/`.

11.7

🔍 Integration test for source cycle

`grep -rn 'env -i' tests/*.bats tests/unit/*.bats tests/integration/*.bats`

A test sources the loader in a CLEAN environment (`env -i`) and fails if it errors or
hangs. Added 2026-09-16 to `tests/tactical-console-fast.bats`; before it, the only
sourcing of the profile in any suite was a sed-patched derivative run with
`&>/dev/null || true`, so nothing failed if sourcing broke.

TWO assertions are required, and the reason matters:

- `source tactical-console.bashrc` non-interactively returns at its interactive guard —
    rc 0, nothing defined, `TACTICAL_PROFILE_VERSION` left unset. So "it exits 0" is true
    even of a no-op, and an item satisfied by that alone is a green that cannot go red.
- `source env.sh` from the SAME empty environment must define the interface
    (`declare -F model`, `declare -F so`). That is the half with teeth, and it is the
    library loader rather than the interactive profile — verified 2026-09-16.

11.8

🔧 Python lint (ruff) passes

`.venv/bin/python -m ruff check scripts/kgraph/ scripts/oc-health-check.py tests/`

All checks passed — no bare excepts (BLE001), no unused imports (F401), no import order violations (E402)

11.9

🔧 Python tests pass

`.venv/bin/python -m pytest tests/test_kgraph.py tests/test_models.py tests/test_untested_modules.py --timeout=60 -q`

All collected tests pass. Do not trust a written-down count: derive it with
`--collect-only -q` before quoting one. Measured 2026-09-16 by collection: **324**
tests (92 + 37 + 195), with ZERO skip/xfail markers — so the "174 passed" this item
used to state cannot describe the command any more (that would require ~150 failures,
which would itself be the finding). A stale pass-count is worse than none: it reads as
a target and quietly stops being checked.

11.10

🔧 Pydantic models enforce schema

Check `scripts/kgraph/models.py`

GraphNode requires `id`; GraphEdge canonicalises `from`/`to` → `source`/`target`; GraphBuilder deduplicates; all kgraph modules accept `Graph | dict`

11.11

🔧 Python CI job exists

Check `.github/workflows/ci.yml`

`python` job runs ruff lint + pytest on Python 3.12

11.12

🔍 No bare `except Exception:` in Python

`.venv/bin/python -m ruff check --select BLE001,S110,S112 scripts/kgraph/ scripts/oc-health-check.py`

0 violations — all exception handlers use specific types

11.13

🔍 Python .venv compliance

Check shebangs in `scripts/oc-health-check.py`

Shebangs point to `.venv/bin/python`, not system `python3`

11.14

🔍 Concept aliases externalised

Check `config/concept-aliases.json` exists and `scripts/kgraph/memory_import.py` loads from it

No hardcoded alias dicts in Python source; all classification data in JSON config

Resolved 2026-09-16. The copies had diverged, so the JSON gained the seven `models.py`
keys it never had plus a `stopwords` section, and `scripts/kgraph/constants.py` is now
the single loader: `SCAFFOLDING_LABELS`, `CONCEPT_ALIASES`, `LOW_VALUE_CONCEPTS`,
`WRAPPER_TERMS`, `AGENT_ROLES` and `STOPWORDS` all come from `load_concept_config()`.
`memory_import.py`, `models.py` and `projection.py` import them instead of keeping
their own dicts, and the test that patched the config path patches
`kgraph.constants._CONCEPT_CONFIG_PATH` now.

12. llama.cpp Integration — Medium

Audit llama-server CLI flags, model management, health monitoring, and inference configuration for correctness against current llama.cpp best practices.

12.1 Build & Version Currency

#

Check

Command

Expected

12.1.1

🔍 llama.cpp version tracked

grep -rn 'LLAMA_BUILD_VERSION' scripts/01-constants.sh

Build version or commit hash stored/displayed so a regression can be traced to a specific build. The variable is `LLAMA_BUILD_VERSION` — 01-constants.sh derives it from the llama.cpp checkout's short commit (`unknown` when that tree is not a git repo), `model status` renders it for a running server (JSON `"build"`, plain `build=`), and `llm-build` refreshes it after a build. There is no `LLAMA_VERSION`: an earlier version of this row named that, and it never existed

12.1.2

🔍 Build flags validated

Inspect build/compilation notes

CUDA build uses -DGGML_CUDA=ON; AVX2/AVX512 detected and used where available

12.1.3

🔍 Update path documented

Inspect maintenance commands

A rebuild/update command or alias exists (e.g., llm rebuild) with steps documented

12.2 Server Flags & Configuration

#

Check

Command

Expected

12.2.1

🔍 --jinja flag used for chat templates

grep -n '\-\-jinja' <file>

--jinja present for models with Jinja chat templates (mandatory for Qwen3, Qwen3.5, Llama 3.x)

12.2.2

🔍 --flash-attn enabled

grep -n '\-\-flash-attn\|--fa' <file>

--flash-attn used to reduce memory bandwidth (requires CUDA flash attention support)

12.2.3

🔍 MoE rows are handled deliberately, without an expert-offload flag

`grep -rnE 'cpu-moe|override-tensor|-ot |exps=' scripts/ bin/ tools/ config/` → expect ZERO

For Mixture-of-Experts models the repo does NOT pass `--cpu-moe` or `-ot exps=CPU`.
Measured 2026-09-16: zero occurrences of either anywhere. The deliberate treatment is by
LAYER COUNT — `11d-llm-gpu.sh` returns the model's total layer count for MoE rows because
"expert weights stay on CPU anyway", and `01-constants.sh` sets `MOE_DEFAULT_CTX`.

That is a design choice, not an omission: naming the experts explicitly buys nothing when
the placement heuristic already keeps them off the card. Change this item only if a
measurement shows expert offload behaves differently.

12.2.4

🔍 -ngl set appropriately

grep -n '\-ngl' <file>

GPU layers set to 999 (all) for small models; documented if partial offload is intentional for VRAM-constrained setups

12.2.5

🔍 --load-mode mlock used consciously

grep -n 'load-mode' <file>

`--load-mode mlock` pins the model in RAM; document the trade-off with system memory pressure. Build 10955 removed `--mlock`/`--mmap`/`--no-mmap` — passing the old spelling is a fatal `invalid argument`, not a warning.

12.2.6

🔍 --no-context-shift considered

grep -n '\-\-no-context-shift' <file>

If present, documented why context shift is disabled (avoids silent truncation; forces explicit context management)

12.2.7

🔍 Thinking models are controlled by `--reasoning`, not a "budget"

`grep -rn -- '--reasoning' scripts/ bin/ tools/ systemd/ config/`

Thinking models are controlled by `--reasoning on|off|auto`, plus `--reasoning-effort
LEVEL` and `--reasoning-format FORMAT`. There is **no `--reasoning-budget` in this
build** — `llama-server --help` lists exactly the three above and nothing containing
"budget" — so the wording this item used to carry named a flag that does not exist.

And something IS passed: every lane unit pins `--reasoning off` in its ExecStart
(`systemd/llama-cuda-llama32-3b-chat.service`, `llama-cuda-qwen35-4b-pipeline.service`,
`llama-xe-minicpm5-1b-chat.service`), confirmed against the live processes. That is the
deliberate choice — thinking traces off for the served lanes.

A 2026-09-16 audit pass reported "no `--reasoning*` flag is passed" and was WRONG: its
grep covered `scripts/ bin/ tools/ .github/` and missed `systemd/`, which is where these
flags live. Read the units, not only the scripts.

12.2.8

🔍 Batch/ubatch sizes tuned

grep -nE '\-\-batch-size|\-b |\-ub ' <file>

Batch and ubatch sizes documented relative to available VRAM; default of 2048/512 noted

12.2.9

🔍 Context size (--ctx-size / -c) validated

grep -nE '\-c [0-9]|\-\-ctx-size' <file>

Context size doesn't exceed model's training context; VRAM impact documented

12.2.10

🔍 Concurrency is expressed through --parallel, not --cont-batching

`grep -rn 'cont-batching' scripts/ bin/ tools/ .github/` → expect ZERO

`--cont-batching` is never passed (measured 2026-09-16: zero occurrences) and is not
wanted. Concurrency is configured per row through the registry's `parallel` column, and
`11e-llm-model.sh` PINS it to 1 with a loud warning, because `kv_unified` is off by
default: `--parallel N` DIVIDES the served window by N, so a row would serve `ctx/N` per
request while advertising `ctx` (21504 → 1344). Real concurrency must set the window
explicitly with `--kv-unified-per-slot`, never derive it.

The governing decision is one LLM per card with one full window, so this item's original
expectation described a flag the design does not need.

12.3 Health & Monitoring

#

Check

Command

Expected

12.3.1

🔍 Health endpoint polled correctly

grep -n '/health' <file>

Uses /health endpoint (not /v1/models) for liveness checks; checks HTTP 200 AND JSON status field

12.3.2

🔍 Health check is time-bounded

`grep -rn '/health' scripts/*.sh bin/* | grep -c connect-timeout` → 0, and that is correct

Every `/health` curl carries `--max-time` (2-5s) and NONE carries `--connect-timeout`
(measured 2026-09-16: zero). That is right rather than a gap: the probes target
`127.0.0.1`, where a TCP connect cannot hang — there is no network to wait on — so
`--max-time` alone bounds the call, which is the property this item is about.
`--connect-timeout` is used everywhere it matters, on the outbound calls (`08-maintenance`,
`09e-oc-health`, `09f-oc-misc`, `11e-llm-model`, `tools/install-shellcheck`).

The old wording required BOTH flags on health calls, which no amount of diligence would
have produced, because the second one had nothing to do.

12.3.3

🔍 Slot counts are NOT used for saturation (item WITHDRAWN)

Inspect health response parsing

Nothing parses `slots_idle` or `slots_processing`, and this item was withdrawn rather
than met. Measured 2026-09-16: zero occurrences of either name; the only slot-related code
is a 5s-TTL cached `GET /slots` used for display (`07-telemetry.sh`).

The reason is the one that demoted the dxgkrnl counter (item §18, card WSL-GATE-001): a
probe is only worth acting on when its threshold has a measured baseline behind it, and
there is none for slot saturation on this box. Saturation is judged by what the repo
already measures — TPS collapse and the health status code (200 ok / 503 loading / down),
which `docs/llm.md` argues for explicitly.

Adding the parse without that baseline would create a signal nobody can calibrate, which
is exactly how the counter it replaced became a gate that stopped healthy lanes.

12.3.4

🔍 TPS (tokens per second) tracking valid

Inspect TPS parsing

TPS extracted from streaming response or /completion endpoint; validated as numeric before display

12.3.5

🔍 Watchdog restart is safe

Inspect watchdog script

Watchdog uses graceful shutdown (SIGTERM, then wait, then SIGKILL); doesn't corrupt in-flight requests

12.4 Model Management

#

Check

Command

Expected

12.4.1

🔍 GGUF file validation

Inspect model loading code

Model file existence and readability checked before passing to llama-server; file size sanity-checked

12.4.2

🔍 Model registry format documented

Inspect .registry or model config

Model metadata format (name, path, flags, context size) documented and validated on load

12.4.3

🔍 Quantization recommendations enforced

Inspect config/quant-guide.conf usage

config/quant-guide.conf consulted or referenced when selecting/recommending models; VRAM limits respected

12.4.4

🔍 --load-mode none available as fallback

Inspect model load error handling

If model loading hangs or fails, `--load-mode none` documented as a recovery option (the removed `--no-mmap` spelling is fatal on build 10955)

12.4.5

🔍 Model switch handles in-flight requests

Inspect model swap logic

Active connections drained or errored cleanly before server restart with new model

13. Cross-Script Consistency — Medium

Verify that constants, patterns, and conventions are consistent across all scripts in the repository. With the modular architecture, this includes consistency between the loader, the 16 profile modules in scripts/, standalone scripts in bin/, and companion files.

13.1 Shared Constants

#

Check

Command

Expected

13.1.1

🔍 LLM_PORT consistent

grep -rn 'LLM_PORT\|8081' scripts/ bin/ tactical-console.bashrc

Defined once in 01-constants.sh; every other file references the variable. Every
literal must agree on 8081 — a disagreement is the finding, not the existence of a
literal. The sanctioned sites are: `scripts/oc-health-check.py` (Python cannot source
the bash constants, so it carries the same default), `scripts/run-autotune-batch.sh`
(an `ss` grep pattern for the interactive port, not a bind), `${LLM_PORT:-8081}`
DEFAULT EXPRESSIONS (`scripts/spec-decode-bench.sh`, `scripts/09a-oc-gateway.sh` —
a fallback, not a second definition), and comment prose. Note that the autotune bench
binds `AUTOTUNE_PORT` (18082), never 8081. Measured 2026-09-16: 5 code sites, all
agreeing. (The old enumeration here listed three and called them exhaustive; it
missed the two fallbacks — an incomplete list reads as a finding when it is not.)

13.1.2

🔍 ACTIVE_LLM_FILE consistent

grep -rn '/dev/shm/active_llm' scripts/ bin/ tactical-console.bashrc

Zero matches outside `01-constants.sh` — the literal path appears in exactly one place, and the eleven modules that track the active model all go through `$ACTIVE_LLM_FILE`. Do NOT check `bin/llama-watchdog.sh` for this variable: since the lane units replaced the single managed server, the watchdog supervises unit states and no longer reads this file (it did when this check was written)

13.1.3

🔍 LLAMA_BIN path consistent

grep -rn 'LLAMA_BIN\|llama-server' scripts/ bin/ tactical-console.bashrc

`01-constants.sh` is the single source (`LLAMA_SERVER_BIN`, `LLAMA_CUDA_SERVER_BIN`, `LLAMA_XE_SERVER_BIN`). The two card launchers (`bin/llama-cuda-server`, `bin/llama-xe-server`) REPEAT the CUDA/Xe default deliberately — a lane start must not depend on the module tree — and `tests/unit/12-gpu-exclusivity.bats` asserts the launcher default and the constants agree, so a one-sided repoint fails the suite. Anything that hardcodes a third location is drift

13.1.4

🔍 Health endpoint URL consistent

grep -rn '/health\|/v1/models' scripts/ bin/ tactical-console.bashrc

Same health check URL and parsing logic used in modules and watchdog

13.1.5

🔍 /dev/shm paths consistent

grep -rn '/dev/shm/' scripts/ bin/ tactical-console.bashrc

Cache file paths match between scripts that write and read them

13.2 Error Handling Patterns

#

Check

Command

Expected

13.2.1

🔍 Error output format consistent

grep -rn 'echo.*error\|printf.*error' scripts/ bin/

Error messages use the same format/prefix across all scripts (e.g., [tac], [watchdog])

13.2.2

🔍 Exit codes consistent

Inspect exit/return patterns

Scripts use consistent exit codes: 0=success, 1=general error, 2=usage error

13.2.3

🔍 Logging approach consistent

Inspect log output patterns

All scripts log to the same mechanism (journald, file, stderr) or document why they differ

13.3 Convention Alignment

#

Check

Command

Expected

13.3.1

🔍 ShellCheck directives aligned

grep -rn 'shellcheck' scripts/ bin/ tactical-console.bashrc

Each module has `# shellcheck shell=bash` at line 1. Existing `disable=` codes are legacy debt: remove them and fix the cause (17.1). New files must not add any. No blanket disables covering unrelated issues.

13.3.2

🔍 Quoting conventions aligned

Inspect variable usage across files

All scripts quote variables consistently — no script uses bare $var while another uses "$var"

13.3.3

🔍 Function naming aligned

Inspect function names across files

If multiple scripts define similar functions, naming follows the same convention

13.3.4

🔍 Install script keeps symlinks current

Inspect install.sh

install.sh creates/updates symlinks for all scripts in bin/ and systemd/; no manual steps required

13.5 Non-Interactive Access (env.sh + tac-exec)

`env.sh` and `bin/tac-exec` provide non-interactive access to all profile
functions for AI agents, cron, and exec environments.

#

Check

Command

Expected

13.5.1

🔍 env.sh sources all profile modules except 13-init.sh

`grep -c 'continue' ~/ubuntu-console/env.sh`

Returns 2, and the count is not the signal. Line 153 is the documented
`case/continue` skip of `13-init.sh`; line 199 is a PID-validation `continue` inside
`__tac_env_cleanup_bg_pids`. What matters is that env.sh loads the 16 canonical
modules from `scripts/_module-list.sh` and skips ONLY `13-init.sh`. Note:
`14-wsl-extras.sh` has an interactive guard (`case $- in`) and returns early in
library mode, so its side-effects don’t run.

13.5.2

🔍 env.sh has idempotency guard

`grep '__TAC_ENV_LOADED' ~/ubuntu-console/env.sh`

Guard variable is checked at entry and set after first load.

13.5.3

🔍 tac-exec delegates via `"$@"`

`grep '"\$@"' ~/ubuntu-console/bin/tac-exec`

Arguments are passed through unmodified.

13.5.4

🔍 tac-exec is executable

`[[ -x ~/ubuntu-console/bin/tac-exec ]] && echo OK`

Prints `OK`.

13.5.5

🔍 end-of-file markers present

`for f in env.sh bin/tac-exec; do grep -v '^[[:space:]]*$' "$f" | tail -1 | grep -qi 'end of file' || echo "MISSING: $f"; done`

Both files end with `# end of file` as last non-blank line.

13.4 Module Versioning

#

Check

Command

Expected

13.4.1

🔍 All modules have version comment

for f in scripts/[0-9][0-9]-*.sh; do grep -q '^# Module Version:' "$f" || echo "MISSING: $f"; done

Zero output — every module contains a `# Module Version: N` comment in its header block.

13.4.2

🔍 All modules have AI instruction

for f in scripts/[0-9][0-9]-*.sh; do grep -q 'AI INSTRUCTION' "$f" || echo "MISSING: $f"; done

Zero output — every module contains the AI instruction to bump its Module Version on any change

13.4.3

🔍 Module version comments all present

grep -h '^# Module Version:' scripts/[0-9][0-9]-*.sh scripts/09b-gog.sh | sort -t: -k3 -n

One `# Module Version: N` line per module, with a plain integer N. The command's glob
also matches `scripts/18-lint.sh` — a standalone utility, NOT a profile module (env.sh
lists only the 16 held in `scripts/_module-list.sh`) — so it prints 17 lines, not 16.
Count the canonical modules from `_module-list.sh`, not from the glob. Measured
2026-09-16: 17 lines, 16 of them canonical.

13.4.4

🔍 Profile version reflects module versions

Inspect TACTICAL_PROFILE_VERSION composition

`TACTICAL_PROFILE_VERSION` is `<loader version>.<sum of all module versions>`; its sum component changes automatically whenever any module version is incremented, so no manual cross-check between it and individual module versions is required.

13.4.5

🔍 Module headers follow standard format

head -8 scripts/[0-9][0-9]-*.sh

Each module starts with `# shellcheck shell=bash`, a `# ─── Module: <name>` (or
`# --- Module:`) divider, a 3-line AI instruction block and the version line.

The shellcheck disable line is NOT part of the standard: it belongs only to files
that still need one, and most file-wide disables were removed on 2026-09-15/16. The
cross-module SC2034/SC2154 class is now resolved by analysing the module graph in
`tools/lint.sh`, so a module no longer needs a disable to describe an interface its
consumers use. Never "fix" a module by ADDING a disable to match this item. Measured
2026-09-16: 6 of 17 files carry no file-wide disable, deliberately.

15. AI Agent Access — High

AI agents (OpenClaw, Copilot, etc.) run commands via exec in non-interactive
shells. The interactive bashrc guard (`case $-`) blocks these shells from
loading the profile, leaving ~100+ functions invisible. This section audits
the `env.sh` library loader and `tac-exec` wrapper that bridge this gap.

Background: The profile's interactive guard exists to protect sftp/rsync/scp
from side-effects. But AI agents need the function library without the
interactive side-effects (screen clear, prompt, completions, WSL loopback).
The solution is a two-layer architecture:

- `env.sh` — Sources modules 01-12 (skips 13-init). No interactive guard.
  Idempotent (guarded by `__TAC_ENV_LOADED`). Sets `TAC_LIBRARY_MODE=1`.
- `bin/tac-exec` — Sources `env.sh`, then runs `"$@"`. Symlinked to
  `~/.local/bin/tac-exec` (on PATH via `~/.profile` and `01-constants.sh`).

#

Check

Command / Action

Expected

15.1

🔍 env.sh exists and is sourced correctly

`bash -c 'source ~/ubuntu-console/env.sh && echo $__TAC_ENV_LOADED'`

Prints `1`. No errors on stderr.

15.2

🔍 env.sh loads all function-defining modules

`bash -c 'source ~/ubuntu-console/env.sh && type oc && type so && type model && type tactical_dashboard && type serve && type halt && type commit_auto && type __test_port' >/dev/null 2>&1 && echo OK`

Prints `OK`. Every user-facing function from modules 01-12 is available.

15.3

🔍 env.sh skips 13-init.sh

`bash -c 'source ~/ubuntu-console/env.sh && echo ${__TAC_INITIALIZED:-unset}'`

Prints `unset`. The init module (clear screen, completions, loopback fix, EXIT trap) must not run in library mode.

15.4

🔍 env.sh is idempotent

`bash -c 'source ~/ubuntu-console/env.sh; source ~/ubuntu-console/env.sh && echo OK'`

Prints `OK`. No readonly variable collision errors. Second source is a no-op.

15.5

🔍 tac-exec is executable and on PATH

`ls -la ~/ubuntu-console/bin/tac-exec ~/.local/bin/tac-exec`

`bin/tac-exec` is `-rwxr-xr-x`. `~/.local/bin/tac-exec` is a symlink to it.

15.6

🔍 tac-exec runs functions in non-interactive shell

`bash -c '~/ubuntu-console/bin/tac-exec oc 2>&1 | head -5'`

Prints the `oc` help reference (subcommand list). Not `command not found`.

15.7

🔍 tac-exec propagates arguments correctly

`bash -c '~/ubuntu-console/bin/tac-exec model list 2>&1 | head -3'`

Prints the model registry table header. Multi-word arguments are preserved.

15.8

🔍 tac-exec with no arguments shows usage

`bash -c '~/ubuntu-console/bin/tac-exec 2>&1'`

Prints usage message. Exits non-zero.

15.9

🔍 ~/.local/bin wrappers delegate to tac-exec

`for f in so xo serve oc-backup oc-model-list oc-model-stop; do grep -q tac-exec ~/.local/bin/$f && echo "$f: OK" || echo "$f: FAIL"; done`

All wrappers print `OK`. None contain re-implemented logic — they must delegate via `exec ~/ubuntu-console/bin/tac-exec`.

15.10

🔍 No standalone function extractions in ~/.local/bin

`for f in ~/.local/bin/{so,xo,serve,oc-backup,oc-model-*,oc-wake,oc-gpu-status,oc-quick-diag}; do lines=$(wc -l < "$f" 2>/dev/null); (( lines > 6 )) && echo "WARN: $f has $lines lines (should be ≤6)"; done`

No warnings. All wrapper scripts must be ≤ 6 lines (shebang, comment, exec line, end-of-file comment). Anything larger suggests an extracted copy that should be replaced with a tac-exec delegation.

15.11

🔍 OpenClaw TOOLS.md documents tac-exec

`grep -c 'tac-exec' ~/.openclaw/workspace/TOOLS.md`

Returns ≥ 5. TOOLS.md must contain: usage examples, the "do not extract" instruction, and the full-path fallback.

15.12

🔍 env.sh does not leak interactive side-effects

`bash -c 'source ~/ubuntu-console/env.sh; [[ -z "$PROMPT_COMMAND" ]] && echo OK || echo "LEAK: PROMPT_COMMAND is set"'`

Prints `OK`. PROMPT_COMMAND, PS1 customisations, and DEBUG traps from hooks (§6) should not fire in library mode. If they do, the hooks module needs a `TAC_LIBRARY_MODE` guard.

15.13

🔍 env.sh does not run slow startup operations

`time bash -c 'source ~/ubuntu-console/env.sh' 2>&1 | grep real`

real < 1.0s. env.sh must not call `pwsh.exe` (API key bridge), `sudo` (loopback), or `clear` (screen). Those belong in 13-init only.

15.14

🔧 No mcp-tools/ directory present

`[[ -d ~/ubuntu-console/mcp-tools ]] && echo "FAIL: mcp-tools/ still exists" || echo "OK: removed"`

Prints `OK: removed`. The mcp-tools directory was superseded by tac-exec and should not be recreated. If it exists, it contains stale duplicates.

15.15

🔍 TAC_LIBRARY_MODE is exported

`bash -c 'source ~/ubuntu-console/env.sh && env | grep TAC_LIBRARY_MODE'`

Prints `TAC_LIBRARY_MODE=1`. Functions that need to detect library mode (e.g., to skip UI output) can check this variable.

15.16

🔍 Minimal-PATH fallback works

`env -i HOME="$HOME" PATH="/usr/local/bin:/usr/bin:/bin" bash -c '~/ubuntu-console/bin/tac-exec oc 2>&1 | head -3'`

Prints the `oc` help header. Even without `~/.local/bin` on PATH, the full path to tac-exec must work. TOOLS.md should document this fallback.

16. Final Validation

#

Check

Command

Expected

16.1

🔍 bash -n passes on all files

bash -n tactical-console.bashrc && for f in scripts/[0-9][0-9]-*.sh bin/*.sh; do bash -n "$f"; done

Exit 0 for the loader and all 16 profile modules plus bin/ scripts

16.2

🔍 ShellCheck passes

shellcheck tactical-console.bashrc scripts/[0-9][0-9]-*.sh

Zero findings. Suppression directives are not a fix — see 17.1: remove the directive and fix the cause.

16.3

🔍 Sourcing works

bash -ic 'source ~/ubuntu-console/tactical-console.bashrc; exit'

Exit 0 — loader sources all 16 profile modules without error

16.4

🔍 No regressions in key functions

Manually test 3-5 core commands (e.g., model, m, h, oc)

Commands produce expected output; no errors on stderr

16.5

🔍 Watchdog timer fires correctly

systemctl --user status llama-watchdog.timer

Timer is active and last trigger time is recent

16.6

🔍 Clean environment source test

env -i HOME="$HOME" bash --noprofile --norc -c 'source ~/ubuntu-console/tactical-console.bashrc'

Sourcing in a minimal environment doesn't fail due to missing dependencies

16.7

🔍 BATS test suite passes

bats tests/tactical-console.bats

All BATS tests pass (0 failures). Verify count matches `grep -c '^@test' tests/tactical-console.bats`. Tests cover syntax, shellcheck, structure, constants, function availability, cross-script consistency, and code hygiene (EOF markers, line length, whitespace, carriage returns).

16.8

🔍 Module count matches expectations

ls scripts/[0-9][0-9]-*.sh | wc -l

16 files match the numbered glob — 15 profile modules (01-15) plus the `18-lint.sh` utility — and `scripts/_module-list.sh` lists 16 profile modules (01-15 + 09b-gog). If a module is added or removed, update `scripts/_module-list.sh` (the shared list) and the drift-guard BATS test; `tools/docs-sync-check.sh` derives the count from that list, and README.md must be updated with it.

16.9

🔍 Audit findings logged

Review audit todo list

All findings from this inspection documented with severity, location, and remediation plan

17. New Insights & Standards (2026-09-12)

#

Check

Command

Expected

17.1

🔧 No suppression comments anywhere

`grep -rnE '# *noqa|# *type: *ignore|shellcheck disable=SC' scripts/ bin/ tools/ tests/ tactical-console.bashrc env.sh`

No new suppressions — fix the cause instead. A suppression is only acceptable for genuinely third-party, unpatchable output: one narrowly scoped filter, owned, with a comment naming the emitting package and `file:line` plus the tracking path. Never for our own code. Residue cleared (2026-09-12): the `scripts/` path insert now lives in `tests/_paths.py`, and the three `# noqa: E402` suppressions in `tests/test_kgraph.py`, `tests/test_kgraph_wiring.py` and `tests/test_untested_modules.py` are gone (standalone `python tests/x.py` runs still work).

Re-measured 2026-09-18 with this item's own command: **20 directive lines across 13 files**
(25 at the start of that day — this item's own two cause-fixes removed two, and three more went
as redundant), down from 68, and **0** in the `noqa` / `type: ignore` class. Every remaining line's code is structural rather than noise — SC1090/SC1091 (computed source paths: the loaders' own module loop, the optional files they source, the tests' run-time generated copies), SC2016 (single-quoted pwsh payloads that must reach Windows unexpanded), SC2317/SC2329 (functions referenced only from quoted trap strings; quoting the trap instead changes when bash expands it, so that fix is not available), SC2034 (version headers read by people and by `tools/check-module-versions.sh`), SC2086/SC2188/SC2221/SC2222. Two causes were FIXED rather than suppressed on 2026-09-18: `__bench_cleanup`'s `return $_exit_code` is now quoted (SC2086), and the bench status line's `$(<file || echo unknown)` — which never ran its fallback, because bash's `$(<file)` takes no trailing command — became a plain assignment (SC2188). Both directives are gone and `tools/lint.sh` stays green.

**Control for this count, because a looser grep over-counts.** Several module headers *document* a removed file-wide disable ("relying on a file-wide `disable=SC2154` (removed 2026-09-15)") without carrying one, so an unanchored `grep -rhoE 'disable=SC[0-9]+'` reports 35 where this item's command reports 20. Use the command above, and never write a comment that reproduces the directive text verbatim — it becomes a phantom hit for every grep-based audit, including this one — and never let a prose line *begin* with the word `shellcheck`, because the directive parser reads it as a malformed directive and fails the file (measured 2026-09-18: one such comment cost a full lint cycle with SC1073/SC1072).

17.2

🔧 Both loaders read one shared module list

grep -l '_module-list\.sh' env.sh tactical-console.bashrc; tools/docs-sync-check.sh

Both loaders source `scripts/_module-list.sh` (via `__tac_module_list`), and docs-sync-check exits 0 with the module count derived from that list. Interactive and library shells must expose the same module functions; the profile adds only 13-init's completion/direnv machinery.

17.3

🔧 Loaders never hardcode or glob the module set

! grep -q '_tac_expected_modules=(' tactical-console.bashrc; ! grep -q '\[0-9\]\[0-9\]-\*\.sh' env.sh

No hardcoded array and no module glob in either loader — add modules to `scripts/_module-list.sh` only. A numbered module missing from the list fails the drift-guard BATS test.

17.4

🔧 Never exec inside a shell function

grep -rnE '^[[:space:]]*exec [^0-9{]' scripts/*.sh tactical-console.bashrc

None. `exec` in a function dispatched by the interactive shell replaces (and on exit kills) the user's shell — this was oc-update's bug. Use a plain call and `return $?`. `exec {fd}>file` redirections and standalone wrappers under `bin/` are fine.

17.5

🔧 Health probes match the JSON/HTTP status

grep -rn "grep -q 'ok'" scripts/ bin/

None. A bare `ok` substring also matches "token"/"blocked". Match `"status":"ok"` or use the HTTP status code (llama-watchdog's `health()` returns 0 ok / 1 down / 2 still-loading).

17.6

🔧 A loading (503) server is never struck or restarted

inspect the lanes in bin/llama-watchdog.sh

`health()` returning 2 must skip both the strike increment and the restart — bouncing a unit that is still loading only lengthens the outage (and can trip the start-limit).

17.7

🔧 Anchor every alternative in path-safety regexes

grep -rn '=~ \^/' scripts/

Group and anchor: `=~ ^(/home|/tmp|/dev/shm)`. In an unanchored alternation only the first branch is anchored, so `/etc/tmp` would pass an `rm -rf` guard.

17.8

🔧 Never append a fallback echo to grep -c

grep -rn 'grep -c .*|| echo' scripts/ bin/ tools/

None. `grep -c` already prints 0 on no match; `|| echo 0` yields "0\n0" and breaks the following arithmetic.

17.9

🔍 Registry schema field numbers are contractual

compare column consumers against the header in scripts/11e-llm-model.sh

Consumers use the documented field numbers (tps = 17, mmap_mode = 15, …). Rows whose field count is unexpected are preserved verbatim by `__llm_registry_sync_state`, never silently dropped.

17.10

🔧 The kgraph write path validates before it writes

POST probes against /graph.json

Requires `Content-Type: application/json`; rejects cross-origin Origins and POST preflights; no wildcard CORS on write responses; enforces `MAX_PAYLOAD_SIZE` before reading the body; runs `validate_graph_payload` before `save_to_graph_db`, so no malformed or hostile body can wipe the graph.

17.11

🔧 Generated HTML escapes interpolated data

inspect scripts/kgraph/pr_dashboard.py, call_flow.py, html.py

Every interpolated value passes through `html.escape()`; JSON embedded in a `<script>` element escapes `<`, `>` and `&`, so a `</script>` in a label cannot break out.

17.12

🔍 BATS serialisation lock tolerates contention

inspect tests/conftest.py; hold the lock externally for >2 min, then run one bridge test

The wait is bounded by the BATS file's own timeout (never a fixed 120s cap), and stale detection is PID + process start-time aware so a recycled PID is not mistaken for a live holder. A legitimate holder must produce a wait, not an `ERROR at setup`.

17.13

🔧 Extracted bash helpers document dynamic-scope dependencies

inspect helpers called from functions (e.g. `__cl_step` in 08-maintenance.sh)

A helper that reads or mutates the caller's locals (`yes_mode`, `deep_count`) must say so in its doc block — bash dynamic scope makes it work but leaves it invisible otherwise.

17.14

🔍 Shared fragments use the `_` prefix

ls scripts/_*.sh

`_startup-env.sh` and `_module-list.sh` are skipped by the module globs, the hygiene checks and the docs-sync module count. A new shared fragment must use the prefix.

17.15

🔧 Bench runs abort after 2 consecutive errors

inspect the bench loops (autotune-model.sh, spec-decode benches)

A bench stops after 2 consecutive case *errors* (exception, timeout, empty generation) and diagnoses rather than grinding through the whole set; a merely wrong verdict is data, not a failure.

17.16

🔍 Graph and wiring health

PYTHONPATH=scripts python3 -m kgraph --update --repo .; PYTHONPATH=scripts python3 -m kgraph --wiring --repo .

The update completes with a node/edge count, and wiring reports 0 orphans, 0 broken internal imports, 0 weak-wiring-only-from-tests, 0 unused facades, 0 cross-file call gaps.

18. Field Notes — the 2026-09-16 pass

Read this before starting the next pass: what the checklist itself got wrong, what
is deliberately not worth fixing, and what was still open when this pass ended.

18.1 Checks corrected as a result

  5.4   the command was a BRE (in which `|` is literal) and could never match
        anything; replaced, and the UI-engine's stdout rendering exempted
  5.8   the literal remedy (`|| exit`) is harmful where the continuation is
        load-bearing; the requirement is now "neither silent nor fatal"
  5.9   scope narrowed to standalone scripts — pipefail in a sourced module leaks
        into the user's interactive shell; `${PIPESTATUS[0]}` is the module idiom
  6.2   the command had a literal newline inside its character class and the item
        had no expected outcome at all; both supplied
  6.3   the command matched `(( ))` arithmetic; `[^(]` makes it discriminating
  7.4   both acceptable guard forms stated, ranked — an availability probe on the
        binary is legitimate, not a lesser substitute

18.2 Findings from that pass — re-derived 2026-09-18 (one was stale, one fixed, one wrong)

- `scripts/spec-decode-bench.sh` HAD no consecutive-error abort (item 17.15) — **FIXED since
    this note was written.** Re-derived 2026-09-18: the bench carries
    `MAX_CONSECUTIVE_ERRORS=2` (line 56), a `--max-consecutive-errors N` flag (line 61) and
    enforcement at line 144, so a curl timeout or an empty generation still scores a zero, but
    the run stops after two in a row instead of grinding through every remaining prompt.
    `autotune-model.sh`'s `CUDA_DEGRADE_CONSECUTIVE_STALLS` remains a *different* signal
    (health-never-ready stalls). Item 17.15 is therefore satisfied, and this entry is the
    worked example of why a pass must re-derive rather than trust its own notes.
- Suppression residue (item 17.1): re-derived 2026-09-18 as **25 directive lines across 14
    files** — this line said 68 across 36 — and zero `# noqa` / `# type: ignore`. Item 17.1
    now carries the per-class breakdown, the two causes fixed on 2026-09-18 (SC2086, SC2188),
    and the control that makes the count reproducible: an unanchored grep reports 35, because
    several module headers *document* a removed file-wide disable without carrying one. The
    SC2154 half of this note is obsolete — those file-wide disables were removed on
    2026-09-15 in favour of each module declaring the globals it consumes. Still true and
    still the reason the loader cannot be linted alone: `tools/lint.sh` lints each
    file as its own entry, so a module's interface looks unused to itself, and `env.sh`'s
    module loop is `source "$_tac_lib_f"`, which shellcheck cannot follow.
- Item 7.4: this line said "only one call site actually detects WSL (`09f-oc-misc.sh:157`)".
    Re-derived 2026-09-18: there are **three** `/proc/version` greps — `09f-oc-misc.sh:157`,
    `11e-llm-model.sh:1038`, `14-wsl-extras.sh:133` — plus `12-dashboard-help.sh:204` reading
    `$WSL_DISTRO_NAME`. The item's corrected text already accepts env-var and
    `command -v pwsh.exe` probes, so the conclusion ("no call site needs changing") stands,
    but the count in this line was wrong.

18.3 Migration backlog — count it, do not fix it during a correctness pass

  Five items are repo-wide style migrations rather than defects. They were
  deliberately not actioned in the 2026-09-16 pass, because the churn would have
  buried the findings that mattered. Baselines, measured that day:

    6.1   sed/awk/grep on non-comment lines ....................... 230
    6.4   `while read` where `mapfile -t` applies ................... 6
    6.7   single-bracket `[ ]` ..................................... 20
    6.8   `[[ n -gt m ]]` where `(( ))` applies ................... 245
    6.9   `echo "$var" | cmd` where `<<<` applies .................. 78
    8.1.5 if/then/fi compressed onto one line ...................... 48
    8.1.6 for/while/done compressed onto one line ................... 9
    8.1.7 lines carrying both `&&` and `||` ....................... 143
    8.1.8 lines over 120 characters (longest 513) ................. 240
    8.2.2 `readonly` names not in ALL_CAPS ......................... 10
    8.2.4 distinct section-divider forms ........................... 10
    9.1   files carrying an Author / Purpose / Date header ....... 1 / 9 / 14
    9.3   Bash-specific constructs with no explanatory comment:
          `printf -v` 36/0, process substitution 43/2, `mapfile` 13/1,
          indirect `${!` 14/0, `set -a` 2/0  (total/commented)
    9.5   functions with no comment above them ..................... 67
    9.7   non-0/1 exit codes with no explanation ................... 34
    9.8   functions setting a global with no note .................. 30
    10.2  non-comment lines holding a 4+-digit literal ............ 202
    10.5  functions nested deeper than 4 levels .................... 43
    10.7  ad-hoc `echo/printf … >&2` rather than a helper ......... 125
    10.4  functions over 100 lines ................................. 21
    4.2.1 `cmd && success || failure` lines ........................ 41
    4.2.2 lines chaining commands with `;` ........................ 262
    4.2.4 `case` blocks with no `*)` and no comment ............. 9 of 94
    4.2.5 same-line `if …; then` headers (idiomatic, not a defect) 576
    4.2.6 one-line `for/do/done` loops .............................. 8
    4.2.8 nested functions with no dynamic-scope note ............ 18 of 20
    4.3.6 mixedCase `local` names .................................. 20

  RE-DERIVED 2026-09-18 — 6.4, 6.6, 6.8, 6.9, 6.11, 6.13. Four of these six items carried no command
  at all ("Inspect …" stood in the Command cell), and the two that had one were both defective in
  opposite directions: 6.4's missed every `while IFS= read`, 6.9's counted any line with an `echo`
  anywhere before a `|`. That is why successive passes produced different numbers for an unchanged
  tree. Each item now carries a command with controls, and the figures below are that command's
  output at `f7403d24`:

    6.4   75 `while`-`read` sites — 46 whole-line, 29 splitting fields — of which 41 are real
          `mapfile` candidates (the table's 6 was the bare `while read` spelling only). All 41
          were read on 2026-09-18 and none ingests a large input, so the item reads as satisfied
          — see 6.4 for the sizes and the two streaming sites that must not change
    6.6   63 forking-tool calls inside a `do…done` body (was: no command). Read 2026-09-18: none
          is hoistable and 10 were in-loop `basename`s, now converted — see 6.6
    6.8   232 `[[ … ]]` arithmetic comparisons, comments excluded. Read 2026-09-18: no action —
          both forms are builtins that behave identically, so there is nothing to save (see 6.8)
    6.9   89 `echo … | cmd` sites. The item's own command returns 179 and the table's 78 is
          reproducible under no scope of it at either revision — see 6.9 for the breakdown
    6.11  23 `mktemp` sites, comments excluded — 27 for the bare `grep -n mktemp` (was: no command)
    6.13  100 lookup call sites, but only 23 (file, lookup) pairs repeated within one file (was: no command)

  ACTIONED, not backlogged — 4.3.4's dead code. `__llm_median_from_list` and
  `__llm_stddev_from_list` had no caller anywhere in the tree and neither is in
  11b's `@exports`; only a tautological existence assertion kept them alive. Both
  were removed, with that assertion, on 2026-09-16. The pass named only the stddev
  one — its median sibling had the same problem and the same single reference.

  The §8–§10 figures come from that pass's own parsers and it flagged 8.2.3, 9.5,
  9.6, 9.8, 10.1, 10.4 and 10.5 as approximations; treat them as a starting count,
  not a verdict. The §3–§4 figures are direct counts (grep/parse), except 4.2.4,
  which that pass read a block at a time.

  TWO ITEMS ARE STANDARDS DECISIONS, NOT MIGRATIONS:

    * 8.2.1 asks for `name() {` while the repo is 301 `function name` to 84 `name()`
      — the majority uses the style the item does not prefer, and no file mixes them.
    * 4.3.8 asks counters to use `declare -i`; the repo uses ZERO of them anywhere and
      writes `local count=0; (( count++ ))` throughout.

  For both, either the item changes to match the code or a migration is decided on
  purpose. Neither should be silently "fixed" a file at a time.

  This belongs in a ratchet — a guard that fails when the count RISES — not in a
  per-pass to-do list. A number with no owner and no enforcement only grows.

18.4 Checks this pass added

- 1.13 — host shell integrity. `/usr/bin/bash` may not be the packaged bash.
- 7.1 — a machine-specific absolute interpreter path in a tracked file now needs a
    stated reason; `#!/usr/bin/env bash` is the default. The two benches carrying
    `#!/home/linuxbrew/.linuxbrew/bin/bash` were switched on 2026-09-16: nothing in
    them needs more than 5.2, and every caller runs `bash <script>`, so the shebang
    was never read in the first place.

18.5 The host shell substitution, made deliberate (2026-09-16)

Found by this pass and fixed the same day. `/usr/bin/bash` and `/bin/bash` were
symlinks to Homebrew's bash 5.3.9 while dpkg still owned `bash 5.2.21-2ubuntu4`, and
`dpkg --verify bash` reported the packaged file as MODIFIED. The arrangement worked,
but nothing announced it: any `apt upgrade bash` would have restored the packaged
binary and changed the interpreter under the console, its hooks, kgraph and the
benches — a 5.3.9 → 5.2.21 change the console tolerates, which is exactly why nobody
would have noticed it happening.

Wayne chose to keep Homebrew bash as the system shell and make it durable, so it is
now a registered dpkg diversion (`of /usr/bin/bash to /usr/bin/bash.distrib`), which
is the mechanism dpkg provides for deliberately replacing a packaged file. Verified
by reinstalling the package twice: the symlink survives and the diversion keeps the
packaged binary available as a real, runnable fallback.

The one genuine cost, recorded here because dpkg warns about exactly this: apt's bash
security updates now land in `/usr/bin/bash.distrib` and are NOT in effect — the box
runs Homebrew's newer bash instead. That is a deliberate trade, and 1.13 is the check
that keeps it from becoming silent: it fails if the symlink dangles or if `.distrib`
becomes newer than the running interpreter. Revert is one command, recorded in 1.13.
If a second machine ever needs this, the three commands belong in `install.sh`
alongside its other host steps rather than in a runbook.

18.6 §11–§12: items whose expectation does not match the product

Two items were simply corrected in the document on 2026-09-16 (11.1 and 11.9 — see
their text for the CI flag drift and the stale pass-count). The rest below were
DECISIONS, because the honest options are "build the missing thing" or "change what
the checklist asks", and neither is a doc edit. Each has its measured evidence.

RE-CHECKED 2026-09-16 (late): most of this list had already been settled IN ITS ITEM
while the summary below kept describing it as open. Only ONE entry is still real work —
11.5, the suppression migration. The others are kept here with what actually happened,
because a stale summary reads exactly like an open decision.

- 12.2.3 — SETTLED as a design choice (item updated 2026-09-16), with one
    correction: the FLAGS DO EXIST in this build — `-cmoe/--cpu-moe`,
    `-ncmoe/--n-cpu-moe` and `-ot/--override-tensor` are all in `llama-server --help`
    (verified 2026-09-16). What is true is that the repo passes none of them and
    handles MoE by LAYER COUNT instead. "No flag exists" was wrong; "no flag is
    passed, deliberately" is the claim the item defends.
- 12.2.7 — CORRECTED, not decided: the flag the item named (`--reasoning-budget`)
    does not exist in this build, and ``--reasoning off`` IS passed — in the systemd
    units, which that pass's grep did not cover. See the item. No measurement is
    outstanding here.
- 12.2.10 — SETTLED as deliberate (item updated 2026-09-16). `--cont-batching` is
    never passed and is not wanted: the build's `-cb` default IS "enabled", but
    `--parallel` is pinned to 1, so there is one slot and batching has nothing to
    batch. Raising `--parallel` would divide the served window (`ctx/N`) unless
    `--kv-unified-per-slot` sets it explicitly.
- 12.3.3 — WITHDRAWN in the item itself: no measured baseline for slot saturation
    exists on this box, and saturation is already judged by TPS collapse plus the
    health status code. Adding the parse would create a signal nobody can calibrate.
- 12.4.1 — DONE (8c4216ff), and this bullet was stale in BOTH directions. The check
    landed in `11e-llm-model.sh` ("Readability, not just existence … the last gate
    before launch") while an earlier pass recorded it as open, and the pass that
    re-checked this list then repeated it as open WITHOUT READING THE CODE — which is
    precisely the failure this section exists to catch. What it did not have is a test;
    that gap is closed in `tests/tactical-console-fast.bats`.
- 11.7 — RESOLVED 2026-09-16 (c16bec50): `tests/tactical-console-fast.bats` now
    sources the loader under `env -i` and asserts the half with teeth — `env.sh`
    defines the interface. The item records why "it exits 0" alone was a green that
    could not go red.
- 11.14 — RESOLVED 2026-09-16 (49507347): the three copies are one. The config
    absorbed `models.py`'s divergent keys plus `stopwords`; `constants.py` owns the
    loader and the three modules import it. See the item.
- 11.6 — ADDRESSED 2026-09-16: the two kgraph hooks now prefer this repo's OWN
    `kgraph` through `.venv/bin/python3` and warn loudly when they fall back to the
    PATH install, so the silent no-op under a system Python is gone (verified in
    `tools/hooks/post-commit` and `post-merge`). Remaining nit: neither sets
    `set -uo pipefail`. NOTE: this bullet's subject does not match §11.6's own text,
    which is about the CI-on-commit hook — the numbering needs checking.
- 12.2.8 — FIXED in docs/llm.md, which now records the measured split rather than a
    fixed pair: "There is NO fixed GPU/CPU pair — measured across the 27 live rows on
    2026-09-16: 1024 ×14, 512 ×7, 2048 ×6", and that the old "4096 (GPU)" figure was
    a stale copy of the bench's candidate ladder.

  11.5 remains the other open item, and it is a documentation migration rather than a
  decision: 46 `# shellcheck disable=` lines exist (16 shell, 30 `.bats`; recounted
  2026-09-16 — the shell count has fallen from 20 as file-wide disables were removed)
  and 41 of the 46 end the line stating no reason — the 30 `.bats` ones are all bare
  `disable=SC1090`. Fix the cause where a fix exists (a `# shellcheck source=` directive
  resolves SC1090 rather than muting it), remove what the module graph made
  unnecessary, and see §18.3: this belongs in a RATCHET that fails when the count
  rises, not in a per-pass to-do list.

<!-- end of file -->
