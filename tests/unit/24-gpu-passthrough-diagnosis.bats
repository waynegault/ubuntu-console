#!/usr/bin/env bats
# ==============================================================================
# Unit — gpu-passthrough-check.sh: the CAUSE behind a failed probe
#        (card c7e15c7a, 2026-11-02; two-arm rule added 2026-11-10)
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
# Module Version 3 replaces the nvidia-smi predicate with a CONTEXT MINT and adds the
# TWO-ARM RULE. These are the invariants pinned here:
#
#   1. A failed probe is NOT a hardware verdict unless BOTH arms were run and both
#      failed, and the loader order was read and found correct. Anything less is
#      liborder, libshadow or unclassified — and none of those prescribes a reboot.
#   2. The WSL arm succeeding is decisive: diagnosis=libshadow, verdict=
#      library-shadowed, even when the cache read says the order is correct. The
#      two-arm test outranks the cache; it is a context, the cache is a metadata file.
#   3. `state` and the exit codes do not move. Consumers (gpu-passthrough-watch.sh,
#      gpu-lane-recover.sh, llama-watchdog.sh) gate on those, and a lane must still
#      refuse to start — only the stated CAUSE and the fix change.
#   4. Both arm results appear in BOTH the JSON and the --alert prose, so an
#      escalation quotes what it measured instead of asserting a cause.
#
# Hermetic: the context probe, ldconfig and the expected WSL libcuda are stubs in the
# test tmpdir; no live box and no driver is touched.
# ==============================================================================

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
CHECK="$REPO_ROOT/bin/gpu-passthrough-check.sh"

setup() {
    export GPU_CHECK_WINDOW_MIN=1
    unset LD_LIBRARY_PATH
    STUB="$BATS_TEST_TMPDIR"
    export GPU_WSL_LIBDIR="$STUB/wsl"
    export GPU_WSL_LIBCUDA="$STUB/wsl/libcuda.so.1"
    mkdir -p "$STUB/wsl"; : >"$GPU_WSL_LIBCUDA"

    # --- context-mint stubs. The count file proves the arm contract. -----------
    cat >"$STUB/ctx-ok" <<EOF
#!/usr/bin/env bash
printf 'x\n' >>"$STUB/mint-calls"
printf 'context=ok device=0 backend=ctypes\n'
exit 0
EOF
    cat >"$STUB/ctx-fail" <<EOF
#!/usr/bin/env bash
printf 'x\n' >>"$STUB/mint-calls"
printf 'context=failed step=cuCtxCreate rc=999 error=CUDA_ERROR_UNKNOWN\n' >&2
exit 1
EOF
    # The shadow shape: the default arm cannot mint; the WSL arm can. This is the
    # exact 2026-11-02 fault and the reason the two-arm test exists.
    cat >"$STUB/ctx-shadow" <<EOF
#!/usr/bin/env bash
printf 'x\n' >>"$STUB/mint-calls"
case ":\${LD_LIBRARY_PATH:-}:" in
    *":\${GPU_WSL_LIBDIR}:"*) printf 'context=ok device=0 backend=ctypes\n'; exit 0 ;;
esac
printf 'context=failed step=cuInit rc=100 error=CUDA_ERROR_NO_DEVICE\n' >&2
exit 1
EOF
    # The instrument itself is unavailable. This may NEVER be escalated as wedge.
    cat >"$STUB/ctx-unavailable" <<EOF
#!/usr/bin/env bash
printf 'x\n' >>"$STUB/mint-calls"
printf 'context=unavailable backend=ctypes detail=cannot-load-libcuda\n' >&2
exit 3
EOF
    # A driver wedged in D state does not answer. The timeout must bound the check.
    cat >"$STUB/ctx-hang" <<EOF
#!/usr/bin/env bash
printf 'x\n' >>"$STUB/mint-calls"
sleep 30
EOF
    # ldconfig stubs: the first libcuda.so.1 line in \`ldconfig -p\` is the cache winner.
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
    chmod +x "$STUB"/ctx-* "$STUB"/ldc-*
    : >"$STUB/mint-calls"
    export GPU_CONTEXT_PROBE="$STUB/ctx-ok"
}

# field <JSON> <name> — read one string field without a JSON parser dependency.
field() { sed -n "s/.*\"$2\":\"\([^\"]*\)\".*/\1/p" <<<"$1"; }
# nfield <JSON> <name> — read one numeric field.
nfield() { sed -n "s/.*\"$2\":\([-0-9]*\).*/\1/p" <<<"$1"; }

