// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../ai/ai_provider_service.dart';
import '../../ai/provider_switch.dart';
import '../../data/models/ai_provider_config.dart';
import '../../data/repositories/ai_provider_repository.dart';
import '../../data/secure_storage.dart';
import '../../data/terminal_settings.dart';
import '../../l10n/l10n.dart';


class AIProvidersScreen extends StatefulWidget {
  const AIProvidersScreen({super.key});

  @override
  State<AIProvidersScreen> createState() => _AIProvidersScreenState();
}

class _AIProvidersScreenState extends State<AIProvidersScreen> {
  late Future<List<AIProviderConfig>> _future;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    final future = context.read<AIProviderRepository>().findAll();
    setState(() { _future = future; });
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return Scaffold(
      appBar: AppBar(
        title: Text(l.aiProviders),
        elevation: 0,
        scrolledUnderElevation: 0,
      ),
      body: FutureBuilder<List<AIProviderConfig>>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          final configs = snap.data ?? [];
          if (configs.isEmpty) {
            return _EmptyState(onAdd: _addProvider);
          }
          return ListView.separated(
            itemCount: configs.length,
            separatorBuilder: (_, __) => Divider(
              height: 0.5,
              thickness: 0.5,
              indent: 64,
              color: Theme.of(context).colorScheme.onSurface.withOpacity(0.08),
            ),
            itemBuilder: (context, i) {
              final c = configs[i];
              return _ProviderTile(
                config: c,
                onSetDefault: () => _setDefault(c),
                onEdit: () => _editProvider(c),
                onDelete: () => _deleteProvider(c),
              );
            },
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addProvider,
        icon: const Icon(Icons.add),
        label: Text(context.l10n.addProvider),
      ),
    );
  }

  Future<void> _setDefault(AIProviderConfig config) async {
    await switchProvider(
      config: config,
      repo: context.read<AIProviderRepository>(),
      storage: context.read<SecureStorageService>(),
      svc: context.read<AIProviderService>(),
      // 可空读取，与 `ai_panel.dart` 那处同一个理由：widget 测试大多不搭
      // `TerminalSettings` provider。
      debugOverlay: context.read<TerminalSettings?>()?.debugOverlay ?? false,
    );
    if (mounted) _reload();
  }

  Future<void> _editProvider(AIProviderConfig config) async {
    await Navigator.of(context)
        .pushNamed('/settings/ai-providers/form', arguments: config);
    _reload();
  }

  Future<void> _addProvider() async {
    await Navigator.of(context)
        .pushNamed('/settings/ai-providers/form');
    _reload();
  }

  Future<void> _deleteProvider(AIProviderConfig config) async {
    final l = context.l10n;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(l.deleteProviderTitle),
        content: Text(l.confirmDeleteProvider(config.name)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(l.cancel)),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(l.delete)),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      final repo = context.read<AIProviderRepository>();
      final storage = context.read<SecureStorageService>();
      final svc = context.read<AIProviderService>();
      await repo.delete(config.id);
      await storage.deleteAIKey(config.id);
      if (config.isDefault) svc.clearProvider();
      _reload();
    }
  }
}

// ── Empty state ───────────────────────────────────────────────────────────────

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onAdd});
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final l = context.l10n;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.smart_toy_outlined,
            size: 48,
            color: cs.onSurface.withOpacity(0.3),
          ),
          const SizedBox(height: 16),
          Text(
            l.noProviders,
            style: TextStyle(
              fontSize: 14,
              color: cs.onSurface.withOpacity(0.5),
            ),
          ),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: onAdd,
            icon: const Icon(Icons.add, size: 18),
            label: Text(l.addProvider),
          ),
        ],
      ),
    );
  }
}

// ── Provider tile ─────────────────────────────────────────────────────────────

