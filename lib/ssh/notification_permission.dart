// SPDX-License-Identifier: GPL-3.0-or-later
/// 通知权限状态的**纯判定** —— 与 `flutter_local_notifications` 解耦，方便
/// device-free 测试。
///
/// ## 为什么需要它
///
/// Android 13+ 用户拒掉 `POST_NOTIFICATIONS`、或事后在系统设置里把
/// `flyterm_events` 频道单独关掉，`notify()` 都**不抛异常**，只是静默不显示。
/// 用户看到的现象是「通知功能没反应」，而 app 里没有任何地方会告诉他真正
/// 的原因是权限 —— 于是他会当成 bug。
///
/// 这条状态把那个静默失败变成可看见的事实：设置页开关旁显示权限状态并能跳
/// 系统设置，否则用户会以为是 bug。
library;

/// 当前通知权限落点。三态而非 bool —— 必须能区分「确实被挡」和「问不出来」。
enum NotificationPermissionState {
  /// 通知可以正常展示。
  granted,

  /// app 级通知开关被关（含 Android 13+ 运行时权限被拒）。这是**唯一**需要
  /// 引导用户去系统设置授权的状态。
  denied,

  /// app 级开着，但 `flyterm_events` 这一个频道被单独关掉。用户能在系统设置
  /// 里只关这一个频道而不动 app 总开关，此时其它 app 的通知照常，功能却静默
  /// 失效 —— 这是最容易被误当成 bug 的一种。
  channelDisabled,

  /// 问不出明确结论（非 Android、旧系统、或查询调用本身失败）。
  ///
  /// **刻意与 [denied] 分开**：误报「被拒」会引导用户去翻一个根本不需要动的
  /// 系统设置，比不提示更糟。
  unknown,
}

/// 由平台查询结果归约出最终状态。
///
/// [appLevelEnabled] 与 [channelImportanceNone] 为 null 表示该维度查询不到
/// （非 Android / 旧系统 / 调用失败）。
///
/// 判定顺序上 [denied] 优先于 [channelDisabled]：两层都关着时，app 级开关是
/// 更外层、更该先处理的那个，先让用户看到它。
NotificationPermissionState resolveNotificationPermission({
  required bool? appLevelEnabled,
  required bool? channelImportanceNone,
}) {
  if (appLevelEnabled == false) return NotificationPermissionState.denied;
  if (channelImportanceNone == true) {
    return NotificationPermissionState.channelDisabled;
  }
  if (appLevelEnabled == true) return NotificationPermissionState.granted;
  return NotificationPermissionState.unknown;
}
