// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:clock/clock.dart';
import 'package:flutter/widgets.dart';

/// 全局单例：跟踪用户是否"活跃"（前台 + 30s 内有输入）。
/// 被 SSH/mosh 用来决定 keepalive / watchdog 间隔。
class ActivityTracker extends ChangeNotifier with WidgetsBindingObserver {
  static const _kInputWindow = Duration(seconds: 30);

  static ActivityTracker? _instance;
  static ActivityTracker get instance {
    if (_instance == null) {
      _instance = ActivityTracker._();
      WidgetsBinding.instance.addObserver(_instance!);
    }
    return _instance!;
  }

  @visibleForTesting
  static ActivityTracker testInstance() => ActivityTracker._();

  ActivityTracker._();

  DateTime? _lastInputAt;
  bool _foreground = true;

  bool get active {
    if (!_foreground) return false;
    final last = _lastInputAt;
    if (last == null) return false;
    return clock.now().difference(last) <= _kInputWindow;
  }

  void recordInput() {
    _lastInputAt = clock.now();
    notifyListeners();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final fg = state == AppLifecycleState.resumed;
    if (fg != _foreground) {
      _foreground = fg;
      notifyListeners();
    }
  }
}
