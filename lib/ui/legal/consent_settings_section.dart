// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../consent/consent_manager.dart';
import '../../l10n/l10n.dart';
import '../settings/widgets/settings_section_header.dart';
import 'privacy_policy_screen.dart';
import 'terms_of_service_screen.dart';

/// 隐私偏好区域，三层分组：
///   • PRIVACY    — 崩溃 / 统计 toggle
///   • DOCUMENTS  — 隐私政策 / ToS 阅读入口
///   • DANGER ZONE — Revoke 卡片化，outlined 警示边框
///
/// 2026-10-07：「开源许可」行已移出本组件（→ `AboutScreen`）。它的语义归属
/// 是「关于本 app」而非隐私，留在文档组里会让「隐私」混进法律展示性内容。
/// 挂在 `PrivacySettingsScreen` 的「PRIVACY」子段下。
class ConsentSettingsSection extends StatelessWidget {
  const ConsentSettingsSection({super.key});

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return Consumer<ConsentManager>(
      builder: (context, manager, _) {
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Telemetry toggles — 紧凑度对齐其他配置 SwitchListTile（设置主屏 5 个）。
            SwitchListTile(
              dense: true,
              visualDensity: VisualDensity.compact,
              secondary: const Icon(Icons.bug_report_outlined, size: 20),
              title: Text(l.privacyCrashReportingToggle),
              subtitle: Text(
                l.privacyCrashReportingDesc,
                style: const TextStyle(fontSize: 11.5),
              ),
              value: manager.crashReportingEnabled,
              onChanged: (v) => manager.setCrashReportingEnabled(v),
            ),
            SwitchListTile(
              dense: true,
              visualDensity: VisualDensity.compact,
              secondary: const Icon(Icons.analytics_outlined, size: 20),
              title: Text(l.privacyAnalyticsToggle),
              subtitle: Text(
                l.privacyAnalyticsDesc,
                style: const TextStyle(fontSize: 11.5),
              ),
              value: manager.analyticsEnabled,
              onChanged: (v) => manager.setAnalyticsEnabled(v),
            ),
            const SizedBox(height: 8),
            SettingsSectionHeader(l.privacySectionDocuments),
            ListTile(
              leading: const Icon(Icons.article_outlined, size: 20),
              title: Text(l.privacyViewPolicy),
              trailing: const Icon(Icons.chevron_right, size: 18),
              dense: true,
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const PrivacyPolicyScreen()),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.gavel_outlined, size: 20),
              title: Text(l.privacyViewToS),
              trailing: const Icon(Icons.chevron_right, size: 18),
              dense: true,
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const TermsOfServiceScreen()),
              ),
            ),
            const SizedBox(height: 16),
            SettingsSectionHeader(l.privacySectionDangerZone),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: _DangerCard(
                title: l.privacyRevokeButton,
                desc: l.privacyRevokeCardDesc,
                onTap: () => _confirmRevoke(context, manager),
              ),
            ),
            const SizedBox(height: 8),
          ],
        );
      },
    );
  }

  Future<void> _confirmRevoke(
    BuildContext context,
    ConsentManager manager,
  ) async {
    final l = context.l10n;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l.privacyRevokeConfirmTitle),
        content: Text(l.privacyRevokeConfirmDesc),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(l.privacyRevokeConfirmNo),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
            ),
            child: Text(l.privacyRevokeConfirmYes),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await manager.revoke();
      SystemNavigator.pop();
    }
  }
}

/// JetBrainsMono uppercase 小标题，复用 HomeScreen industrial console 范式。
class _DangerCard extends StatelessWidget {
  const _DangerCard({
    required this.title,
    required this.desc,
    required this.onTap,
  });
  final String title;
  final String desc;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: cs.errorContainer.withOpacity(0.15),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: cs.error.withOpacity(0.4), width: 0.8),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              Icons.warning_amber_outlined,
              size: 22,
              color: cs.error,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: cs.error,
                      height: 1.3,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    desc,
                    style: TextStyle(
                      fontSize: 11.5,
                      color: cs.onSurface.withOpacity(0.6),
                      height: 1.4,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
