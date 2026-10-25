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
# Module Version: 12
#   v12 (2026-10-25): wrap the class remedies and comment witness_class (ratchet).
#   v11 (2026-10-25, T-JARVIS-094): each store-witness class now has its OWN status, marker
#   and exit status instead of every non-zero witness rc exiting 1.  Measured 2026-10-25T09:23Z:
#   the witness read rc=3 (13 over-cap index lines, bad=0, every link resolving) and the tick
#   exited 1 -- the same code, and the same "tick exited 1" marker downstream, as a foreign
#   bundle whose patch could not be re-applied.  A cosmetic condition wore the emergency's
#   voice, which is how a real revert gets read as noise.  The classes (table in the
#   witness_class function below): rc=0 OK (silent), rc=1 EMERGENCY (exit 1, unchanged),
#   rc=2 NO-STORE (exit 1, its own marker naming the store path), rc=3 STORE-EDIT (exit 3,
#   the edit remedy named), any other rc=UNKNOWN-<n> (exit 1, the number carried).  The tick
#   exits the MOST SEVERE class it saw, never the numerically largest, so a patch failure is
#   never masked by an over-cap line.  ONLY rc=3's classification changed: every other class
#   keeps the exit status it had before v11, so no condition was silenced to draw the line.
#   rc=1 auto-repair (the patch loop) is untouched, and rc=3 is NOT made repairable: an
#   --apply cannot shorten an index line, and the witness is never queued for one.
#   OWED, cross-repo: ~/.openclaw/workspace-jarvis/scripts/qwen-guard-escalate.sh gates its
#   one-tick rc=3 deferral on `guard_rc -eq 1`; with this tick now exiting 3 for that class the
#   gate must accept 3 as well, or a first-sight over-cap sample escalates one tick sooner.
#   v10 (2026-10-16): the store-witness REPORT is keyed on the witness's own rc.  It had
#   claimed "a patch re-apply cannot fix this (retire pre-patch daemons / reboot)" for ANY
#   non-zero witness exit, but only rc=1 (a broken/chopped index link) is a daemon case:
#   rc=3 is an over-cap line with bad=0, whose remedy is editing that store line -- no daemon
#   retires a long line.  Measured 2026-10-16: a 249-character line was reported as a reboot.
# Module Version: 9
#   v9 (2026-10-16): an EIGHTH tool is announced -- the Workboard proof-cap patcher
#   (~/.openclaw/scripts/workboard-proofcap-patch.sh).  It had NO caller anywhere, so the
#   proof-cap fix (legacy over-cap proof notes preserved on read, the new-input cap
#   inlined, the per-card refresh fail-soft) would be reverted by the next OpenClaw
#   upgrade and stay reverted: the same foreign-bundle reversion the comment-cap arm
#   exists to catch, one layer along.  Probed rc-aware like the test-log and agentmail
#   tools -- only rc 1 (a reverted copy) triggers a re-apply; rc 3 (no Workboard bundle),
#   4 (unusable cap) and 5 (no node) stay quiet, because the comment-cap arm is boolean
#   and already pages on those states from the SAME bundle, so no class is left silent.
# Module Version: 8
#   v8 (2026-10-13): a SEVENTH tool is announced -- the agentmail dist patch
#   (~/.openclaw/scripts/agentmail-dist-patch.sh), probed rc-aware like the test-log tool
#   (0 patched / 1 reverted / 2 the extension is absent) and re-applied with --apply.  It
#   re-trims the SDK export `markdownToText` that the plugin's compiled
#   dist/channel/src/inbound.js still imports after the SDK removed it, which makes the
#   plugin unloadable and gets it force-retired.  Every plugin install/update rewrites that
#   file -- measured THREE times on 2026-10-13, the last by `openclaw plugins update
#   agentmail` at 23:30 BST, which is why a hand re-apply was not durable.  Upstream:
#   agentmail-to/openclaw-plugin#20.
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
# The Workboard proof-cap + diagnostics-refresh patcher (2026-10-16).  Same foreign
# bundle as the comment-cap patcher and the same repo, so named the same way.
PROOFCAP="/home/wayne/.openclaw/scripts/workboard-proofcap-patch.sh"
# The VS Code Testing results-logger patcher (2026-10-07).  Named by path like its
# siblings; its --check is rc-aware, so it is probed separately below rather than by
# the boolean `! … --check` test the four above use.
TESTLOG="/home/wayne/.local/bin/vscode-pytest-log-patch.py"
# The plugin-skill hardlink self-heal (2026-10-10).  Named by path like the comment-cap
# patcher (it lives in the OTHER repo); its --check is boolean, so it is probed with the
# four older patchers below.
DENLINK="/home/wayne/.openclaw/scripts/skill-denlink.sh"
# The agentmail dist patch (2026-10-13).  Named by path like the comment-cap patcher (it
# lives in the OTHER repo); its --check is rc-aware, so it is probed separately below.
AGENTMAIL="/home/wayne/.openclaw/scripts/agentmail-dist-patch.sh"
WITNESS="/home/wayne/ubuntu-console/scripts/qwen-memory-index-check.py"
# TEST SEAM (T-JARVIS-094).  Relocate every PROBED tool into one scratch directory so a suite
# can drive each witness class through the real script without touching a live bundle or the
# real log.  Cron never sets it, and the nine production literals above stay exactly as they
# are -- the wiring net's cases grep those lines -- so this block only ever runs under a test.
QSH_TOOL_ROOT="${QSH_TOOL_ROOT:-}"
if [[ -n "$QSH_TOOL_ROOT" ]]; then
  PATCH="$QSH_TOOL_ROOT/qwen-guard-patch.sh"
  IDX="$QSH_TOOL_ROOT/qwen-memory-index-patch.sh"
  STYLE="$QSH_TOOL_ROOT/qwen-memory-style-patch.sh"
  COMMENTCAP="$QSH_TOOL_ROOT/workboard-commentcap-patch.sh"
  PROOFCAP="$QSH_TOOL_ROOT/workboard-proofcap-patch.sh"
  TESTLOG="$QSH_TOOL_ROOT/vscode-pytest-log-patch.py"
  DENLINK="$QSH_TOOL_ROOT/skill-denlink.sh"
  AGENTMAIL="$QSH_TOOL_ROOT/agentmail-dist-patch.sh"
  WITNESS="$QSH_TOOL_ROOT/qwen-memory-index-check.py"
