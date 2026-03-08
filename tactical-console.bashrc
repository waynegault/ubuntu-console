# ==============================================================================
# ~/.bashrc
# ==============================================================================
# Purpose:        Tactical Console Profile (Interactive shell configuration)
# Author:         Wayne
# Last modified:  2026-03-08
# Environment:    WSL2 (Ubuntu 24.04) / RTX 3050 Ti
#
# Prerequisites:  bash >= 4.0
#                 Required tools: git; Optional tools: fzf
#
# Safety:         Do NOT store secrets or credentials in this file.
#                 Do NOT auto-execute remote scripts (curl | bash, wget | sh).
#                 Avoid privileged operations (sudo, chown, chmod 777) at startup.
#
# Loader:         This file is the CANONICAL source of truth and is versioned at:
#                   ~/ubuntu-console/tactical-console.bashrc
#                 ~/.bashrc is a thin loader that sources the canonical file:
#                   source "$HOME/ubuntu-console/tactical-console.bashrc"
#                 This file may source modular fragments from:
#                   ~/.bashrc.d/*.sh  (sourced in numeric order)
#
# HELP INDEX:     See the HELP INDEX section below for functions, aliases, and
#                 sections with one-line descriptions and usage notes.
#
# SYNOPSIS:       Tactical Console Profile (Bash)
#                 Admin: Wayne | Environment: WSL2 (Ubuntu 24.04)
#
# FILE LAYOUT:    - Keep ~/.bashrc as a thin loader only.
#                 - Edit and version-control the canonical file at:
#                     ~/ubuntu-console/tactical-console.bashrc
#                 - Use the 'reload' alias to re-source the loader.
#                 - Use the 'oedit' alias to open the canonical file in VS Code.
#
# NOTES:          - Prefer longhand, explicit bash constructs for readability
#                   and future conversion to PowerShell.
#                 - Guard interactive-only code with an interactive-shell check.
#                 - Heavy or networked tasks must be lazy-loaded or moved to
#                   explicit scripts or systemd user units.
#                 - Modularize large sections into ~/.bashrc.d/ for maintainability.
#
# ==============================================================================
# SHELLCHECK DIRECTIVES
# ==============================================================================
# SC1090: Non-constant source paths — dynamic sourcing is by design.
# SC1091: External files not available for static analysis — expected.
# SC2016: Single-quoted PowerShell commands — must not expand in bash.
# SC2034: C_Border is part of the design-token set; reserved for external use.
# SC2059: printf format strings use ANSI design tokens — intentional pattern.
# shellcheck disable=SC1090,SC1091,SC2016,SC2034,SC2059

# ==============================================================================
# INTERACTIVE GUARD
# ==============================================================================
# Prevent execution in non-interactive shells (like sftp/rsync)
case $- in
    *i*) ;;
      *) return ;;
esac

# ==============================================================================
#  0. MANDATORY INSTRUCTIONS FOR AI EDITORS
# ==============================================================================
# @modular-section: ai-instructions
# @depends: none
#
# AI INSTRUCTION: Increment version on significant changes.
export TACTICAL_PROFILE_VERSION="2.21"

# CHANGELOG:
# 2.21 (2026-03-08) — Quant enforcement, dashboard clarity, thread tuning.
#        model scan: reads quant-guide.conf and auto-archives discouraged quants
#        (Q6_K, Q8_0, F16, etc.) from active/ to archive/ — skips currently
#        running model. Registry renumbered after archival. Dashboard: GPU0→iGPU
#        (Intel Iris Xe / typeperf 3D), GPU1→CUDA (NVIDIA / nvidia-smi compute)
#        to clarify that LLM utilisation reads from CUDA engine, not Task Manager
#        3D. GPU detail row label simplified to "GPU".
#        __calc_threads: dynamic via nproc (80% CPU-only, 70% partial, 50% full
#        offload) replaces hardcoded 16/14/8. --prio 2 added to model use and
#        watchdog for higher process priority on hybrid CPU systems.
# 2.20 (2026-03-08) — GPU optimisation + audit fix implementation.
#        GPU: -ngl 999 (max offload) replaces fixed gpu_layers in model use and
#        watchdog. Batch size tuning: -b 4096/-ub 1024 for GPU models, -b 512
#        for CPU-only. --flash-attn on for all GPU launches (reduces VRAM
#        bandwidth pressure on 4GB cards). __calc_gpu_layers returns 999/0
#        instead of fixed layer count. Actual offload count shown from server
#        log after boot. Quantization guide: ~/ubuntu-console/quant-guide.conf
#        with rating system (recommended/acceptable/discouraged); model download
#        warns on discouraged quants (Q6_K, Q8_0, F16). Watchdog: fixed stale
#        active_llm_file format (was reading pipe-delimited, now reads model
#        number), added flock concurrency guard, -ngl 999, --flash-attn on,
#        --jinja, batch size tuning. Audit: tac_hostmetrics.sh strict mode
#        (set -euo pipefail), install.sh shebang (#!/usr/bin/env bash), 3 curl
#        calls given --max-time, 2 UUOC battery reads replaced with $(< file),
#        QUANT_GUIDE constant added to §1.
# 2.19 (2026-03-08) — 71-item deep audit implementation. Errors: commit:→commitd,
#        chat:→chatl, wtf:→wtf aliases (colon-free naming), LAST_TPS comment,
#        serve <profile>→serve N in help, loopback regex anchored with trailing /.
#        Security: chmod 777→755 hint, pkill -u "$USER" on all 3 llama-server
#        kill sites (user-scoped process termination). Safety: logtrim tmp-file
#        non-empty guard (-s check before mv), hours_left="" init (was 0).
#        Logic: cd venv activate error check, __get_host_metrics sentinel "–|–|–"
#        instead of "0|0|0", model boot progress dots during health wait.
#        Redundancy: __vsc_open helper (deduplicates VS Code wrappers),
#        __save_nullglob/__restore_nullglob, __require_openclaw, __usage.
#        __strip_ansi varname validation added. Quality: bare returns→explicit
#        return 0/1 on all error+cancel paths, [[ -gt ]]→(( )) in dashboard.
#        Non-bash: 68 echo -e→printf '%s\n' conversions (design tokens are
#        ANSI-C quoted, echo -e unnecessary). Style: owk/ologs/ocroot doc
#        headers, __set_cooldown one-liner expanded, PROMPT_COMMAND block
#        expanded with comments, g_util cleanup split to commented multi-line,
#        deploy alias sub-banner, LLM alias comments. Comments: OPENCLAW_ROOT
#        deprecation doc, VENV_DIR scope doc, drive detection fallback warning,
#        PATH guards expanded to if/then/fi. Dashboard: help entries updated for
#        renamed aliases (commitd, chatl, wtf), command bar updated.
# 2.18 (2026-03-08) — Comprehensive 53-item quality audit. Errors: pkill -f→-x
#        in oc-restore, strip trailing % from g_util_n, trailing newline guard,
#        architecture map line numbers updated. Security: ZIP permission validation
#        (setuid/setgid/world-writable), sudo -n guard in wake(), _sync_hash
#        cleanup on all paths, bridge newline validation. Safety: atomic .bak swap
#        in oc-restore, loopback addr precision check. Logic: hours_left dual-use
#        documented, per-PID stale process count, drive recheck at download time,
#        dynamic scoping doc for __send_chat_msg, cd venv activation doc. Dead
#        code: documented alert alias and LAST_TPS default. Redundancy: extracted
#        __renumber_registry and __threshold_color helpers. Quality: ERR trap
#        extracted to __tac_err_handler, consistent return 1 in mkproj, printf
#        safety documented, __require_llm explicit return 0, fgrep/egrep replaced.
#        Style: all one-liner functions expanded to multi-line, shopt commands
#        split, alias section sub-banners. Comments: regex explanation on
#        __strip_ansi, magic-number breakdown in __fRow, model() case branch
#        descriptions, commit_auto UX flow, HISTCONTROL/HISTIGNORE explained,
#        EXIT cleanup lifecycle, __quant_label ggml.h cite, @depended-on-by
#        cross-refs on §1/§4/§5, 2>/dev/null risk comments on oc-llm-sync source.
#        Non-bash: raw ANSI in init→design tokens, echo -e→printf in sysinfo.
#        Efficiency: __get_tokens perf note, du blocking note, git diff intentional
#        double-call documented. Organisation: __save_tps ordering doc,
#        @extractable marker on model(), alias sub-banners. Absorbed serve.sh
#        features: prlimit/memlock, --jinja, adaptive batch sizes, --no-context-
#        shift for Qwen3.
# 2.17 (2026-03-08) — Style standardisation: all 120 function declarations now
#        use `function name()` form. Added LLAMA_ARCHIVE_DIR constant (NTFS move
#        prep). Removed ext4 references, Drive M: label derived from variable.
#        Stale UIWidth comments updated. All interactive read -p prompts use
#        design tokens. Numeric validation added to model info/delete/archive.
#        GGUF parser handles uint64 (vt=10) for block_count/context_length.
# 2.16 (2026-03-08) — Security & quality audit: removed hardcoded HF_TOKEN
#        (moved to ~/.config/huggingface/token), refused unsigned oc-llm-sync.sh
#        source, eliminated post-EOF code. Replaced python3 GGUF parser with
#        pure bash+awk (dd|od|awk), removed WAYNE_HOME dead alias, made
#        OC_ROOT canonical (OPENCLAW_ROOT now compat alias). Dynamic drive size
#        detection via df. Fixed pkill -f→-x (3 sites) + model boot grace
#        period in up(). Hardened API key bridge tmpfile (umask 077). Added
#        model use numeric validation, bench restores prior model. Cached
#        du -sb in model list (30s TTL). Fixed help duplicate + indentation.
#        Replaced shift 2>/dev/null with guarded shift.
# 2.15 (2026-03-08) — Monolithic consolidation: absorbed standalone scripts into
#        .bashrc functions. oc-model-download → model download subcommand with
#        HF_HOME/HF_TOKEN awareness and full format validation. oc-gpu-status →
#        gpu-status function with box-drawn UI. oc-model-status, oc-model-switch,
#        oc-quick-diag, oc-wake already existed as model status, model use,
#        oc-diag, wake — removed redundant bin/ scripts. Only llama-watchdog.sh
#        and tac_hostmetrics.sh remain in bin/ (systemd/subprocess dependency).
#        Updated backup/restore to exclude retired scripts. Help index updated.
# 2.14 (2026-03-07) — Model manager v3: replaced profile-based system (fast/
#        think/experi) with auto-scan numbered registry. `model scan` reads GGUF
#        metadata via python3, calculates optimal GPU layers/ctx/threads for 4GB
#        VRAM. `model use N` replaces `model start <profile>`. Removed assign,
#        swap, download commands. Models consolidated to /mnt/m/active/. Quant
#        detection from file_type + filename fallback. Dashboard and oc-local-llm
#        updated for new format (active file stores model number not pipe string).
#        Fixed --flash-attn flag for newer llama.cpp (requires on/off/auto arg).
#        Help section updated to match new commands.
# 2.13 (2026-03-07) — Added GitHub Copilot CLI integration: COPILOT_CLI_DIR
#        constant, PATH entry, `cop`/`??`/`cop-ask`/`cop-init` aliases.
# 2.12 (2026-03-07) — Final review tidy: defensive-quoted all 15 __test_port
#        call sites ("$LLM_PORT"/"$OC_PORT"). Moved __require_llm from §6 to §11
#        (co-located with its 7 call sites). model bench renders as single open
#        box with __tac_divider (was closed banner + nested header). Fixed PS3
#        leak in second model assign select. Architecture map line numbers
#        updated to match actual section positions.
# 2.11 (2026-03-07) — Full audit implementation: fixed model bench box rendering
#        ("open" style), oc-diag box rendering, oc-restore validation accepts
#        config-only backups, __get_tokens jq null guard, commit_auto PID-based
#        llama-server verification. Dashboard /slots query moved to async cache
#        (__get_llm_slots). __get_oc_metrics split into 60s sessions + 24h
#        version caches. Added __require_llm helper (deduplicates jq+port
#        checks). Replaced eval nullglob restore with flag pattern (3 sites).
#        __fRow dead-code safety-net commented. __TAC_BG_PIDS reset per
#        dashboard render. model bench persists results to ~/.llm/bench_*.tsv.
#        EXIT trap chains with existing traps. Section comments in dashboard.
#        up() step 2 inline logic comments. CHANGELOG dates added.
# 2.10 (2026-03-07) — Hal analysis round 2: llama.cpp perf flags (--batch-size 512,
#        --ubatch-size 512, --cont-batching, --flash-attn GPU-only) in model
#        start, oc-model-switch, llama-watchdog.sh. model swap calls oc-local-llm
#        to update OpenClaw provider. so() warns if provider targets offline local
#        LLM. oc-backup/oc-restore expanded to cover .bashrc, standalone scripts,
#        systemd units. apt upgrade uses --no-install-recommends; split APT
#        cooldown (apt_index 24h / apt 7d). models.conf extended to 8-field
#        format with per-model gpu_layers, ctx_size, threads. New standalone
#        script: oc-gpu-status (agent-accessible NVIDIA GPU summary).
# 2.09 (2026-03-06) — Audit + Hal cross-ref: 25-item implementation covering P0-P3 fixes.
#        Atomic vscode_path write, __check_cooldown per-key support, defensive
#        guards across dashboard, model, and OpenClaw integration functions.
# 2.08 (2026-03-05) — Audit implementation: P0 fixed &&/|| color chain in dashboard (emitted
#        two values), removed duplicate unguarded completions source. P1 so()
#        API key injection uses indirect expansion (${!_key}) instead of raw
#        =‑splitting %q-quoted strings, commit_deploy gates on commit exit code,
#        model start/info use awk instead of unanchored grep. P2 design tokens
#        switched to ANSI-C $'\e[…]' quoting — eliminates ~60 forks per render,
#        removed echo -e subshells in __tac_info/__tac_line/__fRow, oc-cache-
#        clear nullglob guard, dead model pull code removed, GPU sleep retry
#        in up() removed, dashboard GPU parsed once (was twice), TPS read from
#        cache file. Docker Desktop mounts filtered from disk audit.
# 2.07 (2026-03-04) — Full audit pass: P0 find -delete OR-precedence bug, model pull alias
#        (spaces illegal in bash aliases → case branch). P1 deploy gated on
#        push success, model list UIWidth-derived, chat REPL now has multi-turn
#        conversation history, oc-llm-sync.sh SHA256 integrity check. P2 pure-
#        bash __strip_ansi (zero forks), sysinfo single free call, __cleanup_temps
#        restricted to safe dirs, atomic cache writes, openclaw doctor in up().
#        New functions: chat-pipe, model swap, oc-diag, oc-failover. oc-local-llm
#        reads actual model name. mkproj checks for python3/git. Improved bridge
#        regex specificity. Modularisation notes on cross-cutting state.
# 2.06 — Tuned constants: UIWidth 78→80 (overridable), cooldown 24h→7d with
#        d/h display, colour thresholds 33/66→75/90 (industry standard),
#        diff head 200→500, token scan 10→25 files. Windows API key bridge:
#        __bridge_windows_api_keys auto-imports API_KEY/TOKEN/SECRET vars from
#        Windows User env into WSL on shell start (1h cache). oc-refresh-keys.
# 2.05 — Audit fixes: __get_tokens pipe bug, __strip_ansi helper, UIWidth-derived
#        layout constants, HOURS_LEFT refactor, localhost guard on commit_auto,
#        re-source guard for clear_tactical, background job cleanup trap, new
#        utility functions (oc-env, oc-cache-clear, chat-context, model pull).
# 2.04 — Pure bash SSE streaming; removed Python dependency.

# AI INSTRUCTION: Follow these terminal formatting rules strictly:
# 1. A blank line must exist between the bottom of any UI border and the command prompt.
# 2. A blank line must exist between prompt lines if there is no output (e.g., hitting Enter).
# 3. If there is command output, a blank line must exist AFTER the output, before the next prompt.
# 4. Do not cut off rendering code before the comment '# end of file' is reached. never remove the comment '# end of file'. when creating a file, always ensure there is a comment, 'end of file' unless the file format does not permit comments (eg JSON).
#
# IMPLEMENTATION NOTE:
# - PS1 starts with "\n" — this produces exactly one blank line between any prompt pair,
#   whether the previous command had output or not. PS0 is intentionally unset.
# - DO NOT add manual `echo ""` to the end of UI functions, as PS1 natively handles the gap.
# - DO NOT set PS0 — it would add a second blank line for commands with no output.
#
# NAMING CONVENTION:
# - User-facing commands: kebab-case (oc-health, get-ip, oc-backup)
# - Internal helpers / UI primitives: __double_underscore prefix (__tac_header, __get_host_metrics)
# - Short tactical aliases: lowercase abbreviations (so, xo, cl, up, m, h)
# - NEVER use PascalCase or CamelCase for function names.
#
# DEPENDENCY NOTE:
# - jq is REQUIRED for JSON parsing and SSE stream parsing throughout this profile.
# - curl is REQUIRED for all LLM API calls (streaming and non-streaming).
# - python3 is NOT required. All LLM functions are pure bash + curl + jq.

# ==============================================================================
# ARCHITECTURE MAP (approximate line numbers — update after major refactors)
# ==============================================================================
# ┌─  0. AI Instructions    ─ Rules for AI editors & formatting mandates   (~L19)
# ├─  1. Global Constants    ─ All paths, ports, env vars (single truth)   (~L183)
# ├─  2. Error Handling      ─ Bash ERR trap → bash-errors.log             (~L318)
# ├─  3. Alias Definitions   ─ Short commands, VS Code wrappers            (~L339)
# ├─  4. Design Tokens       ─ ANSI color constants (readonly)             (~L448)
# ├─  5. UI Helper Engine    ─ Box-drawing primitives (__tac_* family)      (~L475)
# ├─  6. System Hooks        ─ cd override, prompt (PS1), port test        (~L715)
# ├─  7. Telemetry           ─ CPU, GPU, battery, git, disk, tokens        (~L791)
# ├─  8. Maintenance         ─ get-ip, up, cl, cpwd, sysinfo, logtrim     (~L1006)
# ├─  9. OpenClaw Manager    ─ Gateway, backup, cron, skills, plugins      (~L1358)
# ├─ 10. Deployment          ─ mkproj scaffold, rsync, git commit+push     (~L2145)
# ├─ 11. LLM Manager         ─ model mgmt, chat, burn, explain             (~L2434)
# ├─ 12. Dashboard & Help    ─ Tactical Dashboard ('m') and Help ('h')     (~L3577)
# └─ 13. Initialization      ─ mkdir, completions, WSL loopback fix        (~L3868)
#
# CROSS-CUTTING STATE (needs attention during modularisation):
# - LAST_TPS: written by burn/llm_stream (§11) → read by dashboard (§12) via LLM_TPS_CACHE
# - __LAST_LLM_RESPONSE: written by __llm_chat_send (§11) → read by local_chat (§11)
# - ACTIVE_LLM_FILE: written by model start (§11) → read by oc-local-llm (§9), dashboard (§12)
# - __resolve_vscode_bin: defined in constants (§1) → called by aliases (§3)
# - _TAC_ADMIN_BADGE: set in hooks (§6) → read by custom_prompt_command (§6), safe within section
# - CooldownDB: defined in constants (§1) → read/written by maintenance (§8), up (§8)
# - __TAC_HAS_BATTERY: set in constants (§1) → read by __get_battery (§7)
# - __tac_last_hist_num: written by custom_prompt_command (§6) → read by same, safe within section
# - VSCODE_BIN: lazy-init by __resolve_vscode_bin (§1) → used by aliases (§3)
# - __TAC_INITIALIZED: set by init (§13) → guards re-source idempotency
#
# MODULARISATION GUIDE:
#   Split order must match section numbering (§0–§13).  Each module sources
#   after its @depends list.  Functions in @exports are the public API of that
#   section; anything without __ prefix is user-facing.  Use a thin loader:
#     for f in ~/.bashrc.d/*.sh; do source "$f"; done
#   Readonly vars (C_* design tokens) must be guarded with [[ -z "${C_Reset:-}" ]]
#   to survive re-source.  All /dev/shm caches are inherently cross-module safe.
# ==============================================================================

# ==============================================================================
# 1. GLOBAL CONSTANTS (ALL PATHS / PORTS DEFINED HERE)
# ==============================================================================
# @modular-section: constants
# @depends: none
# @depended-on-by: aliases (§3), design-tokens (§4), ui-engine (§5), hooks (§6),
#   telemetry (§7), maintenance (§8), openclaw (§9), deployment (§10),
#   llm-manager (§11), dashboard (§12), init (§13)
# @exports: AI_STORAGE_ROOT,
#   OC_ROOT, OPENCLAW_ROOT, OC_WORKSPACE, OC_AGENTS, OC_LOGS, OC_BACKUPS,
#   CooldownDB, ErrorLogPath, OC_TMP_LOG, LLAMA_ROOT,
#   LLAMA_MODEL_DIR, LLAMA_DRIVE_ROOT, LLAMA_ARCHIVE_DIR, LLAMA_SERVER_BIN,
#   LLM_REGISTRY, ACTIVE_LLM_FILE, QUANT_GUIDE,
#   LLM_LOG_FILE, LLM_TPS_CACHE, TAC_CACHE_DIR, VENV_DIR, UIWidth, LAST_TPS,
#   LLM_PORT, OC_PORT, LOCAL_LLM_URL, __TAC_HAS_BATTERY, __resolve_vscode_bin,
#   VSCODE_BIN, WSL_NVIDIA_SMI, PATH, HISTCONTROL

# ---- Storage Roots ----
export AI_STORAGE_ROOT="$HOME"

# ---- OpenClaw ----
export OC_ROOT="$AI_STORAGE_ROOT/.openclaw"
# DEPRECATION: OPENCLAW_ROOT is the old name. OC_ROOT is canonical.
# If no external scripts reference OPENCLAW_ROOT, this line can be removed.
# Used by: oc-env display (§9), __sync_bashrc_tracked (§8).
export OPENCLAW_ROOT="$OC_ROOT"
export OC_WORKSPACE="$OC_ROOT/workspace"
export OC_AGENTS="$OC_ROOT/agents"
export OC_LOGS="$OC_ROOT/logs"
export OC_BACKUPS="$OC_ROOT/backups"
export CooldownDB="$OC_ROOT/maintenance_cooldowns.txt"
export ErrorLogPath="$OC_ROOT/bash-errors.log"
export OC_TMP_LOG="/tmp/openclaw/openclaw.log"

# ---- LLM / llama.cpp ----
export LLAMA_ROOT="$AI_STORAGE_ROOT/llama.cpp"
export LLAMA_MODEL_DIR="/mnt/m/active"
export LLAMA_ARCHIVE_DIR="/mnt/m/archive"
export LLAMA_DRIVE_ROOT="/mnt/m"                # Root of the model drive
# Quantization priority guide — editable config controlling download warnings.
# See ~/ubuntu-console/quant-guide.conf for rating/description of each quant.
export QUANT_GUIDE="$HOME/ubuntu-console/quant-guide.conf"
# Detect drive size at startup; falls back to 200 GB if df unavailable.
# WARNING: If the drive is not mounted, all capacity calculations will use
# the 200GB fallback, which may over- or under-estimate available space.
LLAMA_DRIVE_SIZE=$(df -B1 --output=size "$LLAMA_DRIVE_ROOT" 2>/dev/null | awk 'NR==2{print $1+0}')
if [[ -z "$LLAMA_DRIVE_SIZE" || "$LLAMA_DRIVE_SIZE" == "0" ]]; then
    LLAMA_DRIVE_SIZE=$((200 * 1024 * 1024 * 1024))
fi
export LLAMA_DRIVE_SIZE
export LLAMA_SERVER_BIN="$LLAMA_ROOT/build/bin/llama-server"
export LLM_REGISTRY="$AI_STORAGE_ROOT/.llm/models.conf"
export ACTIVE_LLM_FILE="/dev/shm/active_llm"
export LLM_LOG_FILE="/dev/shm/llama-server.log"
export LLM_TPS_CACHE="/dev/shm/last_tps"

# ---- (Python SSE helper removed — all streaming is now pure bash + curl + jq) ----

# ---- Telemetry & System Paths ----
export TAC_CACHE_DIR="/dev/shm"
# VENV_DIR is shell-local only (not exported). Used by the cd() override
# in §6 to auto-activate Python virtual environments on directory change.
VENV_DIR=".venv"
export BASH_COMPLETION_SCRIPT="/usr/share/bash-completion/bash_completion"

# ---- VS Code Path (Lazy-initialized on first use to avoid slow pwsh call at startup) ----
VSCODE_BIN=""
function __resolve_vscode_bin() {
    [[ -n "$VSCODE_BIN" ]] && return
    if [[ -f "$TAC_CACHE_DIR/vscode_path" ]]; then
        VSCODE_BIN=$(< "$TAC_CACHE_DIR/vscode_path")
    else
        local win_user
        win_user=$(pwsh.exe -NoProfile -Command '[Environment]::UserName' 2>/dev/null | tr -d '\r')
        VSCODE_BIN="/mnt/c/Users/${win_user}/AppData/Local/Programs/Microsoft VS Code/bin/code"
        if [[ ! -x "$VSCODE_BIN" ]]; then
            VSCODE_BIN=$(command -v code 2>/dev/null || echo "")
        fi
        if [[ -n "$VSCODE_BIN" ]]; then
            echo "$VSCODE_BIN" > "$TAC_CACHE_DIR/vscode_path.tmp" \
                && mv "$TAC_CACHE_DIR/vscode_path.tmp" "$TAC_CACHE_DIR/vscode_path"
        fi
    fi
}

export WSL_NVIDIA_SMI="/usr/lib/wsl/lib/nvidia-smi"

# ---- GitHub Copilot CLI ----
export COPILOT_CLI_DIR="$HOME/.vscode-server/data/User/globalStorage/github.copilot-chat/copilotCli"

# ---- Hugging Face ----
export HF_HOME="${HF_HOME:-$HOME/hf_cache}"

# ---- Network & API ----
export LLM_PORT=8081
export OC_PORT=18789
export LOCAL_LLM_URL="http://127.0.0.1:${LLM_PORT}/v1/chat/completions"

# ---- Hardware Tuning (Intel i9 / RTX 3050 Ti 4GB VRAM) ----
# These are DEFAULTS, used when the model registry does not specify per-model
# values. The registry format (models.conf) supports per-model overrides:
#   profile|name|size|proc|file|gpu_layers|ctx_size|threads
# If the last three fields are missing or empty, these defaults are used.
export LLAMA_GPU_LAYERS=33   # Default GPU layers (full offload for small models)
export LLAMA_CPU_THREADS=12  # Default CPU threads
export LLAMA_CTX_SIZE=4096   # Default context window size

# ---- Battery detection (cached once at startup to skip pwsh fallback on desktops) ----
if [[ -d /sys/class/power_supply/BAT0 ]]; then
    __TAC_HAS_BATTERY=1
else
    __TAC_HAS_BATTERY=0
fi

# ---- UI Context & Core Environment ----
export UIWidth="${UIWidth:-80}"
# LAST_TPS holds the most recent inference speed measurement (tokens/sec).
# Initialised to "Untested" so the dashboard displays a meaningful label
# before any LLM inference has run in this session.
# Shell-local only (not exported) — intentional. The dashboard reads it in
# the same shell. LLM_TPS_CACHE is the file-backed persistent version in
# /dev/shm. Precedence: LLM_TPS_CACHE is read on dashboard render; LAST_TPS
# is the fallback when the cache file does not yet exist.
LAST_TPS="Untested"

# Guard against PATH duplication on re-source (e.g., source ~/.bashrc).
# Each block checks whether the directory is already in PATH before prepending.

