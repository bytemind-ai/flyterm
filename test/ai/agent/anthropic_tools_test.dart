import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/ai_message.dart';
import 'package:flyterm/ai/agent/agent_tools.dart';
import 'package:flyterm/ai/agent/tool_models.dart';
import 'package:flyterm/ai/providers/anthropic_provider.dart';

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
    final p = AnthropicProvider(apiKey: 'k', model: 'claude-opus-5');
    expect(p.supportsTools, isTrue);
  });

  test('tools 用 input_schema 而非 parameters', () async {
    final adapter = _FakeAdapter({
      'content': [
        {'type': 'text', 'text': 'done'}
      ]
    });
    final p = AnthropicProvider(
        apiKey: 'k', model: 'claude-opus-5', dio: _dioWith(adapter));
    await p.completeWithTools(
        [const AIMessage(role: 'user', content: 'hi')], leanToolSpecs);

    final tools = adapter.captured!['tools'] as List;
    expect(tools[0]['name'], equals('bash'));
    expect(tools[0]['input_schema'], isA<Map>());
    expect(tools[0].containsKey('parameters'), isFalse);
  });

  // 这条测试原来断言 `system` 字段等于裸字符串 —— 那是加 cache_control 之前的
  // 编码形状。`cache_control` 只能挂在 content block 上，裸字符串挂不了，
  // 所以引入 cache 断点后 `system` 恒定变成单元素 block 列表
  // `[{type: text, text: ..., cache_control: ...}]`，这是 API 层面的硬约束，
  // 不是可选的实现取舍。
  //
  // 这条测试真正要保护的不变量是行为层面的，不是编码形状：system 角色的消息
  // 被提到顶层 `system` 字段，而不是当成一条 user turn 混进 `messages`。
  // 改成断言内容（取 `system[0]['text']`）+ 断言 messages 里不出现
  // role=system 的条目，形状变了但这条不变量依然成立。
  test('system 消息走顶层 system 字段', () async {
    final adapter = _FakeAdapter({
      'content': [
        {'type': 'text', 'text': 'ok'}
      ]
    });
    final p = AnthropicProvider(
        apiKey: 'k', model: 'claude-opus-5', dio: _dioWith(adapter));
    await p.completeWithTools([
      const AIMessage(role: 'system', content: 'you are x'),
      const AIMessage(role: 'user', content: 'hi'),
    ], leanToolSpecs);

    final system = adapter.captured!['system'] as List;
    expect(system[0]['text'], equals('you are x'));
    final messages = adapter.captured!['messages'] as List;
    expect(messages.length, equals(1));
    expect(messages.any((m) => (m as Map)['role'] == 'system'), isFalse);
  });

  test('解析 tool_use block，input 是对象', () async {
    final adapter = _FakeAdapter({
      'content': [
        {'type': 'text', 'text': 'let me check'},
        {
          'type': 'tool_use',
          'id': 'toolu_1',
          'name': 'bash',
          'input': {'command': 'uptime', 'description': 'check load'}
        }
      ]
    });
    final p = AnthropicProvider(
        apiKey: 'k', model: 'claude-opus-5', dio: _dioWith(adapter));
    final r = await p.completeWithTools(
        [const AIMessage(role: 'user', content: 'hi')], leanToolSpecs);

    expect(r.text, equals('let me check'));
    expect(r.toolCalls.single.id, equals('toolu_1'));
    expect(r.toolCalls.single.args['command'], equals('uptime'));
  });

  test('assistant toolCalls 编码成 tool_use block', () async {
    final adapter = _FakeAdapter({
      'content': [
        {'type': 'text', 'text': 'ok'}
      ]
    });
    final p = AnthropicProvider(
        apiKey: 'k', model: 'claude-opus-5', dio: _dioWith(adapter));
    await p.completeWithTools([
      const AIMessage(role: 'assistant', content: 'checking', toolCalls: [
        ToolCall(id: 'c1', name: 'bash', args: {'command': 'ls'})
      ]),
    ], leanToolSpecs);

    final blocks = (adapter.captured!['messages'] as List)[0]['content'] as List;
    expect(blocks[0]['type'], equals('text'));
    expect(blocks[1]['type'], equals('tool_use'));
    expect(blocks[1]['id'], equals('c1'));
    expect(blocks[1]['input']['command'], equals('ls'));
  });

  test('401 被翻译成人话，而不是把 DioException 原样抛给界面', () async {
    // 这个 status 参数也让 _FakeAdapter 的可选参数不再是未使用的
    final adapter = _FakeAdapter(null, status: 401);
    final p = AnthropicProvider(
        apiKey: 'bad', model: 'claude-opus-5', dio: _dioWith(adapter));

    await expectLater(
      p.completeWithTools(
          [const AIMessage(role: 'user', content: 'hi')], leanToolSpecs),
      throwsA(predicate((e) =>
          e is Exception &&
          e.toString().contains('401') &&
          e.toString().contains('API Key'))),
    );
  });

  test('多个 toolResults 合并进同一个 user turn', () async {
    final adapter = _FakeAdapter({
      'content': [
        {'type': 'text', 'text': 'ok'}
      ]
    });
    final p = AnthropicProvider(
        apiKey: 'k', model: 'claude-opus-5', dio: _dioWith(adapter));
    await p.completeWithTools([
      const AIMessage(role: 'tool', content: '', toolResults: [
        ToolResult(callId: 'c1', content: 'a'),
        ToolResult(callId: 'c2', content: 'b', isError: true),
      ]),
    ], leanToolSpecs);

    final msgs = adapter.captured!['messages'] as List;
    expect(msgs.length, equals(1));
    expect(msgs[0]['role'], equals('user'));
    final blocks = msgs[0]['content'] as List;
    expect(blocks.length, equals(2));
    expect(blocks[0]['tool_use_id'], equals('c1'));
    expect(blocks[1]['is_error'], isTrue);
  });
}
