import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ssh/aqt/conn/conn_trace.dart';
import 'package:flyterm/ssh/aqt/conn/conn_types.dart';

void main() {
  test('记一条转移，格式含事件名 / facts 数值 / 前后 phase / actions', () {
    final t = ConnTrace(cap: 4);
    t.record(
      event: const WatchdogTick(),
      facts: const Facts(nowMs: 11000, rawRecvAgeMs: 11000, rebindCount: 2),
      from: ConnPhase.live,
      to: ConnPhase.suspect,
      actions: const [SendProbe()],
    );
    final line = t.lines.single;
    expect(line, contains('WatchdogTick'));
    expect(line, contains('now=11000'));
    expect(line, contains('raw=11000'));
    expect(line, contains('rebind=2'));
    expect(line, contains('live→suspect'));
    expect(line, contains('SendProbe'));
  });

  test('有界：超过 cap 丢最旧', () {
    final t = ConnTrace(cap: 2);
    for (var i = 0; i < 5; i++) {
      t.record(
        event: const WatchdogTick(),
        facts: Facts(nowMs: i, rawRecvAgeMs: 0),
        from: ConnPhase.live,
        to: ConnPhase.live,
        actions: const [],
      );
    }
    expect(t.lines.length, 2);
    expect(t.lines.last, contains('now=4'));
  });

  test('不含任何终端内容 —— 只有事件名与数值', () {
    final t = ConnTrace(cap: 4);
    t.record(
      event: const TransportClosed('secret-shell-output'),
      facts: const Facts(nowMs: 1, rawRecvAgeMs: 0),
      from: ConnPhase.live,
      to: ConnPhase.recovering,
      actions: const [],
    );
    expect(t.lines.single, isNot(contains('secret-shell-output')),
        reason: 'reason 字符串可能带远端内容，不落盘');
  });
}
