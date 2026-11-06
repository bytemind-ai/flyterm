// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import '../ai_provider.dart';
import '../attachment.dart';
import 'openai_provider.dart' show OpenAIProvider;
import 'provider_http.dart';
import '../agent/tool_models.dart';

/// 一条消息里 b64 已物化的图片附件，按原顺序。
///
/// `b64` 为 null 说明 `materializeAttachments` 没读到文件（已被删）——跳过
/// 比发一个 data 为空的 image block 好，后者是 400。
List<Attachment> _imagesOf(AIMessage m) => (m.attachments ?? const [])
    .where((a) => a.kind == AttachmentKind.image && a.b64 != null)
    .toList();

/// 把单条消息拼成 Anthropic 的 content 形态。
///
/// 无图时 `content` 仍是裸字符串，与改动前逐字节相同——绝大多数消息没有
/// 图，不该因为这个功能改变请求体形状。有图时才升级成 block 数组，且**图
/// 在文字之前**：官方文档建议图片先给、问题后给。
Map<String, dynamic> _buildAnthropicEntry(AIMessage m) {
  final images = _imagesOf(m);
  if (images.isEmpty) {
    return {'role': m.role, 'content': m.content};
  }
  return {
    'role': m.role,
    'content': [
      for (final a in images)
        {
          'type': 'image',
          'source': {
            'type': 'base64',
            'media_type': a.mime,
            'data': a.b64,
          },
        },
      {'type': 'text', 'text': m.content},
    ],
  };
}

/// 把历史拼成 Anthropic 的 messages 数组（直连路径用）。
///
/// 顶层函数，`@visibleForTesting`：为了能单测而不必造 provider 实例、不碰
/// 网络。agent 路径见 [AnthropicProvider._buildToolMessages]，两条路径共用
/// [_buildAnthropicEntry] 拼装单条消息。
@visibleForTesting
List<Map<String, dynamic>> buildAnthropicMessages(List<AIMessage> history) =>
    history.map(_buildAnthropicEntry).toList();

/// 累积一个 tool_use content block 的解析状态。
class _ToolBlock {
  final String id;
  final String name;
  final StringBuffer json = StringBuffer();
  _ToolBlock(this.id, this.name);
}

/// 把 Anthropic 的 SSE 行流解析成 [AgentChunk]。
///
/// **做成独立的、只吃字符串行的类**，而不是写在 `async*` 方法体里：解析规则
/// （按 index 累积、stop 时定稿、坏 JSON 退化）是这条链上唯一容易写错的部分，
/// 而 `async*` 里的逻辑只能靠造一个假的 HTTP 流去测。这个类可以直接喂几行
/// 字符串断言，测试成本低到可以把每种畸形输入都覆盖一遍。
///
/// 用法：每行调 [acceptLine]，流结束后调一次 [finish]。两者都返回这一步
/// 产生的 chunk 列表（可能为空）。
class AnthropicToolStreamParser {
  final StringBuffer _text = StringBuffer();

  /// 按 content block 的 index 索引。**不能按 tool id 索引** —— delta 事件
  /// 只带 index，不带 id。
  final Map<int, _ToolBlock> _blocks = {};

  /// 定稿顺序即 block 的 start 顺序，而不是 stop 顺序。模型给出的调用顺序
  /// 有语义（先读后写），乱序会让串行桶按错误的顺序执行。
  final List<int> _startOrder = [];
  final Map<int, ToolCall> _finished = {};

  TokenUsage _usage = const TokenUsage();
  bool _done = false;

  /// 模型这一轮是否已经把话说完。口径见 `OpenAIToolStreamParser.sawCompletion`
  /// 的 dartdoc —— 这一家的 `message_stop` 同时也是定稿点，两者合一。
  bool get sawCompletion => _done;

