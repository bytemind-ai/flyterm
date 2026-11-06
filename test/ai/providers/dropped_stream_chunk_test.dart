import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/ai_message.dart';
import 'package:flyterm/ai/providers/anthropic_provider.dart';
import 'package:flyterm/ai/providers/ollama_provider.dart';
import 'package:flyterm/ai/providers/openai_provider.dart';
import 'package:flyterm/ai/providers/provider_http.dart';

/// 丢弃的流分片必须**可观测**。
///
/// 三个 provider 的 SSE/NDJSON 解析循环都长这样：
///
/// ```dart
/// try {
///   final json = jsonDecode(data) as Map<String, dynamic>;
///   ...
/// } catch (_) {}
/// ```
///
/// 一个畸形分片会被静默丢掉 —— 用户看到的是「回复少了半句」，而日志里
/// 什么都没有。`dlog` 在这里帮不上忙：它被 `kDebugMode` 守卫，release 构建
/// 整个 tree-shake 掉，而本项目**禁止 debug 构建**（见 CLAUDE.md），
/// 所以 dlog 在生产包里等于不存在。
///
/// 沿用 `provider_http.dart` 里 `debugNewConnectionCount` 那条现成的路：
/// 一个 release 可见的计数器，只在 `debugCountConnections`（跟随
/// `TerminalSettings.debugOverlay`）打开时增长。
class _SseAdapter implements HttpClientAdapter {
  final List<String> lines;
  _SseAdapter(this.lines);

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<List<int>>? requestStream, Future<void>? cancelFuture) async {
    Stream<Uint8List> gen() async* {
      for (final l in lines) {
        yield Uint8List.fromList(utf8Bytes('$l\n'));
      }
    }

    return ResponseBody(gen(), 200, headers: {
      'content-type': ['text/event-stream']
    });
  }

  @override
  void close({bool force = false}) {}
}

List<int> utf8Bytes(String s) => s.codeUnits;

Dio dioWith(List<String> lines) => createProviderDio()
  ..httpClientAdapter = _SseAdapter(lines);

void main() {
  setUp(() {
    debugCountConnections = true;
    debugDroppedStreamChunks = 0;
  });
  tearDown(() {
    debugCountConnections = false;
    debugDroppedStreamChunks = 0;
  });

  test('OpenAI：畸形分片计数 +1，合法分片不计', () async {
    final p = OpenAIProvider(
      apiKey: 'k',
      model: 'm',
      dio: dioWith([
        'data: {"choices":[{"delta":{"content":"ok"}}]}',
        'data: {this is not json', // 畸形
        'data: [DONE]',
      ]),
    );

    final out = await p.completeStream(const [AIMessage(role: 'user', content: 'hi')]).toList();

    expect(out.join(), contains('ok'), reason: '合法分片照常产出');
    expect(debugDroppedStreamChunks, equals(1));
  });

  test('Anthropic：畸形分片同样计数', () async {
    final p = AnthropicProvider(
      apiKey: 'k',
      model: 'm',
      dio: dioWith([
        'data: {"type":"content_block_delta","delta":{"text":"hi"}}',
        'data: not json at all',
      ]),
    );

    await p.completeStream(const [AIMessage(role: 'user', content: 'hi')]).toList();

    expect(debugDroppedStreamChunks, equals(1));
  });

  test('Ollama：畸形 NDJSON 同样计数', () async {
    final p = OllamaProvider(
      model: 'm',
      baseUrl: 'http://localhost:11434',
      dio: dioWith([
        '{"message":{"content":"hi"},"done":false}',
        '{"broken":',
      ]),
    );

    await p.completeStream(const [AIMessage(role: 'user', content: 'hi')]).toList();

    expect(debugDroppedStreamChunks, equals(1));
  });

  test('开关关闭时不计 —— 与 connection 计数同一条守卫', () async {
    debugCountConnections = false;
    debugDroppedStreamChunks = 0;

    final p = OpenAIProvider(
      apiKey: 'k',
      model: 'm',
      dio: dioWith(['data: {bad json']),
    );

    await p.completeStream(const [AIMessage(role: 'user', content: 'hi')]).toList();

    expect(debugDroppedStreamChunks, equals(0));
  });
}
