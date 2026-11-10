#!/usr/bin/env bash
# AI INSTRUCTION: On ANY change to this file, increment the Module Version below.
# Module Version: 3
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
#   So never pattern-match a single error string.
#
# WHY nvidia-smi IS NO LONGER THE PREDICATE (Module Version 3, card c7e15c7a, 2026-11-10)
#   nvidia-smi is a dlopen client of libcuda.so.1. A check built on it measures LDCONFIG
#   ORDER, not whether CUDA works: on 2026-11-02 `apt install nvidia-cuda-toolkit` filled
#   the empty multiarch slot /usr/lib/aarch64-linux-gnu/libcuda.so.1 with the native 595
#   build. The cache then resolved the native library ahead of /usr/lib/wsl/lib, nvidia-smi
#   reported rc=9 "couldn't communicate with the NVIDIA driver", and this check escalated
#   "WSL2 driver wedge — needs HOST action (Wayne)" — a reboot that stops the gateway and
#   all fourteen lanes and CANNOT fix a loader fault. The same binary, same second:
#       nvidia-smi -L                                    -> rc=9
#       LD_LIBRARY_PATH=/usr/lib/wsl/lib nvidia-smi -L   -> GPU 0: NVIDIA RTX Spark N1X rc=0
#   and a real context + 256x256 matmul failed by default and succeeded with the WSL lib dir.
#   The predicate is now a CONTEXT MINT (bin/cuda-context-probe: cuInit -> cuDeviceGet ->
#   cuCtxCreate -> cuMemAlloc -> cuMemsetD8 -> destroy). That is the only test here that
#   distinguishes "no usable CUDA" from "no driver". nvidia-smi is not consulted at all.
#
# TWO-ARM RULE (the part that stops the reboot claim)
#   A failed context mint is NOT a hardware verdict. Before any host action can be named,
#   the SAME mint is run a second time with LD_LIBRARY_PATH=/usr/lib/wsl/lib.
#       default fails, WSL arm succeeds -> diagnosis=libshadow, verdict=library-shadowed,
#                                           remedy is the in-VM ldconfig drop-in, never a reboot
#       both arms fail, order correct   -> diagnosis=wedge; only here may a host action appear
#       both arms fail, order wrong     -> diagnosis=liborder; fix order in-VM first
#       order unreadable                -> diagnosis=unclassified; NEITHER remedy prescribed
#   Both arm results are always in the JSON and in the --alert body, so an escalation can
#   quote the evidence it rested on instead of asserting a cause.
#
# USAGE
#   gpu-passthrough-check.sh           human one-liner; exit code carries the verdict
#   gpu-passthrough-check.sh --json    one JSON object (machine consumers)
#   gpu-passthrough-check.sh --alert   alert body for delivery
# EXIT  0 = OK   1 = UNAVAILABLE   2 = CHECK ERROR
#
# ENV  GPU_CHECK_WINDOW_MIN   (default 30) minutes of kernel log to summarise
#      GPU_CONTEXT_PROBE      override the context-mint binary (used by tests)
#      GPU_CONTEXT_TIMEOUT    seconds per arm (default 25; a wedged driver must not hang us)
#      GPU_WSL_LIBDIR         the WSL driver directory (default /usr/lib/wsl/lib)
#      GPU_LDCONFIG           override ldconfig, the cache reader (used by tests)
#      GPU_WSL_LIBCUDA        override the expected passthrough libcuda path
set -uo pipefail

WINDOW_MIN="${GPU_CHECK_WINDOW_MIN:-30}"
LDCONFIG="${GPU_LDCONFIG:-ldconfig}"
WSL_LIBCUDA="${GPU_WSL_LIBCUDA:-/usr/lib/wsl/lib/libcuda.so.1}"
WSL_LIBDIR="${GPU_WSL_LIBDIR:-/usr/lib/wsl/lib}"
CTX_TIMEOUT="${GPU_CONTEXT_TIMEOUT:-25}"
MODE="${1:-}"

