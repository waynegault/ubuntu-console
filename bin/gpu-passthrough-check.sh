#!/usr/bin/env bash
# AI INSTRUCTION: On ANY change to this file, increment the Module Version below.
# Module Version: 2
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
# WHY A FAILED nvidia-smi IS NOT A HARDWARE VERDICT (added 2026-11-02, Module Version 2)
#   nvidia-smi is a dlopen client of libcuda.so.1. It therefore cannot distinguish "the
#   passthrough is gone" from "the loader resolved a DIFFERENT libcuda", and it reports
#   both as the same rc=9 "couldn't communicate with the NVIDIA driver". On 2026-11-02
#   `apt install nvidia-cuda-toolkit` filled an empty multiarch slot: every new process
#   then resolved libcuda.so.1 to /usr/lib/aarch64-linux-gnu (native 595) ahead of
#   /usr/lib/wsl/lib, and this check reported state=unavailable — while the card was
#   healthy and serving :18087 with LD_LIBRARY_PATH set. The remedy it prescribed,
#   `wsl --shutdown`, stops the gateway and all fourteen lanes and reorders nothing.
#   So the verdict is now CLASSIFIED before it is reported: reading the ldconfig CACHE
#   costs no driver call, and when the cache names a non-WSL libcuda first the fault is
#   loader ORDER. Exit status and `state` are unchanged (a lane must still not start)
#   but `diagnosis` — ok | liborder | wedge | unclassified — and the remedy text follow the
#   evidence. `wedge` means the order was read and is correct, so hardware is the remaining
#   explanation; `unclassified` means the order could not be read at all, and then NEITHER
#   remedy is prescribed, because the honest report is that the instrument cannot decide.
#   `order` (checked | not-checked) and `libcuda_first` say what the classification rested on.
#
# USAGE
#   gpu-passthrough-check.sh           human one-liner; exit code carries the verdict
#   gpu-passthrough-check.sh --json    one JSON object (machine consumers)
#   gpu-passthrough-check.sh --alert   alert body for delivery
# EXIT  0 = OK   1 = UNAVAILABLE   2 = CHECK ERROR
#
# ENV  GPU_CHECK_WINDOW_MIN (default 30) minutes of kernel log to summarise
#      NVIDIA_SMI            override the nvidia-smi binary (used by tests)
#      GPU_LDCONFIG          override ldconfig, the cache reader (used by tests)
#      GPU_WSL_LIBCUDA       override the expected passthrough libcuda path
set -uo pipefail

WINDOW_MIN="${GPU_CHECK_WINDOW_MIN:-30}"
SMI="${NVIDIA_SMI:-nvidia-smi}"
LDCONFIG="${GPU_LDCONFIG:-ldconfig}"
WSL_LIBCUDA="${GPU_WSL_LIBCUDA:-/usr/lib/wsl/lib/libcuda.so.1}"
MODE="${1:-}"

STATE=ok
REASON="nvidia-smi enumerated a device"
RC=0
DEVCOUNT=0
FIRST_CUDA=""
ldc_out=""
DIAGNOSIS=""
ORDER="not-checked"

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

