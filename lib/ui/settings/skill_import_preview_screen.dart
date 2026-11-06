// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';

import '../../ai/agent/remote_skills.dart';
import '../../l10n/l10n.dart';

/// 三个来源共用的导入确认页。
///
/// ## 为什么一个页面而不是三条各自的确认流程
///
/// 撞名处理、上限检查、description 补录 —— 这三件事在远端导入、文件导入、
/// AI 写入三条路上完全一样。分开写就是三份会各自长歪的代码，而它们长歪的
/// 方式（比如某一条忘了拦空 description）用户是看不出来的，只会表现为
/// 「索引里多了一行废话，每次请求都在付钱」。
class SkillImportPreviewScreen extends StatefulWidget {
  final List<PendingSkill> candidates;

  /// 库里已有的技能名，用于标出撞名。
  final List<String> existingNames;

  /// 解析失败被跳过的份数，顶部显示一行。
  final int skippedCount;

  final void Function(List<PendingSkill> selected) onConfirm;

  const SkillImportPreviewScreen({
    super.key,
    required this.candidates,
    required this.existingNames,
    required this.skippedCount,
    required this.onConfirm,
  });

  @override
  State<SkillImportPreviewScreen> createState() =>
      _SkillImportPreviewScreenState();
}

class _SkillImportPreviewScreenState extends State<SkillImportPreviewScreen> {
  late final List<bool> _checked;
  late final List<TextEditingController> _descCtrls;
  // 撞名条目的处理方式，与 _checked 平行、按下标对齐。非撞名条目的值不会
  // 被读到（UI 上也不展示三选控件），保留只是为了让数组长度对齐好写。
  late final List<_ConflictChoice> _conflictChoices;

  @override
  void initState() {
    super.initState();
    _descCtrls = widget.candidates
        .map((c) => TextEditingController(text: c.description))
        .toList();
    // 缺 description 的默认不勾选：它是索引的计价单位，空着导进去就是
    // 一条永远在花钱、却什么都不说明的索引项。让用户先补一行。
    _checked =
        widget.candidates.map((c) => c.description.trim().isNotEmpty).toList();
    // 撞名默认「跳过」，而不是沿用勾选状态直接覆盖。
    //
    // 空 description 的代价是「索引里多一行废话，每次请求持续小额扣费」；
    // 误覆盖是一次性丢数据，且没有任何撤销手段——用户可能已经在详情页
    // 手动编辑过那条技能的正文。两者不是一个量级，所以不能像空
    // description 那样还留一个「仍可勾选」的口子：默认值必须是无损的
    // 「跳过」，覆盖/合并都要用户明确选一次。
    _conflictChoices =
        widget.candidates.map((_) => _ConflictChoice.skip).toList();
    for (final c in _descCtrls) {
      c.addListener(_onDescChanged);
    }
  }

  void _onDescChanged() => setState(() {});

  @override
  void dispose() {
    for (final c in _descCtrls) {
      c.removeListener(_onDescChanged);
      c.dispose();
    }
    super.dispose();
  }

  bool _conflicts(String name) =>
      widget.existingNames.any((e) => e.toLowerCase() == name.toLowerCase());

  /// 为「两份都留」生成一个确定性、不撞库里已有名字、也不撞同批次里
  /// 已经分配出去的新名字的 name。
  ///
  /// 确定性很重要：同一批候选、同一份 existingNames，反复点「确认」
  /// （或者用户先点了又改主意点回来）必须得到同一个结果，不能用随机数
  /// 或时间戳——`AgentSkillManager` 那边的落库测试和这里的 UI 测试都要
  /// 可预期。`usedLower` 由调用方在一次 _confirm 内滚动更新，所以同批次
  /// 里两条撞名的候选各自分到的新名字也不会互相碰撞。
  String _generateKeepBothName(String base, Set<String> usedLower) {
    var i = 2;
    while (usedLower.contains('$base-$i'.toLowerCase())) {
      i++;
    }
    return '$base-$i';
  }