  List<AgentChunk> acceptLine(String line) {
    // 与 OpenAI / Ollama 的同名方法对齐：message_stop 之后到达的行一律
    // 丢弃。真实 Anthropic API 在 message_stop 之后不会再发数据，但中间的
    // 兼容代理/网关会（keep-alive、自定义事件）——少这道守卫会让
    // content_block_delta / content_block_stop 在 StreamDone 之后继续产出
    // chunk，StreamDone 就不再是流的最后一个元素，直接违反
    // ai_provider.dart 里写死的契约。
    if (_done) return const [];
    final trimmed = line.trim();
    if (!trimmed.startsWith('data: ')) return const [];
    final payload = trimmed.substring(6);
    final Map<String, dynamic> j;
    try {
      final d = jsonDecode(payload);
      if (d is! Map) return const [];
      j = d.cast<String, dynamic>();
    } catch (_) {
      return const [];
    }

    switch (j['type']) {
      case 'message_start':
        final m = j['message'];
        if (m is Map) _usage = _mergeUsage(_usage, m['usage']);
        return const [];

      case 'content_block_start':
        final idx = (j['index'] as num?)?.toInt();
        final block = j['content_block'];
        if (idx == null || block is! Map) return const [];
        if (block['type'] == 'tool_use') {
          _blocks[idx] = _ToolBlock(
            block['id'] as String? ?? 'anthropic_call_$idx',
            block['name'] as String? ?? '',
          );
          _startOrder.add(idx);
        }
        return const [];

      case 'content_block_delta':
        final idx = (j['index'] as num?)?.toInt();
        final delta = j['delta'];
        if (delta is! Map) return const [];
        if (delta['type'] == 'text_delta') {
          final t = delta['text'];
          if (t is String && t.isNotEmpty) {
            _text.write(t);
            return [TextDelta(t)];
          }
          return const [];
        }
        if (delta['type'] == 'input_json_delta' && idx != null) {
          final p = delta['partial_json'];
          if (p is String) _blocks[idx]?.json.write(p);
        }
        return const [];

      case 'content_block_stop':
        final idx = (j['index'] as num?)?.toInt();
        if (idx == null) return const [];
        final b = _blocks.remove(idx);
        if (b == null) return const [];
        final raw = b.json.toString();
        // 「不发半成品」契约（见 AgentChunk.ToolCallReady 的 dartdoc）：
        // 流在参数中途断掉时，isTruncatedToolArgs 能分清「合法的空参数
        // 对象 {}」与「JSON 只有半截」——parseToolArgs(raw).isEmpty 对
        // 两者都返回空 map，分不清。半截参数的调用（例如 bash 缺
        // command）被送去审批/执行比直接丢弃更危险，所以这里整个调用
        // 丢弃：不产出 ToolCallReady，也不记进 _finished（_startOrder 里
        // 这个 idx 找不到 _finished 条目，_finalize 会自动跳过它）。
        if (isTruncatedToolArgs(raw)) return const [];
        final call = ToolCall(
          id: b.id,
          name: b.name,
          // parseToolArgs 对坏 JSON 返回空 map 而不抛 —— 模型偶尔吐坏 JSON
          // 是已知现实，走 isError 回填让它自纠比打断整条 loop 好。
          args: parseToolArgs(raw),
        );
        _finished[idx] = call;
        return [ToolCallReady(call)];

      case 'message_delta':
        _usage = _mergeUsage(_usage, j['usage']);
        return const [];

      case 'message_stop':
        return _finalize();
    }
    return const [];
  }

  /// 流结束时调用。`message_stop` 已经来过就什么都不做，否则补一个
  /// [StreamDone] —— 网络中断、服务端提前关流都会走到这里，而
  /// `AgentLoop` 的契约要求 StreamDone 恰好出现一次。
  List<AgentChunk> finish() => _done ? const [] : _finalize();

  List<AgentChunk> _finalize() {
    if (_done) return const [];
    _done = true;
    return [
      StreamDone(AIResponse(
        text: _text.toString(),
        toolCalls: [
          for (final idx in _startOrder)
            if (_finished[idx] != null) _finished[idx]!,
        ],
        usage: _usage,
      )),
    ];
  }

  /// usage 分两个事件到达：`message_start` 给输入侧，`message_delta` 给输出
  /// 侧。后到的字段为 0 时不能覆盖先到的非 0 值，否则输入量会被清掉。
  static TokenUsage _mergeUsage(TokenUsage base, dynamic raw) {
    if (raw is! Map) return base;
    final input = asTokenCount(raw['input_tokens']) +
        asTokenCount(raw['cache_creation_input_tokens']);
    final cached = asTokenCount(raw['cache_read_input_tokens']);
    final output = asTokenCount(raw['output_tokens']);
    return TokenUsage(
      inputTokens: input == 0 ? base.inputTokens : input,
      cachedTokens: cached == 0 ? base.cachedTokens : cached,
      outputTokens: output == 0 ? base.outputTokens : output,
    );
  }
}

