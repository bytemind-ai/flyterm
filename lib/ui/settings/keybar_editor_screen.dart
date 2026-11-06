// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';
import 'widgets/settings_section_header.dart';
import 'package:provider/provider.dart';

import '../../data/keybar_config.dart';
import '../../data/keybar_settings.dart';
import '../../data/terminal_settings.dart';
import '../../l10n/l10n.dart';
import 'keybar_item_edit_screen.dart';

/// Settings → Terminal → "KeyBar 自定义" main page.
///
/// Two ReorderableListViews stacked in a scrollable column:
///   1. Terminal keys (drag/edit/delete/add via FAB).
///   2. Right-side function buttons (drag-to-reorder + checkbox-to-toggle;
///      cannot be added or deleted — they are fixed app-level actions).
class KeybarEditorScreen extends StatelessWidget {
  const KeybarEditorScreen({super.key});

  static const _accent = Color(0xFF00C896);

  Future<void> _confirmRestoreDefaults(BuildContext context) async {
    final l = context.l10n;
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l.keybarEditorConfirmRestoreTitle),
        content: Text(l.keybarEditorConfirmRestoreBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(l.keybarEditorConfirmRestoreCancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(l.keybarEditorConfirmRestoreOk),
          ),
        ],
      ),
    );
    if (yes == true && context.mounted) {
      await context.read<KeybarSettings>().restoreDefaults();
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final settings = context.watch<KeybarSettings>();
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(l.keybarEditorTitle),
        elevation: 0,
        scrolledUnderElevation: 0,
        actions: [
          PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'restore') _confirmRestoreDefaults(context);
            },
            itemBuilder: (_) => [
              PopupMenuItem(
                value: 'restore',
                child: Text(l.keybarEditorRestoreDefaults),
              ),
            ],
          ),
        ],
      ),
      body: CustomScrollView(
        slivers: [
          // ── KEYBOARD MODE ────────────────────────────────────────────
          const SliverToBoxAdapter(child: SettingsSectionHeader('KEYBOARD MODE')),
          const SliverToBoxAdapter(child: _KeyboardModePicker()),

          // ── LEFT ITEMS ───────────────────────────────────────────────
          const SliverToBoxAdapter(child: SettingsSectionHeader('LEFT ITEMS')),
          SliverReorderableList(
            itemCount: settings.items.length,
            onReorder: (oldIdx, newIdx) =>
                context.read<KeybarSettings>().reorder(oldIdx, newIdx),
            itemBuilder: (_, i) {
              final item = settings.items[i];
              final preview = _preview(item);
              return Material(
                key: ValueKey('row-${item.id}'),
                color: cs.surface,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ListTile(
                      dense: true,
                      visualDensity: VisualDensity.compact,
                      leading: ReorderableDragStartListener(
                        index: i,
                        child: Icon(
                          Icons.drag_indicator,
                          size: 20,
                          color: cs.onSurface.withOpacity(0.35),
                        ),
                      ),
                      title: Text(
                        item.label,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      subtitle: Text(
                        preview,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontFamily: 'JetBrainsMono',
                          fontSize: 11.5,
                          color: cs.onSurface.withOpacity(0.6),
                          height: 1.3,
                        ),
                      ),
                      trailing: IconButton(
                        key: ValueKey('delete-${item.id}'),
                        icon: Icon(
                          Icons.delete_outline,
                          size: 20,
                          color: cs.onSurface.withOpacity(0.5),
                        ),
                        onPressed: () => settings.remove(item.id),
                      ),
                      onTap: () => Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => KeybarItemEditScreen(itemId: item.id),
                      )),
                    ),
                    // 0.5px hairline divider
                    Padding(
                      padding: const EdgeInsets.only(left: 64, right: 16),
                      child: Container(
                        height: 0.5,
                        color: cs.onSurface.withOpacity(0.08),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
          // Add button — mint TextButton.icon
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 16, 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => const KeybarItemEditScreen(),
                  )),
                  icon: const Icon(Icons.add, size: 18, color: _accent),
                  label: Text(
                    l.keybarEditorAddTooltip,
                    style: const TextStyle(color: _accent),
                  ),
                ),
              ),
            ),
          ),

          // ── RIGHT BUTTONS ────────────────────────────────────────────
          const SliverToBoxAdapter(child: SettingsSectionHeader('RIGHT BUTTONS')),
          SliverReorderableList(
            itemCount: settings.rightButtons.length,
            onReorder: (oldIdx, newIdx) => context
                .read<KeybarSettings>()
                .reorderRightButtons(oldIdx, newIdx),
            itemBuilder: (_, i) {
              final btn = settings.rightButtons[i];
              return Material(
                key: ValueKey('right-${btn.type.name}'),
                color: cs.surface,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CheckboxListTile(
                      dense: true,
                      visualDensity: VisualDensity.compact,
                      value: btn.enabled,
                      onChanged: (v) => context
                          .read<KeybarSettings>()
                          .setRightButtonEnabled(btn.type, v ?? false),
                      controlAffinity: ListTileControlAffinity.leading,
                      secondary: ReorderableDragStartListener(
                        index: i,
                        child: Icon(
                          Icons.drag_indicator,
                          size: 20,
                          color: cs.onSurface.withOpacity(0.35),
                        ),
                      ),
                      title: Row(
                        children: [
                          Icon(_iconFor(btn.type), size: 20),
                          const SizedBox(width: 12),
                          Text(_labelFor(btn.type, l)),
                        ],
                      ),
                    ),
                    // 0.5px hairline divider
                    Padding(
                      padding: const EdgeInsets.only(left: 64, right: 16),
                      child: Container(
                        height: 0.5,
                        color: cs.onSurface.withOpacity(0.08),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
          // Bottom padding so FAB doesn't overlap last row.
          const SliverToBoxAdapter(child: SizedBox(height: 80)),
        ],
      ),
      // FAB hidden — add button is now an inline TextButton above RIGHT BUTTONS
    );
  }

  String _preview(KeyBarItem item) {
    if (item.sticky) return '(sticky)';
    if (item.sequence.isEmpty) return '—';
    final parts = <String>[];
    for (final t in item.sequence) {
      if (t is TextToken) {
        parts.add(t.text);
      } else if (t is SpecialToken) {
        parts.add('[${t.key.name}]');
      }
    }
    return parts.join(' ');
  }

  static IconData _iconFor(RightButton type) {
    switch (type) {
      case RightButton.keyboard:    return Icons.keyboard_outlined;
      case RightButton.favorites:   return Icons.star_border;
      case RightButton.microphone:  return Icons.mic_none;
      case RightButton.ai:          return Icons.auto_awesome;
      case RightButton.attachFile:  return Icons.attach_file;
    }
  }

  static String _labelFor(RightButton type, dynamic l) {
    switch (type) {
      case RightButton.keyboard:    return l.keybarRightButtonKeyboard;
      case RightButton.favorites:   return l.keybarRightButtonFavorites;
      case RightButton.microphone:  return l.keybarRightButtonMicrophone;
      case RightButton.ai:          return l.keybarRightButtonAi;
      case RightButton.attachFile:  return l.keybarRightButtonAttachFile;
    }
  }
}

