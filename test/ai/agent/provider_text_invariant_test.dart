// 锁死一条推测执行依赖的不变量：
//   StreamDone.response.text == 此前所有 TextDelta.text 按序拼接的结果
//
// 这条不变量目前在三家 provider 里都成立（写 _text 缓冲紧挨着产出
// TextDelta，中间没有分支），但没有测试守着。一旦哪家漂了，后果是 AI 面板
// 转录出现重复/丢失文字，而请求本身依然成功——只能靠肉眼发现。
//
// 本文件不测三家各自的解析细节（那些已经在 anthropic_stream_test.dart /
// openai_stream_test.dart / ollama_stream_test.dart 里覆盖），只测这一条
// 跨三家共享的契约。
import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/agent/tool_models.dart';
import 'package:flyterm/ai/providers/anthropic_provider.dart';
import 'package:flyterm/ai/providers/openai_provider.dart';
import 'package:flyterm/ai/providers/ollama_provider.dart';

/// 把一串行喂进 parser，返回 (拼接的 TextDelta, StreamDone 里的 text)。
(String, String) _drive(
  List<AgentChunk> Function(String) accept,
  List<AgentChunk> Function() finish,
  List<String> lines,
) {
  final buf = StringBuffer();
  String? doneText;
  void consume(List<AgentChunk> cs) {
    for (final c in cs) {
      switch (c) {
        case TextDelta(:final text):
          buf.write(text);
        case StreamDone(:final response):
          doneText = response.text;
        case ToolCallReady():
          break;
      }
    }
  }

  for (final l in lines) {
    consume(accept(l));
  }
  consume(finish());
  return (buf.toString(), doneText ?? '');
}

void main() {
  group('纯文本流：拼接结果与 StreamDone.text 一致', () {
    test('Anthropic', () {
      final parser = AnthropicToolStreamParser();
      final (concat, done) = _drive(parser.acceptLine, parser.finish, [
        'data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}',
        'data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"你好，"}}',
        'data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"世界"}}',
        'data: {"type":"content_block_stop","index":0}',
        'data: {"type":"message_stop"}',
      ]);

      expect(concat, '你好，世界');
      expect(done, concat);
    });

    test('OpenAI', () {
      final parser = OpenAIToolStreamParser();
      final (concat, done) = _drive(parser.acceptLine, parser.finish, [
        'data: {"choices":[{"delta":{"content":"你好，"}}]}',
        'data: {"choices":[{"delta":{"content":"世界"}}]}',
        'data: [DONE]',
      ]);

      expect(concat, '你好，世界');
      expect(done, concat);
    });

    test('Ollama', () {
      final parser = OllamaToolStreamParser();
      final (concat, done) = _drive(parser.acceptLine, parser.finish, [
        '{"message":{"content":"你好，"},"done":false}',
        '{"message":{"content":"世界"},"done":false}',
        '{"message":{"content":""},"done":true}',
      ]);

      expect(concat, '你好，世界');
      expect(done, concat);
    });
  });

  group('文本 + tool call 混合流：不变量依然成立（推测执行的真实场景）', () {
    test('Anthropic: 文本 -> tool_use -> 文本', () {
      final parser = AnthropicToolStreamParser();
      final (concat, done) = _drive(parser.acceptLine, parser.finish, [
        'data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}',
        'data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"先查一下 "}}',
        'data: {"type":"content_block_stop","index":0}',
        'data: {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_1","name":"bash","input":{}}}',
        'data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\\"command\\":\\"uptime\\"}"}}',
        'data: {"type":"content_block_stop","index":1}',
        'data: {"type":"content_block_start","index":2,"content_block":{"type":"text","text":""}}',
        'data: {"type":"content_block_delta","index":2,"delta":{"type":"text_delta","text":"系统已运行 "}}',
        'data: {"type":"content_block_delta","index":2,"delta":{"type":"text_delta","text":"3 天"}}',
        'data: {"type":"content_block_stop","index":2}',
        'data: {"type":"message_stop"}',
      ]);

      expect(concat, '先查一下 系统已运行 3 天');
      expect(done, concat);
    });

    test('OpenAI: 文本 -> tool_call -> 文本', () {
      final parser = OpenAIToolStreamParser();
      final (concat, done) = _drive(parser.acceptLine, parser.finish, [
        'data: {"choices":[{"delta":{"content":"先查 "}}]}',
        'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"bash","arguments":"{\\"command\\":\\"uptime\\"}"}}]}}]}',
        'data: {"choices":[{"delta":{"content":"日志"}}]}',
        'data: [DONE]',
      ]);

      expect(concat, '先查 日志');
      expect(done, concat);
    });

    test('Ollama: 文本 -> tool_call -> 文本', () {
      final parser = OllamaToolStreamParser();
      final (concat, done) = _drive(parser.acceptLine, parser.finish, [
        '{"message":{"content":"先查 "},"done":false}',
        '{"message":{"content":"","tool_calls":[{"function":{"name":"bash","arguments":{"command":"uptime"}}}]},"done":false}',
        '{"message":{"content":"日志"},"done":false}',
        '{"message":{"content":""},"done":true}',
      ]);

      expect(concat, '先查 日志');
      expect(done, concat);
    });
  });
}
