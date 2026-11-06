import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ssh/notification_service.dart';

/// 通知**分组键契约**。
///
/// ## 背景
///
/// 同一台机器上连着干活，通知栏会堆出一排互不相关的独立条目，每条各占一行、
/// 各自响铃。Android 的通知分组把同 groupKey 的通知折成一条 summary + 子项。
///
/// 这里能 device-free 守住的有两件事，缺一不可：
/// 1. 分组键稳定且非空（写成每次调用都不同的值，分组会静默失效）；
/// 2. **它真的被挂进了展示用的 android 细节** —— 光有一个常量不等于有人用它，
///    那种「写了但没接线」的差异只能靠断言细节守。
void main() {
  group('通知分组键', () {
    test('非空', () {
      expect(NotificationService.groupKeyForTesting, isNotEmpty);
    });

    test('稳定 —— 多次读取同一个值（掺了时间戳之类的会让分组静默失效）', () {
      expect(
        NotificationService.groupKeyForTesting,
        equals(NotificationService.groupKeyForTesting),
      );
    });

    test('与频道 id 不同 —— 两者是不同层的东西，混用会让语义含糊', () {
      expect(
        NotificationService.groupKeyForTesting,
        isNot(equals(NotificationService.channelIdForTesting)),
      );
    });

    test('展示用的 android 细节真的带上了分组键', () {
      final details = NotificationService.androidDetailsForTesting;
      expect(details.android?.groupKey,
          equals(NotificationService.groupKeyForTesting));
    });

    test('分组只整理通知栏，不静音 —— alertBehavior 必须是 all', () {
      // 把后来的那几条悄悄降级，会让「高频通知」从刷屏变成漏看 —— 那是
      // 另一个方向的错误，比刷屏更难被发现。
      final details = NotificationService.androidDetailsForTesting;
      expect(details.android?.groupAlertBehavior,
          equals(GroupAlertBehavior.all));
    });
  });
}