@test "diagnosis: a loader-order fault is named as ORDER, not as lost passthrough" {
    run env GPU_CONTEXT_PROBE="$STUB/ctx-fail" GPU_LDCONFIG="$STUB/ldc-native" "$CHECK" --json
    [ "$status" -eq 1 ]
    [ "$(field "$output" state)" = unavailable ]
    [ "$(field "$output" diagnosis)" = liborder ]
    [ "$(field "$output" verdict)" = loader-order ]
    [ "$(field "$output" order)" = checked ]
    # both arms are in the document the escalation is built from
    [ "$(field "$output" arm_default)" = fail ]
    [ "$(field "$output" arm_wsl)" = fail ]
    # the evidence is the path that actually won, not a category
    [ "$(field "$output" libcuda_first)" = "/usr/lib/aarch64-linux-gnu/libcuda.so.1" ]
    [[ "$(field "$output" reason)" == *"LOADER-ORDER"* ]]
}

@test "diagnosis: the loader remedy replaces the reboot, and the reboot is named as a trap" {
    run env GPU_CONTEXT_PROBE="$STUB/ctx-fail" GPU_LDCONFIG="$STUB/ldc-native" "$CHECK" --alert
    [ "$status" -eq 1 ]
    # the fix offered is the drop-in + ldconfig
    [[ "$output" == *"Fix (in-VM"* ]]
    [[ "$output" == *"00-wsl-libcuda.conf"* ]]
    # and the host reboot appears ONLY as an explicit do-not
    [[ "$output" == *"Do NOT run 'wsl --shutdown'"* ]]
    [[ "$output" != *"Fix (host-side"* ]]
    # a purge is refused by name, because it takes the toolkit's neighbours with it
    [[ "$output" == *"g++-13"* ]]
    # both arm results are in the prose, not only in the JSON
    [[ "$output" == *"Both arms: default=fail; LD_LIBRARY_PATH="* ]]
}

@test "SHADOW: the WSL arm succeeding is decisive — library-shadowed, never wedge" {
    # THIS IS THE REGRESSION THE CARD ASKS FOR. The cache says the native libcuda wins
    # (ldc-native), which is the 2026-11-02 shape. The default arm fails; the WSL arm
    # succeeds. The verdict must be library shadowing and the remedy in-VM.
    run env GPU_CONTEXT_PROBE="$STUB/ctx-shadow" GPU_LDCONFIG="$STUB/ldc-native" "$CHECK" --json
    [ "$status" -eq 1 ]
    [ "$(field "$output" state)" = unavailable ]       # the lane must still not start
    [ "$(field "$output" diagnosis)" = libshadow ]
    [ "$(field "$output" verdict)" = library-shadowed ]
    [ "$(field "$output" arm_default)" = fail ]
    [ "$(field "$output" arm_wsl)" = ok ]
    [ "$(nfield "$output" devices)" = 1 ]              # a device exists; the loader lost it
    [[ "$(field "$output" reason)" == *"LIBRARY SHADOWING"* ]]

    run env GPU_CONTEXT_PROBE="$STUB/ctx-shadow" GPU_LDCONFIG="$STUB/ldc-native" "$CHECK" --alert
    [ "$status" -eq 1 ]
    [[ "$output" == *"LIBRARY SHADOWING"* ]]
    [[ "$output" == *"default=fail; LD_LIBRARY_PATH="*"=ok"* ]]
    [[ "$output" == *"Fix (in-VM"* ]]
    [[ "$output" != *"Fix (host-side"* ]]
    [[ "$output" != *"PASSTHROUGH LOST"* ]]
    [[ "$output" == *"Do NOT run 'wsl --shutdown'"* ]]
}

@test "SHADOW: the two-arm test outranks the cache (WSL arm wins even when order looks correct)" {
    # The cache is a metadata file; a real context is evidence. If the WSL arm can mint,
    # the cache saying "order is correct" does not license a hardware verdict.
    run env GPU_CONTEXT_PROBE="$STUB/ctx-shadow" GPU_LDCONFIG="$STUB/ldc-wsl" "$CHECK" --json
    [ "$status" -eq 1 ]
    [ "$(field "$output" diagnosis)" = libshadow ]
    [ "$(field "$output" verdict)" = library-shadowed ]
    [ "$(field "$output" order)" = checked ]
    [ "$(field "$output" arm_wsl)" = ok ]
}

