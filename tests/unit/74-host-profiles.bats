#!/usr/bin/env bats
# ==============================================================================
# Unit — host profiles: one repo, two machines, no shared per-box defaults
# ==============================================================================
# Criterion (Wayne's requirement, 2026-10-29): this repo must work on the Intel
# x86_64 WSL box AND on the ASUS arm64 WSL box, and each box has its own GPU, its
# own model store and its own model set.  So a value that is true of one machine —
# its lanes, its card size, its quant ratings, its labels — must never be inherited
# by the other, and the choice of machine must be refused rather than guessed.
#
# What these cases would catch, per case, is in each test's comment.  The facts are
# injected (TAC_HOST_FACTS_OVERRIDE, or HOSTTYPE), so no case needs the other box's
# hardware; the profiles themselves are the shipped ones.
# ==============================================================================

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
LIB="$REPO_ROOT/tools/host-profile.sh"
PROFILE_DIR="$REPO_ROOT/config/hosts.d"

setup() {
    FIXTURE="$BATS_TEST_TMPDIR/profiles"
    mkdir -p "$FIXTURE"
}

# selected_with FACTS — resolve a profile with the machine's facts stated.
selected_with() {
    env TAC_HOST_FACTS_OVERRIDE="$1" TAC_HOST_PROFILE_FILE="$BATS_TEST_TMPDIR/no-override" \
        bash -c 'source "$1"; tac_host_profile_selected' _ "$LIB"
}

@test "the shipped intel profile matches this box's facts and no other arch" {
    # Catches: an arm64 host being handed the x86 box's lanes because arch was not
    # part of the match.
    run env TAC_HOST_PROFILE_DIR="$PROFILE_DIR" bash -c '
        source "$1"
        tac_host_profile_match intel-xe-cuda x86_64 1 1 &&
        ! tac_host_profile_match intel-xe-cuda aarch64 1 0' _ "$LIB"
    [ "$status" -eq 0 ]
}

@test "the shipped arm64 profile matches with or without a render node" {
    # Catches: requiring a render node on a box whose SoC may not expose one,
    # which would leave the ASUS box with no profile at all.
    run env TAC_HOST_PROFILE_DIR="$PROFILE_DIR" bash -c '
        source "$1"
        tac_host_profile_match asus-n1n-rtx-spark aarch64 1 0 &&
        tac_host_profile_match asus-n1n-rtx-spark aarch64 1 1 &&
        ! tac_host_profile_match asus-n1n-rtx-spark x86_64 1 1' _ "$LIB"
    [ "$status" -eq 0 ]
}

@test "detection selects exactly one profile per box and refuses an unknown machine" {
    # Catches: a silent fall-through that picks a neighbour profile (or none) where
    # the caller expects a decision.
    run selected_with "x86_64 1 1"
    [ "$status" -eq 0 ]
    [ "$output" = "intel-xe-cuda" ]

    run selected_with "aarch64 1 0"
    [ "$status" -eq 0 ]
    [ "$output" = "asus-n1n-rtx-spark" ]

    run selected_with "x86_64 0 0"
    [ "$status" -eq 2 ]
    [[ "$output" == *"no profile matches"* ]]
    [[ "$output" == *"arch=x86_64 cuda=0 render=0"* ]]
}

@test "two matching profiles are refused, naming both" {
    # Catches: first-match-wins, which silently runs one box's tuning on another.
    cp "$PROFILE_DIR/intel-xe-cuda.conf" "$FIXTURE/one.conf"
    cp "$PROFILE_DIR/intel-xe-cuda.conf" "$FIXTURE/two.conf"
    run env TAC_HOST_PROFILE_DIR="$FIXTURE" TAC_HOST_FACTS_OVERRIDE="x86_64 1 1" \
        TAC_HOST_PROFILE_FILE="$BATS_TEST_TMPDIR/no-override" \
        bash -c 'source "$1"; tac_host_profile_selected' _ "$LIB"
    [ "$status" -eq 3 ]
    [[ "$output" == *"2 profiles match"* ]]
    [[ "$output" == *"one"* && "$output" == *"two"* ]]
}

