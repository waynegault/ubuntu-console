#!/usr/bin/env bash
# ==============================================================================
# load-vault-env — Optional Windows-backed vault env loader
# ==============================================================================
# AI INSTRUCTION: Increment version on significant changes.
# Module Version: 1
# Optional helper loaded by scripts/14-wsl-extras.sh.
#
# Source (repo):   scripts/load-vault-env.sh
# Install target:  ~/.openclaw/credentials/vault/load-vault-env.sh
#
# Purpose:
# - Import Windows-backed credential exports into the current shell.
# - Safely parse KEY=VALUE lines from trusted bridge/env files.
# - Export only valid shell variable names.
#
# Controls:
#   TAC_LOAD_VAULT=0                   — skip vault loading entirely (set in env)
#   TAC_VAULT_REFRESH_FROM_WINDOWS=0   — skip re-running the Windows bridge script
#   TAC_VAULT_EXPORT_NAMES=A,B,C       — override default credential names to import

_lve_bridge_script="$HOME/.openclaw/workspace/scripts/17-import-windows-user-env.sh"
_lve_bridge_file="$HOME/.openclaw/.env.bridge"
_lve_tmp_file=""

# Keep list small by default to avoid importing unrelated host variables.
_lve_default_names=(
    GITHUB_COPILOT_TOKEN
    QWEN_PORTAL_ACCESS
    QWEN_PORTAL_REFRESH
    OPENAI_API_KEY
    ANTHROPIC_API_KEY
    AZURE_OPENAI_API_KEY
    GOOGLE_API_KEY
)

_lve_cleanup() {
    [[ -n "$_lve_tmp_file" && -f "$_lve_tmp_file" ]] && rm -f "$_lve_tmp_file"
}

# Refresh bridge file from Windows env when helper exists.
if [[ -f "$_lve_bridge_script" ]]
then
    if [[ "${TAC_VAULT_REFRESH_FROM_WINDOWS:-1}" != "0" ]]
    then
        mkdir -p "$(dirname "$_lve_bridge_file")" 2>/dev/null || true
        if [[ -n "${TAC_VAULT_EXPORT_NAMES:-}" ]]
        then
            IFS=',' read -r -a _lve_names <<< "$TAC_VAULT_EXPORT_NAMES"
            bash "$_lve_bridge_script" "$_lve_bridge_file" "${_lve_names[@]}" >/dev/null 2>&1 || true
        else
            bash "$_lve_bridge_script" "$_lve_bridge_file" "${_lve_default_names[@]}" >/dev/null 2>&1 || true
        fi
    fi
fi

_lve_candidate_files=(
    "$HOME/.openclaw/credentials/vault/windows.env"
    "$HOME/.openclaw/credentials/vault/vault.env"
    "$_lve_bridge_file"
    "/dev/shm/tac_win_api_keys"
)

_lve_existing_files=()
for _lve_f in "${_lve_candidate_files[@]}"
do
    [[ -f "$_lve_f" ]] && _lve_existing_files+=("$_lve_f")
done

if (( ${#_lve_existing_files[@]} == 0 ))
then
    unset _lve_f _lve_candidate_files _lve_existing_files _lve_bridge_script _lve_bridge_file
    unset _lve_default_names _lve_names _lve_tmp_file
    # shellcheck disable=SC2317
    return 0 2>/dev/null || exit 0
fi

_lve_tmp_file=$(mktemp)

# Parse KEY=VALUE files and emit validated export lines.
python3 - "$_lve_tmp_file" "${_lve_existing_files[@]}" <<'PY'
import pathlib
import re
import shlex
import sys

out_path = pathlib.Path(sys.argv[1])
files = [pathlib.Path(p) for p in sys.argv[2:]]
name_re = re.compile(r'^[A-Za-z_][A-Za-z0-9_]*$')
env = {}

for fp in files:
    try:
        lines = fp.read_text(encoding='utf-8', errors='replace').splitlines()
    except OSError:
        continue
    for line in lines:
        s = line.strip()
        if not s or s.startswith('#') or '=' not in s:
            continue
        key, raw = s.split('=', 1)
        key = key.strip()
        if not name_re.match(key):
            continue
        raw = raw.strip()
        if raw == '':
            continue
        try:
            tokens = shlex.split(raw, posix=True)
            value = tokens[0] if len(tokens) == 1 else raw
        except Exception:
            value = raw
        env[key] = value

with out_path.open('w', encoding='utf-8') as f:
    for key in sorted(env.keys()):
        f.write(f'export {key}={shlex.quote(env[key])}\n')
PY

# shellcheck disable=SC1090
source "$_lve_tmp_file" 2>/dev/null || true

_lve_cleanup

unset _lve_f _lve_candidate_files _lve_existing_files _lve_bridge_script _lve_bridge_file
unset _lve_default_names _lve_names _lve_tmp_file
unset -f _lve_cleanup

# shellcheck disable=SC2317
return 0 2>/dev/null || exit 0
