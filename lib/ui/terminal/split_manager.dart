// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/foundation.dart';
import '../../ssh/session_manager.dart';

enum SplitMode { off, horizontal, vertical }

class SplitManager extends ChangeNotifier {
  SplitMode _splitMode = SplitMode.off;
  SessionTab? _secondarySession;
  SessionTab? _floatingSession;
  double _splitRatio = 0.5;
  // Floating window size as fraction of screen W/H. Survives close/reopen
  // within a single app session; not persisted to disk.
  double _floatRatioW = 0.52;
  double _floatRatioH = 0.35;

  SplitMode get splitMode => _splitMode;
  SessionTab? get secondarySession => _secondarySession;
  SessionTab? get floatingSession => _floatingSession;
  double get splitRatio => _splitRatio;
  double get floatRatioW => _floatRatioW;
  double get floatRatioH => _floatRatioH;

  void setFloatRatio(double w, double h) {
    final cw = w.clamp(0.30, 0.95);
    final ch = h.clamp(0.20, 0.80);
    if (_floatRatioW == cw && _floatRatioH == ch) return;
    _floatRatioW = cw;
    _floatRatioH = ch;
    notifyListeners();
  }

  void setSplitMode(SplitMode mode) {
    if (_splitMode == mode) return;
    _splitMode = mode;
    notifyListeners();
  }

  void setSecondary(SessionTab tab, {SessionTab? primary}) {
    if (primary != null && tab.id == primary.id) {
      throw ArgumentError('Cannot use primary session as secondary');
    }
    if (_floatingSession != null && tab.id == _floatingSession!.id) {
      throw ArgumentError('Session is already used as floating window');
    }
    if (_secondarySession?.id == tab.id) return; // already set, no-op
    _secondarySession = tab;
    notifyListeners();
  }

  void setFloating(SessionTab tab, {SessionTab? primary}) {
    if (primary != null && tab.id == primary.id) {
      throw ArgumentError('Cannot use primary session as floating');
    }
    if (_secondarySession != null && tab.id == _secondarySession!.id) {
      throw ArgumentError('Session is already used as secondary pane');
    }
    if (_floatingSession?.id == tab.id) return; // already set, no-op
    _floatingSession = tab;
    notifyListeners();
  }

  void clearSplit() {
    _splitMode = SplitMode.off;
    _secondarySession = null;
    notifyListeners();
  }

  void clearFloating() {
    _floatingSession = null;
    notifyListeners();
  }

  void setSplitRatio(double ratio) {
    final clamped = ratio.clamp(0.25, 0.75);
    if (_splitRatio == clamped) return;
    _splitRatio = clamped;
    notifyListeners();
  }

  void onTabClosed(SessionTab tab) {
    bool changed = false;
    if (_secondarySession?.id == tab.id) {
      _secondarySession = null;
      _splitMode = SplitMode.off;
      changed = true;
    }
    if (_floatingSession?.id == tab.id) {
      _floatingSession = null;
      changed = true;
    }
    if (changed) notifyListeners();
  }

  /// Swap primary and secondary panes.
  /// [currentPrimary] becomes the new secondary; [_secondarySession] becomes
  /// the new active tab (caller is responsible for updating SessionManager).
  /// Returns the old secondary so the caller can call mgr.setActiveTab().
  SessionTab? swapPanes(SessionTab currentPrimary) {
    final oldSecondary = _secondarySession;
    if (oldSecondary == null) return null;
    _secondarySession = currentPrimary;
    notifyListeners();
    return oldSecondary;
  }

  bool isAvailableForSplit(SessionTab tab, {required SessionTab primary}) {
    if (tab.id == primary.id) return false;
    if (_floatingSession != null && tab.id == _floatingSession!.id) return false;
    return true;
  }

  bool isAvailableForFloat(SessionTab tab, {required SessionTab primary}) {
    if (tab.id == primary.id) return false;
    if (_secondarySession != null && tab.id == _secondarySession!.id) return false;
    return true;
  }

  /// 当前用户视野内所有可见 tab 的 id 集合：activeTab（若有）+ 分屏副屏
  /// （仅当 splitMode 非 off 时——off 状态下副屏引用可能残留但屏幕上不可见）
  /// + 悬浮窗（悬浮窗是否可见与 splitMode 无关，独立字段）。
  ///
  /// 供 NotifyDedup.shouldSuppressSystemNotification 的 visibleTabIds 参数
  /// 使用：用户正看着分屏副屏或悬浮窗里的内容时，即便它不是 activeTab，也
  /// 不该再弹一次系统通知打断他。
  Set<String> visibleTabIds(String? activeTabId) {
    final ids = <String>{};
    if (activeTabId != null) ids.add(activeTabId);
    if (_splitMode != SplitMode.off && _secondarySession != null) {
      ids.add(_secondarySession!.id);
    }
    if (_floatingSession != null) ids.add(_floatingSession!.id);
    return ids;
  }
}
