#!/usr/bin/env bash
# FlyTerm APK 构建脚本 —— **唯一的构建入口**。
#
# 为什么要有这个脚本（而不是让人手打 flutter 命令）：
# 构建参数里有四条**互相咬合**的约束，漏一条就产出错的包。它们写在
# `CLAUDE.md` 的「构建约束」里，但手打命令时总会漏：
#
#   1. `--release`              —— 禁止 debug 包（会带上调试符号与可观测副作用）
#   2. `--split-per-abi`        —— 禁止 fat APK（体积翻倍，且与历史包签名/升级路径不一致）
#   3. `--target-platform android-arm64` —— 只出 arm64
#   4. `--dart-define=FLYTERM_ENABLE_IAP=false` —— **开源构建（全功能解锁）**
#
# 第 4 条默认值是开源模式：不带 IAP，功能全解锁，自行克隆构建的人不会撞上一个
# 他根本无法完成支付的 Paywall。商店发布包需要开启真实 IAP 闭环，所以这里保留
# 一个 `--release-build` 开关 —— 但它是**需要显式指定**的，默认永远是开源构建。
#
#
# ## 为什么不写死路径
#
# 旧版把 Flutter 路径硬编码在脚本里。那个 SDK 后来被一个版本不符的安装覆盖
# （Dart 3.7.2，而 pubspec 要求 ^3.13.0），于是脚本连 pub get 都过不去 ——
# 但「文件存在」这个检查骗过了所有人，没人想到是 SDK 版本的问题。
#
# 教训：硬编码工具链路径时，改名或降级不会有任何提示。现在改为按优先级探测
# 并校验 Dart 版本，见 `resolve_flutter`。
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

APK_OUT="build/app/outputs/flutter-apk"
APK_FILE="$APK_OUT/app-arm64-v8a-release.apk"

# ── 参数 ────────────────────────────────────────────────────────────────
# 默认：开源构建（全功能解锁，无 IAP）。商店包需显式 --release-build。
ENABLE_IAP=false
for arg in "$@"; do
  case "$arg" in
    --release-build)
      # 商店发布包：开启真实 IAP 闭环。
      ENABLE_IAP=true
      ;;
    -h|--help)
      sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument: $arg" >&2
      echo "usage: scripts/build_apk.sh [--release-build]" >&2
      exit 2
      ;;
  esac
done

# ── 找 Flutter ──────────────────────────────────────────────────────────
#
# **不能只信 PATH。** PATH 里的 flutter 未必是版本对的那个 —— 系统包管理器
# 或旧安装留下的 SDK 很常见，而本仓要求 Dart ^3.13.0。因此探测之后还要校验
# 版本，不符就报错而不是硬跑。
#
# 探测顺序：
#   1. $FLYTERM_FLUTTER 环境变量（显式指定，最高优先级）
#   2. $FLUTTER_HOME/bin/flutter
#   3. ~/flutter-*/bin/flutter（带版本号的并存安装，取最高版）
#   4. PATH 里的 flutter
#
# 选出 Dart 版本最高的一个；全都不满足下限就报错并列出各自版本，
# 让人一眼看出该改哪里。
#
# 上限下限取自 pubspec.yaml 的 `sdk: ^3.13.0`。硬编码在这里是有意的：
# 脚本要能在 `pub get` **之前**拦截错 SDK，读 pubspec 会把失败推迟到
# 编译阶段（那时报错信息离原因很远）。pubspec 改了这里也要跟着改。
MIN_DART="3.13.0"

dart_version_of() {
  # `Flutter 3.47.2 • ...` / `Dart 3.13.2 • ...` —— 取 Dart 那行。
  # 某些版本不打 Dart 行，那就退回 `dart --version`。
  local f="$1" out v
  out="$("$f" --version 2>/dev/null | grep -oE 'Dart [0-9]+\.[0-9]+\.[0-9]+' | head -1)"
  if [ -z "$out" ]; then
    local d
    d="$(dirname "$f")/dart"
    [ -x "$d" ] && out="$("$d" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
  fi
  v="${out##* }"
  echo "$v"
}

# 3.13.0 与 3.9.0 比较大小时必须按数值逐段比，字符串比较会把
# "3.9" 排在 "3.13" 前面。
version_ge() {
  local a="$1" b="$2"
  [ -z "$a" ] && return 1
  local IFS=.
  local -a x=($a) y=($b)
  for i in 0 1 2; do
    local xi="${x[$i]:-0}" yi="${y[$i]:-0}"
    if [ "$xi" -gt "$yi" ]; then return 0; fi
    if [ "$xi" -lt "$yi" ]; then return 1; fi
  done
  return 0
}

FLUTTER=""
BEST_VER=""
CANDIDATES=()
if [ -n "${FLYTERM_FLUTTER:-}" ]; then CANDIDATES+=("$FLYTERM_FLUTTER"); fi
while IFS= read -r p; do [ -n "$p" ] && CANDIDATES+=("$p"); done < <(
  {
    [ -n "${FLUTTER_HOME:-}" ] && ls -d "$FLUTTER_HOME/bin/flutter" 2>/dev/null
    ls -d "$HOME"/flutter-*/bin/flutter 2>/dev/null
  } | sort -Vr || true)