class _ProviderTile extends StatelessWidget {
  const _ProviderTile({
    required this.config,
    required this.onSetDefault,
    required this.onEdit,
    required this.onDelete,
  });
  final AIProviderConfig config;
  final VoidCallback onSetDefault;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  static const _accent = Color(0xFF00C896);

  static const _typeColors = <String, Color>{
    'openai':    Color(0xFF10A37F), // OpenAI green
    'anthropic': Color(0xFFD4966A), // Anthropic orange-tan
    'gemini':    Color(0xFF4285F4), // Google blue
    'ollama':    Color(0xFF5C8DD6), // Ollama blue
  };

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final typeLabel = config.type.toUpperCase();
    final typeColor = _typeColors[config.type] ?? cs.onSurface.withOpacity(0.5);

    return InkWell(
      onTap: onEdit,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // Icon box
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: cs.surfaceVariant.withOpacity(0.45),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color: cs.onSurface.withOpacity(0.08),
                  width: 0.5,
                ),
              ),
              alignment: Alignment.center,
              child: Icon(
                Icons.smart_toy_outlined,
                size: 18,
                color: cs.onSurface.withOpacity(0.85),
              ),
            ),
            const SizedBox(width: 12),
            // Middle: name + model line
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Row 1: display name + default star
                  Row(
                    children: [
                      if (config.isDefault) ...[
                        const Icon(Icons.star, size: 13, color: _accent),
                        const SizedBox(width: 4),
                      ],
                      Flexible(
                        child: Text(
                          config.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            color: cs.onSurface,
                            height: 1.2,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  // Row 2: model in mono
                  Text(
                    config.model,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: 'JetBrainsMono',
                      fontSize: 11.5,
                      color: cs.onSurface.withOpacity(0.6),
                      height: 1.25,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            // Right: type chip + overflow menu
            Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                // Type chip
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                  decoration: BoxDecoration(
                    border: Border.all(color: typeColor, width: 0.8),
                    borderRadius: BorderRadius.circular(2),
                  ),
                  child: Text(
                    typeLabel,
                    style: TextStyle(
                      fontFamily: 'JetBrainsMono',
                      fontSize: 9.5,
                      fontWeight: FontWeight.w700,
                      color: typeColor,
                      height: 1.0,
                      letterSpacing: 0.6,
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                // Overflow menu button
                SizedBox(
                  width: 32,
                  height: 32,
                  child: PopupMenuButton<_TileAction>(
                    padding: EdgeInsets.zero,
                    iconSize: 18,
                    icon: Icon(
                      Icons.more_vert,
                      size: 18,
                      color: cs.onSurface.withOpacity(0.5),
                    ),
                    onSelected: (action) {
                      switch (action) {
                        case _TileAction.setDefault:
                          onSetDefault();
                        case _TileAction.edit:
                          onEdit();
                        case _TileAction.delete:
                          onDelete();
                      }
                    },
                    itemBuilder: (context) => [
                      if (!config.isDefault)
                        PopupMenuItem(
                          value: _TileAction.setDefault,
                          child: Row(
                            children: [
                              const Icon(Icons.check_circle_outline, size: 18),
                              const SizedBox(width: 8),
                              Text(context.l10n.setDefault),
                            ],
                          ),
                        ),
                      PopupMenuItem(
                        value: _TileAction.edit,
                        child: Row(
                          children: [
                            const Icon(Icons.edit_outlined, size: 18),
                            const SizedBox(width: 8),
                            Text(context.l10n.edit),
                          ],
                        ),
                      ),
                      PopupMenuItem(
                        value: _TileAction.delete,
                        child: Row(
                          children: [
                            Icon(Icons.delete_outline,
                                size: 18,
                                color: Theme.of(context).colorScheme.error),
                            const SizedBox(width: 8),
                            Text(
                              context.l10n.delete,
                              style: TextStyle(
                                  color:
                                      Theme.of(context).colorScheme.error),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

enum _TileAction { setDefault, edit, delete }
