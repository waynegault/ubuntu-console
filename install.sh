#!/usr/bin/env bash
# install.sh — Set up the Tactical Console Profile on a new machine.
# Run from the repo root: ./install.sh
# Idempotent: safe to re-run.
# AI INSTRUCTION: Increment version on significant changes.
# v1.16 (2026-10-30, repo relocation): `systemctl --user enable` records an ABSOLUTE
#   path in *.wants/ when the unit file is itself a symlink into this repo, so moving the
#   repo left six lanes and eight timers ENABLED IN NAME ONLY - dangling links, units
#   systemd could no longer load, and an install that still reported success.  A dangling
#   enable link whose basename names a unit installed here is now repointed at the unit
#   NAME (systemd's own relative shape), so it also survives the NEXT move.
# v1.15 (2026-10-30): the ~/.bashrc loader is now a TRACKED TEMPLATE (dotfiles/bashrc)
#   rendered by this script instead of a heredoc inside it — so the installed loader has
#   its own history and diff rather than existing only as a fragment of a 700-line
#   installer. The rendered file names the profile path DIRECTLY, and the refresh rule
#   now rewrites a loader that reaches it through a SYMLINK as well as one that names a
#   dead path. Measured before this: the loader read /home/wayne/ubuntu-console/… (a
#   symlink), so removing that convenience link would have turned every new shell into
#   "[WARNING] Tactical Console Profile not found".
# v1.14 (2026-10-30): a symlink that points into this repo but belongs to ANOTHER
#   host profile is disabled (best effort, named) and removed.  Skipping it was not
#   enough on a box installed before this layer: measured 2026-10-30, the ASUS box
#   kept this repo's CPU lane as a live, enabled and failing unit.
# v1.13 (2026-10-29, host profiles): the installer resolves WHICH box it is on
#   (tools/host-profile.sh) before linking systemd units, and links only the units
#   marked `# install-profile: <id>` for that profile plus the unmarked shared set.
#   No profile is a hard refusal: linking every lane on an unknown machine is how a
#   CUDA lane naming this box's model file lands on a different box.  The id is
#   chosen by LLM_HOST_PROFILE or ~/.llm/host-profile, else detected from arch + card.
# v1.12 (2026-10-24, card SYSTEMD-DROPIN-INSTALL-001): a `systemd/*.conf` is a DROP-IN
#   source, not a unit. The user-unit loop skipped only directories, so every .conf was
#   linked into ~/.config/systemd/user/ as a non-unit stray that systemd ignored silently —
#   while the drop-in destination each file documents was never created, leaving a fresh box
#   with the strays and none of the settings. Each .conf now declares its own destinations on
#   `# install-dropin: <unit> <name>` lines (`system/<unit>` for the root-owned set); this
#   installer reads them, links the user ones into <unit>.d/, copies the root-owned ones under
#   the existing `sudo -n` gate, removes a stray an older install left behind, and WARNS on a
#   .conf that declares no destination rather than installing nothing.
# v1.11 (2026-10-08, card c0c6df3d): the VS Code Testing results-logger's two halves are
#   now delivered from this repo — tools/vscode-pytest-log/vscode-pytest-log-patch.py and
#   tools/vscode-pytest-log/vscode_pytest_log.py — so the patch bin/qwen-guard-selfheal.sh
#   re-applies every cron tick has a source anyone can read.  They are tracked under tools/,
#   not bin/, because the shell lint gate treats every bin/* file as a shell script; the two
#   links below deliver them to ~/.local/bin and ~/.local/lib/vscode-pytest-log/.
# v1.10 (2026-10-03, card 5c20ae57): the legacy unit ALIAS loop runs AFTER the
#   systemd/* linking loop (it ran before it, so on a FIRST install the target
#   units did not exist yet and every alias was skipped), and a skipped alias now
#   names its missing target on stderr instead of passing silently.
VERSION="1.16"
set -euo pipefail

# --version (diagnostic; also keeps VERSION referenced, so no SC2034 suppression).
if [[ "${1:-}" == "--version" || "${1:-}" == "-V" ]]
then
    echo "install.sh $VERSION"
    exit 0
fi

