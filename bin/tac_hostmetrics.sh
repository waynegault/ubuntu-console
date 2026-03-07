#!/usr/bin/env bash
# tac_hostmetrics.sh — Query Windows host CPU + dual GPU utilization via typeperf.
# Output: cpu|gpu0|gpu1  (pipe-delimited integers, 0-100)
# GPU0 = Intel Iris Xe (lower LUID), GPU1 = NVIDIA GeForce RTX (higher LUID)
# Requires: typeperf.exe (ships with Windows), gawk
# Typical runtime: ~5s from WSL

raw=$(typeperf.exe "\Processor(_Total)\% Processor Time" \
      "\GPU Engine(*engtype_3D)\Utilization Percentage" \
      -sc 1 2>/dev/null | tr -d '\r"')

# typeperf CSV: line 1 = blank, line 2 = header, line 3 = data values
cpu=$(echo "$raw" | awk -F',' 'NR==3 { printf "%d", $2+0.5 }')

gpu_vals=$(echo "$raw" | gawk -F',' '
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
  for(j=1;j<=n;j++) printf "%d\n", int(sums[sorted[j]]+0.5)
}')

gpu0=$(echo "$gpu_vals" | sed -n '1p')
gpu1=$(echo "$gpu_vals" | sed -n '2p')
echo "${cpu:-0}|${gpu0:-0}|${gpu1:-0}"
