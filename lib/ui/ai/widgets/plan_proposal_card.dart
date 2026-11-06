// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';

import '../../../ai/agent/tool_models.dart';
import '../../../l10n/l10n.dart';
import '../../design/fly_tokens.dart';

/// 提案卡：列出攒下来的待执行调用，整批批准或整批丢弃。
///
/// **没有逐项勾选**，这是刻意的。手机屏幕上一列 checkbox 本身就难点准；
/// 更要紧的是方案里的项通常有依赖关系——「改配置」和「reload 服务」是一对，
/// 单独批准前者会留下一个改了配置但没生效的中间状态，比两个都不做更糟。
///
/// 用户想改其中一项，正确的做法是丢弃整份 + 用一句话告诉 agent 改哪里。
///
/// 不认识 `AgentLoop`：批准/丢弃通过回调交给调用方。这让它能被 widget 测试
/// 直接构造，不必装配 provider。
class PlanProposalCard extends StatelessWidget {
  final List<ToolCall> calls;
  final VoidCallback onApprove;
  final VoidCallback onDiscard;

  const PlanProposalCard({
    super.key,
    required this.calls,
    required this.onApprove,
    required this.onDiscard,
  });

  /// 一项的主标题。优先用模型给的 description——那是它专门为用户写的一句
  /// 话；退回到真实动作只是兜底（模型偶尔漏给这个字段）。
  static String _label(ToolCall c) {
    final desc = c.args['description'];
    if (desc is String && desc.trim().isNotEmpty) return desc.trim();
    return _detail(c);
  }

  /// 副标题：真正要跑的东西。description 可能很委婉，用户有权看到实际动作。
  static String _detail(ToolCall c) {
    final path = c.args['path'];
    if (path is String && path.isNotEmpty) return '${c.name} $path';
    final cmd = c.args['command'];
    if (cmd is String && cmd.isNotEmpty) return cmd;
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
        // 第一层·角色：中性底。紫（「需要你判断」）退到描边。
        color: FlyColors.roleToolFill,
        borderRadius: FlyRadius.bubbleRadius,
        border: Border.all(color: FlyColors.tintBorder(FlyColors.tintViolet)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.playlist_add_check,
                size: 16,
                color: theme.colorScheme.tertiary,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  l.agentProposalTitle,
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: theme.colorScheme.tertiary,
                  ),
                ),
              ),
              Text(
                l.agentProposalCount(calls.length),
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
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${i + 1}.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _label(calls[i]),
                          style: theme.textTheme.bodyMedium,
                        ),
                        Text(
                          _detail(calls[i]),
                          style: theme.textTheme.labelSmall?.copyWith(
                            fontFamily: 'monospace',
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          Text(
            l.agentProposalNote,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              FilledButton.tonal(
                onPressed: onApprove,
                child: Text(l.agentProposalApprove),
              ),
              TextButton(
                onPressed: onDiscard,
                child: Text(l.agentProposalDiscard),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
