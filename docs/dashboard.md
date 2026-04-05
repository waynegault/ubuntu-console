---
title: Dashboard
description: The Tactical Dashboard (m), Help (h), navigation commands, virtual environment auto-activation, and custom shell prompt — your daily driving interface.
---

# Dashboard & Shell Interface

## The Dashboard (`m`)

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

The dashboard colour-codes values at industry-standard thresholds:
- **Green:** < 75% utilisation
- **Yellow:** 75–90%
- **Red:** > 90%

## Help (`h`)

Type `h` to render the full command reference inside a box-drawn panel. Every
command documented here is also listed in the help index.

**OpenClaw-aware:** When OpenClaw is not installed, all OpenClaw-related
sections are hidden from the help display to reduce clutter.

## Navigation & Convenience

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

## Virtual Environment Auto-Activation

The `cd` command is overridden. When you enter a directory containing
`.venv/bin/activate`, it is automatically sourced. When you leave the project
directory tree, `deactivate` is called automatically. The dashboard shows
active venvs under the "CLOAKING" row.

**Error handling:** If venv activation fails, a warning is printed and
`VIRTUAL_ENV` is cleared to prevent confusion.

## Shell Prompt

The custom prompt shows:

```
username ▼ ✓ ~/projects/myapp (myenv) >
```

- **▼** — Present if user is in the `sudo` group (admin badge).
- **✓ / ×** — Green checkmark or red cross for last command exit status.
- **(myenv)** — Active Python virtual environment name.
- Empty-enter detection: pressing Enter with no command clears the error badge.

**Inter-prompt spacing:** A single blank line separates consecutive prompts.
This is achieved solely by PS1's leading `\n`. PS0 is intentionally unset —
using both PS0 and PS1 newlines would produce a double blank line after
commands that produce no output (e.g., `cd`).

← [Back to README](../README.md)

# end of file
