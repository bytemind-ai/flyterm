// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';

import 'notification_permission.dart';

export 'notification_permission.dart' show NotificationPermissionState;

/// 独立于 `flutter_foreground_task` 的一次性系统通知封装。
///
/// `flutter_foreground_task`（见 `foreground_service.dart`）只支持一个
/// 常驻的前台服务通知，且现有 `flyterm_ssh_v2` 频道刻意配成 MIN/静音——用来在
/// 后台保活 SSH 连接，不能借用来展示"有新事件"这种需要震动/响铃、用户能
/// 感知到的推送。事件通知语义完全不同（一次性、HIGH），需要一个独立频道
/// 和一个能展示任意多条、互不覆盖的通知的库，因此引入
/// `flutter_local_notifications` 这个新依赖。
///
/// 频道 `flyterm_events`：HIGH importance（区别于 `flyterm_ssh` 的 LOW）。
class NotificationService {
  static const _channelId = 'flyterm_events';
  static const _channelName = '任务通知';
  static const _channelDescription = '远程服务器上 flyterm notify 推送的任务完成等通知';

  /// Android 通知分组键。
  ///
  /// ## 为什么需要分组
  ///
  /// 没有它时，同一台机器上连着干活（`make && flyterm notify`、几轮 agent 完成
  /// 通知…）会在通知栏里堆出一排**互不相关的独立条目**，每条各占一行、各自
  /// 响铃。/`docs/agent-notifications.md` 把「短时间多条通知刷屏」列为一个待
  /// 优化项。
  ///
  /// Android 的通知分组把同 groupKey 的通知折成一条 summary + 子项：折叠时
  /// 只占一行，展开才逐条列出。这正是「同一个来源的一批事件」应有的形态。
  ///
  /// 用**单一固定组**而不是按服务器分组的理由：通知栏在这个 app 里本来只服务
  /// 于「远端任务/审批」这一件事，用户的心智是「FlyTerm 有事找我」而不是
  /// 「哪台机器有事找我」——按服务器拆成多组反而让通知栏出现好几个折叠头，
  /// 比不分组更乱。真需要区分时，副标题里的服务器名已经写了。
  static const _groupKey = 'flyterm_events_group';

  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  static bool _initialized = false;

  /// 通知被点击时回调，payload 是 [show] 传入的 [tabId]（可能为 null）。
  /// 由调用方（notify_orchestrator）在 [init] 之后赋值。
  static void Function(String? tabId)? onTap;

