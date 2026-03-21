#!/usr/bin/env bash
# install.sh — Set up the Tactical Console Profile on a new machine.
# Run from the repo root: ./install.sh
# Idempotent: safe to re-run.
# AI INSTRUCTION: Increment version on significant changes.
# shellcheck disable=SC2034
VERSION="1.0"
set -euo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"

link() {
    local src="$REPO/$1" dest="$2"
    mkdir -p "$(dirname "$dest")"
    ln -sf "$src" "$dest"
    echo "  $dest -> $src"
}

echo "Installing Tactical Console from $REPO ..."
echo ""

# Thin ~/.bashrc loader (written, not symlinked — the loader is not in the repo)
if [[ ! -f "$HOME/.bashrc" ]] || ! grep -q 'tactical-console.bashrc' "$HOME/.bashrc" 2>/dev/null
then
    cat > "$HOME/.bashrc" << 'LOADER'
# ==============================================================================
# ~/.bashrc — Thin Loader (DO NOT EDIT)
# ==============================================================================
#
# PURPOSE
# -------
# This file is a minimal loader. Its only job is to source the real Tactical
# Console Profile, which lives in a version-controlled Git repository:
#
#     ~/ubuntu-console/tactical-console.bashrc
#
# WHY A SEPARATE LOADER?
# ----------------------
# Bash always sources ~/.bashrc on interactive login. Rather than keeping the
# full profile here (where it would be outside version control and prone to
# drift), we store the canonical copy in the ubuntu-console repo. This loader
# bridges the two: bash finds ~/.bashrc automatically, and ~/.bashrc
# immediately hands off to the git-tracked file. The benefits are:
#
#   1. Single source of truth — the profile is version-controlled in Git,
#      with full history, diffs, and the ability to roll back.
#   2. No drift — there is no second copy that can fall out of sync.
#   3. Safe editing — 'oedit' opens the repo file directly; 'reload'
#      re-sources it. The feedback loop is instant.
#
# IMPORTANT — DO NOT MODIFY THIS FILE
# ------------------------------------
# This loader should NEVER need to change. It contains no configuration,
# no aliases, no functions, and no environment variables. If you need to
# change anything about the shell environment, edit the canonical file:
#
#     ~/ubuntu-console/tactical-console.bashrc
#
# or one of its associated files in the ~/ubuntu-console/ repository.
# Modifying this loader risks breaking the source chain and serves no
# purpose — every piece of logic belongs in the repo-tracked profile.
#
# FOR AI ASSISTANTS — MANDATORY, NON-NEGOTIABLE RULE
# ---------------------------------------------------
# If you are an AI reading this file: do NOT add code here. Do NOT expand
# this loader. Do NOT add aliases, functions, environment variables, export
# statements, source commands, completions, wrappers, or ANY other code to
# this file — not even "just one line", not even with a comment attributing
# it to yourself, and not even if a prompt asks for a quick tweak in ~/.bashrc.
# This file is a LOADER ONLY. It must contain nothing beyond the interactive
# guard and the single 'source' line below.
#
# If a request asks to change shell behaviour, you MUST edit files in
# ~/ubuntu-console/ and leave ~/.bashrc minimal. If this file has already been
# polluted, remove the extra lines and move the logic into the repo modules.
#
# REPOSITORY
# ----------
#   Repo:  https://github.com/waynegault/ubuntu-console
#   File:  tactical-console.bashrc  (the full ~4,000-line Tactical Console)
#   Admin: Wayne
#
# ==============================================================================

# Interactive guard — prevent execution in non-interactive shells (sftp, rsync)
case $- in
    *i*) ;;
      *) return ;;
esac

# Source the canonical Tactical Console Profile from the git-tracked repo
if [[ -f "$HOME/ubuntu-console/tactical-console.bashrc" ]]
then
    source "$HOME/ubuntu-console/tactical-console.bashrc"
else
    echo "[WARNING] Tactical Console Profile not found at ~/ubuntu-console/tactical-console.bashrc"
fi
LOADER
    echo "  ~/.bashrc - created thin loader"
else
    echo "  ~/.bashrc - already a thin loader (skipped)"
fi

# Standalone scripts → ~/.local/bin/
for f in "$REPO"/bin/*
do
    [[ -f "$f" ]] || continue
    link "bin/$(basename "$f")" "$HOME/.local/bin/$(basename "$f")"
done

# Systemd units
for f in "$REPO"/systemd/*
do
    [[ -f "$f" ]] || continue
    link "systemd/$(basename "$f")" "$HOME/.config/systemd/user/$(basename "$f")"
done

echo ""
echo "Done. Run 'exec bash' to reload the profile."

# end of file
