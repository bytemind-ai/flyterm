import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flyterm/ssh/aqt/notify_dedup.dart';
import 'package:flyterm/ssh/aqt/notify_seen_store.dart';

/// C2 回归测试：`NotifySeenStore` 的 key 必须按 tab（= 按 QUIC session）
/// 作用域，不能按 server。
///
/// 背景：服务端 `event_id` 的编号空间绑定在 QUIC session 上
/// （`rust/flyterm-server/src/notify/session.rs` 的 `AqtSession.notify_queue`，
/// 每个 session 各自的 `next_id` 从 0 独立递增）；`broadcast_notify` 把同一条
/// notify 广播进所有 session 各自的队列，各自分号，同一次调用在不同 session
/// 里可能拿到不同的 event_id。客户端这边每个 tab 各自建一条独立的
/// `AqtTransport.connect()`，也就是各自独立的 session。因此 event_id 只在
/// 单个 tab 内唯一，跨 tab（哪怕是同一台服务器上的另一个 tab）完全没有
/// 可比性。
///
/// 这里曾经的实现按 serverId 做 key，把同一服务器多个 tab 的 seen 合并成
/// 一份——第二个用例（负对照）复现了那个 bug 本该表现出的症状：若把 key
/// 换回 serverId，第二个 tab 真实全新的 event_id=1 会被判定为"已展示过"。
/// 第一个用例验证的是修复后（按 tabId scope）的正确行为。
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test(
      '按 tabId scope（当前实现）：同一 server 两个 tab 各自的 event_id=1 互不影响',
      () async {
    final store = NotifySeenStore();
    const tabAId = 'tab-a';
    const tabBId = 'tab-b';

    // tabA 的 QUIC session 收到并展示了它自己队列里的第一条通知
    // （它自己的 event_id 序列从 1 开始）。
    final tabASeen = NotifyDedup.remember(await store.load(tabAId), 1);
    await store.save(tabAId, tabASeen);

    // tabB 是同一台服务器上另一个 tab——独立的 QUIC session，它自己的
    // event_id 序列也从 1 开始。这是 tabB 自己会话里第一次、真实全新的
    // 通知，必须展示。
    final tabBSeen = await store.load(tabBId);
    expect(
      NotifyDedup.shouldShow(tabBSeen, 1),
      isTrue,
      reason: 'tabB 与 tabA 是不同 QUIC session，各自的 event_id 编号空间'
          '互不共享，tabB 第一次见到自己的 event_id=1 必须展示',
    );
  });

  test(
      '负对照：若按 serverId scope（曾经的错误实现），tabB 的全新事件会被误判为已展示',
      () async {
    final store = NotifySeenStore();
    // 复现旧实现：两个 tab 共用同一个 key（serverId）——store 本身只是纯粹
    // 的 key-value，key 传什么完全由调用方决定，这里故意传 serverId 来复现
    // 当年的 bug，而不是这份测试本身有问题。
    const serverId = 'srv-shared-by-both-tabs';

    final sharedSeenAfterTabA =
        NotifyDedup.remember(await store.load(serverId), 1);
    await store.save(serverId, sharedSeenAfterTabA);

    // tabB 若也用 serverId 当 key，会读到 tabA 写下的 [1]。
    final sharedSeenReadByTabB = await store.load(serverId);
    expect(
      NotifyDedup.shouldShow(sharedSeenReadByTabB, 1),
      isFalse,
      reason: '这正是 C2 描述的 bug：serverId scope 下，tabB 自己真实全新的 '
          'event_id=1 被 tabA 的记录误判为"已展示过"而被 shouldShow 拒绝。'
          '这条用例断言的是"旧实现会复现 bug"这件事本身，不是期望行为——'
          '用来证明改成 tabId scope 是必须的，而不是可选的风格调整。',
    );
  });
}
