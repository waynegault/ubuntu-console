Bash Script Inspection, Improvement & Validation Audit

A comprehensive, repeatable checklist for auditing any Bash script or shell
profile. Derived from real-world production audits. Each item includes the
rationale, a concrete test command, and the expected outcome.

Usage: Work through each section top-to-bottom. Mark items [x] as you
go. Items marked 🔧 require code changes; items marked 🔍 are read-only checks.

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

Final Validation

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

grep 'VERSION=' <file>

$VERSION="x.x" exists near the top

1.3

🔧 Mandatory AI instruction

grep 'AI INSTRUCTION: Increment version' <file>

Exact comment # AI INSTRUCTION: Increment version on significant changes. sits directly above the version variable

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

#!/usr/bin/env bash or #!/bin/bash

1.7

🔍 Record baseline error count

shellcheck -s bash <file> 2>&1 | grep -c 'In '

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

tail -5 <file>

Contains "# end of file" as final non-blank line

1.12

🔍 Shellcheck directives documented

grep 'shellcheck disable' <file>

Each disabled rule has a rationale comment on the line above or same line

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

grep -nE 'curl.*|.*bash|wget.*|.*sh|curl.*|.*sh' <file>

Zero matches (comments OK)

2.1.2

🔧 No eval on untrusted input

grep -n '\beval\b' <file>

Zero matches, or each use verified safe

2.1.3

🔧 No source of untrusted paths

grep -n '\bsource\b|\. ' <file>

All source targets are trusted/validated

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

grep -nE 'tmp|temp' <file>

All temp files created via mktemp or atomic .tmp → mv

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

grep -n "case \$- in" <file>

Non-interactive shells exit early in profiles

3.2

🔧 No background daemons at source-time

grep -nE 'nohup|&$|disown' <file>

bg processes only inside explicit user-invoked functions

3.3

🔍 Strict Mode enabled

head -10 <file>

set -euo pipefail is present. For Bash 4.4+, shopt -s inherit_errexit is included

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

🔍 ShellCheck passes

shellcheck -s bash <file>

Zero findings (or all suppressed with rationale)

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

shellcheck SC2034

All declared variables used

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

🔧 Integer variables use declare -i where appropriate

Inspect arithmetic variables

Counter variables and numeric accumulators benefit from declare -i

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

grep -n 'echo.*error|printf.*error' <file>

Error output uses >&2

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

Inspect $(<file) and source calls

All file reads preceded by [[ -f "$file" ]] guard

5.8

🔧 cd failures handled

grep -n '\bcd\b' <file>

All cd calls use cd ... || return (or || exit) to prevent operating in wrong directory

5.9

🔍 Pipe failures detected

grep -n 'pipefail' <file>

Either set -o pipefail is active OR each pipe segment is explicitly checked

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

grep -nE 'echo.*|.*awk|echo.*|.*sed|echo.*|.*grep' <file>

