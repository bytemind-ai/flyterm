// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/foundation.dart' show visibleForTesting;

/// 被判定为「半死」的连接登记处 —— agent 与 SFTP 共享的那份状态。
///
/// ## 为什么需要它
///
/// `tab.connection.client` 同时被 agent 的 exec channel 和 SFTP 复用，而
/// `SSHClient.isClosed` 只反映 socket 的 done：切后台或换网之后它仍是
/// false，服务端却已经拒绝新的 session channel（见 `isSshChannelSetupFailure`）。
///
/// 此前 agent 把「这条连接开不出 channel」记在 `AgentExecChannel._blockedReuse`
/// 这个**私有字段**里，SFTP 则只看 `isClosed`。于是会出现：agent 已经判定这
/// 条连接废了、绕开它自建了新连接，SFTP 完全不知道，继续往同一条死连接上开
/// SFTP channel —— 用户看到的就是「空目录」，而且每次打开都空、永不自愈。
///
/// 判据分叉是一回事，**状态不共享是更深的一层**：即便两边判据写得一模一样，
/// 各记各的也仍然会出现「一边已拉黑、另一边照用」。
///
/// ## 为什么收 Object 而不是 SSHClient
///
/// 为了可测 —— 测试里造不出真的 `SSHClient`（它要真连接）。这一层只负责
/// 「记住哪些对象被拉黑过」，`isClosed` 那一半判据留在 `isSshClientDead`
/// 那个便利函数里。
///
/// ## 为什么用 Expando 而不是 Set
///
/// `Expando` 不持有强引用：client 被回收时标记自动消失，不需要任何清理逻辑。
/// 用 `Set` 会让每一条废连接永远留在内存里。
class DeadSshClients {
  DeadSshClients._();

  static final Expando<bool> _marked = Expando<bool>('flyterm.deadSshClient');

  /// 标记这条连接半死：socket 可能还开着，但它开不出新的 session channel。
  static void mark(Object client) {
    _marked[client] = true;
  }

  /// 这条连接被拉黑过吗。
  ///
  /// **这不是完整的健康判据** —— 它不看 `isClosed`。完整判据见
  /// `isSshClientDead`（`ssh_connection.dart`）。
  static bool isMarked(Object client) => _marked[client] ?? false;

  /// 仅供测试：清掉标记。
  @visibleForTesting
  static void clearForTest(Object client) {
    _marked[client] = null;
  }
}