fi
LOG_DIR="${QSH_LOG_DIR:-/home/wayne/.local/share/qwen-guard}"
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

# The proof-cap patcher shares the comment-cap patcher's exit codes (0 applied, 1 a
# reverted copy, 3 no Workboard bundle, 4 unusable cap, 5 no node), so it cannot use
# the boolean form either: only rc 1 is a reversion worth re-applying.  Measured
# 2026-10-16: nothing executable called it, so the proof-cap fix would rot silently.
PROOFCAP_rc=0
if [[ -x "$PROOFCAP" ]]; then
  "$PROOFCAP" --check >/dev/null 2>&1 || PROOFCAP_rc=$?
  if [[ "$PROOFCAP_rc" -eq 1 ]]; then
    needed+=(proofcap)
  fi
fi
if [[ -x "$DENLINK" ]] && ! "$DENLINK" --check >/dev/null 2>&1; then
  needed+=(denlink)
fi

# The agentmail dist patch's --check is rc-aware too (0 patched, 1 a reverted copy, 2 the
# extension is not installed, or is a build this tool does not know), so it cannot use the
# `! … --check` form: rc 2 is a legitimate state -- the ladder's own step 3 REMOVES the
# plugin -- and treating it as "needs re-applying" would fire on every tick and never clear.
# Only rc 1 is auto-repairable; rc 2 is quiet, exactly as the test-log tool's is.
agentmail_rc=0
if [[ -x "$AGENTMAIL" ]]; then
  "$AGENTMAIL" --check >/dev/null 2>&1 || agentmail_rc=$?
  if [[ "$agentmail_rc" -eq 1 ]]; then
    needed+=(agentmail)
  fi
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

# ONE CLASS PER WITNESS EXIT CODE (v11, T-JARVIS-094).  The witness answers four different
# questions with four exit codes, and two of them do not share a remedy: rc=1 is a chopped
# link (a daemon case) and rc=3 is an over-cap line whose link still resolves (an edit to the
# store).  Until v11 every non-zero code exited 1, so an over-cap title reached the downstream
# marker as "the tick exited 1" -- the same voice as a foreign bundle whose patch could not be
# re-applied.  Measured 2026-10-25T09:23Z: 13 over-cap lines, bad=0 on every store, and the
# marker read as a reverted patch.  The class is carried into BOTH the log marker and the
# tick's exit status, so the two conditions stop being indistinguishable to a reader and to
# the cron wrapper that classifies the marker.
#
#   rc  class        tick exits  meaning / remedy
#   0   OK           0           every store clean; nothing recorded
#   1   EMERGENCY    1           a broken/chopped link -- retiring pre-patch daemons (a reboot)
#   2   NO-STORE     1           the witness could not run (no index found) -- check the store path;
#                               an empty scan is not a clean tree, so this keeps its old severity
#   3   STORE-EDIT   3           an over-cap line (bad=0, link resolves) -- edit that store line
#   *   UNKNOWN-<n>  1           an exit code this guard does not classify; the number is carried
#
# ONLY rc=3's exit status changed in v11.  rc=2 keeps the exit 1 it always had and gains its own
# class and marker instead of being folded into the emergency's: "the witness could not run" is
# not a chopped link, and a reader sent to check the store path should not be told to reboot.
# Nothing is silenced to draw the line -- a condition that used to page still pages; it just
# says which condition it is.
#
# rc=1 keeps its place in the PATCH loop, which is the only thing this tick repairs.  rc=3 is
# NOT made repairable: an --apply cannot shorten an index line, and the witness is never
# queued for one -- a class that cannot be fixed must not be retried, because a retry that
# always fails is the "fires every tick and never clears" shape this file already refuses.
witness_status=""
witness_exit=0
witness_remedy=""

