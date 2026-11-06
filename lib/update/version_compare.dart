// SPDX-License-Identifier: GPL-3.0-or-later
// lib/update/version_compare.dart

/// 极简 semver "major.minor.patch" 比对。
/// 不实现完整 semver；只支持 `vX.Y.Z` / `X.Y.Z[+N|-suffix]` 形态。
abstract class VersionCompare {
  /// `latest` 是否严格高于 `current`。任一无法解析返回 false（不弹更新）。
  static bool isNewer(String latest, {required String current}) {
    final l = _parse(latest);
    final c = _parse(current);
    if (l == null || c == null) return false;
    for (var i = 0; i < 3; i++) {
      if (l[i] > c[i]) return true;
      if (l[i] < c[i]) return false;
    }
    return false;
  }

  static List<int>? _parse(String raw) {
    var s = raw.trim();
    if (s.startsWith('v') || s.startsWith('V')) s = s.substring(1);
    final cut = RegExp(r'[+\-]').firstMatch(s);
    if (cut != null) s = s.substring(0, cut.start);
    final parts = s.split('.');
    if (parts.length != 3) return null;
    try {
      return parts.map(int.parse).toList();
    } catch (_) {
      return null;
    }
  }
}
