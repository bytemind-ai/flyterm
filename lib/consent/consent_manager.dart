// SPDX-License-Identifier: GPL-3.0-or-later
// lib/consent/consent_manager.dart
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'consent_policy.dart';

/// 隐私同意状态单例 + 持久化。
///
/// 启动流程：
///   1. main() 调 ConsentManager.instance.load() 异步读 SharedPreferences
///   2. 若 needsConsent → FlyTermApp 首屏 push ConsentFirstRunScreen
///   3. 用户 accept() / revoke() → 写回 SharedPreferences + 通知 listeners
///
/// 状态：
///   - agreed: bool — 用户是否同意当前版本
///   - agreedVersion: String? — 最后同意的 policy 版本（vs currentVersion）
///   - agreedAt: DateTime? — 同意时间戳
///   - crashReportingEnabled: bool — Sentry crash 上传开关
///   - analyticsEnabled: bool — Sentry breadcrumb/performance 上传开关
class ConsentManager extends ChangeNotifier {
  static final ConsentManager instance = ConsentManager();

  static const _kKey = 'consent.v1';

  bool _agreed = false;
  String? _agreedVersion;
  DateTime? _agreedAt;
  bool _crashReportingEnabled = true;
  bool _analyticsEnabled = true;
  bool _loaded = false;

  bool get agreed => _agreed;
  String? get agreedVersion => _agreedVersion;
  DateTime? get agreedAt => _agreedAt;
  bool get crashReportingEnabled => _crashReportingEnabled;
  bool get analyticsEnabled => _analyticsEnabled;
  bool get loaded => _loaded;

  /// 返回 true 表示需要弹首启动同意页（未同意 或 同意版本过期）。
  bool get needsConsent =>
      !_agreed || _agreedVersion != ConsentPolicy.currentVersion;

  /// 启动时调用。从 SharedPreferences 读取持久化的状态。
  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kKey);
    if (raw != null) {
      final m = _parse(raw);
      _agreed = m['agreed'] as bool? ?? false;
      _agreedVersion = m['version'] as String?;
      final ts = m['agreedAt'] as int?;
      _agreedAt = ts != null ? DateTime.fromMillisecondsSinceEpoch(ts) : null;
      _crashReportingEnabled = m['crashReporting'] as bool? ?? true;
      _analyticsEnabled = m['analytics'] as bool? ?? true;
    }
    _loaded = true;
  }

  /// 用户在 ConsentFirstRunScreen 点 [Agree and Continue]。
  Future<void> accept() async {
    _agreed = true;
    _agreedVersion = ConsentPolicy.currentVersion;
    _agreedAt = DateTime.now();
    await _persist();
    notifyListeners();
  }

  /// 用户在设置页 [Revoke Consent]。调用方负责 SystemNavigator.pop() 退出 app。
  Future<void> revoke() async {
    _agreed = false;
    _agreedVersion = null;
    _agreedAt = null;
    _crashReportingEnabled = false;
    _analyticsEnabled = false;
    await _persist();
    notifyListeners();
  }

  /// 用户在设置页切换 crash 上传开关。
  Future<void> setCrashReportingEnabled(bool v) async {
    if (_crashReportingEnabled == v) return;
    _crashReportingEnabled = v;
    await _persist();
    notifyListeners();
  }

  /// 用户在设置页切换 analytics 上传开关。
  Future<void> setAnalyticsEnabled(bool v) async {
    if (_analyticsEnabled == v) return;
    _analyticsEnabled = v;
    await _persist();
    notifyListeners();
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    final m = {
      'agreed': _agreed,
      'version': _agreedVersion,
      'agreedAt': _agreedAt?.millisecondsSinceEpoch,
      'crashReporting': _crashReportingEnabled,
      'analytics': _analyticsEnabled,
    };
    await prefs.setString(_kKey, _serialize(m));
  }

  // 极简 JSON：避免引 dart:convert 增加体积，且 keys 全部固定。
  String _serialize(Map<String, Object?> m) =>
      '${m['agreed']}|${m['version'] ?? ''}|${m['agreedAt'] ?? ''}|'
      '${m['crashReporting']}|${m['analytics']}';

  Map<String, Object?> _parse(String raw) {
    final parts = raw.split('|');
    if (parts.length < 5) return {};
    return {
      'agreed': parts[0] == 'true',
      'version': parts[1].isEmpty ? null : parts[1],
      'agreedAt': parts[2].isEmpty ? null : int.tryParse(parts[2]),
      'crashReporting': parts[3] == 'true',
      'analytics': parts[4] == 'true',
    };
  }
}
