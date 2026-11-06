import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/ai_message.dart';
import 'package:flyterm/ai/agent/agent_tools.dart';
import 'package:flyterm/ai/providers/openai_provider.dart';

/// 记下每次请求的 body 与 headers。写法基于
/// `test/ai/agent/openai_strict_test.dart` 的 `_SeqAdapter`，多记一份
/// headers —— affinity 走的是 header 而不是 body。
class _CaptureAdapter implements HttpClientAdapter {
  final List<Map<String, dynamic>> bodies = [];
  final List<Map<String, List<String>>> headers = [];

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<List<int>>? requestStream, Future<void>? cancelFuture) async {
    if (requestStream != null) {
      final bytes =
          await requestStream.fold<List<int>>([], (a, b) => a..addAll(b));
      bodies.add(jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>);
    }
    headers.add({
      for (final e in options.headers.entries)
        e.key.toLowerCase(): [e.value.toString()]
    });

    Stream<Uint8List> gen() async* {
      yield Uint8List.fromList(utf8.encode(
          'data: {"choices":[{"delta":{"content":"hi"}}]}\n\ndata: [DONE]\n\n'));
    }

    return ResponseBody(gen(), 200, headers: {
      'content-type': ['text/event-stream']
    });
  }

  @override
  void close({bool force = false}) {}
}

/// 形参取基类类型，好让其他 adapter 也能共用这一个 helper。
Dio _dioWith(HttpClientAdapter a) => Dio()..httpClientAdapter = a;

/// 按调用序号给出不同响应，并记下每次的 body —— 降级路径要断言
/// 「第一次 400、第二次少了哪个字段」。
class _SeqAdapter implements HttpClientAdapter {
  final List<int> statuses;

  /// 200 响应的形态。非流式路径（`completeWithTools`）解析的是
  /// `choices[0].message`，喂 SSE 给它会解析失败。
  final bool json;

  final List<Map<String, dynamic>> bodies = [];
  final List<Map<String, List<String>>> headers = [];
  int _i = 0;

  _SeqAdapter(this.statuses, {this.json = false});

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<List<int>>? requestStream, Future<void>? cancelFuture) async {
    if (requestStream != null) {
      final bytes =
          await requestStream.fold<List<int>>([], (a, b) => a..addAll(b));
      bodies.add(jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>);
    }
    headers.add({
      for (final e in options.headers.entries)
        e.key.toLowerCase(): [e.value.toString()]
    });
    final status = statuses[_i < statuses.length ? _i : statuses.length - 1];
    _i++;

    if (status != 200) {
      return ResponseBody.fromBytes(
          utf8.encode(jsonEncode({'error': {'message': 'bad request'}})), status,
          headers: {'content-type': ['application/json']});
    }

    if (json) {
      return ResponseBody.fromBytes(
          utf8.encode(jsonEncode({
            'choices': [
              {'message': {'content': 'hi'}}
            ]
          })),
          200,
          headers: {'content-type': ['application/json']});
    }

    Stream<Uint8List> gen() async* {
      yield Uint8List.fromList(utf8.encode(
          'data: {"choices":[{"delta":{"content":"hi"}}]}\n\ndata: [DONE]\n\n'));
    }

    return ResponseBody(gen(), 200, headers: {
      'content-type': ['text/event-stream']
    });
  }

  @override
  void close({bool force = false}) {}
}

const _history = <AIMessage>[
  AIMessage(role: 'system', content: 'SYS'),
  AIMessage(role: 'user', content: 'hello'),
];

