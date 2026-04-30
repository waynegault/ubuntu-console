---
title: Command & Interface Reference
description: Complete quick reference card for every command, the tactical dashboard, shell prompt, navigation, and virtual environment auto-activation.
---

# Command & Interface Reference

## Quick Reference Card

| Command | Category | Description |
|---|---|---|
| `m` | Dashboard | Render full tactical dashboard |
| `h` | Help | Show command help index |
| `up` | Maintenance | 13-step system maintenance |
| `cls` | Shell | Clear screen + banner |
| `reload` | Shell | Full profile reload (`exec bash`) |
| `sysinfo` | System | One-line hardware summary |
| `get-ip` | Network | WSL + WAN IP addresses |
| `cpwd` | Utility | Copy path to clipboard |
| `cl` | Utility | Quick temp cleanup (`--dry-run` supported) |
| `docs-sync` | Utility | Check README drift against current repo facts |
| `logtrim` | Utility | Trim logs > 1 MB |
| `oedit` | Editor | Open `tactical-console.bashrc` in VS Code |
| `code` | Editor | Open anything in VS Code |
| `so` | OpenClaw | Start gateway (warns if local LLM provider offline) |
| `xo` | OpenClaw | Stop gateway (stop only — use `oc restart` to restart) |
| `oc-restart` | OpenClaw | Restart gateway (native: openclaw gateway restart) |
| `oc-health` | OpenClaw | Deep health probe (`--json` / `--plain`) |
| `os` | OpenClaw | List sessions |
| `oa` | OpenClaw | List agents |
| `ocstart` | OpenClaw | Send agent turn |
| `ocstop` | OpenClaw | Stop agent |
| `status` | OpenClaw | Quick status |
| `ocstat` | OpenClaw | Full status |
| `ocgs` | OpenClaw | Deep gateway status |
| `ockeys` | OpenClaw | Show API key visibility |
| `oc-refresh-keys` | OpenClaw | Force re-import API keys |
| `oc-backup` | OpenClaw | Snapshot config, scripts, systemd units to ZIP |
| `oc-restore` | OpenClaw | Restore from ZIP (validates contents, `--dry-run`) |
| `oc-diag` | OpenClaw | 5-point diagnostic |
| `oc-doctor-local` | OpenClaw | End-to-end local gateway + llama.cpp validation |
| `oc-env` | OpenClaw | Dump env vars |
| `oc-config` | OpenClaw | Get/set config |
| `oc-failover` | OpenClaw | Cloud fallback toggle (on/off/status) |
| `oc g` | OpenClaw | Launch knowledge graph server and open in browser |
| `oc-local-llm` | OpenClaw | Link to local LLM |
| `oc-sync-models` | OpenClaw | Sync model registry |
| `oc-trust-sync` | OpenClaw | Save current oc-llm-sync.sh SHA256 as trusted |
| `wacli` | OpenClaw | WhatsApp CLI wrapper (auto-injects `--store` flag) |
| `le` / `lo` / `lc` | Logs | View stderr / stdout / clear |
| `model list` | LLM | Show numbered model registry (▶ = active) |
| `model use N` | LLM | Start model #N with optimal GPU/ctx/thread settings |
| `model stop` | LLM | Stop inference server |
| `model status` | LLM | Show running model details (`--json` / `--plain`) |
| `model doctor` | LLM | Validate registry/default/GPU/watchdog/ports |
| `model recommend` | LLM | Rank models for a 4 GB VRAM system |
| `model info N` | LLM | Full details for model #N |
| `model scan` | LLM | Scan GGUF files, read metadata, rebuild registry |
| `model download` | LLM | Fetch from HuggingFace |
| `model delete N` | LLM | Delete model #N from disk and registry (`--dry-run`) |
| `model archive N` | LLM | Move model #N to archive and deregister (`--dry-run`) |
| `model bench` | LLM | Benchmark all on-disk models, persist TSV |
| `model bench-diff` / `model bench-compare` | LLM | Compare two benchmark runs |
| `model bench-history` | LLM | Summarise recent benchmark runs |
| `serve N` / `halt` | LLM | Aliases for use/stop |
| `wake` | GPU | Lock persistence mode |
| `burn` | LLM | Stress test + TPS benchmark |
| `chatl` | LLM | Multi-turn chat REPL |
| `chat-context` | LLM | File context → LLM |
| `chat-pipe` | LLM | Stdin context → LLM |
| `explain` | LLM | Explain last command |
| `wtf` | LLM | Topic explanation REPL |
| `mkproj` | Dev | Scaffold Python project |
| `commit: "msg"` | Git | Stage all + commit with YOUR message + push |
| `commit` | Git | Alias for `commit_auto` — LLM-generated message (PID-verified, secret detection) + push |
| `deploy` | Deploy | Rsync to production workspace |

