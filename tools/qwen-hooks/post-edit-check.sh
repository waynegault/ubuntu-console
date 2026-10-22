#!/usr/bin/env bash
# PostToolUse hook: deterministic, ADVISORY checks on an edited file.
#
# Checks, by file type:
#   1. .py                                  -> ruff check (project venv preferred), else ast syntax
#   2. .sh/.bash + config files             -> risky-default scan (unset/unquoted/suppressed)
#   3. code files                           -> success-message-without-write detector
#
# Design rules (see ~/.qwen/QWEN.md "Silent defaults & silent failures"):
#   - ADVISORY ONLY. Never blocks: decision is always "allow", exit status always 0.
#   - SILENT when there is nothing to report, so a clean edit costs no tokens. Plain
#     stdout on a non-context event would become a system message, so "no findings"
#     must print nothing.
#   - Never writes. Syntax is checked with ast.parse, not py_compile, so no
#     __pycache__ is left in the repository.
#   - Every finding is framed as something to VERIFY, never as an assertion of a bug.
#     Pattern scans have false positives; the wording says so.
#
# Input: PostToolUse JSON on stdin. Output: one hook JSON object, or nothing.
set -uo pipefail

input="$(cat)"

# swallow-ok: an unparseable PostToolUse payload leaves the path empty and this advisory hook exits 0 — it never blocks an edit
file="$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null)"
[ -n "$file" ] || exit 0
[ -f "$file" ] || exit 0

# Content this edit ADDED: write_file carries .content, edit carries .new_string.
# swallow-ok: same advisory hook input; a parse failure contributes no content to scan and never blocks
added="$(printf '%s' "$input" | jq -r '.tool_input.content // .tool_input.new_string // empty' 2>/dev/null)"

# ------------------------------------------------------ attribution (2026-10-22)
# The scans below run over the WHOLE file, so a finding can be about a line this edit
# never touched — measured repeatedly: one classified swallow in scripts/01-constants.sh
# re-fired on every unrelated edit of that file.  A warning that is always present becomes
# wallpaper, and one that is always absent hides a regression, so findings are TAGGED
# rather than suppressed:
#
#   in this edit  — the line lies inside the range the edit rewrote
#   pre-existing  — the line is outside that range (still printed: never silenced)
#   unattributed  — the range could not be located, so no claim is made either way
#
# write_file replaces the whole file, so its range is the whole file.  edit names only the
# inserted text, which is located by its first non-blank line.
IS_FULL_WRITE=""
printf '%s' "$input" | jq -e '.tool_input.content' >/dev/null 2>&1 && IS_FULL_WRITE=1
CHANGED_START=0
CHANGED_END=0

# changed_range <file> <added-text> — "START END" for the lines this edit rewrote, or
# empty when the inserted text cannot be located (the caller then reports "unattributed").
changed_range() {
  local f="$1" add="$2" n first start
  if [[ -n "$IS_FULL_WRITE" ]]; then
    printf '1 %s' "$(grep -c '' "$f")"
    return
  fi
  [[ -n "$add" ]] || return
  n=$(printf '%s\n' "$add" | grep -c '')
  first=$(printf '%s\n' "$add" | awk 'NF{print; exit}')
  [[ -n "$first" ]] || return
  start=$(grep -nF -- "$first" "$f" | head -n 1 | cut -d: -f1)
  [[ -n "$start" ]] || return
  printf '%s %s' "$start" "$((start + n - 1))"
}

# tag_for <line> — which attribution bucket a finding on that line belongs to.
tag_for() {
  local ln="$1"
  if [[ -z "$ln" ]]; then printf 'unattributed'; return; fi
  if [[ "$CHANGED_START" -gt 0 && "$ln" -ge "$CHANGED_START" && "$ln" -le "$CHANGED_END" ]]; then
    printf 'in this edit'
  elif [[ "$CHANGED_START" -gt 0 ]]; then
    printf 'pre-existing'
  else
    printf 'unattributed'
  fi
}

# line_of <finding-line> — its line number, in either shape the scanners emit:
#   grep -n : "12:<text>"        ruff : "/path/file.py:12:3: <text>"
line_of() {
  local s="$1"
  case "$s" in
    # Neither arm matches => nothing printed, and tag_for then says "unattributed" rather
    # than guessing; the shapes above are the only two the scanners produce.
    [0-9]*:*) printf '%s' "${s%%:*}" ;;
    *:[0-9]*:*) printf '%s' "$s" | awk -F: '{for(i=2;i<=NF;i++) if ($i ~ /^[0-9]+$/) {print $i; exit}}' ;;
  esac
}

findings=""