class AnthropicProvider extends AIProvider {
  final String apiKey;
  final String model;

  /// 端点前缀，拼出 `$baseUrl/messages`。
  ///
  /// 规范化方式与 [OpenAIProvider] 一致（去尾部空白和斜杠）：用户从浏览器
  /// 地址栏抄过来的 URL 常带尾斜杠，不处理会拼出 `//messages`。
  final String baseUrl;

  final Dio _dio;

  /// 仅供测试断言连接配置。生产代码一律用 `_dio`。
  @visibleForTesting
  Dio get debugDio => _dio;

  AnthropicProvider({
    required this.apiKey,
    required this.model,
    String? baseUrl,
    Dio? dio,
  })  : baseUrl = (baseUrl ?? 'https://api.anthropic.com/v1')
            .trimRight()
            .replaceAll(RegExp(r'/+$'), ''),
        _dio = dio ?? createProviderDio();

  @override
  String get displayName => 'Anthropic ($model)';

  /// 认证与内容协商头。四处逐字重复过（文本/流式/工具/代理）。
  ///
  /// 字段名小写 `content-type` 是原样搬过来的，不是笔误 —— HTTP 头不区分
  /// 大小写，改成 `Content-Type` 也对，但没必要在一次去重里顺带改。
  Map<String, String> _headers() => {
        'x-api-key': apiKey,
        'anthropic-version': '2023-06-01',
        'content-type': 'application/json',
      };

  @override
  String get providerType => 'anthropic';

  @override
  Future<String> complete(List<AIMessage> messages) async {
    final system = messages
        .where((m) => m.role == 'system')
        .map((m) => m.content)
        .join('\n');
    final userMsgs = messages
        .where((m) => m.role != 'system')
        .map(_buildAnthropicEntry)
        .toList();

    final response = await _dio.post(
      '$baseUrl/messages',
      options: Options(headers: _headers()),
      data: {
        'model': model,
        'max_tokens': 1024,
        if (system.isNotEmpty) 'system': system,
        'messages': userMsgs,
      },
    );
    return response.data['content'][0]['text'] as String;
  }

  @override
  Stream<String> completeStream(List<AIMessage> messages) async* {
    final system = messages
        .where((m) => m.role == 'system')
        .map((m) => m.content)
        .join('\n');
    final userMsgs = messages
        .where((m) => m.role != 'system')
        .map(_buildAnthropicEntry)
        .toList();

    final response = await _dio.post<ResponseBody>(
      '$baseUrl/messages',
      options: Options(
        headers: _headers(),
        responseType: ResponseType.stream,
      ),
      data: {
        'model': model,
        'max_tokens': 1024,
        if (system.isNotEmpty) 'system': system,
        'messages': userMsgs,
        'stream': true,
      },
    );

    String pending = '';
    await for (final Uint8List bytes in response.data!.stream) {
      pending += String.fromCharCodes(bytes);
      final lines = pending.split('\n');
      pending = lines.removeLast();
      for (final line in lines) {
        final trimmed = line.trim();
        if (!trimmed.startsWith('data: ')) continue;
        final data = trimmed.substring(6);
        try {
          final json = jsonDecode(data) as Map<String, dynamic>;
          if (json['type'] == 'content_block_delta') {
            final text = json['delta']?['text'];
            if (text is String && text.isNotEmpty) yield text;
          }
        } catch (_) {
          // 同 OpenAI：丢掉的分片要可观测，而不是静默少半句。
          noteDroppedStreamChunk();
        }
      }
    }
  }

  @override
  bool get supportsTools => true;

  /// Agent 模式的响应可能很长（工具调用 + 解释），1024 不够用。
  static const int _kAgentMaxTokens = 4096;

