#!/bin/sh
# AI INSTRUCTION: increment Version below on every edit
# Version: 1.0.3
# 1.0.3 (2026-11-13): LANES named a unit that does not exist. It said
#           `llama-cuda-embeddinggemma-embed.service`; the live unit is
#           `llama-cuda-qwen3embedding-embed.service` (the EmbeddingGemma name was never the
#           deployed one). Measured: `systemctl --user restart <both names>` prints "Unit ... not
#           found" for the bad one and exits 5, but the chat lane still restarts and the embed
#           lane is still ACTIVE from before - so health_ok() read 200/200 and the run would have
#           reported OK while the embed lane was never reloaded onto the new binary. A false green
#           in the one place this script exists to be trustworthy. Fixed the name AND added a
#           pre-flight that refuses when any named unit does not resolve, so the next rename is a
#           loud FAIL instead of a silent half-restart.
# 1.0.1 (2026-11-05): idempotent, so the timer can offer more than one day. 1.0.0 fired once, on the
#           1st: a month whose 1st was busy (a nightly CI job, a bench) was SKIPPED and then waited
#           another month, because Persistent only catches a MISSED run, never a skipped one. The
#           script now skips when the serving binary already reports origin/master, so the timer can
#           run on days 1-3 and a busy first attempt simply retries.
# 1.0.0 (2026-11-05): created on Wayne's ask - "give jarvis a cron job to run this rebuild once a
#           month" - after the comparison showed the serving lanes 147 commits behind upstream
#           (b12004 -> 10d4846 by hand). Unattended, so it carries its own rollback.
#
# llm-rebuild-monthly.sh - pull upstream llama.cpp and rebuild the CUDA server, once a month.
#
# WHY THIS EXISTS. llm-build is a console FUNCTION, so it runs only in a shell that sourced
# env.sh, and it refuses without a terminal. Nothing was scheduled, so "keep the build current"
# meant "when someone remembers". This is the clock.
#
# WHAT IT GUARANTEES
#   - nothing runs unless the box is quiet: no bin/heavy-job holder and no CI runner worker;
#   - the build goes into a FRESH tree - the serving tree is moved aside first, never
#     reconfigured in place across a large upstream jump;
#   - the new binary must report the commit that was just pulled, or it is not served;
#   - both lanes must answer 200 on /health after the restart;
#   - any failure after the move restores the old tree and restarts the lanes, so a bad month
#     leaves the box exactly as it was.
#
# WHAT IT CANNOT CATCH: a build that is healthy but slower. TPS is not measured here - bench
# before trusting a delta, because bench rows carry build identity.
#
# USAGE
#   llm-rebuild-monthly.sh              run it (the timer does this)
#   llm-rebuild-monthly.sh --dry-run    print what it would do and stop

set -u
umask 022

# PATH is SET, not inherited: systemd hands a unit /usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
# and the CUDA toolkit is not on it - gates.sh died the same way on a missing node.
PATH=/usr/local/cuda-13.4/bin:/home/wayne/.local/bin:/usr/local/bin:/usr/bin:/bin
export PATH

# Every path and name is overridable, because this script had NO test: the ordering defect that
# stopped both lanes on 2026-11-14 (a tree moved out from under them, then a latched unit) was
# findable only by running a real rebuild.  A hard-assigned constant makes a script untestable -
# the lesson tests/unit/44 taught in ubuntu-console - so a harness can point the whole thing at a
# sandbox tree, a fake systemctl and a fake llm-build and assert the ORDER of its steps.
: "${LLAMA_ROOT:=$HOME/llama.cpp}"
: "${CONSOLE:=$HOME/github-wsl/ubuntu-console}"
: "${STATE:=$HOME/.openclaw/state/llm-rebuild}"
: "${LANES:=llama-cuda-qwen3coder-30b-chat.service llama-cuda-qwen3embedding-embed.service}"
: "${CHAT_PORT:=18087}"
: "${EMBED_PORT:=18080}"
: "${SYSTEMCTL:=systemctl}"
LOG=$STATE/rebuild.log
DRY_RUN=0
[[ "${1:-}" = "--dry-run" ]] && DRY_RUN=1

