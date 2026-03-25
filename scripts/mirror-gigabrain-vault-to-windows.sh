#!/usr/bin/env bash
set -euo pipefail

SRC_DEFAULT="/home/wayne/.openclaw/state/memory/gigabrain-workspace/obsidian-vault"
WIN_USERPROFILE_DEFAULT="/mnt/c/Users/wayne"
DEST_DEFAULT="$WIN_USERPROFILE_DEFAULT/Obsidian/Gigabrain"
# Confirmed Windows profile path via PowerShell: C:\Users\wayne

SRC="${1:-$SRC_DEFAULT}"
DEST="${2:-$DEST_DEFAULT}"

if [[ ! -d "$SRC" ]]; then
  echo "Source vault directory not found: $SRC" >&2
  exit 1
fi

mkdir -p "$DEST"

rsync -a --delete \
  --exclude '.obsidian/workspace.json' \
  --exclude '.trash/' \
  --exclude '.DS_Store' \
  "$SRC"/ "$DEST"/

echo "Mirrored Gigabrain vault"
echo "  from: $SRC"
echo "    to: $DEST"
