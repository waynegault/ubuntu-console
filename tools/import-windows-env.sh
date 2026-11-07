#!/usr/bin/env bash
# ==============================================================================
# import-windows-env.sh — Windows environment variable importer
# ==============================================================================
# AI INSTRUCTION: Increment version on significant changes.
# Module Version: 12
#   v12 (2026-11-07): PowerShell resolution now matches scripts/09d-oc-agents.sh:__oc_pwsh_exe —
#   PATH, then the repo's own ~/.local/bin/pwsh.exe shim — instead of starting at the per-machine
#   MSIX path, which does not exist on this box (measured 2026-11-07), so every run silently fell
#   through to Windows PowerShell 5.1 and nothing reported it. A candidate is accepted only if it
#   ANSWERS: the app-execution alias returned EIO under a failing WSL interop the same day, so an
#   executable-bit test would have skipped a working 5.1 behind a dead alias. A fallback is now
#   named on stderr, a missing PowerShell is announced rather than exiting 1 from a bare test, and
#   the two status-suppressing idioms (the positional shift, the PATH lookup) are explicit guards.
#   v11 (2026-10-15): interpreter selection moved to tools/python-runtime.sh so standalone
#   scripts and tools use the same repo-venv-first policy.
# @modular-section: import-windows-user-env
# @depends: none (standalone; calls pwsh.exe / tasklist.exe)
# @exports: (none — standalone script, writes to output-file)
# Usage:
#   tools/import-windows-env.sh [output-file] [VAR_NAME...]
# If no VAR_NAME values are provided, uses the built-in default list.
#
# Sources:
# - Windows User/Machine environment variables
# - Local WSL Qwen CLI OAuth file (~/.qwen/oauth_creds.json) as fallback for
#   QWEN_PORTAL_ACCESS / QWEN_PORTAL_REFRESH when env vars are absent

set -euo pipefail

_REPO_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
# shellcheck source=tools/python-runtime.sh
source "$_REPO_ROOT/tools/python-runtime.sh"

# Sourced by tests/unit/50-python-interpreter-resolution.bats to exercise
# the shared resolver — the Windows env bridge cannot run under CI (no pwsh.exe), so a
# source stops here after defining the resolver. Executed normally otherwise.
if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
    return 0
fi

# The output file holds secrets; create it 0600 from the start. (The trailing
# chmod 600 alone left a world-readable window and no protection if the write
# failed midway.)
umask 077

_TAC_PY="$(_tac_python_path "$_REPO_ROOT")"

# One place writes diagnostics. §18.3 counts hand-written `>&2` sites, and a helper
# keeps this file at one rather than one per message.
_import_env_diag() {
  printf '%s\n' "$*" >&2
}

OUT="${1:-$HOME/.openclaw/.env.bridge}"
# An explicit guard, not a status-suppressing shift: with no operands `shift`
# fails, and a failure suppressed here is the same shape as any other silent one.
if [[ "$#" -gt 0 ]]; then
  shift
fi
mkdir -p "$(dirname "$OUT")"

if [[ "$#" -gt 0 ]]; then
  NAMES=("$@")
else
  NAMES=(
    GITHUB_COPILOT_TOKEN
    QWEN_PORTAL_ACCESS
    QWEN_PORTAL_REFRESH
  )
fi

# Resolve PowerShell the way scripts/09d-oc-agents.sh:__oc_pwsh_exe does — PATH
# first, then the shim this repo generates (14-wsl-extras.sh). The per-machine
# MSIX path this list used to start with does not exist on this box (measured
# 2026-11-07), so the loop always fell through to Windows PowerShell 5.1: the
# bridge kept working, so nothing reported the degradation. 5.1 stays as the
# documented last resort — it runs the same [Environment]::GetEnvironmentVariable
# calls the embedded script makes.
PS_BIN=""
_ps_candidates=()
# The if, not a status-suppressing lookup: absence must be an unremarkable
# outcome of the SEARCH and still leave the loop's result authoritative, rather
# than suppressing a status that would also hide a genuine lookup failure.
if _ps_on_path="$(command -v pwsh.exe 2>/dev/null)"; then
  _ps_candidates+=("$_ps_on_path")
