import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ssh/aqt/conn/conn_types.dart';

void main() {
  test('MachineState.copyWith 只改指定字段', () {
    const s = MachineState(phase: ConnPhase.live, observeStartMs: 100);
    final t = s.copyWith(phase: ConnPhase.suspect);
    expect(t.phase, ConnPhase.suspect);
    expect(t.observeStartMs, 100, reason: '未指定的字段必须保持');
  });

  test('copyWith 能把可空字段显式清成 null', () {
    const s = MachineState(phase: ConnPhase.suspect, suspectSinceMs: 500);
    final t = s.copyWith(clearSuspectSince: true);
    expect(t.suspectSinceMs, isNull);
  });

  test('初始状态是 idle 且无观测起点', () {
    expect(MachineState.initial.phase, ConnPhase.idle);
    expect(MachineState.initial.observeStartMs, isNull);
  });
}
