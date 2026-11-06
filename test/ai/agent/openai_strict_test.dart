import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/ai_message.dart';
import 'package:flyterm/ai/agent/agent_tools.dart';
import 'package:flyterm/ai/agent/tool_models.dart';
import 'package:flyterm/ai/providers/openai_provider.dart';

/// 一个响应「步骤」：要么是普通 JSON 响应（可能带错误状态码），要么是一段
/// SSE 行流（用于流式成功响应）。
class _Step {
  final int status;
  final Map<String, dynamic>? jsonBody;
  final List<String>? sseLines;

  _Step.json(this.jsonBody)
      : status = 200,
        sseLines = null;
  _Step.sse(this.sseLines)
      : status = 200,
        jsonBody = null;
  _Step.error(this.status, [Map<String, dynamic>? body])
      : jsonBody = body ?? {'error': {'message': 'bad request'}},
        sseLines = null;
}

/// 按调用顺序依次返回 [steps] 里的响应，并把每次请求体都记下来。
///
/// 写法基于 `openai_tools_test.dart` 的 `_FakeAdapter` 与
/// `openai_stream_test.dart` 的 `_StreamAdapter`——不同处只在于它按调用
/// 序号返回不同的响应，这是断言「第一次 400、第二次 200」「第二次请求体
/// 里没有 strict」所必需的：单响应的 fake adapter 做不到。
class _SeqAdapter implements HttpClientAdapter {
  final List<_Step> steps;
  final List<Map<String, dynamic>> captured = [];
  int _i = 0;

  _SeqAdapter(this.steps);

  int get callCount => captured.length;

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<List<int>>? requestStream, Future<void>? cancelFuture) async {
    if (requestStream != null) {
      final bytes =
          await requestStream.fold<List<int>>([], (a, b) => a..addAll(b));
      captured.add(jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>);
    }
    final step = steps[_i < steps.length ? _i : steps.length - 1];
    _i++;

    if (step.sseLines != null) {
      Stream<Uint8List> gen() async* {
        for (final l in step.sseLines!) {
          yield Uint8List.fromList(utf8.encode('$l\n'));
        }
      }

      return ResponseBody(gen(), step.status, headers: {
        'content-type': ['text/event-stream']
      });
    }

    final body = utf8.encode(jsonEncode(step.jsonBody));
    return ResponseBody.fromBytes(body, step.status, headers: {
      'content-type': ['application/json']
    });
  }

  @override
  void close({bool force = false}) {}
}

Dio _dioWith(_SeqAdapter adapter) {
  final dio = Dio();
  dio.httpClientAdapter = adapter;
  return dio;
}

const _okJson = {
  'choices': [
    {'message': {'content': 'ok', 'tool_calls': null}}
  ]
};

