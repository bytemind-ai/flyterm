// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';

import '../../../ai/agent/tool_models.dart';
import '../../../l10n/l10n.dart';

/// 一轮里若干需审批的调用，一张卡整批批准。
///
/// 形状照 `PlanProposalCard`（同样是「一批调用 + 两个整批动作」），但语义不同：
/// 那张卡代表「已入队、还没执行」，这张代表「正挂起等你点，模型还在等结果」。
/// 视觉上刻意用 error 色而非 tertiary —— 那张卡是「稍后再说」，这张是「现在
/// 就要决定，而且批准后立刻会在 N 台机器上跑」。
class BatchApprovalCard extends StatelessWidget {
  final List<ToolCall> calls;

  /// 与 [calls] 一一对应的目标机器名。null = 当前会话那台。
  final List<String?> targets;

  final VoidCallback onApproveAll;
  final VoidCallback onDiscard;

  const BatchApprovalCard({
    super.key,
    required this.calls,
    required this.targets,
    required this.onApproveAll,
    required this.onDiscard,
  });

  /// 真正要跑的东西。description 可能很委婉，用户有权看到实际动作。
  static String _detail(ToolCall c) {
    final cmd = c.args['command'];
    if (cmd is String && cmd.isNotEmpty) return cmd;
    final path = c.args['path'];
    if (path is String && path.isNotEmpty) return '${c.name} $path';
    return c.name;
  }

  @override
  Widget build(BuildContext context) {
    if (calls.isEmpty) return const SizedBox.shrink();

    final l = context.l10n;
    final theme = Theme.of(context);

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: theme.colorScheme.error, width: 1.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.warning_amber,
                  size: 16, color: theme.colorScheme.error),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  l.batchApprovalTitle,
                  style: theme.textTheme.labelLarge
                      ?.copyWith(color: theme.colorScheme.error),
                ),
              ),
              Text(
                l.batchApprovalCount(calls.length),
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          for (var i = 0; i < calls.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.dns_outlined,
                          size: 13,
                          color: theme.colorScheme.onSurfaceVariant),
                      const SizedBox(width: 4),
                      Text(
                        // targets 可能比 calls 短（不该发生，但别让 UI 崩）
                        (i < targets.length ? targets[i] : null) ??
                            l.batchApprovalCurrentSession,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.primary,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _detail(calls[i]),
                    style: theme.textTheme.bodySmall
                        ?.copyWith(fontFamily: 'monospace'),
                  ),
                ],
              ),
            ),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: onDiscard,
                child: Text(l.batchApprovalDiscard),
              ),
              const SizedBox(width: 4),
              FilledButton(
                onPressed: onApproveAll,
                style: FilledButton.styleFrom(
                  backgroundColor: theme.colorScheme.error,
                ),
                child: Text(l.batchApprovalApproveAll),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
