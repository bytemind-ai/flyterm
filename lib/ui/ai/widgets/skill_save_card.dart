// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';

import '../../../ai/agent/agent_loop.dart';
import '../../../l10n/l10n.dart';

/// `save_skill` 的审批卡。
///
/// **要展开正文**，与 `load_skill` 的轻量行相反：用户在批准把一段自己没
/// 读过的文字变成每次请求都携带的永久 prompt，必须能看清它写了什么。
class SkillSaveCard extends StatelessWidget {
  final ToolCallEvent event;

  /// 撞名时的旧正文。非 null 时标题变成「更新」。
  final String? previousBody;

  const SkillSaveCard({super.key, required this.event, this.previousBody});

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final name = event.preview?.path ?? '';
    final body = event.preview?.newText ?? '';
    final isUpdate = previousBody != null;

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.auto_awesome_outlined, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    isUpdate
                        ? l.agentSkillUpdateCardTitle(name)
                        : l.agentSkillSaveCardTitle(name),
                    style: theme.textTheme.titleSmall,
                  ),
                ),
              ],
            ),
            if (event.description.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                event.description,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(body, style: theme.textTheme.bodySmall),
            ),
          ],
        ),
      ),
    );
  }
}
