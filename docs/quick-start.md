---
title: Quick Start
description: Get up and running with Tactical Console Profile in 5 minutes — installation, first commands, LLM setup, OpenClaw gateway, git workflow, and common tasks.
---

# Quick Start (5 Minutes)

## Prerequisites

- WSL2 with Ubuntu 24.04
- NVIDIA GPU with CUDA passthrough (for local LLM)
- 20GB free disk space

## Installation

```bash
# Clone the repository
cd ~
git clone https://github.com/waynegault/ubuntu-console.git
cd ubuntu-console

# Run the installer
./install.sh

# Reload your shell
exec bash
```

## First Commands

```bash
h              # Show help index (all commands)
m              # Open tactical dashboard (system stats)
up             # Run 13-step system maintenance
```

## Local LLM Setup

```bash
model list     # See available models
model use 5    # Start model #5 (optimal settings auto-applied)
burn "Hello!"  # Test inference speed (~1300 token stress test)
```

## OpenClaw Gateway

```bash
so             # Start OpenClaw gateway + local LLM
xo             # Stop gateway (LLM continues running)
oc restart     # Full restart (gateway + LLM)
```

## Git Workflow

```bash
git add .
commit_auto    # AI-generated commit message (reviews diff first)
commit: "msg"  # Your own commit message
```

## Common Tasks

| Task | Command |
|------|---------|
| Check system health | `m` (dashboard) |
| View GPU status | `gpu-status` |
| Clean temp files | `cl` |
| Edit profile | `oedit` |
| Open any file in VS Code | `code <path>` |
| Copy current path to clipboard | `cpwd` |

← [Back to README](../README.md)

# end of file
