#!/usr/bin/env bash
# Self-heal guard for the Qwen daemon's read-only-git patch AND the Qwen CLI's
# memory-index patch.
#
# WHY: qwen-guard-patch.sh patches `daemon-git-worktree-guard-*.js` inside the
# VS Code extension bundle. Every extension update replaces that chunk and
# silently reverts the patch (back to the two-verb allowlist, so `git -C <other
# repo> log|status|diff` is denied as "mutating"). This guard re-applies it.
#
# The same watchdog also covers qwen-memory-index-patch.sh, which patches the
# Qwen CLI's own memory-index builder so it stops truncating every MEMORY.md
# index line at 150 chars -- a cut that lands inside the "](path)" link and
# leaves the entry unresolvable.  That patch lives on a FOREIGN bundle too (four
# copies: the linuxbrew CLI, the VS Code companion, the npm update cache, and the
# Windows-side companion), so any CLI/companion update reverts it just like the
# guard patch -- and a reverted index patch fails silently, chopping links.
#
# The third patch (2026-10-02) is qwen-memory-style-patch.sh: the same foreign
# bundle, a different mechanism.  The CLI's managed auto-memory extractor rewrites
# the ~/.qwen memory notes after user turns, and its prompt states no emphasis
# style, so it mixes asterisk spans into files whose dominant style is underscore
# -- which the store's linter flags (MD049 at its default, consistency WITHIN a
# file).  Measured, the asterisk-span count on one note rose 2 -> 4 -> 7 across
# successive passes, so the writer re-creates the violation class it is editing
# around.  That patch states the style in the extractor's prompt.  Same reversion
# risk, same watchdog.
#
# The FOURTH (2026-10-05, card 75b9cfcc) is the Workboard comment-cap patch,
# ~/.openclaw/scripts/workboard-commentcap-patch.sh.  It patches a FOREIGN bundle of its
# own -- the Gateway's runtime-api-<hash>.mjs -- whose filename carries a content hash, so
# every OpenClaw upgrade reverts it.  Measured 2026-10-05: it HAD been reverted, and
# NOTHING invoked the patcher, so a card carrying a comment over the 2000-char cap could
# no longer be read (NIGHTLY-RED-001, b736803c, 2272 chars).  It already had its own
# --check (added 2026-10-03); this watchdog is the place it gets invoked.  A re-applied
# patch needs a GATEWAY RESTART to take effect, which a cron tick cannot perform: the tick
# re-applies and reports; the restart stays the operator's.
#
# The FIFTH (2026-10-07) is the VS Code Testing results-logger patch,
# ~/.local/bin/vscode-pytest-log-patch.py.  It patches a FOREIGN bundle too -- the
# ms-python.python extension's pytest wrapper, one copy per installed extension
# version -- so every Python-extension update reverts it, exactly as the guard and
# memory-index patches revert on their own updates.  Measured 2026-10-07: the patch
# HAD reverted (the `oc health` row read "an extension update reverts this") and only
# a human re-applied it, because nothing periodic invoked the tool; a reverted logger
# fails SILENTLY -- Testing runs simply stop being recorded to ~/.cache/vscode-pytest.
# Unlike its four siblings its --check is not boolean (0 patched, 1 a reverted copy,
# 2 no Python extension at all, 3 the recorder FILE is missing), so the added entry is
# gated on rc==1 and rc==3 is REPORTED (an --apply cannot restore a missing recorder:
# the tool refuses on rc==3 before it patches anything).
#
# The SIXTH (2026-10-10) is the plugin-skill hardlink self-heal,
# ~/.openclaw/scripts/skill-denlink.sh.  It is NOT a bundle patch like its five siblings:
# OpenClaw's OWN plugin-admission capture hardlinks the installed plugin into
# tmp/plugin-captures/…, so the plugin's SKILL.md carries nlink>1, and the skills loader
# refuses any file with nlink>1 -- logging "Skipping invalid skill: … error=path must not
# be hardlinked" on every catalog and leaving the skill silently ABSENT.  Re-materialising
# the installed file to a fresh inode clears it, but the next admission re-creates the
# link, so this tick re-applies it.  Measured 2026-10-09/10 on the agentmail plugin; filed
# upstream as openclaw/openclaw#167991 and recorded as workspace-jarvis issue 0037.  Its
# --check is boolean (0 clean, 1 needs repair), like the four older patchers.
#
# Run from cron. Deliberately quiet when healthy: it does nothing and prints
# nothing when every patch is already in place, and it only writes a record when
# it actually had to act. When it CANNOT restore a patch it exits non-zero, so a
# failed run no longer reports success -- but note that this box has NO mail
# transport (no msmtp/sendmail/postfix, empty /var/mail), so the exit status alone
# reaches nobody: delivering that failure is still an open item.
#
# Idempotency comes from each patch script itself, which refuses to patch a bundle
# whose shape changed rather than patching blind.
#
# TRACKED HERE since 2026-10-01: this script lived only as a loose copy at
# ~/.local/bin/qwen-guard-selfheal.sh, so the one thing that notices a reverted guard
# patch was unversioned.  `install.sh` links every file in `bin/` into ~/.local/bin, so
# the CRON ENTRY IS UNCHANGED: the 17,47 * * * * job invokes the stable path
# ~/.local/bin/qwen-guard-selfheal.sh, which keeps resolving — now as a symlink to
# this file.  Nothing about the schedule or the command has to move.
#
# AI INSTRUCTION: Increment version on significant changes.
# Module Version: 7
#   v7 (2026-10-10): a SIXTH tool is announced -- the plugin-skill hardlink self-heal
#   (~/.openclaw/scripts/skill-denlink.sh), probed with its own boolean --check and
#   re-applied per tick.  It clears the nlink>1 that OpenClaw's own plugin-admission
#   capture puts on the installed plugin's SKILL.md, which the skills loader then refuses
#   (so the skill is silently absent).  Unlike its five siblings it is not a bundle patch
#   and it RECURS on every admission; measured 2026-10-09/10 on agentmail
#   (openclaw/openclaw#167991).
# Module Version: 6
#   v6 (2026-10-07): a FIFTH tool is announced -- the VS Code Testing results-logger
#   patcher (~/.local/bin/vscode-pytest-log-patch.py), probed with its own --check and
#   re-applied like its siblings, but rc-aware: only rc==1 (a reverted copy) is
#   auto-repairable; rc==2 (no extension copy) is quiet, and rc==3 (the recorder file
#   is missing) is REPORTED with a non-zero exit because --apply cannot restore it.
#   Measured: the patch had reverted and only a human had put it back.
# Module Version: 5
#   v5 (2026-10-05, card 75b9cfcc): a FOURTH tool is announced -- the Workboard
#   comment-cap patcher in ~/.openclaw (~/.openclaw/scripts/workboard-commentcap-patch.sh),
#   probed with its own --check and re-applied like its three siblings.  Measured: the
#   patch had been reverted by an OpenClaw upgrade and nothing invoked it, so a card with
#   an over-cap comment became unreadable.
# Module Version: 4
#
# 2026-10-01: wired the STORE-SIDE witness (scripts/qwen-memory-index-check.py)
# into this watchdog, run in the same tick but independently of the patch paths.
# The patches prove the BUNDLE is patched; the witness proves the STORES are
# sound -- a patched bundle still holds links a pre-patch daemon chopped.  Unlike
# a patch, bad>0 is NOT auto-repairable here (the remedy is retiring pre-patch
# daemons, i.e. a reboot, which a cron tick cannot do), so it is a REPORT: its
# per-file lines go to the same log and the tick exits non-zero.  Still silent
# with exit 0 and an unchanged log when both patches are applied and every store
# reads bad=0.  Mirrored into this tracked copy from the loose ~/.local/bin one
# (and into that one from here) so the two stay semantically identical.
#
# 2026-10-01: wired qwen-memory-index-patch.sh into this watchdog (run its
# --check; re-apply; --check again) alongside the guard patch, because its patch
# is also per-foreign-bundle and reverts on every CLI/companion update.  Mirrored
# into this tracked copy from the loose ~/.local/bin one, so that when install.sh
# replaces that copy with a symlink here the index coverage is not silently lost.
#
# 2026-10-02: wired qwen-memory-style-patch.sh the same way (its own --check,
# re-apply, --check again).  It patches the auto-memory extractor's prompt in the
# same four copies, so it reverts on the same events and for the same reason.
set -uo pipefail

