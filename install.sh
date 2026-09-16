#!/usr/bin/env bash
# install.sh — Set up the Tactical Console Profile on a new machine.
# Run from the repo root: ./install.sh
# Idempotent: safe to re-run.
# AI INSTRUCTION: Increment version on significant changes.
VERSION="1.6"
set -euo pipefail

# --version (diagnostic; also keeps VERSION referenced, so no SC2034 suppression).
if [[ "${1:-}" == "--version" || "${1:-}" == "-V" ]]
then
    echo "install.sh $VERSION"
    exit 0
fi

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
    # Fail closed on a non-executable source.  The shim execs it, so a missing exec
    # bit produces "Permission denied" at RUN time — on a lane start, from systemd,
    # far from here.  git records the exec bit, so the fix is chmod +x + commit the
    # mode; catching it here is the difference between a loud install and a silent
    # breakage discovered by a lane that will not come up.
    if [[ ! -x "$src" ]]; then
        echo "  ERROR: $src is not executable — refusing to install a broken shim" >&2
        echo "         Fix: chmod +x $src  (and commit the mode change)" >&2
        return 1
    fi
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
# Scripts in this list are installed as a short `exec` SHIM at the stable path
# rather than a symlink into the repo: they are invoked by systemd units and by
# the watchdog, and a shim keeps the stable path real (no symlink to rely on)
# while the implementation stays repo-owned.
#
# llama-cuda-server / llama-xe-server / llama-cpu-server are the lane launchers:
# they decide, from the constants, which BUILD serves which card (and, for the CPU
# tier, that no card is involved at all), so that answer is a reviewed line in git
# instead of a repointable symlink.
for f in "$REPO"/bin/*
do
    [[ -f "$f" ]] || continue
    case "$(basename "$f")" in
        llama-gpu-clear.sh|gpu-busy.sh|llama-cuda-server|llama-xe-server|llama-cpu-server)
            launcher "bin/$(basename "$f")" "$HOME/.local/bin/$(basename "$f")" ;;
        *)
            link "bin/$(basename "$f")" "$HOME/.local/bin/$(basename "$f")" ;;
    esac
done

# Historical launcher names, forwarding to the canonical card launchers.  The
# investigator's pipeline/gpu/_llama_procs.py knows these names, so they must keep
# resolving; new work uses llama-cuda-server / llama-xe-server.
#
# rm -f FIRST, every time: these paths are currently symlinks, and a redirect into
# a symlink writes THROUGH it — overwriting the build binary it points at.  That
# is not hypothetical: it is the same shape as the cp-through-symlink that ate
# bin/llama-gpu-clear.sh earlier the same day.
for _alias in cuda-llama-server:cuda xe-llama-server:xe xe-llama-embed:xe
do
    _name="${_alias%%:*}"; _card="${_alias##*:}"
    if [[ -x "$HOME/.local/bin/llama-${_card}-server" ]]; then
        rm -f "$HOME/.local/bin/$_name"
        {
            printf '#!/usr/bin/env bash\n'
            printf '# Historical name — forwards to llama-%s-server (see docs/llm.md).\n' "$_card"
            printf 'exec %q "$@"\n' "$HOME/.local/bin/llama-${_card}-server"
        } > "$HOME/.local/bin/$_name"
        chmod 755 "$HOME/.local/bin/$_name"
        echo "  ~/.local/bin/$_name -> llama-${_card}-server"
    else
        echo "  WARNING: llama-${_card}-server not installed — skipped $_name" >&2
    fi
done

# Retired launchers (2026-09-15, Wayne): llama-server-cuda pointed at
# build-cuda133, a third CUDA name on a build that serves nothing (documented
# rollback-only instead); llama-cli used the unrecorded ~/.local/opt build; and
# cuda-llama-phi4 served the retired Phi-4-mini lane, so it has no caller.  None
# is a lane, and each invited "which build is this?".  A symlink is removed
# outright; a generated one-line shim is removed only when its shebang proves it
# is ours, so a real binary that happened to take the name is left alone.
for _retired in llama-server-cuda llama-cli cuda-llama-phi4
do
    if [[ -L "$HOME/.local/bin/$_retired" ]]; then
        rm -f "$HOME/.local/bin/$_retired"
        echo "  removed retired launcher $_retired"
    elif [[ -f "$HOME/.local/bin/$_retired" ]] \
         && [[ "$(head -1 "$HOME/.local/bin/$_retired" 2>/dev/null)" == '#!/usr/bin/env bash' ]]; then
        rm -f "$HOME/.local/bin/$_retired"
        echo "  removed retired launcher shim $_retired"
    fi
done

# Legacy UNIT names, as RELATIVE alias symlinks — deliberately not systemd's
# [Install] Alias=.  Because the unit files are themselves symlinks into this repo,
# `systemctl enable` materialises its alias with an ABSOLUTE target, and systemd
# then loads that as a SEPARATE unit: two units for one service, with is-active
# lying about both.  The investigator found this on 2026-09-15, after it had already
# put a live CUDA lane down — their name-keyed check read the lane as inactive, and
# ours could have added a second server to the card.  A relative symlink to the unit
# NAME merges the two: one Id, one state, both names.
#
# llama-server-phi4.service is absent by design: its unit (the retired Phi-4-mini
# decomposition lane) was removed on 2026-09-15, so there is nothing to alias.
for _pair in llama-server.service:llama-xe-minicpm5-1b-chat.service \
             llama-embed-server.service:llama-xe-embeddinggemma-embed.service \
             llama-server-nvidia.service:llama-cuda-llama32-3b-chat.service \
             llama-server-8081.service:llama-cuda-qwen35-4b-pipeline.service
do
    _old="${_pair%%:*}"; _new="${_pair##*:}"
    if [[ -e "$HOME/.config/systemd/user/$_new" ]]; then
        ln -sfn "$_new" "$HOME/.config/systemd/user/$_old"
        echo "  ~/.config/systemd/user/$_old -> $_new (relative alias)"
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

# Retired UNIT names (2026-09-15): the Phi-4-mini decomposition lane was removed
# from the repo, so its installed unit link and its legacy alias both dangle.
# Remove them explicitly — the alias target is a BARE name, so a "prune links whose
# target left the repo" pass cannot see it, and `systemctl --user list-unit-files`
# would keep listing a name nothing resolves to.
for _stale in llama-cuda-phi4-mini-decompose.service llama-server-phi4.service
do
    if [[ -L "$HOME/.config/systemd/user/$_stale" ]]; then
        rm -f "$HOME/.config/systemd/user/$_stale"
        echo "  removed retired unit $_stale"
    fi
done

if command -v systemctl >/dev/null 2>&1
then
    systemctl --user daemon-reload >/dev/null 2>&1 || true
fi

# Git hooks — tracked in tools/hooks/ and activated through core.hooksPath, so
# the hooks are version-controlled and reviewable.  They used to live untracked
# in .git/hooks/, where they could not be diffed, reviewed, or shared between
# clones; the pre-commit hook and tools/lint.sh then drifted apart — their
# flags for shellcheck lived in two places and only one was ever updated.
if [[ -d "$REPO/tools/hooks" ]]
then
    if [[ "$(git -C "$REPO" config --get core.hooksPath 2>/dev/null || true)" == "$REPO/tools/hooks" ]]
    then
        echo "  hooks - core.hooksPath already points at tools/hooks (skipped)"
    elif git -C "$REPO" config core.hooksPath "$REPO/tools/hooks"
    then
        chmod +x "$REPO"/tools/hooks/* 2>/dev/null || true
        echo "  hooks - core.hooksPath set to tools/hooks"
    else
        echo "  WARNING: could not set core.hooksPath — git hooks will not run" >&2
    fi
fi

echo ""
echo "Done. Run 'exec bash' to reload the profile."
echo ""
echo "LLM backend prerequisite (CUDA):"
echo "  CMAKE_ARGS='-DGGML_CUDA=on' FORCE_CMAKE=1 pip install 'llama-cpp-python[server]==0.3.23'"

# end of file

# end of file marker