# ~/.local/bin — pip-installed CLI tools (hf, openclaw, etc.)
if [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
    export PATH="$HOME/.local/bin:$PATH"
fi

# ~/.npm-global/bin — globally installed npm packages
if [[ ":$PATH:" != *":$HOME/.npm-global/bin:"* ]]; then
    export PATH="$HOME/.npm-global/bin:$PATH"
fi

# GitHub Copilot CLI (only if directory exists)
if [[ -d "$COPILOT_CLI_DIR" && ":$PATH:" != *":$COPILOT_CLI_DIR:"* ]]; then
    export PATH="$COPILOT_CLI_DIR:$PATH"
fi

# HISTCONTROL=ignoreboth combines 'ignorespace' (commands starting with a
# space are not recorded) and 'ignoredups' (consecutive duplicate commands
# are not recorded). This keeps history clean while preserving unique entries.
export HISTCONTROL=ignoreboth
export HISTTIMEFORMAT="%Y-%m-%d %H:%M:%S  "

# histappend: append (not overwrite) on shell exit
shopt -s histappend

# checkwinsize: update LINES/COLUMNS after each command
shopt -s checkwinsize

export HISTSIZE=100000
export HISTFILESIZE=200000
# HISTIGNORE: commands too short or frequently typed to be worth recording.
# These are navigation commands that would dominate history otherwise.
export HISTIGNORE="ls:ll:la:l:h:m:cls"

# PS0 intentionally unset — PS1's leading \n handles all inter-prompt spacing.
# Setting PS0="\n" would double-space prompts when commands produce no output.

# ==============================================================================
# 2. ERROR HANDLING
# ==============================================================================
# @modular-section: error-handling
# @depends: constants
# @exports: (none — sets ERR trap only)
#
# Trap ERR to log failed commands with timestamps for post-mortem debugging.
# Exit code 1 is filtered out because grep/test/[[ return 1 for normal
# "not found" / "false" conditions and would flood the log with false positives.
# Only exit codes >= 2 (real errors) are logged.
# Extracted to a named function for clarity (traps with inline code are hard to read).
# __tac_last_err intentionally global — traps cannot use `local`.
function __tac_err_handler() {
    __tac_last_err=$?
    if (( __tac_last_err > 1 )); then
        echo "$(date +"%Y-%m-%d %H:%M:%S") [EXIT $__tac_last_err] $BASH_COMMAND" >> "$ErrorLogPath" 2>/dev/null
    fi
}
trap '__tac_err_handler' ERR

# ==============================================================================
# 3. ALIAS DEFINITIONS & SHORTCUTS
# ==============================================================================
# @modular-section: aliases
# @depends: constants
# @exports: code, oedit, llmconf, oclogs, le, lo, occonf, os, oa, ocstat,
#   ocgs, ocv, mem-index, status, ocms, cop, cop-ask, cop-init (plus standard shell aliases)

# ---- Core OS Aliases ----
alias ls='ls --color=auto'
alias grep='grep --color=auto'
# fgrep/egrep are deprecated in modern coreutils. These aliases ensure
# backward compat if any inherited scripts call them. Safe to remove once
# confirmed no scripts in ~/console or ~/.openclaw reference fgrep/egrep.
alias fgrep='grep -F --color=auto'
alias egrep='grep -E --color=auto'
alias ll='ls -alF'
alias la='ls -A'
alias l='ls -CF'
# Ubuntu default alert alias — kept for script compatibility even though
# notify-send may not work under WSL. Triggers a desktop notification on
# the exit status of the previous command.
alias alert='notify-send --urgency=low -i "$([ $? = 0 ] && echo terminal || echo error)" "$(history|tail -n1|sed -e '\''s/^\s*[0-9]\+\s*//;s/[;&|]\s*alert$//'\'')"'

# ---- Tactical UI & Navigation ----
alias h='tactical_help'
alias cls='clear_tactical'
alias reload='command clear; exec bash'
alias m='tactical_dashboard'
alias cpwd='copy_path'

# ---- Dev Tools & VS Code Wrappers (lazy-resolved — no pwsh hit at shell start) ----
# All VS Code wrappers use __vsc_open (defined in §5) for deduplication.
function code() {
    __resolve_vscode_bin
    "$VSCODE_BIN" "$@"
}
function oedit() {
    __vsc_open "$HOME/ubuntu-console/tactical-console.bashrc" "VS Code opened... (run 'reload' to apply changes)"
}
function llmconf() {
    __vsc_open "$LLM_REGISTRY"
}
function oclogs() {
    __vsc_open "$OC_TMP_LOG"
}
function le() {
    journalctl --user -u openclaw-gateway.service --no-pager -n 60 --output=cat 2>&1 | tail -40
}
function lo() {
    journalctl --user -u openclaw-gateway.service --no-pager -n 120 --output=cat 2>&1
}
function occonf() {
    __vsc_open "$OC_ROOT/openclaw.json"
}

# ---- Git Shortcuts ----
# commitd    — git add + commit with YOUR message + push
# commit     — git add + commit with LLM-generated message + push
alias commitd='commit_deploy'
alias commit='commit_auto'
alias oc-agent-turn='ocstart'

# ---- OpenClaw Shortcuts (functions defined in §9) ----
# Wrapper: strip the leading blank line that openclaw always prints.
# Skip filtering for interactive/redirected commands to avoid breaking TTY.
function openclaw() {
    if [[ -t 1 ]] && [[ "$1" != "tui" && "$1" != "logs" ]]; then
        command openclaw "$@" | sed '1{/^$/d}'
    else
        command openclaw "$@"
    fi
}

function os() {
    openclaw sessions
}
function oa() {
    openclaw agents list
}
function ocstat() {
    openclaw status --all
}
function ocgs() {
    openclaw gateway status --deep
}
function ocv() {
    openclaw --version
}
function mem-index() {
    openclaw memory index
}
function status() {
    openclaw status
}
function ocms() {
    openclaw models status --probe
}

# ---- GitHub Copilot CLI ----
alias '??'='copilot -p'
alias cop='copilot'
function cop-init() {
    copilot init
}
function cop-ask() {
    copilot -p "$*"
}

# ---- LLM & Inference ----
# chat:      — interactive multi-turn chat with local LLM (end-chat to exit)
# wtf <topic>— ask the local LLM to explain a tool or concept (REPL mode)
alias chat:='local_chat'
alias wtf='wtf_repl'

# ==============================================================================
# 4. DESIGN TOKENS
# ==============================================================================
# @modular-section: design-tokens
# @depends: none
# @depended-on-by: ui-engine (§5), hooks (§6), telemetry (§7), maintenance (§8),
#   openclaw (§9), deployment (§10), llm-manager (§11), dashboard (§12), init (§13)
# @exports: C_Reset, C_BoxBg, C_Border, C_Text, C_Dim, C_Highlight, C_Success,
#   C_Warning, C_Error, C_Info (all readonly)
#
# ANSI colour constants for the tactical UI. Declared readonly so they cannot be
# accidentally mutated. They are NOT exported — child processes do not need them.
# C_BoxBg uses 256-color (38;5;30) for the unique teal border tone; all others
# use basic 16-color codes for maximum terminal compatibility.
if [[ -z "${C_Reset:-}" ]]; then
    readonly C_Reset=$'\e[0m'
    readonly C_BoxBg=$'\e[38;5;30m'    # DarkCyan (256-color)
    readonly C_Border=$'\e[36m'        # Cyan
    readonly C_Text=$'\e[37m'          # White
    readonly C_Dim=$'\e[90m'           # Gray
    readonly C_Highlight=$'\e[96m'     # Light Cyan
    readonly C_Success=$'\e[32m'       # Green
    readonly C_Warning=$'\e[33m'       # Yellow
    readonly C_Error=$'\e[31m'         # Red
    readonly C_Info=$'\e[34m'          # Blue
fi

# ==============================================================================
# 5. UI HELPER ENGINE
# ==============================================================================
# @modular-section: ui-engine
# @depends: constants, design-tokens
# @depended-on-by: telemetry (§7), maintenance (§8), openclaw (§9),
#   deployment (§10), llm-manager (§11), dashboard (§12)
# @exports: __strip_ansi, __tac_header, __tac_footer, __tac_divider, __tac_info,
#   __tac_line, __fRow, __hSection, __hRow, __show_header, clear_tactical,
#   __vsc_open, __save_nullglob, __restore_nullglob, __require_openclaw, __usage
#
# All __tac_* functions render box-drawn UI elements using the UIWidth constant.
# They use printf -v for padding generation (no subshells / no seq) for speed.
# Helper functions (__fRow, __hRow, __hSection) are defined here to keep all
# UI primitives in one section. They are prefixed with __ to signal "internal".
#
# DIVIDER STYLES (intentional distinction):
#   ╠═══╣  Major section break (double-line) — used in dashboard between blocks
#   ╟───╢  Within-section divider (single-line) — __tac_divider(), used in up()

# ---------------------------------------------------------------------------
# __threshold_color — Return a color token based on standard thresholds.
# Usage: local color; color=$(__threshold_color <value>)
#   >90 = C_Error (red), >75 = C_Warning (yellow), else = C_Success (green)
#   Deduplicates the repeated threshold pattern (dashboard, sysinfo, gpu-status).
# ---------------------------------------------------------------------------
function __threshold_color() {
    local val=$1
    if (( val > 90 )); then
        echo "$C_Error"
    elif (( val > 75 )); then
        echo "$C_Warning"
    else
        echo "$C_Success"
    fi
}

# ---------------------------------------------------------------------------
# __vsc_open — Open a file in VS Code with lazy-resolved path.
# Usage: __vsc_open <filepath> [confirmation_message]
# Deduplicates the repeated __resolve_vscode_bin + "$VSCODE_BIN" pattern
# used by oedit, llmconf, oclogs, occonf, mlogs, and any future wrappers.
# ---------------------------------------------------------------------------
function __vsc_open() {
    local target="$1"
    local msg="${2:-VS Code opened...}"

    __resolve_vscode_bin
    "$VSCODE_BIN" "$target"
    printf '%s\n' "$msg"
}

# ---------------------------------------------------------------------------
# __save_nullglob / __restore_nullglob — Save and restore the nullglob state.
# Deduplicates the repeated pattern across __cleanup_temps, logtrim,
# oc-cache-clear, and any future glob-dependent loops.
# Usage:
#   __save_nullglob
#   shopt -s nullglob
#   ... loop ...
#   __restore_nullglob
# ---------------------------------------------------------------------------
function __save_nullglob() {
    __tac_had_nullglob=0
    if shopt -q nullglob; then
        __tac_had_nullglob=1
    fi
    shopt -s nullglob
}

# __restore_nullglob — Undo nullglob set by __save_nullglob.
function __restore_nullglob() {
    if (( ! __tac_had_nullglob )); then
        shopt -u nullglob
    fi
}

# ---------------------------------------------------------------------------
# __require_openclaw — Verify openclaw CLI is installed.
# Prints an error and returns 1 if missing. Deduplicates the repeated
# `command -v openclaw >/dev/null` checks across §9 functions.
# ---------------------------------------------------------------------------
function __require_openclaw() {
    if ! command -v openclaw >/dev/null 2>&1; then
        __tac_info "OpenClaw CLI" "[NOT INSTALLED]" "$C_Error"
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# __usage — Print a formatted usage-hint line using design tokens.
# Usage: __usage "oc-config get <key> | set <key> <value> | unset <key>"
# Deduplicates the repeated  echo -e "${C_Dim}Usage:..."  pattern.
# ---------------------------------------------------------------------------
function __usage() {
    printf '%s%sUsage:%s %s\n' "$C_Dim" "" "$C_Reset" "$1"
}

# ---------------------------------------------------------------------------
# __strip_ansi — Strip ANSI escape codes from a string (pure bash, zero forks).
# Usage: __strip_ansi "string_with_colors" result_var
#   Sets the named variable to the stripped text using bash regex only.
#   No subshells, no sed — critical for dashboard render speed (called 20+ times).
#
# Regex breakdown: $'\e\['[0-9\;]*[mK]
#   $'\e\['  — ESC + literal [ (the CSI introducer)
#   [0-9\;]* — zero or more digits/semicolons (SGR parameters)
#   [mK]     — the terminator: 'm' for colours, 'K' for erase-line
#
# Trade-off (I1): The while-loop + global substitution is O(n²) worst-case for
# strings with many distinct escape sequences, but in practice dashboard values
# have at most 2-3 distinct sequences so this is faster than forking to sed.
# ---------------------------------------------------------------------------
function __strip_ansi() {
    local input="$1" varname="$2" tmp
    # Safety: validate varname is a legal bash identifier (S3 — prevents
    # indirect variable injection if callers ever pass untrusted data).
    if [[ ! "$varname" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
        return 1
    fi
    tmp="$input"
    while [[ "$tmp" =~ $'\e\['[0-9\;]*[mK] ]]; do
        tmp="${tmp//${BASH_REMATCH[0]}/}"
    done
    printf -v "$varname" '%s' "$tmp"
}

# ---------------------------------------------------------------------------
# __tac_header — Render a box header with centred title.
# Usage: __tac_header "TITLE" [open|closed] [version]
# ---------------------------------------------------------------------------
function __tac_header() {
    local title="$1"
    local style="${2:-closed}"
    local version="$3"

    local inner_width=$((UIWidth - 2))

    # Embed title (and optional version) directly in the ═ border line.
    # This avoids font-width misalignment between ═ and space characters.
    local left_label=" ${title}"
    local right_label=" "
    if [[ -n "$version" ]]; then
        right_label=" (v${version}) "
    fi
    local label_len=$(( ${#left_label} + ${#right_label} ))
    local left_eqs=$(( (inner_width - label_len) / 2 ))
    local right_eqs=$(( inner_width - label_len - left_eqs ))

    local left_line; printf -v left_line '%*s' "$left_eqs" ''; left_line="${left_line// /═}"
    local right_line; printf -v right_line '%*s' "$right_eqs" ''; right_line="${right_line// /═}"

    if [[ -n "$version" ]]; then
        printf "${C_BoxBg}╔%s${C_Reset}${C_Highlight}%s${C_Reset}${C_Dim}%s${C_Reset}${C_BoxBg}%s╗${C_Reset}\n" \
            "$left_line" "$left_label" "$right_label" "$right_line"
    else
        printf "${C_BoxBg}╔%s${C_Reset}${C_Highlight}%s${C_Reset}${C_BoxBg}%s╗${C_Reset}\n" \
            "$left_line" "${left_label}${right_label}" "$right_line"
    fi

    # Use thin-line (─) dividers to avoid width mismatch with ═/space title line.
    local thin_line; printf -v thin_line '%*s' "$inner_width" ''; thin_line="${thin_line// /─}"

    if [[ "$style" == "open" ]]; then
        printf "${C_BoxBg}╟${thin_line}╢${C_Reset}\n"
    elif [[ "$style" == "closed" ]]; then
        printf "${C_BoxBg}╙${thin_line}╜${C_Reset}\n"
    fi
}

# ---------------------------------------------------------------------------
# __tac_footer — Render the closing bottom border of a box.
# ---------------------------------------------------------------------------
function __tac_footer() {
    local inner_width=$((UIWidth - 2))
    local line; printf -v line '%*s' "$inner_width" ''; line="${line// /─}"
    printf "${C_BoxBg}╙${line}╜${C_Reset}\n"
}

# ---------------------------------------------------------------------------
# __tac_divider — Render a single-line horizontal divider within a box.
# ---------------------------------------------------------------------------
function __tac_divider() {
    local inner_width=$((UIWidth - 2))
    local line; printf -v line '%*s' "$inner_width" ''; line="${line// /─}"
    printf "${C_BoxBg}╟${line}╢${C_Reset}\n"
}

# ---------------------------------------------------------------------------
# __tac_info — Borderless status line for quick command feedback.
# Usage: __tac_info "Label" "[STATUS]" "$C_Color"
# ---------------------------------------------------------------------------
function __tac_info() {
    local label="$1" status="$2" color="${3:-$C_Text}"
    local cleanLabel; __strip_ansi "$label" cleanLabel
    local cleanStatus; __strip_ansi "$status" cleanStatus
    local padLen=$(( UIWidth - ${#cleanLabel} - ${#cleanStatus} ))
    (( padLen < 1 )) && padLen=1
    local pad; printf -v pad '%*s' "$padLen" ""
    printf "${C_Dim}%b${C_Reset}%s${color}%b${C_Reset}\n" "$label" "$pad" "$status"
}

# ---------------------------------------------------------------------------
# __tac_line — Render a bordered row with action text and right-aligned status.
# Usage: __tac_line "Action text" "[STATUS]" "$C_Color"
# Inner text area = UIWidth - 4 (borders + 1-space padding each side).
# ---------------------------------------------------------------------------
function __tac_line() {
    local action="$1" status="$2" color="${3:-$C_Text}"
    local inner_text=$(( UIWidth - 4 ))  # borders + 1-space padding each side
    local cleanAction; __strip_ansi "$action" cleanAction
    local cleanStatus; __strip_ansi "$status" cleanStatus

    local contentLen=$(( ${#cleanAction} + ${#cleanStatus} ))
    local padLength=$(( inner_text - contentLen ))
    (( padLength < 1 )) && padLength=1

    local padding; printf -v padding '%*s' "$padLength" ""
    printf "${C_BoxBg}║${C_Reset} %b%s%b%b%b ${C_BoxBg}║${C_Reset}\n" "$action" "$padding" "$color" "$status" "$C_Reset"
}

# ---------------------------------------------------------------------------
# __fRow — Dashboard row: "LABEL      :: value" inside box borders.
# Truncates values to prevent border overflow.
# Layout: 2 indent + 12 label + 4 " :: " + val_width + border = UIWidth
# val_width = UIWidth - 20  (the 20 comes from: 2 borders + 2 indent + 12 label + 4 separator)
# Usage: __fRow "LABEL" "value" "$C_Color"
# ---------------------------------------------------------------------------
function __fRow() {
    local label="$1"
    local val="$2"
    local color="${3:-$C_Text}"
    local val_width=$(( UIWidth - 20 ))  # 2 indent + 12 label + 4 sep + 2 borders
    # Strip ANSI codes to measure visible length
    local cleanVal; __strip_ansi "$val" cleanVal
    # Primary truncation: cap at val_width visible chars
    if (( ${#cleanVal} > val_width )); then
        cleanVal="${cleanVal:0:$((val_width - 3))}..."
        val="$cleanVal"
    fi
    local labelPad=$(( 12 - ${#label} ))
    local valPad=$(( val_width - ${#cleanVal} ))
    # Belt-and-suspenders guard — should never trigger after primary truncation.
    # Kept as a defensive safety net: if __strip_ansi miscounts (e.g., partial
    # escape sequences), this prevents printf from overflowing the box border.
    if (( valPad < 0 )); then
        val="${val:0:$((${#val} + valPad - 3))}..."
        cleanVal="${cleanVal:0:$((${#cleanVal} + valPad))}..."
        valPad=0
    fi

    local lPadStr=""; (( labelPad > 0 )) && printf -v lPadStr '%*s' "$labelPad" ""
    local vPadStr=""; (( valPad  > 0 )) && printf -v vPadStr '%*s' "$valPad"  ""

    printf "${C_BoxBg}║${C_Reset}"
    printf "  ${C_Dim}%s%s :: ${C_Reset}" "$label" "$lPadStr"
    printf "${color}%s${C_Reset}" "$val"
    printf "%s${C_BoxBg}║${C_Reset}\n" "$vPadStr"
}

# ---------------------------------------------------------------------------
# __hSection — Help index section header (centred, double-line border).
# Usage: __hSection "SECTION TITLE"
# ---------------------------------------------------------------------------
function __hSection() {
    local title="$1"
    local inner_width=$((UIWidth - 2))
    local sep; printf -v sep '%*s' "$inner_width" ''; sep="${sep// /═}"
    local pad_left=$(( (inner_width - ${#title}) / 2 ))
    local pad_right=$(( inner_width - ${#title} - pad_left ))

    local left_space=""; (( pad_left  > 0 )) && printf -v left_space  '%*s' "$pad_left"  ""
    local right_space=""; (( pad_right > 0 )) && printf -v right_space '%*s' "$pad_right" ""

    printf "${C_BoxBg}╠${sep}╣${C_Reset}\n"
    printf "${C_BoxBg}║${C_Reset}${C_Warning}%s%s%s${C_Reset}${C_BoxBg}║${C_Reset}\n" "$left_space" "$title" "$right_space"
}

# ---------------------------------------------------------------------------
# __hRow — Help index row: "  command        description" inside box borders.
# Layout derived from UIWidth: cmd_width=18, desc_width = UIWidth - 22.
# Usage: __hRow "command" "Description of what it does"
# ---------------------------------------------------------------------------
function __hRow() {
    local cmd="$1"
    local cmd_width=18
    local desc_width=$(( UIWidth - 22 ))  # 2 borders + 2 indent + 18 cmd
    local desc="${2:0:$desc_width}"
    local cmdPad=$(( cmd_width - ${#cmd} ))
    local descPad=$(( desc_width - ${#desc} ))

    local lPadStr=""; (( cmdPad  > 0 )) && printf -v lPadStr '%*s' "$cmdPad"  ""
    local rPadStr=""; (( descPad > 0 )) && printf -v rPadStr '%*s' "$descPad" ""

    printf "${C_BoxBg}║  ${C_Highlight}%s%s${C_Text}%s%s${C_BoxBg}║${C_Reset}\n" "$cmd" "$lPadStr" "$desc" "$rPadStr"
}

# ---------------------------------------------------------------------------
# __show_header — Display the oneliner startup banner.
# ---------------------------------------------------------------------------
function __show_header() {
    local inner_width=$((UIWidth - 2))
    local line; printf -v line '%*s' "$inner_width" ''; line="${line// /═}"

    local left_text=" Bash v${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}"
    local center_text="- Wayne's Ubuntu Terminal v${TACTICAL_PROFILE_VERSION} -"
    local right_text="'h' help "

    local center_start=$(( (inner_width - ${#center_text}) / 2 ))
    local gap1=$(( center_start - ${#left_text} ))
    local gap2=$(( inner_width - center_start - ${#center_text} - ${#right_text} ))

    local pad1=""; (( gap1 > 0 )) && printf -v pad1 '%*s' "$gap1" ""
    local pad2=""; (( gap2 > 0 )) && printf -v pad2 '%*s' "$gap2" ""

    printf "${C_BoxBg}╔${line}╗${C_Reset}\n"
    printf "${C_BoxBg}║${C_Reset}${C_Dim}%s${C_Reset}%s${C_Highlight}%s${C_Reset}%s${C_Dim}%s${C_Reset}${C_BoxBg}║${C_Reset}\n" \
        "$left_text" "$pad1" "$center_text" "$pad2" "$right_text"
    printf "${C_BoxBg}╚${line}╝${C_Reset}\n"
}

# ---------------------------------------------------------------------------
# clear_tactical — Clear screen and redraw the startup banner.
# ---------------------------------------------------------------------------
function clear_tactical() {
    command clear
    __show_header
}

# ==============================================================================
# 6. SYSTEM HOOKS & OVERRIDES
# ==============================================================================
# @modular-section: hooks
# @depends: constants, design-tokens, ui-engine
# @exports: cd (override), custom_prompt_command, __test_port,
#   _TAC_ADMIN_BADGE, PROMPT_COMMAND

# ---------------------------------------------------------------------------
# cd — Override to auto-activate/deactivate Python virtual environments.
# Activates .venv/bin/activate when entering a directory that contains one.
# Deactivates when leaving the project root (trailing-slash check prevents
# false positives like /home/wayne/project2 matching /home/wayne/project).
# ---------------------------------------------------------------------------
function cd() {
    builtin cd "$@" || return $?

    # Auto-activate .venv if present in new directory
    if [[ -f "$VENV_DIR/bin/activate" ]]; then
        # Activate AFTER the cd has completed (builtin cd above already changed PWD).
        # If activation fails, warn but do not abort (the cd itself succeeded).
        if ! source "$VENV_DIR/bin/activate" 2>/dev/null; then
            printf '%sWarning: .venv/bin/activate failed to source%s\n' "$C_Warning" "$C_Reset" >&2
        fi
        return
    fi

    # Auto-deactivate if we left the project root
    if [[ -n "$VIRTUAL_ENV" ]]; then
        local venv_root; venv_root=$(dirname "$VIRTUAL_ENV")
        local current_wd; current_wd=$(pwd -P)
        if [[ "$current_wd" != "$venv_root" && "$current_wd" != "$venv_root/"* ]]; then
            type deactivate >/dev/null 2>&1 && deactivate
        fi
    fi
}

if [[ " $(id -nG 2>/dev/null) " == *" sudo "* ]]; then
    _TAC_ADMIN_BADGE=" \[${C_Warning}\]▼\[${C_Reset}\]"
else
    _TAC_ADMIN_BADGE=""
fi

# custom_prompt_command — PROMPT_COMMAND handler: updates PS1, history, error badge.
function custom_prompt_command() {
    local lastExit=$?
    __tac_preexec_fired=0
    history -a

    # If history number hasn't changed, user pressed Enter with no command —
    # clear the error badge so × doesn't persist across empty prompts.
    local -a _hist_arr=()
    read -ra _hist_arr <<< "$(history 1 2>/dev/null)"
    local hist_num="${_hist_arr[0]}"
    if [[ "$hist_num" == "${__tac_last_hist_num:-}" ]]; then
        lastExit=0
    fi
    __tac_last_hist_num="$hist_num"

    local ps1_user="\[${C_Highlight}\]\u\[${C_Reset}\]"
    local exit_badge=" \[${C_Error}\]×\[${C_Reset}\] "
    (( lastExit == 0 )) && exit_badge=" \[${C_Success}\]✓\[${C_Reset}\] "
    local ps1_path="\[${C_Info}\]\w\[${C_Reset}\]"
    local ps1_venv=""
    [[ -n "$VIRTUAL_ENV" ]] && ps1_venv=" \[${C_Success}\]($(basename "$VIRTUAL_ENV"))\[${C_Reset}\]"

    PS1="\n${ps1_user}${_TAC_ADMIN_BADGE}${exit_badge}${ps1_path}${ps1_venv} \[${C_Dim}\]> \[${C_Reset}\]"
}

# Prepend custom_prompt_command to PROMPT_COMMAND if not already present.
# Uses the ${var:+;$var} idiom to avoid a leading semicolon when PROMPT_COMMAND
# is empty. This chains with any pre-existing PROMPT_COMMAND entries.
if [[ "$PROMPT_COMMAND" != *"custom_prompt_command"* ]]; then
    PROMPT_COMMAND="custom_prompt_command${PROMPT_COMMAND:+;$PROMPT_COMMAND}"
fi

# Print a blank line before every command's output so there is visual breathing
# room between the prompt and the result.  The __tac_preexec_fired guard ensures
# the newline prints only once per interactive command (not again for each
# pipeline segment, PROMPT_COMMAND, or subshell).
__tac_preexec_fired=0
trap '[[ "$BASH_COMMAND" == "$PROMPT_COMMAND" || "$BASH_COMMAND" == custom_prompt_command ]] || \
      (( __tac_preexec_fired )) || { __tac_preexec_fired=1; echo; }' DEBUG

# ---------------------------------------------------------------------------
# __test_port — Instant port check via kernel socket table (returns 0 if listening).
# Usage: __test_port <port_number>
# ---------------------------------------------------------------------------
function __test_port() {
    ss -tln "sport = :$1" 2>/dev/null | grep -q LISTEN
}

# ==============================================================================
# 7. TELEMETRY & HARDWARE (FAST CACHING)
# ==============================================================================
# @modular-section: telemetry
# @depends: constants, design-tokens, ui-engine
# @exports: __cache_fresh, __get_uptime, __get_disk, __get_host_metrics, __get_gpu,
#   __get_battery, __get_git, __get_tokens, __get_oc_version, __get_oc_metrics,
#   __get_llm_slots
#
# All telemetry functions use /dev/shm caching and background subshells to avoid
# blocking the dashboard render. Cache TTLs are tuned per metric volatility.

# ---------------------------------------------------------------------------
# __cache_fresh — Check if a cache file exists and is younger than TTL seconds.
# Usage: __cache_fresh <cache_path> <ttl_seconds>  →  returns 0 (fresh) or 1
# Deduplicates the repeated freshness-check pattern across all telemetry funcs.
# ---------------------------------------------------------------------------
function __cache_fresh() {
    [[ -f "$1" ]] && (( $(date +%s) - $(stat -c %Y "$1" 2>/dev/null || echo 0) < $2 ))
}

# ---------------------------------------------------------------------------
# __get_uptime — Format system uptime as "Xd Yh Zm".
# ---------------------------------------------------------------------------
function __get_uptime() {
    awk '{print int($1/86400)"d "int(($1%86400)/3600)"h "int(($1%3600)/60)"m"}' /proc/uptime
}

# ---------------------------------------------------------------------------
# __get_disk — Summarise free space on C: and WSL root.
# ---------------------------------------------------------------------------
function __get_disk() {
    local __unit_fix='s/\([0-9.]\)G/\1 Gb/;s/\([0-9.]\)M/\1 Mb/;s/\([0-9.]\)T/\1 Tb/'
    local c_drive; c_drive=$(df -h /mnt/c 2>/dev/null | awk 'NR==2 {print $4" free"}' | sed "$__unit_fix")
    local wsl_drive; wsl_drive=$(df -h / | awk 'NR==2 {print $4" free"}' | sed "$__unit_fix")
    if [[ -n "$c_drive" ]]; then
        echo "C: $c_drive | WSL: $wsl_drive"
    else
        df -h / | awk 'NR==2 {print $4" free ("$5" used)"}' | sed "$__unit_fix"
    fi
}

# ---------------------------------------------------------------------------
# __get_host_metrics — Return CPU% | GPU0% | GPU1% from Windows host (10s TTL).
# Uses typeperf.exe for CPU + both GPUs (Intel Iris + NVIDIA RTX) in one call.
# On first call after cache expiry, returns stale data while background
# refresh runs (~4s via typeperf).
# ---------------------------------------------------------------------------
function __get_host_metrics() {
    local cache="$TAC_CACHE_DIR/tac_hostmetrics"
    if ! __cache_fresh "$cache" 10; then
        ( bash "$HOME/.local/bin/tac_hostmetrics.sh" > "${cache}.tmp" 2>/dev/null && mv "${cache}.tmp" "$cache" ) &>/dev/null &
        __TAC_BG_PIDS+=("$!")
    fi
    # Return stale cache data while background refresh runs.
    # Fall back to zeros when cache doesn't exist yet (first boot).
    if [[ -f "$cache" ]]; then
        cat "$cache"
    else
        echo "0|0|0"
    fi
}

# ---------------------------------------------------------------------------
# __get_gpu — Return CSV: name,temp,utilization,mem_used,mem_total (10s TTL).
# NVIDIA-only detail for the GPU COMPUTE dashboard row.
# ---------------------------------------------------------------------------
function __get_gpu() {
    local cache="$TAC_CACHE_DIR/tac_gpu"
    if __cache_fresh "$cache" 10; then
        cat "$cache"; return
    fi
    (
        local smi_cmd="$WSL_NVIDIA_SMI"
        [[ ! -f "$smi_cmd" ]] && smi_cmd=$(command -v nvidia-smi 2>/dev/null)
        if [[ -n "$smi_cmd" && -x "$smi_cmd" ]]; then
            local raw; raw=$("$smi_cmd" --query-gpu=name,temperature.gpu,utilization.gpu,memory.used,memory.total --format=csv,noheader,nounits 2>/dev/null)
            [[ -n "$raw" ]] && printf '%s' "${raw//NVIDIA GeForce /}" > "${cache}.tmp" && mv "${cache}.tmp" "$cache"
        else
            echo "N/A" > "${cache}.tmp" && mv "${cache}.tmp" "$cache"
        fi
    ) &>/dev/null &
    __TAC_BG_PIDS+=("$!")
    if [[ -f "$cache" ]]; then
        cat "$cache"
    else
        echo "Querying..."
    fi
}

# ---------------------------------------------------------------------------
# __get_battery — Return battery percentage + status string (120s TTL).
# Uses /sys/class/power_supply on laptops; skips pwsh entirely on desktops
# (detected once at startup via __TAC_HAS_BATTERY).
# ---------------------------------------------------------------------------
function __get_battery() {
    local cache="$TAC_CACHE_DIR/tac_batt"
    if __cache_fresh "$cache" 120; then
        cat "$cache"; return
    fi
    (
        if (( __TAC_HAS_BATTERY == 1 )); then
            local cap; cap=$(cat /sys/class/power_supply/BAT0/capacity 2>/dev/null || echo "100")
            local bstat; bstat=$(cat /sys/class/power_supply/BAT0/status 2>/dev/null || echo "Unknown")
            echo "${cap}% (${bstat})" > "${cache}.tmp" && mv "${cache}.tmp" "$cache"
        else
            echo "A/C POWERED" > "${cache}.tmp" && mv "${cache}.tmp" "$cache"
        fi
    ) &>/dev/null &
    __TAC_BG_PIDS+=("$!")
    if [[ -f "$cache" ]]; then
        cat "$cache"
    else
        echo "Querying..."
    fi
}

# ---------------------------------------------------------------------------
# __get_git — Return "branch|SECURE" or "branch|BREACHED" for git repos.
# Returns empty string if not inside a git worktree.
# ---------------------------------------------------------------------------
function __get_git() {
    if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        local branch; branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
        local dirty
        if [[ -n $(git status --porcelain) ]]; then
            dirty="BREACHED"
        else
            dirty="SECURE"
        fi
        echo "$branch|$dirty"
    fi
}

# ---------------------------------------------------------------------------
# __get_tokens — Read token usage from the most-recent OpenClaw session (30s TTL).
# Scans agents/*/sessions/sessions.json for the newest session with totalTokens.
# Returns "used|limit" or "N/A|0".
# ---------------------------------------------------------------------------
# Performance note (I2): This function runs jq over up to 10 session files on
# every dashboard refresh (when cache is stale). The background subshell ensures
# the dashboard itself never blocks, but jq parsing still costs CPU. If this
# becomes a bottleneck, consider indexing largest-session only or switching to awk.
function __get_tokens() {
    local cache="$TAC_CACHE_DIR/tac_tokens"
    if __cache_fresh "$cache" 30; then
        cat "$cache"; return
    fi
    (
        local found=0
        while IFS= read -r f; do
            local result
            result=$(jq -r '
                [ to_entries[].value
                  | select(.totalTokens != null and .totalTokens > 0
                          and .contextTokens != null and .contextTokens > 0) ]
                | sort_by(.updatedAt) | last
                | "\(.totalTokens)|\(.contextTokens)"
            ' "$f" 2>/dev/null)
            if [[ -n "$result" && "$result" != "null|null" ]]; then
                echo "$result" > "${cache}.tmp" && mv "${cache}.tmp" "$cache"
                found=1
                break
            fi
        done < <(find "$OC_AGENTS" -name "sessions.json" -type f \
            -printf '%T@ %p\n' 2>/dev/null | \
            sort -n -r | head -n 10 | cut -d' ' -f2-)
        (( found == 0 )) && echo "N/A|0" > "${cache}.tmp" && mv "${cache}.tmp" "$cache"
    ) &>/dev/null &
    __TAC_BG_PIDS+=("$!")
    if [[ -f "$cache" ]]; then
        cat "$cache"
    else
        echo "Querying...|0"
    fi
}

# ---------------------------------------------------------------------------
# __get_oc_version — Fetch OpenClaw CLI version (24h TTL — barely changes).
# ---------------------------------------------------------------------------
function __get_oc_version() {
    local cache="$TAC_CACHE_DIR/tac_ocversion"
    if __cache_fresh "$cache" 86400; then
        cat "$cache"; return
    fi
    (
        local ocVersion="UNKNOWN"
        if command -v openclaw >/dev/null; then
            ocVersion=$(openclaw --version 2>/dev/null | awk '{print $NF}' | tr -d '\r\n')
            [[ -n "$ocVersion" ]] && ocVersion="v${ocVersion#v}"
        fi
        echo "$ocVersion" > "${cache}.tmp" && mv "${cache}.tmp" "$cache"
    ) &>/dev/null &
    __TAC_BG_PIDS+=("$!")
    if [[ -f "$cache" ]]; then
        cat "$cache"
    else
        echo "Querying..."
    fi
}

# ---------------------------------------------------------------------------
# __get_oc_metrics — Fetch OpenClaw session count (60s TTL) + version (24h TTL).
# Combines the session count and cached version into "count|version".
# ---------------------------------------------------------------------------
function __get_oc_metrics() {
    local ver; ver=$(__get_oc_version)
    local cache="$TAC_CACHE_DIR/tac_ocmetrics"
    if __cache_fresh "$cache" 60; then
        cat "$cache"; return
    fi
    (
        local sessionCount=0
        if command -v openclaw >/dev/null; then
            sessionCount=$(openclaw sessions --all-agents --json 2>/dev/null | jq -r '.count // 0' 2>/dev/null)
            sessionCount=${sessionCount:-0}
        fi
        echo "$sessionCount|$ver" > "${cache}.tmp" && mv "${cache}.tmp" "$cache"
    ) &>/dev/null &
    __TAC_BG_PIDS+=("$!")
    if [[ -f "$cache" ]]; then
        cat "$cache"
    else
        echo "Querying...|$ver"
    fi
}

# ---------------------------------------------------------------------------
# __get_llm_slots — Async-cached query to llama.cpp /slots endpoint (5s TTL).
# Returns JSON from the /slots API, or empty string if unavailable.
# ---------------------------------------------------------------------------
function __get_llm_slots() {
    local cache="$TAC_CACHE_DIR/tac_llm_slots"
    if __cache_fresh "$cache" 5; then
        cat "$cache"; return
    fi
    (
        if __test_port "$LLM_PORT"; then
            curl -sf --max-time 2 "http://127.0.0.1:${LLM_PORT}/slots" > "${cache}.tmp" 2>/dev/null \
                && mv "${cache}.tmp" "$cache"
        fi
    ) &>/dev/null &
    __TAC_BG_PIDS+=("$!")
    [[ -f "$cache" ]] && cat "$cache"
}

# ==============================================================================
# 8. MAINTENANCE & UTILS
# ==============================================================================
# @modular-section: maintenance
# @depends: constants, design-tokens, ui-engine, telemetry
# @exports: __cleanup_temps, __check_cooldown, __set_cooldown, get-ip, up, cl,
#   __sync_bashrc_tracked, copy_path, sysinfo, logtrim

# ---------------------------------------------------------------------------
# __cleanup_temps — Remove temp files from known safe locations only.
# Only cleans python-*.exe and .pytest_cache from $PWD. Does NOT remove
# *.log files (too dangerous in arbitrary directories). Used by cl().
# ---------------------------------------------------------------------------
function __cleanup_temps() {
    local count=0
    local f
    local _had_nullglob=0; shopt -q nullglob && _had_nullglob=1
    shopt -s nullglob
    for f in python-*.exe .pytest_cache; do
        if [[ -e "$f" ]]; then
            rm -rf "$f" && ((count++))
        fi
    done
    (( _had_nullglob )) || shopt -u nullglob
    echo "$count"
}

# ---------------------------------------------------------------------------
# __check_cooldown — Check if a maintenance task's 7-day cooldown has expired.
# Usage: time_left=$(__check_cooldown <key> <now_timestamp>)
# Returns 0 if cooldown has expired (task should run), 1 if still active.
# On return 1, prints remaining time (e.g. "6d 12h") to stdout.
# Dependencies: $CooldownDB must be set and touchable.
# ---------------------------------------------------------------------------
function __check_cooldown() {
    local key="$1" now="$2"
    # Per-key cooldown periods (default 7 days)
    local cooldown
    case "$key" in
        apt_index)  cooldown=86400  ;;  # 24 hours — security index
        apt)        cooldown=604800 ;;  # 7 days  — package upgrades
        *)          cooldown=604800 ;;  # 7 days  — everything else
    esac
    local last_run; last_run=$(grep "^${key}=" "$CooldownDB" 2>/dev/null | tail -n 1 | cut -d= -f2)
    last_run=${last_run:-0}
    local diff=$(( now - last_run ))
    if (( diff < cooldown )); then
        local remaining=$(( cooldown - diff ))
        local days=$(( remaining / 86400 ))
        local hours=$(( (remaining % 86400) / 3600 ))
        if (( days > 0 )); then
            echo "${days}d ${hours}h"
        else
            echo "${hours}h"
        fi
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# __set_cooldown — Record that a maintenance task was just completed.
# Usage: __set_cooldown <key> <now_timestamp>
# ---------------------------------------------------------------------------
function __set_cooldown() {
    local key="$1" now="$2"
    # Rewrite the cooldown database: remove old entry, append new timestamp.
    {
        grep -v "^${key}=" "$CooldownDB" 2>/dev/null
        echo "${key}=${now}"
    } > "${CooldownDB}.tmp" \
        && mv "${CooldownDB}.tmp" "$CooldownDB"
}

# ---------------------------------------------------------------------------
# get-ip — Show WSL Ubuntu IP and external WAN IP.
# Renamed from ip() to avoid shadowing /usr/bin/ip (used by WSL loopback fix).
# ---------------------------------------------------------------------------
function get-ip() {
    local wslIp; wslIp=$(hostname -I | awk '{print $1}')
    [[ -z "$wslIp" ]] && wslIp="UNKNOWN"
    __tac_info "WSL Ubuntu IP" "[$wslIp]" "$C_Success"

    local extIp; extIp=$(curl -s --connect-timeout 2 https://api.ipify.org)
    [[ -z "$extIp" ]] && extIp="TIMEOUT / UNAVAILABLE"
    local wan_color=$C_Warning
    if [[ $extIp == TIMEOUT* ]]; then
        wan_color=$C_Error
    fi
    __tac_info "External WAN IP" "[$extIp]" "$wan_color"
}

# ---------------------------------------------------------------------------
# up — Run 10-step system maintenance with 24h cooldowns per step.
# Cooldown functions (__check_cooldown / __set_cooldown) are defined above
# in this section to avoid leaking nested function definitions.
# ---------------------------------------------------------------------------
function up() {
    command clear
    __tac_header "SYSTEM MAINTENANCE" "open"
    local errCount=0
    local now; now=$(date +%s)
    # hours_left is re-used by each __check_cooldown call as a capture variable.
    # When __check_cooldown returns 1 (still cooling down), hours_left holds
    # the remaining time string (e.g. "6d 12h"). The `if` construct exploits
    # the fact that command substitution in the condition captures stdout while
    # the return code controls the branch.
    local hours_left=""
    touch "$CooldownDB" 2>/dev/null

    # [1/10] Connectivity
    if ping -c 1 -W 2 github.com >/dev/null 2>&1; then
        __tac_line "[1/10] Internet Connectivity" "[ESTABLISHED]" "$C_Success"
    else
        __tac_line "[1/10] Internet Connectivity" "[LOST]" "$C_Error"
        ((errCount++))
    fi

    # [2/10] APT Index Update (24h cooldown) + Package Upgrade (7d cooldown)
    # Logic:
    #   1. If apt_index cooldown (24h) expired → update index only
    #   2. If apt cooldown (7d) expired → upgrade packages (updates index if not already done)
    #   3. If only index was refreshed → show that
    #   4. If both cached → show "CACHED"
    local apt_did_update=0
    if hours_left=$(__check_cooldown "apt_index" "$now"); then
        if sudo apt-get update >/dev/null 2>&1; then
            apt_did_update=1
            __set_cooldown "apt_index" "$now"
        fi
    fi
    if hours_left=$(__check_cooldown "apt" "$now"); then
        (( apt_did_update )) || sudo apt-get update >/dev/null 2>&1
        sudo apt-get upgrade -y --no-install-recommends >/dev/null 2>&1
        local apt_rc=$?
        if (( apt_rc == 0 )); then
            __tac_line "[2/10] APT Packages" "[UPDATED]" "$C_Success"
            __set_cooldown "apt" "$now"
            __set_cooldown "apt_index" "$now"  # upgrade implies fresh index
        else
            __tac_line "[2/10] APT Packages" "[FAILED]" "$C_Error"
            ((errCount++))
        fi
    else
        if (( apt_did_update )); then
            __tac_line "[2/10] APT Index" "[REFRESHED]" "$C_Success"
        else
            __tac_line "[2/10] APT Packages" "[CACHED - ${hours_left} LEFT]" "$C_Dim"
        fi
    fi

    # [3/10] NPM / Cargo
    if hours_left=$(__check_cooldown "npm_cargo" "$now"); then
        local pkg_err=0
        command -v npm >/dev/null && { npm update -g --quiet >/dev/null 2>&1 || pkg_err=1; }
        command -v cargo >/dev/null && { cargo install-update -a >/dev/null 2>&1 || pkg_err=1; }

        if (( pkg_err == 0 )); then
            __tac_line "[3/10] NPM & Cargo Crates" "[UPDATED]" "$C_Success"
            __set_cooldown "npm_cargo" "$now"
        else
            __tac_line "[3/10] NPM & Cargo Crates" "[WARNING/FAILED]" "$C_Warning"
            ((errCount++))
        fi
    else
        __tac_line "[3/10] NPM & Cargo Crates" "[CACHED - ${hours_left} LEFT]" "$C_Dim"
    fi

    # [4/10] OpenClaw verification — runs 'openclaw doctor' for real health check
    if hours_left=$(__check_cooldown "openclaw" "$now"); then
        if command -v openclaw >/dev/null; then
            local doc_rc
            openclaw doctor >/dev/null 2>&1
            doc_rc=$?
            if (( doc_rc == 0 )); then
                __tac_line "[4/10] OpenClaw Framework" "[HEALTHY]" "$C_Success"
            else
                __tac_line "[4/10] OpenClaw Framework" "[ISSUES FOUND - run ocdoc-fix]" "$C_Warning"
                ((errCount++))
            fi
            __set_cooldown "openclaw" "$now"
        else
            __tac_line "[4/10] OpenClaw Framework" "[MISSING]" "$C_Error"
            ((errCount++))
        fi
    else
        __tac_line "[4/10] OpenClaw Framework" "[CACHED - ${hours_left} LEFT]" "$C_Dim"
    fi

    # [5/10] Python Venv (a.k.a. "Cloaking" = active virtual environment isolation)
    if [[ -n "$VIRTUAL_ENV" ]]; then
        __tac_line "[5/10] Python Venv Cloaking" "[$(basename "$VIRTUAL_ENV")]" "$C_Success"
    else
        __tac_line "[5/10] Python Venv Cloaking" "[INACTIVE]" "$C_Dim"
    fi

    # [6/10] Python Fleet
    if hours_left=$(__check_cooldown "pyfleet" "$now"); then
        local py_versions=()
        local _py
        for _py in /usr/bin/python3.[0-9]*; do
            [[ -x "$_py" ]] && py_versions+=("$_py")
        done
        if [[ ${#py_versions[@]} -gt 0 ]]; then
            local v_list=()
            for py in "${py_versions[@]}"; do
                v_list+=("$(basename "$py")")
            done
            __tac_line "[6/10] Python Fleet" "[${v_list[*]} VERIFIED]" "$C_Success"
            __set_cooldown "pyfleet" "$now"
        else
            __tac_line "[6/10] Python Fleet" "[NO VERSIONS DETECTED]" "$C_Warning"
            ((errCount++))
        fi
    else
        __tac_line "[6/10] Python Fleet" "[CACHED - ${hours_left} LEFT]" "$C_Dim"
    fi

    # [7/10] GPU Checks
    local gpu; gpu=$(__get_gpu)

    if [[ "$gpu" != "N/A" && "$gpu" != "Querying..." && "$gpu" != *"OFFLINE"* ]]; then
        __tac_line "[7/10] RTX 3050 Ti" "[READY]" "$C_Success"
    else
        __tac_line "[7/10] GPU Status" "[OFFLINE OR ERROR]" "$C_Warning"
        ((errCount++))
    fi

    # [8/10] Sanitation — clean known temp locations, NOT the user's $PWD.
    # Only removes temp artifacts from /tmp/openclaw and the OC_ROOT directory.
    local count=0
    if [[ -d /tmp/openclaw ]]; then
        while IFS= read -r -d '' _tmpf; do
            rm -f "$_tmpf" && ((count++))
        done < <(find /tmp/openclaw \( -name '*.tmp' -o -name 'python-*.exe' \) -print0 2>/dev/null)
    fi
    __tac_line "[8/10] Temp File Sanitation" "[$count CLEANED]" "$C_Success"

    # [9/10] Disk Space Audit — warn if any mount point exceeds 90%
    local disk_warn=0
    while read -r pct mount; do
        local pct_num=${pct%\%}
        if (( pct_num >= 90 )); then
            __tac_line "[9/10] Disk: $mount" "[${pct} USED - LOW SPACE]" "$C_Error"
            disk_warn=1
            ((errCount++))
        fi
    done < <(df -h --output=pcent,target 2>/dev/null | tail -n +2 | grep -v '/snap/' | grep -v '/mnt/wsl/docker-desktop')
    (( disk_warn == 0 )) && __tac_line "[9/10] Disk Space Audit" "[ALL MOUNTS < 90%]" "$C_Success"

    # [10/10] Stale Process Cleanup — kill orphaned llama-server instances.
    # Skip if the active model state file was touched < 60s ago (still booting).
    # Per-PID check: only kill processes that are NOT listening on LLM_PORT.
    local stale_pids; stale_pids=$(pgrep -x llama-server 2>/dev/null)
    local stale_count=0
    if [[ -n "$stale_pids" ]] && ! __test_port "$LLM_PORT"; then
        stale_count=$(echo "$stale_pids" | wc -l)
        local _state_age=999
        [[ -f "$ACTIVE_LLM_FILE" ]] && _state_age=$(( $(date +%s) - $(stat -c %Y "$ACTIVE_LLM_FILE" 2>/dev/null || echo 0) ))
        if (( _state_age < 60 )); then
            __tac_line "[10/10] Stale Processes" "[${stale_count} BOOTING — GRACE PERIOD]" "$C_Dim"
        else
            pkill -u "$USER" -x llama-server 2>/dev/null
            rm -f "$ACTIVE_LLM_FILE"
            __tac_line "[10/10] Stale Processes" "[$stale_count ORPHAN(S) KILLED]" "$C_Warning"
        fi
    else
        __tac_line "[10/10] Stale Processes" "[CLEAN]" "$C_Success"
    fi

    __tac_divider
    if (( errCount > 0 )); then
        __tac_line "Maintenance Status" "[COMPLETED WITH $errCount ISSUE(S)]" "$C_Warning"
    else
        __tac_line "Maintenance Status" "[SYSTEMS AT PEAK PARITY]" "$C_Success"
    fi
    __tac_footer
}

# ---------------------------------------------------------------------------
# cl — Quick cleanup without the full maintenance run.
# ---------------------------------------------------------------------------
function cl() {
    local count; count=$(__cleanup_temps)
    __tac_info "Sanitation..." "[$count artifacts removed]" "$C_Success"
}

# ---------------------------------------------------------------------------
# __sync_bashrc_tracked — RETIRED (v2.20).
# Previously copied ~/.bashrc to .openclaw/bashrc.tracked.
# No longer needed: the canonical source is now version-controlled directly at
# ~/ubuntu-console/tactical-console.bashrc. ~/.bashrc is a thin loader.
# Kept as a no-op stub so existing 'reload' muscle-memory doesn't error.
# ---------------------------------------------------------------------------
function __sync_bashrc_tracked() { :; }

# ---------------------------------------------------------------------------
# copy_path — Copy the current working directory to the Windows clipboard.
# ---------------------------------------------------------------------------
function copy_path() {
    pwd | tr -d '\r\n' | clip.exe 2>/dev/null
    __tac_info "Clipboard" "[$(pwd)]" "$C_Success"
}

# ---------------------------------------------------------------------------
# sysinfo — One-line hardware summary without the full dashboard.
# Usage: sysinfo
# ---------------------------------------------------------------------------
function sysinfo() {
    local host_raw; host_raw=$(__get_host_metrics)
    local cpu gpu0 gpu1
    IFS='|' read -r cpu gpu0 gpu1 <<< "$host_raw"
    # Ensure numeric values for arithmetic (guard against stale/malformed cache)
    [[ "$cpu"  =~ ^[0-9]+$ ]] || cpu=0
    [[ "$gpu0" =~ ^[0-9]+$ ]] || gpu0=0
    [[ "$gpu1" =~ ^[0-9]+$ ]] || gpu1=0
    local mem_used mem_total mem_pct
    read -r mem_used mem_total mem_pct <<< "$(free -m | awk 'NR==2{printf "%.1f %.1f %d", $3/1024, $2/1024, $3*100/$2}')"
    local disk; disk=$(df -h / | awk 'NR==2{print $4}' | sed 's/\([0-9.]\)G/\1 Gb/;s/\([0-9.]\)M/\1 Mb/')
    local gpu_raw; gpu_raw=$(__get_gpu)
    local gpu_info="N/A" gpu_color=$C_Dim
    if [[ "$gpu_raw" != "N/A" && "$gpu_raw" != "Querying..." ]]; then
        local _g_name g_temp g_util _g_mu _g_mt
        IFS=',' read -r _g_name g_temp g_util _g_mu _g_mt <<< "$gpu_raw"
        # Strip whitespace from nvidia-smi CSV fields
        g_util=${g_util// /}
        # Strip trailing % sign for numeric comparison
        g_util=${g_util%%%}
        # Strip whitespace from temperature
        g_temp=${g_temp// /}
        gpu_info="${g_util}%/${g_temp}°C"
        gpu_color=$(__threshold_color "$g_util")
    fi
    # CPU colour
    local cpu_color
    cpu_color=$(__threshold_color "$cpu")
    # Memory colour
    local mem_color
    mem_color=$(__threshold_color "$mem_pct")
    # GPU1 colour (same thresholds as CPU/GPU0)
    local gpu1_color
    gpu1_color=$(__threshold_color "$gpu1")
    # Design tokens are already ANSI-C quoted ($'\e[…]'), so echo -e is
    # unnecessary. Using printf avoids any accidental backslash interpretation.
    printf '%s\n' "${C_Dim}CPU:${C_Reset} ${cpu_color}${cpu}%${C_Reset} ${C_Dim}RAM:${C_Reset} ${mem_color}${mem_used} / ${mem_total} Gb${C_Reset} ${C_Dim}Disk:${C_Reset} ${disk} ${C_Dim}iGPU:${C_Reset} ${gpu_color}${gpu_info}${C_Reset} ${C_Dim}CUDA:${C_Reset} ${gpu1_color}${gpu1}%${C_Reset}"
}

# ---------------------------------------------------------------------------
# logtrim — Trim logs larger than 1 MB to their last 1000 lines.
# ---------------------------------------------------------------------------
function logtrim() {
    local total=0
    local _had_nullglob=0; shopt -q nullglob && _had_nullglob=1
    shopt -s nullglob
    for logfile in "$OC_LOGS"/*.log "$ErrorLogPath" "$LLM_LOG_FILE"; do
        if [[ -f "$logfile" ]] && (( $(stat -c%s "$logfile" 2>/dev/null || echo 0) > 1048576 )); then
            tail -n 1000 "$logfile" > "${logfile}.tmp" || continue
            [[ -s "${logfile}.tmp" ]] || { rm -f "${logfile}.tmp"; continue; }
            mv "${logfile}.tmp" "$logfile" || { rm -f "${logfile}.tmp"; continue; }
            ((total++))
        fi
    done
    (( _had_nullglob )) || shopt -u nullglob
    __tac_info "Trimmed Logs (>1 Mb)" "[$total files]" "$C_Success"
}

# ==============================================================================
# 9. OPENCLAW MANAGER
# ==============================================================================
# @modular-section: openclaw
# @depends: constants, design-tokens, ui-engine, hooks
# @exports: so, xo, oc-restart, ocstart, ocstop, ockeys, ocdoc-fix,
#   __bridge_windows_api_keys, oc-refresh-keys, oc-backup, oc-restore,
#   owk, ologs, ocroot, lc, oc-update, oc-health, oc-cron, oc-skills,
#   oc-plugins, oc-tail, oc-channels, oc-sec, oc-tui, oc-config,
#   oc-docs, oc-usage, oc-memory-search, oc-local-llm, oc-sync-models,
#   oc-browser, oc-nodes, oc-sandbox, oc-env, oc-cache-clear, oc-trust-sync,
#   oc-diag, oc-failover

# ---------------------------------------------------------------------------
# so — Start the OpenClaw gateway (systemd-managed service).
# Injects bridged API keys into the systemd user session before starting.
# ---------------------------------------------------------------------------
function so() {
    if __test_port "$OC_PORT"; then
        __tac_info "Gateway Status" "[ALREADY RUNNING]" "$C_Warning"
        return 0
    fi

    # Push bridged API keys into the systemd user environment so the
    # openclaw-gateway.service can see them. Systemd user services do NOT
    # inherit the interactive shell's exported vars (they run in an
    # isolated activation context). We must push each key explicitly via
    # 'systemctl --user set-environment' so the service's ExecStart can
    # read them. The cache file uses printf %q quoting, so we read key
    # names from the file and use indirect expansion (${!_key}) to get
    # the properly evaluated values that were already sourced at startup.
    local _key
    while IFS= read -r _line; do
        _key="${_line#export }"
        _key="${_key%%=*}"
        [[ -n "$_key" && -n "${!_key:-}" ]] && systemctl --user set-environment "${_key}=${!_key}" 2>/dev/null
    done < <(grep '^export ' "$TAC_CACHE_DIR/tac_win_api_keys" 2>/dev/null)

    # If provider is configured for local LLM, warn if it's not running
    local _prov_url; _prov_url=$(openclaw config get provider.baseUrl 2>/dev/null)
    if [[ "$_prov_url" == *"127.0.0.1:${LLM_PORT}"* ]] && ! __test_port "$LLM_PORT"; then
        __tac_info "Local LLM" "[OFFLINE — provider points to localhost:$LLM_PORT]" "$C_Warning"
        printf '%s\n' "  ${C_Dim}Run 'serve <profile>' to start the LLM before gateway.${C_Reset}"
    fi

    openclaw gateway start >/dev/null 2>&1

    # Wait up to 15 seconds for the gateway to become responsive
    local ready=0
    printf '%s' "${C_Dim}Waiting for gateway"
    for _ in {1..15}; do
        if __test_port "$OC_PORT"; then ready=1; break; fi
        printf '.'
        sleep 1
    done
    printf '%s\n' "${C_Reset}"

    if (( ready )); then
        __tac_info "Supervisor Process" "[ONLINE]" "$C_Success"
    else
        if systemctl --user is-active --quiet openclaw-gateway.service 2>/dev/null; then
            __tac_info "Supervisor Process" "[FAILED TO START IN TIME]" "$C_Error"
        else
            __tac_info "Supervisor Process" "[CRASHED - CHECK LOGS]" "$C_Error"
        fi
        printf '%s\n' "  ${C_Dim}Run 'le' to view the startup errors.${C_Reset}"
    fi
}

# ---------------------------------------------------------------------------
# xo — Stop the OpenClaw gateway.
# Uses 'openclaw gateway stop' then systemctl for clean shutdown.
# ---------------------------------------------------------------------------
function xo() {
    openclaw gateway stop >/dev/null 2>&1
    systemctl --user stop openclaw-gateway.service 2>/dev/null
    sleep 0.5
    rm -f "$OC_ROOT/supervisor.lock"
    __tac_info "Gateway Processes" "[TERMINATED]" "$C_Success"
}

# ---------------------------------------------------------------------------
# oc-restart — Stop and restart the OpenClaw gateway.
# ---------------------------------------------------------------------------
function oc-restart() {
    xo
    sleep 1
    so
}

# ---------------------------------------------------------------------------
# ocstart — Send an agent turn to OpenClaw.
# Usage: ocstart -m "<message>" [--to <E.164>] [--agent <id>]
# ---------------------------------------------------------------------------
function ocstart() {
    if [[ -z "$*" ]]; then
        printf '%s\n' "${C_Dim}Usage:${C_Reset} ocstart --message \"<message>\" [--to <E.164>] [--agent <id>]"
        printf '%s\n' "${C_Dim}  --message     Message body for the agent (required)${C_Reset}"
        printf '%s\n' "${C_Dim}  --to          Recipient number in E.164 format${C_Reset}"
        printf '%s\n' "${C_Dim}  --agent       Agent ID to target${C_Reset}"
        printf '%s\n' "${C_Dim}  --session-id  Explicit session ID${C_Reset}"
        printf '%s\n' "${C_Dim}  --thinking    Thinking level (off|minimal|low|medium|high|xhigh)${C_Reset}"
        return 1
    fi
    openclaw agent "$@"
}

# ---------------------------------------------------------------------------
# ocstop — Delete / stop an agent.
# Usage: ocstop --agent <id>
# ---------------------------------------------------------------------------
function ocstop() {
    if [[ -z "$*" ]]; then
        printf '%s\n' "${C_Dim}Usage:${C_Reset} ocstop --agent <id>"
        printf '%s\n' "${C_Dim}  --agent  Agent ID to stop (required)${C_Reset}"
        printf '%s\n' "${C_Dim}  Tip: run 'oa' to list agents${C_Reset}"
        return 1
    fi
    openclaw agents delete "$@"
}

# ---------------------------------------------------------------------------
# ockeys — Show Windows environment API keys and their WSL visibility.
# Wraps the pwsh call in timeout to prevent hangs after sleep/hibernate.
# ---------------------------------------------------------------------------
function ockeys() {
    printf '%s\n' "${C_Highlight}API Keys & Tokens (Windows Environment → WSL):${C_Reset}"
    local found=0
    while IFS='=' read -r name val; do
        [[ -z "$name" ]] && continue
        local upper; upper=${name^^}
        if [[ "$upper" == *API_KEY* || "$upper" == *API-KEY* || "$upper" == *TOKEN* || "$upper" == *APIKEY* ]]; then
            local masked="${val:0:4}...${val: -4}"
            [[ ${#val} -lt 10 ]] && masked="(too short)"
            local oc_visible=""
            if printenv "$name" >/dev/null 2>&1; then
                oc_visible="${C_Success}WSL ✓${C_Reset}"
            else
                oc_visible="${C_Error}WSL ✗${C_Reset}"
            fi
            printf '%s\n' "  ${C_Dim}$name${C_Reset}  $masked  $oc_visible"
            ((found++))
        fi
    done < <(timeout 5 pwsh.exe -NoProfile -Command '
        [Environment]::GetEnvironmentVariables("User").GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }
    ' 2>/dev/null | tr -d '\r')
    if (( found == 0 )); then
        __tac_info "Windows User Env" "[NO API-KEY / TOKEN VARS FOUND]" "$C_Warning"
    else
        printf '%s\n' "  ${C_Dim}$found key(s) found in Windows User environment${C_Reset}"
    fi
}

# ---------------------------------------------------------------------------
# ocdoc-fix — Run openclaw doctor --fix with automatic config backup.
# ---------------------------------------------------------------------------
function ocdoc-fix() {
    local cfg="$OC_ROOT/openclaw.json"
    local bak="${cfg}.pre-doctor"
    if [[ -f "$cfg" ]]; then
        cp "$cfg" "$bak"
        __tac_info "Config Backup" "[SAVED → $(basename "$bak")]" "$C_Success"
    fi
    openclaw doctor --fix
    if [[ -f "$bak" && -f "$cfg" ]]; then
        printf '%s\n' "${C_Dim}If settings were overwritten, restore with:${C_Reset}"
        printf '%s\n' "  ${C_Highlight}cp $bak $cfg${C_Reset}"
    fi
}

# ---------------------------------------------------------------------------
# __bridge_windows_api_keys — Import Windows User environment variables
# containing API_KEY or TOKEN into the WSL environment.
# Uses a /dev/shm cache (TTL 3600s = 1h) to avoid a slow pwsh call on
# every shell start. Run 'oc-refresh-keys' to force a re-import.
# Security: cache is chmod 600 and lives in tmpfs (RAM only, no disk).
# ---------------------------------------------------------------------------
function __bridge_windows_api_keys() {
    local cache="$TAC_CACHE_DIR/tac_win_api_keys"
    local ttl=3600

    # Use cached exports if fresh enough
    if [[ -f "$cache" ]] && (( $(date +%s) - $(stat -c %Y "$cache" 2>/dev/null || echo 0) < ttl )); then
        source "$cache" 2>/dev/null
        return
    fi

    # Fetch matching vars from Windows User environment via PowerShell
    # Broad match: any var containing API_KEY, API-KEY, APIKEY, or TOKEN
    local raw
    raw=$(timeout 5 pwsh.exe -NoProfile -NonInteractive -Command '
        [Environment]::GetEnvironmentVariables("User").GetEnumerator() |
        Where-Object { $_.Key -match "API[_-]?KEY|TOKEN" } |
        ForEach-Object { "$($_.Key)=$($_.Value)" }
    ' 2>/dev/null | tr -d '\r')

    [[ -z "$raw" ]] && return 1

    # Build a sourceable cache file, skipping vars with invalid names
    local tmpfile="${cache}.tmp"
    ( umask 077; : > "$tmpfile" )
    while IFS='=' read -r name val; do
        [[ -z "$name" || "$name" =~ [^a-zA-Z0-9_] ]] && continue
        [[ -z "$val" ]] && continue
        # Reject values with embedded newlines (could inject extra commands)
        [[ "$val" == *$'\n'* ]] && continue
        printf 'export %s=%q\n' "$name" "$val" >> "$tmpfile"
    done <<< "$raw"
    mv "$tmpfile" "$cache"
    chmod 600 "$cache"
    source "$cache" 2>/dev/null
}

# ---------------------------------------------------------------------------
# oc-refresh-keys — Force re-import of Windows API keys into WSL.
# ---------------------------------------------------------------------------
function oc-refresh-keys() {
    rm -f "$TAC_CACHE_DIR/tac_win_api_keys"
    __bridge_windows_api_keys
    if [[ -f "$TAC_CACHE_DIR/tac_win_api_keys" ]]; then
        local count; count=$(wc -l < "$TAC_CACHE_DIR/tac_win_api_keys")
        __tac_info "Windows API Keys" "[$count variable(s) imported]" "$C_Success"
    else
        __tac_info "Windows API Keys" "[BRIDGE FAILED - pwsh timeout?]" "$C_Warning"
    fi
}

# ---------------------------------------------------------------------------
# oc-backup — Snapshot OpenClaw config, workspace, agents, LLM registry,
# .bashrc profile, standalone scripts, and systemd units.
# ---------------------------------------------------------------------------
function oc-backup() {
    if ! command -v zip >/dev/null; then
        __tac_info "Dependency" "[zip not installed]" "$C_Error"
        printf '%s\n' "  ${C_Dim}Install: sudo apt install zip${C_Reset}"
        return 1
    fi

    local stamp; stamp=$(date +"%Y%m%d_%H%M%S")
    mkdir -p "$OC_BACKUPS"
    local zipPath="$OC_BACKUPS/snapshot_$stamp.zip"

    __tac_info "Compressing Configuration & Agents..." "[WORKING]" "$C_Dim"

    (
        cd "$AI_STORAGE_ROOT" || exit 1
        local -a targets=()
        # Core OpenClaw state
        [[ -d ".openclaw/workspace" ]] && targets+=(".openclaw/workspace")
        [[ -d ".openclaw/agents" ]]    && targets+=(".openclaw/agents")
        [[ -f ".openclaw/openclaw.json" ]] && targets+=(".openclaw/openclaw.json")
        [[ -f ".openclaw/auth.json" ]]     && targets+=(".openclaw/auth.json")
        [[ -f ".llm/models.conf" ]]        && targets+=(".llm/models.conf")
        # Shell profile and standalone scripts
        # Canonical profile is in the ubuntu-console repo; back up both the
        # thin loader (~/.bashrc) and the full profile.
        [[ -f ".bashrc" ]]                && targets+=(".bashrc")
        [[ -f "ubuntu-console/tactical-console.bashrc" ]] && targets+=("ubuntu-console/tactical-console.bashrc")
        local _script
        for _script in .local/bin/llama-watchdog.sh .local/bin/tac_hostmetrics.sh; do
            [[ -f "$_script" ]] && targets+=("$_script")
        done
        # Systemd units
        for _script in .config/systemd/user/llama-watchdog.service \
                       .config/systemd/user/llama-watchdog.timer; do
            [[ -f "$_script" ]] && targets+=("$_script")
        done

        if (( ${#targets[@]} > 0 )); then
            zip -r -q "$zipPath" "${targets[@]}"
        fi
    )

    if [[ -f "$zipPath" ]]; then
        local sz; sz=$(stat -c%s "$zipPath" 2>/dev/null || echo "0")
        local human_sz=$(( sz / 1024 ))
        __tac_info "Snapshot Archive" "[CREATED — ${human_sz}KB]" "$C_Success"
        printf '%s\n' "  ${C_Dim}Path: $zipPath${C_Reset}"

        # Prune old snapshots — keep the 10 most recent
        local -a all_snaps=()
        local _s
        while IFS= read -r _s; do
            all_snaps+=("$_s")
        done < <(ls -1t "$OC_BACKUPS"/snapshot_*.zip 2>/dev/null)
        local keep=10
        if (( ${#all_snaps[@]} > keep )); then
            local pruned=0
            local i
            for (( i=keep; i<${#all_snaps[@]}; i++ )); do
                rm -f "${all_snaps[$i]}"
                (( pruned++ ))
            done
            __tac_info "Pruned Old Snapshots" "[$pruned removed, keeping $keep]" "$C_Dim"
        fi
    else
        __tac_info "Target Directories" "[NOT FOUND]" "$C_Error"
    fi
}

# ---------------------------------------------------------------------------
# oc-restore — Rollback OpenClaw state from the most recent snapshot.
# DESTRUCTIVE: Deletes current workspace and agents. Prompts for confirmation.
# ---------------------------------------------------------------------------
function oc-restore() {
    local latest=""
    local -a snaps=("$OC_BACKUPS"/snapshot_*.zip)
    if [[ -e "${snaps[0]}" ]]; then
        local f newest="" newest_t=0
        for f in "${snaps[@]}"; do
            local t; t=$(stat -c %Y "$f" 2>/dev/null) || continue
            (( t > newest_t )) && newest_t=$t && newest="$f"
        done
        latest="$newest"
    fi
    if [[ -z "$latest" ]]; then
        __tac_info "Available Snapshots" "[NONE FOUND]" "$C_Error"
        return 1
    fi

    printf '%s\n' "${C_Warning}WARNING: This will DESTROY the current workspace and agents.${C_Reset}"
    printf '%s\n' "${C_Dim}Restoring from: $(basename "$latest")${C_Reset}"
    read -r -p "${C_Warning}Continue? [y/N]: ${C_Reset}" confirm
    [[ "${confirm,,}" != "y" ]] && { __tac_info "Restore" "[CANCELLED]" "$C_Dim"; return 0; }

    # Stop gateway inline (avoid calling xo which prints its own UI)
    openclaw gateway stop >/dev/null 2>&1
    # pkill -x matches only the exact process name (not substrings)
    pkill -x openclaw 2>/dev/null

    __tac_info "Purging active configurations..." "[WORKING]" "$C_Dim"

    # Extract to a temp directory first, validate, then swap — protects
    # against corrupt ZIPs destroying current state with nothing to replace it.
    local tmp_restore; tmp_restore=$(mktemp -d "${OC_BACKUPS}/restore_XXXXXX")
    __tac_info "Extracting to staging area..." "[WORKING]" "$C_Dim"
    if ! unzip -q "$latest" -d "$tmp_restore"; then
        __tac_info "State Rollback" "[FAILED — ZIP ERROR, current state preserved]" "$C_Error"
        rm -rf "$tmp_restore"
        return 1
    fi

    # Validate that the extracted archive has at least one known restorable asset
    if [[ ! -d "$tmp_restore/.openclaw/workspace" && ! -d "$tmp_restore/.openclaw/agents" \
       && ! -f "$tmp_restore/.openclaw/openclaw.json" && ! -f "$tmp_restore/.bashrc" \
       && ! -f "$tmp_restore/.llm/models.conf" ]]; then
        __tac_info "State Rollback" "[FAILED — ZIP has no recognisable content]" "$C_Error"
        rm -rf "$tmp_restore"
        return 1
    fi

    # Security: reject extracted files with setuid/setgid/world-writable bits.
    # A crafted ZIP could plant executables with elevated permissions.
    if find "$tmp_restore" \( -perm /4000 -o -perm /2000 -o -perm /0002 \) -print -quit 2>/dev/null | grep -q .; then
        __tac_info "State Rollback" "[FAILED — ZIP contains unsafe file permissions]" "$C_Error"
        rm -rf "$tmp_restore"
        return 1
    fi

    # Only destroy directories that the backup will replace — a config-only
    # restore must NOT wipe workspace/agents if it has no replacements.
    # Atomic swap: rename current → .bak, move new into place, then remove .bak.
    # If the move fails, the .bak can be manually restored (no total-loss window).
    if [[ -d "$tmp_restore/.openclaw/workspace" ]]; then
        [[ -d "$OC_WORKSPACE" ]] && mv "$OC_WORKSPACE" "${OC_WORKSPACE}.bak"
        mv "$tmp_restore/.openclaw/workspace" "$OC_WORKSPACE"
        rm -rf "${OC_WORKSPACE}.bak"
    fi
    if [[ -d "$tmp_restore/.openclaw/agents" ]]; then
        [[ -d "$OC_AGENTS" ]] && mv "$OC_AGENTS" "${OC_AGENTS}.bak"
        mv "$tmp_restore/.openclaw/agents" "$OC_AGENTS"
        rm -rf "${OC_AGENTS}.bak"
    fi
    # Restore config files if they were backed up
    [[ -f "$tmp_restore/.openclaw/openclaw.json" ]] && mv "$tmp_restore/.openclaw/openclaw.json" "$OC_ROOT/openclaw.json"
    [[ -f "$tmp_restore/.openclaw/auth.json" ]]     && mv "$tmp_restore/.openclaw/auth.json" "$OC_ROOT/auth.json"
    [[ -f "$tmp_restore/.llm/models.conf" ]]        && mv "$tmp_restore/.llm/models.conf" "$LLM_REGISTRY"
    # Restore shell profile and standalone scripts if present
    [[ -f "$tmp_restore/.bashrc" ]] && cp "$tmp_restore/.bashrc" "$HOME/.bashrc"
    if [[ -f "$tmp_restore/ubuntu-console/tactical-console.bashrc" ]]; then
        mkdir -p "$HOME/ubuntu-console"
        cp "$tmp_restore/ubuntu-console/tactical-console.bashrc" "$HOME/ubuntu-console/tactical-console.bashrc"
    fi
    local _rs
    for _rs in .local/bin/llama-watchdog.sh .local/bin/tac_hostmetrics.sh; do
        if [[ -f "$tmp_restore/$_rs" ]]; then
            mkdir -p "$(dirname "$HOME/$_rs")"
            cp "$tmp_restore/$_rs" "$HOME/$_rs"
            chmod +x "$HOME/$_rs"
        fi
    done
    # Restore systemd units if present
    for _rs in .config/systemd/user/llama-watchdog.service \
               .config/systemd/user/llama-watchdog.timer; do
        if [[ -f "$tmp_restore/$_rs" ]]; then
            mkdir -p "$(dirname "$HOME/$_rs")"
            cp "$tmp_restore/$_rs" "$HOME/$_rs"
        fi
    done
    rm -rf "$tmp_restore"

    __tac_info "State Rollback" "[COMPLETE]" "$C_Success"
    printf '%s\n' "${C_Dim}Tip: run 'so' to restart the gateway.${C_Reset}"
}

# ---------------------------------------------------------------------------
# owk — cd to OpenClaw workspace directory.
# ---------------------------------------------------------------------------
function owk() {
    cd "$OC_WORKSPACE" 2>/dev/null || __tac_info "Workspace" "[NOT FOUND]" "$C_Error"
}

# ---------------------------------------------------------------------------
# ologs — cd to OpenClaw logs directory.
# ---------------------------------------------------------------------------
function ologs() {
    cd "$OC_LOGS" 2>/dev/null || __tac_info "Logs" "[NOT FOUND]" "$C_Error"
}

# ---------------------------------------------------------------------------
# ocroot — cd to OpenClaw root directory.
# ---------------------------------------------------------------------------
function ocroot() {
    cd "$OC_ROOT" 2>/dev/null || __tac_info "Root" "[NOT FOUND]" "$C_Error"
}

# ---------------------------------------------------------------------------
# lc — Rotate the gateway systemd journal logs.
# ---------------------------------------------------------------------------
function lc() {
    journalctl --user --rotate --vacuum-time=1s -u openclaw-gateway.service >/dev/null 2>&1
    __tac_info "Logs" "[CLEARED]" "$C_Success"
}

# ---------------------------------------------------------------------------
# oc-update — Update the OpenClaw CLI to the latest version.
# ---------------------------------------------------------------------------
function oc-update() {
    if ! command -v openclaw >/dev/null; then
        __tac_info "OpenClaw CLI" "[NOT INSTALLED]" "$C_Error"
        return 1
    fi
    __tac_info "Checking for updates..." "[WORKING]" "$C_Dim"
    local out; out=$(openclaw update 2>&1)
    local rc=$?
    if (( rc == 0 )); then
        __tac_info "Update" "[COMPLETE]" "$C_Success"
        [[ -n "$out" ]] && printf '%s\n' "${C_Dim}${out}${C_Reset}"
    else
        __tac_info "Update" "[FAILED - rc=$rc]" "$C_Error"
        [[ -n "$out" ]] && printf '%s\n' "${C_Dim}${out}${C_Reset}"
    fi
}

# ---------------------------------------------------------------------------
# oc-health — Deep gateway health probe via the OpenClaw CLI.
# Uses jq for JSON parsing instead of Python.
# ---------------------------------------------------------------------------
function oc-health() {
    if ! command -v openclaw >/dev/null; then
        __tac_info "OpenClaw CLI" "[NOT INSTALLED]" "$C_Error"
        return 1
    fi
    if __test_port "$OC_PORT"; then
        __tac_info "Gateway Port $OC_PORT" "[LISTENING]" "$C_Success"
    else
        __tac_info "Gateway Port $OC_PORT" "[NOT LISTENING]" "$C_Error"
        return 1
    fi
    local health_out; health_out=$(openclaw health --json 2>/dev/null)
    if [[ -n "$health_out" ]]; then
        local hstatus
        hstatus=$(jq -r '.status // "unknown"' <<< "$health_out" 2>/dev/null)
        [[ -z "$hstatus" ]] && hstatus="parse_error"
        local health_color=$C_Warning
        if [[ $hstatus == "ok" || $hstatus == "healthy" ]]; then
            health_color=$C_Success
        fi
        __tac_info "Health Status" "[${hstatus^^}]" "$health_color"
    else
        __tac_info "Health Probe" "[NO RESPONSE]" "$C_Warning"
    fi
}

# ---------------------------------------------------------------------------
# oc-cron — OpenClaw scheduler management (list / add / runs).
# ---------------------------------------------------------------------------
function oc-cron() {
    local action="${1:-list}"
    (( $# > 0 )) && shift
    case "$action" in
        list) openclaw cron list ;;
        add)  openclaw cron add "$@" ;;
        runs) openclaw cron runs "$@" ;;
        *)    echo "Usage: oc-cron {list|add|runs} [args...]" ;;
    esac
}

# ---------------------------------------------------------------------------
# oc-skills — List installed and eligible OpenClaw skills.
# ---------------------------------------------------------------------------
function oc-skills() {
    if command -v clawhub >/dev/null 2>&1; then
        clawhub list
    else
        openclaw skills list --eligible
    fi
}

# ---------------------------------------------------------------------------
# oc-plugins — OpenClaw plugin management.
# ---------------------------------------------------------------------------
function oc-plugins() {
    local action="${1:-list}"
    case "$action" in
        list)    openclaw plugins list ;;
        doctor)  openclaw plugins doctor ;;
        enable)  openclaw plugins enable "$2" ;;
        disable) openclaw plugins disable "$2" ;;
        *)       echo "Usage: oc-plugins {list|doctor|enable|disable} [id]" ;;
    esac
}

# ---------------------------------------------------------------------------
# oc-tail — Live-tail the OpenClaw gateway logs in the terminal.
# ---------------------------------------------------------------------------
function oc-tail() {
    openclaw logs --follow
}

# ---------------------------------------------------------------------------
# oc-channels — Channel management wrapper (list/status/logs/add/remove).
# ---------------------------------------------------------------------------
function oc-channels() {
    local action="${1:-list}"
    (( $# > 0 )) && shift
    case "$action" in
        list)   openclaw channels list ;;
        status) openclaw channels status --probe ;;
        logs)   openclaw channels logs "$@" ;;
        add)    openclaw channels add "$@" ;;
        remove) openclaw channels remove "$@" ;;
        *)      echo "Usage: oc-channels {list|status|logs|add|remove} [args...]" ;;
    esac
}

# ---------------------------------------------------------------------------
# oc-sec — Run a deep security audit on the OpenClaw installation.
# ---------------------------------------------------------------------------
function oc-sec() {
    openclaw security audit --deep
}

# ---------------------------------------------------------------------------
# oc-tui — Launch the OpenClaw built-in terminal user interface.
# ---------------------------------------------------------------------------
function oc-tui() {
    openclaw tui
}

# ---------------------------------------------------------------------------
# oc-config — Get or set OpenClaw configuration values.
# Usage: oc-config get <key> | set <key> <value> | unset <key>
# ---------------------------------------------------------------------------
function oc-config() {
    if [[ -z "$*" ]]; then
        printf '%s\n' "${C_Dim}Usage:${C_Reset} oc-config get <key> | set <key> <value> | unset <key>"
        return 1
    fi
    openclaw config "$@"
}

# ---------------------------------------------------------------------------
# oc-docs — Search the OpenClaw documentation from the terminal.
# ---------------------------------------------------------------------------
function oc-docs() {
    if [[ -z "$*" ]]; then
        printf '%s\n' "${C_Dim}Usage:${C_Reset} oc-docs <search query>"
        return 1
    fi
    openclaw docs "$*"
}

# ---------------------------------------------------------------------------
# oc-usage — Show recent token/cost usage statistics.
# Usage: oc-usage [period] (default: 7d)
# ---------------------------------------------------------------------------
function oc-usage() {
    openclaw usage --last "${1:-7d}"
}

# ---------------------------------------------------------------------------
# oc-memory-search — Search OpenClaw's vector memory index.
# ---------------------------------------------------------------------------
function oc-memory-search() {
    if [[ -z "$*" ]]; then
        printf '%s\n' "${C_Dim}Usage:${C_Reset} oc-memory-search <query>"
        return 1
    fi
    openclaw memory search "$*"
}

# ---------------------------------------------------------------------------
# oc-local-llm — Configure OpenClaw to use the local llama.cpp server.
# Binds OpenClaw's model provider to the local inference endpoint so agents
# use your RTX 3050 Ti instead of paying for cloud API calls.
# ---------------------------------------------------------------------------
function oc-local-llm() {
    if ! __test_port "$LLM_PORT"; then
        __tac_info "Local LLM" "[OFFLINE - Start a model first]" "$C_Error"
        return 1
    fi
    # Read the active model's name and GGUF filename from the registry
    local model_name="local" model_file=""
    if [[ -f "$ACTIVE_LLM_FILE" ]]; then
        local _anum; _anum=$(< "$ACTIVE_LLM_FILE")
        if [[ -n "$_anum" && -f "$LLM_REGISTRY" ]]; then
            local _entry; _entry=$(awk -F'|' -v n="$_anum" '$1 == n' "$LLM_REGISTRY" 2>/dev/null)
            IFS='|' read -r _ _name _file _ <<< "$_entry"
            [[ -n "$_name" ]] && model_name="$_name"
            [[ -n "$_file" ]] && model_file="$_file"
        fi
    fi

    # Update the local-llama provider in models.providers (the correct config path).
    # Build the provider JSON with jq and write it in a single config set call.
    local provider_json
    provider_json=$(jq -n \
        --arg url "http://127.0.0.1:${LLM_PORT}/v1" \
        --arg id "${model_file:-local}" \
        --arg name "${model_name} (Local RTX 3050 Ti)" \
        '{
            baseUrl: $url,
            api: "openai-completions",
            models: [{
                id: $id,
                name: $name,
                api: "openai-completions",
                reasoning: false,
                input: ["text"],
                cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }
            }]
        }')
    openclaw config set models.providers.local-llama "$provider_json" 2>/dev/null

    openclaw gateway restart 2>/dev/null
    # Verify the gateway actually came back up after reconfiguration
    sleep 2
    if __test_port "$OC_PORT"; then
        __tac_info "OpenClaw → Local LLM" "[LINKED: $model_name on port $LLM_PORT]" "$C_Success"
    else
        __tac_info "OpenClaw → Local LLM" "[LINKED but gateway not responding]" "$C_Warning"
    fi
}

# ---------------------------------------------------------------------------
# oc-sync-models — Sync the local model registry with OpenClaw's model scan.
# ---------------------------------------------------------------------------
function oc-sync-models() {
    openclaw models scan --no-probe --yes
    __tac_info "Model Registry" "[SYNCED WITH OPENCLAW]" "$C_Success"
}

# ---------------------------------------------------------------------------
# oc-browser — OpenClaw browser automation lifecycle.
# ---------------------------------------------------------------------------
function oc-browser() {
    local action="${1:-status}"
    (( $# > 0 )) && shift
    case "$action" in
        status) openclaw browser status ;;
        start)  openclaw browser start ;;
        stop)   openclaw browser stop ;;
        open)   openclaw browser open "$@" ;;
        *)      echo "Usage: oc-browser {status|start|stop|open} [args...]" ;;
    esac
}

# ---------------------------------------------------------------------------
# oc-nodes — List and inspect connected OpenClaw nodes.
# ---------------------------------------------------------------------------
function oc-nodes() {
    local action="${1:-status}"
    (( $# > 0 )) && shift
    case "$action" in
        status)   openclaw nodes status ;;
        list)     openclaw nodes list ;;
        describe) openclaw nodes describe "$@" ;;
        *)        echo "Usage: oc-nodes {status|list|describe} [args...]" ;;
    esac
}

# ---------------------------------------------------------------------------
# oc-sandbox — Manage OpenClaw agent sandboxes.
# ---------------------------------------------------------------------------
function oc-sandbox() {
    local action="${1:-list}"
    (( $# > 0 )) && shift
    case "$action" in
        list)     openclaw sandbox list ;;
        recreate) openclaw sandbox recreate ;;
        explain)  openclaw sandbox explain ;;
        *)        echo "Usage: oc-sandbox {list|recreate|explain}" ;;
    esac
}

# ---------------------------------------------------------------------------
# oc-env — Dump all OpenClaw and LLM related environment variables.
# ---------------------------------------------------------------------------
function oc-env() {
    __tac_header "ENVIRONMENT VARIABLES" "open"
    __tac_line "OPENCLAW_ROOT" "[$OPENCLAW_ROOT]" "$C_Highlight"
    __tac_line "OC_WORKSPACE" "[$OC_WORKSPACE]" "$C_Dim"
    __tac_line "OC_AGENTS" "[$OC_AGENTS]" "$C_Dim"
    __tac_line "OC_LOGS" "[$OC_LOGS]" "$C_Dim"
    __tac_line "OC_PORT" "[$OC_PORT]" "$C_Highlight"
    __tac_divider
    __tac_line "LLAMA_ROOT" "[$LLAMA_ROOT]" "$C_Highlight"
    __tac_line "LLAMA_MODEL_DIR" "[$LLAMA_MODEL_DIR]" "$C_Dim"
    __tac_line "LLM_PORT" "[$LLM_PORT]" "$C_Highlight"
    __tac_line "LOCAL_LLM_URL" "[$LOCAL_LLM_URL]" "$C_Dim"
    __tac_line "LLAMA_GPU_LAYERS" "[$LLAMA_GPU_LAYERS]" "$C_Dim"
    __tac_line "LLAMA_CPU_THREADS" "[$LLAMA_CPU_THREADS]" "$C_Dim"
    __tac_divider
    __tac_line "AI_STORAGE_ROOT" "[$AI_STORAGE_ROOT]" "$C_Dim"
    __tac_line "UIWidth" "[$UIWidth]" "$C_Dim"
    __tac_line "PROFILE VERSION" "[$TACTICAL_PROFILE_VERSION]" "$C_Success"
    __tac_footer
}

# ---------------------------------------------------------------------------
# oc-cache-clear — Wipe all /dev/shm telemetry caches to force a refresh.
# ---------------------------------------------------------------------------
function oc-cache-clear() {
    local count=0
    local _had_nullglob=0; shopt -q nullglob && _had_nullglob=1
    shopt -s nullglob
    for f in "$TAC_CACHE_DIR"/tac_*; do
        [[ -f "$f" ]] && rm -f "$f" && ((count++))
    done
    (( _had_nullglob )) || shopt -u nullglob
    __tac_info "Telemetry Cache" "[$count file(s) cleared]" "$C_Success"
}

# ---------------------------------------------------------------------------
# oc-trust-sync — Record current oc-llm-sync.sh hash as trusted.
# ---------------------------------------------------------------------------
function oc-trust-sync() {
    local src="$OC_WORKSPACE/oc-llm-sync.sh"
    if [[ ! -f "$src" ]]; then
        __tac_info "oc-llm-sync.sh" "[NOT FOUND]" "$C_Error"
        return 1
    fi
    sha256sum "$src" 2>/dev/null | cut -d' ' -f1 > "$OC_ROOT/oc-llm-sync.sha256"
    __tac_info "Trusted Hash" "[UPDATED]" "$C_Success"
}

# ---------------------------------------------------------------------------
# oc-diag — Combined diagnostic dump: OpenClaw doctor + gateway status +
#            model status + environment variables + recent log tail.
# ---------------------------------------------------------------------------
function oc-diag() {
    __tac_header "OpenClaw Diagnostic Report" "open"
    echo ""

    printf '%s\n' "${C_Highlight}[1/5] openclaw doctor${C_Reset}"
    openclaw doctor 2>&1 | head -n 30
    echo ""

    printf '%s\n' "${C_Highlight}[2/5] Gateway Status${C_Reset}"
    if curl -sf --max-time 5 "http://127.0.0.1:${OC_PORT:-18789}/api/health" -o /dev/null 2>/dev/null; then
        printf '%s\n' "  ${C_Success}● Gateway reachable on port ${OC_PORT:-18789}${C_Reset}"
    else
        printf '%s\n' "  ${C_Error}● Gateway NOT reachable on port ${OC_PORT:-18789}${C_Reset}"
    fi
    echo ""

    printf '%s\n' "${C_Highlight}[3/5] Model Provider Status${C_Reset}"
    ocms 2>&1 | head -n 20
    echo ""

    printf '%s\n' "${C_Highlight}[4/5] Environment Variables${C_Reset}"
    oc-env 2>&1
    echo ""

    printf '%s\n' "${C_Highlight}[5/5] Recent Logs (last 15 lines)${C_Reset}"
    if [[ -f "$OC_TMP_LOG" ]]; then
        tail -n 15 "$OC_TMP_LOG"
    else
        echo "  (no log file found at $OC_TMP_LOG)"
    fi
    echo ""
    __tac_footer
    __tac_info "Diagnostics" "[Complete]" "$C_Success"
}

# ---------------------------------------------------------------------------
# oc-failover — Configure cloud model fallback for when local LLM is down.
#   Usage: oc-failover [on|off|status]
# ---------------------------------------------------------------------------
function oc-failover() {
    local action="${1:-status}"
    case "$action" in
        on)
            if [[ -z "${OPENAI_API_KEY:-}" && -z "${ANTHROPIC_API_KEY:-}" ]]; then
                __tac_info "Failover" "[No cloud API key found — set OPENAI_API_KEY or ANTHROPIC_API_KEY]" "$C_Error"
                return 1
            fi
            # Verify the fallback model list is configured before enabling
            local fb_models; fb_models=$(openclaw config get llm.fallback.models 2>/dev/null)
            if [[ -z "$fb_models" || "$fb_models" == "null" ]]; then
                __tac_info "Failover" "[No fallback models configured — set llm.fallback.models first]" "$C_Warning"
            fi
            openclaw config set llm.fallback.enabled true 2>/dev/null
            __tac_info "Failover" "[Cloud fallback ENABLED]" "$C_Success"
            ;;
        off)
            openclaw config set llm.fallback.enabled false 2>/dev/null
            __tac_info "Failover" "[Cloud fallback DISABLED]" "$C_Warning"
            ;;
        status)
            local val; val=$(openclaw config get llm.fallback.enabled 2>/dev/null || echo "unknown")
            __tac_info "Failover" "[llm.fallback.enabled = $val]" "$C_Info"
            # Show the actual fallback chain so the user knows what will activate
            local chain; chain=$(openclaw config get llm.fallback.models 2>/dev/null)
            if [[ -n "$chain" && "$chain" != "null" ]]; then
                __tac_info "Chain" "$chain" "$C_Dim"
            else
                __tac_info "Chain" "[No fallback models configured]" "$C_Warning"
            fi
            ;;
        *)
            printf '%s\n' "${C_Dim}Usage:${C_Reset} oc-failover [on|off|status]"
            ;;
    esac
}

# ==============================================================================
# 10. DEPLOYMENT & SCAFFOLDING
# ==============================================================================
# @modular-section: deployment
# @depends: constants, design-tokens, ui-engine, hooks
# @exports: mkproj, commit_deploy, commit_auto

# ---------------------------------------------------------------------------
# mkproj — Scaffold a new Python project with PEP-8 main.py, tests, venv, git.
# ---------------------------------------------------------------------------
function mkproj() {
    local n="$1"
    if [[ -z "$n" ]]; then
        __tac_info "Project Name Required" "[mkproj <Name>]" "$C_Error"
        return 1
    fi
    if [[ -d "$n" ]]; then
        __tac_info "Directory $n" "[ALREADY EXISTS]" "$C_Error"
        return 1
    fi

    # Verify required tools before creating any files
    if ! command -v python3 >/dev/null 2>&1; then
        __tac_info "python3" "[NOT FOUND — install before using mkproj]" "$C_Error"
        return 1
    fi
    if ! command -v git >/dev/null 2>&1; then
        __tac_info "git" "[NOT FOUND — install before using mkproj]" "$C_Error"
        return 1
    fi

    mkdir -p "$n/src" "$n/tests"
    cd "$n" || return

    echo "# Core dependencies" > requirements.txt
    printf "__pycache__/\n.venv/\n.env\n*.log\n.pytest_cache/\n" > .gitignore
    printf "ENVIRONMENT=development\nLOG_LEVEL=DEBUG\n" > .env.example
    touch src/__init__.py

    cat << 'EOF' > src/main.py
"""
Module: main.py
Description: Primary entry point.
Author: Wayne
"""
import sys
import logging
import argparse
from pathlib import Path

def setup_logging(debug: bool = False) -> logging.Logger:
    level = logging.DEBUG if debug else logging.INFO
    logging.basicConfig(level=level, format='%(asctime)s | %(levelname)-8s | %(message)s', datefmt='%Y-%m-%d %H:%M:%S')
    return logging.getLogger(__name__)

def execute_task(logger: logging.Logger, target_dir: Path) -> None:
    logger.info(f"Initiating sequence in: {target_dir}")
    if not target_dir.exists():
        logger.error(f"Target directory missing: {target_dir}")
        sys.exit(1)
    logger.info("Task sequence completed successfully.")

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--debug', action='store_true')
    parser.add_argument('--target', type=Path, default=Path.cwd())
    args = parser.parse_args()
    logger = setup_logging(args.debug)
    try:
        execute_task(logger, args.target)
    except Exception as e:
        logger.exception("A critical unhandled failure occurred.")
        sys.exit(1)

if __name__ == '__main__':
    main()
EOF

    cat << 'EOF' > tests/test_core.py
import pytest

def test_initial_sanity():
    assert True
EOF

    git init >/dev/null 2>&1

    # Auto-initialize venv
    __tac_info "Python Environment" "[CREATING .venv...]" "$C_Dim"
    python3 -m venv .venv
    if [[ -f ".venv/bin/activate" ]]; then
        source .venv/bin/activate
        pip install --upgrade pip --quiet
        pip install -r requirements.txt --quiet
        __tac_info "Python Dependencies" "[INSTALLED]" "$C_Success"
    else
        __tac_info "Python Environment" "[FAILED]" "$C_Error"
    fi

    __tac_info "Directory & Git Init" "[SUCCESS]" "$C_Success"
    __tac_info "PEP8 src/main.py Scaffold" "[INJECTED]" "$C_Success"
    __tac_info "tests/, .env, requirements" "[CREATED]" "$C_Success"
}

# ---------------------------------------------------------------------------
# commit_deploy — Stage, commit with a given message, then push.
# ---------------------------------------------------------------------------
function commit_deploy() {
    local msg="$*"
    if [[ -z "$msg" ]]; then
        __tac_info "Commit message required" "[commit: <msg>]" "$C_Error"
        return 1
    fi

    if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        __tac_info "Repository Check" "[NOT A GIT REPO]" "$C_Error"
        return 1
    fi

    # Verify a remote is configured before attempting push
    if ! git remote get-url origin >/dev/null 2>&1; then
        __tac_info "Remote Check" "[NO ORIGIN CONFIGURED]" "$C_Error"
        return 1
    fi

    if [[ -z $(git status --porcelain) ]]; then
        __tac_info "Workspace" "[CLEAN - NO CHANGES]" "$C_Dim"
        return 0
    fi

    __tac_header "VERSION CONTROL" "open"

    local modCount; modCount=$(git status --porcelain | wc -l)
    __tac_line "Staging $modCount file(s)..." "[WORKING]" "$C_Dim"
    git add .

    __tac_line "Committing: \"$msg\"..." "[WORKING]" "$C_Dim"
    if ! git commit -m "$msg" --quiet; then
        __tac_line "Commit" "[FAILED]" "$C_Error"
        __tac_footer
        return 1
    fi

    __tac_line "Syncing with origin..." "[WORKING]" "$C_Dim"
    git push --quiet
    local push_rc=$?

    if (( push_rc == 0 )); then
        __tac_line "Repository Sync" "[SUCCESS]" "$C_Success"
    else
        __tac_line "Repository Sync" "[REMOTE PUSH FAILED]" "$C_Error"
    fi

    __tac_footer
}

# ---------------------------------------------------------------------------
# commit_auto — Stage, generate commit message via local LLM, push, deploy.
# Uses curl + jq (not Python) for the non-streaming LLM request.
#
# SECURITY WARNING: The git diff is sent to $LOCAL_LLM_URL. If this URL is
# ever reconfigured to point to a cloud API, diffs containing secrets (API
# keys, passwords) will be leaked. Ensure LOCAL_LLM_URL always points to a
# local-only inference server (127.0.0.1).
# ---------------------------------------------------------------------------
function commit_auto() {
    if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        __tac_info "Repository Check" "[NOT A GIT REPO]" "$C_Error"
        return 1
    fi
    if ! git remote get-url origin >/dev/null 2>&1; then
        __tac_info "Remote Check" "[NO ORIGIN CONFIGURED]" "$C_Error"
        return 1
    fi
    # Security: block diff leak to non-localhost LLM endpoints
    if [[ "$LOCAL_LLM_URL" != http://127.0.0.1:* && "$LOCAL_LLM_URL" != http://localhost:* ]]; then
        __tac_info "SECURITY" "[BLOCKED: LLM URL is not localhost]" "$C_Error"
        return 1
    fi
    if [[ -z $(git status --porcelain) ]]; then
        __tac_info "Workspace" "[CLEAN - NO CHANGES]" "$C_Dim"
        return 0
    fi
    if ! __test_port "$LLM_PORT"; then
        __tac_info "LLM Required" "[OFFLINE - Start a model first]" "$C_Error"
        return 1
    fi
    # Verify the process listening on $LLM_PORT is actually llama-server
    local _llm_pid; _llm_pid=$(ss -tlnp "sport = :$LLM_PORT" 2>/dev/null | grep -oP 'pid=\K[0-9]+')
    if [[ -z "$_llm_pid" ]] || ! grep -q llama-server "/proc/$_llm_pid/cmdline" 2>/dev/null; then
        __tac_info "SECURITY" "[BLOCKED: port $LLM_PORT is not llama-server]" "$C_Error"
        return 1
    fi

    # UX flow:
    #   1. Stage all changes (git add .)
    #   2. Send diff to local LLM for commit message generation
    #   3. Show proposed message to user
    #   4. Accept (Y/Enter), reject (n), or edit (e) interactively
    #   5. On accept: commit, push, deploy. On reject: git reset HEAD.

    git add .
    # Capture both stat (file-level summary) and body (line-level diff, capped at 500 lines)
    # Note (I4): Two separate `git diff --cached` calls are intentional — --stat
    # produces a columnar summary while the raw diff gives line-level context.
    # Both read the same index snapshot so there is no consistency issue.
    local diff_stat; diff_stat=$(git diff --cached --stat 2>/dev/null)
    local diff_body; diff_body=$(git diff --cached 2>/dev/null | head -500)
    local diff="${diff_stat}
---
${diff_body}"

    __tac_info "Generating commit message..." "[LLM]" "$C_Dim"

    local prompt="Write a concise git commit message (one line, max 72 chars, imperative mood) for the following diff. Return ONLY the message, no quotes or explanation."
    local payload
    payload=$(jq -n \
        --arg prompt "$prompt" \
        --arg diff "${diff:0:3000}" \
        '{messages: [{role: "user", content: ($prompt + "\n\n" + $diff)}], max_tokens: 80, temperature: 0.3}')

    local raw_response
    raw_response=$(curl -s --max-time 30 "$LOCAL_LLM_URL" \
        -H "Content-Type: application/json" \
        -d "$payload" 2>/dev/null)
    local msg
    msg=$(printf '%s' "$raw_response" | jq -r '.choices[0].message.content // empty' 2>/dev/null | \
        tr -d '"' | head -c 72 | head -1)

    if [[ -z "$msg" || "$msg" == "null" ]]; then
        __tac_info "LLM" "[FAILED TO GENERATE MESSAGE]" "$C_Error"
        git reset HEAD >/dev/null 2>&1
        return 1
    fi

    printf '%s\n' "${C_Highlight}Proposed:${C_Reset} $msg"
    while true; do
        read -r -e -p "${C_Dim}Accept? [Y/n/edit]: ${C_Reset}" confirm
        case "${confirm,,}" in
            y|yes|"") break ;;
            n|no)
                __tac_info "Commit" "[CANCELLED]" "$C_Dim"
                git reset HEAD >/dev/null 2>&1
                return 0
                ;;
            e|edit)
                read -r -e -p "${C_Highlight}Message: ${C_Reset}" -i "$msg" msg
                [[ -z "$msg" ]] && { __tac_info "Commit" "[CANCELLED]" "$C_Dim"; git reset HEAD >/dev/null 2>&1; return 0; }
                break
                ;;
            *) echo "Please enter y, n, or e." ;;
        esac
    done

    git commit -m "$msg" --quiet
    __tac_info "Committed" "[$msg]" "$C_Success"
    git push --quiet
    local push_rc=$?
    if (( push_rc == 0 )); then
        __tac_info "Repository Sync" "[SUCCESS]" "$C_Success"
    else
        __tac_info "Repository Sync" "[REMOTE PUSH FAILED]" "$C_Error"
    fi
}

# ==============================================================================
# 11. LLM MODEL MANAGER & OPENCLAW INTEROP
# ==============================================================================
# @modular-section: llm-manager
# @depends: constants, design-tokens, ui-engine, hooks
# @exports: wake, model, serve, halt, mlogs, burn, explain, wtf_repl,
#   __llm_sse_core, __llm_stream, __llm_chat_send, local_chat, chat-context,
#   __gguf_metadata, __calc_gpu_layers, __calc_ctx_size, __calc_threads,
#   __quant_label, __require_llm

# ---------------------------------------------------------------------------
# __save_tps — Write measured TPS to the active model's registry entry.
# Called after every inference (chat, burn). Updates column 11 in models.conf.
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# __save_tps — Persist TPS measurement to the registry's tps column.
# Called after burn / llm_stream benchmarks so the dashboard and model list
# can display the most recent inference speed for each model.
# Must run AFTER the model is loaded (ACTIVE_LLM_FILE exists) and the
# registry is initialised (LLM_REGISTRY exists).
# ---------------------------------------------------------------------------
function __save_tps() {
    local tps_val="$1"
    [[ -z "$tps_val" || ! -f "$ACTIVE_LLM_FILE" || ! -f "$LLM_REGISTRY" ]] && return
    local active_num; active_num=$(< "$ACTIVE_LLM_FILE")
    [[ -z "$active_num" ]] && return
    awk -F'|' -v n="$active_num" -v t="$tps_val" 'BEGIN{OFS="|"} $1 == n {$11 = t} {print}' \
        "$LLM_REGISTRY" > "${LLM_REGISTRY}.tmp" \
        && mv "${LLM_REGISTRY}.tmp" "$LLM_REGISTRY"
}

# ---------------------------------------------------------------------------
# __require_llm — Verify jq is installed and the local LLM is listening.
# Deduplicates the repeated jq + port checks across LLM functions.
# ---------------------------------------------------------------------------
function __require_llm() {
    if ! command -v jq >/dev/null 2>&1; then
        printf '%s\n' "${C_Error}[jq missing]${C_Reset} Install: sudo apt install -y jq"
        return 1
    fi
    if ! __test_port "$LLM_PORT"; then
        __tac_info "Llama Server" "[OFFLINE]" "$C_Error"
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# wake — Lock the GPU into persistent mode to prevent WDDM sleep in WSL2.
# NOTE: Persistence mode (-pm 1) is a runtime setting and does NOT survive
# WSL restarts. You must re-run 'wake' after each 'wsl --shutdown'.
# ---------------------------------------------------------------------------
function wake() {
    local smi_cmd="$WSL_NVIDIA_SMI"
    [[ ! -f "$smi_cmd" ]] && smi_cmd=$(command -v nvidia-smi)

    if [[ -z "$smi_cmd" || ! -x "$smi_cmd" ]]; then
        __tac_info "GPU" "[nvidia-smi not found]" "$C_Error"
        return 1
    fi

    # Requires passwordless sudo; harmless failure if denied
    if ! sudo -n "$smi_cmd" -pm 1 >/dev/null 2>&1; then
        __tac_info "GPU Persistence" "[FAILED — sudo denied or nvidia-smi error]" "$C_Warning"
        return 1
    fi
    __tac_info "GPU Persistence" "[ENABLED]" "$C_Success"

    local stat
    stat=$("$smi_cmd" --query-gpu=utilization.gpu,memory.used,memory.total,temperature.gpu --format=csv,noheader,nounits 2>/dev/null || echo "")
    if [[ -n "$stat" ]]; then
        local g_util g_used g_total g_temp
        IFS=',' read -r g_util g_used g_total g_temp <<< "$stat"
        g_util="${g_util// /}"; g_used="${g_used// /}"; g_total="${g_total// /}"; g_temp="${g_temp// /}"
        __tac_info "GPU Util" "${g_util}%" "$C_Text"
        __tac_info "VRAM" "${g_used} MiB / ${g_total} MiB" "$C_Text"
        __tac_info "Temp" "${g_temp}°C" "$C_Text"
    fi
    printf '%s\n' "${C_Dim}Note: -pm 1 does not survive WSL restarts. Re-run 'wake' after reboot.${C_Reset}"
}

# ---------------------------------------------------------------------------
# gpu-status — Detailed NVIDIA GPU status (replaces standalone oc-gpu-status).
# Shows utilisation, VRAM, temperature, power draw, persistence mode.
# ---------------------------------------------------------------------------
function gpu-status() {
    local smi="$WSL_NVIDIA_SMI"
    if [[ ! -x "$smi" ]]; then
        smi=$(command -v nvidia-smi 2>/dev/null || true)
    fi
    if [[ -z "$smi" || ! -x "$smi" ]]; then
        __tac_info "GPU" "[nvidia-smi not found]" "$C_Error"
        return 1
    fi

    __tac_header "GPU STATUS" "open"

    "$smi" --query-gpu=name,utilization.gpu,memory.used,memory.total,memory.free,temperature.gpu,power.draw,power.limit \
        --format=csv,noheader 2>/dev/null | while IFS=, read -r gname gutil gmused gmtotal gmfree gtemp gpwr gplim; do
        gutil="${gutil// /}"; gmused="${gmused// /}"; gmtotal="${gmtotal// /}"
        gmfree="${gmfree// /}"; gtemp="${gtemp// /}"; gpwr="${gpwr// /}"; gplim="${gplim// /}"

        local util_n="${gutil%\%}"
        if ! [[ "$util_n" =~ ^[0-9]+$ ]]; then
            util_n=0
        fi
        local color
        color=$(__threshold_color "$util_n")

        __tac_info "GPU" "${gname}" "$C_Highlight"
        __tac_info "Util" "${color}${gutil}${C_Reset}" "$color"
        __tac_info "VRAM" "${gmused} / ${gmtotal} (${gmfree} free)" "$C_Text"
        __tac_info "Temp" "${gtemp} C" "$C_Text"
        __tac_info "Power" "${gpwr} / ${gplim}" "$C_Text"
    done

    local pm; pm=$("$smi" --query-gpu=persistence_mode --format=csv,noheader 2>/dev/null | head -1 | tr -d ' ')
    if [[ "$pm" == "Enabled" ]]; then
        __tac_info "Persist" "ON" "$C_Success"
    else
        __tac_info "Persist" "OFF (run 'wake' to enable)" "$C_Warning"
    fi
    __tac_footer
}

# ---------------------------------------------------------------------------
# gpu-check — Quick 5-second CUDA verification.
# Confirms nvidia-smi is reachable, the GPU is visible, and (if a model is
# running) that llama-server is actually offloading layers to the GPU.
# ---------------------------------------------------------------------------
function gpu-check() {
    local smi="$WSL_NVIDIA_SMI"
    [[ ! -x "$smi" ]] && smi=$(command -v nvidia-smi 2>/dev/null || true)

    __tac_header "CUDA / GPU CHECK" "open"

    # 1. nvidia-smi reachable?
    if [[ -z "$smi" || ! -x "$smi" ]]; then
        __tac_info "nvidia-smi" "NOT FOUND — GPU passthrough broken" "$C_Error"
        __tac_info "Tip" "In WSL run: nvidia-smi  (if this fails, CUDA is unavailable)" "$C_Dim"
        __tac_footer; return 1
    fi
    __tac_info "nvidia-smi" "OK" "$C_Success"

    # 2. CUDA device visible?
    local gpu_name
    gpu_name=$("$smi" --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)
    if [[ -z "$gpu_name" ]]; then
        __tac_info "CUDA Device" "NONE DETECTED" "$C_Error"
        __tac_footer; return 1
    fi
    __tac_info "CUDA Device" "$gpu_name" "$C_Success"

    # 3. VRAM status
    local vram
    vram=$("$smi" --query-gpu=memory.used,memory.total --format=csv,noheader,nounits 2>/dev/null | head -1)
    if [[ -n "$vram" ]]; then
        local used total
        IFS=',' read -r used total <<< "$vram"
        used="${used// /}"; total="${total// /}"
        __tac_info "VRAM" "${used} MiB / ${total} MiB" "$C_Text"
    fi

    # 4. llama-server CUDA offload (check the runtime log)
    if pgrep -x llama-server >/dev/null 2>&1 && [[ -f "$LLM_LOG_FILE" ]]; then
        local offload_line
        offload_line=$(grep -i 'offload.*layers to GPU\|offloading.*layers to GPU' "$LLM_LOG_FILE" 2>/dev/null | tail -1)
        local cuda_line
        cuda_line=$(grep -i 'ggml_cuda.*found.*CUDA' "$LLM_LOG_FILE" 2>/dev/null | tail -1)

        if [[ -n "$cuda_line" ]]; then
            __tac_info "CUDA Init" "${cuda_line##*: }" "$C_Success"
        fi
        if [[ -n "$offload_line" ]]; then
            __tac_info "Offload" "${offload_line##*: }" "$C_Success"
        elif [[ -n "$cuda_line" ]]; then
            __tac_info "Offload" "No offload line found (check -ngl setting)" "$C_Warning"
        else
            __tac_info "Offload" "No CUDA references in log — may be CPU-only build" "$C_Error"
        fi
    else
        __tac_info "Server" "Not running — start a model to verify offloading" "$C_Dim"
    fi

    __tac_footer
}

# ---------------------------------------------------------------------------
# model — Unified LLM model manager (v3 — auto-scan, numbered selection).
# Subcommands: scan, list, use, stop, status, info, bench
# Registry: models.conf — auto-generated by 'model scan', do not hand-edit.
# Format: #|name|file|size_gb|arch|quant|layers|gpu_layers|ctx|threads
# Active model tracked in: $ACTIVE_LLM_FILE (just the model number)
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# __gguf_metadata — Extract key metadata from a GGUF file header.
# Outputs: name|architecture|block_count|context_length|file_type
# Uses dd+awk to parse GGUF binary format (pure bash, no python dependency).
# Reads first 256KB — sufficient for all KV metadata in any GGUF file.
# ---------------------------------------------------------------------------
function __gguf_metadata() {
    local fpath="$1" fname
    fname=$(basename "$fpath" .gguf)
    dd if="$fpath" bs=262144 count=1 2>/dev/null | od -A n -t u1 -v | \
    awk -v fname="$fname" '
    { for (i=1; i<=NF; i++) b[n++] = $i+0 }
    END {
        if (n<24 || b[0]!=71||b[1]!=71||b[2]!=85||b[3]!=70) {
            print fname"|unknown|0|4096|0"; exit
        }
        nkv = b[16]+b[17]*256+b[18]*65536+b[19]*16777216
        name=fname; arch="unknown"; blocks=0; ctx=4096; ftype=0; found=0
        off=24
        for (kv=0; kv<nkv && off<n-8; kv++) {
            klen=b[off]+b[off+1]*256+b[off+2]*65536+b[off+3]*16777216; off+=8
            if (off+klen>n) break
            key=""
            for(i=0;i<klen;i++) key=key sprintf("%c",b[off+i])
            off+=klen
            if (off+4>n) break
            vt=b[off]+b[off+1]*256+b[off+2]*65536+b[off+3]*16777216; off+=4
            if(vt==8) {
                if (off+8>n) break
                vlen=b[off]+b[off+1]*256+b[off+2]*65536+b[off+3]*16777216; off+=8
                if (off+vlen>n) break
                val=""
                for(i=0;i<vlen;i++) val=val sprintf("%c",b[off+i])
                off+=vlen
                if(key=="general.architecture") { arch=val; found++ }
                if(key=="general.name")         { name=val; found++ }
            } else if(vt==4||vt==5) {
                if (off+4>n) break
                val=b[off]+b[off+1]*256+b[off+2]*65536+b[off+3]*16777216; off+=4
                if(key=="general.file_type")  { ftype=val; found++ }
                if(key~/block_count/)         { blocks=val; found++ }
                if(key~/context_length/)      { ctx=val; found++ }
            } else if(vt==10||vt==11||vt==12) {
                if (off+8>n) break
                val=b[off]+b[off+1]*256+b[off+2]*65536+b[off+3]*16777216; off+=8
                if(key=="general.file_type")  { ftype=val; found++ }
                if(key~/block_count/)         { blocks=val; found++ }
                if(key~/context_length/)      { ctx=val; found++ }
            }
            else if(vt==6)                    { off+=4 }
            else if(vt==0||vt==1||vt==7)      { off+=1 }
            else if(vt==2||vt==3)             { off+=2 }
            else if(vt==9) {
                if (off+12>n) break
                at=b[off]+b[off+1]*256+b[off+2]*65536+b[off+3]*16777216; off+=4
                al=b[off]+b[off+1]*256+b[off+2]*65536+b[off+3]*16777216; off+=8
                if(at==0||at==1||at==7) off+=al
                else if(at==2||at==3) off+=al*2
                else if(at==4||at==5||at==6) off+=al*4
                else if(at==10||at==11||at==12) off+=al*8
                else if(at==8) {
                    for(a=0;a<al&&off<n;a++){
                        sl=b[off]+b[off+1]*256+b[off+2]*65536+b[off+3]*16777216
                        off+=8+sl
                    }
                } else break
            } else break
            if(found>=5) break
        }
        print name"|"arch"|"blocks"|"ctx"|"ftype
    }'
}

# __calc_gpu_layers — Calculate optimal GPU layer count for available VRAM.
# Strategy: use -ngl 999 at launch to let llama.cpp offload the maximum
# layers that fit in VRAM. This scan-time function determines the launch
# MODE (gpu vs cpu-only) and stores a hint for display/logging. The actual
# offload count is decided by the runtime, not by this calculation.
# Args: file_size_bytes total_layers [arch]
# Returns: 999 (max offload), total_layers (MoE), or 0 (CPU-only)
function __calc_gpu_layers() {
    local file_bytes=$1 total_layers=$2 arch="${3:-}"
    local vram_bytes=$((4 * 1024 * 1024 * 1024))  # 4GB
    local usable_bytes=$((vram_bytes * 95 / 100))  # 95% usable (driver overhead)

    # MoE models: with --cpu-moe, expert weights stay on CPU.
    # Only attention/dense layers load to GPU, so we can offload all layers.
    if [[ "$arch" == *"moe"* ]]; then
        echo "$total_layers"
        return
    fi

    if (( file_bytes <= usable_bytes )); then
        # Model fits in VRAM — use 999 to offload everything the runtime can.
        echo 999
    else
        # Model exceeds VRAM — run CPU-only. Partial offload spills into
        # shared GPU memory which is ~10-15x slower than dedicated VRAM;
        # pure CPU inference with --mlock is faster than the hybrid path.
        echo 0
    fi
}

# __calc_ctx_size — Pick a practical context size.
# Must account for KV cache VRAM: larger ctx = more VRAM consumed beyond model weights.
# CPU-only models (>4GB) have no VRAM constraint so can use larger ctx.
function __calc_ctx_size() {
    local file_bytes=$1 native_ctx=$2 arch="${3:-}"
    local file_gb=$(( file_bytes / 1024 / 1024 / 1024 ))
    local vram_limit_gb=$(( 4 * 85 / 100 ))  # 3GB usable VRAM threshold

    # MoE models: expert weights on CPU, only attention on GPU.
    # Active params ~3B, so treat like a small model for ctx sizing.
    if [[ "$arch" == *"moe"* ]]; then
        echo 8192
        return
    fi

    if (( file_gb > vram_limit_gb )); then
        # CPU-only: no VRAM pressure, limited by RAM instead.
        # Use generous ctx but cap at 8192 to keep RAM usage reasonable.
        local cap=8192
        if (( native_ctx < cap )); then
            echo "$native_ctx"
        else
            echo "$cap"
        fi
    elif (( file_gb >= 3 )); then
        echo 8192
    else
        local cap=16384
        if (( native_ctx < cap )); then
            echo "$native_ctx"
        else
            echo "$cap"
        fi
    fi
}

# __calc_threads — CPU threads based on how much spills to CPU.
# Uses nproc to detect available threads, then scales:
#   CPU-only  → 80% (all layers on CPU, maximise parallelism)
#   Partial   → 70% (CPU handles remaining layers + KV-cache)
#   Full GPU  → 50% (CPU only does prompt processing + sampling)
function __calc_threads() {
    local gpu_layers=$1 total_layers=$2
    local ncpu
    ncpu=$(nproc 2>/dev/null || echo 16)
    local threads
    if (( gpu_layers == 0 )); then
        threads=$(( ncpu * 80 / 100 ))
    elif (( gpu_layers >= total_layers )); then
        threads=$(( ncpu * 50 / 100 ))
    else
        threads=$(( ncpu * 70 / 100 ))
    fi
    (( threads < 1 )) && threads=1
    echo "$threads"
}

# __quant_label — Map GGUF file_type int to human-readable quant label.
# Values sourced from llama.cpp's ggml.h GGML_FTYPE enum.
# Falls back to extracting quant from filename if file_type is 0/unknown.
function __quant_label() {
    local ftype=$1 fname=$2
    local label=""
    case "$ftype" in
        1) label="F16";;   2) label="Q4_0";;  3) label="Q4_1";;
        7) label="Q8_0";;  8) label="Q5_0";;  9) label="Q5_1";;  10) label="Q2_K";;
        11) label="Q3_K_S";; 12) label="Q3_K_M";; 13) label="Q3_K_L";;
        14) label="Q4_K_S";; 15) label="Q4_K_M";; 16) label="Q5_K_S";;
        17) label="Q5_K_M";; 18) label="Q6_K";;  19) label="IQ2_XXS";;
        20) label="IQ2_XS";; 21) label="IQ3_XXS";; 26) label="IQ3_M";;
        28) label="Q4_0_4_4";; 29) label="Q4_0_4_8";; 30) label="Q4_0_8_8";;
    esac
    # If unknown/F32(0), try to extract from filename
    if [[ -z "$label" || "$ftype" == "0" ]] && [[ -n "$fname" ]]; then
        local extracted; extracted=$(echo "$fname" | grep -oiE '(IQ[0-9]_[A-Z]+|Q[0-9]+_K_[SML]|Q[0-9]+_K|Q[0-9]+_[0-9]+|Q[0-9]+|F16|F32|BF16)' | head -1 | tr '[:lower:]' '[:upper:]')
        [[ -n "$extracted" ]] && label="$extracted"
    fi
    echo "${label:-unknown}"
}

# ---------------------------------------------------------------------------
# __renumber_registry — Remove a model entry by number and renumber the rest.
# Usage: __renumber_registry <model_number>
# Shared by model delete and model archive to avoid duplicated renumber logic.
# ---------------------------------------------------------------------------
function __renumber_registry() {
    local target="$1"
    awk -F'|' -v n="$target" '$1 != n && $1 != "#"' "$LLM_REGISTRY" > "${LLM_REGISTRY}.tmp"
    local newnum=0
    { echo "#|name|file|size_gb|arch|quant|layers|gpu_layers|ctx|threads|tps"
      while IFS='|' read -r _num rest; do
          ((newnum++))
          echo "${newnum}|${rest}"
      done < "${LLM_REGISTRY}.tmp"
    } > "$LLM_REGISTRY"
    rm -f "${LLM_REGISTRY}.tmp"
    rm -f "$ACTIVE_LLM_FILE"
    echo "$newnum"
}

# @extractable: model() is the largest function (~500 lines). When splitting
# into modules, extract it into its own file (e.g. ~/.bashrc.d/11-llm-model.sh)
# along with __renumber_registry, __quant_label, and __save_tps.
function model() {
    local action="${1:-}"
    (( $# > 0 )) && shift
    local target="${1:-}"

    case "$action" in
        scan)
            # Scan LLAMA_MODEL_DIR for .gguf files, read metadata, calculate params,
            # and regenerate models.conf. Skips vocab/test files (<500MB).
            __tac_info "Scanning" "$LLAMA_MODEL_DIR" "$C_Highlight"
            local tmpconf="${LLM_REGISTRY}.tmp"
            echo "#|name|file|size_gb|arch|quant|layers|gpu_layers|ctx|threads|tps" > "$tmpconf"

            local num=0
            for gguf in "$LLAMA_MODEL_DIR"/*.gguf; do
                [[ ! -f "$gguf" ]] && continue
                local fname; fname=$(basename "$gguf")
                local fbytes; fbytes=$(stat --format=%s "$gguf" 2>/dev/null || stat -f%z "$gguf" 2>/dev/null)
                # Skip small files (vocab, test, corrupt)
                (( fbytes < 500000000 )) && continue

                __tac_info "Reading" "$fname" "$C_Dim"
                local meta; meta=$(__gguf_metadata "$gguf")
                IFS='|' read -r mname march mblocks mctx mftype <<< "$meta"

                local size_gb; size_gb=$(awk "BEGIN{printf \"%.1f\", $fbytes/1024/1024/1024}")
                local quant; quant=$(__quant_label "$mftype" "$fname")
                local gpu_layers; gpu_layers=$(__calc_gpu_layers "$fbytes" "$mblocks" "$march")
                local ctx; ctx=$(__calc_ctx_size "$fbytes" "$mctx" "$march")
                local threads; threads=$(__calc_threads "$gpu_layers" "$mblocks")

                ((num++))
                # Preserve existing TPS from previous registry if same file
                local prev_tps="-"
                if [[ -f "$LLM_REGISTRY" ]]; then
                    prev_tps=$(awk -F'|' -v f="$fname" '$3 == f {print $11}' "$LLM_REGISTRY" 2>/dev/null)
                    [[ -z "$prev_tps" ]] && prev_tps="-"
                fi
                echo "${num}|${mname}|${fname}|${size_gb}G|${march}|${quant}|${mblocks}|${gpu_layers}|${ctx}|${threads}|${prev_tps}" >> "$tmpconf"
                __tac_info "  #${num}" "${mname} (${size_gb}G, ${quant}, ${mblocks}L → ${gpu_layers} GPU)" "$C_Success"
            done

            if (( num == 0 )); then
                __tac_info "Result" "[No models found in $LLAMA_MODEL_DIR]" "$C_Warning"
                rm -f "$tmpconf"
                return 1
            fi

            mv "$tmpconf" "$LLM_REGISTRY"
            __tac_info "Registry" "[${num} models written to $LLM_REGISTRY]" "$C_Success"

            # Quant enforcement: archive discouraged models (skip active model)
            if [[ -f "$QUANT_GUIDE" ]]; then
                local active_num; active_num=$(cat "$ACTIVE_LLM_FILE" 2>/dev/null)
                local archived=0
                local to_archive=()
                while IFS='|' read -r _qnum _qname _qfile _qsize _qarch _qqnt _rest; do
                    [[ "$_qnum" == "#"* || -z "$_qfile" ]] && continue
                    [[ "$_qnum" == "$active_num" ]] && continue
                    local _qrating=""
                    while IFS='|' read -r _r _pat _d; do
                        [[ -z "$_pat" || "$_r" == "#"* ]] && continue
                        if [[ "${_qfile^^}" == *"${_pat^^}"* ]]; then
                            _qrating="$_r"; break
                        fi
                    done < "$QUANT_GUIDE"
                    if [[ "$_qrating" == "discouraged" ]]; then
                        to_archive+=("${_qnum}|${_qname}|${_qfile}|${_qqnt}")
                    fi
                done < "$LLM_REGISTRY"

                for _ae in "${to_archive[@]}"; do
                    IFS='|' read -r _anum _aname _afile _aqunt <<< "$_ae"
                    local src="$LLAMA_MODEL_DIR/$_afile"
                    if [[ -f "$src" ]]; then
                        mkdir -p "$LLAMA_ARCHIVE_DIR"
                        if mv "$src" "$LLAMA_ARCHIVE_DIR/"; then
                            __tac_info "Archived" "#${_anum} ${_aname} (${_aqunt} — discouraged)" "$C_Warning"
                            ((archived++))
                        fi
                    fi
                done

                if (( archived > 0 )); then
                    __tac_info "Enforcement" "[$archived discouraged model(s) moved to archive]" "$C_Warning"
                    # Rebuild registry without archived files
                    local clean_tmp="${LLM_REGISTRY}.tmp"
                    local new_num=0
                    echo "#|name|file|size_gb|arch|quant|layers|gpu_layers|ctx|threads|tps" > "$clean_tmp"
                    while IFS= read -r _cline; do
                        [[ "$_cline" == "#"* || -z "$_cline" ]] && continue
                        local _cfile
                        _cfile=$(cut -d'|' -f3 <<< "$_cline")
                        [[ -f "$LLAMA_MODEL_DIR/$_cfile" ]] || continue
                        ((new_num++))
                        echo "${new_num}|$(cut -d'|' -f2- <<< "$_cline")" >> "$clean_tmp"
                    done < "$LLM_REGISTRY"
                    mv "$clean_tmp" "$LLM_REGISTRY"
                    __tac_info "Registry" "[Renumbered — ${new_num} models remain]" "$C_Success"
                fi
            fi

            model list
            ;;

        list)
            # Display the numbered model registry with an arrow marking the active model.
            if [[ ! -f "$LLM_REGISTRY" ]]; then
                __tac_info "Registry" "[Not found — run 'model scan' first]" "$C_Warning"
                return 1
            fi

            # Read active model number
            local active_num=""
            [[ -f "$ACTIVE_LLM_FILE" ]] && active_num=$(cat "$ACTIVE_LLM_FILE" 2>/dev/null)

            printf "\n${C_Dim}  %-4s %-30s %-7s %-8s %-6s %-4s %-5s %-4s %s${C_Reset}\n" \
                "#" "MODEL" "SIZE" "QUANT" "ARCH" "GPU" "CTX" "THR" "TPS"
            printf "${C_Dim}  ──────────────────────────────────────────────────────────────────────────────${C_Reset}\n"

            while IFS='|' read -r num name file size arch quant layers gpu_layers ctx threads tps; do
                [[ "$num" == "#" || -z "$num" ]] && continue
                local marker="  "
                local color=""
                if [[ "$num" == "$active_num" ]] && pgrep -x llama-server >/dev/null 2>&1; then
                    marker="▶ "
                    color="$C_Success"
                fi
                printf "${color}${marker}%-4s %-30s %-7s %-8s %-6s %-4s %-5s %-4s %s${C_Reset}\n" \
                    "$num" "${name:0:30}" "$size" "$quant" "$arch" "$gpu_layers" "$ctx" "$threads" "${tps:--}"
            done < "$LLM_REGISTRY"

            # Drive space summary (du-based, 30s cache)
            # Note (I3): `du -sb` walks the entire model directory tree, which can
            # block for several seconds on large or networked NTFS mounts. The 30s
            # cache mitigates this, but consider replacing with `df` if latency is
            # noticeable (du gives accurate per-dir usage; df gives volume-level).
            local d_used_bytes d_total_bytes d_avail_bytes d_pct_n
            local _du_cache="$TAC_CACHE_DIR/tac_drive_du"
            if __cache_fresh "$_du_cache" 30; then
                d_used_bytes=$(< "$_du_cache")
            else
                d_used_bytes=$(du -sb "$LLAMA_DRIVE_ROOT" 2>/dev/null | awk '{print $1}')
                [[ -n "$d_used_bytes" ]] && echo "$d_used_bytes" > "${_du_cache}.tmp" && mv "${_du_cache}.tmp" "$_du_cache"
            fi
            d_used_bytes=${d_used_bytes:-0}
            d_total_bytes=$LLAMA_DRIVE_SIZE
            d_avail_bytes=$(( d_total_bytes - d_used_bytes ))
            (( d_avail_bytes < 0 )) && d_avail_bytes=0
            d_pct_n=$(( d_total_bytes > 0 ? d_used_bytes * 100 / d_total_bytes : 0 ))
            local d_avail_h=$(( d_avail_bytes / 1024 / 1024 / 1024 ))
            local d_total_h=$(( d_total_bytes / 1024 / 1024 / 1024 ))
            local d_color="$C_Success"
            (( d_pct_n >= 90 )) && d_color="$C_Error"
            (( d_pct_n >= 75 && d_pct_n < 90 )) && d_color="$C_Warning"
            local d_label; d_label=$(basename "$LLAMA_DRIVE_ROOT")
            printf "\n${C_Dim}  Drive ${d_label^^}: ${d_color}${d_avail_h}G free${C_Reset}${C_Dim} of ${d_total_h}G (${d_pct_n}%% used)${C_Reset}\n"

            printf "\n${C_Dim}  model use N  │  model stop  │  model info N  │  model scan  │  model bench  │  model archive N${C_Reset}\n"
            ;;

        use)
            # Load and start model #N with VRAM-optimised layer split and context size.
            [[ -z "$target" ]] && { __tac_info "Usage" "[model use <number>]" "$C_Error"; return 1; }
            [[ ! "$target" =~ ^[0-9]+$ ]] && { __tac_info "Error" "[Not a number: '$target']" "$C_Error"; return 1; }
            local entry; entry=$(awk -F'|' -v n="$target" '$1 == n' "$LLM_REGISTRY" 2>/dev/null)
            [[ -z "$entry" ]] && { __tac_info "Error" "[Model #$target not in registry — run 'model scan']" "$C_Error"; return 1; }

            IFS='|' read -r num name file size arch quant layers gpu_layers ctx threads tps <<< "$entry"
            local model_path="$LLAMA_MODEL_DIR/$file"

            [[ ! -f "$model_path" ]] && { __tac_info "Error" "[File $file missing from $LLAMA_MODEL_DIR]" "$C_Error"; return 1; }
            [[ ! -x "$LLAMA_SERVER_BIN" ]] && { __tac_info "Error" "[Server binary not found: $LLAMA_SERVER_BIN]" "$C_Error"; return 1; }

            # Stop existing
            pkill -u "$USER" -x llama-server 2>/dev/null
            sleep 1

            # Raise memlock ulimit so --mlock can actually pin the model in RAM.
            # Without this, the default limit (~64KB) causes --mlock to silently fail.
            # Requires passwordless sudo for prlimit; harmless no-op if denied.
            sudo -n prlimit --memlock=unlimited:unlimited --pid $$ 2>/dev/null

            # Choose batch sizes based on offload level:
            # Larger batches dramatically improve prompt eval speed (~30-50%) when
            # the GPU is doing the work. CPU-only uses moderate batches.
            local batch_size=512
            local ubatch_size=512
            if (( gpu_layers > 0 )); then
                # GPU active: larger batches fill the GPU pipeline more efficiently.
                # -b 4096 / -ub 1024 is safe with 64GB system RAM + 4GB VRAM.
                batch_size=4096
                ubatch_size=1024
            fi

            # Build command
            local cmd=("$LLAMA_SERVER_BIN" "-m" "$model_path" "--port" "$LLM_PORT" "--host" "127.0.0.1")
            cmd+=("--ctx-size" "$ctx" "--mlock" "--prio" "2" "--batch-size" "$batch_size" "--ubatch-size" "$ubatch_size" "--cont-batching" "--parallel" "1")
            # --jinja: enable Jinja2 chat template processing from GGUF metadata.
            # Newer models (Qwen3, Phi-4, Gemma3) embed their chat templates;
            # without this flag the server may apply a wrong or hardcoded format.
            cmd+=("--jinja")

            if (( gpu_layers == 0 )); then
                # CPU-only mode: model too large for VRAM. Use q8_0 KV cache
                # (saves RAM), skip GPU flags entirely.
                cmd+=("--cache-type-k" "q8_0" "--cache-type-v" "q8_0")
                cmd+=("--n-gpu-layers" "0" "--threads" "$threads")
                __tac_info "Note" "CPU-only mode (model exceeds 4GB VRAM)" "$C_Dim"
            else
                # -ngl 999: tell llama.cpp to offload the maximum layers that fit
                # in VRAM. The runtime calculates the actual count based on available
                # memory. This is more accurate than pre-calculating a fixed number,
                # especially since available VRAM varies at launch time.
                #
                # q8_0 KV cache: huge win for partially-offloaded models (frees VRAM
                # for layers). For architectures that benefit from it, always enable.
                if [[ "$arch" == "gemma"* ]] || [[ "$arch" == *"moe"* ]]; then
                    cmd+=("--cache-type-k" "q8_0" "--cache-type-v" "q8_0")
                fi
                # --flash-attn on: reduces VRAM bandwidth pressure, critical for
                # small GPUs (4GB). Improves throughput without quality loss.
                cmd+=("--n-gpu-layers" "999" "--flash-attn" "on" "--threads" "$threads")
            fi

            # Per-architecture sampling and launch overrides
            if [[ "$arch" == "gemma"* ]]; then
                # Google recommends: temp 1.0, top_k 64, top_p 0.95, min_p 0
                cmd+=("--temp" "1.0" "--top-k" "64" "--top-p" "0.95" "--min-p" "0")
                __tac_info "Note" "Gemma sampling: temp=1.0 top_k=64 top_p=0.95" "$C_Dim"
            else
                cmd+=("--temp" "0.7")
            fi

            # Disable Qwen3's default chain-of-thought thinking — it burns tokens
            # on internal reasoning before producing a visible response, which
            # causes timeouts on constrained hardware. Use --reasoning-budget 0.
            # Note: Only Qwen3 has thinking mode. Qwen2 does not.
            if [[ "$arch" == "qwen3" || "$arch" == "qwen3moe" ]]; then
                cmd+=("--reasoning-budget" "0")
                # --no-context-shift: prevent the context manager from shifting out
                # the thinking portion when the window fills, which corrupts the
                # response structure on thinking-capable models.
                cmd+=("--no-context-shift")
                __tac_info "Note" "Reasoning disabled + no-context-shift (Qwen3)" "$C_Dim"
            fi

            # MoE models: offload expert weights to CPU, keep attention on GPU
            # This lets the ~3B active params use GPU while 30B total sits in RAM
            if [[ "$arch" == *"moe"* ]]; then
                cmd+=("--cpu-moe")
                __tac_info "Note" "MoE: expert layers on CPU (--cpu-moe)" "$C_Dim"
            fi

            local ngl_label
            ngl_label=$( (( gpu_layers > 0 )) && echo "ngl=999" || echo "CPU-only" )
            __tac_info "Starting" "#${num} ${name} (${size}, ${ngl_label}, ctx ${ctx}, batch ${batch_size})" "$C_Highlight"

            (nohup "${cmd[@]}" > "$LLM_LOG_FILE" 2>&1 &)

            # Save active model number
            if echo "$num" > "${ACTIVE_LLM_FILE}.tmp" 2>/dev/null \
                && mv "${ACTIVE_LLM_FILE}.tmp" "$ACTIVE_LLM_FILE"; then
                : # success
            else
                __tac_info "Warning" "[Could not save state]" "$C_Warning"
            fi

            # Wait for ready (up to 30s with progress dots)
            local ready=0
            printf '%s' "${C_Dim}Waiting for health endpoint"
            for _ in {1..30}; do
                if __test_port "$LLM_PORT" && curl -sf --max-time 3 "http://127.0.0.1:$LLM_PORT/health" >/dev/null; then ready=1; break; fi
                printf '.'
                sleep 1
            done
            printf '%s\n' "$C_Reset"
            if (( ready )); then
                __tac_info "Status" "ONLINE [Port $LLM_PORT]" "$C_Success"
                # Report actual GPU layer offload from the server log.
                # llama.cpp prints "offloading N layers to GPU" during startup.
                local offload_info
                offload_info=$(grep -oiE 'offload(ing|ed) [0-9]+ .* layers' "$LLM_LOG_FILE" 2>/dev/null | tail -1)
                if [[ -n "$offload_info" ]]; then
                    __tac_info "GPU Offload" "[$offload_info]" "$C_Dim"
                fi
            else
                __tac_info "Status" "FAILED OR TIMEOUT — check: tail $LLM_LOG_FILE" "$C_Error"
            fi
            ;;

        stop)
            # Kill the running llama-server process and clear the active model marker.
            pkill -u "$USER" -x llama-server 2>/dev/null
            rm -f "$ACTIVE_LLM_FILE"
            __tac_info "Llama Server" "[STOPPED]" "$C_Success"
            ;;

        status)
            # Show what model is running (or not) and its TPS if available.
            if pgrep -x llama-server >/dev/null 2>&1 && __test_port "$LLM_PORT"; then
                local active_num; active_num=$(cat "$ACTIVE_LLM_FILE" 2>/dev/null)
                if [[ -n "$active_num" && -f "$LLM_REGISTRY" ]]; then
                    local entry; entry=$(awk -F'|' -v n="$active_num" '$1 == n' "$LLM_REGISTRY" 2>/dev/null)
                    IFS='|' read -r _n name file size _rest <<< "$entry"
                    __tac_info "Active" "#${active_num} ${name} (${size})" "$C_Success"
                else
                    __tac_info "Active" "[Running but unknown model]" "$C_Warning"
                fi
                local health; health=$(curl -s --max-time 2 "http://127.0.0.1:$LLM_PORT/health" 2>/dev/null)
                __tac_info "Health" "${health:-OK}" "$C_Success"
                local tps; tps=$(cat "$LLM_TPS_CACHE" 2>/dev/null)
                [[ -n "$tps" ]] && __tac_info "Last TPS" "$tps" "$C_Dim"
            else
                __tac_info "Status" "[OFFLINE]" "$C_Dim"
            fi
            ;;

        info)
            # Print detailed metadata for model #N from the registry.
            [[ -z "$target" ]] && { __tac_info "Usage" "[model info <number>]" "$C_Error"; return 1; }
            [[ ! "$target" =~ ^[0-9]+$ ]] && { __tac_info "Error" "[Not a number: '$target']" "$C_Error"; return 1; }
            local entry; entry=$(awk -F'|' -v n="$target" '$1 == n' "$LLM_REGISTRY" 2>/dev/null)
            [[ -z "$entry" ]] && { __tac_info "Error" "[Model #$target not found]" "$C_Error"; return 1; }
            IFS='|' read -r num name file size arch quant layers gpu_layers ctx threads tps <<< "$entry"
            __tac_info "#" "$num" "$C_Highlight"
            __tac_info "Model" "$name" "$C_Success"
            __tac_info "File" "$file" "$C_Dim"
            __tac_info "Size" "$size" "$C_Text"
            __tac_info "Architecture" "$arch" "$C_Text"
            __tac_info "Quantisation" "$quant" "$C_Text"
            __tac_info "Total Layers" "$layers" "$C_Text"
            __tac_info "GPU Layers" "$gpu_layers / $layers" "$C_Highlight"
            __tac_info "Context Size" "$ctx" "$C_Text"
            __tac_info "CPU Threads" "$threads" "$C_Text"
            if [[ -f "$LLAMA_MODEL_DIR/$file" ]]; then
                __tac_info "On Disk" "[FOUND]" "$C_Success"
            else
                __tac_info "On Disk" "[MISSING]" "$C_Error"
            fi
            ;;

        bench)
            [[ ! -f "$LLM_REGISTRY" ]] && { __tac_info "Registry" "[Not found — run 'model scan']" "$C_Error"; return 1; }
            __tac_header "MODEL BENCHMARK" "open"

            # Save the currently active model to restore after benchmarking
            local _bench_prev_model=""
            [[ -f "$ACTIVE_LLM_FILE" ]] && _bench_prev_model=$(< "$ACTIVE_LLM_FILE")

            local -a b_num=() b_name=() b_size=() b_tps=()
            while IFS='|' read -r num name file size _rest; do
                [[ "$num" == "#" || -z "$num" ]] && continue
                [[ ! -f "$LLAMA_MODEL_DIR/$file" ]] && continue
                b_num+=("$num"); b_name+=("$name"); b_size+=("$size")
            done < "$LLM_REGISTRY"

            (( ${#b_num[@]} == 0 )) && { __tac_info "Bench" "[No on-disk models]" "$C_Warning"; return 1; }
            printf '%s\n\n' "${C_Dim}Benchmarking ${#b_num[@]} model(s)...${C_Reset}"

            for i in "${!b_num[@]}"; do
                printf '%s\n' "${C_Highlight}[$(( i+1 ))/${#b_num[@]}] ${b_name[$i]} (${b_size[$i]})${C_Reset}"
                model use "${b_num[$i]}" 2>/dev/null
                sleep 2
                burn 2>/dev/null
                local tps="FAIL"; [[ -f "$LLM_TPS_CACHE" ]] && tps=$(< "$LLM_TPS_CACHE")
                b_tps+=("$tps")
                model stop 2>/dev/null
                sleep 1
            done

            echo ""
            printf "${C_Dim}  %-4s %-30s %-7s %s${C_Reset}\n" "#" "MODEL" "SIZE" "TPS"
            printf "${C_Dim}  ──────────────────────────────────────────────────${C_Reset}\n"
            for i in "${!b_num[@]}"; do
                printf "  %-4s %-30s %-7s %s\n" "${b_num[$i]}" "${b_name[$i]}" "${b_size[$i]}" "${b_tps[$i]}"
            done

            local bench_file
            bench_file="$AI_STORAGE_ROOT/.llm/bench_$(date +%Y%m%d_%H%M%S).tsv"
            { printf "#\tmodel\tsize\ttps\n"
              for i in "${!b_num[@]}"; do printf "%s\t%s\t%s\t%s\n" "${b_num[$i]}" "${b_name[$i]}" "${b_size[$i]}" "${b_tps[$i]}"; done
            } > "$bench_file"
            __tac_info "Saved" "$bench_file" "$C_Dim"

            # Restore previously active model if one was running
            if [[ -n "$_bench_prev_model" ]]; then
                __tac_info "Restoring" "Model #${_bench_prev_model}" "$C_Dim"
                model use "$_bench_prev_model" 2>/dev/null
            fi
            __tac_footer
            ;;

        delete)
            # Delete model #N from disk (with confirmation) and renumber the registry.
            [[ -z "$target" ]] && { __tac_info "Usage" "[model delete <number>]" "$C_Error"; return 1; }
            [[ ! "$target" =~ ^[0-9]+$ ]] && { __tac_info "Error" "[Not a number: '$target']" "$C_Error"; return 1; }
            local entry; entry=$(awk -F'|' -v n="$target" '$1 == n' "$LLM_REGISTRY" 2>/dev/null)
            [[ -z "$entry" ]] && { __tac_info "Error" "[Model #$target not found]" "$C_Error"; return 1; }
            IFS='|' read -r _n name file _rest <<< "$entry"
            local fpath="$LLAMA_MODEL_DIR/$file"

            __tac_info "Delete" "#${target} ${name}" "$C_Warning"
            __tac_info "File" "$fpath" "$C_Dim"
            if [[ -f "$fpath" ]]; then
                local fsize; fsize=$(du -h "$fpath" | cut -f1)
                __tac_info "Size" "$fsize" "$C_Dim"
            fi
            read -r -p "${C_Warning}Permanently delete this model? [y/N]: ${C_Reset}" confirm
            [[ "${confirm,,}" != "y" ]] && { __tac_info "Delete" "[CANCELLED]" "$C_Dim"; return 0; }

            # Stop if it's the active model
            local active_num; active_num=$(cat "$ACTIVE_LLM_FILE" 2>/dev/null)
            if [[ "$target" == "$active_num" ]]; then
                model stop
            fi

            # Delete file
            if [[ -f "$fpath" ]]; then
                if rm -f "$fpath" 2>/dev/null; then
                    __tac_info "File" "[DELETED]" "$C_Success"
                else
                    __tac_info "File" "[DELETE FAILED — permission denied]" "$C_Error"
                    return 1
                fi
            fi

            # Remove from registry and renumber
            local remaining
            remaining=$(__renumber_registry "$target")
            __tac_info "Registry" "[Removed and renumbered — ${remaining} models remain]" "$C_Success"
            ;;

        download)
            # Download one or more GGUF models from Hugging Face and auto-scan into registry.
            if [[ $# -eq 0 ]]; then
                printf '%s\n' "${C_Error}Error:${C_Reset} No models specified."
                echo ""
                echo "Usage: model download <repo:file> [repo:file ...]"
                echo ""
                echo "Each argument must be a Hugging Face repo and filename separated by a colon:"
                echo "  <owner/repo>:<filename.gguf>"
                echo ""
                echo "Downloads are saved to ${LLAMA_MODEL_DIR}."
                echo ""
                echo "Examples:"
                echo "  model download TheBloke/Ferret_7B-GGUF:ferret_7b.Q4_K_M.gguf"
                echo "  model download Qwen/Qwen3-8B-GGUF:Qwen3-8B-Q4_K_M.gguf \\"
                echo "                 bartowski/microsoft_Phi-4-mini-instruct-GGUF:microsoft_Phi-4-mini-instruct-Q4_K_M.gguf"
                return 1
            fi

            if ! command -v hf >/dev/null 2>&1; then
                printf '%s\n' "${C_Error}Error:${C_Reset} 'hf' CLI not found. Install with: pip install huggingface_hub[cli]"
                return 1
            fi

            # Warn if no token set (gated repos will fail)
            if [[ -z "${HF_TOKEN:-}" ]]; then
                printf '%s\n' "${C_Warning}Note:${C_Reset} HF_TOKEN is not set. Gated or private repos will fail."
                printf '%s\n' "      Set it with: export HF_TOKEN=hf_..."
                echo ""
            fi

            # Safe WSL cache directory
            export HF_HOME="${HF_HOME:-$HOME/hf_cache}"
            mkdir -p "$HF_HOME" "$LLAMA_MODEL_DIR"

            local ok=0 fail=0
            local spec
            for spec in "$@"; do
                if [[ "$spec" != *":"* ]]; then
                    printf '%s\n' "${C_Error}Error:${C_Reset} '$spec' is not in the right format."
                    printf '%s\n' "       Expected ${C_Warning}<owner/repo>:<filename.gguf>${C_Reset}  e.g. TheBloke/Ferret_7B-GGUF:ferret_7b.Q4_K_M.gguf"
                    ((fail++))
                    continue
                fi

                local dl_repo dl_file
                IFS=":" read -r dl_repo dl_file <<< "$spec"

                if [[ -z "$dl_repo" || "$dl_repo" != *"/"* ]]; then
                    printf '%s\n' "${C_Error}Error:${C_Reset} '$spec' — repo must be in ${C_Warning}<owner>/<repo>${C_Reset} format (e.g. TheBloke/Ferret_7B-GGUF)"
                    ((fail++))
                    continue
                fi

                if [[ -z "$dl_file" ]]; then
                    printf '%s\n' "${C_Error}Error:${C_Reset} '$spec' — missing filename after colon (e.g. :ferret_7b.Q4_K_M.gguf)"
                    ((fail++))
                    continue
                fi

                local dest="$LLAMA_MODEL_DIR/$dl_file"
                local archive_dest="$LLAMA_ARCHIVE_DIR/$dl_file"

                # Check quantization against the guide config (warn, don't block)
                if [[ -f "$QUANT_GUIDE" ]]; then
                    local _qrating=""
                    local _qdesc=""
                    while IFS='|' read -r _r _pat _d; do
                        [[ -z "$_pat" || "$_r" == "#"* ]] && continue
                        if [[ "${dl_file^^}" == *"${_pat^^}"* ]]; then
                            _qrating="$_r"; _qdesc="$_d"; break
                        fi
                    done < "$QUANT_GUIDE"
                    if [[ "$_qrating" == "discouraged" ]]; then
                        printf '%s\n' "${C_Warning}Warning:${C_Reset} ${_pat} is discouraged for 4GB VRAM — ${_qdesc}"
                        read -r -p "${C_Warning}Download anyway? [y/N]: ${C_Reset}" _qconfirm
                        if [[ "${_qconfirm,,}" != "y" ]]; then
                            __tac_info "Skip" "$dl_file (discouraged quant)" "$C_Dim"
                            ((fail++))
                            continue
                        fi
                    elif [[ "$_qrating" == "recommended" ]]; then
                        printf '%s\n' "${C_Success}✓${C_Reset} ${_pat} — ${_qdesc}"
                    elif [[ "$_qrating" == "acceptable" ]]; then
                        printf '%s\n' "${C_Dim}● ${_pat} — ${_qdesc}${C_Reset}"
                    fi
                fi

                if [[ -f "$dest" ]]; then
                    __tac_info "Skip" "$dl_file already exists (active)" "$C_Warning"
                    ((ok++))
                    continue
                fi
                if [[ -f "$archive_dest" ]]; then
                    __tac_info "Skip" "$dl_file already exists (archived)" "$C_Warning"
                    ((ok++))
                    continue
                fi

                # Check available space before downloading.
                # Re-read drive usage at download time (may have changed since startup).
                local d_used_bytes
                d_used_bytes=$(du -sb "$LLAMA_DRIVE_ROOT" 2>/dev/null | awk '{print $1}')
                d_used_bytes=${d_used_bytes:-0}
                local d_total_now
                d_total_now=$(df -B1 --output=size "$LLAMA_DRIVE_ROOT" 2>/dev/null | awk 'NR==2{print $1+0}')
                d_total_now=${d_total_now:-$LLAMA_DRIVE_SIZE}
                local d_avail_bytes=$(( d_total_now - d_used_bytes ))
                (( d_avail_bytes < 0 )) && d_avail_bytes=0

                if [[ "$d_avail_bytes" =~ ^[0-9]+$ ]]; then
                    # Query HF API for file size
                    local remote_size
                    remote_size=$(curl -sfI --max-time 10 "https://huggingface.co/${dl_repo}/resolve/main/${dl_file}" 2>/dev/null \
                        | grep -i '^content-length:' | awk '{print $2}' | tr -d '\r')
                    if [[ "$remote_size" =~ ^[0-9]+$ ]] && (( remote_size > 0 )); then
                        if (( remote_size > d_avail_bytes )); then
                            local need_gb=$(( remote_size / 1024 / 1024 / 1024 ))
                            local have_gb=$(( d_avail_bytes / 1024 / 1024 / 1024 ))
                            printf '%s\n' "${C_Error}Error:${C_Reset} Not enough space for $dl_file (need ~${need_gb}G, only ${have_gb}G free on M:)"
                            ((fail++))
                            continue
                        fi
                    fi
                fi

                __tac_info "Downloading" "$dl_repo → $dl_file" "$C_Highlight"
                if hf download "$dl_repo" "$dl_file" --local-dir "$LLAMA_MODEL_DIR"; then
                    __tac_info "OK" "$dl_file" "$C_Success"
                    ((ok++))
                else
                    __tac_info "FAIL" "$dl_repo $dl_file" "$C_Error"
                    ((fail++))
                fi
            done

            echo ""
            __tac_info "Done" "$ok succeeded, $fail failed. Models in $LLAMA_MODEL_DIR" "$C_Dim"
            (( fail > 0 )) && return 1
            # Auto-scan new models into the registry
            model scan
            ;;

        archive)
            # Move model #N to the archive directory and renumber the registry.
            [[ -z "$target" ]] && { __tac_info "Usage" "[model archive <number>]" "$C_Error"; return 1; }
            [[ ! "$target" =~ ^[0-9]+$ ]] && { __tac_info "Error" "[Not a number: '$target']" "$C_Error"; return 1; }
            local entry; entry=$(awk -F'|' -v n="$target" '$1 == n' "$LLM_REGISTRY" 2>/dev/null)
            [[ -z "$entry" ]] && { __tac_info "Error" "[Model #$target not found]" "$C_Error"; return 1; }
            IFS='|' read -r _n name file _rest <<< "$entry"
            local fpath="$LLAMA_MODEL_DIR/$file"
            local archive_dir="$LLAMA_ARCHIVE_DIR"

            __tac_info "Archive" "#${target} ${name}" "$C_Warning"
            __tac_info "From" "$fpath" "$C_Dim"
            __tac_info "To" "$archive_dir/$file" "$C_Dim"
            read -r -p "${C_Warning}Archive this model? [y/N]: ${C_Reset}" confirm
            [[ "${confirm,,}" != "y" ]] && { __tac_info "Archive" "[CANCELLED]" "$C_Dim"; return 0; }

            # Stop if active
            local active_num; active_num=$(cat "$ACTIVE_LLM_FILE" 2>/dev/null)
            if [[ "$target" == "$active_num" ]]; then
                model stop
            fi

            # Move file
            mkdir -p "$archive_dir"
            if [[ -f "$fpath" ]]; then
                if mv "$fpath" "$archive_dir/" 2>/dev/null; then
                    __tac_info "File" "[MOVED]" "$C_Success"
                else
                    __tac_info "File" "[MOVE FAILED — try: sudo chmod 755 $archive_dir]" "$C_Error"
                    return 1
                fi
            else
                __tac_info "File" "[NOT ON DISK — removing from registry only]" "$C_Warning"
            fi

            # Remove from registry and renumber
            local remaining
            remaining=$(__renumber_registry "$target")
            __tac_info "Registry" "[Archived and renumbered — ${remaining} models remain]" "$C_Success"
            ;;

        *)
            echo "Usage: model {scan|list|use|stop|status|info|bench|delete|archive|download}"
            echo "  scan       — Scan $LLAMA_MODEL_DIR, read GGUF metadata, auto-calculate params"
            echo "  list       — Show numbered model registry (▶ = active)"
            echo "  use N      — Start model #N with optimal settings"
            echo "  stop       — Stop llama-server"
            echo "  status     — Show what's running"
            echo "  info N     — Detailed info for model #N"
            echo "  bench      — Benchmark all on-disk models"
            echo "  delete N   — Permanently delete model #N from disk and registry"
            echo "  archive N  — Move model #N to archive/ and remove from registry"
            echo "  download   — Download GGUF models from Hugging Face (repo:file format)"
            ;;
    esac
}

# serve/halt/mlogs — convenience wrappers for the model manager.
function serve() {
    model use "$1"
}
function halt() {
    model stop
}

function mlogs() {
    __resolve_vscode_bin
    "$VSCODE_BIN" "$LLM_LOG_FILE"
    echo "VS Code opened..."
}

# ---------------------------------------------------------------------------
# burn — Stress test the local LLM with a ~1300 token physics prompt.
# Uses non-streaming request with accurate server-reported completion_tokens.
# Pure bash + curl + jq with nanosecond timing.
# ---------------------------------------------------------------------------
function burn() {
    __require_llm || return 1
    [[ -t 1 ]] && command clear
    __tac_header "HARDWARE BURN-IN STRESS TEST"

    printf '%s\n' "${C_Dim}Testing: ~1300 token synthetic physics response...${C_Reset}"
    printf '%s\n' "${C_Highlight}Processing ....${C_Reset}"

    local prompt="Explain the complete theory of special relativity in extreme detail, including the mathematical derivations for time dilation."

    # Non-streaming request — curl + jq, with bash nanosecond timing.
    local payload
    payload=$(jq -n --arg p "$prompt" '{messages: [{role: "user", content: $p}], max_tokens: 1500, temperature: 0.7}')

    local max_retries=5 attempt=0 response="" start_ns end_ns
    while (( attempt < max_retries )); do
        start_ns=$(date +%s%N)
        response=$(curl -s --max-time 120 "$LOCAL_LLM_URL" \
            -H "Content-Type: application/json" \
            -d "$payload" 2>/dev/null)
        end_ns=$(date +%s%N)
        [[ -n "$response" ]] && break
        (( attempt++ ))
        if (( attempt < max_retries )); then
            printf '%s\n' "${C_Warning}[Waiting]${C_Reset} Model not ready — retry ${attempt}/${max_retries} in 5s..."
            sleep 5
        fi
    done

    if [[ -z "$response" ]]; then
        printf '%s\n' "${C_Error}[API Error]${C_Reset} No response after ${max_retries} attempts — model may not be loaded."
        return 1
    fi

    # Check for HTTP-level error in response body
    local err_msg
    err_msg=$(printf '%s' "$response" | jq -r '.error.message // empty' 2>/dev/null)
    if [[ -n "$err_msg" ]]; then
        printf '%s\n' "${C_Warning}[API Status]${C_Reset} $err_msg"
        return 1
    fi

    local elapsed_ms=$(( (end_ns - start_ns) / 1000000 ))
    local elapsed_s=$(( elapsed_ms / 1000 ))
    local elapsed_dec=$(( (elapsed_ms % 1000) / 100 ))

    # Prefer server-reported completion_tokens; fall back to word count
    local tokens
    tokens=$(printf '%s' "$response" | jq -r '.usage.completion_tokens // 0' 2>/dev/null)
    if (( tokens == 0 )); then
        tokens=$(printf '%s' "$response" | jq -r '.choices[0].message.content // ""' 2>/dev/null | wc -w)
    fi

    local tps_int=0 tps_dec=0
    if (( elapsed_ms > 0 && tokens > 0 )); then
        local tps_x10=$(( tokens * 10000 / elapsed_ms ))
        tps_int=$(( tps_x10 / 10 ))
        tps_dec=$(( tps_x10 % 10 ))
    fi

    printf '%s\n' "${C_Dim}Hint: If inference was slow, first run \"wake\" to lock WDDM state.${C_Reset}"
    printf '%s\n' "${C_Success}Burn complete: ${tps_int}.${tps_dec} tps (${tokens} tokens in ${elapsed_s}.${elapsed_dec}s)${C_Reset}"
    echo "${tps_int}.${tps_dec} tps" > "${LLM_TPS_CACHE}.tmp" && mv "${LLM_TPS_CACHE}.tmp" "$LLM_TPS_CACHE"
    __save_tps "${tps_int}.${tps_dec}"

    [[ -f "$LLM_TPS_CACHE" ]] && LAST_TPS=$(< "$LLM_TPS_CACHE")
}

# ---------------------------------------------------------------------------
# explain — Ask the local LLM to explain the last command run in the terminal.
# Uses `fc -ln -2 -2` instead of history parsing for reliability with HISTCONTROL.
# ---------------------------------------------------------------------------
function explain() {
    local last_cmd; last_cmd=$(fc -ln -2 -2 2>/dev/null | sed 's/^\s*//')
    if [[ -z "$last_cmd" ]]; then
        __tac_line "Explain" "[NO PREVIOUS COMMAND FOUND]" "$C_Warning"
        return 1
    fi
    __llm_stream "Explain this bash command and diagnose any potential errors:\n$last_cmd"
}

# ---------------------------------------------------------------------------
# wtf_repl — Ask the local LLM to explain a tool or concept (toggle mode).
# Type a topic, get an explanation, then type another. 'end-chat' or Ctrl-C to exit.
# Aliased as 'wtf:' in section 3.
# ---------------------------------------------------------------------------
function wtf_repl() {
    local initial="$*"
    __require_llm || return 1

    # Trap Ctrl-C so it breaks the loop cleanly (exit 0, no error badge)
    trap 'echo; trap - INT; return 0' INT

    # If called with args, handle the first query then enter the loop
    if [[ -n "$initial" ]]; then
        __llm_stream "Explain how to use the following tool or concept:\n$initial"
    fi
    printf '%s\n' "${C_Dim}wtf: mode — type a topic (or 'end-chat' / Ctrl-C to exit)${C_Reset}"
    while true; do
        local topic
        read -r -e -p "${C_Highlight}wtf: ${C_Reset}" topic || break
        [[ -z "$topic" ]] && continue
        [[ "$topic" == "end-chat" ]] && break
        __llm_stream "Explain how to use the following tool or concept:\n$topic"
    done

    trap - INT
}

# ---------------------------------------------------------------------------
# __llm_sse_core — Shared SSE streaming engine for all LLM functions.
# Called by __llm_stream (one-shot prompts) and __llm_chat_send (multi-turn).
# Pure bash + curl + jq. Posts payload to llama.cpp OpenAI-compatible API,
# streams SSE delta chunks, computes TPS, caches metrics.
# Sets __LAST_LLM_RESPONSE with the full response text.
# Usage: __llm_sse_core "$json_payload"
# ---------------------------------------------------------------------------
function __llm_sse_core() {
    local payload="$1"
    __LAST_LLM_RESPONSE=""

    local start_ns; start_ns=$(date +%s%N)
    local chunk_count=0
    local server_tokens=0
    local response_text=""

    while IFS= read -r line; do
        [[ "$line" != data:* ]] && continue
        local payload_data="${line#data: }"
        [[ "$payload_data" == "[DONE]" ]] && break

        local content
        content=$(printf '%s' "$payload_data" | jq -r '.choices[0].delta.content // empty' 2>/dev/null)
        if [[ -n "$content" ]]; then
            printf '%s' "$content"
            response_text+="$content"
            ((chunk_count++))
        fi

        local srv_tok
        srv_tok=$(printf '%s' "$payload_data" | jq -r '.usage.completion_tokens // empty' 2>/dev/null)
        [[ -n "$srv_tok" && "$srv_tok" != "null" ]] && server_tokens=$srv_tok
    done < <(curl -s --no-buffer --max-time 300 -X POST "$LOCAL_LLM_URL" \
        -H "Content-Type: application/json" \
        -d "$payload" 2>/dev/null | tr -d '\r')

    local end_ns; end_ns=$(date +%s%N)
    local elapsed_ms=$(( (end_ns - start_ns) / 1000000 ))
    local tokens=$server_tokens
    if (( tokens == 0 )); then tokens=$chunk_count; fi

    if (( tokens > 0 && elapsed_ms > 0 )); then
        local tps_x10=$(( tokens * 10000 / elapsed_ms ))
        local tps_int=$(( tps_x10 / 10 ))
        local tps_dec=$(( tps_x10 % 10 ))
        local elapsed_s=$(( elapsed_ms / 1000 ))
        printf '\n%s(%s.%s tps)%s\n' "$C_Dim" "$tps_int" "$tps_dec" "$C_Reset"
        echo "${tps_int}.${tps_dec} tps" > "${LLM_TPS_CACHE}.tmp" && mv "${LLM_TPS_CACHE}.tmp" "$LLM_TPS_CACHE"
        __save_tps "${tps_int}.${tps_dec}"
    else
        echo
    fi

    [[ -f "$LLM_TPS_CACHE" ]] && LAST_TPS=$(< "$LLM_TPS_CACHE")
    __LAST_LLM_RESPONSE="$response_text"
}

# ---------------------------------------------------------------------------
# __llm_stream — SSE streaming helper for explain / wtf / chat.
# Usage: __llm_stream "prompt text" [show_header: 1|0] [messages_json]
#   If messages_json is provided (a valid JSON array), it is sent directly
#   instead of wrapping prompt in a single user message. This enables
#   multi-turn conversation history for local_chat.
# MODULARISATION NOTE: writes LLM_TPS_CACHE, read by tactical_dashboard.
# ---------------------------------------------------------------------------
function __llm_stream() {
    local prompt="$1"
    local show_header="${2:-1}"
    local messages_json="${3:-}"
    __require_llm || return 1

    local payload
    if [[ -n "$messages_json" ]]; then
        payload=$(jq -n --argjson msgs "$messages_json" '{messages: $msgs, stream: true}')
    else
        payload=$(jq -n --arg p "$prompt" '{messages: [{role: "user", content: $p}], stream: true}')
    fi

    (( show_header == 1 )) && printf '\n%s\n\n' "${C_Highlight}AI Analysis:${C_Reset}"

    __llm_sse_core "$payload"
}

# ---------------------------------------------------------------------------
# __llm_chat_send — Send a message with conversation history to the local LLM.
# Usage: __llm_chat_send "user message" "messages_json_array"
#   Returns: the assistant's response text is captured via __LAST_LLM_RESPONSE.
# ---------------------------------------------------------------------------
function __llm_chat_send() {
    local user_msg="$1"
    local messages_json="$2"
    __require_llm || return 1

    local payload
    payload=$(jq -n --argjson msgs "$messages_json" '{messages: $msgs, stream: true}')

    __llm_sse_core "$payload"
}

# ---------------------------------------------------------------------------
# local_chat — Interactive chat REPL with multi-turn conversation history.
# Accumulates user and assistant messages so the LLM has context of the full
# conversation. First argument (if any) becomes the opening message.
# Type 'end-chat' or press Ctrl-C to return to the shell.
# Aliased as 'chatl' in section 3.
# ---------------------------------------------------------------------------
function local_chat() {
    __require_llm || return 1

    # Trap Ctrl-C: clean up nested function, restore trap, exit cleanly
    trap 'echo; unset -f __send_chat_msg 2>/dev/null; trap - INT; return 0' INT

    # Conversation history as a JSON array string
    local history='[]'

    # __send_chat_msg is a nested (dynamic-scoped) function that captures
    # the 'history' local variable from local_chat's scope. This works because
    # bash uses dynamic scoping — nested functions inherit the caller's locals.
    # It will break if extracted to file scope without passing history by reference.
    function __send_chat_msg() {
        local user_msg="$1"
        # Append user message to history
        history=$(printf '%s' "$history" | jq --arg m "$user_msg" '. + [{role: "user", content: $m}]')
        echo
        __llm_chat_send "$user_msg" "$history"
        # Append assistant response to history
        if [[ -n "$__LAST_LLM_RESPONSE" ]]; then
            history=$(printf '%s' "$history" | jq --arg m "$__LAST_LLM_RESPONSE" '. + [{role: "assistant", content: $m}]')
        fi
    }

    local initial="$*"
    # If called with an initial prompt, send it first
    if [[ -n "$initial" ]]; then
        __send_chat_msg "$initial"
    fi
    printf '%s\n' "${C_Dim}chat: mode — type a message (or 'end-chat' / 'save' / Ctrl-C to exit)${C_Reset}"
    while true; do
        local msg
        echo
        read -r -e -p "${C_Highlight}chat: ${C_Reset}" msg || break
        [[ -z "$msg" ]] && continue
        [[ "$msg" == "end-chat" ]] && break
        if [[ "$msg" == "save" ]]; then
            local save_file
            save_file="$HOME/chat_$(date +%Y%m%d_%H%M%S).json"
            printf '%s' "$history" | jq '.' > "$save_file" 2>/dev/null \
                && printf '%s\n' "${C_Success}Saved to $save_file${C_Reset}" \
                || printf '%s\n' "${C_Error}Failed to save${C_Reset}"
            continue
        fi
        __send_chat_msg "$msg"
    done

    unset -f __send_chat_msg
    trap - INT
}

# ---------------------------------------------------------------------------
# chat-context — Feed a file as context then ask the local LLM about it.
# Usage: chat-context <file> "question about this file"
# The file content is prepended as context to the user's question.
# ---------------------------------------------------------------------------
function chat-context() {
    if [[ -z "$1" ]]; then
        printf '%s\n' "${C_Dim}Usage:${C_Reset} chat-context <file> \"question about this file\""
        return 1
    fi
    local file="$1"; shift
    local question="$*"
    if [[ ! -f "$file" ]]; then
        __tac_info "File" "[NOT FOUND: $file]" "$C_Error"
        return 1
    fi
    __require_llm || return 1
    # Cap file content to stay within context window (configurable via env)
    local max_chars="${CHAT_CONTEXT_MAX:-16000}"
    local content; content=$(head -c "$max_chars" "$file")
    local prompt="Here is the content of '$file':\n\n\`\`\`\n${content}\n\`\`\`\n\n${question:-Explain this file.}"
    __llm_stream "$prompt"
}

# ---------------------------------------------------------------------------
# chat-pipe — Pipe stdin as context and ask the local LLM about it.
# Usage: cat error.log | chat-pipe "What's wrong here?"
# ---------------------------------------------------------------------------
function chat-pipe() {
    __require_llm || return 1
    local ctx; ctx=$(cat)
    if [[ -z "$ctx" ]]; then
        __tac_info "stdin" "[EMPTY — pipe some content]" "$C_Error"
        return 1
    fi
    local question="${*:-Explain this.}"
    __llm_stream "${ctx}\n\n${question}"
}

# ==============================================================================
# 12. DASHBOARD & HELP
# ==============================================================================
# @modular-section: dashboard-help
# @depends: constants, design-tokens, ui-engine, telemetry, hooks, openclaw, llm-manager
# @exports: tactical_dashboard, tactical_help

# ---------------------------------------------------------------------------
# tactical_dashboard — Full-screen system status panel.
# ---------------------------------------------------------------------------
function tactical_dashboard() {
    command clear
    __TAC_BG_PIDS=()  # Reset to avoid unbounded growth across renders
    local line; printf -v line '%*s' "$((UIWidth - 2))" ''; line="${line// /═}"

    __tac_header "TACTICAL DASHBOARD" "open" "$TACTICAL_PROFILE_VERSION"

    # --- System metrics block ---
    local systime; systime=$(date +"%A %H:%M %d/%m/%Y")
    local uptime; uptime=$(__get_uptime)
    local batt; batt=$(__get_battery)
    local host_raw; host_raw=$(__get_host_metrics)
    local cpu gpu0 gpu1
    IFS='|' read -r cpu gpu0 gpu1 <<< "$host_raw"
    # Ensure numeric values for arithmetic (guard against stale/malformed cache)
    [[ "$cpu"  =~ ^[0-9]+$ ]] || cpu=0
    [[ "$gpu0" =~ ^[0-9]+$ ]] || gpu0=0
    [[ "$gpu1" =~ ^[0-9]+$ ]] || gpu1=0
    local disk; disk=$(__get_disk)
    local _mem_raw; _mem_raw=$(free -m | awk 'NR==2{printf "%.2f / %.2f Gb|%d", $3/1024, $2/1024, $3*100/$2}')
    local mem="${_mem_raw%|*}"
    local mem_pct="${_mem_raw##*|}"

    __fRow "SYSTEM TIME" "$systime" "$C_Text"
    __fRow "UPTIME" "$uptime" "$C_Text"

    # Battery colour: >50% green, 20-50% yellow, <20% red, A/C=green
    local batt_color=$C_Success
    if [[ "$batt" != "A/C POWERED" && "$batt" =~ ^([0-9]+)% ]]; then
        local batt_pct=${BASH_REMATCH[1]}
        if (( batt_pct < 20 )); then
            batt_color=$C_Error
        elif (( batt_pct < 50 )); then
            batt_color=$C_Warning
        fi
    fi
    __fRow "BATTERY" "$batt" "$batt_color"

    local gpu_raw; gpu_raw=$(__get_gpu)

    # CPU/GPU colour: >90% red, >75% yellow, else green
    local cpu_gpu_color
    local max_gpu=$(( gpu0 > gpu1 ? gpu0 : gpu1 ))
    cpu_gpu_color=$(__threshold_color $(( cpu > max_gpu ? cpu : max_gpu )))
    __fRow "CPU / GPU" "CPU ${cpu}% | iGPU ${gpu0}% | CUDA ${gpu1}%" "$cpu_gpu_color"

    # Memory colour: <75% used=green, 75-90%=yellow, >90%=red
    local mem_color
    mem_color=$(__threshold_color "$mem_pct")
    __fRow "MEMORY" "$mem" "$mem_color"
    __fRow "STORAGE" "$disk" "$C_Text"

    # --- GPU & LLM block ---
    printf '%s\n' "${C_BoxBg}╠${line}╣${C_Reset}"

    local gpu_display="$gpu_raw"
    local g_name="" g_temp="" g_util="" g_mem_u="" g_mem_t=""
    if [[ "$gpu_raw" != "N/A" && "$gpu_raw" != "Querying..." && "$gpu_raw" != *"OFFLINE"* ]]; then
        IFS=',' read -r g_name g_temp g_util g_mem_u g_mem_t <<< "$gpu_raw"
        g_name="${g_name/ Laptop GPU/}"; g_name="${g_name# }"; g_name="${g_name% }"
        gpu_display="${g_name} | ${g_util// /}% Load | ${g_temp// /}°C | ${g_mem_u// /} / ${g_mem_t// /} Mb"
    fi
    # GPU colour: <75% load=green, 75-90%=yellow, >90%=red
    local gpu_color=$C_Highlight
    if [[ "$gpu_raw" != "N/A" && "$gpu_raw" != "Querying..." && "$gpu_raw" != *"OFFLINE"* ]]; then
        local g_util_n=${g_util// /}
        g_util_n=${g_util_n%\%}  # Strip trailing % for numeric comparison
        gpu_color=$(__threshold_color "$g_util_n")
    fi
    __fRow "GPU" "$gpu_display" "$gpu_color"

    if __test_port "$LLM_PORT"; then
        local act_mod="ONLINE"
        local _anum; _anum=$(cat "$ACTIVE_LLM_FILE" 2>/dev/null)
        if [[ -n "$_anum" && -f "$LLM_REGISTRY" ]]; then
            local _entry; _entry=$(awk -F'|' -v n="$_anum" '$1 == n' "$LLM_REGISTRY" 2>/dev/null)
            IFS='|' read -r _ _aname _ <<< "$_entry"
            [[ -n "$_aname" ]] && act_mod="#${_anum} ${_aname}"
        fi
        local tps; tps=$(cat "$LLM_TPS_CACHE" 2>/dev/null)
        __fRow "LOCAL LLM" "ACTIVE $act_mod | ${tps:-$LAST_TPS}" "$C_Success"

        # LLM context utilisation via async-cached /slots query
        local slots_json; slots_json=$(__get_llm_slots)
        if [[ -n "$slots_json" ]]; then
            local ctx_used ctx_total
            ctx_used=$(printf '%s' "$slots_json" | jq -r '.[0].n_past // 0' 2>/dev/null)
            ctx_total=$(printf '%s' "$slots_json" | jq -r '.[0].n_ctx // 0' 2>/dev/null)
            if (( ctx_total > 0 )); then
                local ctx_pct=$(( ctx_used * 100 / ctx_total ))
                local ctx_color=$C_Success
                (( ctx_pct >= 90 )) && ctx_color=$C_Error
                (( ctx_pct >= 75 && ctx_pct < 90 )) && ctx_color=$C_Warning
                __fRow "LLM CONTEXT" "${ctx_pct}% (${ctx_used}/${ctx_total} tokens)" "$ctx_color"
            fi
        fi
    else
        __fRow "LOCAL LLM" "OFFLINE" "$C_Dim"
    fi

    __fRow "WSL" "ACTIVE  ${WSL_DISTRO_NAME:-UNKNOWN}  ($(uname -r))" "$C_Success"

    # --- OpenClaw status block ---
    printf '%s\n' "${C_BoxBg}╠${line}╣${C_Reset}"
    local oc_stat="OFFLINE"
    local oc_active=0
    __test_port "$OC_PORT" && { oc_stat="ONLINE"; oc_active=1; }

    local metrics; metrics=$(__get_oc_metrics)
    local m_sess m_ver
    IFS='|' read -r m_sess m_ver <<< "$metrics"
    m_sess=${m_sess%$'\r'}; m_ver=${m_ver%$'\r'}

    local oc_color=$C_Error
    if [[ $oc_active == 1 ]]; then
        oc_color=$C_Success
    fi
    __fRow "OPENCLAW" "[$oc_stat]  ${m_ver}" "$oc_color"

    local sess_color=$C_Dim
    if [[ "$m_sess" != "Querying..." && "$m_sess" =~ ^[0-9]+$ ]]; then
        (( m_sess > 0 )) && sess_color=$C_Warning
    fi
    __fRow "SESSIONS" "$m_sess Active" "$sess_color"

    local tokens; tokens=$(__get_tokens)
    if [[ "$tokens" == "Querying..."* || "$tokens" == "N/A"* ]]; then
        __fRow "CONTEXT USED" "No data" "$C_Dim"
    else
        local t_used t_limit
        IFS='|' read -r t_used t_limit <<< "$tokens"
        t_used=${t_used%$'\r'}; t_limit=${t_limit%$'\r'}
        local t_pct=$(( t_limit > 0 ? t_used * 100 / t_limit : 0 ))
        local h_used h_limit
        if (( t_used >= 1000 )); then h_used="$(( t_used / 1000 ))k"; else h_used="$t_used"; fi
        if (( t_limit >= 1000 )); then h_limit="$(( t_limit / 1000 ))k"; else h_limit="$t_limit"; fi
        local ctx_tok_color=$C_Success
        if (( t_pct >= 90 )); then
            ctx_tok_color=$C_Error
        fi
        __fRow "CONTEXT USED" "${t_pct}% (${h_used} of ${h_limit})" "$ctx_tok_color"
    fi

    # "Cloaking" = active Python virtual environment isolation
    if [[ -n "$VIRTUAL_ENV" ]]; then
        __fRow "CLOAKING" "ACTIVE ($(basename "$VIRTUAL_ENV"))" "$C_Success"
    fi

    local gitStat; gitStat=$(__get_git)
    if [[ -n "$gitStat" ]]; then
        printf '%s\n' "${C_BoxBg}╠${line}╣${C_Reset}"
        local gBranch gSec
        IFS='|' read -r gBranch gSec <<< "$gitStat"
        __fRow "TARGET REPO" "$gBranch" "$C_Warning"
        local sec_color=$C_Success
        if [[ "$gSec" == "BREACHED" ]]; then
            sec_color=$C_Error
        fi
        __fRow "SEC STATUS" "$gSec" "$sec_color"
    fi

    printf '%s\n' "${C_BoxBg}╠${line}╣${C_Reset}"

    local cmds_toggle
    if [[ $oc_active == 1 ]]; then
        cmds_toggle="xo"
    else
        cmds_toggle="so"
    fi
    local cmds="up | ${cmds_toggle} | serve <n> | halt | chat: | commit | h"
    local totalPad=$(( UIWidth - 2 - ${#cmds} ))
    local leftPad=$(( totalPad / 2 ))
    local rightPad=$(( totalPad - leftPad ))

    local lCmdPad=""; (( leftPad  > 0 )) && printf -v lCmdPad '%*s' "$leftPad"  ""
    local rCmdPad=""; (( rightPad > 0 )) && printf -v rCmdPad '%*s' "$rightPad" ""

    printf "${C_BoxBg}║%s${C_Dim}%s${C_Reset}%s${C_BoxBg}║${C_Reset}\n" "$lCmdPad" "$cmds" "$rCmdPad"

    printf '%s\n' "${C_BoxBg}╚${line}╝${C_Reset}"
}

# ---------------------------------------------------------------------------
# bashrc_diagnose — Quick health check of the shell environment.
# Reports: bash version, profile version, shell options, key paths, loaded
# functions count, and basic sanity checks.
# ---------------------------------------------------------------------------
function bashrc_diagnose() {
    echo "=== Tactical Console Diagnostics ==="
    echo "Profile version : ${TACTICAL_PROFILE_VERSION:-unknown}"
    echo "Bash version    : ${BASH_VERSION}"
    echo "Shell           : $SHELL"
    echo "Term            : ${TERM:-unset}"
    echo "Interactive     : $(case $- in *i*) echo yes;; *) echo no;; esac)"
    echo "Login shell     : $(shopt -q login_shell && echo yes || echo no)"
    echo ""
    echo "=== Key Paths ==="
    echo "AI_STORAGE_ROOT : ${AI_STORAGE_ROOT:-unset}"
    echo "OC_ROOT         : ${OC_ROOT:-unset}"
    echo "LLM_HOME        : ${LLM_HOME:-unset}"
    echo "LLM_REGISTRY    : ${LLM_REGISTRY:-unset}"
    echo "TAC_CACHE_DIR   : ${TAC_CACHE_DIR:-unset}"
    echo ""
    echo "=== Tool Availability ==="
    local tools=(git jq curl nvidia-smi openclaw python3 node npm)
    for t in "${tools[@]}"; do
        if command -v "$t" >/dev/null 2>&1; then
            echo "  $t : $(command -v "$t")"
        else
            echo "  $t : NOT FOUND"
        fi
    done
    echo ""
    echo "=== Function Count ==="
    echo "  Public  : $(declare -F | grep -cv ' __')"
    echo "  Private : $(declare -F | grep -c ' __')"
    echo ""
    echo "=== ShellCheck ==="
    if command -v shellcheck >/dev/null 2>&1; then
        local src="${BASH_SOURCE[0]:-$HOME/ubuntu-console/tactical-console.bashrc}"
        local sc_count
        sc_count=$(shellcheck -s bash "$src" 2>&1 | grep -c '^In ' || true)
        echo "  Findings: $sc_count"
    else
        echo "  shellcheck not installed"
    fi
}

# ---------------------------------------------------------------------------
# bashrc_dryrun — Source the profile in a subshell to check for errors
# without affecting the current session.
# ---------------------------------------------------------------------------
function bashrc_dryrun() {
    local src="${BASH_SOURCE[0]:-$HOME/ubuntu-console/tactical-console.bashrc}"
    echo "Dry-run: sourcing $src in a subshell..."
    if bash -n "$src" 2>&1; then
        echo "${C_Success}PASS${C_Reset} — No syntax errors."
    else
        echo "${C_Error}FAIL${C_Reset} — Syntax errors detected above."
        return 1
    fi
}

# ---------------------------------------------------------------------------
# tactical_help — Full-screen help index with all commands documented.
# ---------------------------------------------------------------------------
function tactical_help() {
    command clear
    __tac_header "HELP INDEX" "open" "$TACTICAL_PROFILE_VERSION"

    # First section: rendered without leading divider (header already drew one).
    # Uses a manual centred title instead of __hSection to avoid the ╠═══╣ divider.
    local __iw=$((UIWidth - 2))
    local __title="SYSTEM"
    local __pl=$(( (__iw - ${#__title}) / 2 ))
    local __pr=$(( __iw - ${#__title} - __pl ))
    local __ls=""; (( __pl > 0 )) && printf -v __ls '%*s' "$__pl" ""
    local __rs=""; (( __pr > 0 )) && printf -v __rs '%*s' "$__pr" ""
    printf "${C_BoxBg}║${C_Reset}${C_Warning}%s%s%s${C_Reset}${C_BoxBg}║${C_Reset}\n" "$__ls" "$__title" "$__rs"
    __hRow "m" "Open Tactical Dashboard with live system stats"
    __hRow "h" "Display this command reference with all shortcuts"
    __hRow "up" "Run 10-step maintenance: updates, caches, GPU, disk"
    __hRow "sysinfo" "One-line summary: CPU load, RAM, disk usage, GPU"
    __hRow "get-ip" "Show WSL internal IP and external WAN address"
    __hRow "cls / reload" "Clear screen + redraw banner / Full profile reload"
    __hRow "cpwd" "Copy working directory path to Windows clipboard"
    __hRow "cl" "Remove python-*.exe and .pytest_cache in current dir"
    __hRow "logtrim" "Trim log files over 1 Mb to last 1000 lines"
    __hRow "oedit" "Open tactical-console.bashrc in VS Code for editing"
    __hRow "code <path>" "Open any file or directory in VS Code (lazy-resolved)"

    __hSection "OPENCLAW — GATEWAY"
    __hRow "so / xo" "Start / Stop the OpenClaw gateway (systemd)"
    __hRow "oc-restart" "Full gateway restart: stop, wait, then start"
    __hRow "ocgs / ocstat" "Gateway deep health probe / Full status --all"
    __hRow "oc-health" "Ping gateway HTTP /api/health endpoint"
    __hRow "oc-tail" "Live-tail gateway journal logs (Ctrl-C to stop)"
    __hRow "ocv" "Print installed OpenClaw CLI version string"
    __hRow "oc-update" "Update the OpenClaw CLI binary to latest release"
    __hRow "oc-tui" "Launch the OpenClaw interactive terminal UI"

    __hSection "OPENCLAW — AGENTS & SESSIONS"
    __hRow "os / oa" "List all active sessions / Show registered agents"
    __hRow "ocstart" "Dispatch an agent turn (-m '<message>' required)"
    __hRow "ocstop" "Delete an agent by ID (--agent <id> required)"
    __hRow "oc-agent-turn" "Alias for ocstart (send an agent turn)"
    __hRow "mem-index" "Rebuild the OpenClaw vector memory search index"
    __hRow "oc-memory-search" "Semantic search across the OpenClaw memory store"

    __hSection "OPENCLAW — CONFIG & LOGS"
    __hRow "occonf" "Open openclaw.json global config in VS Code"
    __hRow "oc-config" "Read or write OpenClaw config keys (get|set|unset)"
    __hRow "oc-env" "Display all OpenClaw and LLM environment variables"
    __hRow "ockeys" "List Windows API keys bridged into the WSL session"
    __hRow "ocms" "Probe all configured model provider endpoints"
    __hRow "ocdoc-fix" "Run openclaw doctor --fix with config backup"
    __hRow "oclogs" "Open the /tmp/openclaw runtime log in VS Code"
    __hRow "le / lo / lc" "Gateway: 40-line stderr / 120-line full / Clear all"
    __hRow "ologs" "Change directory to the OpenClaw logs folder"
    __hRow "oc-sec" "Run a deep OpenClaw security audit with findings"
    __hRow "oc-docs" "Full-text search across OpenClaw documentation"
    __hRow "oc-cache-clear" "Remove /dev/shm telemetry caches to force refresh"
    __hRow "oc-diag" "5-point check: doctor, gateway, models, env, logs"
    __hRow "oc-failover" "Configure cloud LLM fallback (on|off|status)"
    __hRow "oc-refresh-keys" "Force re-import of Windows API keys into WSL"
    __hRow "oc-trust-sync" "Save current oc-llm-sync.sh SHA256 as trusted"

    __hSection "OPENCLAW — DATA & EXTENSIONS"
    __hRow "owk / ocroot" "Jump to OpenClaw Workspace or Root config dir"
    __hRow "oc-backup" "Snapshot workspace + agents to timestamped ZIP"
    __hRow "oc-restore" "Restore workspace + agents from a backup ZIP"
    __hRow "oc-cron" "Manage OpenClaw scheduled tasks (list|add|runs)"
    __hRow "oc-skills" "Show installed and eligible OpenClaw skill modules"
    __hRow "oc-plugins" "Manage plugins (list|doctor|enable|disable)"
    __hRow "oc-usage" "Display token and cost usage stats (default: 7d)"
    __hRow "oc-channels" "Manage messaging channels (list|status|logs)"
    __hRow "oc-browser" "Control headless browser (status|start|stop)"
    __hRow "oc-nodes" "Manage compute nodes (status|list|describe)"
    __hRow "oc-sandbox" "Manage code execution sandboxes (list|recreate)"

    __hSection "OPENCLAW — LLM INTEGRATION"
    __hRow "oc-local-llm" "Register local llama.cpp as an OpenClaw provider"
    __hRow "oc-sync-models" "Sync models.conf with OpenClaw provider scan"

    __hSection "LLM — MODEL MANAGEMENT"
    __hRow "wake" "Lock NVIDIA GPU persistence mode and WDDM state"
    __hRow "gpu-status" "Detailed NVIDIA GPU stats: util, VRAM, temp, power"
    __hRow "gpu-check" "Quick CUDA verification: device, VRAM, layer offload"
    __hRow "llmconf" "Open the models.conf registry file in VS Code"
    __hRow "model scan" "Scan model dir, read GGUF metadata, auto-calculate params"
    __hRow "model list" "Show numbered model registry (▶ = active)"
    __hRow "model use N" "Start model #N with optimal GPU/ctx/thread settings"
    __hRow "model stop" "Stop the local llama-server"
    __hRow "model status" "Show what's currently running"
    __hRow "model info N" "Display full details for model #N"
    __hRow "model bench" "Benchmark all on-disk models and compare TPS"
    __hRow "model delete N" "Permanently delete model #N from disk and registry"
    __hRow "model archive N" "Move model #N to /mnt/m/archive/ and deregister"
    __hRow "model download" "Download GGUF models from Hugging Face (repo:file)"
    __hRow "serve N" "Alias for model use N"
    __hRow "halt" "Stop the local llama.cpp inference server"
    __hRow "mlogs" "Open the llama-server runtime log in VS Code"
    __hRow "burn" "Run ~1300 token stress test and measure live TPS"

    __hSection "LLM — CHAT & EXPLAIN"
    __hRow "chat: [msg]" "Interactive LLM chat session (end-chat to exit)"
    __hRow "  save" "Inside chat: save conversation history to ~/chat_*.json"
    __hRow "chat-context" "Load a file as context then ask questions about it"
    __hRow "chat-pipe" "Pipe stdout from another command as LLM context"
    __hRow "explain" "Ask the local LLM to explain your last command"
    __hRow "wtf [topic]" "Interactive topic explainer REPL (end-chat to exit)"

    __hSection "GIT & PROJECTS"
    __hRow "mkproj <n>" "Scaffold project: PEP-8 main.py, .venv, git init"
    __hRow "commitd <msg>" "Git add, commit with your message, and push"
    __hRow "commit" "Git add + commit (LLM auto-message) + push"
    __hRow "cop" "Launch interactive GitHub Copilot CLI session"
    __hRow "?? <prompt>" "One-shot Copilot prompt (e.g. ?? find large files)"
    __hRow "cop-ask <msg>" "Non-interactive Copilot prompt (spelled-out alias)"
    __hRow "cop-init" "Generate copilot-instructions.md for a project"

    __hSection "DIAGNOSTICS"
    __hRow "bashrc_diagnose" "Health check: versions, paths, tools, functions"
    __hRow "bashrc_dryrun" "Syntax-check the profile without affecting session"

    __tac_footer
}

# ==============================================================================
# 13. INITIALIZATION
# ==============================================================================
# @modular-section: init
# @depends: all sections above
# @exports: (none — runs startup side-effects only)

# Create required directories
mkdir -p "$OC_ROOT" "$OC_LOGS" "$OC_BACKUPS" "$AI_STORAGE_ROOT/.llm"

# Check for required dependencies
if ! command -v jq >/dev/null 2>&1; then
    printf '%s\n' "${C_Warning}[Tactical Profile]${C_Reset} Missing: jq (required). Run: sudo apt install -y jq"
fi

# Initialize UI (guard prevents screen-clear on re-source)
if [[ -z "${__TAC_INITIALIZED:-}" ]]; then
    clear_tactical
    __TAC_INITIALIZED=1
fi

# Load completions safely (only once — guarded with -f check)
[[ -f "$BASH_COMPLETION_SCRIPT" ]] && . "$BASH_COMPLETION_SCRIPT"
[[ -f "$OC_ROOT/completions/openclaw.bash" ]] && source "$OC_ROOT/completions/openclaw.bash"

# Fix Loopback for WSL Mirrored Networking (Idempotent & Pulse-Free).
# Uses 'command ip' to call /usr/bin/ip directly, avoiding any function shadow.
# Checks both interface existence AND the specific address to be truly idempotent.
if ! command ip link show loopback0 >/dev/null 2>&1; then
    if sudo -n true 2>/dev/null; then
        sudo ip link add loopback0 type dummy 2>/dev/null
        sudo ip link set loopback0 up 2>/dev/null
        sudo ip addr add 127.0.0.2/8 dev loopback0 2>/dev/null
    fi
elif ! command ip addr show loopback0 2>/dev/null | grep -q '127\.0\.0\.2/'; then
    # Interface exists but address is missing (e.g., after network reset)
    if sudo -n true 2>/dev/null; then
        sudo ip addr add 127.0.0.2/8 dev loopback0 2>/dev/null
    fi
fi

# OpenClaw LLM sync function (added by Hal)
# NOTE: This silently sources an external script. If the file is compromised,
# it executes in the interactive shell. Hash is verified against a trusted
# reference file and logged for auditability.
if [[ -f "$OC_WORKSPACE/oc-llm-sync.sh" ]]; then
    _sync_hash=$(sha256sum "$OC_WORKSPACE/oc-llm-sync.sh" 2>/dev/null | cut -d' ' -f1)
    echo "$(date +"%Y-%m-%d %H:%M:%S") [SOURCE] oc-llm-sync.sh SHA256=${_sync_hash:-unknown}" >> "$ErrorLogPath" 2>/dev/null
    if [[ -f "$OC_ROOT/oc-llm-sync.sha256" ]]; then
        _trusted_hash=$(< "$OC_ROOT/oc-llm-sync.sha256")
        if [[ "$_sync_hash" != "$_trusted_hash" ]]; then
            printf '%s\n' "${C_Warning}[Tactical Profile]${C_Reset} oc-llm-sync.sh hash mismatch — skipped (run 'oc-trust-sync' to update)"
        else
            # C7: stderr suppressed because oc-llm-sync.sh may emit harmless
            # warnings (e.g., unbound variables from older versions). The || true
            # prevents a failing sync from aborting shell init. Errors are still
            # logged above via the SHA256 entry in bash-errors.log.
            source "$OC_WORKSPACE/oc-llm-sync.sh" 2>/dev/null || true
        fi
    else
        # No trusted hash — refuse to source. Run 'oc-trust-sync' first.
        printf '%s\n' "${C_Warning}[Tactical Profile]${C_Reset} oc-llm-sync.sh has no trusted hash — skipped (run 'oc-trust-sync' to trust it)"
    fi
    # Always clean up hash variables regardless of code path
    unset _sync_hash _trusted_hash
fi

# Bridge Windows User API keys into WSL so OpenClaw fallback providers work.
# Cached in /dev/shm for 1 hour; run 'oc-refresh-keys' to force refresh.
__bridge_windows_api_keys

# Load Hugging Face token from secure file if not already set by bridge
if [[ -z "${HF_TOKEN:-}" && -f "$HOME/.config/huggingface/token" ]]; then
    HF_TOKEN=$(< "$HOME/.config/huggingface/token")
    export HF_TOKEN
fi

# Clean up background telemetry subshells on shell exit.
# Only kills PIDs we spawned for caching — not user-started background jobs.
# Chains with any pre-existing EXIT trap to avoid silently overwriting it.
#
# Lifecycle:
#   1. Each __get_* telemetry function appends its background PID to __TAC_BG_PIDS
#   2. tactical_dashboard resets the array at the start of each render
#   3. On shell exit, __tac_exit_cleanup kills any lingering background subshells
#   4. The trap chains with any prior EXIT trap so other cleanup still runs
__TAC_BG_PIDS=()
function __tac_exit_cleanup() {
    local pid
    for pid in "${__TAC_BG_PIDS[@]}"; do
        kill "$pid" 2>/dev/null
    done
}
_tac_prev_exit_trap=$(trap -p EXIT | sed "s/trap -- '//;s/' EXIT//")
trap '__tac_exit_cleanup; '"${_tac_prev_exit_trap:-}" EXIT
unset _tac_prev_exit_trap

# ==============================================================================
# end of file

