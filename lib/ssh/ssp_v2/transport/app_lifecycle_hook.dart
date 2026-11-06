// SPDX-License-Identifier: GPL-3.0-or-later
// AppLifecycle bridge for the v2 mosh connection.
//
// On Android/iOS the OS aggressively suspends background apps; UDP
// sockets and tick timers may stop firing without notice. When the user
// brings the app back to foreground we need to decide:
//   - short background (<60s): try to keep the session, kick a roam
//   - long background (>=60s): give up, hard reconnect from scratch
//
// 60 s threshold matches mosh's default server-side
// MOSH_NO_TERM_BUFFER timeout window.
import 'package:flutter/widgets.dart';

typedef LifecycleCallback = void Function();

class MoshLifecycleHook with WidgetsBindingObserver {
  final LifecycleCallback onResumedQuick;
  final LifecycleCallback onResumedHardReconnect;
  final Duration hardThreshold;
  final DateTime Function() _now;
  DateTime? _backgroundedAt;

  MoshLifecycleHook({
    required this.onResumedQuick,
    required this.onResumedHardReconnect,
    this.hardThreshold = const Duration(seconds: 60),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  void start() => WidgetsBinding.instance.addObserver(this);
  void stop() => WidgetsBinding.instance.removeObserver(this);

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _backgroundedAt = _now();
    } else if (state == AppLifecycleState.resumed) {
      final bg = _backgroundedAt;
      _backgroundedAt = null;
      if (bg == null) return;
      if (_now().difference(bg) >= hardThreshold) {
        onResumedHardReconnect();
      } else {
        onResumedQuick();
      }
    }
  }
}
