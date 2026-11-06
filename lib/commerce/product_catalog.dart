// SPDX-License-Identifier: GPL-3.0-or-later
// lib/commerce/product_catalog.dart

/// 应用内购买商品定义。当前 FlyTerm Pro 一次性买断模式仅一个商品。
///
/// 商品 ID 在 App Store Connect 和 Play Console 两端必须配置为同一字符串
/// 才能在 Flutter 端走单一商品 ID 查询路径。
///
/// 修改商品 ID 前必须先在两个商店后台同步更新，否则 IAP 会失败。
abstract class ProductCatalog {
  /// FlyTerm Pro lifetime purchase（一次性买断，永久解锁 Pro 功能）。
  static const String proLifetime = 'flyterm_pro_lifetime';

  /// 所有需要在启动时 queryProductDetails 的商品 ID。
  static const Set<String> productIds = {proLifetime};
}
