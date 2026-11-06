// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import '../ai_provider.dart';
import '../attachment.dart';
import '../agent/tool_models.dart';
import 'provider_http.dart';
import 'strict_schema.dart';

/// 把历史拼成 OpenAI 的 messages 数组。
///
/// 与 Anthropic 的区别只在 block 形状：这边是 `image_url` + `data:` URL，
/// 那边是 `source.base64`。顺序同样图在前。
@visibleForTesting
List<Map<String, dynamic>> buildOpenAIContent(List<AIMessage> history) {
  return [
    for (final m in history)
      if (_imagesOf(m).isEmpty)
        {'role': m.role, 'content': m.content}
      else
        {
          'role': m.role,
          'content': [
            for (final a in _imagesOf(m))
              {
                'type': 'image_url',
                'image_url': {'url': 'data:${a.mime};base64,${a.b64}'},
              },
            {'type': 'text', 'text': m.content},
          ],
        },
  ];
}

List<Attachment> _imagesOf(AIMessage m) => (m.attachments ?? const [])
    .where((a) => a.kind == AttachmentKind.image && a.b64 != null)
    .toList();

/// 累积一个 tool_call 的解析状态。OpenAI 只在**首片**给 id 与 name，
/// 后续片段只有 index + arguments 片段。
class _PartialCall {
  String id;
  String name;
  final StringBuffer args = StringBuffer();
  _PartialCall(this.id, this.name);
}

/// 把 OpenAI 的 SSE 行流解析成 [AgentChunk]。
///
/// 独立成类的理由同 `AnthropicToolStreamParser`：按 index 累加、首片给
/// id/name 后续不给，这套规则是这条链上唯一容易写错的地方，做成能直接喂
/// 字符串的类才好把畸形输入测穷。
class OpenAIToolStreamParser {
  final StringBuffer _text = StringBuffer();

  /// 按 delta 里的 `index` 索引。**不能按 id 索引** —— 后续片段没有 id。
  final Map<int, _PartialCall> _calls = {};

  /// 定稿顺序按 index 升序，即模型给出的调用顺序。
  TokenUsage _usage = const TokenUsage();
  bool _done = false;

  /// 见过 `finish_reason`。与 [_done] 分开是因为这一家**刻意不在
  /// finish_reason 时定稿**（要等后面那块 usage，见 `acceptLine` 末尾的
  /// 注释），于是「说完了」与「定稿了」在 OpenAI 这条路上不是同一件事。
  bool _sawFinishReason = false;

  /// 模型这一轮是否已经把话说完。
  ///
  /// 给 provider 判断「流上的异常是不是只发生在收尾阶段」用：兼容端点常常
  /// 在最后一块之后不发 chunked 终止块就关连接，dart:io 会抛
  /// `HttpException: Connection closed while receiving data`。那时正文早已
  /// 完整，把它当成失败会让用户读到一段完整回答之后再吃一个错误气泡。
  ///
  /// **不能退化成「只要有正文就算说完」**：正文流到一半断掉与说完之后才断，
  /// 对用户是完全不同的两件事，前者必须照旧报错。
  bool get sawCompletion => _done || _sawFinishReason;

