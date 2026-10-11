#!/usr/bin/env bash
# ==============================================================================
# load-vault-env — Optional Windows-backed vault env loader
# ==============================================================================
# AI INSTRUCTION: Increment version on significant changes.
# Module Version: 9
#   v9 (2026-10-11): the Windows env bridge is FORKED, so no shell blocks on
#   pwsh.exe.  The shell pays the fork (~0.05-0.19 s) instead of the refresh
#   (1.7-2.1 s idle; 3.5-9.8 s at load 22-25) and uses the bridge it already has.
#
#   ROTATION SEMANTICS, explicitly: the shell that trips the TTL gets the OLD
#   values and the refresh lands behind it, so a credential rotated on the Windows
#   side is visible to the NEXT shell to start (typically ~2 s later), not to the
#   one that triggered the refresh.  Worst case is bounded by the TTL: a value
#   changed just after a refresh waits up to TAC_VAULT_BRIDGE_TTL (1500 s) for the
#   next trigger.  `TAC_VAULT_REFRESH_SYNC=1` restores the blocking refresh for a
#   caller that must have the new values in ITS OWN shell; `oc-refresh-keys`
#   remains the on-demand path.
#
#   The staleness risk is low on the evidence: two consecutive refreshes emitted
#   BYTE-IDENTICAL values (sha256 8a2fcb5eb037f993 both times, 2026-10-11), and the
#   emitted set is three long-lived tokens, so the fork's one-refresh lag is not a
#   window in which the values are likely to have changed.
#
#   SHORT-SHELL CAVEAT: the spawn is tracked with __tac_track_bg_job, whose pid the
#   profile's EXIT trap kills — so a shell that exits inside the refresh window
#   cancels it, and the next shell simply tries again (the TTL is still expired;
#   nothing is corrupted, and the old file is untouched until the writer rewrites
#   it).  This is the documented cost of not printing a job-control notice over the
#   dashboard, which is what the tracking buys (measured 2026-09-22: the START
#   notice is printed at fork time and a script file cannot see it).
#   v8 (2026-10-11): default TTL raised 300 -> 1500 s, after measuring every cheaper
#   alternative and finding none that removes the block.  Measured at load 4-8:
#   fetching ONE name costs 5.6 s against 6.5 s for all seven (one pwsh.exe start
#   dominates, so a subset saves ~14%, not the cost); the emitted set is 3 vars and
#   their VALUES were byte-identical across two consecutive refreshes; a cheaper
#   incantation is `reg.exe query HKCU\Environment` at 1.0-2.2 s against
#   pwsh.exe's 2.6-4.5 s and powershell.exe 5.1's 2.0-3.3 s (interleaved, load
#   12-15) — ~2x cheaper but still over a second, and it returns REG_EXPAND_SZ
#   values UNEXPANDED and only the User scope, so it is not a drop-in; and no
#   cheaper INVALIDATION signal exists, because every Windows-side probe costs at
#   least a second, leaving the local mtime as the cheapest signal there is (it is
#   the one used).  Backgrounding the refresh makes the shell cost ~0.05-0.19 s
#   instead of 3.5-9.8 s, but it is a behaviour change (see the note above the
#   guard), not a saving, and it was not adopted here.
#
#   STALENESS TRADE-OFF.  A value changed on the Windows side now takes up to
#   1500 s (25 min) to appear in a NEWLY STARTED shell; shells already open keep
#   what they exported.  These are long-lived credentials (the same three names,
#   unchanged across refreshes in the measurement above), and the forced paths
#   remain: `oc-refresh-keys` re-imports on demand, `TAC_VAULT_BRIDGE_TTL=0`
#   restores the per-shell refresh, `TAC_VAULT_REFRESH_FROM_WINDOWS=0` skips the
#   bridge entirely.
#   v7 (2026-10-11): the Windows env bridge is TTL-GUARDED.  It ran on every
#   interactive shell because the guard was "is the helper present", not "is the
#   result stale"; at 1.7-2.1 s per pwsh.exe call that was the largest single cost
#   in shell startup (measured `bash -lic true`: 3.0-6.4 s with it, 0.55-0.63 s with
#   the vault load skipped).  Refreshes now only when the bridge file is missing or
#   older than TAC_VAULT_BRIDGE_TTL, two-sided so a future mtime cannot read as
#   fresh.
# Optional helper loaded by scripts/14-wsl-extras.sh.
#
# Source (repo):   scripts/load-vault-env.sh
# Bridge (repo):   tools/import-windows-env.sh — exec'd by absolute path from the
#                  installed copy to refresh the Windows env bridge.
# Install targets: ~/.local/bin/load-vault-env.sh                  (install.sh link)
#                  ~/.openclaw/credentials/vault/load-vault-env.sh  (sourced by
#                  14-wsl-extras.sh when present — place it there to auto-load)
#                  ~/.local/bin/import-windows-env.sh               (install.sh link)
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

