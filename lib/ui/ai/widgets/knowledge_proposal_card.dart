// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';

import '../../../ai/agent/knowledge.dart';
import '../../../l10n/l10n.dart';
import 'dense_event_row.dart';
import '../../design/fly_tokens.dart';

/// 收尾提议卡：一次排查产出的 1–2 条候选知识，等用户拍板。
///
/// ## 为什么一张卡装两条而不是两张卡
///
/// 一次决策比两次便宜。手机上每多一张卡就多一次滚动、多一次注意力切换，
/// 而这两条本来就来自同一次排查。
///
/// ## 为什么正文可以展开看全文
///
/// 不只是为了让用户确认内容对不对。凭据打码（`redactSecrets`）拦不住
/// `mysql -phunter2` 这类紧贴 flag 的形状，而沉淀下来的凭据是**持久**的
/// ——每轮索引可见、可被 `load_skill` 取出、可随 skill 导出。用户在这里
/// 看见它，是最后一道闸门。
///
/// 不认识 `AgentLoop`：存入/忽略通过回调交给调用方，因此能被 widget 测试
/// 直接构造。
class KnowledgeProposalCard extends StatefulWidget {
  final List<KnowledgeCandidate> candidates;

  /// 已经处理过的下标。这些条目压暗、按钮不可点。
  final Set<int> resolved;

  /// 存入。第二个参数是**当前的**候选 —— 用户可能改过归属，不能用
  /// `candidates[i]` 去取原始那份，那样切换归属就白切了。
  final void Function(int index, KnowledgeCandidate candidate) onSave;

  final VoidCallback onDismiss;

  const KnowledgeProposalCard({
    super.key,
    required this.candidates,
    required this.resolved,
    required this.onSave,
    required this.onDismiss,
  });

  @override
  State<KnowledgeProposalCard> createState() => _KnowledgeProposalCardState();
}

class _KnowledgeProposalCardState extends State<KnowledgeProposalCard> {
  /// 用户改过归属的条目。key 是下标。
  final Map<int, KnowledgeTarget> _retargeted = {};
  final Set<int> _expanded = {};

  KnowledgeCandidate _current(int i) {
    final t = _retargeted[i];
    return t == null
        ? widget.candidates[i]
        : widget.candidates[i].copyWith(target: t);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.candidates.isEmpty) return const SizedBox.shrink();

    // 全部拍板之后这张卡只剩「确实提议过」这一条信息量，退成一行。不摘掉
    // 的理由见 agent_view 里 onDismiss 的注释 —— 那条记录如实反映了用户的
    // 选择。
    //
    // **展开区必须留着。** 收起的那一行说不出提议过哪几条、去向是 skill 还
    // 是本机笔记、正文是什么，也分不出「存入」和「忽略」—— 而 resolved
    // 的语义恰恰是「处理过（存入**或**忽略）」。没有展开区的话，那句「如实
    // 反映了用户的选择」就不成立了。
    if (widget.resolved.length >= widget.candidates.length) {
      final theme = Theme.of(context);
      return DenseEventRow(
        leading: Icon(
          Icons.school_outlined,
          size: 16,
          color: theme.colorScheme.onSurfaceVariant,
        ),
        spans: [
          TextSpan(
            text: context.l10n.agentKnowledgeResolved,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
        // 复用 `_item`：它自己按 resolved 压暗并把按钮换成「已存入」文字，
        // 不需要另写一套只读形态。
        expanded: (ctx) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var i = 0; i < widget.candidates.length; i++)
              _item(i, ctx.l10n, Theme.of(ctx)),
          ],
        ),
      );
    }

    final l = context.l10n;
    final theme = Theme.of(context);

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        // 第一层·角色：中性底。洋红（「学到了东西」）退到描边。
        color: FlyColors.roleToolFill,
        borderRadius: FlyRadius.bubbleRadius,
        border: Border.all(color: FlyColors.tintBorder(FlyColors.tintCyan)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.bookmark_add_outlined,
                size: 16,
                color: theme.colorScheme.secondary,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  l.agentKnowledgeTitle,
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: theme.colorScheme.secondary,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          for (var i = 0; i < widget.candidates.length; i++) _item(i, l, theme),
          Text(
            l.agentKnowledgeSwitchHint,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 6),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: widget.onDismiss,
              child: Text(l.agentKnowledgeDismiss),
            ),
          ),
        ],
      ),
    );
  }

  Widget _item(int i, AppLocalizations l, ThemeData theme) {
    final c = _current(i);
    final done = widget.resolved.contains(i);
    final expanded = _expanded.contains(i);

    return Opacity(
      opacity: done ? 0.5 : 1,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                // 归属标识：点一下切换。补上「模型分类错了不可纠」那个缺口
                // ——分错的一条本该进本机笔记的机器怪癖被存成 skill，
                // 会永久占着索引名额，且在别的机器上是误导。
                InkWell(
                  onTap: done
                      ? null
                      : () => setState(() {
                          _retargeted[i] = c.target == KnowledgeTarget.skill
                              ? KnowledgeTarget.serverNote
                              : KnowledgeTarget.skill;
                        }),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.secondaryContainer,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      c.target == KnowledgeTarget.skill
                          ? l.agentKnowledgeTargetSkill
                          : l.agentKnowledgeTargetNotes,
                      style: theme.textTheme.labelSmall,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(c.name, style: theme.textTheme.bodyMedium),
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  icon: Icon(expanded ? Icons.expand_less : Icons.expand_more),
                  tooltip: expanded
                      ? l.agentKnowledgeCollapse
                      : l.agentKnowledgeExpand,
                  onPressed: () => setState(() {
                    expanded ? _expanded.remove(i) : _expanded.add(i);
                  }),
                ),
              ],
            ),
            if (c.description.isNotEmpty)
              Text(
                c.description,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            // 正文默认折叠、可展开看全文 —— 见类文档「为什么正文可以展开」：
            // 这是凭据打码拦不住的形状（如 `-phunter2`）在存入前的最后一道
            // 人工闸门。
            if (expanded)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Text(
                  c.body,
                  style: theme.textTheme.labelSmall?.copyWith(
                    fontFamily: 'monospace',
                  ),
                ),
              ),
            const SizedBox(height: 4),
            if (done)
              Text(l.agentKnowledgeSaved, style: theme.textTheme.labelSmall)
            else
              FilledButton.tonal(
                onPressed: () => widget.onSave(i, c),
                // 命中已有 skill 时显示「更新 xxx」而不是「存入」——让用户
                // 看得见发生的是更新而非新建。仅对 skill 去向生效：一条
                // 被切去 serverNote 的候选即便带着 updatesExisting，也不是在
                // “更新”一个 skill。
                child: Text(
                  c.updatesExisting != null && c.target == KnowledgeTarget.skill
                      ? l.agentKnowledgeUpdate(c.updatesExisting!)
                      : l.agentKnowledgeSave,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
