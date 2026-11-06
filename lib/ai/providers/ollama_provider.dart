// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import '../ai_provider.dart';
import '../attachment.dart';
import '../agent/tool_models.dart';
import 'provider_http.dart';

/// 把历史拼成 Ollama 的 messages 数组。
///
/// **格式与另两家不同**：图片不是 content 数组的元素，而是消息级的 `images`
/// 字符串数组，`content` 仍然是纯文本。所以三家的拼装无法共享。
@visibleForTesting
List<Map<String, dynamic>> buildOllamaMessages(List<AIMessage> history) {
  return [
    for (final m in history)
      {
        'role': m.role,
        'content': m.content,
        if (_imageB64s(m).isNotEmpty) 'images': _imageB64s(m),
      },
  ];
}

List<String> _imageB64s(AIMessage m) => (m.attachments ?? const [])
    .where((a) => a.kind == AttachmentKind.image && a.b64 != null)
    .map((a) => a.b64!)
    .toList();

/// 把 Ollama 的 NDJSON 行流解析成 [AgentChunk]。
///
/// 与两家 SSE 的差异大到不能共用：**没有 `data: ` 前缀**，每行是一个完整
/// 的 JSON 对象，`tool_calls` 整块到达（`arguments` 是对象而非 JSON 字符串
/// 片段），用量在**顶层**而不是 `usage` 子对象里。
class OllamaToolStreamParser {
  final StringBuffer _text = StringBuffer();
  final List<ToolCall> _calls = [];
  TokenUsage _usage = const TokenUsage();
  bool _done = false;

  /// 模型这一轮是否已经把话说完。口径见 `OpenAIToolStreamParser.sawCompletion`
  /// 的 dartdoc —— 这一家的 `done: true` 同时也是定稿点，两者合一。
  bool get sawCompletion => _done;

  /// 合成 id 的计数器。**跨整个流单调递增**，不是每行从 0 开始 ——
  /// 一行一个 tool call 时若按行内下标合成，两个 call 都会叫
  /// `ollama_call_0`，而 `ToolResult` 靠 callId 与 `tool_use` 配对，
  /// 撞名会让第二个结果覆盖第一个。
  int _seq = 0;

  List<AgentChunk> acceptLine(String line) {
    if (_done) return const [];
    final trimmed = line.trim();
    if (trimmed.isEmpty) return const [];

    final Map<String, dynamic> j;
    try {
      final d = jsonDecode(trimmed);
      if (d is! Map) return const [];
      j = d.cast<String, dynamic>();
    } catch (_) {
      return const [];
    }

    final out = <AgentChunk>[];
    final msg = j['message'];
    if (msg is Map) {
      final content = msg['content'];
      if (content is String && content.isNotEmpty) {
        _text.write(content);
        out.add(TextDelta(content));
      }
      final raw = msg['tool_calls'];
      if (raw is List) {
        for (final c in raw) {
          if (c is! Map) continue;
          final fn = c['function'];
          if (fn is! Map) continue;
          final id = c['id'];
          final call = ToolCall(
            id: (id is String && id.isNotEmpty) ? id : 'ollama_call_${_seq++}',
            name: fn['name'] as String? ?? '',
            args: parseToolArgs(fn['arguments']),
          );
          _calls.add(call);
          out.add(ToolCallReady(call));
        }
      }
    }

    if (j['done'] == true) {
      _usage = TokenUsage(
        inputTokens: asTokenCount(j['prompt_eval_count']),
        outputTokens: asTokenCount(j['eval_count']),
      );
      out.addAll(_finalize());
    }
    return out;
  }

  List<AgentChunk> finish() => _done ? const [] : _finalize();

  List<AgentChunk> _finalize() {
    if (_done) return const [];
    _done = true;
    return [
      StreamDone(AIResponse(
        text: _text.toString(),
        toolCalls: List.of(_calls),
        usage: _usage,
      )),
    ];
  }
}

class OllamaProvider extends AIProvider {
  final String model;
  final String baseUrl;

  /// 让模型在显存/内存里驻留多久。Ollama 默认 5 分钟，手机上一次排查很容易
  /// 跨过这个窗口 —— 之后每一轮都要重新加载权重，那是本地模型「感觉很慢」的
  /// 主因，比推理本身还久。
  ///
  /// 不计费，所以取值偏长；老版本 Ollama 不认这个字段会直接忽略，不报错。
  final String keepAlive;

