// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../ai/agent/agent_session_manager.dart';
import '../../ai/agent/permission_rules.dart';
import '../../l10n/l10n.dart';
import 'agent_rules_data.dart';

/// 「自动执行清单」子页：agent 能不看审批直接跑哪些命令。
///
/// ## 为什么从 hub 首页的折叠区搬成独立子页
///
/// 它原先折叠在 AI Agent 首页底部。折叠解决了"抢注意力"，但没解决"展开后页面暴涨"——展开 7 个分组
/// 会把首页从 1 屏拉到 4 屏，而首页同时还挂着权限档、工具档位、说明、技能……
/// 那些和放行规则毫无关系的东西。
///
/// 搬成子页之后首页只剩 3 项，这一页则拿到完整垂直空间。用户的实际点击次数
/// **没有增加**：折叠区本来就默认收起，原路径也是"首页 → 展开"，现在是
/// "首页 → 子页"。
///
/// ## 能力一个没少
///
/// 原则：简化只做在信息层级上，不做在能力上。整组开关、逐条开关、
/// 用户规则增删、`_CapabilityOverview` 的只读概览全部保留，只是换了容器。
///
/// ## 这页为什么默认不折叠
///
/// 折叠的动机（"别抢首页注意力"）随搬页自动消失——用户点进来就是专门看它的，
/// 再套一层折叠等于让他点两次才看到想看的东西。页顶那两行 `_CapabilityOverview`
/// 仍在，它承担的是"不看 22 条 pattern 也知道总规则"的概览职责，与折叠无关。
class AgentAllowlistScreen extends StatefulWidget {
  const AgentAllowlistScreen({super.key});

  @override
  State<AgentAllowlistScreen> createState() => _AgentAllowlistScreenState();
}

class _AgentAllowlistScreenState extends State<AgentAllowlistScreen> {
  /// 哪些分组当前展开了内部的 pattern 列表（组 id 集合）。
  final Set<String> _expandedGroups = {};

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final mgr = context.watch<AgentSessionManager>();
    final rules = mgr.rules.rules;
    final builtin = rules.where((r) => r.builtin).toList();
    final user = rules.where((r) => !r.builtin).toList();
    final others = otherGroupRules(builtin);

    return Scaffold(
      appBar: AppBar(title: Text(l.agentAllowlistEntry)),
      body: ListView(
        children: [
          const _CapabilityOverview(),
          const Divider(),
          for (final g in ruleGroupDefs)
            _buildGroupTile(context, mgr, g, rulesInGroup(builtin, g)),
          if (others.isNotEmpty)
            _buildOtherGroupTile(context, mgr, others),
          _GroupHeader(title: l.agentRulesUserGroup),
          if (user.isEmpty)
            ListTile(
              dense: true,
              title: Text(l.agentRulesEmpty,
                  style: Theme.of(context).textTheme.bodySmall),
            ),
          ...user.map((r) => ListTile(
                dense: true,
                title: Text(r.pattern,
                    style: const TextStyle(fontFamily: 'monospace')),
                trailing: IconButton(
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => mgr.removeRule(r.pattern),
                ),
              )),
          const SizedBox(height: 16),
        ],
      ),
    );
  }

  Widget _buildGroupTile(
    BuildContext context,
    AgentSessionManager mgr,
    RuleGroupDef group,
    List<PermissionRule> groupRules,
  ) {
    final l = context.l10n;
    final expanded = _expandedGroups.contains(group.id);
    return _RuleGroupSection(
      groupId: group.id,
      title: group.title(l),
      subtitle: group.subtitle(l),
      sensitive: group.sensitive,
      warning: group.sensitive ? l.agentRuleGroupFilesWarning : null,
      enabled: groupRules.any((r) => r.enabled),
      onEnabledChanged: (v) {
        for (final r in groupRules) {
          mgr.setRuleEnabled(r.pattern, v);
        }
      },
      expanded: expanded,
      onToggleExpanded: () => _toggleGroup(group.id, expanded),
      patterns: groupRules,
      onPatternChanged: (pattern, v) => mgr.setRuleEnabled(pattern, v),
    );
  }

  /// 分组表没覆盖到的 builtin 规则的兜底展示。语义与普通分组一致（可整组
  /// 关、可展开逐条关），只是没有精心撰写的 subtitle——它本来就不该经常
  /// 出现，一旦出现，能关掉才是唯一要紧的事。
  Widget _buildOtherGroupTile(
    BuildContext context,
    AgentSessionManager mgr,
    List<PermissionRule> otherRules,
  ) {
    final l = context.l10n;
    const groupId = 'other';
    final expanded = _expandedGroups.contains(groupId);
    return _RuleGroupSection(
      groupId: groupId,
      title: l.agentRuleGroupOtherTitle,
      subtitle: null,
      sensitive: false,
      warning: null,
      enabled: otherRules.any((r) => r.enabled),
      onEnabledChanged: (v) {
        for (final r in otherRules) {
          mgr.setRuleEnabled(r.pattern, v);
        }
      },
      expanded: expanded,
      onToggleExpanded: () => _toggleGroup(groupId, expanded),
      patterns: otherRules,
      onPatternChanged: (pattern, v) => mgr.setRuleEnabled(pattern, v),
    );
  }

  void _toggleGroup(String groupId, bool expanded) => setState(() {
        if (expanded) {
          _expandedGroups.remove(groupId);
        } else {
          _expandedGroups.add(groupId);
        }
      });
}