void main() {
  test('传 sessionKey 时 body 带 prompt_cache_key，header 带两个 affinity 字段',
      () async {
    final a = _CaptureAdapter();
    final p = OpenAIProvider(apiKey: 'k', model: 'gpt-5', dio: _dioWith(a));

    await p
        .completeWithToolsStream(_history, leanToolSpecs, sessionKey: 'sess-42')
        .toList();

    expect(a.bodies[0]['prompt_cache_key'], 'sess-42');
    expect(a.headers[0]['x-client-request-id'], ['sess-42']);
    expect(a.headers[0]['x-session-affinity'], ['sess-42']);
  });

  /// 这条防的是「给所有存量用户改了请求形状」——不传 sessionKey 的调用方
  /// （非 agent 补全、ollama 路径）必须和改动前逐字节相同。
  test('不传 sessionKey 时 body 无该字段、header 无 affinity', () async {
    final a = _CaptureAdapter();
    final p = OpenAIProvider(apiKey: 'k', model: 'gpt-5', dio: _dioWith(a));

    await p.completeWithToolsStream(_history, leanToolSpecs).toList();

    expect(a.bodies[0].containsKey('prompt_cache_key'), isFalse);
    expect(a.headers[0].containsKey('x-client-request-id'), isFalse);
    expect(a.headers[0].containsKey('x-session-affinity'), isFalse);
  });

  test('超过 64 字符被截断 —— OpenAI 对该字段的上限', () async {
    final a = _CaptureAdapter();
    final p = OpenAIProvider(apiKey: 'k', model: 'gpt-5', dio: _dioWith(a));
    final long = 'x' * 100;

    await p
        .completeWithToolsStream(_history, leanToolSpecs, sessionKey: long)
        .toList();

    expect(a.bodies[0]['prompt_cache_key'], 'x' * 64);
  });

  test('OpenRouter 端点换用 x-session-id', () async {
    final a = _CaptureAdapter();
    final p = OpenAIProvider(
      apiKey: 'k',
      model: 'gpt-5',
      baseUrl: 'https://openrouter.ai/api/v1',
      dio: _dioWith(a),
    );

    await p
        .completeWithToolsStream(_history, leanToolSpecs, sessionKey: 'sess-42')
        .toList();

    expect(a.headers[0]['x-session-id'], ['sess-42']);
    expect(a.headers[0].containsKey('x-session-affinity'), isFalse);
  });

  test('非流式路径同样带上', () async {
    final a = _CaptureAdapter();
    final p = OpenAIProvider(apiKey: 'k', model: 'gpt-5', dio: _dioWith(a));

    // 非流式返回的是 JSON，_CaptureAdapter 给的是 SSE —— 解析会失败，
    // 但请求体在那之前就已经被记下了，断言不受影响。
    try {
      await p.completeWithTools(_history, leanToolSpecs, sessionKey: 'sess-7');
    } catch (_) {}

    expect(a.bodies[0]['prompt_cache_key'], 'sess-7');
    expect(a.headers[0]['x-client-request-id'], ['sess-7']);
  });

  /// 阶梯顺序：新引入的 prompt_cache_key 先背锅，strict 是已经实测验证过
  /// 的功能，不该被一个刚加的字段牵连着一起关掉。
  test('首次 400 只关 prompt_cache_key，strict 留着', () async {
    final a = _SeqAdapter([400, 200]);
    final p = OpenAIProvider(apiKey: 'k', model: 'gpt-5', dio: _dioWith(a));

    await p
        .completeWithToolsStream(_history, leanToolSpecs, sessionKey: 'sess-42')
        .toList();

    expect(a.bodies, hasLength(2));
    expect(a.bodies[0]['prompt_cache_key'], 'sess-42');
    expect(a.bodies[1].containsKey('prompt_cache_key'), isFalse);
    // strict 仍在：tools 里第一个函数还带着 strict 标记。
    expect((a.bodies[1]['tools'] as List).first['function']['strict'], isTrue);
  });

  test('连续两次 400 才关 strict', () async {
    final a = _SeqAdapter([400, 400, 200]);
    final p = OpenAIProvider(apiKey: 'k', model: 'gpt-5', dio: _dioWith(a));

    await p
        .completeWithToolsStream(_history, leanToolSpecs, sessionKey: 'sess-42')
        .toList();

    expect(a.bodies, hasLength(3));
    expect(a.bodies[2].containsKey('prompt_cache_key'), isFalse);
    expect((a.bodies[2]['tools'] as List).first['function']
        .containsKey('strict'), isFalse);
  });

  /// 两个标志都是粘性的 —— 不粘住的话每轮都要先撞一次 400 再重试，
  /// 请求数直接翻倍，一个省时的优化反而变成两倍开销。
  test('降级是粘性的：第二轮直接不带 prompt_cache_key', () async {
    final a = _SeqAdapter([400, 200, 200]);
    final p = OpenAIProvider(apiKey: 'k', model: 'gpt-5', dio: _dioWith(a));

    await p
        .completeWithToolsStream(_history, leanToolSpecs, sessionKey: 'sess-42')
        .toList();
    await p
        .completeWithToolsStream(_history, leanToolSpecs, sessionKey: 'sess-42')
        .toList();

    expect(a.bodies, hasLength(3));
    expect(a.bodies[2].containsKey('prompt_cache_key'), isFalse);
  });

  /// 没传 sessionKey 时请求里本来就没有那个字段，把它算进阶梯等于白白
  /// 多撞一次 400。存量调用方的行为必须与改动前完全一致：最多两次请求。
  test('不传 sessionKey 时阶梯退化成单级 —— 400 直接关 strict', () async {
    final a = _SeqAdapter([400, 200]);
    final p = OpenAIProvider(apiKey: 'k', model: 'gpt-5', dio: _dioWith(a));

    await p.completeWithToolsStream(_history, leanToolSpecs).toList();

    expect(a.bodies, hasLength(2));
    expect((a.bodies[1]['tools'] as List).first['function']
        .containsKey('strict'), isFalse);
  });

  /// header 不参与降级阶梯 —— 未知 header 在 HTTP 上是明确无害的，会引发
  /// 400 的只有 body 里那个字段。这条断言把那个设计决定钉死：降级只该拿掉
  /// body 的 prompt_cache_key，两个 affinity header 要原样留着。
  ///
  /// 防的是「重试路径上手滑漏传 headers」——四个请求点是手工重复的，
  /// 这类错误从 diff 里几乎看不出来。
  test('降级重试仍带 affinity header，只有 body 的 cache key 被拿掉', () async {
    final a = _SeqAdapter([400, 200]);
    final p = OpenAIProvider(apiKey: 'k', model: 'gpt-5', dio: _dioWith(a));

    await p
        .completeWithToolsStream(_history, leanToolSpecs, sessionKey: 'sess-42')
        .toList();

    expect(a.bodies, hasLength(2));
    expect(a.bodies[1].containsKey('prompt_cache_key'), isFalse);
    expect(a.headers[1]['x-client-request-id'], ['sess-42']);
    expect(a.headers[1]['x-session-affinity'], ['sess-42']);
  });

  /// 非流式路径是另一处手写的 `_postWithDowngrade` 调用，`sentCacheKey`
  /// 与 `bodyOf` 里的 `_cacheKeyDisabled` 判断都是独立复制的一份。流式那
  /// 四条用例保证不了这一条——这里必须各测各的。
  test('非流式路径同样是两级阶梯：首次 400 只关 prompt_cache_key', () async {
    final a = _SeqAdapter([400, 200], json: true);
    final p = OpenAIProvider(apiKey: 'k', model: 'gpt-5', dio: _dioWith(a));

    await p.completeWithTools(_history, leanToolSpecs, sessionKey: 'sess-42');

    expect(a.bodies, hasLength(2));
    expect(a.bodies[0]['prompt_cache_key'], 'sess-42');
    expect(a.bodies[1].containsKey('prompt_cache_key'), isFalse);
    expect((a.bodies[1]['tools'] as List).first['function']['strict'], isTrue);
  });
}
