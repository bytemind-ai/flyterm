// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../ai/agent/ai_command_manager.dart';
import '../../data/models/favorite_command.dart';
import '../../data/repositories/favorite_command_repository.dart';
import '../../l10n/l10n.dart';

class CommandFavoritesSheet extends StatefulWidget {
  final void Function(String command)? onRun;
  final ScrollController? scrollController;
  final DraggableScrollableController? sheetController;

  const CommandFavoritesSheet(
      {super.key, this.onRun, this.scrollController, this.sheetController});

  static Future<void> show(
    BuildContext context, {
    void Function(String)? onRun,
  }) {
    final ctrl = DraggableScrollableController();
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => DraggableScrollableSheet(
        controller: ctrl,
        initialChildSize: 0.45,
        minChildSize: 0.3,
        maxChildSize: 0.8,
        expand: false,
        builder: (_, scrollController) => CommandFavoritesSheet(
            onRun: onRun,
            scrollController: scrollController,
            sheetController: ctrl),
      ),
    );
  }

  @override
  State<CommandFavoritesSheet> createState() => _CommandFavoritesSheetState();
}

class _CommandFavoritesSheetState extends State<CommandFavoritesSheet> {
  List<FavoriteCommand> _items = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadItems();
  }

  Future<void> _loadItems() async {
    final items = await context.read<FavoriteCommandRepository>().findAll();
    if (mounted) setState(() { _items = items; _loading = false; });
  }

  Future<void> _onReorder(int oldIndex, int newIndex) async {
    if (newIndex > oldIndex) newIndex--;
    setState(() {
      final item = _items.removeAt(oldIndex);
      _items.insert(newIndex, item);
    });
    await context.read<FavoriteCommandRepository>().updateOrders(_items);
    if (mounted) await context.read<AiCommandManager>().reload();
  }

  Future<void> _add() async {
    final result = await showDialog<FavoriteCommand>(
      context: context,
      builder: (_) => const _FavoriteDialog(),
    );
    if (result != null && mounted) {
      await context.read<FavoriteCommandRepository>().insert(result);
      if (mounted) await context.read<AiCommandManager>().reload();
      _loadItems();
    }
  }

  Future<void> _edit(FavoriteCommand cmd) async {
    final result = await showDialog<FavoriteCommand>(
      context: context,
      builder: (_) => _FavoriteDialog(existing: cmd),
    );
    if (result != null && mounted) {
      await context.read<FavoriteCommandRepository>().update(result);
      if (mounted) await context.read<AiCommandManager>().reload();
      _loadItems();
    }
  }

  /// 预算行不是装饰：索引每轮随 system prompt 重发，而这件事对用户完全
  /// 不可见。设限、并让他看见枪口，是同一件事的两半。
  int get _aiExposedCount => _items.where((c) => c.aiEnabled).length;

  int get _aiTokens {
    final text = _items
        .where((c) => c.aiEnabled)
        .take(kMaxIndexedCommands)
        .map((c) => '${c.name} [${c.params.join(', ')}]: ${c.command}')
        .join('\n');
    return (utf8.encode(text).length / 3.5).round();
  }

  Future<void> _delete(FavoriteCommand cmd) async {
    await context.read<FavoriteCommandRepository>().delete(cmd.id);
    if (mounted) await context.read<AiCommandManager>().reload();
    _loadItems();
  }

  Future<void> _run(FavoriteCommand cmd) async {
    if (!cmd.hasParams) {
      widget.onRun?.call(cmd.command);
      if (mounted) Navigator.of(context).pop();
      return;
    }
    final expanded = await showDialog<String>(
      context: context,
      builder: (_) => _ParamDialog(cmd: cmd),
    );
    if (expanded != null && mounted) {
      widget.onRun?.call(expanded);
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
        children: [
          // Handle
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onVerticalDragUpdate: (d) {
              final ctrl = widget.sheetController;
              if (ctrl == null || !ctrl.isAttached) return;
              final screenH = MediaQuery.of(context).size.height;
              final newSize =
                  (ctrl.size - d.delta.dy / screenH).clamp(0.3, 0.8);
              ctrl.animateTo(newSize,
                  duration: Duration.zero, curve: Curves.linear);
            },
            child: Center(
              child: Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.symmetric(vertical: 8),
                decoration: BoxDecoration(
                  color: Theme.of(context)
                      .colorScheme
                      .onSurfaceVariant
                      .withAlpha(80),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
          ),
          // Header
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                const Icon(Icons.star, size: 18, color: Color(0xFF00C896)),
                const SizedBox(width: 8),
                Text(context.l10n.favoritesTitle,
                    style: Theme.of(context).textTheme.titleMedium),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.add),
                  tooltip: context.l10n.addFavoriteTooltip,
                  onPressed: _add,
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          if (_aiExposedCount > 0)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
              child: Text(
                context.l10n.favoriteAiBudget(_aiExposedCount, _aiTokens),
                style: const TextStyle(fontSize: 11, color: Colors.grey),
              ),
            ),
          // List
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _items.isEmpty
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(
                            context.l10n.noFavorites,
                            textAlign: TextAlign.center,
                            style: TextStyle(color: Colors.grey[500]),
                          ),
                        ),
                      )
                    : ReorderableListView.builder(
                        buildDefaultDragHandles: false,
                        scrollController: widget.scrollController,
                        onReorder: _onReorder,
                        itemCount: _items.length,
                        itemBuilder: (_, i) {
                          final cmd = _items[i];
                          return ListTile(
                            key: ValueKey(cmd.id),
                            visualDensity: VisualDensity.compact,
                            contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                            leading: ReorderableDragStartListener(
                              index: i,
                              child: const Icon(Icons.drag_handle,
                                  size: 20, color: Colors.grey),
                            ),
                            title: Text(cmd.name,
                                style: const TextStyle(fontSize: 14)),
                            subtitle: Text(
                              cmd.command,
                              style: const TextStyle(
                                fontSize: 12,
                                fontFamily: 'JetBrainsMono',
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (cmd.aiEnabled)
                                  const Padding(
                                    padding: EdgeInsets.only(right: 4),
                                    child: Icon(Icons.auto_awesome,
                                        size: 14, color: Color(0xFF00C896)),
                                  ),
                                if (cmd.hasParams)
                                  const Padding(
                                    padding: EdgeInsets.only(right: 4),
                                    child: Icon(Icons.tune,
                                        size: 14, color: Colors.grey),
                                  ),
                                IconButton(
                                  icon: Icon(Icons.edit_outlined,
                                      size: 17, color: Colors.blue[300]),
                                  onPressed: () => _edit(cmd),
                                  padding: EdgeInsets.zero,
                                  constraints: const BoxConstraints(
                                      minWidth: 32, minHeight: 32),
                                ),
                                IconButton(
                                  icon: const Icon(
                                      Icons.delete_outline, size: 17),
                                  onPressed: () => _delete(cmd),
                                  color: Colors.red[300],
                                  padding: EdgeInsets.zero,
                                  constraints: const BoxConstraints(
                                      minWidth: 32, minHeight: 32),
                                ),
                              ],
                            ),
                            onTap: () => _run(cmd),
                          );
                        },
                      ),
          ),
        ],
    );
  }
}