/// Three-way picker for [TerminalSettings.keyboardTrigger]. Lives at
/// the top of the keybar editor because it directly governs whether
/// the leftmost right-block button (the soft-keyboard toggle) renders
/// in the bar — i.e. it's a keybar concern even though the underlying
/// flag lives in [TerminalSettings].
class _KeyboardModePicker extends StatelessWidget {
  const _KeyboardModePicker();

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final settings = context.watch<TerminalSettings>();
    final current = settings.keyboardTrigger;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        RadioListTile<KeyboardTriggerMode>(
          dense: true,
          visualDensity: VisualDensity.compact,
          value: KeyboardTriggerMode.singleTap,
          groupValue: current,
          title: Text(l.keyboardTriggerSingleTap),
          subtitle: Text(l.keyboardTriggerSingleTapDesc),
          onChanged: (_) =>
              settings.setKeyboardTrigger(KeyboardTriggerMode.singleTap),
        ),
        RadioListTile<KeyboardTriggerMode>(
          dense: true,
          visualDensity: VisualDensity.compact,
          value: KeyboardTriggerMode.doubleTap,
          groupValue: current,
          title: Text(l.keyboardTriggerDoubleTap),
          subtitle: Text(l.keyboardTriggerDoubleTapDesc),
          onChanged: (_) =>
              settings.setKeyboardTrigger(KeyboardTriggerMode.doubleTap),
        ),
        RadioListTile<KeyboardTriggerMode>(
          dense: true,
          visualDensity: VisualDensity.compact,
          value: KeyboardTriggerMode.iconButton,
          groupValue: current,
          title: Text(l.keyboardTriggerIconButton),
          subtitle: Text(l.keyboardTriggerIconButtonDesc),
          onChanged: (_) =>
              settings.setKeyboardTrigger(KeyboardTriggerMode.iconButton),
        ),
      ],
    );
  }
}
