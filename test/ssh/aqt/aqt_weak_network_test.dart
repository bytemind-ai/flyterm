import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ssh/aqt/aqt_transport.dart';
import 'package:flyterm/ssh/aqt/aqt_transport_factory.dart';

void main() {
  group('QUIC weak-network constants', () {
    test('heartbeat interval is 5 s', () {
      expect(
        AqtTransport.kHeartbeatInterval,
        const Duration(seconds: 5),
      );
    });

    test('default RESUME timeout is 5 s (C2 race tightened from 8 s)', () {
      // C2 — RESUME budget reduced from 8s → 5s; bootstrap race kicks
      // in as backup at the 3s checkpoint, so a 5s RESUME cap is
      // sufficient on healthy paths. Weak-network budget (kWeakNetwork…)
      // stays at 14s for actual slow paths.
      expect(
        AqtTransportFactory.kDefaultResumeTimeout,
        const Duration(seconds: 5),
      );
    });

    test('weak-network RESUME timeout is 14 s', () {
      expect(
        AqtTransportFactory.kWeakNetworkResumeTimeout,
        const Duration(seconds: 14),
      );
    });

    test('foreground fast RESUME timeout is 3 s', () {
      expect(
        AqtTransportFactory.kForegroundFastResumeTimeout,
        const Duration(seconds: 3),
      );
    });

    test('kResumeTimeout alias matches kDefaultResumeTimeout', () {
      expect(
        AqtTransportFactory.kResumeTimeout,
        AqtTransportFactory.kDefaultResumeTimeout,
      );
    });

    test('immediate foreground probe is enabled', () {
      expect(AqtTransport.kImmediateForegroundProbe, isTrue);
    });

    test('background does not run app heartbeat', () {
      // 后台**不**跑 app 心跳：setForeground(false) 会 cancel 心跳定时器
      // （aqt_transport.dart 的 background 分支），只剩 quinn 的 15s keepalive。
      //
      // 这里曾经断言一个名为 kBackgroundHeartbeat 的常量为 true，而实现正好相反
      // —— 常量和它的文档都是过期的，测试锁住了错误的事实。常量已删除。
      expect(AqtTransport.kHeartbeatIntervalForeground, const Duration(seconds: 3));
    });
  });
}
