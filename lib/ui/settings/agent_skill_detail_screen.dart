// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../ai/agent/agent_skill_manager.dart';
import '../../ai/agent/skill.dart';
import '../../l10n/l10n.dart';
import 'widgets/asset_editor.dart';

/// 单条技能的查看 / 编辑 / 删除。
///
/// 正文可编辑，样式沿用 `agent_instructions_screen.dart` 的朴素 TextField，
/// 不做富文本也不做语法高亮。它存在的理由是：AI 写的技能偶尔会把
/// description 写得又长又空，而那一行是唯一每轮都在花钱的东西；正文里多了
/// 一段废话时，没有编辑就只能删掉整条重来。
class AgentSkillDetailScreen extends StatefulWidget {
  final AgentSkill skill;

  const AgentSkillDetailScreen({super.key, required this.skill});

  @override
  State<AgentSkillDetailScreen> createState() =>
      _AgentSkillDetailScreenState();
}

class _AgentSkillDetailScreenState extends State<AgentSkillDetailScreen> {
  late final TextEditingController _desc;
  late final TextEditingController _body;

  /// 附件。从库里异步取 —— `AgentSkill.assets` 在列表层是空的（`all()`
  /// 不填它，见那个字段的说明），这里按需读一次。
  List<AgentSkillAsset> _assets = const [];

  @override
  void initState() {
    super.initState();
    _desc = TextEditingController(text: widget.skill.description);
    _body = TextEditingController(text: widget.skill.body);
    _desc.addListener(_onChanged);
    _loadAssets();
  }

  Future<void> _loadAssets() async {
    final loaded =
        await context.read<AgentSkillManager>().assetsOf(widget.skill.name);
    if (!mounted) return;
    setState(() => _assets = loaded);
  }

  void _onChanged() => setState(() {});

  @override
  void dispose() {
    _desc.removeListener(_onChanged);
    _desc.dispose();
    _body.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    await context.read<AgentSkillManager>().updateFields(
          widget.skill.id,
          description: _desc.text,
          body: _body.text,
          assets: _assets,
        );
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(context.l10n.agentSkillSaved)));
    Navigator.of(context).maybePop();
  }

  Future<void> _delete() async {
    final l = context.l10n;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        content: Text(l.agentSkillDeleteConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(MaterialLocalizations.of(ctx).cancelButtonLabel),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(l.agentSkillDelete),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await context.read<AgentSkillManager>().delete(widget.skill.id);
    if (!mounted) return;
    Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final descBytes = utf8.encode(_desc.text).length;
    final descOver = descBytes > kMaxSkillDescriptionBytes;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.skill.name),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: l.agentSkillDelete,
            onPressed: _delete,
          ),
          IconButton(
            icon: const Icon(Icons.check),
            tooltip: l.agentSkillSaved,
            onPressed: descOver ? null : _save,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _desc,
            decoration: InputDecoration(
              labelText: l.agentSkillDescriptionLabel,
              border: const OutlineInputBorder(),
              errorText: descOver
                  ? '$descBytes / $kMaxSkillDescriptionBytes'
                  : null,
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
