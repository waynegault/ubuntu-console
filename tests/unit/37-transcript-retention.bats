#!/usr/bin/env bats
# ==============================================================================
# Unit — chat-transcript retention: the policy, its boundary, and the LIVE guard
# ==============================================================================
# `scripts/qwen-transcript-retention.sh` ages out chat transcripts that have NO session
# registry entry.  Measured 2026-10-01 in the -home-wayne--openclaw store: 125 transcripts,
# just 2 with a registry entry — 123 files (~250 MiB) that the registry cannot describe, so
# the pid/procStart dead-or-alive test does not apply to them and nothing ever removes them.
#
# The rules under test (stated in the script's header, NOT read off its output):
#   1. a LIVE session's transcript is never removed, whatever its age;
#   2. a REGISTERED session is out of scope entirely, dead or alive;
#   3. age is the criterion — mtime STRICTLY older than the cutoff (default 30 days);
#   4. scope is one project's chat store; another project must be named;
#   5. read-only unless --delete is passed.
#
# The expected values come from those rules, not from the implementation's current output:
# "the live transcript survives" and "the young one is not listed" are consequences of the
# policy, so an implementation that dropped either would fail here rather than agree with
# itself.  The liveness fixture is REAL, not mocked — it registers the running test shell's
# own PID with its true /proc starttime and boot id, so the identity test is exercised
# against /proc exactly as it is in production, and a broken ticks/boot-id comparison
# cannot pass by accident.
#
# Hermetic: every registry entry, transcript and store lives under BATS_TEST_TMPDIR.  The
# real ~/.qwen store is never read and never written.
# ==============================================================================

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    # QWEN_RETENTION_TOOL lets the falsification run below point this suite at a mutated
    # copy: a suite that can only ever see the shipped file cannot show that it disagrees
    # with anything.  Unset — the normal case — it is the shipped tool.
    TOOL="${QWEN_RETENTION_TOOL:-$REPO_ROOT/scripts/qwen-transcript-retention.sh}"
    WORK="$BATS_TEST_TMPDIR"
    QWEN="$WORK/qwen"
    CHATS="$QWEN/projects/-home-wayne--openclaw/chats"
    SUBAGENTS="$QWEN/projects/-home-wayne--openclaw/subagents"
    REGISTRY="$QWEN/sessions"
    mkdir -p "$CHATS" "$SUBAGENTS" "$REGISTRY"
}

# transcript <sessionId> <age-in-touch-syntax> — content is unique per session, so a
# byte-identity check on a survivor means something.
transcript() {
    printf '{"session":"%s","n":%s}\n' "$1" "${#1}" > "$CHATS/$1.jsonl"
    touch -d "$2" "$CHATS/$1.jsonl"
}

# register <sessionId> <pid> <procStart> — a registry entry, named as production names them.
register() {
    printf '{"pid":%s,"procStart":"%s","sessionId":"%s"}\n' "$2" "$3" "$1" \
        > "$REGISTRY/$2-abcdef12.json"
}

# subagent <parentSessionId> <stem> <age> <suffix>... — one call, as the CLI lays it out:
# <project>/subagents/<parentSessionId>/<agent>-<callid><suffix>.  The parent session is the
# DIRECTORY name; the file name carries no sessionId at all.
subagent() {
    local parent="$1" stem="$2" age="$3"
    shift 3
    mkdir -p "$SUBAGENTS/$parent"
    for suffix in "$@"
    do
        printf '{"parent":"%s","stem":"%s","suffix":"%s"}\n' "$parent" "$stem" "$suffix" \
            > "$SUBAGENTS/$parent/$stem$suffix"
        touch -d "$age" "$SUBAGENTS/$parent/$stem$suffix"
    done
}

