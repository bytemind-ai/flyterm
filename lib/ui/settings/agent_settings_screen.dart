// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../ai/agent/agent_session_manager.dart';
import '../../ai/agent/agent_skill_manager.dart';
import '../../ai/agent/agent_tools.dart';
import '../../ai/agent/server_notes_manager.dart';
import '../../ai/agent/tool_registry.dart';
import '../../data/repositories/server_repository.dart';
import '../../l10n/l10n.dart';
import 'agent_allowlist_screen.dart';
import 'agent_instructions_screen.dart';
import 'agent_rules_data.dart';
import 'agent_server_notes_list_screen.dart';
import 'agent_skills_screen.dart';
import 'widgets/mode_segmented.dart';

/// agent 的**全局**设置页（hub）。
///
/// ## 这一页放什么
///
/// 三段：**权限档** + **工具档位** + **agent 记忆**（说明 / 技能 / 机器笔记 /
/// 沉淀开关），再加一个「自动执行清单」导航行。
///
/// 判据沿用 `settings_screen.dart`：段头 + 导航行 + 极少数内联
/// 开关。其中两条边界值得记下：
///
/// - 权限档：最高频、风险最高，且是**唯一**做两级的项。
///   让它待在首屏，用户进设置第一眼就看见 agent 现在有多大权限。
/// - 工具档位：单个枚举、没有兄弟项，为它单开子页荒谬。
/// - 22 条放行清单 → 「自动执行清单」子页。它和别的项**性质不同**：那些是
///   "agent 知道什么"，它是"agent 能做什么"（安全边界，`permission_rules.dart`
///   明确把放行清单定性为安全清单）。搬进子页后首页稳定在 3 段，那一页拿到
///   完整空间，而用户点击次数不变（原来那是个默认收起的折叠区，本就是
///   "再点一下才展开"）。能力一个没少——整组开关、逐条开关、用户规则增删
///   全在子页保留（简化只做在信息层级上，不做在能力上）。
///
/// ## 记忆类四项为什么不单独开子页（2026-10-14 反复）
///
/// 它们一度收进过独立子页 `agent_memory_screen.dart`，那时 hub 上只有一行
/// 「助手记忆 › 已设 N 项」。随后又**展开回本页**，理由：
///
/// 1. 那三项（说明 / 技能 / 机器笔记）本来就是导航行，收进子页只是白加一层
///    点击（「AI Agent → 助手记忆 → 说明」三层深）。CLAUDE.md 已判定按键栏
///    三层深是问题，同一条判准适用。
/// 2. 子页上那行 subtitle（"已设 N 项"）存在的**唯一**目的就是补偿"收进子页
///    看不到明细"。一项设计需要另一个机制来补丁自己的副作用，说明本可以不拆。
/// 3. 技能入口**全 app 仅此一处**（AI 面板里没有第二个入口），它是主路径
///    而不是备份路径——主路径更不该多一层。
///
/// 分组语义改由**段头**（`_GroupHeader('助手记忆')`）保留："记忆"这个概念
/// 不能丢（它和权限档性质不同——权限档是「能做什么」，记忆是「知道什么」），
/// 但表达它不需要花用户一次点击。
///
/// （那次反复留下了 `agent_memory_screen.dart` 这个已被删除的文件，以及
/// `agentMemorySection` 这个 l10n key —— 后者现在只当段头文案用。）
///
/// ## 顶部状态横幅的历史（勿删）
///
/// 这个页面曾经用两行 `RadioListTile` 表达 ask/bypass 二选一。Flutter 的
/// `RadioListTile`（未传 `toggleable`）在"该行已选中"时整行 `onTap` 直接
/// 短路、根本不调用 `onChanged`——用户报"点『全部放行』没反应"，根因就是
/// 他点的时候那一行其实已经是选中态，而页面上表达"已经开着"的信号只有一个
/// 不起眼的圆点。
///
/// 真正的问题从来不是某一次点击的手势判定，而是**状态可见性不够**：用户
/// 看不出"现在是什么状态"，才会去点一个已经选中的选项。
///
/// 2026-10-13 换成三段 `ModeSegmented` 之后，第一版那个 `_StatusBanner` 补丁
/// 不再需要：段位高亮本身就是状态展示。保留这段记录，是因为那个
/// `RadioListTile` 短路 bug 的教训仍然成立——**用户点一个已选中的选项不等于
/// 他有问题，等于界面没说清当前状态。**
///
/// ## 全是全局项
///
/// 唯一按服务器变化的是权限档的**覆盖**，那个在服务器编辑页里（见
/// `widgets/server_perm_section.dart`）—— per-server 页面里只放真正按服务器
/// 变化的东西，混进全局项会让用户以为自己在改这台机器、实际改了所有机器。
class AgentSettingsScreen extends StatefulWidget {
  /// true = 首次启用 agent 模式的强制过目，顶部显示说明条 + 底部「去过目」。
  ///
  /// 注意它**不再**在本页展开放行清单（清单已搬到子页），而是引导用户去
  /// 那一页——强制过目的语义是"过目放行清单"，把一个没有清单的 hub 页按在
  /// 用户面前不构成过目。
  final bool firstReview;

