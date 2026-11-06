// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';

import '../ai_message.dart';
import '../attachment.dart';
import 'tool_models.dart';

/// 一个中日韩字符算多少 token。
///
/// 实测：中文提问 31 字符 → 33 token，中文回复 126 字符 → 105 token
/// （2026-09-14，count_tokens，claude-opus-5）。
const double kCjkTokensPerChar = 1.2;

/// 散文里多少个非中日韩字符算一个 token。
///
/// 实测 system prompt 3.10、技能正文 2.86–3.00 chars/tok。
const double kProseCharsPerToken = 3.0;

/// 结构化输出（命令输出、日志）里多少个非中日韩字符算一个 token。
///
/// 实测真实命令输出合计 1.88 chars/tok（`ps aux` / `df -h` / `ls -la` /
/// `dpkg.log` / `git log --stat` / `flutter analyze`，六种共 20421 字符）。
///
/// **比散文贵近一倍**，因为时间戳、IP、路径、数字、标点在 BPE 下极耗
/// token。原来那个全局 3.5 正是按英文散文标定的，对这一类系统性低估近一倍
/// —— 而命令输出恰恰是排查会话历史里占比最大的那部分。
const double kStructuredCharsPerToken = 2.0;

/// JSON（工具调用参数、工具 schema）里多少个非中日韩字符算一个 token。
///
/// 实测工具 schema 2.51 chars/tok。
const double kJsonCharsPerToken = 2.5;

/// 中日韩判定。
///
/// 只判表意文字与中日韩/全角标点：估算要区分的是「一字约一 token」的表意
/// 文字与「几字一 token」的拉丁文本。假名与谚文行为同侧，但在 flyterm 的
/// 语料里几乎不出现，为它们扩大判定范围只增加误判面，不增加准确度。
bool _isCjk(int rune) =>
    (rune >= 0x4E00 && rune <= 0x9FFF) || // 统一表意文字
    (rune >= 0x3400 && rune <= 0x4DBF) || // 扩展 A
    (rune >= 0xF900 && rune <= 0xFAFF) || // 兼容表意文字
    (rune >= 0x3000 && rune <= 0x303F) || // 中日韩符号与标点「」。
    (rune >= 0xFF00 && rune <= 0xFFEF); // 全角字符，：

/// 中日韩字符数与其余字符数。
///
/// 做成可累加的类而不是返回记录：`estimateMessageTokens` 要把一条消息里
/// 多个字符串归到同一段速率下，逐个 split 再相加会多出一堆临时对象，而这
/// 个函数在 `_dropOldOutputsIfNeeded` 的 while 循环里会被反复调用。
class _Counts {
  int cjk = 0;
  int other = 0;

  void add(String s) {
    for (final r in s.runes) {
      if (_isCjk(r)) {
        cjk++;
      } else {
        other++;
      }
    }
  }

  double at(double charsPerToken) =>
      cjk * kCjkTokensPerChar + other / charsPerToken;
}

double _tokens(String s, double charsPerToken) =>
    (_Counts()..add(s)).at(charsPerToken);

/// 散文（system / user / assistant 的正文）的 token 估算。
double proseTokens(String s) => _tokens(s, kProseCharsPerToken);

/// 结构化输出（工具结果）的 token 估算。
double structuredTokens(String s) => _tokens(s, kStructuredCharsPerToken);

/// 估算一条消息占多少 token。
///
/// **`AgentLoop._estimateTokens()` 与 `findCompactionCut` 必须共用这一个
/// 实现。** 两者口径一旦分裂，「保留 25% 预算」这个判断就会和触发压缩的
/// 那个判断打架：一边觉得该压，一边觉得压完还是超。
///
/// 从前这条约束只写在注释里、靠两个文件各维护一份估算来遵守 —— 那正是本次
/// 改动差点漏掉的地方。抽到这里之后它是结构保证。
///
/// ## 为什么按 role 分段
///
/// `m.content` 是散文，`r.content`（工具结果）是命令输出，两者的 chars/tok
/// 差近一倍（3.10 vs 1.88）。分辨内容类型看起来需要内容分析，其实不用 ——
/// 它们本来就是两个不同的字段，这个区分免费，而且正好落在实测分界线上。
///
/// ## 一处有意接受的偏高
///
/// 技能正文是英文 markdown（实测仅 1% 中文），却经 `load_skill` 的**工具
/// 输出**进历史，于是走结构化速率，偏高约 43%（单条约多算 500 token，
/// 最多同时载两条）。不为它加「像不像散文」的启发式：那会把一个免费且
/// 精确的判据换成一个会误判的判据。而且偏高是安全方向 —— 早压缩丢上下文
/// 比晚压缩撞上下文上限可恢复。
int estimateMessageTokens(AIMessage m) {
  final prose = _Counts()..add(m.content);
  final structured = _Counts();
  final json = _Counts();
  for (final r in m.toolResults ?? const <ToolResult>[]) {
    structured.add(r.content);
  }
  for (final t in m.toolCalls ?? const <ToolCall>[]) {
    json.add(t.name);
    t.args.forEach((k, v) {
      json.add(k);
      json.add('$v');
    });
  }
  final tok = prose.at(kProseCharsPerToken) +
      structured.at(kStructuredCharsPerToken) +
      json.at(kJsonCharsPerToken) +
      // 图片没有 content 长度，但实实在在占 token。不计入的话，一轮里连发
      // 三张图的历史会被算成「很短」，压缩不压、预算熔断不响。
      imageCount(m.attachments) * kImageTokens;
  return tok.round();
}

/// 工具 schema 的 token 数。
///
/// **这一项在旧实现里被结构性漏算**：`_estimateTokens()` 只遍历 `_history`，
/// 而工具 schema 是单独传给 provider 的。full 档实测 3739 token —— 相当于
/// 整整一段 system prompt 从来没进过账。
///
/// 按 provider 线上的形状序列化再估，而不是把 name/description/schema 分开
/// 累加：后者会漏掉 JSON 的结构字符（引号、逗号、花括号），实测差 8%。
int estimateToolSchemaTokens(List<ToolSpec> specs) {
  final wire = jsonEncode([
    for (final s in specs)
      {
        'name': s.name,
        'description': s.description,
        'input_schema': s.parameters,
      },
  ]);
  return (_Counts()..add(wire)).at(kJsonCharsPerToken).round();
}
