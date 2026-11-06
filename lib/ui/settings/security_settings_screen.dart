// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/terminal_settings.dart';
import '../../l10n/l10n.dart';
import 'widgets/settings_section_header.dart';

/// 安全领域子页。
///
/// 危险命令保护 原先被塞在「终端」段（它是安全，不是终端行为），2026-10-07
/// 重排移入独立的「安全」领域 —— 竞品（Blink/ShellFish）均把 Security 独立
/// 成段。
///
/// 2026-10-07 稍后：**生物识别锁已整体移除**（用户决定）。该功能此前是半成品
/// —— 开关与 `LockScreen` 都在，但 `LockScreen` 零调用方、`app` 的
/// `didChangeAppLifecycleState` 是空壳，所以开关实际不产生任何效果。删除后本
/// 页只剩危险命令保护一项；保留「安全」段与子页（1 项也比把它塞回「终端」段
/// 语义正确）。
class SecuritySettingsScreen extends StatelessWidget {
  const SecuritySettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return Scaffold(
      appBar: AppBar(
        title: Text(l.securitySettingsTitle),
        elevation: 0,
        scrolledUnderElevation: 0,
      ),
      body: ListView(
        children: [
          const SettingsSectionHeader('GUARD'),
          _DangerousCommandGuardTile(),
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}

class _DangerousCommandGuardTile extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final settings = context.watch<TerminalSettings>();
    return SwitchListTile(
      dense: true,
      visualDensity: VisualDensity.compact,
      secondary: const Icon(Icons.shield_outlined, size: 20),
      title: Text(l.dangerousCommandGuard),
      subtitle: Text(
        l.dangerousCommandGuardDesc,
        style: const TextStyle(fontSize: 11.5),
      ),
      value: settings.dangerousCommandGuard,
      onChanged: settings.setDangerousCommandGuard,
    );
  }
}