@test "an explicit override wins over detection and is honoured off its own arch" {
    # Catches: detection quietly overriding the operator's stated choice, which is
    # how a box gets the other machine's lanes against a written decision.
    run env LLM_HOST_PROFILE="asus-n1n-rtx-spark" TAC_HOST_FACTS_OVERRIDE="x86_64 1 1" \
        bash -c 'source "$1"; tac_host_profile_selected' _ "$LIB"
    [ "$status" -eq 0 ]
    [ "$output" = "asus-n1n-rtx-spark" ]
}

@test "the recorded override file is read, comments and blank lines ignored, env wins" {
    # Catches: the box's recorded id being ignored (detection then decides), or the
    # env var losing to the file.
    printf '# this box is the arm one\n\n  asus-n1n-rtx-spark  \n' > "$BATS_TEST_TMPDIR/host-profile"
    run env TAC_HOST_PROFILE_FILE="$BATS_TEST_TMPDIR/host-profile" \
        TAC_HOST_FACTS_OVERRIDE="x86_64 1 1" \
        bash -c 'source "$1"; tac_host_profile_selected' _ "$LIB"
    [ "$status" -eq 0 ]
    [ "$output" = "asus-n1n-rtx-spark" ]

    run env TAC_HOST_PROFILE_FILE="$BATS_TEST_TMPDIR/host-profile" \
        LLM_HOST_PROFILE="intel-xe-cuda" TAC_HOST_FACTS_OVERRIDE="aarch64 1 0" \
        bash -c 'source "$1"; tac_host_profile_selected' _ "$LIB"
    [ "$status" -eq 0 ]
    [ "$output" = "intel-xe-cuda" ]
}

@test "an unknown override is refused by name, listing the profiles" {
    # Catches: a typo silently falling back to detection and running the wrong box.
    run env LLM_HOST_PROFILE="intel-xe-cudda" TAC_HOST_FACTS_OVERRIDE="x86_64 1 1" \
        bash -c 'source "$1"; tac_host_profile_selected' _ "$LIB"
    [ "$status" -eq 2 ]
    [[ "$output" == *'unknown profile "intel-xe-cudda"'* ]]
    [[ "$output" == *"intel-xe-cuda"* ]]
}

@test "every shipped profile is well-formed: id matches its file name, arch declared" {
    # Catches: a profile that sources but never matches (missing ARCH) or answers to
    # a name other than the one the override file would carry.
    local f id arch
    for f in "$PROFILE_DIR"/*.conf
    do
        id="$(bash -c 'source "$1"; printf "%s" "${TAC_HOST_PROFILE_ID:-}"' _ "$f")"
        arch="$(bash -c 'source "$1"; printf "%s" "${TAC_HOST_PROFILE_ARCH:-}"' _ "$f")"
        [ "$id.conf" = "${f##*/}" ] \
            || { echo "FAIL: ${f##*/} calls itself '$id'"; return 1; }
        [[ -n "$arch" ]] || { echo "FAIL: ${f##*/} declares no TAC_HOST_PROFILE_ARCH"; return 1; }
    done
}

@test "every port-serving unit is owned by a profile; shared units may opt out" {
    # Catches: a new lane added without ownership (so it links everywhere).  A unit
    # WITHOUT a port may still be owned — the watchdog supervises this box's lanes by
    # name and must travel with them — but a named owner must be a real profile.
    local unit owner
    for unit in "$REPO_ROOT"/systemd/*.service
    do
        owner="$(bash -c 'source "$1"; tac_host_unit_profile "$2"' _ "$LIB" "$unit")"
        if grep -q -- '--port' "$unit"
        then
            [ "$owner" != "any" ] \
                || { echo "FAIL: ${unit##*/} serves a port but is owned by no profile"; return 1; }
        fi
        if [ "$owner" != "any" ]
        then
            [ -f "$PROFILE_DIR/$owner.conf" ] \
                || { echo "FAIL: ${unit##*/} names unknown profile '$owner'"; return 1; }
        fi
    done
}

@test "applying this box's profile exports its lanes, card size and quant guide" {
    # Catches: the applier sourcing a profile but not exporting what modules read —
    # the failure mode where `model lanes` and sizing fall back to generic silently.
    run env LLM_HOST_PROFILE="intel-xe-cuda" TAC_HOST_FACTS_OVERRIDE="x86_64 1 1" \
        bash -c 'source "$1"; tac_host_profile_apply; printf "%s|%s|%s|%s\n" \
            "$TAC_HOST_PROFILE" "$(printf "%s\n" "$LLAMA_LANE_SPECS" | grep -c .)" \
            "$VRAM_TOTAL_BYTES_FALLBACK" "${QUANT_GUIDE##*/}"' _ "$LIB"
    [ "$status" -eq 0 ]
    [ "$output" = "intel-xe-cuda|5|4294967296|quant-guide.conf" ]
}

