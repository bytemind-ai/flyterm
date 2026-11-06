import 'dart:convert';
import 'dart:io' show HttpException;
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/ai_message.dart';
import 'package:flyterm/ai/agent/agent_tools.dart';
import 'package:flyterm/ai/agent/tool_models.dart';
import 'package:flyterm/ai/providers/openai_provider.dart';

List<AgentChunk> feed(List<String> lines) {
  final parser = OpenAIToolStreamParser();
  final out = <AgentChunk>[];
  for (final l in lines) {
    out.addAll(parser.acceptLine(l));
  }
  out.addAll(parser.finish());
  return out;
}

class _StreamAdapter implements HttpClientAdapter {
  final List<String> lines;

  /// 非 null = 所有行发完之后让流以这个错误结束，模拟服务端/中间链路不发
  /// chunked 终止块就关掉连接（dart:io 此时抛的正是 `HttpException`）。
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
      'content-type': ['text/event-stream']
    });
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  test('content delta 逐段产出 TextDelta', () {
    final chunks = feed([
      'data: {"choices":[{"delta":{"content":"查 "}}]}',
      'data: {"choices":[{"delta":{"content":"日志"}}]}',
      'data: [DONE]',
    ]);

    expect(chunks.whereType<TextDelta>().map((c) => c.text).toList(),
        equals(['查 ', '日志']));
    expect((chunks.last as StreamDone).response.text, equals('查 日志'));
  });

  test('tool_calls 的 arguments 按 index 累加，[DONE] 时定稿', () {
    final chunks = feed([
      'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"bash","arguments":""}}]}}]}',
      'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\\"command\\":\\"ss"}}]}}]}',
      'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":" -ltnp\\"}"}}]}}]}',
      'data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}',
      'data: [DONE]',
    ]);

    final ready = chunks.whereType<ToolCallReady>().toList();
    expect(ready.length, equals(1));
    expect(ready.single.call.id, equals('call_1'));
    expect(ready.single.call.name, equals('bash'));
    expect(ready.single.call.args['command'], equals('ss -ltnp'));
  });

  test('两个 tool_call 各按自己的 index 累加，name 只在首片出现也不丢', () {
    final chunks = feed([
      'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"a","function":{"name":"bash","arguments":"{\\"command\\":\\"ls\\"}"}}]}}]}',
      'data: {"choices":[{"delta":{"tool_calls":[{"index":1,"id":"b","function":{"name":"read_file","arguments":"{\\"path\\":"}}]}}]}',
      'data: {"choices":[{"delta":{"tool_calls":[{"index":1,"function":{"arguments":"\\"/etc/hosts\\"}"}}]}}]}',
      'data: [DONE]',
    ]);

    final calls = (chunks.last as StreamDone).response.toolCalls;
    expect(calls.map((c) => c.name).toList(), equals(['bash', 'read_file']));
    expect(calls[1].args['path'], equals('/etc/hosts'));
  });

  test('[DONE] 之后不再产出任何 chunk，StreamDone 只有一个', () {
    final chunks = feed([
      'data: {"choices":[{"delta":{"content":"x"}}]}',
      'data: [DONE]',
      'data: {"choices":[{"delta":{"content":"这行来晚了"}}]}',
    ]);

    expect(chunks.whereType<StreamDone>().length, equals(1));
    expect((chunks.last as StreamDone).response.text, equals('x'));
  });

  test('tool_call 首片后流断掉（没等到 [DONE]），finish 时按截断丢弃，不发半成品', () {
    final chunks = feed([
      'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"bash","arguments":"{\\"command\\":\\"htop"}}]}}]}',
    ]);

    expect(chunks.whereType<ToolCallReady>(), isEmpty);
    expect((chunks.last as StreamDone).response.toolCalls, isEmpty);
  });

  test('usage 从 stream_options 带回的末块里取，prompt 减去 cached', () {
    final chunks = feed([
      'data: {"choices":[],"usage":{"prompt_tokens":100,"completion_tokens":20,"prompt_tokens_details":{"cached_tokens":40}}}',
      'data: [DONE]',
    ]);

    final u = (chunks.last as StreamDone).response.usage;
    expect(u.inputTokens, equals(60));
    expect(u.cachedTokens, equals(40));
    expect(u.outputTokens, equals(20));
  });

  test('completeWithToolsStream 请求体带 stream 与 stream_options', () async {
    final adapter = _StreamAdapter([
      'data: {"choices":[{"delta":{"content":"ok"}}]}',
      'data: [DONE]',
    ]);
    final dio = Dio()..httpClientAdapter = adapter;
    final p = OpenAIProvider(apiKey: 'k', model: 'gpt-5', dio: dio);

    final chunks = await p
        .completeWithToolsStream(
            [const AIMessage(role: 'user', content: 'hi')], leanToolSpecs)
        .toList();

    expect(adapter.captured!['stream'], isTrue);
    expect(adapter.captured!['stream_options'],
        equals({'include_usage': true}));
    expect((chunks.last as StreamDone).response.text, equals('ok'));
  });

  group('流在收尾阶段被掐断', () {
    /// 真机上看到的那条：正文全部到齐、模型已经说完，连接才在收尾时断掉。
    /// 2026-09-14 gmi-serving 上复现，用户看到一段完整回答 + 一个红色错误
    /// 气泡，且本轮 usage 归零。
    const abort = HttpException('Connection closed while receiving data');

    OpenAIProvider providerOn(_StreamAdapter a) =>
        OpenAIProvider(apiKey: 'k', model: 'gpt-5', dio: Dio()..httpClientAdapter = a);

    Future<List<AgentChunk>> run(OpenAIProvider p) => p
        .completeWithToolsStream(
            [const AIMessage(role: 'user', content: 'hi')], leanToolSpecs)
        .toList();

    test('finish_reason 已到、[DONE] 没等到：按正常收尾，不抛', () async {
      final chunks = await run(providerOn(_StreamAdapter([
        'data: {"choices":[{"delta":{"content":"说完了"}}]}',
        'data: {"choices":[{"delta":{},"finish_reason":"stop"}]}',
      ], abortWith: abort)));

      expect((chunks.last as StreamDone).response.text, equals('说完了'));
    });

    test('[DONE] 已到、连接随后才断：StreamDone 仍只有一个，不抛', () async {
      final chunks = await run(providerOn(_StreamAdapter([
        'data: {"choices":[{"delta":{"content":"说完了"}}]}',
        'data: {"choices":[{"delta":{},"finish_reason":"stop"}]}',
        'data: {"choices":[],"usage":{"prompt_tokens":100,"completion_tokens":20}}',
        'data: [DONE]',
      ], abortWith: abort)));

      expect(chunks.whereType<StreamDone>().length, equals(1));
      expect((chunks.last as StreamDone).response.usage.outputTokens, equals(20));
    });

    test('正文中途就断（没有 finish_reason）：照旧抛，不许假装说完了', () async {
      // 这条是给上面两条兜底的：吞掉传输错误的条件必须是「模型说完了」，
      // 不能退化成「一律吞掉」——那会把真正的半截回答伪装成正常结束。
      expect(
        run(providerOn(_StreamAdapter([
          'data: {"choices":[{"delta":{"content":"说到一半"}}]}',
        ], abortWith: abort))),
        throwsA(isA<HttpException>()),
      );
    });
  });
}
