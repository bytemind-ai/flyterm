import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/ai_message.dart';
import 'package:flyterm/ai/agent/agent_tools.dart';
import 'package:flyterm/ai/providers/ollama_provider.dart';

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
  test('初始乐观地报告支持工具', () {
    final p = OllamaProvider(model: 'llama3.1', baseUrl: 'http://x');
    expect(p.supportsTools, isTrue);
  });

  test('arguments 是对象时正常解析', () async {
    final adapter = _FakeAdapter({
      'message': {
        'content': '',
        'tool_calls': [
          {
            'function': {
              'name': 'bash',
              'arguments': {'command': 'uptime', 'description': 'load'}
            }
          }
        ]
      }
    });
    final p = OllamaProvider(
        model: 'llama3.1', baseUrl: 'http://x', dio: _dioWith(adapter));
    final r = await p.completeWithTools(
        [const AIMessage(role: 'user', content: 'hi')], leanToolSpecs);

    expect(r.toolCalls.single.args['command'], equals('uptime'));
    expect(r.toolCalls.single.name, equals('bash'));
  });

  test('缺 id 时自动生成稳定 id', () async {
    final adapter = _FakeAdapter({
      'message': {
        'content': '',
        'tool_calls': [
          {
            'function': {'name': 'bash', 'arguments': {'command': 'a'}}
          },
          {
            'function': {'name': 'bash', 'arguments': {'command': 'b'}}
          }
        ]
      }
    });
    final p = OllamaProvider(
        model: 'llama3.1', baseUrl: 'http://x', dio: _dioWith(adapter));
    final r = await p.completeWithTools(
        [const AIMessage(role: 'user', content: 'hi')], leanToolSpecs);

    expect(r.toolCalls.length, equals(2));
    expect(r.toolCalls[0].id, isNot(equals(r.toolCalls[1].id)));
  });

  test('报错后 supportsTools 翻转为 false', () async {
    final adapter = _FakeAdapter(null, status: 400);
    final p = OllamaProvider(
        model: 'nomic-embed', baseUrl: 'http://x', dio: _dioWith(adapter));

    expect(p.supportsTools, isTrue);
    await expectLater(
      p.completeWithTools(
          [const AIMessage(role: 'user', content: 'hi')], leanToolSpecs),
      throwsA(isA<Exception>()),
    );
    expect(p.supportsTools, isFalse);
  });

  test('四条路径都带 keep_alive', () async {
    for (final call in ['complete', 'tools', 'stream', 'streamTools']) {
      final adapter = _FakeAdapter({
        'message': {'content': 'ok'},
        'done': true,
      });
      final p = OllamaProvider(
          model: 'qwen3', baseUrl: 'http://x:11434', dio: _dioWith(adapter));
      if (call == 'complete') {
        await p.complete([const AIMessage(role: 'user', content: 'hi')]);
      } else if (call == 'tools') {
        await p.completeWithTools(
            [const AIMessage(role: 'user', content: 'hi')], leanToolSpecs);
      } else if (call == 'stream') {
        // completeStream 是 Stream，必须消费一次才会真正发出请求。
        await p
            .completeStream([const AIMessage(role: 'user', content: 'hi')])
            .toList();
      } else {
        // completeWithToolsStream 同样是 Stream，必须消费一次才会真正
        // 发出请求 —— 这是新增的第四条路径（流式 tool-calling）。
        await p
            .completeWithToolsStream(
                [const AIMessage(role: 'user', content: 'hi')], leanToolSpecs)
            .toList();
      }
      expect(adapter.captured!['keep_alive'], equals('30m'),
          reason: '$call 没带 keep_alive；模型每轮重新加载是本地推理慢的主因');
    }
  });

  test('keep_alive 可由构造参数覆盖', () async {
    final adapter = _FakeAdapter({
      'message': {'content': 'ok'}
    });
    final p = OllamaProvider(
        model: 'qwen3',
        baseUrl: 'http://x:11434',
        keepAlive: '5m',
        dio: _dioWith(adapter));
    await p.completeWithTools(
        [const AIMessage(role: 'user', content: 'hi')], leanToolSpecs);
    expect(adapter.captured!['keep_alive'], equals('5m'));
  });

  test('usage 取 prompt_eval_count / eval_count，缓存恒为 0', () async {
    final adapter = _FakeAdapter({
      'message': {'content': 'ok'},
      'prompt_eval_count': 812,
      'eval_count': 44,
    });
    final p = OllamaProvider(
        model: 'qwen3', baseUrl: 'http://x:11434', dio: _dioWith(adapter));
    final r = await p.completeWithTools(
        [const AIMessage(role: 'user', content: 'hi')], leanToolSpecs);
    expect(r.usage.inputTokens, equals(812));
    expect(r.usage.outputTokens, equals(44));
    expect(r.usage.cachedTokens, equals(0));
  });

  test('usage 字段是数字字符串时不抛，正文正常解析（回归：as num? 会在此抛 TypeError，'
      '第三方 Ollama 兼容服务常把数字序列化成字符串）', () async {
    final adapter = _FakeAdapter({
      'message': {'content': 'ok'},
      'prompt_eval_count': '812',
      'eval_count': '44',
    });
    final p = OllamaProvider(
        model: 'qwen3', baseUrl: 'http://x:11434', dio: _dioWith(adapter));
    final r = await p.completeWithTools(
        [const AIMessage(role: 'user', content: 'hi')], leanToolSpecs);

    // 比「没抛」更重要：证明正文没有被 usage 字段的问题连累。
    expect(r.text, equals('ok'));
    expect(r.usage.inputTokens, equals(812));
    expect(r.usage.outputTokens, equals(44));
  });

  test('usage 字段是非数字字符串时不抛，按 0 处理，正文正常解析', () async {
    final adapter = _FakeAdapter({
      'message': {'content': 'ok'},
      'prompt_eval_count': 'lots',
    });
    final p = OllamaProvider(
        model: 'qwen3', baseUrl: 'http://x:11434', dio: _dioWith(adapter));
    final r = await p.completeWithTools(
        [const AIMessage(role: 'user', content: 'hi')], leanToolSpecs);

    expect(r.text, equals('ok'));
    expect(r.usage.inputTokens, equals(0));
  });
}
