import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/ai_message.dart';
import 'package:flyterm/ai/agent/agent_tools.dart';
import 'package:flyterm/ai/agent/tool_models.dart';
import 'package:flyterm/ai/providers/openai_provider.dart';

/// 拦截 Dio 请求，返回固定 JSON，并捕获请求体供断言。
///
/// 写法对齐仓库既有的 `test/ai/ai_providers_test.dart` 里的 `_MockAdapter`
/// —— 那份已被 4 个测试验证可用。两处**不能想当然**：
///
/// 1. 参数类型必须是 `Stream<List<int>>?`。`Stream<Uint8List>?` 是它的
///    子类型，用作 override 参数属于协变，Dart 会拒绝。
/// 2. 请求体要从 `requestStream` 读出来再 decode，**不能**用
///    `options.data` —— 到 fetch 这一层 data 已经序列化掉了。
class _FakeAdapter implements HttpClientAdapter {
  final Map<String, dynamic>? responseBody;
  final int status;
  Map<String, dynamic>? captured;

  _FakeAdapter(this.responseBody, {this.status = 200});

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<List<int>>? requestStream, Future<void>? cancelFuture) async {
    if (requestStream != null) {
      final bytes =
          await requestStream.fold<List<int>>([], (a, b) => a..addAll(b));
      captured = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    }
    final body = utf8.encode(
        jsonEncode(responseBody ?? {'error': 'model does not support tools'}));
    return ResponseBody.fromBytes(body, status, headers: {
      'content-type': ['application/json']
    });
  }

  @override
  void close({bool force = false}) {}
}

Dio _dioWith(_FakeAdapter adapter) {
  final dio = Dio();
  dio.httpClientAdapter = adapter;
  return dio;
}