# proc_start <pid> — "<bootid>:<ticks>", built the same way the tool reads /proc.
proc_start() {
    local ticks
    ticks=$(python3 -c 'import sys; print(open("/proc/%d/stat" % int(sys.argv[1])).read().rsplit(") ", 1)[1].split()[19])' "$1")
    printf '%s:%s' "$(cat /proc/sys/kernel/random/boot_id)" "$ticks"
}

@test "retention: the default run is a dry run — it prints the plan and deletes nothing" {
    transcript unreg-old "200 days ago"

    run "$TOOL" --qwen-dir "$QWEN"

    [ "$status" -eq 0 ]
    [[ "$output" == *"TO REMOVE     1 unit, 1 file ("* ]]
    [[ "$output" == *"unreg-old.jsonl"* ]]
    [[ "$output" == *"DRY RUN       nothing deleted"* ]]
    # Rule 5: the artifact is still there after a default run.
    [ -f "$CHATS/unreg-old.jsonl" ]
}

@test "retention: an OLD transcript of a LIVE registered session is excluded and survives --delete" {
    # The live session is this very test shell: its real PID, its real starttime, the
    # current boot id.  An age far past the cutoff cannot make it eligible (rule 1).
    register live-sid "$$" "$(proc_start "$$")"
    transcript live-sid "300 days ago"

    run "$TOOL" --qwen-dir "$QWEN" --delete

    [ "$status" -eq 0 ]
    [[ "$output" == *"of those LIVE (rule 1, never touched): 1"* ]]
    [[ "$output" == *"TO REMOVE     0 units, 0 files ("* ]]
    [ -f "$CHATS/live-sid.jsonl" ]
}

@test "retention: an old, unregistered transcript IS listed, with its age printed" {
    transcript unreg-old "200 days ago"

    run "$TOOL" --qwen-dir "$QWEN"

    [ "$status" -eq 0 ]
    [[ "$output" == *"TO REMOVE     1 unit, 1 file ("* ]]
    # Size, mtime and age are all printed: a count alone cannot be checked (rule 3).
    [[ "$output" == *"unreg-old.jsonl  "*"bytes  mtime="* ]]
    [[ "$output" == *"age=200.0 days"* ]]
}

@test "retention: a young, unregistered transcript is NOT listed" {
    transcript unreg-young "2 hours ago"

    run "$TOOL" --qwen-dir "$QWEN"

    [ "$status" -eq 0 ]
    [[ "$output" == *"kept          younger than the cutoff: 1"* ]]
    [[ "$output" == *"TO REMOVE     0 units, 0 files ("* ]]
}

@test "retention: --delete removes exactly the listed set and leaves the rest byte-identical" {
    transcript drop-a "200 days ago"
    transcript drop-b "150 days ago"
    printf '{"session":"drop-a","ledger":true}\n' > "$CHATS/drop-a.ledger.jsonl"
    touch -d "200 days ago" "$CHATS/drop-a.ledger.jsonl"
    transcript keep-young "1 hour ago"
    register live-sid "$$" "$(proc_start "$$")"
    transcript live-sid "300 days ago"
    cp "$CHATS/keep-young.jsonl" "$WORK/expected-keep"
    cp "$CHATS/live-sid.jsonl" "$WORK/expected-live"

    run "$TOOL" --qwen-dir "$QWEN" --delete

    [ "$status" -eq 0 ]
    [[ "$output" == *"TO REMOVE     3 units, 3 files ("* ]]
    [[ "$output" == *"DELETED       3 files"* ]]
    # Exactly the listed three are gone — including the ledger that shares the sessionId.
    [ ! -e "$CHATS/drop-a.jsonl" ]
    [ ! -e "$CHATS/drop-a.ledger.jsonl" ]
    [ ! -e "$CHATS/drop-b.jsonl" ]
    # Everything else is untouched, byte for byte.
    [ -f "$CHATS/keep-young.jsonl" ]
    [ -f "$CHATS/live-sid.jsonl" ]
    cmp "$CHATS/keep-young.jsonl" "$WORK/expected-keep"
    cmp "$CHATS/live-sid.jsonl" "$WORK/expected-live"
    [ "$(ls -1 "$CHATS" | wc -l)" -eq 2 ]
}

