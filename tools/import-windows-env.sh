#!/usr/bin/env bash
# ==============================================================================
# import-windows-env.sh — Windows environment variable importer
# ==============================================================================
# AI INSTRUCTION: Increment version on significant changes.
# Module Version: 10
#   v10 (2026-10-03): the interpreter is chosen by the named resolver _tac_python_path
#   (.venv/bin/python3 when present, else PATH python3), replacing `command -v python3`
#   plus a `.venv/bin/python` preference — a bare python3 missing from PATH could abort
#   the script under set -e before the venv was checked (card 117e3303). The source guard
#   lets tests exercise the resolver without running the Windows bridge.
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

# _tac_python_path — print the interpreter the embedded Python runs under: the
# project's .venv/bin/python3 when it exists, else PATH python3. This is the same
# prefer-venv-then-fall-back shape tools/count-ratchet.sh uses; resolving with
# `command -v python3` first meant a bare python3 absent from PATH aborted the
# script under set -e before the venv was ever consulted (card 117e3303).
_tac_python_path() {
    local _repo_root
    _repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    if [[ -x "$_repo_root/.venv/bin/python3" ]]; then
        printf '%s\n' "$_repo_root/.venv/bin/python3"
    else
        printf '%s\n' python3
    fi
}

# Sourced by tests/unit/50-python-interpreter-resolution.bats to exercise
# _tac_python_path — the Windows env bridge cannot run under CI (no pwsh.exe), so a
# source stops here after defining the resolver. Executed normally otherwise.
if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
    return 0
fi

# The output file holds secrets; create it 0600 from the start. (The trailing
# chmod 600 alone left a world-readable window and no protection if the write
# failed midway.)
umask 077

_TAC_PY="$(_tac_python_path)"

OUT="${1:-$HOME/.openclaw/.env.bridge}"
shift || true
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

PS=(/mnt/c/Program\ Files/PowerShell/7/pwsh.exe /mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe)
PS_BIN=""
for candidate in "${PS[@]}"; do
  if [[ -x "$candidate" ]]; then
    PS_BIN="$candidate"
    break
  fi
done
[[ -n "$PS_BIN" ]]

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
    echo "ERROR: PowerShell env bridge failed or timed out after 60s" >&2
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