# cron's PATH omits linuxbrew. The patch scripts run `node --check` to validate
# each patched chunk and ROLL BACK if it fails, so without node on PATH this
# guard would back up, patch, fail the check, and revert on every run - leaving
# stray .orig-* backups and no patch. Pin the path explicitly.
export PATH="/home/linuxbrew/.linuxbrew/bin:/home/wayne/.local/bin:/usr/local/bin:/usr/bin:/bin:${PATH:-}"

PATCH="/home/wayne/.local/bin/qwen-guard-patch.sh"
IDX="/home/wayne/.local/bin/qwen-memory-index-patch.sh"
STYLE="/home/wayne/.local/bin/qwen-memory-style-patch.sh"
# The comment-cap patcher lives in the OTHER repo and takes its own package root; named by
# path here rather than linked into ~/.local/bin, because this watchdog is the only thing
# that invokes it (card 75b9cfcc).
COMMENTCAP="/home/wayne/.openclaw/scripts/workboard-commentcap-patch.sh"
# The VS Code Testing results-logger patcher (2026-10-07).  Named by path like its
# siblings; its --check is rc-aware, so it is probed separately below rather than by
# the boolean `! … --check` test the four above use.
TESTLOG="/home/wayne/.local/bin/vscode-pytest-log-patch.py"
# The plugin-skill hardlink self-heal (2026-10-10).  Named by path like the comment-cap
# patcher (it lives in the OTHER repo); its --check is boolean, so it is probed with the
# four older patchers below.
DENLINK="/home/wayne/.openclaw/scripts/skill-denlink.sh"
WITNESS="/home/wayne/ubuntu-console/scripts/qwen-memory-index-check.py"
LOG_DIR="/home/wayne/.local/share/qwen-guard"
LOG="$LOG_DIR/selfheal.log"

