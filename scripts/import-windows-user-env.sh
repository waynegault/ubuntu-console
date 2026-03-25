#!/usr/bin/env bash
# AI INSTRUCTION: Increment version on significant changes.
# Module Version: 6
# Usage:
#   import-windows-user-env.sh [output-file] [VAR_NAME...]
# If no VAR_NAME values are provided, uses the built-in default list.
#
# Sources:
# - Windows User/Machine environment variables
# - Local WSL Qwen CLI OAuth file (~/.qwen/oauth_creds.json) as fallback for
#   QWEN_PORTAL_ACCESS / QWEN_PORTAL_REFRESH when env vars are absent

set -euo pipefail

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
PS_SCRIPT=$(cat <<PS_EOF
\$names = @($PS_ARRAY)
\$result = @{}
foreach (\$name in \$names) {
  \$v = [Environment]::GetEnvironmentVariable(\$name, "User")
  if ([string]::IsNullOrWhiteSpace(\$v)) {
    \$v = [Environment]::GetEnvironmentVariable(\$name, "Machine")
  }
  if (-not [string]::IsNullOrWhiteSpace(\$v)) {
    \$result[\$name] = [string]\$v
  }
}
\$result | ConvertTo-Json -Compress
PS_EOF
)

WINDOWS_ENV_JSON=$("$PS_BIN" -NoProfile -Command "$PS_SCRIPT")

python3 - "$OUT" "$WINDOWS_ENV_JSON" "$HOME/.qwen/oauth_creds.json" "${NAMES[@]}" <<'PY'
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
except Exception:
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
    except Exception:
        pass

with out.open('w', encoding='utf-8') as f:
    for key in requested:
        value = data.get(key)
        if isinstance(value, str) and value.strip():
            f.write(f'{key}={shlex.quote(value)}\n')
PY

chmod 600 "$OUT"

# end of file