@test "retention: a registered-but-DEAD session is out of scope entirely (rule 2)" {
    # pid 999999999 does not exist, so the session is provably dead — and still excluded,
    # because this policy is only for transcripts the registry cannot describe.
    register dead-sid "999999999" "b6f215bc-7896-4b0d-8b81-9ed4e1c6d0ba:12345"
    transcript dead-sid "300 days ago"

    run "$TOOL" --qwen-dir "$QWEN" --delete

    [ "$status" -eq 0 ]
    [[ "$output" == *"excluded      registered (rule 2): 1"* ]]
    [[ "$output" == *"of those LIVE (rule 1, never touched): 0"* ]]
    [[ "$output" == *"TO REMOVE     0 units, 0 files ("* ]]
    [ -f "$CHATS/dead-sid.jsonl" ]
}

@test "retention: the cutoff splits ages as expected — just-older is listed, just-younger is kept" {
    # Absolute epochs, not "10 days 2 hours ago": GNU date does not parse that phrase as one
    # offset, and a fixture whose mtime is not what the test believes would make this case
    # pass for the wrong reason.  100 minutes of margin either side of the cutoff.
    #
    # WHAT THIS DOES NOT PIN, stated so nobody reads more into it: the equality case
    # (mtime exactly == cutoff) is not reachable at second resolution, so the header's
    # "STRICTLY older" choice is a documented decision and NOT a tested consequence —
    # measured 2026-10-01, a mutant comparing with `<=` survives this suite.
    local now
    now=$(date +%s)
    transcript just-over "@$(( now - 10 * 86400 - 6000 ))"
    transcript just-under "@$(( now - 10 * 86400 + 6000 ))"

    run "$TOOL" --qwen-dir "$QWEN" --max-age-days 10

    [ "$status" -eq 0 ]
    [[ "$output" == *"mtime strictly older than 10 days"* ]]
    [[ "$output" == *"TO REMOVE     1 unit, 1 file ("* ]]
    [[ "$output" == *"just-over.jsonl"* ]]
    [[ "$output" != *"TO REMOVE     2 units"* ]]
    [ -f "$CHATS/just-under.jsonl" ]
}

@test "retention: the default scope is one project; another project needs --project (rule 4)" {
    local other="$QWEN/projects/-home-wayne-ubuntu-console/chats"
    mkdir -p "$other"
    printf '{"session":"other-old"}\n' > "$other/other-old.jsonl"
    touch -d "200 days ago" "$other/other-old.jsonl"
    transcript unreg-old "200 days ago"

    run "$TOOL" --qwen-dir "$QWEN"

    [ "$status" -eq 0 ]
    [[ "$output" == *"projects/-home-wayne--openclaw/chats"* ]]
    [[ "$output" == *"unreg-old.jsonl"* ]]
    [[ "$output" != *"other-old.jsonl"* ]]

    run "$TOOL" --qwen-dir "$QWEN" --project -home-wayne-ubuntu-console

    [ "$status" -eq 0 ]
    [[ "$output" == *"projects/-home-wayne-ubuntu-console/chats"* ]]
    [[ "$output" == *"other-old.jsonl"* ]]
    [[ "$output" != *"unreg-old.jsonl"* ]]
}

@test "retention: a missing chat store is a cannot-run, never a clean scan" {
    run "$TOOL" --qwen-dir "$WORK/no-store-here"

    [ "$status" -eq 2 ]
    [[ "$output" == *"no chats store at"* ]]
    [[ "$output" == *"an empty scan is not a clean tree"* ]]
}

