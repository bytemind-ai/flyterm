import 'package:flyterm/ssh/aqt/notify_dedup.dart';
import 'package:flutter_test/flutter_test.dart';

/// 通知去重与前台抑制。
///
/// 去重是必需项不是优化项：服务端的 last_acked 只在真正收到 NotifyAck 时才推进
/// （宁可重复投递也不能静默丢失），断网发生在 Notify 发出后、NotifyAck 到达前时，
/// 重连补投会让用户再看一遍。QUIC 重连在本 app 里是高频事件。
void main() {
  group('去重', () {
    test('首次出现的 event_id 应展示', () {
      expect(NotifyDedup.shouldShow(const [], 1), isTrue);
    });

    test('已展示过的 event_id 必须丢弃', () {
      expect(NotifyDedup.shouldShow(const [1, 2, 3], 2), isFalse);
    });

    test('remember 追加到末尾', () {
      expect(NotifyDedup.remember(const [1, 2], 3), [1, 2, 3]);
    });

    test('remember 对重复 id 幂等，不重复追加', () {
      expect(NotifyDedup.remember(const [1, 2], 2), [1, 2]);
    });

    test('remember 不修改入参', () {
      final seen = [1, 2];
      NotifyDedup.remember(seen, 3);
      expect(seen, [1, 2], reason: '入参被就地修改会让调用方拿到意外的共享状态');
    });

    test('窗口满时淘汰最旧的', () {
      final seen = List<int>.generate(NotifyDedup.kWindow, (i) => i);
      final out = NotifyDedup.remember(seen, 9999);
      expect(out.length, NotifyDedup.kWindow);
      expect(out.first, 1, reason: '最旧的 0 被淘汰');
      expect(out.last, 9999);
    });

    test('去重窗口必须远大于服务端队列上限', () {
      // 服务端队列 50 条。窗口小于它就会漏掉能被补投的事件，
      // 导致重连后重复弹通知。
      expect(NotifyDedup.kWindow, greaterThan(50));
    });
  });

  group('前台抑制', () {
    test('前台且目标 tab 在可见集合里 → 抑制系统通知', () {
      expect(
        NotifyDedup.shouldSuppressSystemNotification(
            appInForeground: true, visibleTabIds: const {'a'}, targetTabId: 'a'),
        isTrue,
      );
    });

    test('前台但目标 tab 是分屏副屏/悬浮窗（不是 activeTab 但可见）→ 抑制', () {
      // visibleTabIds 由调用方合并 activeTabId + secondarySession + floatingSession；
      // 这里模拟 'a' 是 activeTab、'c' 是副屏，'c' 上来了通知也该抑制。
      expect(
        NotifyDedup.shouldSuppressSystemNotification(
            appInForeground: true,
            visibleTabIds: const {'a', 'c'},
            targetTabId: 'c'),
        isTrue,
      );
    });

    test('前台但目标 tab 完全不在可见集合里 → 仍要通知', () {
      expect(
        NotifyDedup.shouldSuppressSystemNotification(
            appInForeground: true, visibleTabIds: const {'b'}, targetTabId: 'a'),
        isFalse,
      );
    });

    test('后台 → 一律通知', () {
      expect(
        NotifyDedup.shouldSuppressSystemNotification(
            appInForeground: false, visibleTabIds: const {'a'}, targetTabId: 'a'),
        isFalse,
      );
    });

    test('目标 tab 未知（tmux 环境变量过期）→ 不抑制', () {
      // 宁可多弹一次，也不要因为无法判断就吞掉。
      expect(
        NotifyDedup.shouldSuppressSystemNotification(
            appInForeground: true, visibleTabIds: const {'a'}, targetTabId: null),
        isFalse,
      );
    });

    test('当前无可见 tab（比如在服务器列表页）→ 不抑制', () {
      expect(
        NotifyDedup.shouldSuppressSystemNotification(
            appInForeground: true, visibleTabIds: const {}, targetTabId: 'a'),
        isFalse,
      );
    });

    test('目标未知时不抑制，即使可见集合也是空的（双未知）', () {
      // `visibleTabIds` 是 `Set<String>`，健全空安全下不可能包含 null 元素，
      // 所以 `targetTabId == null` 时 `contains(null)` 恒为 false——这个场景
      // 已经被类型系统排除，不需要额外的 `!= null` 守卫。这条用例仍然保留，
      // 是为了在实现细节变化时继续锁住"未知来源不抑制"这条外部可观察行为，
      // 而不是为了验证某个内部守卫是否存在。
      expect(
        NotifyDedup.shouldSuppressSystemNotification(
            appInForeground: true, visibleTabIds: const {}, targetTabId: null),
        isFalse,
      );
    });
  });
}