  List<AgentChunk> acceptLine(String line) {
    if (_done) return const [];
    final trimmed = line.trim();
    if (!trimmed.startsWith('data: ')) return const [];
    final payload = trimmed.substring(6);
    if (payload == '[DONE]') return _finalize();

    final Map<String, dynamic> j;
    try {
      final d = jsonDecode(payload);
      if (d is! Map) return const [];
      j = d.cast<String, dynamic>();
    } catch (_) {
      return const [];
    }

    // usage 单独一块到达（`stream_options.include_usage`），那一块的
    // choices 是空数组，所以这一段必须在 choices 判空之前处理。
    final usage = j['usage'];
    // 直接调私有的 _parseUsage：Dart 的私有是**库级**的，这个解析器与
    // OpenAIProvider 在同一个文件里，本来就能访问，不需要经过任何转发。
    if (usage is Map) _usage = OpenAIProvider._parseUsage(usage);

    final choices = j['choices'];
    if (choices is! List || choices.isEmpty) return const [];
    final choice = choices[0];
    if (choice is! Map) return const [];

    final out = <AgentChunk>[];
    final delta = choice['delta'];
    if (delta is Map) {
      final content = delta['content'];
      if (content is String && content.isNotEmpty) {
        _text.write(content);
        out.add(TextDelta(content));
      }
      final raw = delta['tool_calls'];
      if (raw is List) {
        for (final c in raw) {
          if (c is! Map) continue;
          final idx = (c['index'] as num?)?.toInt() ?? 0;
          final fn = c['function'];
          final partial = _calls.putIfAbsent(
            idx,
            () => _PartialCall(c['id'] as String? ?? 'call_$idx', ''),
          );
          // id 可能只在首片出现，也可能在后续片重复出现；非空就更新，
          // 空字符串不许覆盖已有值。
          final id = c['id'];
          if (id is String && id.isNotEmpty) partial.id = id;
          if (fn is Map) {
            final name = fn['name'];
            if (name is String && name.isNotEmpty) partial.name = name;
            final args = fn['arguments'];
            if (args is String) partial.args.write(args);
          }
        }
      }
    }

    // finish_reason 到达即这一轮说完了。有些端点在此之后还会发 usage 块，
    // 所以**不能**在这里 finalize —— 那会把 usage 丢掉。等 [DONE] 或流结束。
    // 只把「说完了」记下来，供 sawCompletion 判断收尾阶段的异常。
    if (choice['finish_reason'] != null) _sawFinishReason = true;
    return out;
  }

  List<AgentChunk> finish() => _done ? const [] : _finalize();

  List<AgentChunk> _finalize() {
    if (_done) return const [];
    _done = true;
    final indices = _calls.keys.toList()..sort();
    final calls = <ToolCall>[];
    final out = <AgentChunk>[];
    for (final i in indices) {
      final p = _calls[i]!;
      final argsStr = p.args.toString();
      // 「不发半成品」契约（见 AgentChunk.ToolCallReady 的 dartdoc）：流在
      // 参数中途断掉（没等到 [DONE]）时跳过这个 call，既不进 calls 也不
      // 产出 ToolCallReady。isTruncatedToolArgs 能分清「合法的空参数对象
      // {}」与「JSON 只有半截」，parseToolArgs(argsStr).isEmpty 对两者都
      // 返回空 map，分不清——半截参数的调用（例如 bash 缺 command）被
      // 无条件定稿送去审批/执行，比丢弃这个调用更危险。
      if (isTruncatedToolArgs(argsStr)) continue;
      final call = ToolCall(
        id: p.id,
        name: p.name,
        args: parseToolArgs(argsStr),
      );
      calls.add(call);
      out.add(ToolCallReady(call));
    }
    out.add(StreamDone(AIResponse(
      text: _text.toString(),
      toolCalls: calls,
      usage: _usage,
    )));
    return out;
  }
}

class OpenAIProvider extends AIProvider {
  final String apiKey;
  final String model;
  final String baseUrl;
  /// Optional extra fields merged into the request body, e.g.
  /// {"reasoning":{"enabled":true},"temperature":0}
  final Map<String, dynamic>? extraParams;
  final Dio _dio;

  /// 仅供测试断言连接配置。生产代码一律用 `_dio`。
  @visibleForTesting
  Dio get debugDio => _dio;

  /// 首次因 `strict` 被 400 拒掉后置 true，此后本实例不再发它。
  ///
  /// **必须粘住**：不粘的话每轮都要先撞一次 400 再重试，请求数直接翻倍 ——
  /// 一个消除参数错误的优化反而变成两倍开销。理由与 `AnthropicProvider`
  /// 的 `_cacheDisabled` 完全相同。
  ///
  /// **不与 `_cacheDisabled` 那类降级合并成一个集合**：两条降级的触发条件、
  /// 粘住的理由、将来的演化方向都不一样，合并只会让它们互相牵连 —— cache
  /// 被拒时顺手关掉 strict，反之亦然。
  ///
  /// 非流式与流式共用这一个字段：任一路径撞过 400 之后，两条路径都不再发
  /// `strict` —— 它们打的是同一个端点，没有理由分开判断。
  bool _strictDisabled = false;

