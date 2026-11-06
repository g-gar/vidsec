#!/usr/bin/env bash
set -euo pipefail

# Vidsec local packaging script
ZON_VER="$(grep '\.version' build.zig.zon | sed -E 's/.*"([^"]+)".*/\1/')"
VERSION="v${ZON_VER}"
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
if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "${PKG_NAME}.tar.gz" > "${PKG_NAME}.tar.gz.sha256"
else
    shasum -a 256 "${PKG_NAME}.tar.gz" > "${PKG_NAME}.tar.gz.sha256"
fi
cat *.sha256 > SHA256SUMS.txt

echo "==> Release package ready:"
ls -lh "${PKG_NAME}.tar.gz"