/// 决定项与明细之间的两行只读概览——不看 22 条 pattern 也知道 agent 能干
/// 什么。第一行说明"自动执行"覆盖的范围，第二行说明"仍需确认"的范围。
///
/// 在 hub 折叠区时代第一行是可点的展开/折叠触发器；搬成子页后折叠消失，
/// 两行都退化为纯说明。
class _CapabilityOverview extends StatelessWidget {
  const _CapabilityOverview();

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final labelStyle = Theme.of(context)
        .textTheme
        .labelMedium
        ?.copyWith(fontWeight: FontWeight.w600);
    final valueStyle = Theme.of(context).textTheme.bodySmall;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                  width: 88,
                  child: Text(l.agentCapabilityAutoLabel, style: labelStyle)),
              Expanded(
                  child: Text(l.agentCapabilityAutoValue, style: valueStyle)),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                  width: 88,
                  child: Text(l.agentCapabilityAskLabel, style: labelStyle)),
              Expanded(
                  child: Text(l.agentCapabilityAskValue, style: valueStyle)),
            ],
          ),
        ],
      ),
    );
  }
}

/// 一个规则分组：整组开关 + 展开箭头 + （展开后）逐条 pattern 开关。
///
/// [sensitive] 组（目前只有"文件内容"）额外渲染 [warning] 文案，且不受
/// [expanded] 控制——用户不需要展开 pattern 列表就该看到这句提醒。
class _RuleGroupSection extends StatelessWidget {
  /// 分组 id（'service' / 'files' / 'other' / ...）——只用来给内部可交互
  /// 元素派生稳定的 [Key]，不参与展示。分组标题在中/英文之间会变，用它
  /// 定位测试目标比用标题文本更稳。
  final String groupId;
  final String title;
  final String? subtitle;
  final bool sensitive;
  final String? warning;
  final bool enabled;
  final ValueChanged<bool> onEnabledChanged;
  final bool expanded;
  final VoidCallback onToggleExpanded;
  final List<PermissionRule> patterns;
  final void Function(String pattern, bool enabled) onPatternChanged;

  const _RuleGroupSection({
    required this.groupId,
    required this.title,
    required this.subtitle,
    required this.sensitive,
    required this.warning,
    required this.enabled,
    required this.onEnabledChanged,
    required this.expanded,
    required this.onToggleExpanded,
    required this.patterns,
    required this.onPatternChanged,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          key: ValueKey('rule_group_expand_$groupId'),
          onTap: onToggleExpanded,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(title,
                              style: Theme.of(context)
                                  .textTheme
                                  .bodyMedium
                                  ?.copyWith(fontWeight: FontWeight.w600)),
                          if (sensitive) ...[
                            const SizedBox(width: 6),
                            Icon(Icons.info_outline, size: 14, color: cs.error),
                          ],
                        ],
                      ),
                      if (subtitle != null)
                        Text(subtitle!,
                            style: Theme.of(context).textTheme.bodySmall),
                    ],
                  ),
                ),
                Switch(
                  key: ValueKey('rule_group_switch_$groupId'),
                  value: enabled,
                  onChanged: onEnabledChanged,
                ),
                Icon(expanded ? Icons.expand_less : Icons.expand_more,
                    color: cs.onSurfaceVariant),
              ],
            ),
          ),
        ),
        if (warning != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              warning!,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: cs.error),
            ),
          ),
        if (expanded)
          ...patterns.map((r) => SwitchListTile(
                dense: true,
                title: Text(r.pattern,
                    style: const TextStyle(fontFamily: 'monospace')),
                value: r.enabled,
                onChanged: (v) => onPatternChanged(r.pattern, v),
              )),
      ],
    );
  }
}

class _GroupHeader extends StatelessWidget {
  final String title;
  const _GroupHeader({required this.title});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
        child: Text(
          title,
          style: Theme.of(context)
              .textTheme
              .labelLarge
              ?.copyWith(color: Theme.of(context).colorScheme.primary),
        ),
      );
}
