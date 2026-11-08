import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ssh/aqt/conn/conn_machine.dart';
import 'package:flyterm/ssh/aqt/conn/conn_types.dart';

import 'conn_test_dsl.dart';

const _live = MachineState(phase: ConnPhase.live, observeStartMs: 0);

Facts _f(int now, int raw, {bool can = true}) =>
    Facts(nowMs: now, rawRecvAgeMs: raw, canSwitchPath: can);

void main() {
  machineCase('path switch fires at 6s observed silence when allowed',
      from: _live,
      events: [(const WatchdogTick(), _f(6500, 6500))],
      expectActions: [StartPathSwitch, ScheduleTick]);

  machineCase('no path switch when not allowed',
      from: _live,
      events: [(const WatchdogTick(), _f(6500, 6500, can: false))],
      expectPhase: ConnPhase.live,
      forbidActions: [StartPathSwitch]);

  machineCase('elevated urgency switches at 3s',
      // 回前台后盲区：raw 20000、观测起点 3500ms 前 → 观测沉默 3500，盲区 16500。
      from: const MachineState(phase: ConnPhase.live, observeStartMs: 30000),
      events: [(const WatchdogTick(), _f(33500, 20000))],
      expectActions: [StartPathSwitch]);

  machineCase('normal urgency does not switch at 3s',
      from: _live,
      events: [(const WatchdogTick(), _f(3500, 3500))],
      forbidActions: [StartPathSwitch]);

  machineCase('death deferred while switch in flight',
      from: _live,
      events: [
        (const WatchdogTick(), _f(6500, 6500)),
        (const WatchdogTick(), _f(15000, 15000)),
        (const WatchdogTick(), _f(19000, 19000)),
        (const WatchdogTick(), _f(20500, 20500)), // 越过 death，但在预算内
      ],
      forbidActions: [StartResume, StartPathSwitch]);

  test('death deferred: phase is not recovering inside the budget', () {
    final (s, _) = runSeq([
      (const WatchdogTick(), _f(6500, 6500)),
      (const WatchdogTick(), _f(15000, 15000)),
      (const WatchdogTick(), _f(18000, 18000)), // 探测超时，被暂缓
    ], from: _live);
    expect(s.phase, isNot(ConnPhase.recovering));
    expect(s.pathSwitchSinceMs, 6500);
  });

  machineCase('death resumes after budget',
      from: _live,
      events: [
        (const WatchdogTick(), _f(6500, 6500)),
        (const WatchdogTick(), _f(26500, 26500)), // 6500+12000 已过，silence>=20000
      ],
      expectPhase: ConnPhase.recovering,
      expectActions: [StartResume]);

  machineCase('probe timeout resumes after budget',
      from: _live,
      events: [
        (const WatchdogTick(), _f(6500, 6500)),
        (const WatchdogTick(), _f(11000, 11000)), // suspect
        (const WatchdogTick(), _f(18600, 18600)), // 超预算且探测超时
      ],
      expectPhase: ConnPhase.recovering,
      expectActions: [StartResume]);

  machineCase('pty stall still recovers immediately while switching',
      from: const MachineState(
          phase: ConnPhase.live,
          observeStartMs: 0,
          pathSwitchSinceMs: 6500,
          pathSwitchUsed: true),
      events: [
        (
          const WatchdogTick(),
          const Facts(
              nowMs: 8000,
              rawRecvAgeMs: 100,
              ptySilenceMs: 50000,
              sinceLastWriteMs: 1000,
              canSwitchPath: true)
        ),
      ],
      expectPhase: ConnPhase.recovering,
      expectActions: [StartResume]);

  test('path switch fires once per live cycle', () {
    var s = _live;
    List<Action> a;
    (s, a) = step(s, const WatchdogTick(), _f(6500, 6500));
    expect(a.whereType<StartPathSwitch>(), hasLength(1));
    (s, _) = step(s, const PathSwitchFailed(), _f(7000, 7000));
    expect(s.pathSwitchSinceMs, isNull);
    expect(s.pathSwitchUsed, isTrue);
    (s, a) = step(s, const WatchdogTick(), _f(8000, 8000));
    expect(a.whereType<StartPathSwitch>(), isEmpty);
    // 新鲜流量：新的 live 周期。
    (s, a) = step(s, const WatchdogTick(), _f(9000, 500));
    expect(s.phase, ConnPhase.live);
    expect(s.pathSwitchUsed, isFalse);
    (s, a) = step(s, const WatchdogTick(), _f(16000, 6500));
    expect(a.whereType<StartPathSwitch>(), hasLength(1));
  });

  test('PathSwitched then fresh traffic returns to live', () {
    var s = _live;
    (s, _) = step(s, const WatchdogTick(), _f(6500, 6500));
    expect(s.pathSwitchSinceMs, isNotNull);
    List<Action> a;
    (s, a) = step(s, const PathSwitched(), _f(7000, 7000));
    expect(s.pathSwitchSinceMs, isNull);
    expect(a.whereType<ScheduleTick>().single.delayMs, 0);
    (s, _) = step(s, const WatchdogTick(), _f(7100, 50));
    expect(s.phase, ConnPhase.live);
    expect(s.pathSwitchUsed, isFalse);
  });

  test('LifecycleBackground clears the in-flight switch', () {
    var s = _live;
    (s, _) = step(s, const WatchdogTick(), _f(6500, 6500));
    (s, _) = step(s, const LifecycleBackground(), _f(7000, 7000));
    expect(s.pathSwitchSinceMs, isNull);
  });
}
