#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="${HOME}/.flyterm-server"
BIN_DIR="${INSTALL_DIR}/bin"
mkdir -p "${BIN_DIR}"

OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
if [ "$OS" != linux ]; then
  echo "unsupported OS: $OS (only Linux binaries are published)" >&2
  exit 1
fi
ARCH="$(uname -m)"
case "$ARCH" in
  x86_64|amd64) ARCH=x86_64 ;;
  aarch64|arm64) ARCH=aarch64 ;;
  *) echo "unsupported arch: $ARCH" >&2; exit 1 ;;
esac

# 资产名和 .github/workflows/{release,flyterm-server-release}.yml 对齐。
VERSION="${AQT_VERSION:-latest}"
REPO="bytemind-ai/flyterm"
ASSET="flyterm-server-${OS}-${ARCH}.gz"
if [ "$VERSION" = latest ]; then
  URL="https://github.com/${REPO}/releases/latest/download/${ASSET}"
else
  URL="https://github.com/${REPO}/releases/download/${VERSION}/${ASSET}"
fi

echo "Downloading flyterm-server (${OS}-${ARCH}, ${VERSION})..."
curl -fsSL "${URL}" | gunzip > "${BIN_DIR}/flyterm-server.new"
chmod +x "${BIN_DIR}/flyterm-server.new"
mv "${BIN_DIR}/flyterm-server.new" "${BIN_DIR}/flyterm-server"
"${BIN_DIR}/flyterm-server" --version

echo ""
echo "Done. Add to PATH: export PATH=\"\${HOME}/.flyterm-server/bin:\$PATH\""
