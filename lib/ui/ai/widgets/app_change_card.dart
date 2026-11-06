// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';

import '../../../app_control/app_change.dart';
import '../../../app_control/app_change_log.dart';
import '../../../app_control/app_control_service.dart';
import '../../../data/terminal_settings.dart';
import '../../../l10n/l10n.dart';
import '../../terminal/terminal_themes.dart';
import '../../design/fly_tokens.dart';

/// 「AI 改了这些 app 设置」+ 撤销按钮。沿用审批卡的视觉语言。
///
/// 数据来自 [AppChangeLog] 里 [AppChangeEvent.batchId] 对应的那个批次 ——
/// 事件本身只存 id，因为 undo 闭包序列化不了（见那个事件类的文档）。
///
/// 批次查不到时（会话归档恢复之后，撤销栈不落盘）降级成一句历史说明，
/// 不提供撤销按钮。
class AppChangeCard extends StatefulWidget {
  final AppControlService service;
  final String batchId;

  const AppChangeCard({
    super.key,
    required this.service,
    required this.batchId,
  });

  @override
  State<AppChangeCard> createState() => _AppChangeCardState();
}

class _AppChangeCardState extends State<AppChangeCard> {
  bool _undoing = false;

  /// 超过这个条数就折叠，避免一张卡把整个事件流挤满。
  static const _collapseAfter = 3;
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final batch = widget.service.changeLog.batchById(widget.batchId);

