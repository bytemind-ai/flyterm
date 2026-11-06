// SPDX-License-Identifier: GPL-3.0-or-later
// lib/ui/commerce/purchase_state_view.dart
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../commerce/entitlement_service.dart';
import '../../commerce/feature_flags.dart';
import '../../commerce/feature_gate.dart';
import '../../commerce/purchase_service.dart';
import '../../l10n/l10n.dart';

/// 设置页 Pro 状态卡片。两种形态：
///   • Pro：mint 背景卡片 + "FlyTerm Pro · 已激活" + 购买日期 + 恢复按钮（用于
///     跨设备验证）
///   • Free：outlined 卡片 + "免费版" + Upgrade 按钮 + Restore 按钮
///
/// NOTE: Upgrade 按钮当前直接 push PaywallScreen。Wave 4 创建 FeatureGate 后
/// 替换为 FeatureGate.show(context, reason: 'settings_upgrade')。
class PurchaseStateView extends StatelessWidget {
  const PurchaseStateView({super.key});

  static const _accent = Color(0xFF00C896);

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return Consumer<EntitlementService>(
      builder: (context, ent, _) {
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: ent.isPro
              ? _proCard(context, l, ent.purchasedAt)
              : _freeCard(context, l),
        );
      },
    );
  }

  Widget _proCard(BuildContext context, AppLocalizations l, DateTime? purchasedAt) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: _accent.withOpacity(0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: _accent.withOpacity(0.5), width: 0.8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.workspace_premium_outlined, size: 22, color: _accent),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Text(l.proStatusPro,
                        style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: _accent,
                            height: 1.3)),
                    if (!kEnableInAppPurchase) ...[
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: Colors.amber.withOpacity(0.18),
                          borderRadius: BorderRadius.circular(3),
                          border: Border.all(
                              color: Colors.amber.withOpacity(0.5),
                              width: 0.6),
                        ),
                        child: const Text(
                          'OPEN SOURCE',
                          style: TextStyle(
                            fontSize: 9.5,
                            fontWeight: FontWeight.w700,
                            color: Colors.amber,
                            letterSpacing: 0.6,
                            fontFamily: 'JetBrainsMono',
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                if (purchasedAt != null && kEnableInAppPurchase) ...[
                  const SizedBox(height: 4),
                  Text(
                    l.proStatusPurchasedAt(_fmtDate(purchasedAt)),
                    style: TextStyle(
                        fontSize: 11.5,
                        color: cs.onSurface.withOpacity(0.6),
                        height: 1.4,
                        fontFamily: 'JetBrainsMono'),
                  ),
                ],
              ],
            ),
          ),
          // 开源构建隐藏 Restore — 没有真实票据可以恢复，按下只会浪费一次商店
          // 查询；商店构建保留。
          if (kEnableInAppPurchase)
            TextButton(
              onPressed: () => _restore(context),
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: Text(l.proStatusRestore,
                  style: const TextStyle(fontSize: 12)),
            ),
        ],
      ),
    );
  }

  Widget _freeCard(BuildContext context, AppLocalizations l) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: cs.surfaceVariant.withOpacity(0.45),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
            color: cs.onSurface.withOpacity(0.08), width: 0.5),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Icon(Icons.workspace_premium_outlined,
                  size: 22, color: cs.onSurface.withOpacity(0.4)),
              const SizedBox(width: 12),
              Expanded(
                child: Text(l.proStatusFree,
                    style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: cs.onSurface.withOpacity(0.7),
                        height: 1.3)),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 40,
                  child: FilledButton(
                    onPressed: () => FeatureGate.show(
                      context,
                      reason: 'settings_upgrade',
                    ),
                    style: FilledButton.styleFrom(
                      backgroundColor: _accent,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(6)),
                    ),
                    child: Text(l.proStatusUpgrade,
                        style: const TextStyle(
                            fontSize: 13, fontWeight: FontWeight.w600)),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                height: 40,
                child: OutlinedButton(
                  onPressed: () => _restore(context),
                  style: OutlinedButton.styleFrom(
                    side: BorderSide(
                        color: cs.onSurface.withOpacity(0.2), width: 0.7),
                    foregroundColor: cs.onSurface.withOpacity(0.8),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(6)),
                  ),
                  child: Text(l.proStatusRestore,
                      style: const TextStyle(fontSize: 13)),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _restore(BuildContext context) async {
    final l = context.l10n;
    final messenger = ScaffoldMessenger.of(context);
    await context.read<PurchaseService>().restorePurchases();
    await Future.delayed(const Duration(seconds: 3));
    if (!context.mounted) return;
    if (EntitlementService.instance.isPro) {
      messenger.showSnackBar(SnackBar(content: Text(l.paywallRestoreSuccess)));
    } else {
      messenger.showSnackBar(
          SnackBar(content: Text(l.paywallRestoreNoneFound)));
    }
  }

  static String _fmtDate(DateTime d) {
    String two(int n) => n < 10 ? '0$n' : '$n';
    return '${d.year}-${two(d.month)}-${two(d.day)}';
  }
}
