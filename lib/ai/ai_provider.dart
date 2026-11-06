// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:dio/dio.dart';

import 'ai_message.dart';
import 'agent/tool_models.dart';
import 'providers/openai_provider.dart';
import 'providers/anthropic_provider.dart';
import 'providers/ollama_provider.dart';
import 'providers/gemini_provider.dart';
import '../data/models/ai_provider_config.dart';

export 'ai_message.dart';

/// provider 撞上 429（限流 / 额度用尽）。
///
/// ## 为什么要一个专门的类型，而不是让 `AgentLoop` 去匹配字符串
///
/// 同文件里 `_looksLikeContextOverflow` 就是靠匹配错误文本认「上下文超长」的
/// —— 那是没办法：那条信息只存在于各家 provider 自己措辞的错误消息里。而
/// 429 不一样，它是一个**结构化的信号**（HTTP 状态码 + `Retry-After` 头），
/// 降级成字符串再匹配回来会丢掉 `Retry-After` 那个数字，而那正是「该等多久」
/// 唯一可靠的来源。
///
/// 附带的好处是本地化不会弄坏重试：错误文案是中文的，将来若翻成英文，字符串
/// 匹配会静默失效，而类型不会。
class RateLimitedException implements Exception {
  /// 给用户看的完整文案（已含状态码、等待建议、服务端原话）。
  final String message;

  /// 服务端 `Retry-After` 给出的等待时长。null = 服务端没说，由调用方自己
  /// 决定退避多久。
  final Duration? retryAfter;

  const RateLimitedException(this.message, {this.retryAfter});

  @override
  String toString() => message;
}

abstract class AIProvider {
  String get displayName;

  /// provider 的类型标识，与 `AIProviderConfig.type` 同值
  /// （`openai` / `anthropic` / `gemini` / `ollama`）。
  ///
  /// 工具分档要用它。不从 [displayName] 里解析 —— 那是给人看的字符串，
  /// 拿它做判定等于让一次文案调整改掉功能行为。
  String get providerType;

  Future<String> complete(List<AIMessage> messages);

  /// Streams text chunks as they arrive.
  /// Default implementation wraps [complete] as a single-element stream.
  /// Override for true server-sent-events / chunked streaming.
  Stream<String> completeStream(List<AIMessage> messages) async* {
    yield await complete(messages);
  }

  /// 该 provider 是否支持 tool calling。
  ///
  /// Ollama 上这个值是**乐观的**：模型名单变化太快，靠名字判断必然判错。
  /// 先当作支持，第一次请求报错后由 provider 自己翻转为 false（见
  /// `OllamaProvider.supportsTools`）。
  bool get supportsTools => false;

  /// 这个 provider 实例支不支持图片输入。
  ///
  /// **乐观初值 true**，与 `OllamaProvider.supportsTools` 同一个取舍（见那边
  /// 的注释：靠模型名判断不可行，判错就是硬失败）。用户可以接任意 OpenAI
  /// 兼容端点，支不支持视觉无法从 type 推断。
  bool _visionSupported = true;
  bool get supportsVision => _visionSupported;

  /// 一次带图请求失败后调用。**只有明确的 4xx 才翻转。**
  ///
  /// 与 `supportsTools` 的处理刻意不同：那边是 `on DioException catch` 一律
  /// 翻转。图片请求比纯文本大一到两个数量级，移动网络下超时概率高得多，而
  /// 代价不对称 —— 误翻转的后果是「附件按钮突然灰了，用户不知道为什么」，
  /// 漏翻转只是下次再失败一次、多花一次流量。
  void noteVisionFailure(Object error) {
    if (error is! DioException) return;
    final code = error.response?.statusCode;
    if (code != 400 && code != 415 && code != 422) return;
    // context 超限也是 400。把它当成「不支持图片」会让附件按钮永久变灰，
    // 而真实原因只是这段会话太长了 —— 用户换个新会话就好，不该失去功能。
    if (isContextOverflow(error.response?.data)) return;
    _visionSupported = false;
  }

