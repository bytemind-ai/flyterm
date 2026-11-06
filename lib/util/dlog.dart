// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/foundation.dart' show kDebugMode, debugPrint;

/// 带守卫的调试日志。
///
/// 直接调 `debugPrint` 的问题在于它在 release 里照样执行 —— Flutter 只在
/// profile 模式下把它换成 no-op，release APK 里这些日志会原样进 logcat。
/// 全仓 150 处日志里有 SFTP 路径、服务器地址、RESUME 元数据，既是噪音也
/// 不该出现在用户设备的日志缓冲区里。
///
/// `kDebugMode` 是编译期常量，release 构建时整个调用会被 tree-shake 掉，
/// 连字符串插值的代价都不产生。
///
/// ```dart
/// dlog('RACE', 'RESUME stalled >3s → launching bootstrap backup');
/// // debug:   [RACE] RESUME stalled >3s → launching bootstrap backup
/// // release: 不执行
/// ```
void dlog(String tag, String msg) {
  if (kDebugMode) debugPrint('[$tag] $msg');
}