@test "applying the arm64 profile claims no lanes and no quant ratings" {
    # Catches: the 4 GB quant guide (which auto-archives on `model scan`) or this
    # box's lanes being applied on a machine they do not describe.
    run env LLM_HOST_PROFILE="asus-n1n-rtx-spark" TAC_HOST_FACTS_OVERRIDE="aarch64 1 0" \
        bash -c 'source "$1"; tac_host_profile_apply; printf "%s|[%s]|[%s]|%s\n" \
            "$TAC_HOST_PROFILE" "$LLAMA_LANE_SPECS" "$QUANT_GUIDE" "$VRAM_TOTAL_BYTES_FALLBACK"' \
        _ "$LIB"
    [ "$status" -eq 0 ]
    [ "$output" = "asus-n1n-rtx-spark|[]|[]|0" ]
}

@test "an unmatched host keeps generic defaults and says so once" {
    # Catches: an unrecognised box aborting the shell (no console at all) or
    # inheriting a profile in silence, and a notice repeated on every source.
    run env TAC_HOST_FACTS_OVERRIDE="x86_64 0 0" TAC_HOST_PROFILE_FILE="$BATS_TEST_TMPDIR/none" \
        bash -c 'source "$1" 2>&1; tac_host_profile_apply; tac_host_profile_apply; \
                 printf "%s|%s\n" "$TAC_HOST_PROFILE" "$TAC_HOST_PROFILE_MATCHED"' _ "$LIB"
    [ "$status" -eq 0 ]
    [[ "$output" == *"generic|0"* ]]
    [ "$(printf '%s\n' "$output" | grep -c 'none selected')" -eq 1 ]
}

# install_stub_env — a temp HOME plus systemctl/sudo stubs, the shape
# tests/unit/71 uses: `sudo -n true` SUCCEEDS on this box, so an unstubbed run would
# really copy units into /etc.
install_stub_env() {
    INSTALL_HOME="$BATS_TEST_TMPDIR/install-home"
    STUB_DIR="$BATS_TEST_TMPDIR/install-stubs"
    mkdir -p "$INSTALL_HOME" "$STUB_DIR"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB_DIR/systemctl"
    printf '#!/usr/bin/env bash\nexit 1\n' > "$STUB_DIR/sudo"
    chmod +x "$STUB_DIR/systemctl" "$STUB_DIR/sudo"
}

@test "the installer links this box's lane units and none of another profile's" {
    # The load-bearing install case: a lane unit names a GGUF file in ONE box's
    # model store, so linking it elsewhere starts a service against a model that is
    # not there.  Catches: the marker being read but not acted on.
    install_stub_env
    run env HOME="$INSTALL_HOME" PATH="$STUB_DIR:$PATH" LLM_HOST_PROFILE="asus-n1n-rtx-spark" \
        bash "$REPO_ROOT/install.sh"
    [ "$status" -eq 0 ]
    local unit_dir="$INSTALL_HOME/.config/systemd/user"
    [ ! -e "$unit_dir/llama-xe-minicpm5-1b-chat.service" ]
    [ ! -e "$unit_dir/llama-cuda-llama32-3b-chat.service" ]
    [ ! -e "$unit_dir/llama-cpu-qwen25-3b-chat.service" ]
    # ...while a shared unit that must exist on every box is still installed.  The
    # watchdog is NOT one: it supervises this box's lanes by name, so it travels with
    # them and must be absent here too.
    [ -e "$unit_dir/llm-lane-cache-sample.service" ]
    [ ! -e "$unit_dir/llama-watchdog.service" ]
}

