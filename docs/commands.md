---
title: Command Reference
description: Complete quick reference card for every command in Tactical Console Profile — dashboard, maintenance, OpenClaw, LLM, deployment, and utility commands.
---

# Command Reference

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

← [Back to README](../README.md)

# end of file