  /// 首次因 `prompt_cache_key` 被 400 拒掉后置 true，此后本实例不再发它。
  ///
  /// 与 `_strictDisabled` 同一个粘性模式：不粘住的话每轮都要先撞一次 400
  /// 再重试，请求数直接翻倍。
  bool _cacheKeyDisabled = false;

  /// 关掉一个可选特性，返回 false 表示已经没有可关的了。
  ///
  /// **顺序是设计决定，不要调换**：`prompt_cache_key` 是后加的，收益只是
  /// 「提高缓存命中率」；strict 是已经实测验证过的功能（`ca1ee9c9`）。
  /// 一个 400 分不清是谁引起的，那就让新变量先背锅。
  ///
  /// [sentCacheKey] 为 false（调用方没给 sessionKey）时跳过第一级 ——
  /// 请求里本来就没有那个字段，关它是空操作，只会白白多撞一次 400。
  /// 这保证了存量调用方的行为与改动前逐字节一致：最多两次请求。
  bool _downgradeOnce({required bool sentCacheKey}) {
    if (sentCacheKey && !_cacheKeyDisabled) {
      _cacheKeyDisabled = true;
      return true;
    }
    if (!_strictDisabled) {
      _strictDisabled = true;
      return true;
    }
    return false;
  }

  /// OpenAI 对 `prompt_cache_key` 的长度上限。超出部分直接截掉 —— 这个值
  /// 是我们自己生成的（`AgentLoop.sessionKey`，约 23 字符），正常永远不会
  /// 触发，截断只是防止将来换生成方式时静默变成 400。
  static const int kPromptCacheKeyMaxLength = 64;

  static String? _clampCacheKey(String? k) {
    if (k == null || k.isEmpty) return null;
    return k.length <= kPromptCacheKeyMaxLength
        ? k
        : k.substring(0, kPromptCacheKeyMaxLength);
  }

  /// 请求头。[sessionKey] 非空时额外带上缓存亲和字段，让同一条历史尽量落到
  /// 同一台后端机器上。
  ///
  /// **不对 header 做 400 降级**：未知 header 在 HTTP 上是明确无害的，代理和
  /// 端点都会忽略。会引发 400 的只有 body 里那个字段。
  Map<String, String> _agentHeaders({String? sessionKey}) {
    final h = <String, String>{
      'Authorization': 'Bearer $apiKey',
      'Content-Type': 'application/json',
    };
    final key = _clampCacheKey(sessionKey);
    if (key != null) {
      if (baseUrl.contains('openrouter')) {
        h['x-session-id'] = key;
      } else {
        h['x-client-request-id'] = key;
        h['x-session-affinity'] = key;
      }
    }
    return h;
  }

  OpenAIProvider({
    required this.apiKey,
    required this.model,
    String? baseUrl,
    String? extraParamsJson,
    Dio? dio,
  })  : baseUrl = (baseUrl ?? 'https://api.openai.com/v1').trimRight().replaceAll(RegExp(r'/+$'), ''),
        extraParams = _parseJson(extraParamsJson),
        _dio = dio ?? createProviderDio();

  static Map<String, dynamic>? _parseJson(String? json) {
    if (json == null || json.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(json);
      if (decoded is Map<String, dynamic>) return decoded;
    } catch (_) {}
    return null;
  }

  @override
  String get displayName => 'OpenAI ($model)';

  @override
  String get providerType => 'openai';

  Map<String, dynamic> _buildBody(List<AIMessage> messages) {
    final body = <String, dynamic>{
      'model': model,
      'messages': buildOpenAIContent(messages),
    };
    if (extraParams != null) {
      body.addAll(extraParams!);
      body['model'] = model;
      body['messages'] = buildOpenAIContent(messages);
    }
    return body;
  }

