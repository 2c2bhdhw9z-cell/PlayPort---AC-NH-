#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# On the Linux build runner, after install-sdk.sh: compile the release app's Swift for iOS with
# the runner's Swift and the Darwin SDK, as xtool does (`swift build --swift-sdk arm64-apple-ios`),
# before the native build. A Swift error then fails the job in minutes, not after its hours.
# Nothing is linked: .github/ci/typecheck/Package.swift has the app's targets without what the
# native build makes. WinIOS's sources come from Madeira at the pinned gitlink, the files
# build/stages/stage-artifacts.py copies (without patches/madeira-winios, which changes
# Winios.m and not the header Swift reads). The step leaves the checkout as it found it.
#
#   .github/ci/typecheck-app.sh
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
pin=$(git ls-tree HEAD upstream/madeira | awk '{print $3}')
[ -n "$pin" ] || { echo "::error::no upstream/madeira gitlink"; exit 1; }
win=app/Sources/WinIOS
if [ -e "$win" ]; then echo "::error::$win exists already"; exit 1; fi
saved=$(mktemp "${RUNNER_TEMP:-/tmp}/Package.swift.XXXXXX")
cp app/Package.swift "$saved"
resolved=keep
[ -e app/Package.resolved ] || resolved=remove
trap 'cp "$saved" app/Package.swift; rm -f "$saved"; rm -rf "$win"; [ "$resolved" = keep ] || rm -f app/Package.resolved' EXIT
mkdir -p "$win/include"
raw=https://raw.githubusercontent.com/willfaust/Madeira/$pin/app/Madeira
for f in Winios/Winios.m Winios/WiniosGamepad.c IOSDisplayShim.m; do
    curl -fsSL --retry 3 -o "$win/${f##*/}" "$raw/$f"
done
for f in Winios/Winios.h Winios/WiniosGamepad.h IOSDisplayShim.h; do
    curl -fsSL --retry 3 -o "$win/include/${f##*/}" "$raw/$f"
done
cp .github/ci/typecheck/Package.swift app/Package.swift
swift build --package-path app --configuration debug --build-system native --swift-sdk arm64-apple-ios \
    --scratch-path "${RUNNER_TEMP:-/tmp}/typecheck-app" --target Playport
