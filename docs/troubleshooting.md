---
title: Troubleshooting
description: Common issues and solutions — stale dashboard data, context usage, gateway crashes, API key bridging, LLM offline, slow rendering, commit failures, sync hash mismatches, cooldown issues, and slow shell startup.
---

# Troubleshooting

## Dashboard shows stale or missing data

Run `oc-cache-clear` to wipe all `/dev/shm/tac_*` caches, then `m` again.
First render after clearing will show "Querying..." for some metrics while
background refreshes run.

## CONTEXT USED shows "No data"

The CONTEXT USED row reads token usage from the most recently active
OpenClaw agent session. It scans all `agents/*/sessions/sessions.json` files
for the newest session entry containing `totalTokens` and `contextTokens`.
"No data" means either:

1. No agent sessions have been created yet.
2. The session files exist but no session has non-zero `totalTokens`.

The numbers show: **used tokens | context window size** for the most recent
agent session (any agent, not just main/Hal). Values ≥ 1000 are displayed
in `k` notation (e.g., `51k of 128k`). The row turns red at ≥ 90% context
utilisation to warn that the agent conversation is nearing the model limit.

## `so` shows "CRASHED - CHECK LOGS"

1. Run `le` to see gateway startup errors from journalctl.
2. Common cause: missing API keys. Run `oc-refresh-keys` then `so` again.
3. Check the systemd service: `systemctl --user status openclaw-gateway.service`

## `ockeys` shows WSL ✗ for keys

API keys are bridged from Windows but haven't been exported in this shell.
Run `oc-refresh-keys`. If still failing, check `pwsh.exe` is accessible:
`command -v pwsh.exe` should return a path.

## LLM shows OFFLINE

1. Check if a model is running: `model status`
2. Start one: `model use 1` (or any model number from `model list`)
3. If it fails to boot, check `cat /dev/shm/llama-server.log`
4. Run `wake` first to prevent GPU WDDM sleep issues.

## Dashboard takes > 1 second to render

All telemetry functions use background subshells with `&>/dev/null &` to
detach from the calling command substitution. If the dashboard blocks, check
that every `( ... ) &` background refresh includes `&>/dev/null` before `&`
— without it, the `$()` capture waits for the child's inherited pipe FD.
The `typeperf.exe` call in `tac_hostmetrics.sh` takes ~4s cold, so it relies
on this pattern to return stale data instantly while refreshing in the
background.

## `commit` fails with "LLM URL is not localhost"

The `commit_auto` function blocks sending git diffs to non-local LLM
endpoints as a security measure. Ensure `LOCAL_LLM_URL` points to
`http://127.0.0.1:8081/v1/chat/completions`. It also verifies the
`llama-server` process is actually running (PID check) before sending.

## `oc-llm-sync.sh hash mismatch — skipped`

The startup sequence verifies the SHA256 hash of `oc-llm-sync.sh` before
sourcing it. If the file has been modified, sourcing is skipped for safety.
Run `oc-trust-sync` to record the current file's hash as trusted.

## `up` shows everything as CACHED

Each maintenance step has a cooldown (APT index: 24h, APT upgrade and others:
7d). Wait for the cooldown to expire, or delete
`~/.openclaw/maintenance_cooldowns.txt` to force all steps to run.

## Shell starts slowly

The only potentially slow operation at startup is `__bridge_windows_api_keys`
(calls `pwsh.exe` with 5s timeout). The key cache lasts 1 hour, so this only
runs once per hour. If `pwsh.exe` is unreachable, the timeout prevents a hang.

← [Back to README](../README.md)

# end of file
