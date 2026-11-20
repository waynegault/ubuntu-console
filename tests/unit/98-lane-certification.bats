#!/usr/bin/env bats
# ==============================================================================
# Unit — a live lane may deviate from its certified row, but only DECLARED
# ==============================================================================
# Measured 2026-11-19: row 6 (Qwen3-Coder-30B) is certified at ctx 262144,
# batch 512/ubatch 256, threads 6, 1 slot; the live unit served 131072, 2048/512,
# threads 10, 4 slots.  The ctx halving had a written reason — in an INSTALLED
# drop-in with no tracked source, so the repo's unit said 262144 and no reviewer
# could see the difference.  The batch and thread numbers had no reason at all.
#
# The gate is tests/test_lane_certification.py (Python, because the registry is a
# pipe-delimited table and the unit files need a per-field parse).  A suite no
# workflow names never runs, so this file is the registered entry point and the
# cases below prove the gate can go RED — the mutation is the whole point:
#   * an undeclared value change  -> the deviation check fires;
#   * a lane line out of step with its declaration -> the mismatch fires;
#   * the tracked chat lane and the live unit agree on the window.
# ==============================================================================

bats_require_minimum_version 1.5.0

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
PY="$REPO_ROOT/.venv/bin/python3"

setup() {
    [ -x "$PY" ] || skip "the repository venv is required for the Python gate"
    COPIES="$BATS_TEST_TMPDIR/copies"
    mkdir -p "$COPIES"
    cp "$REPO_ROOT"/systemd/llama-cuda-*.service "$COPIES/"
}

@test "lane-certification: the gate passes on the tracked tree" {
    run "$PY" -m pytest "$REPO_ROOT/tests/test_lane_certification.py" -q -p no:cacheprovider
    [ "$status" -eq 0 ] || { printf '%s\n' "$output" | tail -25; return 1; }
}

@test "lane-certification: an undeclared value change turns it RED" {
    # The gate's teeth, driven the way a careless edit would drive it: a COPY of the
    # tracked chat lane with its threads changed and its declaration untouched.  The
    # gate exposes `systemd/` as a module attribute, so the copy is loaded by name and
    # CALLED — no pytest run, so the repo's own units are never mutated.
    local unit="$COPIES/llama-cuda-qwen3coder-30b-chat.service"
    sed -i 's/--threads 10 /--threads 7 /' "$unit"
    run "$PY" - "$REPO_ROOT" "$unit" <<'PY'
import importlib.util
import sys
from pathlib import Path

repo, unit = Path(sys.argv[1]), Path(sys.argv[2])
spec = importlib.util.spec_from_file_location("tlc", repo / "tests" / "test_lane_certification.py")
gate = importlib.util.module_from_spec(spec)
sys.modules["tlc"] = gate
spec.loader.exec_module(gate)
try:
    gate.test_declarations_match_what_is_served(unit)
except AssertionError as exc:
    print(exc)
    raise SystemExit(0)
raise SystemExit("the gate accepted an undeclared change")
PY
    [ "$status" -eq 0 ]
    [[ "$output" == *"declares threads=10 but serves 7"* ]]
}

@test "lane-certification: every declaration names a field the lane SERVES" {
    # A declaration for a flag the ExecStart does not carry is a note about a different
    # server.  Catches a copy-paste between the chat lane and the measurement lane.
    local unit field missing=0
    for unit in "$COPIES"/llama-cuda-*.service
    do
        for field in $(sed -n 's/^# lane-deviation: \([a-z_]*\) .*/\1/p' "$unit")
        do
            case "$field" in
                ctx)        flag='--ctx-size' ;;
                batch)      flag='--batch-size' ;;
                ubatch)     flag='--ubatch-size' ;;
                threads)    flag='--threads' ;;
                parallel)   flag='--parallel' ;;
                gpu_layers) flag='-ngl\|--n-gpu-layers' ;;
                *)          flag="$field" ;;
            esac
            if ! grep -q -- "$flag" "$unit"
            then
                echo "${unit##*/} declares '$field' but never passes $flag"
                missing=$((missing + 1))
            fi
        done
    done
    (( missing == 0 ))
}

@test "lane-certification: the tracked chat lane and the live unit agree on the window" {
    # The 2026-11-19 defect in one line: tracked 262144, running 131072.  The live unit
    # may be absent (another box, CI), in which case only the tracked value is checked.
    # `grep -o` exits 1 when it matches nothing, and this suite runs with `set -e`-like
    # semantics through bats: pipefail is off but the command substitution would read
    # empty.  A lane with no --ctx-size is its own failure, named.
    # The EFFECTIVE value is on the ExecStart line; the file's prose quotes 262144 three
    # times above it (the history and the declaration both name the certified value), so
    # scanning the whole file reads the old number.
    local tracked live unit_line
    unit_line=$(grep '^ExecStart=' "$REPO_ROOT/systemd/llama-cuda-qwen3coder-30b-chat.service" | tail -1)
    tracked=$(printf '%s\n' "$unit_line" | grep -o -- '--ctx-size [0-9]*' | awk '{print $2}')
    [ -n "$tracked" ] || { echo "the tracked chat lane passes no --ctx-size"; return 1; }
    [ "$tracked" = "131072" ]
    if command -v systemctl >/dev/null 2>&1
    then
        live=$(systemctl --user cat llama-cuda-qwen3coder-30b-chat.service 2>/dev/null \
            | grep '^ExecStart=' | tail -1 | grep -o -- '--ctx-size [0-9]*' | awk '{print $2}')
        if [ -n "$live" ]
        then
            [ "$live" = "$tracked" ] || { echo "tracked $tracked, live $live"; return 1; }
        fi
    fi
}

# end of file
