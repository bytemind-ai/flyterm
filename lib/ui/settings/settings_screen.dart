// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';

import '../../ai/agent/agent_session_manager.dart';
// PermissionMode 定义在此（首页「Agent 设置」行的 subtitle 用）
import '../../ai/agent/tool_registry.dart';
import '../../consent/consent_manager.dart';
import '../../data/keybar_settings.dart';
import '../../data/terminal_settings.dart';
import '../../l10n/l10n.dart';
import '../terminal/terminal_themes.dart';
import 'widgets/settings_section_header.dart';

/// 设置首页：8 段 / 13 行的领域分段结构。
///
/// 2026-10-07 重排：
/// 原先的「终端」段是杂物间（10 项横跨外观/输入/安全三个维度），「数据与隐私」
/// 段名不副实（8 项实为设备安全 + 数据管理 + 法律合规 + 遥测）。本次按**领域
/// 对象**重新分段（Termius 范式），同类控件收进领域子页。
///
/// 首页能放什么：段头 + 导航行 + 极少数单项开关。判据是「它是否
/// 有同组兄弟」—— 有则进子页；没有（如命令补全）才可留首页内联。
/// 任何「一组同类控件」都必须进子页。
///
/// 导航行显示动态 subtitle（当前设置值）—— 收进子页后用户失去了直接看到当前
/// 值的能力，动态 subtitle 是对这个损失的补偿。没有它，首页会退化
/// 成一堆无信息的标签。
class SettingsScreen extends StatelessWidget {
  /// true = 作为 `AppShell` 的一个 tab 渲染，没有返回箭头（没地方可返回）。
  /// false = 通过 `/settings` 路由 push 进来，保留返回箭头。
  final bool embedded;

  const SettingsScreen({super.key, this.embedded = false});

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return Scaffold(
      appBar: AppBar(
        title: Text(l.settings),
        automaticallyImplyLeading: !embedded,
        elevation: 0,
        scrolledUnderElevation: 0,
      ),
      body: ListView(
        children: [
          const SizedBox(height: 12),

          // ── 外观 ──
          SettingsSectionHeader(l.sectionAppearance),
          _NavTile(
            icon: Icons.palette_outlined,
            title: l.appearanceSettingsTitle,
            subtitle: _appearanceSubtitle(context),
            route: '/settings/appearance',
          ),

          // ── 输入 ──
          // 按键栏编辑不单开顶层段：它会形成「首页→输入→按键栏」三层深，
          // 而 CLAUDE.md 已判定按键栏三层深是问题。放段内首位即可。
          SettingsSectionHeader(l.sectionInput),
          _NavTile(
            icon: Icons.keyboard_alt_outlined,
            title: l.keybarCustomize,
            subtitle: l.keybarCount(context.watch<KeybarSettings>().items.length),
            route: '/settings/keybar',
          ),
          _NavTile(
            icon: Icons.swap_horiz,
            title: l.fetSettingsTitle,
            subtitle: context.watch<TerminalSettings>().fetEnabled
                ? l.enabled
                : l.disabled,
            route: '/settings/fet',
          ),
          // 命令补全只有一项，为它单开子页是荒谬的 —— 这是首页唯一保留的内联
          // 开关（首页可有内联控件，只要该段主语义仍是导航）。
          const _CommandCompletionTile(),

          // ── 连接 ──
          SettingsSectionHeader(l.sectionConnection),
          _NavTile(
            icon: Icons.key,
            title: l.sshKeys,
            subtitle: l.sshKeysSubtitle,
            route: '/settings/keys',
          ),
          _NavTile(
            icon: Icons.shield_outlined,
            title: l.knownHostsEntry,
            subtitle: l.knownHostsEntrySubtitle,
            route: '/settings/known-hosts',
          ),
          _NavTile(
            icon: Icons.tune,
            title: l.connectionAdvancedTitle,
            subtitle: _connectionAdvancedSubtitle(context),
            route: '/settings/connection-advanced',
          ),

          // ── 安全 ──
          // 独立成段是竞品共识（Blink/ShellFish 均有 Security 段）。此前生物
          // 识别锁被塞在「数据与隐私」、危险命令守卫被塞在「终端」，两处归属
          // 都错。
          SettingsSectionHeader(l.sectionSecurity),
          _NavTile(
            icon: Icons.lock_outline,
            title: l.securitySettingsTitle,
            subtitle: _securitySubtitle(context),
            route: '/settings/security',
          ),

          // ── AI ──
          SettingsSectionHeader(l.sectionAI),
          _NavTile(
            icon: Icons.auto_awesome,
            title: l.aiProviders,
            subtitle: l.aiProvidersSubtitle,
            route: '/settings/ai-providers',
          ),
          _NavTile(
            icon: Icons.smart_toy_outlined,
            title: l.agentSettingsTitle,
            subtitle: switch (context.watch<AgentSessionManager>().defaultMode) {
              PermissionMode.readOnly => l.agentPermReadOnly,
              PermissionMode.ask => l.agentPermAsk,
              PermissionMode.bypass => l.agentPermBypass,
            },
            route: '/settings/agent',
          ),
          // ── 数据与隐私 ──
          SettingsSectionHeader(l.sectionData),
          _NavTile(
            icon: Icons.privacy_tip_outlined,
            title: l.sectionData,
            subtitle: _privacySubtitle(context),
            route: '/settings/privacy',
          ),

          // ── 关于 ──
          // 版本行此前无段头孤悬在页尾，升格为独立段。
          SettingsSectionHeader(l.sectionAbout),
          _AboutNavTile(),

          const SizedBox(height: 16),
        ],
      ),
    );
  }
}

