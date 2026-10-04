#!/usr/bin/env bash
# shellcheck shell=bash
# ==============================================================================
# install-bats.sh — Install the pinned bats-core release.
# ==============================================================================
# The pin matters: bats 1.10.0 (apt noble) accepts a suite it cannot parse —
# `bats --count` on an unterminated `@test {` prints a count and exits 0 — while
# 1.11.x rejects it and exits 1.  tools/lint.sh's `.bats` branch turns that into
# PASS or FAIL, so the same tree lints clean on one bats and blocks on another.
# Resolving a PIN, rather than "what PATH finds", is what makes that gate mean
# the same thing locally and in CI.
#
# bats-core publishes no binary asset — the only artifact is GitHub's
# auto-generated source archive for the tag, whose CHECKSUM IS NOT STABLE
# (GitHub regenerates these archives; the bytes changed in 2023).  Gating on the
# tarball's sha256 would therefore fail spuriously on a later download of the
# identical tag, so the stable check is the CONTENT of the entry point, pinned
# below, plus the installed version this script asserts at the end.
#
# The tree is COPIED into place (bin/, libexec/, lib/) rather than installed by
# running the archive's own install.sh: no third-party script is executed — the
# same posture as tools/install-shellcheck.sh and tools/install-gitleaks.sh,
# which install artifacts and run nothing from them.
#
# Usage:
#   sudo tools/install-bats.sh                   # install under /usr/local
#        tools/install-bats.sh -p "$HOME/.local"  # install under a user prefix
# ==============================================================================
# AI INSTRUCTION: Increment version on significant changes.
# Module Version: 1
#   v1 (2026-10-04): first cut — pinned bats-core v1.11.1, entry-point content
#   hash verified, idempotent skip when the pin is already at the target prefix.
VERSION="1.0"
set -euo pipefail

BATS_VERSION="v1.11.1"
# sha256 of bin/bats in the v1.11.1 source tree.  This is a CONTENT hash, stable
# for the tag; the enclosing archive's own sha256 is not (see the header).
BATS_BIN_SHA256="6b04c75d2657f2059dcd239a59be892d56c6b4603afdf1bc90a63f9ecbf70a7c"

if [[ "${1:-}" == "--version" || "${1:-}" == "-V" ]]
then
    echo "install-bats $VERSION"
    exit 0
fi

prefix="/usr/local"

while getopts ":p:" _opt
do
    case "$_opt" in
        p) prefix="$OPTARG" ;;
        *) echo "install-bats: unknown option -${OPTARG:-}" >&2; exit 2 ;;
    esac
done
shift $((OPTIND - 1))

# Idempotent, and therefore egress-free when the pin is already in place.  The
# contract is "the PIN is installed at <prefix>", not "a tarball was fetched".
if [[ -x "$prefix/bin/bats" ]]
then
    # swallow-ok: version probe of a possibly-foreign binary; non-zero IS the signal
    if _have="$("$prefix/bin/bats" --version 2>/dev/null)" \
       && [[ "$_have" == "Bats ${BATS_VERSION#v}" ]]
    then
        echo "bats ${BATS_VERSION} already installed at $prefix/bin/bats — nothing to do."
        exit 0
    fi
    # Present but not the pin: install the pin rather than trust it, because the
    # version skew between lint machines is the exact failure this pin prevents.
    echo "Installed $prefix/bin/bats is not ${BATS_VERSION} (or will not run) — installing the pin."
fi

stem="bats-core-${BATS_VERSION#v}"
tarball="${stem}.tar.gz"
url="https://github.com/bats-core/bats-core/archive/refs/tags/${BATS_VERSION}.tar.gz"

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

echo "Downloading bats-core ${BATS_VERSION} ..."
curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 10 --max-time 300 \
    -o "$workdir/$tarball" "$url"

tar -xzf "$workdir/$tarball" -C "$workdir"

sha256sum -c - <<< "${BATS_BIN_SHA256}  $workdir/$stem/bin/bats" >/dev/null
echo "bin/bats content verified."

install -d -m 755 "$prefix/bin" "$prefix/libexec/bats-core" "$prefix/lib/bats-core"
install -m 755 "$workdir/$stem/bin"/* "$prefix/bin"
install -m 755 "$workdir/$stem/libexec/bats-core"/* "$prefix/libexec/bats-core"
install -m 644 "$workdir/$stem/lib/bats-core"/* "$prefix/lib/bats-core"

# The authoritative check: what was installed IS the pin.
_have="$("$prefix/bin/bats" --version)" || {
    echo "install-bats: $prefix/bin/bats will not run" >&2
    exit 1
}
if [[ "$_have" != "Bats ${BATS_VERSION#v}" ]]
then
    echo "install-bats: installed $prefix/bin/bats reports '${_have}', expected 'Bats ${BATS_VERSION#v}'" >&2
    exit 1
fi
echo "Installed $prefix/bin/bats (${_have})"

# end of file
