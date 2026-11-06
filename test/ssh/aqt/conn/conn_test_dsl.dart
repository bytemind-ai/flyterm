/// 表驱动测试 DSL。
///
/// 它的输入格式与 `lib/ssh/aqt/conn/conn_trace.dart` 的轨迹落盘格式一一对应
/// —— 于是真机复现出来的轨迹可以直接粘成用例。这条链是整套设计能否终结
/// 「第 11 轮稳定性优化」的关键：前 9 轮的共同弱点就是改完无法证明没回归。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ssh/aqt/conn/conn_machine.dart';
import 'package:flyterm/ssh/aqt/conn/conn_types.dart';

/// 跑一串 (event, facts)，返回终态与**最后一步**产生的 actions。
(MachineState, List<Action>) runSeq(List<(Event, Facts)> seq,
    {MachineState from = MachineState.initial}) {
  var s = from;
  var acts = <Action>[];
  for (final (e, f) in seq) {
    final (s2, a) = step(s, e, f);
    s = s2;
    acts = a;
  }
  return (s, acts);
}

void machineCase(
  String description, {
  required List<(Event, Facts)> events,
  MachineState from = MachineState.initial,
  ConnPhase? expectPhase,
  List<Type> expectActions = const [],
  List<Type> forbidActions = const [],
}) {
  test(description, () {
    final (s, acts) = runSeq(events, from: from);
    if (expectPhase != null) {
      expect(s.phase, expectPhase, reason: '终态 phase 不符');
    }
    for (final t in expectActions) {
      expect(acts.map((a) => a.runtimeType), contains(t),
          reason: '最后一步应当产生 $t');
    }
    for (final t in forbidActions) {
      expect(acts.map((a) => a.runtimeType), isNot(contains(t)),
          reason: '最后一步不该产生 $t');
    }
  });
}
