// SPDX-License-Identifier: GPL-3.0-or-later
// lib/ui/settings/open_source_licenses_screen.dart
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// 跳转到 Flutter 内置 LicensePage。
/// 把所有依赖（含 license 文本）一次性列出，满足 MIT/Apache/BSD 等告知要求。
///
/// 不自己写一份 license 列表 —— Flutter framework 已经在 build 时把所有
/// pubspec 依赖的 LICENSE 文件聚合到 `LicenseRegistry`，showLicensePage 直接读取。
class OpenSourceLicensesScreen extends StatelessWidget {
  const OpenSourceLicensesScreen({super.key});

  static Future<void> open(BuildContext context) async {
    final info = await PackageInfo.fromPlatform();
    if (!context.mounted) return;
    showLicensePage(
      context: context,
      applicationName: 'FlyTerm',
      applicationVersion: '${info.version}+${info.buildNumber}',
      applicationLegalese: '© 2026 FlyTerm Team',
    );
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