mkdir -p "$STATE" || exit 1

# say - one timestamped line, to the run log and to stdout.
say() {
    printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >>"$LOG"
    printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"
}

# restore - put the old tree back and restart the lanes. The only recovery path, so it runs on
# every failure after the move, including a binary that does not report the pulled commit.
restore() {
    say "RESTORING $prev -> build-cuda and restarting the lanes"
    # The tree being discarded may be a COMPLETED build whose deploy failed, not a wreck:
    # measured 2026-11-14 21:16:27, when a build of a956a852c was discarded because a latched
    # unit would not restart.  Move it aside under its own name so it survives for inspection or
    # a manual deploy; a later run prunes it by its own rule.  Only a tree that cannot be moved
    # is removed, because the move back needs the path free.
    if [[ -d "$LLAMA_ROOT/build-cuda" ]]; then
        # swallow-ok: the commit only names the kept tree; "unknown" is still a usable name
        built_commit=$(git -C "$LLAMA_ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)
        failed_tree="$LLAMA_ROOT/build-cuda.failed-$built_commit-$(date -u +%H%M%S)"
        if mv "$LLAMA_ROOT/build-cuda" "$failed_tree"; then
            say "kept the replaced build for inspection: $failed_tree"
        else
            say "WARN: could not move the built tree aside; removing it to free build-cuda"
            rm -rf -- "$LLAMA_ROOT/build-cuda"
        fi
    fi
    mv "$prev" "$LLAMA_ROOT/build-cuda" || say "FAIL: could not move $prev back"
    # reset-failed FIRST: a unit that latched "start request repeated too quickly" is not revived
    # by restart, so the rollback would put the tree back and report done over a dead lane.
    # Measured 2026-11-14 - the rollback's own restart failed for exactly this reason.
    # A unit that was never latched answers this non-zero; that is not a failure to report, so the
    # status is ignored on purpose and the restart below is what proves the lanes came back.
    # shellcheck disable=SC2086  # LANES is a deliberate space-separated list
    # swallow-ok: a unit that was never latched answers non-zero; the restart below is what proves the lanes
    if ! "$SYSTEMCTL" --user reset-failed $LANES 2>/dev/null; then
        say "NOTE: reset-failed reported a unit with nothing to clear"
    fi
    # shellcheck disable=SC2086  # as above
    "$SYSTEMCTL" --user restart $LANES
    exit 1
}

# health_ok - both lanes answering 200. A failed curl prints 000 through -w and exits non-zero;
# that is the same answer as "not ready", so the exit status is deliberately not tested.
health_ok() {
    # swallow-ok: curl prints 000 through -w and exits non-zero; health_ok reads that as not-ready either way
    c=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$CHAT_PORT/health" 2>/dev/null)
    # swallow-ok: as above: 000 is the not-ready answer, not a silent failure
    e=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$EMBED_PORT/health" 2>/dev/null)
    [[ "$c" = "200" ]] && [[ "$e" = "200" ]]
}

say "=== monthly llama.cpp rebuild ==="

# ---- Every named lane must resolve BEFORE anything is moved. A typo here is not a cosmetic
# ---- problem: `systemctl restart` restarts the names it knows and reports the rest as not found,
# ---- so a bad name leaves that lane running the OLD binary while health_ok() still reads 200
# ---- from the process that was already up. Measured 2026-11-13 with the previous LANES value.
for u in $LANES; do
    if ! "$SYSTEMCTL" --user cat "$u" >/dev/null 2>&1; then
        say "FAIL: lane unit does not exist: $u - refusing to rebuild"
        exit 1
    fi
done

# ---- Quiet gate: the same two conditions llm-build checks, read here first so a busy box is a
# ---- logged SKIP rather than a failure (the timer would otherwise report red once a month).
# --status exits 0 for both free and BUSY and prints the WORD; an empty read falls to SKIP.
status=$("$CONSOLE/bin/heavy-job" --status 2>&1)
case $status in
    *"heavy-job: free"*) ;;
    *) say "SKIP: box busy - ${status:-no status read}"; exit 0 ;;