  /// 把 DioException 翻译成用户看得懂的话。
  ///
  /// 本文件原先完全不包装 DioException，于是 401 在界面上呈现为
  /// `bad response... status code of 401` —— 而同样的错误在 OpenAI provider
  /// 上是「401：API Key 无效或已过期」。agent 模式会把这段文字直接显示在
  /// 面板的终止横幅里，三家 provider 的说法不该差这么远。
  /// 把 DioException 翻成要抛出去的异常。
  ///
  /// 429 抛 [RateLimitedException]（带 `Retry-After`），其余抛普通
  /// `Exception`。类型是给 `AgentLoop` 的重试逻辑看的 —— 见
  /// `RateLimitedException` 的文档。
  Exception _translate(DioException e) {
    final msg = _friendlyError(e);
    if (e.response?.statusCode == 429) {
      return RateLimitedException(
        msg,
        retryAfter: OpenAIProvider.parseRetryAfter(
            e.response?.headers.value('retry-after')),
      );
    }
    return Exception(msg);
  }

  String _friendlyError(DioException e) {
    if (e.type == DioExceptionType.connectionTimeout ||
        e.type == DioExceptionType.sendTimeout) {
      return '连接超时，请检查网络';
    }
    if (e.type == DioExceptionType.receiveTimeout) {
      return '响应超时，服务端长时间无数据，请重试';
    }
    final status = e.response?.statusCode;
    return switch (status) {
      401 => '401：API Key 无效或已过期',
      403 => '403：无权限访问该模型',
      404 => '404：接口路径不存在，请确认模型名是否正确',
      429 => () {
          final wait =
              OpenAIProvider.parseRetryAfter(e.response?.headers.value(
            'retry-after',
          ));
          return '429：请求过于频繁或额度用尽，'
              '${wait == null ? '请稍后再试' : '请 ${wait.inSeconds} 秒后重试'}';
        }(),
      _ => '请求失败（$status）：${e.message}',
    };
  }

  /// 仅供测试：agent 路径的消息拼装。
  ///
  /// 暴露它是为了锚定一条线上契约：带 tool_call 的 assistant 消息 content
  /// 恒为空（见 `agent_loop.dart` 的「叙述不进回填历史」），而 Anthropic
  /// **拒绝空的 text block** —— 这里必须不产出它，否则每一轮工具调用都是
  /// 400。以前这条路径只在「模型恰好没说话」时走到，现在 100% 都走。
  @visibleForTesting
  List<Map<String, dynamic>> buildToolMessagesForTest(List<AIMessage> msgs) =>
      _buildToolMessages(msgs);

  List<Map<String, dynamic>> _buildToolMessages(List<AIMessage> msgs) {
    final out = <Map<String, dynamic>>[];
    for (final m in msgs) {
      if (m.role == 'system') continue;

      if (m.role == 'tool' && (m.toolResults?.isNotEmpty ?? false)) {
        // Anthropic 要求一轮里所有 tool_result 合并在同一个 user turn。
        out.add({
          'role': 'user',
          'content': m.toolResults!
              .map((r) => {
                    'type': 'tool_result',
                    'tool_use_id': r.callId,
                    'content': r.content,
                    if (r.isError) 'is_error': true,
                  })
              .toList(),
        });
        continue;
      }

      if (m.role == 'assistant' && (m.toolCalls?.isNotEmpty ?? false)) {
        final blocks = <Map<String, dynamic>>[];
        if (m.content.isNotEmpty) {
          blocks.add({'type': 'text', 'text': m.content});
        }
        for (final t in m.toolCalls!) {
          blocks.add({
            'type': 'tool_use',
            'id': t.id,
            'name': t.name,
            'input': t.args,
          });
        }
        out.add({'role': 'assistant', 'content': blocks});
        continue;
      }

      out.add(_buildAnthropicEntry(m));
    }
    return out;
  }

  /// Anthropic 的 `cache_control` 标的是「**此处及之前**的内容可缓存」——
  /// 所以位置就是全部语义，标错地方的后果是完全不命中而请求照样成功。
  static const Map<String, dynamic> _kCacheControl = {'type': 'ephemeral'};

  /// 首次因 `cache_control` 被 400 拒掉后置 true，此后本实例不再打标记。
  ///
  /// 不粘住的话，每轮都要先撞一次 400 再重试，请求数直接翻倍 ——
  /// 一个省钱的优化反而变成两倍开销。
  bool _cacheDisabled = false;