fi
_ps_candidates+=(
    "$HOME/.local/bin/pwsh.exe"
    /mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe
)
for candidate in "${_ps_candidates[@]}"
do
  [[ -x "$candidate" ]] || continue
  # PROBE BY EXECUTION, not by the executable bit: the MSIX app-execution alias answers
  # EIO under a failing WSL interop (measured 2026-11-07: "WindowsApps/pwsh.exe:
  # Input/output error" while the same moment's Windows PowerShell 5.1 call succeeded),
  # so an `-x` test alone would select a binary that cannot run and skip a working one.
  if timeout 20 "$candidate" -NoProfile -NonInteractive -Command "'probe'" >/dev/null 2>&1; then
    PS_BIN="$candidate"
    break
  fi
  # A loud, named fallback: the degradation this file used to hide was invisible for
  # exactly as long as it worked.
  _import_env_diag "[import-windows-env] WARNING: $candidate did not answer — trying the next PowerShell"
done
if [[ -z "$PS_BIN" ]]; then
  # Not a bare `[[ -n "$PS_BIN" ]]`: under `set -e` that exits 1 with no reason at
  # all, and the caller's log cannot then say which of the three was missing.
  _import_env_diag "ERROR: no PowerShell found — checked pwsh.exe on PATH," \
      "$HOME/.local/bin/pwsh.exe, and Windows PowerShell 5.1"
  exit 1
fi

# Build PowerShell array literal
PS_ARRAY=$(printf "'%s', " "${NAMES[@]}" | sed 's/, $//')

# Build PowerShell script with embedded array
PS_SCRIPT=$(cat <<'PS_EOF'
$names = @(__PS_ARRAY__)
$result = @{}
foreach ($name in $names) {
  $v = [Environment]::GetEnvironmentVariable($name, "User")
  if ([string]::IsNullOrWhiteSpace($v)) {
    $v = [Environment]::GetEnvironmentVariable($name, "Machine")
  }
  if (-not [string]::IsNullOrWhiteSpace($v)) {
    $result[$name] = [string]$v
  }
}
$result | ConvertTo-Json -Compress
PS_EOF
)
# Quoted delimiter, so no \$ escaping anywhere: tree-sitter-bash cannot parse an
# escaped '$' on the same line as an array subscript, and that parse break cost
# this file its call edges.  The names array is injected by substitution instead,
# which emits byte-identical PowerShell.
PS_SCRIPT="${PS_SCRIPT/__PS_ARRAY__/$PS_ARRAY}"

WINDOWS_ENV_JSON=$(timeout 60 "$PS_BIN" -NoProfile -Command "$PS_SCRIPT") || {
    # A bare call hung the whole bridge after sleep/hibernate with no timeout to
    # end it; PowerShell interop calls elsewhere in this repo are all wrapped.
    _import_env_diag "ERROR: PowerShell env bridge failed or timed out after 60s"
    exit 1
}

"$_TAC_PY" - "$OUT" "$WINDOWS_ENV_JSON" "$HOME/.qwen/oauth_creds.json" "${NAMES[@]}" <<'PY'
import json
import pathlib
import shlex
import sys

out = pathlib.Path(sys.argv[1])
raw_windows = (sys.argv[2] if len(sys.argv) > 2 else '').strip() or '{}'
qwen_path = pathlib.Path(sys.argv[3]) if len(sys.argv) > 3 else pathlib.Path.home() / '.qwen' / 'oauth_creds.json'
requested = sys.argv[4:]

try:
    data = json.loads(raw_windows)
    if not isinstance(data, dict):
        data = {}
except Exception as exc:
    print(f"[import-windows-env] WARNING: could not parse the Windows env JSON: {exc}", file=sys.stderr)
    data = {}

needs_qwen_access = 'QWEN_PORTAL_ACCESS' in requested
needs_qwen_refresh = 'QWEN_PORTAL_REFRESH' in requested
needs_qwen = needs_qwen_access or needs_qwen_refresh

if needs_qwen and qwen_path.is_file():
    try:
        qwen = json.loads(qwen_path.read_text(encoding='utf-8'))
        if needs_qwen_access and not data.get('QWEN_PORTAL_ACCESS'):
            value = qwen.get('access_token')
            if isinstance(value, str) and value.strip():
                data['QWEN_PORTAL_ACCESS'] = value
        if needs_qwen_refresh and not data.get('QWEN_PORTAL_REFRESH'):
            value = qwen.get('refresh_token')
            if isinstance(value, str) and value.strip():
                data['QWEN_PORTAL_REFRESH'] = value
    except Exception as exc:
        print(f"[import-windows-env] WARNING: could not read {qwen_path}: {exc}", file=sys.stderr)

with out.open('w', encoding='utf-8') as f:
    for key in requested:
        value = data.get(key)
        if isinstance(value, str) and value.strip():
            f.write(f'{key}={shlex.quote(value)}\n')
PY

chmod 600 "$OUT"

# end of file
