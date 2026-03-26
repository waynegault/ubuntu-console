#!/usr/bin/env bash
# ==============================================================================
# mirror-gigabrain-vault-to-windows.sh — Sync Obsidian vault to Windows
# ==============================================================================
# AI INSTRUCTION: Increment version on significant changes.
# Module Version: 1
#
# Purpose: Mirror gigabrain workspace vault from WSL to Windows Obsidian folder
# Usage:   ./mirror-gigabrain-vault-to-windows.sh [src] [dest]
# ==============================================================================
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