  static Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosSettings = DarwinInitializationSettings();
    await _plugin.initialize(
      const InitializationSettings(android: androidSettings, iOS: iosSettings),
      onDidReceiveNotificationResponse: (response) {
        onTap?.call(response.payload);
      },
    );
    const channel = AndroidNotificationChannel(
      _channelId,
      _channelName,
      description: _channelDescription,
      importance: Importance.high,
    );
    await _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(channel);
  }

  /// 展示一条事件通知。[eventId] 同时用作通知 id（同一 eventId 再次展示会
  /// 覆盖旧的，这是期望行为——理论上每个 eventId 只会成功展示一次，因为
  /// 上层在展示成功之后才会 ack 并写入去重窗口）。
  ///
  /// [text] 是通知标题（消息原文），[subtitle] 是副标题（服务器名 · tab 名 ·
  /// 绝对时间，见 `notify_format.dart`）。[tabId] 作为 payload 透传给点击
  /// 回调，用于 deep link。
  ///
  /// 返回 `true` 仅当有理由相信通知真的会被用户看到；`false` 表示确定不行
  /// （见 [_canDisplay]）。调用方**必须**据此决定是否 ack/remember——
  /// Android 的 `notify()` 在权限缺失或频道被禁用时不会抛异常，只是静默不
  /// 显示，`show()` 本身不抛异常 ≠ 用户真的看到了。
  static Future<bool> show({
    required int eventId,
    required String text,
    required String subtitle,
    String? tabId,
  }) async {
    if (!_initialized) {
      // 防御性兜底：正常路径下 main() 会在 runApp 前调用 init()。若真的漏了，
      // 宁可现场补初始化也不要让通知静默丢失。
      await init();
    }
    if (!await _canDisplay()) {
      return false;
    }
    await _plugin.show(
      // Android 通知 id 是 32-bit int；eventId 理论上单调递增且受
      // NotifyDedup.kWindow 约束不会无限增长，但仍做一次防溢出裁剪。
      eventId & 0x7fffffff,
      text,
      subtitle,
      androidDetailsForTesting,
      payload: tabId,
    );
    return true;
  }

  /// 展示用的平台细节。抽成静态常量而不是内联在 [show] 里，是为了让
  /// 「分组配置真的挂上了」这条能在 device-free 测试里断言 —— 光有
  /// [_groupKey] 常量不等于 [show] 用它，那种「写了但没接线」的差异只能
  /// 靠这个入口守住。
  @visibleForTesting
  static NotificationDetails get androidDetailsForTesting {
    const androidDetails = AndroidNotificationDetails(
      _channelId,
      _channelName,
      channelDescription: _channelDescription,
      importance: Importance.high,
      priority: Priority.high,
      // 同一来源的一批事件折成一组（见 [_groupKey]）。`alertBehavior: all`
      // 让每条子项到达时都提醒——分组是为了**整理通知栏**，不是为了静音；
      // 把后来的那几条悄悄降级会让「高频通知」从刷屏变成漏看。
      groupKey: _groupKey,
      groupAlertBehavior: GroupAlertBehavior.all,
    );
    return const NotificationDetails(
      android: androidDetails,
      iOS: DarwinNotificationDetails(),
    );
  }

  /// 展示前预检：这条通知是否真的有可能被用户看到。
  ///
  /// `FlutterLocalNotificationsPlugin.show()`/Android 原生 `notify()` 中间
  /// 没有任何权限/频道检查——直接调 `notificationManagerCompat.notify(...)`。
  /// Android 13+ 用户拒绝 `POST_NOTIFICATIONS`、或事后在系统设置里把
  /// [_channelId] 整个频道关掉，`notify()` 都不抛异常，只是静默不显示。若
  /// 调用方把"没抛异常"当成"已展示"，就会 ack + 写入去重窗口，这条通知从此
  /// 永久消失、再也不会重试。
  ///
  /// 两层检查，任意一层明确说"不行"就返回 false：
  ///   1. `areNotificationsEnabled()` —— app 级别开关（含运行时权限被拒）。
  ///   2. [_channelId] 频道自身的 importance —— 用户可能只关掉这一个频道
  ///      而不动 app 级别开关；`Importance.none` 即该频道被禁用。
  /// 拿不到明确信号时（iOS 无此 API、旧版 Android、方法调用本身失败）一律
  /// 当作"可能可以"处理，避免预检出错反而误杀真实展示。
  static Future<bool> _canDisplay() async {
    try {
      final android = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      if (android == null) return true; // 非 Android（iOS）：无此预检 API。
      final enabled = await android.areNotificationsEnabled();
      if (enabled == false) return false;

      final channels = await android.getNotificationChannels();
      if (channels != null) {
        for (final c in channels) {
          if (c.id == _channelId) {
            return c.importance != Importance.none;
          }
        }
      }
    } catch (_) {
      // 预检本身失败——当作"可能可以"处理，不要因为查询出错就放弃展示。
    }
    return true;
  }

  /// Requests the Android 13+ POST_NOTIFICATIONS runtime permission (no-op
  /// on older Android / iOS, where it's handled by [init]'s
  /// `DarwinInitializationSettings` request flags or the manifest declaration
  /// alone). Fire-and-forget from `main.dart` — if denied, the feature
  /// degrades gracefully: in-app SnackBar suppression still works while the
  /// app is foreground, only the background system notification is lost.
  static Future<bool?> requestPermission() async {
    try {
      final android = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      if (android == null) return null;
      return await android.requestNotificationsPermission();
    } catch (_) {
      // 插件平台未注册（见 [permissionState] 同处理）——返回 null 而不是让
      // 首帧路径上的 fire-and-forget 调用抱异常。
      return null;
    }
  }

  /// 查询当前通知权限落点，供设置页显示真实状态。
  ///
  /// 与 [_canDisplay] 查的是同一套平台 API，但目的相反：那边是「展示前判断
  /// 能不能弹」，这里是「把结果告诉用户」。归约逻辑抽在
  /// [resolveNotificationPermission]（纯函数，device-free 可测），本方法只
  /// 负责把平台返回值喂进去。
  ///
  /// 任何一处查询失败都降级为「拿不到这个维度的信号」，而不是当成被拒 ——
  /// 误报「被拒」会引导用户去翻一个根本不需要动的系统设置。
  static Future<NotificationPermissionState> permissionState() async {
    // `resolvePlatformSpecificImplementation` 在插件平台未注册时会抛
    // `LateInitializationError`（`FlutterLocalNotificationsPlatform.instance`
    // 尚未初始化）——测试宿主、或 `init()` 尚未跑到的极早期都会碰到。这里
    // 如实报「未知」，而不是让一个查询权限的调用把调用方搞崩。
    AndroidFlutterLocalNotificationsPlugin? android;
    try {
      android = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
    } catch (_) {
      android = null;
    }
    if (android == null) {
      // 非 Android：没有这套预检 API，如实报「未知」而非「正常」——
      // 后者会让设置页对一个我们根本没验证过的平台说「已授权」。
      return resolveNotificationPermission(
          appLevelEnabled: null, channelImportanceNone: null);
    }

    bool? appLevelEnabled;
    try {
      appLevelEnabled = await android.areNotificationsEnabled();
    } catch (_) {
      appLevelEnabled = null;
    }

    bool? channelImportanceNone;
    try {
      final channels = await android.getNotificationChannels();
      if (channels != null) {
        for (final c in channels) {
          if (c.id == _channelId) {
            channelImportanceNone = c.importance == Importance.none;
            break;
          }
        }
      }
    } catch (_) {
      channelImportanceNone = null;
    }

    return resolveNotificationPermission(
      appLevelEnabled: appLevelEnabled,
      channelImportanceNone: channelImportanceNone,
    );
  }

  /// 跳到系统的本 app 通知设置页。用户拒过权限后，app 内再调
  /// `requestPermission()` 在多数 Android 版本上不会再弹系统对话框，此时唯一
  /// 的出路就是引导用户自己去设置里打开 —— 没有这个跳转，设置页上的
  /// 「去设置」就只是一句空话。
  static Future<bool> openSystemSettings() => openAppSettings();

  @visibleForTesting
  static void resetForTesting() {
    _initialized = false;
    onTap = null;
  }

  @visibleForTesting
  static String get channelIdForTesting => _channelId;

  /// 通知分组键（见 [_groupKey] 的文档）。测试用——生产代码不读它。
  @visibleForTesting
  static String get groupKeyForTesting => _groupKey;
}
