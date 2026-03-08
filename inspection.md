# Bash Script Inspection, Improvement & Validation Audit

> A comprehensive, repeatable checklist for auditing any Bash script or shell
> profile. Derived from real-world production audits. Each item includes the
> rationale, a concrete test command, and the expected outcome.
>
> **Usage:** Work through each section top-to-bottom. Mark items `[x]` as you
> go. Items marked 🔧 require code changes; items marked 🔍 are read-only checks.

---

## Table of Contents

1. [Pre-Flight](#1-pre-flight)
2. [Security — Critical](#2-security--critical)
3. [Safety — Critical](#3-safety--critical)
4. [Correctness — High](#4-correctness--high)
5. [Robustness — High](#5-robustness--high)
6. [Efficiency & Performance — Medium](#6-efficiency--performance--medium)
7. [Portability — Medium](#7-portability--medium)
8. [Style & Formatting — Medium](#8-style--formatting--medium)
9. [Documentation — Medium](#9-documentation--medium)
10. [Refactor & Maintainability — Low](#10-refactor--maintainability--low)
11. [Testing & CI — Low](#11-testing--ci--low)
12. [Final Validation](#12-final-validation)

---

## 1. Pre-Flight

Before making any changes, establish a baseline.

| # | Check | Command / Action | Expected |
|---|-------|-----------------|----------|
| 1.1 | 🔍 Record file line count | `wc -l <file>` | Note baseline |
| 1.2 | 🔍 Record current version | `grep -i 'version\|^# v[0-9]' <file> \| head -5` | Note version |
| 1.3 | 🔍 Ensure clean git state | `git status --short` | Working tree clean (or stash first) |
| 1.4 | 🔍 Create a checkpoint | `git stash` or `cp <file> <file>.bak` | Backup exists |
| 1.5 | 🔍 Identify target shell | `head -1 <file>` | `#!/usr/bin/env bash` or `#!/bin/bash` |
| 1.6 | 🔍 Identify target platform | Check README or file header | Note OS / distro constraints |

---

## 2. Security — Critical

These issues can lead to arbitrary code execution, data exfiltration, or
privilege escalation. Fix all findings before proceeding.

### 2.1 Remote Code Execution

| # | Check | Command | Expected |
|---|-------|---------|----------|
| 2.1.1 | 🔧 No `curl \| bash` / `wget \| sh` | `grep -nE 'curl.*\|.*bash\|wget.*\|.*sh\|curl.*\|.*sh' <file>` | Zero matches (comments OK) |
| 2.1.2 | 🔧 No `eval` on untrusted input | `grep -n '\beval\b' <file>` | Zero matches, or each use verified safe |
| 2.1.3 | 🔧 No `source` of untrusted paths | `grep -n '\bsource\b\|\. ' <file>` | All source targets are trusted/validated |

### 2.2 Secrets & Credentials

| # | Check | Command | Expected |
|---|-------|---------|----------|
| 2.2.1 | 🔧 No hardcoded passwords/tokens | `grep -niE 'password\|passwd\|secret\|token\|api.key' <file>` | Only pattern-matching or env-var reads |
| 2.2.2 | 🔧 No API keys in plain text | `grep -nE '[A-Za-z0-9]{32,}' <file>` | No long random strings that look like keys |
| 2.2.3 | 🔍 Secrets loaded securely | Inspect all credential reads | From env vars, files with 600 perms, or secret managers |
| 2.2.4 | 🔧 Prevent log leakage | `grep -n 'set -x\|set -o xtrace' <file>` | `set -x` is not enabled across blocks processing credentials |

### 2.3 Privilege & Permissions

| # | Check | Command | Expected |
|---|-------|---------|----------|
| 2.3.1 | 🔧 No `sudo` in startup path | `grep -n '\bsudo\b' <file>` | None in code that runs at source-time; OK in explicit functions |
| 2.3.2 | 🔧 No `chmod 777` | `grep -n 'chmod 777\|chmod a+rwx' <file>` | Zero matches |
| 2.3.3 | 🔧 No `chown root` without justification | `grep -n 'chown root' <file>` | Zero or justified |
| 2.3.4 | 🔍 Temp files use `mktemp` | `grep -nE 'tmp\|temp' <file>` | All temp files created via `mktemp` or atomic `.tmp` → `mv` |
| 2.3.5 | 🔧 No world-writable output files | `grep -n 'chmod.*o+w\|chmod.*666' <file>` | Zero matches |

### 2.4 PATH Security

| # | Check | Command | Expected |
|---|-------|---------|----------|
| 2.4.1 | 🔧 No `.` in PATH | `grep -n 'PATH=.*:\.:' <file>` | Zero matches |
| 2.4.2 | 🔍 PATH entries are absolute | Inspect all `PATH=` lines | All directories are absolute paths (`$HOME/...` OK) |
| 2.4.3 | 🔍 No world-writable dirs in PATH | Check each appended directory | All owned by root or current user |
| 2.4.4 | 🔧 PATH guarded against duplication | Check for `[[ ":$PATH:" != *"..."* ]]` | Prevents repeated prepending on re-source |

### 2.5 Process & Signal Safety

| # | Check | Command | Expected |
|---|-------|---------|----------|
| 2.5.1 | 🔧 `pkill -x` not `pkill -f` | `grep -n 'pkill -f' <file>` | Zero matches (use `-x` for exact match) |
| 2.5.2 | 🔍 `kill` targets validated PIDs | Inspect all `kill` calls | PID sourced from known process, not user input |
| 2.5.3 | 🔧 No unquoted command substitution in `kill` | `grep -n 'kill \$(' <file>` | All quoted: `kill "$pid"` |

### 2.6 Input Handling

| # | Check | Command | Expected |
|---|-------|---------|----------|
| 2.6.1 | 🔧 No unquoted `$@` or `$*` | `grep -nE '\$@\|\$\*' <file> \| grep -v '"'` | All uses double-quoted: `"$@"` |
| 2.6.2 | 🔧 No unquoted variable in `[[ ]]` | `grep -nE '\[\[.*\$[a-zA-Z]' <file>` | Variables quoted (except inside `(( ))`) |
| 2.6.3 | 🔍 User input sanitized before use | Inspect `read` calls | Input validated/escaped before passing to commands |
| 2.6.4 | 🔧 No injection via variable in `printf` format | `grep -n 'printf.*\$' <file>` | Variables in args, not format string |

---

## 3. Safety — Critical

Prevent the script from damaging the host environment.

| # | Check | Command | Expected |
|---|-------|---------|----------|
| 3.1 | 🔧 Interactive shell guard | `grep -n "case \$- in" <file>` | Non-interactive shells exit early in profiles |
| 3.2 | 🔧 No background daemons at source-time | `grep -nE 'nohup\|&$\|disown' <file>` | bg processes only inside explicit user-invoked functions |
| 3.3 | 🔍 Strict Mode enabled | `head -10 <file>` | `set -euo pipefail` is present. For Bash 4.4+, `shopt -s inherit_errexit` is included |
| 3.4 | 🔍 Subshell error inheritance | `grep -n 'set -E' <file>` | `set -E` is used if trapping `ERR` so subshells trigger traps |
| 3.5 | 🔍 Trap cleans up on signals | `grep -n 'trap' <file>` | Traps handle EXIT, INT, TERM, ERR properly |
| 3.6 | 🔧 No `rm -rf` with variables | `grep -n 'rm -rf.*\$' <file>` | Variable is validated non-empty; path is anchored |
| 3.7 | 🔧 Strict `set +e` scope | Inspect all `set +` | Re-enabled immediately after the guarded block |
| 3.8 | 🔍 Singletons use lockfiles | `grep -n 'flock' <file>` | Cron jobs or background workers use `flock` to prevent concurrency collisions |

---

## 4. Correctness — High

### 4.1 Syntax & Static Analysis

| # | Check | Command | Expected |
|---|-------|---------|----------|
| 4.1.1 | 🔍 `bash -n` passes | `bash -n <file>` | Exit code 0, no output |
| 4.1.2 | 🔍 ShellCheck passes | `shellcheck -s bash <file>` | Zero findings (or all suppressed with rationale) |
| 4.1.3 | 🔧 Fix all ShellCheck errors (SCxxxx) | Address each finding | Severity `error` = must fix; `warning` = should fix; `info` = evaluate |

### 4.2 Control Flow

| # | Check | Command | Expected |
|---|-------|---------|----------|
| 4.2.1 | 🔧 No `A && B \|\| C` as if/then/else | `grep -n '&&.*\|\|' <file> \| grep -v '#'` | Replaced with `if/then/else` |
| 4.2.2 | 🔍 No dead code | `awk` scan for code after control transfer | Zero unreachable lines |
| 4.2.3 | 🔍 All `case` branches end with `;;` | `shellcheck` catches this | No fall-through warnings |

### 4.3 Variable Handling & Data Types

| # | Check | Command | Expected |
|---|-------|---------|----------|
| 4.3.1 | 🔧 Separate `declare` and assignment | `grep -nE 'local \w+=\$\(' <file>` | (SC2155) Split: `local x; x=$(cmd)` |
| 4.3.2 | 🔧 Lists use Arrays | Inspect assignment of lists | Use `arr=(a b c)`, not `str="a b c"`. Iterate with `"${arr[@]}"` |
| 4.3.3 | 🔧 No unused variables | `shellcheck` SC2034 | All declared variables used (or prefixed `_`) |
| 4.3.4 | 🔍 Local variables declared `local` | Inspect functions | No accidental globals inside functions |
| 4.3.5 | 🔧 `[[ ]]` preferred over `[ ]` | `grep -nE '^\s*\[ ' <file>` | Use `[[ ]]` throughout for safer logic in Bash |

### 4.4 Quoting & Word Splitting

| # | Check | Command | Expected |
|---|-------|---------|----------|
| 4.4.1 | 🔧 Variables quoted in command args | `shellcheck` SC2086 | `"$var"` not `$var` |
| 4.4.2 | 🔧 Glob patterns intentional | `shellcheck` SC2035, SC2144 | `*.txt` used only where globbing is intended |

### 4.5 Unicode & Encoding

| # | Check | Command | Expected |
|---|-------|---------|----------|
| 4.5.1 | 🔧 No non-ASCII in executable code | `grep -Pn '[^\x00-\x7F]' <file> \| grep -v '^\s*#\|^[0-9]*:\s*#'` | Zero matches outside comments/strings |
| 4.5.2 | 🔧 No Unicode look-alikes | `grep -Pn '[\x{2010}-\x{2015}\x{2018}-\x{201F}\x{2026}\x{00A0}]' <file>` | Zero matches (catches smart quotes, NBSP) |

---

## 5. Robustness — High

Handle failures gracefully.

| # | Check | Command | Expected |
|---|-------|---------|----------|
| 5.1 | 🔍 External commands guarded | `grep -n 'command -v' <file>` | Optional external tools checked before use via `command -v` |
| 5.2 | 🔍 Network calls have timeouts | `grep -nE 'curl\|wget\|nc ' <file>` | `--connect-timeout` or `--max-time` present |
| 5.3 | 🔍 Fallback values used | Inspect `${var:-default}` usage | Critical paths have defaults |
| 5.4 | 🔍 Error messages to stderr | `grep -n 'echo.*error\|printf.*error' <file>` | Error output uses `>&2` |
| 5.5 | 🔍 File descriptors managed safely | Inspect `exec` usage | Custom FDs opened/closed intentionally without leaking |

---

## 6. Efficiency & Performance — Medium

### Performance Notes
* **Subshells:** Subshells `$(...)` incur a fork overhead. In loops, this destroys performance. Use Bash builtins (e.g., parameter expansion `${var%pattern}`) instead of piping to `sed`, `awk`, or `grep` inside loops.
* **I/O Operations:** Avoid `while read -r line; do ... done < file` for processing large files. It executes line-by-line entirely within the Bash interpreter, which is extremely slow. Use `mapfile` (or `readarray`) to load files into memory as an array if the file is reasonably sized, or offload the entire loop processing to `awk` or `jq`.
* **Builtins over Externals:** Use `[[ $a == *$b* ]]` instead of `echo "$a" | grep "$b"`.

| # | Check | Command | Expected |
|---|-------|---------|----------|
| 6.1 | 🔧 No Useless Use of Cat (UUOC) | `grep -nE 'cat [^|]*\|' <file>` | `grep file` not `cat file \| grep` |
| 6.2 | 🔧 No unnecessary subshells | `grep -nE '^\s*\(' <file>` | `{ }` grouping where subshell isn't needed |
| 6.3 | 🔍 Heavy work is lazy-loaded | Inspect startup path | Network calls, disk scans deferred to first use or async |
| 6.4 | 🔧 Prefer builtins over externals | Check for `echo` vs `printf`, `test` vs `[[ ]]` | Builtins preferred where equivalent |
| 6.5 | 🔧 Optimize file reading | `grep -n 'while read' <file>` | `mapfile -t` used for array ingestion instead of while-loops |

---

## 7. Portability — Medium

| # | Check | Command | Expected |
|---|-------|---------|----------|
| 7.1 | 🔍 Shebang is correct | `head -1 <file>` | `#!/usr/bin/env bash` |
| 7.2 | 🔍 GNU extensions documented | `grep -nE 'stat -c\|find.*-printf\|date \+%s%N\|readarray\|mapfile' <file>` | GNU-ism justified & documented (Standard for Ubuntu/WSL) |
| 7.3 | 🔍 Bash version requirement | `grep -n 'BASH_VERSINFO\|BASH_VERSION' <file>` | Minimum version stated (e.g., 4.3+ for `nameref`, 4.4+ for `mapfile -d`) |

---

## 8. Style & Formatting — Medium

### 8.1 Indentation & Whitespace

| # | Check | Command | Expected |
|---|-------|---------|----------|
| 8.1.1 | 🔧 Consistent indentation | `grep -Pc '\t' <file>` | Uniform (4 spaces recommended for Bash) |
| 8.1.2 | 🔧 No trailing whitespace | `grep -Pn ' +$' <file>` | Zero matches |
| 8.1.4 | 🔧 File ends with newline | `tail -c1 <file> \| xxd` | Last byte is `0a` |
| 8.1.5 | 🔧 No Windows line endings | `grep -Pc '\r' <file>` | Zero matches (Important for WSL interop) |

### 8.2 Naming & Declarations

| # | Check | Command | Expected |
|---|-------|---------|----------|
| 8.2.1 | 🔍 Functions named consistently | `grep -cE '^function \|^[a-z_].*\(\)' <file>` | Prefer `func_name() { ... }` style |
| 8.2.2 | 🔍 Private helpers prefixed `_` | Inspect helper functions | Internal functions namespaced |
| 8.2.3 | 🔍 Constants in UPPER_CASE | Inspect constant declarations | Convention followed |

---

## 9. Documentation — Medium

| # | Check | Action | Expected |
|---|-------|--------|----------|
| 9.1 | 🔍 File header present | `head -20 <file>` | Purpose, author, version, date |
| 9.2 | 🔍 Public functions documented | Scan functions | All public functions have purpose, args, return value |
| 9.3 | 🔍 `--help` output exists | Run `<script> --help` | Clear usage with examples |

---

## 10. Refactor & Maintainability — Low

| # | Check | Action | Expected |
|---|-------|--------|----------|
| 10.1 | 🔍 Abstract repeated logic | Search for 3+ identical code blocks | Extract to helper functions |
| 10.2 | 🔍 Magic numbers extracted | `grep -nE '[^0-9][0-9]{4,}[^0-9]' <file>` | Named constants |
| 10.3 | 🔧 Diagnostic utilities | Inspect for `diagnose`/`dryrun` | Script includes a `--dry-run` or validation mode |

---

## 11. Testing & CI — Low

| # | Check | Action | Expected |
|---|-------|--------|----------|
| 11.1 | 🔧 Lint script exists | Check `scripts/lint.sh` | `bash -n` + `shellcheck` executed automatically |
| 11.2 | 🔍 BATS integration | Check for `tests/*.bats` | Core logic functions are sourced and tested via [BATS-core](https://github.com/bats-core/bats-core) |
| 11.3 | 🔍 Smoke test exists | Check for test script | Basic script invocation works without errors |

---

## 12. Final Validation

| # | Check | Command | Expected |
|---|-------|---------|----------|
| 12.1 | 🔍 `bash -n` passes on all files | `find . -name '*.sh' \| xargs -I{} bash -n {}` | Exit 0 |
| 12.2 | 🔍 ShellCheck passes | `find . -name '*.sh' \| xargs shellcheck -s bash` | Zero findings |
| 12.3 | 🔍 Sourcing works | `bash -ic 'source <file>; exit'` | Exit 0 |
| 12.4 | 🔍 No regressions | Run BATS test suite | All green |