REPO="$(cd "$(dirname "$0")" && pwd)"
PROFILE_PATH="$REPO/tactical-console.bashrc"
# The ~/.bashrc loader is a TRACKED template (dotfiles/bashrc), rendered here with
# this clone's profile path. It used to be a heredoc in this script; v1.15 moved
# it into the repo so the installed loader has its own history and diff.
BASH_RC_TEMPLATE="$REPO/dotfiles/bashrc"

# warn — Report a problem on stderr.  This is the ONLY place in this script that
# writes to stderr (inspection §10.7): every message below is routed through it,
# so the redirect exists once rather than at each call site.  Each argument
# prints on its own line.
warn() {
    printf '%s\n' "$@" >&2
}

# ── Host profile (WHICH box this is) ─────────────────────────────────────────
# This repo serves more than one machine, and a machine-specific lane unit must
# never be linked onto the wrong one: a CUDA lane pointing at this box's model
# file would start on another box and fail, or, worse, serve the wrong card's
# model.  Every `systemd/*` unit that is not shared carries
# `# install-profile: <id>`; this installer links the shared ones plus the ones
# marked for the resolved profile and skips the rest BY NAME.
#
# No profile here is a REFUSAL, not a default: an install is the moment the box's
# identity must be settled, and linking every unit on an unknown machine is
# exactly the defect this block prevents.  The override (LLM_HOST_PROFILE, or an id
# on a line in ~/.llm/host-profile) is stated in the message.
# shellcheck source=/dev/null
source "$REPO/tools/host-profile.sh"
if ! HOST_PROFILE="$(tac_host_profile_selected)"
then
    warn "ERROR: cannot determine this host's profile — refusing to install lane units." \
         "       Profiles: $(tac_host_profile_ids | tr '\n' ' ')" \
         "       Fix: record this box's id on a line in ~/.llm/host-profile" \
         "            (or export LLM_HOST_PROFILE=<id>), then re-run ./install.sh"
    exit 2   # 2 = usage: this machine has no resolvable host profile
fi
echo "  host profile: $HOST_PROFILE"

append_loader_block() {
    cat <<LOADER
# Tactical Console loader
# Appended to a ~/.bashrc that already existed, so the rest of that file stays.
# The path is written LITERALLY and directly — see dotfiles/bashrc for why this
# loader must never reach the profile through a symlink (v1.15).
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
        warn "  ERROR: $src is not executable — refusing to install a broken shim" \
             "         Fix: chmod +x $src  (and commit the mode change)"
        return 1
    fi
    mkdir -p "$(dirname "$dest")"
    printf '#!/usr/bin/env bash\nexec %q "$@"\n' "$src" > "$dest"
    chmod 755 "$dest"
    echo "  $dest -> launcher for $src"
}

echo "Installing Tactical Console from $REPO ..."
echo ""

# ── ~/.bashrc: render the tracked template ──────────────────────────────────
# write_thin_bashrc — render dotfiles/bashrc with THIS clone's profile path.
# The rendered file names an ABSOLUTE path directly; it never reaches the profile
# through a symlink such as ~/ubuntu-console, because removing that convenience
# link would turn every new shell into a "[WARNING] not found" (v1.15).
write_thin_bashrc() {
    local template="$BASH_RC_TEMPLATE"
    local target="$HOME/.bashrc"
    local staged
    if [[ ! -f "$template" ]]
    then
        warn "ERROR: missing $template — cannot render ~/.bashrc" \
             "       (the template is tracked: git -C \"$REPO\" checkout dotfiles/bashrc)"
        return 1
    fi
    staged=$(mktemp) || return 1
    if ! sed "s|@TACTICAL_PROFILE@|$PROFILE_PATH|g" "$template" > "$staged"
    then
        warn "ERROR: could not render $template into $target"
        rm -f "$staged"
        return 1
    fi
    chmod 600 "$target" 2>/dev/null || true
    cat "$staged" > "$target"
    rm -f "$staged"
    chmod 444 "$target" 2>/dev/null || true
}

# Thin ~/.bashrc loader (rendered from the tracked template, never symlinked)
if [[ ! -f "$HOME/.bashrc" ]]
then
    if write_thin_bashrc
    then
        echo "  ~/.bashrc - created thin loader (rendered from dotfiles/bashrc)"
    else
        warn "  WARNING: ~/.bashrc was not created"
    fi