STATE=ok
REASON="a CUDA context was created"
DEVCOUNT=0
FIRST_CUDA=""
ldc_out=""
DIAGNOSIS=ok
VERDICT=ok
ORDER="not-checked"
ARM_DEFAULT="not-run"
ARM_WSL="not-run"
ARM_DEFAULT_RC=-1
ARM_WSL_RC=-1
PROBE_KIND="context"

# Locate the mint next to this script first: install.sh links every bin/ file into
# ~/.local/bin, so the sibling path survives the symlink. Fall back to PATH.
PROBE="${GPU_CONTEXT_PROBE:-}"
if [[ -z "$PROBE" ]]; then
    _here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
    if [[ -x "$_here/cuda-context-probe" ]]; then
        PROBE="$_here/cuda-context-probe"
    elif command -v cuda-context-probe >/dev/null 2>&1; then
        PROBE=$(command -v cuda-context-probe)
    fi
fi

TIMEOUT_BIN=""
command -v timeout >/dev/null 2>&1 && TIMEOUT_BIN=$(command -v timeout)

# --- the context mint, one arm at a time -------------------------------------
# ARM_OUT and ARM_RC are globals: bash cannot return both a stream and a status from a
# command substitution without a temp file, and the output is the evidence we keep.
run_mint() {
    local arm="$1"
    local -a env_arm=()
    if [[ "$arm" = wsl ]]; then
        env_arm=(env "LD_LIBRARY_PATH=${WSL_LIBDIR}${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}")
    fi
    if [[ -n "$TIMEOUT_BIN" ]]; then
        # -k: a driver wedged in D state ignores SIGTERM; force the kill so the check
        # itself can still answer. (An unkillable child is the wedge, reported as timeout.)
        ARM_OUT=$("${env_arm[@]}" "$TIMEOUT_BIN" -k 5 "$CTX_TIMEOUT" "$PROBE" 2>&1)
    else
        ARM_OUT=$("${env_arm[@]}" "$PROBE" 2>&1)
    fi
    ARM_RC=$?
}

# Translate a probe exit status into the arm summary label.
arm_label() {
    case "$1" in
        0) echo ok ;;
        3) echo unavailable ;;
        124|137) echo timeout ;;
        *) echo fail ;;
    esac
}

# Read the loader's winner without touching the driver. The first libcuda.so.1 line in
# `ldconfig -p` IS the cache winner (listed order follows ld.so.conf.d order). Exact-name
# matched with a trailing space so libcuda.so.1.1 cannot satisfy it.
read_order() {
    [[ -e "$WSL_LIBCUDA" ]] || return 0
    # swallow-ok: absent ldconfig drops to stderr and leaves ldc_out empty, which is REPORTED as order=not-checked, never a silent pass
    ldc_out=$("$LDCONFIG" -p 2>/dev/null)
    # swallow-ok: a cache with no libcuda.so.1 line cannot name a winner, and the empty FIRST_CUDA keeps order=not-checked
    FIRST_CUDA=$(printf '%s\n' "$ldc_out" | grep -F 'libcuda.so.1 ' | head -1 | sed -n 's/.*=> //p' || true)
    [[ -n "$FIRST_CUDA" ]] && ORDER=checked
}

if [[ -z "$PROBE" || ! -x "$PROBE" ]]; then
    # A check that cannot run its own instrument is BROKEN, not evidence about the card.
    STATE=error
    DIAGNOSIS=unclassified
    VERDICT=check-error
    REASON="context probe not installed (expected bin/cuda-context-probe next to this script, or on PATH)"
