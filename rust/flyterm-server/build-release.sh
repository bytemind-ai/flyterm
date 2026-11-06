#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

TARGETS=(
  "x86_64-unknown-linux-musl"
  "aarch64-unknown-linux-musl"
)

for target in "${TARGETS[@]}"; do
  echo "==> Building ${target}"
  rustup target add "${target}" 2>/dev/null || true
  cargo build --release --target "${target}" -p flyterm-server
  BIN_PATH="target/${target}/release/flyterm-server"
  OUT_PATH="dist/flyterm-server-${target}"
  mkdir -p dist
  cp "${BIN_PATH}" "${OUT_PATH}"
  echo "==> Built ${OUT_PATH}"
done

echo "Done. Artifacts in dist/"