  /// 把「不支持视觉」的判定清掉，让附件按钮重新可用。
  ///
  /// [noteVisionFailure] 的判定是启发式的 —— 它只看状态码。一张损坏的图、
  /// 一次超大的请求体都可能返回 400/415，于是一个**支持**视觉的模型被误判
  /// 成不支持。代价不对称：误判之后用户在这个 provider 实例上永久失去附件
  /// 能力，直到他换模型或重启 app，而且屏幕上没有任何东西解释为什么。
  ///
  /// 所以留一个显式的逃生口：UI 在用户点灰掉的附件按钮时给出原因，并允许
  /// 「仍要试一次」。真的不支持的话，下一次带图请求会再把它翻回去 ——
  /// 代价只是多一次失败的流量，比永久失能便宜得多。
  void resetVisionSupport() => _visionSupported = true;

  /// 带工具的一轮对话。三家的 wire format 差异在各自实现里消化。
  ///
  /// [sessionKey] 是本轮所属会话的缓存亲和标识。**per-AgentLoop 而非
  /// per-provider**：provider 实例长存且同时服务多个 tab，挂成实例字段会
  /// 让两条不同的历史共用一个 key，命中率比不发还差。目前只有
  /// `OpenAIProvider` 使用它，其余实现收下后忽略。
  Future<AIResponse> completeWithTools(
    List<AIMessage> messages,
    List<ToolSpec> tools, {
    String? sessionKey,
  }) =>
      throw UnsupportedError('$displayName does not support tool calling');

  /// 带工具的一轮对话，流式。
  ///
  /// 默认实现把 [completeWithTools] 包装成一条等价的流 —— **不支持流式的
  /// provider 零改动**，与 [completeStream] 对 [complete] 的处理方式一致。
  /// 覆盖它的 provider 负责自己解 SSE / NDJSON。
  ///
  /// 契约：[StreamDone] 必须是最后一个元素，且必须恰好出现一次。`AgentLoop`
  /// 靠它拿到这一轮的定稿响应，缺了它这一轮会被当成「模型什么都没说」。
  Stream<AgentChunk> completeWithToolsStream(
    List<AIMessage> messages,
    List<ToolSpec> tools, {
    String? sessionKey,
  }) async* {
    final r = await completeWithTools(messages, tools, sessionKey: sessionKey);
    if (r.text.isNotEmpty) yield TextDelta(r.text);
    for (final c in r.toolCalls) {
      yield ToolCallReady(c);
    }
    yield StreamDone(r);
  }
}

class AIProviderFactory {
  static AIProvider create(AIProviderConfig config, String apiKey) {
    switch (config.type) {
      case 'openai':
        return OpenAIProvider(
          apiKey: apiKey,
          model: config.model,
          baseUrl: config.baseUrl,
          extraParamsJson: config.extraParams,
        );
      case 'anthropic':
        return AnthropicProvider(
          apiKey: apiKey,
          model: config.model,
          baseUrl: config.baseUrl,
        );
      case 'ollama':
        return OllamaProvider(
          model: config.model,
          baseUrl: config.baseUrl ?? 'http://localhost:11434',
        );
      case 'gemini':
        return GeminiProvider(
          apiKey: apiKey,
          model: config.model,
          baseUrl: config.baseUrl,
          extraParamsJson: config.extraParams,
        );
      default:
        throw ArgumentError('Unknown provider type: ${config.type}');
    }
  }
}

/// 这个错误响应是不是「上下文超出模型上限」。
///
/// 三家的措辞都不同，只能按关键词认。**宁可漏判也不能误判**：漏判的后果是
/// 附件按钮被错误地置灰一次（重开面板恢复），误判的后果是真的不支持图片却
/// 一直重试。所以关键词取得窄，只认明确谈到长度/上限的那几种。
bool isContextOverflow(Object? body) {
  final text = body?.toString().toLowerCase() ?? '';
  if (text.isEmpty) return false;
  const needles = [
    'maximum context',
    'context length',
    'context window',
    'too long',
    'exceeds',
  ];
  return needles.any(text.contains);
}
