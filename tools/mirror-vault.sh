#!/usr/bin/env bash
# ==============================================================================
# mirror-vault.sh — Sync Obsidian vault to Windows
# ==============================================================================
# AI INSTRUCTION: Increment version on significant changes.
# Module Version: 3
# @modular-section: mirror-vault
# @depends: none (standalone; uses rsync / cp)
# @exports: (none — standalone script, not sourced)
#
# Purpose: Mirror the gigabrain-exported Obsidian vault from WSL to Windows.
# Usage:   ./tools/mirror-vault.sh [--dry-run] [--delete] [src] [dest]
#
# Layout: the source vault root nests its notes under `Gigabrain/`, and the
# destination is the Obsidian vault root (it holds `.obsidian/` plus that same
# `Gigabrain/` folder), so `rsync SRC/ DEST/` reproduces the nesting exactly.
#
# Deletion is OPT-IN (`--delete`): a mirror that prunes by default would erase
# Windows-only note folders on the first run, which is not recoverable. Without
# it, files absent from the source are left in place.
# ==============================================================================
set -euo pipefail

# Confirmed on this machine: the exported vault is ~/.openclaw/obsidian-vault.
# The older …/state/memory/gigabrain-workspace/obsidian-vault path was stale —
# with it as the default the script could only ever exit "source not found".
SRC_DEFAULT="/home/wayne/.openclaw/obsidian-vault"
WIN_USERPROFILE_DEFAULT="/mnt/c/Users/wayne"
DEST_DEFAULT="$WIN_USERPROFILE_DEFAULT/Obsidian/Gigabrain"
# Confirmed Windows profile path via PowerShell: C:\Users\wayne

DRY_RUN=0
DELETE=0
POSITIONAL=()
for arg in "$@"; do
  case "$arg" in
    --dry-run|-n) DRY_RUN=1 ;;
    --delete|--prune) DELETE=1 ;;
    -*) echo "Unknown option: $arg (usage: mirror-vault.sh [--dry-run] [--delete] [src] [dest])" >&2; exit 2 ;;
    *) POSITIONAL+=("$arg") ;;
  esac
done

SRC="${POSITIONAL[0]:-$SRC_DEFAULT}"
DEST="${POSITIONAL[1]:-$DEST_DEFAULT}"

if [[ ! -d "$SRC" ]]; then
  echo "Source vault directory not found: $SRC" >&2
  exit 1
fi

# rsync --delete makes an (almost) empty source catastrophic: it would erase
# every note at DEST. Refuse unless the source holds at least
# MIRROR_VAULT_MIN_FILES files (override for a stricter floor).
MIRROR_VAULT_MIN_FILES="${MIRROR_VAULT_MIN_FILES:-1}"
src_file_count=$(find "$SRC" -type f | wc -l)
if (( src_file_count < MIRROR_VAULT_MIN_FILES )); then
  echo "Refusing to mirror: source has $src_file_count file(s), below the minimum of $MIRROR_VAULT_MIN_FILES ($SRC)." >&2
  echo "An (near-)empty source with rsync --delete would erase the destination ($DEST)." >&2
  exit 1
fi

mkdir -p "$DEST"

# mkdir -p succeeds even when the Windows drive is unmounted, which would write
# the vault into the WSL rootfs and still report success. Require the
# destination to sit on the WSL Windows mount (9p on WSL2, drvfs on WSL1).
dest_fstype=$(findmnt -no FSTYPE --target "$DEST" 2>/dev/null || true)
case "$dest_fstype" in
  9p|drvfs) ;;
  *)
    echo "Refusing to mirror: destination $DEST is on '${dest_fstype:-unknown}' filesystem, not the Windows mount (9p/drvfs)." >&2
    echo "Is the Windows drive mounted at $WIN_USERPROFILE_DEFAULT?" >&2
    exit 1
    ;;
esac

rsync_args=(-a
  # The source carries no Obsidian config, so a prune would otherwise strip the
  # Windows vault's own .obsidian/ (workspace state, plugins, theme).
  --exclude '.obsidian/'
  --exclude '.trash/'
  --exclude '.DS_Store')
if (( DELETE == 1 )); then
  rsync_args+=(--delete)
fi
if (( DRY_RUN == 1 )); then
  rsync_args+=(--dry-run --itemize-changes)
fi

rsync "${rsync_args[@]}" "$SRC"/ "$DEST"/

if (( DRY_RUN == 1 )); then
  echo "Dry run — no changes written."
fi
if (( DELETE == 0 )); then
  echo "Note: files present only in $DEST were kept (pass --delete to prune them)."
fi
echo "Mirrored Gigabrain vault"
echo "  from: $SRC"
echo "    to: $DEST"

# end of file
