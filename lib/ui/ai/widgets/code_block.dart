// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import '../../../l10n/l10n.dart';
import '../../design/fly_tokens.dart';

/// AI 回复正文的 markdown 样式。
///
/// 直连模式与 agent 模式共用同一份 —— 两边呈现的是同一种东西（模型写给
/// 用户看的散文加代码块），字号行距不该有差别。
///
/// [baseFontSize] 让调用方按场景调密度：AI 面板用默认的 12.5（一屏尽量多
/// 信息，与「信息密度优先」一致），文件预览场景可调大 —— 那里是在**读一篇
/// 文档**，不是扫聊天记录，12.5 偏小。所有字号按比例缩放，层级关系不变。
MarkdownStyleSheet aiProseStyle(
  BuildContext context, {
  double baseFontSize = 12.5,
}) {
  // 相对基准 12.5 的缩放系数。行距是倍率，不跟着缩。
  final s = baseFontSize / 12.5;
  double f(double base) => base * s;

  return MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
    p: TextStyle(fontSize: baseFontSize, height: 1.45, color: Colors.white70),
    code: TextStyle(
      fontFamily: 'JetBrainsMono',
      fontSize: f(11.5),
      backgroundColor: Colors.white.withValues(alpha: 0.08),
    ),
    codeblockDecoration: const BoxDecoration(
      color: Colors.transparent,
      borderRadius: FlyRadius.cardRadius,
    ),
    // 标题必须逐级覆盖。
    //
    // `fromTheme` 把 h1 映射到 `headlineSmall`（24px）、h2 到 `titleLarge`
    // （22px），而正文只有 12.5px —— 差了将近两倍。真机截图（2026-09-08）
    // 里模型回了一段带 `##` 小标题的说明，标题直接把半屏占满、与紧随的正文
    // 糊成一团，用户指认「文字大小不合适」。
    //
    // 模型写小标题是常态（它在组织一段说明），所以这不是偶发内容问题，而是
    // 样式表漏了一整类元素。层级差别靠**字重**和间距表达，不靠字号：手机
    // 窄屏上 12.5 的正文配 15.5 的一级标题已经足够分明，再大就是在用一行
    // 标题换掉三行正文。
    h1: TextStyle(fontSize: f(15.5), height: 1.3, fontWeight: FontWeight.w700),
    h2: TextStyle(fontSize: f(14.5), height: 1.3, fontWeight: FontWeight.w700),
    h3: TextStyle(
      fontSize: f(13.5),
      height: 1.35,
      fontWeight: FontWeight.w600,
    ),
    h4: TextStyle(fontSize: baseFontSize, height: 1.4, fontWeight: FontWeight.w600),
    h5: TextStyle(fontSize: baseFontSize, height: 1.4, fontWeight: FontWeight.w600),
    h6: TextStyle(fontSize: baseFontSize, height: 1.4, fontWeight: FontWeight.w600),
    // 标题上方留白比下方大，让它跟着**下面**那段走，而不是浮在两段中间。
    h1Padding: const EdgeInsets.only(top: 8, bottom: 2),
    h2Padding: const EdgeInsets.only(top: 8, bottom: 2),
    h3Padding: const EdgeInsets.only(top: 6, bottom: 2),

    // ── 以下四类同样必须逐个覆盖，理由与上面标题那段完全一样 ──
    //
    // `fromTheme` 的默认值是**给浅色主题设计的**，其中 blockquote 的背景
    // 甚至是硬编码的 `Colors.blue.shade100`（`style_sheet.dart:147`），
    // 根本不看传进去的 theme。深色面板上配 `bodyMedium` 的白字，等于白字
    // 印在浅蓝底上 —— 真机截图（2026-09-13）里那段 Goal / Boundary / Done
    // 几乎读不出来。
    //
    // 这个坑是内置技能上线后才被踩到的：`plan-change` 要求模型「各用一句
    // 话说清 Goal / Boundary / Done」，模型照做时把三句写成了 blockquote。
    // 在那之前日常对话里几乎没人用 `>`，所以漏了两年也没暴露。
    blockquote: TextStyle(
      fontSize: baseFontSize,
      height: 1.45,
      color: Colors.white70,
    ),
    blockquoteDecoration: BoxDecoration(
      color: Colors.white.withValues(alpha: 0.05),
      border: const Border(left: BorderSide(color: FlyColors.active, width: 3)),
      borderRadius: BorderRadius.circular(4),
    ),
    blockquotePadding: const EdgeInsets.fromLTRB(10, 6, 8, 6),

    // 默认 5px + dividerColor，在深色面板上是一道比正文还重的粗白线。
    // 分隔线的职责是「这里断一下」，不是抢注意力。
    horizontalRuleDecoration: const BoxDecoration(
      border: Border(top: BorderSide(width: 1, color: Colors.white24)),
    ),

    // 表格默认走 `bodyMedium`（14px），比正文 12.5 大一圈，模型一输出表格
    // 排版就跳。默认的 `tableCellsPadding` 是 16/8/16/8 —— 那是桌面尺寸，
    // 手机窄屏上光左右内边距就吃掉 32px。
    tableHead: TextStyle(fontSize: baseFontSize, fontWeight: FontWeight.w700),
    tableBody: TextStyle(
      fontSize: baseFontSize,
      height: 1.35,
      color: Colors.white70,
    ),
    tableBorder: TableBorder.all(color: Colors.white24, width: 1),
    tableCellsPadding: const EdgeInsets.fromLTRB(8, 5, 8, 5),

    // ── 列表 ────────────────────────────────────────────────
    //
    // 同样必须覆盖，理由与标题/表格**完全同一类**——`fromTheme` 的列表默认值
    // 是给桌面 + 浅色主题调的：
    //
    //   `listBullet: theme.textTheme.bodyMedium`（本主题下 14px），而正文 `p`
    //   是 12.5px。于是列表项和它前面的项目符号**都比正文大一圈**，一段带
    //   列表的回答里，列表部分会明显「胖」出来。
    //
    // 为什么标题、表格之后才轮到这里：模型输出列表是**极高频行为**（让它
    // 「列出几个问题」几乎必出列表），而在此之前它一直默默地用着桌面级默认值。
    listBullet: TextStyle(
      fontSize: baseFontSize,
      height: 1.45,
      color: Colors.white70,
    ),
    // 默认 24 是桌面缩进。手机窄屏一行本就只有三十来个字，24 的缩进加项目
    // 符号再吃掉一截，正文可用宽度明显变窄。18 是「看得出缩进但对正文宽度
    // 影响可接受」的值。
    listIndent: 18,
    // 默认 4 太贴，项目符号和文字会粘在一起。
    listBulletPadding: const EdgeInsets.only(right: 6),

    // 任务列表（`- [ ]`）的勾选框。默认同样走 `bodyMedium`（14px）—— agent
    // 模式输出计划清单时常用这个语法，不覆盖就会和列表项一样「胖一圈」。
    checkbox: TextStyle(
      fontSize: baseFontSize,
      height: 1.45,
      color: Colors.white70,
    ),

    // 块之间的默认间距 8 是按 14px 正文调的。正文降到 12.5 后，段落与段落、
    // 段落与列表之间显得空，一屏放不下多少内容 —— 与「信息密度优先」的
    // 立场相反。收到 6。
    blockSpacing: 6,

    // ── 表格列宽：分层 ──────────────────────────────────────
    //
    // `IntrinsicColumnWidth(flex: 1)` —— 两层叠加：
    //
    //   1. **先按内容取内在宽度**（短列窄、长列宽）。实测一张「短标签 +
    //      一句话」的两列表（可用 326dp）：等分给两列各 147dp，而按内容
    //      分则短列 84dp / 长列 211dp —— 后者才符合阅读直觉。
    //   2. **剩余空间按 flex 均分**。纯 `IntrinsicColumnWidth`（flex 为
    //      null 时不分余量）会把短列压垮：同张表实测短列只剩 **39dp**
    //      （约 3 个中文字，字段名都显示不全）。
    //
    // 跟纯 `FlexColumnWidth`（等分）的区别：等分不看内容，长列每行多换一次。
    // 实测 26 字的长内容，等分要 3 行、按内容只要 2 行。
    //
    // ## 它同时是「滚动兜底」
    //
    // 库只在 `FixedColumnWidth` / `IntrinsicColumnWidth` 下才给表格包横向
    // 滚动（见 `aiMarkdownBuilders` 的文档）。所以这一项同时保证了：极端宽
    // 的表（列数多 + 每列都长）仍能横拖读出，而普通表格因内容内在宽度小于
    // 屏宽，**根本不产生滚动** —— 正合「非必要不滚动」。
    //
    // 注：在受约束容器里（`MarkdownBody` 就是），没有任何列宽类型会让表格
    // 真的溢出屏宽 —— 实在放不下时 Flutter 压缩单元格，不是撑破布局。
    // 所以这里的取舍是**列宽如何分配**，而不是「会不会溢出」。
    tableColumnWidth: const IntrinsicColumnWidth(flex: 1),

    // 不画那根滚动条（滚动能力保留，见上）。
    //
    // 不设这个值时走 Flutter 默认：Android 上是 4px 粗、无圆角的直角条，
    // 且**只在滚动时突然冒出来**。它压在 12.5px 的正文旁边比正文还扎眼，
    // 直角也与整套圆角语汇（2/4/6/8/10）冲突。
    //
    // 移动端横向滚动本来就靠手势、不靠滚动条 —— iOS/Android 原生列表都不
    // 常显，常显是 Web/桌面的习惯。
  tableScrollbarThumbVisibility: false,
  );
}