  /// 从响应体里挖出服务端给的原话。
  ///
  /// OpenAI 兼容端点出错时返回 `{"error": {"message": "..."}}`，那句话通常
  /// 比我们能编的任何文案都准确（「本月额度已用尽」「并发数超限」「该模型
  /// 需要实名认证」）。挖不到就返回 null，由调用方退回状态码文案。
  ///
  /// **流式路径挖不到**：那时 `responseType` 是 stream，`e.response?.data`
  /// 是一个还没读的 `ResponseBody` 而不是解析好的 Map。这里对非 Map/String
  /// 一律返回 null，所以流式路径会安静地退回状态码文案 —— 不为它引入一次
  /// 异步读体。
  static String? _serverMessage(DioException e) {
    final d = e.response?.data;
    if (d is Map) {
      final err = d['error'];
      if (err is Map && err['message'] is String) return err['message'] as String;
      if (err is String) return err;
      if (d['message'] is String) return d['message'] as String;
    }
    // 有些兼容端点直接回一段纯文本。太长的多半是 HTML 错误页（nginx 502
    // 之类），那种贴出来只会刷屏，不如只说状态码。
    if (d is String && d.trim().isNotEmpty && d.trim().length <= 200) {
      return d.trim();
    }
    return null;
  }

  /// 把 `Retry-After` 头解析成时长。
  ///
  /// RFC 7231 允许两种形式：delta-seconds 与 HTTP-date。**只认前者** ——
  /// 各家 LLM API（OpenAI、Anthropic、以及绝大多数兼容端点）给的都是秒数，
  /// 而 HTTP-date 那一支要处理时区与客户端时钟偏移，为一条没人用的分支引入
  /// 那些不划算。认不出就返回 null，调用方退回自己的退避策略。
  ///
  /// 上限 120 秒：见过端点在额度耗尽时回 `Retry-After: 86400`（一天）。照着
  /// 等一天等于把会话挂死，不如当成「没给」交给调用方决定。
  static Duration? parseRetryAfter(String? raw) {
    if (raw == null) return null;
    final secs = int.tryParse(raw.trim());
    if (secs == null || secs <= 0 || secs > 120) return null;
    return Duration(seconds: secs);
  }

  /// 把 DioException 翻成要抛出去的异常。
  ///
  /// 429 抛 [RateLimitedException]（带 `Retry-After`），其余抛普通
  /// `Exception`。**类型是给 `AgentLoop` 的重试逻辑看的** —— 见
  /// `RateLimitedException` 的文档：降级成字符串再匹配回来会丢掉那个秒数。
  Exception _translate(int? status, String url, DioException e) {
    final msg = _friendlyError(status, url, e);
    if (status == 429) {
      return RateLimitedException(
        msg,
        retryAfter: parseRetryAfter(e.response?.headers.value('retry-after')),
      );
    }
    return Exception(msg);
  }

  String _friendlyError(int? status, String url, DioException e) {
    if (e.type == DioExceptionType.connectionTimeout ||
        e.type == DioExceptionType.sendTimeout) {
      return '连接超时，请检查网络或 Base URL（当前：$url）';
    }
    if (e.type == DioExceptionType.receiveTimeout) {
      return '响应超时，服务端长时间无数据，请重试';
    }

    final detail = _serverMessage(e);
    final tail = detail == null ? '' : '：$detail';

    switch (status) {
      case 404:
        return '404：接口路径不存在，请确认 Base URL 是否包含 /v1（当前：$url）';
      case 401:
        return '401：API Key 无效或已过期';
      case 403:
        return '403：无权限访问该模型';
      case 429:
        // 与 anthropic_provider 的同名分支对齐 —— 这一条此前只有 Anthropic
        // 有，OpenAI 这边落到下面的兜底，于是用户看到的是 Dio 那段
        // 「the request contains bad syntax or cannot be fulfilled」样板。
        // 那句话对 429 还是**错的**：429 不是语法问题，是限流。
        final wait = parseRetryAfter(e.response?.headers.value('retry-after'));
        final after =
            wait == null ? '请稍后再试' : '请 ${wait.inSeconds} 秒后重试';
        return '429：请求过于频繁或额度用尽，$after$tail';
      default:
        // **绝不要在这里贴 `e.message`。** Dio 对「响应状态码不合法」这类
        // 异常的 message 是一整段面向开发者的说明（"This exception was
        // thrown because the response has a status code of ... and
        // RequestOptions.validateStatus was configured to throw ..."，还带
        // 一个 MDN 链接），在手机上会糊满整个终止横幅，而且它对状态码的
        // 解释按 4xx 通用措辞给，经常是错的。
        return '请求失败（$status）$tail';
    }
  }