else
    # Which profile does ~/.bashrc already load, if any? Only a `source`/`.`
    # line counts (matching the bare filename would false-positive on prose).
    _loader_ref=$(grep -E '^[[:space:]]*(source|\.)[[:space:]]+' "$HOME/.bashrc" 2>/dev/null \
                  | grep -oE '[^"[:space:]]*tactical-console\.bashrc' | head -1 || true)
    _loader_needs_fix=0
    _loader_why=""
    if [[ -n "$_loader_ref" && "$_loader_ref" != "$PROFILE_PATH" && "$_loader_ref" != *'$'* ]]
    then
        if [[ ! -f "$_loader_ref" ]]
        then
            # A LITERAL path that no longer exists: the repo moved, so refresh the
            # line — otherwise every new shell warns "not found at <old path>" and a
            # re-run of this installer would keep skipping it.
            _loader_needs_fix=1
            _loader_why="stale"
        else
            # The path resolves TODAY, but through a symlink (~/ubuntu-console was
            # the common case). That is a warning waiting for the day the link is
            # removed: the loader must name the repo directly (v1.15).
            _loader_resolved=$(readlink -f "$_loader_ref" 2>/dev/null || true)
            if [[ -n "$_loader_resolved" && "$_loader_resolved" != "$_loader_ref" ]]
            then
                _loader_needs_fix=1
                _loader_why="symlinked"
            fi
        fi
    fi
    if [[ "$_loader_needs_fix" -eq 1 ]]
    then
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
            if [[ "$_loader_why" == "symlinked" ]]
            then
                echo "  ~/.bashrc - loader path $PROFILE_PATH (was symlinked via $_loader_ref)"
            else
                echo "  ~/.bashrc - refreshed stale loader path"
            fi
        else
            warn "  WARNING: could not refresh the loader path in ~/.bashrc"
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
    || warn "  WARNING: could not set ~/.bashrc read-only (continuing)"
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
    _bn="${f##*/}"
    case "$_bn" in
        llama-gpu-clear.sh|gpu-busy.sh|llama-cuda-server|llama-xe-server|llama-cpu-server)
            launcher "bin/$_bn" "$HOME/.local/bin/$_bn" ;;
        *)
            link "bin/$_bn" "$HOME/.local/bin/$_bn" ;;
    esac
done

# The VS Code Testing results-logger's TWO halves are tracked under tools/vscode-pytest-log/
# rather than bin/, because tools/lint.sh runs `bash -n` and shellcheck over every bin/*
# file — a Python file there fails both (measured: "syntax error near unexpected token `('",
# rc 2).  Each is delivered to the path its own consumer expects: the patcher onto
# ~/.local/bin, where bin/qwen-guard-selfheal.sh probes it by absolute path, and the recorder
# into ~/.local/lib/vscode-pytest-log, where the patched extension wrapper imports it from.
#
# Both are tracked so the patch the self-heal cron re-applies every tick has a source anyone
# can read, instead of existing only in ~/.local (card VSCODE-PYTEST-LOG-UNVERSIONED-001,
# c0c6df3d).
link "tools/vscode-pytest-log/vscode-pytest-log-patch.py" "$HOME/.local/bin/vscode-pytest-log-patch.py"
link "tools/vscode-pytest-log/vscode_pytest_log.py" "$HOME/.local/lib/vscode-pytest-log/vscode_pytest_log.py"

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
        warn "  WARNING: llama-${_card}-server not installed — skipped $_name"
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

# Additional utility scripts that are expected to be directly executable.
# tools/import-windows-env.sh is listed here, not under bin/, because
# scripts/load-vault-env.sh execs it by absolute path to refresh the Windows env
# bridge.  Nothing installed it, so the probe there never matched and
# TAC_VAULT_REFRESH_FROM_WINDOWS silently never refreshed anything (measured
# 2026-09-24).
for _rel in scripts/load-vault-env.sh scripts/oc-update-enhanced.sh \
            tools/import-windows-env.sh
do
    [[ -f "$REPO/$_rel" ]] || continue
    link "$_rel" "$HOME/.local/bin/${_rel##*/}"
done

# `oc health` PREFERS a richer checker when it finds one at
# $HOME/.openclaw/workspace/scripts/oc-health-check.py, and returns before its own
# rows when it does (scripts/09e-oc-health.sh).  Nothing placed the checker there,
# so that branch was dead code on every box while the file was maintained in this
# repo (measured 2026-09-24).  Symlink it into the path the probe reads.
if [[ -f "$REPO/scripts/oc-health-check.py" ]]
then
    link "scripts/oc-health-check.py" "$HOME/.openclaw/workspace/scripts/oc-health-check.py"
