#!/usr/bin/env bash
# shellcheck shell=bash
# ==============================================================================
# install-shellcheck.sh — Install the pinned shellcheck release.
# ==============================================================================
# Downloads the official static release tarball, verifies its sha256, and
# installs the binary into <prefix> (default /usr/local/bin, which precedes
# /usr/bin on PATH, so it shadows any older distro package without touching the
# package manager's copy).
#
# The pin matters: shellcheck's diagnostics change between releases. For one and
# the same trap-only function, 0.9.0 reported SC2317 while 0.11.0 reports SC2329,
# so a version skew makes the identical tree pass on one machine and fail on
# another. CI and local lint must therefore resolve the same version.
#
# Usage:
#   sudo tools/install-shellcheck.sh               # install to /usr/local/bin
#        tools/install-shellcheck.sh -p "$HOME/.local/bin"
# ==============================================================================
# AI INSTRUCTION: Increment version on significant changes.
# Module Version: 4
#   v4 (2026-09-23): skip the download when the pin is already installed at the
#   target prefix.  CI runs this before every shell job on a SELF-HOSTED runner
#   where a previous job already put the pinned binary in place, so re-downloading
#   made each job depend on GitHub egress it did not need: measured 2026-09-23, a
#   ~46 s egress outage failed the Fast Test Suite with `curl: (28) Failed to
#   connect to github.com port 443 ... Timeout was reached` while
#   /usr/local/bin/shellcheck was ALREADY the pin on that runner — the Lint job
#   reported `version: 0.11.0` from it minutes later.
VERSION="1.0"
set -euo pipefail

SHELLCHECK_VERSION="v0.11.0"
# sha256 of shellcheck-v0.11.0.linux.x86_64.tar.xz from the official release
# (github.com/koalaman/shellcheck/releases/tag/v0.11.0).
SHELLCHECK_SHA256="8c3be12b05d5c177a04c29e3c78ce89ac86f1595681cab149b65b97c4e227198"

# --version works without touching the network (repo-wide idiom).
if [[ "${1:-}" == "--version" || "${1:-}" == "-V" ]]; then
    echo "install-shellcheck $VERSION"
    exit 0
fi

prefix="/usr/local/bin"

while getopts ":p:" _opt; do
    case "$_opt" in
        p) prefix="$OPTARG" ;;
        *) echo "install-shellcheck: unknown option -${OPTARG:-}" >&2; exit 2 ;;
    esac
done
shift $((OPTIND - 1))

# Idempotent, and therefore egress-free when the pin is already in place.  The
# contract this script exists to keep is "the PIN is installed at <prefix>", not
# "a tarball was fetched", so an already-correct binary means there is no work.
# The check consults the TARGET PREFIX only, never PATH: PATH order is a separate
# concern this script also guards, and resolving a different copy would defeat it.
if [[ -x "$prefix/shellcheck" ]]
then
    if _have="$("$prefix/shellcheck" --version 2>/dev/null)" \
       && [[ "$_have" == *"version: ${SHELLCHECK_VERSION#v}"* ]]
    then
        echo "shellcheck ${SHELLCHECK_VERSION} already installed at $prefix/shellcheck — nothing to do."
        exit 0
    fi
    # Present but not the pin (or not runnable): install the pin rather than trust
    # it, because a version skew between lint machines is the exact failure the
    # pin exists to prevent.  Say so, so this is a stated fallback and not a skip.
    echo "Installed $prefix/shellcheck is not ${SHELLCHECK_VERSION} (or will not run) — installing the pin."
fi

tarball="shellcheck-${SHELLCHECK_VERSION}.linux.x86_64.tar.xz"
url="https://github.com/koalaman/shellcheck/releases/download/${SHELLCHECK_VERSION}/${tarball}"

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

echo "Downloading shellcheck ${SHELLCHECK_VERSION} ..."
# --connect-timeout/--max-time: without them a stalled connection blocks the
# installer indefinitely, and this runs before shellcheck exists to check anything.
curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 10 --max-time 300 \
    -o "$workdir/$tarball" "$url"

sha256sum -c - <<< "${SHELLCHECK_SHA256}  $workdir/$tarball" >/dev/null
echo "sha256 verified."

tar -xJf "$workdir/$tarball" -C "$workdir"
install -D -m 755 "$workdir/shellcheck-${SHELLCHECK_VERSION}/shellcheck" \
    "$prefix/shellcheck"

echo "Installed $prefix/shellcheck ($("$prefix/shellcheck" --version | sed -n '2p'))"

# end of file
