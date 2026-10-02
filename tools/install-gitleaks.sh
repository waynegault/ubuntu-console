#!/usr/bin/env bash
# shellcheck shell=bash
# ==============================================================================
# install-gitleaks.sh — Install the pinned gitleaks release.
# ==============================================================================
# Downloads the official static release tarball, verifies its sha256, and
# installs the binary into <prefix> (default /usr/local/bin).  Same contract as
# tools/install-shellcheck.sh: a PIN, not "whatever PATH resolves", because the
# scanner's rule set and findings move between releases — a version skew would
# make the same tree pass locally and fail in CI (or, worse, the reverse).
#
# Usage:
#   sudo tools/install-gitleaks.sh               # install to /usr/local/bin
#        tools/install-gitleaks.sh -p "$HOME/.local/bin"
# ==============================================================================
# AI INSTRUCTION: Increment version on significant changes.
# Module Version: 1
#   v1 (2026-10-02): first cut — pinned v8.30.1, sha256-verified, idempotent skip
#   when the pin is already installed at the target prefix (mirrors
#   install-shellcheck.sh, so CI does not re-download on a warm self-hosted runner).
VERSION="1.0"
set -euo pipefail

GITLEAKS_VERSION="v8.30.1"
# sha256 of gitleaks_8.30.1_linux_x64.tar.gz from the official release
# (github.com/gitleaks/gitleaks/releases/tag/v8.30.1 — its checksums.txt).
GITLEAKS_SHA256="551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb"

if [[ "${1:-}" == "--version" || "${1:-}" == "-V" ]]; then
    echo "install-gitleaks $VERSION"
    exit 0
fi

prefix="/usr/local/bin"

while getopts ":p:" _opt; do
    case "$_opt" in
        p) prefix="$OPTARG" ;;
        *) echo "install-gitleaks: unknown option -${OPTARG:-}" >&2; exit 2 ;;
    esac
done
shift $((OPTIND - 1))

if [[ -x "$prefix/gitleaks" ]]
then
    # swallow-ok: version probe of a possibly-foreign binary; non-zero IS the signal
    if _have="$("$prefix/gitleaks" version 2>/dev/null)" \
       && [[ "$_have" == *"${GITLEAKS_VERSION#v}"* ]]
    then
        echo "gitleaks ${GITLEAKS_VERSION} already installed at $prefix/gitleaks — nothing to do."
        exit 0
    fi
    echo "Installed $prefix/gitleaks is not ${GITLEAKS_VERSION} (or will not run) — installing the pin."
fi

tarball="gitleaks_${GITLEAKS_VERSION#v}_linux_x64.tar.gz"
url="https://github.com/gitleaks/gitleaks/releases/download/${GITLEAKS_VERSION}/${tarball}"

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

echo "Downloading gitleaks ${GITLEAKS_VERSION} ..."
curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 10 --max-time 300 \
    -o "$workdir/$tarball" "$url"

sha256sum -c - <<< "${GITLEAKS_SHA256}  $workdir/$tarball" >/dev/null
echo "sha256 verified."

tar -xzf "$workdir/$tarball" -C "$workdir"
install -D -m 755 "$workdir/gitleaks" "$prefix/gitleaks"

echo "Installed $prefix/gitleaks ($("$prefix/gitleaks" version))"
# end of file