// ---------------------------------------------------------------------------
// AI 正文的 markdown builder 集合
// ---------------------------------------------------------------------------

/// AI 回复正文的 markdown builder 集合。
///
/// 直连模式与 agent 模式共用构造，但**动作按钮的开关不同**（`showActions`）：
/// agent 模式不该给它手动执行围栏内容的入口，否则模型用 ``` 包一段中文计划
/// 时，「执行」会把那段中文原样送进终端（2026-09-09 真机截图）。
///
/// 抽成函数而不是让两处各自写一遍：两个调用点（`agent_view` 与
/// `message_bubble`）之前是重复的，改一处忘了另一处就会出现
/// 「同一个回答在两种模式里渲染得不一样」。
///
/// ## 表格滚动不在这个 map 里
///
/// 库（`flutter_markdown_plus` 的 `builder.dart`）**自己会为表格包一层横向
/// 滚动 + Scrollbar**，但触发条件是 `tableColumnWidth` 为 `FixedColumnWidth`
/// 或 `IntrinsicColumnWidth` —— 默认的 `FlexColumnWidth` 不触发。
/// 所以那件事靠 `aiProseStyle` 里把列宽改成 `IntrinsicColumnWidth` 完成，
/// 这里不需要（也不应该有）额外的 builder。
Map<String, MarkdownElementBuilder> aiMarkdownBuilders({
  bool showActions = true,
  void Function(String)? onRun,
  void Function(String)? onSave,
  void Function(String)? onExplain,
}) => {
  'code': CodeBlockBuilder(
    showActions: showActions,
    onRun: onRun,
    onSave: onSave,
    onExplain: onExplain,
  ),
};

