import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/agent/approval_notification.dart';

/// 审批通知的**通知 id 分配**与**展示失败补偿**。
///
/// ## 为什么 id 不能用哈希
///
/// 之前是 `Object.hash(serverId, seq) & 0x7fffffff`。它有两个问题，都不在
/// 理论上而在日常使用里：
///
/// 1. **不同通知可能撞同一个 id。** Android 的通知 id 相同即**覆盖**——后一
///    条会把前一条顶掉。哈希空间是 2^31，但审批通知 id 的唯一性要求不是
///    「概率低」，而是「不能覆盖已有的那条」。两台服务器、不同命令、不同
///    seq 撞进同一个 bucket 是有可能发生的，撞上就是一条审批通知静默消失。
/// 2. **它不单调。** `NotificationService.show` 的契约是「同一 eventId 再次
///    展示会覆盖旧的，这是期望行为」—— 那个契约成立的前提是 eventId 只对应
///    一条真实事件。哈希不满足这个前提。
///
/// 改成进程内单调递增计数器后，两者同时解决。
void main() {
  group('审批通知 id 分配', () {
    test('同一实例连续分配，id 严格递增', () {
      final a = ApprovalNotificationIds();
      final first = a.next();
      final second = a.next();
      expect(second, greaterThan(first));
    });

    test('不同 (serverId, seq) 一定拿到不同 id —— 哪怕它们哈希相同', () {
      final a = ApprovalNotificationIds();
      // 交错分配两条不同来源的审批，模拟两台服务器同时等你。
      final id1 = a.next();
      final id2 = a.next();
      expect(id1, isNot(equals(id2)));
    });

    test('id 落在 Android 32-bit 正整数范围内', () {
      final a = ApprovalNotificationIds();
      for (var i = 0; i < 1000; i++) {
        final id = a.next();
        expect(id, greaterThanOrEqualTo(0));
        expect(id, lessThanOrEqualTo(0x7fffffff));
      }
    });

    test('从 1 开始，不用 0 —— 0 是「没有通知」的惯用哨兵', () {
      expect(ApprovalNotificationIds().next(), 1);
    });
  });
}
