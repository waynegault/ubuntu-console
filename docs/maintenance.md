---
title: System Maintenance
description: The `up` maintenance pipeline — 13-step system maintenance with cooldown management, race condition protection, and detailed step descriptions.
---

# System Maintenance (`up`)

## Maintenance Pipeline

Run `up` to execute the 13-step maintenance pipeline:

| Step | What It Does |
|---|---|
| 1. Internet Connectivity | Pings `github.com` |
| 2. APT Packages | Split cooldown: `apt-get update` (24h) + `upgrade --no-install-recommends` (7d). Dry-run first to detect dependency issues. |
| 3. NPM & Cargo | `npm update -g` and `cargo install-update -a` |
| 4. R Packages | Updates CRAN and Bioconductor packages when available |
| 5. OpenClaw Framework | Runs `openclaw doctor` (skipped if not installed) |
| 6. Python Venv Cloaking | Reports active virtual environment |
| 7. Python Fleet | Scans `/usr/bin/python3.*` for installed versions |
| 8. GPU Status | Queries `nvidia-smi` readiness |
| 9. Sanitation | Cleans temp files from `/tmp/openclaw` |
| 10. Disk Space Audit | Warns if any mount exceeds 90% (validates numeric input) |
| 11. Stale Processes | Kills orphaned `llama-server` instances |
| 12. README Sync | Checks a few tracked repo facts for documentation drift |
| 13. Documentation Drift | Lightweight README accuracy check |

## Cooldown System

Each step that involves network or package operations has a **cooldown**
stored in `~/.openclaw/maintenance_cooldowns.txt`. APT index refresh uses a
24-hour cooldown; APT upgrade and all other network steps use a 7-day
cooldown. The cooldown uses Unix timestamps and shows remaining time
(e.g., `[CACHED - 4d 12h LEFT]`).

**Race Condition Fix:** All cooldown operations use `flock -x` for exclusive
access to prevent parallel `up` runs from both passing the same check.

← [Back to README](../README.md)

# end of file