# Ask each TOOL its own --check (never this guard's own idea of health), so one
# tool being absent cannot mask the other.  A tool that is not executable is
# treated as "nothing to do", mirroring the original guard-only behaviour.
needed=()
if [[ -x "$PATCH" ]] && ! "$PATCH" --check >/dev/null 2>&1; then
  needed+=(guard)
fi
if [[ -x "$IDX" ]] && ! "$IDX" --check >/dev/null 2>&1; then
  needed+=(memory-index)
fi
if [[ -x "$STYLE" ]] && ! "$STYLE" --check >/dev/null 2>&1; then
  needed+=(memory-style)
fi
if [[ -x "$COMMENTCAP" ]] && ! "$COMMENTCAP" --check >/dev/null 2>&1; then
  needed+=(commentcap)
fi
if [[ -x "$DENLINK" ]] && ! "$DENLINK" --check >/dev/null 2>&1; then
  needed+=(denlink)
fi

# The test-log tool's --check is NOT boolean (0 patched, 1 a reverted copy, 2 no
# Python-extension copy at all, 3 the recorder file is missing), so it cannot use the
# `! … --check` form above: rc 2 is a legitimate state, not a reversion, and treating
# it as "needs re-applying" would fire on every tick and never clear.  Only rc 1 is
# auto-repairable; rc 2 is quiet; rc 3 cannot be fixed by --apply at all (the tool
# refuses before patching), so it is carried to the report below.
testlog_rc=0
testlog_report=""
if [[ -x "$TESTLOG" ]]; then
  "$TESTLOG" --check >/dev/null 2>&1 || testlog_rc=$?
  if [[ "$testlog_rc" -eq 1 ]]; then
    needed+=(testlog)
  elif [[ "$testlog_rc" -eq 3 ]]; then
    # Capture the tool's own words for the log.  Its rc is already known (3) and the
    # assignment is not errexit-guarded, so no error-suppressing tail is needed to keep
    # the tick alive — and adding one would be a swallow site the contracts gate counts.
    testlog_report="$("$TESTLOG" --check 2>&1)"
  fi
fi