  final Dio _dio;

  /// 仅供测试断言连接配置。生产代码一律用 `_dio`。
  @visibleForTesting
  Dio get debugDio => _dio;

  OllamaProvider({
    required this.model,
    required this.baseUrl,
    this.keepAlive = '30m',
    Dio? dio,
  }) : _dio = dio ??
            // 60 秒而不是另两家的 30：Ollama 本地推理较慢。
            createProviderDio(receiveTimeout: const Duration(seconds: 60));

  @override
  String get displayName => 'Ollama ($model)';

  /// 聊天端点。四处逐字重复过。Ollama 没有版本化路径（不像两家的
  /// `/v1/chat/completions`），所以只拼这一段。
  String get _chatUrl => '$baseUrl/api/chat';

  @override
  String get providerType => 'ollama';

  @override
  Future<String> complete(List<AIMessage> messages) async {
    final response = await _dio.post(
      _chatUrl,
      data: {
        'model': model,
        'messages': buildOllamaMessages(messages),
        'stream': false,
        'keep_alive': keepAlive,
      },
    );
    return response.data['message']['content'] as String;
  }

  @override
  Stream<String> completeStream(List<AIMessage> messages) async* {
    final response = await _dio.post<ResponseBody>(
      _chatUrl,
      options: Options(responseType: ResponseType.stream),
      data: {
        'model': model,
        'messages': buildOllamaMessages(messages),
        'stream': true,
        'keep_alive': keepAlive,
      },
    );

    String pending = '';
    await for (final Uint8List bytes in response.data!.stream) {
      pending += String.fromCharCodes(bytes);
      final lines = pending.split('\n');
      pending = lines.removeLast();
      for (final line in lines) {
        final trimmed = line.trim();
        if (trimmed.isEmpty) continue;
        try {
          final json = jsonDecode(trimmed) as Map<String, dynamic>;
          final content = json['message']?['content'];
          if (content is String && content.isNotEmpty) yield content;
          if (json['done'] == true) return;
        } catch (_) {
          // 同另两家：模型话没说完 vs 分片没解析出来，UI 上长得一样，
          // 这个计数把两者分开。
          noteDroppedStreamChunk();
        }
      }
    }
  }

  /// 乐观假设支持工具，第一次报错后翻转。
  ///
  /// 靠模型名判断不可行 —— Ollama 的支持名单变化太快，判错就是硬失败。
  /// 试一次的代价是一个失败请求，判错的代价是功能对能用的模型也不可用。
  bool _toolsSupported = true;

  @override
  bool get supportsTools => _toolsSupported;

  List<Map<String, dynamic>> _msgToJson(AIMessage m) {
    if (m.role == 'tool' && m.toolResults != null) {
      return m.toolResults!
          .map((r) => <String, dynamic>{
                'role': 'tool',
                'content': r.content,
              })
          .toList();
    }
    if (m.role == 'assistant' && (m.toolCalls?.isNotEmpty ?? false)) {
      return [
        <String, dynamic>{
          'role': 'assistant',
          'content': m.content,
          'tool_calls': m.toolCalls!
              .map((t) => {
                    'function': {'name': t.name, 'arguments': t.args},
                  })
              .toList(),
        }
      ];
    }
    return [
      <String, dynamic>{
        'role': m.role,
        'content': m.content,
        if (_imageB64s(m).isNotEmpty) 'images': _imageB64s(m),
      }
    ];
  }

