// SPDX-License-Identifier: GPL-3.0-or-later
// lib/commerce/feature_gate.dart
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../telemetry/breadcrumb_helpers.dart';
import '../ui/commerce/paywall_screen.dart';
import 'entitlement_service.dart';
import 'feature_flags.dart';

/// Pro 入口拦截工具。在 4 个 Pro 功能入口（QUIC/Mosh Transport / SFTP /
/// Tunnel / AI 总开关）用 [checkOrShow] 守卫。
class FeatureGate {
  static bool isEntitled(BuildContext ctx) {
    if (!kEnableInAppPurchase) return true;
    return ctx.read<EntitlementService>().isPro;
  }

  static Future<bool> checkOrShow(BuildContext ctx,
      {required String reason}) async {
    if (!kEnableInAppPurchase) return true;
    if (ctx.read<EntitlementService>().isPro) return true;
    Breadcrumbs.paywall('shown', reason: reason);
    await Navigator.of(ctx).push(
      MaterialPageRoute(
        builder: (_) => PaywallScreen(triggerReason: reason),
        fullscreenDialog: true,
      ),
    );
    if (!ctx.mounted) return false;
    final passed = ctx.read<EntitlementService>().isPro;
    Breadcrumbs.paywall(passed ? 'converted' : 'dismissed', reason: reason);
    return passed;
  }

  static void show(BuildContext ctx, {required String reason}) {
    if (!kEnableInAppPurchase) return;
    Breadcrumbs.paywall('shown', reason: reason);
    Navigator.of(ctx).push(
      MaterialPageRoute(
        builder: (_) => PaywallScreen(triggerReason: reason),
        fullscreenDialog: true,
      ),
    );
  }
}
