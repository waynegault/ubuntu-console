"""Git hooks for post-commit graph auto-rebuild.

Detects changes in files known to kgraph (AST-tracked source files,
graph DB, memory DB) and runs an incremental rebuild after commits
that modify tracked files.

CLI integration:
    kgraph --install-hook   — install the post-commit hook in the current repo
    kgraph --uninstall-hook — remove the post-commit hook
"""

import os
import sys
import subprocess
import json

HOOK_NAME = "post-commit"
HOOK_CONTENT = """\
#!/usr/bin/env bash
# kgraph post-commit hook — auto-rebuild graph when tracked files change
set -euo pipefail

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")
KGRAPH="kgraph"
if command -v kgraph &>/dev/null; then
    KGRAPH="kgraph"
elif [ -f "$REPO_ROOT/scripts/kgraph.py" ]; then
    KGRAPH="python3 \"$REPO_ROOT/scripts/kgraph.py\""
elif [ -f "$REPO_ROOT/scripts/kgraph/cli.py" ]; then
    KGRAPH="python3 -m kgraph"
fi

# Get the list of changed files in this commit
CHANGED=$(git diff-tree --no-commit-id -r --name-only HEAD 2>/dev/null || echo "")

if [ -z "$CHANGED" ]; then
    exit 0
fi

# Known kgraph-tracked file patterns
HAS_CHANGES=false
while IFS= read -r FILE; do
    case "$FILE" in
        scripts/kgraph/*)
            HAS_CHANGES=true
            ;;
        *.py|*.sh|*.bash|*.json|*.yaml|*.yml|*.md|*.sqlite)
            HAS_CHANGES=true
            ;;
    esac
    if [ "$HAS_CHANGES" = true ]; then
        break
    fi
done <<< "$CHANGED"

if [ "$HAS_CHANGES" = false ]; then
    exit 0
fi

echo "--- kgraph: tracked files changed, rebuilding graph ---"
eval "$KGRAPH --update" 2>&1 || echo "kgraph: update failed (non-fatal)"
echo "--- kgraph: rebuild complete ---"
"""


def _find_git_root() -> str | None:
    """Find the git repository root from CWD."""
    try:
        result = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            capture_output=True, text=True, timeout=5,
        )
        if result.returncode == 0:
            return result.stdout.strip()
    except (FileNotFoundError, subprocess.TimeoutExpired):
        pass
    return None


def _hooks_dir(repo_root: str) -> str:
    return os.path.join(repo_root, ".git", "hooks")


def is_installed(repo_root: str | None = None) -> bool:
    """Check whether the kgraph post-commit hook is currently installed."""
    root = repo_root or _find_git_root()
    if not root:
        return False
    hook_path = os.path.join(_hooks_dir(root), HOOK_NAME)
    if not os.path.isfile(hook_path):
        return False
    try:
        with open(hook_path, "r", encoding="utf-8") as f:
            content = f.read()
        return "kgraph post-commit hook" in content
    except (OSError, UnicodeDecodeError):
        return False


def install_hook(repo_root: str | None = None) -> str:
    """Install the kgraph post-commit hook in the current git repository.

    Returns a message describing what was done.
    """
    root = repo_root or _find_git_root()
    if not root:
        return "Error: not inside a git repository"

    hooks = _hooks_dir(root)
    os.makedirs(hooks, exist_ok=True)
    hook_path = os.path.join(hooks, HOOK_NAME)

    if os.path.isfile(hook_path):
        with open(hook_path, "r", encoding="utf-8") as f:
            existing = f.read()
        if "kgraph post-commit hook" in existing:
            return f"kgraph post-commit hook already installed at {hook_path}"
        # Backup existing hook
        backup = hook_path + ".bak"
        os.rename(hook_path, backup)
        existing_note = f" (existing hook backed up to {backup})"
    else:
        existing_note = ""

    with open(hook_path, "w", encoding="utf-8") as f:
        f.write(HOOK_CONTENT)
    os.chmod(hook_path, 0o755)

    return f"Installed kgraph post-commit hook at {hook_path}{existing_note}"


def uninstall_hook(repo_root: str | None = None) -> str:
    """Remove the kgraph post-commit hook from the current git repository.

    Returns a message describing what was done.
    """
    root = repo_root or _find_git_root()
    if not root:
        return "Error: not inside a git repository"

    hook_path = os.path.join(_hooks_dir(root), HOOK_NAME)
    if not os.path.isfile(hook_path):
        return "No kgraph post-commit hook found"

    with open(hook_path, "r", encoding="utf-8") as f:
        content = f.read()
    if "kgraph post-commit hook" not in content:
        return f"{hook_path} exists but is not a kgraph hook (leaving untouched)"

    os.remove(hook_path)

    # Restore backup if present
    backup = hook_path + ".bak"
    if os.path.isfile(backup):
        os.rename(backup, hook_path)
        return f"Removed kgraph hook; restored previous hook from {backup}"

    return f"Removed kgraph post-commit hook from {hook_path}"
