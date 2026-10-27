#!/usr/bin/env bats
# ==============================================================================
# Unit — bin/tac_hostmetrics.sh: the engine summary names the loaded class
# ==============================================================================
# THE DEFECT (measured 2026-10-27 12:10:29 BST):
#
#   nvidia-smi:   RTX 3050 Ti | 81% util | 76°C | 3062 / 4096 Mb
#   typeperf:     dGPU LUID total 93.07 — Cuda#1 91.24, Copy#1 1.82
#   dashboard:    GPU ENGINES :: Idle
#
# Windows emits ONE counter per engine INSTANCE, so the class under load is
# named "Cuda#1" — and the shipped whitelist
# (VDec VEnc VProc 3D Comp Copy Overlay Other) matched neither the "#N" suffix
# nor CUDA at all.  Every busy counter was dropped, `printed == 0`, and the row
# printed "Idle" beside a loaded card.
#
# These cases drive the SHIPPED script with TAC_TYPERF_EXE pointed at a fixture,
# so no Windows host and no real card are involved.  Each fixture carries a CPU
# column at index 2, because the production query asks for one and the parser
# starts its engine scan at column 3.
# ==============================================================================

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"

setup() {
    SCRIPT="$REPO_ROOT/bin/tac_hostmetrics.sh"
    FIXTURES="$BATS_TEST_TMPDIR/fixtures"
    mkdir -p "$FIXTURES"
}

# write_fixture NAME LUID|ENGTYPE|VALUE... — emits typeperf's three-line shape
# (blank, header, data) with one GPU Engine counter column per triple.
# Windows writes the LUID as two 32-bit halves, high first
# (luid_0x00000000_0x00017957_...); the parser captures the LOW half, which is
# what distinguishes the adapters — reversing them collapses every adapter into
# one LUID and silently merges the engine classes.
write_fixture() {
    local name="$1"; shift
    local header='"(PDH-CSV 4.0)","\\BOX\Processor(_Total)\% Processor Time"'
    local body='"27/10/2026 12:10:29.000","26.0"'
    local i=0 triple luid eng val
    for triple in "$@"; do
        IFS='|' read -r luid eng val <<< "$triple"
        i=$((i + 1))
        header+=",\"\\\\BOX\\GPU Engine(pid_100${i}_luid_0x00000000_0x${luid#0x}_phys_0_eng_${i}_engtype_${eng})\\Utilization Percentage\""
        body+=",\"${val}\""
    done
    printf '\n%s\n%s\n' "$header" "$body" > "$FIXTURES/$name.csv"
}

# probe NAME — run the script against fixture NAME; sets ENGINES and GPU1.
probe() {
    local fixture="$FIXTURES/$1.csv" rc=0
    printf '#!/usr/bin/env bash\ncat %q\n' "$fixture" > "$BATS_TEST_TMPDIR/typeperf.exe"
    chmod +x "$BATS_TEST_TMPDIR/typeperf.exe"
    TAC_TYPERF_EXE="$BATS_TEST_TMPDIR/typeperf.exe" \
    TAC_GPU_ENGINES_OUT="$BATS_TEST_TMPDIR/engines.txt" \
        bash "$SCRIPT" > "$BATS_TEST_TMPDIR/contract.txt" 2> "$BATS_TEST_TMPDIR/stderr.txt" || rc=$?
    if (( rc != 0 )); then
        echo "tac_hostmetrics exited $rc:"
        cat "$BATS_TEST_TMPDIR/stderr.txt"
        return 1
    fi
    ENGINES="$(cat "$BATS_TEST_TMPDIR/engines.txt")"
    GPU1="$(cut -d'|' -f3 "$BATS_TEST_TMPDIR/contract.txt")"
}

@test "engines: a CUDA-only dGPU sample renders Comp, not Idle" {
    # 82% of the interval is CUDA (two instances of the same class), 4% copy,
    # and the iGPU's 3D counter is present so the LUID split is exercised.
    write_fixture cuda-heavy \
        "0x000162F8|3D|1.2" \
        "0x00017957|Cuda#1|50.0" \
        "0x00017957|Cuda#2|20.0" \
        "0x00017957|Copy#2|4.0" \
        "0x00017957|Compute_0#1|12.0"

    probe cuda-heavy

    # Cuda + Compute_0 are two names for the compute class; both instances of
    # Cuda count.  Idle here was the reported bug.
    [[ "$ENGINES" == "Comp 82% | Copy 4%" ]]
    [[ "$ENGINES" != "Idle" ]]
    # The same sample's dGPU total (86) must survive the smi max, so the row
    # above cannot read 0% while this row names 82%.
    [[ "$GPU1" -ge 86 ]]
}

@test "engines: an idle dGPU sample still renders Idle" {
    write_fixture idle \
        "0x000162F8|3D|0.0" \
        "0x00017957|Cuda#1|0.0" \
        "0x00017957|Copy#1|0.0"

    probe idle
    [[ "$ENGINES" == "Idle" ]]
}

@test "engines: instance suffixes fold for the video and 3D classes too" {
    write_fixture video \
        "0x00017957|VideoDecode#1|12.0" \
        "0x00017957|3D#2|4.0" \
        "0x00017957|Graphics_1|2.0"

    probe video
    # VideoDecode#1 -> VDec; 3D#2 + Graphics_1 -> one 3D at 6%.
    [[ "$ENGINES" == "VDec 12% | 3D 6%" ]]
}
