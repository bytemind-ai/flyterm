// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';

/// 提供给模型的工具声明。[parameters] 是 JSON Schema。
class ToolSpec {
  final String name;
  final String description;
  final Map<String, dynamic> parameters;

  const ToolSpec({
    required this.name,
    required this.description,
    required this.parameters,
  });
}

/// 模型请求的一次工具调用。
class ToolCall {
  final String id;
  final String name;
  final Map<String, dynamic> args;

  const ToolCall({required this.id, required this.name, required this.args});

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'args': args};

  static ToolCall fromJson(Map<String, dynamic> j) => ToolCall(
        id: j['id'] as String,
        name: j['name'] as String,
        args: (j['args'] as Map?)?.cast<String, dynamic>() ?? const {},
      );
}

/// 一次工具调用的结果，回填给模型。
class ToolResult {
  final String callId;
  final String content;
  final bool isError;

  /// 命令的退出码。null 表示这条结果不是命令执行产生的（参数非法、用户
  /// 拒绝、执行前就失败）。
  ///
  /// 存在这里而不只存在 `ToolCallEvent` 上，是因为上下文丢弃时要把它写进
  /// marker —— 模型据此判断「那条查过了、成功了」还是「那条失败了，也许
  /// 该再看看」。丢弃发生在 `_history` 上，那里只有 ToolResult。
  ///
  /// `SshCommandRunner` 在超时和「拿不到退出码」两种情况下都填 -1 ——
  /// 那是「没有退出码」的哨兵值，不是任何真实进程能返回的值（POSIX 是
  /// 0–255）。这个哨兵本身承载了两种不同原因，光看 -1 分不清，所以需要
  /// [timedOut] 把其中一种原因单独标出来。
  final int? exitCode;

  /// 命令是否因超时被杀死。true 时 [exitCode] 恒为 -1。
  ///
  /// 丢弃 marker 需要区分「没跑完」和「跑完了但失败」——超时是排查场景里
  /// 的高频失败模式，`exit -1` 对模型是个没有先验含义的数字，容易被当成
  /// 解析错误或直接忽略，而 `timed out` 是可以直接理解的信号。
  final bool timedOut;

  const ToolResult({
    required this.callId,
    required this.content,
    this.isError = false,
    this.exitCode,
    this.timedOut = false,
  });

  Map<String, dynamic> toJson() => {
        'callId': callId,
        'content': content,
        if (isError) 'isError': true,
        // 判空只判 null，**不能**顺手把 0 也排除掉 —— exit 0 是最常见的
        // 情形，丢了它 marker 就分不出成功与失败。
        if (exitCode != null) 'exitCode': exitCode,
        // 与 isError 同样的处理：默认 false 时不写进 json，省字节。
        if (timedOut) 'timedOut': true,
      };

  static ToolResult fromJson(Map<String, dynamic> j) => ToolResult(
        callId: j['callId'] as String,
        content: j['content'] as String? ?? '',
        isError: j['isError'] as bool? ?? false,
        exitCode: (j['exitCode'] as num?)?.toInt(),
        timedOut: j['timedOut'] as bool? ?? false,
      );
}

/// 一次请求的 token 用量，用于**观测**。不参与任何逻辑判断 —— 预算判断走
/// `AgentLoop._estimateTokens()`，那个不依赖服务端返回。
///
/// ## 字段语义必须写死，否则三家的数字没法比
///
/// [inputTokens] 是**全价**输入 token，**不含**缓存命中部分。这个归一化是
/// 刻意的，因为两家的原始字段口径相反：
///
/// - Anthropic 的 `input_tokens` 本来就不含缓存读取（另有
///   `cache_read_input_tokens`）→ 原样取
/// - OpenAI 的 `prompt_tokens` **包含** `cached_tokens` → 必须相减
///
/// 不归一化的话，同一段对话在两家会显示出成倍的差距，而那纯粹是口径差异。
///
/// 缓存**写入**（Anthropic 的 `cache_creation_input_tokens`）按 1.25 倍计费，
/// 仍属全价档，因此并入 [inputTokens] 而不是 [cachedTokens]。
class TokenUsage {
  final int inputTokens;
  final int cachedTokens;
  final int outputTokens;

