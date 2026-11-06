import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/agent/approval_notification.dart';

/// 审批去重集合的**对账**逻辑。
///
/// ## 问题
///
/// `AgentSessionManager._notified` 是一个只加不减的 `Set<String>`：每条新审批
/// 都把 `approvalDedupKey` 塞进去，**从此再没有任何路径把它取出来**（只有整个
/// manager `dispose` 才随对象一起消失）。
///
/// 后果有两层：
///
/// 1. **内存只涨不落。** 一段长期运行的会话里，每一条审批留一个字符串。量级
///    不大，但它是那种「永远不会被回收」的形态，长期挂后台的会话会持续累积。
/// 2. **语义错位。** 集合的语义是「已经通知过的审批」，而它实际记的是「历史
///    上出现过的所有 (serverId, callId, seq)」。这两者不该等价 —— 一个已经
///    被用户应答掉的审批，不再需要被记住；一旦它因为任何原因重新进入待审批
///    状态，**应该**重新通知（那是一次新的等待），而不是被一条陈旧的记录
///    永久压住。
///
/// ## 修法
///
/// 每次 `_checkPendingApprovals` 都拿「当前仍在等审批的 key 集合」去对账：
/// 不在其中的 key 全部丢弃。这样集合的语义精确回到「此刻仍处于待审批且已通知
/// 过」。
///
/// 注意**不能**反过来把「已通知」当成「永远不再通知」——对账只清不在待审批
/// 里的 key，仍在待审批的保留原样，所以同一张卡重复触发仍然只通知一次（这是
/// 这个机制本来要解决的问题，不能修坏）。
void main() {
  group('审批去重集合对账', () {
    test('仍在待审批的 key 被保留', () {
      final kept = reconcileNotified(
        notified: {'a', 'b'},
        stillPending: {'a', 'b'},
      );
      expect(kept, {'a', 'b'});
    });

    test('已不在待审批里的 key 被清掉', () {
      final kept = reconcileNotified(
        notified: {'a', 'b', 'c'},
        stillPending: {'a'},
      );
      expect(kept, {'a'});
    });

    test('待审批为空 → 全部清空', () {
      final kept = reconcileNotified(
        notified: {'a', 'b'},
        stillPending: <String>{},
      );
      expect(kept, isEmpty);
    });

    test('出现过但从未通知过的 key 不会被加进来 —— 对账只做删减', () {
      // 这条守的是「集合语义是『已通知且仍待审批』」：`stillPending` 里那些
      // 还没通知过的 key 应该由调用方在通知时 add，不归对账管。
      final kept = reconcileNotified(
        notified: {'a'},
        stillPending: {'a', 'new'},
      );
      expect(kept, {'a'});
      expect(kept.contains('new'), isFalse);
    });

    test('不修改入参 —— 调用方可能还在别处持有这个集合', () {
      final notified = {'a', 'b'};
      reconcileNotified(notified: notified, stillPending: {'a'});
      expect(notified, {'a', 'b'});
    });
  });
}
