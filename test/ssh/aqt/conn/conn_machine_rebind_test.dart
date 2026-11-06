import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ssh/aqt/conn/conn_machine.dart';
import 'package:flyterm/ssh/aqt/conn/conn_types.dart';

void main() {
  test('rebindCount 增加 → 重置观测起点，不因跨迁移点的 age 判死', () {
    // 服务端日志里那 9 次 ConnectionLost(TimedOut)（同一 IP、9 个源端口）就是
    // 这个场景：NAT 重绑定后，迁移之前的沉默对新路径没有说明力。
    const s = MachineState(
        phase: ConnPhase.live, observeStartMs: 0, lastRebindCount: 0);
    const f = Facts(nowMs: 30000, rawRecvAgeMs: 25000, rebindCount: 1);
    final (s2, actions) = step(s, const WatchdogTick(), f);
    expect(s2.lastRebindCount, 1);
    expect(s2.observeStartMs, 30000, reason: '观测起点必须重置到迁移时刻');
    expect(s2.phase, ConnPhase.live, reason: '不得因跨迁移点的 age 判死');
    expect(actions.whereType<StartResume>(), isEmpty);
  });

  test('rebindCount 不变 → 正常判活', () {
    const s = MachineState(
        phase: ConnPhase.live, observeStartMs: 0, lastRebindCount: 3);
    const f = Facts(nowMs: 25000, rawRecvAgeMs: 25000, rebindCount: 3);
    final (s2, _) = step(s, const WatchdogTick(), f);
    expect(s2.phase, ConnPhase.recovering, reason: '没有迁移，25s 沉默该判死');
  });
}
