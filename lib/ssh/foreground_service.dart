// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import 'keep_alive_controller.dart';

@pragma('vm:entry-point')
void _taskCallback() {
  FlutterForegroundTask.setTaskHandler(_KeepAliveHandler());
}

class _KeepAliveHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {}
}

class SshForegroundService {
  static bool _initialized = false;

  /// 用户是否允许后台保活。**默认 false** —— 前台服务通知在 Android 上
  /// 无法隐藏，装上就挂一条常驻通知是不可接受的默认行为。开关在设置页，
  /// 由 main.dart 监听 TerminalSettings 同步进来。
  static bool _enabled = false;

  /// 关闭时立即停掉已在运行的服务 —— 否则关了开关通知还挂着。
  /// 幂等：值没变就什么都不做（main.dart 挂的是 TerminalSettings 的通用
  /// listener，任何设置变动都会触发它）。
  static Future<void> setEnabled(bool v) async {
    if (v == _enabled) return;
    _enabled = v;
    if (!v) await stop();
  }

  static bool get enabled => _enabled;

  static void init() {
    if (_initialized) return;
    _initialized = true;
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        // channelId 从 flyterm_ssh 换成 _v2：Android 对已存在的频道只更新
        // name/description，importance 改动被系统忽略（官方原文 "Once you
        // submit the channel to the NotificationManager, you can't change
        // the importance level"）。不换 ID 的话老用户升级后横条原样保留，
        // 而我们会以为修好了。代价是旧频道作为孤儿残留在系统设置列表里 ——
        // 可接受，删除频道 API 会连带丢掉用户此前的自定义设置。
        channelId: 'flyterm_ssh_v2',
        channelName: '后台连接保活',
        channelDescription: '保持终端会话在后台持续活跃',
        // MIN 而非 LOW：官方重要性表里 IMPORTANCE_MIN 是 "Makes no sound
        // and doesn't appear in the status bar"，LOW 只是静音、状态栏图标
        // 仍在。前台服务通知无法完全隐藏（Android 8.0+ 强制显示），MIN 是
        // 合法档位里最低的 —— NONE 会连通知抽屉都不显示，对前台服务是未定
        // 义行为，可能导致服务启动异常。
        channelImportance: NotificationChannelImportance.MIN,
        priority: NotificationPriority.MIN,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: false,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
        autoRunOnBoot: false,
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );
  }

  /// 启动或更新通知。已运行时只更新文字，否则启动服务。
  static Future<void> startOrUpdate(String serverName) async {
    if (!_enabled) return;
    if (await FlutterForegroundTask.isRunningService) {
      await FlutterForegroundTask.updateService(
        notificationTitle: '后台保活中',
        notificationText: serverName,
      );
    } else {
      await FlutterForegroundTask.startService(
        notificationTitle: '后台保活中',
        notificationText: serverName,
        callback: _taskCallback,
      );
    }
  }

  static Future<void> stop() async {
    if (await FlutterForegroundTask.isRunningService) {
      await FlutterForegroundTask.stopService();
    }
  }
}

/// [KeepAliveServicePort] 的生产实现 —— 纯转发给上面的静态方法。
///
/// 为什么要这一层：静态成员在 Dart 里**无法** implements 一个带实例成员的
///接口（会撞名）。包一层实例适配器是最小代价，换来的好处是
///[KeepAliveController] 能在测试里注入假实现，从而锁住「开关到服务的接线
///真的存在」——那正是它之前断掉的地方。
class SshForegroundServicePort implements KeepAliveServicePort {
  const SshForegroundServicePort();

  @override
  bool get enabled => SshForegroundService.enabled;

  @override
  Future<void> setEnabled(bool v) => SshForegroundService.setEnabled(v);

  @override
  Future<void> startOrUpdate(String serverName) =>
      SshForegroundService.startOrUpdate(serverName);
}
