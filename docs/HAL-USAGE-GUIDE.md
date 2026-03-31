# Hal's Guide to Tactical Console Commands

## Quick Start

**All commands run via:** `tac-exec <command> [args...]`

**For file-reading commands:** `tac-exec --read <command>` or set `TAC_READ_MODE=1`

---

## Command Categories

### 🔍 Status & Diagnostics (No `--read` needed)

These output to stdout automatically:

```bash
tac-exec model status              # Current model, health, build
tac-exec model status --json       # JSON output for parsing
tac-exec model list                # All available models
tac-exec model list --json         # JSON model list
tac-exec so                        # Gateway status (starts if needed)
tac-exec oc health                 # Gateway HTTP health check
tac-exec gpu-status                # GPU info
tac-exec get-ip                    # Network info
```

### 📖 File Reading Commands (Use `--read`)

These open VS Code for humans, but output content for Hal:

```bash
tac-exec --read llmconf            # Read models.conf
tac-exec --read mlogs              # Read last 100 lines of LLM log
tac-exec --read occonf             # Read openclaw.json
tac-exec --read oedit              # Read tactical-console.bashrc
tac-exec --read oclogs             # Read OpenClaw temp log
```

**Example:**
```bash
# Check model registry
tac-exec --read llmconf

# Check LLM logs for errors
tac-exec --read mlogs

# Check OpenClaw config
tac-exec --read occonf
```

### 🎮 Control Commands

```bash
tac-exec model use N               # Start model #N
tac-exec model stop                # Stop running LLM
tac-exec serve                     # Start default LLM
tac-exec halt                      # Stop LLM
tac-exec so                        # Start gateway (+ LLM if needed)
tac-exec xo                        # Stop gateway
```

### 📝 Log Viewing (Auto-outputs, no `--read` needed)

```bash
tac-exec le                        # Last 60 lines of gateway journal
tac-exec lo                        # Last 120 lines of gateway journal
tac-exec mlogs                     # LLM log (use --read for content)
```

---

## JSON Output for Programmatic Use

Commands that support `--json` flag:

```bash
# Model status as JSON
tac-exec model status --json
# Output: {"online":true,"port":8081,"active_num":"1",...}

# Model list as JSON
tac-exec model list --json
# Output: {"models":[{...},{...}],"drive":{...}}
```

**Parse with jq:**
```bash
tac-exec model status --json | jq '.health'
tac-exec model list --json | jq '.models[] | select(.active==true) | .name'
```

---

## Common Workflows

### 1. Check System Health
```bash
tac-exec model status
tac-exec so
```

### 2. Start LLM If Offline
```bash
# Check status
tac-exec model status

# If offline, start default model
tac-exec serve
# OR start specific model
tac-exec model use 1
```

### 3. Switch Models
```bash
# List available
tac-exec model list

# Switch to model 2
tac-exec model use 2

# Verify
tac-exec model status
```

### 4. Debug LLM Issues
```bash
# Check status
tac-exec model status

# Check logs
tac-exec --read mlogs

# Check gateway logs
tac-exec le

# Check config
tac-exec --read occonf
```

### 5. Gateway Management
```bash
# Check status
tac-exec so

# Restart if needed
tac-exec xo
tac-exec so

# Check logs
tac-exec le
```

---

## File Locations Reference

| File | Command to Read |
|------|-----------------|
| Model registry | `tac-exec --read llmconf` |
| LLM logs | `tac-exec --read mlogs` |
| OpenClaw config | `tac-exec --read occonf` |
| Gateway logs | `tac-exec le` or `tac-exec lo` |
| Shell profile | `tac-exec --read oedit` |

---

## Ports Reference

| Service | Port | Health URL |
|---------|------|------------|
| LLM (llama-server) | 8081 | `http://127.0.0.1:8081/health` |
| Gateway (OpenClaw) | 18789 | `http://127.0.0.1:18789/api/health` |

---

## Error Handling

All commands return:
- **Exit code 0** = Success
- **Exit code 1** = Failure (check output for details)

**Common errors:**
- `[OFFLINE]` = LLM not running → use `tac-exec serve`
- `[NOT FOUND]` = File missing → check path or run scan
- `[FAILED TO START]` = Model failed → check `tac-exec --read mlogs`

---

## Tips for Hal

1. **Always check status first** before starting/stopping services
2. **Use `--json`** for programmatic parsing when available
3. **Use `--read`** for VS Code commands to get file content
4. **Gateway includes LLM** - `tac-exec so` auto-starts LLM if offline
5. **Logs are your friend** - `mlogs` for LLM, `le` for gateway

---

## Example: Full Diagnostic

```bash
# 1. Check LLM status
tac-exec model status --json | jq '.'

# 2. Check gateway status  
tac-exec so

# 3. Check model registry
tac-exec --read llmconf

# 4. Check LLM logs
tac-exec --read mlogs | tail -50

# 5. Check gateway logs
tac-exec le

# 6. Check OpenClaw config
tac-exec --read occonf | jq '.agents'
```

---

**Remember:** All commands are auto-approved - no approval prompts!