void main() {
  group('strict（非流式）', () {
    test('请求体里带 strict: true', () async {
      final adapter = _SeqAdapter([_Step.json(_okJson)]);
      final p = OpenAIProvider(apiKey: 'k', model: 'gpt-4o', dio: _dioWith(adapter));
      await p.completeWithTools(
          [const AIMessage(role: 'user', content: 'hi')], leanToolSpecs);

      final tools = adapter.captured[0]['tools'] as List;
      expect(tools[0]['function']['strict'], isTrue);
    });

    test('参数被翻译成 strict 子集', () async {
      final adapter = _SeqAdapter([_Step.json(_okJson)]);
      final p = OpenAIProvider(apiKey: 'k', model: 'gpt-4o', dio: _dioWith(adapter));
      await p.completeWithTools(
          [const AIMessage(role: 'user', content: 'hi')], leanToolSpecs);

      final tools = adapter.captured[0]['tools'] as List;
      // read_file 的 `server` 参数在共享的 ToolSpec 里是可选的（不在
      // required 里），strict 子集必须把它翻成 nullable，且整体带上
      // additionalProperties: false。
      final readFile =
          tools.firstWhere((t) => t['function']['name'] == 'read_file');
      final params = readFile['function']['parameters'] as Map;
      final props = params['properties'] as Map;
      expect(props['server']['type'], ['string', 'null']);
      expect(params['additionalProperties'], isFalse);
      expect((params['required'] as List), contains('server'));
    });

    test('400 之后关掉 strict 重试一次，第二次请求里没有 strict', () async {
      final adapter =
          _SeqAdapter([_Step.error(400), _Step.json(_okJson)]);
      final p = OpenAIProvider(apiKey: 'k', model: 'gpt-4o', dio: _dioWith(adapter));
      final r = await p.completeWithTools(
          [const AIMessage(role: 'user', content: 'hi')], leanToolSpecs);

      expect(r.text, equals('ok'));
      expect(adapter.callCount, equals(2));
      final firstTools = adapter.captured[0]['tools'] as List;
      final secondTools = adapter.captured[1]['tools'] as List;
      expect(firstTools[0]['function'].containsKey('strict'), isTrue);
      expect(secondTools[0]['function'].containsKey('strict'), isFalse);
    });

    test('降级粘住 —— 之后的请求都不带 strict', () async {
      final adapter = _SeqAdapter(
          [_Step.error(400), _Step.json(_okJson), _Step.json(_okJson)]);
      final p = OpenAIProvider(apiKey: 'k', model: 'gpt-4o', dio: _dioWith(adapter));

      // 第一轮：撞 400，降级重试成功。
      await p.completeWithTools(
          [const AIMessage(role: 'user', content: 'hi')], leanToolSpecs);
      // 第二轮：同一个 provider 实例再发一次。
      await p.completeWithTools(
          [const AIMessage(role: 'user', content: 'hi again')], leanToolSpecs);

      expect(adapter.callCount, equals(3));
      final thirdTools = adapter.captured[2]['tools'] as List;
      expect(thirdTools[0]['function'].containsKey('strict'), isFalse);
    });

    test('重试之后仍然 400 → 照常抛错', () async {
      final adapter = _SeqAdapter([_Step.error(400), _Step.error(400)]);
      final p = OpenAIProvider(apiKey: 'k', model: 'gpt-4o', dio: _dioWith(adapter));

      await expectLater(
        p.completeWithTools(
            [const AIMessage(role: 'user', content: 'hi')], leanToolSpecs),
        throwsA(isA<Exception>()),
      );
      expect(adapter.callCount, equals(2));
    });
  });

  group('strict（流式，agent 的主路径）', () {
    test('流式请求体里也带 strict', () async {
      final adapter = _SeqAdapter([
        _Step.sse([
          'data: {"choices":[{"delta":{"content":"ok"}}]}',
          'data: [DONE]',
        ])
      ]);
      final p = OpenAIProvider(apiKey: 'k', model: 'gpt-4o', dio: _dioWith(adapter));
      await p
          .completeWithToolsStream(
              [const AIMessage(role: 'user', content: 'hi')], leanToolSpecs)
          .toList();

      final tools = adapter.captured[0]['tools'] as List;
      expect(tools[0]['function']['strict'], isTrue);
    });

    test('流式 400 之后同样降级重试，且能正常产出内容', () async {
      final adapter = _SeqAdapter([
        _Step.error(400),
        _Step.sse([
          'data: {"choices":[{"delta":{"content":"ok"}}]}',
          'data: [DONE]',
        ]),
      ]);
      final p = OpenAIProvider(apiKey: 'k', model: 'gpt-4o', dio: _dioWith(adapter));

      final chunks = await p
          .completeWithToolsStream(
              [const AIMessage(role: 'user', content: 'hi')], leanToolSpecs)
          .toList();

      expect(adapter.callCount, equals(2));
      final firstTools = adapter.captured[0]['tools'] as List;
      final secondTools = adapter.captured[1]['tools'] as List;
      expect(firstTools[0]['function'].containsKey('strict'), isTrue);
      expect(secondTools[0]['function'].containsKey('strict'), isFalse);
      expect((chunks.last as StreamDone).response.text, equals('ok'));
    });

    test('流式与非流式共享同一个 _strictDisabled', () async {
      final adapter = _SeqAdapter([
        _Step.error(400), // 非流式第一次：撞 400
        _Step.json(_okJson), // 非流式第二次：降级重试成功
        _Step.sse([
          // 流式：应当直接不带 strict，不再撞一次 400
          'data: {"choices":[{"delta":{"content":"ok"}}]}',
          'data: [DONE]',
        ]),
      ]);
      final p = OpenAIProvider(apiKey: 'k', model: 'gpt-4o', dio: _dioWith(adapter));

      await p.completeWithTools(
          [const AIMessage(role: 'user', content: 'hi')], leanToolSpecs);
      await p
          .completeWithToolsStream(
              [const AIMessage(role: 'user', content: 'hi again')],
              leanToolSpecs)
          .toList();

      expect(adapter.callCount, equals(3));
      final streamTools = adapter.captured[2]['tools'] as List;
      expect(streamTools[0]['function'].containsKey('strict'), isFalse);
    });
  });
}
