// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';

import '../../data/terminal_settings.dart';
import '../../l10n/l10n.dart';
import 'open_source_licenses_screen.dart';
import 'widgets/settings_section_header.dart';

/// 关于子页：版本（含 7 击解锁 debug overlay）+ 开源许可。
///
/// 版本行此前无段头孤悬在设置页尾；开源许可此前在「隐私」段的文档组里，
/// 语义上属于「关于本 app」而非隐私。2026-10-07 重排合并于此。
class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return Scaffold(
      appBar: AppBar(
        title: Text(l.aboutTitle),
        elevation: 0,
        scrolledUnderElevation: 0,
      ),
      body: ListView(
        children: [
          const SettingsSectionHeader('BUILD'),
          _VersionTile(),
          const SettingsSectionHeader('LEGAL'),
          ListTile(
            leading: const Icon(Icons.code, size: 20),
            title: Text(l.settingsOpenSourceLicenses),
            subtitle: Text(
              l.settingsOpenSourceLicensesSubtitle,
              style: const TextStyle(fontSize: 11.5),
            ),
            trailing: const Icon(Icons.chevron_right, size: 18),
            dense: true,
            visualDensity: VisualDensity.compact,
            onTap: () => OpenSourceLicensesScreen.open(context),
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}

class _VersionTile extends StatefulWidget {
  @override
  State<_VersionTile> createState() => _VersionTileState();
}

class _VersionTileState extends State<_VersionTile> {
  static const _kTapsToToggle = 7;
  int _taps = 0;
  Timer? _resetTimer;
  late final Future<PackageInfo> _packageInfo = PackageInfo.fromPlatform();

  @override
  void dispose() {
    _resetTimer?.cancel();
    super.dispose();
  }

  void _onTap() {
    final settings = context.read<TerminalSettings>();
    _resetTimer?.cancel();
    _taps++;
    if (_taps >= _kTapsToToggle) {
      settings.toggleDebugOverlay();
      final on = settings.debugOverlay;
      _taps = 0;
      final l = context.l10n;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(on ? l.debugOverlayEnabled : l.debugOverlayDisabled),
            duration: const Duration(seconds: 2),
          ),
        );
      return;
    }
    final remaining = _kTapsToToggle - _taps;
    if (_taps >= 3) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(context.l10n.debugOverlayTapsRemaining(remaining)),
            duration: const Duration(seconds: 1),
          ),
        );
    }
    _resetTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) _taps = 0;
    });
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<TerminalSettings>();
    return FutureBuilder<PackageInfo>(
      future: _packageInfo,
      builder: (context, snapshot) {
        final info = snapshot.data;
        final version =
            info == null ? '...' : '${info.version}+${info.buildNumber}';
        return ListTile(
          leading: const Icon(Icons.info_outline, size: 20),
          title: Text(context.l10n.version),
          subtitle: Text(
            settings.debugOverlay
                ? context.l10n.versionSubtitleDebugActive(version)
                : version,
            style: const TextStyle(
              fontFamily: 'JetBrainsMono',
              fontSize: 11.5,
            ),
          ),
          dense: true,
          visualDensity: VisualDensity.compact,
          onTap: _onTap,
        );
      },
    );
  }
}

