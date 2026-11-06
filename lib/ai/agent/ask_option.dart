// SPDX-License-Identifier: GPL-3.0-or-later
/// `ask_user` 的一个候选项。
///
/// [label] 短、可点；[description] 可选的一行补充。分成两个字段而不是一段
/// 长文本，是因为手机上按钮文字一长就折行——解释放在按钮下面而不是里面。
class AskOption {
  final String label;
  final String? description;

  const AskOption({required this.label, this.description});
}

/// 一次参数解析的结果。
///
/// [error] 非 null 时 [options] 为空，调用方直接回一条 isError。
/// [note] 非 null 时解析成功但有需要告知模型的调整（目前只有截断）。
class AskOptionsParse {
  final List<AskOption> options;
  final String? error;
  final String? note;

  const AskOptionsParse(this.options, {this.error, this.note});
}

/// 选项个数上限。
///
/// 4 是屏幕宽度与决策成本的双重约束：手机上放不下更多，而且选项一多，用户
/// 读完四项再挑一项的成本就超过直接打字了——那时这个工具反而是负收益。
const int kMaxAskOptions = 4;

/// 选项个数下限。
///
/// 只有一个答案的问题不该问：模型已经知道答案了，问只是把决定推给用户。
const int kMinAskOptions = 2;

/// 把模型给的 `options` 参数解析成 [AskOption] 列表。
///
/// **纯函数、无 IO**，所以边界能直接单测，不必装配 loop。
///
/// 非 Map 的项、label 为空的项都被**丢弃而不是报错**：模型偶尔会混进一个
/// 裸字符串，为此整个调用失败不如用剩下的继续——只有丢到不足 [kMinAskOptions]
/// 时才报错。
AskOptionsParse parseAskOptions(List<Object?> raw) {
  final out = <AskOption>[];
  for (final item in raw) {
    if (item is! Map) continue;
    final label = item['label'];
    if (label is! String || label.trim().isEmpty) continue;
    final desc = item['description'];
    out.add(AskOption(
      label: label.trim(),
      description:
          desc is String && desc.trim().isNotEmpty ? desc.trim() : null,
    ));
  }

  if (out.length < kMinAskOptions) {
    return const AskOptionsParse(
      [],
      error: 'Provide at least two options with a non-empty `label`. '
          'If there is only one possible answer, do not ask.',
    );
  }
  if (out.length > kMaxAskOptions) {
    return AskOptionsParse(
      out.take(kMaxAskOptions).toList(growable: false),
      note: 'Only the first $kMaxAskOptions options were shown to the user; '
          'the rest were dropped.',
    );
  }
  return AskOptionsParse(out);
}

/// 分类标签的**码点**上限。
///
/// 手机上它与问题句共占一行，再长就把问题挤到第二行去了——而标签只是导航
/// 用的提示词，不该抢问题的位置。超出**截断而不报错**：为一个装饰性字段让
/// 整次调用失败不划算。
///
/// **按码点（rune）数而不是 UTF-16 code unit 数计。** 模型给中文用户写标签
/// 时混进 emoji、生僻扩展 CJK 一点也不罕见，这些字符在 UTF-16 里占两个
/// code unit（代理对）；按 code unit 数截断，截断点一旦落在代理对中间，
/// 就会把一个字符劈成两半，留下孤立代理项、渲染成乱码方块——`ask_user`
/// 清单本来就在防同一类坑（`? ○ ✓ ✗ ✎` 不能被 emoji 字体接管），不能在
/// 同一类边界上再栽一次。见 [truncateAskHeader]。
const int kMaxAskHeaderChars = 12;

/// 把模型给的 `header` 截到 [kMaxAskHeaderChars] 个码点，不切碎代理对。
///
/// **纯函数**：只做 trim + 按码点截断，不判断 header 是否存在——调用方
/// （`AskExecutors.askUser`）已经决定「这是不是一个字符串」，这里只管截。
///
/// 用 `.runes` 而不是 `.substring`：后者按 UTF-16 code unit 切，会把
/// emoji 一类的代理对从中间劈开（见 [kMaxAskHeaderChars] 的说明）。项目里
/// `attach_path.dart` 处理文件名边界、`terminal_screen.dart` 处理终端输出
/// 边界时都是同一个理由用 `.runes`，这里照抄那个先例。
String truncateAskHeader(String raw) {
  final trimmed = raw.trim();
  final runes = trimmed.runes.toList();
  return runes.length > kMaxAskHeaderChars
      ? String.fromCharCodes(runes.take(kMaxAskHeaderChars))
      : trimmed;
}

/// 拼出回给模型的 `tool_result` 内容：选中的答案 + 需要模型知道的注解。
///
/// 顺序固定：[choice] 本身 → free-form 提示（不在选项列表里时）→
/// [AskOptionsParse.note] 里的截断说明（选项被截断过时）。判据是「不在
/// label 列表里」——用户在输入框里打的字恰好等于某个 label 时按选项算，
/// 那本来就是同一个答案，不需要 free-form 提示。
///
/// **纯函数、无 IO**，与 [parseAskOptions] 同一个理由：这里的分支该在
/// 单测里直接钉住，不必装配 `AgentLoop` 走完一轮挂起/应答。
String formatAskAnswerContent(String choice, AskOptionsParse parsed) {
  final parts = <String>[choice];
  if (!parsed.options.any((o) => o.label == choice)) {
    parts.add('(free-form answer, not one of the offered options)');
  }
  if (parsed.note != null) parts.add('(${parsed.note})');
  return parts.join('\n\n');
}
