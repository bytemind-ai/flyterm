// test/commerce/purchase_service_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/commerce/product_catalog.dart';

// 注意：PurchaseService 实际行为依赖 in_app_purchase SDK，需要真机 Sandbox
// 测试。这里只验证商品 ID 配置正确性 + 静态行为。完整 IAP 流程在 manual
// verification（Step 10）做。
void main() {
  group('ProductCatalog', () {
    test('proLifetime ID matches App Store / Play Console config', () {
      expect(ProductCatalog.proLifetime, 'flyterm_pro_lifetime');
    });

    test('productIds set contains proLifetime', () {
      expect(ProductCatalog.productIds.contains(ProductCatalog.proLifetime),
          true);
      expect(ProductCatalog.productIds.length, 1);
    });
  });
}
