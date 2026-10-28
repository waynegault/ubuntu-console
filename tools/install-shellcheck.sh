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
# The ASSET is per architecture: upstream publishes linux.x86_64 and
# linux.aarch64 tarballs with different bytes, so each carries its own sha256.
# The host is read by tools/arch.sh and an unsupported machine is refused before
# anything is downloaded.
#
# Usage:
#   sudo tools/install-shellcheck.sh               # install to /usr/local/bin
#        tools/install-shellcheck.sh -p "$HOME/.local/bin"
#        tools/install-shellcheck.sh --print-asset # the asset this host resolves
# ==============================================================================
# AI INSTRUCTION: Increment version on significant changes.
# Module Version: 5
#   v5 (2026-10-28): aarch64 support.  The asset name and sha256 were x86_64-only,
#   so the installer could not run on an arm64 box at all.  Both architectures'
#   checksums are pinned — the arm64 value computed from the official v0.11.0
#   aarch64 tarball — and an unsupported host is refused with the reason instead
#   of a 404.
#   v4 (2026-09-23): skip the download when the pin is already installed at the
#   target prefix.  CI runs this before every shell job on a SELF-HOSTED runner
#   where a previous job already put the pinned binary in place, so re-downloading
#   made each job depend on GitHub egress it did not need: measured 2026-09-23, a
#   ~46 s egress outage failed the Fast Test Suite with `curl: (28) Failed to
#   connect to github.com port 443 ... Timeout was reached` while
#   /usr/local/bin/shellcheck was ALREADY the pin on that runner — the Lint job
#   reported `version: 0.11.0` from it minutes later.
VERSION="1.1"
set -euo pipefail

# shellcheck source=tools/arch.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/arch.sh"

SHELLCHECK_VERSION="v0.11.0"
# sha256 per host architecture, both from the official v0.11.0 release
# (github.com/koalaman/shellcheck/releases/tag/v0.11.0).
declare -A SHELLCHECK_SHA256=(
    [x86_64]="8c3be12b05d5c177a04c29e3c78ce89ac86f1595681cab149b65b97c4e227198"
    [aarch64]="12b331c1d2db6b9eb13cfca64306b1b157a86eb69db83023e261eaa7e7c14588"
)

# --version works without touching the network (repo-wide idiom).
if [[ "${1:-}" == "--version" || "${1:-}" == "-V" ]]; then
    echo "install-shellcheck $VERSION"
    exit 0
fi

# Resolve the host BEFORE parsing options or touching the network: an
# unsupported machine has no asset to install, and refusing here names the
# architecture instead of failing later on a 404 or a checksum mismatch.
host_arch="$(tac_host_arch)"
tarball="shellcheck-${SHELLCHECK_VERSION}.linux.${host_arch}.tar.xz"
url="https://github.com/koalaman/shellcheck/releases/download/${SHELLCHECK_VERSION}/${tarball}"
sha256="${SHELLCHECK_SHA256[$host_arch]}"

# --print-asset: the resolution above, printed without a download.  It exists so
# the arch mapping has a network-free witness a test can check.
if [[ "${1:-}" == "--print-asset" ]]; then
    printf 'asset=%s\nurl=%s\nsha256=%s\n' "$tarball" "$url" "$sha256"
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

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

echo "Downloading shellcheck ${SHELLCHECK_VERSION} (${host_arch}) ..."
# --connect-timeout/--max-time: without them a stalled connection blocks the
# installer indefinitely, and this runs before shellcheck exists to check anything.
curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 10 --max-time 300 \
    -o "$workdir/$tarball" "$url"

sha256sum -c - <<< "${sha256}  $workdir/$tarball" >/dev/null
echo "sha256 verified."

tar -xJf "$workdir/$tarball" -C "$workdir"
install -D -m 755 "$workdir/shellcheck-${SHELLCHECK_VERSION}/shellcheck" \
    "$prefix/shellcheck"

echo "Installed $prefix/shellcheck ($("$prefix/shellcheck" --version | sed -n '2p'))"

# end of file