// ---------------------------------------------------------------------------
// Add / Edit dialog (shared)
// ---------------------------------------------------------------------------

class _FavoriteDialog extends StatefulWidget {
  /// Non-null when editing an existing command.
  final FavoriteCommand? existing;
  const _FavoriteDialog({this.existing});

  @override
  State<_FavoriteDialog> createState() => _FavoriteDialogState();
}

class _FavoriteDialogState extends State<_FavoriteDialog> {
  late final TextEditingController _nameCtrl;
  late final TextEditingController _cmdCtrl;
  late bool _aiEnabled;

  bool get _isEdit => widget.existing != null;

  @override
  void initState() {
    super.initState();
    _nameCtrl =
        TextEditingController(text: widget.existing?.name ?? '');
    _cmdCtrl =
        TextEditingController(text: widget.existing?.command ?? '');
    _aiEnabled = widget.existing?.aiEnabled ?? false;
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _cmdCtrl.dispose();
    super.dispose();
  }

  void _save() {
    final name = _nameCtrl.text.trim();
    final cmd = _cmdCtrl.text.trim();
    if (name.isEmpty || cmd.isEmpty) return;
    final result = _isEdit
        ? FavoriteCommand(
            id: widget.existing!.id,
            name: name,
            command: cmd,
            sortOrder: widget.existing!.sortOrder,
            aiEnabled: _aiEnabled,
          )
        : FavoriteCommand.create(name: name, command: cmd)
            .copyWith(aiEnabled: _aiEnabled);
    Navigator.pop(context, result);
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return AlertDialog(
      title: Text(_isEdit ? l.editFavoriteTitle : l.addFavoriteTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _nameCtrl,
            decoration: InputDecoration(
              labelText: l.favoriteName,
              hintText: l.favoriteNameHint,
            ),
            autofocus: !_isEdit,
            textInputAction: TextInputAction.next,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _cmdCtrl,
            decoration: InputDecoration(
              labelText: l.favoriteCommand,
              hintText: l.favoriteCommandHint,
            ),
            autocorrect: false,
            enableSuggestions: false,
            textCapitalization: TextCapitalization.none,
            autofocus: _isEdit,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _save(),
          ),
          const SizedBox(height: 4),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            value: _aiEnabled,
            onChanged: (v) => setState(() => _aiEnabled = v),
            title: Text(context.l10n.favoriteAiEnabled,
                style: const TextStyle(fontSize: 14)),
            // 用户有权知道勾了之后什么东西进了 prompt。
            subtitle: Text(context.l10n.favoriteAiEnabledHint,
                style: const TextStyle(fontSize: 11)),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l.cancel),
        ),
        TextButton(
          onPressed: _save,
          child: Text(_isEdit ? l.save : l.add),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Param-fill dialog (for {{placeholder}} commands)
// ---------------------------------------------------------------------------

class _ParamDialog extends StatefulWidget {
  final FavoriteCommand cmd;
  const _ParamDialog({required this.cmd});

  @override
  State<_ParamDialog> createState() => _ParamDialogState();
}

class _ParamDialogState extends State<_ParamDialog> {
  late final Map<String, TextEditingController> _ctrls;

  @override
  void initState() {
    super.initState();
    _ctrls = {for (final p in widget.cmd.params) p: TextEditingController()};
  }

  @override
  void dispose() {
    for (final c in _ctrls.values) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.cmd.name),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: widget.cmd.params
              .map(
                (p) => Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: TextField(
                    controller: _ctrls[p],
                    decoration: InputDecoration(labelText: p),
                    autocorrect: false,
                    enableSuggestions: false,
                    textCapitalization: TextCapitalization.none,
                  ),
                ),
              )
              .toList(),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(context.l10n.cancel),
        ),
        TextButton(
          onPressed: () {
            final values = {
              for (final e in _ctrls.entries) e.key: e.value.text
            };
            Navigator.pop(context, widget.cmd.expand(values));
          },
          child: Text(context.l10n.favoriteRun),
        ),
      ],
    );
  }
}
