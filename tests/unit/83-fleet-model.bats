#!/usr/bin/env bats
# ==============================================================================
# Unit Tests — the fleet is moved off a lane a sweep denies, and moved back
# ==============================================================================
# WHAT THESE PIN (card c74ff012's sibling ruling, Wayne 2026-11-07):
#
# A clean-room sweep stops llama-cuda-qwen3coder-30b-chat.service to free ~20 GB, and
# that service is agents.defaults.model.primary. Measured 2026-11-06 23:41-23:42: the
# gateway logged ECONNREFUSED for cuda-qwen3coder-30b on every subagent run and only then
# failed over — every agent paid a denied attempt before it could work. The ruling is
# that during a sweep the fleet USES a hosted deepseek lane.  WHICH lane is Wayne's
# 2026-11-08 refinement (bin/fleet-model.sh v5, commit 0181b4f8): the sweep lane is
# cheaper-inference's deepseek-v4.1-flash-1017, not the direct deepseek/deepseek-flash.
# The expected value below is pinned from that ruling, not read off the implementation.
#
# The interesting half is not the switch, it is the RETURN:
#   * a sweep that dies must not leave the fleet on the hosted model silently;
#   * a restore that runs twice must not restore a stale primary, and must not set an
#     empty one;
#   * a switch that fails must not leave a saved value behind, because that saved value
#     would be "restored" later over a primary that was never changed.
#
# AND THE RETURN DEPENDS ENTIRELY ON THE SLOT (card FLEET-MODEL-SAVED-SLOT-EMPTY-001,
# bin/fleet-model.sh v7).  2026-11-10T00:53Z: a sweep wrote a 0-byte slot, `restore`
# correctly refused, and the fleet stayed on the paid lane for hours while the local CUDA
# lane sat up and serving.  So the slot's own write is pinned here: it is atomic (a
# symlinked slot is REPLACED, never written through), it is verified before the switch,
# and a save that cannot be verified must refuse the switch rather than strand the fleet.
# A broken slot must also be LOUD: `restore` names the ruled baseline and exits 2, and
# `status` reports the unrecoverable state as RED with exit 1.
#
# No real config is written and no real lane is touched: OPENCLAW_CONFIG points at a
# temp JSON and a stub `openclaw` on PATH performs the models-set write.
# ==============================================================================

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
SRC="$REPO_ROOT/bin/fleet-model.sh"
# The sweep lane, from Wayne's 2026-11-08 ruling (bin/fleet-model.sh v5).  One place, so
# the next refinement is one edit rather than four assertions drifting apart.
SWEEP_MODEL="cheaper-inference/deepseek-v4.1-flash-1017"
# The ruled baseline (workspace/policies/heartbeat-policy.md:32, Wayne 2026-11-07): the
# model a human is told to set when the slot cannot answer.  Pinned from that ruling.
BASELINE_MODEL="cuda-qwen3coder-30b/qwen3-coder-30b-gpu"

setup() {
    TMP="$(mktemp -d)"
    export TAC_STATE_DIR="$TMP/state"
    export OPENCLAW_CONFIG="$TMP/openclaw.json"
    mkdir -p "$TMP/bin"
    cat > "$OPENCLAW_CONFIG" <<'JSON'
{"agents":{"defaults":{"model":{"primary":"cuda-qwen3coder-30b/qwen3-coder-30b-gpu","fallbacks":["cheaper-inference/deepseek-v4.1-flash-1017"]}}}}
JSON
    # The stub performs the same write the real CLI performs, and records the call.
    cat > "$TMP/bin/openclaw" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_LOG"
if [[ "${STUB_SET_FAILS:-0}" == "1" ]]; then
    echo "stub: refusing to write config" >&2
    exit 1
fi
if [[ "$1" == "models" && "$2" == "set" ]]; then
    python3 - "$OPENCLAW_CONFIG" "$3" <<'PY'
import json, sys
path, model = sys.argv[1], sys.argv[2]
with open(path, encoding="utf-8") as fh:
    doc = json.load(fh)
doc["agents"]["defaults"]["model"]["primary"] = model
with open(path, "w", encoding="utf-8") as fh:
    json.dump(doc, fh)
PY
    exit 0
fi
exit 0
STUB
    chmod +x "$TMP/bin/openclaw"
    export STUB_LOG="$TMP/openclaw.calls"
    # PATH is narrowed deliberately: the system `openclaw` must never be reachable here,
    # or a broken seam would silently edit the real fleet default.
    export PATH="$TMP/bin:/usr/bin:/bin"
    REAL_OPENCLAW="$(command -v -- openclaw 2>/dev/null || true)"
    [[ "$REAL_OPENCLAW" == "$TMP/bin/openclaw" ]]
}

