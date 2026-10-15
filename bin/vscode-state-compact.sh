#!/usr/bin/env bash
# vscode-state-compact.sh - return the VS Code state DBs' freed pages to the filesystem.
#
# WHY IT EXISTS.  Only a VACUUM hands back the pages a deleted value freed, and the DBs
# are held open by the running app - so the ONE reliable moment to compact them is the
# window bin/wsl-restart.sh already creates: the client is killed before `wsl --shutdown`
# and relaunched only after the distro answers.  This is the WSL-side half that window
# calls, at step 3b of the generated wrapper.
#
# MEASURED 2026-10-15: the profile's state.vscdb was 153,202,688 bytes with 152,252,416
# free - 99% of a file whose extension state was 0.8 MB - because the companion's 75 MB
# globalState blob was deleted when it updated to 0.25.1 and its pages stayed behind.
# Deleting a value frees PAGES; only a VACUUM returns them.
#
# THE RESTART IS THE JOB; THIS IS OPPORTUNISTIC.  It always exits 0, because the wrapper
# logs its output and neither branches on nor gates the relaunch with it: a refusal (a
# locked DB, i.e. VS Code came back first) or a missing tool costs an opportunity and
# must never cost the restart.  Nothing here is silent - the tool prints why it refused,
# and that output goes to the wrapper's log with everything else.
#
# USAGE: vscode-state-compact.sh      (no arguments)
#
# AI INSTRUCTION: On ANY change to this file, increment the Module Version below.
# Module Version: 1
VERSION="1.0.0"

set -uo pipefail

REPO="${REPO:-/home/wayne/ubuntu-console}"
TOOL="${TAC_COMPACT_TOOL:-$REPO/tools/vscode-companion-state/vscode-companion-state-trim.py}"
PY="${TAC_PYTHON:-python3}"

if [[ ! -f "$TOOL" ]]; then
    printf 'vscode-state-compact: no compact tool at %s - nothing compacted\n' "$TOOL"
    exit 0
fi

printf 'vscode-state-compact %s: compacting the state DBs (the client is closed)\n' "$VERSION"
rc=0
"$PY" "$TOOL" --vacuum --apply || rc=$?
if (( rc != 0 )); then
    printf 'vscode-state-compact: the tool exited %s - any DB it refused is unchanged\n' "$rc"
fi
exit 0

# end of file