  /// 带降级阶梯的 POST。每次 400 关掉一级可选特性后重试，关无可关时抛。
  ///
  /// [bodyOf] 与 [optionsOf] 必须是**闭包**而不是预先算好的值 —— 每次重试
  /// 都要重新读 `_cacheKeyDisabled` / `_strictDisabled`，拿固定值进来的话
  /// 重试请求与首次完全相同，降级等于没做。
  ///
  /// 重试只发生在 response 交给调用方之前 —— 流式时流还没开始读、非流式时
  /// Future 还没 resolve，两种情况下重试都不会让调用方看到重复内容。这一点
  /// 由「dio 默认只接受 2xx（`validateStatus`），400 在 `_dio.post` 阶段就抛」
  /// 保证。
  Future<Response<T>> _postWithDowngrade<T>(
    String url, {
    required bool hadImages,
    required bool sentCacheKey,
    required Options Function() optionsOf,
    required Map<String, dynamic> Function() bodyOf,
  }) async {
    while (true) {
      try {
        return await _dio.post<T>(url, options: optionsOf(), data: bodyOf());
      } on DioException catch (e) {
        // 400 也可能是别的原因（模型名写错、消息格式不对）——那种情况下降级
        // 重试会再收到一个错误，照实报出去，只多花了一两次请求。
        //
        // **不去匹配错误文案**：措辞因服务端实现而异（官方、代理、自建网关
        // 各不相同），匹配文案是文本耦合。
        if (e.response?.statusCode == 400 &&
            _downgradeOnce(sentCacheKey: sentCacheKey)) {
          continue;
        }
        if (hadImages) noteVisionFailure(e);
        throw _translate(e.response?.statusCode, url, e);
      }
    }
  }

  @override
  Future<String> complete(List<AIMessage> messages) async {
    final body = _buildBody(messages);
    final url = '$baseUrl/chat/completions';
    // 本轮是否真的带了图 —— 只有它为 true 时才让失败去翻转 supportsVision，
    // 否则一次普通的文本请求 400 也会把 vision 关掉。
    final hadImages = messages.any((m) => _imagesOf(m).isNotEmpty);
    try {
      final response = await _dio.post(
        url,
        options: Options(headers: _agentHeaders()),
        data: body,
      );
      return response.data['choices'][0]['message']['content'] as String;
    } on DioException catch (e) {
      if (hadImages) noteVisionFailure(e);
      throw _translate(e.response?.statusCode, url, e);
    }
  }

  @override
  Stream<String> completeStream(List<AIMessage> messages) async* {
    final body = _buildBody(messages);
    body['stream'] = true;
    final url = '$baseUrl/chat/completions';
    final hadImages = messages.any((m) => _imagesOf(m).isNotEmpty);
    try {
      final response = await _dio.post<ResponseBody>(
        url,
        options: Options(
          headers: _agentHeaders(),
          responseType: ResponseType.stream,
        ),
        data: body,
      );
      String pending = '';
      await for (final Uint8List bytes in response.data!.stream) {
        pending += utf8.decode(bytes, allowMalformed: true);
        final lines = pending.split('\n');
        pending = lines.removeLast(); // keep incomplete line
        for (final line in lines) {
          final trimmed = line.trim();
          if (!trimmed.startsWith('data: ')) continue;
          final data = trimmed.substring(6);
          if (data == '[DONE]') return;
          try {
            final json = jsonDecode(data) as Map<String, dynamic>;
            final content = json['choices']?[0]?['delta']?['content'];
            if (content is String && content.isNotEmpty) yield content;
          } catch (_) {
            // 畸形分片：不能把它当「这轮没内容」放过 —— 那是用户可见的
            // 「回复少了半句」，而日志里什么都没有。计数让它可观测。
            noteDroppedStreamChunk();
          }
        }
      }
    } on DioException catch (e) {
      if (hadImages) noteVisionFailure(e);
      throw _translate(e.response?.statusCode, url, e);
    }
  }

