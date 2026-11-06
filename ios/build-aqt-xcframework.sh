#!/usr/bin/env bash
# Build aqt_client_ffi as xcframework for iOS device + simulator.
# Requires: cargo, Rust toolchain, Xcode command-line tools.
# Usage: cd ios && ./build-aqt-xcframework.sh
#
# 只出 arm64：真机 aarch64-apple-ios + 模拟器 aarch64-apple-ios-sim（Apple
# Silicon 模拟器）。不编 x86_64-apple-ios（Intel 模拟器）—— 本机与 CI 均为
# arm64 模拟器，且 x86_64 下 cc-rs 会错选 iPhoneOS 真机 SDK 导致 ring 的
# C 编译报 "Unsupported architecture"（SDK 头文件只认 arm/arm64）。

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
AQT_CRATE="${REPO_ROOT}/rust/aqt_client_ffi"
FRAMEWORKS_DIR="${REPO_ROOT}/ios/Frameworks"

echo "==> Building aqt_client_ffi for iOS targets"

# Device target
rustup target add aarch64-apple-ios 2>/dev/null || true
cargo build --manifest-path="${AQT_CRATE}/Cargo.toml" \
    --release --target aarch64-apple-ios

# Simulator target (arm64 — Apple Silicon / CI runners)
rustup target add aarch64-apple-ios-sim 2>/dev/null || true
cargo build --manifest-path="${AQT_CRATE}/Cargo.toml" \
    --release --target aarch64-apple-ios-sim

# Build xcframework (single-arch simulator slice, no lipo needed)
mkdir -p "${FRAMEWORKS_DIR}"
rm -rf "${FRAMEWORKS_DIR}/AqtClientFfi.xcframework"
xcodebuild -create-xcframework \
    -library "${REPO_ROOT}/rust/target/aarch64-apple-ios/release/libaqt_client_ffi.a" \
    -headers "${AQT_CRATE}/include" \
    -library "${REPO_ROOT}/rust/target/aarch64-apple-ios-sim/release/libaqt_client_ffi.a" \
    -headers "${AQT_CRATE}/include" \
    -output "${FRAMEWORKS_DIR}/AqtClientFfi.xcframework"

echo "==> Done: ${FRAMEWORKS_DIR}/AqtClientFfi.xcframework"
echo ""
echo "Next: Add AqtClientFfi.xcframework to Runner target in Xcode:"
echo "  1. Open ios/Runner.xcworkspace in Xcode"
echo "  2. Runner target → General → Frameworks, Libraries → + → Add Other → Add Files"
echo "  3. Select ios/Frameworks/AqtClientFfi.xcframework"
echo "  4. Set to 'Embed & Sign' (or 'Do Not Embed' for static)"
