#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Build the toolchains Playport's build takes as inputs, in the places the
# workflow caches (each step is skipped when its result is already there):
#   - llvm-mingw 20260922 with its aarch64 CRT rebuilt for arm64ec, and
#     libclang_rt.builtins-aarch64.a as libgcc*.a (docs/BUILDING.md, "llvm-mingw");
#   - SPIRV-LLVM-Translator for LLVM 22, which Mesa's host shader tools link
#     (docs/BUILDING.md, "KosmicKrisp"; Ubuntu and apt.llvm.org do not package it);
#   - Playport's own ld64, patched xtool and Rust under $PLAYPORT_BUILD/inputs
#     (build/toolchain/*.sh, which stage_inputs would otherwise run on demand).
set -euo pipefail
: "${PLAYPORT_BUILD:?}" "${LLVM_MINGW:?}" "${SPIRV_PREFIX:?}"
REPO=$(cd "$(dirname "$0")/../.." && pwd)
export JOBS=${JOBS:-$(nproc)}
work=$(mktemp -d "${RUNNER_TEMP:-/tmp}/toolchain.XXXXXX")
trap 'rm -rf "$work"' EXIT

LLVM_MINGW_TAG=20260922
LLVM_MINGW_SHA256=bb7bb7654b33d5aa8712acb837c963b2e0c56352560c76105270a3268c665c21
# llvm-mingw 20260922's MINGW_W64_VERSION (docs/BUILDING.md)
MINGW_W64_COMMIT=57b595039040eaa15bece85b7cc71d952281b269
SPIRV_BRANCH=llvm_release_220

own() { sudo mkdir -p "$1" && sudo chown "$(id -u):$(id -g)" "$1"; }

if [ ! -f "$LLVM_MINGW/aarch64-w64-mingw32/lib/libgcc.a" ]; then
    echo "::group::llvm-mingw $LLVM_MINGW_TAG with the arm64ec CRT"
    tarball=$work/llvm-mingw.tar.xz
    curl -fsSL -o "$tarball" \
        "https://github.com/mstorsjo/llvm-mingw/releases/download/$LLVM_MINGW_TAG/llvm-mingw-$LLVM_MINGW_TAG-ucrt-ubuntu-22.04-x86_64.tar.xz"
    echo "$LLVM_MINGW_SHA256  $tarball" | sha256sum -c -
    rm -rf "$LLVM_MINGW"
    own "$LLVM_MINGW"
    tar -xJf "$tarball" -C "$LLVM_MINGW" --strip-components=1
    rm -f "$tarball"
    git init -q "$work/mingw-w64"
    git -C "$work/mingw-w64" fetch -q --depth 1 https://github.com/mingw-w64/mingw-w64.git "$MINGW_W64_COMMIT"
    git -C "$work/mingw-w64" checkout -q FETCH_HEAD
    mkdir "$work/mingw-w64/mingw-w64-crt/build-aarch64"
    # The prefix is the target's own directory, as llvm-mingw's build-mingw-w64.sh
    # installs it: for an aarch64 host the CRT's libraries go to PREFIX/lib, and
    # clang's MinGW driver reads $LLVM_MINGW/aarch64-w64-mingw32/lib.
    (
        cd "$work/mingw-w64/mingw-w64-crt/build-aarch64"
        export PATH="$LLVM_MINGW/bin:$PATH"
        ../configure --prefix="$LLVM_MINGW/aarch64-w64-mingw32" --host=aarch64-w64-mingw32 \
            --disable-lib32 --disable-lib64 --enable-libarm64 --enable-arm64x \
            --with-default-msvcrt=ucrt --enable-cfguard --enable-silent-rules >/dev/null
        make -j"$JOBS" >/dev/null
        make install >/dev/null
    )
    builtins=$(ls "$LLVM_MINGW"/lib/clang/*/lib/windows/libclang_rt.builtins-aarch64.a | head -1)
    for n in libgcc.a libgcc_eh.a libgcc_s.a; do
        cp "$builtins" "$LLVM_MINGW/aarch64-w64-mingw32/lib/$n"
    done
    "$LLVM_MINGW/bin/aarch64-w64-mingw32-clang" --version | head -1
    echo "::endgroup::"
fi

if [ ! -f "$SPIRV_PREFIX/lib/pkgconfig/LLVMSPIRVLib.pc" ]; then
    echo "::group::SPIRV-LLVM-Translator ($SPIRV_BRANCH)"
    git clone -q --depth 1 -b "$SPIRV_BRANCH" https://github.com/KhronosGroup/SPIRV-LLVM-Translator.git "$work/spirv"
    own "$SPIRV_PREFIX"
    cmake -S "$work/spirv" -B "$work/spirv/build" -G Ninja -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++ \
        -DLLVM_DIR=/usr/lib/llvm-22/lib/cmake/llvm -DLLVM_SPIRV_INCLUDE_TESTS=OFF \
        -DCMAKE_INSTALL_PREFIX="$SPIRV_PREFIX" >/dev/null
    ninja -C "$work/spirv/build" install >/dev/null
    PKG_CONFIG_PATH=$SPIRV_PREFIX/lib/pkgconfig pkg-config --modversion LLVMSPIRVLib
    echo "::endgroup::"
fi

cd "$REPO"
inputs=$PLAYPORT_BUILD/inputs
if [ ! -x "$inputs/apple-linker/prefix/bin/arm64-apple-darwin-ld" ]; then
    echo "::group::ld64 (build/toolchain/ld64.sh)"
    bash build/toolchain/ld64.sh
    # The cache keeps the installed prefix; libtapi's LLVM build tree is only scratch.
    rm -rf "$inputs/apple-linker/apple-libtapi/build" "$inputs/apple-linker/apple-libdispatch/build"
    echo "::endgroup::"
fi
if [ ! -x "$inputs/xtool-src/.build/release/xtool" ]; then
    echo "::group::xtool (build/toolchain/xtool.sh)"
    bash build/toolchain/xtool.sh
    # Package sources; the release directory keeps the binary and its resource bundles.
    rm -rf "$inputs/xtool-src/.build/checkouts" "$inputs/xtool-src/.build/repositories"
    echo "::endgroup::"
fi
rust=$(awk '$1 == "rust" {print $2}' pins.lock)
if ! RUSTUP_HOME=$inputs/rust/rustup "$inputs/rust/cargo/bin/rustc" --version 2>/dev/null | grep -q "^rustc $rust "; then
    echo "::group::Rust $rust (build/toolchain/rust.sh)"
    bash build/toolchain/rust.sh
    echo "::endgroup::"
fi

du -sh "$LLVM_MINGW" "$SPIRV_PREFIX" "$inputs"/* 2>/dev/null || true