  @override
  Future<AIResponse> completeWithTools(
    List<AIMessage> messages,
    List<ToolSpec> tools, {
    String? sessionKey,
  }) async {
    // 本轮是否真的带了图 —— 只有它为 true 时才让失败去翻转 supportsVision，
    // 否则一次普通的「模型不支持工具」400 也会把 vision 关掉。
    final hadImages = messages.any((m) => _imageB64s(m).isNotEmpty);
    try {
      final response = await _dio.post(
        _chatUrl,
        data: {
          'model': model,
          'messages': messages.expand(_msgToJson).toList(),
          'stream': false,
          'keep_alive': keepAlive,
          'tools': tools
              .map((t) => {
                    'type': 'function',
                    'function': {
                      'name': t.name,
                      'description': t.description,
                      'parameters': t.parameters,
                    },
                  })
              .toList(),
        },
      );

      final msg = response.data['message'] as Map? ?? const {};
      final calls = <ToolCall>[];
      final raw = msg['tool_calls'];
      if (raw is List) {
        for (var i = 0; i < raw.length; i++) {
          final fn = raw[i]['function'];
          // Ollama 不返回 call id，自己造一个稳定且本轮唯一的。
          final id = (raw[i]['id'] as String?) ?? 'ollama_call_$i';
          calls.add(ToolCall(
            id: id,
            name: fn['name'] as String,
            args: parseToolArgs(fn['arguments']),
          ));
        }
      }
      return AIResponse(
        text: (msg['content'] as String?) ?? '',
        toolCalls: calls,
        // Ollama 的用量在响应**顶层**，不在 usage 子对象里。没有缓存概念，
        // cachedTokens 恒为 0 —— keep_alive 省的是加载时间，不是 token。
        usage: TokenUsage(
          inputTokens: asTokenCount(response.data['prompt_eval_count']),
          outputTokens: asTokenCount(response.data['eval_count']),
        ),
      );
    } on DioException catch (e) {
      if (hadImages) noteVisionFailure(e);
      _toolsSupported = false;
      throw Exception(
        '该 Ollama 模型不支持工具调用（${e.response?.statusCode ?? e.type}），'
        '已切回直连聊天模式',
      );
    }
  }

  @override
  Stream<AgentChunk> completeWithToolsStream(
    List<AIMessage> messages,
    List<ToolSpec> tools, {
    String? sessionKey,
  }) async* {
    // 同上：只有本轮带图时，失败才允许翻转 supportsVision。
    final hadImages = messages.any((m) => _imageB64s(m).isNotEmpty);
    final Response<ResponseBody> response;
    try {
      response = await _dio.post<ResponseBody>(
        _chatUrl,
        options: Options(responseType: ResponseType.stream),
        data: {
          'model': model,
          'messages': messages.expand(_msgToJson).toList(),
          'stream': true,
          'keep_alive': keepAlive,
          'tools': tools
              .map((t) => {
                    'type': 'function',
                    'function': {
                      'name': t.name,
                      'description': t.description,
                      'parameters': t.parameters,
                    },
                  })
              .toList(),
        },
      );
    } on DioException catch (e) {
      // 与非流式路径一致：这类失败就是「这个模型不支持工具调用」，
      // 翻转 _toolsSupported 让 AIPanel 下次直接走直连。
      if (hadImages) noteVisionFailure(e);
      _toolsSupported = false;
      throw Exception(
        '该 Ollama 模型不支持工具调用（${e.response?.statusCode ?? e.type}），'
        '已切回直连聊天模式',
      );
    }

    final parser = OllamaToolStreamParser();
    // `.cast<List<int>>()` 是必需的，不是冗余：dio 的 `ResponseBody.stream`
    // 是 `Stream<Uint8List>`，而 `utf8.decoder` 是
    // `StreamTransformer<List<int>, String>` —— 函数参数逆变让它不能赋给
    // `StreamTransformer<Uint8List, _>`，不加这一句编译不过。
    //
    // **不要退回本文件 `completeStream` 里那种手动 buffer + 逐块
    // `utf8.decode` 的写法**：那样会在 chunk 切口处把多字节字符变成
    // U+FFFD，中文流式输出会夹带乱码。`utf8.decoder` 与 `LineSplitter`
    // 作为 StreamTransformer 使用时自带跨块状态，前者攒住半个字符等下半截，
    // 后者攒住半行等换行符，两处切口都由标准库正确处理。
    //
    // 收尾阶段断流不算失败：见 `OpenAIToolStreamParser.sawCompletion`。
    try {
      await for (final line in response.data!.stream
          .cast<List<int>>()
          .transform(utf8.decoder)
          .transform(const LineSplitter())) {
        for (final c in parser.acceptLine(line)) {
          yield c;
        }
      }
    } catch (_) {
      if (!parser.sawCompletion) rethrow;
    }
    for (final c in parser.finish()) {
      yield c;
    }
  }
}
