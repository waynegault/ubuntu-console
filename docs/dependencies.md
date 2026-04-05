---
title: Dependencies & Requirements
description: System requirements, required and optional packages, and what is NOT required to run Tactical Console Profile.
---

# Dependencies & Requirements

## System Requirements

| Component | Requirement |
|---|---|
| **OS** | Windows 11 Pro with WSL2 |
| **WSL Distribution** | Ubuntu 24.04 |
| **Shell** | Bash 5.2+ |
| **GPU** | NVIDIA RTX 3050 Ti (or any CUDA-capable GPU) |
| **PowerShell** | 7.4+ (as `pwsh.exe` in WSL interop PATH) |

## Required Packages (All Standard Linux)

| Package | Used By | Install |
|---|---|---|
| `jq` | All LLM/SSE functions, token scanning | `sudo apt install jq` |
| `curl` | LLM API calls, health checks, WAN IP | Pre-installed |
| `ss` (iproute2) | `__test_port` port checking | Pre-installed |
| `grep` / `awk` / `sed` | Telemetry parsing, text processing | Pre-installed |
| `find` | Token scanning, temp cleanup, session counting | Pre-installed |
| `systemctl` / `journalctl` | OpenClaw gateway lifecycle, logs | Pre-installed (systemd) |
| `typeperf.exe` | Host CPU + iGPU (Intel Iris 3D engine) telemetry | Windows built-in (WSL interop) |
| `nvidia-smi` | CUDA/compute GPU telemetry (NVIDIA RTX) — captures LLM/ML workloads that typeperf's 3D engine misses | WSL NVIDIA driver (`/usr/lib/wsl/lib/nvidia-smi`) |
| `git` | Deployment, commit, sec status | `sudo apt install git` |
| `rsync` | Deploy sync | `sudo apt install rsync` |
| `zip` / `unzip` | `oc-backup` / `oc-restore` | `sudo apt install zip unzip` |

## Optional Packages

| Package | Used By | Install |
|---|---|---|
| `huggingface-cli` | `model download` | `pip install huggingface-hub` |
| `cargo` + `install-update` | `up` step 3 (Cargo crate updates) | Rust toolchain |
| `npm` | `up` step 3 (global package updates) | Node.js |
| `openclaw` CLI | All `oc-*` commands | `npm install -g openclaw` |
| `clawhub` | `oc-skills` (optional alternate) | OpenClaw ecosystem |

## What Is NOT Required

- **Python** — All LLM streaming was rewritten to pure bash + curl + jq in v2.04.
- **Ruby** — Never used.
- **Docker** — The gateway runs as a native systemd service.

← [Back to README](../README.md)

# end of file
