// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../ai/agent/agent_skill_manager.dart';
import '../../ai/agent/builtin_skill_manager.dart';
import '../../ai/agent/remote_skills.dart';
import '../../ai/agent/skill.dart';
import '../../ai/agent/skill_file_import.dart';
import '../../l10n/l10n.dart';
import 'agent_skill_create_screen.dart';
import 'agent_skill_detail_screen.dart';
import 'skill_import_preview_screen.dart';

/// 技能列表。
///
/// 顶部那行预算不是装饰：`kMaxIndexedSkills` / `kMaxSkillDescriptionBytes`
/// 存在的理由是「索引每轮重发」，而那件事对用户完全不可见。把它显示出来，
/// 用户才能自己判断该不该关掉几条 —— 与 `kMaxInstructionBytes` 那句「不设
/// 上限等于给用户一把烧钱的枪」是同一件事的两半：设限，并让他看见枪口。
class AgentSkillsScreen extends StatelessWidget {
  /// 远端导入的入口只在有可用连接时给出。null = 不显示那一项。
  final Future<RemoteSkillsResult> Function()? onImportFromServer;

  const AgentSkillsScreen({super.key, this.onImportFromServer});

  Future<void> _createManually(BuildContext context) async {
    await Navigator.push<void>(
      context,
      MaterialPageRoute(builder: (_) => const AgentSkillCreateScreen()),
    );
  }

