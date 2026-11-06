// SPDX-License-Identifier: GPL-3.0-or-later
// lib/consent/consent_policy.dart

/// 隐私同意条款版本。policy 实质内容（隐私政策 / ToS 文本）变更时 bump。
///
/// 用户的同意记录绑定到 [ConsentPolicy.currentVersion]。启动时 ConsentManager
/// 比对，版本不同会重新弹首启动同意页（不退 app，但必须重新 accept）。
///
/// 版本号约定：v1, v2, ... 单调递增字符串。
abstract class ConsentPolicy {
  /// 当前条款版本。修改 lib/legal/privacy_policy.dart 或 terms_of_service.dart
  /// 实质内容时必须 bump（typo/格式微调不算实质内容）。
  static const String currentVersion = 'v1';
}