teardown() {
    rm -rf "$TMP"
}

primary() {
    python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["agents"]["defaults"]["model"]["primary"])' "$OPENCLAW_CONFIG"
}

@test "sweep moves the primary to the sweep model and saves what was there" {
    run bash "$SRC" sweep
    [ "$status" -eq 0 ]
    [ "$(primary)" = "$SWEEP_MODEL" ]
    [ "$(cat "$TAC_STATE_DIR/fleet-model.saved")" = "cuda-qwen3coder-30b/qwen3-coder-30b-gpu" ]
    grep -qF "models set $SWEEP_MODEL" "$STUB_LOG"
}

@test "sweep goes through the documented writer, not a hand edit" {
    run bash "$SRC" sweep
    [ "$status" -eq 0 ]
    [ "$(wc -l < "$STUB_LOG")" -eq 1 ]
}

@test "sweep twice saves nothing the second time" {
    bash "$SRC" sweep
    run bash "$SRC" sweep
    [ "$status" -eq 0 ]
    [[ "$output" == *"nothing to save"* ]]
    [ "$(cat "$TAC_STATE_DIR/fleet-model.saved")" = "cuda-qwen3coder-30b/qwen3-coder-30b-gpu" ]
    [ "$(wc -l < "$STUB_LOG")" -eq 1 ]
}

@test "restore puts back the saved primary and consumes the state file" {
    bash "$SRC" sweep
    run bash "$SRC" restore
    [ "$status" -eq 0 ]
    [ "$(primary)" = "cuda-qwen3coder-30b/qwen3-coder-30b-gpu" ]
    [ ! -f "$TAC_STATE_DIR/fleet-model.saved" ]
}

@test "a second restore is a no-op and does not write the config again" {
    bash "$SRC" sweep
    bash "$SRC" restore
    after_first="$(primary)"
    run bash "$SRC" restore
    [ "$status" -eq 0 ]
    [[ "$output" == *"nothing to restore"* ]]
    [ "$(primary)" = "$after_first" ]
    [ "$(wc -l < "$STUB_LOG")" -eq 2 ]
}

@test "restore refuses an empty saved value instead of clearing the primary" {
    mkdir -p "$TAC_STATE_DIR"
    : > "$TAC_STATE_DIR/fleet-model.saved"
    run bash "$SRC" restore
    [ "$status" -eq 2 ]
    [[ "$output" == *"leaving the fleet on the sweep model"* ]]
    [ "$(primary)" = "cuda-qwen3coder-30b/qwen3-coder-30b-gpu" ]
    [ ! -s "$STUB_LOG" ] || [ ! -f "$STUB_LOG" ]
}

@test "a failed switch leaves NO saved value to restore later" {
    STUB_SET_FAILS=1 run bash "$SRC" sweep
    [ "$status" -eq 2 ]
    [[ "$output" == *"FAILED to set"* ]]
    [ ! -f "$TAC_STATE_DIR/fleet-model.saved" ]
    [ "$(primary)" = "cuda-qwen3coder-30b/qwen3-coder-30b-gpu" ]
}

@test "sweep refuses to switch blind when the current primary is unreadable" {
    rm -f "$OPENCLAW_CONFIG"
    run bash "$SRC" sweep
    [ "$status" -eq 2 ]
    [[ "$output" == *"refusing to switch blind"* ]]
    [ ! -f "$TAC_STATE_DIR/fleet-model.saved" ]
    [ ! -f "$STUB_LOG" ] || [ ! -s "$STUB_LOG" ]
}