else
    run_mint default
    ARM_DEFAULT_RC=$ARM_RC
    ARM_DEFAULT=$(arm_label "$ARM_RC")

    if [[ "$ARM_RC" -eq 0 ]]; then
        STATE=ok
        DEVCOUNT=1
        REASON="CUDA context created (${PROBE##*/}, ${ARM_OUT:-ok})"
    else
        STATE=unavailable
        run_mint wsl
        ARM_WSL_RC=$ARM_RC
        ARM_WSL=$(arm_label "$ARM_RC")
        read_order

        if [[ "$ARM_RC" -eq 0 ]]; then
            # The card answers under the WSL lib dir. Whatever the cache says, this is
            # resolution, not hardware: never call it a wedge and never prescribe a reboot.
            DIAGNOSIS=libshadow
            VERDICT=library-shadowed
            DEVCOUNT=1
            REASON="LIBRARY SHADOWING: default arm failed but LD_LIBRARY_PATH=${WSL_LIBDIR} created a \
CUDA context — the loader is resolving libcuda.so.1 away from the WSL driver; the card is not dead"
        elif [[ "$ORDER" = checked && "$FIRST_CUDA" != "$WSL_LIBCUDA" ]]; then
            DIAGNOSIS=liborder
            VERDICT=loader-order
            REASON="libcuda.so.1 resolves to ${FIRST_CUDA}, not ${WSL_LIBCUDA} — a LOADER-ORDER fault, \
and both context arms failed, so correcting order is the first in-VM step; hardware is not established"
        elif [[ "$ORDER" = checked && "$FIRST_CUDA" = "$WSL_LIBCUDA" \
                && "$ARM_DEFAULT" != unavailable && "$ARM_WSL" != unavailable ]]; then
            DIAGNOSIS=wedge
            VERDICT=wedge
            REASON="both context arms failed (default=${ARM_DEFAULT}, wsl=${ARM_WSL}) and loader order \
was read and names the passthrough library first — hardware is the remaining explanation"
        else
            DIAGNOSIS=unclassified
            VERDICT=unclassified
            REASON="both context arms did not succeed (default=${ARM_DEFAULT}, wsl=${ARM_WSL}) and loader \
order ${ORDER}${FIRST_CUDA:+ names ${FIRST_CUDA}} — this check cannot decide between hardware and resolution, \
so it prescribes neither remedy"
        fi
    fi
fi

# --- corroboration: kernel-side dxg + WSL crash captures in the window ---------
# swallow-ok: an unreadable journal yields no matches, which is the same zero this counter reports; the figure is corroboration only, never the verdict
count_kernel() { journalctl -k --since "-${WINDOW_MIN}min" --no-pager 2>/dev/null | grep -c -- "$1" || true; }
DXG=$(count_kernel 'create_process failed'); DXG=${DXG:-0}
CRASH=$(count_kernel 'Capturing crash');     CRASH=${CRASH:-0}

# Format both context-mint arm verdicts for diagnostic alert lines.
arm_evidence() {
    printf 'default=%s; LD_LIBRARY_PATH=%s=%s' "$ARM_DEFAULT" "$WSL_LIBDIR" "$ARM_WSL"
}

