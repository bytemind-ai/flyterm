import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/ai_message.dart';
import 'package:flyterm/ai/providers/openai_provider.dart';

/// 按指定状态码 + 响应体作答的适配器。
///
/// 与 `openai_tools_test.dart` 里的 `_FakeAdapter` 同源，多一个 [headers]
/// —— 429 的 `Retry-After` 要从响应头读。
class _ErrorAdapter implements HttpClientAdapter {
  final int status;
  final Object? body;
  final Map<String, List<String>> extraHeaders;

  _ErrorAdapter(this.status, {this.body, this.extraHeaders = const {}});

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<List<int>>? requestStream, Future<void>? cancelFuture) async {
    if (requestStream != null) {
      await requestStream.fold<List<int>>([], (a, b) => a..addAll(b));
    }
    final encoded = body is String
        ? utf8.encode(body as String)
        : utf8.encode(jsonEncode(body ?? const {}));
    return ResponseBody.fromBytes(encoded, status, headers: {
      'content-type': [body is String ? 'text/plain' : 'application/json'],
      ...extraHeaders,
    });
  }

  @override
  void close({bool force = false}) {}
}

OpenAIProvider _providerWith(_ErrorAdapter adapter) {
  final dio = Dio();
  dio.httpClientAdapter = adapter;
  return OpenAIProvider(apiKey: 'k', model: 'gpt-4o', dio: dio);
}

/// 跑一次非流式带工具的请求，返回抛出来的那条消息。
Future<String> _errorFrom(_ErrorAdapter adapter) async {
  final p = _providerWith(adapter);
  try {
    await p.completeWithTools(
      const [AIMessage(role: 'user', content: 'hi')],
      const [],
    );
  } catch (e) {
    return e.toString();
  }
  fail('该请求本应抛出');
}

void main() {
  group('429 有专门的文案', () {
    test('不再泄漏 Dio 的开发者说明', () async {
      final msg = await _errorFrom(_ErrorAdapter(429));

      expect(msg, contains('429'));
      expect(msg, contains('请求过于频繁或额度用尽'));

      // 这几段是 Dio 对「状态码不合法」的内部说明。它此前会被原样塞进
      // 终止横幅糊满整个手机屏幕，而且它对 429 的解释是错的 —— 429 不是
      // 「bad syntax」，是限流。
      expect(msg, isNot(contains('validateStatus')));
      expect(msg, isNot(contains('bad syntax')));
      expect(msg, isNot(contains('developer.mozilla.org')));
    });

    test('有 Retry-After 时说出具体秒数', () async {
      final msg = await _errorFrom(_ErrorAdapter(429, extraHeaders: {
        'retry-after': ['30']
      }));

      expect(msg, contains('请 30 秒后重试'));
    });

    test('没有 Retry-After 时退回「请稍后再试」', () async {
      final msg = await _errorFrom(_ErrorAdapter(429));

      expect(msg, contains('请稍后再试'));
    });

    test('带上服务端给的原话 —— 它比我们编的准', () async {
      final msg = await _errorFrom(_ErrorAdapter(429, body: {
        'error': {'message': 'You exceeded your current quota'}
      }));

      expect(msg, contains('You exceeded your current quota'));
    });
  });

  group('兜底分支同样不泄漏 Dio 内部说明', () {
    test('5xx', () async {
      final msg = await _errorFrom(_ErrorAdapter(500));

      expect(msg, contains('500'));
      expect(msg, isNot(contains('validateStatus')));
      expect(msg, isNot(contains('RequestOptions')));
    });

    test('5xx 也带上服务端原话', () async {
      final msg = await _errorFrom(_ErrorAdapter(503, body: {
        'error': {'message': 'upstream model overloaded'}
      }));

      expect(msg, contains('upstream model overloaded'));
    });

    test('纯文本错误体也认', () async {
      final msg = await _errorFrom(_ErrorAdapter(502, body: 'bad gateway'));

      expect(msg, contains('bad gateway'));
    });

    test('超长响应体不贴出来 —— 多半是 HTML 错误页，贴了只会刷屏', () async {
      final msg = await _errorFrom(
          _ErrorAdapter(502, body: '<html>${'x' * 500}</html>'));

      expect(msg, contains('502'));
      expect(msg.length, lessThan(120));
    });
  });

  group('既有分支没被改坏', () {
    test('401', () async {
      expect(await _errorFrom(_ErrorAdapter(401)),
          contains('API Key 无效或已过期'));
    });

    test('403', () async {
      expect(await _errorFrom(_ErrorAdapter(403)), contains('无权限访问该模型'));
    });

    test('404 仍然点名 Base URL —— 那是这个错最常见的成因', () async {
      final msg = await _errorFrom(_ErrorAdapter(404));
      expect(msg, contains('Base URL'));
      expect(msg, contains('/v1'));
    });
  });
}
