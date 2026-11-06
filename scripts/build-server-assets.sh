#!/usr/bin/env bash
# Build musl static flyterm-server binary for both Linux targets,
# copy to assets/flyterm-server/ for APK bundling.
#
# Required: rustup 1.99 toolchain with x86_64-unknown-linux-musl
# and aarch64-unknown-linux-musl targets installed; musl-tools (apt);
# zig 0.13 (aarch64 only); cargo-zigbuild (auto-installed if missing).
#
# Options:
#   --force, -f    rebuild even if assets already match current source
#
# Env:
#   FLYTERM_REQUIRE_AARCH64=1   fail instead of warn when the aarch64 build
#                               fails. CI sets this so a release can't
#                               silently ship without the ARM binary.
#
# Smart-skip: if assets/flyterm-server/VERSION matches the cargo version
# plus the SHA of the last commit touching rust/flyterm-server or
# rust/aqt_protocol, AND no source file is newer than the bundled gz,
# the script exits 0 immediately. This makes the script safe to call
# from Gradle on every APK build with negligible overhead.
set -euo pipefail
cd "$(dirname "$0")/../rust"

TOOLCHAIN="${TOOLCHAIN:-+1.99}"

# ── 找 cargo ────────────────────────────────────────────────────────────────
#
# **rustup shim 优先，不能只用 `command -v cargo`。** TOOLCHAIN 的 `+1.99`
# 是 rustup 的 toolchain 指令，只有 shim（~/.cargo/bin/cargo → rustup）认识。
# 发行版装的 /usr/bin/cargo 不是 shim，撞上它会报：
#
#     error: no such command: `+1.99`
#     Cargo does not handle `+toolchain` directives.
#
# 而 PATH 里先出现发行版 cargo 是很常见的（apt install cargo）。所以查找顺序
# 是 $CARGO → $CARGO_HOME/bin → ~/.cargo/bin → PATH，最后再校验它确实能处理
# toolchain 指令，不行就明确报错而不是让 cargo 吐一句难懂的话。
_rustup_home="${CARGO_HOME:-$HOME/.cargo}"
if [ -z "${CARGO:-}" ]; then
  if [ -x "$_rustup_home/bin/cargo" ]; then
    CARGO="$_rustup_home/bin/cargo"
  else
    CARGO="$(command -v cargo || true)"
  fi
fi

if [ -z "$CARGO" ]; then
  echo "ERROR: 找不到 cargo。安装 rustup（https://rustup.rs）或设 \$CARGO。" >&2
  exit 1
fi

if [ -n "$TOOLCHAIN" ] && ! "$CARGO" "$TOOLCHAIN" --version >/dev/null 2>&1; then
  echo "ERROR: $CARGO 不认识 toolchain 指令 '$TOOLCHAIN'。" >&2
  echo "       它多半不是 rustup shim（发行版的 /usr/bin/cargo 就不是）。" >&2
  echo "       装 rustup 后重试，或显式指定：" >&2
  echo "         CARGO=\$HOME/.cargo/bin/cargo scripts/build-server-assets.sh" >&2
  echo "       已装好 ${TOOLCHAIN#+} 工具链时也可跳过版本钉死：" >&2
  echo "         TOOLCHAIN= scripts/build-server-assets.sh" >&2
  exit 1
fi
ASSETS="../assets/flyterm-server"
mkdir -p "$ASSETS"

FORCE=0
for arg in "$@"; do
  case "$arg" in
    --force|-f) FORCE=1 ;;
    *) echo "WARN: unknown arg '$arg' ignored" ;;
  esac
done

# Compute SHA once and write to rust/server-sha.txt — single source of truth
# shared by build.rs (binary embed), VERSION asset, and Gradle check.
# Scope: last commit touching flyterm-server/ or aqt_protocol/.
# Pure Dart/Flutter changes don't affect this SHA.
#
# **没有 git 也要能跑。** 源码不是只经由 clone 分发 —— GitHub 的
# "Download ZIP"、release tarball、以及 CI 的浅归档都不带 .git。在
# `set -euo pipefail` 下，`git log` 失败会让整个脚本在第一步就 fatal，
# 而报错信息（"not a git repository"）完全不解释发生了什么。
#
# 此时 smart-skip 失去判据，退化为「无条件构建」—— 这正是 Gradle 侧
# `ensureServerAssetsFresh` 的做法（见 android/app/build.gradle.kts 的
# "git not available" 分支），两边保持一致。
SERVER_SHA=$(git log -1 --format=%h -- flyterm-server/ aqt_protocol/ 2>/dev/null || true)
if [ -z "$SERVER_SHA" ]; then
  SERVER_SHA="nogit"
  echo "NOTE: git 不可用（tarball / ZIP 下载？），跳过新鲜度检查，无条件构建。"
fi
CARGO_VERSION=$(grep '^version =' flyterm-server/Cargo.toml | head -1 \
                | sed 's/.*"\(.*\)".*/\1/')
EXPECTED_VERSION="${CARGO_VERSION}-${SERVER_SHA}"

