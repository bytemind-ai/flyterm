// SPDX-License-Identifier: GPL-3.0-or-later
/// 通知点击后的 deep-link 判定——纯函数，方便 device-free 测试。
///
/// 两层判定分别对应 10.3 的两个子问题：
///   1. 服务端推来的 `NotifyPayload.tabId` 是协议层的 `u32`（对应
///      `AqtTransport.lastTabId`，即 flyterm-server 侧的 pty tab 编号），
///      不是 App 内 `SessionTab.id`（客户端生成的 String）。收到通知时必须
///      先把协议层 tabId 解析回 App 内的 tab —— [resolveTargetTabId]。
///   2. 解析出目标 tab 后，究竟要不要 `SessionManager.setActiveTab` /
///      要不要新开一个 `TerminalScreen` 路由——[decideAction]。
library;

/// 参与 tabId 解析的候选 tab 快照（从 `SessionManager.tabs` 投影而来）。
class TabCandidate {
  final String tabId;
  final String serverId;

  /// 该 tab 底层 AqtTransport 的协议层 tab 编号；非 QUIC 传输（SSH/Mosh）
  /// 或尚未拿到编号时为 null。
  final int? protocolTabId;

  const TabCandidate({
    required this.tabId,
    required this.serverId,
    this.protocolTabId,
  });
}

/// [NotifyDeepLink.decideAction] 的判定结果，交给调用方（widget 层）执行
/// 对应的副作用——本类自身不触碰 SessionManager / SplitManager / Navigator。
enum NotifyDeepLinkAction {
  /// 目标 tab 已经在用户视野内（活跃 tab、分屏副屏或悬浮窗）——不要调用
  /// `setActiveTab`，不要动 SplitManager 的任何分配，只需确保
  /// `TerminalScreen` 在屏幕上（若当前不在，push 一个 restore-mode 的）。
  /// 这是"只 activate、不重排"里"重排"这一半的核心保护：目标已可见时，
  /// 切一次 activeTab 反而可能把它挤进 primary 位置、打乱用户已经摆好
  /// 的分屏/悬浮布局。
  alreadyVisible,

  /// 目标 tab 存在，但当前不在用户视野内——调用 `setActiveTab` 把它带到
  /// 前台（primary 位），再确保 `TerminalScreen` 在屏幕上。
  promoteToActive,

  /// 目标 tab 已经不存在了（用户在通知到达和点击之间关闭了它）。已知限制：
  /// 不会新建 tab，也不会退回到该服务器的其它 tab——用户点了一条已失效的
  /// 通知，静默无操作好过跳到一个非预期的 tab。
  tabNotFound,
}

class NotifyDeepLink {
  /// 把服务端 `NotifyPayload.tabId`（协议层 int，可能为 null）解析成 App
  /// 内的 `SessionTab.id`（String）。
  ///
  /// 解析优先级：
  ///  1. [protocolTabId] 非 null，且能在这台服务器的候选里精确匹配某个
  ///     `protocolTabId` → 返回那个 tab。
  ///  2. 否则退化为这台服务器"最近"的一个 tab——用 [candidates] 里最后一个
  ///     匹配该服务器的条目近似（`SessionManager.tabs` 目前没有真正的
  ///     "最后活跃时间戳"，这是已知的不精确 fallback，不是"最近打开"或
  ///     "最后使用"的精确定义，只是一个合理的近似）。
  ///  3. 这台服务器当前一个 tab 都没有（已被全部关闭）→ 返回 null。
  static String? resolveTargetTabId({
    required List<TabCandidate> candidates,
    required String serverId,
    required int? protocolTabId,
  }) {
    final forServer =
        candidates.where((c) => c.serverId == serverId).toList();
    if (forServer.isEmpty) return null;
    if (protocolTabId != null) {
      for (final c in forServer) {
        if (c.protocolTabId == protocolTabId) return c.tabId;
      }
    }
    return forServer.last.tabId;
  }

  /// 决定点击通知后该做什么。见 [NotifyDeepLinkAction] 各分支的注释。
  ///
  /// [targetTabExists] — 目标 tab 此刻是否仍存在于 `SessionManager.tabs`
  /// 中（点击时重新查一次，而不是复用通知到达时刻的判定——两者之间用户可能
  /// 已经关闭了这个 tab）。
  /// [visibleTabIds] — 点击这一刻的可见 tab 集合（activeTab + 分屏副屏 +
  /// 悬浮窗），与 `NotifyDedup.shouldSuppressSystemNotification` 用的是
  /// 同一个概念、同一处 SplitManager 计算逻辑。
  static NotifyDeepLinkAction decideAction({
    required String targetTabId,
    required bool targetTabExists,
    required Set<String> visibleTabIds,
  }) {
    if (!targetTabExists) return NotifyDeepLinkAction.tabNotFound;
    if (visibleTabIds.contains(targetTabId)) {
      return NotifyDeepLinkAction.alreadyVisible;
    }
    return NotifyDeepLinkAction.promoteToActive;
  }
}
