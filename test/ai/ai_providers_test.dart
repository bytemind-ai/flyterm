import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/ai_message.dart';
import 'package:flyterm/ai/providers/openai_provider.dart';
import 'package:flyterm/ai/providers/anthropic_provider.dart';
import 'package:flyterm/ai/providers/ollama_provider.dart';
import 'package:flyterm/ai/ai_provider.dart';
import 'package:flyterm/ai/providers/gemini_provider.dart';
import 'package:flyterm/data/models/ai_provider_config.dart';

/// Intercepts Dio requests and returns a fixed JSON response.
class _MockAdapter implements HttpClientAdapter {
  String? capturedPath;
  Map<String, dynamic>? capturedHeaders;
  Map<String, dynamic>? capturedBody;
  final Map<String, dynamic> response;

  _MockAdapter(this.response);

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<List<int>>? requestStream,
      Future<void>? cancelFuture) async {
    capturedPath = options.path;
    capturedHeaders = options.headers.cast<String, dynamic>();
    if (requestStream != null) {
      final bytes = await requestStream
          .fold<List<int>>([], (a, b) => a..addAll(b));
      capturedBody =
          jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    }
    final body = utf8.encode(jsonEncode(response));
    return ResponseBody.fromBytes(body, 200,
        headers: {
          'content-type': ['application/json']
        });
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  test('OpenAIProvider complete returns content', () async {
    final adapter = _MockAdapter({
      'choices': [
        {
          'message': {'content': 'Use ls -la'}
        }
      ]
    });
    final dio = Dio()..httpClientAdapter = adapter;
    final provider =
        OpenAIProvider(apiKey: 'sk-test', model: 'gpt-4o', dio: dio);
    final result = await provider.complete([
      const AIMessage(role: 'user', content: 'how to list hidden files?'),
    ]);
    expect(result, 'Use ls -la');
    expect(adapter.capturedPath, contains('/chat/completions'));
    expect(adapter.capturedHeaders?['Authorization'], 'Bearer sk-test');
    expect(adapter.capturedBody?['model'], 'gpt-4o');
  });

  test('OpenAIProvider respects custom baseUrl', () async {
    final adapter = _MockAdapter({
      'choices': [
        {
          'message': {'content': 'ok'}
        }
      ]
    });
    final dio = Dio()..httpClientAdapter = adapter;
    final provider = OpenAIProvider(
        apiKey: 'key',
        model: 'gpt-4',
        baseUrl: 'https://proxy.example.com/v1',
        dio: dio);
    await provider
        .complete([const AIMessage(role: 'user', content: 'hi')]);
    expect(adapter.capturedPath,
        'https://proxy.example.com/v1/chat/completions');
  });

  test('AnthropicProvider complete returns content', () async {
    final adapter = _MockAdapter({
      'content': [
        {'text': 'Use grep -r'}
      ]
    });
    final dio = Dio()..httpClientAdapter = adapter;
    final provider = AnthropicProvider(
        apiKey: 'ant-test',
        model: 'claude-3-5-sonnet-20241022',
        dio: dio);
    final result = await provider.complete([
      const AIMessage(role: 'user', content: 'search in files'),
    ]);
    expect(result, 'Use grep -r');
    expect(adapter.capturedHeaders?['x-api-key'], 'ant-test');
    expect(adapter.capturedHeaders?['anthropic-version'], '2023-06-01');
  });

  test('OllamaProvider sends to correct endpoint', () async {
    final adapter = _MockAdapter({
      'message': {'content': 'ollama says hi'}
    });
    final dio = Dio()..httpClientAdapter = adapter;
    final provider = OllamaProvider(
        model: 'llama3', baseUrl: 'http://localhost:11434', dio: dio);
    final result = await provider.complete([
      const AIMessage(role: 'user', content: 'hello'),
    ]);
    expect(result, 'ollama says hi');
    expect(adapter.capturedPath, 'http://localhost:11434/api/chat');
    expect(adapter.capturedBody?['stream'], false);
  });

  test('GeminiProvider 默认打官方兼容端点', () async {
    final adapter = _MockAdapter({
      'choices': [
        {
          'message': {'content': 'pong'}
        }
      ]
    });
    final dio = Dio()..httpClientAdapter = adapter;
    final provider = GeminiProvider(
        apiKey: 'AIza-test', model: 'gemini-2.5-flash', dio: dio);
    final result = await provider.complete([
      const AIMessage(role: 'user', content: 'ping'),
    ]);
    expect(result, 'pong');
    expect(
        adapter.capturedPath,
        'https://generativelanguage.googleapis.com/v1beta/openai'
        '/chat/completions');
    // 兼容层的认证头与 OpenAI 相同 —— Google 文档对切换的描述是「只改三行」：
    // key、baseUrl、model，认证方式不在其中。
    expect(adapter.capturedHeaders?['Authorization'], 'Bearer AIza-test');
    expect(adapter.capturedBody?['model'], 'gemini-2.5-flash');
  });

  test('GeminiProvider 自定义 baseUrl 覆盖默认值', () async {
    // 反代场景：generativelanguage.googleapis.com 在很多网络下不可直达。
    final adapter = _MockAdapter({
      'choices': [
        {
          'message': {'content': 'ok'}
        }
      ]
    });
    final dio = Dio()..httpClientAdapter = adapter;
    final provider = GeminiProvider(
        apiKey: 'k',
        model: 'gemini-2.5-pro',
        baseUrl: 'https://gemini-proxy.example.com/v1beta/openai',
        dio: dio);
    await provider.complete([const AIMessage(role: 'user', content: 'hi')]);
    expect(adapter.capturedPath,
        'https://gemini-proxy.example.com/v1beta/openai/chat/completions');
  });

  test('GeminiProvider 的身份与继承来的能力', () {
    final p = GeminiProvider(apiKey: 'k', model: 'gemini-2.5-pro');
    expect(p.providerType, 'gemini');
    expect(p.displayName, 'Gemini (gemini-2.5-pro)');
    // 从 OpenAIProvider 继承，不需要自己声明。
    expect(p.supportsTools, isTrue);
    expect(p.supportsVision, isTrue);
  });

  test('factory 对 type gemini 造出 GeminiProvider', () {
    final p = AIProviderFactory.create(
      const AIProviderConfig(
        id: 'g1',
        name: 'My Gemini',
        type: 'gemini',
        model: 'gemini-2.5-flash',
      ),
      'AIza-key',
    );
    expect(p, isA<GeminiProvider>());
    expect(p.providerType, 'gemini');
  });

  test('GeminiProvider 纯空白 baseUrl 回退到默认端点', () async {
    final adapter = _MockAdapter({
      'choices': [
        {
          'message': {'content': 'ok'}
        }
      ]
    });
    final dio = Dio()..httpClientAdapter = adapter;
    final provider = GeminiProvider(
        apiKey: 'k', model: 'gemini-2.5-flash', baseUrl: '   ', dio: dio);
    await provider.complete([const AIMessage(role: 'user', content: 'hi')]);
    expect(
        adapter.capturedPath,
        'https://generativelanguage.googleapis.com/v1beta/openai'
        '/chat/completions');
  });

  test('AnthropicProvider 自定义 baseUrl 生效', () async {
    final adapter = _MockAdapter({
      'content': [
        {'text': 'ok'}
      ]
    });
    final dio = Dio()..httpClientAdapter = adapter;
    final provider = AnthropicProvider(
        apiKey: 'ant',
        model: 'claude-3-5-sonnet-20241022',
        baseUrl: 'https://ant-proxy.example.com/v1',
        dio: dio);
    await provider.complete([const AIMessage(role: 'user', content: 'hi')]);
    expect(
        adapter.capturedPath, 'https://ant-proxy.example.com/v1/messages');
  });

  test('AnthropicProvider 不填 baseUrl 时仍打官方端点', () async {
    // 回归保护：这是四处硬编码替换后最容易悄悄改坏的行为。
    final adapter = _MockAdapter({
      'content': [
        {'text': 'ok'}
      ]
    });
    final dio = Dio()..httpClientAdapter = adapter;
    final provider = AnthropicProvider(
        apiKey: 'ant', model: 'claude-3-5-sonnet-20241022', dio: dio);
    await provider.complete([const AIMessage(role: 'user', content: 'hi')]);
    expect(adapter.capturedPath, 'https://api.anthropic.com/v1/messages');
  });

  test('AnthropicProvider completeWithTools（_postAgent 路径）也走自定义 baseUrl', () async {
    // complete() 那条只覆盖了 4 处硬编码 '$baseUrl/messages' 里的 1 处。
    // _postAgent 是 aipanel 实际最常走的路径（带工具的那条），单独锁住。
    final adapter = _MockAdapter({
      'content': [
        {'type': 'text', 'text': 'ok'}
      ],
      'usage': {'input_tokens': 1, 'output_tokens': 1}
    });
    final dio = Dio()..httpClientAdapter = adapter;
    final provider = AnthropicProvider(
        apiKey: 'ant',
        model: 'claude-3-5-sonnet-20241022',
        baseUrl: 'https://ant-proxy.example.com/v1',
        dio: dio);
    final result = await provider.completeWithTools(
      [const AIMessage(role: 'user', content: 'hi')],
      const [],
    );
    expect(result.text, 'ok');
    expect(adapter.capturedPath,
        'https://ant-proxy.example.com/v1/messages');
  });
}
