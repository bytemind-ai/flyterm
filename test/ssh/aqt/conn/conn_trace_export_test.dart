import 'package:flyterm/ssh/aqt/conn/conn_runner.dart';
import 'package:flyterm/ssh/aqt/conn/conn_types.dart';
import 'package:flutter_test/flutter_test.dart';

AqtConnRunner _runner() => AqtConnRunner(
      onProbe: () {},
      onResume: () {},
      onBootstrap: () {},
      onClose: () {},
      onBanner: (_) {},
      onClearBanner: () {},
      scheduleTick: (_) {},
      cancelTick: () {},
    );

void main() {
  test('轨迹为空时 export 返回空串，不该写盘', () {
    final r = _runner();
    expect(r.trace.lines, isEmpty);
    expect(r.trace.export(), isEmpty);
  });

  test('喂过事件后 export 出可粘贴的文本', () {
    final r = _runner();
    r.state = const MachineState(phase: ConnPhase.live, observeStartMs: 0);
    r.feed(const WatchdogTick(), const Facts(nowMs: 11000, rawRecvAgeMs: 11000));
    final text = r.trace.export();
    expect(text, contains('WatchdogTick'));
    expect(text, contains('live→suspect'));
    expect(text, contains('now=11000'));
  });

  test('进 givenUp 的轨迹里能看到那次转移', () {
    // 熔断那一刻的序列是最值钱的，必须在轨迹里可见。
    final marks = [
      for (var i = 0; i < 5; i++)
        AttemptMark(startedAtMs: 1000 + i * 5000, aliveMs: 2000),
    ];
    final r = _runner();
    r.state = MachineState(
        phase: ConnPhase.recovering, inFlight: true, recent: marks,
        recoveringSinceMs: 26000);
    r.feed(const ConnectedOk(), const Facts(nowMs: 27000, rawRecvAgeMs: 10));
    expect(r.state.phase, ConnPhase.givenUp);
    expect(r.trace.export(), contains('→givenUp'));
  });
}
