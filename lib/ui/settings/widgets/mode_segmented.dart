// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';

import '../../../ai/agent/tool_registry.dart';
import '../../../l10n/l10n.dart';

/// 三档权限的横向分段选择器。设置页与服务器编辑页共用。
///
/// ## 为什么自绘而不是 `SegmentedButton`
///
/// M3 的 `SegmentedButton` 默认带药丸形 indicator，与本产品语汇拧着 —— 与
/// `app_shell.dart` 的 `ShellNavBar` 当初拒绝 M3 底部栏是同一个判断。
///
/// ## 为什么只显示当前档的说明
///
/// 三档各配一句说明，竖排会占掉屏幕一半高度。只显示选中档那句，省一半空间，
/// 而且**选中态本身就是状态展示** —— 这正是原先 `_StatusBanner` 要解决的
/// 问题（见 `agent_settings_screen.dart` 的类文档），现在用段位高亮直接解决，
/// 横幅可以删。
///
/// ## 不依赖任何 provider
///
/// 只收 `value` / `onChanged` / `enabled` 三个参数，方便直接构造测试。
class ModeSegmented extends StatelessWidget {
  final PermissionMode value;
  final ValueChanged<PermissionMode> onChanged;

  /// false 时置灰且点击无效（服务器页"跟随全局"打开时用它）。
  /// **仍然渲染当前值** —— 用户要看得到自己在跟随什么。
  final bool enabled;

  const ModeSegmented({
    super.key,
    required this.value,
    required this.onChanged,
    this.enabled = true,
  });

  static String labelOf(BuildContext context, PermissionMode m) {
    final l = context.l10n;
    return switch (m) {
      PermissionMode.readOnly => l.agentPermReadOnly,
      PermissionMode.ask => l.agentPermAsk,
      PermissionMode.bypass => l.agentPermBypass,
    };
  }

  static String descOf(BuildContext context, PermissionMode m) {
    final l = context.l10n;
    return switch (m) {
      PermissionMode.readOnly => l.agentPermReadOnlyDesc,
      PermissionMode.ask => l.agentPermAskDesc,
      PermissionMode.bypass => l.agentPermBypassDesc,
    };
  }

  static IconData _iconOf(PermissionMode m) => switch (m) {
        PermissionMode.readOnly => Icons.visibility_outlined,
        PermissionMode.ask => Icons.pan_tool_outlined,
        PermissionMode.bypass => Icons.bolt,
      };

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final bypass = value == PermissionMode.bypass;

    return Opacity(
      opacity: enabled ? 1 : 0.5,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              for (final m in PermissionMode.values)
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    child: _Segment(
                      key: Key('mode-seg-${m.name}'),
                      icon: _iconOf(m),
                      label: labelOf(context, m),
                      selected: m == value,
                      danger: m == PermissionMode.bypass,
                      onTap: enabled ? () => onChanged(m) : null,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              descOf(context, value),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: bypass ? cs.error : cs.onSurfaceVariant,
                  ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Segment extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final bool danger;
  final VoidCallback? onTap;

  const _Segment({
    super.key,
    required this.icon,
    required this.label,
    required this.selected,
    required this.danger,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final Color borderColor;
    final Color? bg;
    final Color fg;

    if (danger) {
      borderColor = selected ? cs.error : cs.outlineVariant;
      bg = selected ? cs.errorContainer : null;
      fg = selected ? cs.onErrorContainer : cs.error;
    } else {
      borderColor = selected ? cs.primary : cs.outlineVariant;
      bg = selected ? cs.primaryContainer.withValues(alpha: 0.4) : null;
      fg = selected ? cs.primary : cs.onSurfaceVariant;
    }

    return Material(
      color: bg ?? Colors.transparent,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            border: Border.all(color: borderColor, width: selected ? 2 : 1),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Column(
            children: [
              Icon(icon, size: 20, color: fg),
              const SizedBox(height: 4),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: fg,
                      fontWeight: selected ? FontWeight.w600 : null,
                    ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 切到 bypass 的二次确认。设置页与服务器页共用 —— 它与"哪台服务器"无关。
///
/// 返回 true = 用户确认。**这是唯一一个"放开"而非"收紧"的方向**，所以只有它
/// 需要确认；选 readOnly / ask 不弹。
Future<bool> confirmBypass(BuildContext context) async {
  final l = context.l10n;
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(l.agentPermBypass),
      content: Text(l.agentModeBypassWarning),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: Text(MaterialLocalizations.of(ctx).cancelButtonLabel),
        ),
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          child: Text(MaterialLocalizations.of(ctx).okButtonLabel),
        ),
      ],
    ),
  );
  return ok == true;
}
