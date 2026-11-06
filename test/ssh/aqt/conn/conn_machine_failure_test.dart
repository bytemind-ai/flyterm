import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ssh/aqt/conn/conn_machine.dart';
import 'package:flyterm/ssh/aqt/conn/conn_types.dart';

void main() {
  const recovering = MachineState(phase: ConnPhase.recovering, inFlight: true);
  const f = Facts(nowMs: 50000, rawRecvAgeMs: 100);

  test('networkTimeout → 退避后重试 resume，保留凭据', () {
    final (s2, actions) =
        step(recovering, const ConnectFailed(FailReason.networkTimeout), f);
    expect(s2.phase, ConnPhase.backoff);
    expect(s2.inFlight, isFalse);
    expect(s2.attempt, 1);
    expect(actions.whereType<ScheduleTick>().single.delayMs, greaterThan(0));
    expect(actions.whereType<StartBootstrap>(), isEmpty);
  });

  test('sessionNotFound → 直接 bootstrap，不退避', () {
    final (s2, actions) =
        step(recovering, const ConnectFailed(FailReason.sessionNotFound), f);
    expect(s2.phase, ConnPhase.recovering);
    expect(actions.whereType<StartBootstrap>().length, 1);
  });

  test('handshakeFailed 第 1 次 → 退避重试', () {
    final (s2, actions) =
        step(recovering, const ConnectFailed(FailReason.handshakeFailed), f);
    expect(s2.handshakeFailStreak, 1);
    expect(s2.phase, ConnPhase.backoff);
    expect(actions.whereType<StartBootstrap>(), isEmpty);
  });

  test('handshakeFailed 第 2 次 → 升级为 bootstrap（防 ALPN 死循环）', () {
    // prewarm 拿磁盘 token 直连 QUIC、不走 SSH，没有任何一处比对版本。
    // ALPN aqt/1→aqt/2 之后旧服务端会让新客户端在这里失败，必须能升级成
    // "走 SSH 重新引导"，否则永远失败。
    const s = MachineState(
        phase: ConnPhase.recovering, inFlight: true, handshakeFailStreak: 1);
    final (s2, actions) =
        step(s, const ConnectFailed(FailReason.handshakeFailed), f);
    expect(s2.handshakeFailStreak, 0, reason: '升级后计数归零');
    expect(actions.whereType<StartBootstrap>().length, 1);
  });

  test('连接成功 → live，清空失败计数与退避', () {
    const s = MachineState(
        phase: ConnPhase.backoff,
        attempt: 3,
        handshakeFailStreak: 1,
        backoffUntilMs: 60000);
    final (s2, actions) = step(s, const ConnectedOk(), f);
    expect(s2.phase, ConnPhase.live);
    expect(s2.attempt, 0);
    expect(s2.handshakeFailStreak, 0);
    expect(s2.backoffUntilMs, isNull);
    expect(s2.observeStartMs, 50000, reason: '新连接是新的观测起点');
    expect(actions.whereType<ClearBanner>().length, 1);
  });

  test('TabClosed → gone，关闭并停表', () {
    final (s2, actions) = step(recovering, const TabClosed(), f);
    expect(s2.phase, ConnPhase.gone);
    expect(actions.whereType<CancelTick>().length, 1);
    expect(actions.whereType<Close>().length, 1);
  });

  test('退避到期 → 再试一次', () {
    const s = MachineState(
        phase: ConnPhase.backoff, attempt: 2, backoffUntilMs: 49000);
    final (s2, actions) = step(s, const WatchdogTick(), f);
    expect(s2.phase, ConnPhase.recovering);
    expect(s2.inFlight, isTrue);
    expect(actions.whereType<StartResume>().length, 1);
  });

  test('退避未到期 → 继续等，不重试', () {
    const s = MachineState(
        phase: ConnPhase.backoff, attempt: 2, backoffUntilMs: 60000);
    final (s2, actions) = step(s, const WatchdogTick(), f);
    expect(s2.phase, ConnPhase.backoff);
    expect(actions.whereType<StartResume>(), isEmpty);
    expect(actions.whereType<ScheduleTick>().length, 1);
  });

  test('切网时若在退避中 → 立即重试，不等退避走完', () {
    const s = MachineState(
        phase: ConnPhase.backoff, attempt: 3, backoffUntilMs: 999999);
    final (s2, actions) = step(s, const ConnectivityChanged('cellular'), f);
    expect(s2.phase, ConnPhase.recovering);
    expect(s2.backoffUntilMs, isNull);
    expect(actions.whereType<StartResume>().length, 1);
  });

  test('transport 关闭 → 进恢复', () {
    const s = MachineState(phase: ConnPhase.live, observeStartMs: 0);
    final (s2, actions) = step(s, const TransportClosed('peer reset'), f);
    expect(s2.phase, ConnPhase.recovering);
    expect(actions.whereType<StartResume>().length, 1);
  });
}
