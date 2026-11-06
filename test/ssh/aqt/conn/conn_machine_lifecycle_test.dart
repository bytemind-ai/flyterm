import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ssh/aqt/conn/conn_machine.dart';
import 'package:flyterm/ssh/aqt/conn/conn_types.dart';

void main() {
  test('进后台：取消 tick 并清掉观测起点（进入盲区）', () {
    const s = MachineState(phase: ConnPhase.live, observeStartMs: 0);
    const f = Facts(nowMs: 1000, rawRecvAgeMs: 500, isForeground: false);
    final (s2, actions) = step(s, const LifecycleBackground(), f);
    expect(s2.observeStartMs, isNull, reason: '后台期间没有观测能力');
    expect(actions.whereType<CancelTick>().length, 1);
    expect(actions.whereType<SendProbe>(), isEmpty, reason: '后台不做探测');
  });

  test('回前台：重设观测起点并立即 tick', () {
    const s = MachineState(phase: ConnPhase.live);
    const f = Facts(nowMs: 721000, rawRecvAgeMs: 720000);
    final (s2, actions) = step(s, const LifecycleForeground(), f);
    expect(s2.observeStartMs, 721000);
    expect(actions.whereType<ScheduleTick>().single.delayMs, 0,
        reason: '不等 1s，立刻看一眼');
  });

  test('长后台回前台：第一个 tick 命中 elevated，3s 后判死而非 10s', () {
    var s = const MachineState(phase: ConnPhase.live, observeStartMs: 0);
    (s, _) = step(s, const LifecycleBackground(),
        const Facts(nowMs: 1000, rawRecvAgeMs: 500, isForeground: false));
    // 冻结 12 分钟
    (s, _) = step(s, const LifecycleForeground(),
        const Facts(nowMs: 721000, rawRecvAgeMs: 720000));
    // 第一个 tick：观测到的沉默才 100ms，但盲区 720s → elevated
    List<Action> a;
    (s, a) = step(s, const WatchdogTick(),
        const Facts(nowMs: 721100, rawRecvAgeMs: 720100));
    expect(s.phase, ConnPhase.live, reason: '观测到的沉默只有 100ms，不得判死');
    expect(a.whereType<SendProbe>(), isEmpty);

    // 3.1s 后仍无入向流量：elevated 档 suspect=3s → 该发探测了
    (s, a) = step(s, const WatchdogTick(),
        const Facts(nowMs: 724200, rawRecvAgeMs: 723200));
    expect(s.phase, ConnPhase.suspect);
    expect(a.whereType<SendProbe>().length, 1);
  });

  test('刚 RESUME 完的新 handle：哨兵 age 不得判死', () {
    // aqt_resume 分配全新 Rust handle，last_recv_at_ms 从 0 起，FFI 归一化成
    // 巨大哨兵值。observeStartMs 刚设 → 观测到的沉默≈0，必须读作"新鲜"。
    const s = MachineState(phase: ConnPhase.live, observeStartMs: 1000);
    const f = Facts(nowMs: 1050, rawRecvAgeMs: 1 << 40);
    final (s2, actions) = step(s, const WatchdogTick(), f);
    expect(s2.phase, ConnPhase.live);
    expect(actions.whereType<StartResume>(), isEmpty);
  });
}
