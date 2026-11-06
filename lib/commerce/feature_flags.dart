// SPDX-License-Identifier: GPL-3.0-or-later
// lib/commerce/feature_flags.dart

/// 编译时商业化开关。通过 `--dart-define=FLYTERM_ENABLE_IAP=true` 注入。
///
/// **默认 false —— 源码构建全功能解锁。** 这与项目的开源模式一致：代码免费，
/// 商店版卖的是省事、签名与自动更新。自行克隆构建的人不该撞上一个他根本
/// 无法完成支付的 Paywall。
///
/// 默认构建（false）行为：
///   • EntitlementService.load() 直接 markPro，不读 SharedPreferences
///   • FeatureGate.isEntitled / checkOrShow 永远 true，不弹 Paywall
///   • PurchaseService.init() short-circuit，不初始化 IAP / 不订阅 purchaseStream
///   • PurchaseStateView Pro 卡片标识 "OPEN SOURCE"
///
/// 商店构建（true）：完整 IAP 闭环。
///
/// 切换方式：
///   开源：flutter build apk ...  （不带 flag）
///   上架：flutter build apk ... --dart-define=FLYTERM_ENABLE_IAP=true
const bool kEnableInAppPurchase = bool.fromEnvironment(
  'FLYTERM_ENABLE_IAP',
  defaultValue: false,
);