@test "diagnosis: order read and correct with BOTH arms failed leaves hardware (wedge)" {
    run env GPU_CONTEXT_PROBE="$STUB/ctx-fail" GPU_LDCONFIG="$STUB/ldc-wsl" "$CHECK" --json
    [ "$status" -eq 1 ]
    [ "$(field "$output" diagnosis)" = wedge ]
    [ "$(field "$output" verdict)" = wedge ]
    [ "$(field "$output" order)" = checked ]
    [ "$(field "$output" arm_default)" = fail ]
    [ "$(field "$output" arm_wsl)" = fail ]
    # the reason names the evidence it rested on, both arms included
    [[ "$(field "$output" reason)" == *"both context arms failed"* ]]

    run env GPU_CONTEXT_PROBE="$STUB/ctx-fail" GPU_LDCONFIG="$STUB/ldc-wsl" "$CHECK" --alert
    # the host-side remedy belongs here, and only here
    [[ "$output" == *"Fix (host-side"* ]]
    [[ "$output" == *"PASSTHROUGH LOST"* ]]
    [[ "$output" == *"Both arms failed"* ]]
}

@test "diagnosis: an unreadable order is 'unclassified' and prescribes NEITHER remedy" {
    for ldc in ldc-empty ldc-only-dotdot nonexistent; do
        run env GPU_CONTEXT_PROBE="$STUB/ctx-fail" GPU_LDCONFIG="$STUB/$ldc" "$CHECK" --json
        [ "$status" -eq 1 ]
        [ "$(field "$output" diagnosis)" = unclassified ] || { echo "ldc=$ldc"; false; }
        run env GPU_CONTEXT_PROBE="$STUB/ctx-fail" GPU_LDCONFIG="$STUB/$ldc" "$CHECK" --alert
        [[ "$output" == *"UNATTRIBUTED"* ]]
        [[ "$output" != *"Fix (host-side"* ]]
        [[ "$output" != *"Fix (in-VM"* ]]
    done
}

@test "diagnosis: a MISSING instrument is not a hardware verdict (never wedge)" {
    # If the context probe cannot load libcuda at all, the honest answer is that this
    # check cannot decide. It may not inherit the old nvidia-smi verdict by default.
    run env GPU_CONTEXT_PROBE="$STUB/ctx-unavailable" GPU_LDCONFIG="$STUB/ldc-wsl" "$CHECK" --json
    [ "$status" -eq 1 ]
    [ "$(field "$output" state)" = unavailable ]
    [ "$(field "$output" diagnosis)" = unclassified ]
    [ "$(field "$output" arm_default)" = unavailable ]
    [ "$(field "$output" arm_wsl)" = unavailable ]
    run env GPU_CONTEXT_PROBE="$STUB/ctx-unavailable" GPU_LDCONFIG="$STUB/ldc-wsl" "$CHECK" --alert
    [[ "$output" == *"UNATTRIBUTED"* ]]
    [[ "$output" != *"Fix (host-side"* ]]
}

@test "diagnosis: a wedged driver is bounded by the timeout, and a timeout is an arm result" {
    # A D-state driver does not answer; the check must return rather than hang, and the
    # timeout must be recorded as both arms failing before any wedge verdict.
    run env GPU_CONTEXT_PROBE="$STUB/ctx-hang" GPU_CONTEXT_TIMEOUT=1 \
        GPU_LDCONFIG="$STUB/ldc-wsl" "$CHECK" --json
    [ "$status" -eq 1 ]
    [ "$(field "$output" arm_default)" = timeout ]
    [ "$(field "$output" arm_wsl)" = timeout ]
    [ "$(field "$output" diagnosis)" = wedge ]
}

@test "contract: state and exit codes do not move (consumers gate on them)" {
    run env GPU_CONTEXT_PROBE="$STUB/ctx-ok" "$CHECK" --json
    [ "$status" -eq 0 ]; [ "$(field "$output" state)" = ok ]
    run env GPU_CONTEXT_PROBE="$STUB/ctx-fail" GPU_LDCONFIG="$STUB/ldc-native" "$CHECK" --json
    [ "$status" -eq 1 ]; [ "$(field "$output" state)" = unavailable ]
    # a check whose own instrument is missing is a BROKEN CHECK, not evidence
    run env GPU_CONTEXT_PROBE="$STUB/absent-binary" "$CHECK" --json
    [ "$status" -eq 2 ]; [ "$(field "$output" state)" = error ]
}

@test "contract: a working probe is never gated on the cache" {
    # the card answers, so the order is irrelevant — a healthy lane must not be parked
    # by a classification that only exists to explain a FAILURE
    run env GPU_CONTEXT_PROBE="$STUB/ctx-ok" GPU_LDCONFIG="$STUB/ldc-native" "$CHECK" --json
    [ "$status" -eq 0 ]
    [ "$(field "$output" state)" = ok ]
    [ "$(field "$output" diagnosis)" = ok ]
    [ "$(field "$output" order)" = not-checked ]
    [ "$(field "$output" arm_wsl)" = not-run ]
}