  Future<void> _importFromServer(BuildContext context) async {
    final mgr = context.read<AgentSkillManager>();
    final res = await onImportFromServer!();
    if (!context.mounted) return;
    if (res.error != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(res.error!)));
      return;
    }
    await _openPreview(context, mgr, res.skills, res.skipped);
  }

  Future<void> _importFromFile(BuildContext context) async {
    final mgr = context.read<AgentSkillManager>();
    final path = await pickSkillFilePath();
    if (path == null || !context.mounted) return;
    final res = await importSkillFromFile(path);
    if (!context.mounted) return;
    if (res.error != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(res.error!)));
      return;
    }
    await _openPreview(context, mgr, [res.skill!], 0);
  }

  /// 导入一个目录（CC 风格的 `<name>/SKILL.md` + 附件）。
  Future<void> _importFromFolder(BuildContext context) async {
    final mgr = context.read<AgentSkillManager>();
    final path = await pickSkillDirectoryPath();
    if (path == null || !context.mounted) return;
    final res = await importSkillsFromDirectory(path);
    if (!context.mounted) return;
    if (res.error != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(res.error!)));
      return;
    }
    await _openPreview(context, mgr, res.skills, res.skipped);
  }

  /// 导入一个 zip / `.skill` 包。
  ///
  /// 与选目录互补：某些平台上选目录拿不到（Android 的某些文件提供器只给
  /// 单个文件），而把技能目录压成 zip 在任何平台都能选。
  Future<void> _importFromArchive(BuildContext context) async {
    final mgr = context.read<AgentSkillManager>();
    final path = await pickSkillArchivePath();
    if (path == null || !context.mounted) return;
    final res = await importSkillsFromArchive(path);
    if (!context.mounted) return;
    if (res.error != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(res.error!)));
      return;
    }
    await _openPreview(context, mgr, res.skills, res.skipped);
  }

  Future<void> _openPreview(
    BuildContext context,
    AgentSkillManager mgr,
    List<PendingSkill> candidates,
    int skipped,
  ) async {
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (ctx) => SkillImportPreviewScreen(
          candidates: candidates,
          // 内置技能的名字也算已存在：`load_skill` 内置优先，导入一份同名的
          // 永远读不到，理由同 `AgentSkillCreateScreen` 里那段。
          // `allNames` 含被禁用的 —— 禁用不释放名字。
          existingNames: [
            ...context.read<BuiltinSkillManager>().allNames,
            ...mgr.skills.map((s) => s.name),
          ],
          skippedCount: skipped,
          onConfirm: (selected) async {
            for (final s in selected) {
              await mgr.save(
                name: s.name,
                description: s.description,
                body: s.body,
                source: s.source,
                // **必须传**：不传（null）的语义是“不动附件”，覆盖已有
                // 同名技能时旧附件会被原样留着。而这里用户刚刚看过预览、
                // 期望的是“以这份为准”。
                assets: s.assets,
              );
            }
            if (ctx.mounted) Navigator.of(ctx).pop();
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final mgr = context.watch<AgentSkillManager>();
    final builtin = context.watch<BuiltinSkillManager>();

    return Scaffold(
      appBar: AppBar(
        title: Text(l.agentSkillsTitle),
        actions: [
          PopupMenuButton<String>(
            icon: const Icon(Icons.add),
            onSelected: (v) {
              if (v == 'manual') _createManually(context);
              if (v == 'server') _importFromServer(context);
              if (v == 'file') _importFromFile(context);
              if (v == 'folder') _importFromFolder(context);
              if (v == 'archive') _importFromArchive(context);
            },
            itemBuilder: (_) => [
              PopupMenuItem(
                value: 'manual',
                child: Text(l.agentSkillsCreateManually),
              ),
              if (onImportFromServer != null)
                PopupMenuItem(
                  value: 'server',
                  child: Text(l.agentSkillsImportFromServer),
                ),
              PopupMenuItem(
                value: 'file',
                child: Text(l.agentSkillsImportFromFile),
              ),
              PopupMenuItem(
                value: 'folder',
                child: Text(l.agentSkillsImportFromFolder),
              ),
              PopupMenuItem(
                value: 'archive',
                child: Text(l.agentSkillsImportFromArchive),
              ),
            ],
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(l.agentSkillsHint, style: theme.textTheme.bodySmall),
          const SizedBox(height: 12),
          Text(
            l.agentSkillsBudget(
              mgr.indexEntries.length + builtin.entries.length,
              mgr.indexTokenEstimate + builtin.indexTokenEstimate,
            ),
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          if (mgr.overflowCount > 0)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: InkWell(
                onTap: () => _showOverflowHint(context),
                child: Text(
                  l.agentSkillsOverflow(mgr.overflowCount),
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.error,
                    decoration: TextDecoration.underline,
                  ),
                ),
              ),
            ),
          if (builtin.all.isNotEmpty) ...[
            const Divider(height: 24),
            Text(l.agentBuiltinSkillsSection,
                style: theme.textTheme.titleSmall),
            const SizedBox(height: 4),
            Text(l.agentBuiltinSkillsHint,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                )),
            for (final s in builtin.all)
              ListTile(
                contentPadding: EdgeInsets.zero,
                // 标题用中文，副标题第二行带上英文 name。
                //
                // 两个都要有：中文是给人读的（英文 slug 认不出是干什么的），
                // 而 name 是用户在输入框里打 `/` 时真正要输入的那个串——只显示
                // 中文的话，补全列表里出现的 `plan-change` 与设置页里的
                // 「规划改动」对不上号。
                title: Text(_builtinLocalizedTitle(context, s.name) ?? s.name),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(_builtinLocalizedDesc(context, s.name) ?? s.description),
                    Text(
                      '${l.agentBuiltinSkillBadge} · ${s.name}',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
                // 没有删除按钮，没有 onTap 编辑入口 —— 只读。
                trailing: Switch(
                  value: builtin.isEnabled(s.name),
                  onChanged: (v) => builtin.setEnabled(s.name, v),
                ),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => Scaffold(
                      appBar: AppBar(title: Text(s.name)),
                      body: SingleChildScrollView(
                        padding: const EdgeInsets.all(16),
                        child: SelectableText(s.body),
                      ),
                    ),
                  ),
                ),
              ),
          ],
          const Divider(height: 24),
          if (mgr.skills.isEmpty)
            Text(l.agentSkillsEmpty, style: theme.textTheme.bodyMedium),
          for (final s in mgr.skills)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(s.name),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(s.description),
                  Text(
                    _sourceLabelImpl(context, s.source),
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  Text(
                    switch (skillUsageDays(s)) {
                      null => l.agentSkillNeverUsed,
                      0 => l.agentSkillUsedToday,
                      final d => l.agentSkillUsedDaysAgo(d),
                    },
                    style: theme.textTheme.labelSmall,
                  ),
                  if (s.hitCount > 0)
                    Text(l.agentSkillHits(s.hitCount),
                        style: theme.textTheme.labelSmall),
                  if (s.assetCount > 0)
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.attach_file, size: 12),
                        const SizedBox(width: 2),
                        Text('${s.assetCount}',
                            style: theme.textTheme.labelSmall),
                      ],
                    ),
                  if (s.enabled && !_isIndexed(mgr, s.name))
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.visibility_off_outlined,
                            size: 12, color: theme.colorScheme.error),
                        const SizedBox(width: 4),
                        Text(l.agentSkillNotLoaded,
                            style: theme.textTheme.labelSmall
                                ?.copyWith(color: theme.colorScheme.error)),
                      ],
                    ),
                ],
              ),
              trailing: Switch(
                value: s.enabled,
                onChanged: (v) => mgr.setEnabled(s.id, v),
              ),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => AgentSkillDetailScreen(skill: s),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// 是否进了索引。`load_skill`（`AgentSkillManager.bodyOf`）匹配大小写
  /// 不敏感，这里判「挤没挤出去」要用同一套折叠规则，否则 `Nginx` 会被
  /// 误判成不在索引里，仅仅因为存的是 `nginx`。
  static bool _isIndexed(AgentSkillManager mgr, String name) {
    final target = name.trim().toLowerCase();
    return mgr.names.any((n) => n.toLowerCase() == target);
  }

  /// 内置技能的中文说明。**只用于界面** —— 送给模型的仍是 markdown 里那份
  /// 英文 description（与 system prompt 同语言，依从性更好、更省 token）。
  ///
  /// 按 name 硬编码映射而不是把译文放进 markdown：那份文件是喂模型的，加一
  /// 个 `description_zh` 字段等于让 `parseSkillMarkdown` 认第三个键，而它
  /// 刻意只认两个（见那个函数的文档）。
  static String? _builtinLocalizedDesc(BuildContext context, String name) {
    final l = context.l10n;
    return switch (name) {
      'troubleshoot' =>
        l.agentBuiltinSkillDescTroubleshoot,
      'plan-change' => l.agentBuiltinSkillDescPlanChange,
      'skill-creator' => l.agentBuiltinSkillDescSkillCreator,
      _ => null,
    };
  }

  /// 内置技能的中文标题，同 [_builtinLocalizedDesc]：只用于界面。
  ///
  /// 认不出的 name 返回 null，调用方回落到英文 name —— 将来新增一条内置技能
  /// 而忘了加译文时，界面显示英文 slug（能用、不好看），而不是崩掉或显示空白。
  static String? _builtinLocalizedTitle(BuildContext context, String name) {
    final l = context.l10n;
    return switch (name) {
      'troubleshoot' =>
        l.agentBuiltinSkillTitleTroubleshoot,
      'plan-change' => l.agentBuiltinSkillTitlePlanChange,
      'skill-creator' => l.agentBuiltinSkillTitleSkillCreator,
      _ => null,
    };
  }

  static String _sourceLabelImpl(BuildContext context, SkillSource s) =>
      switch (s) {
        SkillSource.ai => context.l10n.agentSkillsSourceAi,
        SkillSource.remote => context.l10n.agentSkillsSourceRemote,
        SkillSource.file => context.l10n.agentSkillsSourceFile,
        SkillSource.manual => context.l10n.agentSkillsSourceManual,
      };

  static Future<void> _showOverflowHint(BuildContext context) {
    final l = context.l10n;
    return showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        content: Text(l.agentSkillNotLoadedHint),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(MaterialLocalizations.of(ctx).okButtonLabel),
          ),
        ],
      ),
    );
  }
}

/// 这条 skill 多少天没被用过。null = 从未用过。
///
/// 顶层纯函数（不是 State 上的私有方法）：日期算术是最容易写错又最容易
/// 单测的那类代码，放外面才测得到。
int? skillUsageDays(AgentSkill s, {DateTime? now}) {
  final used = s.lastUsedAt;
  if (used == null) return null;
  final d = (now ?? DateTime.now()).difference(used).inDays;
  // 时钟回拨或设备时区变化会让差值为负。显示「-3 天没用」比显示「今天」
  // 更让人困惑，钳到 0。
  return d < 0 ? 0 : d;
}