fi

# 14-wsl-extras.sh sources load-vault-env.sh from the vault directory, so place
# it there too — otherwise `TAC_LOAD_VAULT=1` silently loads nothing after a
# fresh install.
if [[ -f "$REPO/scripts/load-vault-env.sh" ]]
then
    mkdir -p "$HOME/.openclaw/credentials/vault"
    link "scripts/load-vault-env.sh" "$HOME/.openclaw/credentials/vault/load-vault-env.sh"
fi

# Systemd units
# `systemd/*` is the USER unit set (symlinked into ~/.config/systemd/user/).
# The subdirectory `systemd/system` is a separate, root-owned set and is skipped
# here by the -f test below — do not turn that test into a glob that recurses.
# A `*.conf` is NOT a unit: it is a drop-in, and it names its own destinations on
# `# install-dropin:` lines, which the block after this loop installs. Linking one
# here put a stray in the unit dir that systemd ignored silently (card
# SYSTEMD-DROPIN-INSTALL-001), so .conf files are skipped rather than linked.
#
# A unit marked `# install-profile: <id>` belongs to ONE box's lane set and is
# linked only where that id matches; an unmarked unit is shared infrastructure
# (watchdogs, timers, samplers) and is linked everywhere.  The marker is read from
# the file, beside the ExecStart it applies to, so a new lane cannot be added
# with its ownership declared in some other file.
for f in "$REPO"/systemd/*
do
    [[ -f "$f" ]] || continue
    _bn="${f##*/}"
    if [[ "$_bn" == *.conf ]]
    then
        continue
    fi
    _unit_profile="$(tac_host_unit_profile "$f")"
    if [[ "$_unit_profile" != "any" && "$_unit_profile" != "$HOST_PROFILE" ]]
    then
        echo "  skipped systemd/$_bn (belongs to profile: $_unit_profile)"
        continue
    fi
    link "systemd/$_bn" "$HOME/.config/systemd/user/$_bn"
done
unset _unit_profile

# ── Stale links for a DIFFERENT profile ─────────────────────────────────────
# Skipping a unit is not enough on a box that was installed before this layer, or
# under a different profile: the old symlink stays in the unit dir and systemd keeps
# starting a lane that names another machine's model file. Measured 2026-10-30 — the
# ASUS box carried this repo's CPU lane as a live, ENABLED and failing unit exactly
# that way. So a symlink that points INTO this repo but is owned by another profile
# is disabled (best effort, its name reported) and removed. Only links into
# $REPO/systemd/ are touched; anything the operator owns is left alone.
#
# ...and the comparison is made on PHYSICAL paths.  Measured 2026-10-30 on the ASUS
# box: `~/ubuntu-console` is a symlink to this clone, so $REPO is
# the logical path while `readlink -f` returns the physical one.  (Measured when the
# clone root was still `~/github-wsl`; the root has since been renamed to `~/github`,
# and the fix is indifferent to which of the two you reach it through — that is the point.)  The sweep matched
# nothing and removed nothing — the v1.14 fix above, shipped, did not fire on the very
# box it was written for, while every test passed because a test fixture's repo root
# is not a symlink.  Same shape as "green because out of scope": the check was honest
# and its scope was the test's layout, not the box's.
_repo_phys="$(cd "$REPO" && pwd -P)"
for _stale in "$HOME"/.config/systemd/user/*
do
    [[ -L "$_stale" ]] || continue
    _stale_tgt="$(readlink -f "$_stale")" || continue
    [[ "$_stale_tgt" == "$_repo_phys"/systemd/* ]] || continue
    _stale_owner="$(tac_host_unit_profile "$_stale_tgt")"
    [[ "$_stale_owner" == "any" || "$_stale_owner" == "$HOST_PROFILE" ]] && continue
    if systemctl --user is-enabled --quiet "${_stale##*/}" 2>/dev/null
    then
        if ! systemctl --user disable "${_stale##*/}" >/dev/null 2>&1
        then
            warn "  WARNING: could not disable ${_stale##*/} before removing its link" \
                 "           it belongs to profile '$_stale_owner', not '$HOST_PROFILE'"
        fi
    fi
    rm -f "$_stale"
    echo "  removed ${_stale##*/} (belongs to profile: $_stale_owner)"