@test "status reports both sides, and 'none' when no switch is pending" {
    run bash "$SRC" status
    [ "$status" -eq 0 ]
    [[ "$output" == *"primary=cuda-qwen3coder-30b/qwen3-coder-30b-gpu"* ]]
    [[ "$output" == *"saved=none"* ]]
    bash "$SRC" sweep
    run bash "$SRC" status
    [[ "$output" == *"primary=$SWEEP_MODEL"* ]]
    [[ "$output" == *"saved=cuda-qwen3coder-30b/qwen3-coder-30b-gpu"* ]]
}

# ── the slot itself: durable, atomic, verified (card FLEET-MODEL-SAVED-SLOT-EMPTY-001) ──

@test "the saved slot holds exactly the previous primary and leaves no temp file behind" {
    run bash "$SRC" sweep
    [ "$status" -eq 0 ]
    [ "$(cat "$TAC_STATE_DIR/fleet-model.saved")" = "$BASELINE_MODEL" ]
    # One line: the model id and its terminator, nothing else.
    [ "$(wc -l < "$TAC_STATE_DIR/fleet-model.saved")" -eq 1 ]
    # The atomic writer's temp file is renamed away, never left beside the slot.
    run find "$TAC_STATE_DIR" -name '*.tmp' -print
    [ -z "$output" ]
}

@test "the saved slot is replaced, not written through — a symlinked slot leaves its target untouched" {
    # The repo rule (AGENTS.md §3) is atomic_write_text: fsync, then os.replace.  An
    # in-place `printf > "$STATE"` would follow this symlink and write into the target,
    # which is the truncating write the incident's 0-byte slot is consistent with.
    mkdir -p "$TAC_STATE_DIR"
    : > "$TMP/symlink-target"
    ln -s "$TMP/symlink-target" "$TAC_STATE_DIR/fleet-model.saved"
    run bash "$SRC" sweep
    [ "$status" -eq 0 ]
    [ ! -s "$TMP/symlink-target" ]
    [ ! -L "$TAC_STATE_DIR/fleet-model.saved" ]
    [ "$(cat "$TAC_STATE_DIR/fleet-model.saved")" = "$BASELINE_MODEL" ]
}

@test "a save that cannot be verified refuses the switch and leaves the primary unchanged" {
    # The state dir's parent is a REGULAR FILE, so the slot cannot be created and the
    # write cannot be read back.  A save reported as successful here would switch the
    # fleet to the paid lane with nothing to restore — the 2026-11-10T00:53Z incident.
    : > "$TMP/not-a-directory"
    export TAC_STATE_DIR="$TMP/not-a-directory/state"
    run bash "$SRC" sweep
    [ "$status" -eq 2 ]
    [ "$(primary)" = "$BASELINE_MODEL" ]
    [ ! -f "$STUB_LOG" ] || [ ! -s "$STUB_LOG" ]
    [ ! -e "$TAC_STATE_DIR/fleet-model.saved" ]
}

@test "restore on an empty slot names the ruled baseline and exits 2" {
    mkdir -p "$TAC_STATE_DIR"
    : > "$TAC_STATE_DIR/fleet-model.saved"
    run bash "$SRC" restore
    [ "$status" -eq 2 ]
    [[ "$output" == *"openclaw models set $BASELINE_MODEL"* ]]
    [ "$(primary)" = "$BASELINE_MODEL" ]
}

@test "status is RED with exit 1 on an empty slot over the sweep model, and 0 when idle" {
    run bash "$SRC" status
    [ "$status" -eq 0 ]
    [[ "$output" == *"saved=none"* ]]
    bash "$SRC" sweep
    : > "$TAC_STATE_DIR/fleet-model.saved"     # the incident, reproduced exactly
    run bash "$SRC" status
    [ "$status" -eq 1 ]
    [[ "$output" == *"RED"* ]]
    [[ "$output" == *"openclaw models set $BASELINE_MODEL"* ]]
}

@test "an unknown verb is a usage error, not a silent success" {
    run bash "$SRC" nonsense
    [ "$status" -eq 64 ]
    [[ "$output" == *"usage: fleet-model.sh sweep|restore|status"* ]]
    [ "$(wc -l < "$STUB_LOG" 2>/dev/null || echo 0)" -eq 0 ]
}
