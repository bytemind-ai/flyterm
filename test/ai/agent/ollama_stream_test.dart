import 'dart:convert';
import 'dart:io' show HttpException;
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/ai_message.dart';
import 'package:flyterm/ai/agent/agent_tools.dart';
import 'package:flyterm/ai/agent/tool_models.dart';
import 'package:flyterm/ai/providers/ollama_provider.dart';

List<AgentChunk> feed(List<String> lines) {
  final parser = OllamaToolStreamParser();
  final out = <AgentChunk>[];
  for (final l in lines) {
    out.addAll(parser.acceptLine(l));
  }
  out.addAll(parser.finish());
  return out;
}

/// 造一条 NDJSON 流式响应。写法照 anthropic_stream_test.dart /
/// openai_stream_test.dart 里的 `_StreamAdapter`：把每行切成两个字节块
/// 发出，逼出「多字节字符被分片切断」的情况。
class _StreamAdapter implements HttpClientAdapter {
  final List<String> lines;

  /// 非 null = 所有行发完之后让流以这个错误结束，模拟服务端/中间链路不发
  /// chunked 终止块就关掉连接。
  final Object? abortWith;

  Map<String, dynamic>? captured;

  _StreamAdapter(this.lines, {this.abortWith});

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<List<int>>? requestStream, Future<void>? cancelFuture) async {
    if (requestStream != null) {
      final bytes =
          await requestStream.fold<List<int>>([], (a, b) => a..addAll(b));
      captured = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    }
    Stream<Uint8List> gen() async* {
      for (final l in lines) {
        final b = utf8.encode('$l\n');
        final mid = b.length ~/ 2;
        yield Uint8List.fromList(b.sublist(0, mid));
        yield Uint8List.fromList(b.sublist(mid));
      }
      if (abortWith != null) throw abortWith!;
    }

    return ResponseBody(gen(), 200, headers: {
      'content-type': ['application/x-ndjson']
    });
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  test('NDJSON 每行一个完整对象，content 逐段产出', () {
    final chunks = feed([
      '{"message":{"role":"assistant","content":"看 "},"done":false}',
      '{"message":{"role":"assistant","content":"端口"},"done":false}',
      '{"message":{"role":"assistant","content":""},"done":true,"prompt_eval_count":30,"eval_count":8}',
    ]);

    expect(chunks.whereType<TextDelta>().map((c) => c.text).toList(),
        equals(['看 ', '端口']));
    final done = chunks.last as StreamDone;
    expect(done.response.text, equals('看 端口'));
    expect(done.response.usage.inputTokens, equals(30));
    expect(done.response.usage.outputTokens, equals(8));
    // Ollama 没有缓存概念
    expect(done.response.usage.cachedTokens, equals(0));
  });

  test('tool_calls 整块到达，args 是对象，id 按出现顺序合成', () {
    final chunks = feed([
      '{"message":{"role":"assistant","content":"","tool_calls":[{"function":{"name":"bash","arguments":{"command":"uptime"}}}]},"done":false}',
      '{"message":{"role":"assistant","content":"","tool_calls":[{"function":{"name":"read_file","arguments":{"path":"/etc/os-release"}}}]},"done":false}',
      '{"message":{"role":"assistant","content":""},"done":true}',
    ]);

    final calls = (chunks.last as StreamDone).response.toolCalls;
    expect(calls.map((c) => c.id).toList(),
        equals(['ollama_call_0', 'ollama_call_1']));
    expect(calls[0].args['command'], equals('uptime'));
    expect(calls[1].args['path'], equals('/etc/os-release'));
    // 每个 tool call 到达时就该产出 ToolCallReady（args 本来就是完整的）
    expect(chunks.whereType<ToolCallReady>().length, equals(2));
  });

  test('服务端自带 id 时用它，不覆盖成合成 id', () {
    final chunks = feed([
      '{"message":{"content":"","tool_calls":[{"id":"real_id","function":{"name":"bash","arguments":{"command":"ls"}}}]},"done":false}',
      '{"message":{"content":""},"done":true}',
    ]);

    expect((chunks.last as StreamDone).response.toolCalls.single.id,
        equals('real_id'));
  });

  test('空行与坏 JSON 被跳过', () {
    final chunks = feed([
      '',
      'not json',
      '{"message":{"content":"ok"},"done":false}',
      '{"message":{"content":""},"done":true}',
    ]);

    expect((chunks.last as StreamDone).response.text, equals('ok'));
  });

  test('done 之前流断掉，finish 补出 StreamDone', () {
    final chunks = feed([
      '{"message":{"content":"partial"},"done":false}',
    ]);

    expect(chunks.last, isA<StreamDone>());
    expect((chunks.last as StreamDone).response.text, equals('partial'));
  });

  test('completeWithToolsStream 走 NDJSON，请求体带 stream/keep_alive/tools，'
      '中文按字节切断也能拼回', () async {
    final adapter = _StreamAdapter([
      jsonEncode({
        'message': {'role': 'assistant', 'content': '查一下中文日志'},
        'done': false,
      }),
      jsonEncode({
        'message': {'role': 'assistant', 'content': ''},
        'done': true,
        'prompt_eval_count': 30,
        'eval_count': 8,
      }),
    ]);
    final dio = Dio()..httpClientAdapter = adapter;
    final p = OllamaProvider(model: 'qwen3', baseUrl: 'http://x', dio: dio);

    final chunks = await p
        .completeWithToolsStream(
            [const AIMessage(role: 'user', content: 'hi')], leanToolSpecs)
        .toList();

    expect(adapter.captured!['stream'], isTrue);
    expect(adapter.captured!['keep_alive'], equals('30m'));
    expect((adapter.captured!['tools'] as List).isNotEmpty, isTrue);
    // 分片切断多字节字符后仍要拼回原文
    expect((chunks.last as StreamDone).response.text, equals('查一下中文日志'));
  });

  group('流在收尾阶段被掐断', () {
    const abort = HttpException('Connection closed while receiving data');

    Future<List<AgentChunk>> run(_StreamAdapter a) =>
        OllamaProvider(
                model: 'qwen3',
                baseUrl: 'http://x',
                dio: Dio()..httpClientAdapter = a)
            .completeWithToolsStream(
                [const AIMessage(role: 'user', content: 'hi')], leanToolSpecs)
            .toList();

    test('done:true 已到、连接随后才断：不抛，StreamDone 仍只有一个', () async {
      final chunks = await run(_StreamAdapter([
        jsonEncode({
          'message': {'role': 'assistant', 'content': '说完了'},
          'done': false,
        }),
        jsonEncode({
          'message': {'role': 'assistant', 'content': ''},
          'done': true,
          'prompt_eval_count': 30,
          'eval_count': 8,
        }),
      ], abortWith: abort));

      expect(chunks.whereType<StreamDone>().length, equals(1));
      expect((chunks.last as StreamDone).response.text, equals('说完了'));
      expect((chunks.last as StreamDone).response.usage.outputTokens, equals(8));
    });

    test('正文中途就断（没有 done:true）：照旧抛', () {
      expect(
        run(_StreamAdapter([
          jsonEncode({
            'message': {'role': 'assistant', 'content': '说到一半'},
            'done': false,
          }),
        ], abortWith: abort)),
        throwsA(isA<HttpException>()),
      );
    });
  });
}
