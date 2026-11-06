// SPDX-License-Identifier: GPL-3.0-or-later
/// 通知去重与前台抑制的纯判定逻辑。
///
/// 抽成纯函数是为了 device-free 锁定 —— 参照 `ReconnectService.seedServerRingOff`
/// 和 `ReconnectService.decideResumeRetry` 的既有做法。
///
/// ## 前提：`seen` 必须按 session 作用域维护
///
/// 服务端的 event_id 序号绑定在 `session_token` 上：进程重启会让 `next_id` 连同
/// `session_token` 一起归零（见 `rust/flyterm-server/src/notify/queue.rs`）。客户端
/// 据此走冷启动 HELLO 还是断线 RESUME，只有握手层知道——`NotifyDedup` 本身是无状态
/// 纯函数，看不到这个信息。
///
/// **调用方必须保证**：一旦握手层检测到走的是新 HELLO（而非 RESUME，即
/// `session_token` 变化），必须先清空持久化的 `seen` 再继续调用本类的方法。
///
/// 不这样做的后果：新一代服务器从 event_id=1 重新计数，如果旧一代的 `seen` 里
/// 恰好还留着旧的 `1`（例如用户此前总共只收到过几十条通知，窗口 200 远未触发
/// 淘汰），`shouldShow(seen, 1)` 会对这条全新通知返回 `false`，导致它被**永久
/// 静默丢弃**——服务端并不知道客户端吞掉了它，不会重发。这正好把整个协议的核心
/// 取舍（宁可重复投递，不可静默丢失）在客户端这一层反了过来。
class NotifyDedup {
  /// 记住多少个已展示的 event_id。
  ///
  /// 必须远大于服务端队列上限（50），否则窗口外的事件会在重连补投时被当成
  /// 新事件重复弹出。
  static const int kWindow = 200;

  /// 这条事件是否该展示。已在 [seen] 里的一律丢弃。
  ///
  /// 去重是必需项不是优化项：服务端的 last_acked 只在真正收到 NotifyAck 时
  /// 才推进（宁可重复投递也不能静默丢失），所以重连补投必然会重发未 ack 的
  /// 事件。QUIC 重连在本 app 里是高频事件，不去重则每次网络抖动都重放一批
  /// 旧通知。
  static bool shouldShow(List<int> seen, int eventId) => !seen.contains(eventId);

  /// 记下一个已展示的 event_id，返回新的窗口内容（**不修改入参**）。
  ///
  /// 窗口收敛统一放在末尾执行，对"追加新 id"和"命中重复 id"两条分支都生效——
  /// 这样即便外部传入的 `seen` 本身已经超长（例如 `kWindow` 被调小、或持久化
  /// 数据迁移遗留的历史包袱），命中重复分支时也会被立即收敛，而不用等到下一次
  /// 非重复 id 才自愈。
  static List<int> remember(List<int> seen, int eventId) {
    final out = seen.contains(eventId)
        ? List<int>.from(seen)
        : (List<int>.from(seen)..add(eventId));
    if (out.length > kWindow) {
      out.removeRange(0, out.length - kWindow);
    }
    return out;
  }

  /// 是否该抑制系统通知，改用应用内提示。
  ///
  /// 只在"用户正看得见这条通知来源的那个 tab"时抑制。你正看着屏幕它还给你推
  /// 锁屏通知，是最容易招致用户关闭通知的行为。
  ///
  /// [visibleTabIds] 是当前用户视野内所有可见 tab 的集合，不只是"当前活跃
  /// tab"——分屏副屏和悬浮窗里的 tab 同样在用户眼皮底下，即便它们不是
  /// SessionManager 意义上的 activeTab。调用方（widget 层）负责把
  /// activeTabId、SplitManager.secondarySession、floatingSession 的 id
  /// 合并成这个集合；本类只做纯粹的集合判定。
  ///
  /// [targetTabId] 为 null 表示来源未知（tmux pane 继承了过期的 FLYTERM_TAB_ID）
  /// —— 此时不抑制，宁可多弹一次也不要因为无法判断就吞掉。
  ///
  /// 这个场景已经被类型系统排除，不需要显式 `!= null` 守卫：[visibleTabIds]
  /// 是 `Set<String>`，在 Dart 健全空安全下不可能包含 `null` 元素，
  /// `visibleTabIds.contains(null)` 在类型层面就无法通过编译（`contains` 接受
  /// `Object?` 但集合本身的元素类型是 `String`，不存在的元素恒不命中），
  /// `targetTabId == null` 时结果恒为 `false`，与保留显式守卫完全等价。之前
  /// 这里留了一条 `targetTabId != null &&` 守卫并声称"必须保留、必须持续测
  /// 到"——那是错的：变异测试删掉守卫后全部用例仍然通过（含专门为它写的
  /// 双未知用例），说明它从未真正生效过。保留一条不产生任何行为差异的"护栏"
  /// 比没有护栏更糟：它会让人误以为这里有一层额外覆盖。
  static bool shouldSuppressSystemNotification({
    required bool appInForeground,
    required Set<String> visibleTabIds,
    required String? targetTabId,
  }) =>
      appInForeground && visibleTabIds.contains(targetTabId);
}
