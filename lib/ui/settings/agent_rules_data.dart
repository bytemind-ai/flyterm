// SPDX-License-Identifier: GPL-3.0-or-later
import '../../ai/agent/permission_rules.dart';
import '../../l10n/l10n.dart';

/// 放行清单的**分组表**——22 条默认规则按"它能看到你机器上的什么"分成 6 组。
///
/// 这张表**只服务 UI 展示**——真正的放行判定仍然逐条走
/// `PermissionRule.matches`（见 permission_rules.dart），不受这张表的顺序或
/// 分组影响。刻意不把它塞进 permission_rules.dart：那份文件是安全清单，它
/// 的内容变化该由"要不要放行这条命令"驱动，不该被"UI 想怎么摆"牵着走。
///
/// 分组名说的是"它能看到什么"（文件内容/进程/网络……），不是"它能跑什么
/// 命令"——用户脑子里想的是"不许它读我的文件"，不是"关掉 `cat *`"。
///
/// **必须处理的边界**：这张表和 `defaultAllowRules` 是两份独立维护的清单，
/// 后者增删 pattern 时前者可能跟不上。跟不上的后果不能是"用户再也关不掉
/// 那条规则"——所以任何没被这张表覆盖到的 builtin 规则，一律兜底进最后的
/// "其他"组（见 [otherGroupRules]），而不是从 UI 上消失。
///
/// 从 `agent_settings_screen.dart` 抽出：那些文件既放页面 State 又放这张表，
/// 后者是纯数据，与 State 无关，混在一起让两边都读不清。
class RuleGroupDef {
  final String id;
  final List<String> patterns;
  final String Function(AppLocalizations) title;
  final String Function(AppLocalizations) subtitle;

  /// true = 这组值得单独提醒："开着"本身没问题，但用户应该知道后果。
  final bool sensitive;

  const RuleGroupDef({
    required this.id,
    required this.patterns,
    required this.title,
    required this.subtitle,
    this.sensitive = false,
  });
}

// 不能是 const 列表：字段里的 `(l) => l.xxx` 是闭包，闭包不是编译期常量。
final List<RuleGroupDef> ruleGroupDefs = [
  RuleGroupDef(
    id: 'service',
    patterns: ['systemctl status *', 'journalctl *'],
    title: (l) => l.agentRuleGroupServiceTitle,
    subtitle: (l) => l.agentRuleGroupServiceSubtitle,
  ),
  RuleGroupDef(
    id: 'system',
    patterns: ['ps *', 'df *', 'free *', 'uptime *', 'uname *'],
    title: (l) => l.agentRuleGroupSystemTitle,
    subtitle: (l) => l.agentRuleGroupSystemSubtitle,
  ),
  RuleGroupDef(
    id: 'network',
    patterns: ['ss *', 'netstat *'],
    title: (l) => l.agentRuleGroupNetworkTitle,
    subtitle: (l) => l.agentRuleGroupNetworkSubtitle,
  ),
  RuleGroupDef(
    id: 'files',
    patterns: ['ls *', 'cat *', 'head *', 'tail *', 'grep *', 'stat *'],
    title: (l) => l.agentRuleGroupFilesTitle,
    subtitle: (l) => l.agentRuleGroupFilesSubtitle,
    sensitive: true,
  ),
  RuleGroupDef(
    id: 'docker',
    patterns: ['docker ps *', 'docker logs *', 'docker stats *'],
    title: (l) => l.agentRuleGroupDockerTitle,
    subtitle: (l) => l.agentRuleGroupDockerSubtitle,
  ),
  RuleGroupDef(
    id: 'k8s',
    patterns: [
      'kubectl get *',
      'kubectl describe *',
      'kubectl logs *',
      'kubectl top *',
    ],
    title: (l) => l.agentRuleGroupK8sTitle,
    subtitle: (l) => l.agentRuleGroupK8sSubtitle,
  ),
];

/// [builtin] 中属于 [group] 的那些规则，原始顺序不保。
List<PermissionRule> rulesInGroup(
        List<PermissionRule> builtin, RuleGroupDef group) =>
    builtin.where((r) => group.patterns.contains(r.pattern)).toList();

/// 兜底组：[ruleGroupDefs] 里 22 个 pattern 都没提到的 builtin 规则。
///
/// 正常情况下应该是空列表——这条函数存在的唯一理由是
/// `defaultAllowRules` 将来改动时不让任何一条规则从 UI 上"消失"。
List<PermissionRule> otherGroupRules(List<PermissionRule> builtin) {
  final covered = ruleGroupDefs.expand((g) => g.patterns).toSet();
  return builtin.where((r) => !covered.contains(r.pattern)).toList();
}

/// 当前至少有一条规则启用的分组数（含兜底组）。
///
/// 用途：hub 页「自动执行清单」导航行的动态 subtitle。用户不进子页也该看到
/// 「22 类里放行了多少」——动态 subtitle 补偿的正是收进子页带来的信息损失。
///
/// 计数口径是**分组**而非逐条 pattern：分组才对应"一类能力"，而 22 条 pattern
/// 逐条数出来的数字对用户无意义。一个组里只要有一条启用就算这组开着——与
/// `_RuleGroupSection` 的开关状态（`groupRules.any((r) => r.enabled)`）同口径。
int enabledGroupCount(List<PermissionRule> builtin) {
  var n = 0;
  for (final g in ruleGroupDefs) {
    if (rulesInGroup(builtin, g).any((r) => r.enabled)) n++;
  }
  if (otherGroupRules(builtin).any((r) => r.enabled)) n++;
  return n;
}

/// 放行清单里**总共**有多少组（含兜底组，若它非空）。
///
/// 与 [enabledGroupCount] 配对使用来渲染 `{enabled} / {total}`。兜底组只有在
/// 真的存在未覆盖规则时才计入分母——否则会显示「22 / 23」这种用户看不懂的
/// 分数（第 23 组是空的）。
int totalGroupCount(List<PermissionRule> builtin) =>
    ruleGroupDefs.length + (otherGroupRules(builtin).isEmpty ? 0 : 1);
