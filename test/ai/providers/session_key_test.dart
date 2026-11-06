import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/ai_message.dart';
import 'package:flyterm/ai/ai_provider.dart';
import 'package:flyterm/ai/agent/tool_models.dart';

/// 只实现非流式那一个方法，用来验证基类的默认 `completeWithToolsStream`
/// 把 `sessionKey` 原样转发下去 —— 不转发的话，任何依赖默认实现的
/// provider 都会静默丢掉这个参数。
class _RecordingProvider extends AIProvider {
  String? seen;

  @override
  String get displayName => 'rec';

  @override
  String get providerType => 'rec';

  @override
  Future<String> complete(List<AIMessage> messages) async => '';

  @override
  Future<AIResponse> completeWithTools(
    List<AIMessage> messages,
    List<ToolSpec> tools, {
    String? sessionKey,
  }) async {
    seen = sessionKey;
    return const AIResponse(text: 'ok', toolCalls: []);
  }
}

void main() {
  test('默认的 completeWithToolsStream 把 sessionKey 转发给 completeWithTools',
      () async {
    final p = _RecordingProvider();

    await p.completeWithToolsStream(const [], const [], sessionKey: 'sk-1')
        .toList();

    expect(p.seen, 'sk-1');
  });

  test('不传时转发 null，不自造值', () async {
    final p = _RecordingProvider();

    await p.completeWithToolsStream(const [], const []).toList();

    expect(p.seen, isNull);
  });
}