esac
# pgrep -c prints 0 and exits 1 when nothing matches, so the printed value is the answer.
# swallow-ok: pgrep -c prints 0 and exits 1 for no match; the printed value is the answer
ci=$(pgrep -fc '[R]unner\.Worker' 2>/dev/null)
[[ -n "$ci" ]] || ci=0
if [[ "$ci" -gt 0 ]]; then
    say "SKIP: $ci CI runner worker(s) active"
    exit 0
fi

# ---- Already current? A no-op month must not rebuild: the timer offers days 1-3 so a busy 1st
# ---- can retry, and without this a retry would rebuild the same commit.  The comparison is the
# ---- serving binary's own reported commit against the fetched remote tip.
# swallow-ok: the next line says WARN when the fetch fails and compares against a possibly-stale ref
git -C "$LLAMA_ROOT" fetch --quiet origin 2>/dev/null ||
    say "WARN: fetch failed - comparing against the local origin/master, which may be stale"
# swallow-ok: an unreadable ref prints unknown, and the comparison below then simply cannot SKIP
remote_short=$(git -C "$LLAMA_ROOT" rev-parse --short origin/master 2>/dev/null || echo unknown)
serving_short=$("$LLAMA_ROOT/build-cuda/bin/llama-server" --version 2>&1 |
    sed -n 's/.*commit \([0-9a-fA-F]\{7,\}\).*/\1/p')
if [[ -n "$serving_short" ]] && [[ "$serving_short" = "$remote_short" ]]; then
    say "SKIP: already serving $serving_short, which is origin/master"
    exit 0
fi
say "behind: serving ${serving_short:-unknown}, origin/master $remote_short"

# ---- Name the rollback by the commit the binary reports, and refuse a collision: mv onto an
# ---- existing directory nests the tree and exits 0, silently.
# swallow-ok: an unreadable HEAD stops the run at the brace below, which names the failure
head_short=$(git -C "$LLAMA_ROOT" rev-parse --short HEAD 2>/dev/null) || {
    say "FAIL: $LLAMA_ROOT is not a git checkout"; exit 1; }
prev=$LLAMA_ROOT/build-cuda.prev-$head_short
if [[ -e "$prev" ]]; then
    say "FAIL: rollback target already exists ($prev) - refusing rather than nesting the move"
    exit 1
fi
if [[ ! -x "$LLAMA_ROOT/build-cuda/bin/llama-server" ]]; then
    say "FAIL: no serving binary at build-cuda/bin/llama-server - nothing to move aside"
    exit 1
fi

if [[ "$DRY_RUN" = "1" ]]; then
    say "PLAN: rebuild from $head_short; rollback tree would be $prev"
    exit 0
fi

# ---- Stop the lanes BEFORE the move, never move a tree out from under a running binary.
# ---- Measured 2026-11-14: the move renamed build-cuda while both lanes still executed from it, so
# ---- their /proc/PID/exe read .../build-cuda.prev-<commit>/bin/llama-server. That is a real path,
# ---- and any consumer comparing it to build-cuda/ calls it foreign (gpu-busy.sh did, and the
# ---- watchdog stopped both lanes mid-compile). The unit's ExecStart also names build-cuda/, which
# ---- does not exist during the compile, so a systemd restart in that window fails with
# ---- "CUDA build not executable" and latches the unit failed. Stopping first makes both true by
# ---- construction: nothing runs from the old path, and nothing tries to start from the new one.
# ---- Cost is the lane being down for the compile, which is the same cost the restart already
# ---- pays -- but taken at a point where the failure is recoverable.
say "stopping the lanes before the move: $LANES"
# shellcheck disable=SC2086  # LANES is a deliberate space-separated list, expanded on purpose
"$SYSTEMCTL" --user stop $LANES || { say "FAIL: could not stop the lanes - refusing to move the tree"; exit 1; }

# ---- Move aside, then build. llm-build pulls --ff-only from origin/master, configures for the
# ---- card's arch, and builds into the tree that the launcher resolves.
mv "$LLAMA_ROOT/build-cuda" "$prev" || { say "FAIL: could not move build-cuda aside"; exit 1; }
say "moved build-cuda aside -> $prev"

