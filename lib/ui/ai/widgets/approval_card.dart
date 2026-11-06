// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';

import '../../../ai/agent/agent_loop.dart';
import '../../../ai/agent/tool_registry.dart';
import '../../../l10n/l10n.dart';
import 'file_diff_view.dart';

/// 审批卡。
///
/// 按钮组由 [CheckResult] 决定，不写死：命中凭据 deny 时**没有**「允许并
/// 记住」—— 那类命令永远不该进 allowlist。
class ApprovalCard extends StatefulWidget {
  final ToolCallEvent event;

  /// 显示在凭据警示里，让用户知道内容会发给谁。
  final String providerName;

  /// (decision, rememberRule, silenceInSession)
  final void Function(ApprovalDecision, String?, bool) onDecision;

  /// true = 该服务器当前处于 bypass 档。
  ///
  /// 「本轮不再问」只在 `bypassMode && check.denyHit` 时渲染。
  /// readOnly / ask 档出现它会让用户以为凭据边界被关掉了 —— 那两档的语义是
  /// 「每次都让你看见」。
  ///
  /// 由调用方传入而不是在卡里 `context.read`，因为直接构造这个 widget 的
  /// 测试不该被迫进 provider 装配。
  final bool bypassMode;

  const ApprovalCard({
    super.key,
    required this.event,
    required this.providerName,
    required this.onDecision,
    this.bypassMode = false,
  });

  @override
  State<ApprovalCard> createState() => _ApprovalCardState();
}

class _ApprovalCardState extends State<ApprovalCard> {
  late final TextEditingController _ruleCtrl =
      TextEditingController(text: widget.event.check.suggestedRule);
  bool _editingRule = false;

  @override
  void dispose() {
    _ruleCtrl.dispose();
    super.dispose();
  }

  String? _reasonText(BuildContext context) {
    final l = context.l10n;
    return switch (widget.event.check.reason) {
      ApprovalReason.shellMetachar => l.agentReasonMetachar,
      ApprovalReason.noMatchingRule => l.agentReasonNoRule,
      ApprovalReason.fileWrite => l.agentReasonFileWrite,
      ApprovalReason.credentialDeny => null, // 用更醒目的警示条代替
      null => null,
    };
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final check = widget.event.check;
    final reason = _reasonText(context);

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: check.denyHit
              ? theme.colorScheme.error
              : theme.colorScheme.primary,
          width: 1.5,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.pan_tool_outlined,
                  size: 16, color: theme.colorScheme.primary),
              const SizedBox(width: 6),
              Text(l.agentApprovalTitle,
                  style: theme.textTheme.labelLarge
                      ?.copyWith(color: theme.colorScheme.primary)),
            ],
          ),
          const SizedBox(height: 8),
          if (widget.event.description.isNotEmpty)
            Text(widget.event.description, style: theme.textTheme.bodyMedium),
          const SizedBox(height: 6),
          if (widget.event.preview != null)
            FileDiffView(preview: widget.event.preview!)
          else
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: theme.colorScheme.surface,
                borderRadius: BorderRadius.circular(6),
              ),
              child: SelectableText(
                widget.event.displayCommand,
                style: theme.textTheme.bodySmall
                    ?.copyWith(fontFamily: 'monospace'),
              ),
            ),
          if (check.denyHit) ...[
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.warning_amber_rounded,
                    size: 16, color: theme.colorScheme.error),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    l.agentDenyWarning(widget.providerName),
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.error),
                  ),
                ),
              ],
            ),
          ] else if (reason != null) ...[
            const SizedBox(height: 6),
            Text(reason,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          ],
          if (check.canRemember) ...[
            const SizedBox(height: 8),
            if (_editingRule)
              TextField(
                controller: _ruleCtrl,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                decoration: const InputDecoration(
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
              )
            else
              InkWell(
                onTap: () => setState(() => _editingRule = true),
                child: Row(
                  children: [
                    Icon(Icons.expand_more,
                        size: 14, color: theme.colorScheme.onSurfaceVariant),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        '${l.agentApprovalRulePrefix} `${_ruleCtrl.text}`',
                        style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant),
                      ),
                    ),
                  ],
                ),
              ),
          ],
          const SizedBox(height: 10),
          // 三个按钮封顶：拒绝 / 就这一次 / 总是允许。
          //
          // ## 「加入方案」为什么删掉（2026-10-13）
          //
          // `ask` 档（= 旧 `plan`）下写文件工具的判定层**已经**返回
          // `deferToPlan` —— 也就是说那一档下能走到这张卡的写操作本来就不会
          // 出现。这个按钮实际只可能在**命令**类审批上出现，而那时点「就这一次」
          // 与「加入方案」的差别只是「这条命令执行 vs 攒进方案再批准」。
          //
          // 想要「攒批」的语义由写文件的提案卡负责，两者不再混在同一张卡上。
          //
          // **注意：只删按钮，不动 `ApprovalDecision.addToPlan`。** 那个枚举值
          // 有 11 个消费者，消费的是提案卡路径（file_executors /
          // transfer_executors / job_executors / skill_executors），与这张卡无关。
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              // 拒绝放最左：破坏性动作不放在右手的"顺手位"。
              TextButton(
                onPressed: () => widget.onDecision(
                  ApprovalDecision.reject,
                  null,
                  false,
                ),
                child: Text(l.agentApprovalReject),
              ),
              FilledButton.tonal(
                onPressed: () => widget.onDecision(
                    ApprovalDecision.allowOnce, null, false),
                child: Text(l.agentApprovalOnce),
              ),
              if (check.canRemember)
                FilledButton.tonal(
                  onPressed: () => widget.onDecision(
                    ApprovalDecision.allowOnce,
                    _ruleCtrl.text.trim(),
                    false,
                  ),
                  child: Text(l.agentApprovalAlways),
                ),
              // 只在 bypass + 凭据命中时出现。与「总是允许」互斥且不可能
              // 同时出现：后者由 `check.canRemember` 控制，而 canRemember 在
              // denyHit 时恒为 false。
              //
              // **为什么保留它**：凭据边界连 bypass 都盖不住，于是这个档下
              // 反复读同一个敏感文件的场景会一直弹卡。这个按钮是那条边界的
              // 减压阀 —— 没有它，用户会去关掉更该保留的东西。
              if (widget.bypassMode && check.denyHit)
                FilledButton.tonal(
                  onPressed: () => widget.onDecision(
                      ApprovalDecision.allowOnce, null, true),
                  child: Text(l.agentSilenceInSession),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
