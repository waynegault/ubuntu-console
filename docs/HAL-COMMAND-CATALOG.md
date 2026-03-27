# Tactical Console — Command Catalog for Hal

## Executive Summary

**Single entry point:** `tac-exec <command>`

All tactical console commands are shell functions loaded from `~/ubuntu-console/scripts/`. The `tac-exec` wrapper sources the environment and executes the command.

---

## Command Categories

### 🎯 LLM Model Management

| Command | Description | Output |
|---------|-------------|--------|
| `tac-exec model status` | Show active model, health, build | `Active #1 Model (1.0G)` `Health OK` |
| `tac-exec model list` | List all registered models | Table with #, name, size, quant, GPU layers |
| `tac-exec model use N` | Start model #N | Spinner + `ONLINE [Port 8081]` |
| `tac-exec model stop` | Stop running LLM | `[STOPPED]` |
| `tac-exec model info N` | Show model #N details | Full config |
| `tac-exec model default N` | Set default model | `[DEFAULT SET]` |
| `tac-exec model scan` | Rescan model directory | Updates registry |
| `tac-exec model doctor` | Health diagnostic | Checklist report |
| `tac-exec model bench` | Run benchmark | TPS metrics |

### 🚪 Gateway Control

| Command | Description | Output |
|---------|-------------|--------|
| `tac-exec so` | Start gateway (+ LLM if needed) | `Local LLM [RUNNING]` `Gateway [RUNNING]` |
| `tac-exec xo` | Stop gateway | `[TERMINATED]` |
| `tac-exec oc restart` | Full gateway restart | Stop → Start |

### 🦙 Direct LLM Control

| Command | Description | Output |
|---------|-------------|--------|
| `tac-exec serve` | Start default LLM | `ONLINE [Port 8081]` |
| `tac-exec serve N` | Start model #N | `ONLINE [Port 8081]` |
| `tac-exec halt` | Stop LLM | `[STOPPED]` |
| `tac-exec mlogs` | Open LLM logs in VS Code | Opens `llama-server.log` |

### ⚙️ Configuration

| Command | Description | Opens |
|---------|-------------|-------|
| `tac-exec llmconf` | Edit models.conf | `~/.llm/models.conf` |
| `tac-exec oedit` | Edit tactical-console.bashrc | `~/ubuntu-console/tactical-console.bashrc` |
| `tac-exec oc conf` | Edit openclaw.json | `~/.openclaw/openclaw.json` |
| `tac-exec reload` | Reload shell profile | N/A |

### 🔍 Diagnostics

| Command | Description |
|---------|-------------|
| `tac-exec model doctor` | Full LLM health check |
| `tac-exec oc doctor-local` | Gateway + LLM end-to-end |
| `tac-exec oc diag` | 5-point diagnostic |
| `tac-exec oc health` | Gateway HTTP health |
| `tac-exec le` | Last 40 gateway log lines |
| `tac-exec mlogs` | LLM logs |
| `tac-exec oc logs` | OpenClaw logs |

### 📊 OpenClaw Operations

| Command | Description |
|---------|-------------|
| `tac-exec oc start -m "msg"` | Dispatch agent turn |
| `tac-exec oc stop --agent ID` | Delete agent |
| `tac-exec oc mem-index` | Rebuild memory index |
| `tac-exec oc backup` | Create backup ZIP |
| `tac-exec oc skills` | List skill modules |
| `tac-exec oc tui` | Launch terminal UI |

---

## Usage Examples

### "Check if the LLM is running"
```bash
tac-exec model status
```

### "Start the gateway"
```bash
tac-exec so
```

### "Switch to model 2"
```bash
tac-exec model list      # See available
tac-exec model use 2     # Start #2
```

### "The gateway is stuck, restart it"
```bash
tac-exec xo              # Stop
tac-exec so              # Start fresh
```

### "Show me the LLM logs"
```bash
tac-exec mlogs
```

### "What models do I have?"
```bash
tac-exec model list
```

---

## Port Reference

| Service | Port | Health URL |
|---------|------|------------|
| LLM (llama-server) | 8081 | `http://127.0.0.1:8081/health` |
| Gateway (OpenClaw) | 18790 | `http://127.0.0.1:18790/api/health` |

---

## File Locations

| File | Purpose |
|------|---------|
| `~/ubuntu-console/scripts/` | All shell functions |
| `~/ubuntu-console/bin/tac-exec` | Command wrapper |
| `~/.llm/models.conf` | Model registry |
| `~/.llm/default_model.conf` | Default model file |
| `/dev/shm/active_llm` | Active model number |
| `/dev/shm/last_tps` | Last benchmark TPS |
| `/dev/shm/llama-server.log` | LLM runtime log |

---

## Error Handling

Commands return:
- **0** = Success
- **1** = Failure (check output for details)

Common errors:
- `[OFFLINE]` = LLM not running
- `[FAILED TO START]` = Model failed (check `tac-exec mlogs`)
- `[PORT BLOCKED]` = Port in use (Windows conflict possible)

---

## Security Notes

- All commands run as current user (no sudo)
- API keys bridged from Windows (stored in `~/.openclaw/.env.bridge`)
- Exec approval required for Hal (configured in `~/.openclaw/exec-approvals.json`)

---

**Last updated:** 2026-03-27  
**Profile version:** v3.65