@test "retention: a malformed command line is a usage error, not a silent default" {
    transcript unreg-old "200 days ago"

    # A typo'd flag must not be ignored just because it is unrecognised.
    run "$TOOL" --qwen-dir "$QWEN" --dlete
    [ "$status" -eq 2 ]
    [[ "$output" == *"unrecognized argument: --dlete"* ]]
    [[ "$output" == *"usage: qwen-transcript-retention.sh"* ]]

    # A flag with no value must not silently take the default cutoff (an omitted argument is
    # an unmade decision, not a 30-day consent).
    run "$TOOL" --qwen-dir "$QWEN" --max-age-days
    [ "$status" -eq 2 ]
    [[ "$output" == *"--max-age-days needs a value"* ]]

    # A non-numeric value must not be coerced either.
    run "$TOOL" --qwen-dir "$QWEN" --max-age-days soon
    [ "$status" -eq 2 ]
    [[ "$output" == *"--max-age-days is not a number"* ]]

    # None of the three reached a scan, and none of them deleted anything.
    [ -f "$CHATS/unreg-old.jsonl" ]
}

# ==============================================================================
# The default cutoff, and the subagent store (--store subagents)
# ==============================================================================

@test "retention: the default cutoff is 60 days (Wayne's decision, 2026-10-01)" {
    # Both files are far outside the 24 h in-flight window, so only the cutoff can separate
    # them.  A 30-day default would take the 45-day file; a 90-day default would spare the
    # 90-day one — this case pins the value that was actually decided.
    transcript inside-default "45 days ago"
    transcript outside-default "90 days ago"

    run "$TOOL" --qwen-dir "$QWEN"

    [ "$status" -eq 0 ]
    [[ "$output" == *"strictly older than 60 days"* ]]
    [[ "$output" == *"TO REMOVE     1 unit, 1 file ("* ]]
    [[ "$output" == *"outside-default.jsonl"* ]]
    [ -f "$CHATS/inside-default.jsonl" ]
}

@test "retention: a file being written right now is never eligible (rule 6, the in-flight guard)" {
    # The measurement the guard rests on: appending updates mtime.  The cutoff is 0 days, so
    # EVERY file here is "old enough" and only the in-flight window can tell them apart —
    # which is what makes this a test of rule 6 rather than a second test of rule 3.
    subagent parent-gone call-inflight "300 days ago" ".jsonl"
    subagent parent-gone call-abandoned "300 days ago" ".jsonl"
    printf 'append\n' >> "$SUBAGENTS/parent-gone/call-inflight.jsonl"

    run "$TOOL" --qwen-dir "$QWEN" --store subagents --max-age-days 0

    [ "$status" -eq 0 ]
    [[ "$output" == *"in-flight     newest mtime inside 24 h"* ]]
    [[ "$output" == *"kept          inside the in-flight window: 1"* ]]
    [[ "$output" == *"TO REMOVE     1 unit, 1 file ("* ]]
    [[ "$output" == *"call-abandoned"* ]]
    [[ "$output" != *"call-inflight"* ]]
    [ -f "$SUBAGENTS/parent-gone/call-inflight.jsonl" ]
}

@test "retention: an abandoned subagent call is one unit — transcript, sidecar and stale stream go together" {
    subagent parent-gone agent-Explore-deadbeef "200 days ago" ".jsonl" ".meta.json" ".stream"

    run "$TOOL" --qwen-dir "$QWEN" --store subagents --delete

    [ "$status" -eq 0 ]
    [[ "$output" == *"1 unit per call, keyed by the PARENT session directory"* ]]
    [[ "$output" == *"TO REMOVE     1 unit, 3 files ("* ]]
    [[ "$output" == *"DELETED       3 files"* ]]
    # No orphan sidecar and no orphan stream: the call goes as one.
    [ -z "$(ls -A "$SUBAGENTS/parent-gone")" ]
}

