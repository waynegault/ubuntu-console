#!/usr/bin/env bash
# shellcheck shell=bash
# ==============================================================================
# secret-scan.sh — run the PINNED gitleaks over staged changes or full history.
# ==============================================================================
# One place for the scan flags, used by both tools/hooks/pre-commit (--staged)
# and .github/workflows/secret-scan.yml (--all), so the two can never drift —
# the same "flags in exactly one place" rule tools/lint.sh states for shellcheck.
#
# Modes:
#   --staged   scan the git INDEX (what is about to be committed)   [hook]
#   --all      scan the whole history of the current branch         [CI]  (default)
#
# Exit 0 = clean, 1 = leaks found, 2 = gitleaks missing / bad usage.
# ==============================================================================
# AI INSTRUCTION: Increment version on significant changes.
# Module Version: 1
VERSION="1.0"
set -uo pipefail

GITLEAKS_PIN="8.30.1"

if [[ "${1:-}" == "--version" || "${1:-}" == "-V" ]]; then echo "secret-scan $VERSION"; exit 0; fi

mode="--all"
case "${1:-}" in
    --staged)      mode="--staged" ;;
    --all|"")      mode="--all" ;;
    *) echo "secret-scan: unknown argument '${1:-}'" >&2; exit 2 ;;
esac

# Resolve the PINNED binary, not PATH order — the same reasoning tools/lint.sh
# applies to its own static-analysis pin: /usr/local/bin first (where
# install-gitleaks.sh puts it and where CI installs it), then ~/.local/bin, then
# PATH as a last resort.
gl=""
for _cand in /usr/local/bin/gitleaks "$HOME/.local/bin/gitleaks"; do
    [[ -x "$_cand" ]] || continue
    # swallow-ok: version probe; a non-zero exit just means "not the pin"
    if "$_cand" version 2>/dev/null | grep -q "$GITLEAKS_PIN"; then gl="$_cand"; break; fi
done
[[ -z "$gl" ]] && command -v gitleaks >/dev/null 2>&1 && gl="$(command -v gitleaks)"
if [[ -z "$gl" ]]; then
    echo "secret-scan: gitleaks not installed. Install the PIN: sudo tools/install-gitleaks.sh" >&2
    exit 2
fi
# swallow-ok: version probe; the grep result is the decision, not the probe's exit
if ! "$gl" version 2>/dev/null | grep -q "$GITLEAKS_PIN"; then
    echo "secret-scan: WARNING: $gl is not the pinned gitleaks $GITLEAKS_PIN" >&2
fi

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root" || exit 2
cfg=(--config "$repo_root/.gitleaks.toml")

if [[ "$mode" == "--staged" ]]; then
    echo "=== Secret scan (gitleaks $GITLEAKS_PIN, staged) ==="
    "$gl" git --staged --redact --no-banner "${cfg[@]}"
else
    echo "=== Secret scan (gitleaks $GITLEAKS_PIN, full history) ==="
    "$gl" git --redact --no-banner "${cfg[@]}"
fi
rc=$?
if (( rc == 0 )); then
    echo "  PASS  no secrets found"
else
    echo "  FAIL  gitleaks found potential secret(s) — see above" >&2
fi
exit "$rc"
# end of file
