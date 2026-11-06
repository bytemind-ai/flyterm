import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flyterm/ssh/aqt/notify_seen_store.dart';

void main() {
  group('NotifySeenStore', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('未写入过 → load 返回空列表', () async {
      final store = NotifySeenStore();
      expect(await store.load('tab-1'), isEmpty);
    });

    test('save 后 load 能读回同样内容', () async {
      final store = NotifySeenStore();
      await store.save('tab-1', [1, 2, 3]);
      expect(await store.load('tab-1'), [1, 2, 3]);
    });

    test('不同 tabId 互不影响（即便是同一台服务器上的两个 tab）', () async {
      // 这里刻意不用 srv-1/srv-2 这种"看起来像不同服务器"的命名——真正要
      // 锁住的行为是"scope 按 tab 走"，同一服务器的两个 tab 也必须互不影响。
      // 更具体的回归场景见 notify_seen_scope_regression_test.dart。
      final store = NotifySeenStore();
      await store.save('tab-1', [1, 2]);
      await store.save('tab-2', [9]);
      expect(await store.load('tab-1'), [1, 2]);
      expect(await store.load('tab-2'), [9]);
    });

    test('clear 后 load 回到空列表', () async {
      final store = NotifySeenStore();
      await store.save('tab-1', [1, 2, 3]);
      await store.clear('tab-1');
      expect(await store.load('tab-1'), isEmpty);
    });

    test('clear 只清目标 tab，不影响其它 tab', () async {
      final store = NotifySeenStore();
      await store.save('tab-1', [1, 2, 3]);
      await store.save('tab-2', [7, 8]);
      await store.clear('tab-1');
      expect(await store.load('tab-1'), isEmpty);
      expect(await store.load('tab-2'), [7, 8],
          reason: 'clear(tab-1) 不应该误伤 tab-2 的去重记录');
    });

    test('数据损坏（非法 JSON）→ load 兜底为空列表，不抛异常', () async {
      SharedPreferences.setMockInitialValues({
        'notify_seen_tab-1': 'not-json{{',
      });
      final store = NotifySeenStore();
      expect(await store.load('tab-1'), isEmpty);
    });
  });
}
