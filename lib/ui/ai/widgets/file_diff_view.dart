// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';

import '../../../ai/agent/tool_models.dart';
import '../../../l10n/l10n.dart';

/// 审批卡里的文件改动预览。
///
/// **不做逐行 diff 算法。** `edit_file` 给的就是 old_string / new_string
/// 两段文本，直接摆出来比算一遍 Myers 更准确、也更适合窄屏 —— 手机上一行
/// 放不下几个字，逐行 diff 的上下文行只会把关键的两行挤出屏幕。
class FileDiffView extends StatelessWidget {
  final FileEditPreview preview;

  const FileDiffView({super.key, required this.preview});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l = context.l10n;
    final mono = theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          preview.atLine == null
              ? preview.path
              : l.agentDiffAtLine(preview.path, preview.atLine!),
          style: theme.textTheme.labelSmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        // oldText 与 newText 各自可能超限，各自独立折叠/展开 —— 不要共用
        // 一个开关，否则会出现「newText 展开了但 oldText 还是那句提示」
        // 这种对不上的状态。
        if (preview.oldText != null)
          _DiffBlock(
            text: preview.oldText!,
            background: theme.colorScheme.errorContainer,
            style: mono,
          ),
        _DiffBlock(
          text: preview.newText,
          background: theme.colorScheme.primaryContainer,
          style: mono,
        ),
      ],
    );
  }
}

/// old/new 其中一段文本的展示块。
///
/// `write_file` / `edit_file` 单次上限 6000 字节，等宽字体下能轻松写到
/// 大几十行 —— 远超默认折叠的 12 行。**折叠但不给出口**等于让用户对着
/// 一屏「看起来完整」的内容点允许，实际却批准了他没看到的大半部分。审批
/// 卡存在的全部理由就是让用户知道自己在同意什么，所以折叠时必须给一个
/// 「展开」入口，而不是截断了事。
///
/// 判断是否需要折叠用 [TextPainter] 实测排版结果是否超过 12 行，而不是
/// 数文本里 `\n` 的个数 —— `maxLines` 限的是渲染后的行数（含自动换行），
/// 一行 300 字符的内容在窄屏上会自己折成好几行，按 `\n` 数算会漏判。
class _DiffBlock extends StatefulWidget {
  final String text;
  final Color background;
  final TextStyle? style;

  const _DiffBlock({
    required this.text,
    required this.background,
    this.style,
  });

  @override
  State<_DiffBlock> createState() => _DiffBlockState();
}

class _DiffBlockState extends State<_DiffBlock> {
  static const _collapsedMaxLines = 12;
  bool _expanded = false;

  bool _exceedsMaxLines(TextScaler textScaler, double maxWidth) {
    if (maxWidth <= 0) return false;
    final painter = TextPainter(
      text: TextSpan(text: widget.text, style: widget.style),
      maxLines: _collapsedMaxLines,
      textDirection: TextDirection.ltr,
      textScaler: textScaler,
    )..layout(maxWidth: maxWidth);
    return painter.didExceedMaxLines;
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final theme = Theme.of(context);

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 4),
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: widget.background,
        borderRadius: BorderRadius.circular(4),
      ),
      child: widget.text.isEmpty
          ? SelectableText(l.agentDiffEmpty, style: widget.style)
          : LayoutBuilder(
              builder: (context, constraints) {
                final overflow = _exceedsMaxLines(
                  MediaQuery.textScalerOf(context),
                  constraints.maxWidth,
                );
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SelectableText(
                      widget.text,
                      maxLines:
                          overflow && !_expanded ? _collapsedMaxLines : null,
                      style: widget.style,
                    ),
                    if (overflow)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: InkWell(
                          onTap: () => setState(() => _expanded = !_expanded),
                          child: Text(
                            _expanded
                                ? l.agentDiffCollapse
                                : l.agentDiffExpand,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: theme.colorScheme.primary,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                  ],
                );
              },
            ),
    );
  }
}
