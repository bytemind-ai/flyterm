// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';

import 'package:flutter/material.dart';

import '../../../l10n/l10n.dart';

/// 一段输出的行数。
///
/// 用 [LineSplitter] 而不是数 `\n`：命令输出通常以换行结尾，`'a\n'` 数
/// 出来是 2 行而实际只有 1 行 —— 标签上写「2 行」而展开只有一行，是那种
/// 没人会报但每次都别扭的错。
int countLines(String s) {
  final t = s.trimRight();
  if (t.isEmpty) return 0;
  return const LineSplitter().convert(t).length;
}

/// 事件流里「已经结束的事」的统一形态。
///
/// 存在的理由是密度：2026-09-09 算过一笔账 —— 一轮典型排查占
/// 956px，而手机对话区只有约 600px，屏幕被已经过去的事情占满，AI 的结论
/// 反而要滚动才找得到。终态卡片脱掉边框、背景与纵向 padding 之后，同一轮
/// 落在 466px。
///
/// **不截断是硬约束。** [spans] 里的命令原文永远完整渲染，超宽折行而不是
/// 省略 —— `ed7bbe9` 回退过一次单行 + ellipsis 的实现，因为命令的信息量
/// 集中在尾部（文件路径、参数），ellipsis 砍的正是尾部。所以这里既不设
/// `maxLines` 也不设 `overflow`，任何后来者想加都要先读那条 revert。
///
/// 用 [SelectableText.rich] 而不是 `Text.rich` 是为了保住长按选中复制。
class DenseEventRow extends StatefulWidget {
  /// 状态图标，约定 16px —— 它决定行的最小高度。
  final Widget leading;

  /// 富文本段，由调用方拼。描述、命令、耗时、状态后缀都在这里。
  final List<InlineSpan> spans;

  /// 右侧计数标签（「12 行」「12.4 KB」）。null = 不显示。
  final String? trailingLabel;

  /// 展开区内容。null = 没有可展开的东西，连展开钮都不渲染。
  final WidgetBuilder? expanded;

  const DenseEventRow({
    super.key,
    required this.leading,
    required this.spans,
    this.trailingLabel,
    this.expanded,
  });

  @override
  State<DenseEventRow> createState() => _DenseEventRowState();
}

class _DenseEventRowState extends State<DenseEventRow> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l = context.l10n;
    final canExpand = widget.expanded != null;

    return Padding(
      // 水平 8 与各完整卡 margin 的水平值一致：两档混排时左边缘对齐，
      // 不会出现「有的卡缩进多一点」的抖动。
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: widget.leading,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: SelectableText.rich(
                  TextSpan(children: widget.spans),
                  style: theme.textTheme.bodySmall,
                ),
              ),
              // 计数标签与展开钮合成**一个**热区。
              //
              // 真机反馈：单独压到 28×20 的图标钮不好点 —— 那只有推荐触摸
              // 目标（48×48）的四分之一。但纵向不能加，加了行高就回去了，
              // 密度优化当场归零。
              //
              // 横向是免费的：行高由内容决定，把热区拉宽不影响它。把「12 行」
              // 一起纳进来既扩了面积，也符合直觉 —— 用户本来就会去点那个数字。
              // 实际热区从 28×20 变成约 70×26，面积三倍，视觉一模一样。
              if (canExpand || widget.trailingLabel != null)
                _TrailingTapTarget(
                  label: widget.trailingLabel,
                  open: _open,
                  // 没有展开区时（例如 TruncatedEvent）只显示标签，不给
                  // 手势也不给箭头 —— 点开一片空白会让人以为功能坏了。
                  onTap: canExpand
                      ? () => setState(() => _open = !_open)
                      : null,
                  tooltip: _open ? l.agentToolCollapse : l.agentToolExpand,
                ),
            ],
          ),
          if (_open && canExpand)
            Padding(
              // 左 22 = 图标 16 + 间隔 6，让展开内容与文本左缘对齐。
              padding: const EdgeInsets.only(left: 22, top: 4, bottom: 2),
              child: widget.expanded!(context),
            ),
        ],
      ),
    );
  }
}

/// 行尾的「计数标签 + 展开箭头」——两者共用一个热区。
///
/// 拆成独立 widget 而不是内联，是为了让 `dense_event_row_test.dart` 能直接
/// 量它的尺寸：热区大小是这个组件唯一的存在理由，量不到就守不住。
class _TrailingTapTarget extends StatelessWidget {
  final String? label;
  final bool open;
  final String tooltip;

  /// null = 没有展开区，只当静态标签渲染（不给手势、不画箭头）。
  final VoidCallback? onTap;

  const _TrailingTapTarget({
    required this.label,
    required this.open,
    required this.tooltip,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final content = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (label != null)
          Text(
            label!,
            style: theme.textTheme.labelSmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        if (onTap != null) ...[
          const SizedBox(width: 2),
          Icon(
            open ? Icons.expand_less : Icons.expand_more,
            size: 16,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ],
      ],
    );

    if (onTap == null) {
      return Padding(
        padding: const EdgeInsets.only(left: 4, top: 2),
        child: content,
      );
    }

    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(4),
        child: Padding(
          // 横向留白撑热区、纵向只给 3：行高由图标（16）决定，3+16+3 = 22
          // 仍在流水行的高度预算内，而左右各 10 把可点宽度顶到 ~50。
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
          child: content,
        ),
      ),
    );
  }
}
