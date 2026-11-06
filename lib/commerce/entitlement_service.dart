// SPDX-License-Identifier: GPL-3.0-or-later
// lib/commerce/entitlement_service.dart
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'feature_flags.dart';

/// Pro entitlement 三态状态。
/// - unknown: 启动初始，尚未 load
/// - free: 无 Pro 票据
/// - pro: 持有 flyterm_pro_lifetime 票据
enum EntitlementStatus { unknown, free, pro }

/// Pro 状态唯一来源单例。
///
/// 启动流程：
///   1. main() 调 EntitlementService.instance.load() 读 SharedPreferences 缓存
///   2. PurchaseService.init() 调 restorePurchases() 跟商店核对真实票据
///   3. 票据回调时调 markPro() / markFree() 更新状态 + notify listeners
///
/// 缓存设计：
///   - SharedPreferences 'entitlement.v1' = "status|purchasedAtMs"
///   - 启动用缓存值快速渲染，但商店真实票据是权威源
class EntitlementService extends ChangeNotifier {
  static final EntitlementService instance = EntitlementService._internal();

  EntitlementService() : this._internal();

  EntitlementService._internal();

  static const _kKey = 'entitlement.v1';

  EntitlementStatus _status = EntitlementStatus.unknown;
  DateTime? _purchasedAt;
  bool _loaded = false;

  EntitlementStatus get status => _status;
  bool get isPro => _status == EntitlementStatus.pro;
  DateTime? get purchasedAt => _purchasedAt;
  bool get loaded => _loaded;

  /// 启动时调用。从本地缓存恢复状态（快速 UI 渲染）。
  /// PurchaseService.init() 之后会用商店票据 override。
  Future<void> load() async {
    if (!kEnableInAppPurchase) {
      // 开源构建：跳过缓存读取，直接进 pro 态。
      _status = EntitlementStatus.pro;
      _purchasedAt = DateTime(2026, 1, 1);
      _loaded = true;
      notifyListeners();
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kKey);
    if (raw != null) {
      final parts = raw.split('|');
      if (parts.length >= 2) {
        _status = parts[0] == 'pro'
            ? EntitlementStatus.pro
            : EntitlementStatus.free;
        final ts = int.tryParse(parts[1]);
        _purchasedAt =
            ts != null ? DateTime.fromMillisecondsSinceEpoch(ts) : null;
      } else {
        _status = EntitlementStatus.free;
      }
    } else {
      _status = EntitlementStatus.free;
    }
    _loaded = true;
  }

  /// PurchaseService 收到 purchased / restored 时调用。
  Future<void> markPro(DateTime purchasedAt) async {
    if (_status == EntitlementStatus.pro &&
        _purchasedAt?.millisecondsSinceEpoch ==
            purchasedAt.millisecondsSinceEpoch) {
      return;
    }
    _status = EntitlementStatus.pro;
    _purchasedAt = purchasedAt;
    await _persist();
    notifyListeners();
  }

  /// PurchaseService 检测到票据失效 / 退款时调用。
  Future<void> markFree() async {
    if (_status == EntitlementStatus.free) return;
    _status = EntitlementStatus.free;
    _purchasedAt = null;
    await _persist();
    notifyListeners();
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = _status == EntitlementStatus.pro
        ? 'pro|${_purchasedAt?.millisecondsSinceEpoch ?? 0}'
        : 'free|';
    await prefs.setString(_kKey, raw);
  }
}