// ---------------------------------------------------------------------------
// Markdown code block builder — replaces default code rendering with our
// custom CodeBlock widget that has Run / Save / Explain action buttons.
// ---------------------------------------------------------------------------

class CodeBlockBuilder extends MarkdownElementBuilder {
  final void Function(String)? onRun;
  final void Function(String)? onSave;
  final void Function(String)? onExplain;

  /// 是否渲染底部那一行动作按钮（复制 / 解释 / 收藏 / 执行）。
  ///
  /// **agent 模式传 false。** 那里命令由模型发起、走审批卡，用户不需要也不
  /// 该手动执行一段围栏内容。而围栏并不保证是命令 —— 是否显示按钮只看「有
  /// 没有回调」，不看 `language`，所以模型把一段中文计划用 ``` 包起来时，
  /// 「执行」会把那段中文原样送进终端（2026-09-09 真机截图）。
  ///
  /// 直连模式保持 true：那个模式没有工具调用也没有审批，这一行是把命令送进
  /// 终端的唯一入口，去掉等于把能力也去掉。
  final bool showActions;

  CodeBlockBuilder({
    this.onRun,
    this.onSave,
    this.onExplain,
    this.showActions = true,
  });

  @override
  Widget? visitElementAfter(element, TextStyle? preferredStyle) {
    final code = element.textContent.trimRight();
    if (!element.attributes.containsKey('class') && !code.contains('\n')) {
      return null; // let inline code render normally
    }
    final langClass = element.attributes['class'] ?? '';
    final lang = langClass.replaceFirst('language-', '');
    return CodeBlock(
      code: code,
      language: lang,
      onRun: onRun,
      onSave: onSave,
      onExplain: onExplain,
      showActions: showActions,
    );
  }
}

