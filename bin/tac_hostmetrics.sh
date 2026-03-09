#!/usr/bin/env bash
# tac_hostmetrics.sh — Query Windows host CPU + dual GPU utilization.
# Output: cpu|gpu0|gpu1  (pipe-delimited integers, 0-100)
# GPU0 = Intel Iris Xe (via typeperf 3D engine counter)
# GPU1 = NVIDIA GeForce RTX (via nvidia-smi — captures CUDA/compute workloads)
# Requires: typeperf.exe (ships with Windows), gawk, nvidia-smi (optional)
# Typical runtime: ~5s from WSL
# AI: Output format is a contract — callers split on '|'. Do not change it.
# AI INSTRUCTION: Increment version on significant changes.
# shellcheck disable=SC2034  # VERSION is read by external tooling, not this script
VERSION="1.0"
set -euo pipefail

raw=$(typeperf.exe "\Processor(_Total)\% Processor Time" \
      "\GPU Engine(*engtype_3D)\Utilization Percentage" \
      -sc 1 2>/dev/null | tr -d '\r"')

# typeperf CSV: line 1 = blank, line 2 = header, line 3 = data values
cpu=$(echo "$raw" | awk -F',' 'NR==3 { printf "%d", $2+0.5 }')

# Intel iGPU (gpu0) from typeperf — works well for the integrated GPU.
# We take the lowest LUID which corresponds to Intel Iris Xe.
gpu0=$(echo "$raw" | gawk -F',' '
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
  n = asorti(sums, sorted)
  if (n >= 1) printf "%d", int(sums[sorted[1]]+0.5)
  else printf "0"
}')

# NVIDIA dGPU (gpu1) via nvidia-smi — captures CUDA/compute workloads that
# typeperf's engtype_3D counter misses entirely (LLM inference, ML training).
WSL_NVIDIA_SMI="/usr/lib/wsl/lib/nvidia-smi"
smi_cmd="$WSL_NVIDIA_SMI"
[[ ! -x "$smi_cmd" ]] && smi_cmd=$(command -v nvidia-smi 2>/dev/null)
if [[ -n "$smi_cmd" && -x "$smi_cmd" ]]; then
    gpu1=$("$smi_cmd" --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>/dev/null | awk '{printf "%d", $1+0.5}')
else
    # Fallback: take highest LUID from typeperf (3D engine only)
    gpu1=$(echo "$raw" | gawk -F',' '
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
  n = asorti(sums, sorted)
  if (n >= 2) printf "%d", int(sums[sorted[2]]+0.5)
  else printf "0"
}')
fi

echo "${cpu:-0}|${gpu0:-0}|${gpu1:-0}"