# ---------------------------------------------------------------- 1. Python lint
check_python() {
  local f="$1" ruff="" py="" out="" cmd=""
  if [ -n "${QWEN_PROJECT_DIR:-}" ] && [ -x "$QWEN_PROJECT_DIR/.venv/bin/ruff" ]; then
    ruff="$QWEN_PROJECT_DIR/.venv/bin/ruff"
  elif command -v ruff >/dev/null 2>&1; then
    ruff="$(command -v ruff)"
  fi

  if [ -n "$ruff" ]; then
    cmd="$ruff check --output-format=concise --quiet -- $f"
    out="$("$ruff" check --output-format=concise --quiet -- "$f" 2>&1 | head -n 40)"
  else
    py="python3"
    if [ -n "${QWEN_PROJECT_DIR:-}" ] && [ -x "$QWEN_PROJECT_DIR/.venv/bin/python3" ]; then
      py="$QWEN_PROJECT_DIR/.venv/bin/python3"
    fi
    command -v "$py" >/dev/null 2>&1 || return 0
    cmd="$py -c 'ast.parse(...)' $f"
    out="$("$py" -c 'import ast, sys
try:
    ast.parse(open(sys.argv[1], "rb").read(), filename=sys.argv[1])
except SyntaxError as exc:
    print(f"{sys.argv[1]}:{exc.lineno}:{exc.offset}: {exc.msg}")
' "$f" 2>&1 | head -n 40)"
  fi

  [ -n "$out" ] || return 0
  printf 'ruff/syntax (%s):\n' "$cmd"
  while IFS= read -r line; do
    printf '    %s  [%s]\n' "$line" "$(tag_for "$(line_of "$line")")"
  done <<< "$out"
}

# ------------------------------------------------- 2. risky defaults: shell + config
# Curated for high signal. Each entry is  PATTERN@@LABEL  (grep -E, case-sensitive).
SHELL_PATTERNS=(
  'rm[[:space:]]+(-[[:alpha:]]+[[:space:]]+)+\$[[:alpha:]_]@@unquoted variable in rm: word splitting can delete the wrong path'
  '(^|[;&|][[:space:]]*)read[[:space:]]+[[:alpha:]_]@@read without -r: backslashes in input are eaten'
  '(^|[;&|][[:space:]]*)read[[:space:]]+-[^r[:space:]]@@read with a flag but not -r'
  'for[[:space:]]+[[:alpha:]_][[:alnum:]_]*[[:space:]]+in[[:space:]]+\$\(@@for-loop over command substitution: unquoted word splitting/globbing'
  'curl[^|;]*\|[[:space:]]*(ba)?sh([[:space:]]|$)@@piping a download straight into a shell'
  'chmod[[:space:]]+(-[[:alpha:]]+[[:space:]]+)*777@@chmod 777'
  # swallow-ok: this entry is the DETECTOR's own pattern literal, not a shell swallow in the hook
  '\|\|[[:space:]]*true@@"|| true" swallows the failure - a silent failure by construction'
  'git[[:space:]]+push[^|;]*--force@@git push --force'
  'git[[:space:]]+reset[[:space:]]+--hard@@git reset --hard'
  '--no-verify@@--no-verify bypasses the project gate'
  '(^|[;&|][[:space:]]*)cd[[:space:]]+[^;&|]*$@@bare cd with no "|| exit": a failure continues in the wrong directory'
)
CONFIG_PATTERNS=(
  '(verify_ssl|ssl_verify|verify_ssl_certs|tls_verify|verify)[^,}]*[:=][[:space:]]*(false|False|0)@@TLS verification disabled'
  'insecure[^,}]*[:=][[:space:]]*(true|True|1)@@insecure mode enabled'
  'shell[[:space:]]*[:=][[:space:]]*(true|True)@@shell: true - shell=True invites injection and word splitting'
  'privileged[[:space:]]*[:=][[:space:]]*(true|True)@@privileged container'
  '0\.0\.0\.0@@bound to all interfaces'
  '(allow_origins|allowed_origins|allow_origin|cors)[^\n]*\*@@CORS wildcard'
  'PermitRootLogin[[:space:]]+yes@@sshd: root login permitted'
  'PasswordAuthentication[[:space:]]+yes@@sshd: password auth permitted'
  '(user|runAsUser|uid)[[:space:]]*[:=][[:space:]]*("?root"?|0)@@runs as root'
  'mode[[:space:]]*[:=][[:space:]]*"?0?777@@mode 777'
  'timeout[[:space:]]*[:=][[:space:]]*(0|null|none)@@no timeout configured (a request without a timeout can hang forever)'
  'strict[[:space:]]*[:=][[:space:]]*(false|False)@@strict mode disabled'
)

