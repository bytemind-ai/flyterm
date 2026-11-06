import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/ai_provider.dart';
import 'package:flyterm/ai/agent/agent_tools.dart';
import 'package:flyterm/ai/agent/tool_models.dart';

/// 只实现非流式那条路 —— 用来验证默认的 completeWithToolsStream
/// 把它包装成了一条等价的流。
class _NonStreamingProvider extends AIProvider {
  final AIResponse response;
  _NonStreamingProvider(this.response);

  @override
  String get displayName => 'non-streaming';

  @override
  String get providerType => 'fake';

  @override
  bool get supportsTools => true;

  @override
  Future<String> complete(List<AIMessage> messages) async => '';

  @override
  Future<AIResponse> completeWithTools(
          List<AIMessage> messages, List<ToolSpec> tools,
          {String? sessionKey}) async =>
      response;
}

void main() {
  test('默认实现把 completeWithTools 包成等价的单轮流', () async {
    final provider = _NonStreamingProvider(const AIResponse(
      text: 'checking nginx',
      toolCalls: [
        ToolCall(id: 'c1', name: 'bash', args: {'command': 'ls'}),
      ],
      usage: TokenUsage(inputTokens: 10, outputTokens: 3),
    ));

    final chunks = await provider
        .completeWithToolsStream(
            [const AIMessage(role: 'user', content: 'hi')], leanToolSpecs)
        .toList();

    expect(chunks.whereType<TextDelta>().map((c) => c.text).join(),
        equals('checking nginx'));
    expect(chunks.whereType<ToolCallReady>().map((c) => c.call.id).toList(),
        equals(['c1']));

    // 顺序也是契约的一部分：文本 → tool call → StreamDone。上面两句用
    // whereType 各自过滤，互相之间的先后没被检查——把 for 循环写到
    // 文本之前的实现照样能过。
    expect(chunks.map((c) => c.runtimeType).toList(),
        equals([TextDelta, ToolCallReady, StreamDone]));

    final done = chunks.last as StreamDone;
    expect(done.response.text, equals('checking nginx'));
    expect(done.response.toolCalls.length, equals(1));
    expect(done.response.usage.inputTokens, equals(10));
  });

  test('StreamDone 永远是最后一个 chunk，即使响应是空的', () async {
    final provider = _NonStreamingProvider(const AIResponse());
    final chunks = await provider
        .completeWithToolsStream(
            [const AIMessage(role: 'user', content: 'hi')], leanToolSpecs)
        .toList();

    expect(chunks.length, equals(1));
    expect(chunks.single, isA<StreamDone>());
  });
}
