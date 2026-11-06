import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/ai_message.dart';
import 'package:flyterm/ai/agent/agent_tools.dart';
import 'package:flyterm/ai/agent/tool_models.dart';
import 'package:flyterm/ai/providers/anthropic_provider.dart';

/// 与 anthropic_tools_test.dart 的 `_FakeAdapter` 同构，但**按序**给出多个
/// 响应并记下每一次的请求体 —— 降级路径要断言「第二次请求里没有标记」。
class _SeqAdapter implements HttpClientAdapter {
  final List<({int status, Map<String, dynamic> body})> responses;
  final List<Map<String, dynamic>> captured = [];
  int _i = 0;

  _SeqAdapter(this.responses);

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<List<int>>? requestStream, Future<void>? cancelFuture) async {
    if (requestStream != null) {
      final bytes =
          await requestStream.fold<List<int>>([], (a, b) => a..addAll(b));
      captured.add(jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>);
    }
    final r = responses[_i < responses.length ? _i : responses.length - 1];
    _i++;
    return ResponseBody.fromBytes(utf8.encode(jsonEncode(r.body)), r.status,
        headers: {'content-type': ['application/json']});
  }

  @override
  void close({bool force = false}) {}
}

Dio _dioWith(HttpClientAdapter a) => Dio()..httpClientAdapter = a;

const _okBody = {
  'content': [
    {'type': 'text', 'text': 'done'}
  ]
};

/// 三轮对话的历史：user / assistant+tool_use / tool 结果。
/// `_buildToolMessages` 会把它变成 3 个 message。
final _history = <AIMessage>[
  const AIMessage(role: 'system', content: 'SYS'),
  const AIMessage(role: 'user', content: 'why is nginx down'),
  const AIMessage(
    role: 'assistant',
    content: 'checking',
    toolCalls: [ToolCall(id: 'c1', name: 'bash', args: {'command': 'x'})],
  ),
  const AIMessage(
    role: 'tool',
    content: '',
    toolResults: [ToolResult(callId: 'c1', content: 'exit 0')],
  ),
];