done
unset _stale _stale_tgt _stale_owner _repo_phys

# -- Enable-time links that name an ABSOLUTE path ----------------------------
# `systemctl --user enable` records WHERE the unit file is, and these units are
# themselves symlinks into this repo, so the enable link is a *.wants/*.requires
# entry naming an absolute path (`.../ubuntu-console/systemd/x.service`).  Nothing
# in this installer creates that path, so when the repo MOVES every enabled lane
# stays enabled in name only: the link dangles, systemd cannot load the unit, and
# the install still reports success -- measured 2026-10-30, a relocation left six
# lanes and eight timers dangling exactly that way.  Repairing a dangling link as a
# RELATIVE link to the unit NAME (systemd's own shape for a unit in this directory)
# also survives the next move.  Only a dangling link whose basename names a unit
# installed here is touched; anything else in those directories is the operator's.
for _want in "$HOME"/.config/systemd/user/*.wants/* "$HOME"/.config/systemd/user/*.requires/*
do
    [[ -L "$_want" ]] || continue
    [[ -e "$_want" ]] && continue
    _want_name="${_want##*/}"
    [[ -e "$HOME/.config/systemd/user/$_want_name" ]] || continue
    ln -sfn "../$_want_name" "$_want"
    echo "  repaired stale enable link ${_want#"$HOME"/} -> ../$_want_name"
done
unset _want _want_name

