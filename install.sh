#!/bin/bash
# install.sh — Create symlinks from the repo into the system locations.
# Run from the repo root: ./install.sh
# Idempotent: safe to re-run (ln -sf overwrites existing symlinks).
set -euo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"

link() {
    local src="$REPO/$1" dest="$2"
    mkdir -p "$(dirname "$dest")"
    ln -sf "$src" "$dest"
    echo "  $dest → $src"
}

echo "Installing symlinks from $REPO ..."
echo ""

# Core profile
link ".bashrc"              "$HOME/.bashrc"
link "README.md"            "$HOME/.bashrc_readme.md"
link "llm/models.conf"      "$HOME/.llm/models.conf"

# Standalone scripts → ~/.local/bin/
for f in "$REPO"/bin/*; do
    [[ -f "$f" ]] || continue
    link "bin/$(basename "$f")" "$HOME/.local/bin/$(basename "$f")"
done

# Systemd units
for f in "$REPO"/systemd/*; do
    [[ -f "$f" ]] || continue
    link "systemd/$(basename "$f")" "$HOME/.config/systemd/user/$(basename "$f")"
done

echo ""
echo "Done. Run 'exec bash' to reload the profile."
