#!/usr/bin/env bash
set -euo pipefail

# Vidsec local packaging script
VERSION="v2.0.0"
TARGET="${1:-native}"
NAME="linux-x86_64"

if [ "$TARGET" != "native" ]; then
    NAME="$TARGET"
fi

echo "==> Building vidsec for $NAME (ReleaseSafe)..."
if [ "$TARGET" = "native" ]; then
    zig build -Doptimize=ReleaseSafe --summary all
else
    zig build -Dtarget="$TARGET" -Doptimize=ReleaseSafe --summary all
fi

PKG_NAME="vidsec-${VERSION}-${NAME}"
DIST_DIR="dist/${PKG_NAME}"

echo "==> Packaging into ${DIST_DIR}..."
rm -rf "dist/${PKG_NAME}" "dist/${PKG_NAME}.tar.gz"
mkdir -p "${DIST_DIR}/bin" "${DIST_DIR}/lib" "${DIST_DIR}/configs"

# Binaries & plugins
cp zig-out/bin/* "${DIST_DIR}/bin/"
cp -P zig-out/lib/* "${DIST_DIR}/lib/"

# Configs & documentation
cp configs/pipeline.yaml configs/schemas.yaml "${DIST_DIR}/configs/"
[ -f README.md ] && cp README.md "${DIST_DIR}/"

# Tarball
cd dist
tar -czvf "${PKG_NAME}.tar.gz" "${PKG_NAME}"
sha256sum "${PKG_NAME}.tar.gz" > "${PKG_NAME}.tar.gz.sha256"
cat *.sha256 > SHA256SUMS.txt

echo "==> Release package ready:"
ls -lh "${PKG_NAME}.tar.gz"