# ── Smart skip ─────────────────────────────────────────────────────────────
# Skip rebuild if all three hold:
#   1. assets/flyterm-server/VERSION matches "<cargo_version>-<server_sha>"
#   2. both gz binaries exist
#   3. no source file (.rs / Cargo.toml / Cargo.lock) is newer than the
#      x86_64 gz — catches uncommitted source edits that wouldn't shift
#      the git SHA but should still trigger rebuild.
if [ "$FORCE" -eq 0 ] \
   && [ -f "$ASSETS/VERSION" ] \
   && [ "$(cat "$ASSETS/VERSION")" = "$EXPECTED_VERSION" ] \
   && [ -f "$ASSETS/flyterm-server-linux-x86_64.gz" ] \
   && [ -f "$ASSETS/flyterm-server-linux-aarch64.gz" ]; then
  NEWER=$(find flyterm-server aqt_protocol Cargo.lock \
             -newer "$ASSETS/flyterm-server-linux-x86_64.gz" \
             -type f 2>/dev/null | head -1)
  if [ -z "$NEWER" ]; then
    echo "==> Server assets already fresh: $EXPECTED_VERSION (use --force to rebuild)"
    echo "$SERVER_SHA" > server-sha.txt
    exit 0
  fi
  echo "==> $NEWER newer than bundled gz — rebuilding"
fi

echo "$SERVER_SHA" > server-sha.txt
echo "==> Server SHA: $SERVER_SHA (written to rust/server-sha.txt)"

# 先清掉旧产物：aarch64 软失败时，上一次留下的旧 aarch64.gz 会和新的
# x86_64 版本号对不上，却照样被打进 APK。
rm -f "$ASSETS"/flyterm-server-linux-*

# x86_64: musl-tools 提供 x86_64-linux-musl-gcc, cargo build 直接走
echo "==> Building x86_64 flyterm-server..."
$CARGO $TOOLCHAIN build --release \
  --target x86_64-unknown-linux-musl -p flyterm-server \
  --features flyterm-server/compression
# Note: history and persist-sessions are excluded from the default APK build.
# They add ~550 KB (bundled sqlite3) and are not required for basic PTY use.
# Compression: feature stays ENABLED so the LZ4 code path is present in the
# binary. Disable at runtime via `--no-compression` flag (used by the client
# bootstrap commands until we finish diagnosing the rendering-residue bug).
cp target/x86_64-unknown-linux-musl/release/flyterm-server \
   "$ASSETS/flyterm-server-linux-x86_64"
echo "==> x86_64 binary copied."

# aarch64: ring crate 的 NEON 汇编需要 cross gcc，用 cargo-zigbuild（它要
# zig）。本地默认软失败（只影响 ARM Linux 远端）；
# FLYTERM_REQUIRE_AARCH64=1 时硬失败。
echo "==> Building aarch64 flyterm-server via cargo-zigbuild..."
aarch64_rc=0
# pip 装的 ziglang 不进 PATH，cargo-zigbuild 会经 python 模块找到它。
if ! command -v zig >/dev/null \
   && ! python3 -c "import ziglang" 2>/dev/null; then
  echo "zig not found — install zig 0.13 (\`pip install ziglang==0.13.0\`," >&2
  echo "your package manager, or https://ziglang.org/download/)." >&2
  aarch64_rc=127
elif ! command -v cargo-zigbuild >/dev/null; then
  echo "==> Installing cargo-zigbuild..."
  $CARGO $TOOLCHAIN install --locked cargo-zigbuild || aarch64_rc=$?
fi
if [ $aarch64_rc -eq 0 ]; then
  set +e
  $CARGO $TOOLCHAIN zigbuild --release \
    --target aarch64-unknown-linux-musl -p flyterm-server \
    --features flyterm-server/compression
  aarch64_rc=$?
  set -e
fi
if [ $aarch64_rc -eq 0 ]; then
  cp target/aarch64-unknown-linux-musl/release/flyterm-server \
     "$ASSETS/flyterm-server-linux-aarch64"
  echo "==> aarch64 binary copied."
elif [ "${FLYTERM_REQUIRE_AARCH64:-}" = 1 ]; then
  echo "ERROR: aarch64 build failed (rc=$aarch64_rc) and FLYTERM_REQUIRE_AARCH64=1." >&2
  exit 1
else
  echo "WARN: aarch64 build failed (rc=$aarch64_rc); continuing with x86_64 only."
  echo "      ARM Linux remotes will be unsupported until aarch64 build is fixed."
fi

# gzip -9 binaries to ~35% original size. Remote `gunzip` decompresses
# after SFTP upload (saves ~65% install bandwidth, esp. on 4G).
echo "==> Compressing binaries with gzip -9..."
for f in "$ASSETS"/flyterm-server-linux-*; do
  # Skip if already gzipped or absent
  case "$f" in
    *.gz) continue ;;
  esac
  [ -f "$f" ] || continue
  gzip -9 -f "$f"  # produces $f.gz, removes original
  echo "    $(basename "$f").gz: $(ls -la "${f}.gz" | awk '{print $5}') bytes"
done

# 版本戳: cargo version + SHA (computed at top, single source of truth).
echo "==> Writing VERSION: $EXPECTED_VERSION"
echo "$EXPECTED_VERSION" > "$ASSETS/VERSION"

echo "==> Built assets:"
ls -la "$ASSETS/"
echo "Done. Run: flutter build apk --release ..."