# ── Drop-in sources (systemd/*.conf) ─────────────────────────────────────────
# A .conf here is a drop-in for one or more units, and it declares every destination
# itself on `# install-dropin: <unit> <name>` lines (`system/<unit> <name>` for the
# root-owned set). Reading the mapping FROM THE FILE keeps it beside the setting it
# applies: a map inside this installer drifts the moment a .conf is added and the map
# is not, which is the defect this block closes (card SYSTEMD-DROPIN-INSTALL-001).
_dropin_user=()
_dropin_sys=()
for f in "$REPO"/systemd/*.conf
do
    [[ -f "$f" ]] || continue
    _src="${f##*/}"
    _declared=0
    while read -r _target _name _extra
    do
        _declared=1
        if [[ -z "$_target" || -z "$_name" || -n "$_extra" ]]
        then
            # Named rather than skipped: the destination a malformed line meant to give
            # would otherwise be installed nowhere.
            warn "  WARNING: systemd/$_src has a malformed '# install-dropin:' line — skipped"
            continue
        fi
        if [[ "$_target" == system/* ]]
        then
            _dropin_sys+=("${_target#system/}|$_name|$_src")
        else
            _dropin_user+=("$_target|$_name|$_src")
        fi
    done < <(sed -n 's/^# install-dropin:[[:space:]]*//p' "$f")
    if (( _declared == 0 ))
    then
        # Not silence: a .conf with no declaration would otherwise be installed
        # nowhere, and the setting it carries would simply be absent from the machine.
        warn "  WARNING: systemd/$_src declares no '# install-dropin:' line — NOT installed" \
             "           add one per destination: # install-dropin: <unit> <name>"
    fi
done

# An older install linked every systemd/* file here, so a .conf could be sitting in the
# unit dir as a non-unit symlink that systemd ignores without a word. Remove only the
# symlinks that point into this repo's systemd/ — anything else here is the operator's.
for _stray in "$HOME"/.config/systemd/user/*.conf
do
    [[ -L "$_stray" ]] || continue
    _stray_tgt=$(readlink -f "$_stray") || continue
    if [[ "$_stray_tgt" == "$REPO"/systemd/* ]]
    then
        rm -f "$_stray"
        echo "  removed stray $_stray (a drop-in source, not a unit)"
    fi
done
unset _stray _stray_tgt

for _row in "${_dropin_user[@]}"
do
    IFS='|' read -r _unit _name _src <<< "$_row"
    link "systemd/$_src" "$HOME/.config/systemd/user/$_unit.d/$_name"
done
unset _row _unit _name _src

# Legacy UNIT names, as RELATIVE alias symlinks — deliberately not systemd's
# [Install] Alias=.  Because the unit files are themselves symlinks into this repo,
# `systemctl enable` materialises its alias with an ABSOLUTE target, and systemd
# then loads that as a SEPARATE unit: two units for one service, with is-active
# lying about both.  The investigator found this on 2026-09-15, after it had already
# put a live CUDA lane down — their name-keyed check read the lane as inactive, and
# ours could have added a second server to the card.  A relative symlink to the unit
# NAME merges the two: one Id, one state, both names.
#
# ORDER (card 5c20ae57): this loop runs AFTER the unit-linking loop above.  It used
# to run BEFORE it, so on a FIRST install the target unit did not exist yet and the
# `-e` guard skipped EVERY alias (a re-run happened to work, which hid it).  The
# else-branch now NAMES any target that is still absent instead of skipping quietly.
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
    elif [[ -L "$HOME/.config/systemd/user/$_old" ]] \
         && [[ "$(readlink "$HOME/.config/systemd/user/$_old")" == "$_new" ]]
    then
        # The alias exists but its target does not: the target was removed above as
        # another host profile's.  A dangling alias still makes
        # `systemctl --user list-unit-files` name something nothing resolves, so it
        # goes with its target.  Only an alias pointing at THIS pair's target goes.
        rm -f "$HOME/.config/systemd/user/$_old"
        echo "  removed alias $_old (target $_new is not installed on this box)"
    else
        warn "  WARNING: alias $_old skipped — target $_new is not installed"
    fi
done

# Retired UNIT names (2026-09-15): the Phi-4-mini decomposition lane was removed
# from the repo, so its installed unit link and its legacy alias both dangle.
# Remove them explicitly — the alias target is a BARE name, so a "prune links whose
# target left the repo" pass cannot see it, and `systemctl --user list-unit-files`
# would keep listing a name nothing resolves to.
# llama-xe-qwen25-3b-chat.service joins them as a RENAME, not a removal: it became
# llama-xe-llama32-3b-chat.service on 2026-10-26 (the old name still claimed the
# weights the 2026-10-02 bake-off replaced), and it is retired with no alias.
for _stale in llama-cuda-phi4-mini-decompose.service llama-server-phi4.service \
              llama-xe-qwen25-3b-chat.service
do
    if [[ -L "$HOME/.config/systemd/user/$_stale" ]]; then
        rm -f "$HOME/.config/systemd/user/$_stale"
        echo "  removed retired unit $_stale"
    fi
done

if command -v systemctl >/dev/null 2>&1
then
    # Reported, not swallowed: a failed reload leaves the freshly linked units
    # invisible to systemd, and the next `so` then fails with a confusing
    # "unit not found" rather than naming the cause.
    systemctl --user daemon-reload >/dev/null 2>&1 \
        || warn "  WARNING: systemctl --user daemon-reload failed — user units may not be active until reloaded"
fi

# ── System units (/etc/systemd/system) ───────────────────────────────────────
# The user units above run as wayne.  Some host facts need root: loopback0 — the
# dummy interface WSL2 mirrored networking does not create, which OpenClaw's
# node-to-node 127.0.0.2 traffic needs — cannot be brought up by a user unit.
# Those units live in systemd/system/ and are COPIED (not symlinked) into
# /etc/systemd/system: a root-owned unit pointing into a user's home is a
# boot-time dependency on that home being mounted and readable.
#
# This is install.sh's only privileged step, so it is deliberately narrow:
#   * `sudo -n` only — it must never prompt, or an unattended install would hang;
#   * with no passwordless sudo (CI, a container) it SKIPS with the commands to
#     run by hand, so an unprivileged install still completes;
#   * it enables AND starts each unit, so re-running install.sh repairs a machine
#     whose loopback0 is missing without needing a reboot.
_sys_units=()
for f in "$REPO"/systemd/system/*
do
    [[ -f "$f" ]] || continue
    _sys_units+=("${f##*/}")
done

if (( ${#_sys_units[@]} == 0 ))
then
    # Not silence: this repo ships tac-loopback0.service, so an empty set means
    # a broken checkout, and silently installing no systemd units would be
    # indistinguishable from a machine that needs none.
    warn "  WARNING: systemd/system/ holds no unit files (expected tac-loopback0.service)"
elif sudo -n true 2>/dev/null
then
    _sys_changed=0
    for _bn in "${_sys_units[@]}"
    do
        if cmp -s "$REPO/systemd/system/$_bn" "/etc/systemd/system/$_bn" 2>/dev/null
        then
            echo "  /etc/systemd/system/$_bn - already current (skipped)"
        else
            sudo install -m 644 "$REPO/systemd/system/$_bn" "/etc/systemd/system/$_bn"
            echo "  /etc/systemd/system/$_bn - installed"
            _sys_changed=1
        fi
    done
    if (( _sys_changed ))
    then
        sudo systemctl daemon-reload
    fi
    for _bn in "${_sys_units[@]}"
    do
        sudo systemctl enable "$_bn" >/dev/null 2>&1 \
            || warn "  WARNING: could not enable $_bn"
        if ! systemctl is-active --quiet "$_bn"
        then
            sudo systemctl start "$_bn" \
                || warn "  WARNING: $_bn failed to start — see: systemctl status $_bn"
        fi
    done
    unset _sys_changed
else
    warn "  WARNING: passwordless sudo unavailable — system units NOT installed" \
         "           run: sudo install -m 644 $REPO/systemd/system/* /etc/systemd/system/" \
         "           and: sudo systemctl enable --now ${_sys_units[*]}"
fi
unset _sys_units

# ── System drop-ins (/etc/systemd/system/<unit>.service.d) ───────────────────
# The same declarations, at the root-owned destinations: `system/<unit> <name>`.
# `sudo -n` only, as above — an unattended install must never hang on a prompt, and
# with no passwordless sudo the commands are printed instead of silently skipped.
if (( ${#_dropin_sys[@]} ))
then
    if sudo -n true 2>/dev/null
    then
        _sysd_changed=0
        for _row in "${_dropin_sys[@]}"
        do
            IFS='|' read -r _unit _name _src <<< "$_row"
            # The declaration carries the FULL unit name (`….service`), and a drop-in
            # directory is `<unit>.d` — appending `.service.d` here produced
            # `….service.service.d`, which systemd would never read.
            _dest="/etc/systemd/system/$_unit.d/$_name"
            if cmp -s "$REPO/systemd/$_src" "$_dest" 2>/dev/null
            then
                echo "  $_dest - already current (skipped)"
            else
                sudo install -Dm644 "$REPO/systemd/$_src" "$_dest"
                echo "  $_dest - installed"
                _sysd_changed=1
            fi
        done
        if (( _sysd_changed ))
        then
            sudo systemctl daemon-reload
        fi
        unset _sysd_changed
    else
        warn "  WARNING: passwordless sudo unavailable — system drop-ins NOT installed"
        for _row in "${_dropin_sys[@]}"
        do
            IFS='|' read -r _unit _name _src <<< "$_row"
            _dest="/etc/systemd/system/$_unit.d/$_name"
            warn "           run: sudo install -Dm644 $REPO/systemd/$_src $_dest"
        done
    fi
fi
unset _dropin_sys _dropin_user _row _unit _name _src

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
        warn "  WARNING: could not set core.hooksPath — git hooks will not run"
    fi
fi

# Qwen CLI agent hooks — tracked in tools/qwen-hooks/ and linked to the ABSOLUTE
# paths the CLI already has registered in ~/.qwen/settings.json.  The CLI names a
# hook by absolute path, so that path must keep resolving or the hook is silently
# disabled; the four files used to sit as loose, unversioned copies in
# ~/.qwen/hooks/ (post-edit-check.sh is one Wayne relies on).  A symlink keeps
# every registered path valid while the implementation stays repo-owned and
# reviewable beside docs/qwen-shell-guard-audit.md.  Deliberately NOT under
# tools/hooks/: that directory is core.hooksPath, so only real Git hook names
# belong in it.
if [[ -d "$REPO/tools/qwen-hooks" ]]
then
    for _qh in "$REPO"/tools/qwen-hooks/*
    do
        [[ -f "$_qh" ]] || continue
        link "tools/qwen-hooks/${_qh##*/}" "$HOME/.qwen/hooks/${_qh##*/}"
    done
    unset _qh
else
    warn "  WARNING: $REPO/tools/qwen-hooks is missing — the Qwen CLI hooks will NOT be installed"
fi

echo ""
echo "Done. Run 'exec bash' to reload the profile."
echo ""
echo "LLM backend prerequisite (CUDA):"
echo "  CMAKE_ARGS='-DGGML_CUDA=on' FORCE_CMAKE=1 pip install 'llama-cpp-python[server]==0.3.23'"

# end of file

# end of file marker