  /// 给一条消息的**最后一个** content block 打标记。
  ///
  /// content 有两种形态：普通对话是裸 String，带 tool_use / tool_result 的
  /// 是 block 列表。标记挂在 block 上而不是消息上，所以 String 形态必须先
  /// 展开成 `[{type: text, ...}]`。
  static Map<String, dynamic> _markCached(Map<String, dynamic> msg) {
    final content = msg['content'];
    if (content is String) {
      return {
        ...msg,
        'content': [
          {'type': 'text', 'text': content, 'cache_control': _kCacheControl},
        ],
      };
    }
    if (content is List && content.isNotEmpty) {
      final blocks = content
          .map((b) => Map<String, dynamic>.from(b as Map))
          .toList();
      blocks[blocks.length - 1] = {
        ...blocks.last,
        'cache_control': _kCacheControl,
      };
      return {...msg, 'content': blocks};
    }
    return msg;
  }

  /// 组装 agent 请求体。[useCache] 为 false 时产出的请求体里**一个标记都没有**
  /// —— 降级重试用它，带残留标记的话会被同一个原因再拒一次。
  Map<String, dynamic> _agentBody(
    String system,
    List<AIMessage> messages,
    List<ToolSpec> tools, {
    required bool useCache,
  }) {
    final msgs = _buildToolMessages(messages);
    final toolDefs = tools
        .map((t) => <String, dynamic>{
              'name': t.name,
              'description': t.description,
              'input_schema': t.parameters,
            })
        .toList();

    if (useCache) {
      // 断点 2/3：工具定义的末项 —— 覆盖它前面的全部工具声明。
      if (toolDefs.isNotEmpty) {
        toolDefs[toolDefs.length - 1] = {
          ...toolDefs.last,
          'cache_control': _kCacheControl,
        };
      }
      // 断点 3/3，也是大头（历史占请求量约八成）：**倒数第二条消息**。
      //
      // 最后一条是本轮刚追加的 tool 结果，每轮都不同；标它等于每轮写一份
      // 新缓存、一次也命中不了。倒数第二条及其之前的内容与上一轮请求逐字节
      // 相同，那才是可缓存的前缀。
      if (msgs.length >= 2) {
        msgs[msgs.length - 2] = _markCached(msgs[msgs.length - 2]);
      }
    }

    return {
      'model': model,
      'max_tokens': _kAgentMaxTokens,
      if (system.isNotEmpty)
        // 断点 1/3。裸 String 也是合法的 system 形态，但挂不上标记。
        'system': useCache
            ? [
                {
                  'type': 'text',
                  'text': system,
                  'cache_control': _kCacheControl,
                }
              ]
            : system,
      'messages': msgs,
      'tools': toolDefs,
    };
  }

  /// 解析 Anthropic 的 usage。
  ///
  /// `input_tokens` 本来就**不含**缓存读取，与 [TokenUsage] 的口径一致，原样取。
  /// `cache_creation_input_tokens` 按 1.25 倍计费，属全价档，并入 inputTokens。
  static TokenUsage _parseUsage(dynamic raw) {
    if (raw is! Map) return const TokenUsage();
    final input = asTokenCount(raw['input_tokens']);
    final write = asTokenCount(raw['cache_creation_input_tokens']);
    return TokenUsage(
      inputTokens: input + write,
      cachedTokens: asTokenCount(raw['cache_read_input_tokens']),
      outputTokens: asTokenCount(raw['output_tokens']),
    );
  }

  Future<Response<dynamic>> _postAgent(Map<String, dynamic> body) => _dio.post(
        '$baseUrl/messages',
        options: Options(headers: _headers()),
        data: body,
      );

