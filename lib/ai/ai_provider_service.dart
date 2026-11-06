// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'ai_provider.dart';

class AIProviderService extends ChangeNotifier {
  /// 目前没有任何持久化字段用到 prefs（原先唯一的 `completionEnabled`
  /// 已随设置页那个重复的补全开关一起删除），但构造签名保留 —— 调用点有
  /// 近 20 处，且这里迟早还要存 provider 级的偏好。
  AIProviderService(SharedPreferences prefs);

  AIProvider? _provider;

  bool get hasProvider => _provider != null;
  AIProvider? get provider => _provider;

  void setProvider(AIProvider provider) {
    _provider = provider;
    notifyListeners();
  }

  void clearProvider() {
    _provider = null;
    notifyListeners();
  }

  /// 清掉当前 provider 的「不支持视觉」判定并通知 UI 重建。
  ///
  /// 两步必须在一起：光调 `resetVisionSupport()` 不会让附件按钮变亮 ——
  /// 那个按钮的可用性读的是 `context.watch<AIProviderService?>()`，而
  /// `supportsVision` 是 provider 内部的可变字段，改它不触发任何通知。
  ///
  /// 没有 provider 时是 no-op：调用方（附件按钮）在那种情况下本来也不该
  /// 提供「再试一次」。
  void retryVision() {
    final p = _provider;
    if (p == null) return;
    p.resetVisionSupport();
    notifyListeners();
  }
}