  const TokenUsage({
    this.inputTokens = 0,
    this.cachedTokens = 0,
    this.outputTokens = 0,
  });

  /// 送进模型的输入总量（全价 + 缓存命中）。
  int get totalInput => inputTokens + cachedTokens;

  bool get isEmpty =>
      inputTokens == 0 && cachedTokens == 0 && outputTokens == 0;

  TokenUsage operator +(TokenUsage o) => TokenUsage(
        inputTokens: inputTokens + o.inputTokens,
        cachedTokens: cachedTokens + o.cachedTokens,
        outputTokens: outputTokens + o.outputTokens,
      );
}

/// 把服务端报的 token 计数转成 int，**任何取不到的情形都返回 0**。
///
/// 不用 `as num?` 硬转：字段**存在但不是数字**时那会抛 `TypeError`，而这些
/// 字段来自别人的服务器 —— OpenAI 兼容代理把数字序列化成字符串（`"5000"`）
/// 很常见，第三方 Ollama 兼容服务也有。
///
/// 抛出来的后果与 [AIResponse.usage] 的契约直接冲突：异常会穿过 provider 的
/// `try`（那里只 catch `DioException`），落到 `AgentLoop` 的通用 catch，于是
/// 整轮被判成 error —— 尽管正文和工具调用都已经解析成功了。一个纯展示用的
/// 数字不该有能力做到这件事。
int asTokenCount(dynamic v) {
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v) ?? double.tryParse(v)?.toInt() ?? 0;
  return 0;
}

/// 一轮模型响应的归一化形态。三家 provider 的 wire format 差异全部在各自
/// provider 文件里消化，loop 只看这个类型。
class AIResponse {
  final String text;
  final List<ToolCall> toolCalls;

  /// 服务端报告的用量。三家都可能给不全，缺的字段按 0 处理 —— 它只用于
  /// 展示，取不到就不显示，绝不能因此影响这一轮的结果。
  final TokenUsage usage;

  const AIResponse({
    this.text = '',
    this.toolCalls = const [],
    this.usage = const TokenUsage(),
  });

  bool get hasToolCalls => toolCalls.isNotEmpty;
}

/// 解析 tool call 的参数。
///
/// OpenAI 把 arguments 编码成 **JSON 字符串**，Anthropic 和 Ollama 给的是
/// **对象**。两种都要吃，且非法 JSON 不能抛 —— 模型确实会偶尔吐出坏 JSON，
/// 那种情况走 `isError` 回填让它自纠，而不是把 loop 打断。
Map<String, dynamic> parseToolArgs(dynamic raw) {
  if (raw == null) return {};
  // 用 Map.from 而不是 .cast()：后者返回惰性视图，键类型不符时不在这里抛，
  // 而是等到远处某次遍历（jsonEncode / .keys）才炸，堆栈指不回问题源头。
  if (raw is Map) return Map<String, dynamic>.from(raw);
  if (raw is String) {
    if (raw.trim().isEmpty) return {};
    try {
      final d = jsonDecode(raw);
      if (d is Map) return d.cast<String, dynamic>();
    } catch (_) {}
  }
  return {};
}

/// 判断一段 tool-call 参数文本是否**被截断**。
///
/// ## 为什么不能用 `parseToolArgs(raw).isEmpty` 代替
///
/// 那个判断分不清两种完全不同的情形，因为两者都返回空 map：
///
/// - `'{}'` —— 合法的空参数对象（无参工具的正常调用）
/// - `'{"command":"ls'` —— 流在参数中途断掉，JSON 只有半截
///
/// 前者必须保留，后者必须丢弃：一个 `bash` 调用少了 `command` 会被当成
/// 就绪的调用送去审批和执行，而 [AgentChunk] 的 `ToolCallReady` 契约明确
/// 写着「不发半成品」。
///
/// 空串返回 false —— 模型压根没发参数与「发了一半」是两回事，前者交给
/// 工具层去回 isError 让它自纠。
///
/// 两家 provider（Anthropic 的 `input_json_delta`、OpenAI 的 `arguments`
/// 片段）共用这一份实现。各写一份必然漂：截断是罕见路径，漂了没人发现。
bool isTruncatedToolArgs(String raw) {
  if (raw.isEmpty) return false;
  try {
    return jsonDecode(raw) is! Map;
  } catch (_) {
    return true;
  }
}

