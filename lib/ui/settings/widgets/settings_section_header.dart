// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';

/// Industrial Monitor Console 风格段头。
///
/// ASCII label → JetBrainsMono + 大写 + 字距 1.2；CJK label → 系统字体、不转大小写。
/// 实现原样取自 settings_screen.dart 的 `_SectionHeader`（与 keybar_editor_screen.dart
/// 的同名类逐字相同），2026-10-07 抽公共以免拆成多个子页后复制 6 份。
class SettingsSectionHeader extends StatelessWidget {
  const SettingsSectionHeader(this.label, {super.key});

  final String label;

  static bool _isAscii(String s) {
    for (final c in s.codeUnits) {
      if (c > 0x7E) return false;
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final ascii = _isAscii(label);
    final color = Theme.of(context).colorScheme.onSurface.withOpacity(0.55);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
      child: Text(
        ascii ? label.toUpperCase() : label,
        style: TextStyle(
          fontFamily: ascii ? 'JetBrainsMono' : null,
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: color,
          letterSpacing: ascii ? 1.2 : 0,
          height: 1.0,
        ),
      ),
    );
  }
}
