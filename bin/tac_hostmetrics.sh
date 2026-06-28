#!/usr/bin/env bash
# tac_hostmetrics.sh - Query Windows host CPU + dual GPU utilization.
# Output: cpu|gpu0|gpu1  (pipe-delimited integers, 0-100)
# Optional side effect: if TAC_GPU_ENGINES_OUT is set, writes a short summary
# of active NVIDIA dGPU engine classes to that path.
# GPU0 = Intel Iris Xe (via typeperf 3D engine counter)
# GPU1 = NVIDIA GeForce RTX dGPU load (max of Windows engine telemetry and
#        nvidia-smi compute utilisation)
# Requires: typeperf.exe (ships with Windows), gawk, nvidia-smi (optional)
# Typical runtime: ~5s from WSL
# AI: Output format is a contract — callers split on '|'. Do not change it.
# AI INSTRUCTION: Increment version on significant changes.
# shellcheck disable=SC2034  # VERSION is read by external tooling, not this script
VERSION="1.1"
set -euo pipefail

raw=$(timeout 15 typeperf.exe "\Processor(_Total)\% Processor Time" \
  "\GPU Engine(*)\Utilization Percentage" \
      -sc 1 2>/dev/null | tr -d '\r"')

# typeperf CSV structure: line 1 = blank, line 2 = column headers,
# line 3 = data values.  Column 2 = CPU %.  +0.5 rounds to nearest int.
cpu=$(echo "$raw" | awk -F',' 'NR==3 { printf "%d", $2+0.5 }')

# Intel iGPU (gpu0) from typeperf.
# Each GPU engine counter embeds a LUID (Locally Unique Identifier) in its
# column header. We parse LUIDs from the header row (NR==2), sum utilisation
# values per LUID from the data row (NR==3), then sort by LUID.  The lowest
# LUID corresponds to the Intel Iris Xe integrated GPU (enumerated first by
# Windows).  The highest LUID is the NVIDIA discrete GPU (see gpu1 below).
gpu0=$(echo "$raw" | gawk -F',' '
NR==2 {
  for(i=3;i<=NF;i++) {
    if (match($i, /luid_0x[0-9a-fA-F]+_0x([0-9a-fA-F]+).*engtype_([^\\)]*)/, m)) {
      luids[i] = m[1]
      engines[i] = m[2]
    }
  }
}
NR==3 {
  for(i=3;i<=NF;i++) {
    if (luids[i] != "" && engines[i] == "3D")
      sums[luids[i]] += ($i + 0)
  }
}
END {
  min_luid = ""
  min_val = -1
  for (luid in sums) {
    luid_val = strtonum("0x" luid)
    if (min_val < 0 || luid_val < min_val) {
      min_val = luid_val
      min_luid = luid
    }
  }
  if (min_luid != "") printf "%d", int(sums[min_luid]+0.5)
  else printf "0"
}')

# Windows dGPU telemetry from the highest GPU LUID. We aggregate all engine
# counters for the discrete adapter and clamp to 100 so the dashboard reflects
# Windows-side video/graphics load that nvidia-smi in WSL can miss.
gpu1_windows=$(echo "$raw" | gawk -F',' '
NR==2 {
  for(i=3;i<=NF;i++) {
    if (match($i, /luid_0x[0-9a-fA-F]+_0x([0-9a-fA-F]+)/, m))
      luids[i] = m[1]
  }
}
NR==3 {
  for(i=3;i<=NF;i++) {
    if (luids[i] != "")
      sums[luids[i]] += ($i + 0)
  }
}
END {
  max_luid = ""
  max_val = -1
  for (luid in sums) {
    luid_val = strtonum("0x" luid)
    if (luid_val > max_val) {
      max_val = luid_val
      max_luid = luid
    }
  }
  if (max_luid != "") {
    util = sums[max_luid]
    if (util > 100) util = 100
    printf "%d", int(util+0.5)
  } else {
    printf "0"
  }
}')

# NVIDIA dGPU (gpu1) via nvidia-smi - still needed for CUDA/compute workloads
# that Windows engine counters in WSL can miss or lag.
WSL_NVIDIA_SMI="/usr/lib/wsl/lib/nvidia-smi"
smi_cmd="$WSL_NVIDIA_SMI"
[[ ! -x "$smi_cmd" ]] && smi_cmd=$(command -v nvidia-smi 2>/dev/null)
if [[ -n "$smi_cmd" && -x "$smi_cmd" ]]
then
    gpu1_smi=$("$smi_cmd" \
        --query-gpu=utilization.gpu \
        --format=csv,noheader,nounits 2>/dev/null \
        | awk '{printf "%d", $1+0.5}')
    if (( gpu1_smi > gpu1_windows ))
    then
        gpu1=$gpu1_smi
    else
        gpu1=$gpu1_windows
    fi
else
    gpu1=$gpu1_windows
fi

echo "${cpu:-0}|${gpu0:-0}|${gpu1:-0}"

if [[ -n "${TAC_GPU_ENGINES_OUT:-}" ]]
then
    gpu1_engines=$(echo "$raw" | gawk -F',' '
NR==2 {
  for(i=3;i<=NF;i++) {
    if (match($i, /luid_0x[0-9a-fA-F]+_0x([0-9a-fA-F]+).*engtype_([^\\)]*)/, m)) {
      luids[i] = m[1]
      eng = m[2]
      if (eng == "") eng = "Other"
      engines[i] = eng
    }
  }
}
NR==3 {
  for(i=3;i<=NF;i++) {
    if (luids[i] != "") {
      sums[luids[i]] += ($i + 0)
      engsum[luids[i] SUBSEP engines[i]] += ($i + 0)
    }
  }
}
END {
  max_luid = ""
  max_val = -1
  for (luid in sums) {
    luid_val = strtonum("0x" luid)
    if (luid_val > max_val) {
      max_val = luid_val
      max_luid = luid
    }
  }

  n = 0
  for (key in engsum) {
    split(key, parts, SUBSEP)
    if (parts[1] != max_luid)
      continue

    util = engsum[key]
    if (util > 100)
      util = 100
    if (util < 1)
      continue

    eng = parts[2]
    if (eng == "VideoDecode") eng = "VDec"
    else if (eng == "VideoEncode") eng = "VEnc"
    else if (eng == "VideoProcessing") eng = "VProc"
    else if (eng == "Compute") eng = "Comp"
    else if (eng == "LegacyOverlay") eng = "Overlay"

    util_map[eng] = util
  }

  split("VDec VEnc VProc 3D Comp Copy Overlay Other", order, " ")
  for (i = 1; i <= length(order); i++) {
    eng = order[i]
    if (!(eng in util_map))
      continue
    if (printed > 0)
      printf " | "
    printf "%s %d%%", eng, int(util_map[eng] + 0.5)
    printed++
    if (printed >= 3)
      break
  }

  if (printed == 0)
    printf "Idle"
}')
    printf '%s\n' "${gpu1_engines:-Idle}" > "$TAC_GPU_ENGINES_OUT"
fi

# end of file