void main() {
  test('supportsTools 为 true', () {
    final p = OpenAIProvider(apiKey: 'k', model: 'gpt-4o');
    expect(p.supportsTools, isTrue);
  });

  test('请求体带上 tools 声明', () async {
    final adapter = _FakeAdapter({
      'choices': [
        {'message': {'content': 'done', 'tool_calls': null}}
      ]
    });
    final p = OpenAIProvider(
        apiKey: 'k', model: 'gpt-4o', dio: _dioWith(adapter));
    await p.completeWithTools(
        [const AIMessage(role: 'user', content: 'hi')], leanToolSpecs);

    final tools = adapter.captured!['tools'] as List;
    // lean 档现在是 bash / read_file / read_terminal / ask_user 四个。
    //
    // 这条断言在 `ask_user` 加进 `leanToolSpecs` 时漏改过一次（2026-09）：
    // 改动方只跑了 `agent_tools_test` 那几个直接相关的文件，而这条计数藏在
    // provider 的测试里。**加减 leanToolSpecs 的成员时记得搜 `leanToolSpecs`
    // 的全部引用**，不只是名字里带 tools 的那个测试文件。
    expect(tools.length, equals(4));
    expect(tools[0]['type'], equals('function'));
    expect(tools[0]['function']['name'], equals('bash'));
  });

  test('解析 tool_calls，arguments 是 JSON 字符串', () async {
    final adapter = _FakeAdapter({
      'choices': [
        {
          'message': {
            'content': null,
            'tool_calls': [
              {
                'id': 'call_1',
                'type': 'function',
                'function': {
                  'name': 'bash',
                  'arguments': '{"command":"uptime","description":"check load"}'
                }
              }
            ]
          }
        }
      ]
    });
    final p = OpenAIProvider(
        apiKey: 'k', model: 'gpt-4o', dio: _dioWith(adapter));
    final r = await p.completeWithTools(
        [const AIMessage(role: 'user', content: 'hi')], leanToolSpecs);

    expect(r.hasToolCalls, isTrue);
    expect(r.toolCalls.single.id, equals('call_1'));
    expect(r.toolCalls.single.args['command'], equals('uptime'));
    expect(r.text, isEmpty);
  });

  test('assistant 的 toolCalls 被正确编码进请求', () async {
    final adapter = _FakeAdapter({
      'choices': [
        {'message': {'content': 'ok'}}
      ]
    });
    final p = OpenAIProvider(
        apiKey: 'k', model: 'gpt-4o', dio: _dioWith(adapter));
    await p.completeWithTools([
      const AIMessage(role: 'user', content: 'hi'),
      const AIMessage(role: 'assistant', content: '', toolCalls: [
        ToolCall(id: 'c1', name: 'bash', args: {'command': 'ls'})
      ]),
      const AIMessage(role: 'tool', content: '', toolResults: [
        ToolResult(callId: 'c1', content: 'file.txt')
      ]),
    ], leanToolSpecs);

    final msgs = adapter.captured!['messages'] as List;
    expect(msgs[1]['tool_calls'][0]['id'], equals('c1'));
    expect(msgs[1]['tool_calls'][0]['function']['arguments'],
        equals('{"command":"ls"}'));
    expect(msgs[2]['role'], equals('tool'));
    expect(msgs[2]['tool_call_id'], equals('c1'));
    expect(msgs[2]['content'], equals('file.txt'));
  });

  test('401 走 _friendlyError，不是原始 DioException', () async {
    // 这个 status 参数也让 _FakeAdapter 的可选参数不再是未使用的
    final adapter = _FakeAdapter(null, status: 401);
    final p = OpenAIProvider(
        apiKey: 'bad', model: 'gpt-4o', dio: _dioWith(adapter));

    await expectLater(
      p.completeWithTools(
          [const AIMessage(role: 'user', content: 'hi')], leanToolSpecs),
      throwsA(predicate((e) =>
          e is Exception && e.toString().contains('API Key'))),
    );
  });

  test('多个 toolResults 拆成多条 tool 消息', () async {
    final adapter = _FakeAdapter({
      'choices': [
        {'message': {'content': 'ok'}}
      ]
    });
    final p = OpenAIProvider(
        apiKey: 'k', model: 'gpt-4o', dio: _dioWith(adapter));
    await p.completeWithTools([
      const AIMessage(role: 'tool', content: '', toolResults: [
        ToolResult(callId: 'c1', content: 'a'),
        ToolResult(callId: 'c2', content: 'b'),
      ]),
    ], leanToolSpecs);

    final msgs = adapter.captured!['messages'] as List;
    expect(msgs.length, equals(2));
    expect(msgs[0]['tool_call_id'], equals('c1'));
    expect(msgs[1]['tool_call_id'], equals('c2'));
  });

  test('usage: prompt_tokens 减去 cached_tokens 才是全价输入', () async {
    final adapter = _FakeAdapter({
      'choices': [
        {'message': {'content': 'ok'}}
      ],
      'usage': {
        'prompt_tokens': 5000,
        'completion_tokens': 120,
        'prompt_tokens_details': {'cached_tokens': 4608},
      },
    });
    final p = OpenAIProvider(
        apiKey: 'k', model: 'gpt-4o', dio: _dioWith(adapter));
    final r = await p.completeWithTools(
        [const AIMessage(role: 'user', content: 'hi')], leanToolSpecs);

    expect(r.usage.cachedTokens, equals(4608));
    // 5000 - 4608，不是 5000 —— 否则和 Anthropic 的口径差一个数量级
    expect(r.usage.inputTokens, equals(392));
    expect(r.usage.outputTokens, equals(120));
    expect(r.usage.totalInput, equals(5000));
  });

  test('usage 整段缺失时不抛，按全零处理', () async {
    final adapter = _FakeAdapter({
      'choices': [
        {'message': {'content': 'ok'}}
      ],
    });
    final p = OpenAIProvider(
        apiKey: 'k', model: 'gpt-4o', dio: _dioWith(adapter));
    final r = await p.completeWithTools(
        [const AIMessage(role: 'user', content: 'hi')], leanToolSpecs);
    expect(r.usage.isEmpty, isTrue);
  });

  test('cached_tokens 比 prompt_tokens 还大时钳到 0，不出负数', () async {
    final adapter = _FakeAdapter({
      'choices': [
        {'message': {'content': 'ok'}}
      ],
      'usage': {
        'prompt_tokens': 100,
        'prompt_tokens_details': {'cached_tokens': 400},
      },
    });
    final p = OpenAIProvider(
        apiKey: 'k', model: 'gpt-4o', dio: _dioWith(adapter));
    final r = await p.completeWithTools(
        [const AIMessage(role: 'user', content: 'hi')], leanToolSpecs);
    expect(r.usage.inputTokens, equals(0));
  });

  test('usage 字段是数字字符串时不抛，正文正常解析（回归：as num? 会在此抛 TypeError，'
      '第三方 OpenAI 兼容代理常把数字序列化成字符串）', () async {
    final adapter = _FakeAdapter({
      'choices': [
        {'message': {'content': 'ok'}}
      ],
      'usage': {
        'prompt_tokens': '5000',
        'completion_tokens': '120',
      },
    });
    final p = OpenAIProvider(
        apiKey: 'k', model: 'gpt-4o', dio: _dioWith(adapter));
    final r = await p.completeWithTools(
        [const AIMessage(role: 'user', content: 'hi')], leanToolSpecs);

    // 比「没抛」更重要：证明正文没有被 usage 字段的问题连累。
    expect(r.text, equals('ok'));
    expect(r.usage.inputTokens, equals(5000));
    expect(r.usage.outputTokens, equals(120));
  });

  test('usage 字段是非数字字符串时不抛，按 0 处理，正文正常解析', () async {
    final adapter = _FakeAdapter({
      'choices': [
        {'message': {'content': 'ok'}}
      ],
      'usage': {
        'prompt_tokens': 'lots',
      },
    });
    final p = OpenAIProvider(
        apiKey: 'k', model: 'gpt-4o', dio: _dioWith(adapter));
    final r = await p.completeWithTools(
        [const AIMessage(role: 'user', content: 'hi')], leanToolSpecs);

    expect(r.text, equals('ok'));
    expect(r.usage.inputTokens, equals(0));
  });
}
