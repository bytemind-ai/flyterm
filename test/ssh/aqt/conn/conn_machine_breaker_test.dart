import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ssh/aqt/conn/conn_machine.dart';
import 'package:flyterm/ssh/aqt/conn/conn_types.dart';

void main() {
  test('反复成功但活不过 kMinAliveMs → givenUp', () {
    // 级联的定义是"反复成功又反复掉"，不是"次数多"。
    // 弱网下次数多是正常的，不该熔断。
    final marks = [
      for (var i = 0; i < 5; i++)
        AttemptMark(startedAtMs: 1000 + i * 5000, aliveMs: 2000),
    ];
    final s = MachineState(
        phase: ConnPhase.recovering, inFlight: true, recent: marks,
        recoveringSinceMs: 26000);
    const f = Facts(nowMs: 27000, rawRecvAgeMs: 10);
    final (s2, actions) = step(s, const ConnectedOk(), f);
    expect(s2.phase, ConnPhase.givenUp);
    expect(actions.whereType<ShowBanner>().single.code, 'reconnectLoopDetected');
    expect(actions.whereType<ScheduleTick>(), isEmpty, reason: '熔断后停止自动重连');
  });

  test('次数多但每次都活得久 → 不熔断', () {
    final marks = [
      for (var i = 0; i < 5; i++)
        AttemptMark(startedAtMs: 1000 + i * 60000, aliveMs: 55000),
    ];
    final s = MachineState(
        phase: ConnPhase.recovering, inFlight: true, recent: marks,
        recoveringSinceMs: 300000);
    const f = Facts(nowMs: 301000, rawRecvAgeMs: 10);
    final (s2, _) = step(s, const ConnectedOk(), f);
    expect(s2.phase, ConnPhase.live);
  });

  test('givenUp 后只有 UserRefresh 能救', () {
    const s = MachineState(phase: ConnPhase.givenUp);
    const f = Facts(nowMs: 100000, rawRecvAgeMs: 99999);
    final (s1, a1) = step(s, const WatchdogTick(), f);
    expect(s1.phase, ConnPhase.givenUp);
    expect(a1, isEmpty);

    final (s2, a2) = step(s, const UserRefresh(), f);
    expect(s2.phase, ConnPhase.recovering);
    expect(a2.whereType<StartResume>().length, 1);
  });

  test('recovering 超过 kBannerDelayMs 才出横幅', () {
    const s = MachineState(
        phase: ConnPhase.recovering, inFlight: true, recoveringSinceMs: 1000);
    // 500ms：还在静默期，不打扰用户
    final (_, early) =
        step(s, const WatchdogTick(), const Facts(nowMs: 1500, rawRecvAgeMs: 100));
    expect(early.whereType<ShowBanner>(), isEmpty);
    // 900ms：超过 800ms → 提示
    final (_, late_) =
        step(s, const WatchdogTick(), const Facts(nowMs: 1900, rawRecvAgeMs: 100));
    expect(late_.whereType<ShowBanner>().single.code, 'reconnectInProgress');
  });

  test('isCascading 是纯函数，可单独测', () {
    final shortLived = [
      for (var i = 0; i < 5; i++)
        AttemptMark(startedAtMs: 1000 + i * 5000, aliveMs: 2000),
    ];
    expect(isCascading(shortLived, 27000), isTrue);

    // 不足阈值次数
    expect(isCascading(shortLived.take(3).toList(), 27000), isFalse);

    // 全是失败（aliveMs 为 null）→ 不算级联，那是"连不上"不是"连上又掉"
    final allFailed = [
      for (var i = 0; i < 5; i++) AttemptMark(startedAtMs: 1000 + i * 5000),
    ];
    expect(isCascading(allFailed, 27000), isFalse);
  });
}
