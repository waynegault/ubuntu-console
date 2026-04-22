---
title: Hal Integration
---

# Hal Integration

> **Consolidated:** All Hal / AI agent access documentation has been merged into
> [HAL-COMMAND-CATALOG.md](HAL-COMMAND-CATALOG.md).

See [HAL-COMMAND-CATALOG.md](HAL-COMMAND-CATALOG.md) for:

- Setup and exec allowlist configuration
- All command categories with expected outputs
- JSON/plain output formats
- Common workflows and troubleshooting
- Security considerations and key file locations

← [Back to README](../README.md)

# end of file


## ✅ What's Configured

### 1. Command Access
- **Allowlist entry:** `tac-exec` in `~/.openclaw/exec-approvals.json`
- **Location:** `/home/wayne/ubuntu-console/bin/tac-exec` (canonical)
- **Symlink:** `~/.local/bin/tac-exec` → canonical path

### 2. Available Commands

Hal can now run **any** tactical console command via:
```
tac-exec <command> [args...]
```

**Key commands:**
| Category | Commands |
|----------|----------|
| Model Mgmt | `model status`, `model list`, `model use N`, `model stop` |
| Gateway | `so` (start), `xo` (stop) |
| LLM Control | `serve`, `halt` |
| Config | `llmconf`, `reload` |
| Logs | `mlogs`, `le` |
| Diagnostics | `model doctor`, `oc diag`, `oc health` |

### 3. Output Formats

**Human-readable (default):**
```
Active                                   #1 Deepseek-R1-Distill-Qwen-1.5B (1.0G)
Health                                                                        OK
Build                                                                  182acfe5c
```

**JSON (for programmatic use):**
```bash
tac-exec model status --json
# {"online":true,"port":8081,"active_num":"1",...}
```

**Plain (for scripting):**
```bash
tac-exec model status --plain
# online=1
# port=8081
# active_num=1
```

### 4. Documentation

| File | Purpose |
|------|---------|
| `~/ubuntu-console/docs/HAL-COMMAND-CATALOG.md` | Complete command reference |
| `~/ubuntu-console/skills/tactical-console/SKILL.md` | OpenClaw skill definition |
| `docs/HAL-INTEGRATION.md` | This file |

---

## 📋 Recommended Next Steps

### 1. Install Tactical Console Skill (Optional)

Copy the skill to OpenClaw's skills directory:

```bash
# Option A: Install to user skills
mkdir -p ~/.openclaw/skills
cp -r ~/ubuntu-console/skills/tactical-console ~/.openclaw/skills/

# Option B: Install to global skills (requires sudo)
sudo cp -r ~/ubuntu-console/skills/tactical-console \
  /home/linuxbrew/.linuxbrew/lib/node_modules/openclaw/skills/
```

Then enable:
```bash
openclaw skills enable tactical-console
```

**Benefit:** Hal will automatically discover and understand when to use tactical console commands.

### 2. Add More JSON Output

Commands that could benefit from `--json` flag:
- `model list --json`
- `so --json`
- `oc health --json`

This makes it easier for Hal to parse results programmatically.

### 3. Create Composite Commands

Common multi-step operations as single commands:

```bash
# Example: Full system restart
tac-exec oc-restart-all  # xo → wait → so

# Example: Model switch with health check
tac-exec model-switch-healthy 2  # use 2 → wait → status --json
```

### 4. Add Command Aliases for Hal

Create intuitive aliases:
```bash
# In ~/.bashrc or tactical-console.bashrc
alias llm-status='tac-exec model status'
alias llm-start='tac-exec serve'
alias llm-stop='tac-exec halt'
alias gateway-start='tac-exec so'
alias gateway-stop='tac-exec xo'
```

Then add to allowlist:
```json
{
  "id": "llm-commands",
  "pattern": "/usr/bin/tac-exec",
  ...
}
```

### 5. Create Health Check Endpoint

Add a dedicated health command for Hal to poll:

```bash
# tac-exec system-health
tac-exec model status --json | jq -c '{
  llm: (.online == "true"),
  llm_port: .port,
  model: .active_name,
  gateway: "check via oc health"
}'
```

---

## 🔧 Troubleshooting

### Hal can't run commands

1. Check allowlist:
   ```bash
   jq '.agents.main.allowlist[] | select(.pattern | contains("tac-exec"))' \
     ~/.openclaw/exec-approvals.json
   ```

2. Test manually:
   ```bash
   tac-exec model status
   ```

3. Checktac-exec path:
   ```bash
   which tac-exec
   # Should return: /home/wayne/.local/bin/tac-exec
   ```

### Commands fail silently

Check error log:
```bash
cat ~/.openclaw/bash-errors.log | tail -20
```

Common issues:
- Missing `|| true` on commands that might fail
- `set -e` causing early exit
- Functions not loaded (check `env.sh` sources all modules)

### Output not showing

Some commands buffer output. Try:
```bash
tac-exec model status 2>&1 | cat
```

---

## 📊 Usage Statistics

Track which commands Hal uses most:

```bash
# Add to tac-exec (optional logging)
echo "$(date +%s) $*" >> ~/.openclaw/tac-exec-history.log
```

Then analyze:
```bash
awk '{print $2}' ~/.openclaw/tac-exec-history.log | sort | uniq -c | sort -rn
```

---

## 🔐 Security Considerations

### Current Setup
- ✅ Single entry point (`tac-exec`)
- ✅ Allowlist-based approval
- ✅ No sudo access
- ✅ Commands logged in exec-approvals.json

### Additional Hardening (Optional)

1. **Command whitelist in tac-exec:**
   ```bash
   # Only allow specific commands
   allowed=("model" "so" "xo" "serve" "halt" "llmconf")
   if [[ ! " ${allowed[@]} " =~ " $1 " ]]; then
     echo "Command not allowed: $1"
     exit 1
   fi
   ```

2. **Rate limiting:**
   ```bash
   # Prevent command flooding
   last_cmd=$(tail -1 ~/.tac-exec-log 2>/dev/null | cut -d' ' -f1)
   now=$(date +%s)
   if (( now - last_cmd < 1 )); then
     sleep 1
   fi
   ```

3. **Audit logging:**
   ```bash
   # Log all Hal commands
   echo "$(date -Iseconds) hal $*" >> ~/.openclaw/hal-commands.log
   ```

---

## 🎯 Summary

**Status:** ✅ Complete

Hal can now:
- ✅ Run all tactical console commands
- ✅ Get structured output (JSON/plain)
- ✅ Access full LLM and gateway management
- ✅ View logs and diagnostics
- ✅ Edit configuration files

**Next:** Consider installing the tactical-console skill for better discovery.

---

**Last updated:** 2026-03-27  
**Profile version:** v3.65
