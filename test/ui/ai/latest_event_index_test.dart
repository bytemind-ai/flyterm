import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/agent/agent_loop.dart';
import 'package:flyterm/ai/agent/tool_registry.dart';
import 'package:flyterm/ui/ai/latest_event_index.dart';

void main() {
  test('同类只有最后一个是最新', () {
    final a = PlanUpdatedEvent(['一'], 0);
    final b = PlanUpdatedEvent(['一', '二'], 1);
    final idx = LatestEventIndex.from([a, b]);
    expect(idx.isLatest(b), isTrue);
    expect(idx.isLatest(a), isFalse);
  });

  test('内容相同的两条也能区分 —— 用 identical 而非相等', () {
    final a = PlanUpdatedEvent(['一'], 0);
    final b = PlanUpdatedEvent(['一'], 0);
    final idx = LatestEventIndex.from([a, b]);
    expect(idx.isLatest(b), isTrue);
    expect(idx.isLatest(a), isFalse);
  });

  test('各类型互不干扰', () {
    final plan = PlanUpdatedEvent(['一'], 0);
    final stop = StoppedEvent(AgentStopReason.completed);
    final idx = LatestEventIndex.from([plan, stop]);
    expect(idx.isLatest(plan), isTrue);
    expect(idx.isLatest(stop), isTrue);
  });

  test('不参与活性判定的类型一律算最新', () {
    final tool = ToolCallEvent(
      seq: 0,
      callId: 'c1',
      toolName: 'bash',
      displayCommand: 'ls',
      description: '',
      check: const CheckResult(decision: ToolDecision.allow),
      status: ToolCallStatus.done,
    );
    final idx = LatestEventIndex.from([tool]);
    expect(idx.isLatest(tool), isTrue);
  });

  test('空列表不炸', () {
    final idx = LatestEventIndex.from([]);
    expect(idx.isLatest(StoppedEvent(AgentStopReason.completed)), isFalse);
  });

  test('长列表下仍然只认最后一个', () {
    final events = [
      for (var i = 0; i < 1000; i++) PlanUpdatedEvent(['第 $i 步'], 0),
    ];
    final idx = LatestEventIndex.from(events);
    expect(idx.isLatest(events.last), isTrue);
    expect(idx.isLatest(events[998]), isFalse);
    expect(idx.isLatest(events.first), isFalse);
  });
}