alert_text() {
    case "$STATE" in
        ok)
            printf '%s\n' "✅ GPU PASSTHROUGH OK — a CUDA context was created and destroyed."
            printf '%s\n' "Evidence: ${REASON}; ${DXG} dxg failure(s) + ${CRASH} crash capture(s) in the last ${WINDOW_MIN} min."
            ;;
        unavailable)
            if [[ "$DIAGNOSIS" = libshadow ]]; then
                printf '%s\n' "🔴 GPU CHECK FAILING on LIBRARY SHADOWING — not a lost passthrough, and no reboot will fix it."
                printf '%s\n' "Both arms: $(arm_evidence)."
                printf '%s\n' "Reason: ${REASON}"
                printf '%s\n' "Loader cache: ${ORDER}${FIRST_CUDA:+ (libcuda.so.1 -> ${FIRST_CUDA})}. \
The WSL arm succeeding is the discriminator: the driver answers when the loader can find it."
                printf '%s\n' "Impact: the CUDA lane cannot trust the default environment, so it must not start yet. \
Processes that set LD_LIBRARY_PATH=${WSL_LIBDIR} are unaffected."
                printf '%s\n' "Fix (in-VM, one file, no reboot, no packages): printf '${WSL_LIBDIR}\n'\
 | sudo tee /etc/ld.so.conf.d/00-wsl-libcuda.conf >/dev/null && sudo ldconfig —\
 then re-run this check."
                printf '%s\n' "Do NOT run 'wsl --shutdown': it stops the gateway and every lane and reorders \
nothing. Do NOT remove packages: the toolkit purge also takes g++-13, \
libthrust-dev and nvidia-cuda-dev."
            elif [[ "$DIAGNOSIS" = liborder ]]; then
                printf '%s\n' "🔴 GPU CHECK FAILING on LOADER ORDER — the fix is in-VM; no host action is named yet."
                printf '%s\n' "Both arms: $(arm_evidence)."
                printf '%s\n' "Reason: ${REASON}"
                printf '%s\n' "Evidence: ${DXG} dxg create_process failure(s) + ${CRASH} WSL crash capture(s) \
in the last ${WINDOW_MIN} min. Both context arms failed, so order alone is not proven to be the whole cause."
                printf '%s\n' "Fix (in-VM, one file, no reboot, no packages): printf '${WSL_LIBDIR}\n'\
 | sudo tee /etc/ld.so.conf.d/00-wsl-libcuda.conf >/dev/null && sudo ldconfig —\
 then re-run this check. It is the cheap step and it must be ruled out before any host action."
                printf '%s\n' "Do NOT run 'wsl --shutdown': it stops the gateway and every lane and reorders \
nothing. Do NOT remove packages: the toolkit purge also takes g++-13, \
libthrust-dev and nvidia-cuda-dev."
            elif [[ "$DIAGNOSIS" = wedge ]]; then
                printf '%s\n' "🔴 GPU PASSTHROUGH LOST — CUDA lane cannot start."
                printf '%s\n' "Both arms failed: $(arm_evidence)."
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
                printf '%s\n' "Both arms: $(arm_evidence)."
                printf '%s\n' "Reason: ${REASON}"
                printf '%s\n' "Loader order ${ORDER}${FIRST_CUDA:+ (libcuda.so.1 -> ${FIRST_CUDA})}, so this \
check cannot say whether the passthrough is gone or library resolution is wrong. \
Deliberately prescribing NEITHER remedy: a host reboot on a loader fault fixes \
nothing and costs the gateway."
                printf '%s\n' "Next: confirm the loader order by hand (ldconfig -p | grep 'libcuda\.so\.1 ') and try one run with\
 LD_LIBRARY_PATH=${WSL_LIBDIR} ${PROBE##*/}. If that mints a context, it is ORDER, not hardware."
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
        printf '{"state":"%s","diagnosis":"%s","verdict":"%s","order":"%s","reason":"%s","libcuda_first":"%s",' \
            "$STATE" "$DIAGNOSIS" "$VERDICT" "$ORDER" "$REASON" "$FIRST_CUDA"
        printf '"probe":"%s","arm_default":"%s","arm_wsl":"%s","probe_rc":%d,"arm_default_rc":%d,"arm_wsl_rc":%d,' \
            "$PROBE_KIND" "$ARM_DEFAULT" "$ARM_WSL" "$ARM_DEFAULT_RC" "$ARM_DEFAULT_RC" "$ARM_WSL_RC"
        printf '"smi_rc":-1,"devices":%d,"window_min":%d,"dxg_failures":%d,"wsl_crashes":%d}\n' \
            "$DEVCOUNT" "$WINDOW_MIN" "$DXG" "$CRASH"
        ;;
    --alert)
        alert_text
        ;;
    *)
        printf '%s: %s (%s; diagnosis=%s; arms: %s; %s dxg failures, %s crashes / %s min)\n' \
            "$STATE" "$REASON" "rc=$ARM_DEFAULT_RC" "$DIAGNOSIS" "$(arm_evidence)" "$DXG" "$CRASH" "$WINDOW_MIN"
        ;;
esac

case "$STATE" in
    ok)          exit 0 ;;
    unavailable) exit 1 ;;
    *)           exit 2 ;;
esac

# end of file
