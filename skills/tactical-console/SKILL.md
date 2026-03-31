---
name: tactical-console
description: 'Use the Tactical Console for local LLM management, gateway control, and system diagnostics. Commands: model (list/use/status/stop), so/xo (gateway start/stop), serve/halt (LLM start/stop), llmconf (edit registry), mlogs (view logs), reload (refresh profile). All commands run via: tac-exec <command>'
metadata:
  {
    "openclaw":
      {
        "emoji": "⚡",
        "requires": { "bins": ["tac-exec"] },
        "install": [],
      },
  }
---

# Tactical Console (Local LLM & Gateway Management)

Use **tac-exec** to run tactical console commands for managing your local llama.cpp instance and OpenClaw gateway.

## Quick Reference

| Command | Description | Example |
|---------|-------------|---------|
| `tac-exec model status` | Show active model, health, TPS | Check if LLM is running |
| `tac-exec model list` | List all registered models | See available models |
| `tac-exec model use N` | Start model #N | `tac-exec model use 1` |
| `tac-exec model stop` | Stop running LLM | Halt current model |
| `tac-exec so` | Start OpenClaw gateway | Gateway + LLM if needed |
| `tac-exec xo` | Stop OpenClaw gateway | Clean shutdown |
| `tac-exec serve` | Start default LLM | Launch llama-server |
| `tac-exec halt` | Stop LLM | Kill llama-server |
| `tac-exec llmconf` | Edit models.conf | Open registry in VS Code |
| `tac-exec mlogs` | View LLM logs | Open llama-server.log |
| `tac-exec reload` | Reload shell profile | Refresh functions |

## Common Patterns

### Check System Status
```bash
# Quick health check
tac-exec model status
tac-exec so
```

### Switch Models
```bash
# List available, then switch
tac-exec model list
tac-exec model use 2
```

### Gateway Management
```bash
# Full restart
tac-exec xo
tac-exec so
```

### Diagnostics
```bash
# Check logs
tac-exec mlogs
tac-exec model doctor
```

## ⚠️ Rules

1. **Always use `tac-exec` prefix** - Commands are shell functions, not standalone binaries
2. **Check status first** - Run `tac-exec model status` before starting/stopping
3. **Gateway includes LLM** - `tac-exec so` auto-starts LLM if offline
4. **Port 8081 = LLM, Port 18789 = Gateway** - Use these for health checks
5. **Don't run in ~/.openclaw/** - LLM operations should target model directories

## Output Format

Commands use `__tac_info` format:
```
Local LLM    [RUNNING on PORT 8081]
Gateway      [RUNNING on PORT 18789]
```

Colors: Green = running, Red = offline/error, Yellow = warning

## Model Numbers

Models are numbered in registry (`~/.llm/models.conf`):
```
#  MODEL                          SIZE   QUANT    GPU
> 1  Deepseek-R1-Distill-Qwen-1.5B  1.0G   Q4_K_M   999
  2  Llama 3.2 3B Instruct          1.9G   Q4_K_M   999
```

Use the number for `tac-exec model use N`.

## When to Use

✅ **Use tactical-console when:**
- User asks to "start the LLM" or "check if model is running"
- Need to switch between models
- Gateway needs restart
- Checking system health/status
- Viewing LLM logs or config

❌ **Don't use when:**
- OpenClaw agent operations (use OpenClaw CLI directly)
- File editing (use coding agents or VS Code)
- Web browsing (use browser tools)

---