Replaced with native Bash ${var//find/replace} or ${var#prefix}

6.2

🔧 No Useless Use of Cat (UUOC)

`grep -nE 'cat [^

]*|' `

6.3

🔧 No unnecessary subshells

grep -nE '^\s*\(' <file>

{ } grouping where subshell isn't needed

6.4

🔧 Optimize file reading

grep -n 'while read' <file>

mapfile -t used for array ingestion instead of while-loops

6.5

🔧 No external non-bash tooling

grep -nE '\bpython\b|\bperl\b|\bnode\b' <file>

Used strictly for templating/specialized tasks. Core logic stays native.

6.6

🔧 Avoid repeated forks in loops

Inspect for/while bodies

Loops that iterate >10× must not call date, grep, awk, cut inside the body; hoist or cache the result beforehand

6.7

🔧 String tests prefer [[ ]]

grep -nE '^\s*\[ ' <file>

Use [[ ]] instead of [ ] for string/regex tests — no word-splitting, supports pattern matching

6.8

🔧 Arithmetic tests prefer (( ))

Inspect numeric comparisons

Use (( n > 5 )) instead of [[ $n -gt 5 ]] for numeric comparisons

6.9

🔧 Here-strings over echo | pipe

grep -nE 'echo.*\|' <file>

Use <<< "$var" instead of echo "$var" | cmd where possible; avoids a fork

6.10

🔧 printf over echo -e

grep -n 'echo -e' <file>

printf is portable and unambiguous; echo -e behavior varies across shells

6.11

🔧 Process substitution over temp files

Inspect mktemp usage

Use <(cmd) or >(cmd) instead of writing to temp files when data is consumed once

6.12

🔧 Avoid du on drvfs mounts

grep -n '\bdu\b' <file>

du -sb on /mnt/c (drvfs) is extremely slow; use stat --printf='%s' or wc -c instead

6.13

🔧 Cache expensive lookups

Inspect repeated calls to same command

Results of command -v, uname, lsb_release, etc. called once and stored in a variable

7. Portability — Medium

#

Check

Command

Expected

7.1

🔍 Shebang is correct

head -1 <file>

#!/usr/bin/env bash

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

grep -nE '/mnt/[c-z]|wslpath|wsl\.exe|clip\.exe|pwsh\.exe' <file>

WSL interop calls wrapped in a WSL detection guard (e.g., [[ -n "${WSL_DISTRO_NAME:-}" ]])

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

grep -nE 'if .*;.*then|;.*fi$' <file>

if/then/else/fi each on their own line; no semicolons to compress

8.1.6

🔧 No compressed for/while/do on one line

grep -nE 'for .*;.*do|while .*;.*do|;.*done$' <file>

for/do/done and while/do/done each on their own line

8.1.7

🔧 && / || not used as if replacements

grep -nE '&&|\|\|' <file>

Avoid cmd && success || failure pattern; use explicit if/then/else for clarity

8.1.8

🔧 Long lines wrapped

awk 'length > 120' <file>

Lines under 120 characters; long strings broken with backslash continuation

8.1.9

🔧 Heredocs indented with tabs (<<-)

grep -n '<<[^-]' <file>

Indented heredocs use <<- with tab indentation for readability

8.2 Declarations

#

Check

Command

Expected

8.2.1

🔍 Functions named consistently

grep -cE '^function |^[a-z_].*\(\)' <file>

Prefer func_name() { ... } style; one style used throughout

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

🔧 Preparation for Modularisation

Scan for section headers

File uses prominent visual dividers (e.g., # === NETWORK FUNCTIONS ===) to group functions logically for easy extraction later.

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

🔧 Version changelog maintained

Inspect file header

A CHANGELOG section or external file tracks significant changes with dates

9.11

🔧 Design decisions documented

Inspect §0 or file header

Key architectural choices (monolithic design, /dev/shm caching, WSL interop strategy) documented for future maintainers

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

awk '/^[a-z_].*\(\)/{name=$1; start=NR} /^}/{if(NR-start>100) print name, NR-start}' <file>

Functions under 100 lines; longer functions have subsection comments or are candidates for splitting

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

Check scripts/lint.sh

bash -n + shellcheck executed automatically

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

Check .github/workflows/ or pre-commit hooks

Linting and bash -n run automatically before commits land

11.7

🔍 Integration test for source cycle

Check for test that sources bashrc

A test verifies that sourcing tactical-console.bashrc in a clean environment completes without error or hang

12. llama.cpp Integration — Medium

Audit llama-server CLI flags, model management, health monitoring, and inference configuration for correctness against current llama.cpp best practices.

12.1 Build & Version Currency

#

Check

Command

Expected

12.1.1

🔍 llama.cpp version tracked

Inspect LLAMA_VERSION or build metadata

Build version or commit hash stored/displayed so regressions can be traced to specific builds

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

🔍 --cpu-moe / -ot configured for MoE models

grep -nE '\-\-cpu-moe|\-ot' <file>

For Mixture-of-Experts models (Qwen3 MoE, Mixtral), expert layers offloaded to CPU with --cpu-moe or -ot exps=CPU

12.2.4

🔍 -ngl set appropriately

grep -n '\-ngl' <file>

GPU layers set to 999 (all) for small models; documented if partial offload is intentional for VRAM-constrained setups

12.2.5

🔍 --mlock used consciously

grep -n '\-\-mlock' <file>

--mlock present to prevent swapping; documented trade-off with system memory pressure

12.2.6

🔍 --no-context-shift considered

grep -n '\-\-no-context-shift' <file>

If present, documented why context shift is disabled (avoids silent truncation; forces explicit context management)

12.2.7

🔍 --reasoning-budget configured for thinking models

grep -n '\-\-reasoning-budget' <file>

Thinking models (Qwen3, QwQ) have explicit reasoning budget; -1 for unlimited documented

12.2.8

🔍 Batch/ubatch sizes tuned

grep -nE '\-\-batch-size|\-b |\-ub ' <file>

Batch and ubatch sizes documented relative to available VRAM; default of 2048/512 noted

12.2.9

🔍 Context size (--ctx-size / -c) validated

grep -nE '\-c [0-9]|\-\-ctx-size' <file>

Context size doesn't exceed model's training context; VRAM impact documented

12.2.10

🔍 --cont-batching enabled

grep -n '\-\-cont-batching' <file>

Continuous batching enabled for concurrent request handling

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

🔍 Health check has timeout

Inspect health polling code

curl calls to /health have --connect-timeout and --max-time to prevent blocking on hung server

12.3.3

🔍 Slot availability checked

Inspect health response parsing

Health response's slots_idle / slots_processing parsed to detect overloaded server

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

Inspect quant-guide.conf usage

quant-guide.conf consulted or referenced when selecting/recommending models; VRAM limits respected

12.4.4

🔍 --no-mmap available as fallback

Inspect model load error handling

If model loading hangs or fails, --no-mmap documented as a recovery option

12.4.5

🔍 Model switch handles in-flight requests

Inspect model swap logic

Active connections drained or errored cleanly before server restart with new model

13. Cross-Script Consistency — Medium

Verify that constants, patterns, and conventions are consistent across all scripts in the repository.

13.1 Shared Constants

#

Check

Command

Expected

13.1.1

🔍 LLM_PORT consistent

grep -rn 'LLM_PORT\|8081' *.sh *.bashrc

Port number defined in one place or sourced from a shared constant; not hardcoded differently in multiple files

13.1.2

🔍 ACTIVE_LLM_FILE consistent

grep -rn 'ACTIVE_LLM_FILE\|active_model' *.sh *.bashrc

File path identical across tactical-console.bashrc and llama-watchdog.sh

13.1.3

🔍 LLAMA_BIN path consistent

grep -rn 'LLAMA_BIN\|llama-server' *.sh *.bashrc

Binary path resolved identically; not hardcoded to different locations

13.1.4

🔍 Health endpoint URL consistent

grep -rn '/health\|/v1/models' *.sh *.bashrc

Same health check URL and parsing logic used in bashrc and watchdog

13.1.5

🔍 /dev/shm paths consistent

grep -rn '/dev/shm/' *.sh *.bashrc

Cache file paths match between scripts that write and read them

13.2 Error Handling Patterns

#

Check

Command

Expected

13.2.1

🔍 Error output format consistent

grep -rn 'echo.*error\|printf.*error' *.sh *.bashrc

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

grep -rn 'shellcheck' *.sh *.bashrc

Same SC codes disabled across files for the same reasons; no contradictory directives

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

14. Final Validation

#

Check

Command

Expected

14.1

🔍 bash -n passes on all files

find . -name '*.sh' -o -name '*.bashrc' | xargs -I{} bash -n {}

Exit 0

14.2

🔍 ShellCheck passes

find . -name '*.sh' | xargs shellcheck -s bash

Zero findings (or all remaining findings have documented disable directives)

14.3

🔍 Sourcing works

bash -ic 'source <file>; exit'

Exit 0

14.4

🔍 No regressions in key functions

Manually test 3-5 core commands (e.g., model, tac, oc)

Commands produce expected output; no errors on stderr

14.5

🔍 Watchdog timer fires correctly

systemctl --user status llama-watchdog.timer

Timer is active and last trigger time is recent

14.6

🔍 Clean environment source test

env -i HOME="$HOME" bash --noprofile --norc -c 'source <file>'

Sourcing in a minimal environment doesn't fail due to missing dependencies

14.7

🔍 Audit findings logged

Review audit todo list

All findings from this inspection documented with severity, location, and remediation plan

<!-- # end of file -->