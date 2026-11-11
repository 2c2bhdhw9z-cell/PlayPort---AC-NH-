#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Turn a GitHub-hosted ubuntu-24.04 runner into the Linux host Playport's build
# expects (docs/BUILDING.md, "Prerequisites"; build/pipeline, stage_inputs):
#   - LLVM 22 from apt.llvm.org as the unversioned tools in /usr/bin, which
#     build/stages/unix.sh, wine-pe.sh and gstreamer.sh call by absolute path;
#   - every host tool stage_inputs checks, plus what the stages use beyond that
#     list: m4 and pkg-config (Madeira's GMP/nettle/gnutls), Mesa's host
#     dependencies (meson >= 1.4, mako, PyYAML, packaging, SPIRV-Tools, libclc,
#     zlib, expat), glslang for DXVK and vkd3d-proton, Swift's usual packages;
#   - /usr/lib/swift, where stage_inputs copies Swift's clang resource headers
#     from (the runner image installs Swift under /usr/share/swift).
# The build area is $PLAYPORT_BUILD (the workflow sets it, on the runner's
# second disk at /mnt). SPIRV-LLVM-Translator and llvm-mingw come from
# .github/ci/toolchain.sh, which the workflow caches.
set -euo pipefail

LLVM=22
MESON=1.8.2
: "${PLAYPORT_BUILD:?set by the workflow}"

group() { echo "::group::$*"; }
endgroup() { echo "::endgroup::"; }

group "Disk"
# Preinstalled SDKs this build never uses; the apt LLVM, the Darwin SDK and the
# toolchains go on /.
sudo rm -rf /usr/share/dotnet /usr/local/lib/android /opt/ghc /usr/local/.ghcup \
    /opt/hostedtoolcache/CodeQL /usr/local/share/powershell /usr/local/share/chromium \
    /usr/share/miniconda 2>/dev/null || true
sudo mkdir -p "$PLAYPORT_BUILD"
sudo chown "$(id -u):$(id -g)" "$PLAYPORT_BUILD"
df -h / "$PLAYPORT_BUILD"
avail_gb=$(df -Pk "$PLAYPORT_BUILD" | awk 'NR==2 {print int($4/1024/1024)}')
[ "$avail_gb" -ge 40 ] || echo "::warning::only ${avail_gb} GB free for PLAYPORT_BUILD=$PLAYPORT_BUILD"
endgroup

group "apt packages"
sudo apt-get update -qq
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
    build-essential bison flex gettext m4 pkgconf cmake ninja-build \
    python3 python3-pip python3-pefile python3-mako python3-yaml python3-packaging pipx \
    xxd openssl patch git rsync p7zip-full curl ca-certificates gnupg unzip xz-utils zstd file \
    glslang-tools spirv-tools zlib1g-dev libexpat1-dev libdrm-dev libzstd-dev \
    uuid-dev libbsd-dev libssl-dev libcurl4-openssl-dev libxml2-dev libsqlite3-dev \
    libncurses-dev libz3-dev libedit-dev libpython3-dev >/dev/null
command -v 7za >/dev/null || sudo ln -sf "$(command -v 7z)" /usr/local/bin/7za
endgroup

group "LLVM $LLVM (apt.llvm.org)"
curl -fsSL https://apt.llvm.org/llvm-snapshot.gpg.key | sudo gpg --batch --yes --dearmor -o /usr/share/keyrings/apt.llvm.org.gpg
echo "deb [signed-by=/usr/share/keyrings/apt.llvm.org.gpg] http://apt.llvm.org/noble/ llvm-toolchain-noble-$LLVM main" |
    sudo tee /etc/apt/sources.list.d/llvm-$LLVM.list >/dev/null
sudo apt-get update -qq
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
    clang-$LLVM lld-$LLVM llvm-$LLVM llvm-$LLVM-dev llvm-$LLVM-tools \
    libclang-$LLVM-dev libclang-cpp$LLVM-dev libclc-$LLVM libclc-$LLVM-dev libpolly-$LLVM-dev >/dev/null
# Unversioned names in /usr/bin, over the image's clang 18: the stages call
# /usr/bin/clang and friends, and the PATH clang must be the same LLVM.
for t in /usr/lib/llvm-$LLVM/bin/*; do
    n=$(basename "$t")
    case $n in
        clang | clang++ | clang-cpp | ld.lld | ld64.lld | lld | lld-link | llc | opt | llvm-*)
            sudo ln -sf "$t" "/usr/bin/$n" ;;
    esac
done
clang --version | head -1
ld64.lld --version | head -1
llvm-config --version
endgroup

group "meson $MESON"
# The runner image points pipx at its own bin directory (PIPX_BIN_DIR=/opt/pipx_bin).
pipx install --quiet --force "meson==$MESON"
bindir=${PIPX_BIN_DIR:-$HOME/.local/bin}
echo "$bindir" >> "$GITHUB_PATH"
"$bindir/meson" --version
endgroup

group "Swift"
if [ -L /usr/lib/swift ] || [ ! -e /usr/lib/swift ]; then
    sudo ln -sfn /usr/share/swift /usr/lib/swift
fi
swift --version 2>&1 | head -1
ls -d /usr/lib/swift/usr/lib/clang/*/include ||
    { echo "::error::no Swift clang resource headers under /usr/lib/swift"; exit 1; }
endgroup

group "pkg-config paths"
clc=$(dirname "$(find /usr/lib /usr/share -name libclc.pc -print -quit 2>/dev/null)")
[ -n "$clc" ] && [ "$clc" != . ] || { echo "::error::libclc.pc not found"; exit 1; }
echo "PKG_CONFIG_PATH=${SPIRV_PREFIX:?}/lib/pkgconfig:$clc" >> "$GITHUB_ENV"
echo "libclc: $clc"
endgroup
