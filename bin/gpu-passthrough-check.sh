#!/usr/bin/env bash
# AI INSTRUCTION: On ANY change to this file, increment the Module Version below.
# Module Version: 1
# TRACKED HERE since 2026-10-01: this script lived only as a loose ~/.local/bin copy, so a
# change to it was unversioned and unreviewable — while bin/llama-watchdog.sh depends on it
# by name.  Code that is exclusively supportive of ubuntu-console belongs in this repo;
# install.sh links every file in bin/ into ~/.local/bin, so the watchdog's stable path keeps
# resolving while the body is reviewable here.
#
# gpu-passthrough-check.sh — classify WSL2 GPU-passthrough health (gates the CUDA lane).
#
# WHY THIS EXISTS
#   WSL2 GPU passthrough can die silently while everything else keeps running: the
#   Intel/Xe lane still serves, so the gateway looks healthy, and any run that falls
#   back to the CUDA lane just returns zero tokens. On 2026-09-12 that surfaced only as
#   an opaque `heartbeat failed: agent-runner-failure` on 8 agents, invisible in the
#   gateway journal. The same failure presented with TWO different signatures within
#   one hour:
#     (a) rc=255, stderr "Failed to initialize NVML: GPU access blocked by the OS"
#     (b) rc=139, SIGSEGV (core dumped), and NO stderr at all
#   So never pattern-match a single error string. The only positive proof the GPU is
#   usable is nvidia-smi exiting 0 *and* enumerating a device line.
#
# USAGE
#   gpu-passthrough-check.sh           human one-liner; exit code carries the verdict
#   gpu-passthrough-check.sh --json    one JSON object (machine consumers)
#   gpu-passthrough-check.sh --alert   alert body for delivery
# EXIT  0 = OK   1 = UNAVAILABLE   2 = CHECK ERROR
#
# ENV  GPU_CHECK_WINDOW_MIN (default 30) minutes of kernel log to summarise
#      NVIDIA_SMI            override the nvidia-smi binary (used by tests)
set -uo pipefail

WINDOW_MIN="${GPU_CHECK_WINDOW_MIN:-30}"
SMI="${NVIDIA_SMI:-nvidia-smi}"
MODE="${1:-}"

STATE=ok
REASON="nvidia-smi enumerated a device"
RC=0
DEVCOUNT=0

# --- primary signal: ONE invocation, stdout+stderr captured together -----------
# One call matters: while the GPU is broken every nvidia-smi invocation is a crash,
# and each crash makes WSL capture a core dump (kernel-log noise). Never probe twice.
ALL=$("$SMI" -L 2>&1); RC=$?
# swallow-ok: an empty match IS the "exited 0 but enumerated no GPU" case this probe exists to distinguish, and DEVCOUNT is defaulted below
DEVS=$(grep -E '^GPU [0-9]+:' <<<"$ALL" || true)
# swallow-ok: counting a list already known non-empty; a zero match is impossible here, and DEVCOUNT is defaulted below
[ -z "$DEVS" ] || DEVCOUNT=$(printf '%s\n' "$DEVS" | grep -cE '^GPU [0-9]+:' || true)
DEVCOUNT=${DEVCOUNT:-0}

sig_name() {
    case "$1" in
        139) echo "SIGSEGV" ;; 134) echo "SIGABRT" ;; 132) echo "SIGILL" ;;
        135) echo "SIGBUS"  ;; 137) echo "SIGKILL" ;; *) echo "signal $(( $1 - 128 ))" ;;
    esac
}

if (( RC == 127 )); then
    STATE=error; REASON="nvidia-smi not found (${SMI})"
elif (( RC == 0 )) && (( DEVCOUNT > 0 )); then
    STATE=ok; REASON="nvidia-smi ok (${DEVCOUNT} device(s))"
else
    STATE=unavailable
    # Order matters: check the error TEXT before the signal range. nvidia-smi uses
    # 255 as an ordinary NVML-init failure code, and blindly reading rc>=128 as a
    # signal reports the nonsense "signal 127"; exact signal deaths are 129..192.
    if (( RC == 0 )); then
        REASON="nvidia-smi exited 0 but enumerated no GPU"
    elif grep -qi 'GPU access blocked' <<<"$ALL"; then
        REASON="NVML: GPU access blocked by the operating system (rc=$RC)"
    elif grep -qi 'Failed to initialize NVML' <<<"$ALL"; then
        REASON="NVML failed to initialize (rc=$RC)"
    elif (( RC > 128 && RC <= 192 )); then
        REASON="nvidia-smi crashed ($(sig_name "$RC"), rc=$RC)"
    elif [[ -n "$ALL" ]]; then
        REASON="nvidia-smi failed (rc=$RC): $(head -1 <<<"$ALL")"
    else
        REASON="nvidia-smi failed unexpectedly (rc=$RC)"
    fi
fi

# --- corroboration: kernel-side dxg + WSL crash captures in the window ---------
# swallow-ok: an unreadable journal yields no matches, which is the same zero this counter reports; the figure is corroboration only, never the verdict
count_kernel() { journalctl -k --since "-${WINDOW_MIN}min" --no-pager 2>/dev/null | grep -c -- "$1" || true; }
DXG=$(count_kernel 'create_process failed'); DXG=${DXG:-0}
CRASH=$(count_kernel 'Capturing crash');     CRASH=${CRASH:-0}

alert_text() {
    case "$STATE" in
        ok)
            printf '%s\n' "✅ GPU passthrough RECOVERED — the CUDA lane (cuda-llama32-3b/llama32, :18083) can start again."
            printf '%s\n' "Evidence: ${REASON}; ${DXG} dxg failure(s) + ${CRASH} crash capture(s) in the last ${WINDOW_MIN} min."
            ;;
        unavailable)
            printf '%s\n' "🔴 GPU PASSTHROUGH LOST — CUDA lane (cuda-llama32-3b/llama32, :18083) cannot start."
            printf '%s\n' "Reason: ${REASON}"
            printf '%s\n' "Evidence: ${DXG} dxg create_process failure(s) + ${CRASH} WSL crash capture(s) in the last ${WINDOW_MIN} min."
            printf '%s\n' "Impact: any run falling back to the CUDA lane returns ZERO tokens (shows up as 'heartbeat failed: agent-runner-failure'). The Xe lane (:18081) is unaffected and still serving."
            printf '%s\n' "Fix (host-side, needs a human): run 'wsl --shutdown' then restart WSL, or update the Windows GPU driver / run 'wsl --update'. NOTE: 'wsl --shutdown' also stops the gateway."
            ;;
        *)
            printf '%s\n' "⚠️ GPU passthrough CHECK BROKEN — cannot determine GPU health."
            printf '%s\n' "Reason: ${REASON}"
            ;;
    esac
}

case "$MODE" in
    --json)
        printf '{"state":"%s","reason":"%s","smi_rc":%d,"devices":%d,"window_min":%d,"dxg_failures":%d,"wsl_crashes":%d}\n' \
            "$STATE" "$REASON" "$RC" "$DEVCOUNT" "$WINDOW_MIN" "$DXG" "$CRASH"
        ;;
    --alert)
        alert_text
        ;;
    *)
        printf '%s: %s (%s; %s dxg failures, %s crashes / %s min)\n' \
            "$STATE" "$REASON" "rc=$RC" "$DXG" "$CRASH" "$WINDOW_MIN"
        ;;
esac

case "$STATE" in
    ok)          exit 0 ;;
    unavailable) exit 1 ;;
    *)           exit 2 ;;
esac

# end of file