if command -v flutter >/dev/null 2>&1; then CANDIDATES+=("$(command -v flutter)"); fi

REJECTED=()
for cand in "${CANDIDATES[@]:-}"; do
  [ -n "$cand" ] || continue
  [ -x "$cand" ] || continue
  ver="$(dart_version_of "$cand")"
  if version_ge "$ver" "$MIN_DART"; then
    if [ -z "$BEST_VER" ] || version_ge "$ver" "$BEST_VER"; then
      BEST_VER="$ver"; FLUTTER="$cand"
    fi
  else
    REJECTED+=("$cand (Dart ${ver:-未知})")
  fi
done

if [ -z "$FLUTTER" ]; then
  {
    echo "ERROR: 找不到满足要求的 Flutter SDK（需要 Dart >= $MIN_DART）。"
    echo ""
    if [ "${#REJECTED[@]}" -gt 0 ]; then
      echo "以下候选都太旧（或不可用），已排除："
      for r in "${REJECTED[@]}"; do echo "  - $r"; done
      echo ""
    fi
    echo "候选来源（按优先级）："
    echo "  1. \$FLYTERM_FLUTTER"
    echo "  2. \$FLUTTER_HOME/bin/flutter 或 ~/flutter-<版本>/bin/flutter"
    echo "  3. PATH 里的 flutter"
    echo ""
    echo "显式指定：export FLYTERM_FLUTTER=/path/to/flutter/bin/flutter"
  } >&2
  exit 1
fi

if [ "${#REJECTED[@]}" -gt 0 ]; then
  echo "⚠ 已排除不合要求的 SDK："
  for r in "${REJECTED[@]}"; do echo "    $r"; done
fi
echo "▶ Flutter: $FLUTTER (Dart $BEST_VER)"

# ── 服务器资源（必须在构建前刷新）────────────────────────────────────────
# QUIC server 的 musl binary 是嵌进 APK assets 的；不刷新就会打包出一个
# 与当前 rust/ 源码不匹配的服务端 —— 而那种不一致在真机上才暴露。
if [ -x scripts/build-server-assets.sh ]; then
  echo "▶ 刷新 server assets..."
  scripts/build-server-assets.sh
fi

# ── 构建 ────────────────────────────────────────────────────────────────
if [ "$ENABLE_IAP" = "false" ]; then
  echo "▶ 构建 release APK（开源构建：全功能解锁，无 IAP）..."
else
  echo "▶ 构建 release APK（**商店发布包**：真实 IAP，--dart-define=FLYTERM_ENABLE_IAP=true）..."
  if [ "$(git rev-parse --abbrev-ref HEAD 2>/dev/null)" = "master" ] || [ -n "${CI:-}" ]; then
    : # 主干/CI 上构建发布包是预期用法
  else
    echo "   注意：当前不在 master（$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')）。" >&2
    echo "   发布包会走真实 IAP，确认这是你要的。" >&2
  fi
fi

# 开源贡献者通常没有发布 keystore。没有 android/key.properties 时自动回落到
# debug 签名（android/app/build.gradle.kts 的 allowDebugSigning opt-in）——
# Gradle 会自动读取 ORG_GRADLE_PROJECT_<name> 环境变量作为 project property，
# 这条路径对 `flutter build apk`（底层就是跑 gradlew）同样生效。
if [ ! -f android/key.properties ]; then
  echo "⚠ 未找到 android/key.properties，自动启用 debug 签名回落（allowDebugSigning）。"
  echo "  产物会用 debug key 签名，仅供本地安装/测试，不可对外分发。"
  export ORG_GRADLE_PROJECT_allowDebugSigning=true
fi

"$FLUTTER" build apk \
  --release \
  --split-per-abi \
  --target-platform android-arm64 \
  --dart-define=FLYTERM_ENABLE_IAP="$ENABLE_IAP"

# ── 后置校验 ─────────────────────────────────────────────────────────────
echo "▶ 校验 pubspec / APK / 下载页版本来源..."
python3 scripts/check_version_consistency.py --apk "$APK_FILE"

# 约束守护：这条命令能通过，说明 split-per-abi 真的生效了。fat APK 不会产生
# app-arm64-v8a-release.apk（它只有 app-release.apk），所以文件不存在即说明
# 有人改了构建方式 —— 那种包体积翻倍且与历史包不一致，必须拦住。
if [ ! -f "$APK_FILE" ]; then
  echo "ERROR: 期望的产物不存在：$APK_FILE" >&2
  echo "       说明 --split-per-abi 没生效（或 target-platform 不对）。" >&2
  ls -la "$APK_OUT" 2>/dev/null >&2 || true
  exit 1
fi

SIZE=$(du -sh "$APK_FILE" | cut -f1)
echo ""
echo "✓ 构建完成：$APK_FILE ($SIZE)"
if [ "$ENABLE_IAP" = "false" ]; then
  echo "  模式：开源构建（全功能解锁，无 IAP）"
else
  echo "  模式：商店发布包（真实 IAP）"
fi
