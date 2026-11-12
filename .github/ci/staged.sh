#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# The native stages' outputs between CI runs (.github/workflows/build-ipa.yml): what the app and
# verify stages read once unix, pe, fex, dxmt, vulkan, steamapi, idevice, stage and notices have
# run, with their stamps (build/pipeline). A run whose inputs to those stages are unchanged then
# runs only inputs, sources, app and verify: a change to the app's Swift alone builds the app.
#
#   staged.sh keep      after pp build: when every one of those stages finished, put the build
#                       records the run wrote (app/artifacts.tsv, build/generated/wine-pe-*.tsv)
#                       in $PLAYPORT_BUILD/staged-records and set the step output complete=true
#   staged.sh restore   after the cache is restored: put those records over the checkout's, so
#                       the stage and notices stages' digests match their stamps
#
# Wine PE and DXMT hash their build directory, so a CI build's records differ from the committed
# ones; build/pipeline puts the checkout's back when a run ends (keep_records) and leaves its own
# beside the IPA, or in the run directory when the run stopped before verify.
set -euo pipefail
: "${PLAYPORT_BUILD:?}"
cd "$(git rev-parse --show-toplevel)"
run=$PLAYPORT_BUILD/run
records=$PLAYPORT_BUILD/staged-records
case ${1:-} in
keep)
    for s in unix pe fex dxmt vulkan steamapi idevice; do
        if [ ! -f "$run/stamps/$s" ]; then echo "the $s stage did not finish: nothing kept"; exit 0; fi
    done
    for s in stage notices; do
        if [ ! -f "app/Staged/.stamps/$s" ]; then echo "the $s stage did not finish: nothing kept"; exit 0; fi
    done
    rm -rf "$records"
    mkdir -p "$records"
    src=$(ls -dt "$PLAYPORT_BUILD"/out/*/records "$run/records" 2>/dev/null | head -1 || true)
    if [ -n "$src" ]; then
        cp "$src"/*.tsv "$records/"
    elif ! git diff --quiet -- app/artifacts.tsv build/generated; then
        cp app/artifacts.tsv build/generated/wine-pe-*.tsv "$records/"
    fi
    ls -l "$records"
    du -sh "$run/stamps" "$run/dxmt-patched/pe" app/Staged app/Sources/S1Probe/Runtime app/Sources/WinIOS
    echo "complete=true" >> "$GITHUB_OUTPUT"
    ;;
restore)
    if [ -f "$records/artifacts.tsv" ]; then cp "$records/artifacts.tsv" app/artifacts.tsv; fi
    for f in "$records"/wine-pe-*.tsv; do
        if [ -f "$f" ]; then cp "$f" build/generated/; fi
    done
    git status --short -- app/artifacts.tsv build/generated
    ls "$run/stamps" app/Staged/.stamps
    ;;
*)
    echo "usage: staged.sh keep|restore" >&2
    exit 2
    ;;
esac
