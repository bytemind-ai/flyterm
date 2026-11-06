import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/ai_message.dart';
import 'package:flyterm/ai/attachment.dart';
import 'package:flyterm/ai/agent/tool_models.dart';
import 'package:flyterm/ai/providers/gemini_provider.dart';
import 'package:flyterm/ai/providers/openai_provider.dart';

/// `GeminiProvider extends OpenAIProvider`，**一行协议代码都没有** —— 请求体
/// 拼装、SSE 解析、tool call 的流式累积、图片 data URI 全部继承。
///
/// 这是有意的耦合（见 `gemini_provider.dart` 的类注释）：兼容层在协议层面
/// 就是 OpenAI 格式，两者本该一起演进。代价是**父类重构可以静默破坏 Gemini**
/// —— 编译通过、其他测试全绿，只有真机上 Gemini 不工作。
///
/// 这个文件把「继承来的能力」逐条钉住：不是断言 `isA<OpenAIProvider>()`
/// （那是实现细节），而是**让 Gemini 真的跑一遍那些协议路径**，断言产出。
class _CapturingAdapter implements HttpClientAdapter {
  _CapturingAdapter({this.json, this.lines});

  final Map<String, dynamic>? json;
  final List<String>? lines;

  Map<String, dynamic>? capturedBody;
  Map<String, dynamic>? capturedHeaders;
  String? capturedPath;

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<List<int>>? requestStream, Future<void>? cancelFuture) async {
    capturedPath = options.path;
    capturedHeaders = options.headers.cast<String, dynamic>();
    if (requestStream != null) {
      final bytes =
          await requestStream.fold<List<int>>([], (a, b) => a..addAll(b));
      capturedBody = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    }

    if (lines != null) {
      Stream<Uint8List> gen() async* {
        for (final l in lines!) {
          yield Uint8List.fromList(utf8.encode('$l\n'));
        }
      }

      return ResponseBody(gen(), 200, headers: {
        'content-type': ['text/event-stream']
      });
    }

    return ResponseBody.fromBytes(utf8.encode(jsonEncode(json)), 200,
        headers: {
          'content-type': ['application/json']
        });
  }

  @override
  void close({bool force = false}) {}
}

GeminiProvider gemini(_CapturingAdapter a) => GeminiProvider(
      apiKey: 'AIza-test',
      model: 'gemini-2.5-flash',
      dio: Dio()..httpClientAdapter = a,
    );

void main() {
  test('非流式：走父类的请求体拼装与鉴权头', () async {
    final a = _CapturingAdapter(json: {
      'choices': [
        {
          'message': {'content': 'ok'}
        }
      ]
    });

    final r = await gemini(a).complete(const [
      AIMessage(role: 'user', content: 'hi'),
    ]);

    expect(r, equals('ok'));
    expect(a.capturedPath,
        'https://generativelanguage.googleapis.com/v1beta/openai'
        '/chat/completions');
    expect(a.capturedHeaders?['Authorization'], 'Bearer AIza-test');
    expect(a.capturedBody?['model'], 'gemini-2.5-flash');
  });

  test('流式：SSE 解析走父类（TextDelta 逐段产出）', () async {
    final a = _CapturingAdapter(lines: [
      'data: {"choices":[{"delta":{"content":"查 "}}]}',
      'data: {"choices":[{"delta":{"content":"日志"}}]}',
      'data: [DONE]',
    ]);

    final chunks = await gemini(a)
        .completeStream(const [AIMessage(role: 'user', content: 'hi')])
        .toList();

    expect(chunks.join(), equals('查 日志'));
    expect(a.capturedBody?['stream'], isTrue);
  });

  test('工具调用：请求体带 tools，响应解析走父类', () async {
    final a = _CapturingAdapter(json: {
      'choices': [
        {
          'message': {
            'content': null,
            'tool_calls': [
              {
                'id': 'c1',
                'type': 'function',
                'function': {'name': 'bash', 'arguments': '{"command":"ls"}'},
              }
            ],
          }
        }
      ]
    });

    final r = await gemini(a).completeWithTools(
      const [AIMessage(role: 'user', content: 'list files')],
      [
        const ToolSpec(
          name: 'bash',
          description: 'run',
          parameters: {'type': 'object', 'properties': <String, dynamic>{}},
        ),
      ],
    );

    expect(r.toolCalls, hasLength(1));
    expect(r.toolCalls.single.name, equals('bash'));
    expect(a.capturedBody?['tools'], isNotNull,
        reason: '父类的 tools 拼装没被继承到 Gemini');
  });

  test('图片输入：data URI 拼装走父类', () async {
    final a = _CapturingAdapter(json: {
      'choices': [
        {
          'message': {'content': 'a cat'}
        }
      ]
    });

    await gemini(a).complete([
      AIMessage(
        role: 'user',
        content: 'what is this',
        attachments: const [
          Attachment(
            kind: AttachmentKind.image,
            relPath: 's1/x.png',
            mime: 'image/png',
            bytes: 3,
            b64: 'AAEC',
          ),
        ],
      ),
    ]);

    final msgs = a.capturedBody?['messages'] as List;
    final content = (msgs.last as Map)['content'] as List;
    final imagePart = content.firstWhere(
      (p) => (p as Map)['type'] == 'image_url',
      orElse: () => <String, dynamic>{},
    ) as Map;
    expect(imagePart['image_url'], isNotNull,
        reason: '父类的图片 data URI 拼装没被继承到 Gemini');
    expect((imagePart['image_url'] as Map)['url'],
        startsWith('data:image/png;base64,'));
  });

  test('能力位是继承来的：supportsTools / supportsVision 都真', () {
    final p = GeminiProvider(apiKey: 'k', model: 'gemini-2.5-pro');
    expect(p.supportsTools, isTrue);
    expect(p.supportsVision, isTrue);
  });

  test('身份位是覆写的：providerType 必须是 gemini 而不是 openai', () {
    final p = GeminiProvider(apiKey: 'k', model: 'gemini-2.5-pro');
    expect(p.providerType, equals('gemini'),
        reason: '继承成 openai 会让设置页认不出、factory 也回不到 Gemini');
    expect(p.displayName, equals('Gemini (gemini-2.5-pro)'));
  });
}