# The STORE-SIDE witness: a health signal separate from the patches.  The patches prove
# the BUNDLE is patched; this proves the STORES are sound -- a patched bundle still holds
# links that a pre-patch daemon chopped.  It runs every tick, independently of the patch
# paths: a missing or non-executable witness is skipped without affecting them, and a
# missing patch tool never suppresses it.  Unlike a patch, bad>0 is NOT auto-repairable
# here (the remedy is retiring pre-patch daemons, i.e. a reboot, which a cron tick cannot
# do), so it is a REPORT: its per-file lines are recorded and the tick exits non-zero.
witness_out=""
witness_rc=0
if [[ -x "$WITNESS" ]]; then
  witness_out="$("$WITNESS" 2>&1)"
  witness_rc=$?
fi

# Every patch already in place, every store clean AND the test-log tool not in its
# unreachable rc==3 state: stay silent, write nothing.
if [[ "${#needed[@]}" -eq 0 && "$witness_rc" -eq 0 && -z "$testlog_report" ]]; then
  exit 0
fi

mkdir -p "$LOG_DIR"

# Bound the log so an unattended loop cannot grow it without limit.  An unreadable
# or absent log must not abort the guard, so the size test reads 0 lines and simply
# skips the trim.
if [ -f "$LOG" ] && [ "$(wc -l <"$LOG" 2>/dev/null || echo 0)" -gt 500 ]; then  # swallow-ok: no log yet on first run
  tail -n 200 "$LOG" >"$LOG.tmp" && mv "$LOG.tmp" "$LOG"
fi

rc=0
for tool in "${needed[@]}"; do
  # Each arm names the tool's own re-apply invocation.  The four older patchers apply
  # when run bare; the test-log and denlink patchers are the siblings with NO default
  # action — a bare invocation is a usage error — so each names --apply here.  Found by
  # this script's own proof run (2026-10-07): with a bare invocation the tick logged the
  # tool's usage text and left the wrapper unpatched, while still logging
  # "--check after: STILL-NEEDS-ATTENTION".
  case "$tool" in
    guard) patch="$PATCH"; label="guard patch"; apply_args=() ;;
    memory-index) patch="$IDX"; label="memory-index patch"; apply_args=() ;;
    memory-style) patch="$STYLE"; label="memory-style patch"; apply_args=() ;;
    commentcap) patch="$COMMENTCAP"; label="workboard-commentcap patch"; apply_args=() ;;
    denlink) patch="$DENLINK"; label="plugin-skill hardlink"; apply_args=(--apply) ;;
    testlog) patch="$TESTLOG"; label="test-log patch"; apply_args=(--apply) ;;
  esac

  {
    echo "=== $(date -Is) - ${label} was missing; re-applying"
    "$patch" "${apply_args[@]}" 2>&1
    if "$patch" --check >/dev/null 2>&1
    then
      echo "    --check after: ok"
    else
      echo "    --check after: STILL-NEEDS-ATTENTION"
      rc=1
    fi
  } >>"$LOG" 2>&1
done

# Report the test-log tool's rc==3 state: the recorder FILE is missing, so the patch
# would load nothing and --apply refuses before it touches a wrapper.  A cron tick
# cannot restore that file, so it is a REPORT (log + non-zero exit), like the store
# witness below — and the record names the file to restore.
if [[ -n "$testlog_report" ]]; then
  {
    echo "=== $(date -Is) - the test-log patch cannot be re-applied: its recorder is"
    echo "    missing from ~/.local/lib/vscode-pytest-log/vscode_pytest_log.py; restore"
    echo "    that file (the patch tool refuses on rc==3), then re-apply with --apply"
    printf '%s\n' "$testlog_report"
  } >>"$LOG" 2>&1
  rc=1
fi

# Report the store witness when it had something to say (bad>0, or it could not run),
# and make the tick exit non-zero.  Silent and rc-neutral when every store reads clean.
if [[ "$witness_rc" -ne 0 ]]; then
  {
    echo "=== $(date -Is) - memory-index stores reported broken entries; a patch"
    echo "    re-apply cannot fix this (retire pre-patch daemons / reboot)"
    printf '%s\n' "$witness_out"
  } >>"$LOG" 2>&1
  rc=1
fi

# Exit non-zero when a patch could not be restored: 30 consecutive runs on
# 2026-09-27 recorded STILL-NEEDS-ATTENTION here and still exited 0, so nothing
# downstream could tell a repaired box from one that had been unpatched for hours.
exit "$rc"
# end of file
