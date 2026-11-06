// SPDX-License-Identifier: GPL-3.0-or-later
// lib/ui/commerce/paywall_screen.dart
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../commerce/entitlement_service.dart';
import '../../commerce/purchase_service.dart';
import '../../l10n/l10n.dart';
import '../legal/privacy_policy_screen.dart';
import '../legal/terms_of_service_screen.dart';

/// Pro 升级 modal。
///   • Hero logo（terminal icon + mint）
///   • 4 行 feature 列表
///   • 价格区（从 PurchaseService 拿本地化价格）
///   • Purchase 主按钮 / Restore 副按钮 / "稍后" TextButton
///   • 底部 inline 隐私 / ToS 链接
///
/// 监听 EntitlementService：用户购买完成 isPro=true 时自动 pop。
class PaywallScreen extends StatefulWidget {
  const PaywallScreen({super.key, required this.triggerReason});

  /// 触发来源（'pro_transport' / 'pro_sftp' / 'pro_tunnel' / 'pro_ai'），
  /// 写到 Sentry breadcrumb 用于转化漏斗分析。
  final String triggerReason;

  @override
  State<PaywallScreen> createState() => _PaywallScreenState();
}

class _PaywallScreenState extends State<PaywallScreen> {
  static const _accent = Color(0xFF00C896);
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    // 监听 EntitlementService — 购买完成自动 pop。
    EntitlementService.instance.addListener(_onEntitlementChanged);
  }

  @override
  void dispose() {
    EntitlementService.instance.removeListener(_onEntitlementChanged);
    super.dispose();
  }

  void _onEntitlementChanged() {
    if (EntitlementService.instance.isPro && mounted) {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final cs = Theme.of(context).colorScheme;
    final purchase = context.watch<PurchaseService>();
    // 价格优先级：
    //   1. 商店真实本地化价格（最准，含货币符号 / 区域差异）
    //   2. 商店 unavailable / 商品未配置 fallback "$14.99"（design 默认）
    // 这样开发期 / 商店尚未配商品 / 模拟器 也能看到价格而非 "加载中..." 永挂。
    // 真上架前必须在 App Store Connect / Play Console 创建 flyterm_pro_lifetime
    // 商品（iOS Tier 15 / Play 价格 $14.99）才能拿到 #1 价格；此 fallback 仅
    // 是 UX 兜底。
    const _kFallbackPrice = r'$14.99';
    final priceLabel = purchase.proProduct?.price ?? _kFallbackPrice;
    final purchaseAvailable = purchase.isAvailable && purchase.proProduct != null;
    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // close
              Align(
                alignment: Alignment.centerRight,
                child: IconButton(
                  icon: const Icon(Icons.close, size: 22),
                  onPressed: () => Navigator.of(context).pop(),
                  visualDensity: VisualDensity.compact,
                ),
              ),
              const SizedBox(height: 8),
              // Hero logo
              Center(
                child: Container(
                  width: 64,
                  height: 64,
                  decoration: BoxDecoration(
                    color: _accent.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: _accent, width: 1),
                  ),
                  child: const Icon(Icons.workspace_premium_outlined,
                      size: 32, color: _accent),
                ),
              ),
              const SizedBox(height: 24),
              Text(l.paywallTitle,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      fontSize: 28, fontWeight: FontWeight.w700, height: 1.2)),
              const SizedBox(height: 8),
              Text(l.paywallSubtitle,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontSize: 14,
                      color: cs.onSurface.withOpacity(0.6),
                      height: 1.4)),
              const SizedBox(height: 28),
              // feature rows
              _featureRow(context, Icons.flash_on_outlined, l.paywallFeatureQuic),
              _featureRow(context, Icons.psychology_outlined, l.paywallFeatureAi),
              _featureRow(context, Icons.cable_outlined, l.paywallFeatureTunnel),
              _featureRow(context, Icons.update, l.paywallFeatureFutureUpdates),
              const SizedBox(height: 28),
              // purchase button — 商店不可用时按钮 disabled 但仍显示价格
              // （fallback），用户至少知道目标定价，避免空白挂着的 UX。
              SizedBox(
                height: 52,
                child: FilledButton(
                  onPressed:
                      (_busy || !purchaseAvailable) ? null : _onPurchase,
                  style: FilledButton.styleFrom(
                    backgroundColor: _accent,
                    foregroundColor: Colors.white,
                    disabledBackgroundColor: _accent.withOpacity(0.4),
                    disabledForegroundColor: Colors.white.withOpacity(0.7),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8)),
                  ),
                  child: _busy
                      ? const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white))
                      : Text(
                          l.paywallPurchaseButton(priceLabel),
                          style: const TextStyle(
                              fontSize: 15, fontWeight: FontWeight.w600),
                        ),
                ),
              ),
              if (!purchaseAvailable) ...[
                const SizedBox(height: 6),
                Center(
                  child: Text(
                    l.paywallUnavailable,
                    style: TextStyle(
                      fontSize: 11.5,
                      color: cs.error.withOpacity(0.75),
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 12),
              // restore
              TextButton(
                onPressed: _busy ? null : _onRestore,
                child: Text(l.paywallRestoreButton,
                    style: TextStyle(
                        fontSize: 13, color: cs.onSurface.withOpacity(0.7))),
              ),
              const SizedBox(height: 4),
              // continue later
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(l.paywallContinueLater,
                    style: TextStyle(
                        fontSize: 13, color: cs.onSurface.withOpacity(0.5))),
              ),
              const SizedBox(height: 16),
              // inline privacy / ToS links
              Text.rich(
                TextSpan(
                  style: TextStyle(
                      fontSize: 11.5,
                      color: cs.onSurface.withOpacity(0.5),
                      height: 1.5),
                  children: [
                    TextSpan(text: '${l.consentAgreeBoilerplate} '),
                    _linkSpan(context, l.consentPrivacyLink,
                        const PrivacyPolicyScreen()),
                    TextSpan(text: ' ${l.consentAgreeBoilerplateAnd} '),
                    _linkSpan(context, l.consentTosLink,
                        const TermsOfServiceScreen()),
                    const TextSpan(text: '.'),
                  ],
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _featureRow(BuildContext context, IconData icon, String label) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Icon(icon, size: 18, color: _accent),
          const SizedBox(width: 12),
          Expanded(
            child: Text(label,
                style: TextStyle(
                    fontSize: 13.5,
                    color: cs.onSurface.withOpacity(0.85),
                    height: 1.35)),
          ),
        ],
      ),
    );
  }

  InlineSpan _linkSpan(BuildContext ctx, String label, Widget page) {
    return WidgetSpan(
      alignment: PlaceholderAlignment.middle,
      child: GestureDetector(
        onTap: () =>
            Navigator.of(ctx).push(MaterialPageRoute(builder: (_) => page)),
        child: Text(label,
            style: TextStyle(
                fontSize: 11.5,
                color: _accent,
                decoration: TextDecoration.underline,
                decorationColor: _accent.withOpacity(0.6))),
      ),
    );
  }

  Future<void> _onPurchase() async {
    setState(() => _busy = true);
    try {
      final result = await context.read<PurchaseService>().buyPro();
      if (!mounted) return;
      switch (result) {
        case PurchaseOutcome.unavailable:
          _snack(context.l10n.paywallUnavailable);
          break;
        case PurchaseOutcome.pending:
          _snack(context.l10n.paywallPurchasePending);
          // 不退出 modal — 等 purchaseStream 回调 markPro 触发 pop
          break;
        case PurchaseOutcome.error:
          _snack(context.l10n.paywallPurchaseError('unknown'));
          break;
        case PurchaseOutcome.canceled:
        case PurchaseOutcome.success:
          break;
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _onRestore() async {
    setState(() => _busy = true);
    try {
      final result = await context.read<PurchaseService>().restorePurchases();
      if (!mounted) return;
      if (result == PurchaseOutcome.unavailable) {
        _snack(context.l10n.paywallUnavailable);
      }
      // 等 3 秒看 EntitlementService 是否变 pro
      await Future.delayed(const Duration(seconds: 3));
      if (!mounted) return;
      if (!EntitlementService.instance.isPro) {
        _snack(context.l10n.paywallRestoreNoneFound);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _snack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }
}