@test "contract: the --json document PARSES, so a consumer can read it as JSON" {
    # Added after the first version of this file passed against a malformed document: field()
    # reads with sed, which finds "state" in broken JSON as happily as in valid JSON. A
    # backslash-newline inside a single-quoted printf format emitted a literal \\ and a real
    # newline, and all the tests above stayed green. Parse the document, do not pattern it.
    run env GPU_CONTEXT_PROBE="$STUB/ctx-shadow" GPU_LDCONFIG="$STUB/ldc-native" "$CHECK" --json
    [ "$status" -eq 1 ]
    # Resolve a WORKING interpreter rather than naming one.  The CI runner's bare
    # `python3` exists but cannot load libpython3.14.so (exit 127), and a hardcoded
    # .venv path does not exist in a runner checkout — so each candidate is asked to
    # run before it is trusted (measured 2026-11-11, this case red both ways).
    PY=""
    for _cand in python3 python; do
        _path=$(command -v "$_cand" 2>/dev/null) || continue
        if "$_path" -c 'pass' >/dev/null 2>&1; then PY="$_path"; break; fi
    done
    if [ -n "$PY" ]; then
        "$PY" - "$output" <<'PY'
import json, sys
obj = json.loads(sys.argv[1])
for key in ("state", "diagnosis", "verdict", "order", "reason", "libcuda_first",
            "probe", "arm_default", "arm_wsl", "probe_rc", "arm_default_rc",
            "arm_wsl_rc", "smi_rc", "devices", "window_min", "dxg_failures",
            "wsl_crashes"):
    assert key in obj, f"missing key {key}"
assert obj["diagnosis"] == "libshadow"
assert obj["verdict"] == "library-shadowed"
assert obj["arm_wsl"] == "ok"
assert "\n" not in obj["reason"], "reason carries an embedded newline"
print("parsed")
PY
    else
        # No usable python on this runner (measured 2026-11-11: its tool python3 cannot
        # load libpython3.14.so).  jq parses the same document and checks the same keys,
        # so the contract is still tested rather than skipped.
        command -v jq >/dev/null 2>&1 || { echo "no python or jq to parse the document"; false; }
        printf '%s' "$output" | jq -e '
            (type == "object")
            and (has("state") and has("diagnosis") and has("verdict") and has("order")
                 and has("reason") and has("libcuda_first") and has("probe")
                 and has("arm_default") and has("arm_wsl") and has("probe_rc")
                 and has("arm_default_rc") and has("arm_wsl_rc") and has("smi_rc")
                 and has("devices") and has("window_min") and has("dxg_failures")
                 and has("wsl_crashes"))
            and (.diagnosis == "libshadow") and (.verdict == "library-shadowed")
            and (.arm_wsl == "ok") and (.reason | contains("\n") | not)
        ' >/dev/null
    fi
}

@test "contract: prose joins keep their separators (a reflow must not run words together)" {
    # The prose is written as bash line continuations to stay under 120 columns. A backslash
    # that swallows the following space joins two words silently: the first version shipped
    # `'/usr/lib/wsl/lib\\n'| sudo tee` and `—then re-run`, readable-but-wrong, with every
    # test above green because they assert on other substrings.
    run env GPU_CONTEXT_PROBE="$STUB/ctx-fail" GPU_LDCONFIG="$STUB/ldc-native" "$CHECK" --alert
    [[ "$output" == *"' | sudo tee"* ]]
    [[ "$output" == *"— then re-run"* ]]
    [[ "$output" != *"'| sudo"* ]]
    [[ "$output" != *"—then"* ]]
    run env GPU_CONTEXT_PROBE="$STUB/ctx-fail" GPU_LDCONFIG="$STUB/ldc-none" "$CHECK" --alert
    [[ "$output" == *"with LD_LIBRARY_PATH"* ]]
    [[ "$output" != *"withLD_LIBRARY_PATH"* ]]
}

@test "contract: the default arm is asked once; the WSL arm only after a failure" {
    # A healthy box pays one context mint. A failed one pays exactly two, and no more:
    # each attempt on a wedged driver can leak a process in D state, so the two-arm test
    # must not become a retry loop.
    run env GPU_CONTEXT_PROBE="$STUB/ctx-ok" "$CHECK" --json
    [ "$status" -eq 0 ]
    [ "$(grep -c '^x$' "$STUB/mint-calls")" -eq 1 ]

    : >"$STUB/mint-calls"
    run env GPU_CONTEXT_PROBE="$STUB/ctx-fail" GPU_LDCONFIG="$STUB/ldc-wsl" "$CHECK" --json
    [ "$status" -eq 1 ]
    [ "$(grep -c '^x$' "$STUB/mint-calls")" -eq 2 ]
}
