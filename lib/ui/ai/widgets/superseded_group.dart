// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';
import '../../../l10n/l10n.dart';

/// 被「编辑重发」取代的那一段事件的折叠容器。
///
/// **默认收起，但可以展开。** 里面的工具卡带着 `backupPath`，撤销按钮仍然
/// 有效 —— 这正是折叠式相对截断式的核心收益：用户想重发的场景很可能是
/// 「agent 改错了文件」，那一刻不能把回退能力一起收走。
class SupersededGroup extends StatefulWidget {
  final List<Widget> children;

  const SupersededGroup({super.key, required this.children});

  @override
  State<SupersededGroup> createState() => _SupersededGroupState();
}

class _SupersededGroupState extends State<SupersededGroup> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: () => setState(() => _expanded = !_expanded),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Row(
              children: [
                Icon(
                  _expanded ? Icons.expand_less : Icons.expand_more,
                  size: 16,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 6),
                Text(
                  context.l10n
                      .agentSupersededCollapsed(widget.children.length),
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
        if (_expanded)
          Opacity(opacity: 0.6, child: Column(children: widget.children)),
      ],
    );
  }
}
