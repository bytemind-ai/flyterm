import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/agent/agent_loop.dart';
import 'package:flyterm/ai/agent/tool_registry.dart';

void main() {
  ToolCallEvent makeEvent() => ToolCallEvent(
        seq: 1,
        callId: 'c1',
        toolName: 'bash',
        displayCommand: 'ls',
        description: '',
        check: const CheckResult(decision: ToolDecision.allow),
        status: ToolCallStatus.running,
      );

  test('跑完的调用带上 durationMs', () {
    final ev = makeEvent();
    ev.startedAt = DateTime.now().subtract(const Duration(milliseconds: 1500));
    finishToolCallForTest(ev, ToolCallStatus.done);
    expect(ev.durationMs, isNotNull);
    expect(ev.durationMs, greaterThanOrEqualTo(1500));
  });

  test('没开始执行过的调用不编造耗时', () {
    final ev = makeEvent();
    finishToolCallForTest(ev, ToolCallStatus.rejected);
    expect(ev.durationMs, isNull,
        reason: '没跑过就没有耗时，给 0 会让卡片显示「0.0s」，是假信息');
  });

  test('重复进终态不覆盖首次耗时', () {
    final ev = makeEvent();
    ev.startedAt = DateTime.now().subtract(const Duration(seconds: 3));
    finishToolCallForTest(ev, ToolCallStatus.done);
    final first = ev.durationMs;
    finishToolCallForTest(ev, ToolCallStatus.failed);
    expect(ev.durationMs, first);
  });

  test('durationMs 跨归档往返', () {
    final ev = makeEvent();
    ev.startedAt = DateTime.now().subtract(const Duration(milliseconds: 2400));
    finishToolCallForTest(ev, ToolCallStatus.done);
    final restored = agentEventsFromJson([agentEventToJson(ev)]).single
        as ToolCallEvent;
    expect(restored.durationMs, ev.durationMs);
  });

  test('旧存档没有 durationMs 字段也能读', () {
    final restored = agentEventsFromJson([
      {'t': 'tool', 'seq': 1, 'callId': 'c', 'toolName': 'bash',
       'displayCommand': 'ls', 'description': '', 'status': 'done'},
    ]).single as ToolCallEvent;
    expect(restored.durationMs, isNull);
  });
}
