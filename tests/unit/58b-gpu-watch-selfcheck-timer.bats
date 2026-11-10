#!/usr/bin/env bats
# ==============================================================================
# Unit — systemd/gpu-watch-selfcheck.timer (hourly liveness probe for the
# GPU-passthrough automation)
# ==============================================================================
# The unit's job is to make a STOPPED watcher loud: the check exits non-zero when
# it cannot vouch for the automation, and that non-zero exit is what puts the unit
# in `systemctl --user --failed`.  The failure mode pinned here is the opposite one
# — a false red at boot that teaches a reader to ignore the channel (the checker's
# own header: a false alarm is worse than no alarm).
#
# Measured 2026-10-11, 6/6 boots: the timer carried
# `Requires=gpu-watch-selfcheck.service`, so systemd started the SERVICE the moment
# the timer started at boot (~13 s in), before the Gateway's control plane serves.
# The check then read the STARTUP as an unreadable watcher, exited 2, and landed
# the unit in `--failed` on every reboot — before the timer's own `OnBootSec=10min`
# probe had even fired.  The Requires= is gone; these cases keep it gone AND keep
# the timer's own activation working without it (the service is reached through the
# timer's implicit Unit=, i.e. a `Triggers=` link, not a dependency clause).
# ==============================================================================

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    TIMER="$REPO_ROOT/systemd/gpu-watch-selfcheck.timer"
    SERVICE="$REPO_ROOT/systemd/gpu-watch-selfcheck.service"
}

@test "gpu-watch timer: ships in the repo, install.sh links the user unit set" {
    # A unit only on the machine it was written on is not a fix: install.sh's
    # generic `systemd/*` loop is what puts it in ~/.config/systemd/user/.
    [ -f "$TIMER" ]
    [ -f "$SERVICE" ]

    run grep -q 'for f in "$REPO"/systemd/\*' "$REPO_ROOT/install.sh"
    [ "$status" -eq 0 ]
}

@test "gpu-watch timer: systemd-analyze verify accepts it" {
    run systemd-analyze verify "$TIMER"
    [ "$status" -eq 0 ]
}

@test "gpu-watch timer: no Requires=/Wants= on its own service" {
    # The regression guard.  A dependency clause on the service makes systemd
    # start it at boot, OFF the timer's schedule and before the Gateway serves —
    # the measured cause of a false `--failed` on 6/6 boots (2026-10-11).  grep
    # exits 1 when nothing matches, which is the passing case; a re-added line
    # makes it exit 0 and fails this case.
    run grep -E '^[[:space:]]*(Requires|Wants)=.*gpu-watch-selfcheck\.service' "$TIMER"
    [ "$status" -ne 0 ]
}

@test "gpu-watch timer: still anchored to an install target and a schedule" {
    # Without WantedBy=timers.target nothing starts the timer; without a schedule
    # clause it starts and never fires — either way the watcher is unbounded.
    run grep -q '^WantedBy=timers.target' "$TIMER"
    [ "$status" -eq 0 ]
    run grep -qE '^(OnBootSec|OnUnitActiveSec)=' "$TIMER"
    [ "$status" -eq 0 ]
}

# end of file

@test "gpu-watch selfcheck: every path named in the alarm text ships in the repo" {
    # Measured 2026-11-03: the alarm text promised an independent
    # openclaw-gpu-passthrough-watch.timer that existed at no scope and was invoked by nothing,
    # and no test read that sentence.  The text now names the SCRIPT that does the watching
    # (bin/gpu-passthrough-check.sh), so derive the population from the text itself and require
    # at least one path: an empty extraction is a broken test, not "nothing to check".
    run awk '/^alarm_text\(\)/,/^}/' "$REPO_ROOT/bin/gpu-watch-selfcheck.sh"
    [ "$status" -eq 0 ]
    [ -n "$output" ] || { echo "alarm_text() not found in bin/gpu-watch-selfcheck.sh" >&2; return 1; }
    named=$(printf '%s\n' "$output" | grep -oE '(bin|systemd)/[a-z0-9][a-z0-9-]*\.(sh|timer|service)' | sort -u)
    [ -n "$named" ] || {
        echo "alarm text names no repo path; the extractor or the text changed" >&2
        return 1
    }
    while IFS= read -r path; do
        [ -f "$REPO_ROOT/$path" ] || {
            echo "alarm text names $path, which this repo does not ship" >&2
            return 1
        }
    done <<< "$named"
}
