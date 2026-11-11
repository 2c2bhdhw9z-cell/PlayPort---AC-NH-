#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# On the Linux build runner: install the darwin.xtoolsdk the macOS job packaged,
# with Playport's own xtool, and export DARWIN_SDK the way tools/machine.py
# (pp setup) finds it: the directory of the SDK's first toolset path.
#
#   .github/ci/install-sdk.sh TARBALL    TARBALL is deleted once unpacked
set -euo pipefail
TARBALL=${1:?usage: install-sdk.sh darwin.xtoolsdk.tar.zst}
: "${PLAYPORT_BUILD:?}"
XTOOL=$PLAYPORT_BUILD/inputs/xtool-src/.build/release/xtool
# xtool's libimobiledevice stack came back with the toolchain cache.
sudo ldconfig
work=$(mktemp -d "${RUNNER_TEMP:-/tmp}/sdk.XXXXXX")
trap 'rm -rf "$work"' EXIT

zstd -dc "$TARBALL" | tar -xf - -C "$work"
rm -f "$TARBALL"
"$XTOOL" sdk install "$work/darwin.xtoolsdk"

conf=$(swift sdk configure --show-configuration darwin arm64-apple-ios 2>&1 || true)
toolset=$(printf '%s\n' "$conf" | sed -n 's/.*toolsetPaths: \["\([^"]*\)".*/\1/p' | head -1)
if [ -z "$toolset" ]; then
    printf '%s\n' "$conf"
    echo "::error::swift sdk does not list the darwin SDK for arm64-apple-ios"
    exit 1
fi
sdk=$(dirname "$toolset")
for p in iPhoneOS.platform/Developer/SDKs/iPhoneOS26.5.sdk MacOSX.platform/Developer/SDKs/MacOSX26.5.sdk; do
    test -d "$sdk/Developer/Platforms/$p" || { echo "::error::no $p under $sdk"; exit 1; }
done
echo "DARWIN_SDK=$sdk" >> "$GITHUB_ENV"
echo "DARWIN_SDK=$sdk"