/// 文件写入类工具的审批/展示载荷。
///
/// 审批卡靠它渲染「改了什么」。做成独立类型而不是往 [ToolCall] 的 args 里
/// 塞 —— args 是模型给的原始输入，这个是我们算过之后的结果（含行号、含
/// 校验通过的现有内容），两者不该混。
class FileEditPreview {
  final String path;

  /// 被替换掉的原文。null 表示整份覆盖（`write_file`）。
  final String? oldText;
  final String newText;

  /// 命中的起始行号（1-based）。整份覆盖时为 null。
  final int? atLine;

  const FileEditPreview({
    required this.path,
    this.oldText,
    required this.newText,
    this.atLine,
  });

  Map<String, dynamic> toJson() => {
        'path': path,
        if (oldText != null) 'oldText': oldText,
        'newText': newText,
        if (atLine != null) 'atLine': atLine,
      };

  static FileEditPreview fromJson(Map<String, dynamic> j) => FileEditPreview(
        path: j['path'] as String? ?? '',
        oldText: j['oldText'] as String?,
        newText: j['newText'] as String? ?? '',
        atLine: (j['atLine'] as num?)?.toInt(),
      );
}

/// 流式 tool-calling 的一个增量片段。三家 provider 的 wire format 差异在各自
/// provider 文件里消化成这三种形态，`AgentLoop` 只看这个类型。
///
/// ## 为什么 [StreamDone] 要携带完整的 [AIResponse]
///
/// `AgentLoop` 后续逻辑（`_history.add`、`_totalUsage`、`hasToolCalls` 判定）
/// 全部依赖那个对象。让 loop 侧自己把 [TextDelta] 与 [ToolCallReady] 攒成
/// 一个 AIResponse，等于把「文本拼接顺序」「usage 从哪来」这些三家各不相同
/// 的细节漏回上层——那正是这套归一化要消掉的东西。
sealed class AgentChunk {
  const AgentChunk();
}

/// 一段文本增量。可能是一个字，也可能是一整句。
final class TextDelta extends AgentChunk {
  final String text;
  const TextDelta(this.text);
}

/// 一次工具调用的参数**已经拼完整**，可以执行了。
///
/// 三家都会分片发送参数（Anthropic 的 `input_json_delta`、OpenAI 的
/// `arguments` 片段），拼不完整的 JSON 无法执行，所以这个 chunk 只在
/// 一个 tool call 完全就绪时才发出——不发半成品。
final class ToolCallReady extends AgentChunk {
  final ToolCall call;
  const ToolCallReady(this.call);
}

/// 流正常结束，携带这一轮的定稿响应。
final class StreamDone extends AgentChunk {
  final AIResponse response;
  const StreamDone(this.response);
}

/// 这个异常是**我们自己的代码 bug**，而不是一次正常的执行失败。
///
/// 判据取 `TypeError` / `NoSuchMethodError` 两类：命令返回非 0、超时、连接
/// 断开这些是正常的执行失败，它们的 message 本身就说明了问题；而这两类必然
/// 是某处在 null 上用了 `!`、或者调了一个不存在的方法 —— 那种情况下 message
/// （典型如 `Null check operator used on a null value`）零信息量，不带栈就
/// 只能靠在源码里逐个 grep `!`。
///
/// 与 `agent_loop.dart` 的 `describeToolError` 共用这一条判据：同一个异常
/// 在「给模型的 tool_result」与「给用户的卡片」上必须归为同一类，否则会出现
/// 模型拿到了栈、用户面前只有一句话的割裂（2026-09-13 排查真机
/// 「切后台后命令执行失败」时就是这样：栈明明记下了，却没有任何界面读它）。
bool isCodeBugError(Object e) => e is TypeError || e is NoSuchMethodError;

/// 工具失败时写进 `ToolCallEvent.output`（也就是卡片上）的文案。
///
/// 代码 bug 类附前 4 帧栈，其余原样。4 帧够定位到出事的那个函数，又不至于
/// 把卡片撑满 —— 与 `describeToolError` 取同样的帧数。
String toolErrorForCard(Object e, StackTrace st) {
  if (!isCodeBugError(e)) return e.toString();
  return '$e\n${st.toString().split('\n').take(4).join('\n')}';
}
