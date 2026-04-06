# Tactical Console Profile v3.1

> **Repo:** [`waynegault/ubuntu-console`](https://github.com/waynegault/ubuntu-console)
> **Environment:** WSL2 Ubuntu 24.04 on Windows 11 Pro
> **Hardware:** Intel i9 / Intel Iris Xe (iGPU) / RTX 3050 Ti 4 GB VRAM (CUDA)

The **Tactical Console Profile** is a modular Bash environment that turns a
WSL2 Ubuntu shell into a unified command-and-control console. A thin loader
(`tactical-console.bashrc`) sources 15 numbered modules from `scripts/` in
dependency order.

Non-interactive library loader (all modules except 13-init.sh) — `env.sh`
sources all modules for MCP tools, cron jobs, and AI exec environments.

## Quick Links

| What You Need | Where to Find It |
|---|---|
| **Install & first commands** | [docs/quick-start.md](docs/quick-start.md) |
| **Dashboard usage** | [docs/dashboard.md](docs/dashboard.md) |
| **Full command reference** | [docs/commands.md](docs/commands.md) |
| **OpenClaw integration** | [docs/openclaw.md](docs/openclaw.md) |
| **Local LLM setup** | [docs/llm.md](docs/llm.md) |
| **Maintenance pipeline** | [docs/maintenance.md](docs/maintenance.md) |
| **Architecture & modules** | [docs/architecture.md](docs/architecture.md) |
| **Troubleshooting** | [docs/troubleshooting.md](docs/troubleshooting.md) |
| **Dependencies** | [docs/dependencies.md](docs/dependencies.md) |

## Features

- **System telemetry** — CPU, dual GPU, memory, disk, battery in a 78-column dashboard
- **Local LLM inference** — Full lifecycle management of `llama-server` (llama.cpp)
- **OpenClaw agent framework** — Gateway lifecycle, agent orchestration, backup/restore
- **Maintenance** — 15-step `up` pipeline with cooldown management
- **Deployment** — Git commit/push with optional LLM-generated commit messages
- **Knowledge graph** — Interactive Cytoscape.js visualisation via `oc g`

## Design Principles

| Principle | Implementation |
|---|---|
| **Determinism** | Every step is idempotent with 7-day cooldowns |
| **Zero Dependencies Beyond Coreutils** | All LLM streaming is pure `bash + curl + jq` |
| **Instant UI** | Telemetry uses `/dev/shm` caching with background refresh |
| **Security First** | LLM binds to `127.0.0.1`, API key cache is `chmod 600` on `tmpfs` |
| **Hardware Awareness** | `-ngl 999` auto-offload, dynamic CPU thread scaling |

## CI Status

[![CI](.github/workflows/ci.yml)](.github/workflows/ci.yml)

- **Fast tests:** `bats tests/tactical-console-fast.bats` (20s, 41 tests)
- **Full tests:** `bats tests/tactical-console.bats` (473 BATS unit tests, runtime behaviour)
- **Lint:** `scripts/lint.sh` (bash -n + shellcheck + Unicode safety)

# end of file
