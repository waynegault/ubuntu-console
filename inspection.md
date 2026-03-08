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
6. [Efficiency — Medium](#6-efficiency--medium)
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

**Why:** Piping remote content to a shell is the #1 attack vector in shell
scripts. `eval` and dynamic `source` bypass all static analysis.

### 2.2 Secrets & Credentials

| # | Check | Command | Expected |
|---|-------|---------|----------|
| 2.2.1 | 🔧 No hardcoded passwords/tokens | `grep -niE 'password\|passwd\|secret\|token\|api.key' <file>` | Only pattern-matching or env-var reads |
| 2.2.2 | 🔧 No API keys in plain text | `grep -nE '[A-Za-z0-9]{32,}' <file>` | No long random strings that look like keys |
| 2.2.3 | 🔍 Secrets loaded securely | Inspect all credential reads | From env vars, files with 600 perms, or secret managers |

**Why:** Secrets committed to source control are effectively public.

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
| 2.6.4 | 🔧 No injection via variable in `printf` format | `grep -n 'printf.*\$' <file>` | Variables in args, not format string (or SC2059 suppressed with comment) |

---

## 3. Safety — Critical

Prevent the script from damaging the host environment.

| # | Check | Command | Expected |
|---|-------|---------|----------|
| 3.1 | 🔧 Interactive shell guard (for profiles) | `grep -n "case \$- in" <file>` | Non-interactive shells exit early (`return` / `exit`) |
| 3.2 | 🔧 No background daemons at source-time | `grep -nE 'nohup\|&$\|disown' <file>` within startup path | bg processes only inside explicit user-invoked functions |
| 3.3 | 🔍 `set -euo pipefail` for standalone scripts | `head -5 <file>` | Present (unless interactive profile) |
| 3.4 | 🔍 Trap cleans up on EXIT | `grep -n 'trap.*EXIT' <file>` | Cleanup trap exists (temp files, bg processes) |
| 3.5 | 🔧 No `rm -rf` with variables | `grep -n 'rm -rf.*\$' <file>` | Variable is validated non-empty; path is anchored |
| 3.6 | 🔧 No `set +e` / `set +u` that stay disabled | Inspect all `set +` | Re-enabled after the guarded block |
| 3.7 | 🔍 `readonly` for constants | Inspect constant declarations | Immutable values declared `readonly` or `declare -r` |

---

## 4. Correctness — High

Logic errors that cause wrong behaviour.

### 4.1 Syntax & Static Analysis

| # | Check | Command | Expected |
|---|-------|---------|----------|
| 4.1.1 | 🔍 `bash -n` passes | `bash -n <file>` | Exit code 0, no output |
| 4.1.2 | 🔍 ShellCheck passes | `shellcheck -s bash <file>` | Zero findings (or all suppressed with rationale) |
| 4.1.3 | 🔧 Fix all ShellCheck errors (SCxxxx) | Address each finding | Severity `error` = must fix; `warning` = should fix; `info` = evaluate |

### 4.2 Control Flow

| # | Check | Command | Expected |
|---|-------|---------|----------|
| 4.2.1 | 🔧 No `A && B \|\| C` as if/then/else | `grep -n '&&.*\|\|' <file> \| grep -v '#'` | Replaced with `if/then/else` (B failure incorrectly triggers C) |
| 4.2.2 | 🔍 No dead code after `return`/`exit`/`exec` | `awk` scan for code after control transfer | Zero unreachable lines |
| 4.2.3 | 🔍 All `case` branches end with `;;` | `shellcheck` catches this | No fall-through warnings |
| 4.2.4 | 🔍 All functions `return` consistently | Inspect error paths | Every error path has explicit `return 1` |

### 4.3 Variable Handling

| # | Check | Command | Expected |
|---|-------|---------|----------|
| 4.3.1 | 🔧 Separate `declare` and assignment | `grep -nE 'local \w+=\$\(' <file>` | (SC2155) Split: `local x; x=$(cmd)` |
| 4.3.2 | 🔧 No unused variables | `shellcheck` SC2034 | All declared variables used (or prefixed `_`) |
| 4.3.3 | 🔧 No duplicate assignments | `grep -nE '^(export\s+)?(PATH\|PS1\|EDITOR\|LANG)=' <file>` | Each variable set once (or guarded) |
| 4.3.4 | 🔍 Local variables declared `local` | Inspect functions | No accidental globals inside functions |
| 4.3.5 | 🔧 `[[ ]]` not `[ ]` | `grep -nE '^\s*\[ ' <file>` | Use `[[ ]]` throughout (bashism is fine for bash scripts) |

### 4.4 Quoting & Word Splitting

| # | Check | Command | Expected |
|---|-------|---------|----------|
| 4.4.1 | 🔧 Variables quoted in command args | `shellcheck` SC2086 | `"$var"` not `$var` |
| 4.4.2 | 🔧 Glob patterns intentional | `shellcheck` SC2035, SC2144 | `*.txt` used only where globbing is intended |
| 4.4.3 | 🔍 IFS manipulation restored | `grep -n 'IFS=' <file>` | IFS saved/restored or used in subshell |

---

## 5. Robustness — High

Handle failures gracefully.

| # | Check | Command | Expected |
|---|-------|---------|----------|
| 5.1 | 🔍 External commands guarded with `command -v` | `grep -n 'command -v' <file>` | Every optional external tool checked before use |
| 5.2 | 🔍 Network calls have timeouts | `grep -nE 'curl\|wget\|nc ' <file>` | `--connect-timeout` or `--max-time` on every network call |
| 5.3 | 🔍 Fallback values for critical variables | Inspect `${var:-default}` usage | Critical paths have defaults |
| 5.4 | 🔍 Error messages go to stderr | `grep -n 'echo.*error\|printf.*error' <file>` | Error output uses `>&2` |
| 5.5 | 🔧 Pipeline errors caught | `set -o pipefail` or explicit checks | Failed piped commands don't silently pass |
| 5.6 | 🔍 `2>/dev/null` used judiciously | `grep -c '2>/dev/null' <file>` | Not masking real errors; only suppressing known-benign noise |
| 5.7 | 🔍 Arithmetic overflow considered | Inspect `$(( ))` expressions | Division by zero guarded; large values bounded |

---

## 6. Efficiency — Medium

Avoid unnecessary work, especially in code that runs at shell startup.

| # | Check | Command | Expected |
|---|-------|---------|----------|
| 6.1 | 🔧 No Useless Use of Cat (UUOC) | `grep -nE 'cat [^|]*\|' <file>` | `grep file` not `cat file \| grep` |
| 6.2 | 🔧 No unnecessary subshells | `grep -nE '^\s*\(' <file>` | `{ }` grouping where subshell isn't needed |
| 6.3 | 🔍 Heavy work is lazy-loaded | Inspect startup path | Network calls, disk scans deferred to first use or async |
| 6.4 | 🔧 Prefer builtins over externals | Check for `echo` vs `printf`, `test` vs `[[ ]]` | Builtins preferred where equivalent |
| 6.5 | 🔍 Loops don't fork per iteration | Inspect `for`/`while` bodies | Batch operations; avoid `sed`/`awk` per line |
| 6.6 | 🔍 Cache expensive results | Look for repeated calls | Expensive queries (network, disk) cached with TTL |
| 6.7 | 🔍 Profile startup time | `time bash -ic exit` | < 500ms for interactive profiles |

---

## 7. Portability — Medium

Relevant if the script may run on different systems. Skip if single-platform.

| # | Check | Command | Expected |
|---|-------|---------|----------|
| 7.1 | 🔍 Shebang is correct | `head -1 <file>` | `#!/usr/bin/env bash` (portable) or `#!/bin/bash` (fixed) |
| 7.2 | 🔍 GNU extensions documented | `grep -nE 'stat -c\|find.*-printf\|date \+%s%N\|readarray\|mapfile' <file>` | Each GNU-ism justified & platform noted in header |
| 7.3 | 🔍 Bash version requirement documented | `grep -n 'BASH_VERSINFO\|BASH_VERSION' <file>` | Minimum version stated (e.g. 4.3+ for `nameref`) |
| 7.4 | 🔍 No `echo -e` (not portable) | `grep -n 'echo -e' <file>` | Use `printf` instead |
| 7.5 | 🔍 `$'...'` quoting intentional | `grep -n "\$'" <file>` | ANSI-C quoting is bash-only; OK if bash is the target |
| 7.6 | 🔍 `local` used only in functions | `grep -n '\blocal\b' <file>` | Not used at top-level scope |

---

## 8. Style & Formatting — Medium

Consistency reduces cognitive load and merge conflicts.

### 8.1 Indentation & Whitespace

| # | Check | Command | Expected |
|---|-------|---------|----------|
| 8.1.1 | 🔧 Consistent indentation (tabs OR spaces) | `grep -Pc '\t' <file>` | Uniform: either all tabs or all spaces |
| 8.1.2 | 🔧 No trailing whitespace | `grep -Pn ' +$' <file>` | Zero matches |
| 8.1.3 | 🔍 Reasonable line length | `awk 'length > 120' <file> \| wc -l` | Minimal exceedances (allow for long strings) |
| 8.1.4 | 🔧 File ends with newline | `tail -c1 <file> \| xxd` | Last byte is `0a` |
| 8.1.5 | 🔧 No Windows line endings | `grep -Pc '\r' <file>` | Zero matches |

### 8.2 Naming & Declarations

| # | Check | Command | Expected |
|---|-------|---------|----------|
| 8.2.1 | 🔍 Functions use `function name()` consistently | `grep -cE '^function \|^[a-z_].*\(\)' <file>` | One style throughout |
| 8.2.2 | 🔍 Private helpers prefixed `__` or `_` | Inspect helper functions | Internal functions namespaced to prevent collisions |
| 8.2.3 | 🔍 Constants in UPPER_SNAKE_CASE | Inspect constant declarations | Convention followed |
| 8.2.4 | 🔍 Local variables in lower_snake_case | Inspect function bodies | Convention followed |

### 8.3 Structure

| # | Check | Command | Expected |
|---|-------|---------|----------|
| 8.3.1 | 🔍 Aliases are appropriate | `grep -n '^alias ' <file>` | Simple name→command mappings; complex logic uses functions |
| 8.3.2 | 🔧 One-liner logic expanded | `grep -n '&&.*\|\|' <file>` | Complex conditionals use multi-line if/then/else |
| 8.3.3 | 🔍 `case` for multiple conditions | Inspect long if/elif chains | 4+ conditions → `case` statement |

---

## 9. Documentation — Medium

### 9.1 File-Level

| # | Check | Action | Expected |
|---|-------|--------|----------|
| 9.1.1 | 🔍 File header present | `head -20 <file>` | Purpose, author, version, date, usage, platform |
| 9.1.2 | 🔍 Changelog maintained | `grep -n 'changelog\|HISTORY\|^# v[0-9]' <file>` | Recent changes documented |
| 9.1.3 | 🔍 ShellCheck directives explained | `grep -n 'shellcheck disable' <file>` | Each disable has an inline rationale comment |

### 9.2 Function-Level

| # | Check | Command | Expected |
|---|-------|---------|----------|
| 9.2.1 | 🔍 Public functions documented | Scan for functions without preceding `# ----` or `# @` block | All public functions have purpose, args, return value |
| 9.2.2 | 🔍 Complex logic annotated | Manual review | Non-obvious algorithms have explanatory comments |
| 9.2.3 | 🔍 TODO/FIXME/HACK tracked | `grep -niE 'TODO\|FIXME\|HACK\|XXX' <file>` | Each has an owner or issue reference |

### 9.3 User-Facing

| # | Check | Action | Expected |
|---|-------|--------|----------|
| 9.3.1 | 🔍 `--help` / usage output exists | Run `<script> --help` or inspect help function | Clear usage with examples |
| 9.3.2 | 🔍 Help index matches actual commands | Cross-reference help text with `declare -F` | No stale or missing entries |
| 9.3.3 | 🔍 README matches current behaviour | Compare README command tables with code | No references to removed/renamed commands |
| 9.3.4 | 🔍 README dependency list is complete | Cross-reference `command -v` checks with README | All external tools listed with install instructions |

---

## 10. Refactor & Maintainability — Low

Items for long-term health. Address after all higher-priority items.

| # | Check | Action | Expected |
|---|-------|--------|----------|
| 10.1 | 🔍 Largest function identified | `awk '/^function /{name=$2; start=NR} /^}/{print NR-start, name}' <file> \| sort -rn \| head -5` | Functions under ~100 lines; mark large ones for future extraction |
| 10.2 | 🔍 Repeated patterns abstracted | Search for 3+ identical code blocks | Extract to helper functions |
| 10.3 | 🔍 Magic numbers replaced with constants | `grep -nE '[^0-9][0-9]{4,}[^0-9]' <file>` | Named constants (e.g. `MAX_RETRIES=5`) |
| 10.4 | 🔍 Section headers and dependency metadata | `grep -n '@modular-section\|@depends\|@exports' <file>` | Each section documents its deps and exports |
| 10.5 | 🔧 Add diagnostic utilities | Inspect for `diagnose`/`dryrun` functions | Self-test functions: env check, syntax check, tool audit |
| 10.6 | 🔍 Error handler present | `grep -n 'trap.*ERR' <file>` | ERR trap logs failures for debugging |

---

## 11. Testing & CI — Low

| # | Check | Action | Expected |
|---|-------|--------|----------|
| 11.1 | 🔧 Lint script exists | Check `scripts/lint.sh` or CI config | `bash -n` + `shellcheck` for all `.sh` / `.bashrc` files |
| 11.2 | 🔍 Lint runs in CI | Check `.github/workflows/` | PR checks include shell linting |
| 11.3 | 🔍 Smoke test exists | Check for test script | Basic source + key function invocation without errors |

### Example lint script

```bash
#!/usr/bin/env bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
rc=0

echo "=== Bash Syntax Check ==="
for f in "$REPO_ROOT"/**/*.sh "$REPO_ROOT"/**/*.bashrc; do
    [[ -f "$f" ]] || continue
    if bash -n "$f" 2>&1; then
        echo "  PASS  ${f#"$REPO_ROOT"/}"
    else
        echo "  FAIL  ${f#"$REPO_ROOT"/}"
        rc=1
    fi
done

echo ""
echo "=== ShellCheck ==="
if ! command -v shellcheck >/dev/null 2>&1; then
    echo "  shellcheck not installed — skipping"
    exit "$rc"
fi

for f in "$REPO_ROOT"/**/*.sh "$REPO_ROOT"/**/*.bashrc; do
    [[ -f "$f" ]] || continue
    if shellcheck -s bash "$f" 2>&1; then
        echo "  PASS  ${f#"$REPO_ROOT"/}"
    else
        echo "  FAIL  ${f#"$REPO_ROOT"/}"
        rc=1
    fi
done

exit "$rc"
```

---

## 12. Final Validation

Run these after all fixes are applied.

| # | Check | Command | Expected |
|---|-------|---------|----------|
| 12.1 | 🔍 `bash -n` passes on all files | `find . -name '*.sh' -o -name '*.bashrc' \| xargs -I{} bash -n {}` | Exit 0, no output |
| 12.2 | 🔍 ShellCheck passes on all files | `find . -name '*.sh' -o -name '*.bashrc' \| xargs shellcheck -s bash` | Zero findings |
| 12.3 | 🔍 File can be sourced without error | `bash -ic 'source <file>; exit'` | Exit 0 |
| 12.4 | 🔍 Key functions are callable | `bash -ic 'source <file>; <func> --help 2>&1; exit'` | No "command not found" |
| 12.5 | 🔍 No regressions | Run any existing test suite | All green |
| 12.6 | 🔍 Diff review | `git diff --stat` | Changes are intentional; no collateral damage |
| 12.7 | 🔍 Line count delta reasonable | `wc -l <file>` | Increase from diagnostic additions; no unexplained bloat |
| 12.8 | 🔍 Commit with audit summary | `git add -A && git commit` | Descriptive commit message listing what was fixed |

---

## Quick-Reference: Common ShellCheck Codes

| Code | Severity | Meaning | Fix |
|------|----------|---------|-----|
| SC1090 | info | Can't follow non-constant source | Add `# shellcheck source=path` or global disable |
| SC1091 | info | File not found for source | Same as above — expected for runtime paths |
| SC2016 | info | Single quotes prevent expansion | Intentional for PowerShell/SQL strings |
| SC2034 | warning | Variable appears unused | Remove, prefix with `_`, or export/document |
| SC2059 | info | Variable in printf format | Move to `%s` arg, or disable with rationale |
| SC2086 | warning | Double-quote to prevent splitting | `"$var"` not `$var` |
| SC2155 | warning | Declare and assign separately | `local x; x=$(cmd)` |
| SC2015 | info | `A && B \|\| C` is not if-then-else | Rewrite as `if A; then B; else C; fi` |
| SC1102 | error | Ambiguous `$((` | Separate arithmetic `$(( ))` from command sub `$( )` |
| SC2035 | info | Glob used as command | Quote or use explicit path |
| SC2044 | info | Avoid `for f in $(find)` | Use `find -exec` or `while read` with process substitution |

---

## Audit Log Template

Copy this for each audit run:

```
## Audit: <project name>
Date:       YYYY-MM-DD
Auditor:    <name or agent>
File(s):    <list>
Baseline:   <line count>, <version>, <git SHA>

### Findings
| Item | Severity | Status | Notes |
|------|----------|--------|-------|
| 2.1.1 | Critical | ✅ Clean | No remote exec patterns |
| ... | ... | ... | ... |

### Changes Made
- ...

### Final Status
- bash -n:    PASS / FAIL
- shellcheck: PASS / FAIL (N findings)
- Sourcing:   PASS / FAIL
```
