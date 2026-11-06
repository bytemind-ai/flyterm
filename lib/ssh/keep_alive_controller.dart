// SPDX-License-Identifier: GPL-3.0-or-later
/// 「后台保活」设置 → 前台服务的**接线**。
///
/// ## 为什么需要这一层
///
/// 设置页里「后台保活」曾经是个**摆设**：开关能拨、值能存进 `SharedPreferences`、
/// 重启还能记住，但**没有任何消费者**。`main.dart` 里有一段显式说明不再把
/// `TerminalSettings.backgroundKeepAlive` 同步进 `SshForegroundService`（有意
/// 休眠）。而 `SshForegroundService._enabled` 默认 `false`、`startOrUpdate()`
/// 开头就是 `if (!_enabled) return;` —— 于是 `terminal_screen` 与
/// `reconnect_service` 里那几个调用点全部静默变成 no-op。
///
/// 后果不是「通知栏多一条或少一条」：后台前台服务是「app 切后台后 QUIC 连接
/// 还活着」的唯一依靠，也就是锁屏通知能收到的前提。开关关着而用户以为开着，
/// 等于通知功能整体不可用。
///
/// 这层把同步逻辑从 `main.dart` 的装配代码里抽出来，变成可注入、可测的单元。
/// 用的是[端口]而不是直接调静态 `SshForegroundService`：静态调用只能在真机上
/// 验证，而「它到底有没有被调用」才是这里要锁的东西。
library;

/// [KeepAliveController] 依赖的服务端口。生产实现是 `SshForegroundService`；
/// 测试注入假实现，锁的是「调用有没有发生」而不是 Android 侧的真实效果。
abstract class KeepAliveServicePort {
  /// 用户是否允许后台保活。设为 false 时实现**必须**停掉已在运行的服务 ——
  /// 否则关了开关通知还挂着。
  bool get enabled;
  Future<void> setEnabled(bool v);

  /// 起服务 / 更新服务通知上的服务器名。
  Future<void> startOrUpdate(String serverName);
}

/// 把「后台保活」的设置值同步进前台服务，并在会话变化时更新服务通知。
///
/// ## 幂等
///
/// 调用方（`main.dart`）挂的是 `TerminalSettings` 的**通用** listener ——
/// 任何设置变动都会触发它。所以 [apply] 必须对「值没变」的情况完全 no-op，
/// 否则用户每次改字体大小都会重启一次前台服务。
class KeepAliveController {
  final KeepAliveServicePort service;

  /// 当前生效的值。null = 还没同步过（首次 [apply] 一定会下发）。
  bool? _current;

  /// 「当前有没有一个值得保活的会话」——返回服务器名，没有则 null。
  ///
  /// 做成回调而不是直接读 `SessionManager`：这样控制器不认识 session 模型，
  /// 装配层决定「什么算活跃会话」。默认返回 null（没有会话）。
  String? Function() _sessionStarter = () => null;

  KeepAliveController({required this.service});

  bool get enabled => _current ?? false;

  /// 装配层注入「取当前活跃服务器名」的读法。
  void setSessionStarter(String? Function() starter) {
    _sessionStarter = starter;
  }

  /// 同步设置值。幂等：值没变则完全不碰服务。
  ///
  /// 打开时若已有活跃会话，会**立即**起服务而不是等下一次连接 —— 用户在一段
  /// 已连上的会话里打开开关，期望的是立刻生效。
  Future<void> apply({required bool keepAlive}) async {
    if (_current == keepAlive) return;
    _current = keepAlive;
    await service.setEnabled(keepAlive);
    if (keepAlive) {
      final name = _sessionStarter();
      if (name != null) {
        await service.startOrUpdate(name);
      }
    }
  }
}