  @override
  Future<AIResponse> completeWithTools(
    List<AIMessage> messages,
    List<ToolSpec> tools, {
    String? sessionKey,
  }) async {
    final system = messages
        .where((m) => m.role == 'system')
        .map((m) => m.content)
        .join('\n');
    // 本轮是否真的带了图 —— 只有它为 true 时才让失败去翻转 supportsVision，
    // 否则一次普通的文本请求 400（比如 cache_control 不被认、模型名写错）
    // 也会把 vision 关掉。
    final hadImages = messages.any((m) => _imagesOf(m).isNotEmpty);

    Response<dynamic> response;
    try {
      response = await _postAgent(
          _agentBody(system, messages, tools, useCache: !_cacheDisabled));
    } on DioException catch (e) {
      // 只有 400 才可能是「不认 cache_control」。401/403/429/超时都不是，
      // 重试它们毫无意义（429 更是会加剧限流）。
      //
      // 400 也可能是别的原因（模型名写错等）——那种情况下降级重试会再收到
      // 一个错误，我们照实报出去，只多花了一次请求。省钱的优化不能把功能弄坏。
      if (e.response?.statusCode == 400 && !_cacheDisabled) {
        _cacheDisabled = true;
        try {
          response = await _postAgent(
              _agentBody(system, messages, tools, useCache: false));
        } on DioException catch (e2) {
          if (hadImages) noteVisionFailure(e2);
          throw _translate(e2);
        }
      } else {
        if (hadImages) noteVisionFailure(e);
        throw _translate(e);
      }
    }

    final blocks = response.data['content'] as List? ?? const [];
    final buf = StringBuffer();
    final calls = <ToolCall>[];
    for (final b in blocks) {
      switch (b['type']) {
        case 'text':
          buf.write(b['text'] as String? ?? '');
        case 'tool_use':
          calls.add(ToolCall(
            id: b['id'] as String,
            name: b['name'] as String,
            args: parseToolArgs(b['input']),
          ));
      }
    }
    return AIResponse(
      text: buf.toString(),
      toolCalls: calls,
      usage: _parseUsage(response.data['usage']),
    );
  }

  @override
  Stream<AgentChunk> completeWithToolsStream(
    List<AIMessage> messages,
    List<ToolSpec> tools, {
    String? sessionKey,
  }) async* {
    final system = messages
        .where((m) => m.role == 'system')
        .map((m) => m.content)
        .join('\n');
    final hadImages = messages.any((m) => _imagesOf(m).isNotEmpty);

    // 与非流式路径共用 _agentBody —— cache_control 的三个断点、tools 的
    // input_schema 形状都不该出现两份实现。只多一个 stream 标记。
    final body = {
      ..._agentBody(system, messages, tools, useCache: !_cacheDisabled),
      'stream': true,
    };

    final Response<ResponseBody> response;
    try {
      response = await _dio.post<ResponseBody>(
        '$baseUrl/messages',
        options: Options(
          headers: _headers(),
          responseType: ResponseType.stream,
        ),
        data: body,
      );
    } on DioException catch (e) {
      // 流式路径**不做** cache_control 的 400 降级重试。
      //
      // 这个 400 发生在 `_dio.post` 那次 await 上，此时 async* 方法体还没
      // yield 过任何 chunk（Dart 的 async* 直到第一次 yield 才产生可见
      // 输出），在这里重试并不会让调用方看到两段矛盾的增量——所以「已经把
      // Stream 交给调用方」不是不能重试的理由。
      //
      // 真正的理由是成本收益不划算：_cacheDisabled 是**实例级**的，而
      // 同一个 provider 实例的非流式调用（会话摘要走的就是那条）几乎总是
      // 先撞上 400 并翻转它，所以流式路径很难成为第一个踩中这个 400 的
      // 调用。为一条罕见路径再实现一遍降级重试不划算；真撞上时用户看到的
      // 是一次明确的错误横幅，重发一次即可。
      if (hadImages) noteVisionFailure(e);
      throw _translate(e);
    }

    final parser = AnthropicToolStreamParser();
    // `utf8.decoder` 与 `LineSplitter` 作为 StreamTransformer 使用时**自带
    // 跨块状态**：前者会把切在两个 chunk 之间的多字节字符攒起来等下半截，
    // 后者会把切断的行攒起来等换行符。手工维护 buffer 是这条链上最容易写
    // 错的地方（既要处理字节切口又要处理行切口），标准库已经做对了。
    //
    // `.cast<List<int>>()`：dio 的 `stream` 是 `Stream<Uint8List>`，而
    // `utf8.decoder` 的类型是 `StreamTransformer<List<int>, String>`——
    // Dart 泛型不变，两者不直接兼容，需要先放宽成 `Stream<List<int>>`。
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