/// 首页导航行：图标 + 标题 + 动态 subtitle + chevron。
///
/// 抽出来是因为首页现在有 9 行同构导航 —— 逐行手写会让 build 膨胀到看不清
/// 分段结构本身，而分段结构正是这次重构要让人一眼看见的东西。
class _NavTile extends StatelessWidget {
  const _NavTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.route,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final String route;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon, size: 20),
      title: Text(title),
      subtitle: Text(subtitle, style: const TextStyle(fontSize: 11.5)),
      trailing: const Icon(Icons.chevron_right, size: 18),
      dense: true,
      visualDensity: VisualDensity.compact,
      onTap: () => Navigator.of(context).pushNamed(route),
    );
  }
}

/// 「关于」行。版本号来自 `PackageInfo.fromPlatform()`，是异步的，而 subtitle
/// 必须同步渲染 —— 用一个 static Future 缓存一次结果（PackageInfo 本身也有
/// 内部缓存，这里只是把 async 结果接进同步的 widget 树）。
class _AboutNavTile extends StatelessWidget {
  static final Future<String> _version = PackageInfo.fromPlatform()
      .then((i) => '${i.version}+${i.buildNumber}');

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<String>(
      future: _version,
      builder: (context, snap) => _NavTile(
        icon: Icons.info_outline,
        title: context.l10n.aboutTitle,
        subtitle: snap.data ?? '...',
        route: '/settings/about',
      ),
    );
  }
}

/// 命令补全开关。首页唯一的内联开关 —— 它没有同组兄弟，为单项开子页不合理。
class _CommandCompletionTile extends StatelessWidget {
  const _CommandCompletionTile();

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final settings = context.watch<TerminalSettings>();
    return SwitchListTile(
      dense: true,
      visualDensity: VisualDensity.compact,
      secondary: const Icon(Icons.keyboard_tab, size: 20),
      title: Text(l.commandCompletionTitle),
      subtitle: Text(
        l.commandCompletionSubtitle,
        style: const TextStyle(fontSize: 11.5),
      ),
      value: settings.commandCompletion,
      onChanged: settings.setCommandCompletion,
    );
  }
}

/// 「Tomorrow · JetBrains Mono · 14pt」—— 见 [SettingsScreen] 类文档关于动态
/// subtitle 的说明。
String _appearanceSubtitle(BuildContext context) {
  final s = context.watch<TerminalSettings>();
  return '${_themeShortName(s.terminalTheme)} · ${s.fontFamily} · '
      '${s.fontSize.round()}pt';
}

/// 主题短名。首页 subtitle 用短名而非完整 l10n 标签，避免 subtitle 被挤断；
/// 完整名称在外观子页的下拉里。
String _themeShortName(AppTerminalTheme t) => switch (t) {
      AppTerminalTheme.defaultDark => 'Default',
      AppTerminalTheme.dracula => 'Dracula',
      AppTerminalTheme.solarizedDark => 'Solarized Dark',
      AppTerminalTheme.monokai => 'Monokai',
      AppTerminalTheme.solarizedLight => 'Solarized Light',
      AppTerminalTheme.nord => 'Nord',
      AppTerminalTheme.gruvboxDark => 'Gruvbox',
      AppTerminalTheme.oneDark => 'One Dark',
      AppTerminalTheme.tokyoNight => 'Tokyo Night',
    };

String _connectionAdvancedSubtitle(BuildContext context) {
  final s = context.watch<TerminalSettings>();
  final l = context.l10n;
  return l.settingsConnectionAdvancedSubtitle(
    s.sshCompression ? l.appChangeOn : l.appChangeOff,
    s.backgroundKeepAlive ? l.appChangeOn : l.appChangeOff,
  );
}

String _securitySubtitle(BuildContext context) {
  final s = context.watch<TerminalSettings>();
  final l = context.l10n;
  return l.settingsSecuritySubtitle(
      s.dangerousCommandGuard ? l.appChangeOn : l.appChangeOff);
}

String _privacySubtitle(BuildContext context) {
  final c = context.watch<ConsentManager>();
  final l = context.l10n;
  return l.settingsPrivacySubtitle(
    c.crashReportingEnabled ? l.appChangeOn : l.appChangeOff,
    c.analyticsEnabled ? l.appChangeOn : l.appChangeOff,
  );
}
