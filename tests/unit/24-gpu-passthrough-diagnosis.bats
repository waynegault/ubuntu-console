#!/usr/bin/env bats
# ==============================================================================
# Unit — gpu-passthrough-check.sh: the CAUSE behind a failed probe
#        (card c7e15c7a, 2026-11-02)
# ==============================================================================
# nvidia-smi is a dlopen client of libcuda.so.1, so it cannot distinguish "the
# passthrough is gone" from "the loader resolved a different libcuda", and it reports
# both as the same rc=9 "couldn't communicate with the NVIDIA driver".
#
# On 2026-11-02 an `apt install nvidia-cuda-toolkit` filled an empty multiarch slot;
# every new process then resolved libcuda.so.1 to /usr/lib/aarch64-linux-gnu ahead of
# /usr/lib/wsl/lib, and this check reported state=unavailable while the card was
# healthy and serving :18087 under LD_LIBRARY_PATH. Its remedy — `wsl --shutdown` —
# stops the gateway and all fourteen lanes and reorders nothing.
#
# So the verdict is CLASSIFIED before it is reported: reading the ldconfig cache costs
# no driver call, and `diagnosis` (ok | liborder | wedge | unclassified) plus the
# remedy text now follow the evidence. Two things must stay true and are pinned here:
#
#   1. A failed probe is NOT reported as a hardware verdict unless the order was read
#      and found correct. Order unreadable means "unclassified", and it prescribes
#      NEITHER remedy — an honest "cannot decide" beats a confident wrong cause.
#   2. `state` and the exit codes do not move. Consumers (gpu-passthrough-watch.sh,
#      gpu-lane-recover.sh, llama-watchdog.sh) gate on those, and a lane must still
#      refuse to start — only the stated CAUSE and the fix change.
#
# Hermetic: the nvidia-smi and ldconfig seams (NVIDIA_SMI, GPU_LDCONFIG,
# GPU_WSL_LIBCUDA) are stubs in the test tmpdir; no live box is touched.
# ==============================================================================

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
CHECK="$REPO_ROOT/bin/gpu-passthrough-check.sh"

setup() {
    export GPU_CHECK_WINDOW_MIN=1
    STUB="$BATS_TEST_TMPDIR"
    export GPU_WSL_LIBCUDA="$STUB/wsl/libcuda.so.1"
    mkdir -p "$STUB/wsl"; : >"$GPU_WSL_LIBCUDA"

    # nvidia-smi stubs. The count file proves the single-probe contract.
    cat >"$STUB/smi-ok" <<'EOF'
#!/usr/bin/env bash
printf 'GPU 0: NVIDIA RTX Spark N1X (UUID: GPU-1)\n'
EOF
    cat >"$STUB/smi-fail" <<EOF
#!/usr/bin/env bash
printf 'x\n' >>"$STUB/smi-calls"
printf 'NVIDIA-SMI has failed because it could not communicate with the NVIDIA driver.\n' >&2
exit 9
EOF
    # ldconfig stubs: the first libcuda.so.1 line in \\`ldconfig -p\\` is the cache winner.
    cat >"$STUB/ldc-native" <<EOF
#!/usr/bin/env bash
printf '\tlibcuda.so.1 (libc6,AArch64) => /usr/lib/aarch64-linux-gnu/libcuda.so.1\n'
printf '\tlibcuda.so.1 (libc6,AArch64) => $GPU_WSL_LIBCUDA\n'
EOF
    cat >"$STUB/ldc-wsl" <<EOF
#!/usr/bin/env bash
printf '\tlibcuda.so.1 (libc6,AArch64) => $GPU_WSL_LIBCUDA\n'
printf '\tlibcuda.so.1 (libc6,AArch64) => /usr/lib/aarch64-linux-gnu/libcuda.so.1\n'
EOF
    cat >"$STUB/ldc-empty" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    # libcuda.so.1.1 must never satisfy the exact-name match.
    cat >"$STUB/ldc-only-dotdot" <<EOF
#!/usr/bin/env bash
printf '\tlibcuda.so.1.1 (libc6,AArch64) => $GPU_WSL_LIBCUDA\n'
EOF
    chmod +x "$STUB"/smi-* "$STUB"/ldc-*
    : >"$STUB/smi-calls"
}

# field <JSON> <name> — read one string field without a JSON parser dependency.
field() { sed -n "s/.*\"$2\":\"\([^\"]*\)\".*/\1/p" <<<"$1"; }

@test "diagnosis: a loader-order fault is named as ORDER, not as lost passthrough" {
    run env NVIDIA_SMI="$STUB/smi-fail" GPU_LDCONFIG="$STUB/ldc-native" "$CHECK" --json
    [ "$status" -eq 1 ]
    [ "$(field "$output" state)" = unavailable ]
    [ "$(field "$output" diagnosis)" = liborder ]
    [ "$(field "$output" order)" = checked ]
    # the evidence is the path that actually won, not a category
    [ "$(field "$output" libcuda_first)" = "/usr/lib/aarch64-linux-gnu/libcuda.so.1" ]
    [[ "$(field "$output" reason)" == *"LOADER-ORDER"* ]]
}

@test "diagnosis: the loader remedy replaces the reboot, and the reboot is named as a trap" {
    run env NVIDIA_SMI="$STUB/smi-fail" GPU_LDCONFIG="$STUB/ldc-native" "$CHECK" --alert
    [ "$status" -eq 1 ]
    # the fix offered is the drop-in + ldconfig
    [[ "$output" == *"Fix (in-VM"* ]]
    [[ "$output" == *"00-wsl-libcuda.conf"* ]]
    # and the host reboot appears ONLY as an explicit do-not
    [[ "$output" == *"Do NOT run 'wsl --shutdown'"* ]]
    [[ "$output" != *"Fix (host-side"* ]]
    # a purge is refused by name, because it takes the toolkit's neighbours with it
    [[ "$output" == *"g++-13"* ]]
}