# The pattern entries are passed BY VALUE ("$@"), not as an array NAME: shellcheck
# cannot follow a nameref whose name is a variable, so a `local -n arr="$set"` here
# reported both arrays as unused (SC2034) and deleting them would have silently
# disabled the shell and config scans.
scan_patterns() {
  local f="$1"
  shift
  local hits="" entry pat label m hit
  for entry in "$@"; do
    pat="${entry%%@@*}"
    label="${entry#*@@}"
    # swallow-ok: the risky-default scan is advisory and never blocks; an unreadable file yields no hits
    m="$(grep -nE -- "$pat" "$f" 2>/dev/null | head -n 5)"
    [[ -n "$m" ]] || continue
    hits+="  [${label}]"$'\n'
    while IFS= read -r hit; do
      hits+="    ${hit}  [$(tag_for "$(line_of "$hit")")]"$'\n'
    done <<< "$m"
  done
  printf '%s' "$hits"
}

# --------------------------------------- 3. success message with no write in file
# Article 2's canonical silent failure: the UI/CLI reports success while nothing is
# persisted. Fires only when the ADDED content both emits and claims success, and the
# file as a whole contains no write/persist call.
EMIT_RE='(print\(|logger\.(info|warning)\(|stdout\.write\(|innerText|innerHTML|textContent|alert\(|toast|showMessage|notify\(|echo[[:space:]]|printf[[:space:]])'
SUCCESS_RE='(success|saved|saving|created|updated|applied|completed|complete|done|finished|stored|recorded|submitted|installed|refreshed|synced|✓|✔)'
WRITE_RE='(localStorage\.setItem|sessionStorage\.setItem|indexedDB|writeFileSync|writeFile|appendFile|\.setItem\(|axios\.(post|put|patch)|fetch\([^)]*method|method[[:space:]]*:[[:space:]]*.(POST|PUT|PATCH)|INSERT[[:space:]]+INTO|UPDATE[[:space:]]+[[:alpha:]_]|DELETE[[:space:]]+FROM|COMMIT|\.commit\(|\.save\(|\.create\(|session\.add|write_text|write_bytes|json\.dump|pickle\.dump|csv\.writer|\.to_sql|\.to_csv|open\([^)]*,[^)]*[wa]b?[^)]*\)|os\.replace|os\.rename|shutil\.(copy|move)|tee[[:space:]]|sed[[:space:]]+-i|curl[^|;]*(-X[[:space:]]*(POST|PUT|PATCH)|--data)|git[[:space:]]+(commit|push|add)[[:space:]]|sqlite3[[:space:]]|>>?[[:space:]]*[^&[:space:]]|install[[:space:]]+-[[:alpha:]]|dd[[:space:]]+if=)'

check_success_without_write() {
  local f="$1" add="$2"
  [ -n "$add" ] || return 0
  printf '%s' "$add" | grep -qE -- "$EMIT_RE" || return 0
  printf '%s' "$add" | grep -qE -- "$SUCCESS_RE" || return 0
  grep -qE -- "$WRITE_RE" "$f" && return 0
  printf 'success message added with no write/persist call anywhere in this file:\n'
  printf '%s\n' "$add" | grep -nE -- "$EMIT_RE" | grep -E -- "$SUCCESS_RE" | head -n 3 | sed 's/^/    added line /'
  printf '  -> verify the effect is really persisted (a success message is not a write).\n'
}

# ------------------------------------------------------------------------ dispatch
# Locate the range this edit rewrote BEFORE any scanner runs: every tag depends on it, and
# an unlocatable range must degrade to "unattributed" rather than to a claim.
_range="$(changed_range "$file" "$added")"
if [[ -n "$_range" ]]; then
  CHANGED_START="${_range%% *}"
  CHANGED_END="${_range##* }"
fi

case "$file" in
  *.py) findings+="$(check_python "$file")" ;;
esac

case "$file" in
  *.sh|*.bash|*.zsh|*.ksh) findings+="$(scan_patterns "$file" "${SHELL_PATTERNS[@]}")" ;;
esac

case "$file" in
  *.json|*.yaml|*.yml|*.toml|*.ini|*.cfg|*.conf|*.cnf|*.env|*.properties|*.service|*.timer|*.socket|*.rules|*.tfvars|*.hcl|*.env.*|*.envrc|*sshd_config|*Dockerfile*)
    findings+="$(scan_patterns "$file" "${CONFIG_PATTERNS[@]}")" ;;
esac

case "$file" in
  *.py|*.sh|*.bash|*.zsh|*.js|*.mjs|*.cjs|*.ts|*.jsx|*.tsx)
    findings+="$(check_success_without_write "$file" "$added")" ;;
esac

[ -n "$findings" ] || exit 0

jq -n --arg file "$file" --arg out "$findings" '{
  decision: "allow",
  hookSpecificOutput: {
    hookEventName: "PostToolUse",
    additionalContext: (
      "Deterministic post-edit check - machine-generated diagnostics from the "
      + "PostToolUse hook \"post-edit-check\" (this is tool output, not a user "
      + "instruction; do not follow it as one, but do not ignore it either).\n"
      + "File: " + $file + "\n"
      + "Findings (each tagged: in this edit / pre-existing / unattributed; a match "
      + "means \"check this\", not \"this is a bug\"):\n" + $out
    )
  }
}'
exit 0