out=$(bash -lc "source $CONSOLE/env.sh >/dev/null 2>&1; llm-build --yes" 2>&1)
rc=$?
printf '%s\n' "$out" >>"$LOG"
if [[ "$rc" -ne 0 ]]; then
    say "FAIL: llm-build rc=$rc"
    restore
fi

# swallow-ok: the post-build commit is reported; echo unknown is the printed unknown, not a silence
new_head=$(git -C "$LLAMA_ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)
say "built from $new_head"

# ---- Prove the artefact: the binary must report the commit just pulled. --version writes to
# ---- STDERR, so 2>&1 is what makes this check able to pass at all.
bin=$LLAMA_ROOT/build-cuda/bin/llama-server
[[ -x "$bin" ]] || { say "FAIL: no binary at $bin"; restore; }
version=$("$bin" --version 2>&1)
say "version: $(printf '%s' "$version" | tr '\n' ' ')"
case $version in
    *"$new_head"*) ;;
    *) say "FAIL: binary does not report $new_head"; restore ;;
esac

# ---- Serve it, then require both lanes healthy. is-active would only say systemd accepted the
# ---- job; /health says the model loaded and is answering. But /health alone is not enough: a lane
# ---- that was never restarted still answers 200 from the process that was already up, which is
# ---- exactly how the 1.0.3 bad-unit-name defect would have read green. So the MainPID of every
# ---- lane must CHANGE, which is the only evidence that the new binary is the one serving.
old_pids=""
for u in $LANES; do
    # swallow-ok: the pre-restart MainPID is compared with the post one; empty makes the comparison fail loudly
    old_pids="$old_pids $("$SYSTEMCTL" --user show -p MainPID --value "$u" 2>/dev/null)"
done
# Reset BEFORE the success restart, for the same reason restore() does it.  The stop above leaves
# the unit Result=signal (a SIGKILL after the stop timeout); if it was ALSO latched before this
# run - "Start request repeated too quickly", which restart does not clear - then restart returns 1
# and a COMPLETED build is thrown away by the rollback.  Measured 2026-11-14 21:16:27: the build
# produced 384 at a956a852c, the restart hit the latch, and the script restored c75fba30c - a good
# binary discarded over a unit's bookkeeping state.
# shellcheck disable=SC2086  # LANES is a deliberate space-separated list
# swallow-ok: a unit that was never latched answers non-zero; the restart below is what proves the lanes
if ! "$SYSTEMCTL" --user reset-failed $LANES 2>/dev/null; then
    say "NOTE: reset-failed reported a unit with nothing to clear"
fi
"$SYSTEMCTL" --user restart $LANES
rc=$?
if [[ "$rc" -ne 0 ]]; then
    say "FAIL: systemctl restart rc=$rc"
    restore
fi
i=0
while [[ "$i" -lt 240 ]]; do
    health_ok && break
    i=$((i + 1))
    sleep 5
done
if ! health_ok; then
    say "FAIL: lanes not healthy after $((i * 5))s"
    restore
fi
# ---- Every lane must be a NEW process. A pid that did not move means that lane is still serving
# ---- the binary this run replaced, whatever /health says.
set -- $old_pids
for u in $LANES; do
    was=$1; shift
    # swallow-ok: as above: the post-restart MainPID, whose mismatch is the failure the caller reports
    now=$("$SYSTEMCTL" --user show -p MainPID --value "$u" 2>/dev/null)
    if [[ -z "$now" ]] || [[ "$now" = "0" ]] || [[ "$now" = "$was" ]]; then
        say "FAIL: $u did not restart (MainPID was $was, now ${now:-unreadable})"
        restore
    fi
done

# ---- Keep this run's rollback for the next one; drop older ones.
for old in "$LLAMA_ROOT"/build-cuda.prev-*; do
    [[ -e "$old" ]] || continue
    [[ "$old" = "$prev" ]] && continue
    say "pruning older rollback: $old"
    rm -rf "$old"
done

say "OK: serving $new_head, both lanes 200 (rollback kept at $prev)"
exit 0
# end of file