@test "diagnosis: order read and correct leaves hardware as the explanation (wedge)" {
    run env NVIDIA_SMI="$STUB/smi-fail" GPU_LDCONFIG="$STUB/ldc-wsl" "$CHECK" --json
    [ "$status" -eq 1 ]
    [ "$(field "$output" diagnosis)" = wedge ]
    [ "$(field "$output" order)" = checked ]
    run env NVIDIA_SMI="$STUB/smi-fail" GPU_LDCONFIG="$STUB/ldc-wsl" "$CHECK" --alert
    # the host-side remedy belongs here, and only here
    [[ "$output" == *"Fix (host-side"* ]]
    [[ "$output" == *"PASSTHROUGH LOST"* ]]
}

@test "diagnosis: an unreadable order is 'unclassified' and prescribes NEITHER remedy" {
    for ldc in ldc-empty ldc-only-dotdot nonexistent; do
        run env NVIDIA_SMI="$STUB/smi-fail" GPU_LDCONFIG="$STUB/$ldc" "$CHECK" --json
        [ "$status" -eq 1 ]
        [ "$(field "$output" diagnosis)" = unclassified ] || { echo "ldc=$ldc"; false; }
        run env NVIDIA_SMI="$STUB/smi-fail" GPU_LDCONFIG="$STUB/$ldc" "$CHECK" --alert
        [[ "$output" == *"UNATTRIBUTED"* ]]
        [[ "$output" != *"Fix (host-side"* ]]
        [[ "$output" != *"Fix (in-VM"* ]]
    done
}

@test "contract: state and exit codes do not move (consumers gate on them)" {
    run env NVIDIA_SMI="$STUB/smi-ok" "$CHECK" --json
    [ "$status" -eq 0 ]; [ "$(field "$output" state)" = ok ]
    run env NVIDIA_SMI="$STUB/smi-fail" GPU_LDCONFIG="$STUB/ldc-native" "$CHECK" --json
    [ "$status" -eq 1 ]; [ "$(field "$output" state)" = unavailable ]
    run env NVIDIA_SMI="$STUB/absent-binary" "$CHECK" --json
    [ "$status" -eq 2 ]; [ "$(field "$output" state)" = error ]
}

@test "contract: a working probe is never gated on the cache" {
    # the card answers, so the order is irrelevant — a healthy lane must not be parked
    # by a classification that only exists to explain a FAILURE
    run env NVIDIA_SMI="$STUB/smi-ok" GPU_LDCONFIG="$STUB/ldc-native" "$CHECK" --json
    [ "$status" -eq 0 ]
    [ "$(field "$output" state)" = ok ]
    [ "$(field "$output" diagnosis)" = ok ]
    [ "$(field "$output" order)" = not-checked ]
}

@test "contract: the --json document PARSES, so a consumer can read it as JSON" {
    # Added after the first version of this file passed against a malformed document: field()
    # reads with sed, which finds "state" in broken JSON as happily as in valid JSON. A
    # backslash-newline inside a single-quoted printf format emitted a literal \\ and a real
    # newline, and all seven tests above stayed green. Parse the document, do not pattern it.
    run env NVIDIA_SMI="$STUB/smi-fail" GPU_LDCONFIG="$STUB/ldc-native" "$CHECK" --json
    [ "$status" -eq 1 ]
    python3 - "$output" <<'PY'
import json, sys
obj = json.loads(sys.argv[1])
for key in ("state", "diagnosis", "order", "reason", "libcuda_first",
            "smi_rc", "devices", "window_min", "dxg_failures", "wsl_crashes"):
    assert key in obj, f"missing key {key}"
assert obj["diagnosis"] == "liborder"
assert "\n" not in obj["reason"], "reason carries an embedded newline"
print("parsed")
PY
}

@test "contract: prose joins keep their separators (a reflow must not run words together)" {
    # The prose is written as bash line continuations to stay under 120 columns. A backslash
    # that swallows the following space joins two words silently: the first version shipped
    # `'/usr/lib/wsl/lib\\n'| sudo tee` and `—then re-run`, readable-but-wrong, with every
    # test above green because they assert on other substrings.
    run env NVIDIA_SMI="$STUB/smi-fail" GPU_LDCONFIG="$STUB/ldc-native" "$CHECK" --alert
    [[ "$output" == *"' | sudo tee"* ]]
    [[ "$output" == *"— then re-run"* ]]
    [[ "$output" != *"'| sudo"* ]]
    [[ "$output" != *"—then"* ]]
    run env NVIDIA_SMI="$STUB/smi-fail" GPU_LDCONFIG="$STUB/ldc-none" "$CHECK" --alert
    [[ "$output" == *"with LD_LIBRARY_PATH"* ]]
    [[ "$output" != *"withLD_LIBRARY_PATH"* ]]
}

@test "contract: a failed probe is called exactly ONCE, classification or not" {
    # each invocation on a genuinely broken GPU is a crash plus a WSL core dump, so the
    # discriminator reads a file cache and never re-probes the driver
    run env NVIDIA_SMI="$STUB/smi-fail" GPU_LDCONFIG="$STUB/ldc-native" "$CHECK" --json
    [ "$status" -eq 1 ]
    [ "$(grep -c '^x$' "$STUB/smi-calls")" -eq 1 ]
}