---

## Dashboard & Shell Interface

### The Dashboard (`m`)

Type `m` at any prompt to render the full-screen Tactical Dashboard:

```
+------------------------------------------------------------------------------+
|                      TACTICAL DASHBOARD                      (ver.: 2.12) |
|------------------------------------------------------------------------------|
|  SYSTEM TIME  :: Saturday 03:04 07/03/2026                                |
|  UPTIME       :: 0d 0h 24m                                                |
|  BATTERY      :: A/C POWERED                                              |
|  CPU / GPU    :: CPU 3% | iGPU 2% | CUDA 0%                                |
|  MEMORY       :: 2.77 / 47.04 Gb                                          |
|  STORAGE      :: C: 995 Gb free | WSL: 877 Gb free                        |
|------------------------------------------------------------------------------|
|  GPU          :: RTX 3050 Ti | 0% Load | 62°C | 3897 / 4096 Mb            |
|  LOCAL LLM    :: ACTIVE Phi-4-mini-Q6_K | 14.2 t/s                        |
|  WSL          :: ACTIVE  Ubuntu-24.04  (6.6.87.2-microsoft-standard-WSL2) |
|------------------------------------------------------------------------------|
|  OPENCLAW     :: [ONLINE]  v2026.3.2    (or [NOT INSTALLED] if missing)   |
|  SESSIONS     :: 8 Active (cached 34s ago)  (hidden if not installed)     |
|  ACTIVE AGENT :: 14% (18k of 128k)        (hidden if not installed)       |
|------------------------------------------------------------------------------|
|  TARGET REPO  :: main                                                     |
|  SEC STATUS   :: SECURE                                                   |
|------------------------------------------------------------------------------|
|            up | xo | serve | halt | chatl | commitd | status | h           |
+------------------------------------------------------------------------------+
```

Colour thresholds: **Green** < 75% · **Yellow** 75–90% · **Red** > 90%.

### Help (`h`)

Type `h` to render the full command reference inside a box-drawn panel.
**OpenClaw-aware:** when OpenClaw is not installed, all OpenClaw-related
sections are hidden to reduce clutter.

### Navigation & Convenience

| Command | What It Does |
|---|---|
| `c` or `cls` | Clear screen and redraw the startup banner |
| `reload` | `exec bash` — full profile reload |
| `cpwd` | Copy current directory path to Windows clipboard |
| `cl` | Quick cleanup of `python-*.exe` and `.pytest_cache` in `$PWD` |
| `sysinfo` | One-line: `CPU: 12% RAM: 5.2/15.4 Gb Disk: 142 Gb iGPU: 3%/47°C CUDA: 12%` |
| `get-ip` | Show WSL IP and external WAN IP |
| `logtrim` | Trim any log file > 1 MB to its last 1000 lines |
| `oedit` | Open `tactical-console.bashrc` in VS Code |
| `code <path>` | Open anything in VS Code (lazy-resolved path) |

### Virtual Environment Auto-Activation

The `cd` command is overridden. When you enter a directory containing
`.venv/bin/activate`, it is automatically sourced; when you leave the project
tree, `deactivate` is called automatically. The dashboard shows active venvs
under the "CLOAKING" row.

If venv activation fails, a warning is printed and `VIRTUAL_ENV` is cleared
to prevent confusion.

### Shell Prompt

```
username ▼ ✓ ~/projects/myapp (myenv) >
```

- **▼** — Present if user is in the `sudo` group (admin badge).
- **✓ / ×** — Green checkmark or red cross for last command exit status.
- **(myenv)** — Active Python virtual environment name.
- Empty-enter detection: pressing Enter with no command clears the error badge.

**Inter-prompt spacing:** A single blank line separates consecutive prompts via
PS1's leading `\n`. PS0 is intentionally unset — using both PS0 and PS1
newlines produces a double blank line after silent commands like `cd`.

← [Back to README](../README.md)

# end of file