  @override
  bool get supportsTools => true;

  /// 解析 OpenAI 的 usage。
  ///
  /// `prompt_tokens` **包含**缓存命中，所以要减 —— 见 [TokenUsage] 的口径说明。
  /// 缓存是自动的（≥1024 token 的前缀），代码不用做任何事，这里只是把命中量
  /// 读出来给用户看。字段缺失一律按 0，不抛。
  static TokenUsage _parseUsage(dynamic raw) {
    if (raw is! Map) return const TokenUsage();
    final prompt = asTokenCount(raw['prompt_tokens']);
    final details = raw['prompt_tokens_details'];
    final cached = details is Map ? asTokenCount(details['cached_tokens']) : 0;
    final uncached = prompt - cached;
    return TokenUsage(
      // 服务端理论上不会给出 cached > prompt，但它是别人的字段，
      // 不该让一个展示用的数字有机会变成负数。
      inputTokens: uncached < 0 ? 0 : uncached,
      cachedTokens: cached,
      outputTokens: asTokenCount(raw['completion_tokens']),
    );
  }

  /// 把一条 [AIMessage] 转成 OpenAI 的 message 对象。
  ///
  /// `role == 'tool'` 的消息会展开成**多条** —— 每个 ToolResult 一条，
  /// OpenAI 不接受一条消息里塞多个结果。
  List<Map<String, dynamic>> _msgToJson(AIMessage m) {
    if (m.role == 'tool' && m.toolResults != null) {
      return m.toolResults!
          .map((r) => <String, dynamic>{
                'role': 'tool',
                'tool_call_id': r.callId,
                'content': r.content,
              })
          .toList();
    }
    if (m.role == 'assistant' && (m.toolCalls?.isNotEmpty ?? false)) {
      return [
        <String, dynamic>{
          'role': 'assistant',
          'content': m.content.isEmpty ? null : m.content,
          'tool_calls': m.toolCalls!
              .map((t) => {
                    'id': t.id,
                    'type': 'function',
                    'function': {
                      'name': t.name,
                      'arguments': jsonEncode(t.args),
                    },
                  })
              .toList(),
        }
      ];
    }
    return buildOpenAIContent([m]);
  }

  /// 工具定义的 JSON 形状。两处请求体（流式与非流式）共用。
  ///
  /// 抽出来是为了让 `strict` 只在一个地方加 —— 原先两段代码一字不差地
  /// 重复着，改一处漏一处的漂移只是时间问题。
  ///
  /// [strict] 为 true 时：`parameters` 先经 [toStrictSchema] 翻译成 strict
  /// 子集，并带上 `"strict": true`。为 false（降级之后）时两者都不出现 ——
  /// 不是「带一个 false 值」，是这个 key 完全不出现，避免端点对未预期的
  /// `strict: false` 有奇怪的反应。
  List<Map<String, dynamic>> _toolsJson(List<ToolSpec> tools,
          {required bool strict}) =>
      tools
          .map((t) => {
                'type': 'function',
                'function': {
                  'name': t.name,
                  'description': t.description,
                  'parameters':
                      strict ? toStrictSchema(t.parameters) : t.parameters,
                  if (strict) 'strict': true,
                },
              })
          .toList();

  Map<String, dynamic> _agentToolsBody(
    List<AIMessage> messages,
    List<ToolSpec> tools, {
    required bool strict,
    String? cacheKey,
  }) =>
      <String, dynamic>{
        // 放在 extraParams 展开**之前**，与 `stream_options` 同一个理由：
        // 用户在 extraParams 里写同名键时应当能盖掉这里的默认值。
        if (cacheKey != null) 'prompt_cache_key': cacheKey,
        if (extraParams != null) ...extraParams!,
        'model': model,
        'messages': messages.expand(_msgToJson).toList(),
        'tools': _toolsJson(tools, strict: strict),
      };

