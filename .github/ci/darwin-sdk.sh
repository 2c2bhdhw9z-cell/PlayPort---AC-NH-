#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# On a macOS runner: package the iOS and macOS SDKs of the runner's Xcode 26.6
# as xtool's darwin.xtoolsdk for an x86-64 Linux host, with the xtool release
# Playport pins (1.20.1). This is what `xtool sdk install <Xcode 26.6 .xip> --slim`
# does on Linux (docs/BUILDING.md, DARWIN_SDK), without an Apple ID download.
#
#   .github/ci/darwin-sdk.sh OUTDIR    writes OUTDIR/darwin.xtoolsdk.tar.zst
#
# Apple's SDK is not redistributable. The workflow hands this file to the Linux
# build job through an Actions cache entry of the same run, never as an artifact,
# and deletes the entry once the build job has it.
set -euo pipefail
OUT=${1:?usage: darwin-sdk.sh OUTDIR}
XCODE=/Applications/Xcode_26.6.app
XTOOL_TAG=1.20.1
XTOOL_ZIP_SHA256=39123efc283528b119fa3567dc1123059d6690aab76c80e6003470d17c333ca2
work=$(mktemp -d "${RUNNER_TEMP:-/tmp}/darwin-sdk.XXXXXX")
trap 'rm -rf "$work"' EXIT

if [ ! -d "$XCODE" ]; then
    echo "::error::no $XCODE on this runner"
    ls -d /Applications/Xcode*
    exit 1
fi
for p in iPhoneOS MacOSX; do
    echo "$p: $(ls "$XCODE/Contents/Developer/Platforms/$p.platform/Developer/SDKs" | tr '\n' ' ')"
done

curl -fsSL -o "$work/xtool.app.zip" "https://github.com/xtool-org/xtool/releases/download/$XTOOL_TAG/xtool.app.zip"
echo "$XTOOL_ZIP_SHA256  $work/xtool.app.zip" | shasum -a 256 -c -
ditto -x -k "$work/xtool.app.zip" "$work"
xtool=$work/xtool.app/Contents/MacOS/xtool
# Without XTL_CLI=1 the app's executable starts its UI, which waits forever on a
# runner. The app's own CLI wrapper (Contents/Resources/bin/xtool) sets it.
export XTL_CLI=1
"$xtool" --version

"$xtool" sdk build "$XCODE" "$work/out" --arch x86_64
bundle=$work/out/darwin.xtoolsdk
for sdk in iPhoneOS.platform/Developer/SDKs/iPhoneOS26.5.sdk MacOSX.platform/Developer/SDKs/MacOSX26.5.sdk; do
    if [ ! -d "$bundle/Developer/Platforms/$sdk" ]; then
        echo "::error::the bundle has no $sdk"
        find "$bundle/Developer/Platforms" -maxdepth 4 -name '*.sdk'
        exit 1
    fi
done
du -sh "$bundle"

mkdir -p "$OUT"
# No AppleDouble files or extended attributes: GNU tar unpacks it on Linux.
COPYFILE_DISABLE=1 tar --no-xattrs --no-mac-metadata -C "$work/out" -cf - darwin.xtoolsdk |
    zstd -T0 -10 -q -o "$OUT/darwin.xtoolsdk.tar.zst"
ls -lh "$OUT"
