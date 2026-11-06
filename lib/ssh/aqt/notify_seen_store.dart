// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// 持久化每个 tab 的通知去重窗口（[NotifyDedup] 的 `seen` 列表）。
///
/// 用 `shared_preferences` 而非 `flutter_secure_storage`：`seen` 只是一串
/// event_id 整数，不是凭据，走 Keystore 没有必要（参照 `AqtSessionStore`
/// 用 secure storage 存 session token 敏感数据 vs `KeybarSettings` 用
/// shared_preferences 存非敏感配置的既有区分）。
///
/// ## Key 作用域：按 tab，不是按 server（曾经错误地按 server 做过，已修正）
///
/// Key: `notify_seen_<tabId>`。
///
/// 服务端 `event_id` 的编号空间绑定在 QUIC session 上（`AqtSession.notify_queue`，
/// `rust/flyterm-server/src/notify/session.rs:29-39`），`next_id` 从每个 session
/// 各自的 0 起独立递增；`broadcast_notify`（同文件 153-158 行）把同一条 notify
/// 广播进所有 session 各自的队列，各自分号——同一次调用在不同 session 里可能
/// 拿到不同的 `event_id`。客户端这边每个 tab 各自 `AqtTransport.connect()`
/// 建一条独立 QUIC 连接（`terminal_screen.dart`），也就是各自独立的 session。
///
/// 换句话说：**`event_id` 只在单个 tab 的 transport 内唯一，跨 tab 完全没有
/// 可比性。** 若按 serverId 把多个 tab 的 `seen` 合并成一份（本类曾经的实现），
/// 后果是：同一服务器开两个 tab 时，新 tab 的 session 从 event_id=1 重新计数，
/// 而同 server 上另一个 tab 早就记录过同样的号码区间——新 tab 后续真实、全新的
/// 通知会被 `shouldShow` 误判为"已展示过"而永久静默丢弃，服务端并不知道客户端
/// 吞掉了它，不会重发，直到 24h TTL 或 50 条队列上限才把它挤掉。这是日常操作
/// （对同一台常用服务器开两个 tab）就会触发的问题，不是边角场景。
///
/// scope 必须和 `event_id` 的实际编号空间对齐——即按 tab。
///
/// **调用方必须保证**：一旦握手层检测到本次是新 HELLO（[wasResumed] ==
/// false，即这个 tab 对应的服务器端 session 从零开始），必须先对**这个 tab**
/// 调用 [clear] 再继续使用 `NotifyDedup`——否则旧一代残留的小 event_id 会让
/// 新一代同号的通知被 `NotifyDedup.shouldShow` 误判为"已展示过"而永久静默
/// 丢弃。详见 `notify_dedup.dart` 顶部注释。按 tab 清空还顺带避免了"新开一个
/// tab 却抹掉同 server 上另一个存活 tab 的记录"这个副作用。
class NotifySeenStore {
  static const _prefix = 'notify_seen_';

  Future<List<int>> load(String tabId) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('$_prefix$tabId');
    if (raw == null) return const [];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return list.cast<int>();
    } catch (_) {
      // 数据损坏——当成空窗口处理，宁可多弹几条通知也不要让异常向上传播。
      return const [];
    }
  }

  Future<void> save(String tabId, List<int> seen) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('$_prefix$tabId', jsonEncode(seen));
  }

  /// 新 HELLO（这个 tab 对应的服务端 session 归零）时调用：清空这个 tab 的
  /// 去重窗口。**不要传 serverId**——`event_id` 的编号空间是按 tab（= 按
  /// QUIC session）划分的，传 serverId 会误伤同一服务器上其它存活 tab 的
  /// 去重记录。
  Future<void> clear(String tabId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('$_prefix$tabId');
  }
}