    if (batch == null || batch.changes.isEmpty) {
      return _frame(
        theme,
        dimmed: true,
        children: [
          Text(
            l.appChangeRestoredNote,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      );
    }

    final rows = _expanded || batch.changes.length <= _collapseAfter
        ? batch.changes
        : batch.changes.take(_collapseAfter).toList();
    final hidden = batch.changes.length - rows.length;

    return _frame(
      theme,
      dimmed: batch.undone,
      children: [
        Row(
          children: [
            Icon(
              Icons.settings_backup_restore,
              size: 16,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(width: 6),
            Text(
              l.appChangeCardTitle(batch.changes.length),
              style: theme.textTheme.labelLarge?.copyWith(
                color: theme.colorScheme.primary,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final c in rows) _changeRow(context, c),
              if (hidden > 0)
                InkWell(
                  onTap: () => setState(() => _expanded = true),
                  child: Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      l.appChangeMore(hidden),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.primary,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        if (batch.hasIrreversible) ...[
          const SizedBox(height: 6),
          Text(
            l.appChangeIrreversible,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            key: Key('app-change-undo-${widget.batchId}'),
            onPressed: (batch.canUndo && !_undoing) ? () => _undo(batch) : null,
            child: Text(batch.undone ? l.appChangeUndone : l.appChangeUndo),
          ),
        ),
      ],
    );
  }

  Widget _frame(
    ThemeData theme, {
    required List<Widget> children,
    bool dimmed = false,
  }) => Opacity(
    opacity: dimmed ? 0.55 : 1,
    child: Container(
      margin: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        // 第一层·角色：中性底。绿（强调）退到描边。
        // 原本描边用 primary(mint)，与「活动/成功」状态语义撞车 ——
        // 这张卡只是「agent 改了 app 设置」，不是「一切正常」。
        color: FlyColors.roleToolFill,
        borderRadius: FlyRadius.bubbleRadius,
        border: Border.all(color: FlyColors.tintBorder(FlyColors.tintAmber)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: children,
      ),
    ),
  );

  Widget _changeRow(BuildContext context, AppChange c) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: 4,
            child: Text(
              appChangeFieldLabel(context, c.field),
              style: theme.textTheme.bodySmall,
            ),
          ),
          Expanded(
            flex: 5,
            child: Text(
              c.newValue == null
                  ? formatAppChangeValue(context, c.field, c.oldValue)
                  : '${formatAppChangeValue(context, c.field, c.oldValue)}'
                        ' → ${formatAppChangeValue(context, c.field, c.newValue)}',
              style: theme.textTheme.bodySmall?.copyWith(
                fontFamily: 'monospace',
                color: theme.colorScheme.onSurface,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _undo(AppChangeBatch batch) async {
    setState(() => _undoing = true);
    try {
      await widget.service.changeLog.undoBatch(batch.id);
    } finally {
      if (mounted) setState(() => _undoing = false);
    }
  }
}

/// `AppChange.field` → 用户看得懂的标签。
///
/// 尽量复用设置页已有的 l10n，而不是为这张卡新造一套文案 —— 同一个设置项
/// 在两处叫不同的名字，用户会以为是两个东西。
///
/// 没有对应 l10n 的键回落到原始键名：那总比显示空白强，而且能提示开发者
/// 这里缺一条映射。
String appChangeFieldLabel(BuildContext context, String field) {
  final l = context.l10n;

  // server: / tunnel: / key: / session: 这些带前缀的是「对象」而非设置项，
  // 冒号后面就是对象名，直接显示。
  final colon = field.indexOf(':');
  if (colon > 0) {
    final kind = field.substring(0, colon);
    final name = field.substring(colon + 1);
    final kindLabel = switch (kind) {
      'server' => l.appChangeKindServer,
      'tunnel' => l.appChangeKindTunnel,
      'key' => l.appChangeKindKey,
      'session' => l.appChangeKindSession,
      _ => kind,
    };
    return '$kindLabel $name';
  }

  return switch (field) {
    'fontSize' => l.terminalFontSize,
    'fontFamily' => l.appChangeFieldFontFamily,
    'lineHeight' => l.appChangeFieldLineHeight,
    'terminalTheme' => l.terminalTheme,
    'cursorStyle' => l.terminalCursorStyle,
    'keyboardTrigger' => l.keyboardTrigger,
    'commandCompletion' => l.commandCompletionTitle,
    'sshCompression' => l.sshCompressionTitle,
    'backgroundKeepAlive' => l.backgroundKeepAliveTitle,
    'layout' => l.appChangeKindLayout,
    _ => field,
  };
}

/// 值的显示形式。
///
/// 三件事：double 去掉无意义的尾零（`13.0` → `13`）、bool 变成开/关、
/// enum 名换成界面上用的那个词。原始值直接显示会让卡片看起来像调试输出。
String formatAppChangeValue(BuildContext context, String field, Object? v) {
  final l = context.l10n;
  if (v == null) return '—';
  if (v is bool) return v ? l.appChangeOn : l.appChangeOff;
  if (v is double) {
    return v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(1);
  }
  if (v is String) {
    switch (field) {
      case 'terminalTheme':
        return _themeLabel(context, v);
      case 'cursorStyle':
        return _cursorLabel(context, v);
      case 'keyboardTrigger':
        return _triggerLabel(context, v);
    }
  }
  return '$v';
}

String _themeLabel(BuildContext context, String name) {
  final l = context.l10n;
  for (final t in AppTerminalTheme.values) {
    if (t.name == name) {
      return switch (t) {
        AppTerminalTheme.defaultDark => l.terminalThemeDefault,
        AppTerminalTheme.dracula => l.terminalThemeDracula,
        AppTerminalTheme.solarizedDark => l.terminalThemeSolarizedDark,
        AppTerminalTheme.monokai => l.terminalThemeMonokai,
        AppTerminalTheme.solarizedLight => l.terminalThemeSolarizedLight,
        AppTerminalTheme.nord => l.terminalThemeNord,
        AppTerminalTheme.gruvboxDark => l.terminalThemeGruvboxDark,
        AppTerminalTheme.oneDark => l.terminalThemeOneDark,
        AppTerminalTheme.tokyoNight => l.terminalThemeTokyoNight,
      };
    }
  }
  return name;
}

String _cursorLabel(BuildContext context, String name) {
  final l = context.l10n;
  return switch (name) {
    'defaultStyle' => l.terminalCursorStyleDefault,
    'block' => l.terminalCursorStyleBlock,
    'underline' => l.terminalCursorStyleUnderline,
    'verticalBar' => l.terminalCursorStyleVerticalBar,
    _ => name,
  };
}

String _triggerLabel(BuildContext context, String name) {
  final l = context.l10n;
  return switch (name) {
    'singleTap' => l.keyboardTriggerSingleTap,
    'doubleTap' => l.keyboardTriggerDoubleTap,
    'iconButton' => l.keyboardTriggerIconButton,
    _ => name,
  };
}