# The bridge is tools/import-windows-env.sh in this repo, installed by install.sh
# to ~/.local/bin.  This probe used to name scripts/17-import-windows-user-env.sh
# under ~/.openclaw/workspace/scripts/ — the file was RENAMED and moved into
# tools/ by the tools/ split (e357fbb2) without this path being updated, so the
# [[ -f ]] guard below never matched and TAC_VAULT_REFRESH_FROM_WINDOWS silently
# refreshed nothing (measured 2026-09-24: the probed path did not exist, and no
# ~/.openclaw/.env.bridge had ever been written).
_lve_bridge_script="$HOME/.local/bin/import-windows-env.sh"
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
#
# TTL GUARD (v7, default raised v8).  This crossed the WSL/Windows boundary and
# started pwsh.exe on EVERY interactive shell — measured 2026-10-11 at 1.7-2.1 s per
# call (and 2.7-9.8 s at load 12-25), making it the single largest contributor to
# shell startup.  The only guard was "is the helper present", never "is the result
# stale", so the cost was paid on every shell even when the bridge file was a second
# old.  It now refreshes only when the file is missing or older than
# TAC_VAULT_BRIDGE_TTL seconds (default 1500; 0 forces a refresh on every shell, and
# TAC_VAULT_REFRESH_FROM_WINDOWS=0 still skips the bridge entirely).
#
# ASYNCHRONOUS REFRESH (v9 — ADOPTED).  The bridge is forked, so no shell BLOCKS on
# pwsh.exe: the shell pays the fork (~0.05-0.19 s measured) instead of the refresh
# (1.7-2.1 s idle, 3.5-9.8 s at load 22-25), reads the bridge it already has, and a
# LATER shell picks up the update.  It was held back in v8 on the grounds that a
# concurrent reader could source a half-written bridge; that was REASONED, not
# reproduced, and the measurement (2026-10-11, independent verification) refuted it:
# sampling the real writer's output at microsecond resolution across a 12.8 s
# refresh never observed an intermediate size — the file goes old -> new in under
# one sampling interval, because the writer spends ~all of that time in pwsh BEFORE
# it touches the file and only microseconds in the rewrite.  A kill could not be
# timed into the window either.  So the fork is safe to adopt; see the spawn below
# for the tracking requirement.
#
# The age test is TWO-SIDED, like every other freshness guard in this profile: a
# NEGATIVE age (a future mtime, from a clock step or a writer that backdates) must
# not read as "fresh", or the refresh would be skipped until the clock caught up.
_lve_bridge_ttl="${TAC_VAULT_BRIDGE_TTL:-1500}"
if [[ -f "$_lve_bridge_script" ]]
then
    _lve_need_refresh=1
    if [[ "$_lve_bridge_ttl" =~ ^[0-9]+$ ]] && (( _lve_bridge_ttl > 0 )) && [[ -f "$_lve_bridge_file" ]]
    then
        # swallow-ok: a failed stat means the file vanished after the -f test above; epoch age = refresh
        _lve_age=$(( $(date +%s) - $(stat -c %Y "$_lve_bridge_file" 2>/dev/null || echo 0) ))
        (( _lve_age >= 0 && _lve_age < _lve_bridge_ttl )) && _lve_need_refresh=0
    fi
    if [[ "${TAC_VAULT_REFRESH_FROM_WINDOWS:-1}" != "0" && "$_lve_need_refresh" == "1" ]]
    then
        mkdir -p "$(dirname "$_lve_bridge_file")" 2>/dev/null || true
        if [[ -n "${TAC_VAULT_EXPORT_NAMES:-}" ]]
        then
            IFS=',' read -r -a _lve_names <<< "$TAC_VAULT_EXPORT_NAMES"
        else
            _lve_names=("${_lve_default_names[@]}")
        fi
        if [[ "${TAC_VAULT_REFRESH_SYNC:-0}" == "1" ]]
        then
            # The pre-v9 BLOCKING refresh, kept reachable for a caller that must have
            # the new values in THIS shell (e.g. immediately after rotating a key).
            bash "$_lve_bridge_script" "$_lve_bridge_file" "${_lve_names[@]}" >/dev/null 2>&1 || true
        else
            # FORK it: this shell never blocks on pwsh.exe.  __tac_track_bg_job records
            # the pid for the profile's EXIT trap AND disowns the job, so no "[n] Done
            # <command>" notice is printed over the dashboard render (the START notice
            # is emitted at fork time regardless, which is why the spawn must be tracked
            # rather than left bare).  Called only when defined: in library mode
            # (env.sh, non-interactive) it is absent and no notice is printed anyway.
            { bash "$_lve_bridge_script" "$_lve_bridge_file" "${_lve_names[@]}" >/dev/null 2>&1 & } 2>/dev/null
            if declare -f __tac_track_bg_job >/dev/null 2>&1
            then
                __tac_track_bg_job "$!"
            fi
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
    [[ -f "$_lve_f" ]] || continue
    # A /dev/shm candidate is only trusted when it is ours and mode 600 —
    # /dev/shm is world-writable and sourcing it executes its contents.
    if [[ "$_lve_f" == /dev/shm/* ]]
    then
        if [[ ! -O "$_lve_f" ]] || [[ "$(stat -c '%a' "$_lve_f" 2>/dev/null)" != "600" ]]
        then
            continue
        fi
    fi
    _lve_existing_files+=("$_lve_f")
done

if (( ${#_lve_existing_files[@]} == 0 ))
then
    unset _lve_f _lve_candidate_files _lve_existing_files _lve_bridge_script _lve_bridge_file
    unset _lve_default_names _lve_names _lve_tmp_file
    unset _lve_bridge_ttl _lve_need_refresh _lve_age
    # shellcheck disable=SC2317
    return 0 2>/dev/null || exit 0
fi

_lve_tmp_file=$(mktemp)

# Restrict exports to the known credential names (the same allowlist the bridge
# uses) so a stray key in a vault file is not exported, and so
# TAC_VAULT_EXPORT_NAMES means what its name says. An empty allowlist disables
# filtering.
if [[ -n "${TAC_VAULT_EXPORT_NAMES:-}" ]]
then
    _lve_allow_csv="$TAC_VAULT_EXPORT_NAMES"
else
    _lve_allow_csv="$(IFS=','; echo "${_lve_default_names[*]}")"
fi

# Parse KEY=VALUE files and emit validated export lines.
"${TAC_PYTHON:-python3}" - "$_lve_tmp_file" "$_lve_allow_csv" "${_lve_existing_files[@]}" <<'PY'
import pathlib
import re
import shlex
import sys

out_path = pathlib.Path(sys.argv[1])
allow = {k.strip() for k in sys.argv[2].split(',') if k.strip()}
files = [pathlib.Path(p) for p in sys.argv[3:]]
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
        if allow and key not in allow:
            continue
        raw = raw.strip()
        if raw == '':
            continue
        try:
            tokens = shlex.split(raw, posix=True)
            value = tokens[0] if len(tokens) == 1 else raw
        except Exception as exc:
            print(f"[load-vault-env] WARNING: could not parse value for {key}: {exc}", file=sys.stderr)
            value = raw
        env[key] = value

with out_path.open('w', encoding='utf-8') as f:
    for key in sorted(env.keys()):
        f.write(f'export {key}={shlex.quote(env[key])}\n')
PY

# shellcheck disable=SC1090  # $_lve_tmp_file is generated by the python block above;
#                             # there is no static file for the linter to follow.
source "$_lve_tmp_file" 2>/dev/null || true

_lve_cleanup

unset _lve_f _lve_candidate_files _lve_existing_files _lve_bridge_script _lve_bridge_file
unset _lve_default_names _lve_names _lve_tmp_file _lve_allow_csv
unset _lve_bridge_ttl _lve_need_refresh _lve_age
unset -f _lve_cleanup

# shellcheck disable=SC2317  # this file is both sourced and executed: `return` is the
                            # sourced path, `exit` the executed one, so neither is dead.
return 0 2>/dev/null || exit 0

# end of file

# end of file marker
