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

4.2 Control Flow (Longhand Bash Enforced)

#

Check

Command

Expected

4.2.1

🔧 No golfed `&&



` logic

4.2.2

🔧 Multi-line statements

Inspect script

Avoid ; to chain commands on one line. Use newlines.

4.2.3

🔍 All case branches end with ;;

shellcheck catches this

No fall-through warnings

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

8.2 Declarations

#

Check

Command

Expected

8.2.1

🔍 Functions named consistently

grep -cE '^function |^[a-z_].*\(\)' <file>

Prefer func_name() { ... } style

8.2.2

🔍 Constants in UPPER_CASE

Inspect constant declarations

Read-only global constants in ALL_CAPS.

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

12. Final Validation

#

Check

Command

Expected

12.1

🔍 bash -n passes on all files

find . -name '*.sh' | xargs -I{} bash -n {}

Exit 0

12.2

🔍 ShellCheck passes

find . -name '*.sh' | xargs shellcheck -s bash

Zero findings

12.3

🔍 Sourcing works

bash -ic 'source <file>; exit'

Exit 0

<!-- # end of file -->