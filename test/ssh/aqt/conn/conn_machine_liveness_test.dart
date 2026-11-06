import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ssh/aqt/conn/conn_machine.dart';
import 'package:flyterm/ssh/aqt/conn/conn_types.dart';

void main() {
  test('入向流量新鲜 → 保持 live，只排下一个 tick', () {
    const s = MachineState(phase: ConnPhase.live, observeStartMs: 0);
    const f = Facts(nowMs: 5000, rawRecvAgeMs: 1000);
    final (s2, actions) = step(s, const WatchdogTick(), f);
    expect(s2.phase, ConnPhase.live);
    expect(actions.whereType<ScheduleTick>().length, 1);
    expect(actions.whereType<SendProbe>(), isEmpty);
  });

  test('沉默越过 suspect → 发探测并进 suspect', () {
    const s = MachineState(phase: ConnPhase.live, observeStartMs: 0);
    const f = Facts(nowMs: 11000, rawRecvAgeMs: 11000);
    final (s2, actions) = step(s, const WatchdogTick(), f);
    expect(s2.phase, ConnPhase.suspect);
    expect(s2.suspectSinceMs, 11000);
    expect(actions.whereType<SendProbe>().length, 1);
  });

  test('探测无回音超过 probeTimeout → 判死并发起恢复', () {
    const s = MachineState(
        phase: ConnPhase.suspect, observeStartMs: 0, suspectSinceMs: 11000);
    const f = Facts(nowMs: 14100, rawRecvAgeMs: 14100);
    final (s2, actions) = step(s, const WatchdogTick(), f);
    expect(s2.phase, ConnPhase.recovering);
    expect(s2.inFlight, isTrue);
    expect(actions.whereType<StartResume>().length, 1);
  });

  test('丢 tick：单次越过 death 天花板 → 当场判死，不经 probe', () {
    // 这是 death 天花板存在的唯一理由：丢 tick 时不能等 probe。
    //
    // 原 test/ssh/aqt/conn/death_ceiling_test.dart 用旧的 WatchdogState 锁同一个
    // 结论，随旧实现一起删除 —— 结论并入此处，不要再拆回去。
    const s = MachineState(phase: ConnPhase.live, observeStartMs: 0);
    const f = Facts(nowMs: 25000, rawRecvAgeMs: 25000);
    final (s2, actions) = step(s, const WatchdogTick(), f);
    expect(s2.phase, ConnPhase.recovering);
    expect(actions.whereType<StartResume>().length, 1);
    expect(actions.whereType<SendProbe>(), isEmpty);
  });

  test('探测有回音 → 回到 live 并清掉 suspect', () {
    const s = MachineState(
        phase: ConnPhase.probing, observeStartMs: 0, suspectSinceMs: 11000);
    const f = Facts(nowMs: 12000, rawRecvAgeMs: 10);
    final (s2, _) = step(s, const ProbeAnswered(), f);
    expect(s2.phase, ConnPhase.live);
    expect(s2.suspectSinceMs, isNull);
  });

  test('弱网：停在 suspect/probing 往复，不进 recovering', () {
    var s = const MachineState(phase: ConnPhase.live, observeStartMs: 0);
    // 11s 沉默 → suspect
    (s, _) = step(s, const WatchdogTick(), const Facts(nowMs: 11000, rawRecvAgeMs: 11000));
    expect(s.phase, ConnPhase.suspect);
    // 12s：探测在途，尚未超时 → probing
    (s, _) = step(s, const WatchdogTick(), const Facts(nowMs: 12000, rawRecvAgeMs: 12000));
    expect(s.phase, ConnPhase.probing);
    // 包回来了 → live
    (s, _) = step(s, const ProbeAnswered(), const Facts(nowMs: 12500, rawRecvAgeMs: 5));
    expect(s.phase, ConnPhase.live);
  });
}