# Map the witness's own exit code to this tick's class, status and remedy.
witness_class() {
  case "$1" in
    0) witness_status="OK";          witness_exit=0; witness_remedy="" ;;
    1) witness_status="EMERGENCY";   witness_exit=1
       witness_remedy="a broken/chopped index link.  A patch re-apply cannot restore it; \
the remedy is retiring pre-patch daemons (a reboot), which a cron tick cannot do." ;;
    2) witness_status="NO-STORE";    witness_exit=1
       witness_remedy="the witness could not run (no index found).  An empty scan is not a clean tree; \
check the STORE PATH before reading this as a daemon or patch failure." ;;
    3) witness_status="STORE-EDIT";  witness_exit=3
       witness_remedy="an over-cap index line (bad=0; the link still resolves).  Remedy: edit that store line \
- no daemon retires a long line.  It recurs only if the patched writer re-emits one \
(bin/qwen-memory-index-patch.sh hunk 4)." ;;
    *) witness_status="UNKNOWN-$1";  witness_exit=1
       witness_remedy="an exit code this guard does not classify.  Read the store lines below \
before assuming a daemon or a patch failure." ;;
  esac
}
witness_class "$witness_rc"

# Every patch already in place, every store clean AND the test-log tool not in its
# unreachable rc==3 state: stay silent, write nothing.  A CLEAN witness (rc=0) is the only
# class that lets this tick stay silent -- every other class carries its own marker and its
# own exit status (see the class table above), so an absent store still pages.
if [[ "${#needed[@]}" -eq 0 && "$witness_exit" -eq 0 && -z "$testlog_report" ]]; then
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
    proofcap) patch="$PROOFCAP"; label="workboard-proofcap patch"; apply_args=() ;;
    denlink) patch="$DENLINK"; label="plugin-skill hardlink"; apply_args=(--apply) ;;
    testlog) patch="$TESTLOG"; label="test-log patch"; apply_args=(--apply) ;;
    agentmail) patch="$AGENTMAIL"; label="agentmail dist patch"; apply_args=(--apply) ;;
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

# Report the store witness under ITS OWN class and exit status (v11).  OK (rc=0) writes
# nothing: a clean store is not a finding.  Every other class writes its own marker and
# carries its own exit status, so an absent store pages under WITNESS-NO-STORE rather than
# under the emergency's code.  The
# marker's first line carries the class token, so a reader -- and the cron wrapper that
# classifies this tick -- can tell an edit to the store from the fault the watchdog exists
# for.  The last line states the class's CLEARING CONDITION, which is the condition under
# which this marker stops being written: the witness exiting 0 on a later tick.  Nothing is
# left standing here to be cleared out of band, so a class that clears stops being reported
# on the very next tick, and no stale marker outlives the condition it described.
if [[ "$witness_exit" -ne 0 ]]; then
  {
    echo "=== $(date -Is) - store witness WITNESS-$witness_status (witness rc=$witness_rc, tick exit $witness_exit)"
    echo "    class: $witness_status (rc=$witness_rc) - $witness_remedy"
    echo "    clears when: $WITNESS exits 0 again; this marker is not re-emitted while it does"
    printf '%s\n' "$witness_out"
  } >>"$LOG" 2>&1
fi

# The tick exits the MOST SEVERE class it saw, not the numerically largest: an emergency is
# 1 and a store edit is 3, so a plain max() would rank the cosmetic finding above the fault.
# A patch that could not be re-applied therefore keeps exit 1 even beside an over-cap line,
# while a store edit with every patch in place exits 3 rather than borrowing the emergency's
# code.  (An UNKNOWN witness class carries exit 1: an unclassifiable reading is a fault.)
if [[ "$witness_exit" -eq 1 ]]; then
  rc=1
elif [[ "$witness_exit" -ne 0 && "$rc" -eq 0 ]]; then
  rc="$witness_exit"
fi

# Exit non-zero when a patch could not be restored: 30 consecutive runs on
# 2026-09-27 recorded STILL-NEEDS-ATTENTION here and still exited 0, so nothing
# downstream could tell a repaired box from one that had been unpatched for hours.
exit "$rc"
# end of file
