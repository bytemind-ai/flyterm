import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/agent/approval_notification.dart';

void main() {
  group('shouldNotify', () {
    test('前台且正看着该会话 → 不弹', () {
      expect(
        shouldNotifyApproval(
            appInForeground: true, visibleServerId: 'srv1', serverId: 'srv1'),
        isFalse,
      );
    });

    test('前台但在看别的服务器 → 弹', () {
      expect(
        shouldNotifyApproval(
            appInForeground: true, visibleServerId: 'srv2', serverId: 'srv1'),
        isTrue,
      );
    });

    test('后台 → 弹', () {
      expect(
        shouldNotifyApproval(
            appInForeground: false, visibleServerId: 'srv1', serverId: 'srv1'),
        isTrue,
      );
    });

    test('前台但面板没开（visibleServerId 为 null）→ 弹', () {
      expect(
        shouldNotifyApproval(
            appInForeground: true, visibleServerId: null, serverId: 'srv1'),
        isTrue,
      );
    });
  });

  group('approvalDedupKey', () {
    test('由 serverId、callId 与 seq 组成', () {
      expect(approvalDedupKey('srv1', 'c1', 1), equals('agent:srv1:c1:1'));
    });

    test('不同 callId 产生不同键', () {
      expect(approvalDedupKey('srv1', 'c1', 1),
          isNot(equals(approvalDedupKey('srv1', 'c2', 2))));
    });

    test('同一 callId 不同 seq 也要产生不同键 —— edit_file 的读/写两次审批'
        '共用同一个 callId，只有 seq 能把它们区分开', () {
      expect(approvalDedupKey('srv1', 'c1', 1),
          isNot(equals(approvalDedupKey('srv1', 'c1', 2))));
    });

    test('同一 (callId, seq) 重复调用产生相同键 —— 这是去重机制本身依赖的性质', () {
      expect(approvalDedupKey('srv1', 'c1', 1),
          equals(approvalDedupKey('srv1', 'c1', 1)));
    });
  });
}
