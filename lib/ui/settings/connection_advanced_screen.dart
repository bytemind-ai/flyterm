// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/terminal_settings.dart';
import '../../l10n/l10n.dart';
import 'widgets/notification_permission_tile.dart';
import 'widgets/settings_section_header.dart';

/// 高级连接选项子页：SSH 压缩 / 后台保活。
///
/// 这两项此前**没有任何用户入口** —— 值存在于 TerminalSettings、参与连接
/// 行为、且已接入 app_control（AI 可通过 app_change 改），但设置页从未渲染
/// 它们（_SshCompressionTile 是定义了却无引用的死代码，backgroundKeepAlive
/// 连 tile 都没有）。2026-10-07 重排把入口补上。
class ConnectionAdvancedScreen extends StatelessWidget {
  const ConnectionAdvancedScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return Scaffold(
      appBar: AppBar(
        title: Text(l.connectionAdvancedTitle),
        elevation: 0,
        scrolledUnderElevation: 0,
      ),
      body: ListView(
        children: [
          const SettingsSectionHeader('TRANSPORT'),
          _SshCompressionTile(),
          _BackgroundKeepAliveTile(),
          const SizedBox(height: 16),
          // 通知权限紧跟在「后台保活」下面：两者讲的是同一件事（能不能在
          // app 不在前台时收到任务通知），而且保活开着权限却被拒是最常见的
          // 误解来源 —— 用户以为开了保活就该收到通知了。放一起才能一眼看出
          // 「两个都要满足」。
          const SettingsSectionHeader('NOTIFICATIONS'),
          const NotificationPermissionTile(),
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}

class _SshCompressionTile extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final settings = context.watch<TerminalSettings>();
    return SwitchListTile(
      dense: true,
      visualDensity: VisualDensity.compact,
      secondary: const Icon(Icons.compress, size: 20),
      title: Text(l.sshCompressionTitle),
      subtitle: Text(
        l.sshCompressionDesc,
        style: const TextStyle(fontSize: 11.5),
      ),
      value: settings.sshCompression,
      onChanged: settings.setSshCompression,
    );
  }
}

class _BackgroundKeepAliveTile extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final settings = context.watch<TerminalSettings>();
    return SwitchListTile(
      dense: true,
      visualDensity: VisualDensity.compact,
      secondary: const Icon(Icons.notifications_active_outlined, size: 20),
      title: Text(l.backgroundKeepAliveTitle),
      subtitle: Text(
        l.backgroundKeepAliveDesc,
        style: const TextStyle(fontSize: 11.5),
      ),
      value: settings.backgroundKeepAlive,
      onChanged: settings.setBackgroundKeepAlive,
    );
  }
}