  const AgentSettingsScreen({super.key, this.firstReview = false});

  @override
  State<AgentSettingsScreen> createState() => _AgentSettingsScreenState();
}

class _AgentSettingsScreenState extends State<AgentSettingsScreen> {
  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final mgr = context.watch<AgentSessionManager>();
    final skillMgr = context.watch<AgentSkillManager>();
    final rules = mgr.rules.rules;
    final builtin = rules.where((r) => r.builtin).toList();
    final mode = mgr.defaultMode;

    return Scaffold(
      appBar: AppBar(title: Text(l.agentSettingsTitle)),
      body: ListView(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text(
              l.agentPermTitle,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: ModeSegmented(
              value: mode,
              onChanged: (m) async {
                // 已选中的档再点一次是 **no-op**：不做无谓的重复确认，
                // 也不发一次内容相同的写入。旧 `_ModeCard` 用
                // `if (mode == X) return;` 做过同一件事。
                if (m == mode) return;
                if (m == PermissionMode.bypass) {
                  if (!await confirmBypass(context)) return;
                  if (!context.mounted) return;
                }
                mgr.defaultMode = m;
              },
            ),
          ),
          if (widget.firstReview)
            Container(
              margin: const EdgeInsets.all(12),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(l.agentRulesFirstReview),
            ),
          const Divider(),
          _GroupHeader(title: l.agentToolTierGroup),
          ListTile(
            title: Text(switch (mgr.toolTierOverride) {
              null => l.agentToolTierAuto,
              AgentToolTier.lean => l.agentToolTierLean,
              AgentToolTier.full => l.agentToolTierFull,
            }),
            subtitle: Text(switch (mgr.toolTierOverride) {
              null => l.agentToolTierAutoDesc,
              AgentToolTier.lean => l.agentToolTierLeanDesc,
              AgentToolTier.full => l.agentToolTierFullDesc,
            }),
            trailing: DropdownButton<AgentToolTier?>(
              value: mgr.toolTierOverride,
              onChanged: (v) => mgr.toolTierOverride = v,
              items: [
                DropdownMenuItem(value: null, child: Text(l.agentToolTierAuto)),
                DropdownMenuItem(
                    value: AgentToolTier.lean, child: Text(l.agentToolTierLean)),
                DropdownMenuItem(
                    value: AgentToolTier.full, child: Text(l.agentToolTierFull)),
              ],
            ),
          ),
          const Divider(),
          // ── agent 记忆 ──
          //
          // 这四项（说明 / 技能 / 机器笔记 / 沉淀开关）都是"agent 的知识"，
          // 2026-10-14 拆分时它们曾收进一个独立的「助手记忆」子页，
          // 2026-10-14 稍后又**展开回这里**：那三项本来就是导航行，收进子页
          // 只是白加一层点击（「AI Agent → 助手记忆 → 说明」三层深），
          // 而 CLAUDE.md 已判定按键栏三层深是问题——同一条判准适用。
          //
          // 分组语义靠**段头**保留，不靠一个子页："记忆"这个概念不能丢
          // （它和上面那个权限档性质不同——权限档是「能做什么」，记忆是
          // 「知道什么」），但表达它不需要花用户一次点击。
          //
          // 与 `settings_screen.dart` 一致：段头 + 导航行 +
          // 极少数内联开关。
          _GroupHeader(title: l.agentMemorySection),
          ListTile(
            leading: const Icon(Icons.sticky_note_2_outlined),
            title: Text(l.agentInstructionsEntry),
            subtitle: Text(mgr.instructions == null
                ? l.agentInstructionsEntryEmpty
                : l.agentInstructionsEntrySet),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                // 不带 serverId：这是全局页面，没有「哪台服务器」这个概念。
                builder: (_) => const AgentInstructionsScreen(),
              ),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.auto_awesome_outlined),
            title: Text(l.agentSkillsEntry),
            subtitle: Text(skillMgr.skills.isEmpty
                ? l.agentSkillsEntryEmpty
                : l.agentSkillsEntryCount(skillMgr.skills.length)),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                // 不带 serverId：与自定义指令一样是全局页面。远端导入的入口
                // 由调用方按需注入 —— 这个设置页拿不到 CommandRunner。
                builder: (_) => const AgentSkillsScreen(),
              ),
            ),
          ),
          // 机器笔记总览：全部机器一眼看完 —— 单台机器的笔记仍在服务器
          // 编辑页里编辑。
          Consumer<ServerNotesManager>(
            builder: (context, notes, _) => ListTile(
              leading: const Icon(Icons.dns_outlined),
              title: Text(l.agentServerNotesOverviewEntry),
              subtitle: Text(
                l.agentServerNotesOverviewSubtitle(notes.notes.length),
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () async {
                // servers 是异步取的，而这一页只需要一个 id→name 映射 ——
                // 与 `AgentServerNotesListScreen` 构造函数收 List<Server> 的
                // 理由一致（它也没法在 build 里 await）。
                final servers =
                    await context.read<ServerRepository>().findAll();
                if (!context.mounted) return;
                await Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) =>
                        AgentServerNotesListScreen(servers: servers),
                  ),
                );
              },
            ),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.lightbulb_outline),
            title: Text(l.agentKnowledgeCaptureTitle),
            subtitle: Text(l.agentKnowledgeCaptureDesc),
            value: mgr.knowledgeCaptureEnabled,
            onChanged: (v) => mgr.knowledgeCaptureEnabled = v,
          ),
          const Divider(),
          _NavTile(
            icon: Icons.playlist_add_check_circle_outlined,
            title: l.agentAllowlistEntry,
            subtitle: l.agentAllowlistSubtitleEnabled(
              enabledGroupCount(builtin),
              totalGroupCount(builtin),
            ),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const AgentAllowlistScreen()),
            ),
          ),
          if (widget.firstReview)
            Padding(
              padding: const EdgeInsets.all(16),
              child: FilledButton(
                // 过目标记在**进入清单页**时落下，而不是在这里 —— 用户点
                // "我知道了"但没看过清单，不算过目。语义与标记本身一致：
                // 「用过目了放行清单」为真。
                onPressed: () async {
                  await Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const AgentAllowlistScreen(),
                    ),
                  );
                  if (!context.mounted) return;
                  mgr.markRulesReviewed();
                  Navigator.of(context).pop();
                },
                child: Text(l.agentRulesGoReview),
              ),
            ),
        ],
      ),
    );
  }
}

/// hub 导航行：图标 + 标题 + 动态 subtitle + chevron。
///
/// 与 `settings_screen.dart` 里那个同名私有类是同构的——两个文件各自持有
/// 一份而不是抽公共组件，是因为它们的依赖面不同（这里多一个 onTap 而非
/// 路由名），抽出去会让两边都要为一个共享抽象让路。
class _NavTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _NavTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon),
      title: Text(title),
      subtitle: Text(subtitle),
      trailing: const Icon(Icons.chevron_right),
      onTap: onTap,
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