@test "retention: a live .stream pins its whole call, transcript and sidecar included" {
    # An in-flight call writes its .stream continuously; the unit's age is the NEWEST of its
    # files, so the fresh partial holds back the 300-day-old transcript beside it.  Delete a
    # transcript out from under a running call and the call is what breaks.
    #
    # The cutoff is 0 days on purpose: at the 60-day default such a unit is ALSO "younger
    # than the cutoff", and then the cutoff, not rule 6, is what saves it — this case pins
    # the rule that actually decides, and the transcript here is old enough that nothing
    # else could.
    subagent parent-gone agent-general-purpose-runnow "300 days ago" ".jsonl" ".meta.json"
    printf 'tokens\n' > "$SUBAGENTS/parent-gone/agent-general-purpose-runnow.jsonl.stream"

    run "$TOOL" --qwen-dir "$QWEN" --store subagents --max-age-days 0 --delete

    [ "$status" -eq 0 ]
    [[ "$output" == *"kept          inside the in-flight window: 1"* ]]
    [[ "$output" == *"TO REMOVE     0 units, 0 files ("* ]]
    [ -f "$SUBAGENTS/parent-gone/agent-general-purpose-runnow.jsonl" ]
    [ -f "$SUBAGENTS/parent-gone/agent-general-purpose-runnow.meta.json" ]
}

@test "retention: a live registered parent's subagent call is excluded and survives --delete (rule 1)" {
    # The subagent file names no session, so the ONLY link is the parent directory.  Here the
    # parent is this test shell, registered and alive: its calls are excluded whatever age
    # they carry.
    register live-parent "$$" "$(proc_start "$$")"
    subagent live-parent agent-Explore-12345678 "300 days ago" ".jsonl" ".meta.json"

    run "$TOOL" --qwen-dir "$QWEN" --store subagents --delete

    [ "$status" -eq 0 ]
    [[ "$output" == *"of those LIVE (rule 1, never touched): 1"* ]]
    [[ "$output" == *"TO REMOVE     0 units, 0 files ("* ]]
    [ -f "$SUBAGENTS/live-parent/agent-Explore-12345678.jsonl" ]
}

@test "retention: rule 2 excludes nothing for subagents — a registered parent is a LIVE parent" {
    # Stated in the header, and measured here: the registry holds live sessions, so a parent
    # found in it is registered AND live, and rule 2's own contribution is zero.  A subagent
    # call whose parent is NOT in the registry is what the policy actually decides on.
    register registered-parent "$$" "$(proc_start "$$")"
    subagent registered-parent agent-Explore-aaaaaaaa "300 days ago" ".jsonl"
    subagent never-registered agent-Explore-bbbbbbbb "300 days ago" ".jsonl"

    run "$TOOL" --qwen-dir "$QWEN" --store subagents

    [ "$status" -eq 0 ]
    [[ "$output" == *"excluded      registered (rule 2): 1"* ]]
    [[ "$output" == *"TO REMOVE     1 unit, 1 file ("* ]]
    [[ "$output" == *"never-registered/agent-Explore-bbbbbbbb  "* ]]
    # The registered parent's call is REPORTED as excluded; it must not appear in the plan
    # listing, whose entries are the full path under the store (the exclusion lines are not).
    [[ "$output" != *"/subagents/registered-parent/"* ]]
}

@test "retention: --store selects one store and leaves the other alone" {
    transcript chat-old "300 days ago"
    subagent parent-gone agent-Explore-99999999 "300 days ago" ".jsonl"

    run "$TOOL" --qwen-dir "$QWEN"
    [ "$status" -eq 0 ]
    [[ "$output" == *"store         chats ("* ]]
    [[ "$output" == *"chat-old.jsonl"* ]]
    [[ "$output" != *"agent-Explore-99999999"* ]]

    run "$TOOL" --qwen-dir "$QWEN" --store subagents
    [ "$status" -eq 0 ]
    [[ "$output" == *"store         subagents ("* ]]
    [[ "$output" == *"agent-Explore-99999999"* ]]
    [[ "$output" != *"chat-old.jsonl"* ]]
}
