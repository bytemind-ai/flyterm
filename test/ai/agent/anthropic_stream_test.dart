import 'dart:convert';
import 'dart:io' show HttpException;
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/agent/tool_models.dart';
import 'package:flyterm/ai/ai_message.dart';
import 'package:flyterm/ai/agent/agent_tools.dart';
import 'package:flyterm/ai/providers/anthropic_provider.dart';

/// 把一串 SSE 行喂给解析器，收集产出的 chunk。
List<AgentChunk> feed(List<String> lines) {
  final parser = AnthropicToolStreamParser();
  final out = <AgentChunk>[];
  for (final l in lines) {
    out.addAll(parser.acceptLine(l));
  }
  out.addAll(parser.finish());
  return out;
}

/// 造一条流式响应。`ResponseBody.fromStream` 要的是 `Stream<Uint8List>`。
class _StreamAdapter implements HttpClientAdapter {
  final List<String> sseLines;

  /// 非 null = 所有行发完之后让流以这个错误结束，模拟服务端/中间链路不发
  /// chunked 终止块就关掉连接。
  final Object? abortWith;

  Map<String, dynamic>? captured;

  _StreamAdapter(this.sseLines, {this.abortWith});

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<List<int>>? requestStream, Future<void>? cancelFuture) async {
    if (requestStream != null) {
      final bytes =
          await requestStream.fold<List<int>>([], (a, b) => a..addAll(b));
      captured = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    }
    // 刻意把每行切成两个字节块发出，逼出「多字节字符被分片切断」的情况 ——
    // 这正是 String.fromCharCodes 会出错、utf8.decode 才对的场景。
    Stream<Uint8List> gen() async* {
      for (final line in sseLines) {
        final bytes = utf8.encode('$line\n');
        final mid = bytes.length ~/ 2;
        yield Uint8List.fromList(bytes.sublist(0, mid));
        yield Uint8List.fromList(bytes.sublist(mid));
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
  test('text_delta 逐段产出 TextDelta', () {
    final chunks = feed([
      'data: {"type":"message_start","message":{"usage":{"input_tokens":12,"cache_read_input_tokens":4}}}',
      'data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}',
      'data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"查一下 "}}',
      'data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"nginx"}}',
      'data: {"type":"content_block_stop","index":0}',
      'data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":7}}',
      'data: {"type":"message_stop"}',
    ]);

    expect(chunks.whereType<TextDelta>().map((c) => c.text).toList(),
        equals(['查一下 ', 'nginx']));

    final done = chunks.last as StreamDone;
    expect(done.response.text, equals('查一下 nginx'));
    expect(done.response.usage.inputTokens, equals(12));
    expect(done.response.usage.cachedTokens, equals(4));
    expect(done.response.usage.outputTokens, equals(7));
  });

  test('input_json_delta 跨片段拼接，content_block_stop 时才产出 ToolCallReady', () {
    final chunks = feed([
      'data: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_1","name":"bash","input":{}}}',
      'data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\\"command\\":\\"systemctl"}}',
      'data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":" status nginx\\"}"}}',
      // stop 之前不该有任何 ToolCallReady —— 参数还没拼完，执行会用到半个 JSON
      'data: {"type":"content_block_stop","index":0}',
      'data: {"type":"message_stop"}',
    ]);

    final ready = chunks.whereType<ToolCallReady>().toList();
    expect(ready.length, equals(1));
    expect(ready.single.call.id, equals('toolu_1'));
    expect(ready.single.call.name, equals('bash'));
    expect(ready.single.call.args['command'], equals('systemctl status nginx'));

    // ToolCallReady 必须出现在 StreamDone 之前
    expect(chunks.indexOf(ready.single) < chunks.length - 1, isTrue);
    expect((chunks.last as StreamDone).response.toolCalls.length, equals(1));
  });

  test('同一轮两个 tool_use 按 index 各自累积，不串参数', () {
    final chunks = feed([
      'data: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"a","name":"bash","input":{}}}',
      'data: {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"b","name":"read_file","input":{}}}',
      'data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\\"path\\":\\"/etc/hosts\\"}"}}',
      'data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\\"command\\":\\"ls\\"}"}}',
      'data: {"type":"content_block_stop","index":1}',
      'data: {"type":"content_block_stop","index":0}',
      'data: {"type":"message_stop"}',
    ]);

    final calls = (chunks.last as StreamDone).response.toolCalls;
    expect(calls.map((c) => c.id).toList(), equals(['a', 'b']));
    expect(calls.firstWhere((c) => c.id == 'a').args['command'], equals('ls'));
    expect(calls.firstWhere((c) => c.id == 'b').args['path'],
        equals('/etc/hosts'));
  });

  test('参数是坏 JSON / 被截断时丢弃该调用，不发半成品', () {
    final chunks = feed([
      'data: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"x","name":"bash","input":{}}}',
      'data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{not json"}}',
      'data: {"type":"content_block_stop","index":0}',
      'data: {"type":"message_stop"}',
    ]);

    // 这条断言现在才有判别力。在「统一为丢弃」修好之前，两条完全不同的
    // 路径会给出相同的表面结果：
    //   - 事件解析成功，但 partial_json 缓冲的是坏 JSON `'{not json'`
    //     （本用例真正要测的路径）
    //   - 整行被解析器静默丢弃（比如夹具本身缺闭合括号导致 jsonDecode 抛
    //     异常），缓冲从未被写入，是空字符串
    // 两者喂给 parseToolArgs 都会返回空 map，`args isEmpty` 分不清楚。
    // 现在两条路径的产出不再相同：真正丢弃时（本用例）不产出
    // ToolCallReady 且 StreamDone.toolCalls 为空；如果是整行被丢弃这个
    // bug，isTruncatedToolArgs('') 判为 false，会产出 ToolCallReady(args={})。
    expect(chunks.whereType<ToolCallReady>(), isEmpty);
    expect((chunks.last as StreamDone).response.toolCalls, isEmpty);
  });

  test('非 data 行与无法解析的行被跳过', () {
    final chunks = feed([
      'event: content_block_delta',
      '',
      'data: not-json-at-all',
      'data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}',
      'data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"ok"}}',
      'data: {"type":"message_stop"}',
    ]);

    expect((chunks.last as StreamDone).response.text, equals('ok'));
  });

  test('流在 message_stop 之前断掉，finish 仍补出 StreamDone', () {
    final chunks = feed([
      'data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}',
      'data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"half"}}',
    ]);

    expect(chunks.last, isA<StreamDone>());
    expect((chunks.last as StreamDone).response.text, equals('half'));
  });

  test('message_stop 之后到达的数据不产出任何 chunk，StreamDone 仍是唯一且最后的元素', () {
    final chunks = feed([
      'data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}',
      'data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"ok"}}',
      'data: {"type":"message_stop"}',
      // 模拟兼容代理在 message_stop 之后仍发数据（keep-alive、自定义
      // 事件）。真实 Anthropic API 不会这样，但中间的网关会。
      'data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"迟到的文本"}}',
      'data: {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"late","name":"bash","input":{}}}',
      'data: {"type":"content_block_stop","index":1}',
    ]);

    expect(chunks.last, isA<StreamDone>());
    expect(chunks.whereType<StreamDone>().length, equals(1));
    expect((chunks.last as StreamDone).response.text, equals('ok'));
    expect((chunks.last as StreamDone).response.toolCalls, isEmpty);
  });

  test('completeWithToolsStream 走 SSE，请求体带 stream:true 与 tools', () async {
    final adapter = _StreamAdapter([
      'data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}',
      'data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"中文也要对"}}',
      'data: {"type":"message_stop"}',
    ]);
    final dio = Dio()..httpClientAdapter = adapter;
    final p =
        AnthropicProvider(apiKey: 'k', model: 'claude-opus-5', dio: dio);

    final chunks = await p
        .completeWithToolsStream(
            [const AIMessage(role: 'user', content: 'hi')], leanToolSpecs)
        .toList();

    expect(adapter.captured!['stream'], isTrue);
    expect((adapter.captured!['tools'] as List).isNotEmpty, isTrue);
    // 分片切断多字节字符后仍要拼回原文
    expect((chunks.last as StreamDone).response.text, equals('中文也要对'));
  });

  group('流在收尾阶段被掐断', () {
    const abort = HttpException('Connection closed while receiving data');

    Future<List<AgentChunk>> run(_StreamAdapter a) =>
        AnthropicProvider(
                apiKey: 'k',
                model: 'claude-opus-5',
                dio: Dio()..httpClientAdapter = a)
            .completeWithToolsStream(
                [const AIMessage(role: 'user', content: 'hi')], leanToolSpecs)
            .toList();

    test('message_stop 已到、连接随后才断：不抛，StreamDone 仍只有一个', () async {
      final chunks = await run(_StreamAdapter([
        'data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"说完了"}}',
        'data: {"type":"message_stop"}',
      ], abortWith: abort));

      expect(chunks.whereType<StreamDone>().length, equals(1));
      expect((chunks.last as StreamDone).response.text, equals('说完了'));
    });

    test('正文中途就断（没有 message_stop）：照旧抛', () {
      expect(
        run(_StreamAdapter([
          'data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"说到一半"}}',
        ], abortWith: abort)),
        throwsA(isA<HttpException>()),
      );
    });
  });
}
