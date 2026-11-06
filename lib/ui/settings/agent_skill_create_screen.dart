// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../ai/agent/agent_skill_manager.dart';
import '../../ai/agent/builtin_skill_manager.dart';
import '../../ai/agent/skill.dart';
import '../../l10n/l10n.dart';
import 'widgets/asset_editor.dart';

/// 手动从零新建一条技能。
///
/// 与 `AgentSkillDetailScreen` 分开、而不是给它加一个可空的 skill 参数：
/// 详情页的 `widget.skill` 是 non-null，一旦可空，name / id / 删除按钮就要
/// 到处判空。两个页面只是长得像 —— 详情页改的是已有行（`updateFields`），
/// 新建走的是 `save`，还多出撞名与必填两条独有校验。
class AgentSkillCreateScreen extends StatefulWidget {
  const AgentSkillCreateScreen({super.key});

  @override
  State<AgentSkillCreateScreen> createState() => _AgentSkillCreateScreenState();
}

class _AgentSkillCreateScreenState extends State<AgentSkillCreateScreen> {
  final _name = TextEditingController();
  final _desc = TextEditingController();
  final _body = TextEditingController();

  /// 暂存的附件（还没落库）。
  List<AgentSkillAsset> _assets = const [];

  @override
  void initState() {
    super.initState();
    // 保存按钮的可用性由 name 与 description 共同决定，两者输入时都要重算。
    _name.addListener(_onChanged);
    _desc.addListener(_onChanged);
  }

  void _onChanged() => setState(() {});

  @override
  void dispose() {
    _name.removeListener(_onChanged);
    _desc.removeListener(_onChanged);
    _name.dispose();
    _desc.dispose();
    _body.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    await context.read<AgentSkillManager>().save(
          name: _name.text,
          description: _desc.text,
          body: _body.text,
          source: SkillSource.manual,
          assets: _assets,
        );
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(context.l10n.agentSkillSaved)));
    Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final name = _name.text.trim();

    // 大小写不敏感，与 `AgentSkillRepository.upsert` 的
    // `name = ? COLLATE NOCASE` 判据保持一致 —— 两边不一致的话，UI 放行的
    // 名字到了仓库那层照样命中已有行，变成静默覆盖。
    //
    // **内置技能的名字也算被占用。** `load_skill` 是内置优先
    // （`resolveSkillBody`），存进来的同名技能永远读不到，却会照常列在这个
    // 页面上显示「已启用」—— 没法向用户解释的状态。`save_skill` 那条 AI
    // 路径已经拦了，这里是同一条约束在 UI 路径上的落点。
    //
    // 用 `allNames`（含被禁用的）而不是 `names`：禁用不释放名字，理由见那个
    // getter 的文档。
    final existing = [
      ...context.watch<BuiltinSkillManager>().allNames,
      ...context.watch<AgentSkillManager>().skills.map((s) => s.name),
    ];
    final taken =
        existing.any((n) => n.toLowerCase() == name.toLowerCase());

    final canSave =
        name.isNotEmpty && _desc.text.trim().isNotEmpty && !taken;

    return Scaffold(
      appBar: AppBar(
        title: Text(l.agentSkillCreateTitle),
        actions: [
          IconButton(
            icon: const Icon(Icons.check),
            tooltip: l.agentSkillSaved,
            onPressed: canSave ? _save : null,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _name,
            decoration: InputDecoration(
              labelText: l.agentSkillNameLabel,
              border: const OutlineInputBorder(),
              errorText: taken ? l.agentSkillsConflictTitle(name) : null,
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _desc,
            decoration: InputDecoration(
              labelText: l.agentSkillDescriptionLabel,
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          Text(l.agentSkillBodyLabel, style: theme.textTheme.labelMedium),
          const SizedBox(height: 6),
          TextField(
            controller: _body,
            maxLines: 20,
            minLines: 8,
            decoration: const InputDecoration(border: OutlineInputBorder()),
          ),
          const SizedBox(height: 20),
          AssetEditor(
            assets: _assets,
            onChanged: (v) => setState(() => _assets = v),
          ),
        ],
      ),
    );
  }
}