void main() {
  test('system 变成带 cache_control 的 block 列表', () async {
    final a = _SeqAdapter([(status: 200, body: _okBody)]);
    final p = AnthropicProvider(
        apiKey: 'k', model: 'claude-opus-5', dio: _dioWith(a));
    await p.completeWithTools(_history, leanToolSpecs);

    final sys = a.captured[0]['system'] as List;
    expect(sys, hasLength(1));
    expect(sys[0]['text'], equals('SYS'));
    expect(sys[0]['cache_control'], equals({'type': 'ephemeral'}));
  });

  test('cache_control 打在 tools 的最后一项，不是第一项', () async {
    final a = _SeqAdapter([(status: 200, body: _okBody)]);
    final p = AnthropicProvider(
        apiKey: 'k', model: 'claude-opus-5', dio: _dioWith(a));
    await p.completeWithTools(_history, leanToolSpecs);

    final tools = a.captured[0]['tools'] as List;
    expect(tools.length, greaterThan(1));
    expect(tools.last['cache_control'], equals({'type': 'ephemeral'}));
    // 位置错了缓存就不覆盖后面的工具定义 —— 必须显式排除前面的项
    for (final t in tools.sublist(0, tools.length - 1)) {
      expect((t as Map).containsKey('cache_control'), isFalse,
          reason: '只有最后一项能带标记，前面的项带上等于白付缓存写入');
    }
  });

  test('cache_control 打在 messages 的倒数第二条，不是最后一条', () async {
    final a = _SeqAdapter([(status: 200, body: _okBody)]);
    final p = AnthropicProvider(
        apiKey: 'k', model: 'claude-opus-5', dio: _dioWith(a));
    await p.completeWithTools(_history, leanToolSpecs);

    final msgs = a.captured[0]['messages'] as List;
    expect(msgs, hasLength(3));

    // 倒数第二条（assistant + tool_use）的**最后一个 block** 上有标记
    final marked = (msgs[1]['content'] as List).last as Map;
    expect(marked['cache_control'], equals({'type': 'ephemeral'}),
        reason: '标记必须落在倒数第二条上：最后一条是本轮新增的 tool 结果，'
            '标它等于每轮写一份新缓存、一次都命中不了');

    // 最后一条不能有
    final lastBlocks = msgs[2]['content'] as List;
    for (final b in lastBlocks) {
      expect((b as Map).containsKey('cache_control'), isFalse);
    }
    // 倒数第二条的非末尾 block 也不能有
    final middleBlocks = msgs[1]['content'] as List;
    for (final b in middleBlocks.sublist(0, middleBlocks.length - 1)) {
      expect((b as Map).containsKey('cache_control'), isFalse);
    }
  });

  test('只有一条消息时不打消息断点（没有倒数第二条）', () async {
    final a = _SeqAdapter([(status: 200, body: _okBody)]);
    final p = AnthropicProvider(
        apiKey: 'k', model: 'claude-opus-5', dio: _dioWith(a));
    await p.completeWithTools(
        [const AIMessage(role: 'user', content: 'hi')], leanToolSpecs);

    final msgs = a.captured[0]['messages'] as List;
    expect(msgs, hasLength(1));
    // content 仍是裸字符串，没被展开成 block
    expect(msgs[0]['content'], equals('hi'));
  });

  test('字符串 content 的消息被标记时展开成 text block', () async {
    final a = _SeqAdapter([(status: 200, body: _okBody)]);
    final p = AnthropicProvider(
        apiKey: 'k', model: 'claude-opus-5', dio: _dioWith(a));
    await p.completeWithTools([
      const AIMessage(role: 'user', content: 'first'),
      const AIMessage(role: 'assistant', content: 'second'),
    ], leanToolSpecs);

    final msgs = a.captured[0]['messages'] as List;
    final marked = msgs[0]['content'];
    expect(marked, isA<List>());
    expect((marked as List)[0]['type'], equals('text'));
    expect(marked[0]['text'], equals('first'));
    expect(marked[0]['cache_control'], equals({'type': 'ephemeral'}));
  });

  test('400 之后去掉标记重试一次，且不再报错', () async {
    final a = _SeqAdapter([
      (status: 400, body: {'error': {'message': 'cache_control not supported'}}),
      (status: 200, body: _okBody),
    ]);
    final p = AnthropicProvider(
        apiKey: 'k', model: 'claude-opus-5', dio: _dioWith(a));
    final r = await p.completeWithTools(_history, leanToolSpecs);

    expect(r.text, equals('done'));
    expect(a.captured, hasLength(2));
    // 第二次请求：system 回到裸字符串，tools 与 messages 里一个标记都没有
    expect(a.captured[1]['system'], equals('SYS'));
    final json2 = jsonEncode(a.captured[1]);
    expect(json2.contains('cache_control'), isFalse,
        reason: '降级请求必须彻底干净，否则重试也会被同一个原因拒掉');
  });

  test('降级是粘住的：第二次调用直接不带标记', () async {
    final a = _SeqAdapter([
      (status: 400, body: {'error': 'nope'}),
      (status: 200, body: _okBody),
      (status: 200, body: _okBody),
    ]);
    final p = AnthropicProvider(
        apiKey: 'k', model: 'claude-opus-5', dio: _dioWith(a));
    await p.completeWithTools(_history, leanToolSpecs);
    await p.completeWithTools(_history, leanToolSpecs);

    expect(a.captured, hasLength(3));
    expect(jsonEncode(a.captured[2]).contains('cache_control'), isFalse,
        reason: '每轮都先撞一次 400 再重试等于把请求数翻倍');
  });

  test('降级后仍然失败时报出真实错误，不吞', () async {
    final a = _SeqAdapter([
      (status: 400, body: {'error': 'bad model'}),
      (status: 401, body: {'error': 'bad key'}),
    ]);
    final p = AnthropicProvider(
        apiKey: 'k', model: 'claude-opus-5', dio: _dioWith(a));
    await expectLater(
      p.completeWithTools(_history, leanToolSpecs),
      throwsA(predicate((e) => e.toString().contains('401'))),
    );
  });

  test('非 400 的错误不触发降级重试', () async {
    final a = _SeqAdapter([
      (status: 429, body: {'error': 'slow down'}),
      (status: 200, body: _okBody),
    ]);
    final p = AnthropicProvider(
        apiKey: 'k', model: 'claude-opus-5', dio: _dioWith(a));
    await expectLater(
      p.completeWithTools(_history, leanToolSpecs),
      throwsA(predicate((e) => e.toString().contains('429'))),
    );
    expect(a.captured, hasLength(1), reason: '429 是限流，重试只会加剧');
  });

  test('usage: cache_read 单列，cache_creation 并入全价', () async {
    final a = _SeqAdapter([
      (status: 200, body: {
        'content': [
          {'type': 'text', 'text': 'done'}
        ],
        'usage': {
          'input_tokens': 300,
          'cache_creation_input_tokens': 1200,
          'cache_read_input_tokens': 8000,
          'output_tokens': 90,
        },
      }),
    ]);
    final p = AnthropicProvider(
        apiKey: 'k', model: 'claude-opus-5', dio: _dioWith(a));
    final r = await p.completeWithTools(_history, leanToolSpecs);

    expect(r.usage.cachedTokens, equals(8000));
    expect(r.usage.inputTokens, equals(1500)); // 300 + 1200
    expect(r.usage.outputTokens, equals(90));
  });

  test('usage 字段是数字字符串时不抛，正文正常解析（回归：as num? 会在此抛 TypeError，'
      '第三方 Anthropic 兼容代理常把数字序列化成字符串）', () async {
    final a = _SeqAdapter([
      (status: 200, body: {
        'content': [
          {'type': 'text', 'text': 'done'}
        ],
        'usage': {
          'input_tokens': '300',
          'cache_read_input_tokens': '8000',
          'output_tokens': '90',
        },
      }),
    ]);
    final p = AnthropicProvider(
        apiKey: 'k', model: 'claude-opus-5', dio: _dioWith(a));
    final r = await p.completeWithTools(_history, leanToolSpecs);

    // 比「没抛」更重要：证明正文没有被 usage 字段的问题连累。
    expect(r.text, equals('done'));
    expect(r.usage.inputTokens, equals(300));
    expect(r.usage.cachedTokens, equals(8000));
    expect(r.usage.outputTokens, equals(90));
  });

  test('usage 字段是非数字字符串时不抛，按 0 处理，正文正常解析', () async {
    final a = _SeqAdapter([
      (status: 200, body: {
        'content': [
          {'type': 'text', 'text': 'done'}
        ],
        'usage': {
          'input_tokens': 'lots',
        },
      }),
    ]);
    final p = AnthropicProvider(
        apiKey: 'k', model: 'claude-opus-5', dio: _dioWith(a));
    final r = await p.completeWithTools(_history, leanToolSpecs);

    expect(r.text, equals('done'));
    expect(r.usage.inputTokens, equals(0));
  });
}
