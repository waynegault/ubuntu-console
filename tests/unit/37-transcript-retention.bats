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
    REGISTRY="$QWEN/sessions"
    mkdir -p "$CHATS" "$REGISTRY"
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
    [[ "$output" == *"TO REMOVE     1 ("* ]]
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
    [[ "$output" == *"TO REMOVE     0 ("* ]]
    [ -f "$CHATS/live-sid.jsonl" ]
}

@test "retention: an old, unregistered transcript IS listed, with its age printed" {
    transcript unreg-old "200 days ago"

    run "$TOOL" --qwen-dir "$QWEN"

    [ "$status" -eq 0 ]
    [[ "$output" == *"TO REMOVE     1 ("* ]]
    # Size, mtime and age are all printed: a count alone cannot be checked (rule 3).
    [[ "$output" == *"unreg-old.jsonl  "*"bytes  mtime="* ]]
    [[ "$output" == *"age=200.0 days"* ]]
}

@test "retention: a young, unregistered transcript is NOT listed" {
    transcript unreg-young "2 hours ago"

    run "$TOOL" --qwen-dir "$QWEN"

    [ "$status" -eq 0 ]
    [[ "$output" == *"kept          younger than the cutoff: 1"* ]]
    [[ "$output" == *"TO REMOVE     0 ("* ]]
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
    [[ "$output" == *"TO REMOVE     3 ("* ]]
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
    [[ "$output" == *"TO REMOVE     0 ("* ]]
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
    [[ "$output" == *"TO REMOVE     1 ("* ]]
    [[ "$output" == *"just-over.jsonl"* ]]
    [[ "$output" != *"TO REMOVE     2 ("* ]]
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
    [[ "$output" == *"no chat store at"* ]]
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
