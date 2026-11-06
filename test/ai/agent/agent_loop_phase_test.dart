// phaseStartedAt / runningCalls 的单测。
//
// 这两个 getter 是运行条唯一的新数据来源，而它们的语义有一条容易被后来者
// 当 bug 修掉的地方：每次 _setState 都重置起点。
import 'package:flutter_test/flutter_test.dart';

import 'package:flyterm/ai/agent/agent_loop.dart';
import 'package:flyterm/ai/agent/tool_models.dart';
import 'package:flyterm/ai/agent/tool_registry.dart';

import '_fakes.dart';

ToolCallEvent _call({
  required int seq,
  ToolCallStatus status = ToolCallStatus.running,
  String cmd = 'systemctl status nginx',
}) =>
    ToolCallEvent(
      seq: seq,
      callId: 'c$seq',
      toolName: 'bash',
      displayCommand: cmd,
      description: '',
      check: const CheckResult(decision: ToolDecision.allow),
      status: status,
    );

void main() {
  test('新建的 loop 还没进过任何阶段，phaseStartedAt 为 null', () {
    final loop = makeLoop(provider: FakeProvider(const []));
    addTearDown(loop.dispose);

    expect(loop.phaseStartedAt, isNull);
  });

  test('debugForceRunning 进入 thinking 时记下起点', () {
    final loop = makeLoop(provider: FakeProvider(const []));
    addTearDown(loop.dispose);

    loop.debugForceRunning();

    expect(loop.state, AgentLoopState.thinking);
    expect(loop.phaseStartedAt, isNotNull);
  });

  // 秒表语义是「当前这一步等了多久」，不是「整轮」。executing 在
  // 每个 executor 入口都会 _setState 一次，一轮跑五个工具就重置五次 ——
  // 这是想要的行为。这条测试把它钉住，免得被当成重置 bug「修」掉。
  test('再次进入某个阶段会重置起点', () async {
    final loop = makeLoop(provider: FakeProvider(const []));
    addTearDown(loop.dispose);

    loop.debugForceRunning();
    final first = loop.phaseStartedAt!;

    await Future<void>.delayed(const Duration(milliseconds: 5));
    loop.debugForceRunning();

    expect(loop.phaseStartedAt!.isAfter(first), isTrue);
  });

  test('runningCalls 只收 running 状态的调用', () {
    final loop = makeLoop(provider: FakeProvider(const []));
    addTearDown(loop.dispose);

    loop.debugAddEvent(_call(seq: 1, cmd: 'a'));
    loop.debugAddEvent(_call(seq: 2, status: ToolCallStatus.done, cmd: 'b'));
    loop.debugAddEvent(
        _call(seq: 3, status: ToolCallStatus.awaitingApproval, cmd: 'c'));
    loop.debugAddEvent(_call(seq: 4, cmd: 'd'));

    expect(loop.runningCalls.map((e) => e.displayCommand), ['a', 'd']);
  });

  test('没有运行中调用时 runningCalls 为空', () {
    final loop = makeLoop(provider: FakeProvider(const []));
    addTearDown(loop.dispose);

    loop.debugAddEvent(_call(seq: 1, status: ToolCallStatus.done));

    expect(loop.runningCalls, isEmpty);
  });
}