  @override
  Future<AIResponse> completeWithTools(
    List<AIMessage> messages,
    List<ToolSpec> tools, {
    String? sessionKey,
  }) async {
    final url = '$baseUrl/chat/completions';
    final hadImages = messages.any((m) => _imagesOf(m).isNotEmpty);
    final key = _clampCacheKey(sessionKey);
    final response = await _postWithDowngrade<dynamic>(
      url,
      hadImages: hadImages,
      sentCacheKey: key != null,
      optionsOf: () => Options(headers: _agentHeaders(sessionKey: sessionKey)),
      bodyOf: () => _agentToolsBody(messages, tools,
          strict: !_strictDisabled,
          cacheKey: _cacheKeyDisabled ? null : key),
    );

    final msg = response.data['choices'][0]['message'];
    final calls = <ToolCall>[];
    final raw = msg['tool_calls'];
    if (raw is List) {
      for (final c in raw) {
        final fn = c['function'];
        calls.add(ToolCall(
          id: c['id'] as String,
          name: fn['name'] as String,
          args: parseToolArgs(fn['arguments']),
        ));
      }
    }
    return AIResponse(
      text: (msg['content'] as String?) ?? '',
      toolCalls: calls,
      usage: _parseUsage(response.data['usage']),
    );
  }

  Map<String, dynamic> _agentStreamBody(
    List<AIMessage> messages,
    List<ToolSpec> tools, {
    required bool strict,
    String? cacheKey,
  }) =>
      <String, dynamic>{
        // 流式下 usage 默认**不返回**，必须显式要。放在 extraParams 展开
        // **之前**：Dart map 字面量里后写的键覆盖先写的，只有先写
        // stream_options 再展开 extraParams，用户在 extraParams 里写的
        // stream_options 才能真的盖掉这里的默认值——反过来（展开在前）会
        // 让这个硬编码值恒赢，下面这句"可以用 extraParams 覆盖掉它"就是一句
        // 不成立的空话。model / messages / tools 仍保持在展开之后，那是既有
        // 行为，不在本次范围。
        //
        // 风险与取舍：这是 OpenAI 官方字段，vLLM / LiteLLM / 各家兼容端点
        // 通常支持或忽略未知字段；万一某个端点因此 400，用户看到的是一次
        // 明确的错误而不是静默降级，可以用 extraParams 覆盖掉它。
        // 不带的话 agent 模式的 usage 页脚在 OpenAI 上会永远显示 0 ——
        // 那是一次可见的能力退化，比这点兼容性风险更糟。
        'stream_options': {'include_usage': true},
        if (cacheKey != null) 'prompt_cache_key': cacheKey,
        if (extraParams != null) ...extraParams!,
        'model': model,
        'messages': messages.expand(_msgToJson).toList(),
        'tools': _toolsJson(tools, strict: strict),
        'stream': true,
      };

  @override
  Stream<AgentChunk> completeWithToolsStream(
    List<AIMessage> messages,
    List<ToolSpec> tools, {
    String? sessionKey,
  }) async* {
    final url = '$baseUrl/chat/completions';
    final hadImages = messages.any((m) => _imagesOf(m).isNotEmpty);
    final key = _clampCacheKey(sessionKey);
    final response = await _postWithDowngrade<ResponseBody>(
      url,
      hadImages: hadImages,
      sentCacheKey: key != null,
      optionsOf: () => Options(
        headers: _agentHeaders(sessionKey: sessionKey),
        responseType: ResponseType.stream,
      ),
      bodyOf: () => _agentStreamBody(messages, tools,
          strict: !_strictDisabled,
          cacheKey: _cacheKeyDisabled ? null : key),
    );

    final parser = OpenAIToolStreamParser();
    // `.cast<List<int>>()`：dio 的 `stream` 是 `Stream<Uint8List>`，而
    // `utf8.decoder` 的静态类型是 `StreamTransformer<List<int>, String>`——
    // 泛型不变性导致不能直接 transform，先放宽一次元素类型。
    // 收尾阶段断流不算失败：见 `OpenAIToolStreamParser.sawCompletion`。
    // catch 必须包住整个 await for 而不是只包最后一次 moveNext —— 错误可能
    // 在 [DONE] 之后的任何一次读上抛出（终止块缺失、代理提前 FIN）。
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
