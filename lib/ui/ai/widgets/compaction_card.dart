// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';

import '../../../ai/agent/agent_loop.dart';
import '../../../l10n/l10n.dart';
import 'dense_event_row.dart';

/// 「已压缩 N 条」的可展开流水行。
///
/// 存在的理由不是好看：2026-08-21 的设计曾以「摘错了没法察觉」为由
/// 否决摘要压缩，可展开核对是这个功能的安全前提，不是装饰。摘要为空时
/// 不给展开钮 —— 点开一片空白会让用户以为功能坏了。
class CompactionCard extends StatelessWidget {
  final CompactedEvent event;

  const CompactionCard({super.key, required this.event});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasSummary = event.summary.trim().isNotEmpty;

    return DenseEventRow(
      leading: Icon(Icons.compress,
          size: 16, color: theme.colorScheme.onSurfaceVariant),
      spans: [
        TextSpan(
          text: context.l10n.agentCompacted(event.droppedMessages),
          style: theme.textTheme.labelSmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      ],
      expanded: hasSummary
          // 摘要不走 markdown：它的价值在于逐字核对（路径、job id、
          // 备份路径都要能原样读出来），markdown 会把 `_` 和 `*` 吃掉。
          ? (_) => SelectableText(event.summary,
              style: theme.textTheme.bodySmall)
          : null,
    );
  }
}
