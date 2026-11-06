// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';

import '../../../ai/agent/skill.dart';
import '../../../l10n/l10n.dart';

/// 附件编辑器。新建页与详情页共用。
///
/// ## 为什么是「弹窗改一份」而不是内联展开的长表单
///
/// 一份附件的主体是**文件正文**，可能几千字节。把它内联铺在技能表单里，
/// 描述 / 正文 / 附件三段会各自抢注意力，用户不知道自己在编辑哪一层。这里
/// 列表只显示路径与可执行位，点开才进全屏编辑——与详情页看正文的层级一致。
///
/// ## 校验放在这里，与 `save_skill` 用同一套函数
///
/// `parseAssetPath` / `kMaxSkillAssetBytes` 等都由 `skill.dart` 提供。两边
/// 各写一套的话，UI 放行的路径到了 AI 那条路会被拒（或反过来），而用户看到
/// 的是“我明明存得进去”。
class AssetEditor extends StatefulWidget {
  final List<AgentSkillAsset> assets;
  final ValueChanged<List<AgentSkillAsset>> onChanged;

  /// 只读模式（详情页在没进入编辑时也可以用它展示）。
  final bool readOnly;

  const AssetEditor({
    super.key,
    required this.assets,
    required this.onChanged,
    this.readOnly = false,
  });

  @override
  State<AssetEditor> createState() => _AssetEditorState();
}

class _AssetEditorState extends State<AssetEditor> {
  int get _totalBytes =>
      widget.assets.fold(0, (s, a) => s + a.byteLength);

  Future<void> _add() async {
    final created = await showModalBottomSheet<AgentSkillAsset>(
      context: context,
      isScrollControlled: true,
      builder: (_) => const _AssetEditSheet(),
    );
    if (created == null) return;

    // 同一路径替换而不是追加：与库里 `UNIQUE(skill_id, path)` 一致，
    // 在那里会被后者覆盖，这里先就地替换，让用户看到的就是最终结果。
    final next = List.of(widget.assets);
    final at = next.indexWhere((a) => a.path == created.path);
    if (at >= 0) {
      next[at] = created;
    } else {
      next.add(created);
    }
    widget.onChanged(next);
  }

  Future<void> _edit(int index) async {
    final edited = await showModalBottomSheet<AgentSkillAsset>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _AssetEditSheet(initial: widget.assets[index]),
    );
    if (edited == null) return;
    final next = List.of(widget.assets);
    next[index] = edited;
    widget.onChanged(next);
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final over = _totalBytes > kMaxSkillAssetsTotalBytes;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(l.agentSkillAssetsLabel,
                  style: theme.textTheme.labelMedium),
            ),
            if (!widget.readOnly)
              TextButton.icon(
                onPressed:
                    widget.assets.length >= kMaxSkillAssets ? null : _add,
                icon: const Icon(Icons.add, size: 18),
                label: Text(l.skillAssetAdd),
              ),
          ],
        ),
        if (widget.assets.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Text(
              l.skillAssetEmptyHint,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          )
        else
          for (var i = 0; i < widget.assets.length; i++)
            ListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              leading: Icon(
                widget.assets[i].executable
                    ? Icons.terminal
                    : Icons.description_outlined,
                size: 20,
              ),
              title: Text(widget.assets[i].path,
                  style: theme.textTheme.bodyMedium),
              subtitle: Text(
                widget.assets[i].executable
                    ? l.agentSkillAssetExecutable
                    : l.agentSkillAssetData,
                style: theme.textTheme.bodySmall,
              ),
              onTap: widget.readOnly ? null : () => _edit(i),
              trailing: widget.readOnly
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.close, size: 18),
                      tooltip: l.cancel,
                      onPressed: () {
                        final next = List.of(widget.assets)..removeAt(i);
                        widget.onChanged(next);
                      },
                    ),
            ),
        if (over)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              l.skillAssetTotalTooBig(_totalBytes, kMaxSkillAssetsTotalBytes),
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.error),
            ),
          ),
      ],
    );
  }
}

/// 一份附件的编辑表单（路径 / 可执行位 / 正文）。
class _AssetEditSheet extends StatefulWidget {
  final AgentSkillAsset? initial;
  const _AssetEditSheet({this.initial});

  @override
  State<_AssetEditSheet> createState() => _AssetEditSheetState();
}

class _AssetEditSheetState extends State<_AssetEditSheet> {
  late final TextEditingController _path;
  late final TextEditingController _content;
  late bool _executable;

  @override
  void initState() {
    super.initState();
    _path = TextEditingController(text: widget.initial?.path ?? '');
    _content = TextEditingController(text: widget.initial?.content ?? '');
    _executable = widget.initial?.executable ?? false;
    _path.addListener(_onChanged);
    _content.addListener(_onChanged);
  }

  void _onChanged() => setState(() {});

  @override
  void dispose() {
    _path.removeListener(_onChanged);
    _content.removeListener(_onChanged);
    _path.dispose();
    _content.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final theme = Theme.of(context);

    final path = _path.text.trim();
    final safePath = parseAssetPath(path);
    final contentBytes = _byteLength(_content.text);
    final overSize = contentBytes > kMaxSkillAssetBytes;

    final canSave = safePath != null && _content.text.isNotEmpty && !overSize;

    return Padding(
      // 键盘弹起时把表单顶上去。
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.85,
        maxChildSize: 0.95,
        builder: (_, controller) => ListView(
          controller: controller,
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              widget.initial == null ? l.skillAssetAdd : l.skillAssetEdit,
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _path,
              autocorrect: false,
              decoration: InputDecoration(
                labelText: l.skillAssetPathLabel,
                helperText: l.skillAssetPathHelper,
                errorText: path.isNotEmpty && safePath == null
                    ? l.skillAssetPathInvalid
                    : null,
                border: const OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _executable,
              onChanged: (v) => setState(() => _executable = v),
              title: Text(l.skillAssetExecutableToggle,
                  style: theme.textTheme.bodyMedium),
              subtitle: Text(l.skillAssetExecutableHint,
                  style: theme.textTheme.bodySmall),
            ),
            const SizedBox(height: 8),
            Text(l.skillAssetContentLabel,
                style: theme.textTheme.labelMedium),
            const SizedBox(height: 6),
            TextField(
              controller: _content,
              maxLines: 14,
              minLines: 8,
              autocorrect: false,
              enableSuggestions: false,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              decoration: InputDecoration(
                border: const OutlineInputBorder(),
                errorText: overSize
                    ? '$contentBytes / $kMaxSkillAssetBytes'
                    : null,
              ),
            ),
            const SizedBox(height: 4),
            Text('$contentBytes / $kMaxSkillAssetBytes',
                style: theme.textTheme.bodySmall),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: canSave
                  ? () => Navigator.of(context).pop(AgentSkillAsset(
                        path: safePath,
                        content: _content.text,
                        executable: _executable,
                      ))
                  : null,
              child: Text(l.save),
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }
}

int _byteLength(String s) => s.codeUnits.fold(0, (n, u) => n + (u < 0x80 ? 1 : 3));