class CodeBlock extends StatelessWidget {
  final String code;
  final String language;
  final void Function(String)? onRun;
  final void Function(String)? onSave;
  final void Function(String)? onExplain;

  /// 见 [CodeBlockBuilder.showActions]。
  final bool showActions;

  const CodeBlock({
    super.key,
    required this.code,
    this.language = '',
    this.onRun,
    this.onSave,
    this.onExplain,
    this.showActions = true,
  });

  @override
  Widget build(BuildContext context) {
    const accent = FlyColors.active;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.45),
        borderRadius: FlyRadius.cardRadius,
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Language label + code text
          if (language.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: Text(
                language,
                style: const TextStyle(
                  fontFamily: 'JetBrainsMono',
                  fontSize: 10,
                  color: Colors.white24,
                ),
              ),
            ),
          Padding(
            padding: EdgeInsets.fromLTRB(
              12,
              language.isNotEmpty ? 4 : 10,
              12,
              6,
            ),
            child: SelectableText(
              code,
              style: const TextStyle(
                fontFamily: 'JetBrainsMono',
                fontSize: 12.5,
                color: Colors.white,
              ),
            ),
          ),
          // Action row
          if (showActions)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  // Copy
                  PanelActionChip(
                    icon: Icons.copy,
                    label: context.l10n.aiCopyAction,
                    onTap: () => Clipboard.setData(ClipboardData(text: code)),
                  ),
                  if (onExplain != null) ...[
                    const SizedBox(width: 6),
                    PanelActionChip(
                      icon: Icons.info_outline,
                      label: context.l10n.aiExplainAction,
                      onTap: () => onExplain!(code),
                    ),
                  ],
                  if (onSave != null) ...[
                    const SizedBox(width: 6),
                    PanelActionChip(
                      icon: Icons.star_border,
                      label: context.l10n.aiSaveAction,
                      onTap: () => onSave!(code),
                    ),
                  ],
                  const SizedBox(width: 6),
                  if (onRun != null)
                    PanelActionChip(
                      icon: Icons.play_arrow,
                      label: context.l10n.aiRunAction,
                      accent: true,
                      accentColor: accent,
                      onTap: () => onRun!(code),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class PanelActionChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool accent;
  final Color? accentColor;
  final VoidCallback onTap;

  const PanelActionChip({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.accent = false,
    this.accentColor,
  });

  @override
  Widget build(BuildContext context) {
    final color = accent
        ? (accentColor ?? Theme.of(context).colorScheme.primary)
        : Colors.white54;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          border: Border.all(color: color.withValues(alpha: 0.5)),
          borderRadius: BorderRadius.circular(6),
          color: accent ? color.withValues(alpha: 0.15) : Colors.transparent,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 13, color: color),
            const SizedBox(width: 4),
            Text(label, style: TextStyle(fontSize: 12, color: color)),
          ],
        ),
      ),
    );
  }
}
