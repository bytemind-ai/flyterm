import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/providers/provider_http.dart';
import 'package:flyterm/ai/providers/anthropic_provider.dart';
import 'package:flyterm/ai/providers/openai_provider.dart';
import 'package:flyterm/ai/providers/gemini_provider.dart';
import 'package:flyterm/ai/providers/ollama_provider.dart';

void main() {
  test('idleTimeout 提到 3 分钟 —— Dart 默认的 15 秒在移动端会被打字间隔穿透',
      () {
    final dio = createProviderDio();
    final adapter = dio.httpClientAdapter as IOHttpClientAdapter;
    final client = adapter.createHttpClient!();

    expect(client.idleTimeout, const Duration(minutes: 3));
  });

  test('超时保持既有取值 —— 这次只动 idleTimeout，不顺手改别的', () {
    final dio = createProviderDio();

    expect(dio.options.connectTimeout, const Duration(seconds: 15));
    expect(dio.options.receiveTimeout, const Duration(seconds: 30));
  });

  /// 三个 provider 的超时值**并不一致**：ollama 是 60 秒（本地推理慢）。
  /// 不开这个参数的话，统一接入时会把那个有意为之的差异静默抹平，
  /// 且不会有任何报错。
  test('receiveTimeout 可覆盖 —— Ollama 的 60 秒不能被抹平', () {
    final dio = createProviderDio(receiveTimeout: const Duration(seconds: 60));

    expect(dio.options.receiveTimeout, const Duration(seconds: 60));
    expect(dio.options.connectTimeout, const Duration(seconds: 15));
  });

  /// 三个 provider 都必须走同一个工厂 —— 漏掉任何一个，那一家就还在吃
  /// 15 秒默认值，而这种遗漏不会有任何报错，只会静默地少一份收益。
  test('三个 provider 默认构造出的 Dio 都带 3 分钟 idleTimeout', () {
    Duration? idleOf(Dio dio) {
      final adapter = dio.httpClientAdapter;
      if (adapter is! IOHttpClientAdapter) return null;
      return adapter.createHttpClient!().idleTimeout;
    }

    expect(idleOf(AnthropicProvider(apiKey: 'k', model: 'm').debugDio),
        const Duration(minutes: 3));
    expect(idleOf(OpenAIProvider(apiKey: 'k', model: 'm').debugDio),
        const Duration(minutes: 3));
    expect(
        idleOf(OllamaProvider(model: 'm', baseUrl: 'http://localhost:11434')
            .debugDio),
        const Duration(minutes: 3));
  });

  test('Gemini 继承 OpenAI 的 Dio，不需要自己接工厂', () {
    final dio = GeminiProvider(apiKey: 'k', model: 'm').debugDio;
    final adapter = dio.httpClientAdapter as IOHttpClientAdapter;

    expect(adapter.createHttpClient!().idleTimeout, const Duration(minutes: 3));
  });

  /// 接工厂时最容易犯的错：三家看着一样就套同一行，把 Ollama 的 60 秒
  /// 悄悄改成 30 秒。这条回归断言就是为了让那个错误当场失败。
  test('Ollama 接入后仍是 60 秒 receiveTimeout，另两家仍是 30 秒', () {
    expect(
        OllamaProvider(model: 'm', baseUrl: 'http://localhost:11434')
            .debugDio
            .options
            .receiveTimeout,
        const Duration(seconds: 60));
    expect(
        AnthropicProvider(apiKey: 'k', model: 'm').debugDio.options
            .receiveTimeout,
        const Duration(seconds: 30));
    expect(
        OpenAIProvider(apiKey: 'k', model: 'm').debugDio.options.receiveTimeout,
        const Duration(seconds: 30));
  });

  /// 对本机必然被拒的端口发起一次连接：`connectionFactory` 在拿到 RST 之前
  /// 就会被调用，所以不需要真实网络也能验证计数确实发生。
  ///
  /// 这条是本功能的核心行为。原先那条「构造 HttpClient 后断言计数没变」
  /// 验证不了任何东西——`connectionFactory` 只在真正建连接时才触发，
  /// 不发请求的话开关开着关着计数都是 0。
  test('开启后真实发起连接会让计数 +1', () async {
    debugCountConnections = true;
    addTearDown(() => debugCountConnections = false);
    debugNewConnectionCount = 0;

    final client =
        (createProviderDio().httpClientAdapter as IOHttpClientAdapter)
            .createHttpClient!();
    try {
      final req = await client.getUrl(Uri.parse('http://127.0.0.1:1'));
      await req.close();
    } catch (_) {
      // 连不上是预期的，我们要的是 connectionFactory 被调用过这个事实。
    }

    expect(debugNewConnectionCount, 1);
  });

  /// 与上一条对照：同样的操作，开关关闭时计数不动。两条合起来才真正
  /// 区分了「装了 factory」和「没装」。
  test('关闭时同样的连接尝试不计数', () async {
    debugCountConnections = false;
    debugNewConnectionCount = 0;

    final client =
        (createProviderDio().httpClientAdapter as IOHttpClientAdapter)
            .createHttpClient!();
    try {
      final req = await client.getUrl(Uri.parse('http://127.0.0.1:1'));
      await req.close();
    } catch (_) {}

    expect(debugNewConnectionCount, 0);
  });

  test('开启后 createHttpClient 产出的 client 带 3 分钟 idleTimeout（不受影响）',
      () {
    debugCountConnections = true;
    addTearDown(() => debugCountConnections = false);

    final dio = createProviderDio();
    final adapter = dio.httpClientAdapter as IOHttpClientAdapter;

    expect(adapter.createHttpClient!().idleTimeout, const Duration(minutes: 3));
  });
}