@test "the installer removes a stale lane link that belongs to another profile" {
    # Catches the state a box installed BEFORE this layer is left in: the symlink
    # survives a re-install that merely skips it, so systemd keeps starting a lane
    # that names another machine's model file.  Measured 2026-10-30 — the ASUS box
    # carried this repo's CPU lane as a live, enabled and failing unit that way.
    install_stub_env
    local unit_dir="$INSTALL_HOME/.config/systemd/user"
    mkdir -p "$unit_dir"
    ln -s "$REPO_ROOT/systemd/llama-xe-minicpm5-1b-chat.service" \
        "$unit_dir/llama-xe-minicpm5-1b-chat.service"
    # The legacy alias the installer itself creates, pointing at that unit by name.
    ln -s "llama-xe-minicpm5-1b-chat.service" "$unit_dir/llama-server.service"
    printf '[Unit]\nDescription=the operator own unit\n' > "$unit_dir/operator-own.service"

    run env HOME="$INSTALL_HOME" PATH="$STUB_DIR:$PATH" LLM_HOST_PROFILE="asus-n1n-rtx-spark" \
        bash "$REPO_ROOT/install.sh"
    [ "$status" -eq 0 ]
    [ ! -e "$unit_dir/llama-xe-minicpm5-1b-chat.service" ]
    [ ! -L "$unit_dir/llama-xe-minicpm5-1b-chat.service" ]
    [[ "$output" == *"removed llama-xe-minicpm5-1b-chat.service (belongs to profile: intel-xe-cuda)"* ]]
    # The installer's own alias goes with its target rather than dangling.
    [ ! -e "$unit_dir/llama-server.service" ]
    [ ! -L "$unit_dir/llama-server.service" ]
    # Control: a unit the operator owns is never touched.
    [ -e "$unit_dir/operator-own.service" ]
}

@test "the installer keeps a link for the box's OWN profile" {
    # Control for the removal above: the same link must survive where it belongs,
    # or the next re-install on this box deletes its own lanes.
    install_stub_env
    local unit_dir="$INSTALL_HOME/.config/systemd/user"
    mkdir -p "$unit_dir"
    ln -s "$REPO_ROOT/systemd/llama-xe-minicpm5-1b-chat.service" \
        "$unit_dir/llama-xe-minicpm5-1b-chat.service"

    run env HOME="$INSTALL_HOME" PATH="$STUB_DIR:$PATH" LLM_HOST_PROFILE="intel-xe-cuda" \
        bash "$REPO_ROOT/install.sh"
    [ "$status" -eq 0 ]
    [ -L "$unit_dir/llama-xe-minicpm5-1b-chat.service" ]
    [[ "$output" != *"removed llama-xe-minicpm5-1b-chat.service"* ]]
}

@test "the recommender refuses to rank when the card cannot answer and no fallback exists" {
    # Catches: an invented card size on a box this repo has never measured — a 4 GB
    # ranking hides models the card can hold and recommends ones it cannot, and
    # nothing in the output would say the size was guessed.  Hermetic: a failing
    # nvidia-smi stub, the arm64 profile (fallback 0), and a throwaway registry.
    local stub="$BATS_TEST_TMPDIR/nosmi"
    mkdir -p "$stub"
    printf '#!/bin/sh\nexit 1\n' > "$stub/nvidia-smi"
    chmod +x "$stub/nvidia-smi"
    printf '#|name|file\n' > "$BATS_TEST_TMPDIR/registry.conf"
    run env LLM_HOST_PROFILE="asus-n1n-rtx-spark" PATH="$stub:$PATH" \
        LLM_REGISTRY="$BATS_TEST_TMPDIR/registry.conf" TAC_CACHE_DIR="$BATS_TEST_TMPDIR/cache" \
        bash -c 'source "$1" >/dev/null 2>&1; model-recommend general' _ "$REPO_ROOT/env.sh"
    [ "$status" -eq 1 ]
    [[ "$output" == *"UNKNOWN"* ]]
}

@test "the installer links all five lanes on this box's own profile" {
    # Control for the case above: the filter must not drop this box's lanes, or the
    # next fresh install here comes up with no resident model at all.
    install_stub_env
    run env HOME="$INSTALL_HOME" PATH="$STUB_DIR:$PATH" LLM_HOST_PROFILE="intel-xe-cuda" \
        bash "$REPO_ROOT/install.sh"
    [ "$status" -eq 0 ]
    local unit_dir="$INSTALL_HOME/.config/systemd/user"
    [ -e "$unit_dir/llama-xe-minicpm5-1b-chat.service" ]
    [ -e "$unit_dir/llama-xe-embeddinggemma-embed.service" ]
    [ -e "$unit_dir/llama-xe-llama32-3b-chat.service" ]
    [ -e "$unit_dir/llama-cuda-llama32-3b-chat.service" ]
    [ -e "$unit_dir/llama-cpu-qwen25-3b-chat.service" ]
}
