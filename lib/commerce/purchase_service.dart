// SPDX-License-Identifier: GPL-3.0-or-later
// lib/commerce/purchase_service.dart
import 'dart:async';
import '../util/dlog.dart';
import 'package:flutter/foundation.dart';
import 'package:in_app_purchase/in_app_purchase.dart';

import '../telemetry/breadcrumb_helpers.dart';
import 'entitlement_service.dart';
import 'feature_flags.dart';
import 'product_catalog.dart';

/// 内购操作结果枚举（UI 层据此显示对应反馈）。
enum PurchaseOutcome { unavailable, success, pending, canceled, error }

/// `in_app_purchase` 包的应用层封装。负责：
///   1. 启动时 init: 订阅 purchaseStream + restorePurchases 同步票据
///   2. queryProProduct: 拿本地化价格供 Paywall 显示
///   3. buyPro: 触发原生 IAP 支付
///   4. restorePurchases: 跨设备恢复
///   5. 收到 PurchaseDetails 时调 completePurchase 防漏单 + 更新 EntitlementService
///
/// 错误处理：除致命 SDK 错误外，所有失败/取消/pending 都通过 PurchaseOutcome
/// 返回给调用方，UI 负责呈现。
class PurchaseService {
  PurchaseService({InAppPurchase? iap, EntitlementService? entitlement})
      : _iapOverride = iap,
        _entitlement = entitlement ?? EntitlementService.instance;

  final InAppPurchase? _iapOverride;

  /// 惰性求值，不在构造函数里碰插件。`InAppPurchase.instance` 的 getter 有副
  /// 作用：它会 registerPlatform → new BillingClientManager → 立刻发起
  /// startConnection。main() 无条件 `PurchaseService()`，若在初始化列表里求
  /// 值，开源构建（kEnableInAppPurchase=false）光是建这个 Provider 占位对象
  /// 就会拉起一条 Billing 连接 —— init() 里的 short-circuit 根本拦不住，因为
  /// 插件在 init() 被调用之前就已经被碰过了。
  late final InAppPurchase _iap = _iapOverride ?? InAppPurchase.instance;
  final EntitlementService _entitlement;
  StreamSubscription<List<PurchaseDetails>>? _sub;
  ProductDetails? _cachedProProduct;
  bool _available = false;

  bool get isAvailable => _available;
  ProductDetails? get proProduct => _cachedProProduct;

  /// 必须在 main() 中 EntitlementService.load() 之后调用一次。
  /// 启动 purchaseStream 监听 + 主动 restorePurchases() 跟商店核对票据。
  Future<void> init() async {
    if (!kEnableInAppPurchase) {
      // 开源构建：跳过 IAP 初始化（不订阅 purchaseStream、不查 productDetails、
      // 不 restore）。Paywall 进不来，PurchaseService 仅作为 Provider 占位。
      return;
    }
    _available = await _iap.isAvailable();
    if (!_available) return;

    _sub = _iap.purchaseStream.listen(
      _handlePurchaseUpdates,
      onDone: () => _sub?.cancel(),
      onError: (e, st) {
        dlog('IAP', 'purchaseStream error: $e');
      },
    );

    try {
      final resp = await _iap.queryProductDetails(ProductCatalog.productIds);
      if (resp.productDetails.isNotEmpty) {
        _cachedProProduct = resp.productDetails.firstWhere(
          (p) => p.id == ProductCatalog.proLifetime,
          orElse: () => resp.productDetails.first,
        );
      }
    } catch (e) {
      dlog('IAP', 'queryProductDetails error: $e');
    }

    // 启动时主动 restore 让商店票据 override 本地缓存（防止退款后缓存仍是 pro）。
    try {
      await _iap.restorePurchases();
    } catch (e) {
      dlog('IAP', 'restorePurchases on init error: $e');
    }
  }

  /// 用户在 Paywall 点 Purchase 按钮。
  Future<PurchaseOutcome> buyPro() async {
    if (!_available) return PurchaseOutcome.unavailable;
    final product = _cachedProProduct;
    if (product == null) return PurchaseOutcome.unavailable;
    Breadcrumbs.iap('purchase_started', productId: product.id);
    try {
      final ok = await _iap.buyNonConsumable(
        purchaseParam: PurchaseParam(productDetails: product),
      );
      // 返回 true 仅表示 SDK 收到请求；真实成功在 purchaseStream 回调中。
      return ok ? PurchaseOutcome.pending : PurchaseOutcome.error;
    } catch (e) {
      Breadcrumbs.iap('purchase_error', errorCode: e.toString());
      return PurchaseOutcome.error;
    }
  }

  /// 用户在 Paywall 或设置页点 Restore 按钮。
  Future<PurchaseOutcome> restorePurchases() async {
    if (!_available) return PurchaseOutcome.unavailable;
    Breadcrumbs.iap('restore_started');
    try {
      await _iap.restorePurchases();
      return PurchaseOutcome.pending;
    } catch (e) {
      Breadcrumbs.iap('restore_error', errorCode: e.toString());
      return PurchaseOutcome.error;
    }
  }

  Future<void> _handlePurchaseUpdates(
    List<PurchaseDetails> purchases,
  ) async {
    for (final p in purchases) {
      if (p.productID != ProductCatalog.proLifetime) {
        if (p.pendingCompletePurchase) {
          await _iap.completePurchase(p);
        }
        continue;
      }
      switch (p.status) {
        case PurchaseStatus.purchased:
        case PurchaseStatus.restored:
          Breadcrumbs.iap(
            p.status == PurchaseStatus.purchased ? 'purchased' : 'restored',
            productId: p.productID,
          );
          // 用 transactionDate 如有，否则用当前时间。
          final ts = p.transactionDate != null
              ? DateTime.fromMillisecondsSinceEpoch(
                  int.tryParse(p.transactionDate!) ??
                      DateTime.now().millisecondsSinceEpoch,
                )
              : DateTime.now();
          await _entitlement.markPro(ts);
          if (p.pendingCompletePurchase) {
            await _iap.completePurchase(p);
          }
          break;
        case PurchaseStatus.error:
          Breadcrumbs.iap('error',
              productId: p.productID, errorCode: p.error?.code);
          if (p.pendingCompletePurchase) {
            await _iap.completePurchase(p);
          }
          break;
        case PurchaseStatus.canceled:
          Breadcrumbs.iap('canceled', productId: p.productID);
          if (p.pendingCompletePurchase) {
            await _iap.completePurchase(p);
          }
          break;
        case PurchaseStatus.pending:
          Breadcrumbs.iap('pending', productId: p.productID);
          break;
      }
    }
  }

  void dispose() {
    _sub?.cancel();
    _sub = null;
  }
}
