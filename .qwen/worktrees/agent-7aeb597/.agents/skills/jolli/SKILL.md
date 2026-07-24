---
name: jolli
description: The Jolli action menu — a single front door that lists the Jolli skills (recall, search, run a workflow local or remote, workflow history) plus the Jolli MCP tools registered in this session, then routes your choice to the right one. Use when the user types /jolli or asks for the Jolli menu.
metadata:
  version: "0.99.9"
  revision: 5
  vendor: "jolli.ai"
---

# Jolli

The single umbrella action menu for Jolli. It ties together the standalone Jolli
skills and whatever Jolli MCP tools are registered in this session, and routes the
user's choice to the right one. It is a friendly front door — it **never**
re-implements any action, it only invokes an existing skill or an existing MCP
tool. The standalone `/jolli-recall`, `/jolli-search` commands and
the `/mcp__jollimemory__jolli` prompt all keep working unchanged; this is layered
on top of them, not a replacement.

The **Workflow history** action below shells the `jolli` CLI (via the run-cli
entry script), so the shell prerequisite applies when that action is used.

### Shell prerequisite

This block requires a POSIX bash shell. On Linux/macOS the system bash works.
**On Windows, use Git Bash** (the bash bundled with Git for Windows). Other
Windows "bash" options — `C:\Windows\System32\bash.exe`, the WindowsApps
alias, or any WSL bash — see a separate Linux home directory and will not
find the Jolli entry script that lives under `%USERPROFILE%`.

If Git Bash is not available on Windows, STOP and tell the user:
"Jolli skill needs Git Bash on Windows. Install Git for Windows from
https://git-scm.com/download/win and retry."

Do NOT fall back to `npm run`, `npx`, `node` directly, PowerShell-native
commands, WSL bash, or any workspace-local script — those bypass the
security recipe and the dist resolver and will not produce valid output.

## Step 1 — build the unified menu

Assemble ONE combined list of actions from two sources.

### Local Jolli skills (always present)

- **jolli-recall** — Recall prior development context for the current branch.
  Route by invoking the `jolli-recall` skill.
- **jolli-search** — Search structured commit memories across branches
  (decisions, topics, files). Route by invoking the `jolli-search` skill.
- **Run a workflow** — Run a Jolli workflow. When the user picks this, ask them
  **local vs remote**, defaulting to **local**:
  - **local (default)** — your agent executes the workflow's recipe on this
    machine (no Jolli LLM budget); the writes land in a git-backed Space via a
    branch + PR. Route by invoking the `jolli-local-run` skill.
  - **remote** — the Jolli backend executes the workflow server-side, and the run
    is monitored to completion and its result reported. Route by invoking the
    `jolli-remote-run` skill (which drives the `run_remote_workflow` tool for
    you) — not by calling the raw tool.

  A running **remote** run can be canceled with the `cancel_remote_workflow` MCP
  tool (`mcp__jollimemory__cancel_remote_workflow`) — offer this if the user
  wants to stop an in-flight remote run.
- **Workflow history** — Show a workflow's past runs. When the user picks this,
  identify the workflow's numeric id (if the `list_workflows` tool is registered
  this session, use it to let the user pick one by name; otherwise ask for the
  id), then shell:

  ```bash
  "$HOME/.jolli/jollimemory/run-cli" workflow runs <workflowId>
  ```

  It prints `{ "type": "runs", "runs": [ ... ] }` — one entry per run with its
  `status`, `timestamp`, and any `workflowUrl` / `runUrl` / `prUrl` /
  `articleUrls`. An empty `runs` list is the normal "no history yet" outcome, not
  an error. If instead the command exits non-zero and prints an install hint naming
  `@jolli.ai/workflow-cli` (rather than the JSON above), the workflow-cli plugin is
  not installed — tell the user to install it (`npm i -g @jolli.ai/cli @jolli.ai/workflow-cli`)
  and stop. Offer to open any listed URL via the `open-url` helper:

  ```bash
  "$HOME/.jolli/jollimemory/run-cli" open-url <url>
  ```

  (`{ "opened": true|false, "url": "..." }`; `opened: false` on a headless host
  just prints the URL — normal, not a failure. Only `https` URLs are accepted. A URL
  whose origin is off Jolli's allowlist is refused (never launched) and printed — the
  result carries `"refused": true`; surface it for the user to open manually.)

Route a local, remote, or history choice by invoking that skill through your
host's skill-invocation mechanism (for example, the Skill tool in Claude Code);
the Workflow history action runs its `run-cli` commands directly as shown above.

### Jolli MCP tools (whatever is registered this session)

Surface every tool whose name starts with `mcp__jollimemory__` that is available
in the current session — for example `recall`, `search`, `get_pr_description`,
`queue_status`, and any manifest-driven platform tools (space, article, and the
like). Route a choice by calling the matching `mcp__jollimemory__*` tool.

**Exclusions — do NOT surface these as standalone menu items:**

- `list_workflow_definitions` — discovery/plumbing, not a human quick-action.
- `run_remote_workflow` and `cancel_remote_workflow` — these are already covered
  by the **Run a workflow** action above (its *remote* path and its cancellation
  option); don't list them again as raw tools.

Do NOT assume a fixed list — enumerate the Jolli MCP tools that are actually
registered right now, minus the exclusions above. Do NOT try to fetch or
re-derive any backend "menu" curation; a skill cannot read the manifest, so
simply surface the Jolli MCP tools present in the session. If no Jolli MCP tools
are registered, present just the local skills above.

## Step 2 — route the request

This skill takes one optional free-text argument.

- **Argument provided** → match it to exactly one menu action and invoke that
  action directly (invoke the skill, or call the MCP tool). Only ask the user to
  choose if the request is ambiguous or matches no menu action.
- **Argument absent** → present the unified menu and let the user pick one, using
  an interactive single-select tool if your host provides one (for example
  AskUserQuestion in Claude Code); otherwise list the options as plain text and
  ask the user to choose. After the user selects, invoke the corresponding skill
  or MCP tool.

Host-agnostic by design: the AskUserQuestion mention is only an example; the
text-list fallback keeps `/jolli` usable on every host that loads skills.
