import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/agent/agent_loop.dart';
import 'package:flyterm/ai/agent/tool_registry.dart';
import 'package:flyterm/ai/agent/knowledge_gate.dart';

/// 造一次 ToolCallEvent 的辅助函数。
ToolCallEvent makeToolCall({
  required int seq,
  required String toolName,
  required ToolCallStatus status,
}) {
  return ToolCallEvent(
    seq: seq,
    callId: 'call_$seq',
    toolName: toolName,
    displayCommand: '$toolName test',
    description: 'Test tool call',
    check: const CheckResult(decision: ToolDecision.allow),
    status: status,
  );
}

/// 造一个「够格」的会话事件流：3 次成功 bash 调用。
List<AgentEvent> goodSession() {
  return [
    UserTurnEvent('how do I check disk space?'),
    ToolCallEvent(
      seq: 1,
      callId: 'call_1',
      toolName: 'bash',
      displayCommand: 'df -h',
      description: 'Check disk usage',
      check: const CheckResult(decision: ToolDecision.allow),
      status: ToolCallStatus.done,
    ),
    AssistantTextEvent('I will run df -h'),
    ToolCallEvent(
      seq: 2,
      callId: 'call_2',
      toolName: 'bash',
      displayCommand: 'mount',
      description: 'Check mounts',
      check: const CheckResult(decision: ToolDecision.allow),
      status: ToolCallStatus.done,
    ),
    AssistantTextEvent('Now checking mounts'),
    ToolCallEvent(
      seq: 3,
      callId: 'call_3',
      toolName: 'bash',
      displayCommand: 'free -h',
      description: 'Check memory',
      check: const CheckResult(decision: ToolDecision.allow),
      status: ToolCallStatus.done,
    ),
  ];
}

void main() {
  group('shouldProposeKnowledge', () {
    test('够格的会话提议 —— 3 次成功调用且含实际动作', () {
      final events = goodSession();
      final result = shouldProposeKnowledge(
        reason: AgentStopReason.completed,
        events: events,
        alreadyProposed: false,
      );
      expect(result, isTrue);
    });

    test('非 completed 收场一律不提议 —— 半截的排查沉淀下来就是错误知识', () {
      final events = goodSession();
      final nonCompletedReasons = [
        AgentStopReason.userCancelled,
        AgentStopReason.error,
        AgentStopReason.tokenBudget,
        AgentStopReason.maxTurns,
        AgentStopReason.invalidArgs,
      ];

      for (final reason in nonCompletedReasons) {
        final result = shouldProposeKnowledge(
          reason: reason,
          events: events,
          alreadyProposed: false,
        );
        expect(
          result,
          isFalse,
          reason: 'Stop reason $reason should not propose',
        );
      }
    });

    test('一次会话只提议一次', () {
      final events = goodSession();
      final result = shouldProposeKnowledge(
        reason: AgentStopReason.completed,
        events: events,
        alreadyProposed: true,
      );
      expect(result, isFalse);
    });

    test('边界：只有 2 次成功调用时不提议', () {
      final events = [
        UserTurnEvent('help'),
        makeToolCall(seq: 1, toolName: 'bash', status: ToolCallStatus.done),
        makeToolCall(seq: 2, toolName: 'bash', status: ToolCallStatus.done),
      ];
      final result = shouldProposeKnowledge(
        reason: AgentStopReason.completed,
        events: events,
        alreadyProposed: false,
      );
      expect(result, isFalse);
    });

    test('边界：恰好 3 次成功调用时提议', () {
      final events = [
        UserTurnEvent('help'),
        makeToolCall(seq: 1, toolName: 'bash', status: ToolCallStatus.done),
        makeToolCall(seq: 2, toolName: 'bash', status: ToolCallStatus.done),
        makeToolCall(seq: 3, toolName: 'bash', status: ToolCallStatus.done),
      ];
      final result = shouldProposeKnowledge(
        reason: AgentStopReason.completed,
        events: events,
        alreadyProposed: false,
      );
      expect(result, isTrue);
    });

    test('失败与被拒的调用不计入次数', () {
      final events = [
        makeToolCall(seq: 1, toolName: 'bash', status: ToolCallStatus.failed),
        makeToolCall(seq: 2, toolName: 'bash', status: ToolCallStatus.rejected),
        makeToolCall(seq: 3, toolName: 'bash', status: ToolCallStatus.done),
        makeToolCall(seq: 4, toolName: 'bash', status: ToolCallStatus.done),
        makeToolCall(seq: 5, toolName: 'bash', status: ToolCallStatus.done),
      ];
      final result = shouldProposeKnowledge(
        reason: AgentStopReason.completed,
        events: events,
        alreadyProposed: false,
      );
      expect(result, isTrue);
    });

    test('只有只读调用时不提议 —— 「我看了三个文件」不是知识', () {
      final events = [
        makeToolCall(
          seq: 1,
          toolName: 'read_file',
          status: ToolCallStatus.done,
        ),
        makeToolCall(
          seq: 2,
          toolName: 'read_terminal',
          status: ToolCallStatus.done,
        ),
        makeToolCall(
          seq: 3,
          toolName: 'list_servers',
          status: ToolCallStatus.done,
        ),
      ];
      final result = shouldProposeKnowledge(
        reason: AgentStopReason.completed,
        events: events,
        alreadyProposed: false,
      );
      expect(result, isFalse);
    });

    test('bash / edit_file / write_file 各自都算实际动作', () {
      final actionTools = ['bash', 'edit_file', 'write_file'];

      for (final actionTool in actionTools) {
        final events = [
          makeToolCall(
            seq: 1,
            toolName: 'read_file',
            status: ToolCallStatus.done,
          ),
          makeToolCall(
            seq: 2,
            toolName: 'read_file',
            status: ToolCallStatus.done,
          ),
          makeToolCall(
            seq: 3,
            toolName: actionTool,
            status: ToolCallStatus.done,
          ),
        ];
        final result = shouldProposeKnowledge(
          reason: AgentStopReason.completed,
          events: events,
          alreadyProposed: false,
        );
        expect(
          result,
          isTrue,
          reason: '$actionTool should count as action tool',
        );
      }
    });

    test('空事件流不提议', () {
      final result = shouldProposeKnowledge(
        reason: AgentStopReason.completed,
        events: [],
        alreadyProposed: false,
      );
      expect(result, isFalse);
    });
  });
}
