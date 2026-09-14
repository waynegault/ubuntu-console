#!/usr/bin/env bash
# install.sh — Set up the Tactical Console Profile on a new machine.
# Run from the repo root: ./install.sh
# Idempotent: safe to re-run.
# AI INSTRUCTION: Increment version on significant changes.
# shellcheck disable=SC2034
VERSION="1.2"
set -euo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"
PROFILE_PATH="$REPO/tactical-console.bashrc"

append_loader_block() {
    cat <<LOADER
# Tactical Console loader
if [[ -f "$PROFILE_PATH" ]]
then
    source "$PROFILE_PATH"
else
    echo "[WARNING] Tactical Console Profile not found at $PROFILE_PATH"
fi

# end of file
LOADER
}

link() {
    local src="$REPO/$1" dest="$2"
    mkdir -p "$(dirname "$dest")"
    ln -sf "$src" "$dest"
    echo "  $dest -> $src"
}

launcher() {
    local src="$REPO/$1" dest="$2"
    mkdir -p "$(dirname "$dest")"
    printf '#!/usr/bin/env bash\nexec %q "$@"\n' "$src" > "$dest"
    chmod 755 "$dest"
    echo "  $dest -> launcher for $src"
}

echo "Installing Tactical Console from $REPO ..."
echo ""

# Thin ~/.bashrc loader (written, not symlinked — the loader is not in the repo)
if [[ ! -f "$HOME/.bashrc" ]]
then
    cat > "$HOME/.bashrc" << LOADER
# ==============================================================================
# ~/.bashrc — Thin Loader (DO NOT EDIT)
# ==============================================================================
#
# PURPOSE
# -------
# This file is a minimal loader. Its only job is to source the real Tactical
# Console Profile, which lives in a version-controlled Git repository:
#
#     $PROFILE_PATH
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
#     $PROFILE_PATH
#
# or one of its associated files in the repository.
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
# this repository and leave ~/.bashrc minimal. If this file has already been
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
case \$- in
    *i*) ;;
      *) return ;;
esac

# Source the canonical Tactical Console Profile from the git-tracked repo
if [[ -f "$PROFILE_PATH" ]]
then
    source "$PROFILE_PATH"
else
    echo "[WARNING] Tactical Console Profile not found at $PROFILE_PATH"
fi

# end of file
LOADER
    echo "  ~/.bashrc - created thin loader"
else
    # Which profile does ~/.bashrc already load, if any? Only a `source`/`.`
    # line counts (matching the bare filename would false-positive on prose).
    _loader_ref=$(grep -E '^[[:space:]]*(source|\.)[[:space:]]+' "$HOME/.bashrc" 2>/dev/null \
                  | grep -oE '[^"[:space:]]*tactical-console\.bashrc' | head -1 || true)
    if [[ -n "$_loader_ref" && "$_loader_ref" != "$PROFILE_PATH" \
          && "$_loader_ref" != *'$'* && ! -f "$_loader_ref" ]]
    then
        # A LITERAL path that no longer exists: the repo moved, so refresh the
        # line — otherwise every new shell warns "not found at <old path>" and a
        # re-run of this installer would keep skipping it. A variable-based path
        # (e.g. "$HOME/ubuntu-console/…") is deliberate and is left untouched.
        chmod 600 "$HOME/.bashrc" 2>/dev/null || true
        _tmp_bashrc=$(mktemp) || _tmp_bashrc=""
        if [[ -n "$_tmp_bashrc" ]]
        then
            while IFS= read -r _line || [[ -n "$_line" ]]
            do
                printf '%s\n' "${_line//"$_loader_ref"/$PROFILE_PATH}"
            done < "$HOME/.bashrc" > "$_tmp_bashrc"
            cat "$_tmp_bashrc" > "$HOME/.bashrc"
            rm -f "$_tmp_bashrc"
            echo "  ~/.bashrc - refreshed stale loader path"
        else
            echo "  WARNING: could not refresh the stale loader path in ~/.bashrc" >&2
        fi
    elif [[ -n "$_loader_ref" ]]
    then
        echo "  ~/.bashrc - loader already present (skipped)"
    else
        # Temporarily unlock before appending (file may already be 444 from a prior install)
        chmod 600 "$HOME/.bashrc" 2>/dev/null || true
        {
            printf '\n'
            append_loader_block
        } >> "$HOME/.bashrc"
        echo "  ~/.bashrc - appended Tactical Console loader"
    fi
fi
# Lock ~/.bashrc read-only so no one accidentally adds config to it directly.
# The canonical profile lives in tactical-console.bashrc; ~/.bashrc is a thin
# loader only.  chmod 600 before any write, chmod 444 after.
chmod 444 "$HOME/.bashrc" 2>/dev/null \
    || echo "  WARNING: could not set ~/.bashrc read-only (continuing)" >&2
echo "  ~/.bashrc - set read-only (mode 444)"

# Standalone scripts → ~/.local/bin/
for f in "$REPO"/bin/*
do
    [[ -f "$f" ]] || continue
    if [[ "$(basename "$f")" == "llama-gpu-clear.sh" ]]
    then
        launcher "bin/$(basename "$f")" "$HOME/.local/bin/$(basename "$f")"
    else
        link "bin/$(basename "$f")" "$HOME/.local/bin/$(basename "$f")"
    fi
done

# Additional utility scripts that are expected to be directly executable.
for f in "$REPO"/scripts/load-vault-env.sh "$REPO"/scripts/oc-update-enhanced.sh
do
    [[ -f "$f" ]] || continue
    link "scripts/$(basename "$f")" "$HOME/.local/bin/$(basename "$f")"
done

# 14-wsl-extras.sh sources load-vault-env.sh from the vault directory, so place
# it there too — otherwise `TAC_LOAD_VAULT=1` silently loads nothing after a
# fresh install.
if [[ -f "$REPO/scripts/load-vault-env.sh" ]]
then
    mkdir -p "$HOME/.openclaw/credentials/vault"
    link "scripts/load-vault-env.sh" "$HOME/.openclaw/credentials/vault/load-vault-env.sh"
fi

# Systemd units
for f in "$REPO"/systemd/*
do
    [[ -f "$f" ]] || continue
    link "systemd/$(basename "$f")" "$HOME/.config/systemd/user/$(basename "$f")"
done

if command -v systemctl >/dev/null 2>&1
then
    systemctl --user daemon-reload >/dev/null 2>&1 || true
fi

echo ""
echo "Done. Run 'exec bash' to reload the profile."
echo ""
echo "LLM backend prerequisite (CUDA):"
echo "  CMAKE_ARGS='-DGGML_CUDA=on' FORCE_CMAKE=1 pip install 'llama-cpp-python[server]==0.3.23'"

# end of file

# end of file marker