  void _confirm() {
    final out = <PendingSkill>[];
    // 库里已有的名字打底；每分配/采用一个新名字就滚动加入，保证同批次
    // 内部也不会互相撞名（这是最容易漏掉的一步：只跟 existingNames 比
    // 是不够的）。
    final usedLower =
        widget.existingNames.map((e) => e.toLowerCase()).toSet();

    for (var i = 0; i < widget.candidates.length; i++) {
      final candidate = widget.candidates[i];
      final desc = _descCtrls[i].text.trim();

      if (_conflicts(candidate.name)) {
        switch (_conflictChoices[i]) {
          case _ConflictChoice.skip:
            break;
          case _ConflictChoice.overwrite:
            // 覆盖：保留原 name，调用方按 name upsert 天然就是覆盖。
            if (desc.isNotEmpty) {
              out.add(candidate.copyWith(description: desc));
            }
          case _ConflictChoice.keepBoth:
            if (desc.isNotEmpty) {
              final newName =
                  _generateKeepBothName(candidate.name, usedLower);
              usedLower.add(newName.toLowerCase());
              out.add(candidate.copyWith(name: newName, description: desc));
            }
        }
        continue;
      }

      if (!_checked[i]) continue;
      if (desc.isEmpty) continue;
      out.add(candidate.copyWith(description: desc));
      usedLower.add(candidate.name.toLowerCase());
    }
    widget.onConfirm(out);
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(l.agentSkillsImportTitle),
        actions: [
          IconButton(
            // SegmentedButton（撞名三选控件）在选中态默认也会画一个
            // Icons.check 覆盖层，光凭图标已经没法唯一定位确认按钮，
            // 所以额外挂一个 Key 给测试用。
            key: const Key('skillImportConfirmButton'),
            icon: const Icon(Icons.check),
            tooltip: l.agentSkillsImportConfirm,
            onPressed: _confirm,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (widget.skippedCount > 0)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                l.agentSkillsImportSkipped(widget.skippedCount),
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
          if (widget.candidates.isEmpty)
            Text(l.agentSkillsImportNone, style: theme.textTheme.bodyMedium),
          for (var i = 0; i < widget.candidates.length; i++)
            _CandidateTile(
              name: widget.candidates[i].name,
              descCtrl: _descCtrls[i],
              checked: _checked[i],
              conflicts: _conflicts(widget.candidates[i].name),
              onChanged: (v) => setState(() => _checked[i] = v),
              conflictChoice: _conflictChoices[i],
              onConflictChoiceChanged: (v) =>
                  setState(() => _conflictChoices[i] = v),
              assetCount: widget.candidates[i].assets.length,
            ),
        ],
      ),
    );
  }
}

/// 撞名条目三选：跳过 / 覆盖 / 两份都留。默认必须是 [skip]——见
/// `_SkillImportPreviewScreenState.initState` 里的注释。
enum _ConflictChoice { skip, overwrite, keepBoth }

class _CandidateTile extends StatelessWidget {
  final String name;
  final TextEditingController descCtrl;
  final bool checked;
  final bool conflicts;
  final ValueChanged<bool> onChanged;
  final _ConflictChoice conflictChoice;
  final ValueChanged<_ConflictChoice> onConflictChoiceChanged;
  final int assetCount;

  const _CandidateTile({
    required this.name,
    required this.descCtrl,
    required this.checked,
    required this.conflicts,
    required this.onChanged,
    required this.conflictChoice,
    required this.onConflictChoiceChanged,
    this.assetCount = 0,
  });

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final needsDesc = descCtrl.text.trim().isEmpty;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                // 撞名条目不给勾选框：命运完全由下面的三选控件决定
                // （跳过 = 不导入，覆盖/两份都留 = 导入），两套控件叠在
                // 一起只会让「勾了但选了跳过」这种矛盾态变得可能。
                if (!conflicts)
                  Checkbox(
                    value: checked,
                    // 没有 description 时勾不上：勾了也会在 _confirm 里被
                    // 过滤，让它勾不上比让它悄悄失效诚实。
                    onChanged: needsDesc ? null : (v) => onChanged(v ?? false),
                  ),
                Expanded(
                  child: Text(name, style: theme.textTheme.titleSmall),
                ),
                if (conflicts)
                  Icon(Icons.warning_amber_rounded,
                      size: 18, color: theme.colorScheme.error),
              ],
            ),
            if (conflicts) ...[
              Padding(
                padding: const EdgeInsets.only(left: 12, bottom: 6),
                child: Text(
                  l.agentSkillsConflictTitle(name),
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.error),
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: SegmentedButton<_ConflictChoice>(
                  segments: [
                    ButtonSegment(
                      value: _ConflictChoice.skip,
                      label: Text(l.agentSkillsConflictSkip),
                    ),
                    ButtonSegment(
                      value: _ConflictChoice.overwrite,
                      label: Text(l.agentSkillsConflictOverwrite),
                    ),
                    ButtonSegment(
                      value: _ConflictChoice.keepBoth,
                      label: Text(l.agentSkillsConflictKeepBoth),
                    ),
                  ],
                  selected: {conflictChoice},
                  onSelectionChanged: (s) => onConflictChoiceChanged(s.first),
                ),
              ),
            ],
            TextField(
              controller: descCtrl,
              decoration: InputDecoration(
                labelText: l.agentSkillDescriptionLabel,
                helperText:
                    needsDesc ? l.agentSkillsImportNeedsDescription : null,
                border: const OutlineInputBorder(),
                isDense: true,
              ),
            ),
            // 附件数要让用户看见：它决定这份技能导入后会在服务器上写出哪些
            // 文件，而预览页是批准前的最后一道。
            if (assetCount > 0) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  const Icon(Icons.attach_file, size: 14),
                  const SizedBox(width: 4),
                  Text(
                    l.skillImportAssetCount(assetCount),
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