# --- classification: loader order BEFORE hardware -------------------------
# Only reached when the probe failed, so the ok path pays nothing. A metadata read of
# the cache is free and cannot crash, unlike a second nvidia-smi (each invocation on a
# genuinely broken GPU is a crash plus a WSL core dump — never probe twice).
# The first libcuda.so.1 line in `ldconfig -p` IS the winner: the listing follows cache
# order, which follows ld.so.conf.d order. Deliberately exact-name matched with a
# trailing space so libcuda.so.1.1 cannot satisfy it.
DIAGNOSIS=$STATE
if [[ "$STATE" = unavailable ]]; then
    # Default for an unavailable probe whose cause we have NOT attributed. "wedge" is only
    # claimable after the order was read and found correct — otherwise the honest answer is
    # that the instrument cannot say which fault it is, and "unclassified" says exactly that.
    DIAGNOSIS=unclassified
    if [[ -e "$WSL_LIBCUDA" ]]; then
        # swallow-ok: absent ldconfig drops to stderr and leaves ldc_out empty, which is REPORTED as order=not-checked, never a silent pass
        ldc_out=$("$LDCONFIG" -p 2>/dev/null)
        # swallow-ok: a cache with no libcuda.so.1 line cannot name a winner, and the empty FIRST_CUDA is what keeps order=not-checked
        FIRST_CUDA=$(printf '%s\n' "$ldc_out" | grep -F 'libcuda.so.1 ' | head -1 | sed -n 's/.*=> //p' || true)
        if [[ -n "$FIRST_CUDA" ]]; then
            ORDER=checked
            if [[ "$FIRST_CUDA" != "$WSL_LIBCUDA" ]]; then
                DIAGNOSIS=liborder
                REASON="libcuda.so.1 resolves to ${FIRST_CUDA}, not ${WSL_LIBCUDA} — a LOADER-ORDER \
fault, not lost passthrough (nvidia-smi is a dlopen client of libcuda and \
reports an unreachable driver; the card may be healthy)"
            else
                DIAGNOSIS=wedge
            fi
        fi
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
            if [[ "$DIAGNOSIS" = liborder ]]; then
                printf '%s\n' "🔴 GPU CHECK FAILING on LOADER ORDER — not a lost passthrough, and no reboot will fix it."
                printf '%s\n' "Reason: ${REASON}"
                printf '%s\n' "Evidence: ${DXG} dxg create_process failure(s) + ${CRASH} WSL crash \
capture(s) in the last ${WINDOW_MIN} min. A lost passthrough leaves dxg/crash \
traces; a loader fault leaves the card answering under the right library, \
which is what separates them."
                printf '%s\n' "Impact: the CUDA lane cannot trust nvidia-smi, so it must not start yet. \
Processes that set LD_LIBRARY_PATH=/usr/lib/wsl/lib are unaffected and are \
serving."
                printf '%s\n' "Fix (in-VM, one file, no reboot, no packages): printf '/usr/lib/wsl/lib\n'\
 | sudo tee /etc/ld.so.conf.d/00-wsl-libcuda.conf >/dev/null && sudo ldconfig —\
 then re-run this check."
                printf '%s\n' "Do NOT run 'wsl --shutdown': it stops the gateway and every lane and reorders \
nothing. Do NOT remove packages: the toolkit purge also takes g++-13, \
libthrust-dev and nvidia-cuda-dev."
            elif [[ "$DIAGNOSIS" = wedge ]]; then
                printf '%s\n' "🔴 GPU PASSTHROUGH LOST — CUDA lane (cuda-llama32-3b/llama32, :18083) cannot start."
                printf '%s\n' "Reason: ${REASON}"
                printf '%s\n' "Evidence: ${DXG} dxg create_process failure(s) + ${CRASH} WSL crash capture(s) \
in the last ${WINDOW_MIN} min; loader order ${ORDER} and names the passthrough \
library first, so library resolution is not the explanation."
                printf '%s\n' "Impact: any run falling back to the CUDA lane returns ZERO tokens (shows up as \
'heartbeat failed: agent-runner-failure'). The Xe lane (:18081) is unaffected \
and still serving."
                printf '%s\n' "Fix (host-side, needs a human): run 'wsl --shutdown' then restart WSL, or \
update the Windows GPU driver / run 'wsl --update'. NOTE: 'wsl --shutdown' \
also stops the gateway."
            else
                printf '%s\n' "⚠️ GPU UNUSABLE AND UNATTRIBUTED — the probe failed and the cause was not established."
                printf '%s\n' "Reason: ${REASON}"
                printf '%s\n' "Loader order ${ORDER}${FIRST_CUDA:+ (libcuda.so.1 -> ${FIRST_CUDA})}, so this \
check cannot say whether the passthrough is gone or library resolution is wrong. \
Deliberately prescribing NEITHER remedy: a host reboot on a loader fault fixes \
nothing and costs the gateway."
                printf '%s\n' "Next: confirm the loader order by hand (ldconfig -p | grep 'libcuda\.so\.1 ') and try one run with\
 LD_LIBRARY_PATH=/usr/lib/wsl/lib nvidia-smi -L. If that names the card, it is ORDER, not hardware."
            fi
            ;;
        *)
            printf '%s\n' "⚠️ GPU passthrough CHECK BROKEN — cannot determine GPU health."
            printf '%s\n' "Reason: ${REASON}"
            ;;
    esac
}

case "$MODE" in
    --json)
        # Two printf calls, not one continued format string: inside single quotes a
        # backslash-newline is a LITERAL, so a continued format would emit a stray "\" and a
        # real newline and break every JSON consumer (measured 2026-11-02 — the suite passed
        # because it read fields by sed, which cannot see a malformed document).
        printf '{"state":"%s","diagnosis":"%s","order":"%s","reason":"%s","libcuda_first":"%s",' \
            "$STATE" "$DIAGNOSIS" "$ORDER" "$REASON" "$FIRST_CUDA"
        printf '"smi_rc":%d,"devices":%d,"window_min":%d,"dxg_failures":%d,"wsl_crashes":%d}\n' \
            "$RC" "$DEVCOUNT" "$WINDOW_MIN" "$DXG" "$CRASH"
        ;;
    --alert)
        alert_text
        ;;
    *)
        printf '%s: %s (%s; diagnosis=%s; %s dxg failures, %s crashes / %s min)\n' \
            "$STATE" "$REASON" "rc=$RC" "$DIAGNOSIS" "$DXG" "$CRASH" "$WINDOW_MIN"
        ;;
esac

case "$STATE" in
    ok)          exit 0 ;;
    unavailable) exit 1 ;;
    *)           exit 2 ;;
esac

# end of file
