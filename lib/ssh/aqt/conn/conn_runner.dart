// SPDX-License-Identifier: GPL-3.0-or-later
/// 状态机的执行壳。
///
/// **它自己不做任何判断。** 允许 `switch (action)`（那是机械分派），禁止读
/// `state` 或 `facts` 做分支 —— 一旦壳里出现判断，"单一真相"就又漏了，而那
/// 正是这次重构要消除的病根。约束由 `conn_runner_test.dart` 机械锁住。
///
/// 异步动作（resume / bootstrap）**不把结果返回给调用点**，而是由调用方把成败
/// 作为新事件喂回来（`ConnectedOk` / `ConnectFailed`）。于是"在途"这件事只存在
/// 于 `MachineState.inFlight` 一处，不会再出现三个互斥集合各记一份。
library;

import 'conn_machine.dart';
import 'conn_trace.dart';
import 'conn_types.dart';

class AqtConnRunner {
  final void Function() onProbe;
  final void Function() onResume;
  final void Function() onBootstrap;
  final void Function() onClose;
  final void Function(String code) onBanner;
  final void Function() onClearBanner;
  final void Function(int delayMs) scheduleTick;
  final void Function() cancelTick;

  final ConnTrace trace;

  MachineState state = MachineState.initial;

  AqtConnRunner({
    required this.onProbe,
    required this.onResume,
    required this.onBootstrap,
    required this.onClose,
    required this.onBanner,
    required this.onClearBanner,
    required this.scheduleTick,
    required this.cancelTick,
    ConnTrace? trace,
  }) : trace = trace ?? ConnTrace();

  void feed(Event e, Facts f) {
    final from = state.phase;
    final (next, actions) = step(state, e, f);
    state = next;
    trace.record(
        event: e, facts: f, from: from, to: next.phase, actions: actions);
    for (final a in actions) {
      switch (a) {
        case SendProbe():
          onProbe();
        case StartResume():
          onResume();
        case StartBootstrap():
          onBootstrap();
        case Close():
          onClose();
        case ShowBanner(:final code):
          onBanner(code);
        case ClearBanner():
          onClearBanner();
        case ScheduleTick(:final delayMs):
          scheduleTick(delayMs);
        case CancelTick():
          cancelTick();
      }
    }
  }
}
