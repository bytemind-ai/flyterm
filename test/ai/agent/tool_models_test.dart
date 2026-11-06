import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/ai_message.dart';
import 'package:flyterm/ai/agent/tool_models.dart';

void main() {
  group('parseToolArgs', () {
    test('Map 原样返回（Ollama / Anthropic 形态）', () {
      expect(parseToolArgs({'command': 'ls'}), equals({'command': 'ls'}));
    });

    test('JSON 字符串被解析（OpenAI 形态）', () {
      expect(parseToolArgs('{"command":"ls"}'), equals({'command': 'ls'}));
    });

    test('非法 JSON 返回空 Map，不抛异常', () {
      expect(parseToolArgs('{not json'), isEmpty);
    });

    test('null 返回空 Map', () {
      expect(parseToolArgs(null), isEmpty);
    });
  });

  group('ToolCall JSON 往返', () {
    test('往返后字段一致', () {
      const c = ToolCall(id: 'c1', name: 'bash', args: {'command': 'ls'});
      final back = ToolCall.fromJson(c.toJson());
      expect(back.id, equals('c1'));
      expect(back.name, equals('bash'));
      expect(back.args['command'], equals('ls'));
    });
  });

  group('AIMessage 扩展', () {
    test('assistant 消息可携带 toolCalls 并往返', () {
      const m = AIMessage(
        role: 'assistant',
        content: '',
        toolCalls: [ToolCall(id: 'c1', name: 'bash', args: {'command': 'ls'})],
      );
      final back = AIMessage.fromJson(m.toJson());
      expect(back.toolCalls, isNotNull);
      expect(back.toolCalls!.single.name, equals('bash'));
    });

    test('tool 消息可携带多个 toolResults 并往返', () {
      const m = AIMessage(
        role: 'tool',
        content: '',
        toolResults: [
          ToolResult(callId: 'c1', content: 'out1'),
          ToolResult(callId: 'c2', content: 'err', isError: true),
        ],
      );
      final back = AIMessage.fromJson(m.toJson());
      expect(back.toolResults!.length, equals(2));
      expect(back.toolResults![1].isError, isTrue);
    });

    test('旧格式历史仍能读 —— 缺字段不抛异常', () {
      final back = AIMessage.fromJson({'role': 'user', 'content': 'hi'});
      expect(back.role, equals('user'));
      expect(back.toolCalls, isNull);
      expect(back.toolResults, isNull);
    });

    test('旧的 toolResult 类型字段仍能读', () {
      final back = AIMessage.fromJson(
          {'role': 'user', 'content': 'x', 'type': 'toolResult', 'command': 'ls'});
      expect(back.type, equals(AIMessageType.toolResult));
      expect(back.command, equals('ls'));
    });
  });

  group('AIResponse', () {
    test('无 toolCalls 时 hasToolCalls 为 false', () {
      const r = AIResponse(text: 'done');
      expect(r.hasToolCalls, isFalse);
    });

    test('有 toolCalls 时为 true', () {
      const r = AIResponse(
          toolCalls: [ToolCall(id: 'c1', name: 'bash', args: {})]);
      expect(r.hasToolCalls, isTrue);
    });

    test('默认构造下 usage 为空', () {
      const r = AIResponse();
      expect(r.usage.isEmpty, isTrue);
    });

    test('传入自定义 usage 能原样取回', () {
      const usage = TokenUsage(inputTokens: 10, cachedTokens: 5, outputTokens: 2);
      const r = AIResponse(usage: usage);
      expect(r.usage.inputTokens, equals(10));
      expect(r.usage.cachedTokens, equals(5));
      expect(r.usage.outputTokens, equals(2));
    });
  });

  group('ToolResult.exitCode', () {
    test('往返 json 不丢', () {
      const r = ToolResult(callId: 'c1', content: 'ok', exitCode: 3);
      final back = ToolResult.fromJson(r.toJson());
      expect(back.exitCode, equals(3));
    });

    test('null 时不写进 json（不让旧格式历史文件膨胀）', () {
      const r = ToolResult(callId: 'c1', content: 'ok');
      expect(r.toJson().containsKey('exitCode'), isFalse);
    });

    test('exitCode 0 必须写进 json', () {
      const r = ToolResult(callId: 'c1', content: 'ok', exitCode: 0);
      expect(r.toJson()['exitCode'], equals(0));
      expect(ToolResult.fromJson(r.toJson()).exitCode, equals(0));
    });

    test('旧存档没有该字段时读成 null', () {
      final back = ToolResult.fromJson({'callId': 'c1', 'content': 'x'});
      expect(back.exitCode, isNull);
    });
  });

  group('ToolResult.timedOut', () {
    test('往返 json 不丢', () {
      const r = ToolResult(
          callId: 'c1', content: 'x', exitCode: -1, timedOut: true);
      final back = ToolResult.fromJson(r.toJson());
      expect(back.timedOut, isTrue);
      expect(back.exitCode, equals(-1));
    });

    test('默认 false 时不写进 json（与 isError 处理一致）', () {
      const r = ToolResult(callId: 'c1', content: 'ok', exitCode: 0);
      expect(r.toJson().containsKey('timedOut'), isFalse);
    });

    test('旧存档没有该字段时读成 false', () {
      final back = ToolResult.fromJson({'callId': 'c1', 'content': 'x'});
      expect(back.timedOut, isFalse);
    });
  });
}
