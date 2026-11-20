#!/bin/bash
# Clona/atualiza o armbian/build e compila o kernel 6.18 para o X96Q (H616)
# com os patches deste repositorio.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="${ARMBIAN_BUILD_DIR:-$ROOT/../armbian-build}"

if [ ! -d "$BUILD/.git" ]; then
    echo "clonando armbian/build em $BUILD"
    git clone --depth 1 https://github.com/armbian/build "$BUILD"
fi

DEST="$BUILD/userpatches/kernel/archive/sunxi-6.18"
mkdir -p "$DEST"
rm -f "$DEST"/*.patch
cp -v "$ROOT"/patches/*.patch "$DEST"/

echo "patches instalados:"
ls -1 "$DEST"

cd "$BUILD"
./compile.sh kernel \
    BOARD=x96q BRANCH=current RELEASE=trixie \
    BUILD_MINIMAL=yes KERNEL_ONLY=yes KERNEL_CONFIGURE=no DOCKER=yes

echo "debs em: $BUILD/output/debs"
ls -lh "$BUILD"/output/debs/*.deb
