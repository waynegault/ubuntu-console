#!/usr/bin/env bash
# AI INSTRUCTION: Increment version on significant changes.
# Module Version: 1

set -euo pipefail

OUT="${1:-$HOME/.openclaw/.env.bridge}"
mkdir -p "$(dirname "$OUT")"

PS=(/mnt/c/Program\ Files/PowerShell/7/pwsh.exe /mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe)
PS_BIN=""
for candidate in "${PS[@]}"; do
  if [[ -x "$candidate" ]]; then
    PS_BIN="$candidate"
    break
  fi
done
[[ -n "$PS_BIN" ]]

# shellcheck disable=SC2016
RAW_JSON=$("$PS_BIN" -NoProfile -Command '
$names = @(
  "GITHUB_COPILOT_TOKEN",
  "QWEN_PORTAL_ACCESS",
  "QWEN_PORTAL_REFRESH"
)
$result = @{}
foreach ($name in $names) {
  $v = [Environment]::GetEnvironmentVariable($name, "User")
  if ([string]::IsNullOrWhiteSpace($v)) {
    $v = [Environment]::GetEnvironmentVariable($name, "Machine")
  }
  if (-not [string]::IsNullOrWhiteSpace($v)) {
    $result[$name] = $v
  }
}
$result | ConvertTo-Json -Compress
')

python3 - "$OUT" "$RAW_JSON" <<'PY'
import json, shlex, sys, pathlib
out = pathlib.Path(sys.argv[1])
raw = (sys.argv[2] if len(sys.argv) > 2 else '').strip() or '{}'
data = json.loads(raw)
with out.open('w', encoding='utf-8') as f:
    for key, value in data.items():
        f.write(f'{key}={shlex.quote(str(value))}\n')
PY
chmod 600 "$OUT"

# end of file
