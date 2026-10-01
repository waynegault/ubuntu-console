#!/usr/bin/env bash
# guard-patch-check.sh — surface a REVERTED Qwen-daemon guard patch, once per user turn.
#
# The read-only Git relaxation (`~/.local/bin/qwen-guard-patch.sh`) is a source patch against the
# daemon's bundled guard chunk.  A companion update replaces that chunk and silently reverts the
# patch; only the script's own `--check` notices.  Until now that left the reminder in prose
# ("remember to run --check after an update"), which is the workaround shape Wayne's rule forbids —
# so the check runs itself, once per turn.
#
# Contract:
#   * prints NOTHING when the patch is in place (or when there is nothing to patch);
#   * prints a short warning naming the exact remediation when it is not;
#   * ALWAYS exits 0.  A stale patch degrades a capability — relocated read-only git is refused
#     again — it corrupts nothing, so this is a warning to act on, never a blocker.
# Limitation, stated because the hook cannot see it: this reports the patch state ON DISK.  Whether
# the running daemon loaded the patched chunk is only visible from BEHAVIOUR (a relocated
# `git -C <other-repo> log --oneline -1` is allowed once the patch is live, refused while it is not),
# and a hook has no way to ask the daemon that question.
set -u

SCRIPT="$HOME/.local/bin/qwen-guard-patch.sh"

if [ ! -x "$SCRIPT" ]; then
    echo "guard-patch-check: $SCRIPT is missing or not executable — the guard patch cannot be verified."
    exit 0
fi

if out="$("$SCRIPT" --check 2>&1)"; then
    exit 0
fi

echo "WARNING (guard patch reverted): a companion update has replaced the daemon's bundled guard chunk,"
echo "so the read-only Git relaxation is gone and relocated read-only git commands are refused again."
echo "Remediation: run '$SCRIPT', then RELOAD the VS Code window — that keystroke is required, and no"
echo "CLI path reloads it (measured: neither a vscode:// URI via cmd.exe nor PowerShell Start-Process"
echo "reloads anything, and the bundled CLI has no --reload-window)."
echo "The check said:"
printf '  %s\n' "$out" | head -5
exit 0
